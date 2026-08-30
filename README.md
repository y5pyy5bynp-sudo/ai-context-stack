# ai-context-stack

Isolated **RAGFlow v0.27.1** + **Khoj** dual-stack. Two compose projects,
two networks, two volume prefixes, two host port sets. Each `make` target
is safe to re-run. Destructive restore always snapshots current state first.

| Stack   | Compose project | Network           | Web port | Image                         |
|---------|-----------------|-------------------|----------|-------------------------------|
| RAGFlow | `ragflow`       | `ragflow_isolated`| **8081** | `infiniflow/ragflow:v0.27.1`  |
| Khoj    | `khoj`          | `khoj_isolated`   | **42110**| official `ghcr.io/khoj-ai/khoj` |

Khoj follows the official compose file with the **computer** service removed
(no `:5900`). RAGFlow never binds host **:80**.

Secrets live in `stacks/ragflow/.env` and `stacks/khoj/.env`. Only
`.env.example` files are committed.

## Quick start

```bash
make init-env      # create .env files, generate secrets, pin ports/image
make preflight     # fail closed on host pitfalls (see below)
make up            # both stacks
make status
# RAGFlow  http://127.0.0.1:8081
# Khoj     http://127.0.0.1:42110
```

Single stack: `make up-ragflow` / `make up-khoj`. Stop without deleting
volumes: `make down`.

On a **~16 GiB** host, `init-env` / `preflight` force
`MEM_LIMIT=4294967296` (4 GiB) so Elasticsearch and Khoj can run together.

## Known pitfalls (preflight)

`make preflight` **fails** when a check cannot run. It never parses
`ss` / `netstat`.

1. **iptables nft + legacy.** If `iptables-nft FORWARD=ACCEPT` but
   `iptables-legacy FORWARD=DROP`, containers look `Up` while they time out
   talking to their own database. Fix:

   ```bash
   sudo iptables-legacy -P FORWARD ACCEPT
   ```

2. **Port occupancy.** Probes are `timeout 1 bash -c 'echo >/dev/tcp/127.0.0.1/$PORT'`.
   A foreign listener on 8081 / 42110 / 3306 / … is a failure. The same
   port already published by this pack is treated as a re-run, not a conflict.

3. **Elasticsearch `vm.max_map_count`.** Must be `>= 262144`:

   ```bash
   sudo sysctl -w vm.max_map_count=262144
   echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
   ```

Also requires Docker Engine + Compose `>= 2.26.1`.

## Backup and restore

These are real volume tarballs, not placeholders.

```bash
make backup                         # backups/<UTC>/ + backups/latest
make restore BACKUP=backups/<UTC>   # snapshots current state first, then replaces
make test-backup                    # archive/extract self-test (no Docker)
```

Each snapshot contains `MANIFEST`, both `.env` files, bind-mount logs, and
`*.tar.gz` (or `*.missing`) for every named volume. Restore stops the
stacks, writes `.env` back, and unpacks volumes in place.

`docker compose down -v` is **not** wired into this Makefile.

## Layout

```
Makefile
.env.example                 # pointers only; no secrets
ops/
  lib.sh
  preflight.sh
  init-env.sh
  status.sh
  backup.sh
  restore.sh
stacks/ragflow/              # official v0.27.1 docker/ + isolation
  .env.example
  docker-compose.yml
  docker-compose-base.yml
  VENDOR.md
stacks/khoj/                 # official compose minus computer
  .env.example
  docker-compose.yml
  VENDOR.md
```

## Makefile

| Target | What it does |
|--------|----------------|
| `make init-env` | Create/merge `.env`, generate secrets, apply pins |
| `make preflight` | Host + pin checks (fail closed) |
| `make up` | `init-env` + `preflight` + both stacks |
| `make down` | `compose down` (volumes kept) |
| `make status` | `compose ps` + `/dev/tcp` probes |
| `make backup` / `make restore BACKUP=…` | Volume + env snapshot / replace |
| `make logs` | Tail both stacks |

Re-running `init-env` does not rotate existing secrets.

## Isolation contract

- Compose `--project-name` / `name:` is `ragflow` vs `khoj`
- Networks: `ragflow_isolated` vs `khoj_isolated`
- Volumes: `ragflow_*` vs `khoj_*`
- Host UI: `8081` vs `42110` (RAGFlow HTTPS on `8443`, not `443`)

See `stacks/*/VENDOR.md` for upstream tags and the exact local diffs.
