"""
Look up covers, descriptions, genres and ratings from free, open, community-run
databases. No accounts and no API keys.

  Movies  -> Wikidata (CC0) + Wikipedia (CC BY-SA)
  TV      -> TVmaze (CC BY-SA)
  Music   -> MusicBrainz (CC0) + Cover Art Archive

What is sent: only the title and year of a movie or show, or the artist and album
name of an album, as a search. No file paths, no account, nothing about you or
what you watch. Each title is looked up once and the answer (and cover) is saved
on your computer. Turn it all off with "online_info": false in burrow.json.
"""
from __future__ import annotations

import html
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TIMEOUT = 20
MAX_IMAGE = 8 * 1024 * 1024

# Seconds to wait between requests to each site (be a polite guest).
MIN_GAP = {"musicbrainz.org": 1.1, "www.wikidata.org": 0.5, "en.wikipedia.org": 0.5,
           "api.tvmaze.com": 0.6}

FILM_TYPES = {
    "Q11424",     # film
    "Q24869",     # feature film
    "Q202866",    # animated film
    "Q17517379",  # animated feature film
    "Q93204",     # documentary film
    "Q506240",    # television film
    "Q229390",    # 3D film
    "Q24862",     # short film
    "Q20650540",  # anime film
}

# Turn Wikidata/TVmaze/MusicBrainz genre names into the same short names that
# folder genres use, so "science fiction film" and Movies/Sci-Fi line up.
GENRE_MAP = {
    "science fiction": "Sci-Fi", "science-fiction": "Sci-Fi", "sci-fi": "Sci-Fi",
    "science fiction action": "Sci-Fi", "speculative fiction": "Sci-Fi",
    "action": "Action", "action thriller": "Action", "martial arts": "Action",
    "adventure": "Adventure", "animated": "Animation", "animation": "Animation",
    "anime": "Anime", "comedy": "Comedy", "romantic comedy": "Romance",
    "comedy-drama": "Comedy", "black comedy": "Comedy", "parody": "Comedy",
    "crime": "Crime", "crime thriller": "Crime", "heist": "Crime", "gangster": "Crime",
    "documentary": "Documentary", "drama": "Drama", "family": "Family",
    "children's": "Kids", "fantasy": "Fantasy", "historical": "History",
    "history": "History", "horror": "Horror", "slasher": "Horror", "supernatural": "Horror",
    "musical": "Musical", "music": "Music", "mystery": "Mystery", "romance": "Romance",
    "romantic": "Romance", "thriller": "Thriller", "psychological thriller": "Thriller",
    "war": "War", "western": "Western", "biographical": "Biography", "sports": "Sports",
    "sport": "Sports", "superhero": "Action", "disaster": "Action", "teen": "Drama",
    "legal": "Drama", "medical": "Drama", "espionage": "Thriller", "spy": "Thriller",
    # music
    "rock": "Rock", "alternative rock": "Rock", "hard rock": "Rock", "indie rock": "Indie",
    "pop": "Pop", "hip hop": "Hip-Hop", "hip-hop": "Hip-Hop", "rap": "Hip-Hop",
    "jazz": "Jazz", "blues": "Blues", "classical": "Classical", "country": "Country",
    "electronic": "Electronic", "house": "Electronic", "techno": "Electronic",
    "metal": "Metal", "heavy metal": "Metal", "r&b": "R&B", "rnb": "R&B",
    "soul": "Soul", "reggae": "Reggae", "folk": "Folk", "punk": "Punk",
    "punk rock": "Punk", "indie": "Indie", "latin": "Latin", "gospel": "Gospel",
    "soundtrack": "Soundtrack", "ambient": "Electronic", "funk": "Funk", "disco": "Pop",
}


def tidy_genre(name: str) -> str | None:
    g = name.lower().strip()
    g = re.sub(r"\b(film|movie|television series|tv series|series)\b", "", g).strip(" -")
    if not g:
        return None
    if g in GENRE_MAP:
        return GENRE_MAP[g]
    for key, val in GENRE_MAP.items():   # "american horror" -> Horror
        if re.search(rf"\b{re.escape(key)}\b", g):
            return val
    return None   # unknown/obscure genres are skipped to keep the list tidy


def strip_html(s: str | None) -> str | None:
    if not s:
        return None
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip() or None


def short(text: str | None, limit: int = 700) -> str | None:
    """Trim to whole sentences."""
    if text:
        text = re.sub(r"\s+([,.;])", r"\1", re.sub(r"\s{2,}", " ", text)).replace("( )", "").strip()
    if not text or len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    return cut[: end + 1] if end > 200 else cut.rstrip() + "…"


def label(e: dict) -> str:
    """English label, or the language-neutral one Wikidata uses for names."""
    labels = e.get("labels", {})
    return (labels.get("en") or labels.get("mul") or {}).get("value", "")


def norm(s: str | None) -> str:
    s = (s or "").lower().replace("&", "and")
    s = re.sub(r"^(the|a|an)\s+", "", s)
    return re.sub(r"[^a-z0-9]+", "", s)


class Lookup:
    def __init__(self, contact: str = ""):
        ua = "Burrow/1.0 (self-hosted personal media server)"
        if contact:
            ua = f"Burrow/1.0 ({contact})"
        self.headers = {"User-Agent": ua, "Accept": "application/json"}
        self.last: dict[str, float] = {}
        self.lock = threading.Lock()

    # ---------------- HTTP ----------------
    def _wait(self, host: str):
        with self.lock:
            gap = MIN_GAP.get(host, 0.3)
            now = time.time()
            delay = self.last.get(host, 0) + gap - now
            if delay > 0:
                time.sleep(delay)
            self.last[host] = time.time()

    def _open(self, url: str, accept_json=True):
        host = urllib.parse.urlparse(url).hostname or ""
        for attempt in range(4):
            self._wait(host)
            headers = dict(self.headers)
            if not accept_json:
                headers["Accept"] = "image/*"
            try:
                return urllib.request.urlopen(urllib.request.Request(url, headers=headers),
                                              timeout=TIMEOUT)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code in (429, 503) and attempt < 3:
                    wait = e.headers.get("Retry-After", "")
                    time.sleep(min(int(wait) if wait.isdigit() else 5 * (attempt + 1), 60))
                    continue
                raise
        return None

    def get(self, url: str, **params):
        if params:
            url += "?" + urllib.parse.urlencode(params)
        r = self._open(url)
        if r is None:
            return None
        with r:
            return json.loads(r.read().decode("utf-8"))

    def download(self, url: str, dest: Path) -> bool:
        try:
            r = self._open(url, accept_json=False)
        except (urllib.error.URLError, OSError, ValueError):
            return False
        if r is None:
            return False
        with r:
            if not r.headers.get("Content-Type", "").startswith("image/"):
                return False
            data = r.read(MAX_IMAGE + 1)
        if len(data) > MAX_IMAGE:
            return False
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(dest)
        return True

    # ---------------- Movies: Wikidata + Wikipedia ----------------
    def movie(self, title: str, year: int | None) -> dict | None:
        WD = "https://www.wikidata.org/w/api.php"
        found = self.get(WD, action="wbsearchentities", search=title, language="en",
                         type="item", limit=15, format="json")
        ids = [r["id"] for r in (found or {}).get("search", [])]
        if not ids:
            return None
        ents = self.get(WD, action="wbgetentities", ids="|".join(ids),
                        props="claims|sitelinks|labels|descriptions",
                        languages="en|mul", sitefilter="enwiki", format="json") or {}
        ents = ents.get("entities", {})

        def vals(e, prop):
            out = []
            for c in e.get("claims", {}).get(prop, []):
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if v is not None:
                    out.append(v)
            return out

        def years(e):
            ys = set()
            for v in vals(e, "P577"):
                m = re.match(r"[+-](\d{4})", v.get("time", "")) if isinstance(v, dict) else None
                if m:
                    ys.add(int(m.group(1)))
            return ys

        best = None
        for qid in ids:                       # search order = relevance
            e = ents.get(qid)
            if not e:
                continue
            types = {v.get("id") for v in vals(e, "P31") if isinstance(v, dict)}
            desc = e.get("descriptions", {}).get("en", {}).get("value", "")
            if not (types & FILM_TYPES or re.search(r"\bfilm\b", desc)):
                continue
            name = label(e)
            if norm(name) != norm(title) and norm(title) not in norm(name):
                continue
            ys = years(e)
            if year and ys and not any(abs(y - year) <= 1 for y in ys):
                continue
            best = e
            break
        if not best:
            return None

        ys = sorted(years(best))
        genre_ids = [v["id"] for v in vals(best, "P136") if isinstance(v, dict)][:8]
        director_ids = [v["id"] for v in vals(best, "P57") if isinstance(v, dict)][:3]
        labels = {}
        if genre_ids or director_ids:
            lab = self.get(WD, action="wbgetentities", ids="|".join(genre_ids + director_ids),
                           props="labels", languages="en|mul", format="json") or {}
            for k, e in lab.get("entities", {}).items():
                labels[k] = label(e)
        genres = []
        for g in genre_ids:
            t = tidy_genre(labels.get(g, ""))
            if t and t not in genres:
                genres.append(t)
        runtime = None
        for v in vals(best, "P2047"):
            try:
                runtime = round(float(v["amount"]))
                break
            except (KeyError, TypeError, ValueError):
                pass

        meta = {
            "source": "Wikipedia", "ext_id": "wikidata:" + best["id"],
            "title": label(best) or title,
            "year": ys[0] if ys else year, "genres": genres[:5], "runtime": runtime,
            "director": ", ".join(labels[d] for d in director_ids if labels.get(d)) or None,
            "overview": best.get("descriptions", {}).get("en", {}).get("value"),
            "link": f"https://www.wikidata.org/wiki/{best['id']}",
        }
        imdb = vals(best, "P345")
        if imdb:
            meta["imdb"] = imdb[0]

        page = best.get("sitelinks", {}).get("enwiki", {}).get("title")
        if page:
            wp = self.get("https://en.wikipedia.org/w/api.php", action="query",
                          prop="extracts|pageimages", exintro=1, explaintext=1,
                          piprop="thumbnail", pithumbsize=500, pilicense="any", titles=page,
                          redirects=1, format="json") or {}
            for p in wp.get("query", {}).get("pages", {}).values():
                if p.get("extract"):
                    meta["overview"] = short(p["extract"])
                if p.get("thumbnail", {}).get("source"):
                    meta["image"] = p["thumbnail"]["source"]
            meta["link"] = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(page.replace(" ", "_"))
        return meta

    # ---------------- TV: TVmaze ----------------
    def show(self, title: str, year: int | None) -> dict | None:
        results = self.get("https://api.tvmaze.com/search/shows", q=title) or []
        pick = None
        for r in results:
            s = r.get("show", {})
            prem = (s.get("premiered") or "")[:4]
            if year and prem.isdigit() and abs(int(prem) - year) > 1:
                continue
            if norm(s.get("name")) == norm(title) or (r.get("score", 0) > 0.7 and not pick):
                pick = s
                if norm(s.get("name")) == norm(title):
                    break
        if not pick:
            return None
        full = self.get(f"https://api.tvmaze.com/shows/{pick['id']}", embed="episodes") or pick
        eps = {}
        for e in full.get("_embedded", {}).get("episodes", []):
            if e.get("season") is not None and e.get("number") is not None:
                eps[f"{e['season']}x{e['number']}"] = {
                    "title": e.get("name"), "overview": short(strip_html(e.get("summary")), 400),
                    "aired": e.get("airdate")}
        genres = []
        for g in full.get("genres", []):
            t = tidy_genre(g) or g
            if t not in genres:
                genres.append(t)
        prem = (full.get("premiered") or "")[:4]
        net = (full.get("network") or full.get("webChannel") or {}).get("name")
        return {
            "source": "TVmaze", "ext_id": f"tvmaze:{full['id']}",
            "title": full.get("name") or title, "year": int(prem) if prem.isdigit() else year,
            "genres": genres[:4], "overview": short(strip_html(full.get("summary"))),
            "rating": (full.get("rating") or {}).get("average"),
            "runtime": full.get("runtime") or full.get("averageRuntime"),
            "network": net, "status": full.get("status"),
            "image": (full.get("image") or {}).get("medium"),
            "link": full.get("url"), "episodes": eps,
        }

    # ---------------- Music: MusicBrainz + Cover Art Archive ----------------
    def album(self, artist: str, album: str) -> dict | None:
        def q(s):
            return '"' + re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r"\\\1", s) + '"'
        query = f"releasegroup:{q(album)}"
        if artist and artist.lower() not in ("unknown artist", "various artists"):
            query += f" AND artist:{q(artist)}"
        res = self.get("https://musicbrainz.org/ws/2/release-group/", query=query,
                       fmt="json", limit=5) or {}
        groups = [g for g in res.get("release-groups", []) if int(g.get("score", 0)) >= 90]
        if not groups:
            return None
        g = groups[0]
        tags = sorted(g.get("tags", []), key=lambda t: -t.get("count", 0))
        genres = []
        for t in tags:
            n = tidy_genre(t.get("name", ""))
            if n and n not in genres:
                genres.append(n)
        date = (g.get("first-release-date") or "")[:4]
        credit = "".join(c.get("name", "") + c.get("joinphrase", "")
                         for c in g.get("artist-credit", [])) or artist
        return {
            "source": "MusicBrainz", "ext_id": f"musicbrainz:{g['id']}",
            "title": g.get("title") or album, "artist": credit,
            "year": int(date) if date.isdigit() else None, "genres": genres[:3],
            "image": f"https://coverartarchive.org/release-group/{g['id']}/front-500",
            "link": f"https://musicbrainz.org/release-group/{g['id']}",
        }
