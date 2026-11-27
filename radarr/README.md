# Movie setup for Radarr (Windows)

One command sets up [Radarr](https://radarr.video) so your movie collection:

- **Is 1080p at most.** No 4K and no huge remux files.
- **Prefers 5.1 surround sound.** If a release with 5.1 exists, Radarr picks it. If not, it gets the normal 1080p copy, then swaps it for a 5.1 copy automatically when one shows up.
- **Is organized using a public movie database.** Radarr looks every movie up on TMDb, renames it, and saves a poster, fanart and a `.nfo` info file (plot, cast, genres, rating) next to it.
- **Lives on the drive you pick.** Finished downloads are moved out of your download folder onto that drive.

```
E:\Movies\
  Heat (1995)\
    Heat (1995) [Bluray-1080p][DTS 5.1]-GROUP.mkv
    Heat (1995) [Bluray-1080p][DTS 5.1]-GROUP.nfo
    poster.jpg
    fanart.jpg
```

Burrow (in this repo) reads these folders, posters and `.nfo` files as they are.

## What you need

1. **Radarr** installed and running. It's free: get the Windows installer from https://radarr.video. Radarr is the movie version of Sonarr.
2. **A download client** added in Radarr (Settings > Download Clients) and **indexers** (Settings > Indexers). Use the ones you already use with Sonarr.

## Install

1. Download this folder: on GitHub click **Code > Download ZIP**, then unzip it. You only need the `radarr` folder (`movies.cmd` and `movies.ps1`). Put it anywhere, for example `C:\Tools\movies`.
2. Open **Command Prompt** in that folder (in File Explorer, type `cmd` in the address bar and press Enter).
3. Run:
   ```
   movies setup
   ```
   It finds Radarr's API key by itself, shows your drives with their free space, and asks where the library should go. Pick a number or type a folder like `E:\Media\Movies`.

You can also just double-click `movies.cmd` to see the commands.

## Commands

| Command | What it does |
|---|---|
| `movies setup` | Sets everything up. Safe to run again, for example to change drives. |
| `movies organize D:\Downloads` | Takes the movies sitting in a folder, looks each one up, adds it to Radarr, and moves it into your library with poster and info. Each sub-folder or video file counts as one movie. |
| `movies search` | Looks for every missing movie, and for 5.1 or 1080p upgrades of what you already have. Use this to rebuild your collection. |
| `movies status` | Shows the library folder, the quality settings and how many movies you have. |

Options:

- `movies setup -Allow720p`: if no 1080p release exists, accept 720p instead of waiting.
- `movies setup -Url http://192.168.1.20:7878`: Radarr runs on another computer or port.
- `movies setup -ApiKey YOURKEY`: if the key isn't found automatically (Radarr > Settings > General > Security).

## Starting your collection over

1. `movies setup` and choose the new drive. If Radarr already has movies, it offers to switch them all to the new quality settings and to move their files to the new drive.
2. In Radarr, add movies with **Quality profile: 1080p 5.1** and the new folder. To bring in an old folder of movies, use Radarr's **Movies > Library Import**.
3. `movies search` to start downloading everything that's missing or can be upgraded.

## What setup changes in Radarr

| Radarr setting | Value |
|---|---|
| Custom format **Surround 5.1** | Matches `5.1` in the release name (DDP5.1, DTS-HD.MA.5.1, AAC 5.1...). |
| Quality profile **1080p 5.1** | Allowed: HDTV-1080p, WEB-DL/WEBRip 1080p, Bluray-1080p. Surround 5.1 scores 100; minimum score 0, so a normal release is still allowed; upgrades on until it has 5.1 and Bluray-1080p. |
| Media Management | Rename movies on, folder `Title (Year)`, subtitles (`.srt` etc.) imported, empty folders removed. |
| Metadata | Kodi/Emby: `.nfo` plus poster and fanart images. |
| Root folder | The drive or folder you picked. |
| Download Clients | Completed Download Handling on, so finished downloads are moved into the library. |

It doesn't touch your indexers or download clients. Settings are saved in `%APPDATA%\MovieSetup\settings.json`. Nothing is sent anywhere except to your own Radarr.

Notes:

- A release labeled 7.1 or Atmos counts as a normal release (it doesn't get the 5.1 bonus), because you asked for 5.1 at most. A 7.1 track still plays on a 5.1 system.
- Moving files to a different drive means copying them, so a big library takes a while. If you use torrents, Radarr copies (it doesn't move) so you can keep seeding. Your download client's own settings decide when the torrent and its files get removed.
