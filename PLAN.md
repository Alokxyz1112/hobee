# Hobee fork – change plan

Work through phases in order. Each phase ends with `flutter analyze` + `flutter test` passing and a release APK built by CI.
Rule: before editing code, summarize the planned change and wait for the owner's go-ahead.

## Phase 0 – Setup
- Fork `Alokxyz1112/hobee` to your own GitHub account (MIT license, keep the copyright notice).
- Add `CLAUDE.md` and this `PLAN.md` to the repo root.
- Add a GitHub Actions workflow (`.github/workflows/build.yml`): on push/PR, install Flutter (version from `README.md`), run `flutter analyze`, `flutter test`, `flutter build apk --release`, and upload the APK as a build artifact so it can be downloaded to the phone without a PC.

## Phase 1 – Aspect-ratio thumbnails (masonry grid)
Today: `lib/gallery.dart` uses `SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols)` with `BoxFit.cover` → square crops.
- `lib/models.dart`: add `width`/`height` (nullable) to `MediaItem`. Fill from `preview.images[0].source` for single posts and from `media_metadata[id].s.x / s.y` for galleries.
- Add `flutter_staggered_grid_view`; replace the `SliverGrid` with `SliverMasonryGrid.count` (3 columns). Each tile uses `AspectRatio(width/height)`, so space is reserved before the image loads (no jumping).
- Items without dimensions (some archive/Redlib/RSS rows): fall back to square, or update the ratio once the image decodes.
- Fix scroll anchoring: `anchoredOffset(...)` currently assumes a fixed tile height (`tile = width / _cols`). Make it work with variable heights or anchor by item key.
- Keep the square grid as a setting option ("Grid: Square / Original shape").
- Tests: update `long_scroll_test.dart` / `nav_preview_test.dart` as needed and add a test for dimension parsing.

## Phase 2 – Instant viewer (progressive loading)
Today: `PhotoFallback` (`lib/viewer.dart`) tries `[original, full, url, preview, thumb]` in order and shows a spinner until one loads.
- Show the Reddit preview (or the grid thumbnail, which is already cached) immediately.
- Load the original in the background and cross-fade it in when decoded. Keep the existing decode-size cap.
- Keep the fallback chain for failures: if the original fails, stay on the preview without an error.
- Prefetch originals for the next 1–2 items in the viewer with `precacheImage`.
- Downloads keep using the original (`MediaItem.full`, unchanged).
- Tests: update `viewer_fallback_test.dart`.

## Phase 3 – Video duplicate detection
Today (`lib/dedupe.dart`): videos collapse only via post ID / crosspost keys, plus a dHash of Reddit's single poster thumbnail. That thumbnail often differs between re-uploads. `exactKeys` (`_file` regex) only matches image hosts (`i.redd.it`, `i.imgur.com`, preview hosts), so video file IDs are never compared.
- **3a. Video file-ID keys (exact):** extend `exactKeys` with `v:` keys for:
  - `v.redd.it/<id>` (from `url`, `secure_media.reddit_video.fallback_url`, or the HLS/DASH base)
  - Imgur `.gifv` / `.mp4` IDs (normalized to the bare ID)
  - Redgifs IDs (from the URL / `media.oembed`)
  - Crosspost parents already handled; keep them.
- **3b. Duration + loose thumbnail match:** read the duration from `secure_media.reddit_video.duration` (or `media.reddit_video.duration`) and store it on `MediaItem` as nullable. Two single-video posts match when the durations are within ±1 s and the thumbnail dHash distance is ≤ ~12 (looser than the image threshold of 6). Only compare when both durations are known, so images aren't affected. Use a separate bucket `kind` for videos so they never match images.
- **3c (optional setting, off by default): multi-frame hashing.** Extract 3–4 frames (e.g. at 10/40/70/90 %) with a frame-extraction package, dHash each, and match when most frames agree. Cache in the SQLite `phash` table keyed by `url#t`. Run it only for videos in view or on demand, because it costs data and time.
- Tests: add to `resolve_dedupe_test.dart`:
  - same `v.redd.it` ID in different posts → collapsed
  - same duration with similar thumbnails → collapsed
  - same duration with different thumbnails → kept
  - video vs image → never collapsed

## Phase 4 – Import lists + "Following" feed (no login)
Goal: paste or import your subreddits/users and browse them as a combined feed, like a logged-in Home feed.
- **Import screen** (Settings → Import): paste text or pick a .txt/.csv file. The parser accepts, one or many per line, comma- or space-separated:
  - `r/name`, `/r/name`, `u/name`, `/u/name`, `/user/name`
  - full reddit / old.reddit URLs
  - multireddit links like `reddit.com/r/a+b+c`
  - `u_name` entries (how followed users appear in old.reddit.com/subreddits/mine). Usernames may contain `-` (subreddit names can't), so allow it after `u_`.
  - Trailing `/` and query strings on URLs are ignored. A single multireddit URL can hold 300+ names; split it into batches for fetching.
  - CSV with a `subreddit` column (e.g. `subscribed_subreddits.csv` from Reddit's data export)
  - Show a preview of what was found (counts plus a list) before saving, and dedupe case-insensitively.
- **Storage**: new SQLite tables in `lib/db.dart`: `profiles(id INTEGER PRIMARY KEY, name TEXT UNIQUE, created INTEGER)` and `follows(profile INTEGER, kind TEXT, name TEXT, added INTEGER, PRIMARY KEY(profile,kind,name))`. Create a default profile on first run. Add a management screen to remove entries and to export the list back to text/CSV.
- **Feed profiles** (local, no Reddit login): named follow lists (e.g. "Main", "Art") you switch between.
  - Create, rename, delete profiles; switcher in the Following feed header.
  - Import, export and manage screens act on one profile at a time.
  - Each profile has its own feed cache key and scroll position.
- **No-login subreddit source** (new; `public_sources.dart` only covers users today):
  - Reddit RSS: `/r/a+b+c/new/.rss`, batching subs into groups of about 20–30 per request.
  - Redlib: `/r/a+b+c?sort=new` as fallback.
  - Both return reddit-JSON-shaped rows, like the existing user sources.
- **Following feed**: a new source key (e.g. `following`). Merges subreddit batches plus per-user pages, sorted by date, cached via `Db.savePosts`. Existing filters and `Dedupe.collapse` apply unchanged.
- **Must work without login** (Reddit login is unresolved): today the Home tab and normal subreddit/user pages show "Log in with Reddit" when logged out, and only Deep Search works.
  - Entry point in the Deep Search tab (e.g. a "Following" segment next to Accounts / Subreddits) showing the active profile's feed in the same masonry grid, plus on the logged-out Home screen.
  - Sources in order: Reddit RSS → Redlib → public archives (Arctic Shift, as Deep Search uses today) when the live sources are blocked or rate-limited. Show which sources are working, like the existing Deep Search status panel.
  - Opening a subreddit or user from the feed goes to its Deep Search view, not the login-only page.
- Respect rate limits: run requests one batch at a time, back off on 429, and reuse the existing user agent and retry handling.
- Tests: parser tests (all input formats), feed merge/paging tests, and profile isolation (importing into one profile doesn't touch others; deleting a profile removes only its follows).

## Phase 5 – App lock (off by default)
- `local_auth`: unlock with fingerprint/face, falling back to the device PIN/pattern/password. Optional app-only PIN, stored as a salted hash in `flutter_secure_storage`.
- Lock on app start and after a chosen time in the background (immediately / 1 min / 5 min).
- Optional "hide in recent apps": blank the app-switcher preview and block screenshots (`FLAG_SECURE`).
- Optional per-profile lock: chosen profiles need unlocking before switching to them.
- Keep screen on (built early, with the viewer fixes): Settings → Keep screen on (Off / While viewing / Everywhere) with an idle limit (`lib/screen_awake.dart`). With the lock on, the idle limit also locks the app, so a phone left awake doesn't stay open.
- No lockout: if biometrics are removed, fall back to device credential or app PIN; turning the lock off requires unlocking first.
- Tests: lock-timer logic, PIN hash/verify, settings flow.

## Phase 6 – In-app gallery with export to the phone's gallery
Today: `lib/download.dart` saves straight to public `Pictures/` / `Movies/` via MediaStore (`MainActivity.kt`), so downloads appear in Samsung Gallery immediately.
- **Save destination setting**: "Hobees gallery (private)" (new default) or "Phone gallery" (current behaviour).
- **Private storage**: files in app-private storage (`getApplicationDocumentsDirectory()/gallery/`), not visible to other apps or the Samsung Gallery. New SQLite table `saved(id INTEGER PRIMARY KEY, path TEXT, kind TEXT, width INTEGER, height INTEGER, duration REAL, post_id TEXT, subreddit TEXT, author TEXT, profile INTEGER, saved_at INTEGER)`. Keep the existing metadata cleaning (`clean.dart` / `clean_image.dart`) on save.
- **Gallery screen**: grid reusing the feed grid and viewer (Phase 1 masonry, Phase 2 viewer); sort by date saved, filter by subreddit/user/profile/type; multi-select; delete; open source post.
- **Export**: selected items → existing MediaStore save path, so they show up in Samsung Gallery; option "remove from Hobees after export". Also "Share" via the Android share sheet.
- **App lock**: the gallery is covered by the Phase 5 lock; optional "always require unlock for the gallery".
- **Risk – data loss**: private files are deleted when the app is uninstalled (or its data cleared). Show this in the setting, and add "Export all" plus a backup/restore as a single .zip file.
- Tests: `saved` table CRUD, save-destination switch, export calls the MediaStore path with the right name/mime, delete removes file and row.

## Phase 7 – WebView login (only if phases 1–6 aren't enough)
- `webview_flutter`: log in on Reddit's own page and show the real feed.
- Optional hybrid: read post data from the loaded page and show it in Hobee's grid.
- Fragile: breaks when Reddit changes its site. Keep the page-reading rules in one file, with fallback to the plain page.

## Already present (verify only)
- Image duplicate hiding: exact URL plus 64-bit dHash (`lib/dedupe.dart`) works. Confirm it runs on the Following feed. Video duplicates are handled in Phase 3.
