import { useState, useEffect, useCallback, useRef, useMemo, type ReactNode } from "react";
import {
  api, money, ago, dur, initials,
  type Company, type Issue, type Agent, type Run, type Activity, type Orchestrator, type Message,
  type Persona, type PersonaRun, type PersonaReport,
  type IssueEvent, type BoardRow, type SpendView, type GateInfo,
} from "./api";

const LANES = ["Backlog", "In Progress", "Verifying", "In Review", "Done", "Failed"];

// An issue lives in the Failed lane whether it truly Failed or was Reverted
// off main; the "reverted" case gets its own chip on the card.
const laneOf = (status: string) => (status === "Reverted" ? "Failed" : status);

// where the loop got this issue from — operator issues show nothing.
const ORIGIN_CHIP: Record<string, string> = {
  auto: "⚙ auto", reflect: "🪞 reflect", feedback: "🎯 feedback", persona: "🧑 persona",
};

// verify_state (STRING from the DB) → a semantic color class for a chip.
// green | red_* | conflict | reverted | "".
const verifyClass = (vs: string) =>
  vs === "green" ? "green"
  : vs === "conflict" ? "conflict"
  : vs === "reverted" ? "reverted"
  : vs.startsWith("red") ? "red"
  : "none";

// ---- generic modal -------------------------------------------------
function Modal(props: {
  title: string; wide?: boolean; onClose: () => void;
  children: ReactNode; footer?: ReactNode;
}) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === "Escape") props.onClose(); };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [props]);
  return (
    <div className="backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) props.onClose(); }}>
      <div className={"modal" + (props.wide ? " wide" : "")}>
        <header>
          <span className="h">{props.title}</span>
          <button className="ghost icon" onClick={props.onClose}>✕</button>
        </header>
        <div className="mbody">{props.children}</div>
        {props.footer && <footer>{props.footer}</footer>}
      </div>
    </div>
  );
}

function Field(props: { label: string; children: ReactNode }) {
  return <label className="field"><span>{props.label}</span>{props.children}</label>;
}

// ---- create / manage modals ---------------------------------------
function NewCompany({ onClose, done }: { onClose: () => void; done: () => void }) {
  const [name, setName] = useState(""), [mission, setMission] = useState("");
  const [prefix, setPrefix] = useState("TASK"), [budget, setBudget] = useState("");
  const [daily, setDaily] = useState("");
  const [repo, setRepo] = useState(""), [verifyCmd, setVerifyCmd] = useState("");
  const [protectedPaths, setProtectedPaths] = useState("");
  const [picking, setPicking] = useState(false);
  const save = async () => {
    if (!name.trim()) return;
    await api.createCompany({
      name: name.trim(), mission: mission.trim(),
      issue_prefix: prefix.trim() || "TASK",
      budget_monthly_cents: Math.round((parseFloat(budget) || 0) * 100),
      budget_daily_cents: Math.round((parseFloat(daily) || 0) * 100),
      repo: repo.trim(), verify_cmd: verifyCmd.trim(),
      protected_paths: protectedPaths.trim(),
    });
    done();
  };
  return (
    <>
      <Modal title="New company" onClose={onClose}
        footer={<><button className="ghost" onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save}>Create company</button></>}>
        <Field label="Name"><input autoFocus value={name} onChange={e => setName(e.target.value)} placeholder="Acme Inc" /></Field>
        <Field label="Mission"><input value={mission} onChange={e => setMission(e.target.value)} placeholder="what this company is for" /></Field>
        <Field label="Repo (the codebase the loop maintains)">
          <div style={{ display: "flex", gap: 8 }}>
            <input value={repo} readOnly placeholder="(none) — empty workspace per issue" />
            <button type="button" onClick={() => setPicking(true)}>Browse…</button>
            {repo && <button type="button" className="ghost" onClick={() => setRepo("")}>clear</button>}
          </div>
        </Field>
        <div className="row3">
          <Field label="Verify command"><input value={verifyCmd} onChange={e => setVerifyCmd(e.target.value)} placeholder="make check" /></Field>
          <Field label="Protected paths"><input value={protectedPaths} onChange={e => setProtectedPaths(e.target.value)} placeholder="comma-sep, e.g. .github/,deploy/" /></Field>
        </div>
        <div className="row3">
          <Field label="Issue prefix"><input value={prefix} onChange={e => setPrefix(e.target.value)} /></Field>
          <Field label="Daily budget (USD)"><input type="number" value={daily} onChange={e => setDaily(e.target.value)} placeholder="0 = no daily cap" /></Field>
          <Field label="Monthly budget (USD)"><input type="number" value={budget} onChange={e => setBudget(e.target.value)} placeholder="0 = unlimited" /></Field>
        </div>
        <p className="hint">The verify command is the grounded gate — a change only merges when it exits 0. Protected paths can never be touched by an agent.</p>
      </Modal>
      {picking && <FolderPicker onClose={() => setPicking(false)} onPick={p => { setRepo(p); setPicking(false); }} />}
    </>
  );
}

function NewIssue({ cid, onClose, done }: { cid: string; onClose: () => void; done: () => void }) {
  const [title, setTitle] = useState(""), [body, setBody] = useState(""), [prio, setPrio] = useState("medium");
  const save = async () => {
    if (!title.trim()) return;
    await api.createIssue(cid, { title: title.trim(), body: body.trim(), priority: prio });
    done();
  };
  return (
    <Modal title="New issue" onClose={onClose}
      footer={<><button className="ghost" onClick={onClose}>Cancel</button>
        <button className="primary" onClick={save}>File issue</button></>}>
      <Field label="Title"><input autoFocus value={title} onChange={e => setTitle(e.target.value)} placeholder="what needs doing" /></Field>
      <Field label="Details for the agent"><textarea value={body} onChange={e => setBody(e.target.value)} placeholder="context, acceptance criteria, files to touch..." /></Field>
      <Field label="Priority">
        <select value={prio} onChange={e => setPrio(e.target.value)}>
          <option value="high">high</option><option value="medium">medium</option><option value="low">low</option>
        </select>
      </Field>
    </Modal>
  );
}

// pick a folder by browsing the daemon's filesystem — no typed paths
function FolderPicker({ onPick, onClose }: { onPick: (p: string) => void; onClose: () => void }) {
  const [cwd, setCwd] = useState("");
  const [parent, setParent] = useState("");
  const [dirs, setDirs] = useState<string[]>([]);
  const [gits, setGits] = useState<Set<string>>(new Set());
  const load = (p: string) => {
    api.fs(p).then(r => {
      setCwd(r.path); setParent(r.parent);
      setDirs((r.listing || "").split("\n").filter(l => l.endsWith("/")).map(l => l.slice(0, -1)).sort());
      const g = new Set<string>();
      (r.gits || "").split("\n").filter(Boolean).forEach(line => {
        const parts = line.split("/");
        if (parts.length >= 2) g.add(parts[parts.length - 2]);
      });
      setGits(g);
    }).catch(() => {});
  };
  useEffect(() => { load(""); }, []);
  const into = (d: string) => load((cwd.endsWith("/") ? cwd : cwd + "/") + d);
  return (
    <Modal title="Pick a folder" onClose={onClose}
      footer={<><button className="ghost" onClick={onClose}>Cancel</button>
        <button className="primary" onClick={() => onPick(cwd)}>Use this folder</button></>}>
      <div className="box mono" style={{ marginBottom: 10 }}>{cwd || "…"}</div>
      <div className="fslist">
        {parent && parent !== cwd &&
          <div className="fsrow" onClick={() => load(parent)}><span style={{ color: "var(--dim)" }}>↑ ..</span></div>}
        {dirs.length === 0 && <div className="hint" style={{ padding: "12px 4px" }}>No sub-folders here.</div>}
        {dirs.map(d => (
          <div className="fsrow" key={d} onClick={() => into(d)}>
            <span>📁 {d}</span>
            {gits.has(d) && <span className="rtag cc" style={{ marginLeft: "auto" }}>git repo</span>}
          </div>
        ))}
      </div>
    </Modal>
  );
}

function HireAgent({ cid, onClose, done }: { cid: string; onClose: () => void; done: () => void }) {
  const [name, setName] = useState(""), [role, setRole] = useState("engineer");
  const [runtime, setRuntime] = useState("claude-code"), [repo, setRepo] = useState("");
  const [picking, setPicking] = useState(false);
  const save = async () => {
    if (!name.trim()) return;
    await api.hireAgent(cid, { name: name.trim(), role: role.trim() || "generalist", runtime, repo: repo.trim() });
    done();
  };
  return (
    <>
      <Modal title="Hire an agent" onClose={onClose}
        footer={<><button className="ghost" onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save}>Hire</button></>}>
        <div className="row3">
          <Field label="Name"><input autoFocus value={name} onChange={e => setName(e.target.value)} placeholder="Ada" /></Field>
          <Field label="Role"><input value={role} onChange={e => setRole(e.target.value)} /></Field>
        </div>
        <Field label="Runtime">
          <select value={runtime} onChange={e => setRuntime(e.target.value)}>
            <option value="claude-code">claude-code — real headless Claude</option>
            <option value="swarm-code">swarm-code — Kimi/sw coding agent</option>
            <option value="sim">sim — deterministic stub (no spend)</option>
          </select>
        </Field>
        <Field label="Repo (optional — for claude-code dev agents)">
          <div style={{ display: "flex", gap: 8 }}>
            <input value={repo} readOnly placeholder="(none) — empty workspace per issue" />
            <button type="button" onClick={() => setPicking(true)}>Browse…</button>
            {repo && <button type="button" className="ghost" onClick={() => setRepo("")}>clear</button>}
          </div>
        </Field>
        <p className="hint">Pick the folder — no typing, no typos. A claude-code agent with a repo works each issue in an isolated git worktree on branch <code>o/&lt;issue&gt;</code>.</p>
      </Modal>
      {picking && <FolderPicker onClose={() => setPicking(false)} onPick={p => { setRepo(p); setPicking(false); }} />}
    </>
  );
}

function Manage({ company, onClose, done }: { company: Company; onClose: () => void; done: () => void }) {
  const [budget, setBudget] = useState(String((company.budget_monthly_cents / 100) || 0));
  const [daily, setDaily] = useState(String((company.budget_daily_cents / 100) || 0));
  const [status, setStatus] = useState(company.status);
  const [repo, setRepo] = useState(company.repo || "");
  const [verifyCmd, setVerifyCmd] = useState(company.verify_cmd || "");
  const [protectedPaths, setProtectedPaths] = useState(company.protected_paths || "");
  const [ghRepo, setGhRepo] = useState(company.github_repo || "");
  const [ship, setShip] = useState(company.ship || "merge");
  const [err, setErr] = useState("");
  const [gate, setGate] = useState<GateInfo | null>(null);
  const [picking, setPicking] = useState(false);
  useEffect(() => { api.gate(company.id).then(setGate).catch(() => {}); }, [company.id]);
  const save = async () => {
    setErr("");
    try {
      await api.updateCompany(company.id, {
        budget_monthly_cents: Math.round((parseFloat(budget) || 0) * 100),
        budget_daily_cents: Math.round((parseFloat(daily) || 0) * 100),
        status, repo: repo.trim(), verify_cmd: verifyCmd.trim(),
        protected_paths: protectedPaths.trim(),
        github_repo: ghRepo.trim(), ship,
      });
      done();
    } catch (e) {
      setErr(ship === "pr" && !ghRepo.includes("/")
        ? "PR mode needs a GitHub repo as owner/name."
        : "The daemon refused this change (" + String((e as Error).message) + ").");
    }
  };
  return (
    <>
      <Modal title={"Manage " + company.name} onClose={onClose}
        footer={<><button className="ghost" onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save}>Save</button></>}>
        <Field label="Repo (the codebase the loop maintains)">
          <div style={{ display: "flex", gap: 8 }}>
            <input value={repo} readOnly placeholder="(none) — empty workspace per issue" />
            <button type="button" onClick={() => setPicking(true)}>Browse…</button>
            {repo && <button type="button" className="ghost" onClick={() => setRepo("")}>clear</button>}
          </div>
        </Field>
        <div className="row3">
          <Field label="Verify command"><input value={verifyCmd} onChange={e => setVerifyCmd(e.target.value)} placeholder="make check" /></Field>
          <Field label="Protected paths"><input value={protectedPaths} onChange={e => setProtectedPaths(e.target.value)} placeholder="comma-sep, e.g. .github/,deploy/" /></Field>
        </div>
        <div className="row3">
          <Field label="Daily budget (USD)"><input type="number" value={daily} onChange={e => setDaily(e.target.value)} /></Field>
          <Field label="Monthly budget (USD)"><input type="number" value={budget} onChange={e => setBudget(e.target.value)} /></Field>
          <Field label="Status">
            <select value={status} onChange={e => setStatus(e.target.value)}>
              <option value="active">active</option><option value="paused">paused</option>
            </select>
          </Field>
        </div>
        <p className="hint">Set status to <b>active</b> to resume a company that was budget- or no-signal-paused.</p>
        <div className="row3">
          <Field label="GitHub repo (owner/name)"><input value={ghRepo} onChange={e => setGhRepo(e.target.value)} placeholder="acme/widgets" /></Field>
          <Field label="Ship">
            <select value={ship} onChange={e => setShip(e.target.value)}>
              <option value="merge">merge (local branch merge)</option><option value="pr">pr (GitHub PR + gate)</option>
            </select>
          </Field>
        </div>
        {err && <div className="warn">{err}</div>}
        {gate && <GatePanel cid={company.id} g={gate} onRotated={setGate} />}
      </Modal>
      {picking && <FolderPicker onClose={() => setPicking(false)} onPick={p => { setRepo(p); setPicking(false); }} />}
    </>
  );
}

// The merge gate as the daemon sees it: .o-review.json on base, read-only (o#8)
function GatePanel({ cid, g, onRotated }: { cid: string; g: GateInfo; onRotated: (g: GateInfo) => void }) {
  type Tier = { name?: string; paths?: string[]; merge?: string; gate_model?: string; focus?: string[]; extra?: string[] };
  const cfg = g.config as { build?: string; suite?: string; required_checks?: string[]; test_runners?: { paths?: string[] }[]; tiers?: Tier[] };
  const tiers: Tier[] = Array.isArray(cfg.tiers) ? cfg.tiers : [];
  return (
    <div className="gatepanel">
      <h4 className="sec">Merge gate {g.merge_gate ? "· on" : "· off (O_MERGE_GATE)"}</h4>
      {!g.config_protected && g.ship === "pr" &&
        <div className="warn">.o-review.json isn't in protected paths: an agent could edit the gate's own config. Add it.</div>}
      {Object.keys(cfg).length === 0
        ? <div className="hint">No .o-review.json on the base branch.</div>
        : <div className="mono box">
            <div>build: {String(cfg.build || "—")}</div>
            <div>suite: {String(cfg.suite || "—")}</div>
            <div>required checks: {(cfg.required_checks || []).join(", ") || "—"}</div>
            <div>test runners: {(cfg.test_runners || []).map(t => (t.paths || []).join(",")).join("; ") || "—"}</div>
            {tiers.map((t, n) => <div key={n}>tier {t.name}: {(t.paths || []).join(", ")} · {t.merge || "auto"}{t.gate_model ? " · gate " + t.gate_model : ""}{t.focus ? " · focus " + t.focus.join("/") : ""}{t.extra ? " · extra: " + t.extra.join("; ") : ""}</div>)}
          </div>}
      <div className="runrow">
        <span>maintainer session: <code>{g.maintainer_session ? g.maintainer_session.slice(0, 12) : "none"}</code> · {g.maintainer_reviews || 0} reviews</span>
        <button className="sm" style={{ marginLeft: "auto" }} onClick={() => api.rotateGate(cid).then(onRotated).catch(() => {})}>Rotate now</button>
      </div>
    </div>
  );
}

// ---- live agent activity (claude-code stream-json events) ----------
type AnyEvent = Record<string, unknown> & { type?: string };

function parseStream(raw: string): AnyEvent[] {
  if (!raw) return [];
  const out: AnyEvent[] = [];
  for (const line of raw.split("\n")) {
    if (!line) continue;
    try { out.push(JSON.parse(line) as AnyEvent); } catch { /* partial / malformed line — skip */ }
  }
  return out;
}

function Activity({ e }: { e: AnyEvent }) {
  const t = e.type;
  if (t === "system") {
    if (e.subtype === "init") return <div className="evt sys">▶ started · {String(e.model || "")}</div>;
    return null;
  }
  if (t === "assistant") {
    const blocks: any[] = ((e.message as any) || {}).content || [];
    return <>{blocks.map((b, i) => {
      if (b.type === "text") return <div key={i} className="evt text">{b.text}</div>;
      if (b.type === "tool_use") {
        const args = typeof b.input === "object" ? JSON.stringify(b.input) : String(b.input || "");
        return <div key={i} className="evt tool">🔧 <b>{b.name}</b> <span className="mono">{args.slice(0, 200)}{args.length > 200 ? "…" : ""}</span></div>;
      }
      if (b.type === "thinking") return <div key={i} className="evt sys">💭 thinking…</div>;
      return null;
    })}</>;
  }
  if (t === "user") {
    const blocks: any[] = ((e.message as any) || {}).content || [];
    return <>{blocks.map((b, i) => {
      if (b.type === "tool_result") {
        const txt = typeof b.content === "string" ? b.content
          : Array.isArray(b.content) ? b.content.map((c: any) => c.text || "").join("")
          : JSON.stringify(b.content);
        return <div key={i} className="evt tres">↳ <span className="mono">{txt.slice(0, 240)}{txt.length > 240 ? "…" : ""}</span></div>;
      }
      return null;
    })}</>;
  }
  if (t === "result") {
    const usd = (e.total_cost_usd as number) || 0;
    return <div className="evt done">✓ done · ${usd.toFixed(4)}</div>;
  }
  return null;
}

// ---- an issue's pipeline, one row per attempt (o#5) -----------------
// Each step's state comes from the activity verbs logged inside that attempt's
// time window (from its run's start to the next run's start).
const STEPS: { k: string; label: string; start: string[]; ok: string[]; red: string[]; wait?: string[] }[] = [
  { k: "agent", label: "agent", start: ["run.dispatch", "run.resume"], ok: ["run.succeeded", "verify.start"], red: ["run.failed", "run.stalled", "run.needs_human"] },
  { k: "verify", label: "verify", start: ["verify.start"], ok: ["verify.pass", "verify.flaky", "verify.inherited"], red: ["verify.fail"] },
  { k: "review", label: "review", start: ["review.start"], ok: ["review.pass"], red: ["review.reject"] },
  { k: "ci", label: "PR + CI", start: ["ci.start"], ok: ["gate.start", "ci.awaiting_review"], red: ["ci.fail"] },
  { k: "gate", label: "merge gate", start: ["gate.start"], ok: ["gate.approve"], red: ["gate.reject"], wait: ["gate.human", "gate.unverified", "shadow.park"] },
  { k: "merge", label: "merge", start: ["merge.queued"], ok: ["ci.merged", "merge.done", "pr.merged"], red: ["merge.conflict", "merge.revert"] },
];

function Pipeline({ issue, runs }: { issue: Issue; runs: Run[] }) {
  const [evs, setEvs] = useState<IssueEvent[]>([]);
  const live = runs.some(r => r.state === "Running" || r.state === "Verifying");
  useEffect(() => {
    let off = false;
    const load = () => api.issueActivity(issue.id).then(e => { if (!off) setEvs(e); }).catch(() => {});
    load();
    const t = live ? setInterval(load, 2000) : undefined;
    return () => { off = true; if (t) clearInterval(t); };
  }, [issue.id, live]);
  if (runs.length === 0) return null;
  const ordered = [...runs].sort((a, b) => a.started_at - b.started_at);
  return <>
    <h4 className="sec">Pipeline</h4>
    <div className="pipe">
      {ordered.map((r, n) => {
        const end = n + 1 < ordered.length ? ordered[n + 1].started_at : Infinity;
        const mine = evs.filter(e => e.ts >= r.started_at - 1000 && e.ts < end);
        const at = (vs: string[]) => mine.find(e => vs.includes(e.verb))?.ts;
        return (
          <div className="pipe-row" key={r.id}>
            <span className="pipe-n">#{r.attempt}</span>
            {STEPS.map(s => {
              const t0 = at(s.start), tr = at(s.red), tok = at(s.ok), tw = s.wait ? at(s.wait) : undefined;
              const st = tr ? "red" : tok ? "done" : tw ? "wait" : t0 ? "running" : "skip";
              const t1 = tr || tok || tw;
              return (
                <span key={s.k} className={"pstep " + st}
                  title={st === "red" ? (r.verify_state || s.label + " failed") : st}>
                  {s.label}{t0 && t1 ? <em>{dur(t0, t1)}</em> : null}
                </span>
              );
            })}
            <span className={"vchip " + verifyClass(r.verify_state || "")} style={{ marginLeft: "auto" }}>{r.verify_state || r.state}</span>
          </div>
        );
      })}
    </div>
  </>;
}

// ---- issue detail (editable + live agent activity) ----------------
function IssueModal({ issue, agents, runs, onClose, done }: {
  issue: Issue; agents: Agent[]; runs: Run[]; onClose: () => void; done: () => void;
}) {
  const [status, setStatus] = useState(issue.status);
  const [assignee, setAssignee] = useState(issue.assignee_agent_id || "");
  const [prio, setPrio] = useState(issue.priority || "medium");
  const [streamRaw, setStreamRaw] = useState<string>("");
  const [errlog, setErrlog] = useState<string>("");
  const [vstate, setVstate] = useState<string>("");
  const [voutput, setVoutput] = useState<string>("");
  const [mergeSha, setMergeSha] = useState<string>("");
  const mine = runs.filter(r => r.issue_id === issue.id);
  const last = mine[0];

  useEffect(() => {
    if (!last) return;
    let cancelled = false;
    const fetchOnce = () => api.runResult(last.id).then(r => {
      if (cancelled) return;
      setStreamRaw(r.stream || r.result || "");
      setErrlog(r.error || "");
      setVstate(r.verify_state || "");
      setVoutput(r.verify_output || "");
      setMergeSha(r.merge_sha || "");
    }).catch(() => {});
    fetchOnce();
    if (last.state === "Running" || last.state === "Verifying") {
      const t = setInterval(fetchOnce, 1500);
      return () => { cancelled = true; clearInterval(t); };
    }
    return () => { cancelled = true; };
  }, [last?.id, last?.state]); // eslint-disable-line react-hooks/exhaustive-deps

  const events = useMemo(() => parseStream(streamRaw), [streamRaw]);
  const finalEvent = events.find(e => e.type === "result") as any;
  const summary: string = (finalEvent && finalEvent.result) || "";

  const save = async () => {
    await api.updateIssue(issue.id, { status, priority: prio, assignee_agent_id: assignee });
    done();
  };
  return (
    <Modal title={issue.identifier} wide onClose={onClose}
      footer={<><button className="ghost" onClick={onClose}>Close</button>
        <button className="primary" onClick={save}>Save changes</button></>}>
      <div style={{ fontSize: 16, fontWeight: 600, marginBottom: 13 }}>{issue.title}</div>
      <div className="row3">
        <Field label="Status">
          <select value={status} onChange={e => setStatus(e.target.value)}>
            {["Backlog", "In Progress", "Verifying", "Done", "Failed", "Reverted", "Canceled"].map(s => <option key={s}>{s}</option>)}
          </select>
        </Field>
        <Field label="Assignee">
          <select value={assignee} onChange={e => setAssignee(e.target.value)}>
            <option value="">— unassigned —</option>
            {agents.map(a => <option key={a.id} value={a.id}>{a.name} · {a.runtime}</option>)}
          </select>
        </Field>
        <Field label="Priority">
          <select value={prio} onChange={e => setPrio(e.target.value)}>
            {["high", "medium", "low"].map(s => <option key={s}>{s}</option>)}
          </select>
        </Field>
      </div>
      {issue.body
        ? <div className="box">{issue.body}</div>
        : <div className="hint">No details provided.</div>}
      <Pipeline issue={issue} runs={mine} />
      <h4 className="sec">Runs ({mine.length})</h4>
      {mine.length ? mine.map(r => (
        <div className="runrow" key={r.id}>
          <span className={"st " + r.state}>{r.state}</span>
          <span style={{ color: "var(--faint)" }}>attempt {r.attempt}</span>
          <span style={{ color: "var(--dim)" }}>{dur(r.started_at, r.ended_at)}</span>
          <span style={{ marginLeft: "auto", color: "var(--dim)" }}>{r.cost_cents ? money(r.cost_cents) : ""}</span>
        </div>
      )) : <div className="hint">Not run yet — the orchestrator will pick it up.</div>}

      {(() => {
        const evs = vstate || (last?.verify_state || "");
        const sha = mergeSha || (last?.merge_sha || "");
        if (!evs) return null;
        const merged = evs === "green" && sha.length > 0;
        return <>
          <h4 className="sec">Verification</h4>
          <div className="runrow">
            <span className={"vchip " + verifyClass(evs)}>{evs}</span>
            {merged
              ? <span style={{ color: "var(--green)" }}>merged as <code>{sha.slice(0, 8)}</code></span>
              : evs === "reverted"
                ? <span style={{ color: "var(--red)" }}>reverted — branch kept</span>
                : null}
          </div>
          {voutput.length > 0 &&
            <pre className="vout">{voutput.slice(-4000)}</pre>}
        </>;
      })()}

      {events.length > 0 && <>
        <h4 className="sec">Agent activity {(last?.state === "Running" || last?.state === "Verifying") && <span style={{ color: "var(--green)", marginLeft: 6 }}>· live</span>}</h4>
        <div className="activity">
          {events.map((e, i) => <Activity key={i} e={e} />)}
        </div>
      </>}
      {summary.length > 0 && <>
        <h4 className="sec">Final result</h4>
        <div className="box">{summary}</div>
      </>}
      {errlog.length > 0 && <>
        <h4 className="sec" style={{ color: "var(--red)" }}>Error log</h4>
        <div className="box mono" style={{ color: "var(--red)" }}>{errlog.slice(0, 2000)}</div>
      </>}
    </Modal>
  );
}

// ---- chat with a hired agent --------------------------------------
function AgentChat({ agent, onClose }: { agent: Agent; onClose: () => void }) {
  const [msgs, setMsgs] = useState<Message[]>([]);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);
  const load = () => api.agentMessages(agent.id).then(setMsgs).catch(() => {});
  useEffect(() => {
    load();
    const t = setInterval(load, 2000);
    return () => clearInterval(t);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [msgs.length]);
  const send = async () => {
    const m = text.trim();
    if (!m || sending) return;
    setText(""); setSending(true);
    await api.agentChat(agent.id, m).catch(() => {});
    setSending(false);
    load();
  };
  const thinking = msgs.length > 0 && msgs[msgs.length - 1].role === "operator";
  return (
    <Modal title={"Chat · " + agent.name} wide onClose={onClose}>
      <div className="chat">
        {msgs.length === 0 &&
          <div className="hint" style={{ margin: "auto", textAlign: "center" }}>
            Say something to {agent.name} — it answers from its own persistent session.</div>}
        {msgs.map(m => (
          <div key={m.id} className={"msg " + (m.role === "operator" ? "me" : "them")}>{m.content}</div>
        ))}
        {thinking && <div className="msg them think">{agent.name} is working…</div>}
        <div ref={endRef} />
      </div>
      <div className="chatbar">
        <textarea value={text} onChange={e => setText(e.target.value)} rows={2}
          placeholder={"Message " + agent.name + "…  (Enter to send)"}
          onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }} />
        <button className="primary" onClick={send} disabled={sending}>Send</button>
      </div>
    </Modal>
  );
}

// ---- panels --------------------------------------------------------
function TopBar({ orch, offline }: { orch: Orchestrator | null; offline: boolean }) {
  return (
    <div className="top">
      <span className="brand">◯ O<span className="v">v4</span></span>
      <span className="sub">agent-company orchestrator</span>
      <div className="stats">
        {offline && <span className="offline">⚠ daemon offline — start swarmd</span>}
        <div className="stat"><b>{orch?.tick ?? "–"}</b><span>tick</span></div>
        <div className="stat"><b>{orch?.running ?? "–"}</b><span>running</span></div>
        <div className="stat"><b>{orch?.retrying ?? "–"}</b><span>retry</span></div>
        <div className="stat"><span className="live" /></div>
      </div>
    </div>
  );
}

function Sidebar({ companies, selId, onSelect, onNew }: {
  companies: Company[]; selId: string | null;
  onSelect: (id: string) => void; onNew: () => void;
}) {
  return (
    <div className="side">
      <div className="panhead">
        <span className="lbl">Companies</span>
        <button className="icon" onClick={onNew} title="New company">+</button>
      </div>
      <div className="colist">
        {companies.length === 0 && <div style={{ padding: "16px 12px", color: "var(--faint)", fontSize: 12 }}>No companies yet.</div>}
        {companies.map(c => {
          const pct = c.budget_monthly_cents > 0 ? Math.min(100, 100 * c.spent_cents / c.budget_monthly_cents) : 0;
          const over = c.budget_monthly_cents > 0 && c.spent_cents >= c.budget_monthly_cents;
          return (
            <div key={c.id} className={"co" + (c.id === selId ? " sel" : "")} onClick={() => onSelect(c.id)}>
              <div className="r1"><span className={"dot " + c.status} /><span className="nm">{c.name}</span></div>
              <div className="meta">{c.issue_prefix} · {money(c.spent_cents)}{c.budget_monthly_cents > 0 ? " / " + money(c.budget_monthly_cents) : ""}</div>
              {c.budget_monthly_cents > 0 && <div className="bar"><i className={over ? "over" : ""} style={{ width: pct + "%" }} /></div>}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function Rail({ runs, activity }: { runs: Run[]; activity: Activity[] }) {
  return (
    <div className="rail">
      <div className="rsec">
        <span className="lbl">Activity</span>
        {activity.length === 0 && <div className="hint">Nothing yet.</div>}
        {activity.slice(0, 26).map(a => {
          const ok = /succeed|create|hire|approv/.test(a.verb);
          const bad = /fail|exceed|stall|reject/.test(a.verb);
          return (
            <div className="feed" key={a.id}>
              <span className={"vb" + (ok ? " ok" : bad ? " bad" : "")}>{a.verb}</span>
              <span className="by">{a.actor}</span>
              <span className="at">{ago(a.ts)}</span>
            </div>
          );
        })}
      </div>
      <div className="rsec">
        <span className="lbl">Recent runs</span>
        {runs.length === 0 && <div className="hint">No runs yet.</div>}
        {runs.slice(0, 16).map(r => (
          <div className="feed" key={r.id}>
            <span className={"st " + r.state}>{r.state}</span>
            <span className="by">attempt {r.attempt}</span>
            <span className="at" style={{ color: "var(--dim)" }}>{r.cost_cents ? money(r.cost_cents) : ""}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function CompanyView({ company, issues, agents, onIssue, onNewIssue, onHire, onManage, onAgentChat }: {
  company: Company; issues: Issue[]; agents: Agent[];
  onIssue: (id: string) => void; onNewIssue: () => void; onHire: () => void; onManage: () => void;
  onAgentChat: (id: string) => void;
}) {
  const over = company.budget_monthly_cents > 0 && company.spent_cents >= company.budget_monthly_cents;
  const hasDaily = company.budget_daily_cents > 0;
  const paused = company.status === "paused";
  const PAUSE_LABEL: Record<string, string> = {
    "budget-daily": "budget · daily", "budget-monthly": "budget · monthly", "no-signal": "no signal",
  };
  const pauseLabel = PAUSE_LABEL[company.pause_reason] || company.pause_reason;
  const [tab, setTab] = useState<"board" | "personas">("board");
  const [board, setBoard] = useState<Record<string, BoardRow>>({});
  const [spend, setSpend] = useState<SpendView | null>(null);
  useEffect(() => {
    let off = false;
    const load = () => {
      api.board(company.id).then(b => { if (!off) setBoard(Object.fromEntries(b.map(r => [r.id, r]))); }).catch(() => {});
      api.spend(company.id, 14).then(s => { if (!off) setSpend(s); }).catch(() => {});
    };
    load();
    const t = setInterval(load, 5000);
    return () => { off = true; clearInterval(t); };
  }, [company.id]);
  return (
    <div className="main">
      <div className="cohead">
        <div className="t">
          <div>
            <h1>{company.name}</h1>
            <div className="mission">{company.mission || "no mission set"}</div>
          </div>
          <span className={"badge " + company.status}>{company.status}</span>
          {paused && company.pause_reason &&
            <span className="badge paused" title="why this company is paused">⏸ {pauseLabel}</span>}
          {company.greens_today > 0 &&
            <span className="badge done" title="green (merged) verifications today">✓ {company.greens_today} today</span>}
          <div className="acts">
            <button className="primary sm" onClick={onNewIssue}>+ Issue</button>
            <button className="sm" onClick={onHire}>Hire agent</button>
            <button className="sm" onClick={onManage}>Manage</button>
          </div>
        </div>
        <div className="money">
          {hasDaily &&
            <div><div className="k">Today</div><div className="vv">{money(company.spent_today_cents)} <span style={{ color: "var(--faint)", fontWeight: 400 }}>/ {money(company.budget_daily_cents)}</span></div></div>}
          <div><div className="k">Spent{hasDaily ? " (mo)" : ""}</div><div className="vv">{money(company.spent_cents)}</div></div>
          <div><div className="k">Budget{hasDaily ? " (mo)" : ""}</div><div className="vv">{company.budget_monthly_cents > 0 ? money(company.budget_monthly_cents) : "—"}</div></div>
          <div><div className="k">Issues</div><div className="vv">{issues.length}</div></div>
          <div><div className="k">Agents</div><div className="vv">{agents.length}</div></div>
          {over && <div className="warn">⚠ budget cap reached — paused</div>}
        </div>
        {spend && <SpendBars s={spend} />}
      </div>
      <div className="tabs">
        <button className={tab === "board" ? "on" : ""} onClick={() => setTab("board")}>Board</button>
        <button className={tab === "personas" ? "on" : ""} onClick={() => setTab("personas")}>Personas</button>
      </div>
      {tab === "personas" ? <PersonasView company={company} issues={issues} onIssue={onIssue} /> : <>
      <div className="agents">
        {agents.length === 0
          ? <span style={{ color: "var(--faint)", fontSize: 12 }}>No agents yet — issues won't run until you hire one.</span>
          : agents.map(a => (
            <span className="chip" key={a.id} onClick={() => onAgentChat(a.id)}
              style={{ cursor: "pointer" }} title={"Chat with " + a.name}>
              <span className="av">{initials(a.name)}</span>{a.name}
              <span className={"rtag " + (a.runtime === "claude-code" ? "cc" : a.runtime)}>{a.runtime}</span>
              <span style={{ color: "var(--faint)", fontSize: 12 }}>💬</span>
            </span>
          ))}
      </div>
      <div className="board">
        {LANES.map(lane => {
          const items = issues.filter(i => laneOf(i.status) === lane);
          return (
            <div className="lane" key={lane}>
              <h3>{lane}<span className="ct">{items.length}</span></h3>
              <div className="cards">
                {items.map(i => {
                  const ag = agents.find(a => a.id === i.assignee_agent_id);
                  const origin = ORIGIN_CHIP[i.origin];
                  return (
                    <div key={i.id} className={"icard " + (i.priority || "medium")} onClick={() => onIssue(i.id)}>
                      <div className="id">
                        {i.identifier}
                        {i.status === "Reverted" && <span className="ochip reverted" style={{ marginLeft: 6 }}>reverted</span>}
                        {origin && <span className="ochip" style={{ marginLeft: 6 }}>{origin}</span>}
                      </div>
                      <div className="ti">{i.title}</div>
                      {board[i.id] && <CardPr row={board[i.id]} repo={company.github_repo} lane={lane} />}
                      <div className="ft">
                        <span className="pri">{i.priority || "medium"}</span>
                        {ag && <span className="av" style={{ marginLeft: "auto" }} title={ag.name}>{initials(ag.name)}</span>}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
      </>}
    </div>
  );
}

// PR chip, CI dot and gate chip on a card; In Review, why it waits (o#6)
function CardPr({ row, repo, lane }: { row: BoardRow; repo: string; lane: string }) {
  if (!row.pr && !row.gate && !row.waiting) return null;
  return <>
    <div className="prline" onClick={e => e.stopPropagation()}>
      {row.pr > 0 && (repo
        ? <a className="prchip" href={`https://github.com/${repo}/pull/${row.pr}`} target="_blank" rel="noreferrer">#{row.pr}</a>
        : <span className="prchip">#{row.pr}</span>)}
      {row.ci && <span className={"cidot " + row.ci} title={"CI " + row.ci} />}
      {row.gate && <span className={"gchip " + row.gate.toLowerCase()} title={row.gate_reason}>{row.gate}</span>}
    </div>
    {lane === "In Review" && row.waiting && <div className="waiting" title={row.waiting}>{row.waiting}</div>}
  </>;
}

// Spend by kind for the last 14 days, a bar per day (o#7)
const KINDS = ["agent", "reviewer", "gate", "planner", "reflect", "persona"];
function SpendBars({ s }: { s: SpendView }) {
  const today = s.today;
  const days = Array.from({ length: s.days }, (_, n) => today - s.days + 1 + n);
  const of = (d: number, k: string) => s.rows.find(r => r.day === d && r.kind === k)?.cents || 0;
  const tot = (d: number) => KINDS.reduce((a, k) => a + of(d, k), 0);
  const max = Math.max(1, ...days.map(tot));
  const week = (k: string) => days.slice(-7).reduce((a, d) => a + of(d, k), 0);
  return (
    <div className="spend">
      <div className="bars">
        {days.map(d => (
          <div className="bar" key={d} title={new Date(d * 86400000).toISOString().slice(0, 10) + " · " + money(tot(d))}>
            {KINDS.map(k => of(d, k) > 0 && <div key={k} className={"seg " + k} style={{ height: (100 * of(d, k) / max) + "%" }} />)}
          </div>
        ))}
      </div>
      <div className="legend">
        {KINDS.map(k => <span key={k}><i className={"seg " + k} />{k} {money(week(k))}</span>)}
        <span>· 7 days · {money(s.cost_per_merge_cents)} per merge ({s.merges} merges in {s.days} days)</span>
      </div>
    </div>
  );
}

// ---- personas: simulated users and what they hit -------------------
const OUTCOME_CLASS: Record<string, string> = {
  clean: "green", confirmed: "green", reported: "red", still_broken: "red",
  error: "conflict", running: "none",
};

function reportsOf(r: PersonaRun): PersonaReport[] {
  try { return r.report ? (JSON.parse(r.report) as PersonaReport[]) : []; } catch { return []; }
}

function NewPersona({ cid, onClose, done }: { cid: string; onClose: () => void; done: () => void }) {
  const [name, setName] = useState(""), [role, setRole] = useState(""), [goal, setGoal] = useState("");
  const [start, setStart] = useState("README.md"), [doneWhen, setDoneWhen] = useState(""), [model, setModel] = useState("");
  const [err, setErr] = useState("");
  const save = async () => {
    try {
      await api.createPersona(cid, { name, role, goal, start, done_when: doneWhen, model });
      done();
    } catch (e) { setErr(String(e)); }
  };
  return (
    <Modal title="New persona" onClose={onClose}
      footer={<><button className="ghost" onClick={onClose}>Cancel</button>
        <button className="primary" disabled={!name.trim() || !goal.trim()} onClick={save}>Add persona</button></>}>
      <Field label="Name"><input value={name} onChange={e => setName(e.target.value)} placeholder="Newcomer" autoFocus /></Field>
      <Field label="Who they are"><textarea value={role} onChange={e => setRole(e.target.value)} placeholder="A backend developer who has never seen this project. Copies commands exactly." /></Field>
      <Field label="What they're trying to do"><textarea value={goal} onChange={e => setGoal(e.target.value)} placeholder="Follow the quick start and get the tests passing." /></Field>
      <div className="row3">
        <Field label="Start from"><input value={start} onChange={e => setStart(e.target.value)} /></Field>
        <Field label="Model (blank: O_PERSONA_MODEL)"><input value={model} onChange={e => setModel(e.target.value)} placeholder="haiku" /></Field>
      </div>
      <Field label="Done when"><input value={doneWhen} onChange={e => setDoneWhen(e.target.value)} placeholder="the tests pass, or you're blocked" /></Field>
      {err && <p className="hint" style={{ color: "var(--red)" }}>{err}</p>}
    </Modal>
  );
}

function PersonasView({ company, issues, onIssue }: { company: Company; issues: Issue[]; onIssue: (id: string) => void }) {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [runs, setRuns] = useState<PersonaRun[]>([]);
  const [adding, setAdding] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [perDay, setPerDay] = useState(String(company.personas_per_day ?? 2));
  const [daily, setDaily] = useState(String(((company.persona_daily_cents ?? 200) / 100) || 0));
  const load = useCallback(async () => {
    try {
      const [p, r] = await Promise.all([api.personas(company.id), api.personaRuns(company.id)]);
      setPersonas(p); setRuns(r);
    } catch { /* daemon offline: the top bar says so */ }
  }, [company.id]);
  useEffect(() => {
    const first = setTimeout(load, 0), t = setInterval(load, 5000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [load]);
  const toggle = async (p: Persona) => { await api.updatePersona(p.id, { enabled: p.enabled ? 0 : 1 }); load(); };
  const saveBudget = async () => {
    await api.updateCompany(company.id, {
      personas_per_day: Math.max(0, parseInt(perDay) || 0),
      persona_daily_cents: Math.round((parseFloat(daily) || 0) * 100),
    });
    load();
  };
  const found = issues.filter(i => i.origin === "persona" || i.persona_id);
  const confirmed = runs.filter(r => r.outcome === "confirmed").length;
  const lastRun = (pid: string) => runs.find(r => r.persona_id === pid);
  const identOf = (id: string) => issues.find(i => i.id === id)?.identifier || id;
  return (
    <div className="personas">
      <div className="pstats">
        <div><div className="k">Persona spend today</div><div className="vv">{money(company.persona_spent_today ?? 0)} <span style={{ color: "var(--faint)", fontWeight: 400 }}>/ {money(company.persona_daily_cents ?? 0)}</span></div></div>
        <div><div className="k">Runs</div><div className="vv">{runs.length}</div></div>
        <div><div className="k">Issues found</div><div className="vv">{found.length}</div></div>
        <div><div className="k">Fixes confirmed</div><div className="vv">{confirmed}</div></div>
        <div className="pbudget">
          <Field label="Personas a day"><input type="number" min={0} value={perDay} onChange={e => setPerDay(e.target.value)} /></Field>
          <Field label="Daily budget (USD)"><input type="number" min={0} step="0.5" value={daily} onChange={e => setDaily(e.target.value)} /></Field>
          <button className="sm" onClick={saveBudget}>Save</button>
        </div>
      </div>
      <div className="pcols">
        <section>
          <div className="phead"><span className="lbl">Personas</span><button className="primary sm" onClick={() => setAdding(true)}>+ Persona</button></div>
          {personas.length === 0 && <p className="hint">No personas yet. Add one, or load <code>examples/personas/</code>. The pass runs daily with <code>O_PERSONAS=1</code>.</p>}
          {personas.map(p => {
            const lr = lastRun(p.id);
            return (
              <div className={"pcard" + (p.enabled ? "" : " off")} key={p.id}>
                <div className="r1">
                  <span className="av">{initials(p.name)}</span>
                  <b>{p.name}</b>
                  {p.model && <span className="rtag">{p.model}</span>}
                  <label className="tog" title={p.enabled ? "enabled" : "disabled"}>
                    <input type="checkbox" checked={!!p.enabled} onChange={() => toggle(p)} /> on
                  </label>
                </div>
                {p.role && <div className="role">{p.role}</div>}
                <div className="goal"><span className="k">Goal</span> {p.goal}</div>
                <div className="meta">
                  starts at {p.start || "README.md"}
                  {lr && <> · last run {ago(lr.started_at)} ago, <span className={"vchip " + (OUTCOME_CLASS[lr.outcome] || "none")}>{lr.outcome}</span></>}
                </div>
              </div>
            );
          })}
        </section>
        <section>
          <div className="phead"><span className="lbl">Runs</span></div>
          {runs.length === 0 && <p className="hint">No runs yet.</p>}
          {runs.map(r => {
            const reps = reportsOf(r);
            const isOpen = open === r.id;
            return (
              <div className="prun" key={r.id}>
                <div className="r1" onClick={() => setOpen(isOpen ? null : r.id)} style={{ cursor: reps.length ? "pointer" : "default" }}>
                  <b>{r.persona || "?"}</b>
                  <span className="ochip">{r.kind === "confirm" ? "confirm" : "scenario"}</span>
                  <span className={"vchip " + (OUTCOME_CLASS[r.outcome] || "none")}>{r.outcome}</span>
                  {reps.length > 0 && <span className="ct">{reps.length} report{reps.length > 1 ? "s" : ""} {isOpen ? "▾" : "▸"}</span>}
                  {r.issue_id && <a className="ilink" onClick={(e) => { e.stopPropagation(); onIssue(r.issue_id); }}>{identOf(r.issue_id)}</a>}
                  <span className="at">{money(r.cost_cents)} · {r.ended_at ? dur(r.started_at, r.ended_at) : "running"} · {ago(r.started_at)}</span>
                </div>
                {isOpen && reps.map((rep, k) => (
                  <div className="prep" key={k}>
                    <div><span className={"sev " + rep.severity}>{rep.severity}</span> <b>{rep.title}</b> {rep.doc_section && <span className="by">· {rep.doc_section}</span>}</div>
                    <pre>{rep.steps}</pre>
                    {rep.expected && <div className="by">expected: {rep.expected}</div>}
                    <pre className="actual">{rep.actual}</pre>
                  </div>
                ))}
              </div>
            );
          })}
        </section>
      </div>
      {adding && <NewPersona cid={company.id} onClose={() => setAdding(false)} done={() => { setAdding(false); load(); }} />}
    </div>
  );
}

// ---- app -----------------------------------------------------------
type ModalState =
  | { kind: "newCompany" } | { kind: "newIssue" } | { kind: "hireAgent" }
  | { kind: "manage" } | { kind: "issue"; id: string } | { kind: "chat"; id: string } | null;

export default function App() {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [selId, setSelId] = useState<string | null>(null);
  const [issues, setIssues] = useState<Issue[]>([]);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [runs, setRuns] = useState<Run[]>([]);
  const [activity, setActivity] = useState<Activity[]>([]);
  const [orch, setOrch] = useState<Orchestrator | null>(null);
  const [offline, setOffline] = useState(false);
  const [modal, setModal] = useState<ModalState>(null);
  const selRef = useRef<string | null>(null);
  selRef.current = selId;

  const refresh = useCallback(async () => {
    try {
      const [c, o, r, a] = await Promise.all([
        api.companies(), api.orchestrator(), api.runs(), api.activity(),
      ]);
      setOffline(false);
      setCompanies(c); setOrch(o); setRuns(r); setActivity(a);
      let sel = selRef.current;
      if (!sel || !c.some(x => x.id === sel)) sel = c[0]?.id ?? null;
      if (sel !== selRef.current) { selRef.current = sel; setSelId(sel); }
      if (sel) {
        const [iss, ags] = await Promise.all([api.issues(sel), api.agents(sel)]);
        setIssues(iss); setAgents(ags);
      } else { setIssues([]); setAgents([]); }
    } catch {
      setOffline(true);
    }
  }, []);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 3000);
    return () => clearInterval(t);
  }, [refresh]);

  const select = (id: string) => { selRef.current = id; setSelId(id); refresh(); };
  const afterChange = () => { setModal(null); refresh(); };
  const company = companies.find(c => c.id === selId) || null;

  return (
    <div className="app">
      <TopBar orch={orch} offline={offline} />
      <div className="body">
        <Sidebar companies={companies} selId={selId} onSelect={select}
          onNew={() => setModal({ kind: "newCompany" })} />
        {company
          ? <CompanyView company={company} issues={issues} agents={agents}
              onIssue={(id) => setModal({ kind: "issue", id })}
              onNewIssue={() => setModal({ kind: "newIssue" })}
              onHire={() => setModal({ kind: "hireAgent" })}
              onManage={() => setModal({ kind: "manage" })}
              onAgentChat={(id) => setModal({ kind: "chat", id })} />
          : <div className="main"><div className="empty">
              <div className="big">Welcome to O v4</div>
              <div>Create a company, hire an agent, file issues —<br />then watch them get done.</div>
              <button className="primary" onClick={() => setModal({ kind: "newCompany" })}>Create a company</button>
            </div></div>}
        <Rail runs={runs} activity={activity} />
      </div>

      {modal?.kind === "newCompany" && <NewCompany onClose={() => setModal(null)} done={afterChange} />}
      {modal?.kind === "newIssue" && company && <NewIssue cid={company.id} onClose={() => setModal(null)} done={afterChange} />}
      {modal?.kind === "hireAgent" && company && <HireAgent cid={company.id} onClose={() => setModal(null)} done={afterChange} />}
      {modal?.kind === "manage" && company && <Manage company={company} onClose={() => setModal(null)} done={afterChange} />}
      {modal?.kind === "issue" && (() => {
        const iss = issues.find(i => i.id === modal.id);
        return iss ? <IssueModal issue={iss} agents={agents} runs={runs}
          onClose={() => setModal(null)} done={afterChange} /> : null;
      })()}
      {modal?.kind === "chat" && (() => {
        const ag = agents.find(a => a.id === modal.id);
        return ag ? <AgentChat agent={ag} onClose={() => setModal(null)} /> : null;
      })()}
    </div>
  );
}
