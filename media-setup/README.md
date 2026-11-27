# Movie and TV setup for Radarr and Sonarr (Windows)

`movies setup` configures [Radarr](https://radarr.video) for movies and `tv setup` configures [Sonarr](https://sonarr.tv) for TV shows. Both work the same way. TV is covered [further down](#tv-shows-sonarr). To clean up and merge the drives you already have, see [`library`](#cleaning-up-your-drives-library).

One command sets up Radarr so your movie collection:

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

1. Download this folder: on GitHub click **Code > Download ZIP**, then unzip it. You only need the `media-setup` folder. Put it anywhere, for example `C:\Tools\movies`.
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

## TV shows (Sonarr)

`tv` works just like `movies`, but for Sonarr (v4 or newer; free from https://sonarr.tv):

```
tv setup
tv organize D:\Downloads
tv search
tv status
```

Same rules: 1080p at most, 5.1 surround preferred, a normal 1080p copy if there's no 5.1 (swapped for 5.1 later), artwork and `.nfo` files from TheTVDB (a public TV database), and the library on the drive you pick (it suggests `X:\TV`). Its settings are saved separately, in `%APPDATA%\MovieSetup\tv-settings.json`.

```
E:\TV\
  Office Plants (2019)\
    tvshow.nfo, poster.jpg, fanart.jpg
    Season 01\
      Office Plants (2019) - S01E01 - Pilot [WEBDL-1080p][EAC3 5.1]-GROUP.mkv
      Office Plants (2019) - S01E01 - Pilot [WEBDL-1080p][EAC3 5.1]-GROUP.nfo
```

Differences from movies:

- Quality upgrades stop at **WEB 1080p**, because most shows come out as WEB-DL and chasing Blu-ray copies would re-download whole seasons. Upgrades to 5.1 still happen.
- `tv organize` takes a folder of show folders, season packs or single episodes. If it's a new show, it adds it to Sonarr first, then moves the episodes into `Show (Year)\Season 01\...`.
- `tv setup` offers to switch shows Sonarr already has to the new settings and move them to the new drive.

## Cleaning up your drives (`library`)

`library` finds every movie and episode across all your drives, works out which copies are duplicates, keeps the best one, and can gather everything onto one drive.

```
library scan D: E: F:                  report only, changes nothing
library dedupe D: E: F:                set the extra copies aside
library consolidate D: E: F: -To G:    move the kept copies to G:\Movies and G:\TV
library purge D: E: F:                 delete the set-aside copies for good
library undo                           put back what the last dedupe or consolidate moved
```

Leave out the drive letters to pick them from a list. Type `D:`, not `"D:\"` (in CMD, quotes around a path that ends in `\` break it).

**Recommended order**

1. `library scan D: E: F:` writes `library-report.csv` (opens in Excel). Every file is listed as **KEEP** or **EXTRA**, with the reason. Check it.
2. `library dedupe D: E: F:` moves each EXTRA into a `_Duplicates` folder **on the same drive**. It's instant and nothing is deleted.
3. `library consolidate D: E: F: -To G:` moves the kept copies to `G:\Movies\Title (Year)\` and `G:\TV\Show\Season 01\`, along with their subtitles, `.nfo` files and posters. It checks for free space first. You can stop it with Ctrl+C and run it again; it continues where it left off.
4. Watch a few things. If anything's wrong, `library undo` reverses the last step (run it again to reverse the one before).
5. `library purge D: E: F:` deletes the `_Duplicates` folders, after you type `DELETE`.
6. In Radarr: **Movies > Library Import** on `G:\Movies`. In Sonarr: **Series > Library Import** on `G:\TV`. They match everything to the online databases and can rename files and add posters. From then on, new downloads arrive in the same place.

**Which copy is kept**

- 1080p wins (4K is ranked just below it, since you wanted 1080p at most; use `-Prefer4K` to flip that), then 720p, then SD.
- Then surround sound (5.1 or 7.1) beats stereo.
- Then the bigger file (higher bitrate) wins.
- Byte-for-byte identical copies are caught even when their names are different.

Install FFmpeg (`winget install Gyan.FFmpeg`) so the resolution and audio channels are read from the files themselves. Without it, they're guessed from file names, and badly named files can be judged wrong.

**What's never treated as a duplicate**

- Parts: `CD1` and `CD2`, `Part 1` and `Part 2`.
- Different cuts: Director's Cut, Extended, Theatrical, Unrated and so on.
- A double episode file (`S01E01E02`) and a single `S01E01`.
- Samples, trailers and extras folders are skipped completely. Files it can't recognize are left alone.

Every move is logged in `%APPDATA%\MovieSetup\logs`.
