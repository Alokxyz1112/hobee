# Hobee (personal fork)

Flutter/Dart Android app: grid browser for Reddit users' and subreddits' media. The work plan is in `PLAN.md`; follow its phases in order.

## Working rules
- Before editing code, give a short summary of the planned change and wait for confirmation.
- Small, focused commits, one per logical step. Don't touch unrelated code.
- Keep the app working without Reddit login. Don't add tracking, analytics or ads.
- Don't use another app's Reddit client ID, and don't disguise requests to evade Reddit's detection.

## Commands
- `flutter pub get`
- `flutter analyze` (must be clean)
- `flutter test` (must pass; tests live in `test/`, SQLite via `sqflite_common_ffi`)
- `flutter build apk --release` (falls back to debug signing if no keystore)

## Code map (lib/)
- `models.dart`: `Post`, `MediaItem` (url = original, thumb, preview), `parseMedia`, `originalOf`
- `gallery.dart`: media grid (`SliverGrid`, `_cols = 3`, square tiles); `anchoredOffset` scroll anchoring
- `viewer.dart`: full-screen viewer; `PhotoFallback` tries URLs in order
- `feed.dart`: feed screen; `api.dart`: OAuth API (`oauth.reddit.com`, needs login), `pathFor`, `fetchMore`
- `auth.dart`: OAuth login with user-supplied client ID
- `public_sources.dart`: no-login sources (Reddit RSS, Redlib) – **users only** today
- `deep_search.dart`, `archive.dart`, `archive_ui.dart`: Deep Search (Arctic Shift / PullPush, Live/Archive/Removed)
- `dedupe.dart`: duplicate collapse (exact URL + dHash, cached in SQLite `phash`)
- `db.dart`: SQLite schema and cache (`posts`, `cursors`, …)
- `filters.dart`: view filters, `effectiveSource()`; `settings.dart`: settings screen
