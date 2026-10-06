# TubePlayer

An ad-free video browser and player for iPhone and iPad.

- **Browse** video sites in a built-in browser that blocks ads and trackers and keeps sites from autoplaying.
- **Watch right away.** Opening a video page hands it to yt-dlp (running on the device), which finds the real stream. VLCKit then plays it full screen with no ads.
- **Download** any video for offline viewing, and **stop** a download at any time. Stopping also deletes the partly downloaded file.
- **Feed.** Swipe through your downloads one after another, full screen. Favorite, add to a playlist, share or delete from the feed.
- **Library.** Shows your downloads, favorites and playlists (create, rename, reorder, delete), plus the downloads that are still in progress.

## Setup

Requirements: Xcode 16 or newer, iOS/iPadOS 17 or newer, and `python3` with pip on the Mac (only used to fetch packages).

```bash
./Tools/fetch-dependencies.sh
open TubePlayer.xcodeproj
```

The script downloads the embedded Python runtime (BeeWare Python-Apple-support, checksum verified) into `Vendor/` and installs yt-dlp, yt-dlp-ejs and certifi into `python/app_packages/`. Both folders are git-ignored.

In Xcode, pick your team under **Signing & Capabilities**, then run on a device or simulator. Swift Package Manager fetches VLCKit automatically.

## How it works

| Piece | Where |
|---|---|
| Embedded CPython 3.14 | `Vendor/Python.xcframework`, started by `TubePlayer/Engine/PythonBridge.c` |
| yt-dlp wrapper (extract, download, cancel, update) | `python/app/tubeplayer_engine.py` |
| YouTube JS challenge solver using JavaScriptCore | `python/app/tubeplayer_jsc.py` |
| Swift API over the engine | `TubePlayer/Engine/YTDLPEngine.swift` |
| Browser, ad blocking, video page detection | `TubePlayer/Browser/` |
| VLCKit player | `TubePlayer/Player/` |
| Downloads | `TubePlayer/Downloads/DownloadManager.swift` |
| Library, feed, playlists (SwiftData) | `TubePlayer/Library/` |

- **Streams:** high-quality video usually comes as separate video and audio streams. VLC plays them together (with the audio added as a second track), so nothing has to be merged.
- **Downloads:** the video and audio are saved as separate files in `Documents/Videos/<id>/` and played the same way. You can see these files in the Files app under *On My iPhone › TubePlayer*.
- **JavaScript challenges:** YouTube requires solving JavaScript challenges. iOS apps can't run deno or node, so a yt-dlp challenge provider runs yt-dlp's solver scripts in JavaScriptCore through its C API. If that fails, yt-dlp falls back to clients that don't need JavaScript.
- **Updating yt-dlp:** use *Library › Settings › Update yt-dlp*, which downloads the latest yt-dlp from PyPI, then relaunch the app. You can also re-run `./Tools/fetch-dependencies.sh` and rebuild.

## Notes

- This is a personal sideloaded app; downloading from some sites is against their terms of service, so it is not suitable for the App Store.
- With a free Apple ID, apps signed in Xcode expire after 7 days; a paid developer account extends that to a year.
- The app also runs on Apple silicon Macs ("Designed for iPad").
