#!/usr/bin/env node
// O v4 MCP server — exposes the daemon's API as MCP tools so you can
// drive O (file issues, hire agents, etc.) from Claude Code without
// leaving the editor. Talks to swarmd on $O_API (default :4100).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const API = process.env.O_API || "http://localhost:4100/api";

async function j(path, opts = {}) {
  let r;
  try {
    r = await fetch(API + path, {
      ...opts,
      headers: {
        "Content-Type": "application/json",
        ...(process.env.O_API_TOKEN ? { Authorization: `Bearer ${process.env.O_API_TOKEN}` } : {}),
        ...(opts.headers || {}),
      },
    });
  } catch (e) {
    throw new Error(`O daemon unreachable at ${API} — is swarmd running?  (${e.message})`);
  }
  if (!r.ok) throw new Error(`HTTP ${r.status} ${r.statusText} on ${path}`);
  return r.json();
}
const post = (p, b) => j(p, { method: "POST", body: JSON.stringify(b) });
const tx = (d) => ({ content: [{ type: "text", text: JSON.stringify(d, null, 2) }] });

const server = new McpServer({ name: "o-v4", version: "0.1.0" });

// ---- companies ---------------------------------------------------
server.registerTool("o_list_companies",
  { description: "List all companies in O v4. Use this first to find a company_id for the other tools.",
    inputSchema: {} },
  async () => tx(await j("/companies")));

server.registerTool("o_create_company",
  { description: "Create a new company.",
    inputSchema: {
      name: z.string().describe("Company name"),
      mission: z.string().optional().describe("One-line mission"),
      issue_prefix: z.string().optional().describe("Issue id prefix, e.g. 'OTO'. Default 'TASK'."),
      budget_monthly_cents: z.number().int().optional().describe("Monthly budget cap in cents. 0 = unlimited."),
    } },
  async (a) => tx(await post("/companies", a)));

server.registerTool("o_update_company",
  { description: "Update a company's budget or status. status='active' un-pauses a budget-paused company.",
    inputSchema: {
      id: z.string(),
      budget_monthly_cents: z.number().int().optional(),
      status: z.enum(["active", "paused"]).optional(),
    } },
  async ({ id, ...body }) => tx(await post(`/companies/${id}`, body)));

// ---- issues ------------------------------------------------------
server.registerTool("o_list_issues",
  { description: "List issues for a company.",
    inputSchema: { company_id: z.string() } },
  async ({ company_id }) => tx(await j(`/companies/${company_id}/issues`)));

server.registerTool("o_create_issue",
  { description: "File a new issue in a company. The orchestrator will dispatch it to an active agent within ~5s.",
    inputSchema: {
      company_id: z.string(),
      title: z.string(),
      body: z.string().optional().describe("Context, acceptance criteria, files to touch — what the agent needs."),
      priority: z.enum(["high", "medium", "low"]).optional(),
    } },
  async ({ company_id, ...body }) => tx(await post(`/companies/${company_id}/issues`, body)));

server.registerTool("o_update_issue",
  { description: "Update an issue's status, priority, or assignee.",
    inputSchema: {
      id: z.string(),
      status: z.enum(["Backlog", "In Progress", "Done", "Canceled"]).optional(),
      priority: z.enum(["high", "medium", "low"]).optional(),
      assignee_agent_id: z.string().optional().describe("Agent id; empty string to unassign."),
    } },
  async ({ id, ...body }) => tx(await post(`/issues/${id}`, body)));

// ---- agents ------------------------------------------------------
server.registerTool("o_list_agents",
  { description: "List agents hired into a company.",
    inputSchema: { company_id: z.string() } },
  async ({ company_id }) => tx(await j(`/companies/${company_id}/agents`)));

server.registerTool("o_hire_agent",
  { description: "Hire an agent into a company. runtime: 'claude-code' (real Claude), 'sim' (free stub), 'swarm-code'. For dev agents, set repo to an absolute git repo path.",
    inputSchema: {
      company_id: z.string(),
      name: z.string(),
      role: z.string().optional(),
      runtime: z.enum(["claude-code", "sim", "swarm-code"]).optional(),
      repo: z.string().optional().describe("Absolute git repo path. Empty = empty workspace per issue."),
    } },
  async ({ company_id, ...body }) => tx(await post(`/companies/${company_id}/agents`, body)));

// ---- visibility --------------------------------------------------
server.registerTool("o_orchestrator_status",
  { description: "Live scheduler snapshot: current tick, running, retrying.",
    inputSchema: {} },
  async () => tx(await j("/orchestrator")));

server.registerTool("o_recent_runs",
  { description: "The 100 most recent agent runs — state, attempt, cost, workspace.",
    inputSchema: {} },
  async () => tx(await j("/runs")));

server.registerTool("o_recent_activity",
  { description: "Recent activity log entries (verbs like company.create, issue.create, run.succeeded, budget.exceeded).",
    inputSchema: {} },
  async () => tx(await j("/activity")));

await server.connect(new StdioServerTransport());
