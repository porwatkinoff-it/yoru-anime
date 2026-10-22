# Architecture: Night Anime 2.0 (best of Netflix, Crunchyroll, Кинопоиск on Anime 365)

## Stack

No server of our own: Anime 365 is the backend, the apps keep personal state locally and sync it with the TV over the home network (exists since 1.6).

| layer | choice | why |
| --- | --- | --- |
| iOS / iPadOS | SwiftUI + UIKit player (MobileVLCKit) | already built, plays ASS subtitles and every Anime 365 stream |
| Android phone + TV | one APK, plain Android views in Java + LibVLC 3.6.5 | already built and tuned for the 2 GB SberBox; no extra libraries |
| content API | Anime 365 public API (`/api/series`, `/api/translations`, `/api/translations/embed`) with the user's own token | the only official source |
| downloads iOS | background `URLSession` (`com.resvvt.nightanime.downloads`) | keeps downloading with the app closed, resumes after relaunch |
| downloads Android | system `DownloadManager` into the app's own external files dir | background, notification, retries and Wi‑Fi rule for free; files deleted with the app |
| local storage | UserDefaults / SharedPreferences (existing keys) + `downloads.json` index | same keys as the sync format |
| sync | existing `_nightanime._tcp` HTTP on the TV (Night Air) | unchanged |

## Data

Remote entities: Series, Episode, Translation, Embed (see recon). Local:

```
Download  episodeId (key), seriesId, series (raw JSON of the title for offline cards), episodeTitle, episodeNumber,
          translationId, translationTitle, height, file, subtitles?, bytes, total,
          state: queued | running | paused | failed | done, error?, createdAt
          stored: iOS  Application Support/Downloads/index.json, files <episodeId>.mp4 / .ass
                  Android  getExternalFilesDir("Downloads")/<episodeId>.mp4 / .ass, index in prefs "downloads"
```

Progress for a downloaded episode uses the same `position-<translationId>` key, so offline viewing syncs to the TV like online viewing.

## API calls by flow

| call | does | auth | flow |
| --- | --- | --- | --- |
| GET /api/series?isAiring=1 | hero + «Сейчас выходят», schedule (uses `episodes[].firstUploadedDateTime`) | no | F01 F05 |
| GET /api/series?year=Y&fields=… | «Лучшее года» | no | F02 |
| GET /api/series?type=movie&fields=… | «Фильмы» | no | F02 |
| GET /api/series?genres=G&fields=… | genre shelves, «Похожие», search chips | no | F02 |
| GET /api/series?query=… | search | no | F02 |
| GET /api/series/{id} | title page: description, genres, episodes | no | F02 F03 |
| GET /api/translations?episodeId=… | translation chooser | no | F02 F03 |
| GET /api/translations/embed/{id} | stream + download URLs + subtitles | token | F01 F02 F03 |

`fields=id,titles,posterUrl,posterUrlSmall,typeTitle,year,myAnimeListScore,season,genres` keeps shelf payloads small (important on the box).

Jobs: new-episode check every hour (exists); download queue runs one file at a time on iOS (two on Android via DownloadManager).

## The parts that bite

- Download links come from the embed call and may expire: fetch the embed right before queueing, re-fetch on retry.
- No download link without a subscription: show the site's reason, do not queue.
- App killed mid-download: iOS background session reconnects by identifier on launch; Android DownloadManager keeps going, the app reconciles states from `DownloadManager.query` on resume.
- Wi‑Fi only: iOS `allowsCellularAccess=false` per request; Android `setAllowedOverMetered(false)`.
- Storage: show free space; DownloadManager fails with `ERROR_INSUFFICIENT_SPACE`, iOS with `NSURLErrorCannotWriteToFile` → state failed with a readable message.
- Offline: home falls back to downloads when the network call fails.
- TV focus: horizontal shelves inside a vertical scroll; focused card scales, shelf scrolls to keep it visible, UP/DOWN moves between shelves.

## Build order

1. Vertical slice: new Home with hero + shelves + title page + play (S01, S03, S05) on iOS.
2. Must-haves: downloads (S07, S08) iOS; Android phone/TV home + title page; Android downloads.
3. Should-haves: search chips (S02), schedule (S09), quality / Wi‑Fi / auto-delete settings, similar titles.
4. Fixes: from testing on simulator and the box.
