#!/usr/bin/env bash
# Shared helpers for the RAGFlow + Khoj dual-stack ops scripts.
# Every check that cannot actually run must fail (never "skip" as success).

set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${OPS_DIR}/.." && pwd)"

RAGFLOW_DIR="${ROOT}/stacks/ragflow"
KHOJ_DIR="${ROOT}/stacks/khoj"
BACKUP_ROOT="${ROOT}/backups"

RAGFLOW_PROJECT="ragflow"
KHOJ_PROJECT="khoj"
RAGFLOW_NETWORK="ragflow_isolated"
KHOJ_NETWORK="khoj_isolated"

RAGFLOW_IMAGE_PIN="infiniflow/ragflow:v0.27.1"
RAGFLOW_WEB_PORT_PIN="8081"
KHOJ_WEB_PORT_PIN="42110"
ES_MIN_MAP_COUNT="262144"
# 4 GiB in bytes — required on ~16 GiB hosts so both stacks can coexist.
MEM_LIMIT_16G="4294967296"
# Treat hosts at or below this many KiB as "16 GB class".
MEM_16G_CLASS_MAX_KB="17825792"

if [[ -t 1 ]]; then
  _c_red=$'\033[31m'
  _c_grn=$'\033[32m'
  _c_yel=$'\033[33m'
  _c_dim=$'\033[2m'
  _c_off=$'\033[0m'
else
  _c_red="" _c_grn="" _c_yel="" _c_dim="" _c_off=""
fi

log()  { printf '%s\n' "$*"; }
ok()   { printf '%sOK%s  %s\n' "${_c_grn}" "${_c_off}" "$*"; }
warn() { printf '%sWARN%s %s\n' "${_c_yel}" "${_c_off}" "$*" >&2; }
fail() {
  printf '%sFAIL%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2
  return 1
}
die() {
  printf '%sFAIL%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2
  exit 1
}

require_cmd() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    die "required command '${name}' is not on PATH; refusing to continue"
  fi
}

# Read KEY=value from an env file without sourcing it (avoids executing values).
env_get() {
  local file="$1" key="$2"
  if [[ ! -r "${file}" ]]; then
    die "cannot read env file: ${file}"
  fi
  local line
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    return 1
  fi
  printf '%s\n' "${line#*=}"
}

env_get_or() {
  local file="$1" key="$2" default="$3"
  local val=""
  if [[ -r "${file}" ]]; then
    val="$(env_get "${file}" "${key}" || true)"
  fi
  if [[ -z "${val}" ]]; then
    printf '%s\n' "${default}"
  else
    printf '%s\n' "${val}"
  fi
}

# Confirm bash /dev/tcp is compiled in. Do not fall back to ss/netstat.
assert_tcp_probe_available() {
  require_cmd bash
  require_cmd timeout
  local err rc=0
  set +e
  err="$(bash -c 'true >/dev/tcp/127.0.0.1/9' 2>&1)"
  rc=$?
  set -e
  if [[ "${err}" == *"No such file or directory"* ]]; then
    die "bash /dev/tcp is unavailable; port checks cannot run (will not parse ss/netstat)"
  fi
  # Connection refused (rc != 0) is expected on a closed port and proves the probe works.
  if [[ "${rc}" -eq 124 ]]; then
    die "bash /dev/tcp probe timed out while verifying itself; refusing to treat ports as free"
  fi
}

# 0 = something accepted the TCP connection (port in use)
# 1 = connection refused / closed (port free)
# any probe failure -> die
tcp_port_open() {
  local port="$1"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    die "invalid port for TCP probe: ${port}"
  fi
  local err rc=0
  set +e
  err="$(timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>&1)"
  rc=$?
  set -e
  if [[ "${err}" == *"No such file or directory"* ]]; then
    die "bash /dev/tcp disappeared mid-run; cannot probe port ${port}"
  fi
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${rc}" -eq 124 ]]; then
    die "TCP probe to 127.0.0.1:${port} timed out; refusing to treat the port as free"
  fi
  return 1
}

host_mem_kb() {
  if [[ ! -r /proc/meminfo ]]; then
    die "cannot read /proc/meminfo; memory check cannot run"
  fi
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo || true)"
  if [[ -z "${kb}" || ! "${kb}" =~ ^[0-9]+$ ]]; then
    die "failed to parse MemTotal from /proc/meminfo"
  fi
  printf '%s\n' "${kb}"
}

is_16g_class_host() {
  local kb
  kb="$(host_mem_kb)"
  (( kb <= MEM_16G_CLASS_MAX_KB ))
}

compose() {
  local dir="$1"
  shift
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose (v2) is not available; refusing to continue"
  fi
  docker compose --project-directory "${dir}" "$@"
}

ragflow_compose() {
  local env_file="${RAGFLOW_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    die "missing ${env_file}; run: make init-env"
  fi
  compose "${RAGFLOW_DIR}" --env-file "${env_file}" --project-name "${RAGFLOW_PROJECT}" "$@"
}

khoj_compose() {
  local env_file="${KHOJ_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    die "missing ${env_file}; run: make init-env"
  fi
  compose "${KHOJ_DIR}" --env-file "${env_file}" --project-name "${KHOJ_PROJECT}" "$@"
}

# Host ports this pack publishes. Values come from each stack .env when present.
ragflow_host_ports() {
  local env="${RAGFLOW_DIR}/.env"
  local web https api admin mcp go_http go_admin es mysql redis minio minio_console
  web="$(env_get_or "${env}" SVR_WEB_HTTP_PORT "${RAGFLOW_WEB_PORT_PIN}")"
  https="$(env_get_or "${env}" SVR_WEB_HTTPS_PORT "8443")"
  api="$(env_get_or "${env}" SVR_HTTP_PORT "9380")"
  admin="$(env_get_or "${env}" ADMIN_SVR_HTTP_PORT "9381")"
  mcp="$(env_get_or "${env}" SVR_MCP_PORT "9382")"
  go_http="$(env_get_or "${env}" GO_HTTP_PORT "9384")"
  go_admin="$(env_get_or "${env}" GO_ADMIN_PORT "9383")"
  es="$(env_get_or "${env}" ES_PORT "1200")"
  mysql="$(env_get_or "${env}" EXPOSE_MYSQL_PORT "3306")"
  redis="$(env_get_or "${env}" REDIS_PORT "6379")"
  minio="$(env_get_or "${env}" MINIO_PORT "9000")"
  minio_console="$(env_get_or "${env}" MINIO_CONSOLE_PORT "9001")"
  printf '%s\n' "${web}" "${https}" "${api}" "${admin}" "${mcp}" "${go_http}" "${go_admin}" \
    "${es}" "${mysql}" "${redis}" "${minio}" "${minio_console}"
}

khoj_host_ports() {
  local env="${KHOJ_DIR}/.env"
  local web
  web="$(env_get_or "${env}" KHOJ_HTTP_PORT "${KHOJ_WEB_PORT_PIN}")"
  printf '%s\n' "${web}"
}

# True if a running container from compose project $1 publishes host port $2.
project_owns_port() {
  local project="$1" port="$2"
  require_cmd docker
  local ids
  ids="$(docker ps --filter "label=com.docker.compose.project=${project}" -q 2>/dev/null || true)"
  if [[ -z "${ids}" ]]; then
    return 1
  fi
  local id bindings
  for id in ${ids}; do
    bindings="$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' "${id}" 2>/dev/null || true)"
    if [[ -z "${bindings}" ]]; then
      die "docker inspect failed or returned empty port bindings for ${id}; cannot decide who owns :${port}"
    fi
    local b
    for b in ${bindings}; do
      if [[ "${b}" == "${port}" ]]; then
        return 0
      fi
    done
  done
  return 1
}

utc_stamp() {
  date -u +%Y%m%dT%H%M%SZ
}
