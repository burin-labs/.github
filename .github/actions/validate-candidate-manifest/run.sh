#!/usr/bin/env bash
# Dispatch the manifest validator inside Harn's sandbox, reading only the
# validator and the manifest's own directory.
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
manifest="${CANDIDATE_MANIFEST:?the manifest input is required}"
if [[ ! -f "$manifest" ]]; then
  echo "::error::candidate manifest $manifest does not exist" >&2
  exit 1
fi
CANDIDATE_MANIFEST="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"
export CANDIDATE_MANIFEST
# Harn refuses a grant whose variable is unset; an omitted expectation is empty.
export CANDIDATE_REPOSITORY="${CANDIDATE_REPOSITORY:-}"
export CANDIDATE_SOURCE_COMMIT="${CANDIDATE_SOURCE_COMMIT:-}"
export CANDIDATE_RUN_ID="${CANDIDATE_RUN_ID:-}"

harn run \
  --standalone \
  --grant manifest=env:CANDIDATE_MANIFEST,expose=CANDIDATE_MANIFEST \
  --grant repository=env:CANDIDATE_REPOSITORY,expose=CANDIDATE_REPOSITORY \
  --grant source_commit=env:CANDIDATE_SOURCE_COMMIT,expose=CANDIDATE_SOURCE_COMMIT \
  --grant run_id=env:CANDIDATE_RUN_ID,expose=CANDIDATE_RUN_ID \
  --read-only-root "$package_root" \
  --read-only-root "$(dirname "$CANDIDATE_MANIFEST")" \
  "$package_root/scripts/release-promotion/validate.harn"
