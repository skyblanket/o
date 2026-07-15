import { useState, useEffect, useCallback, useRef, useMemo, type ReactNode } from "react";
import {
  api, money, ago, dur, initials,
  type Company, type Issue, type Agent, type Run, type Activity, type Orchestrator, type Message,
} from "./api";

const LANES = ["Backlog", "In Progress", "Verifying", "Done", "Failed"];

// An issue lives in the Failed lane whether it truly Failed or was Reverted
// off main; the "reverted" case gets its own chip on the card.
const laneOf = (status: string) => (status === "Reverted" ? "Failed" : status);

// where the loop got this issue from — operator issues show nothing.
const ORIGIN_CHIP: Record<string, string> = {
  auto: "⚙ auto", reflect: "🪞 reflect", feedback: "🎯 feedback",
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
  const [picking, setPicking] = useState(false);
  const save = async () => {
    await api.updateCompany(company.id, {
      budget_monthly_cents: Math.round((parseFloat(budget) || 0) * 100),
      budget_daily_cents: Math.round((parseFloat(daily) || 0) * 100),
      status, repo: repo.trim(), verify_cmd: verifyCmd.trim(),
      protected_paths: protectedPaths.trim(),
    });
    done();
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
      </Modal>
      {picking && <FolderPicker onClose={() => setPicking(false)} onPick={p => { setRepo(p); setPicking(false); }} />}
    </>
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
      </div>
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
