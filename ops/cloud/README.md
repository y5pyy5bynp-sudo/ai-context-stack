# Cursor Cloud Agent environment

Bootstrap scripts that make this repo's **RAGFlow + Khoj dual-stack** runnable
inside a [Cursor Cloud Agent](https://cursor.com/docs/cloud-agent) VM, where
Docker is not preinstalled and there is no systemd.

| Script | Lifecycle | What it does |
|--------|-----------|--------------|
| `agent-install.sh` | once, at build/bootstrap (after checkout) | Installs Docker Engine + the Compose v2 plugin (if missing), grants the `iptables` binaries `CAP_NET_ADMIN,CAP_NET_RAW` so the pack's preflight can read the `FORWARD` policy as non-root, adds the agent user to the `docker` group, runs `make init-env` to create the gitignored `stacks/*/.env` files, and pre-pulls the RAGFlow + Khoj images (so they are baked into the environment build). |
| `agent-start.sh` | every boot | Sets `vm.max_map_count=262144` (Elasticsearch), forces `iptables FORWARD=ACCEPT` on all backends, starts `dockerd` (fuse-overlayfs storage driver) if not already running, and makes the Docker socket usable by the agent user. Does **not** start the heavy compose stacks. |

Both scripts are idempotent and safe to re-run.

## Base image expectations

`agent-install.sh` is self-contained and works on top of Cursor's default
Ubuntu base image: it installs Docker itself. The base only needs:

- A Debian/Ubuntu userland with `sudo`, `apt-get`, `curl` and network egress
  to `download.docker.com`, Docker Hub and `ghcr.io`.
- `/dev/fuse` available (rootful Docker uses the `fuse-overlayfs` storage
  driver because the rootfs is itself an overlay mount). There is no systemd,
  so `dockerd` is launched directly by `agent-start.sh`.

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
