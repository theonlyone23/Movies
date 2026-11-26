# Burrow

A tiny, private media server for your own movies, TV shows and music.

- **Private by design.** No accounts, no telemetry, no online metadata lookups. The library index is one SQLite file on your computer. The page blocks every outside request.
- **Tiny.** Pure Python standard library: nothing to install, about 60 KB of code.
- **Simple.** Home, Movies, TV Shows, Music and Genres. Picks up where you left off and plays the next episode on its own.

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

## Formats

Burrow streams files as they are, with no re-encoding, which keeps it light. MP4 (H.264/AAC) plays everywhere. MKV plays in Chrome and Edge when it uses common codecs. MP3/M4A/FLAC/OGG audio all work.
