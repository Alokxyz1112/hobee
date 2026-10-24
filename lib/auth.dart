import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const redirectUri = 'redditgallery://auth';
const scopes = 'identity read history save mysubreddits';

class Auth extends ChangeNotifier {
  static final Auth i = Auth._();
  Auth._();
  final _s = const FlutterSecureStorage();
  String? clientId, accessToken, refreshToken, username;
  DateTime expiry = DateTime.fromMillisecondsSinceEpoch(0);
  String? _state;
  StreamSubscription? _sub;
  String? lastError;

  bool get loggedIn => refreshToken != null;
  String get userAgent => 'android:com.alok.hobee:v1.0 (by /u/${username ?? 'unknown'})';

  Future<void> init() async {
    clientId = await _s.read(key: 'clientId');
    accessToken = await _s.read(key: 'access');
    refreshToken = await _s.read(key: 'refresh');
    username = await _s.read(key: 'username');
    expiry = DateTime.fromMillisecondsSinceEpoch(int.tryParse(await _s.read(key: 'expiry') ?? '0') ?? 0);
    _sub = AppLinks().uriLinkStream.listen(_onLink);
    notifyListeners();
  }

  Future<void> setClientId(String id) async {
    clientId = id.trim().isEmpty ? null : id.trim();
    if (clientId == null) {
      await _s.delete(key: 'clientId');
    } else {
      await _s.write(key: 'clientId', value: clientId);
    }
    notifyListeners();
  }

  Future<void> login() async {
    if (clientId == null) throw Exception('No client ID');
    _state = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
    final u = Uri.https('www.reddit.com', '/api/v1/authorize.compact', {
      'client_id': clientId!,
      'response_type': 'code',
      'state': _state!,
      'redirect_uri': redirectUri,
      'duration': 'permanent',
      'scope': scopes,
    });
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  Future<void> _onLink(Uri uri) async {
    if (uri.scheme != 'redditgallery' || uri.host != 'auth') return;
    final err = uri.queryParameters['error'];
    if (err != null) { lastError = 'Reddit returned: $err'; notifyListeners(); return; }
    if (_state != null && uri.queryParameters['state'] != _state) { lastError = 'State mismatch'; notifyListeners(); return; }
    final code = uri.queryParameters['code'];
    if (code == null) return;
    try {
      await _token({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirectUri});
      await _fetchMe();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    }
    notifyListeners();
  }

  Future<void> _token(Map<String, String> body) async {
    final r = await http.post(Uri.parse('https://www.reddit.com/api/v1/access_token'),
        headers: {
          'Authorization': 'Basic ${base64Encode(utf8.encode('$clientId:'))}',
          'User-Agent': userAgent,
        },
        body: body);
    final j = jsonDecode(r.body);
    if (r.statusCode != 200 || j['access_token'] == null) throw Exception('Token error ${r.statusCode}: ${r.body}');
    accessToken = j['access_token'];
    if (j['refresh_token'] != null) refreshToken = j['refresh_token'];
    expiry = DateTime.now().add(Duration(seconds: (j['expires_in'] ?? 3600) - 60));
    await _s.write(key: 'access', value: accessToken);
    await _s.write(key: 'refresh', value: refreshToken);
    await _s.write(key: 'expiry', value: '${expiry.millisecondsSinceEpoch}');
  }

  Future<void> _fetchMe() async {
    final r = await http.get(Uri.parse('https://oauth.reddit.com/api/v1/me'),
        headers: {'Authorization': 'bearer $accessToken', 'User-Agent': userAgent});
    if (r.statusCode == 200) {
      username = jsonDecode(r.body)['name'];
      await _s.write(key: 'username', value: username);
    }
  }

  Future<String> token({bool force = false}) async {
    if (refreshToken == null) throw Exception('Not logged in');
    if (force || accessToken == null || DateTime.now().isAfter(expiry)) {
      await _token({'grant_type': 'refresh_token', 'refresh_token': refreshToken!});
    }
    if (username == null) await _fetchMe();
    return accessToken!;
  }

  Future<void> logout() async {
    accessToken = refreshToken = username = null;
    for (final k in ['access', 'refresh', 'username', 'expiry']) {
      await _s.delete(key: k);
    }
    notifyListeners();
  }

  @override
  void dispose() { _sub?.cancel(); super.dispose(); }
}
