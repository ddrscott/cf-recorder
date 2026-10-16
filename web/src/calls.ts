// The calls themselves: files in R2 under calls/<id>/<name>, plus a D1 row per call
// rebuilt from its meeting.json. Both the OAuth sync API (/api/v1) and the signed-in
// viewer (/api) route here. Only the sync API may upload; either may trash and restore.
//
// Trashing is soft: the row gets a trashed_at and the files stay put, so a call can come
// back. Lists, the viewer, and MCP leave trashed calls out, and purgeTrash() deletes them
// for good after TRASH_DAYS.

const FILES = new Set(["meeting.json", "transcript.md", "notes.md", "me.m4a", "them.m4a"]);
// Workers cap a request body at 100 MB, so anything bigger goes up in parts.
const MAX_SINGLE_PUT = 95 * 1024 * 1024;
export const TRASH_DAYS = 30;

/** What a caller may do: read, also trash/restore/purge calls, or also upload. */
export type Access = "read" | "trash" | "write";

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

/** The live calls, or with ?trash=1 the trashed ones. */
async function listCalls(env: Env, trash: boolean): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT id, title, their_name, my_name, started_at, duration, lines, preview, trashed_at FROM calls
     WHERE trashed_at IS ${trash ? "NOT NULL" : "NULL"} ORDER BY ${trash ? "trashed_at" : "started_at"} DESC`,
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

async function purgeCall(env: Env, id: string): Promise<void> {
  const files = await listFiles(env, id);
  if (files.length) await env.FILES.delete(files.map((f) => key(id, f.name)));
  await env.DB.prepare("DELETE FROM calls WHERE id = ?").bind(id).run();
}

/** DELETE moves a call to the trash; DELETE ?forever=1 deletes it and its files now. */
async function deleteCall(env: Env, id: string, forever: boolean): Promise<Response> {
  const row = await env.DB.prepare("SELECT trashed_at FROM calls WHERE id = ?").bind(id).first();
  // Files without a row never got their meeting.json, so there's nothing to show in the trash.
  if (forever || !row) await purgeCall(env, id);
  else await env.DB.prepare("UPDATE calls SET trashed_at = ? WHERE id = ? AND trashed_at IS NULL").bind(Date.now(), id).run();
  return new Response(null, { status: 204 });
}

async function restoreCall(env: Env, id: string): Promise<Response> {
  const done = await env.DB.prepare("UPDATE calls SET trashed_at = NULL WHERE id = ?").bind(id).run();
  if (!done.meta.changes) return error(404, "No call with that id.");
  return new Response(null, { status: 204 });
}

/** Run daily from the cron trigger: empties calls that have been in the trash TRASH_DAYS. */
export async function purgeTrash(env: Env): Promise<number> {
  const cutoff = Date.now() - TRASH_DAYS * 24 * 60 * 60 * 1000;
  const { results } = await env.DB.prepare("SELECT id FROM calls WHERE trashed_at < ?").bind(cutoff).all<{ id: string }>();
  for (const { id } of results) await purgeCall(env, id);
  return results.length;
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
 * Routes `/calls…` (the part after /api or /api/v1). `access` is "write" only for a token
 * that carries the recordings:write scope; the signed-in viewer gets "trash".
 */
export async function handleCalls(req: Request, env: Env, path: string, access: Access): Promise<Response> {
  const parts = path.split("/").filter(Boolean); // ["calls", id, "files", name, "uploads", …]
  if (parts[0] !== "calls") return error(404, "Not found.");
  const write = req.method !== "GET" && req.method !== "HEAD";
  const trashing = (parts.length === 2 && req.method === "DELETE") || (parts.length === 3 && parts[2] === "restore");
  if (write && access === "read") return error(403, "This needs the recordings:write scope.");
  if (write && access === "trash" && !trashing) return error(403, "Only the sync API can upload.");

  if (parts.length === 1) {
    return req.method === "GET" ? listCalls(env, new URL(req.url).searchParams.has("trash")) : error(405, "Use GET.");
  }
  const id = callId(parts[1]);
  if (!id) return error(400, "That isn't a valid call id.");

  if (parts.length === 2) {
    if (req.method === "GET") return getCall(env, id);
    if (req.method === "DELETE") return deleteCall(env, id, new URL(req.url).searchParams.has("forever"));
    return error(405, "Use GET or DELETE.");
  }
  if (parts.length === 3 && parts[2] === "restore") {
    return req.method === "POST" ? restoreCall(env, id) : error(405, "Use POST.");
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
