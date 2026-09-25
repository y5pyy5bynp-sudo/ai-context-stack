# Cursor Cloud Agent environment

Bootstrap scripts that make this repo's **RAGFlow + Khoj dual-stack** runnable
inside a [Cursor Cloud Agent](https://cursor.com/docs/cloud-agent) VM, where
Docker is not preinstalled and there is no systemd.

| Script | Lifecycle | What it does |
|--------|-----------|--------------|
| `agent-install.sh` | once, at build/bootstrap (after checkout) | Verifies required tools and runs `make init-env` to create the gitignored `stacks/*/.env` files. |
| `agent-start.sh` | every boot | Sets `vm.max_map_count=262144` (Elasticsearch), forces `iptables FORWARD=ACCEPT` on all backends, starts `dockerd` (fuse-overlayfs storage driver) if not already running, and makes the Docker socket usable by the agent user. Does **not** start the heavy compose stacks. |

Both scripts are idempotent and safe to re-run.

## Base image expectations

The scripts assume the VM's base image/snapshot already provides:

- Docker Engine + the Compose v2 plugin (`docker`, `docker compose`)
- `fuse-overlayfs` and `/dev/fuse` (rootful Docker on a nested overlay rootfs)
- `CAP_NET_ADMIN,CAP_NET_RAW` file capabilities on the `iptables` backends so
  the pack's preflight can read the `FORWARD` policy as a non-root user:
  ```bash
  sudo setcap 'cap_net_admin,cap_net_raw+ep' /usr/sbin/xtables-nft-multi
  sudo setcap 'cap_net_admin,cap_net_raw+ep' /usr/sbin/xtables-legacy-multi
  ```
- The `ubuntu` user in the `docker` group
- Pre-pulled RAGFlow/Khoj images (optional but avoids a large first-run pull)

## Running the apps

After the host is prepared:

```bash
make up            # both stacks
make up-ragflow    # RAGFlow only  -> http://127.0.0.1:8081
make up-khoj       # Khoj only     -> http://127.0.0.1:42110
make status
make down          # stop (keeps volumes)
```

> Memory note: on a 16 GiB-class VM `make init-env` pins RAGFlow's
> `MEM_LIMIT` to 4 GiB. Both stacks together use roughly 8-10 GiB while
> running; bring them up together only when enough RAM is free, otherwise run
> one stack at a time.
