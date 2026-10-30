import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'embeds.dart';

/// Settings → 'Original quality': viewer and downloads use the original upload instead of Reddit's resized preview.
final originalQuality = ValueNotifier<bool>(true);

enum MediaType { image, gif, video }

class MediaItem {
  final MediaType type;
  final String url; // full image / mp4 / fallback video url
  final String thumb;
  final String? hls; // HLS playlist (video+audio) for reddit videos
  final bool redditVideo;
  /// Resized/recompressed Reddit preview of the same media (fallback when the original fails, or when 'Original quality' is off).
  final String? preview;
  MediaItem(this.type, this.url, this.thumb, {this.hls, this.redditVideo = false, this.preview});

  /// URL the viewer and downloads should use.
  String get full => originalQuality.value || preview == null || preview!.isEmpty ? url : preview!;
}

/// Image item that prefers the original upload; [src] is whatever URL we have (possibly a preview).
MediaItem imageItem(String src, String thumb, {MediaType type = MediaType.image}) {
  final o = originalOf(src);
  return MediaItem(type, o, thumb.isEmpty ? src : thumb, preview: o == src ? null : src);
}

const _imgurSuffix = 'sbtmlhrg';

/// Maps a resized preview/thumbnail URL to the original upload when the id is derivable, like gallery-dl / bdfr do:
/// preview.redd.it/ID.ID?width=..&auto=webp&s=.. → i.redd.it/ID.ID;
/// i.imgur.com/IDID.ID → i.imgur.com/ID.ID. Anything else is returned unchanged.
String originalOf(String url) {
  final u = unesc(url);
  final m = RegExp(r'^https?://preview\.redd\.it/([a-z0-9]{10,16})\.(jpe?g|png|gif|webp)(?:\?|$)').firstMatch(u);
  if (m != null) return 'https://i.redd.it/${m.group(1)}.${m.group(2)}';
  final im = RegExp(r'^https?://i\.imgur\.com/([A-Za-z0-9]+)\.(jpe?g|png|webp)(?:\?.*)?$').firstMatch(u);
  if (im != null) {
    final id = im.group(1)!;
    if ((id.length == 6 || id.length == 8) && _imgurSuffix.contains(id[id.length - 1])) {
      return 'https://i.imgur.com/${id.substring(0, id.length - 1)}.${im.group(2)}';
    }
  }
  return u;
}

/// i.redd.it original for a gallery media id from media_metadata (m = mimetype like image/png).
String? galleryOriginal(String mediaId, Map meta) {
  final mt = '${meta['m'] ?? ''}';
  final ext = switch (mt.split('/').last) { 'jpeg' || 'jpg' => 'jpg', 'png' => 'png', 'gif' => 'gif', 'webp' => 'webp', _ => '' };
  if (ext.isEmpty || !RegExp(r'^[a-z0-9]{8,20}$').hasMatch(mediaId)) return null;
  return 'https://i.redd.it/$mediaId.$ext';
}

String unesc(String s) => s.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');

class Post {
  final String id, title, subreddit, author, permalink;
  final int created; // epoch seconds
  final List<MediaItem> media;
  final Map<String, dynamic> raw;
  Post(this.id, this.title, this.subreddit, this.author, this.permalink, this.created, this.media, this.raw);

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(created * 1000);

  static Post? fromJson(Map<String, dynamic> d) {
    if (d['title'] == null) return null; // comments etc.
    if (d['over_18'] == true) return null; // adult posts are never shown in this build
    final media = parseMedia(d);
    return Post(d['id'] ?? d['name'], unesc(d['title'] ?? ''), d['subreddit'] ?? '', d['author'] ?? '',
        d['permalink'] ?? '', ((d['created_utc'] ?? 0) as num).toInt(), media, d);
  }

  String encode() => jsonEncode(raw);
}

String _thumb(Map d) {
  try {
    final img = d['preview']['images'][0];
    final res = (img['resolutions'] as List);
    if (res.isNotEmpty) {
      final r = res.firstWhere((r) => (r['width'] ?? 0) >= 320, orElse: () => res.last);
      return unesc(r['url']);
    }
    return unesc(img['source']['url']);
  } catch (_) {}
  final t = d['thumbnail'];
  if (t is String && t.startsWith('http')) return unesc(t);
  return '';
}

List<MediaItem> parseMedia(Map<String, dynamic> d0) {
  Map<String, dynamic> d = d0;
  final cp = d0['crosspost_parent_list'];
  if (cp is List && cp.isNotEmpty) d = Map<String, dynamic>.from(cp.first);
  final out = <MediaItem>[];
  final thumb = _thumb(d);

  // Gallery
  if (d['is_gallery'] == true && d['media_metadata'] is Map) {
    final meta = d['media_metadata'] as Map;
    final items = (d['gallery_data']?['items'] as List?) ?? meta.keys.map((k) => {'media_id': k}).toList();
    for (final it in items) {
      final m = meta[it['media_id']];
      if (m == null || m['status'] != 'valid') continue;
      final s = m['s'] ?? {};
      final p = (m['p'] as List?) ?? [];
      String th = p.isNotEmpty ? unesc((p.length > 2 ? p[2] : p.last)['u'] ?? '') : '';
      if (m['e'] == 'AnimatedImage') {
        if (s['mp4'] != null) {
          out.add(MediaItem(MediaType.video, unesc(s['mp4']), th.isEmpty ? unesc(s['gif'] ?? '') : th));
        } else if (s['gif'] != null) {
          out.add(MediaItem(MediaType.gif, unesc(s['gif']), th.isEmpty ? unesc(s['gif']) : th));
        }
      } else if (s['u'] != null) {
        final u = unesc(s['u']);
        final o = galleryOriginal('${it['media_id']}', m) ?? originalOf(u);
        out.add(MediaItem(MediaType.image, o, th.isEmpty ? u : th, preview: o == u ? null : u));
      }
    }
    if (out.isNotEmpty) return out;
  }
  // Gallery whose archived copy lacks media_metadata: fall back to preview/thumbnail below.
  final galleryNoMeta = d['is_gallery'] == true;

  // Reddit hosted video
  final rv = d['secure_media']?['reddit_video'] ?? d['media']?['reddit_video'];
  if (rv != null) {
    final fb = unesc(rv['fallback_url'] ?? '');
    out.add(MediaItem(MediaType.video, fb, thumb,
        hls: rv['hls_url'] != null ? unesc(rv['hls_url']) : Embeds.redditHls(fb), redditVideo: true));
    return out;
  }

  final url = unesc((d['url_overridden_by_dest'] ?? d['url'] ?? '') as String);
  final lower = url.toLowerCase().split('?').first;

  // v.redd.it link whose archived copy was captured before reddit_video metadata existed.
  final vm = RegExp(r'^https?://v\.redd\.it/([A-Za-z0-9]+)').firstMatch(url);
  if (vm != null) {
    final base = 'https://v.redd.it/${vm.group(1)}';
    out.add(MediaItem(MediaType.video, '$base/DASH_720.mp4', thumb, hls: '$base/HLSPlaylist.m3u8', redditVideo: true));
    return out;
  }

  // RedGIFs / Streamable: resolved to an mp4 when played or saved. Reddit's own preview clip is the backup.
  if (Embeds.redgifsId(url) != null || Embeds.streamableId(url) != null) {
    final oe = (d['secure_media'] ?? d['media'])?['oembed'];
    var th = thumb;
    if (th.isEmpty && oe is Map && oe['thumbnail_url'] is String) th = unesc(oe['thumbnail_url']);
    final rvp = d['preview']?['reddit_video_preview'];
    final backup = rvp is Map && rvp['fallback_url'] != null ? unesc(rvp['fallback_url']) : null;
    out.add(MediaItem(MediaType.video, url, th, preview: backup));
    return out;
  }

  // imgur
  if (url.contains('imgur.com')) {
    if (lower.endsWith('.gifv') || lower.endsWith('.mp4')) {
      final mp4 = url.replaceAll(RegExp(r'\.gifv$|\.gifv\?'), '.mp4');
      out.add(MediaItem(MediaType.video, mp4, thumb));
      return out;
    }
    if (lower.endsWith('.gif')) {
      // Imgur serves the same animation as a much smaller/better mp4.
      out.add(MediaItem(MediaType.video, url.replaceAll(RegExp(r'\.gif(\?.*)?$', caseSensitive: false), '.mp4'), thumb.isEmpty ? url : thumb));
      return out;
    }
    if (RegExp(r'\.(jpe?g|png|webp)$').hasMatch(lower)) {
      out.add(imageItem(url, thumb));
      return out;
    }
    final m = RegExp(r'imgur\.com/([A-Za-z0-9]{5,8})$').firstMatch(lower);
    if (m != null) {
      final u = 'https://i.imgur.com/${m.group(1)}.jpg';
      out.add(MediaItem(MediaType.image, u, thumb.isEmpty ? u : thumb));
      return out;
    }
  }

  // GIF with reddit mp4 preview
  final rvp = d['preview']?['reddit_video_preview'];
  if (lower.endsWith('.gif') || rvp != null) {
    if (rvp != null && rvp['fallback_url'] != null) {
      out.add(MediaItem(MediaType.video, unesc(rvp['fallback_url']), thumb,
          hls: rvp['hls_url'] != null ? unesc(rvp['hls_url']) : Embeds.redditHls(unesc(rvp['fallback_url']))));
    } else {
      out.add(MediaItem(MediaType.gif, url, thumb.isEmpty ? url : thumb));
    }
    return out;
  }

  if (RegExp(r'\.(jpe?g|png|webp)$').hasMatch(lower) || url.contains('i.redd.it') || d['post_hint'] == 'image') {
    String full = url;
    if (!RegExp(r'\.(jpe?g|png|webp)$').hasMatch(lower)) {
      try { full = unesc(d['preview']['images'][0]['source']['url']); } catch (_) {}
    }
    String? pv;
    try { pv = unesc(d['preview']['images'][0]['source']['url']); } catch (_) {}
    final o = originalOf(full);
    out.add(MediaItem(MediaType.image, o, thumb.isEmpty ? full : thumb, preview: o != full ? full : (pv != null && pv != o ? pv : null)));
    return out;
  }

  // Other image hosts with a direct file URL.
  if (RegExp(r'^https?://').hasMatch(url) && RegExp(r'\.(jpe?g|png|webp)$').hasMatch(lower)) {
    out.add(MediaItem(MediaType.image, url, thumb.isEmpty ? url : thumb));
    return out;
  }

  // Embedded GIF/clip hosts (redgifs, gfycat, imgur albums): show the oEmbed thumbnail.
  final oe = (d['secure_media'] ?? d['media'])?['oembed'];
  final host = '${(d['secure_media'] ?? d['media'])?['type'] ?? ''}$url';
  if (oe is Map && oe['thumbnail_url'] is String && RegExp(r'redgifs|gfycat|imgur').hasMatch(host)) {
    final t = unesc(oe['thumbnail_url']);
    out.add(MediaItem(MediaType.image, t, thumb.isEmpty ? t : thumb));
    return out;
  }

  // Last resort for picture posts: preview source, then the small thumbnail field.
  if (galleryNoMeta || d['post_hint'] == 'image' || url.contains('imgur.com')) {
    String full = '';
    try { full = unesc(d['preview']['images'][0]['source']['url']); } catch (_) {}
    if (full.isEmpty) full = thumb;
    if (full.isNotEmpty) out.add(imageItem(full, thumb));
  }
  return out;
}
