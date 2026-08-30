# ai-context-stack

Isolated **RAGFlow v0.27.1** + **Khoj** dual-stack deploy pack.

Two compose projects, two networks, two volume prefixes, two host port sets.
Secrets live in per-stack `.env` files (generated, never committed).

```bash
make help
make check-lib
```

Further steps add `ops/preflight.sh`, `ops/init-env.sh`, the two stacks, then
`make backup` / `make restore`.
