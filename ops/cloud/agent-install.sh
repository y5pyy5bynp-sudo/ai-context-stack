#!/usr/bin/env bash
# Build-time / bootstrap install for the ai-context-stack Cloud Agent
# environment. Runs after the repository is checked out. Idempotent.
#
# The base snapshot already contains Docker Engine + Compose, the pre-pulled
# RAGFlow and Khoj images, iptables capabilities, and docker-group membership.
# This step only prepares repo-local state that depends on the checkout.
set -euo pipefail

log() { printf '[agent-install] %s\n' "$*"; }

# Locate the ai-context-stack repo (the one containing the Makefile + ops/).
REPO=""
for cand in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
  "${PWD}" \
  /agent/repos/ai-context-stack \
  "${HOME}/ai-context-stack"; do
  if [[ -f "${cand}/Makefile" && -d "${cand}/ops" ]]; then REPO="${cand}"; break; fi
done
if [[ -z "${REPO}" ]]; then
  # Fall back to searching the workspace.
  REPO="$(dirname "$(grep -rlm1 'RAGFlow + Khoj dual-stack' /agent/repos 2>/dev/null | head -1)" 2>/dev/null || true)"
fi
if [[ -z "${REPO}" || ! -f "${REPO}/Makefile" ]]; then
  log "ERROR: could not locate the ai-context-stack repo (Makefile + ops/)"
  exit 1
fi
log "repo: ${REPO}"

# Sanity: required tools exist (baked into the snapshot).
for t in docker openssl python3 make; do
  command -v "$t" >/dev/null 2>&1 || { log "ERROR: missing required tool: $t"; exit 1; }
done

# Create per-stack .env files with generated secrets (idempotent; existing
# secrets are preserved). Does not require the Docker daemon.
cd "${REPO}"
make init-env

log "install complete. On boot the host is prepared by /opt/cloud/agent-start.sh;"
log "start the apps with: make up  (or make up-ragflow / make up-khoj)"
