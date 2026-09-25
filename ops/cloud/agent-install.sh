#!/usr/bin/env bash
# Build-time / bootstrap install for the ai-context-stack Cloud Agent
# environment. Runs after the repository is checked out. Idempotent.
#
# Self-contained: installs Docker Engine + Compose, grants the iptables
# capabilities the pack's preflight needs, generates the per-stack .env files,
# and pre-pulls the RAGFlow + Khoj images so they are baked into the build.
# Per-boot concerns (dockerd, sysctl, iptables policy) live in agent-start.sh.
set -euo pipefail

log() { printf '[agent-install] %s\n' "$*"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- locate the ai-context-stack repo (Makefile + ops/) --------------------
REPO=""
for cand in "${PWD}" /agent/repos/ai-context-stack "${HOME}/ai-context-stack" "${SELF_DIR}/../.."; do
  if [[ -f "${cand}/Makefile" && -d "${cand}/ops" && -f "${cand}/ops/lib.sh" ]]; then
    REPO="$(cd "${cand}" && pwd)"; break
  fi
done
if [[ -z "${REPO}" ]]; then
  marker="$(grep -rlm1 'RAGFlow + Khoj dual-stack' /agent/repos /root /home 2>/dev/null | head -1 || true)"
  [[ -n "${marker}" ]] && REPO="$(dirname "${marker}")"
fi
if [[ -z "${REPO}" || ! -f "${REPO}/Makefile" ]]; then
  log "ERROR: could not locate the ai-context-stack repo (Makefile + ops/)"; exit 1
fi
log "repo: ${REPO}"

# --- 1. Docker Engine + Compose (idempotent) -------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker Engine + Compose..."
  export DEBIAN_FRONTEND=noninteractive
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo apt-get update -qq
  sudo apt-get install -y -qq -o Dpkg::Options::=--force-confold \
    ca-certificates curl gnupg fuse-overlayfs iptables
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq -o Dpkg::Options::=--force-confold \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "installed: $(docker --version)"
else
  log "docker already present: $(docker --version)"
fi

# --- 2. Let the preflight read iptables as non-root (persists on binaries) --
for multi in /usr/sbin/xtables-nft-multi /usr/sbin/xtables-legacy-multi; do
  if [[ -e "${multi}" ]]; then
    sudo setcap 'cap_net_admin,cap_net_raw+ep' "${multi}" 2>/dev/null || true
  fi
done

# --- 3. Docker group --------------------------------------------------------
sudo groupadd -f docker
sudo usermod -aG docker "$(id -un)" || true

# --- 4. Bring the host up so we can pull images (reuses start logic) --------
bash "${SELF_DIR}/agent-start.sh"

# --- 5. Generate per-stack .env files (idempotent) -------------------------
cd "${REPO}"
make init-env

# --- 6. Pre-pull the images for both stacks (bakes them into the build) -----
# shellcheck disable=SC1091
source "${REPO}/ops/lib.sh"
log "pulling RAGFlow images (default profiles)..."
ragflow_compose pull
log "pulling Khoj images..."
khoj_compose pull
log "images present:"
docker images --format '  {{.Repository}}:{{.Tag}} ({{.Size}})' | sort

log "install complete. Apps start on demand: make up | make up-ragflow | make up-khoj"
