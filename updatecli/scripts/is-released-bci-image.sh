#!/usr/bin/env bash

set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <image-reference>" >&2
  exit 2
fi

image_ref="$1"
release_stage="$(docker buildx imagetools inspect --format '{{index (index .Image "linux/amd64").Config.Labels "com.suse.release-stage"}}' "${image_ref}")"

echo "${image_ref}: com.suse.release-stage=${release_stage}"

if [[ "${release_stage}" != "released" ]]; then
  echo "Decision: update blocked (candidate is not a released BCI image)." >&2
  exit 1
fi

echo "Decision: update allowed (candidate is a released BCI image)."