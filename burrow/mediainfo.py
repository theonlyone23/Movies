"""
Read technical details (4K / 1080p, HDR, 5.1 surround, codecs, length, music tags)
straight from your files. Uses ffprobe (part of the free, open-source FFmpeg) when
it is installed, and falls back to clues in the file name when it isn't.
Nothing here touches the network.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess

FFPROBE = shutil.which("ffprobe")

RES_RANK = {"4K": 4, "1080p": 3, "720p": 2, "SD": 1}


def _resolution(width: int, height: int) -> str | None:
    if not width:
        return None
    # judge by width so letterboxed films (1920x800) still count as 1080p
    if width >= 3200 or height >= 2000:
        return "4K"
    if width >= 1700 or height >= 1000:
        return "1080p"
    if width >= 1200 or height >= 700:
        return "720p"
    return "SD"


def _layout(ch: int) -> str | None:
    return {1: "Mono", 2: "Stereo", 3: "2.1", 6: "5.1", 7: "6.1", 8: "7.1"}.get(ch, f"{ch}ch" if ch else None)


VIDEO_CODECS = {"hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9",
                "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "vc1": "VC-1"}


def _audio_name(codec: str, profile: str) -> str:
    profile = profile or ""
    names = {"aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital+",
             "truehd": "Dolby TrueHD", "dts": "DTS", "flac": "FLAC", "opus": "Opus",
             "mp3": "MP3", "vorbis": "Vorbis", "alac": "ALAC"}
    name = names.get(codec, "PCM" if codec.startswith("pcm") else codec.upper())
    if codec == "dts" and "MA" in profile:
        name = "DTS-HD MA"
    elif codec == "dts" and "X" in profile.replace("DTS-HD", ""):
        name = "DTS:X"
    if "atmos" in profile.lower():
        name += " Atmos"
    return name


def probe(path: str) -> dict:
    """Return technical info for one file (empty dict if it can't be read)."""
    if not FFPROBE:
        return {}
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-print_format", "json",
             "-show_streams", "-show_format", path],
            capture_output=True, timeout=60, check=False).stdout
        data = json.loads(out or b"{}")
    except (subprocess.SubprocessError, OSError, json.JSONDecodeError):
        return {}

    info: dict = {"probed": True}
    fmt = data.get("format", {})
    try:
        info["duration"] = round(float(fmt.get("duration", 0)))
    except ValueError:
        pass

    streams = data.get("streams", [])
    video = [s for s in streams if s.get("codec_type") == "video"
             and not s.get("disposition", {}).get("attached_pic")]
    audio = [s for s in streams if s.get("codec_type") == "audio"]

    if video:
        v = max(video, key=lambda s: (s.get("width") or 0) * (s.get("height") or 0))
        w, h = v.get("width") or 0, v.get("height") or 0
        info.update(width=w, height=h, resolution=_resolution(w, h),
                    video_codec=VIDEO_CODECS.get(v.get("codec_name", ""), (v.get("codec_name") or "").upper()))
        side = " ".join(str(d.get("side_data_type", "")) for d in v.get("side_data_list", []))
        transfer = v.get("color_transfer", "")
        if "DOVI" in side or "Dolby Vision" in side:
            info["hdr"] = "Dolby Vision"
        elif transfer == "smpte2084":
            info["hdr"] = "HDR10+" if "HDR10+" in side or "2094" in side else "HDR10"
        elif transfer == "arib-std-b67":
            info["hdr"] = "HLG"

    if audio:
        a = max(audio, key=lambda s: s.get("channels") or 0)
        ch = a.get("channels") or 0
        info.update(audio_channels=ch, audio_layout=_layout(ch),
                    audio_codec=_audio_name(a.get("codec_name", ""), a.get("profile", "")))
        langs = sorted({(s.get("tags") or {}).get("language", "") for s in audio} - {"", "und"})
        if len(langs) > 1:
            info["audio_languages"] = langs
    subs = sorted({(s.get("tags") or {}).get("language", "") for s in streams
                   if s.get("codec_type") == "subtitle"} - {"", "und"})
    if subs:
        info["subtitles"] = subs

    # Music tags (artist / album / title / track / genre / year)
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    if not tags and audio:
        tags = {k.lower(): v for k, v in (audio[0].get("tags") or {}).items()}
    keep = {}
    for k in ("title", "artist", "album_artist", "album", "track", "genre", "date"):
        if tags.get(k):
            keep[k] = str(tags[k]).strip()
    if keep:
        info["tags"] = keep
    return info


NAME_HINTS = [
    (re.compile(r"\b(2160p|4k|uhd)\b", re.I), ("resolution", "4K")),
    (re.compile(r"\b1080[pi]\b", re.I), ("resolution", "1080p")),
    (re.compile(r"\b720p\b", re.I), ("resolution", "720p")),
    (re.compile(r"\b(480p|576p|dvdrip)\b", re.I), ("resolution", "SD")),
    (re.compile(r"\b(dv|dovi|dolby[ ._-]?vision)\b", re.I), ("hdr", "Dolby Vision")),
    (re.compile(r"\bhdr10\+", re.I), ("hdr", "HDR10+")),
    (re.compile(r"\bhdr(10)?\b", re.I), ("hdr", "HDR10")),
    (re.compile(r"\b(x265|h\.?265|hevc)\b", re.I), ("video_codec", "HEVC")),
    (re.compile(r"\b(x264|h\.?264|avc)\b", re.I), ("video_codec", "H.264")),
    (re.compile(r"\bav1\b", re.I), ("video_codec", "AV1")),
    (re.compile(r"\b7[ ._]1\b"), ("audio_layout", "7.1")),
    (re.compile(r"\b5[ ._]1\b"), ("audio_layout", "5.1")),
    (re.compile(r"\batmos\b", re.I), ("audio_codec", "Atmos")),
    (re.compile(r"\btruehd\b", re.I), ("audio_codec", "Dolby TrueHD")),
    (re.compile(r"\bdts[ ._-]?hd([ ._-]?ma)?\b", re.I), ("audio_codec", "DTS-HD MA")),
    (re.compile(r"\bdts\b", re.I), ("audio_codec", "DTS")),
    (re.compile(r"\b(ddp|eac3|dd\+)", re.I), ("audio_codec", "Dolby Digital+")),
    (re.compile(r"\b(ac3|dd)\b", re.I), ("audio_codec", "Dolby Digital")),
]


def from_name(name: str) -> dict:
    """Guess quality from a file name like Movie.2019.2160p.HDR.DTS-HD.MA.5.1.mkv"""
    info: dict = {}
    for rx, (key, val) in NAME_HINTS:
        if key not in info and rx.search(name):
            info[key] = val
    if info.get("audio_layout"):
        info["audio_channels"] = {"5.1": 6, "7.1": 8}[info["audio_layout"]]
    return info


def describe(path: str, name: str) -> dict:
    """Best available info: what's in the file, with gaps filled from the name."""
    info = probe(path)
    for k, v in from_name(name).items():
        info.setdefault(k, v)
    return info


def quality_score(info: dict) -> int:
    """Higher = better copy. Used to pick which duplicate to keep."""
    hdr = 1 if info.get("hdr") else 0
    return RES_RANK.get(info.get("resolution"), 0) * 1000 + hdr * 100 + (info.get("audio_channels") or 0)
