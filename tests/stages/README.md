# tests/stages: tests O can add

`scripts/check.sh` and `tests/heldout/` are protected paths: an agent working on O
(O-self included) can't edit or weaken them. New tests go here instead, one file per
concern: `tests/stages/<NN>-<what>.sh`.

## How a stage runs

- `scripts/check.sh` runs every `tests/stages/*.sh`, in name order, after its own
  stages and before the held-out suite.
- Each stage is sourced in its own subshell, from the repo root, with `bin/swarmd`
  already built and `set -euo pipefail` on. A `fail` ends only that stage, and then
  the suite fails.
- Run one stage alone: `O_STAGE_ONLY=tests/stages/<file>.sh ./scripts/check.sh`
  (it builds, runs that stage, and stops).

## What a stage can use

check.sh's helpers:

| helper | what it does |
|---|---|
| `free_port BASE SPAN` | a free port in `[BASE, BASE+SPAN)`; stages use 6000-6999 |
| `stop_daemon PID` | stop a daemon and wait until it is gone |
| `rmtmp DIR` | remove a temp dir (kept when `O_KEEP_TMP=1`, for a post-mortem) |
| `ocurl ...` | curl with a 10 s cap and one retry on a dropped connection |
| `jget JSON 'd["key"]'` | print a value from a JSON string |
| `wait_status_at BASE IID STATUS SECONDS` | wait until an issue reaches a status |
| `sqlite3 ...` | sqlite3 that waits out the daemon's write lock |
| `pass MSG`, `fail MSG` | report |

The environment already sets fast ticks (`O_TICK_MS=500`, `O_BACKOFF_MS=300`) and
turns off the adaptive model, the breaker and the boot preflight
(`O_ADAPT=0`, `O_BROKEN_RUNS=0`, `O_PREFLIGHT=0`). Turn one back on in your stage
when that is what you test.

## A stage owns its daemon

Boot your own daemon on a throwaway `HOME` and DB, and clean up in your own trap:

```sh
# tests/stages/10-example.sh: one line on what this stage proves
T="$(mktemp -d)"; P="$(free_port 6000 1000)"; B="http://127.0.0.1:$P"; D=""
trap '[ -n "$D" ] && stop_daemon "$D"; rmtmp "$T"' EXIT
HOME="$T" O_DB="$T/o.db" O_PORT="$P" O_NO_OPEN=1 ./bin/swarmd >"$T/daemon.log" 2>&1 &
D=$!
for _i in $(seq 1 30); do [ "$(ocurl -s -o /dev/null -w '%{http_code}' "$B/api/health")" = 200 ] && break; sleep 0.5; done
# a company on a scratch git repo, a "sim" agent, an issue, then assert on the API and DB
pass "what this stage proved"
```

- **Fake GitHub:** point `O_GH_BIN` at a stub script. `stage_d4` in `scripts/check.sh` has a complete one: REST paths, PR numbers, real merges into a bare repo.
- **Fake model:** point `O_CLAUDE_BIN` at a stub that reads the prompt on stdin and prints stream-json. Stages 4 and 5 in `scripts/check.sh` show the format.

Rules:
- A new test must fail without the change it covers.
- Keep a stage under about a minute.
- Never delete or weaken an existing stage.
