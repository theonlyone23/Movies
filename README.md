# Burrow

A tiny, private media server for your own movies, TV shows and music.

- **Private by design.** No accounts and no tracking. Your files, your library and what you watch stay on your computer. The page itself never contacts any outside site.
- **Covers and info from open databases** (details below).
- **No duplicates.** If you have the same movie, episode or song more than once, Burrow shows it once and plays the best copy. Nothing is ever deleted; a **Duplicates** page lists the extra files so you can clean up.
- **Knows your quality.** Every title shows its real specs, read from the file: **4K / 1080p / 720p**, **HDR10 / Dolby Vision**, **HEVC / H.264**, **5.1 / 7.1 surround**, **Dolby Digital+ / TrueHD / DTS-HD / Atmos**, and subtitle languages.
- **Tiny.** Pure Python, about 100 KB of code. Install [FFmpeg](https://ffmpeg.org) (free) for the most accurate quality info; without it, Burrow reads it from file names.
- **Simple.** Home, Movies, TV Shows, Music and Genres. Picks up where you left off and plays the next episode on its own.

## Covers and info (open databases)

| What | Where it comes from |
|---|---|
| Movies | [Wikidata](https://www.wikidata.org) (CC0) and [Wikipedia](https://en.wikipedia.org) (CC BY-SA): poster, description, genres, director, runtime |
| TV shows | [TVmaze](https://www.tvmaze.com) (CC BY-SA): cover, summary, genres, rating, network, real episode names and summaries |
| Music | [MusicBrainz](https://musicbrainz.org) (CC0) and the [Cover Art Archive](https://coverartarchive.org): album art, genres, year |

All of these are free, community-run and need no account or key. **What is sent:** only the title and year (or artist and album) as a search, from your computer, once per title. No file paths and nothing about you or what you watch. Covers are saved locally in `burrow/covers/`.

Your own files always win: a `poster.jpg` next to a movie, or a `.nfo` file, is used instead of anything online. If something matched wrong, open it and pick **Wrong match? Remove** or **Refresh info**. To turn lookups off completely, set `"online_info": false` in `burrow.json`.

## Quick start

1. Install Python 3.9+ (already on Mac/Linux; on Windows get it from python.org).
2. Run:
   ```
   cd burrow
   python3 server.py
   ```
   The first run creates `burrow.json`. Edit it so it points at your folders, then run it again.
3. Open http://127.0.0.1:8484

## Organizing your files

```
Movies/
  Horror/The Thing (1982).mkv        <- a genre folder sets the genre
  Paper Boats (2018)/movie.mp4
  Paper Boats (2018)/poster.jpg      <- optional poster
TV/
  Comedy/Office Plants/Season 1/Office Plants S01E01.mp4
  Deep Static/tvshow.nfo             <- optional: <genre>, <plot>
Music/
  Jazz/Artist Name/Album Name/01 - Song.mp3
```

Genres come from (1) genre folder names, (2) `.nfo` files, or (3) adding them yourself on any title's page.

## Watching on other devices (phone, TV, laptop)

In `burrow.json` set `"host": "0.0.0.0"` and a `"password"`, then open `http://<this-computer's-IP>:8484` on the other device. Leave `host` as `127.0.0.1` to keep it to this computer only.

## On your TV

Burrow has a TV mode: big text, and you move around with the remote's arrow keys. It's used automatically on LG, Samsung and Fire TV, or add `?tv=1` to the address. You can sideload apps for **LG (webOS)**, **Samsung (Tizen)** and **Fire TV**; see [`tv/README.md`](tv/README.md). A Roku app is planned.

## Formats

Burrow streams files as they are, with no re-encoding, which keeps it light. MP4 (H.264/AAC) plays everywhere. MKV plays in Chrome and Edge when it uses common codecs. MP3/M4A/FLAC/OGG audio all work.
