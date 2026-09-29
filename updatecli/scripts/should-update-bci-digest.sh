#!/usr/bin/env bash

set -euo pipefail

# Evaluate a single image and allow the update only when the candidate has
# fewer HIGH/CRITICAL OS CVEs than the current pin.
#
# Arguments:
#   <current-image-ref> <candidate-image-ref> <default-tag>
#
# Returns exit code 0 (update allowed) when:
#   1) the current image has at least one HIGH/CRITICAL OS CVE, and
#   2) the candidate image has fewer HIGH/CRITICAL OS CVEs than current.
# Otherwise returns exit code 1 (update blocked).

if (( $# != 3 )); then
  echo "usage: $0 <current-ref> <candidate-ref> <default-tag>" >&2
  exit 2
fi

current_ref="$1"
candidate_ref="$2"
default_tag="$3"

infer_image_name_from_ref() {
  local ref ref_without_digest tail
  ref="$1"

  # Drop digest part first (if any), then strip tag from the last path element.
  ref_without_digest="${ref%@*}"
  tail="${ref_without_digest##*/}"
  if [[ "${tail}" == *:* ]]; then
    echo "${ref_without_digest%:*}"
    return 0
  fi

  echo "${ref_without_digest}"
}

normalize_ref() {
  local ref default_tag default_image
  ref="$1"
  default_tag="$2"
  default_image="$3"

  # If the value is only a digest, prepend image name.
  if [[ "${ref}" =~ ^sha256: ]]; then
    if [[ -z "${default_image}" ]]; then
      echo "cannot normalize digest-only reference without image name" >&2
      exit 2
    fi
    echo "${default_image}@${ref}"
    return 0
  fi

  # Already a digest reference.
  if [[ "${ref}" == *@sha256:* ]]; then
    echo "${ref}"
    return 0
  fi

  # Tag reference: detect ':' after the last '/'.
  local tail
  tail="${ref##*/}"
  if [[ "${tail}" == *:* ]]; then
    echo "${ref}"
    return 0
  fi

  # Bare image name fallback.
  if [[ -n "${default_tag}" ]]; then
    echo "${ref}:${default_tag}"
    return 0
  fi

  echo "${ref}"
}

count_high_critical_os_vulns() {
  local image_ref output_file
  image_ref="$1"
  output_file="$2"

  trivy image \
    --quiet \
    --format json \
    --output "${output_file}" \
    --severity HIGH,CRITICAL \
    --vuln-type os \
    --ignore-unfixed=false \
    --exit-code 0 \
    "${image_ref}" >/dev/null

  jq '[.Results[]? | select(.Class == "os-pkgs") | .Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length' "${output_file}"
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

default_image="$(infer_image_name_from_ref "${candidate_ref}")"
current_ref="$(normalize_ref "${current_ref}" "${default_tag}" "${default_image}")"
candidate_ref="$(normalize_ref "${candidate_ref}" "${default_tag}" "${default_image}")"

current_json="${workdir}/current.json"
candidate_json="${workdir}/candidate.json"

current_count="$(count_high_critical_os_vulns "${current_ref}" "${current_json}")"
candidate_count="$(count_high_critical_os_vulns "${candidate_ref}" "${candidate_json}")"

echo "current:   ${current_ref} (HIGH/CRITICAL OS CVEs: ${current_count})"
echo "candidate: ${candidate_ref} (HIGH/CRITICAL OS CVEs: ${candidate_count})"

if (( current_count > 0 && candidate_count < current_count )); then
  echo "Decision: update allowed (candidate runtime image is safer)."
  exit 0
fi

echo "Decision: update blocked (no security improvement)."
exit 1
