#!/usr/bin/env bash
# Host preflight for the RAGFlow + Khoj dual-stack.
# Re-runnable. A check that cannot execute is a failure, never a silent pass.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILED=0
note_fail() {
  FAILED=1
  printf '%sFAIL%s %s\n' "${_c_red}" "${_c_off}" "$*"
}

# ---------------------------------------------------------------------------
# 1. Docker / Compose — if we cannot talk to the engine, fail.
# ---------------------------------------------------------------------------
check_docker() {
  log "== docker"
  if ! command -v docker >/dev/null 2>&1; then
    note_fail "docker is not on PATH"
    return 0
  fi
  local info
  if ! info="$(docker info --format '{{.ServerVersion}}' 2>&1)"; then
    note_fail "docker info failed (daemon down or no permission): ${info}"
    return 0
  fi
  ok "docker engine ${info}"

  local ver
  if ! ver="$(docker compose version --short 2>&1)"; then
    note_fail "docker compose v2 is required: ${ver}"
    return 0
  fi
  # Official RAGFlow v0.27.1 asks for Compose >= 2.26.1
  local major minor patch
  IFS=. read -r major minor patch <<<"${ver%%-*}"
  if [[ -z "${major}" || -z "${minor}" || -z "${patch}" ]]; then
    note_fail "cannot parse docker compose version '${ver}'"
    return 0
  fi
  if (( major < 2 )) || { (( major == 2 && minor < 26 )); } || { (( major == 2 && minor == 26 && patch < 1 )); }; then
    note_fail "docker compose ${ver} < 2.26.1 (RAGFlow v0.27.1 requirement)"
    return 0
  fi
  ok "docker compose ${ver}"
}

# ---------------------------------------------------------------------------
# 2. bash /dev/tcp port probes — never parse ss/netstat.
# ---------------------------------------------------------------------------
read_forward_policy() {
  # Prints ACCEPT|DROP|... or returns non-zero if the binary cannot be queried.
  local bin="$1"
  if [[ ! -x "${bin}" ]] && ! command -v "${bin}" >/dev/null 2>&1; then
    return 2
  fi
  local out rc=0
  set +e
  out="$("${bin}" -S FORWARD 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    printf '%s\n' "${out}"
    return 1
  fi
  local pol
  pol="$(printf '%s\n' "${out}" | awk '/^-P FORWARD/ {print $3; exit}')"
  if [[ -z "${pol}" ]]; then
    printf '%s\n' "${out}"
    return 1
  fi
  printf '%s\n' "${pol}"
  return 0
}

check_iptables_forward() {
  log "== iptables FORWARD (nft vs legacy)"
  # Dual-backend hosts: nft FORWARD=ACCEPT + legacy FORWARD=DROP lets
  # containers show Up while app-to-db traffic inside the bridge times out.
  local nft="" legacy="" have_nft=0 have_legacy=0

  if command -v iptables-nft >/dev/null 2>&1; then
    have_nft=1
  fi
  if command -v iptables-legacy >/dev/null 2>&1; then
    have_legacy=1
  fi

  if (( have_nft == 0 && have_legacy == 0 )); then
    if command -v iptables >/dev/null 2>&1; then
      local pol out rc=0
      set +e
      out="$(read_forward_policy iptables)"
      rc=$?
      set -e
      if [[ "${rc}" -ne 0 ]]; then
        note_fail "iptables exists but FORWARD policy cannot be read: ${out}"
        return 0
      fi
      pol="${out}"
      if [[ "${pol}" == "DROP" ]]; then
        note_fail "iptables FORWARD policy is DROP; Docker bridge traffic will black-hole. Set ACCEPT on the backend Docker actually uses."
        return 0
      fi
      ok "iptables FORWARD=${pol} (single backend)"
      return 0
    fi
    note_fail "neither iptables-nft, iptables-legacy, nor iptables is available; cannot verify FORWARD (refusing to skip)"
    return 0
  fi

  if (( have_nft == 1 )); then
    local out rc=0
    set +e
    out="$(read_forward_policy iptables-nft)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
      note_fail "iptables-nft is present but FORWARD policy cannot be read: ${out}"
    else
      nft="${out}"
      ok "iptables-nft FORWARD=${nft}"
    fi
  fi

  if (( have_legacy == 1 )); then
    local out rc=0
    set +e
    out="$(read_forward_policy iptables-legacy)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
      note_fail "iptables-legacy is present but FORWARD policy cannot be read: ${out}"
    else
      legacy="${out}"
      ok "iptables-legacy FORWARD=${legacy}"
    fi
  fi

  if [[ -n "${nft}" && -n "${legacy}" && "${nft}" == "ACCEPT" && "${legacy}" == "DROP" ]]; then
    note_fail "nft FORWARD=ACCEPT but legacy FORWARD=DROP. Containers look Up while they time out talking to their own DB. Fix: sudo iptables-legacy -P FORWARD ACCEPT"
  fi
}

# ---------------------------------------------------------------------------
# 3. Ports via 127.0.0.1 TCP connect. Foreign occupancy is a fail unless
#    the listening container belongs to this pack (re-run safe).
# ---------------------------------------------------------------------------
check_ports() {
  log "== host ports (bash /dev/tcp, not ss/netstat)"
  if ! assert_tcp_probe_available; then
    note_fail "TCP probe is not usable"
    return 0
  fi
  ok "bash /dev/tcp probe works"

  local port stack
  local -a pairs=()
  while IFS= read -r port; do
    [[ -n "${port}" ]] && pairs+=("ragflow:${port}")
  done < <(ragflow_host_ports)
  while IFS= read -r port; do
    [[ -n "${port}" ]] && pairs+=("khoj:${port}")
  done < <(khoj_host_ports)

  local seen=""
  for pair in "${pairs[@]}"; do
    stack="${pair%%:*}"
    port="${pair##*:}"
    if [[ " ${seen} " == *" ${port} "* ]]; then
      note_fail "duplicate host port ${port} in the planned publish list (stacks are not isolated)"
      continue
    fi
    seen+=" ${port} "

    if ! tcp_port_open "${port}"; then
      ok "127.0.0.1:${port} is free (${stack})"
      continue
    fi

    # Port is open — only OK if this pack already owns it.
    if ! command -v docker >/dev/null 2>&1; then
      note_fail "127.0.0.1:${port} is open and docker is missing, so ownership cannot be proven"
      continue
    fi
    local owner=""
    if project_owns_port "${RAGFLOW_PROJECT}" "${port}"; then
      owner="ragflow"
    elif project_owns_port "${KHOJ_PROJECT}" "${port}"; then
      owner="khoj"
    fi
    if [[ -n "${owner}" ]]; then
      ok "127.0.0.1:${port} already published by ${owner} (re-run ok)"
    else
      note_fail "127.0.0.1:${port} is in use by something that is not ${stack}; refuse to steal it"
    fi
  done
}

# ---------------------------------------------------------------------------
# 4. Elasticsearch vm.max_map_count
# ---------------------------------------------------------------------------
check_max_map_count() {
  log "== vm.max_map_count"
  if [[ ! -r /proc/sys/vm/max_map_count ]]; then
    note_fail "cannot read /proc/sys/vm/max_map_count"
    return 0
  fi
  local val
  val="$(tr -d '[:space:]' < /proc/sys/vm/max_map_count || true)"
  if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
    note_fail "unreadable vm.max_map_count value: '${val}'"
    return 0
  fi
  if (( val < ES_MIN_MAP_COUNT )); then
    note_fail "vm.max_map_count=${val} < ${ES_MIN_MAP_COUNT} (Elasticsearch). Fix: sudo sysctl -w vm.max_map_count=${ES_MIN_MAP_COUNT}  and persist in /etc/sysctl.conf"
    return 0
  fi
  ok "vm.max_map_count=${val}"
}

# ---------------------------------------------------------------------------
# 5. 16 GB hosts must cap RAGFlow MEM_LIMIT at 4 GiB so both stacks fit.
# ---------------------------------------------------------------------------
check_mem_limit() {
  log "== memory / MEM_LIMIT"
  local kb
  kb="$(host_mem_kb)"
  ok "MemTotal=${kb} kB"

  local env="${RAGFLOW_DIR}/.env"
  if [[ ! -f "${env}" ]]; then
    if is_16g_class_host; then
      warn "16 GB-class host: init-env will set MEM_LIMIT=${MEM_LIMIT_16G} (4 GiB) so RAGFlow + Khoj can coexist"
    fi
    return 0
  fi

  local limit
  if ! limit="$(env_get "${env}" MEM_LIMIT)"; then
    note_fail "${env} has no MEM_LIMIT"
    return 0
  fi
  if [[ ! "${limit}" =~ ^[0-9]+$ ]]; then
    note_fail "MEM_LIMIT='${limit}' is not an integer byte count"
    return 0
  fi

  if is_16g_class_host && (( limit > MEM_LIMIT_16G )); then
    note_fail "16 GB-class host (MemTotal=${kb} kB) but MEM_LIMIT=${limit} > ${MEM_LIMIT_16G}. Set MEM_LIMIT=${MEM_LIMIT_16G} in stacks/ragflow/.env"
    return 0
  fi
  ok "MEM_LIMIT=${limit}"
}

# ---------------------------------------------------------------------------
# 6. Image / port pins when .env already exists
# ---------------------------------------------------------------------------
check_pins() {
  log "== pins"
  local rf="${RAGFLOW_DIR}/.env" kj="${KHOJ_DIR}/.env"
  if [[ -f "${rf}" ]]; then
    local img web
    img="$(env_get_or "${rf}" RAGFLOW_IMAGE "")"
    web="$(env_get_or "${rf}" SVR_WEB_HTTP_PORT "")"
    if [[ "${img}" != "${RAGFLOW_IMAGE_PIN}" ]]; then
      note_fail "RAGFLOW_IMAGE='${img}' must be ${RAGFLOW_IMAGE_PIN}"
    else
      ok "RAGFLOW_IMAGE=${img}"
    fi
    if [[ "${web}" == "80" || -z "${web}" ]]; then
      note_fail "SVR_WEB_HTTP_PORT must be ${RAGFLOW_WEB_PORT_PIN} (refusing to occupy host :80)"
    elif [[ "${web}" != "${RAGFLOW_WEB_PORT_PIN}" ]]; then
      warn "SVR_WEB_HTTP_PORT=${web} (pack default is ${RAGFLOW_WEB_PORT_PIN})"
    else
      ok "RAGFlow web :${web}"
    fi
  else
    warn "stacks/ragflow/.env not created yet (make init-env)"
  fi

  if [[ -f "${kj}" ]]; then
    local kweb
    kweb="$(env_get_or "${kj}" KHOJ_HTTP_PORT "${KHOJ_WEB_PORT_PIN}")"
    if [[ "${kweb}" != "${KHOJ_WEB_PORT_PIN}" ]]; then
      warn "KHOJ_HTTP_PORT=${kweb} (pack default is ${KHOJ_WEB_PORT_PIN})"
    else
      ok "Khoj web :${kweb}"
    fi
  else
    warn "stacks/khoj/.env not created yet (make init-env)"
  fi
}

check_docker
check_iptables_forward
check_ports
check_max_map_count
check_mem_limit
check_pins

if (( FAILED != 0 )); then
  die "preflight failed (see FAIL lines). Re-run after fixing; this script is idempotent."
fi
ok "preflight passed"
