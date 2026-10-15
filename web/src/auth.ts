// Passwordless email login, trimmed from ~/code/todo-agent/src/auth.ts. The user enters
// their email, we send a 6-digit code plus a one-click link carrying the same code, and a
// verified code becomes a 30-day session cookie. Only hashes of codes and tokens are stored.

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_COOLDOWN_MS = 30 * 1000;
const MAX_ATTEMPTS = 5;
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const EMAIL_GUESSES_PER_HOUR = 10;
const EMAIL_GUESSES_PER_DAY = 20;
const IP_GUESSES_PER_HOUR = 30;
const SESSION_TTL_S = 30 * 24 * 60 * 60;
// Path=/recordings keeps this cookie away from the other apps on askscottpierce.com.
const COOKIE = "recordings-sid";

export type User = { email: string };

const enc = new TextEncoder();

export async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  Response.json(body, { status, headers });

function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}

function allowed(env: Env, email: string): boolean {
  const list = (env.ALLOWED_EMAILS ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  return list.some((rule) => (rule.startsWith("@") ? email.endsWith(rule) : email === rule));
}

function randomCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function cookieValue(req: Request, name: string): string | null {
  for (const part of (req.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

function sessionCookie(req: Request, token: string, maxAge: number): string {
  const secure = new URL(req.url).protocol === "https:" ? "; Secure" : "";
  return `${COOKIE}=${token}; HttpOnly; SameSite=Lax; Path=/recordings; Max-Age=${maxAge}${secure}`;
}

async function createSession(req: Request, env: Env, email: string): Promise<string> {
  const token = randomToken();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO sessions (token_hash, email, expires_at, created_at) VALUES (?, ?, ?, ?)")
      .bind(await sha256(token), email, Date.now() + SESSION_TTL_S * 1000, Date.now()),
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(Date.now()),
    env.DB.prepare("DELETE FROM login_limits WHERE window_start < ?").bind(Date.now() - DAY_MS),
  ]);
  return sessionCookie(req, token, SESSION_TTL_S);
}

/** A per-session value for forms that change something (the OAuth consent screen). */
export async function csrfToken(req: Request): Promise<string | null> {
  const token = cookieValue(req, COOKIE);
  return token ? (await sha256(`csrf:${token}`)).slice(0, 32) : null;
}

export async function currentUser(req: Request, env: Env): Promise<User | null> {
  const token = cookieValue(req, COOKIE);
  if (!token) return null;
  const row = await env.DB.prepare("SELECT email FROM sessions WHERE token_hash = ? AND expires_at > ?")
    .bind(await sha256(token), Date.now())
    .first<{ email: string }>();
  return row ? { email: row.email } : null;
}

async function start(req: Request, env: Env): Promise<Response> {
  const body = await req.json<{ email?: unknown }>().catch(() => ({}) as { email?: unknown });
  const email = normalizeEmail(body.email);
  if (!email) return json({ error: "That doesn't look like an email address." }, 400);
  // Same answer either way, so the form doesn't reveal who's on the list.
  if (!allowed(env, email)) return json({ ok: true });

  const prev = await env.DB.prepare("SELECT sent_at FROM login_codes WHERE email = ?").bind(email).first<{ sent_at: number }>();
  if (prev && Date.now() - prev.sent_at < RESEND_COOLDOWN_MS) {
    return json({ error: "A code was just sent. Check your inbox, or try again in a few seconds." }, 429);
  }

  const code = randomCode();
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO login_codes (email, code_hash, expires_at, attempts, sent_at) VALUES (?, ?, ?, 0, ?)
     ON CONFLICT(email) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at,
       attempts = 0, sent_at = excluded.sent_at`,
  ).bind(email, await sha256(`${email}:${code}`), now + CODE_TTL_MS, now).run();

  // The link opens the app, which submits the code from JavaScript. A plain GET that
  // signed you in would be burned by mail scanners that prefetch links.
  const link = `${new URL(req.url).origin}/recordings/?email=${encodeURIComponent(email)}&code=${code}`;

  if (env.DEV_LOGIN_CODES === "1") {
    console.log(`[dev] login code for ${email}: ${code}  ${link}`);
    return json({ ok: true, devCode: code });
  }

  try {
    await env.EMAIL.send({
      from: { email: env.EMAIL_FROM, name: "Recordings" },
      to: email,
      subject: `${code} is your Recordings sign-in code`,
      text: `Your sign-in code is ${code}\n\nOr sign in with this link:\n${link}\n\nThe code expires in 10 minutes. If you didn't ask for it, you can ignore this email.`,
      html: loginEmailHtml(code, link),
    });
  } catch (e) {
    console.error("login email failed", (e as Error).message);
    return json({ error: "We couldn't send the email. Try again in a minute." }, 502);
  }
  return json({ ok: true });
}

/** Count one guess against `key`; one atomic statement so parallel requests can't race. */
async function spendGuess(env: Env, key: string, max: number, windowMs: number): Promise<boolean> {
  const now = Date.now();
  const row = await env.DB.prepare(
    `INSERT INTO login_limits (key, window_start, guesses) VALUES (?1, ?2, 1)
     ON CONFLICT(key) DO UPDATE SET
       guesses = CASE WHEN window_start <= ?3 THEN 1 ELSE guesses + 1 END,
       window_start = CASE WHEN window_start <= ?3 THEN ?2 ELSE window_start END
     RETURNING guesses`,
  ).bind(key, now, now - windowMs).first<{ guesses: number }>();
  return !!row && row.guesses <= max;
}

async function verify(req: Request, env: Env): Promise<Response> {
  const body = await req.json<{ email?: unknown; code?: unknown }>().catch(() => ({}) as Record<string, unknown>);
  const email = normalizeEmail(body.email);
  const code = String(body.code ?? "").trim();
  if (!email || !/^\d{6}$/.test(code)) return json({ error: "Enter the 6-digit code from the email." }, 400);

  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  const within = (await spendGuess(env, `ip:${ip}`, IP_GUESSES_PER_HOUR, HOUR_MS))
    && (await spendGuess(env, `email:${email}`, EMAIL_GUESSES_PER_HOUR, HOUR_MS))
    && (await spendGuess(env, `email-day:${email}`, EMAIL_GUESSES_PER_DAY, DAY_MS));
  if (!within) return json({ error: "Too many sign-in attempts. Wait a while and send a new code." }, 429);

  const row = await env.DB.prepare(
    `UPDATE login_codes SET attempts = attempts + 1
     WHERE email = ? AND expires_at > ? AND attempts < ?
     RETURNING code_hash, attempts`,
  ).bind(email, Date.now(), MAX_ATTEMPTS).first<{ code_hash: string; attempts: number }>();
  if (!row) return json({ error: "That code expired or ran out of tries. Send a new one." }, 400);
  if ((await sha256(`${email}:${code}`)) !== row.code_hash) {
    const left = MAX_ATTEMPTS - row.attempts;
    return json({ error: left > 0 ? `That code isn't right. ${left} ${left === 1 ? "try" : "tries"} left.` : "Too many tries. Send a new code." }, 400);
  }
  const used = await env.DB.prepare("DELETE FROM login_codes WHERE email = ? AND code_hash = ?").bind(email, row.code_hash).run();
  if (used.meta.changes !== 1) return json({ error: "That code was just used. Send a new one." }, 400);
  await env.DB.prepare("DELETE FROM login_limits WHERE key IN (?, ?)").bind(`email:${email}`, `email-day:${email}`).run();
  return json({ ok: true }, 200, { "Set-Cookie": await createSession(req, env, email) });
}

async function logout(req: Request, env: Env): Promise<Response> {
  const token = cookieValue(req, COOKIE);
  if (token) await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(token)).run();
  return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(req, "", 0) });
}

export async function handleAuth(req: Request, env: Env, path: string): Promise<Response | null> {
  if (path === "/api/auth/start" && req.method === "POST") return start(req, env);
  if (path === "/api/auth/verify" && req.method === "POST") return verify(req, env);
  if (path === "/api/auth/logout" && req.method === "POST") return logout(req, env);
  // "Not signed in" is an answer, not an error, so it's a 200 with null.
  if (path === "/api/me" && req.method === "GET") return json(await currentUser(req, env));
  return null;
}

function loginEmailHtml(code: string, link: string): string {
  return `<!doctype html><html><body style="margin:0;background:#f7f6f3;font-family:-apple-system,Segoe UI,Inter,sans-serif;color:#2c2c2c">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:40px 16px">
<table width="100%" style="max-width:440px;background:#fffef9;border:2px solid #2c2c2c" cellpadding="0" cellspacing="0"><tr><td style="padding:32px">
<div style="font-size:24px;font-weight:700;margin-bottom:24px">recordings<span style="color:#E85D00">.</span></div>
<div style="font-size:15px;color:#6b6b6b;margin-bottom:8px">Your sign-in code</div>
<div style="font-family:'JetBrains Mono',Menlo,monospace;font-size:36px;letter-spacing:8px;font-weight:700;margin-bottom:24px">${code}</div>
<a href="${link}" style="display:inline-block;background:#E85D00;color:#fff;text-decoration:none;font-weight:600;padding:12px 20px">Sign in with one click</a>
<p style="font-size:13px;color:#6b6b6b;margin:24px 0 0">The code expires in 10 minutes. If you didn't ask for it, ignore this email.</p>
</td></tr></table></td></tr></table></body></html>`;
}
