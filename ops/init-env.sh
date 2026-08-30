#!/usr/bin/env bash
# Create per-stack .env files from examples. Idempotent: existing secret
# values are never overwritten. Real secrets stay in .env (gitignored).

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd openssl
require_cmd python3

SECRET_KEYS=(
  ELASTIC_PASSWORD
  OPENSEARCH_PASSWORD
  SERENEDB_PASSWORD
  OCEANBASE_PASSWORD
  SEEKDB_PASSWORD
  MYSQL_PASSWORD
  MINIO_PASSWORD
  REDIS_PASSWORD
  CLICKHOUSE_PASSWORD
  POSTGRES_PASSWORD
  KHOJ_DJANGO_SECRET_KEY
  KHOJ_ADMIN_PASSWORD
)

is_placeholder() {
  local v="$1"
  [[ -z "${v}" || "${v}" == "CHANGE_ME" || "${v}" == "infini_rag_flow" \
    || "${v}" == "infini_rag_flow_OS_01" || "${v}" == "secret" \
    || "${v}" == "password" || "${v}" == "postgres" ]]
}

gen_secret() {
  openssl rand -hex 24
}

# Copy missing keys from example -> dest without touching existing keys.
merge_missing_keys() {
  local example="$1" dest="$2"
  python3 - "${example}" "${dest}" <<'PY'
import sys
from pathlib import Path

example, dest = Path(sys.argv[1]), Path(sys.argv[2])
ex_lines = example.read_text().splitlines(keepends=True)
have = set()
for line in dest.read_text().splitlines():
    if line and not line.startswith("#") and "=" in line:
        have.add(line.split("=", 1)[0])

missing = []
for line in ex_lines:
    raw = line.strip()
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    key = raw.split("=", 1)[0]
    if key not in have:
        missing.append(line if line.endswith("\n") else line + "\n")

if missing:
    with dest.open("a", encoding="utf-8") as fh:
        fh.write("\n# --- keys added from .env.example ---\n")
        fh.writelines(missing)
    print(f"added {len(missing)} missing key(s) to {dest}")
else:
    print(f"no missing keys in {dest}")
PY
}

set_key() {
  local file="$1" key="$2" value="$3"
  python3 - "${file}" "${key}" "${value}" <<'PY'
import sys
from pathlib import Path
path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines(keepends=True)
found = False
out = []
for line in lines:
    raw = line.lstrip()
    if raw.startswith(f"{key}="):
        nl = "\n" if line.endswith("\n") else ""
        out.append(f"{key}={value}{nl}")
        found = True
    else:
        out.append(line)
if not found:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(f"{key}={value}\n")
path.write_text("".join(out))
PY
}

get_key() {
  local file="$1" key="$2"
  env_get "${file}" "${key}" || true
}

ensure_env() {
  local example="$1" dest="$2" stack="$3"
  if [[ ! -f "${example}" ]]; then
    die "missing ${example}"
  fi
  if [[ ! -f "${dest}" ]]; then
    cp "${example}" "${dest}"
    chmod 600 "${dest}"
    ok "created ${dest} from example"
  else
    chmod 600 "${dest}" || true
    merge_missing_keys "${example}" "${dest}"
    ok "reusing existing ${dest}"
  fi

  local key current
  for key in "${SECRET_KEYS[@]}"; do
    current="$(get_key "${dest}" "${key}")"
    if [[ -z "${current}" ]] && ! grep -qE "^${key}=" "${dest}"; then
      continue
    fi
    if is_placeholder "${current}"; then
      set_key "${dest}" "${key}" "$(gen_secret)"
      ok "generated ${key} in ${stack}"
    fi
  done
}

ensure_env "${RAGFLOW_DIR}/.env.example" "${RAGFLOW_DIR}/.env" "ragflow"
ensure_env "${KHOJ_DIR}/.env.example" "${KHOJ_DIR}/.env" "khoj"

# Hard pins — always enforce pack contract, even on re-runs.
set_key "${RAGFLOW_DIR}/.env" COMPOSE_PROJECT_NAME "${RAGFLOW_PROJECT}"
set_key "${RAGFLOW_DIR}/.env" RAGFLOW_IMAGE "${RAGFLOW_IMAGE_PIN}"
set_key "${RAGFLOW_DIR}/.env" SVR_WEB_HTTP_PORT "${RAGFLOW_WEB_PORT_PIN}"
set_key "${KHOJ_DIR}/.env" COMPOSE_PROJECT_NAME "${KHOJ_PROJECT}"
set_key "${KHOJ_DIR}/.env" KHOJ_HTTP_PORT "${KHOJ_WEB_PORT_PIN}"

# Never publish RAGFlow on host :80 / :443.
local_https="$(get_key "${RAGFLOW_DIR}/.env" SVR_WEB_HTTPS_PORT)"
if [[ "${local_https}" == "443" || -z "${local_https}" ]]; then
  set_key "${RAGFLOW_DIR}/.env" SVR_WEB_HTTPS_PORT "8443"
  ok "SVR_WEB_HTTPS_PORT=8443 (avoid host :443)"
fi

if is_16g_class_host; then
  set_key "${RAGFLOW_DIR}/.env" MEM_LIMIT "${MEM_LIMIT_16G}"
  ok "16 GB-class host: MEM_LIMIT=${MEM_LIMIT_16G}"
fi

# Refuse to leave CHANGE_ME in the generated files.
leftover="$(grep -n '=CHANGE_ME$' "${RAGFLOW_DIR}/.env" "${KHOJ_DIR}/.env" || true)"
if [[ -n "${leftover}" ]]; then
  die "placeholder CHANGE_ME still present:\n${leftover}"
fi

ok "init-env complete (secrets are in stacks/*/.env, not git)"
