Live at https://askscottpierce.com/recordings

# Recordings

The web side of Recorder. The Mac app syncs each call folder here over an OAuth-protected API, the viewer lets you read transcripts and notes and play both tracks from anywhere, and an MCP server lets AI agents search and read them.

It's one Cloudflare Worker: R2 holds the files, D1 holds sign-in state and an index of calls, and KV holds OAuth clients and grants (`@cloudflare/workers-oauth-provider`).

## // SUBPATH

The Worker owns only `askscottpierce.com/recordings` and `/recordings/*`, plus two discovery paths, `/.well-known/oauth-authorization-server/recordings` and `/.well-known/oauth-protected-resource/recordings/*` (one document for `api/v1`, one for `mcp`). RFC 8414 and RFC 9728 put metadata at the domain root with the issuer's or resource's path appended, so those belong to this app. Tasks owns the bare `/.well-known/oauth-authorization-server`, and nothing here touches it. There's no workers.dev URL.

`/recordings` is hard-coded in five places: `src/server.ts` (`BASE`, which `API_V1` and `MCP` build on), `src/auth.ts` (cookie path and email link), `src/oauth.ts` (`AUTHORIZE_PATH`), `wrangler.jsonc` (routes), and `public/recordings/app.js` (`BASE`). Static files live under `public/recordings/` so their file path is their URL. The session cookie is `recordings-sid` with `Path=/recordings`.

Sign-in is the emailed-code flow from Tasks, limited to the `ALLOWED_EMAILS` secret (comma-separated emails or `@domain.com` rules; empty lets nobody in).

## // SYNC_API

Anyone can host a server the Mac app syncs to. A client needs only the server's base URL (here `https://askscottpierce.com/recordings`); everything else is discovered.

**Discovery and sign-in**

1. `GET {base}/api/v1` without a token returns `401` with `WWW-Authenticate: Bearer resource_metadata="…"` (RFC 9728).
2. That document names the resource (`{base}/api/v1`) and its issuer in `authorization_servers`.
3. The issuer's RFC 8414 metadata is at `{issuer origin}/.well-known/oauth-authorization-server{issuer path}` and lists the registration, authorization, and token endpoints.
4. The client registers itself (RFC 7591) as a public client (`token_endpoint_auth_method: none`) with a loopback redirect, `http://127.0.0.1/callback`. Any port is accepted on the loopback host (RFC 8252).
5. Authorization code with PKCE (S256), `resource={base}/api/v1`, scopes `recordings:read recordings:write offline_access`. Refresh tokens last 90 days past their last use.

**Endpoints** (under `{base}/api/v1`, `Authorization: Bearer …`)

| Method | Path | Scope | Does |
|---|---|---|---|
| GET | `/` | read | `{name, version, user, scope}` |
| GET | `/calls` | read | Every call: `id, title, their_name, my_name, started_at, duration, lines, preview` |
| GET | `/calls/{id}` | read | `{call, files: [{name, size, sha256, uploaded}], meeting}` |
| DELETE | `/calls/{id}` | write | Removes the call and its files |
| GET | `/calls/{id}/files/{name}` | read | The file; honors `Range` |
| PUT | `/calls/{id}/files/{name}` | write | Upload up to 95 MB. Send `X-Content-SHA256: <hex>` and the server checks the body against it. |
| POST | `/calls/{id}/files/{name}/uploads` | write | Start a multipart upload for bigger files → `{uploadId}`. Send `X-Content-SHA256` for the whole file. |
| PUT | `/calls/{id}/files/{name}/uploads/{uploadId}/{n}` | write | Part `n` (1-based; every part but the last at least 5 MB) → `{partNumber, etag}` |
| POST | `/calls/{id}/files/{name}/uploads/{uploadId}` | write | `{"parts": [...]}` finishes it |

`{id}` is the Mac app's folder name (`2026-10-15 140312`). `{name}` is one of `meeting.json`, `transcript.md`, `notes.md`, `me.m4a`, `them.m4a`. Uploading `meeting.json` updates the call list, so clients send it last. Clients skip any file whose SHA-256 matches the one the server reports.

## // MCP

`{base}/mcp` is an MCP server over Streamable HTTP, for AI agents:

```sh
claude mcp add --transport http recordings https://askscottpierce.com/recordings/mcp
```

It's a second OAuth protected resource on the same authorization server, so an agent discovers it the same way the sync client does: a `401` points at `/.well-known/oauth-protected-resource/recordings/mcp`. MCP clients usually authorize without naming a scope, and those get `recordings:read` only. The tools never write either way, and a token issued for one resource is refused by the other.

| Tool | Does |
|---|---|
| `list_calls` | The newest calls: id, title, when, who, length, line count |
| `search_calls` | Calls whose title, notes, or transcript contain every word of a query, with the matching lines |
| `get_call` | One call's notes, transcript, or both, as Markdown |

`src/mcp.ts` is stateless JSON-RPC with JSON responses and no SSE stream, which the spec allows and these quick reads don't need. `search_calls` reads the newest 300 calls' notes and transcripts from R2 on each call. That's fine for one person's calls; a bigger archive would want a full-text index in D1.

## Develop

```sh
npm install
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply recordings-auth --local
npm run dev       # http://localhost:8787/recordings/
npm test          # full OAuth + sync + MCP round trip against the dev server
```

`npm run dev` passes `--host localhost:8787`. Without it, wrangler dev rewrites the host to the route's zone, the issuer becomes `http://askscottpierce.com/recordings`, and the OAuth library rightly refuses plain http off loopback.

`.dev.vars` sets `DEV_LOGIN_CODES=1`, which shows sign-in codes on screen instead of emailing them. `test/e2e.mjs` takes a base URL, so it also works against another deployment that has dev codes on.

## Deploy

```sh
npx wrangler secret put ALLOWED_EMAILS   # once: who may sign in
npm run deploy                           # remote D1 migrations, then wrangler deploy
```

To host your own, create the D1 database, R2 bucket, and KV namespace (`wrangler d1 create`, `r2 bucket create`, `kv namespace create`), put their ids and your own routes and `EMAIL_FROM` in `wrangler.jsonc`, and point the Mac app at your URL in Settings → Sync.

Check the output for all four `askscottpierce.com/…recordings…` triggers and no `DEV_*` vars.
