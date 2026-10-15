// The calls themselves: files in R2 under calls/<id>/<name>, plus a D1 row per call
// rebuilt from its meeting.json. Both the OAuth sync API (/api/v1) and the signed-in
// viewer (/api) route here; only the sync API may write.

const FILES = new Set(["meeting.json", "transcript.md", "notes.md", "me.m4a", "them.m4a"]);
// Workers cap a request body at 100 MB, so anything bigger goes up in parts.
const MAX_SINGLE_PUT = 95 * 1024 * 1024;

const json = (body: unknown, status = 200) => Response.json(body, { status });
export const error = (status: number, message: string) => json({ error: message }, status);

const key = (id: string, name?: string) => (name ? `calls/${id}/${name}` : `calls/${id}/`);

/** Call ids are the Mac app's folder names, like "2026-10-15 140312". */
function callId(raw: string): string | null {
  const id = decodeURIComponent(raw);
  return /^[\w][\w .:-]{0,79}$/.test(id) ? id : null;
}

type Meeting = {
  title?: string;
  theirName?: string;
  myName?: string;
  startedAt?: string;
  duration?: number;
  utterances?: { text?: string }[];
};

type FileInfo = { name: string; size: number; sha256: string | null; uploaded: string };

async function listFiles(env: Env, id: string): Promise<FileInfo[]> {
  const listed = await env.FILES.list({ prefix: key(id), include: ["customMetadata"] });
  return listed.objects.map((o) => ({
    name: o.key.slice(key(id).length),
    size: o.size,
    sha256: o.customMetadata?.sha256 ?? null,
    uploaded: o.uploaded.toISOString(),
  }));
}

async function index(env: Env, id: string, meeting: Meeting): Promise<void> {
  const lines = meeting.utterances ?? [];
  await env.DB.prepare(
    `INSERT INTO calls (id, title, their_name, my_name, started_at, duration, lines, preview, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET title = excluded.title, their_name = excluded.their_name,
       my_name = excluded.my_name, started_at = excluded.started_at, duration = excluded.duration,
       lines = excluded.lines, preview = excluded.preview, updated_at = excluded.updated_at`,
  ).bind(
    id,
    String(meeting.title ?? ""),
    String(meeting.theirName ?? "Them"),
    String(meeting.myName ?? "Me"),
    String(meeting.startedAt ?? new Date().toISOString()),
    Number(meeting.duration ?? 0),
    lines.length,
    lines.map((u) => u.text ?? "").join(" ").slice(0, 240),
    Date.now(),
  ).run();
}

async function listCalls(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    "SELECT id, title, their_name, my_name, started_at, duration, lines, preview FROM calls ORDER BY started_at DESC",
  ).all();
  return json({ calls: results });
}

async function getCall(env: Env, id: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT * FROM calls WHERE id = ?").bind(id).first();
  const files = await listFiles(env, id);
  if (!row && files.length === 0) return error(404, "No call with that id.");
  const meeting = await env.FILES.get(key(id, "meeting.json"));
  return json({ id, call: row, files, meeting: meeting ? await meeting.json() : null });
}

async function deleteCall(env: Env, id: string): Promise<Response> {
  const files = await listFiles(env, id);
  if (files.length) await env.FILES.delete(files.map((f) => key(id, f.name)));
  await env.DB.prepare("DELETE FROM calls WHERE id = ?").bind(id).run();
  return new Response(null, { status: 204 });
}

/** Streams a file, honoring Range so audio can seek. */
async function getFile(req: Request, env: Env, id: string, name: string): Promise<Response> {
  const object = await env.FILES.get(key(id, name), { range: req.headers, onlyIf: req.headers });
  if (!object) return error(404, "No such file.");
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", "private, no-cache");
  if (!("body" in object)) return new Response(null, { status: 304, headers });
  const range = object.range as { offset?: number; length?: number; suffix?: number } | undefined;
  if (range && req.headers.has("Range")) {
    const offset = range.suffix !== undefined ? object.size - range.suffix : (range.offset ?? 0);
    const length = range.suffix ?? range.length ?? object.size - offset;
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("Content-Length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(object.size));
  return new Response(object.body, { headers });
}

const contentType = (name: string) =>
  name.endsWith(".m4a") ? "audio/mp4" : name.endsWith(".json") ? "application/json" : "text/markdown; charset=utf-8";

const sha256Header = (req: Request) => {
  const value = req.headers.get("X-Content-SHA256")?.toLowerCase() ?? null;
  return value && /^[0-9a-f]{64}$/.test(value) ? value : null;
};

async function putFile(req: Request, env: Env, id: string, name: string): Promise<Response> {
  const size = Number(req.headers.get("Content-Length") ?? NaN);
  if (!Number.isFinite(size)) return error(411, "Send a Content-Length.");
  if (size > MAX_SINGLE_PUT) return error(413, "Too big for one request. Use a multipart upload.");
  const sha256 = sha256Header(req);

  if (name === "meeting.json") {
    const text = await req.text();
    let meeting: Meeting;
    try {
      meeting = JSON.parse(text);
    } catch {
      return error(400, "meeting.json isn't valid JSON.");
    }
    await env.FILES.put(key(id, name), text, {
      httpMetadata: { contentType: contentType(name) },
      customMetadata: sha256 ? { sha256 } : {},
      ...(sha256 ? { sha256 } : {}),
    });
    await index(env, id, meeting);
  } else {
    // R2 checks the body against sha256 when it's given, so a torn upload is refused.
    await env.FILES.put(key(id, name), req.body, {
      httpMetadata: { contentType: contentType(name) },
      customMetadata: sha256 ? { sha256 } : {},
      ...(sha256 ? { sha256 } : {}),
    });
  }
  return json({ ok: true, name, sha256 });
}

async function multipart(req: Request, env: Env, id: string, name: string, rest: string[]): Promise<Response> {
  const k = key(id, name);
  // POST …/uploads → start
  if (rest.length === 0 && req.method === "POST") {
    const sha256 = sha256Header(req);
    const upload = await env.FILES.createMultipartUpload(k, {
      httpMetadata: { contentType: contentType(name) },
      customMetadata: sha256 ? { sha256 } : {},
    });
    return json({ uploadId: upload.uploadId });
  }
  const upload = env.FILES.resumeMultipartUpload(k, decodeURIComponent(rest[0]));
  // PUT …/uploads/<uploadId>/<partNumber> → one part
  if (rest.length === 2 && req.method === "PUT") {
    const part = Number(rest[1]);
    if (!Number.isInteger(part) || part < 1 || part > 10000) return error(400, "Part numbers run from 1 to 10000.");
    if (!req.body) return error(400, "Send the part as the body.");
    const uploaded = await upload.uploadPart(part, req.body);
    return json({ partNumber: uploaded.partNumber, etag: uploaded.etag });
  }
  // POST …/uploads/<uploadId> with {"parts": [...]} → finish; DELETE → abandon
  if (rest.length === 1 && req.method === "POST") {
    const body = await req.json<{ parts?: R2UploadedPart[] }>().catch(() => ({}) as { parts?: R2UploadedPart[] });
    if (!Array.isArray(body.parts) || body.parts.length === 0) return error(400, "Send the uploaded parts.");
    await upload.complete(body.parts);
    return json({ ok: true, name });
  }
  if (rest.length === 1 && req.method === "DELETE") {
    await upload.abort();
    return new Response(null, { status: 204 });
  }
  return error(405, "Not a multipart operation.");
}

/**
 * Routes `/calls…` (the part after /api or /api/v1). `canWrite` is true only for a token
 * that carries the recordings:write scope.
 */
export async function handleCalls(req: Request, env: Env, path: string, canWrite: boolean): Promise<Response> {
  const parts = path.split("/").filter(Boolean); // ["calls", id, "files", name, "uploads", …]
  if (parts[0] !== "calls") return error(404, "Not found.");
  const write = req.method !== "GET" && req.method !== "HEAD";
  if (write && !canWrite) return error(403, "This needs the recordings:write scope.");

  if (parts.length === 1) return req.method === "GET" ? listCalls(env) : error(405, "Use GET.");
  const id = callId(parts[1]);
  if (!id) return error(400, "That isn't a valid call id.");

  if (parts.length === 2) {
    if (req.method === "GET") return getCall(env, id);
    if (req.method === "DELETE") return deleteCall(env, id);
    return error(405, "Use GET or DELETE.");
  }
  if (parts[2] !== "files" || parts.length < 4) return error(404, "Not found.");
  const name = decodeURIComponent(parts[3]);
  if (!FILES.has(name)) return error(400, `Files are named ${[...FILES].join(", ")}.`);

  if (parts.length === 4) {
    if (req.method === "GET" || req.method === "HEAD") return getFile(req, env, id, name);
    if (req.method === "PUT") return putFile(req, env, id, name);
    return error(405, "Use GET or PUT.");
  }
  if (parts[4] === "uploads") return multipart(req, env, id, name, parts.slice(5));
  return error(404, "Not found.");
}
