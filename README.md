# O

**An agent-company orchestrator — a stable, single-binary control plane that runs a company of AI agents.**

O is the open-source flagship for [swarmrt](https://github.com/skyblanket/swarmrt): a
long-lived daemon (`swarmd`) whose supervision tree *is* the org chart. It runs a
polling-orchestrator engine, manages a studio of role-based agents, enforces budgets and
approval gates, and exposes everything through the [O-Docs](../o-docs) graph + kanban UI.

This is **v4** — the swarmrt rebuild, succeeding the O-v3 Python studio.

> Design: see [`PRD-SWARM-ORCHESTRATOR.md`](../PRD-SWARM-ORCHESTRATOR.md).

## Status — P0 (the spine)

Implemented: SQLite control-plane schema · `swarmd` daemon · HTTP server · REST CRUD for
companies and issues · activity log.

Next: P1 — the orchestration tick loop (Symphony-style: poll, dispatch, retry, stall-detect).

## Build & run

```sh
make            # builds bin/swarmd  (needs swarmrt at ../swarmrt)
make run        # starts the daemon on http://127.0.0.1:4100
```

The control-plane database is created automatically at `~/.o/o.db`.

## API (P0)

```sh
curl http://127.0.0.1:4100/api/health
curl http://127.0.0.1:4100/api/companies
curl -X POST http://127.0.0.1:4100/api/companies \
  -H 'Content-Type: application/json' \
  -d '{"name":"Otonomy","mission":"ship","issue_prefix":"OTO"}'
curl http://127.0.0.1:4100/api/companies/<id>/issues
curl -X POST http://127.0.0.1:4100/api/companies/<id>/issues \
  -H 'Content-Type: application/json' \
  -d '{"title":"first task","priority":"high"}'
```

## License

MIT © 2026 Otonomy Labs
