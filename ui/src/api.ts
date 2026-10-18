// Typed client for the O v4 daemon (swarmd). The daemon serves a
// JSON API on :4100 with permissive CORS, so this app can run from
// the Vite dev server and talk to it directly.

const BASE = (import.meta.env.VITE_O_API as string) || "http://localhost:4100/api";
// Matches the daemon's O_API_TOKEN, when one is set (guards company/agent writes).
const TOKEN = import.meta.env.VITE_O_TOKEN as string | undefined;

export interface Company {
  id: string; name: string; mission: string; issue_prefix: string; status: string;
  budget_monthly_cents: number; spent_cents: number; issue_counter: number;
  created_at: number; updated_at: number;
  // phase 0-6: repo target + verify gate + daily budget ledger
  repo: string; verify_cmd: string; protected_paths: string;
  budget_daily_cents: number; spent_today_cents: number; budget_day: number;
  pause_reason: string; greens_today: number; no_signal_days: number;
  // GitHub in/out: issues imported from github_repo; ship "merge" | "pr"
  github_repo: string; ship: string;
}
export interface Issue {
  id: string; company_id: string; identifier: string; title: string; body: string;
  status: string; priority: string; assignee_agent_id: string | null;
  sort_order: number; created_at: number; updated_at: number;
  // where this issue came from: operator | auto | reflect | feedback
  origin: string; fingerprint: string;
}
export interface Agent {
  id: string; company_id: string; name: string; role: string;
  runtime: string; repo: string; status: string; created_at: number;
}
export interface Run {
  id: string; issue_id: string; agent_id: string; attempt: number; state: string;
  workspace_path: string; started_at: number; ended_at: number | null; cost_cents: number;
  // phase 2-3 verify gate: green | red_* | conflict | reverted (verify_output
  // is only carried on the /result endpoint, not the runs list)
  verify_state: string; merge_sha: string;
}
export interface Activity {
  id: string; company_id: string; actor: string; verb: string; target: string; ts: number;
}
export interface Orchestrator {
  tick: number; running: number; retrying: number;
  tick_interval_ms: number; max_concurrent: number;
}
export interface Message {
  id: string; agent_id: string; role: string; content: string; created_at: number;
}

async function req<T>(path: string, opts?: RequestInit): Promise<T> {
  const r = await fetch(BASE + path, {
    ...opts,
    headers: {
      "Content-Type": "application/json",
      ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
      ...(opts?.headers || {}),
    },
  });
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.json() as Promise<T>;
}
const post = (p: string, body: unknown) =>
  req(p, { method: "POST", body: JSON.stringify(body) });

export const api = {
  companies: () => req<Company[]>("/companies"),
  createCompany: (b: Record<string, unknown>) => post("/companies", b) as Promise<Company>,
  updateCompany: (id: string, b: Record<string, unknown>) =>
    post(`/companies/${id}`, b) as Promise<Company>,
  issues: (cid: string) => req<Issue[]>(`/companies/${cid}/issues`),
  createIssue: (cid: string, b: Record<string, unknown>) =>
    post(`/companies/${cid}/issues`, b) as Promise<Issue>,
  updateIssue: (id: string, b: Record<string, unknown>) =>
    post(`/issues/${id}`, b) as Promise<Issue>,
  agents: (cid: string) => req<Agent[]>(`/companies/${cid}/agents`),
  hireAgent: (cid: string, b: Record<string, unknown>) =>
    post(`/companies/${cid}/agents`, b),
  runs: () => req<Run[]>("/runs"),
  activity: () => req<Activity[]>("/activity"),
  orchestrator: () => req<Orchestrator>("/orchestrator"),
  runResult: (id: string) => req<{
    workspace: string; result: string; stream: string; error: string;
    verify_state: string; verify_output: string; merge_sha: string;
  }>(`/runs/${id}/result`),
  fs: (path: string) =>
    post("/fs", { path }) as Promise<{ path: string; parent: string; listing: string; gits: string }>,
  agentMessages: (id: string) => req<Message[]>(`/agents/${id}/messages`),
  agentChat: (id: string, message: string) => post(`/agents/${id}/chat`, { message }),
};

// ---- formatting helpers --------------------------------------
export const money = (c: number) => "$" + ((Number(c) || 0) / 100).toFixed(2);
export const ago = (ts: number) => {
  const s = (Date.now() - ts) / 1000;
  if (s < 60) return Math.max(0, Math.floor(s)) + "s";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
};
export const dur = (a: number, b: number | null) => {
  if (!a || !b) return "–";
  const s = (b - a) / 1000;
  return s < 60 ? s.toFixed(1) + "s" : Math.floor(s / 60) + "m" + Math.round(s % 60) + "s";
};
export const initials = (n: string) => (n || "?").trim().slice(0, 2).toUpperCase();
