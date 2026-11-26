// Burrow front-end. No frameworks, no trackers, no outside requests.
"use strict";

const $ = (s, el = document) => el.querySelector(s);
const view = $("#view");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, body) {
  const opt = body ? { method: "POST", headers: { "Content-Type": "application/json" },
                       body: JSON.stringify(body) } : {};
  const r = await fetch(path, opt);
  if (r.status === 401) { showLogin(); throw new Error("login"); }
  return r.json();
}

// ---------- Generated poster art (when you have no poster image) ----------
function hue(str) { let h = 0; for (const c of String(str)) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
function art(str) {
  const h = hue(str);
  return `background:linear-gradient(150deg,hsl(${h} 55% 42%),hsl(${(h + 40) % 360} 60% 18%))`;
}
const GENRE_COLORS = {
  Horror: "#7a1420", Comedy: "#d18b10", Action: "#c2410c", Drama: "#5b3b8c",
  "Sci-Fi": "#0e7490", Romance: "#be3a6b", Thriller: "#334155", Animation: "#16a34a",
  Documentary: "#57534e", Family: "#2563eb", Fantasy: "#7c3aed", Crime: "#44403c",
  Adventure: "#15803d", Mystery: "#3730a3", Western: "#92400e", Rock: "#9f1239",
  Jazz: "#1e40af", "Hip-Hop": "#a16207", Pop: "#db2777", Classical: "#4d7c0f",
};
const gcolor = (g) => GENRE_COLORS[g] || `hsl(${hue(g)} 45% 35%)`;

function posterHTML(it, label) {
  const bar = it.progress && it.progress.duration
    ? `<div class="bar"><i style="width:${Math.min(100, 100 * it.progress.position / it.progress.duration)}%"></i></div>` : "";
  const inner = it.has_poster
    ? `<img loading="lazy" src="/poster/${it.id}" alt="">`
    : `<div class="fake" style="${art(label || it.title)}">${esc(label || it.title)}</div>`;
  return `<div class="poster">${inner}${bar}</div>`;
}

function card(it) {
  let meta = it.year || "";
  let title = it.title;
  if (it.kind === "show") meta = (it.year ? it.year + " · " : "") + "Series";
  if (it.kind === "episode") { title = it.show_title || it.title; meta = `S${it.season} · E${it.episode}`; }
  return `<div class="card" data-id="${it.id}" data-kind="${it.kind}">
    ${posterHTML(it, title)}
    <div class="t">${esc(title)}</div><div class="m">${esc(meta)}</div></div>`;
}

function grid(items, cls = "grid") {
  return `<div class="${cls}">${items.map(card).join("")}</div>`;
}

function emptyMsg(what) {
  return `<div class="empty">No ${what} yet.<br>Put files in the folders listed in
    <code>burrow.json</code>, then press <b>Rescan library</b>.</div>`;
}

// ---------- Views ----------
async function homeView() {
  const d = await api("/api/home");
  const c = d.counts;
  let html = `<h1>Welcome back</h1>
    <div class="stats">
      <div class="stat"><b>${c.movie || 0}</b><span>Movies</span></div>
      <div class="stat"><b>${c.show || 0}</b><span>TV Shows</span></div>
      <div class="stat"><b>${c.episode || 0}</b><span>Episodes</span></div>
      <div class="stat"><b>${c.track || 0}</b><span>Songs</span></div>
    </div>`;
  if (d.continue.length) html += `<h2>Continue watching</h2>${grid(d.continue, "row")}`;
  html += `<h2>Recently added</h2>` + (d.recent.length ? grid(d.recent, "row") : emptyMsg("movies or shows"));
  const genres = await api("/api/genres");
  if (genres.length) {
    html += `<h2>Browse by genre</h2><div class="chips">` +
      genres.map((g) => `<a class="chip" href="#/genres/${encodeURIComponent(g.genre)}">${esc(g.genre)}</a>`).join("") + "</div>";
  }
  view.innerHTML = html;
}

async function libraryView(kind, label) {
  const q = $("#search").value.trim();
  const [items, genres] = await Promise.all([
    api(`/api/library?kind=${kind}&q=${encodeURIComponent(q)}`), api("/api/genres")]);
  const relevant = genres.filter((g) => g[kind] > 0);
  view.innerHTML = `<h1>${label}</h1><p class="sub">${items.length} in your library</p>
    ${relevant.length ? `<div class="chips"><button class="chip on" data-g="">All</button>${
      relevant.map((g) => `<button class="chip" data-g="${esc(g.genre)}">${esc(g.genre)} <span>${g[kind]}</span></button>`).join("")}</div>` : ""}
    <div id="lib">${items.length ? grid(items) : emptyMsg(label.toLowerCase())}</div>`;
  view.querySelectorAll(".chips .chip").forEach((b) => b.onclick = async () => {
    view.querySelectorAll(".chips .chip").forEach((x) => x.classList.toggle("on", x === b));
    const g = b.dataset.g;
    const list = await api(`/api/library?kind=${kind}&q=${encodeURIComponent(q)}${g ? "&genre=" + encodeURIComponent(g) : ""}`);
    $("#lib").innerHTML = grid(list);
  });
}

async function musicView() {
  const q = $("#search").value.trim();
  const tracks = await api(`/api/library?kind=track&q=${encodeURIComponent(q)}`);
  if (!tracks.length) { view.innerHTML = `<h1>Music</h1>${emptyMsg("music")}`; return; }
  const albums = new Map();
  for (const t of tracks) {
    const key = t.artist + "|" + t.album;
    if (!albums.has(key)) albums.set(key, []);
    albums.get(key).push(t);
  }
  let html = `<h1>Music</h1><p class="sub">${tracks.length} songs · ${albums.size} albums</p>`;
  for (const list of albums.values()) {
    const a = list[0];
    html += `<div class="album"><div class="card square">${posterHTML(a, a.album)}</div><div>
      <h2 style="margin-top:0">${esc(a.album)}</h2><p class="sub">${esc(a.artist)}${a.genres.length ? " · " + esc(a.genres.join(", ")) : ""}</p>
      <ol class="tracks">${list.map((t) =>
        `<li data-track="${t.id}"><span class="n">${t.track_no || ""}</span>${esc(t.title)}</li>`).join("")}</ol></div></div>`;
  }
  view.innerHTML = html;
  view.querySelectorAll("[data-track]").forEach((li) => li.onclick = () =>
    playAudio(tracks.find((t) => t.id == li.dataset.track), tracks));
}

async function genresView() {
  const genres = await api("/api/genres");
  if (!genres.length) {
    view.innerHTML = `<h1>Genres</h1><div class="empty">No genres yet.<br>
      Sort files into folders like <code>Movies/Horror/</code>, add <code>.nfo</code> files,
      or open any title and add genres yourself.</div>`;
    return;
  }
  view.innerHTML = `<h1>Genres</h1><p class="sub">Pick a mood.</p><div class="gtiles">` +
    genres.map((g) => {
      const pl = (n, w) => n && `${n} ${w}${n === 1 ? "" : "s"}`;
      const bits = [pl(g.movie, "movie"), pl(g.show, "show"), pl(g.track, "song")].filter(Boolean);
      return `<a class="gtile" href="#/genres/${encodeURIComponent(g.genre)}"
        style="background:linear-gradient(135deg,${gcolor(g.genre)},#0009)"><b>${esc(g.genre)}</b><span>${bits.join(" · ")}</span></a>`;
    }).join("") + "</div>";
}

async function genreView(genre) {
  const enc = encodeURIComponent(genre);
  const [movies, shows, tracks] = await Promise.all([
    api(`/api/library?kind=movie&genre=${enc}`), api(`/api/library?kind=show&genre=${enc}`),
    api(`/api/library?kind=track&genre=${enc}`)]);
  let html = `<p class="sub"><a href="#/genres">← All genres</a></p><h1>${esc(genre)}</h1>`;
  if (movies.length) html += `<h2>Movies</h2>${grid(movies)}`;
  if (shows.length) html += `<h2>TV Shows</h2>${grid(shows)}`;
  if (tracks.length) html += `<h2>Music</h2><ol class="tracks">${tracks.map((t) =>
    `<li data-track="${t.id}"><span class="n">♪</span>${esc(t.title)} <span class="m">— ${esc(t.artist)}</span></li>`).join("")}</ol>`;
  if (!movies.length && !shows.length && !tracks.length) html += `<div class="empty">Nothing here yet.</div>`;
  view.innerHTML = html;
  view.querySelectorAll("[data-track]").forEach((li) => li.onclick = () =>
    playAudio(tracks.find((t) => t.id == li.dataset.track), tracks));
}

// ---------- Detail sheet ----------
async function openItem(id) {
  const it = await api(`/api/items/${id}`);
  if (it.kind === "episode") return playVideo(it);
  const sheet = $("#sheet");
  let body = `<button class="close" data-close>✕</button>
    ${posterHTML(it)}
    <div><h1>${esc(it.title)}</h1>
    <p class="sub">${[it.year, it.kind === "show" ? `${it.episodes.length} episodes` : null].filter(Boolean).join(" · ")}</p>
    ${it.overview ? `<p>${esc(it.overview)}</p>` : ""}
    <div class="chips" id="gchips"></div>
    <div class="genre-edit"><input id="gin" placeholder="Add a genre (e.g. Horror)" list="glist">
      <button class="btn" id="gadd">Add</button></div><datalist id="glist"></datalist>`;
  if (it.kind === "movie") {
    const resume = it.progress && it.progress.position > 30;
    body += `<p style="margin-top:22px"><button class="btn" id="play">${resume ? "▶ Resume" : "▶ Play"}</button>
      ${resume ? `<button class="ghost" style="width:auto;margin-left:8px" id="restart">Start over</button>` : ""}</p>`;
  } else {
    const seasons = [...new Set(it.episodes.map((e) => e.season))];
    body += `<h2>Episodes</h2><div class="season-tabs">${seasons.map((s, i) =>
      `<button class="chip ${i ? "" : "on"}" data-season="${s}">Season ${s}</button>`).join("")}</div>
      <ul class="eps" id="eps"></ul>`;
  }
  sheet.innerHTML = body + "</div>";
  $("#modal").classList.remove("hidden");

  // genres editor
  let genres = [...it.genres];
  const drawGenres = () => {
    $("#gchips").innerHTML = genres.map((g) =>
      `<span class="chip">${esc(g)}<button class="x" data-rm="${esc(g)}" style="background:none;border:0;color:inherit;padding:0">✕</button></span>`).join("");
    $("#gchips").querySelectorAll("[data-rm]").forEach((x) => x.onclick = () => {
      genres = genres.filter((g) => g !== x.dataset.rm); save();
    });
  };
  const save = async () => { genres = (await api(`/api/items/${id}/genres`, { genres })).genres; drawGenres(); };
  api("/api/genres").then((all) => $("#glist").innerHTML = all.map((g) => `<option value="${esc(g.genre)}">`).join(""));
  $("#gadd").onclick = () => { const v = $("#gin").value.trim(); if (v && !genres.includes(v)) { genres.push(v); save(); } $("#gin").value = ""; };
  $("#gin").onkeydown = (e) => { if (e.key === "Enter") $("#gadd").click(); };
  drawGenres();

  if (it.kind === "movie") {
    $("#play").onclick = () => playVideo(it);
    if ($("#restart")) $("#restart").onclick = () => playVideo(it, true);
  } else {
    const drawEps = (s) => {
      $("#eps").innerHTML = it.episodes.filter((e) => e.season == s).map((e) => {
        const done = e.progress && e.progress.duration && e.progress.position > e.progress.duration - 60;
        return `<li data-ep="${e.id}"><span class="code">S${e.season} E${e.episode}</span>
          <span>${esc(e.title)}</span><span class="m" style="margin-left:auto">${done ? "✓ watched" : ""}</span></li>`;
      }).join("");
      $("#eps").querySelectorAll("[data-ep]").forEach((li) => li.onclick = () => {
        const ep = it.episodes.find((e) => e.id == li.dataset.ep);
        playVideo({ ...ep, show_title: it.title }, false, it.episodes);
      });
    };
    sheet.querySelectorAll("[data-season]").forEach((b) => b.onclick = () => {
      sheet.querySelectorAll("[data-season]").forEach((x) => x.classList.toggle("on", x === b));
      drawEps(b.dataset.season);
    });
    drawEps(it.episodes[0]?.season);
  }
}
const closeModal = () => $("#modal").classList.add("hidden");
$("#modal").onclick = (e) => { if (e.target.id === "modal" || e.target.dataset.close !== undefined) closeModal(); };

// ---------- Playback ----------
const video = $("#video");
let current = null, queue = [], lastSave = 0;

function playVideo(it, fromStart = false, episodes = []) {
  $("#audio").pause();
  current = it; queue = episodes;
  $("#ptitle").textContent = it.kind === "episode"
    ? `${it.show_title || ""} · S${it.season}E${it.episode} · ${it.title}` : it.title;
  video.src = `/media/${it.id}`;
  video.onloadedmetadata = () => {
    if (!fromStart && it.progress && it.progress.position > 30 &&
        it.progress.position < video.duration - 60) video.currentTime = it.progress.position;
    video.play().catch(() => {});
  };
  $("#player").classList.remove("hidden");
}
function saveProgress(force) {
  if (!current || !video.duration) return;
  const now = Date.now();
  if (!force && now - lastSave < 5000) return;
  lastSave = now;
  api(`/api/items/${current.id}/progress`, { position: video.currentTime, duration: video.duration }).catch(() => {});
}
video.ontimeupdate = () => saveProgress(false);
video.onpause = () => saveProgress(true);
video.onended = () => {
  saveProgress(true);
  const i = queue.findIndex((e) => e.id === current.id);
  if (i >= 0 && queue[i + 1]) playVideo({ ...queue[i + 1], show_title: current.show_title }, true, queue);
};
function closePlayer() {
  saveProgress(true);
  video.pause(); video.removeAttribute("src"); video.load();
  $("#player").classList.add("hidden");
  current = null;
  route();
}
$("#closePlayer").onclick = closePlayer;
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (!$("#player").classList.contains("hidden")) closePlayer(); else closeModal();
});

const audio = $("#audio");
let aQueue = [], aCur = null;
function playAudio(t, list) {
  aQueue = list; aCur = t;
  $("#abTitle").textContent = t.title;
  $("#abArtist").textContent = `${t.artist} — ${t.album}`;
  audio.src = `/media/${t.id}`;
  audio.play().catch(() => {});
  $("#audiobar").classList.remove("hidden");
}
audio.onended = () => {
  const i = aQueue.findIndex((t) => t.id === aCur.id);
  if (aQueue[i + 1]) playAudio(aQueue[i + 1], aQueue);
};

// ---------- Router ----------
async function route() {
  const h = decodeURIComponent(location.hash.slice(1) || "/");
  const section = h.split("/")[1] || "home";
  document.querySelectorAll("[data-nav]").forEach((a) => a.classList.toggle("on", a.dataset.nav === section));
  try {
    if (section === "movies") await libraryView("movie", "Movies");
    else if (section === "tv") await libraryView("show", "TV Shows");
    else if (section === "music") await musicView();
    else if (section === "genres" && h.split("/")[2]) await genreView(h.split("/").slice(2).join("/"));
    else if (section === "genres") await genresView();
    else await homeView();
  } catch (e) { if (e.message !== "login") console.error(e); }
}
view.addEventListener("click", (e) => {
  const c = e.target.closest(".card[data-id]");
  if (!c) return;
  if (c.dataset.kind === "episode") api(`/api/items/${c.dataset.id}`).then(async (ep) => {
    const show = await api(`/api/items/${ep.parent_id}`);
    playVideo({ ...ep, show_title: show.title }, false, show.episodes);
  });
  else openItem(c.dataset.id);
});

let searchTimer;
$("#search").oninput = () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const s = (location.hash.split("/")[1] || "");
    if (!["movies", "tv", "music"].includes(s)) location.hash = "#/movies"; else route();
  }, 250);
};

$("#scanBtn").onclick = async () => {
  const b = $("#scanBtn");
  b.textContent = "Scanning…"; b.disabled = true;
  await api("/api/scan", {});
  const poll = setInterval(async () => {
    const d = await api("/api/home");
    if (!d.scanning) { clearInterval(poll); b.textContent = "Rescan library"; b.disabled = false; route(); }
  }, 1000);
};

// ---------- Login (only if you set a password) ----------
function showLogin() { $("#login").classList.remove("hidden"); $("#pw").focus(); }
$("#loginForm").onsubmit = async (e) => {
  e.preventDefault();
  const r = await fetch("/api/login", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password: $("#pw").value }) });
  if (r.ok) { $("#login").classList.add("hidden"); route(); }
  else $("#loginErr").textContent = "Wrong password";
};

window.addEventListener("hashchange", route);
api("/api/status").then((s) => { if (!s.auth) showLogin(); else route(); });
