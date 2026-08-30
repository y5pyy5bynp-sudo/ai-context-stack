# Khoj stack provenance

- Upstream: https://github.com/khoj-ai/khoj
- Compose file at commit `61cb2d5b7e3349fdd6d06c92aa26b46fb8c9966d`
  (`docker-compose.yml` on `master`)
- Image default: `ghcr.io/khoj-ai/khoj:latest`

## Local changes

- Removed the `computer` service and `khoj_computer` volume (and its `:5900`)
- Compose project `name: khoj`, network `khoj_isolated`
- Named volumes `khoj_*` so they cannot collide with RAGFlow
- Host web port `${KHOJ_HTTP_PORT:-42110}` only
- Passwords and Django secret come from `.env` via `make init-env`
