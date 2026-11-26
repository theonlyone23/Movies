#!/usr/bin/env python3
"""Assemble the TV apps from the shared connect screen and icons.

    python3 tv/build.py

Output:
  tv/dist/webos/   -> LG webOS app folder (and an .ipk if the webOS CLI is installed)
  tv/dist/tizen/   -> Samsung Tizen app folder (sign and package it in Tizen Studio)
  tv/firetv/       -> Android Studio project for Fire TV (assets refreshed in place)
"""
import shutil
import subprocess
from pathlib import Path

TV = Path(__file__).resolve().parent
DIST = TV / "dist"
CONNECT = TV / "connect" / "index.html"
ICONS = TV / "icons"


def fresh(d: Path) -> Path:
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    return d


def main():
    w = fresh(DIST / "webos")
    shutil.copy(CONNECT, w / "index.html")
    shutil.copy(TV / "webos" / "appinfo.json", w)
    for n in ("icon-80.png", "icon-130.png"):
        shutil.copy(ICONS / n, w)

    t = fresh(DIST / "tizen")
    shutil.copy(CONNECT, t / "index.html")
    shutil.copy(TV / "tizen" / "config.xml", t)
    shutil.copy(ICONS / "icon-512.png", t)

    main_dir = TV / "firetv" / "app" / "src" / "main"
    shutil.copy(CONNECT, main_dir / "assets" / "index.html")
    shutil.copy(ICONS / "banner-320x180.png", main_dir / "res" / "drawable" / "banner.png")
    shutil.copy(ICONS / "icon-512.png", main_dir / "res" / "mipmap" / "ic_launcher.png")
    print("Assembled dist/webos, dist/tizen and refreshed firetv assets.")

    ares = shutil.which("ares-package")
    if ares:
        subprocess.run([ares, "--no-minify", str(w), "-o", str(DIST)], check=True)
        print("Built LG package in", DIST)
    else:
        print("Tip: run  npm install -g @webos-tools/cli  to build the LG .ipk")


if __name__ == "__main__":
    main()
