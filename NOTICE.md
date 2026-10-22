# Yoru Anime — notices

Yoru Anime (formerly Night Anime) native client © 2026. GPL-3.0-or-later; see LICENSE.

- **iOS MobileVLCKit 3.6.0**: VideoLAN and contributors, LGPL-2.1-or-later;
  source: https://code.videolan.org/videolan/VLCKit/-/tree/3.6.0
  https://github.com/videolan/vlckit/tree/3.6.0
  Binary XCFramework packaging: https://github.com/tylerjonesio/vlckit-spm/tree/3.6.0
  Original archive checksum is recorded in README.md. Binary includes libVLC/VLC modules
  and third-party multimedia/subtitle libraries under their respective licenses.
- **Android libvlc-all 3.6.5**: VideoLAN and contributors;
  https://code.videolan.org/videolan/libvlcjni
  https://code.videolan.org/videolan/vlc
  Maven artifact: org.videolan.android:libvlc-all:3.6.5.
- **ASS rendering** is provided by the bundled VLC/libass stack, not a replacement
  plain-text subtitle parser. Original library notices and symbols are retained.
- API schema: https://smotret-anime.app/api/openapi.yaml (Anime 365).
  API response field definitions were also verified against the MIT-licensed client
  https://github.com/ragedrugg/anime365; no wrapper implementation code was copied.
- Posters, series metadata, video and translated subtitles belong to their respective
  rights holders and are fetched from the user's Anime 365 service. They are not
  included in the application package. QA uses an existing wallpaper clip locally;
  that clip is not part of the distributed application/source archive.

The application dynamically links MobileVLCKit on iOS; replacing/re-signing that
framework is permitted. Full project sources and dependency versions are provided.
No license verification or device-binding restrictions are added by Yoru Anime.
