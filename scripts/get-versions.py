#!/usr/bin/env python3
"""
Generic matrix resolver for bitsnbites CI images.

Reads a versions.yml (or .json) config from the calling repo, fetches each
declared axis from its source (endoflife.date or GitHub releases), takes
the cartesian product, and emits a .matrix.json in the normalized shape
that ci-image.yml consumes.

Sources currently supported
---------------------------

endoflife (endoflife.date/api):
    pw:
      source: endoflife
      product: nodejs        # required, matches the slug in the URL
      only_lts: true         # optional, default false. Drops non-LTS lines.
      min_major: 22          # optional. Drops anything below this major.

  Returned item fields: cycle, latest, lts, eol, support, ..., major (parsed int)

github-releases (api.github.com/repos/.../releases):
    pw:
      source: github-releases
      repo: microsoft/playwright   # required
      keep_minors: 3               # optional, default 3. One latest patch per minor.
      include_prereleases: false   # optional, default false.

  Returned item fields: tag, full, minor, major

Templates
---------

`tags`, `tag_key`, and `build_args` values are templates. Use
`{axis_name.field}` to substitute. Example:

    tag_key: "{pw.minor}-node{node.cycle}"
    tags:
      - "{pw.minor}-node{node.cycle}"
      - "{pw.full}-node{node.cycle}"
    build_args:
      PLAYWRIGHT_VERSION: "{pw.full}"
      NODE_MAJOR: "{node.cycle}"

`latest_when` decides which combo also gets the literal `latest` tag.
For each named axis, give the field to compare against the newest item
of that axis:

    latest_when:
      pw: full
      node: cycle

That means: add `latest` to the combo where `combo.pw.full == newest.pw.full`
AND `combo.node.cycle == newest.node.cycle`.

Output
------

Writes JSON in the shape consumed by ci-image.yml:

    {
      "include": [
        { "tag_key": "1.59-node24",
          "tags":    ["1.59-node24", "1.59.1-node24", "latest"],
          "build_args": { "PLAYWRIGHT_VERSION": "1.59.1", "NODE_MAJOR": "24" } },
        ...
      ]
    }

Usage
-----

    get-versions.py --config versions.yml --out .matrix.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import date


# ----------------------------------------------------------- HTTP helpers

def fetch_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} fetching {url}: {e.reason}")


# --------------------------------------------------------- Config loading

def load_config(path):
    text = open(path, encoding="utf-8").read()
    if path.endswith((".yml", ".yaml")):
        # Prefer PyYAML (standard on GH runners). Fall back to yq if available.
        try:
            import yaml
            return yaml.safe_load(text)
        except ImportError:
            pass
        try:
            return json.loads(
                subprocess.check_output(["yq", "-o=json", ".", path])
            )
        except (FileNotFoundError, subprocess.CalledProcessError):
            sys.exit(
                "Need either PyYAML (`pip install pyyaml`) or yq "
                "(https://github.com/mikefarah/yq) to read YAML configs."
            )
    return json.loads(text)


# -------------------------------------------------------- Source resolvers

def resolve_endoflife(cfg):
    product = cfg["product"]
    only_lts = bool(cfg.get("only_lts", False))
    min_major = int(cfg.get("min_major", 0))
    today = date.today().isoformat()

    raw = fetch_json(f"https://endoflife.date/api/{product}.json")

    out = []
    for entry in raw:
        eol = entry.get("eol")
        if eol is True:
            continue
        if isinstance(eol, str) and eol <= today:
            continue
        if only_lts and (entry.get("lts") in (False, None)):
            continue
        try:
            major = int(entry["cycle"])
        except (ValueError, TypeError, KeyError):
            continue
        if major < min_major:
            continue
        item = dict(entry)
        item["major"] = major
        out.append(item)
    out.sort(key=lambda x: -x["major"])
    return out


def _ver_tuple(v):
    return tuple(int(x) for x in v.split("."))


def resolve_github_releases(cfg):
    repo = cfg["repo"]
    keep = int(cfg.get("keep_minors", 3))
    include_pre = bool(cfg.get("include_prereleases", False))

    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    releases = fetch_json(
        f"https://api.github.com/repos/{repo}/releases?per_page=40", headers
    )

    by_minor = {}
    pat = re.compile(r"^(?P<full>(?P<minor>(?P<major>\d+)\.\d+)\.\d+)$")
    for r in releases:
        if r.get("draft"):
            continue
        if r.get("prerelease") and not include_pre:
            continue
        tag = r.get("tag_name", "").lstrip("v")
        m = pat.match(tag)
        if not m:
            continue
        item = {
            "tag": tag,
            "full": m["full"],
            "minor": m["minor"],
            "major": m["major"],
        }
        existing = by_minor.get(item["minor"])
        if existing is None or _ver_tuple(item["full"]) > _ver_tuple(existing["full"]):
            by_minor[item["minor"]] = item

    minors = sorted(by_minor.values(), key=lambda x: _ver_tuple(x["full"]), reverse=True)
    return minors[:keep]


SOURCE_RESOLVERS = {
    "endoflife": resolve_endoflife,
    "github-releases": resolve_github_releases,
}


# ----------------------------------------------------- Templates / matrix

_PLACEHOLDER = re.compile(r"\{([^}]+)\}")


def fill(template, ctx):
    """Substitute {axis.field} placeholders. Field can be dotted path."""
    def repl(m):
        path = m.group(1).split(".")
        v = ctx
        for p in path:
            if not isinstance(v, dict) or p not in v:
                sys.exit(f"Template error: '{m.group(0)}' refers to missing field "
                         f"({'.'.join(path)}). Available top-level keys: {list(ctx)}")
            v = v[p]
        return str(v)
    return _PLACEHOLDER.sub(repl, template)


def cartesian(axes):
    """Cartesian product. axes: dict[name -> list[item]]. Returns list[dict]."""
    out = [{}]
    for name, items in axes.items():
        out = [{**combo, name: item} for combo in out for item in items]
    return out


# --------------------------------------------------------------- Driver

def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--config", default="versions.yml",
                    help="Path to versions config (yml or json)")
    ap.add_argument("--out", default=".matrix.json",
                    help="Output path for the resolved matrix")
    args = ap.parse_args()

    if not os.path.exists(args.config):
        # Allow .yml or .json without forcing the user to pass either
        for alt_ext in (".json", ".yml", ".yaml"):
            alt = re.sub(r"\.(yml|yaml|json)$", alt_ext, args.config)
            if os.path.exists(alt):
                args.config = alt
                break
        else:
            sys.exit(f"Config not found: {args.config}")

    cfg = load_config(args.config)
    print(f"==> Loaded config from {args.config}", file=sys.stderr)

    if "axes" not in cfg or not cfg["axes"]:
        sys.exit("Config must declare at least one axis under 'axes:'")
    if "tag_key" not in cfg:
        sys.exit("Config must declare 'tag_key' template")

    # Resolve each axis
    resolved = {}
    newest = {}
    for name, axis_cfg in cfg["axes"].items():
        source = axis_cfg.get("source")
        resolver = SOURCE_RESOLVERS.get(source)
        if not resolver:
            sys.exit(f"Axis '{name}': unknown source '{source}'. "
                     f"Supported: {list(SOURCE_RESOLVERS)}")
        items = resolver(axis_cfg)
        if not items:
            sys.exit(f"Axis '{name}' resolved to an empty list — refusing to "
                     "produce an empty matrix.")
        resolved[name] = items
        newest[name] = items[0]
        sample_keys = list(items[0])[:6]
        print(f"    axis {name} ({source}): {len(items)} item(s); "
              f"newest fields {sample_keys}",
              file=sys.stderr)

    # Templates
    tag_templates = cfg.get("tags", [])
    build_args_template = cfg.get("build_args", {})
    tag_key_template = cfg["tag_key"]
    latest_when = cfg.get("latest_when", {})

    combos = cartesian(resolved)

    include = []
    for combo in combos:
        entry = {
            "tag_key":    fill(tag_key_template, combo),
            "tags":       [fill(t, combo) for t in tag_templates],
            "build_args": {k: fill(v, combo) for k, v in build_args_template.items()},
        }
        if latest_when and all(
            combo[axis][field] == newest[axis][field]
            for axis, field in latest_when.items()
        ):
            entry["tags"].append("latest")
        include.append(entry)

    matrix = {"include": include}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(matrix, f, indent=2)
        f.write("\n")

    print(f"==> Wrote {args.out} with {len(include)} build(s)", file=sys.stderr)
    for e in include:
        print(f"    - {e['tag_key']:30s} -> {', '.join(e['tags'])}", file=sys.stderr)


if __name__ == "__main__":
    main()
