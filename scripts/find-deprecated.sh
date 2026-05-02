#!/usr/bin/env bash
# Diff the freshly-resolved supported matrix against what we have already
# published, and emit the list of tags that should be marked deprecated.
#
# This script is image-agnostic. The matrix file is expected to follow the
# normalized shape:
#   {
#     "include": [
#       { "tag_key": "1.59-node24",
#         "tags": ["1.59-node24", "1.59.1-node24", "latest"],
#         "build_args": { ... } },
#       ...
#     ]
#   }
#
# Inputs (env):
#   IMAGE_NAME            required (e.g. "playwright")
#   GHCR_OWNER            default "bitsnbites"
#   DOCKERHUB_NAMESPACE   default "bitsnbites"
#   GITHUB_TOKEN          required for GHCR listing (read:packages)
#   MATRIX                default ".matrix.json"
#   TAG_PATTERN           default '^[0-9]+(\.[0-9]+){1,2}-.+$'
#                         — regex for "version-like" tags this image uses;
#                         tags not matching are ignored (e.g. "latest").
#   OUT                   default ".deprecated.json"
#
# Output: .deprecated.json
#   { "deprecate": [ { "tag": "...", "reason": "..." }, ... ] }
#
# Tags ending in "-deprecated" are skipped (already deprecated).

set -euo pipefail

: "${IMAGE_NAME:?required}"
OWNER="${GHCR_OWNER:-bitsnbites}"
HUB_NS="${DOCKERHUB_NAMESPACE:-bitsnbites}"
MATRIX="${MATRIX:-.matrix.json}"
TAG_PATTERN="${TAG_PATTERN:-^[0-9]+(\.[0-9]+){1,2}-.+$}"
OUT="${OUT:-.deprecated.json}"
TODAY="$(date -u +%Y-%m-%d)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dep: $1" >&2; exit 2; }; }
need curl
need jq

[[ -f "$MATRIX" ]] || { echo "missing $MATRIX — run the matrix resolver first" >&2; exit 3; }

TAGS_FILE="$(mktemp)"
trap 'rm -f "$TAGS_FILE"' EXIT

list_ghcr_tags() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "    GHCR: no GITHUB_TOKEN — skipping" >&2
    return 0
  fi
  local page=1
  while :; do
    local resp
    resp="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/users/${OWNER}/packages/container/${IMAGE_NAME}/versions?per_page=100&page=${page}" \
      || echo '[]')"
    local count
    count="$(jq 'length' <<<"$resp")"
    [[ "$count" -eq 0 ]] && break
    jq -r '.[].metadata.container.tags[]?' <<<"$resp" >> "$TAGS_FILE"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

list_dockerhub_tags() {
  local url="https://hub.docker.com/v2/repositories/${HUB_NS}/${IMAGE_NAME}/tags/?page_size=100"
  while [[ -n "$url" && "$url" != "null" ]]; do
    local resp
    resp="$(curl -fsSL "$url" || echo '{}')"
    jq -r '.results[]?.name' <<<"$resp" >> "$TAGS_FILE"
    url="$(jq -r '.next // empty' <<<"$resp")"
  done
}

echo "==> Listing GHCR tags (${OWNER}/${IMAGE_NAME})"
list_ghcr_tags || true
echo "==> Listing Docker Hub tags (${HUB_NS}/${IMAGE_NAME})"
list_dockerhub_tags || true

PUBLISHED="$(sort -u "$TAGS_FILE" \
  | grep -E "$TAG_PATTERN" \
  | grep -v -- '-deprecated$' \
  | jq -R . | jq -s '. // []')"

PUBLISHED_COUNT="$(jq 'length' <<<"$PUBLISHED")"
echo "    found ${PUBLISHED_COUNT} version-like published tag(s) (pattern: ${TAG_PATTERN})"

# Supported set: union of all tag_key + tags entries from the matrix.
SUPPORTED="$(jq '
  [ .include[] | (.tag_key, .tags[]?) ] | unique
' "$MATRIX")"

DEPRECATE="$(jq -n --argjson published "$PUBLISHED" --argjson supported "$SUPPORTED" --arg today "$TODAY" '
  ($supported | unique) as $sup
  | $published
  | map(select(. as $t | ($sup | index($t)) | not))
  | unique
  | map({
      tag: .,
      reason: "No longer in supported matrix as of \($today)."
    })
')"

jq -n --argjson dep "$DEPRECATE" '{deprecate: $dep}' > "$OUT"

DEP_COUNT="$(jq '.deprecate | length' "$OUT")"
echo "==> Wrote $OUT — $DEP_COUNT tag(s) flagged for deprecation"
[[ "$DEP_COUNT" -gt 0 ]] && jq -r '.deprecate[] | "    - \(.tag): \(.reason)"' "$OUT"
exit 0
