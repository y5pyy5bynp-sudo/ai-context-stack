# RAGFlow stack provenance

- Upstream: https://github.com/infiniflow/ragflow
- Tag: `v0.27.1`
- Image pin: `infiniflow/ragflow:v0.27.1`
- Paths copied from `docker/` on that tag:
  - `docker-compose.yml`
  - `docker-compose-base.yml`
  - `entrypoint.sh`
  - `service_conf.yaml.template`
  - `init.sql`
  - `init-clickhouse.sql`
  - `infinity_conf.toml`

## Local changes (isolation + this pack)

- Compose project `name: ragflow`
- Named volumes `ragflow_*` and network `ragflow_isolated`
- Host HTTP `SVR_WEB_HTTP_PORT=8081` (never 80), HTTPS `8443`
- `MEM_LIMIT=4294967296` on ~16 GiB hosts
- Secrets generated into `.env` by `make init-env`, not committed

Optional official profiles (`gpu`, `infinity`, `sandbox`, …) remain unused
unless you change `COMPOSE_PROFILES` in `.env`.
