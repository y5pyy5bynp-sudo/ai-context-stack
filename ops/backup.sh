#!/usr/bin/env bash
# Snapshot both stacks. Re-runnable: each run writes a new backups/<utc>/ dir.
# Volume archives are real tar.gz files. If docker cannot run, this fails.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SELF_TEST=0
if [[ "${1:-}" == "--self-test" ]]; then
  SELF_TEST=1
fi

backup_bind_dir() {
  local src="$1" dest_tar="$2" label="$3"
  if [[ ! -d "${src}" ]]; then
    warn "bind dir ${src} absent (${label}); recorded as missing"
    printf 'missing\n' > "${dest_tar}.missing"
    return 0
  fi
  archive_dir "${src}" "${dest_tar}"
  ok "archived bind ${label} -> ${dest_tar}"
}

backup_docker_volume() {
  local vol="$1" dest_tar="$2"
  require_cmd docker
  local inspect rc=0
  set +e
  inspect="$(docker volume inspect "${vol}" --format '{{.Name}}' 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    warn "volume ${vol} does not exist yet; recorded as missing"
    printf '%s\n' "${inspect}" > "${dest_tar}.missing"
    return 0
  fi
  mkdir -p "$(dirname "${dest_tar}")"
  # alpine is small and always has tar. Failure here is a real backup failure.
  if ! docker run --rm \
      -v "${vol}:/volume:ro" \
      -v "$(dirname "${dest_tar}"):/backup" \
      alpine:3.20 \
      tar -C /volume -czf "/backup/$(basename "${dest_tar}")" .; then
    die "docker volume archive failed for ${vol}"
  fi
  ok "archived volume ${vol}"
}

write_manifest() {
  local dest="$1"
  {
    printf 'timestamp=%s\n' "$(utc_stamp)"
    printf 'hostname=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'ragflow_project=%s\n' "${RAGFLOW_PROJECT}"
    printf 'khoj_project=%s\n' "${KHOJ_PROJECT}"
    printf 'ragflow_network=%s\n' "${RAGFLOW_NETWORK}"
    printf 'khoj_network=%s\n' "${KHOJ_NETWORK}"
    printf 'ragflow_image=%s\n' "${RAGFLOW_IMAGE_PIN}"
    printf 'ragflow_web_port=%s\n' "${RAGFLOW_WEB_PORT_PIN}"
    printf 'khoj_web_port=%s\n' "${KHOJ_WEB_PORT_PIN}"
    printf 'self_test=%s\n' "${SELF_TEST}"
  } > "${dest}/MANIFEST"
}

if (( SELF_TEST == 1 )); then
  require_cmd tar
  work="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-backup-selftest.XXXXXX")"
  src="${work}/src"
  out="${work}/out"
  mkdir -p "${src}/nested" "${out}"
  printf 'payload-%s\n' "$$" > "${src}/nested/hello.txt"
  archive_dir "${src}" "${out}/demo.tar.gz"
  restored="${work}/restored"
  extract_dir "${restored}" "${out}/demo.tar.gz"
  if ! diff -qr "${src}" "${restored}" >/dev/null; then
    die "self-test archive/restore mismatch in ${work}"
  fi
  write_manifest "${out}"
  ok "backup --self-test passed (${work})"
  rm -rf "${work}"
  exit 0
fi

if [[ ! -f "${RAGFLOW_DIR}/.env" || ! -f "${KHOJ_DIR}/.env" ]]; then
  die "both stack .env files are required; run make init-env"
fi

require_cmd docker
if ! docker info >/dev/null 2>&1; then
  die "docker daemon is not reachable; volume backup cannot run"
fi

stamp="$(utc_stamp)"
dest="${BACKUP_ROOT}/${stamp}"
mkdir -p "${dest}/ragflow/volumes" "${dest}/khoj/volumes"
write_manifest "${dest}"

install -m 600 "${RAGFLOW_DIR}/.env" "${dest}/ragflow.env"
install -m 600 "${KHOJ_DIR}/.env" "${dest}/khoj.env"
ok "copied stack .env files"

backup_bind_dir "${RAGFLOW_DIR}/ragflow-logs" "${dest}/ragflow/ragflow-logs.tar.gz" "ragflow-logs"

while IFS= read -r vol; do
  [[ -n "${vol}" ]] || continue
  backup_docker_volume "${vol}" "${dest}/ragflow/volumes/${vol}.tar.gz"
done < <(ragflow_volume_names)

while IFS= read -r vol; do
  [[ -n "${vol}" ]] || continue
  backup_docker_volume "${vol}" "${dest}/khoj/volumes/${vol}.tar.gz"
done < <(khoj_volume_names)

# Point "latest" at this snapshot without deleting older ones.
ln -sfn "${stamp}" "${BACKUP_ROOT}/latest"
ok "backup written to ${dest}"
printf '%s\n' "${dest}"
