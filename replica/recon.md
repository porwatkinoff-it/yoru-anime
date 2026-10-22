# Recon map: Netflix + Crunchyroll + Кинопоиск → Night Anime (iOS, iPadOS, Android phone, Android TV)

Scope: the watching loop of three streaming apps — home showcase, title page, episodes, player, my list, history, offline downloads, release schedule. Content comes from Anime 365 (smotret-anime.app), through its public API and the user's own account.
For: the user themself (personal apps on an iPhone/iPad, an Android phone and a SberBox).
Date: 2026-10-22

Clean-room: worked from public help pages, app store listings and the apps' public behaviour as a normal user knows it. No code, assets, logos, colours or copy of the originals are used. Night Anime keeps its own night palette, icon and wording.

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | Netflix help: downloads | https://help.netflix.com/node/54816 | download per episode, quality, Wi‑Fi only, smart downloads (delete watched, fetch next) |
| 2 | Netflix help: continue watching / My List | https://help.netflix.com/node/102242 | rows, progress bars, remove from row |
| 3 | Crunchyroll help: offline viewing | https://help.crunchyroll.com/hc/en-us/articles/360041437731 | download episodes, sub/dub per download, storage |
| 4 | Crunchyroll simulcast calendar | https://www.crunchyroll.com/simulcastcalendar | weekly schedule of new episodes |
| 5 | Кинопоиск помощь: загрузки | https://yandex.ru/support/kinopoisk/ | offline, quality choice, «Буду смотреть» |
| 6 | App Store listings (Netflix, Crunchyroll, Кинопоиск) | apps.apple.com | screenshots of home, title page, downloads |
| 7 | Anime 365 public API | https://smotret-anime.app/api/series | data model: series, episodes, translations, embed (stream + download URLs + subtitles) |
| 8 | current Night Anime 1.6.x | work/night-anime | baseline: catalog grid, favorites, history, episode list, translation chooser, VLC player, TV sync |

## Core loop

Open the app → see what to continue or what is new → open a title → press one big button → watch; on the phone, download episodes for later without internet.

## Screens

| ID | screen | how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Home (Главная) | launch, tab 1 | showcase | hero billboard (backdrop, title, meta, ▶ Смотреть, ＋ Мой список), rows: Продолжить (progress bar), Новые серии, Сейчас выходят, Лучшее года, Фильмы, жанровые подборки | loading skeleton, filled, offline (only downloads shown), error + retry |
| S02 | Search (Поиск) | tab 2 | find a title | search field, genre chips, result grid | empty query (genre chips + popular), typing, no results, error |
| S03 | Title page (Аниме) | tap a card | decide and start | poster backdrop with gradient, title, rating chip coloured by score, year · type · season · episodes, genres, description (expand), primary ▶ Смотреть / Продолжить N серию, ♡ Мой список, ↓ Скачать, episode list with per-episode progress and download state, «Похожие» row | loading, filled, no episodes, error |
| S04 | Translation chooser | tap episode / play | pick sub/dub | list grouped Субтитры / Озвучка / Оригинал, remembered ★ first | loading, empty, needs login |
| S05 | Player | after S04 | watch | existing Netflix-style chrome, skip opening in bottom row, next episode, speed, subs, quality | buffering, playing, paused, ended (up next) |
| S06 | My list (Моё) | tab 3 | own titles | segments Избранное / История, grid with progress | empty, filled |
| S07 | Downloads (Загрузки) | tab 4 (phones) | offline | groups by title, each episode: progress / size / ✓, play, delete; storage line; settings: quality, Wi‑Fi only, auto-delete watched | empty with hint, downloading, paused/failed + retry, done |
| S08 | Download chooser | ↓ on S03 or episode | queue | translation, quality | needs login, no download link |
| S09 | Schedule (Расписание) | link on Home | when new episodes come out | weekday columns/sections built from last upload dates of airing titles | loading, filled |
| S10 | Account | top-right | login/logout, version, settings | existing login form + download settings | logged out, logged in |

## Flows

```
F01 Continue watching
    S01 row «Продолжить» -> S05 (resumes last episode with remembered translation)
    happy path clicks: 1 (Netflix: 1, Crunchyroll: 2, current Night Anime: 4)
    edge: translation gone, token expired, finished episode -> next one
F02 Find and start a new title
    S02 type -> S03 -> ▶ Смотреть -> S04 -> S05
    happy path clicks: 3 (+ typing)
    edge: no results, no active episodes, subtitles missing
F03 Download an episode for later (phones)
    S03 ↓ on episode -> S08 pick translation/quality -> S07 shows progress -> (offline) S07 ▶ -> S05 from file
    happy path clicks: 3
    edge: no download URL (subscription), app killed mid-download, no space, Wi‑Fi only and on mobile data, deleted file
F04 Download a whole season
    S03 «Скачать все» -> S08 -> queue N episodes
F05 Check what is new
    S01 row «Новые серии» / S09 schedule -> S03
F06 Watch on TV what I started on phone
    phone S05 -> sync -> TV home «Продолжить» (exists since 1.6)
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Hero billboard | phone (portrait poster + blur), TV/iPad (wide) | loading, filled | S01 |
| Poster card | row (small), grid, continue (with progress bar) | default, focused (TV), new-episode badge, downloaded badge | S01 S02 S03 S06 |
| Shelf (horizontal row) | titled, with «Все» | loading skeleton, empty (hidden) | S01 S03 |
| Rating chip | high ≥8 green, mid ≥6.5 neutral, low red | | S01 S03 |
| Pill button | primary (white), secondary (glass), icon | default, pressed, focused, disabled | all |
| Episode row | default, current (продолжить), watched, downloading, downloaded | progress bar | S03 |
| Genre chip | default, selected | | S02 S03 |
| Tab bar | phone bottom bar, TV top bar | selected | all |
| Download row | queued, downloading %, paused, failed, done | | S07 |

## Inferred data model

```
Series      id, titles{ru,romaji}, posterUrl, posterUrlSmall, type, typeTitle, year, season,
            myAnimeListScore, numberOfEpisodes, isAiring, genres[{id,title}], descriptions[{source,value}], episodes[]
            evidence: GET /api/series, /api/series/{id}   confidence: high (checked 2026-10-22)
Episode     id, episodeFull, episodeInt, episodeType, firstUploadedDateTime, isActive, seriesId
            confidence: high
Translation id, type (subRu|voiceRu|raw|…), authorsSummary   confidence: high
Embed       stream[{height, urls[]}], download[{height, url}], subtitlesUrl  (needs access_token)
            confidence: high (already used by the player)
Download    (local) episodeId, seriesId, translationId, title, height, file, subtitles file, bytes, total, state
            confidence: our own design
Progress    position-<translationId>, done-<episodeId>, last-<seriesId>, tr-<seriesId> (existing, synced with TV)
```

Relationships: Series 1-n Episode 1-n Translation 1-1 Embed; Download n-1 Episode.

API filters checked: `isAiring`, `year`, `type`, `genres`, `query`, `fields` (results come sorted by score).

## Feature matrix

See `features.csv`.

## Out of scope

- The originals' catalogues, originals, trailers with sound autoplay licensed from studios — content is whatever Anime 365 has.
- Profiles/kids accounts — Anime 365 has one account per user.
- Ratings by Night users, comments, social — no backend of our own (and none wanted).
- DRM-protected downloads — Anime 365 gives plain files; they stay inside the app sandbox.
- Downloads on the TV box — not needed (always online, 2 GB RAM, small storage).

## Size

Screens 10, flows 6, entities 5 (1 local). Hard parts: background downloads on iOS (URLSession background session) and Android (DownloadManager), offline playback with subtitles in VLC, TV D-pad focus across horizontal shelves. Size: M.
