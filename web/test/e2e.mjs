// End-to-end check of the sync API against a running server, local by default:
//
//   node test/e2e.mjs [base]          base defaults to http://localhost:8787/recordings
//
// It discovers everything from a bare 401 the way a client on someone else's server
// would, so it doubles as a conformance check for anyone hosting their own.
// Signing in needs DEV_LOGIN_CODES=1 on the server (wrangler dev reads .dev.vars).
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";

const base = (process.argv[2] ?? "http://localhost:8787/recordings").replace(/\/$/, "");
const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const step = (s) => console.log(`\x1b[38;5;202m//\x1b[0m ${s}`);

// 1. Discovery: 401 → RFC 9728 resource metadata → RFC 8414 server metadata.
step("discover");
const challenge = await fetch(`${base}/api/v1`);
assert.equal(challenge.status, 401);
const prmUrl = challenge.headers.get("www-authenticate").match(/resource_metadata="([^"]+)"/)[1];
const prm = await (await fetch(prmUrl)).json();
const issuer = prm.authorization_servers[0];
const iss = new URL(issuer);
const asm = await (await fetch(`${iss.origin}/.well-known/oauth-authorization-server${iss.pathname}`)).json();
assert.equal(asm.issuer, issuer);
console.log("   resource", prm.resource, "\n   issuer  ", issuer);

// 2. Dynamic client registration as a native app with a loopback redirect.
step("register");
const redirect = "http://127.0.0.1:53682/callback";
const reg = await (await fetch(asm.registration_endpoint, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    client_name: "e2e test", redirect_uris: ["http://127.0.0.1/callback"],
    grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none",
  }),
})).json();
assert.ok(reg.client_id, JSON.stringify(reg));

// 3. Sign in to the viewer with a dev code to get a session cookie.
step("sign in");
const email = process.env.E2E_EMAIL ?? "dev@example.com";
const started = await (await fetch(`${base}/api/auth/start`, { method: "POST", body: JSON.stringify({ email }) })).json();
assert.ok(started.devCode, "server must run with DEV_LOGIN_CODES=1");
const verified = await fetch(`${base}/api/auth/verify`, { method: "POST", body: JSON.stringify({ email, code: started.devCode }) });
const cookie = verified.headers.get("set-cookie").split(";")[0];

// 4. Authorize with PKCE, then Allow on the consent screen.
step("authorize");
const verifier = b64url(randomBytes(32));
const state = b64url(randomBytes(12));
const auth = new URL(asm.authorization_endpoint);
Object.entries({
  response_type: "code", client_id: reg.client_id, redirect_uri: redirect, state,
  code_challenge: b64url(createHash("sha256").update(verifier).digest()), code_challenge_method: "S256",
  scope: "recordings:read recordings:write offline_access", resource: prm.resource,
}).forEach(([k, v]) => auth.searchParams.set(k, v));
const consent = await (await fetch(auth, { headers: { Cookie: cookie } })).text();
const csrf = consent.match(/name="csrf" value="([^"]+)"/)[1];
const q = consent.match(/name="q" value="([^"]+)"/)[1].replace(/&amp;/g, "&");
const allow = await fetch(asm.authorization_endpoint, {
  method: "POST", redirect: "manual", headers: { Cookie: cookie },
  body: new URLSearchParams({ q, csrf, decision: "allow" }),
});
const back = new URL(allow.headers.get("location"));
assert.equal(back.searchParams.get("state"), state);
const code = back.searchParams.get("code");
assert.ok(code, back.toString());

// 5. Code → tokens.
step("token");
const tokenRes = await (await fetch(asm.token_endpoint, {
  method: "POST",
  body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: redirect, client_id: reg.client_id, code_verifier: verifier, resource: prm.resource }),
})).json();
assert.ok(tokenRes.access_token && tokenRes.refresh_token, JSON.stringify(tokenRes));
const bearer = { Authorization: `Bearer ${tokenRes.access_token}` };

// 6. Use the API.
step("sync");
const id = "e2e test call";
const callUrl = `${base}/api/v1/calls/${encodeURIComponent(id)}`;
const meeting = JSON.stringify({ title: "E2E", theirName: "Robot", myName: "Scott", startedAt: "2026-10-15T12:00:00Z", duration: 3, utterances: [{ id: "1", speaker: "them", text: "beep", start: 0, end: 1 }], notes: "## Summary\nIt beeped." });
const sha = createHash("sha256").update(meeting).digest("hex");
let r = await fetch(`${callUrl}/files/meeting.json`, { method: "PUT", headers: { ...bearer, "X-Content-SHA256": sha }, body: meeting });
assert.equal(r.status, 200, await r.text());

// A small multipart upload, the path big audio files take.
const audio = randomBytes(6 * 1024 * 1024);
const start = await (await fetch(`${callUrl}/files/them.m4a/uploads`, { method: "POST", headers: { ...bearer, "X-Content-SHA256": createHash("sha256").update(audio).digest("hex") } })).json();
const parts = [];
for (const [n, chunk] of [[1, audio.subarray(0, 5 * 1024 * 1024)], [2, audio.subarray(5 * 1024 * 1024)]]) {
  parts.push(await (await fetch(`${callUrl}/files/them.m4a/uploads/${encodeURIComponent(start.uploadId)}/${n}`, { method: "PUT", headers: bearer, body: chunk })).json());
}
r = await fetch(`${callUrl}/files/them.m4a/uploads/${encodeURIComponent(start.uploadId)}`, { method: "POST", headers: { ...bearer, "Content-Type": "application/json" }, body: JSON.stringify({ parts }) });
assert.equal(r.status, 200, await r.text());

const list = await (await fetch(`${base}/api/v1/calls`, { headers: bearer })).json();
assert.ok(list.calls.some((c) => c.id === id && c.title === "E2E"));
const detail = await (await fetch(callUrl, { headers: bearer })).json();
assert.equal(detail.files.find((f) => f.name === "meeting.json").sha256, sha);
assert.equal(detail.files.find((f) => f.name === "them.m4a").size, audio.length);
const ranged = await fetch(`${callUrl}/files/them.m4a`, { headers: { ...bearer, Range: "bytes=0-99" } });
assert.equal(ranged.status, 206);
assert.equal((await ranged.arrayBuffer()).byteLength, 100);

// The viewer sees the same call through the session cookie, and can't write.
const viewer = await (await fetch(`${base}/api/calls`, { headers: { Cookie: cookie } })).json();
assert.ok(viewer.calls.some((c) => c.id === id));
assert.equal((await fetch(`${base}/api/calls/${encodeURIComponent(id)}`, { method: "DELETE", headers: { Cookie: cookie } })).status, 403);

// 7. An AI agent over MCP: discover from /mcp, register, and authorize with no scope
// (what MCP clients do), which grants read-only. Then call each tool.
step("mcp");
for (const [name, body] of [["transcript.md", "# E2E\n\nOct 15 · Scott and Robot\n\n[00:00] Robot: beep about the zebra budget\n"], ["notes.md", "## Summary\nIt beeped about the zebra budget."]]) {
  r = await fetch(`${callUrl}/files/${name}`, { method: "PUT", headers: bearer, body });
  assert.equal(r.status, 200, await r.text());
}
const mcpUrl = `${base}/mcp`;
const mcpChallenge = await fetch(mcpUrl, { method: "POST", body: "{}" });
assert.equal(mcpChallenge.status, 401);
const mcpPrm = await (await fetch(mcpChallenge.headers.get("www-authenticate").match(/resource_metadata="([^"]+)"/)[1])).json();
assert.equal(mcpPrm.resource, mcpUrl);
assert.equal(mcpPrm.authorization_servers[0], issuer);

const agent = await (await fetch(asm.registration_endpoint, {
  method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ client_name: "e2e agent", redirect_uris: ["http://localhost:4567/callback"], grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none" }),
})).json();
const agentVerifier = b64url(randomBytes(32));
const agentAuth = new URL(asm.authorization_endpoint);
Object.entries({
  response_type: "code", client_id: agent.client_id, redirect_uri: "http://localhost:4567/callback", state,
  code_challenge: b64url(createHash("sha256").update(agentVerifier).digest()), code_challenge_method: "S256", resource: mcpUrl,
}).forEach(([k, v]) => agentAuth.searchParams.set(k, v));
const agentConsent = await (await fetch(agentAuth, { headers: { Cookie: cookie } })).text();
assert.match(agentConsent, /list your calls/);
const agentAllow = await fetch(asm.authorization_endpoint, {
  method: "POST", redirect: "manual", headers: { Cookie: cookie },
  body: new URLSearchParams({
    q: agentConsent.match(/name="q" value="([^"]+)"/)[1].replace(/&amp;/g, "&"),
    csrf: agentConsent.match(/name="csrf" value="([^"]+)"/)[1], decision: "allow",
  }),
});
const agentCode = new URL(agentAllow.headers.get("location")).searchParams.get("code");
const agentToken = await (await fetch(asm.token_endpoint, {
  method: "POST",
  body: new URLSearchParams({ grant_type: "authorization_code", code: agentCode, redirect_uri: "http://localhost:4567/callback", client_id: agent.client_id, code_verifier: agentVerifier, resource: mcpUrl }),
})).json();
assert.ok(agentToken.access_token, JSON.stringify(agentToken));
assert.equal(agentToken.scope, "recordings:read");
const agentBearer = { Authorization: `Bearer ${agentToken.access_token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" };

let rpcId = 0;
const rpc = async (method, params) => {
  const res = await fetch(mcpUrl, { method: "POST", headers: agentBearer, body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }) });
  assert.equal(res.status, 200, await res.clone().text());
  const reply = await res.json();
  assert.ok(!reply.error, JSON.stringify(reply.error));
  return reply.result;
};
const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
assert.equal(init.protocolVersion, "2025-06-18");
assert.equal((await fetch(mcpUrl, { method: "POST", headers: agentBearer, body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) })).status, 202);
const tools = (await rpc("tools/list")).tools.map((t) => t.name).sort();
assert.deepEqual(tools, ["get_call", "list_calls", "search_calls"]);
const toolText = async (name, args) => (await rpc("tools/call", { name, arguments: args })).content[0].text;
assert.match(await toolText("list_calls", {}), /E2E/);
assert.match(await toolText("search_calls", { query: "zebra budget" }), /zebra budget/);
assert.match(await toolText("search_calls", { query: "nonexistent-word" }), /No calls mention/);
const read = await toolText("get_call", { id });
assert.match(read, /## Notes[\s\S]*zebra budget[\s\S]*## Transcript\n\n\[00:00\] Robot: beep/);
const missing = await rpc("tools/call", { name: "get_call", arguments: { id: "nope" } });
assert.equal(missing.isError, true);

// The agent's read-only token can't write through the sync API, and the sync
// client's token isn't for the MCP resource.
assert.notEqual((await fetch(callUrl, { method: "DELETE", headers: { Authorization: `Bearer ${agentToken.access_token}` } })).status, 204);
assert.equal((await fetch(mcpUrl, { method: "POST", headers: { ...bearer, "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }) })).status, 401);

// 8. Refresh, then clean up.
step("refresh + delete");
const refreshed = await (await fetch(asm.token_endpoint, {
  method: "POST",
  body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: tokenRes.refresh_token, client_id: reg.client_id, resource: prm.resource }),
})).json();
assert.ok(refreshed.access_token, JSON.stringify(refreshed));
r = await fetch(callUrl, { method: "DELETE", headers: { Authorization: `Bearer ${refreshed.access_token}` } });
assert.equal(r.status, 204);
assert.equal((await fetch(callUrl, { headers: { Authorization: `Bearer ${refreshed.access_token}` } })).status, 404);

console.log("\x1b[32mok\x1b[0m");
