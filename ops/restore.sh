#!/usr/bin/env bash
# Restore a backups/<utc> snapshot. Destructive: current state is backed up first.
# Re-runnable: a second restore of the same snapshot is a no-op after replace.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SELF_TEST=0
SRC=""
if [[ "${1:-}" == "--self-test" ]]; then
  SELF_TEST=1
elif [[ $# -ge 1 ]]; then
  SRC="$1"
else
  die "usage: restore.sh backups/<utc>   or   restore.sh --self-test"
fi

restore_docker_volume() {
  local vol="$1" tar="$2"
  require_cmd docker
  if [[ -f "${tar}.missing" && ! -f "${tar}" ]]; then
    warn "snapshot has no data for ${vol} (was missing); leave volume untouched"
    return 0
  fi
  if [[ ! -f "${tar}" ]]; then
    die "snapshot is missing ${tar}"
  fi
  docker volume create "${vol}" >/dev/null
  if ! docker run --rm \
      -v "${vol}:/volume" \
      -v "$(dirname "${tar}"):/backup" \
      alpine:3.20 \
      sh -c 'find /volume -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -C /volume -xzf "/backup/'"$(basename "${tar}")"'"'; then
    die "docker volume restore failed for ${vol}"
  fi
  ok "restored volume ${vol}"
}

if (( SELF_TEST == 1 )); then
  require_cmd tar
  work="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-restore-selftest.XXXXXX")"
  live="${work}/live"
  snap="${work}/snap"
  mkdir -p "${live}" "${snap}"
  printf 'old\n' > "${live}/state.txt"
  printf 'new\n' > "${work}/incoming.txt"
  # Safety backup of "current" then replace — same contract as production restore.
  archive_dir "${live}" "${work}/pre-restore.tar.gz"
  mkdir -p "${work}/incoming_dir"
  printf 'new\n' > "${work}/incoming_dir/state.txt"
  archive_dir "${work}/incoming_dir" "${snap}/state.tar.gz"
  extract_dir "${live}" "${work}/pre-restore.tar.gz"
  if [[ "$(cat "${live}/state.txt")" != "old" ]]; then
    die "self-test pre-restore backup did not preserve current state"
  fi
  extract_dir "${live}" "${snap}/state.tar.gz"
  if [[ "$(cat "${live}/state.txt")" != "new" ]]; then
    die "self-test restore did not replace current state"
  fi
  ok "restore --self-test passed (${work})"
  rm -rf "${work}"
  exit 0
fi

if [[ ! -d "${SRC}" ]]; then
  die "backup dir not found: ${SRC}"
fi
if [[ ! -f "${SRC}/MANIFEST" ]]; then
  die "backup is missing MANIFEST: ${SRC}"
fi
if [[ ! -f "${SRC}/ragflow.env" || ! -f "${SRC}/khoj.env" ]]; then
  die "backup is missing stack .env files"
fi

require_cmd docker
if ! docker info >/dev/null 2>&1; then
  die "docker daemon is not reachable; volume restore cannot run"
fi

log "taking a safety backup of current state before restore"
"${OPS_DIR}/backup.sh"
safety="$(readlink -f "${BACKUP_ROOT}/latest")"
ok "pre-restore backup: ${safety}"

if [[ -f "${RAGFLOW_DIR}/.env" ]]; then
  ragflow_compose stop || warn "ragflow stop failed (continuing restore)"
fi
if [[ -f "${KHOJ_DIR}/.env" ]]; then
  khoj_compose stop || warn "khoj stop failed (continuing restore)"
fi

install -m 600 "${SRC}/ragflow.env" "${RAGFLOW_DIR}/.env"
install -m 600 "${SRC}/khoj.env" "${KHOJ_DIR}/.env"
ok "restored stack .env files"

if [[ -f "${SRC}/ragflow/ragflow-logs.tar.gz" ]]; then
  extract_dir "${RAGFLOW_DIR}/ragflow-logs" "${SRC}/ragflow/ragflow-logs.tar.gz"
  ok "restored ragflow-logs"
fi

while IFS= read -r vol; do
  [[ -n "${vol}" ]] || continue
  restore_docker_volume "${vol}" "${SRC}/ragflow/volumes/${vol}.tar.gz"
done < <(ragflow_volume_names)

while IFS= read -r vol; do
  [[ -n "${vol}" ]] || continue
  restore_docker_volume "${vol}" "${SRC}/khoj/volumes/${vol}.tar.gz"
done < <(khoj_volume_names)

ok "restore from ${SRC} complete"
ok "start stacks with: make up"
