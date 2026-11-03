import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/archive_ui.dart';
import 'package:hobee/public_sources.dart';

void main() {
  test('zero posts is not a green success when others have posts', () {
    const r = ProviderStatus(null, count: 0, name: 'Redlib');
    expect(sourceLine(r, true), contains('returned nothing'));
    expect(sourceLine(r, false), 'Redlib: no posts found');
  });
  test('friendly errors and summary', () {
    const a = ProviderStatus(null, count: 8, name: 'Arctic Shift');
    const j = ProviderStatus(null, error: 'unavailable (HTTP 403)', name: 'Reddit JSON');
    const s = ProviderStatus(null, error: 'rate-limited (HTTP 429)', name: 'Reddit RSS');
    expect(sourceLine(a, true), 'Arctic Shift: 8 posts in the last batch');
    expect(sourceLine(j, true), 'Reddit JSON: blocked from this network');
    expect(sourceLine(s, true), 'Reddit RSS: busy right now, will work later');
    expect(sourcesSummary([a, j, s, const ProviderStatus(null, count: 0, name: 'R')], true), 'Sources: 1 working, 1 empty, 2 unavailable');
  });
  test('redlib bot check pages are detected, real listings are not', () {
    expect(Redlib.isChallenge('<title>Making sure you&#39;re not a bot!</title>'), isTrue);
    expect(Redlib.isChallenge('<div id="posts"><div class="post" id="abc">'), isFalse);
  });
  test('Retry-After parsing', () {
    expect(RedditRss.retryAfter('7'), 7);
    expect(RedditRss.retryAfter(null), 5);
    expect(RedditRss.retryAfter('600'), 30);
  });
}
