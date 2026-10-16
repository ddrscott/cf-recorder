// askscottpierce.com/recordings: the web side of Recorder.
//
//   /recordings/                 viewer (static files in public/recordings)
//   /recordings/api/…            viewer API, signed-in session cookie, read plus trash/restore
//   /recordings/api/v1/…         sync API, OAuth bearer token (README // SYNC_API)
//   /recordings/mcp              MCP server for AI agents, OAuth bearer token, read-only
//   /recordings/oauth/…          authorize (ours), token, register, revoke (the provider's)
//   /.well-known/…/recordings…   RFC 8414 and RFC 9728 discovery
//
// The issuer is built from the request's origin, so the same code runs under wrangler dev,
// on askscottpierce.com, or on anyone else's domain.

import { OAuthAuthorizationServer, OAuthResourceServer, type OAuthResourceContext } from "@cloudflare/workers-oauth-provider";
import { currentUser, handleAuth } from "./auth";
import { error, handleCalls, purgeTrash } from "./calls";
import { handleMcp } from "./mcp";
import { AUTHORIZE_PATH, handleAuthorize } from "./oauth";

const BASE = "/recordings"; // don't export plain values from the Worker entry module
const API_V1 = `${BASE}/api/v1`;
const MCP = `${BASE}/mcp`;

type Props = { email: string };

type OAuth = {
  server: OAuthAuthorizationServer<Env>;
  resource: OAuthResourceServer<Env, Props>;
  mcp: OAuthResourceServer<Env, Props>;
};
const byOrigin = new Map<string, OAuth>();

function oauthFor(origin: string): OAuth {
  const cached = byOrigin.get(origin);
  if (cached) return cached;
  const issuer = `${origin}${BASE}`;
  const resourceUrl = `${origin}${API_V1}`;
  const mcpUrl = `${origin}${MCP}`;
  const server = new OAuthAuthorizationServer<Env>({
    issuer,
    resources: [resourceUrl, mcpUrl],
    defaultResource: resourceUrl,
    authorizeEndpoint: AUTHORIZE_PATH,
    tokenEndpoint: `${BASE}/oauth/token`,
    clientRegistrationEndpoint: `${BASE}/oauth/register`,
    scopesSupported: ["recordings:read", "recordings:write", "offline_access"],
    accessTokenTTL: 60 * 60,
    // A sync client keeps its grant as long as it keeps syncing; 90 idle days ends it.
    refreshTokenTTL: 90 * 24 * 60 * 60,
    refreshTokenIdleTTL: 90 * 24 * 60 * 60,
  });
  const resource = new OAuthResourceServer<Env, Props>({
    resourceMetadata: { resource: resourceUrl, authorization_servers: [issuer] },
    requiredScopes: ["recordings:read"],
    validateToken: (env) => (res, token) => server.validateToken(res, token, env),
    handler: {
      fetch(req: Request, env: Env, ctx: OAuthResourceContext<Props>) {
        const sub = new URL(req.url).pathname.slice(API_V1.length);
        if (sub === "" || sub === "/") {
          return Response.json({ name: "cf-recorder-sync", version: 2, user: ctx.props.email, scope: ctx.auth.scope });
        }
        if (!ctx.auth.scope.includes("recordings:read")) return error(403, "This needs the recordings:read scope.");
        return handleCalls(req, env, sub, ctx.auth.scope.includes("recordings:write") ? "write" : "read");
      },
    },
  });
  // Agents get read-only access: the MCP tools never write, whatever the token's scope.
  const mcp = new OAuthResourceServer<Env, Props>({
    resourceMetadata: { resource: mcpUrl, authorization_servers: [issuer], resource_name: "Recordings" },
    requiredScopes: ["recordings:read"],
    validateToken: (env) => (res, token) => server.validateToken(res, token, env),
    handler: { fetch: (req: Request, env: Env) => handleMcp(req, env) },
  });
  const made = { server, resource, mcp };
  byOrigin.set(origin, made);
  return made;
}

async function app(req: Request, env: Env, sub: string): Promise<Response> {
  if (sub.startsWith("/api/")) {
    const auth = await handleAuth(req, env, sub);
    if (auth) return auth;
    if (!(await currentUser(req, env))) return error(401, "Sign in first.");
    return handleCalls(req, env, sub.slice("/api".length), "trash");
  }
  // /recordings → /recordings/ so relative asset paths resolve.
  if (sub === "") return Response.redirect(new URL(`${BASE}/`, req.url).toString(), 301);
  return env.ASSETS.fetch(req);
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const path = url.pathname;
    const { server, resource, mcp } = oauthFor(url.origin);

    if (path.startsWith("/.well-known/oauth-authorization-server")) return server.fetch(req, env, ctx);
    if (path === `/.well-known/oauth-protected-resource${MCP}`) return mcp.fetch(req, env, ctx);
    if (path.startsWith("/.well-known/oauth-protected-resource")) return resource.fetch(req, env, ctx);
    if (path === AUTHORIZE_PATH) return handleAuthorize(req, env, server.getOAuthApi(env));
    if (path.startsWith(`${BASE}/oauth/`)) return server.fetch(req, env, ctx);
    if (path === API_V1 || path.startsWith(`${API_V1}/`)) return resource.fetch(req, env, ctx);
    if (path === MCP) return mcp.fetch(req, env, ctx);
    if (path !== BASE && !path.startsWith(`${BASE}/`)) return new Response("Not found", { status: 404 });
    return app(req, env, path.slice(BASE.length));
  },

  async scheduled(_event, env) {
    const purged = await purgeTrash(env);
    if (purged) console.log(`Emptied ${purged} call(s) from the trash.`);
  },
} satisfies ExportedHandler<Env>;
