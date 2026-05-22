# O

**An agent-company orchestrator — a stable, single-binary control plane that runs a company of AI agents.**

O is the open-source flagship for [swarmrt](https://github.com/skyblanket/swarmrt): a
long-lived daemon (`swarmd`) whose supervision tree *is* the org chart. It runs a
polling-orchestrator engine, manages a studio of role-based agents, enforces budgets and
approval gates, and exposes everything through the [O-Docs](../o-docs) graph + kanban UI.

This is **v4** — the swarmrt rebuild, succeeding the O-v3 Python studio.

> Design: see [`PRD-SWARM-ORCHESTRATOR.md`](../PRD-SWARM-ORCHESTRATOR.md).

## Status — P2 (the agent layer)

- **P0 — spine:** SQLite control-plane (8 tables) · `swarmd` daemon · HTTP server · REST CRUD.
- **P1 — engine:** single-authority orchestrator · Symphony-style tick loop · bounded
  concurrency · crash retry with exponential backoff · stall detection.
- **P2 — agents:** runtime-pluggable workers — `claude-code` (real headless `claude -p` in a
  per-issue workspace), `native` (single-shot LLM over HTTP), `sim` (deterministic stub) ·
  agent CRUD · the orchestrator assigns an agent to every issue.

Next: P3 — governance: budgets + hard-stop, approval gates, cost hooks.

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

curl -X POST http://127.0.0.1:4100/api/companies/<id>/agents \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada","role":"engineer","runtime":"claude-code"}'

curl http://127.0.0.1:4100/api/orchestrator   # live scheduler snapshot
curl http://127.0.0.1:4100/api/runs           # run history
```

An issue is only dispatched once its company has at least one active agent. The agent's
`runtime` (`claude-code` \| `native` \| `sim`) decides how the work actually runs.

Seeded issues are picked up automatically by the orchestrator — it dispatches workers,
retries failures, and kills stalled runs, with no further input.

## License

MIT © 2026 Otonomy Labs
