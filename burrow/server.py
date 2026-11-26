#!/usr/bin/env python3
"""
Burrow - a tiny, private, self-hosted media server.

* Pure Python standard library: nothing to install, nothing phones home.
* Your library index lives in a single SQLite file next to this program.
* No accounts, no telemetry. Covers and descriptions come from open databases
  (see metadata.py for exactly what is sent); turn that off with "online_info": false.

Run:  python3 server.py            (uses burrow.json, creates one if missing)
Then open http://127.0.0.1:8484 in your browser.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
import xml.etree.ElementTree as ET
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import metadata
from mediainfo import describe, quality_score

APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
CONFIG_PATH = Path(os.environ.get("BURROW_CONFIG", APP_DIR / "burrow.json"))

DEFAULT_CONFIG = {
    # 127.0.0.1 = only this computer can connect. Use "0.0.0.0" to allow
    # other devices on your home network (then set a password below).
    "host": "127.0.0.1",
    "port": 8484,
    "password": "",
    "library": {
        "movies": ["~/Videos/Movies"],
        "tv": ["~/Videos/TV"],
        "music": ["~/Music"],
    },
    "database": "burrow.db",
    # Fetch covers, descriptions, genres and ratings from open databases
    # (TVmaze, Wikidata/Wikipedia, MusicBrainz). Only titles are sent.
    "online_info": True,
    # Optional: an email or web page, added to requests so the databases can
    # reach you if something goes wrong. Leave empty to send nothing.
    "online_info_contact": "",
}

VIDEO_EXT = {".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi", ".ogv"}
AUDIO_EXT = {".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wav"}
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")

# Folder names that count as a genre when a file sits inside them,
# e.g. Movies/Horror/The Thing (1982).mkv
KNOWN_GENRES = {
    "action", "adventure", "animation", "anime", "biography", "comedy",
    "crime", "documentary", "drama", "family", "fantasy", "history",
    "horror", "kids", "musical", "mystery", "romance", "sci-fi",
    "science fiction", "sports", "thriller", "war", "western",
    # music
    "rock", "pop", "hip-hop", "hip hop", "rap", "jazz", "blues",
    "classical", "country", "electronic", "metal", "r&b", "soul",
    "reggae", "folk", "punk", "indie", "latin", "gospel", "soundtrack",
}


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
def load_config() -> dict:
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        print(f"Created {CONFIG_PATH} - edit it to point at your media folders.")
    cfg = {**DEFAULT_CONFIG, **json.loads(CONFIG_PATH.read_text())}
    cfg["library"] = {**DEFAULT_CONFIG["library"], **cfg.get("library", {})}
    return cfg


# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id        INTEGER PRIMARY KEY,
    kind      TEXT NOT NULL,          -- movie | show | episode | track
    title     TEXT NOT NULL,
    sort      TEXT NOT NULL,
    year      INTEGER,
    path      TEXT UNIQUE,            -- file path (or folder for shows)
    parent_id INTEGER,                -- episode -> show
    season    INTEGER,
    episode   INTEGER,
    artist    TEXT,
    album     TEXT,
    track_no  INTEGER,
    poster    TEXT,
    overview  TEXT,
    size      INTEGER,
    added     REAL,
    seen_scan INTEGER
);
CREATE INDEX IF NOT EXISTS idx_items_kind ON items(kind);
CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id);
CREATE TABLE IF NOT EXISTS genres (
    item_id INTEGER NOT NULL,
    genre   TEXT NOT NULL,
    manual  INTEGER DEFAULT 0,
    PRIMARY KEY (item_id, genre)
);
CREATE TABLE IF NOT EXISTS progress (
    item_id  INTEGER PRIMARY KEY,
    position REAL,
    duration REAL,
    updated  REAL
);
"""


class DB:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        # Upgrade older databases in place
        have = {r[1] for r in self.conn.execute("PRAGMA table_info(items)")}
        for col, typ in [("mtime", "REAL"), ("media", "TEXT"), ("quality", "INTEGER"),
                         ("dup_of", "INTEGER"), ("meta", "TEXT"), ("art", "TEXT"),
                         ("ext_id", "TEXT"), ("meta_status", "TEXT")]:
            if col not in have:
                self.conn.execute(f"ALTER TABLE items ADD COLUMN {col} {typ}")
        self.conn.commit()

    def q(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def x(self, sql, args=()):
        with self.lock:
            cur = self.conn.execute(sql, args)
            self.conn.commit()
            return cur.lastrowid


# --------------------------------------------------------------------------
# Scanner - works purely from your file names, folders and local .nfo files
# --------------------------------------------------------------------------
YEAR_RE = re.compile(r"[\(\[\.\s_-]((?:19|20)\d{2})(?:[\)\]\.\s_-]|$)")
EP_RE = re.compile(r"[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})|(\d{1,2})x(\d{2,3})")
JUNK_RE = re.compile(
    r"\b(1080p|720p|2160p|4k|bluray|brrip|webrip|web-dl|hdtv|x264|x265|hevc|"
    r"aac|dts|hdr|remux|proper|repack)\b.*$", re.I)
TRACK_RE = re.compile(r"^(\d{1,3})[\s._-]+(.*)$")


def clean_title(stem: str) -> tuple[str, int | None]:
    year = None
    m = YEAR_RE.search(stem)
    if m:
        year = int(m.group(1))
        stem = stem[: m.start()]
    stem = JUNK_RE.sub("", stem)
    stem = re.sub(r"[._]+", " ", stem).strip(" -[]()")
    return (stem or "Untitled"), year


def sort_key(title: str) -> str:
    t = title.lower()
    for art in ("the ", "a ", "an "):
        if t.startswith(art):
            return t[len(art):]
    return t


def find_image(folder: Path, stem: str | None = None) -> str | None:
    names = []
    if stem:
        names += [f"{stem}-poster", f"{stem}"]
    names += ["poster", "folder", "cover", "front"]
    for n in names:
        for ext in IMAGE_EXT:
            p = folder / f"{n}{ext}"
            if p.is_file():
                return str(p)
    return None


def read_nfo(path: Path) -> dict:
    """Read a Kodi-style .nfo (XML) for genres / plot / title, if present."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return {}
    out = {"genres": [g.text.strip() for g in root.iter("genre") if g.text]}
    for tag in ("title", "plot", "year"):
        el = root.find(tag)
        if el is not None and el.text:
            out[tag] = el.text.strip()
    return out


def folder_genres(path: Path, root: Path) -> list[str]:
    try:
        rel = path.relative_to(root).parts[:-1]
    except ValueError:
        return []
    return [p.title() if p.lower() != "sci-fi" else "Sci-Fi"
            for p in rel if p.lower() in KNOWN_GENRES]


def norm_genre(g: str) -> str:
    g = g.strip()
    return g[:1].upper() + g[1:] if g else g


def norm_key(s) -> str:
    return metadata.norm(str(s or ""))


class Scanner:
    def __init__(self, db: DB, cfg: dict, on_done=None):
        self.db, self.cfg = db, cfg
        self.running = False
        self.last = None
        self.stamp = 0
        self.on_done = on_done
        self.show_keys: dict[str, int] = {}

    def media_for(self, f: Path) -> dict:
        """Technical info for a file; only re-read when the file changed."""
        st = f.stat()
        row = self.db.q("SELECT media, size, mtime FROM items WHERE path=?", (str(f),))
        if row and row[0]["media"] and row[0]["size"] == st.st_size \
                and row[0]["mtime"] == st.st_mtime:
            return json.loads(row[0]["media"])
        return describe(str(f), f.name)

    def file_fields(self, f: Path, info: dict) -> dict:
        st = f.stat()
        return {"size": st.st_size, "mtime": st.st_mtime,
                "media": json.dumps(info), "quality": quality_score(info)}

    def roots(self, kind):
        for r in self.cfg["library"].get(kind, []):
            p = Path(os.path.expanduser(r))
            if p.is_dir():
                yield p

    def upsert(self, **f) -> int:
        f.setdefault("sort", sort_key(f["title"]))
        f["seen_scan"] = self.stamp
        row = self.db.q("SELECT id FROM items WHERE path=?", (f["path"],))
        if row:
            sets = ",".join(f"{k}=?" for k in f)
            self.db.x(f"UPDATE items SET {sets} WHERE id=?", (*f.values(), row[0]["id"]))
            return row[0]["id"]
        f["added"] = time.time()
        cols = ",".join(f)
        return self.db.x(f"INSERT INTO items ({cols}) VALUES ({','.join('?'*len(f))})",
                         tuple(f.values()))

    def set_auto_genres(self, item_id, genres):
        self.db.x("DELETE FROM genres WHERE item_id=? AND manual=0", (item_id,))
        for g in {norm_genre(g) for g in genres if g.strip()}:
            self.db.x("INSERT OR IGNORE INTO genres (item_id, genre) VALUES (?,?)",
                      (item_id, g))

    def scan(self):
        if self.running:
            return
        self.running = True
        self.stamp = int(time.time())
        try:
            self.show_keys = {}
            self.scan_movies()
            self.scan_tv()
            self.scan_music()
            # Forget files that disappeared from disk
            gone = self.db.q("SELECT id FROM items WHERE seen_scan<>?", (self.stamp,))
            for r in gone:
                self.db.x("DELETE FROM items WHERE id=?", (r["id"],))
                self.db.x("DELETE FROM genres WHERE item_id=?", (r["id"],))
                self.db.x("DELETE FROM progress WHERE item_id=?", (r["id"],))
            dedupe(self.db)
            self.last = time.time()
        finally:
            self.running = False
        if self.on_done:
            self.on_done()

    def scan_movies(self):
        for root in self.roots("movies"):
            for f in root.rglob("*"):
                if f.suffix.lower() not in VIDEO_EXT or f.name.startswith("."):
                    continue
                title, year = clean_title(f.stem)
                # "Movie (2001)/movie.mkv" - prefer the folder name if it has a year
                ft, fy = clean_title(f.parent.name)
                if f.parent != root and fy and not year:
                    title, year = ft, fy
                nfo = {}
                for cand in (f.with_suffix(".nfo"), f.parent / "movie.nfo"):
                    if cand.is_file():
                        nfo = read_nfo(cand)
                        break
                iid = self.upsert(
                    kind="movie", title=nfo.get("title", title),
                    year=int(nfo["year"]) if str(nfo.get("year", "")).isdigit() else year,
                    path=str(f), poster=find_image(f.parent, f.stem),
                    overview=nfo.get("plot"), **self.file_fields(f, self.media_for(f)))
                self.set_auto_genres(iid, nfo.get("genres", []) + folder_genres(f, root))

    def scan_tv(self):
        for root in self.roots("tv"):
            for show_dir in sorted(p for p in root.iterdir() if p.is_dir()):
                genre_from_parent = []
                shows = [show_dir]
                # Allow TV/Comedy/Show Name/... layout
                if show_dir.name.lower() in KNOWN_GENRES:
                    genre_from_parent = [show_dir.name.title()]
                    shows = sorted(p for p in show_dir.iterdir() if p.is_dir())
                for sd in shows:
                    self.scan_show(sd, genre_from_parent)

    def scan_show(self, sd: Path, extra_genres):
        eps = [f for f in sd.rglob("*")
               if f.suffix.lower() in VIDEO_EXT and not f.name.startswith(".")]
        if not eps:
            return
        title, year = clean_title(sd.name)
        nfo = read_nfo(sd / "tvshow.nfo") if (sd / "tvshow.nfo").is_file() else {}
        title = nfo.get("title", title)
        key = norm_key(title)
        if key in self.show_keys:
            # Same show in a second folder (e.g. "Show" and "Show (2019)"):
            # merge its episodes into the first one instead of listing it twice.
            show_id = self.show_keys[key]
        else:
            show_id = self.upsert(kind="show", title=title, year=year,
                                  path=str(sd), poster=find_image(sd),
                                  overview=nfo.get("plot"))
            self.show_keys[key] = show_id
            self.set_auto_genres(show_id, nfo.get("genres", []) + extra_genres)
        for i, f in enumerate(sorted(eps)):
            m = EP_RE.search(f.stem)
            if m:
                s, e = (int(m.group(1)), int(m.group(2))) if m.group(1) \
                    else (int(m.group(3)), int(m.group(4)))
                rest = f.stem[m.end():]
                ep_title = clean_title(rest)[0] if clean_title(rest)[0] != "Untitled" \
                    else f"Episode {e}"
            else:
                sm = re.search(r"season\s*(\d+)", str(f.parent), re.I)
                s, e, ep_title = (int(sm.group(1)) if sm else 1), i + 1, clean_title(f.stem)[0]
            self.upsert(kind="episode", title=ep_title, path=str(f), parent_id=show_id,
                        season=s, episode=e, sort=f"{s:04d}{e:04d}",
                        **self.file_fields(f, self.media_for(f)))

    def scan_music(self):
        for root in self.roots("music"):
            for f in root.rglob("*"):
                if f.suffix.lower() not in AUDIO_EXT or f.name.startswith("."):
                    continue
                rel = f.relative_to(root).parts
                genre = [p for p in rel[:-1] if p.lower() in KNOWN_GENRES]
                parts = [p for p in rel[:-1] if p.lower() not in KNOWN_GENRES]
                artist = parts[0] if len(parts) >= 1 else "Unknown Artist"
                album = parts[1] if len(parts) >= 2 else "Singles"
                m = TRACK_RE.match(f.stem)
                no, name = (int(m.group(1)), m.group(2)) if m else (None, f.stem)
                name = re.sub(r"[._]+", " ", name).strip()
                info = self.media_for(f)
                # Tags inside the file beat folder names
                tags = info.get("tags", {})
                artist = tags.get("album_artist") or tags.get("artist") or artist
                album = tags.get("album") or album
                name = tags.get("title") or name
                tn = re.match(r"\d+", tags.get("track", ""))
                no = int(tn.group()) if tn else no
                if tags.get("genre"):
                    genre += [g.strip() for g in re.split(r"[;/,]", tags["genre"]) if g.strip()]
                iid = self.upsert(kind="track", title=name, path=str(f), artist=artist,
                                  album=album, track_no=no, poster=find_image(f.parent),
                                  sort=f"{artist.lower()}|{album.lower()}|{no or 0:04d}",
                                  **self.file_fields(f, info))
                self.set_auto_genres(iid, [g.title() if g.islower() else g for g in genre])


# --------------------------------------------------------------------------
# Duplicates: the same movie / episode / song more than once. The best copy
# (highest resolution, then HDR, then most audio channels, then biggest file)
# stays in the library; the others are hidden. Files are never deleted.
# --------------------------------------------------------------------------
def dedupe(db: DB):
    rows = db.q("""SELECT id, kind, title, year, parent_id, season, episode, artist,
                          album, ext_id, quality, size FROM items
                   WHERE kind IN ('movie','episode','track')""")
    groups: dict[tuple, list] = {}
    years_for_title: dict[str, set] = {}
    for r in rows:
        if r["kind"] == "movie" and not r["ext_id"] and r["year"]:
            years_for_title.setdefault(norm_key(r["title"]), set()).add(r["year"])
    for r in rows:
        if r["kind"] == "movie":
            if r["ext_id"]:
                key = ("m", r["ext_id"])
            else:
                t = norm_key(r["title"])
                y = r["year"]
                if not y and len(years_for_title.get(t, ())) == 1:
                    y = next(iter(years_for_title[t]))   # "Inception" == "Inception (2010)"
                key = ("m", t, y)
        elif r["kind"] == "episode":
            key = ("e", r["parent_id"], r["season"], r["episode"])
        else:
            key = ("t", norm_key(r["artist"]), norm_key(r["album"]), norm_key(r["title"]))
        groups.setdefault(key, []).append(r)
    # ext_id groups and title groups can describe the same film: fold them together
    by_title = {}
    for key, members in list(groups.items()):
        if key[0] == "m" and len(key) == 2:
            for m in members:
                by_title[(norm_key(m["title"]), m["year"])] = key
    for key in list(groups):
        if key[0] == "m" and len(key) == 3 and (key[1], key[2]) in by_title:
            groups[by_title[(key[1], key[2])]] += groups.pop(key)

    hide = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        best = max(members, key=lambda m: (m["quality"] or 0, m["size"] or 0, -m["id"]))
        for m in members:
            if m is not best:
                hide[m["id"]] = best["id"]
    with db.lock:
        db.conn.execute("UPDATE items SET dup_of=NULL")
        db.conn.executemany("UPDATE items SET dup_of=? WHERE id=?",
                            [(keep, iid) for iid, keep in hide.items()])
        db.conn.commit()


# --------------------------------------------------------------------------
# Online info (covers, descriptions, genres, ratings) - runs in the background
# --------------------------------------------------------------------------
class MetaWorker:
    def __init__(self, db: DB, cfg: dict, cache: Path):
        self.db, self.cfg, self.cache = db, cfg, cache
        self.lookup = metadata.Lookup(cfg.get("online_info_contact", ""))
        self.busy = threading.Lock()
        self.pending = 0
        self.again = False

    def enabled(self):
        return bool(self.cfg.get("online_info", True))

    def kick(self):
        if not self.enabled():
            return
        if self.busy.locked():
            self.again = True
            return
        threading.Thread(target=self.run, daemon=True).start()

    def todo(self):
        return self.db.q("""SELECT id, kind, title, year FROM items
                            WHERE kind IN ('movie','show') AND dup_of IS NULL
                              AND meta_status IS NULL ORDER BY added DESC""")

    def albums_todo(self):
        return self.db.q("""SELECT artist, album, MIN(id) id FROM items
                            WHERE kind='track' AND meta_status IS NULL
                            GROUP BY artist, album""")

    def count_pending(self):
        if not self.enabled():
            return 0
        return len(self.todo()) + len(self.albums_todo())

    def save(self, ids, meta, status):
        art = None
        if meta and meta.get("image"):
            dest = self.cache / f"{meta['ext_id'].replace(':', '-')}.jpg"
            if dest.exists() or self.lookup.download(meta["image"], dest):
                art = str(dest)
        for iid in ids:
            self.db.x("UPDATE items SET meta=?, art=?, ext_id=?, meta_status=? WHERE id=?",
                      (json.dumps(meta) if meta else None, art,
                       meta.get("ext_id") if meta else None, status, iid))
            self.db.x("DELETE FROM genres WHERE item_id=? AND manual=2", (iid,))
            for g in (meta or {}).get("genres", []):
                self.db.x("INSERT OR IGNORE INTO genres (item_id, genre, manual) VALUES (?,?,2)",
                          (iid, g))

    def run(self):
        with self.busy:
            while True:
                self.again = False
                for r in self.todo():
                    try:
                        meta = (self.lookup.movie if r["kind"] == "movie"
                                else self.lookup.show)(r["title"], r["year"])
                        self.save([r["id"]], meta, "ok" if meta else "notfound")
                    except Exception as e:   # network down etc.: try again next scan
                        print(f"  info lookup failed for {r['title']!r}: {e}")
                        continue   # leave it for next time
                for a in self.albums_todo():
                    ids = [x["id"] for x in self.db.q(
                        "SELECT id FROM items WHERE kind='track' AND artist IS ? AND album IS ?",
                        (a["artist"], a["album"]))]
                    try:
                        meta = self.lookup.album(a["artist"], a["album"])
                        self.save(ids, meta, "ok" if meta else "notfound")
                    except Exception as e:
                        print(f"  info lookup failed for {a['album']!r}: {e}")
                        continue
                dedupe(self.db)   # matching can reveal more duplicates
                if not self.again:
                    break


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class App:
    def __init__(self, cfg):
        self.cfg = cfg
        db_path = Path(cfg["database"])
        if not db_path.is_absolute():
            db_path = APP_DIR / db_path
        self.db = DB(db_path)
        self.meta = MetaWorker(self.db, cfg, db_path.parent / "covers")
        self.scanner = Scanner(self.db, cfg, on_done=self.meta.kick)
        self.secret = secrets.token_bytes(32)  # session cookies die on restart

    def token(self):
        return hmac.new(self.secret, b"ok", hashlib.sha256).hexdigest()


def item_out(app: App, r: dict) -> dict:
    r = dict(r)
    r["file"] = os.path.basename(r.pop("path", "") or "")
    for k in ("seen_scan", "mtime", "quality", "ext_id"):
        r.pop(k, None)
    r["media"] = json.loads(r["media"]) if r.get("media") else {}
    r["media"].pop("tags", None)
    meta = json.loads(r.pop("meta") or "null") or {}
    meta.pop("episodes", None)
    r["info"] = meta
    if meta:
        r["overview"] = r.get("overview") or meta.get("overview")
        r["year"] = r.get("year") or meta.get("year")
        if r["kind"] in ("movie", "show") and meta.get("title"):
            r["title"] = meta["title"]
    r["has_poster"] = bool(r.pop("poster", None) or r.pop("art", None))
    r.pop("art", None)
    r["genres"] = [g["genre"] for g in app.db.q(
        "SELECT genre FROM genres WHERE item_id=? ORDER BY genre", (r["id"],))]
    p = app.db.q("SELECT position, duration FROM progress WHERE item_id=?", (r["id"],))
    r["progress"] = p[0] if p else None
    return r


class Handler(BaseHTTPRequestHandler):
    app: App = None  # set at startup
    server_version = "Burrow"
    sys_version = ""

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    # ---------- helpers ----------
    def send_json(self, data, status=200, cors=False):
        body = json.dumps(data).encode()
        self.send_response(status)
        if cors:  # lets the TV apps check the server address before connecting
            self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1_000_000:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return {}

    def authed(self) -> bool:
        if not self.app.cfg.get("password"):
            return True
        cookie = self.headers.get("Cookie", "")
        m = re.search(r"burrow=([0-9a-f]+)", cookie)
        return bool(m) and hmac.compare_digest(m.group(1), self.app.token())

    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        # The UI is fully self-contained: block all outside resources.
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; img-src 'self' data:; media-src 'self'; "
                         "style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'")

    def end_headers(self):
        self.security_headers()
        super().end_headers()

    # ---------- routing ----------
    def do_GET(self):
        url = urlparse(self.path)
        path, qs = url.path, parse_qs(url.query)
        if path.startswith("/api/"):
            if path == "/api/status":
                return self.send_json({"app": "burrow", "auth": self.authed(),
                                       "needs_password": bool(self.app.cfg.get("password"))},
                                      cors=True)
            if not self.authed():
                return self.send_json({"error": "login required"}, 401)
            return self.api_get(path, qs)
        if path.startswith("/media/") or path.startswith("/poster/"):
            if not self.authed():
                return self.send_error(401)
            return self.serve_item_file(path)
        return self.serve_static(path)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            pw = str(self.body_json().get("password", ""))
            if hmac.compare_digest(pw.encode(), str(self.app.cfg.get("password")).encode()):
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Set-Cookie",
                                 f"burrow={self.app.token()}; HttpOnly; SameSite=Strict; Path=/")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            time.sleep(1)  # slow down guessing
            return self.send_json({"error": "wrong password"}, 403)
        if not self.authed():
            return self.send_json({"error": "login required"}, 401)
        data = self.body_json()
        db = self.app.db

        if path == "/api/scan":
            threading.Thread(target=self.app.scanner.scan, daemon=True).start()
            return self.send_json({"ok": True})

        m = re.fullmatch(r"/api/items/(\d+)/progress", path)
        if m:
            db.x("INSERT OR REPLACE INTO progress VALUES (?,?,?,?)",
                 (int(m.group(1)), float(data.get("position", 0)),
                  float(data.get("duration", 0)), time.time()))
            return self.send_json({"ok": True})

        m = re.fullmatch(r"/api/items/(\d+)/(refresh|clearinfo)", path)
        if m:
            iid, action = int(m.group(1)), m.group(2)
            rows = db.q("SELECT kind, artist, album FROM items WHERE id=?", (iid,))
            if not rows:
                return self.send_json({"error": "not found"}, 404)
            ids = [iid]
            if rows[0]["kind"] == "track":   # info is per album
                ids = [x["id"] for x in db.q(
                    "SELECT id FROM items WHERE kind='track' AND artist IS ? AND album IS ?",
                    (rows[0]["artist"], rows[0]["album"]))]
            status = None if action == "refresh" else "off"
            for i in ids:
                db.x("""UPDATE items SET meta=NULL, art=NULL, ext_id=NULL, meta_status=?
                        WHERE id=?""", (status, i))
                db.x("DELETE FROM genres WHERE item_id=? AND manual=2", (i,))
            dedupe(db)
            self.app.meta.kick()
            return self.send_json({"ok": True})

        m = re.fullmatch(r"/api/items/(\d+)/genres", path)
        if m:
            iid = int(m.group(1))
            genres = {norm_genre(str(g))[:40] for g in data.get("genres", []) if str(g).strip()}
            db.x("DELETE FROM genres WHERE item_id=?", (iid,))
            for g in genres:   # the user's list replaces scanned + looked-up genres
                db.x("INSERT INTO genres (item_id, genre, manual) VALUES (?,?,1)", (iid, g))
            return self.send_json({"ok": True, "genres": sorted(genres)})

        return self.send_json({"error": "not found"}, 404)

    # ---------- API ----------
    def api_get(self, path, qs):
        db = self.app.db
        one = lambda k, d=None: (qs.get(k) or [d])[0]

        if path == "/api/library":
            kind = one("kind", "movie")
            genre = one("genre")
            search = one("q")
            sql = "SELECT i.* FROM items i"
            args = []
            where = ["i.kind=?", "i.dup_of IS NULL"]
            args.append(kind)
            if genre:
                sql += " JOIN genres g ON g.item_id=i.id"
                where.append("g.genre=?")
                args.append(genre)
            if search:
                where.append("(i.title LIKE ? OR i.artist LIKE ? OR i.album LIKE ?)")
                args += [f"%{search}%"] * 3
            sql += " WHERE " + " AND ".join(where) + " ORDER BY i.sort"
            return self.send_json([item_out(self.app, r) for r in db.q(sql, args)])

        if path == "/api/genres":
            rows = db.q("""SELECT g.genre, i.kind, COUNT(*) n FROM genres g
                           JOIN items i ON i.id=g.item_id
                           WHERE i.kind IN ('movie','show','track') AND i.dup_of IS NULL
                           GROUP BY g.genre, i.kind ORDER BY g.genre""")
            out = {}
            for r in rows:
                out.setdefault(r["genre"], {"genre": r["genre"], "movie": 0, "show": 0, "track": 0})
                out[r["genre"]][r["kind"]] = r["n"]
            return self.send_json(list(out.values()))

        if path == "/api/home":
            cont = db.q("""SELECT i.* FROM progress p JOIN items i ON i.id=p.item_id
                           WHERE p.position > 30 AND p.position < p.duration - 60
                             AND i.dup_of IS NULL
                           ORDER BY p.updated DESC LIMIT 12""")
            recent = db.q("""SELECT * FROM items WHERE kind IN ('movie','show')
                             AND dup_of IS NULL ORDER BY added DESC LIMIT 18""")
            counts = {r["kind"]: r["n"] for r in db.q(
                "SELECT kind, COUNT(*) n FROM items WHERE dup_of IS NULL GROUP BY kind")}
            dups = db.q("SELECT COUNT(*) n FROM items WHERE dup_of IS NOT NULL")[0]["n"]
            out = lambda rows: [item_out(self.app, r) for r in rows]
            for c in (cont_out := out(cont)):
                if c["kind"] == "episode":
                    show = db.q("SELECT title FROM items WHERE id=?", (c["parent_id"],))
                    c["show_title"] = show[0]["title"] if show else ""
            return self.send_json({"continue": cont_out, "recent": out(recent),
                                   "counts": counts, "duplicates": dups,
                                   "info_pending": self.app.meta.count_pending(),
                                   "scanning": self.app.scanner.running,
                                   "last_scan": self.app.scanner.last})

        m = re.fullmatch(r"/api/items/(\d+)", path)
        if m:
            rows = db.q("SELECT * FROM items WHERE id=?", (int(m.group(1)),))
            if not rows:
                return self.send_json({"error": "not found"}, 404)
            item = item_out(self.app, rows[0])
            if item["kind"] == "show":
                eps_meta = (json.loads(rows[0]["meta"] or "null") or {}).get("episodes", {})
                item["episodes"] = []
                for e in db.q("""SELECT * FROM items WHERE parent_id=? AND dup_of IS NULL
                                 ORDER BY season, episode""", (item["id"],)):
                    e = item_out(self.app, e)
                    em = eps_meta.get(f"{e['season']}x{e['episode']}")
                    if em:   # real episode names and summaries from TVmaze
                        if em.get("title") and re.fullmatch(r"Episode \d+", e["title"]):
                            e["title"] = em["title"]
                        e["overview"] = e.get("overview") or em.get("overview")
                        e["aired"] = em.get("aired")
                    item["episodes"].append(e)
            return self.send_json(item)

        if path == "/api/duplicates":
            out = []
            for d in db.q("SELECT * FROM items WHERE dup_of IS NOT NULL ORDER BY dup_of"):
                keep = db.q("SELECT * FROM items WHERE id=?", (d["dup_of"],))
                if keep:
                    kept = item_out(self.app, keep[0])
                    if kept["kind"] == "episode":
                        show = db.q("SELECT title, meta FROM items WHERE id=?", (kept["parent_id"],))
                        if show:
                            kept["show_title"] = (json.loads(show[0]["meta"] or "null") or {}).get("title") \
                                or show[0]["title"]
                    out.append({"hidden": item_out(self.app, d), "kept": kept,
                                "hidden_path": d["path"], "kept_path": keep[0]["path"]})
            return self.send_json(out)

        return self.send_json({"error": "not found"}, 404)

    # ---------- files ----------
    def serve_item_file(self, path):
        m = re.fullmatch(r"/(media|poster)/(\d+)", path)
        if not m:
            return self.send_error(404)
        rows = self.app.db.q("SELECT path, poster, art, kind FROM items WHERE id=?", (int(m.group(2)),))
        if not rows:
            return self.send_error(404)
        # Only paths recorded by the scanner can ever be served.
        fpath = rows[0]["path"] if m.group(1) == "media" \
            else (rows[0]["poster"] or rows[0]["art"])   # your own poster wins
        if not fpath or not os.path.isfile(fpath):
            return self.send_error(404)
        self.send_file(fpath, cache=m.group(1) == "poster")

    def serve_static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        target = (STATIC_DIR / path.lstrip("/")).resolve()
        if STATIC_DIR not in target.parents or not target.is_file():
            target = STATIC_DIR / "index.html"
        self.send_file(str(target))

    def send_file(self, fpath, cache=False):
        size = os.path.getsize(fpath)
        ctype = mimetypes.guess_type(fpath)[0] or "application/octet-stream"
        if fpath.lower().endswith(".mkv"):
            ctype = "video/webm"  # lets Chromium-based browsers try to play it
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        status = HTTPStatus.OK
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                elif m.group(2):
                    start = max(0, size - int(m.group(2)))
                if start >= size:
                    self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                status = HTTPStatus.PARTIAL_CONTENT
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "max-age=86400" if cache else "no-cache")
        self.end_headers()
        try:
            with open(fpath, "rb") as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # viewer seeked or closed the tab


def main():
    cfg = load_config()
    app = App(cfg)
    Handler.app = app
    def first_scan():
        app.scanner.scan()
        counts = app.db.q("SELECT kind, COUNT(*) n FROM items WHERE dup_of IS NULL GROUP BY kind")
        dups = app.db.q("SELECT COUNT(*) n FROM items WHERE dup_of IS NOT NULL")[0]["n"]
        print("Library: " + (", ".join(f"{c['n']} {c['kind']}s" for c in counts) or "nothing found yet")
              + (f" ({dups} duplicate files hidden)" if dups else ""))
    print("Scanning your library in the background...")
    threading.Thread(target=first_scan, daemon=True).start()
    host, port = cfg["host"], int(cfg["port"])
    if host not in ("127.0.0.1", "localhost") and not cfg.get("password"):
        print("WARNING: other devices can reach Burrow and no password is set.")
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"Burrow is running at http://{'127.0.0.1' if host == '0.0.0.0' else host}:{port}")
    print("Press Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nBye!")


if __name__ == "__main__":
    sys.exit(main())
