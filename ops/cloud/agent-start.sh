#!/usr/bin/env bash
# Per-boot startup for the ai-context-stack Cloud Agent environment.
# Brings the host to the state the RAGFlow + Khoj dual-stack needs, then
# returns. Idempotent: safe to run on every boot and re-runnable by hand.
#
# It does NOT start the heavy compose stacks. Bring those up on demand with:
#   cd <repo> && make up            # both stacks
#   make up-ragflow  |  make up-khoj
set -euo pipefail

log() { printf '[agent-start] %s\n' "$*"; }

# 1. Kernel tunable required by Elasticsearch (resets every boot).
want_mmc=262144
cur_mmc="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if (( cur_mmc < want_mmc )); then
  sudo sysctl -w vm.max_map_count="${want_mmc}" >/dev/null
  log "vm.max_map_count set to ${want_mmc}"
else
  log "vm.max_map_count already ${cur_mmc}"
fi

# 2. Docker bridge forwarding. On dual-backend hosts, a legacy FORWARD=DROP
#    black-holes container->container traffic while containers look "Up".
#    Keep FORWARD=ACCEPT on whichever backends exist. (resets every boot)
sudo touch /run/xtables.lock 2>/dev/null || true
sudo chmod 666 /run/xtables.lock 2>/dev/null || true
for bin in iptables-legacy iptables-nft iptables; do
  if command -v "${bin}" >/dev/null 2>&1; then
    sudo "${bin}" -P FORWARD ACCEPT 2>/dev/null && log "${bin} FORWARD=ACCEPT" || true
  fi
done

# 3. Docker daemon. Start it (detached) only if it is not already responding.
if sudo docker info >/dev/null 2>&1; then
  log "dockerd already running"
else
  log "starting dockerd (fuse-overlayfs)..."
  # If a previous dockerd is still shutting down (socket gone but process
  # alive), wait for it to fully exit before launching a new one.
  for i in $(seq 1 30); do
    pgrep -x dockerd >/dev/null 2>&1 || break
    sleep 1
  done
  # Log to a root-owned path: fs.protected_regular blocks writing logs into
  # the sticky /tmp dir when the file is owned by another user. The
  # fuse-overlayfs storage driver is required on the nested overlay rootfs.
  DOCKERD_LOG=/var/log/dockerd.log
  sudo bash -c "setsid dockerd --storage-driver fuse-overlayfs >${DOCKERD_LOG} 2>&1 < /dev/null &"
  for i in $(seq 1 60); do
    if sudo docker info >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if ! sudo docker info >/dev/null 2>&1; then
    log "ERROR: dockerd did not become ready in 60s; see ${DOCKERD_LOG}"
    sudo tail -n 20 "${DOCKERD_LOG}" || true
    exit 1
  fi
  log "dockerd is ready"
fi

# 4. Let the non-root agent user talk to the daemon without sudo.
#    (Group membership is not picked up by non-login shells, so relax the
#    socket mode on this ephemeral single-user dev VM.)
if [[ -S /var/run/docker.sock ]]; then
  sudo chown root:docker /var/run/docker.sock 2>/dev/null || true
  sudo chmod 666 /var/run/docker.sock
  log "docker.sock is accessible to the agent user"
fi

log "host is ready. Start apps with: make up  (or make up-ragflow / make up-khoj)"
