#!/usr/bin/env bash
# Show both isolated stacks. Re-runnable. Cannot-run is a failure.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILED=0
note_fail() {
  FAILED=1
  printf '%sFAIL%s %s\n' "${_c_red}" "${_c_off}" "$*"
}

assert_tcp_probe_available

stack_status() {
  local name="$1"
  shift
  log "== ${name}"
  if ! command -v docker >/dev/null 2>&1; then
    note_fail "docker is not on PATH; cannot read compose project ${name}"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    note_fail "docker daemon is not reachable; cannot read compose project ${name}"
    return 0
  fi
  if "$@"; then
    ok "${name} compose ps ok"
  else
    note_fail "${name} compose ps failed"
  fi
}

if [[ -f "${RAGFLOW_DIR}/.env" ]]; then
  stack_status "ragflow" ragflow_compose ps
else
  note_fail "stacks/ragflow/.env missing (make init-env)"
fi

if [[ -f "${KHOJ_DIR}/.env" ]]; then
  stack_status "khoj" khoj_compose ps
else
  note_fail "stacks/khoj/.env missing (make init-env)"
fi

log "== TCP probes"
probe_row() {
  local stack="$1" port="$2"
  if tcp_port_open "${port}"; then
    if command -v docker >/dev/null 2>&1 && project_owns_port "${stack}" "${port}"; then
      ok "127.0.0.1:${port} open (${stack})"
    else
      warn "127.0.0.1:${port} open (not proven as ${stack})"
    fi
  else
    warn "127.0.0.1:${port} closed (${stack} web/API not reachable)"
  fi
}

while IFS= read -r port; do
  [[ -n "${port}" ]] && probe_row "${RAGFLOW_PROJECT}" "${port}"
done < <(ragflow_host_ports)
while IFS= read -r port; do
  [[ -n "${port}" ]] && probe_row "${KHOJ_PROJECT}" "${port}"
done < <(khoj_host_ports)

log "== isolation"
ok "compose projects: ${RAGFLOW_PROJECT} / ${KHOJ_PROJECT}"
ok "networks: ${RAGFLOW_NETWORK} / ${KHOJ_NETWORK}"

if (( FAILED != 0 )); then
  die "status failed (docker/env checks could not run or compose ps errored)"
fi
ok "status complete"
