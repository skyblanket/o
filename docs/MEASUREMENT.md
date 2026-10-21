# Measuring O: tuning, then a frozen run

O maintains [skyblanket/swarmrt](https://github.com/skyblanket/swarmrt) in public, and both repos' full histories are open. To keep the numbers honest, O's history is split into two phases. Only the second phase produces results.

## Phase 1: tuning (now)

O is still being built. Restarts, prompt and policy changes, defects and repeated attempts are expected and visible. Everything is still recorded (merges, reverts, attempts per issue, cost), so trends show and the bar below can be set from data. **No tuning-phase number is presented as a result.**

Done so far in tuning:

| Fix | Where |
|---|---|
| Merges made while `shell()` could report a failed command as exit 0 were re-verified: `main` passes in full with plain bash | [swarmrt#137](https://github.com/skyblanket/swarmrt/issues/137#issuecomment-6317690734) |
| One PR per issue across rounds; at most 3 rounds, then O stops and posts what it tried | [o#54](https://github.com/skyblanket/o/pull/54) |
| Post-merge check: bisect and auto-revert any merge that breaks `main` | [o#55](https://github.com/skyblanket/o/pull/55) |
| Gate hard rules: no deleted tests, no CI/gate-config edits, at most 1500 changed lines | [o#55](https://github.com/skyblanket/o/pull/55) |
| Retry a failed issue on a stronger model; `GET /api/proof` | [o#53](https://github.com/skyblanket/o/pull/53) |

Still to do in tuning:
- O makes the final call on every tier, including runtime (swarmrt's `.o-review.json`).
- O plans its own work instead of waiting for issues a person labels `o`.
- O merges and authors as its own GitHub identity (an App), so "merged by O" shows on GitHub as well as on the dashboard. O's branches are already `o/…`; manual sessions use `claude/…`.
- Fix stale public claims in swarmrt's docs ([swarmrt#171](https://github.com/skyblanket/swarmrt/issues/171)).

## Exit bar: when tuning ends

Tuning ends when **all** of these hold:

- [ ] 7 consecutive days with no restarts and no code, prompt or policy changes to O
- [ ] 0 escaped defects in those 7 days
- [ ] Merged by O with no human: **≥ 70%** of resolved issues
- [ ] Cost per resolved issue: **≤ $3**
- [ ] Builder attempts per resolved issue: **≤ 2**
- [ ] Target start of measurement: **around 18 Nov 2026**

Where O stood at the start of tuning (all time, 21 Oct 2026): 27% merged with no human, about $4.12 per resolved issue, about 7.7 builder runs per resolved issue, 1 escaped defect in 43 merges.

If the bar isn't met by the target date, the blockers are written up here instead of tuning indefinitely.

## Phase 2: measurement

- Freeze an O version and tag it in **both** repos (`o-v1-measurement-start`), with a README note: "O v1 measurement run starts here."
- No changes to O during the run. If a change is unavoidable: stop, tag the end, write down why, and restart the count with a new tag.
- Counted from day 1 of the tag only:
  - merges: by O alone vs. approved by a human
  - escaped defects: a merged change later reverted, or a bug traced to it within 14 days; all counted, none hidden
  - automatic reverts (O's post-merge check)
  - attempts and cost per resolved issue
  - human minutes per merge
  - operator interventions, and how many were caused by runtime bugs
  - cross-family reviewer disagreement rate (once a second model family reviews)
  - results of a weekly random audit sample
- Published on a dashboard linked from both READMEs. `GET /api/proof` serves the raw counts from O's activity log.

## Labels for the public history

- Everything before the measurement tag is **tuning**: how O was built, mistakes included.
- Everything after is **measured results**: the only numbers used in claims.
- When something in tuning looks bad (an escaped defect, repeated PRs), it is written up with what was learned and how it was fixed.
