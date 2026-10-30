import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/embeds.dart';
import 'package:hobee/models.dart';
import 'package:hobee/player.dart';

void main() {
  test('redgifs ids', () {
    expect(Embeds.redgifsId('https://www.redgifs.com/watch/shrillwastefulstarfish'), 'shrillwastefulstarfish');
    expect(Embeds.redgifsId('https://redgifs.com/watch/ShrillWastefulStarfish?x=1'), 'shrillwastefulstarfish');
    expect(Embeds.redgifsId('https://v3.redgifs.com/watch/abcdef'), 'abcdef');
    expect(Embeds.redgifsId('https://www.redgifs.com/ifr/abcdef'), 'abcdef');
    expect(Embeds.redgifsId('https://i.redgifs.com/i/abcdef.jpg'), 'abcdef');
    expect(Embeds.redgifsId('https://media.redgifs.com/AbcDef-mobile.mp4'), 'abcdef');
    expect(Embeds.redgifsId('https://imgur.com/abc'), null);
    expect(Embeds.redgifsId('https://www.redgifs.com/users/someone'), null);
    expect(Embeds.needsResolve('https://media.redgifs.com/AbcDef.mp4'), false);
    expect(Embeds.needsResolve('https://redgifs.com/watch/abcdef'), true);
  });
  test('streamable and v.redd.it', () {
    expect(Embeds.streamableId('https://streamable.com/moo'), 'moo');
    expect(Embeds.streamableId('https://streamable.com/e/moo'), 'moo');
    expect(Embeds.redditHls('https://v.redd.it/abc123/DASH_720.mp4?source=fallback'), 'https://v.redd.it/abc123/HLSPlaylist.m3u8');
    expect(Embeds.redditHls('https://i.redd.it/x.jpg'), null);
  });
  test('posts map to playable video items', () {
    final rg = parseMedia({'url': 'https://redgifs.com/watch/abcdef', 'thumbnail': 'https://t/x.jpg',
      'preview': {'reddit_video_preview': {'fallback_url': 'https://v.redd.it/zz/DASH_480.mp4'}}});
    expect(rg.single.type, MediaType.video);
    expect(rg.single.preview, 'https://v.redd.it/zz/DASH_480.mp4');
    final rv = parseMedia({'url': 'https://v.redd.it/abc', 'media': {'reddit_video': {'fallback_url': 'https://v.redd.it/abc/DASH_720.mp4'}}});
    expect(rv.single.hls, 'https://v.redd.it/abc/HLSPlaylist.m3u8');
    final gv = parseMedia({'url': 'https://i.imgur.com/abc.gifv'});
    expect(gv.single.url, 'https://i.imgur.com/abc.mp4');
  });
  test('time format', () {
    expect(fmtDur(const Duration(seconds: 65)), '1:05');
    expect(fmtDur(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });
}
