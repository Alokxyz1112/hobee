<p align="center"><img src="assets/icon/logo.png" width="128" alt="Hobee logo"></p>

# Hobee

An ad-free Reddit gallery app for Android, built with Flutter.

## Features

- Year / month gallery view of any subreddit
- Filters: images, videos, galleries, text posts
- Sort by Best, Hot, New, Rising, Top, Controversial
- Search posts by date
- Layouts: Card, Slides, Compact, Gallery
- Deep Search: merges live posts, Reddit RSS, Redlib and the Arctic Shift archive, with **Live / Removed / Archive** labels
- Duplicate-photo filter (dHash)
- Download original-quality images, and videos with sound
- Frosted glass UI

## Screenshots

Coming soon.

## Install

Download the latest APK from the [Releases](../../releases) page and open it on your Android phone.

## Build from source

```bash
flutter pub get
flutter build apk --split-per-abi
```

Release signing is optional: put a `keystore/key.properties` file (with `storeFile`, `storePassword`, `keyAlias`, `keyPassword`) in the project root. Without it, the build uses debug keys.

## Credits

- [gallery-dl](https://github.com/mikf/gallery-dl)
- [Bulk Downloader for Reddit](https://github.com/aliparlakci/bulk-downloader-for-reddit)
- [Redlib](https://github.com/redlib-org/redlib)
- [Arctic Shift](https://github.com/ArthurHeitmann/arctic_shift)

## Disclaimer

This is a personal, non-commercial project. It is not affiliated with or endorsed by Reddit. It respects Reddit's API terms.

## License

[MIT](LICENSE)
