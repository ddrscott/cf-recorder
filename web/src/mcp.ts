// Recordings as an MCP server, so an AI agent (Claude Code, Claude.ai, Cursor, …) can find
// and read your calls. Served at /recordings/mcp over Streamable HTTP. The OAuth resource
// server in server.ts checks the bearer token first; everything here is read-only.
//
// It's stateless JSON-RPC with JSON responses: no sessions and no SSE stream, which the
// spec allows and every tool here needs (each call is one quick read of D1 or R2).

const SERVER_INFO = { name: "recordings", title: "Recordings", version: "1.0.0" };
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS = `These are the user's recorded calls, made with the Recorder Mac app. Each call has two
speakers transcribed separately (the user and the other person), plus generated notes: a summary,
key points, decisions, action items, and open questions.

list_calls shows the most recent calls. search_calls finds calls whose title, notes, or transcript
mention something, with the matching lines. get_call reads one call: its notes, its full transcript,
or both. Call ids look like "2026-10-15 141525", the local time the call started.

Transcripts come from speech recognition, so expect some misheard words. Quote them as what was
said, not as verified fact.`;

type Json = Record<string, unknown>;
type RpcRequest = { jsonrpc: "2.0"; id?: string | number | null; method: string; params?: Json };
type CallRow = { id: string; title: string; their_name: string; my_name: string; started_at: string; duration: number; lines: number };

const LIST_DEFAULT = 20;
const LIST_MAX = 100;
const SEARCH_SCAN_MAX = 300;

const TOOLS = [
  {
    name: "list_calls",
    title: "List calls",
    description: "The most recent calls, newest first: id, title, when, who, how long, and how many lines were said.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: LIST_MAX, description: `How many calls (default ${LIST_DEFAULT})` } },
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "search_calls",
    title: "Search calls",
    description: "Finds calls whose title, notes, or transcript contain every word of the query (case-insensitive), newest first, with the matching lines.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", minLength: 1, description: "Words to look for, like a name, a project, or a topic" },
        limit: { type: "integer", minimum: 1, maximum: LIST_MAX, description: `How many calls (default ${LIST_DEFAULT})` },
      },
      required: ["query"],
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "get_call",
    title: "Read a call",
    description: "One call's notes (summary, decisions, action items, open questions) and full timestamped transcript.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: 'The call id from list_calls or search_calls, like "2026-10-15 141525"' },
        include: {
          type: "string",
          enum: ["both", "notes", "transcript"],
          description: "What to return (default both). Notes are short; a transcript can be long.",
        },
      },
      required: ["id"],
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
];

const clock = (seconds: number) => {
  const s = Math.max(0, Math.round(seconds));
  const pad = (n: number) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
};

/** The id is the call's local start time, which reads better than the UTC startedAt. */
const when = (id: string) => {
  const m = id.match(/^(\d{4}-\d{2}-\d{2}) (\d{2})(\d{2})/);
  return m ? `${m[1]} ${m[2]}:${m[3]}` : id;
};

const describe = (c: CallRow) =>
  `- **${c.title || "Untitled call"}** · id \`${c.id}\` · ${when(c.id)} · ${c.my_name} with ${c.their_name} · ${clock(c.duration)} · ${c.lines} lines`;

async function calls(env: Env, limit: number): Promise<CallRow[]> {
  const { results } = await env.DB.prepare(
    "SELECT id, title, their_name, my_name, started_at, duration, lines FROM calls ORDER BY started_at DESC LIMIT ?",
  ).bind(limit).all<CallRow>();
  return results;
}

const text = async (env: Env, id: string, name: string) => (await env.FILES.get(`calls/${id}/${name}`))?.text() ?? "";

const limitOf = (args: Json) => Math.min(LIST_MAX, Math.max(1, Math.floor(Number(args.limit ?? LIST_DEFAULT)) || LIST_DEFAULT));

async function listCalls(env: Env, args: Json): Promise<string> {
  const rows = await calls(env, limitOf(args));
  if (!rows.length) return "No calls yet. They show up here after the Recorder Mac app syncs them.";
  return rows.map(describe).join("\n");
}

async function searchCalls(env: Env, args: Json): Promise<string> {
  const query = String(args.query ?? "").trim();
  if (!query) throw new ToolError("Give a query to search for.");
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const limit = limitOf(args);
  const found: string[] = [];
  // Small enough to read through: a person's calls, not a corpus. Newest first, stop at limit.
  for (const c of await calls(env, SEARCH_SCAN_MAX)) {
    const [notes, transcript] = await Promise.all([text(env, c.id, "notes.md"), text(env, c.id, "transcript.md")]);
    const haystack = `${c.title}\n${notes}\n${transcript}`.toLowerCase();
    if (!words.every((w) => haystack.includes(w))) continue;
    const hits = `${notes}\n${transcript}`
      .split("\n")
      .filter((line) => line.trim() && words.some((w) => line.toLowerCase().includes(w)))
      .slice(0, 5)
      .map((line) => `    > ${line.trim().slice(0, 240)}`);
    found.push([describe(c), ...hits].join("\n"));
    if (found.length >= limit) break;
  }
  return found.length ? found.join("\n") : `No calls mention "${query}".`;
}

async function getCall(env: Env, args: Json): Promise<string> {
  const id = String(args.id ?? "").trim();
  const include = String(args.include ?? "both");
  const row = await env.DB.prepare(
    "SELECT id, title, their_name, my_name, started_at, duration, lines FROM calls WHERE id = ?",
  ).bind(id).first<CallRow>();
  if (!row) throw new ToolError(`No call with id "${id}". list_calls or search_calls give the ids.`);

  const parts = [`# ${row.title || "Untitled call"}`, `${when(row.id)} · ${row.my_name} with ${row.their_name} · ${clock(row.duration)}`];
  if (include !== "transcript") {
    const notes = (await text(env, id, "notes.md")).trim();
    parts.push("## Notes", notes || "_No notes were written for this call._");
  }
  if (include !== "notes") {
    // transcript.md repeats the title and date as a header; keep only the lines.
    const transcript = (await text(env, id, "transcript.md")).split("\n").filter((l) => /^\[\d/.test(l)).join("\n");
    parts.push("## Transcript", transcript || "_Nothing was transcribed._");
  }
  return parts.join("\n\n");
}

class ToolError extends Error {}

async function callTool(env: Env, params: Json): Promise<Json> {
  const name = String(params.name ?? "");
  const args = (params.arguments ?? {}) as Json;
  const run = { list_calls: listCalls, search_calls: searchCalls, get_call: getCall }[name];
  if (!run) throw new RpcError(-32602, `Unknown tool "${name}".`);
  try {
    return { content: [{ type: "text", text: await run(env, args) }] };
  } catch (e) {
    if (e instanceof ToolError) return { content: [{ type: "text", text: e.message }], isError: true };
    throw e;
  }
}

class RpcError extends Error {
  constructor(readonly code: number, message: string) {
    super(message);
  }
}

async function dispatch(env: Env, msg: RpcRequest): Promise<Json | null> {
  const isNotification = msg.id === undefined || msg.id === null;
  try {
    let result: Json;
    switch (msg.method) {
      case "initialize": {
        const asked = String(msg.params?.protocolVersion ?? "");
        result = {
          protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        };
        break;
      }
      case "ping":
        result = {};
        break;
      case "tools/list":
        result = { tools: TOOLS };
        break;
      case "tools/call":
        result = await callTool(env, msg.params ?? {});
        break;
      default:
        if (msg.method?.startsWith("notifications/")) return null;
        throw new RpcError(-32601, `Method not found: ${msg.method}`);
    }
    return isNotification ? null : { jsonrpc: "2.0", id: msg.id, result };
  } catch (e) {
    if (isNotification) return null;
    const code = e instanceof RpcError ? e.code : -32603;
    return { jsonrpc: "2.0", id: msg.id, error: { code, message: (e as Error).message } };
  }
}

export async function handleMcp(req: Request, env: Env): Promise<Response> {
  if (req.method !== "POST") {
    // No server-to-client stream; clients fall back to plain POSTs.
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
  }
  const batch = Array.isArray(body);
  const messages = (batch ? body : [body]) as RpcRequest[];
  const replies = (await Promise.all(messages.map((m) => dispatch(env, m)))).filter((r): r is Json => r !== null);
  if (!replies.length) return new Response(null, { status: 202 });
  return Response.json(batch ? replies : replies[0]);
}
