#!/usr/bin/env bash
# Decide whether a particular image build needs to happen.
#
# Computes a deterministic "build hash" from the inputs that affect the
# output image:
#   - SHA256 of the Dockerfile
#   - All build args (sorted, key=value)
#   - Resolved digest of the base image (FROM line in the Dockerfile)
#
# If the manifest already in the registry for IMAGE_REF carries the same
# hash in the org.bitsnbites.build-hash annotation, the build is a no-op.
#
# Inputs (env):
#   IMAGE_REF       required, e.g. ghcr.io/bitsnbites/playwright:1.59-node24
#   BUILD_ARGS_JSON required, JSON object e.g. {"PLAYWRIGHT_VERSION":"1.59.1","NODE_MAJOR":"24"}
#   DOCKERFILE      default ./Dockerfile
#
# Output:
#   prints "build" or "skip" to stdout
#   writes build_hash=<hex> to $GITHUB_OUTPUT (if set)

set -euo pipefail

: "${IMAGE_REF:?required}"
: "${BUILD_ARGS_JSON:?required}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dep: $1" >&2; exit 2; }; }
need sha256sum
need docker
need jq

[[ -f "$DOCKERFILE" ]] || { echo "missing Dockerfile at $DOCKERFILE" >&2; exit 3; }

# Pull the FROM line out of the Dockerfile (last FROM, since multi-stage
# builds put the runtime stage last). Substitute build args if the FROM
# line uses them.
FROM_LINE="$(grep -iE '^[[:space:]]*FROM[[:space:]]' "$DOCKERFILE" | tail -n1 \
  | awk '{print $2}')"
while read -r key; do
  val="$(jq -r --arg k "$key" '.[$k]' <<<"$BUILD_ARGS_JSON")"
  FROM_LINE="${FROM_LINE//\$\{$key\}/$val}"
  FROM_LINE="${FROM_LINE//\$$key/$val}"
done < <(jq -r 'keys[]' <<<"$BUILD_ARGS_JSON")

echo "==> Resolving base image digest: $FROM_LINE" >&2
BASE_DIGEST="$(docker buildx imagetools inspect "$FROM_LINE" \
  --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // "unknown"' \
  || echo unknown)"

DOCKERFILE_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
ARGS_FLAT="$(jq -r 'to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join("|")' <<<"$BUILD_ARGS_JSON")"

BUILD_HASH="$(printf '%s|%s|%s' "$DOCKERFILE_SHA" "$ARGS_FLAT" "$BASE_DIGEST" \
  | sha256sum | awk '{print $1}')"

echo "    Dockerfile SHA       : $DOCKERFILE_SHA" >&2
echo "    Build args (sorted)  : $ARGS_FLAT" >&2
echo "    Base image digest    : $BASE_DIGEST" >&2
echo "    Build hash           : $BUILD_HASH" >&2

EXISTING_HASH=""
if EXISTING_JSON="$(docker buildx imagetools inspect "$IMAGE_REF" --raw 2>/dev/null)"; then
  EXISTING_HASH="$(jq -r '
    (.annotations // {})["org.bitsnbites.build-hash"]
    // (.manifests[0].annotations // {})["org.bitsnbites.build-hash"]
    // ""
  ' <<<"$EXISTING_JSON")"
fi
echo "    Previously published : ${EXISTING_HASH:-<none>}" >&2

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "build_hash=$BUILD_HASH" >> "$GITHUB_OUTPUT"
fi

if [[ -n "$EXISTING_HASH" && "$EXISTING_HASH" == "$BUILD_HASH" ]]; then
  echo "skip"
  exit 0
fi
echo "build"
