#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC_SCRIPT="${ROOT_DIR}/scripts/sync-images.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

TEST_COUNT=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

create_fakes() {
  CASE_DIR="${TEST_ROOT}/${TEST_COUNT}"
  FAKE_BIN="${CASE_DIR}/bin"
  SKOPEO_LOG="${CASE_DIR}/skopeo.log"
  mkdir -p "${FAKE_BIN}"
  : > "${SKOPEO_LOG}"
  : > "${CASE_DIR}/images.yml"

  cat > "${FAKE_BIN}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$2" in
  '.images | length') echo 1 ;;
  '.images[0].name') echo nginx ;;
  '.images[0].source') echo nginx ;;
  '.images[0].tag[]?')
    if [[ "${MULTI_TAGS:-false}" == true ]]; then
      printf '1.30.5\nlatest\n'
    fi
    ;;
  '.images[0].tag') echo "${IMAGE_TAG}" ;;
  *) echo "unexpected yq query: $2" >&2; exit 1 ;;
esac
EOF

  cat > "${FAKE_BIN}/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${SKOPEO_LOG}"

case "$1" in
  inspect)
    image="${!#}"
    if [[ "${image}" == docker://ghcr.io/* ]]; then
      if [[ "${MULTI_TAG_STATE:-false}" == true ]]; then
        case "${image}" in
          *:1.30.5)
            echo 'sha256:existing'
            exit 0
            ;;
          *:latest)
            echo 'manifest unknown' >&2
            exit 1
            ;;
        esac
      fi

      case "${TARGET_STATE}" in
        exists)
          printf '%s\n' "${TARGET_DIGEST}"
          ;;
        missing)
          echo 'manifest unknown' >&2
          exit 1
          ;;
        error)
          echo 'unauthorized: authentication required' >&2
          exit 1
          ;;
        *)
          echo "unknown target state: ${TARGET_STATE}" >&2
          exit 1
          ;;
      esac
    else
      if [[ "${SOURCE_STATE:-exists}" == error ]]; then
        echo 'dial tcp: network is unreachable' >&2
        exit 1
      fi
      printf '%s\n' "${SOURCE_DIGEST}"
    fi
    ;;
  copy)
    ;;
  *)
    echo "unexpected skopeo command: $1" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${FAKE_BIN}/yq" "${FAKE_BIN}/skopeo"
}

run_sync() {
  set +e
  PATH="${FAKE_BIN}:${PATH}" \
    IMAGES_FILE="${CASE_DIR}/images.yml" \
    REGISTRY="ghcr.io" \
    OWNER="tellcts" \
    IMAGE_TAG="${IMAGE_TAG}" \
    MULTI_TAGS="${MULTI_TAGS:-false}" \
    MULTI_TAG_STATE="${MULTI_TAG_STATE:-false}" \
    TARGET_STATE="${TARGET_STATE}" \
    TARGET_DIGEST="${TARGET_DIGEST:-}" \
    SOURCE_STATE="${SOURCE_STATE:-exists}" \
    SOURCE_DIGEST="${SOURCE_DIGEST:-}" \
    SKOPEO_LOG="${SKOPEO_LOG}" \
    bash "${SYNC_SCRIPT}" >"${CASE_DIR}/stdout.log" 2>"${CASE_DIR}/stderr.log"
  EXIT_CODE=$?
  set -e
}

assert_exit_code() {
  local expected=$1
  [[ "${EXIT_CODE}" -eq "${expected}" ]] ||
    fail "expected exit ${expected}, got ${EXIT_CODE}: $(cat "${CASE_DIR}/stderr.log")"
}

assert_log_contains() {
  local expected=$1
  grep -Fq -- "${expected}" "${SKOPEO_LOG}" ||
    fail "expected skopeo log to contain: ${expected}"
}

assert_log_not_contains() {
  local unexpected=$1
  if grep -Fq -- "${unexpected}" "${SKOPEO_LOG}"; then
    fail "expected skopeo log not to contain: ${unexpected}"
  fi
}

assert_copy_count() {
  local expected=$1
  local actual
  actual=$(grep -Fc -- 'copy ' "${SKOPEO_LOG}" || true)
  [[ "${actual}" -eq "${expected}" ]] ||
    fail "expected ${expected} copy commands, got ${actual}"
}

test_fixed_tag_already_exists_is_skipped() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='1.30.5'
  TARGET_STATE='exists'
  TARGET_DIGEST='sha256:existing'
  run_sync

  assert_exit_code 0
  assert_log_contains 'inspect --override-os linux --override-arch amd64 --format {{.Digest}} docker://ghcr.io/tellcts/nginx:1.30.5'
  assert_log_not_contains 'copy'
}

test_fixed_tag_missing_is_copied_as_amd64() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='1.30.5'
  TARGET_STATE='missing'
  run_sync

  assert_exit_code 0
  assert_log_contains 'copy --preserve-digests --override-os linux --override-arch amd64 docker://nginx:1.30.5 docker://ghcr.io/tellcts/nginx:1.30.5'
}

test_latest_unchanged_is_skipped() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='latest'
  TARGET_STATE='exists'
  TARGET_DIGEST='sha256:same'
  SOURCE_DIGEST='sha256:same'
  run_sync

  assert_exit_code 0
  assert_log_contains 'docker://nginx:latest'
  assert_log_contains 'inspect --override-os linux --override-arch amd64 --format {{.Digest}} docker://nginx:latest'
  assert_log_not_contains 'copy'
}

test_latest_changed_is_copied_as_amd64() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='latest'
  TARGET_STATE='exists'
  TARGET_DIGEST='sha256:old'
  SOURCE_DIGEST='sha256:new'
  run_sync

  assert_exit_code 0
  assert_log_contains 'copy --preserve-digests --override-os linux --override-arch amd64 docker://nginx:latest docker://ghcr.io/tellcts/nginx:latest'
}

test_target_lookup_error_fails_without_copy() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='1.30.5'
  TARGET_STATE='error'
  run_sync

  assert_exit_code 2
  assert_log_not_contains 'copy'
}

test_source_lookup_error_for_latest_fails_without_copy() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='latest'
  TARGET_STATE='missing'
  SOURCE_STATE='error'
  run_sync

  assert_exit_code 1
  assert_log_not_contains 'copy'
}

test_multiple_tags_are_processed_independently() {
  TEST_COUNT=$((TEST_COUNT + 1))
  create_fakes

  IMAGE_TAG='1.30.5'
  MULTI_TAGS='true'
  MULTI_TAG_STATE='true'
  TARGET_STATE='exists'
  SOURCE_STATE='exists'
  SOURCE_DIGEST='sha256:latest'
  run_sync

  assert_exit_code 0
  assert_copy_count 1
  assert_log_contains 'docker://ghcr.io/tellcts/nginx:1.30.5'
  assert_log_contains 'copy --preserve-digests --override-os linux --override-arch amd64 docker://nginx:latest docker://ghcr.io/tellcts/nginx:latest'
  assert_log_not_contains 'copy --preserve-digests --override-os linux --override-arch amd64 docker://nginx:1.30.5'
}

test_fixed_tag_already_exists_is_skipped
test_fixed_tag_missing_is_copied_as_amd64
test_latest_unchanged_is_skipped
test_latest_changed_is_copied_as_amd64
test_target_lookup_error_fails_without_copy
test_source_lookup_error_for_latest_fails_without_copy
test_multiple_tags_are_processed_independently

printf 'PASS: %d sync-image tests\n' "${TEST_COUNT}"
