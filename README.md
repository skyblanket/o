# O

**An agent-company orchestrator — a stable, single-binary control plane that runs a company of AI agents.**

O is the open-source flagship for [swarmrt](https://github.com/skyblanket/swarmrt): a
long-lived daemon (`swarmd`) whose supervision tree *is* the org chart. It runs a
polling-orchestrator engine, staffs companies with role-based agents, enforces budgets and
approval gates, and serves a live operator dashboard — all from one ~290 KB native binary.
No Node, no Postgres, no containers.

This is **v4** — the swarmrt rebuild, succeeding the O-v3 Python studio.

> Design rationale: [`PRD-SWARM-ORCHESTRATOR.md`](../PRD-SWARM-ORCHESTRATOR.md).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/skyblanket/o/main/scripts/install.sh | sh
```

Or from source (needs the [swarmrt](https://github.com/skyblanket/swarmrt) toolchain):

```sh
git clone https://github.com/skyblanket/o && cd o
make            # build bin/swarmd
make install    # -> ~/.local/bin/swarmd, dashboard -> ~/.o/web/
```

## Quickstart

```sh
swarmd                       # start the daemon
make seed                    # seed an example company to watch
open http://localhost:4100   # the operator dashboard
```

An embedded SQLite control plane is created at `~/.o/o.db` — no database to set up.

## How it works

A single **orchestrator** process polls the issue board on a fixed tick, assigns each open
issue to an agent, and dispatches it up to a concurrency cap — retrying crashes with
exponential backoff and killing stalled runs. Agents do real work through pluggable
**runtimes**: `claude-code` spawns a headless `claude -p` in an isolated per-issue
workspace; `native` calls an LLM over HTTP; `sim` is a deterministic stub. Every run's cost
is metered onto the company **budget**; a company that hits its cap is hard-stopped — new
dispatch and in-flight retries both freeze.

The supervision tree is the company. The task board is the orchestrator's self-model. You
watch it from the dashboard; you don't drive it.

## Status

All milestones complete:

| | |
|---|---|
| **P0** spine | SQLite control-plane (8 tables) · `swarmd` daemon · HTTP + REST CRUD |
| **P1** engine | single-authority orchestrator · tick loop · concurrency · backoff retry · stall detection |
| **P2** agents | runtime-pluggable workers — `claude-code` / `native` / `sim` |
| **P3** governance | per-company budgets + hard-stop · cost hook · approval gates |
| **P4** dashboard | `swarmd` serves a single-file operator UI at `/` |
| **P5** polish | installer · example company · docs |

## API

```sh
curl http://localhost:4100/api/health
curl http://localhost:4100/api/companies
curl -X POST http://localhost:4100/api/companies \
  -d '{"name":"Otonomy","mission":"ship","issue_prefix":"OTO","budget_monthly_cents":50000}'
curl -X POST http://localhost:4100/api/companies/<id>/agents \
  -d '{"name":"Ada","role":"engineer","runtime":"claude-code"}'
curl -X POST http://localhost:4100/api/companies/<id>/issues \
  -d '{"title":"first task","priority":"high"}'
curl -X POST http://localhost:4100/api/companies/<id> \
  -d '{"budget_monthly_cents":80000,"status":"active"}'   # set budget / un-pause

curl http://localhost:4100/api/orchestrator   # live scheduler snapshot
curl http://localhost:4100/api/runs           # run history
curl http://localhost:4100/api/activity       # activity log
curl http://localhost:4100/api/approvals      # pending governance approvals
```

An issue is dispatched only once its company has an active agent. Set `O_REQUIRE_APPROVALS=1`
to route agent hiring through `/api/approvals` for operator sign-off (off by default).

## License

MIT © 2026 Otonomy Labs
