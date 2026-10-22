#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${OWNER:?OWNER is required}"

IMAGES_FILE="${IMAGES_FILE:-images.yml}"
ERROR_FILE=$(mktemp)
trap 'rm -f "${ERROR_FILE}"' EXIT

if [[ ! -f "${IMAGES_FILE}" ]]; then
  echo "images config not found: ${IMAGES_FILE}" >&2
  exit 1
fi

count=$(yq -r '.images | length' "${IMAGES_FILE}")
if [[ "${count}" -eq 0 ]]; then
  echo "No images configured"
  exit 0
fi

inspect_digest() {
  local image_ref=$1

  skopeo inspect \
    --override-os linux \
    --override-arch amd64 \
    --format '{{.Digest}}' \
    "docker://${image_ref}"
}

inspect_target() {
  local target_ref=$1

  if dig=$(inspect_digest "${target_ref}" 2>"${ERROR_FILE}"); then
    printf '%s\n' "${dig}"
    return 0
  fi

  if grep -Eiq \
    'manifest unknown|name unknown|not found|404 Not Found|StatusCode: 404' \
    "${ERROR_FILE}"; then
    return 1
  fi

  cat "${ERROR_FILE}" >&2
  return 2
}

copy_image() {
  local source_ref=$1
  local target_ref=$2

  echo "Copying linux/amd64: ${source_ref} -> ${target_ref}"
  skopeo copy \
    --preserve-digests \
    --override-os linux \
    --override-arch amd64 \
    "docker://${source_ref}" \
    "docker://${target_ref}"
}

for ((i = 0; i < count; i++)); do
  name=$(yq -r ".images[${i}].name" "${IMAGES_FILE}")
  source=$(yq -r ".images[${i}].source" "${IMAGES_FILE}")

  if [[ -z "${name}" || "${name}" == "null" ||
        -z "${source}" || "${source}" == "null" ]]; then
    echo "Invalid image entry at index ${i}" >&2
    exit 1
  fi

  tags=()
  mapfile -t tags < <(yq -r ".images[${i}].tag[]?" "${IMAGES_FILE}")
  if [[ "${#tags[@]}" -eq 0 ]]; then
    tags=("$(yq -r ".images[${i}].tag" "${IMAGES_FILE}")")
  fi

  for tag in "${tags[@]}"; do
    if [[ -z "${tag}" || "${tag}" == "null" ]]; then
      echo "Invalid tag for image at index ${i}" >&2
      exit 1
    fi

    source_ref="${source}:${tag}"
    target_ref="${REGISTRY}/${OWNER}/${name}:${tag}"

    echo "=============================="
    echo "Checking ${source_ref}"
    echo "Target: ${target_ref}"
    echo "=============================="

    source_digest=""
    if [[ "${tag}" == "latest" ]]; then
      if ! source_digest=$(inspect_digest "${source_ref}"); then
        echo "Unable to inspect source image: ${source_ref}" >&2
        exit 1
      fi

      if [[ -z "${source_digest}" ]]; then
        echo "Source image has no digest: ${source_ref}" >&2
        exit 1
      fi
    fi

    if target_digest=$(inspect_target "${target_ref}"); then
      if [[ "${tag}" != "latest" ]]; then
        echo "Skip ${tag}; image already exists"
        continue
      fi

      if [[ "${source_digest}" == "${target_digest}" ]]; then
        echo "Skip latest; digest unchanged (${source_digest})"
        continue
      fi

      echo "latest changed: ${target_digest} -> ${source_digest}"
      copy_image "${source_ref}" "${target_ref}"
      continue
    else
      inspect_status=$?
      if [[ "${inspect_status}" -ne 1 ]]; then
        exit "${inspect_status}"
      fi
    fi

    echo "Target tag does not exist"
    copy_image "${source_ref}" "${target_ref}"
  done
done

echo "Image synchronization completed"
