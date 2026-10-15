// Viewer for synced CF Recorder calls. Hash routes: #/ is the list, #/c/<id> is one call.
const BASE = "/recordings";
const api = (path) => `${BASE}${path}`;
const view = document.getElementById("view");
const who = document.getElementById("who");

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const clock = (sec) => {
  const s = Math.max(0, Math.floor(sec || 0));
  const hms = [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60];
  return (hms[0] ? `${hms[0]}:` : "") + hms.slice(1).map((n) => String(n).padStart(2, "0")).join(":");
};
const when = (iso) => new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });

async function getJSON(path, init) {
  const res = await fetch(api(path), { credentials: "same-origin", ...init });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw Object.assign(new Error(body?.error || `HTTP ${res.status}`), { status: res.status });
  return body;
}
const post = (path, data) => getJSON(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });

// ---- Sign in ----

/** Only the OAuth consent page may be a post-login destination. */
const safeNext = (raw) => (raw && raw.startsWith(`${BASE}/oauth/authorize?`) ? raw : null);

function renderLogin(params) {
  const next = safeNext(params.get("next"));
  view.innerHTML = `
    <div class="login">
      <p class="h">sign_in</p>
      <h1>${next ? "Sign in to connect an app." : "Your call recordings."}</h1>
      <p class="muted">We'll email you a 6-digit code.</p>
      <form id="emailForm"><input id="email" type="email" placeholder="you@example.com" autocomplete="email" required><button class="btn primary">Send code</button></form>
      <form id="codeForm" hidden><input id="code" inputmode="numeric" pattern="\\d{6}" maxlength="6" placeholder="123456" autocomplete="one-time-code" required><button class="btn primary">Sign in</button></form>
      <p class="err" id="err"></p>
    </div>`;
  const err = view.querySelector("#err");
  const emailForm = view.querySelector("#emailForm");
  const codeForm = view.querySelector("#codeForm");
  let email = "";

  const finish = () => {
    history.replaceState(null, "", `${BASE}/`);
    if (next) location.href = next;
    else start();
  };

  emailForm.onsubmit = async (e) => {
    e.preventDefault();
    err.textContent = "";
    email = view.querySelector("#email").value;
    try {
      const r = await post("/api/auth/start", { email });
      emailForm.hidden = true;
      codeForm.hidden = false;
      const code = view.querySelector("#code");
      if (r.devCode) code.value = r.devCode;
      code.focus();
      err.textContent = `Check ${email} for the code.`;
    } catch (x) { err.textContent = x.message; }
  };
  codeForm.onsubmit = async (e) => {
    e.preventDefault();
    err.textContent = "";
    try {
      await post("/api/auth/verify", { email, code: view.querySelector("#code").value });
      finish();
    } catch (x) { err.textContent = x.message; }
  };

  // The one-click email link carries the code; submit it from here, never on a bare GET.
  if (params.get("email") && params.get("code")) {
    email = params.get("email");
    post("/api/auth/verify", { email, code: params.get("code") })
      .then(finish)
      .catch((x) => { err.textContent = x.message; });
  }
}

// ---- List ----

async function renderList() {
  view.innerHTML = `<div class="list"><p class="muted mono">loading…</p></div>`;
  const { calls } = await getJSON("/api/calls");
  const draw = (q) => {
    const needle = q.trim().toLowerCase();
    const shown = calls.filter((c) => !needle || `${c.title} ${c.their_name} ${c.preview}`.toLowerCase().includes(needle));
    view.querySelector("#calls").innerHTML = shown.length
      ? shown.map((c) => `
        <a class="call" href="#/c/${encodeURIComponent(c.id)}">
          <div class="t">${esc(c.title || "Untitled call")}</div>
          <div class="m">${esc(when(c.started_at))} · ${clock(c.duration)} · with ${esc(c.their_name)} · ${c.lines} lines</div>
          ${c.preview ? `<div class="p">${esc(c.preview)}</div>` : ""}
        </a>`).join("")
      : `<div class="empty mono">${calls.length ? "Nothing matches." : "No calls yet. Connect CF Recorder on your Mac in Settings → Sync."}</div>`;
  };
  view.innerHTML = `
    <div class="list">
      <div class="bar"><p class="h">calls</p><input id="q" type="search" placeholder="Search calls"></div>
      <div id="calls"></div>
    </div>`;
  view.querySelector("#q").oninput = (e) => draw(e.target.value);
  draw("");
}

// ---- One call ----

function notesHTML(md) {
  const inline = (s) => esc(s)
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>")
    .replace(/_([^_]+)_/g, "<em>$1</em>");
  return md.split("\n").map((raw) => {
    const line = raw.trim();
    if (!line) return "";
    if (line.startsWith("#")) return `<p class="h">${esc(line.replace(/^#+\s*/, "").replace(/\s+/g, "_"))}</p>`;
    const todo = line.match(/^- \[( |x|X)\]\s*(.*)$/);
    if (todo) {
      const done = todo[1] !== " ";
      return `<div class="todo${done ? " done" : ""}"><span class="box">${done ? "[x]" : "[ ]"}</span><span>${inline(todo[2])}</span></div>`;
    }
    if (/^[-*] /.test(line)) return `<div class="li"><span>${inline(line.slice(2))}</span></div>`;
    return `<p>${inline(line)}</p>`;
  }).join("");
}

async function renderCall(id) {
  view.innerHTML = `<p class="muted mono pad">loading…</p>`;
  const data = await getJSON(`/api/calls/${encodeURIComponent(id)}`);
  const m = data.meeting ?? {};
  const names = { me: m.myName || "Me", them: m.theirName || "Them" };
  const has = new Set(data.files.map((f) => f.name));
  const file = (name) => api(`/api/calls/${encodeURIComponent(id)}/files/${name}`);
  const utterances = m.utterances ?? [];

  view.innerHTML = `
    <div class="callview">
      <section>
        <div class="head">
          <h1>${esc(m.title || "Untitled call")}</h1>
          <div class="m">${m.startedAt ? esc(when(m.startedAt)) : ""} · ${clock(m.duration)} · ${esc(names.me)} and ${esc(names.them)}</div>
          ${has.has("me.m4a") || has.has("them.m4a") ? `
          <div class="player">
            <button id="play"><span class="d">$</span> <span id="playLabel">play</span></button>
            <input id="seek" type="range" min="0" max="${Math.max(1, Math.ceil(m.duration || 1))}" step="0.1" value="0">
            <span class="time" id="time">00:00 / ${clock(m.duration)}</span>
            <select id="rate"><option>1</option><option>1.25</option><option>1.5</option><option>2</option></select>
          </div>` : ""}
          <div class="files">${[...has].sort().map((n) => `<a href="${file(n)}" download>${esc(n)}</a>`).join("")}</div>
        </div>
        <div class="section-bar"><p class="h">transcript</p><span class="muted mono" style="font-size:12px">${utterances.length} lines</span></div>
        <div class="transcript" id="transcript">
          ${utterances.map((u, i) => {
            const prev = utterances[i - 1];
            const head = !prev || prev.speaker !== u.speaker || u.start - prev.end > 20;
            return `<div class="u ${u.speaker === "me" ? "me" : "them"}" data-start="${u.start}" data-end="${u.end}">
              ${head ? `<div class="who">${esc(names[u.speaker] ?? u.speaker)}<time>${clock(u.start)}</time></div>` : ""}
              <div class="b">${esc(u.text)}</div></div>`;
          }).join("") || `<p class="muted mono">Nothing was transcribed.</p>`}
        </div>
      </section>
      <aside class="notes">
        <div class="section-bar"><p class="h">notes</p></div>
        <div class="body">${m.notes ? notesHTML(m.notes) : `<p class="muted mono">No notes for this call.</p>`}</div>
      </aside>
    </div>`;

  // Both tracks play together on one clock; "me" leads and "them" follows it.
  const tracks = ["me", "them"].filter((t) => has.has(`${t}.m4a`)).map((t) => {
    const a = new Audio(file(`${t}.m4a`));
    a.preload = "metadata";
    return a;
  });
  if (!tracks.length) return;
  const lead = tracks[0];
  const playBtn = view.querySelector("#playLabel");
  const seek = view.querySelector("#seek");
  const time = view.querySelector("#time");
  const bubbles = [...view.querySelectorAll(".u")];
  let dragging = false;

  const setTime = (t) => tracks.forEach((a) => { a.currentTime = t; });
  const play = () => Promise.all(tracks.map((a) => a.play())).catch(() => {});
  const pause = () => tracks.forEach((a) => a.pause());
  view.querySelector("#play").onclick = () => (lead.paused ? play() : pause());
  view.querySelector("#rate").onchange = (e) => tracks.forEach((a) => { a.playbackRate = Number(e.target.value); });
  seek.oninput = () => { dragging = true; time.textContent = `${clock(seek.value)} / ${clock(m.duration)}`; };
  seek.onchange = () => { dragging = false; setTime(Number(seek.value)); };
  bubbles.forEach((b) => b.querySelector(".b").addEventListener("click", () => {
    setTime(Math.max(0, Number(b.dataset.start) - 0.4));
    play();
  }));
  lead.onplay = () => { playBtn.textContent = "pause"; };
  lead.onpause = () => { playBtn.textContent = "play"; };
  lead.onended = pause;
  lead.ontimeupdate = () => {
    const t = lead.currentTime;
    for (const a of tracks.slice(1)) if (!a.paused && Math.abs(a.currentTime - t) > 0.25) a.currentTime = t;
    if (!dragging) seek.value = t;
    time.textContent = `${clock(t)} / ${clock(m.duration)}`;
    let current = null;
    for (const b of bubbles) {
      const on = t >= Number(b.dataset.start) && t <= Number(b.dataset.end) + 0.3;
      b.classList.toggle("now", on);
      if (on) current = b;
    }
    if (current && !lead.paused) {
      const r = current.getBoundingClientRect();
      if (r.top < 80 || r.bottom > innerHeight) current.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  };
}

// ---- Account menu ----

// Lucide "user-round". The email stays behind this button so the header carries no name.
const ICON_USER = `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="8" r="5"/><path d="M20 21a8 8 0 0 0-16 0"/></svg>`;

function renderAccount() {
  if (!user) { who.innerHTML = ""; return; }
  who.innerHTML = `
    <div class="anchor">
      <button class="icon-btn" id="account" title="${esc(user.email)}" aria-label="Account" aria-haspopup="menu" aria-expanded="false">${ICON_USER}</button>
      <div class="popover" id="accountMenu" role="menu" aria-label="Account, ${esc(user.email)}" hidden>
        <div class="menu-who">${esc(user.email)}</div>
        <button class="danger" role="menuitem" id="out">Sign out</button>
      </div>
    </div>`;
  const button = who.querySelector("#account");
  const menu = who.querySelector("#accountMenu");
  const setOpen = (open) => {
    menu.hidden = !open;
    button.setAttribute("aria-expanded", String(open));
    if (open) menu.querySelector("[role=menuitem]").focus();
  };
  button.onclick = (e) => { e.stopPropagation(); setOpen(menu.hidden); };
  menu.onclick = (e) => e.stopPropagation();
  document.addEventListener("click", () => setOpen(false));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !menu.hidden) { setOpen(false); button.focus(); } });
  who.querySelector("#out").onclick = async () => { await post("/api/auth/logout", {}); user = null; start(); };
}

// ---- Shell ----

let user = null;

async function route() {
  const params = new URLSearchParams(location.search);
  if (!user) return renderLogin(params);
  const m = location.hash.match(/^#\/c\/(.+)$/);
  try {
    if (m) await renderCall(decodeURIComponent(m[1]));
    else await renderList();
  } catch (x) {
    if (x.status === 401) { user = null; return start(); }
    view.innerHTML = `<p class="err pad">${esc(x.message)}</p>`;
  }
}

async function start() {
  user = await getJSON("/api/me").catch(() => null);
  const next = safeNext(new URLSearchParams(location.search).get("next"));
  if (user && next) { location.href = next; return; }
  renderAccount();
  route();
}

addEventListener("hashchange", route);
start();
