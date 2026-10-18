# O

An autonomous software loop. O watches its own issue board, dispatches coding
agents into isolated git worktrees, verifies their work with your real test
suite, auto-merges what passes, auto-reverts what regresses, budgets itself by
the day, and files its own follow-up issues — from failures it catches and from
a daily pass where it reflects on its own recent work. It runs as one native
daemon (`swarmd`) built on [swarmrt](https://github.com/skyblanket/swarmrt).
There is no queue, no Postgres, no container — an embedded SQLite file is the
whole control plane.

```
                 ┌──────────────────────────────────────────────┐
                 │                   swarmd                      │
                 │                                               │
   issue board ──┼─▶ tick ─▶ dispatch ─▶ agent in git worktree  │
        ▲        │             (claude-code / swarm-code / sim)  │
        │        │                       │                       │
        │        │                       ▼                       │
        │        │            verify (your test suite)           │
        │        │              │              │                 │
        │        │         green│              │red              │
        │        │              ▼              ▼                 │
        │        │      --no-ff merge      retry ─▶ Failed        │
        │        │              │                    │           │
        │        │       post-merge verify           │           │
        │        │          │         │              │           │
        │        │      ok  │         │ regressed    │           │
        │        │          ▼         ▼              ▼           │
        │        │        Done     revert +      file follow-up  │
        └────────┼──────────────── fix issue ◀──── issue (auto)  │
                 │                                               │
                 │   daily: rollover budgets · reflection pass   │
                 └──────────────────────────────────────────────┘
```

## Quick start

Prerequisites: a C toolchain (`cc`, `make`), `git`, `perl`, `python3` and the
`sqlite3` CLI (the test suites query the control plane with it); Node for the UI
and the MCP server; `claude` on `PATH` for real agent runs.

O builds with the swarmrt toolchain. Clone swarmrt as a sibling of this repo
(the default the Makefile expects), build its compiler, then build O:

```sh
git clone https://github.com/skyblanket/swarmrt   # sibling of this repo
(cd swarmrt && make swc libswarmrt)
git clone https://github.com/skyblanket/o
cd o
make                 # -> bin/swarmd   (or: make SWARMRT=/path/to/swarmrt)
make check           # hermetic end-to-end test suite (sim runtime, no tokens)
./scripts/acceptance.sh                  # whole-loop acceptance, stub agent
O_ACCEPT_REAL=1 ./scripts/acceptance.sh  # same, with a real claude agent (spends tokens)
```

Run the daemon and the web UI together:

```sh
make dev             # swarmd on :4100 + the React UI on :5173
open http://localhost:5173
```

Point O at a repo it should maintain — including itself:

```sh
./scripts/seed-maintainer.sh          # an "O Core" company that maintains this repo
./scripts/seed-example.sh             # a sim-runtime demo company, no tokens spent
```

Drive O from Claude Code over MCP (`mcp/node_modules` is not committed):

```sh
(cd mcp && npm install)
claude mcp add o -- node "$PWD/mcp/server.js"
```

The control plane lives at `~/.o/o.db`; per-issue worktrees live under
`~/.o/workspaces/`. Nothing else is created.

## Safety model

O edits real repositories on its own. The guard rails are the point.

- **Agent sandbox (Linux, `O_SANDBOX=bwrap`).** Agent and reviewer runs see a
  read-only filesystem. They can write only their own worktree, the repo's
  `.git` (with `config` and `hooks` kept read-only, since both can make git run
  commands), `~/.claude` and `/tmp`. `~/.o` is hidden, and a private PID
  namespace keeps the daemon's environment (and `O_API_TOKEN`) out of reach.
- **Grounded verifier.** A change is judged only by running the company's real
  `verify_cmd` in the worktree — never by the agent's own claim of success. A run
  that makes no commit, that touches a protected path, or whose verify command
  fails does not merge. Verdicts are recorded per run: `red_no_commit`,
  `red_protected`, `red_tests`, and so on.
- **Review gate (opt-in, `O_REVIEW=1`).** Passing tests prove the tests pass,
  not that the change is right. With the gate on, a second, read-only model
  reviews each green diff against its issue before merge; a rejection is a
  `red_review` verdict whose reason feeds the next attempt's prompt. It fails
  closed: no parseable verdict counts as a rejection.
- **Protected paths.** Each company declares `protected_paths`. An agent may not
  change them; a commit that does is rejected (`red_protected`) before it can
  merge. Renames count as touching both paths, and the agent's prompt lists the
  fence. The test harness and this loop's own invariants live behind it, so an
  agent maintaining O cannot edit the checks that gate its merges.
- **Guarded control plane.** Writes must be `Content-Type: application/json` and
  CORS preflights are answered only for loopback origins, so a web page can't
  drive the API. Set `O_API_TOKEN` to require `Authorization: Bearer` on
  company / agent / approval writes (filing issues and feedback stays open);
  agent subprocesses never receive the token, so an agent can't rewrite its own
  `verify_cmd` or `protected_paths` through the API.
- **Everything on a branch.** Each issue runs on `o/<issue>` in its own worktree.
  Green work lands with a `--no-ff` merge that names the branch. If the merge
  regresses the base (post-merge verify goes red, and stays red on a re-run so a
  single flaky test doesn't count), O reverts the merge on the base branch and
  **keeps the branch** for forensics.
- **Budget circuit breakers.** Every run is metered onto the company's daily and
  monthly budgets; a run killed on its wall-clock cap (which reports no cost) is
  charged a flat estimate. Hitting a cap pauses the company (`budget-daily` /
  `budget-monthly`). A separate **no-signal** breaker pauses a company that burns
  budget across days without shipping a single verified-green merge.
- **Bounded self-filing.** When O files its own follow-up work (a regression to
  fix, a repeated stall, a no-signal diagnostic, a reflection idea) it is
  guarded: **depth-1** (an auto-filed issue that itself fails files no child, so
  a red loop can't fork-bomb), **fingerprint dedup** (one open issue per failure
  fingerprint), and a **daily cap** per company.

## GitHub in / out

Point a company at a GitHub repo and O works its issue tracker and ships
through its CI. `repo` must be a local clone whose `origin` is that repo; the
`gh` CLI must be authenticated.

```sh
curl -s -X POST localhost:4100/api/companies -H 'Content-Type: application/json' -d '{
  "name": "Widgets", "issue_prefix": "WID",
  "repo": "/path/to/widgets-clone", "verify_cmd": "make test",
  "protected_paths": "tests/,.github/",
  "github_repo": "acme/widgets", "ship": "pr",
  "budget_daily_cents": 2000 }'
```

- **In:** every `O_GH_POLL_S` O imports open issues labelled `O_GH_LABEL`
  (default `o`) as `origin: "github"` work items, each exactly once.
- **Out (`ship: "pr"`):** each issue branch forks from `origin/<base>`. Once it
  passes `verify_cmd` (and the review gate, if on), O pushes it and opens a PR
  (`Closes #n` for imported issues). The repo's own CI is the merge gate: all
  checks green means `gh pr merge`. A failing check (`red_ci`) or a conflict
  goes back to the agent, and its next push updates the same PR. If GitHub
  refuses the merge (required reviews, say), the issue parks in **In Review**
  with the PR open for a human.
- `ship: "merge"` (the default) keeps the local serialized merge, with
  post-merge verify and auto-revert.

## Feedback widget

`feedback/o-feedback.js` is a dependency-free annotation layer for your dev app.
Toggle it (Alt+Shift+A), click any element, type what should change, batch a few,
send — O files a single `origin='feedback'` issue the loop picks up like any
other work item.

```html
<script
  src="/o-feedback.js"
  data-endpoint="http://127.0.0.1:4100"
  data-company="co_XXXXXXXX"></script>
```

Endpoint contract:

```
POST {endpoint}/api/companies/{company}/feedback
{
  "page_url": "http://localhost:3000/dashboard",   // required, 400 if missing
  "annotations": [                                   // required, non-empty, 400 if empty
    { "selector": "#hero > h1", "html": "<h1>…</h1>",
      "styles": { "color": "rgb(0,0,0)" },
      "instruction": "make the heading bigger" }
  ]
}
```

`201` returns the created issue (`origin: "feedback"`, one `### Annotation N`
section per annotation in the body). Filed outside the self-file cap, so operator
feedback is never dropped. Full docs: [`feedback/README.md`](feedback/README.md).

## Runtimes

An agent does real work through a pluggable runtime, chosen per agent:

| runtime | what it is |
|---|---|
| `claude-code` | headless `claude -p` in the worktree (default). |
| `swarm-code` | the swarm-code agent, run in the worktree. |
| `sim` | a deterministic, no-token stub — drives the pipeline in tests. |

## Issue lifecycle

```
Backlog ─▶ In Progress ─▶ Verifying ─▶ Done        (ship=pr: ─▶ In Review when GitHub wants a human)
                │              │
                │              ├─▶ Failed     (verify red, attempts exhausted)
                │              └─▶ Reverted   (regressed the base after merge)
                └──────────────── Canceled    (operator)
```

Every transition and decision is written to an append-only activity log
(`GET /api/activity`). Verbs include: `run.dispatch`, `run.succeeded`,
`run.failed`, `run.failed_final`, `run.stalled`, `verify.start`, `verify.pass`,
`verify.fail`, `merge.queued`, `merge.done`, `merge.revert`, `merge.conflict`,
`merge.dirty`, `selffile.created`, `selffile.duped`, `selffile.capped`,
`selffile.skipped_depth`, `budget.reset`, `budget.exceeded`, `budget.no_signal`,
`reflect.spawn`, `reflect.filed`, `reflect.done`, `feedback.filed`,
`issue.create`, `issue.update`, `agent.hire`, `company.create`.

## Environment

The daemon reads its configuration from the environment. All are optional.

| variable | default | meaning |
|---|---|---|
| `O_DB` | `~/.o/o.db` | control-plane SQLite path. |
| `O_PORT` | `4100` | HTTP port. |
| `O_CLAUDE_BIN` | `claude` on `PATH` | claude-code binary for the `claude-code` runtime. |
| `O_SWARM_BIN` | `swarm-code` on `PATH` | binary for the `swarm-code` runtime. |
| `O_MAX_TURNS` | `50` | per-run turn cap passed to claude-code. |
| `O_VERIFY_TIMEOUT_S` | `600` | wall-clock cap on a single verify command. |
| `O_GLOBAL_DAILY_CENTS` | unset | global daily spend ceiling across all companies; dispatch stops for the day when met. |
| `O_SELF_FILE_CAP` | `10` | max auto/reflect issues one company may file per day. |
| `O_NO_SIGNAL_DAYS` | `2` | consecutive no-signal days before the breaker pauses a company. |
| `O_SWARM_FLAT_CENTS` | `25` | flat per-run cost charged for a swarm-code run (it reports no telemetry yet). |
| `O_REFLECT` | unset | set `1` to enable the daily reflection pass. |
| `O_REQUIRE_APPROVALS` | unset | set `1` to route agent hiring through `/api/approvals`. |
| `O_API_TOKEN` | unset | when set, company / agent / approval writes need `Authorization: Bearer <token>`. The UI reads `VITE_O_TOKEN`, the MCP server `O_API_TOKEN`. |
| `O_TIMEOUT_FLAT_CENTS` | `300` | cost charged for an agent run killed on its wall-clock cap. |
| `O_REVIEW` | unset | set `1` to require a reviewer model's APPROVE before any green change merges. |
| `O_REVIEW_MODEL` | claude default | model for the reviewer (e.g. a stronger one than the builder). |
| `O_GH_BIN` | `gh` on `PATH` | GitHub CLI used for issue import and PRs. |
| `O_GH_LABEL` | `o` | only open GitHub issues with this label are imported. |
| `O_GH_POLL_S` | `60` | GitHub issue poll interval. |
| `O_CI_POLL_S` / `O_CI_TIMEOUT_S` | `30` / `3600` | PR check poll interval / give-up deadline (`red_timeout`). |
| `O_CI_SETTLE_S` | `30` | how long a PR with no checks reported waits before counting as "no CI, green". |
| `O_SANDBOX` | unset | `bwrap` confines agent + reviewer runs with bubblewrap (Linux). |
| `O_SANDBOX_RW` | unset | extra comma-separated paths the sandbox keeps writable, if your agent CLI needs them. |
| `O_VERIFY_RERUNS` | `1` | post-merge verify re-runs before a red result counts as a regression. |

## API

```sh
curl http://localhost:4100/api/health
curl http://localhost:4100/api/companies
curl -X POST http://localhost:4100/api/companies \
  -d '{"name":"Core","issue_prefix":"COR","repo":"/path/to/repo",
       "verify_cmd":"make test","protected_paths":"ci/,scripts/",
       "budget_daily_cents":5000,"budget_monthly_cents":100000}'
curl -X POST http://localhost:4100/api/companies/<id>/agents \
  -d '{"name":"Maintainer","runtime":"claude-code","repo":"/path/to/repo"}'
curl -X POST http://localhost:4100/api/companies/<id>/issues \
  -d '{"title":"first task","priority":"high"}'

curl http://localhost:4100/api/orchestrator   # live scheduler snapshot
curl http://localhost:4100/api/runs           # run history
curl http://localhost:4100/api/activity       # activity log
```

## Known limitations

- **Single-node.** One daemon, one SQLite control plane, one machine. There is no
  clustering and no multi-writer coordination.
- **Without `O_SANDBOX` the machine is the trust boundary.** Agents run with
  `--dangerously-skip-permissions`, so they can run arbitrary commands as your
  user. Protected paths and the verify gate constrain what *merges*, not what an
  agent may *do* while working. Turn on `O_SANDBOX=bwrap` on Linux. Even then
  network access stays open (the agent needs the model API), and macOS has no
  sandbox backend yet.
- **The API token needs the sandbox to be airtight.** Unsandboxed agents run as
  your user and could read the token out of the daemon's environment. With
  `O_SANDBOX=bwrap` they can't. Either way, bind the API to localhost.
- **swarm-code cost is estimated.** swarm-code emits no usage telemetry yet, so
  its runs are metered at a flat per-run estimate (`O_SWARM_FLAT_CENTS`) rather
  than true token cost.

## Built on swarmrt

O is written in the `sw` language and runs on the swarmrt runtime —
<https://github.com/skyblanket/swarmrt>.

## License

MIT — see [LICENSE](LICENSE).
