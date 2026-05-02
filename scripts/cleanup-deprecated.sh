#!/usr/bin/env bash
# Hard-delete deprecated image tags that have been marked for more than
# RETENTION_DAYS (default 90). Reads the deprecation date from the
# org.bitsnbites.deprecated.at label on each manifest.
#
# Inputs (env):
#   IMAGE_NAME             required (e.g. "playwright")
#   GHCR_OWNER             default "bitsnbites"
#   GITHUB_TOKEN           required for GHCR (delete:packages)
#   DOCKERHUB_NAMESPACE    default "bitsnbites"
#   DOCKERHUB_TOKEN        required for Docker Hub deletes
#   RETENTION_DAYS         default 90
#   DRY_RUN                if "true", logs but does not delete
#
# Output: prints a summary + writes .cleaned.json

set -euo pipefail

: "${IMAGE_NAME:?required}"
OWNER="${GHCR_OWNER:-bitsnbites}"
IMAGE="${IMAGE_NAME}"
HUB_NS="${DOCKERHUB_NAMESPACE:-bitsnbites}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
DRY_RUN="${DRY_RUN:-false}"
OUT="${OUT:-.cleaned.json}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dep: $1" >&2; exit 2; }; }
need curl
need jq
need docker

# Cutoff date in YYYY-MM-DD (UTC). Anything deprecated on or before this
# date gets deleted.
CUTOFF="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%d)"

echo "==> Cleanup retention: ${RETENTION_DAYS} days (cutoff=${CUTOFF})"
echo "==> Dry run: ${DRY_RUN}"

DELETED='[]'

# ----- GHCR ---------------------------------------------------------------
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "    GHCR: no GITHUB_TOKEN — skipping" >&2
else
  echo "==> Scanning GHCR (${OWNER}/${IMAGE})"
  page=1
  while :; do
    versions="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/users/${OWNER}/packages/container/${IMAGE}/versions?per_page=100&page=${page}" \
      || echo '[]')"
    count="$(jq 'length' <<<"$versions")"
    [[ "$count" -eq 0 ]] && break

    while IFS= read -r row; do
      version_id="$(jq -r '.id' <<<"$row")"
      tags="$(jq -r '.metadata.container.tags[]?' <<<"$row")"
      [[ -z "$tags" ]] && continue

      # Skip if none of the tags suggests deprecation (cheap pre-filter).
      if ! grep -q -- '-deprecated' <<<"$tags"; then
        continue
      fi

      # Pick a representative tag and read the deprecated.at label off the
      # manifest. If the label is missing or unparseable, skip (don't risk
      # deleting an image that wasn't formally deprecated).
      rep_tag="$(grep -- '-deprecated' <<<"$tags" | head -n1)"
      ref="ghcr.io/${OWNER}/${IMAGE}:${rep_tag}"

      manifest="$(docker buildx imagetools inspect "$ref" --raw 2>/dev/null || echo '{}')"
      dep_at="$(jq -r '
        (.annotations // {})["org.bitsnbites.deprecated.at"]
        // (.manifests[0].annotations // {})["org.bitsnbites.deprecated.at"]
        // ""
      ' <<<"$manifest")"

      if [[ -z "$dep_at" || "$dep_at" == "null" ]]; then
        echo "    ${ref}: no deprecated.at label — skipping" >&2
        continue
      fi

      if [[ "$dep_at" > "$CUTOFF" ]]; then
        echo "    ${ref}: deprecated ${dep_at} (within retention) — skipping"
        continue
      fi

      echo "    ${ref}: deprecated ${dep_at} — DELETING (cutoff ${CUTOFF})"
      if [[ "$DRY_RUN" != "true" ]]; then
        curl -fsSL -X DELETE \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/users/${OWNER}/packages/container/${IMAGE}/versions/${version_id}" \
          >/dev/null \
          || echo "    !! GHCR delete failed for version ${version_id}" >&2
      fi
      DELETED="$(jq --arg ref "$ref" --arg at "$dep_at" \
        '. + [{registry:"ghcr.io",ref:$ref,deprecated_at:$at}]' <<<"$DELETED")"
    done < <(jq -c '.[]' <<<"$versions")

    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
fi

# ----- Docker Hub --------------------------------------------------------
if [[ -z "${DOCKERHUB_TOKEN:-}" ]]; then
  echo "    Docker Hub: no DOCKERHUB_TOKEN — skipping" >&2
else
  echo "==> Scanning Docker Hub (${HUB_NS}/${IMAGE})"
  url="https://hub.docker.com/v2/repositories/${HUB_NS}/${IMAGE}/tags/?page_size=100"
  while [[ -n "$url" && "$url" != "null" ]]; do
    resp="$(curl -fsSL "$url" || echo '{}')"
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      [[ "$tag" != *-deprecated ]] && continue

      ref="docker.io/${HUB_NS}/${IMAGE}:${tag}"
      manifest="$(docker buildx imagetools inspect "$ref" --raw 2>/dev/null || echo '{}')"
      dep_at="$(jq -r '
        (.annotations // {})["org.bitsnbites.deprecated.at"]
        // (.manifests[0].annotations // {})["org.bitsnbites.deprecated.at"]
        // ""
      ' <<<"$manifest")"

      if [[ -z "$dep_at" || "$dep_at" == "null" ]]; then
        echo "    ${ref}: no deprecated.at label — skipping" >&2
        continue
      fi

      if [[ "$dep_at" > "$CUTOFF" ]]; then
        echo "    ${ref}: deprecated ${dep_at} (within retention) — skipping"
        continue
      fi

      echo "    ${ref}: deprecated ${dep_at} — DELETING (cutoff ${CUTOFF})"
      if [[ "$DRY_RUN" != "true" ]]; then
        curl -fsSL -X DELETE \
          -H "Authorization: JWT ${DOCKERHUB_TOKEN}" \
          "https://hub.docker.com/v2/repositories/${HUB_NS}/${IMAGE}/tags/${tag}/" \
          >/dev/null \
          || echo "    !! Docker Hub delete failed for ${tag}" >&2
      fi
      DELETED="$(jq --arg ref "$ref" --arg at "$dep_at" \
        '. + [{registry:"docker.io",ref:$ref,deprecated_at:$at}]' <<<"$DELETED")"
    done < <(jq -r '.results[]?.name' <<<"$resp")
    url="$(jq -r '.next // empty' <<<"$resp")"
  done
fi

jq -n --argjson deleted "$DELETED" --arg cutoff "$CUTOFF" --arg dry "$DRY_RUN" \
  '{cutoff:$cutoff, dry_run:($dry == "true"), deleted:$deleted}' > "$OUT"

DEL_COUNT="$(jq '.deleted | length' "$OUT")"
echo "==> Wrote $OUT — ${DEL_COUNT} tag(s) processed for deletion"
