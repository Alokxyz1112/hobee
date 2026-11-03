import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hobee/clean_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('404 and disposed-stream errors are benign', () {
    expect(isBenignImageError(NetworkImageLoadException(statusCode: 404, uri: Uri.parse('https://i.redd.it/x.jpeg'))), isTrue);
    expect(isBenignImageError(StateError('Bad state: Stream has been disposed.')), isTrue);
    expect(isBenignImageError(NetworkImageLoadException(statusCode: 500, uri: Uri.parse('https://x'))), isFalse);
    expect(isBenignImageError(StateError('other')), isFalse);
  });

  test('completer does not setImage after all listeners left', () async {
    final done = Completer<ImageInfo>();
    final c = SafeImageCompleter()..start(done.future);
    final l = ImageStreamListener((_, _) {});
    c.addListener(l);
    c.removeListener(l); // tile scrolled away: stream disposed
    expect(c.abandoned, isTrue);
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    done.completeError(StateError('should be swallowed'));
    await Future<void>.delayed(Duration.zero);
    FlutterError.onError = old;
    expect(errors, isEmpty);
  });

  test('404 is reported silently to the listener', () async {
    CleanNetworkImage.fetcher = (u, {headers}) async => http.Response('', 404);
    addTearDown(() => CleanNetworkImage.fetcher = null);
    final errs = <Object>[];
    final reported = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = reported.add;
    final stream = const CleanNetworkImage('https://i.redd.it/gone.jpeg', 512).resolve(ImageConfiguration.empty);
    final got = Completer<void>();
    stream.addListener(ImageStreamListener((_, _) {}, onError: (e, _) { errs.add(e); got.complete(); }));
    await got.future.timeout(const Duration(seconds: 5));
    FlutterError.onError = old;
    expect((errs.single as NetworkImageLoadException).statusCode, 404);
    expect(reported, isEmpty);
  });

  test('expired preview falls back to the i.redd.it original', () {
    expect(redditOriginalOf('https://preview.redd.it/kkjr9l4bizuh1.jpeg?width=320&crop=smart&s=x'), 'https://i.redd.it/kkjr9l4bizuh1.jpeg');
    expect(redditOriginalOf('https://preview.redd.it/my-title-v0-abc123.png?width=640'), 'https://i.redd.it/abc123.png');
    expect(redditOriginalOf('https://i.redd.it/abc.jpg'), isNull);
    expect(withRedditOriginals(['https://preview.redd.it/a.jpg?w=1', 'https://i.redd.it/a.jpg', 'x']),
        ['https://preview.redd.it/a.jpg?w=1', 'https://i.redd.it/a.jpg']);
  });

  test('404 on a preview tries the original before failing', () async {
    final asked = <String>[];
    CleanNetworkImage.fetcher = (u, {headers}) async { asked.add('$u'); return http.Response('', 404); };
    addTearDown(() => CleanNetworkImage.fetcher = null);
    final stream = const CleanNetworkImage('https://preview.redd.it/zz.jpeg?width=320', 512).resolve(ImageConfiguration.empty);
    final got = Completer<Object>();
    stream.addListener(ImageStreamListener((_, _) {}, onError: (e, _) => got.complete(e)));
    final e = await got.future.timeout(const Duration(seconds: 5));
    expect((e as NetworkImageLoadException).statusCode, 404);
    expect(asked, ['https://preview.redd.it/zz.jpeg?width=320', 'https://i.redd.it/zz.jpeg']);
  });
}
