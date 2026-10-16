// Viewer for synced Recorder calls. Hash routes: #/ is the list, #/c/<id> is one call,
// #/trash is the trash.
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
const callPath = (id) => `/api/calls/${encodeURIComponent(id)}`;
const trashCall = (id) => fetch(api(callPath(id)), { method: "DELETE", credentials: "same-origin" }).then(okOrThrow);
const restoreCall = (id) => fetch(api(`${callPath(id)}/restore`), { method: "POST", credentials: "same-origin" }).then(okOrThrow);
const purgeCall = (id) => fetch(api(`${callPath(id)}?forever=1`), { method: "DELETE", credentials: "same-origin" }).then(okOrThrow);
async function okOrThrow(res) {
  if (res.ok) return;
  const body = await res.json().catch(() => null);
  throw Object.assign(new Error(body?.error || `HTTP ${res.status}`), { status: res.status });
}

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
      : `<div class="empty mono">${calls.length ? "Nothing matches." : "No calls yet. Connect Recorder on your Mac in Settings → Sync."}</div>`;
  };
  view.innerHTML = `
    <div class="list">
      <div class="bar"><p class="h">calls</p><input id="q" type="search" placeholder="Search calls"><a class="link" href="#/trash">trash</a></div>
      <div id="calls"></div>
    </div>`;
  view.querySelector("#q").oninput = (e) => draw(e.target.value);
  draw("");
}

// ---- Trash ----

const TRASH_DAYS = 30;

async function renderTrash() {
  view.innerHTML = `<div class="list"><p class="muted mono">loading…</p></div>`;
  const { calls } = await getJSON("/api/calls?trash=1");
  const left = (ms) => Math.max(0, Math.ceil(TRASH_DAYS - (Date.now() - ms) / 86400000));
  view.innerHTML = `
    <div class="list">
      <div class="bar"><p class="h">trash</p><a class="link" href="#/">calls</a></div>
      <p class="muted small mono">Calls here are deleted for good ${TRASH_DAYS} days after they were trashed. Restoring one here puts it back on your Mac too.</p>
      <div id="calls">${calls.length ? calls.map((c) => `
        <div class="call trashed" data-id="${esc(c.id)}">
          <a class="t" href="#/c/${encodeURIComponent(c.id)}">${esc(c.title || "Untitled call")}</a>
          <div class="m">${esc(when(c.started_at))} · ${clock(c.duration)} · with ${esc(c.their_name)} · ${left(c.trashed_at)}d left</div>
          <div class="actions">
            <button class="act" data-do="restore"><span class="d">$</span> restore</button>
            <button class="act danger" data-do="purge">delete forever</button>
          </div>
        </div>`).join("") : `<div class="empty mono">The trash is empty.</div>`}</div>
    </div>`;
  view.querySelectorAll(".call.trashed").forEach((row) => row.querySelector(".actions").addEventListener("click", async (e) => {
    const button = e.target.closest("button");
    if (!button) return;
    // Deleting forever takes a second click, since it can't be undone.
    if (button.dataset.do === "purge" && !button.dataset.armed) {
      button.dataset.armed = "1";
      button.textContent = "click again to delete";
      return;
    }
    button.disabled = true;
    try {
      await (button.dataset.do === "restore" ? restoreCall : purgeCall)(row.dataset.id);
      row.remove();
      if (!view.querySelector(".call.trashed")) view.querySelector("#calls").innerHTML = `<div class="empty mono">The trash is empty.</div>`;
    } catch (x) {
      button.disabled = false;
      button.textContent = x.message;
    }
  }));
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

/** Undoes whatever the current view started (audio, listeners), so leaving a call stops it. */
let teardown = null;

async function renderCall(id) {
  view.innerHTML = `<p class="muted mono pad">loading…</p>`;
  const data = await getJSON(`/api/calls/${encodeURIComponent(id)}`);
  const m = data.meeting ?? {};
  const names = { me: m.myName || "Me", them: m.theirName || "Them" };
  const has = new Set(data.files.map((f) => f.name));
  const file = (name) => api(`/api/calls/${encodeURIComponent(id)}/files/${name}`);
  const utterances = m.utterances ?? [];
  const audible = ["me", "them"].filter((t) => has.has(`${t}.m4a`));
  const trashed = Boolean(data.call?.trashed_at);

  document.body.classList.add("is-call");
  view.innerHTML = `
    <div class="callpage">
      <div class="head">
        <div class="title">
          <h1>${esc(m.title || "Untitled call")}</h1>
          <div class="m">${trashed ? `<span class="tag">in trash</span> · ` : ""}${m.startedAt ? esc(when(m.startedAt)) : ""} · ${clock(m.duration)} · <span class="spk me">${esc(names.me)}</span> and <span class="spk them">${esc(names.them)}</span></div>
        </div>
        ${trashed
          ? `<button class="act" id="restore"><span class="d">$</span> restore</button>`
          : `<button class="act" id="trash">move to trash</button>`}
      </div>
      <div class="tabs" role="tablist">
        <button role="tab" data-pane="transcript" aria-selected="true">transcript</button>
        <button role="tab" data-pane="notes" aria-selected="false">notes</button>
      </div>
      <div class="callview" data-pane="transcript">
        <section class="pane transcript-pane" id="transcriptPane">
          <div class="section-bar">
            <p class="h">transcript</p>
            <span class="muted mono small">${utterances.length} lines</span>
            <button class="follow" id="follow" hidden><span class="d">$</span> follow</button>
          </div>
          <div class="transcript">
            ${utterances.map((u, i) => {
              const prev = utterances[i - 1];
              const head = !prev || prev.speaker !== u.speaker || u.start - prev.end > 20;
              return `<div class="u ${u.speaker === "me" ? "me" : "them"}" data-start="${u.start}" data-end="${u.end}">
                ${head ? `<div class="who">${esc(names[u.speaker] ?? u.speaker)}<time>${clock(u.start)}</time></div>` : ""}
                <div class="b">${esc(u.text)}</div></div>`;
            }).join("") || `<p class="muted mono">Nothing was transcribed.</p>`}
          </div>
        </section>
        <aside class="pane notes">
          <div class="section-bar"><p class="h">notes</p></div>
          <div class="body">${m.notes ? notesHTML(m.notes) : `<p class="muted mono">No notes for this call.</p>`}</div>
          <div class="section-bar"><p class="h">files</p></div>
          <div class="files">${[...has].sort().map((n) => `<a href="${file(n)}" download>${esc(n)}</a>`).join("")}</div>
        </aside>
      </div>
      ${audible.length ? `
      <footer class="dock">
        <button class="play" id="play" aria-label="Play"><span class="d">$</span> <span id="playLabel">play</span></button>
        <span class="time" id="now">00:00</span>
        <div class="wave" id="wave" role="slider" tabindex="0" aria-label="Seek" aria-valuemin="0" aria-valuemax="${Math.round(m.duration || 0)}" aria-valuenow="0">
          <canvas></canvas>
          <span class="lane me">${esc(names.me)}</span>
          <span class="lane them">${esc(names.them)}</span>
          <span class="tip" hidden></span>
        </div>
        <span class="time" id="total">${clock(m.duration)}</span>
        <select id="rate" aria-label="Speed"><option value="1">1×</option><option value="1.25">1.25×</option><option value="1.5">1.5×</option><option value="2">2×</option></select>
      </footer>` : ""}
    </div>`;

  const act = view.querySelector(".head .act");
  act.onclick = () => {
    act.disabled = true;
    (trashed ? restoreCall : trashCall)(id).then(
      () => (trashed ? route() : (location.hash = "#/")),
      (x) => { act.disabled = false; act.textContent = x.message; },
    );
  };

  // Narrow screens show one pane at a time.
  const callview = view.querySelector(".callview");
  view.querySelectorAll(".tabs [role=tab]").forEach((tab) => tab.addEventListener("click", () => {
    callview.dataset.pane = tab.dataset.pane;
    view.querySelectorAll(".tabs [role=tab]").forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
  }));

  if (!audible.length) return;

  // Both tracks play together on one clock; "me" leads and "them" follows it.
  const tracks = audible.map((t) => {
    const a = new Audio(file(`${t}.m4a`));
    a.preload = "metadata";
    return a;
  });
  const lead = tracks[0];
  const duration = () => (Number.isFinite(lead.duration) && lead.duration) || m.duration || 1;
  const playLabel = view.querySelector("#playLabel");
  const nowEl = view.querySelector("#now");
  const pane = view.querySelector("#transcriptPane");
  const followBtn = view.querySelector("#follow");
  const bubbles = [...view.querySelectorAll(".u")];
  const wave = view.querySelector("#wave");
  const canvas = wave.querySelector("canvas");
  const tip = wave.querySelector(".tip");
  const aborter = new AbortController();
  let scrubTo = null; // seconds while dragging the waveform, otherwise null
  let hoverX = null;
  let follow = true;
  let current = null;
  let frame = 0;

  const setTime = (t) => {
    t = Math.min(Math.max(0, t), duration());
    tracks.forEach((a) => { a.currentTime = t; });
    tick();
  };
  const play = () => Promise.all(tracks.map((a) => a.play())).catch(() => {});
  const pause = () => tracks.forEach((a) => a.pause());
  const toggle = () => (lead.paused ? play() : pause());

  view.querySelector("#play").onclick = toggle;
  view.querySelector("#rate").onchange = (e) => tracks.forEach((a) => { a.playbackRate = Number(e.target.value); });
  bubbles.forEach((b) => b.querySelector(".b").addEventListener("click", () => {
    setFollow(true);
    setTime(Number(b.dataset.start) - 0.4);
    play();
  }));
  lead.onplay = () => { playLabel.textContent = "pause"; loop(); };
  lead.onpause = () => { playLabel.textContent = "play"; tick(); };
  lead.onended = pause;
  lead.onloadedmetadata = () => { view.querySelector("#total").textContent = clock(duration()); tick(); };

  // Scrolling the transcript yourself stops it following playback until you ask it to.
  const setFollow = (on) => { follow = on; followBtn.hidden = on; };
  followBtn.onclick = () => { setFollow(true); if (current) center(current, "smooth"); };
  for (const type of ["wheel", "touchmove"]) pane.addEventListener(type, () => { if (!lead.paused) setFollow(false); }, { passive: true });
  const center = (el, behavior) => {
    const top = el.offsetTop - pane.clientHeight / 2 + el.offsetHeight / 2;
    pane.scrollTo({ top, behavior });
  };

  // ---- Waveform: "me" above the center line, "them" below, each in its own color ----

  const peaks = {}; // speaker -> { values: Float32Array, seconds }
  const ctx2d = canvas.getContext("2d");
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function draw(t) {
    const dpr = devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const g = ctx2d;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    const mid = h / 2, half = mid - 2, dur = duration();
    const playX = (t / dur) * w;
    const colors = { me: css("--me"), them: css("--them") };

    for (const speaker of ["me", "them"]) {
      const dir = speaker === "me" ? -1 : 1;
      const p = peaks[speaker];
      g.fillStyle = colors[speaker];
      for (const played of [false, true]) {
        g.save();
        g.beginPath();
        g.rect(played ? 0 : playX, 0, played ? playX : w - playX, h);
        g.clip();
        g.globalAlpha = played ? 1 : 0.35;
        if (p) {
          // One 2px bar per 3px of width, each the loudest stretch it covers.
          for (let x = 0; x < w; x += 3) {
            const a = Math.floor(((x / w) * dur / p.seconds) * p.values.length);
            const b = Math.max(a + 1, Math.floor((((x + 3) / w) * dur / p.seconds) * p.values.length));
            let v = 0;
            for (let i = a; i < b && i < p.values.length; i++) v = Math.max(v, p.values[i]);
            const bar = Math.max(1, v * half);
            g.fillRect(x, dir < 0 ? mid - 1 - bar : mid + 1, 2, bar);
          }
        } else {
          // Until the audio decodes, the transcript's timing shows who talked when.
          for (const u of utterances) {
            if ((u.speaker === "me" ? "me" : "them") !== speaker) continue;
            const x0 = (u.start / dur) * w, x1 = Math.max(x0 + 1, (u.end / dur) * w);
            g.fillRect(x0, dir < 0 ? mid - 1 - half * 0.4 : mid + 1, x1 - x0, half * 0.4);
          }
        }
        g.restore();
      }
    }

    g.globalAlpha = 1;
    g.fillStyle = css("--line");
    g.fillRect(0, mid - 0.5, w, 1);
    if (hoverX !== null && scrubTo === null) {
      g.fillStyle = css("--muted");
      g.fillRect(Math.round(hoverX), 0, 1, h);
    }
    g.fillStyle = css("--ink");
    g.fillRect(Math.round(playX) - 1, 0, 2, h);
  }

  async function loadPeaks(speaker, url) {
    const res = await fetch(url, { credentials: "same-origin", signal: aborter.signal });
    const bytes = await res.arrayBuffer();
    // Decoding at 8 kHz keeps an hour-long track to about 100 MB while we measure it.
    const audio = await new OfflineAudioContext(1, 1, 8000).decodeAudioData(bytes);
    const samples = audio.getChannelData(0);
    const n = Math.min(8000, Math.max(1, Math.floor(audio.duration * 20)));
    const per = samples.length / n;
    const values = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      let sum = 0;
      const s = Math.floor(i * per), e = Math.min(samples.length, Math.floor((i + 1) * per));
      for (let j = s; j < e; j++) sum += samples[j] * samples[j];
      values[i] = Math.sqrt(sum / Math.max(1, e - s));
    }
    // Scale each track to its own loud speech so a quiet mic still reads.
    const sorted = Float32Array.from(values).sort();
    const loud = sorted[Math.floor(sorted.length * 0.98)] || 1;
    for (let i = 0; i < n; i++) values[i] = Math.min(1, values[i] / loud);
    peaks[speaker] = { values, seconds: audio.duration };
    tick();
  }
  audible.forEach((t) => loadPeaks(t, file(`${t}.m4a`)).catch(() => {}));

  const timeAt = (clientX) => {
    const r = canvas.getBoundingClientRect();
    return Math.min(Math.max(0, (clientX - r.left) / r.width), 1) * duration();
  };
  const showTip = (x, t) => {
    tip.hidden = false;
    tip.textContent = clock(t);
    tip.style.left = `${x}px`;
  };
  wave.addEventListener("pointerdown", (e) => {
    wave.setPointerCapture(e.pointerId);
    scrubTo = timeAt(e.clientX);
    tick();
  });
  wave.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    hoverX = e.clientX - r.left;
    const t = timeAt(e.clientX);
    if (scrubTo !== null) scrubTo = t;
    showTip(Math.min(Math.max(hoverX, 0), r.width), t);
    tick();
  });
  wave.addEventListener("pointerup", () => {
    if (scrubTo === null) return;
    const t = scrubTo;
    scrubTo = null;
    setTime(t);
  });
  wave.addEventListener("pointercancel", () => { scrubTo = null; tick(); });
  wave.addEventListener("pointerleave", () => { hoverX = null; if (scrubTo === null) tip.hidden = true; tick(); });
  wave.addEventListener("keydown", (e) => {
    const step = { ArrowLeft: -5, ArrowRight: 5, PageDown: -30, PageUp: 30 }[e.key];
    if (step) { e.preventDefault(); setTime(lead.currentTime + step); }
    else if (e.key === "Home") { e.preventDefault(); setTime(0); }
    else if (e.key === "End") { e.preventDefault(); setTime(duration()); }
  });

  // ---- Clock ----

  function tick() {
    const t = scrubTo ?? lead.currentTime;
    for (const a of tracks.slice(1)) if (!a.paused && Math.abs(a.currentTime - lead.currentTime) > 0.25) a.currentTime = lead.currentTime;
    nowEl.textContent = clock(t);
    wave.setAttribute("aria-valuenow", String(Math.round(t)));
    wave.setAttribute("aria-valuetext", `${clock(t)} of ${clock(duration())}`);
    draw(t);

    let on = null;
    for (const b of bubbles) {
      const hit = t >= Number(b.dataset.start) && t <= Number(b.dataset.end) + 0.3;
      b.classList.toggle("now", hit);
      if (hit) on = b;
    }
    if (on && on !== current && follow) {
      const r = on.getBoundingClientRect(), p = pane.getBoundingClientRect();
      if (r.top < p.top + 48 || r.bottom > p.bottom - 24) center(on, "smooth");
    }
    current = on ?? current;
  }
  function loop() {
    cancelAnimationFrame(frame);
    tick();
    if (!lead.paused) frame = requestAnimationFrame(loop);
  }

  // Space plays and pauses; arrows skip 5 seconds. Leave typing and controls alone.
  const onKey = (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest("input, select, textarea, button, [role=slider]")) return;
    if (e.key === " ") { e.preventDefault(); toggle(); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); setTime(lead.currentTime - 5); }
    else if (e.key === "ArrowRight") { e.preventDefault(); setTime(lead.currentTime + 5); }
  };
  document.addEventListener("keydown", onKey);
  const resize = new ResizeObserver(() => tick());
  resize.observe(canvas);

  teardown = () => {
    pause();
    tracks.forEach((a) => { a.removeAttribute("src"); a.load(); });
    cancelAnimationFrame(frame);
    aborter.abort();
    resize.disconnect();
    document.removeEventListener("keydown", onKey);
  };
  tick();
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
  teardown?.();
  teardown = null;
  document.body.classList.remove("is-call");
  const params = new URLSearchParams(location.search);
  if (!user) return renderLogin(params);
  const m = location.hash.match(/^#\/c\/(.+)$/);
  try {
    if (m) await renderCall(decodeURIComponent(m[1]));
    else if (location.hash === "#/trash") await renderTrash();
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
