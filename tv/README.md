# Burrow on your TV

Each TV app is a small wrapper. The first time it opens, it asks for your Burrow server's address and remembers it. After that it connects straight away. Your TV remote's arrows, OK, Back, play/pause and rewind/fast-forward buttons all work.

**First, let your TV reach Burrow.** In `burrow/burrow.json` set:

```json
"host": "0.0.0.0",
"password": "pick-something"
```

Restart Burrow, then find your computer's local IP address (for example `192.168.1.20`). That plus `:8484` is what you type on the TV.

> Quickest test, no install needed: open your TV's web browser and go to `http://192.168.1.20:8484/?tv=1`.

Run `python3 tv/build.py` after changing anything in `tv/connect/` or `tv/icons/`.

---

## LG TV (webOS): ready to install

The package is already built: **`tv/dist/app.burrow.tv_1.0.0_all.ipk`** (23 KB).

1. On the TV, install **Developer Mode** from the LG Content Store and sign in with a free LG developer account. Turn on *Dev Mode Status* and *Key Server*.
2. On your computer: `npm install -g @webos-tools/cli`
3. `ares-setup-device` → add your TV's IP (passphrase is shown in the Developer Mode app).
4. `ares-install --device tv tv/dist/app.burrow.tv_1.0.0_all.ipk`

Note: LG's Developer Mode session expires and must be extended in the app (every 50 hours unless renewed).

## Samsung TV (Tizen)

Samsung requires every app to be signed with *your* certificate, so this step has to happen on your computer:

1. Install **Tizen Studio** with the *TV Extensions* and *Samsung Certificate Extension*.
2. On the TV: Apps → press `1 2 3 4 5` on the remote → turn Developer Mode **On**, enter your computer's IP, restart the TV.
3. In Tizen Studio: *Certificate Manager* → create a Samsung certificate. *Device Manager* → connect to the TV.
4. *File → Import → Tizen → Tizen Project* → choose `tv/dist/tizen`, then right-click the project → *Run As → Tizen Web Application*.

## Fire TV (Fire OS / Android)

`tv/firetv/` is an Android Studio project (a full-screen WebView).

1. Open `tv/firetv` in **Android Studio** and let it sync. Then use *Build → Build APK(s)*.
2. On the Fire TV: *Settings → My Fire TV → Developer options* → turn on *ADB debugging* and *Apps from Unknown Sources*.
3. `adb connect <firetv-ip>` then `adb install app/build/outputs/apk/debug/app-debug.apk`

(Or upload the APK somewhere on your network and use the *Downloader* app.) The same APK also works on Android TV / Google TV boxes.

## Roku: not yet

Roku can't run web pages; it needs a separate app written in Roku's own language (BrightScript). That's the planned next step. Burrow's server already has everything a Roku app would need.
