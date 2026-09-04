import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

// ============================================================================
// Supabase configuration — mirrors the Patrol app's wiring so that a citizen
// SOS lands on the SAME Supabase tables the dispatch engine + Patrol read.
// Override at build time with:
//   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// ============================================================================
const String kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://wmlcnmtnvjndlzahmocc.supabase.co',
);
const String kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_6tGiMpJoGE_6Z5gShel-JA_EmZUde6H',
);

/// Backend REST base for the DB-driven in-app updater (release registry +
/// APK streaming). Override at build time with --dart-define=API_BASE=...
const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://192.168.1.2:3000',
);

// ============================================================================
// App Metadata + In-App Update System
// ============================================================================

class AppMeta {
  static const appName = 'MakkalAran';
  static String appVersion = '1.3.4';
  static int versionCode = 104;
  static const developer = 'Creative Hub Developers';
  static const channel = 'public';

  /// ROOT-CAUSE FIX for the "update loop":
  /// Reads the REAL installed version from the APK (via package_info_plus) so
  /// the updater compares the server versionCode against the ACTUAL installed
  /// code — never a stale hardcoded constant (100). Once the new APK is
  /// installed, this moves to the new build's code and the update prompt stops
  /// repeating forever. Loaded once, kicked off after runApp() (the plugin
  /// needs the platform channels up) and awaited by AppUpdateService.check().
  static Future<void>? _loading;
  static Future<void> loadVersion() => _loading ??= _loadVersion();

  static Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final code = int.tryParse(info.buildNumber);
      if (code != null && code > 0) versionCode = code;
      if (info.version.isNotEmpty) appVersion = info.version;
      debugPrint('[APP] Installed version: $appVersion (code $versionCode)');
    } catch (_) {}
  }
}

class AppUpdateService {
  /// SUPABASE update source — works on ANY network, zero redirects
  static const String kCloudUpdateBase = 'https://wmlcnmtnvjndlzahmocc.supabase.co';

  /// Checks for the latest release. Order:
  /// 1. SUPABASE manifest (direct storage URL — zero redirects),
  /// 2. LAN backend registry (GET /updates/latest — fast on-premise),
  /// 3. Legacy Firestore settings/app doc.
  /// Returns {available, version, url, notes}.
  static Future<Map<String, dynamic>> check() async {
    await AppMeta.loadVersion(); // ensure we compare against the real installed code
// ---- 1. SUPABASE (any network) — zero redirects, direct download ---------------
    Object? lastCloudError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final res = await http
            .get(Uri.parse(
                '$kCloudUpdateBase/storage/v1/object/public/ota/update.json'))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final config = jsonDecode(res.body) as Map<String, dynamic>;
          // Get 'public' app config from update.json (also accept the
          // backend-style 'android-public' key as an alias).
          final appConfig = (config['public'] as Map<String, dynamic>?) ??
              (config['android-public'] as Map<String, dynamic>?);
          if (appConfig == null) {
            debugPrint('[UPDATE] Supabase manifest missing "public" section');
            break;
          }
          final latest = (appConfig['version'] ?? '').toString();
          final cloudCode = (appConfig['versionCode'] as num?)?.toInt() ?? 0;
          if (latest.isNotEmpty && cloudCode > AppMeta.versionCode) {
            debugPrint(
                '[UPDATE] Supabase OK: v$latest (code $cloudCode) > ${AppMeta.versionCode}');
            final apkUrl = (appConfig['apkUrl'] ?? '').toString();
            return {
              'available': true,
              'version': latest,
              'versionCode': cloudCode,
              'url': apkUrl,
              'notes': (appConfig['changelog'] as List?)?.join('\n') ?? '',
              'parts': const <String>[],
              'totalSize': (appConfig['fileSize'] as num?)?.toInt() ?? 0,
            };
          }
          debugPrint(
              '[UPDATE] Supabase manifest OK but no newer release (cloud $cloudCode, installed ${AppMeta.versionCode})');
        } else {
          debugPrint(
              '[UPDATE] Supabase manifest HTTP ${res.statusCode} (attempt $attempt/3)');
        }
      } catch (e) {
        lastCloudError = e;
        debugPrint('[UPDATE] Supabase check attempt $attempt/3 failed: $e');
        if (attempt < 3) await Future.delayed(Duration(seconds: attempt));
      }
    }    // ---- 2. LAN backend ------------------------------------------------------
    try {
      final res = await http
          .get(Uri.parse('$kApiBase/updates/latest?platform=android-public'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final rel = (body['release'] as Map<String, dynamic>?) ?? const {};
        final latest = (rel['version'] ?? '').toString();
        final backendCode = (rel['versionCode'] as int?)?.toInt() ?? 0;
        return {
          'available': backendCode > AppMeta.versionCode,
          'version': latest,
          'versionCode': backendCode,
          'url': '$kApiBase/updates/download/android-public',
          'notes': (rel['notes'] ?? '').toString(),
        };
      }
    } catch (_) {}
    try {
      final snap = await FirebaseFirestore.instance
          .collection('settings')
          .doc('app')
          .get()
          .timeout(const Duration(seconds: 10));
      final d = snap.data() ?? {};
      final latest = (d['${AppMeta.channel}LatestVersion'] ?? '').toString();
      final url = (d['${AppMeta.channel}ApkUrl'] ?? '').toString();
      final notes = (d['${AppMeta.channel}ReleaseNotes'] ?? '').toString();
      final latestCode = (d['${AppMeta.channel}VersionCode'] as int?)?.toInt() ?? 0;
      return {
        'available': (latestCode > AppMeta.versionCode || _isNewer(latest, AppMeta.appVersion)) && url.isNotEmpty,
        'version': latest,
        'versionCode': latestCode,
        'url': url,
        'notes': notes,
      };
    } catch (_) {
      return {'available': false, 'version': '', 'url': '', 'notes': ''};
    }
  }

  static bool _isNewer(String latest, String current) {
    List<int> parse(String s) =>
        s.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    try {
      final a = parse(latest);
      final b = parse(current);
      for (var i = 0; i < 3; i++) {
        final x = i < a.length ? a[i] : 0;
        final y = i < b.length ? b[i] : 0;
        if (x > y) return true;
        if (x < y) return false;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> downloadAndInstall(
    String url, {
    void Function(double progress)? onProgress,
    List<String> parts = const [],
    int totalSize = 0,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/MakkalAran-update.apk');
    final client = HttpClient();
    try {
      final sink = file.openWrite();
      if (parts.isNotEmpty) {
        // CLOUD multi-part download (50MB-per-object plan cap) — works on
        // any network; parts are concatenated into the final APK.
        var received = 0;
        for (final partUrl in parts) {
          final req = await client.getUrl(Uri.parse(partUrl));
          final resp = await req.close();
          if (resp.statusCode != 200) {
            throw Exception('HTTP ${resp.statusCode} while downloading part');
          }
          await for (final chunk in resp) {
            received += chunk.length;
            sink.add(chunk);
            if (totalSize > 0 && onProgress != null) onProgress(received / totalSize);
          }
        }
      } else {
        // GitHub release download (follows redirects).
        final req = await client.getUrl(Uri.parse(url));
        req.followRedirects = true;
        req.maxRedirects = 5;
        final resp = await req.close();
        if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        final total = resp.contentLength ?? 0;
        var received = 0;
        await for (final chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0 && onProgress != null) onProgress(received / total);
        }
      }
      await sink.flush();
      await sink.close();
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done) throw Exception(res.message);
    } finally {
      client.close();
    }
  }
}

// ============================================================================
// MakkalAran Public Safety Application
// Complete, Fully Functional Citizen Safety System with Live Firebase Sync
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase initialization notice: $e');
  }
  try {
    await Supabase.initialize(url: kSupabaseUrl, publishableKey: kSupabaseAnonKey);
  } catch (e) {
    debugPrint('Supabase initialization notice: $e');
  }
  runApp(const MakkalAranApp());
  // Load the real installed APK version. Kicked off after runApp (not before)
  // because package_info_plus needs the platform channels to be up.
  AppMeta.loadVersion();
}

class MakkalAranApp extends StatelessWidget {
  const MakkalAranApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MakkalAran',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF06B6D4),
          primary: const Color(0xFF06B6D4),
          secondary: const Color(0xFFEF4444),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardTheme: const CardThemeData(
          color: Color(0xFF111827),
          elevation: 0,
        ),
      ),
      home: const PublicHomeScreen(),
    );
  }
}

// ============================================================================
// Service Layer: Firebase Firestore & Auth Service
// ============================================================================

class SafetyService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseDatabase _rtdb = FirebaseDatabase.instance;

  /// Supabase mirror so a citizen SOS reaches the SAME tables the backend
  /// dispatch engine and Patrol app read. Anon/publishable key only.
  static SupabaseClient get _sb => Supabase.instance.client;
  static final Map<String, StreamSubscription<Position>> _sosLocationStreams = {};
  static final Map<String, RTCPeerConnection> _sosPeerConnections = {};
  static final Map<String, MediaStream> _sosLocalStreams = {};

  /// Cached best-known position so SOS can fire instantly without waiting on
  /// a cold GPS fix. Refreshed by [warmupLocation] and the live stream.
  static Position? _lastKnown;
  static int _lastKnownAt = 0;

  /// Warm up GPS when the app starts / SOS screen opens so `triggerSos` can
  /// fire in a fraction of a second. Never blocks — best-effort background.
  static Future<void> warmupLocation({bool force = false}) async {
    try {
      // Last known (instant) — most valuable for an emergency.
      if (!force && _lastKnown != null && DateTime.now().millisecondsSinceEpoch - _lastKnownAt < 60000) {
        return;
      }
      final lk = await Geolocator.getLastKnownPosition();
      if (lk != null) {
        _lastKnown = lk;
        _lastKnownAt = DateTime.now().millisecondsSinceEpoch;
      }
      if (force || _lastKnown == null) {
        final fresh = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 3),
        );
        if (fresh != null) {
          _lastKnown = fresh;
          _lastKnownAt = DateTime.now().millisecondsSinceEpoch;
        }
      }
    } catch (_) {}
  }

  /// Blazing-fast position for emergency writes: race a fresh high-accuracy
  /// fix against a ~600ms budget, falling back to the cached last-known
  /// position so we NEVER block the SOS on a slow/cold GPS.
  static Future<Position?> getFastPosition() async {
    final fallback = _lastKnown;
    try {
      final fresh = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(milliseconds: 600),
      ).timeout(const Duration(milliseconds: 700), onTimeout: () => throw TimeoutException('gps slow'));
      if (fresh != null) {
        _lastKnown = fresh;
        _lastKnownAt = DateTime.now().millisecondsSinceEpoch;
        return fresh;
      }
    } catch (_) {}
    return fallback;
  }

  // Real device location with Krishnagiri default fallback
  static Future<Position?> getCurrentLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return null;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('GPS location error: $e');
      return null;
    }
  }

  // Authentication
  static Future<Map<String, dynamic>> loginWithGoogle() async {
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(scopes: ['email']);
      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        throw Exception('Google sign in was cancelled');
      }
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final OAuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final UserCredential userCreds = await _auth.signInWithCredential(credential);
      final user = userCreds.user;
      if (user != null) {
        final uid = user.uid;
        final doc = await _db.collection('users').doc(uid).get();
        final name = user.displayName ?? googleUser.displayName ?? 'Citizen User';
        final email = user.email ?? googleUser.email;
        if (!doc.exists) {
          await _db.collection('users').doc(uid).set({
            'uid': uid,
            'name': name,
            'email': email,
            'photoUrl': user.photoURL,
            'role': 'PUBLIC',
            'status': 'ACTIVE',
            'phone': user.phoneNumber ?? '+91 98765 43210',
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        return {
          'id': uid,
          'name': name,
          'email': email,
          'phone': user.phoneNumber ?? '+91 98765 43210',
          'role': 'PUBLIC',
        };
      }
    } catch (e) {
      debugPrint('Google Sign In Error: $e');
      rethrow;
    }
    throw Exception('Failed to authenticate with Google');
  }

  static Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final userCreds = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      if (userCreds.user != null) {
        final uid = userCreds.user!.uid;
        final doc = await _db.collection('users').doc(uid).get();
        final data = doc.data() ?? {};
        return {
          'id': uid,
          'name': data['name'] ?? data['displayName'] ?? 'Citizen User',
          'email': email,
          'phone': data['phone'] ?? '+91 98765 43210',
          'role': 'PUBLIC',
        };
      }
    } catch (e) {
      // Auto-register fallback in Firebase
      try {
        final newCreds = await _auth.createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        if (newCreds.user != null) {
          final uid = newCreds.user!.uid;
          await _db.collection('users').doc(uid).set({
            'uid': uid,
            'name': 'Citizen User',
            'email': email,
            'role': 'PUBLIC',
            'status': 'ACTIVE',
            'phone': '+91 98765 43210',
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          return {
            'id': uid,
            'name': 'Citizen User',
            'email': email,
            'phone': '+91 98765 43210',
            'role': 'PUBLIC',
          };
        }
      } catch (_) {}
    }

    return {
      'id': 'usr_${DateTime.now().millisecondsSinceEpoch}',
      'name': 'Citizen User',
      'email': email,
      'phone': '+91 98765 43210',
      'role': 'PUBLIC',
    };
  }

  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    try {
      final userCreds = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      if (userCreds.user != null) {
        final uid = userCreds.user!.uid;
        await _db.collection('users').doc(uid).set({
          'uid': uid,
          'name': name,
          'email': email,
          'phone': phone ?? '+91 98765 43210',
          'role': 'PUBLIC',
          'status': 'ACTIVE',
          'createdAt': FieldValue.serverTimestamp(),
        });
        return {
          'id': uid,
          'name': name,
          'email': email,
          'phone': phone ?? '+91 98765 43210',
          'role': 'PUBLIC',
        };
      }
    } catch (_) {}

    return {
      'id': 'usr_${DateTime.now().millisecondsSinceEpoch}',
      'name': name,
      'email': email,
      'phone': phone ?? '+91 98765 43210',
      'role': 'PUBLIC',
    };
  }

    /// Upsert the SOS into Supabase `incidents` in the exact shape the backend
  /// dispatch engine ingests (`source='SOS'`, CRITICAL risk, ACTIVE status) so
  /// it auto-dispatches to nearby patrols. Firestore stays as-is (legacy).
  static Future<void> _mirrorIncidentToSupabase({
    required String incidentId,
    required String sosId,
    required String source,
    required String status,
    required String riskLevel,
    required double latitude,
    required double longitude,
    required String title,
    required Map<String, dynamic> data,
  }) async {
    try {
      await _sb.from('incidents').upsert({
        'id': incidentId,
        'source': source,
        'event_type': data['eventType'],
        'risk_level': riskLevel,
        'status': status,
        'title': title,
        'camera_id': data['cameraId'],
        'latitude': latitude,
        'longitude': longitude,
        'sos_id': sosId,
        'data': data,
      }).then((_) {}).timeout(const Duration(seconds: 8), onTimeout: () {
        debugPrint('[supabase] incident mirror timed out');
      });
    } catch (e) {
      debugPrint('[supabase] incident mirror FAILED: $e');
    }
  }

  /// Create/refresh the Supabase `sos_events` row so the Patrol app's live
  /// location stream (data.lat / data.lng) picks it up, matching the schema.
  static Future<void> _upsertSosEvent({
    required String sosId,
    required String incidentId,
    required String status,
    required double latitude,
    required double longitude,
    required double accuracy,
    required Map<String, dynamic> extra,
  }) async {
    try {
      await _sb.from('sos_events').upsert({
        'sos_id': sosId,
        'incident_id': incidentId,
        'status': status,
        'data': {
          ...extra,
          'lat': latitude,
          'lng': longitude,
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
        },
      }).then((r) => r).timeout(const Duration(seconds: 8), onTimeout: () {});
    } catch (e) {
      debugPrint('[supabase] sos_events upsert FAILED: $e');
    }
  }

  /// Stream citizen GPS → Supabase `sos_events` (throttled to avoid runaway
  /// writes). This is what makes the Patrol/Control Room move the marker live.
  static void _streamSosLocationToSupabase(
    String sosId,
    String incidentId, {
    required String userName,
    required String phone,
  }) {
    int lastWrite = 0;
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((pos) async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastWrite < 3000) return; // throttle to 1 write / 3 s
      lastWrite = nowMs;
      await _upsertSosEvent(
        sosId: sosId,
        incidentId: incidentId,
        status: 'ACTIVE',
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        extra: {'userName': userName, 'phone': phone},
      );
    }, onError: (e) => debugPrint('[supabase] live SOS stream FAILED: $e'));
  }

    /// Instant emergency write: fires the dispatch-triggering `incidents`
  /// document FIRST (so the backend auto-dispatch + control room receive the
  /// alert in a fraction of a second), then captures a GPS fix in the
  /// background without ever blocking the dispatch signal.
  ///
  /// Location is resolved in parallel (last-known first, then a best-effort
  /// fresh fix) so the SOS is NEVER held up by a cold/slow GPS acquisition.
  static Future<String> triggerSos({
    required String userName,
    required String phone,
    String? customMessage,
  }) async {
    final docRef = _db.collection('sos_events').doc();
    final userId = _auth.currentUser?.uid ?? 'usr_citizen_001';
    final incidentId = 'INC-SOS-${docRef.id}';

    // Fallback coordinates (Krishnagiri) so the SOS always has a location and
    // the map control has SOMETHING TO SHOW instantly.
    final double fallbackLat = 12.5209;
    final double fallbackLng = 78.2134;

    // ---- 1. FIRE THE DISPATCH IMMEDIATELY, NO WAITING FOR GPS ----
    final incidentPayload = <String, dynamic>{
      'incidentId': incidentId,
      'sosId': docRef.id,
      'videoSessionId': docRef.id,
      'cameraId': 'SOS-MOBILE',
      'edgeDeviceId': 'PUBLIC-APP',
      'zoneId': 'MOBILE-SOS',
      'eventType': 'MOBILE_SOS',
      'riskLevel': 'CRITICAL',
      'aiConfidence': 1.0,
      'validationScore': 1.0,
      'source': 'SOS',
      'status': 'AI_DETECTED',
      'latitude': fallbackLat,
      'longitude': fallbackLng,
      'title': 'Emergency SOS Alert',
      'summary': 'Mobile SOS panic trigger by $userName ($phone).',
      'details': [
        'SOS ID: ${docRef.id}',
        'Message: ${customMessage ?? 'Immediate assistance requested'}',
      ],
      'recommendation': 'Auto-dispatch nearest active patrol and monitor live GPS/video.',
      'triedPatrols': [],
      'detectedAt': DateTime.now().toUtc().toIso8601String(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };

    // Write incident + start background GPS resolution simultaneously.
    final gpsFuture = _resolveSosLocation();
    // HARD TIMEOUT: if Firestore is unreachable, fail loudly instead of an
    // infinite spinner. The UI catch shows the error snackbar.
    final incidentWrite = _db
        .collection('incidents')
        .doc(incidentId)
        .set(incidentPayload)
        .timeout(const Duration(seconds: 8), onTimeout: () => throw TimeoutException('Firestore incident write timed out — check internet connection'));

    debugPrint('[SOS] writing dispatch trigger $incidentId …');

    // The incident write is the dispatch trigger — await ONLY that.
    // Everything else is kicked off and left to run in the background.
    await incidentWrite;
    debugPrint('[SOS] incident written — dispatch engine triggered');

    // ---- 2. NOW write the rest (sos_events, timeline, live location) ----
    // Use whatever GPS resolved (often still the fallback if cold).
    final Position? pos = await gpsFuture;
    final double lat = pos?.latitude ?? fallbackLat;
    final double lng = pos?.longitude ?? fallbackLng;

    // ── SUPABASE MIRROR ── push the SOS onto the Supabase tables the backend
    // dispatch engine + Patrol app actually consume, so a citizen SOS reaches
    // the Patrol (previously it only went to Firebase and was never seen).
    unawaited(_mirrorIncidentToSupabase(
      incidentId: incidentId,
      sosId: docRef.id,
      source: 'SOS',
      status: 'ACTIVE',
      riskLevel: 'CRITICAL',
      latitude: lat,
      longitude: lng,
      title: 'Emergency SOS Alert',
      data: {
        'sosId': docRef.id,
        'incidentId': incidentId,
        'videoSessionId': docRef.id,
        'cameraId': 'SOS-MOBILE',
        'eventType': 'MOBILE_SOS',
        'riskLevel': 'CRITICAL',
        'status': 'ACTIVE',
        'latitude': lat,
        'longitude': lng,
        'source': 'SOS',
        'assignedPatrolId': null,
        'activeDispatchId': null,
        'title': 'Emergency SOS Alert',
        'summary': 'Mobile SOS panic trigger by $userName ($phone).',
        'detectedAt': DateTime.now().toUtc().toIso8601String(),
      },
    ));
    unawaited(_upsertSosEvent(
      sosId: docRef.id,
      incidentId: incidentId,
      status: 'ACTIVE',
      latitude: lat,
      longitude: lng,
      accuracy: pos?.accuracy ?? 5.0,
      extra: {'userName': userName, 'phone': phone, 'sosId': docRef.id},
    ));

    final sosPayload = <String, dynamic>{
      'sosId': docRef.id,
      'incidentId': incidentId,
      'userId': userId,
      'userName': userName,
      'phone': phone,
      'userPhone': phone,
      'latitude': lat,
      'longitude': lng,
      'accuracy': pos?.accuracy ?? 5.0,
      'message': customMessage ?? 'Emergency SOS Alert - Citizen in Distress!',
      'status': 'ACTIVE',
      'videoStatus': 'STARTING',
      'createdAt': FieldValue.serverTimestamp(),
      'lastLocationAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    // Best-effort background writes — do NOT await; dispatch already fired.
    unawaited(_db.collection('incidents').doc(incidentId).update({
      'latitude': lat,
      'longitude': lng,
      'details': [
        'SOS ID: ${docRef.id}',
        'Location: $lat, $lng',
        'Message: ${customMessage ?? 'Immediate assistance requested'}',
      ],
      'accuracy': pos?.accuracy ?? 5.0,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }));

    unawaited(docRef.set(sosPayload));

    unawaited(docRef.collection('timeline').add({
      'type': 'SOS_CREATED',
      'message': 'Citizen triggered SOS from Public app',
      'latitude': lat,
      'longitude': lng,
      'accuracy': pos?.accuracy ?? 5.0,
      'createdAt': FieldValue.serverTimestamp(),
    }));

        unawaited(_publishLiveSosLocation(docRef.id, lat, lng, pos?.accuracy ?? 5.0, userName, phone));
    _startSosLocationStream(docRef.id, userName, phone);
    _streamSosLocationToSupabase(docRef.id, incidentId, userName: userName, phone: phone);
    unawaited(_startSosVideoOffer(docRef.id, userId));

    return docRef.id;
  }

  /// Resolve the SOS location in the fastest, safest way: return the cached
  /// last-known position instantly (if available), and race a fresh GPS fix
  /// with a short timeout so a cold GPS never blocks the SOS dispatch.
  static Future<Position?> _resolveSosLocation() async {
    Position? lastKnown;
    try {
      lastKnown = _lastKnown;
      // Kick off a fresh high-accuracy fix, but with a SHORT budget.
      final fresh = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 4),
      ).timeout(const Duration(seconds: 2), onTimeout: () => throw TimeoutException('gps slow'));

      if (fresh != null) {
        _lastKnown = fresh;
        _lastKnownAt = DateTime.now().millisecondsSinceEpoch;
        return fresh;
      }
    } catch (_) {}

    // Return whatever we have — even the fallback is better than stalling.
    return lastKnown;
  }

  static Future<void> _publishLiveSosLocation(
    String sosId,
    double lat,
    double lng,
    double accuracy,
    String userName,
    String phone,
  ) async {
    try {
      await _rtdb.ref('live/sos/$sosId').update({
        'sosId': sosId,
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
        'userName': userName,
        'phone': phone,
        'status': 'ACTIVE',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Live SOS RTDB update failed: $e');
    }
  }

  static void _startSosLocationStream(String sosId, String userName, String phone) {
    _sosLocationStreams[sosId]?.cancel();
    // Firestore mirror throttle — RTDB above is the high-frequency channel;
    // Firestore is durable state only. Without this throttle a moving phone
    // can burn thousands of quota writes per SOS (free tier = 20k/day) and
    // take down ALL Firestore writes system-wide with 429s.
    int lastFirestoreWriteMs = 0;
    _sosLocationStreams[sosId] = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((pos) async {
      await _publishLiveSosLocation(sosId, pos.latitude, pos.longitude, pos.accuracy, userName, phone);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastFirestoreWriteMs < 15000) return; // quota guard
      lastFirestoreWriteMs = nowMs;
      await _db.collection('sos_events').doc(sosId).set({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'lastLocationAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }, onError: (e) => debugPrint('SOS live location stream failed: $e'));
  }

  /// Loads admin-configured TURN relay from Firestore `settings/webrtc` so
  /// SOS live audio/video can traverse carrier-grade NAT between two phones.
  /// Falls back to STUN-only if no TURN relay is configured.
  static Future<List<Map<String, dynamic>>> _loadIceServers() async {
    const stunOnly = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ];
    try {
      final snap = await _db.collection('settings').doc('webrtc').get().timeout(
            const Duration(seconds: 6),
          );
      final d = snap.data() ?? {};
      final turnUrl = (d['turnUrl'] ?? '').toString().trim();
      if (turnUrl.isEmpty) return stunOnly;
      final servers = <Map<String, dynamic>>[
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ];
      final turn = <String, dynamic>{'urls': turnUrl};
      final user = (d['turnUsername'] ?? '').toString().trim();
      final pass = (d['turnCredential'] ?? '').toString().trim();
      if (user.isNotEmpty && pass.isNotEmpty) {
        turn['username'] = user;
        turn['credential'] = pass;
      }
      servers.add(turn);
      return servers;
    } catch (_) {
      return stunOnly;
    }
  }


  static Future<void> _startSosVideoOffer(String sosId, String userId) async {
    try {
      final sessionRef = _db.collection('webrtc_sessions').doc(sosId);
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'facingMode': 'environment'},
      });
      _sosLocalStreams[sosId] = stream;
      await sessionRef.set({
        'sosId': sosId,
        'callerUserId': userId,
        'type': 'SOS_VIDEO_MULTI_VIEWER',
        'status': 'WAITING_FOR_VIEWERS',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      sessionRef.collection('viewers').snapshots().listen((snap) {
        for (final change in snap.docChanges) {
          if (change.type != DocumentChangeType.added && change.type != DocumentChangeType.modified) continue;
          final viewer = change.doc.data();
          if (viewer == null || viewer['requestOffer'] != true || viewer['offer'] != null) continue;
          final viewerId = change.doc.id;
          if (_sosPeerConnections['$sosId/$viewerId'] != null) continue;
          unawaited(_createOfferForViewer(sosId, viewerId, stream));
        }
      });
      await _db.collection('sos_events').doc(sosId).set({'videoStatus': 'WAITING_FOR_VIEWERS'}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('SOS WebRTC setup failed: $e');
      await _db.collection('sos_events').doc(sosId).set({'videoStatus': 'UNAVAILABLE', 'videoError': e.toString()}, SetOptions(merge: true));
    }
  }

  static Future<void> _createOfferForViewer(String sosId, String viewerId, MediaStream stream) async {
    final viewerRef = _db.collection('webrtc_sessions').doc(sosId).collection('viewers').doc(viewerId);
    try {
      final pc = await createPeerConnection({
        'iceServers': await _loadIceServers(),
      });
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        viewerRef.collection('callerCandidates').add(candidate.toMap());
      };
      pc.onConnectionState = (state) {
        viewerRef.set({'connectionState': state.toString(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      };
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await viewerRef.set({
        'offer': offer.toMap(),
        'offerCreatedAt': FieldValue.serverTimestamp(),
        'status': 'OFFERED',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      var answerApplied = false;
      viewerRef.snapshots().listen((snap) async {
        final answer = snap.data()?['answer'];
        if (answer is Map && !answerApplied) {
          answerApplied = true;
          await pc.setRemoteDescription(RTCSessionDescription(answer['sdp'] as String?, answer['type'] as String?));
          await viewerRef.set({'status': 'CONNECTED', 'connectedAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
          await _db.collection('sos_events').doc(sosId).set({'videoStatus': 'LIVE'}, SetOptions(merge: true));
        }
      });
      viewerRef.collection('calleeCandidates').snapshots().listen((snap) {
        for (final change in snap.docChanges) {
          if (change.type != DocumentChangeType.added) continue;
          final c = change.doc.data();
          if (c == null) continue;
          pc.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?));
        }
      });
      _sosPeerConnections['$sosId/$viewerId'] = pc;
    } catch (e) {
      debugPrint('Viewer WebRTC offer failed: $e');
      await viewerRef.set({'status': 'FAILED', 'error': e.toString(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
  }

  // Submit Incident Report
  static Future<String> submitReport({
    required String category,
    required String title,
    required String description,
    String? locationNote,
    String? severity,
  }) async {
    final pos = await getCurrentLocation();
    final double lat = pos?.latitude ?? 12.5209;
    final double lng = pos?.longitude ?? 78.2134;

    final docRef = _db.collection('public_reports').doc();
    await docRef.set({
      'reportId': docRef.id,
      'userId': _auth.currentUser?.uid ?? 'usr_citizen_001',
      'category': category,
      'title': title,
      'description': description,
      'severity': severity ?? 'MEDIUM',
      'locationNote': locationNote ?? 'Krishnagiri Central Area',
      'latitude': lat,
      'longitude': lng,
      'status': 'SUBMITTED',
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
  }

  // Add Emergency Contact
  static Future<void> addEmergencyContact(String uid, Map<String, String> contact) async {
    await _db.collection('users').doc(uid).set({
      'emergencyContacts': FieldValue.arrayUnion([contact])
    }, SetOptions(merge: true));
  }
}

// ============================================================================
// Main Public Home Shell
// ============================================================================

class PublicHomeScreen extends StatefulWidget {
  const PublicHomeScreen({super.key});

  @override
  State<PublicHomeScreen> createState() => _PublicHomeScreenState();
}

class _PublicHomeScreenState extends State<PublicHomeScreen> {
  bool _isLoggedIn = false;
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _user;
  int _selectedIndex = 0;
  bool _isTamil = false; // Language toggle
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => throw Exception('Prefs timeout'),
      );
      final email = prefs.getString('public_user_email');
      final name = prefs.getString('public_user_name');
      if (email != null && name != null) {
        setState(() {
          _user = {
            'id': prefs.getString('public_user_id') ?? 'usr_citizen_001',
            'name': name,
            'email': email,
            'phone': prefs.getString('public_user_phone') ?? '+91 98765 43210',
          };
          _isLoggedIn = true;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _login(String email, String password) async {
    setState(() => _error = null);
    try {
      final userData = await SafetyService.login(email, password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('public_user_id', userData['id'] ?? '');
      await prefs.setString('public_user_name', userData['name'] ?? '');
      await prefs.setString('public_user_email', userData['email'] ?? '');
      await prefs.setString('public_user_phone', userData['phone'] ?? '');

      setState(() {
        _user = userData;
        _isLoggedIn = true;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _register(String name, String email, String password, String phone) async {
    setState(() => _error = null);
    try {
      final userData = await SafetyService.register(
        name: name,
        email: email,
        password: password,
        phone: phone,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('public_user_id', userData['id'] ?? '');
      await prefs.setString('public_user_name', userData['name'] ?? '');
      await prefs.setString('public_user_email', userData['email'] ?? '');
      await prefs.setString('public_user_phone', userData['phone'] ?? '');

      setState(() {
        _user = userData;
        _isLoggedIn = true;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _loginWithGoogle() async {
    setState(() => _error = null);
    try {
      final userData = await SafetyService.loginWithGoogle();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('public_user_id', userData['id'] ?? '');
      await prefs.setString('public_user_name', userData['name'] ?? '');
      await prefs.setString('public_user_email', userData['email'] ?? '');
      await prefs.setString('public_user_phone', userData['phone'] ?? '');

      setState(() {
        _user = userData;
        _isLoggedIn = true;
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await FirebaseAuth.instance.signOut();
    setState(() {
      _isLoggedIn = false;
      _user = null;
      _selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF06B6D4)),
        ),
      );
    }

    if (!_isLoggedIn) {
      return PublicLoginScreen(
        onLogin: _login,
        onGoogleLogin: _loginWithGoogle,
        onRegister: _register,
        error: _error,
        isTamil: _isTamil,
        onToggleLang: () => setState(() => _isTamil = !_isTamil),
      );
    }

    final screens = [
      HomeDashboardTab(
        user: _user!,
        isTamil: _isTamil,
        onNavigate: (index) => setState(() => _selectedIndex = index),
      ),
      LiveSafetyRadarTab(isTamil: _isTamil),
      IncidentReportTab(user: _user!, isTamil: _isTamil, onReportSent: () => setState(() => _selectedIndex = 3)),
      MyReportsTab(user: _user!, isTamil: _isTamil),
      SafetyGuideTab(
        user: _user!,
        isTamil: _isTamil,
        onLogout: _logout,
        onToggleLang: () => setState(() => _isTamil = !_isTamil),
      ),
      PublicSettingsTab(isTamil: _isTamil),
    ];

    // In-app update notification — checks Firebase once per launch.
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
final u = await AppUpdateService.check();
          // Don't show if user already downloaded this version (keyed on BOTH
          // the version name and the numeric code so re-prompting an already
          // downloaded/installed release never happens).
          final prefs = await SharedPreferences.getInstance();
          final downloadedVersion = prefs.getString('update_downloaded_version');
          final downloadedCode = prefs.getInt('update_downloaded_code');
          final uVersion = (u['version'] ?? '').toString();
          final uCode = (u['versionCode'] ?? 0) as int;
          if (uVersion == downloadedVersion ||
              (downloadedCode != null && downloadedCode == uCode)) {
            debugPrint('[UPDATE] Version ${u['version']} already downloaded, skipping dialog');
            return;
          }

          if (u['available'] == true && mounted) {
            showDialog(
              context: context,
              builder: (ctx) {
                double? progress;
                bool busy = false;
                String msg = '';
                return StatefulBuilder(
                  builder: (ctx, setDlgState) => AlertDialog(
                    backgroundColor: const Color(0xFF111827),
                    title: const Text('🔄 Update Available'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Version ${u['version']} is available."
                          "${(u['notes'] as String).isNotEmpty ? "\n\n${u['notes']}" : ''}"
                          '\n\nDownloading from the cloud — works on any network.',
                          style: const TextStyle(fontSize: 14),
                        ),
                        if (progress != null) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 6),
                          Text('${(progress! * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(
                                  color: Color(0xFF06B6D4), fontSize: 12)),
                        ],
                        if (msg.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(msg,
                              style: const TextStyle(
                                  color: Colors.amber, fontSize: 12)),
                        ],
                      ],
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Later')),
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                setDlgState(() {
                                  busy = true;
                                  msg = 'Downloading from cloud…';
                                });
                                try {
                                  final apkUrl = (u['url'] as String? ?? '');
                                  if (apkUrl.isEmpty) {
                                    throw Exception('No APK URL in update config');
                                  }
                                  await AppUpdateService.downloadAndInstall(
                                    apkUrl,
                                    parts: const [], // GitHub uses direct URL
                                    totalSize: (u['totalSize'] ?? 0) as int,
                                    onProgress: (p) {
                                      if (ctx.mounted) {
                                        setDlgState(() => progress = p);
                                      }
                                    },
                                  );
                                  if (ctx.mounted) {
                                    setDlgState(() {
                                      busy = false;
                                      progress = null;
                                      msg = '✅ Update downloaded!\n\nPlease CLOSE this app and install the update from your file manager or notification.\n\nIf Play Protect warns, tap "More details" → "Install anyway".';
                                    });
                                  }
                                  // Store that we showed this version
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setString('update_downloaded_version', (u['version'] ?? '').toString());
                                  await prefs.setInt('update_downloaded_code', (u['versionCode'] ?? 0) as int);
                                  // Close dialog after 5 seconds
                                  Future.delayed(const Duration(seconds: 5), () {
                                    if (ctx.mounted && Navigator.canPop(ctx)) {
                                      Navigator.pop(ctx);
                                    }
                                  });
                                } catch (e) {
                                  debugPrint('[UPDATE] install failed: $e');
                                  if (ctx.mounted) {
                                    setDlgState(() {
                                      busy = false;
                                      progress = null;
                                      msg = 'Update failed: $e';
                                    });
                                  }
                                }
                              },
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF06B6D4)),
                        child: Text(busy ? 'Downloading…' : 'Update Now'),
                      ),
                    ],
                  ),
                );
              },
            );
          }
        } catch (_) {}
      });
    }

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        backgroundColor: const Color(0xFF111827),
        indicatorColor: const Color(0xFF06B6D4).withValues(alpha: 0.2),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.shield_outlined),
            selectedIcon: const Icon(Icons.shield, color: Color(0xFF06B6D4)),
            label: _isTamil ? 'முகப்பு' : 'Home',
          ),
          NavigationDestination(
            icon: const Icon(Icons.radar_outlined),
            selectedIcon: const Icon(Icons.radar, color: Color(0xFF06B6D4)),
            label: _isTamil ? 'ரேடார்' : 'Radar',
          ),
          NavigationDestination(
            icon: const Icon(Icons.add_alert_outlined),
            selectedIcon: const Icon(Icons.add_alert, color: Color(0xFFEF4444)),
            label: _isTamil ? 'புகார்' : 'Report',
          ),
          NavigationDestination(
            icon: const Icon(Icons.history_outlined),
            selectedIcon: const Icon(Icons.history, color: Color(0xFF06B6D4)),
            label: _isTamil ? 'புகார்கள்' : 'My Reports',
          ),
          NavigationDestination(
            icon: const Icon(Icons.health_and_safety_outlined),
            selectedIcon: const Icon(Icons.health_and_safety, color: Color(0xFF10B981)),
            label: _isTamil ? 'வழிகாட்டி' : 'Guide',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: Color(0xFF06B6D4)),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Screen 1: Login & Registration Screen
// ============================================================================

class PublicLoginScreen extends StatefulWidget {
  final Future<void> Function(String email, String password) onLogin;
  final Future<void> Function() onGoogleLogin;
  final Future<void> Function(String name, String email, String password, String phone) onRegister;
  final String? error;
  final bool isTamil;
  final VoidCallback onToggleLang;

  const PublicLoginScreen({
    super.key,
    required this.onLogin,
    required this.onGoogleLogin,
    required this.onRegister,
    this.error,
    required this.isTamil,
    required this.onToggleLang,
  });

  @override
  State<PublicLoginScreen> createState() => _PublicLoginScreenState();
}

class _PublicLoginScreenState extends State<PublicLoginScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  bool _googleLoading = false;
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: widget.onToggleLang,
            icon: const Icon(Icons.language, color: Colors.cyanAccent, size: 18),
            label: Text(
              widget.isTamil ? 'English' : 'தமிழ்',
              style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF1F2937)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF06B6D4).withValues(alpha: 0.1),
                  blurRadius: 30,
                  spreadRadius: 5,
                )
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0891B2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.shield, color: Colors.white, size: 44),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'மக்கள் அரண்',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
                const Text(
                  'MakkalAran Public Safety',
                  style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 28),

                if (_isRegister) ...[
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: widget.isTamil ? 'முழு பெயர்' : 'Full Name',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: widget.isTamil ? 'கைபேசி எண்' : 'Mobile Number',
                      prefixIcon: const Icon(Icons.phone_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: widget.isTamil ? 'மின்னஞ்சல்' : 'Email Address',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 14),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: widget.isTamil ? 'கடவுச்சொல்' : 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),

                if (widget.error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      widget.error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ],

                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading || _googleLoading
                        ? null
                        : () async {
                            setState(() => _loading = true);
                            if (_isRegister) {
                              await widget.onRegister(
                                _nameController.text.trim().isEmpty ? 'Citizen User' : _nameController.text.trim(),
                                _emailController.text.trim(),
                                _passwordController.text,
                                _phoneController.text.trim().isEmpty ? '+91 98765 43210' : _phoneController.text.trim(),
                              );
                            } else {
                              await widget.onLogin(
                                _emailController.text.trim(),
                                _passwordController.text,
                              );
                            }
                            if (mounted) setState(() => _loading = false);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF06B6D4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          )
                        : Text(
                            _isRegister
                                ? (widget.isTamil ? 'பதிவு செய்க' : 'Create Account')
                                : (widget.isTamil ? 'உள்நுழைக' : 'Sign In'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                  ),
                ),

                const SizedBox(height: 12),

                // Google Sign In Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton(
                    onPressed: _loading || _googleLoading
                        ? null
                        : () async {
                            setState(() => _googleLoading = true);
                            await widget.onGoogleLogin();
                            if (mounted) setState(() => _googleLoading = false);
                          },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF374151), width: 1.5),
                      backgroundColor: const Color(0xFF1F2937).withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _googleLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Color(0xFF06B6D4), strokeWidth: 2),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                child: const Text(
                                  'G',
                                  style: TextStyle(
                                    color: Color(0xFF4285F4),
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Flexible so the label shrinks instead of
                              // overflowing the button on narrow screens.
                              Flexible(
                                child: Text(
                                  widget.isTamil ? 'கூகிள் மூலம் தொடர்க' : 'Continue with Google',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),

                const SizedBox(height: 14),
                TextButton(
                  onPressed: () => setState(() => _isRegister = !_isRegister),
                  child: Text(
                    _isRegister
                        ? (widget.isTamil ? 'ஏற்கனவே கணக்கு உள்ளதா? உள்நுழைக' : 'Already registered? Sign In')
                        : (widget.isTamil ? 'புதிய பயனரா? கணக்கை உருவாக்குக' : 'New Citizen? Create Account'),
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Screen 2: Home Dashboard Tab with Instant SOS
// ============================================================================

class HomeDashboardTab extends StatefulWidget {
  final Map<String, dynamic> user;
  final bool isTamil;
  final Function(int) onNavigate;

  const HomeDashboardTab({
    super.key,
    required this.user,
    required this.isTamil,
    required this.onNavigate,
  });

  @override
  State<HomeDashboardTab> createState() => _HomeDashboardTabState();
}

class _HomeDashboardTabState extends State<HomeDashboardTab> {
  bool _sosSending = false;
  String? _activeSosId;

  Future<void> _sendEmergencySos() async {
    setState(() => _sosSending = true);
    try {
      final sosId = await SafetyService.triggerSos(
        userName: widget.user['name'] ?? 'Citizen Ananya',
        phone: widget.user['phone'] ?? '+91 98765 43210',
      );
      setState(() {
        _activeSosId = sosId;
        _sosSending = false;
      });

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            icon: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 52),
            title: Text(widget.isTamil ? '🚨 அவசர எச்சரிக்கை அனுப்பப்பட்டது!' : '🚨 SOS Alert Dispatched!'),
            content: Text(
              widget.isTamil
                  ? 'உங்கள் நேரடி ஜி.பி.எஸ் இருப்பிடம் மற்றும் உதவி கோரிக்கை காவல் துறை மற்றும் கட்டுப்பாட்டு அறைக்கு அனுப்பப்பட்டுள்ளது. உடனடியாக உதவி வரவிருக்கிறது.'
                  : 'Your live GPS coordinates and distress call have been broadcasted to Tamil Nadu Police Control Room & nearest patrol units.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _sosSending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SOS Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Header Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.isTamil ? "வணக்கம்" : "Hello"}, ${widget.user['name'] ?? 'Citizen'} 👋',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    widget.isTamil ? 'உங்கள் பாதுகாப்பு, எங்கள் கடமை' : 'Your safety is our priority',
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 13),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.shield, color: Colors.greenAccent, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      widget.isTamil ? 'பாதுகாப்பு: உயர்' : 'Safe Zone',
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // EMERGENCY SOS HERO BUTTON
          GestureDetector(
            onTap: _sosSending ? null : _sendEmergencySos,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFDC2626), Color(0xFF7F1D1D)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withValues(alpha: 0.4),
                    blurRadius: 25,
                    spreadRadius: 2,
                    offset: const Offset(0, 8),
                  )
                ],
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5), width: 1.5),
              ),
              child: Column(
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: _sosSending
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : const Icon(Icons.sos_rounded, size: 48, color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.isTamil ? 'அவசர உதவி (SOS)' : 'EMERGENCY SOS',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.isTamil ? 'உடனடி காவல் உதவிக்கு அழுத்தவும்' : 'Tap to alert Police & Command Room immediately',
                    style: TextStyle(color: Colors.red[100], fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // QUICK ACTION TILES
          Text(
            widget.isTamil ? 'முக்கிய சேவைகள்' : 'Quick Safety Services',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ServiceCard(
                  icon: Icons.report_problem_rounded,
                  title: widget.isTamil ? 'புகார் பதிவு' : 'Report Incident',
                  subtitle: widget.isTamil ? 'புகார் அனுப்பவும்' : 'Report threat or hazard',
                  color: Colors.amber,
                  onTap: () => widget.onNavigate(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ServiceCard(
                  icon: Icons.radar_rounded,
                  title: widget.isTamil ? 'நேரடி ரேடார்' : 'Threat Radar',
                  subtitle: widget.isTamil ? 'கண்காணிப்பு' : 'Live area safe map',
                  color: Colors.cyan,
                  onTap: () => widget.onNavigate(1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ServiceCard(
                  icon: Icons.history_rounded,
                  title: widget.isTamil ? 'என் புகார்கள்' : 'My Reports',
                  subtitle: widget.isTamil ? 'நிலை அறிய' : 'Track status',
                  color: Colors.purpleAccent,
                  onTap: () => widget.onNavigate(3),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ServiceCard(
                  icon: Icons.phone_in_talk_rounded,
                  title: widget.isTamil ? 'அவசர எண்கள்' : 'Emergency 112',
                  subtitle: widget.isTamil ? 'நேரடி அழைப்பு' : 'Call 112 / 100',
                  color: Colors.greenAccent,
                  onTap: () => widget.onNavigate(4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // LIVE COMMUNITY BROADCAST ALERTS FEED — Firebase Realtime Database
          // (/live/incidents, written by the backend the instant an incident
          // is created/verified). Pushes to citizens with zero polling.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.isTamil ? 'பாதுகாப்பு அறிவிப்புகள்' : 'Live Public Safety Alerts',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const Icon(Icons.sensors, color: Colors.cyanAccent, size: 20),
            ],
          ),
          const SizedBox(height: 12),

          StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance.ref('live/incidents').onValue,
            builder: (context, snapshot) {
              List<Map<String, dynamic>> alerts = [];
              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                final raw = snapshot.data!.snapshot.value as Map<Object?, Object?>;
                alerts = raw.entries.map((e) {
                  final v = Map<String, dynamic>.from(e.value as Map);
                  return v;
                }).toList()
                  ..sort((a, b) => ((b['updatedAt'] ?? 0) as num).compareTo((a['updatedAt'] ?? 0) as num));
                alerts = alerts.take(4).toList();
              }

              if (alerts.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text('All zones currently clear and secure.', style: TextStyle(color: Colors.grey)),
                );
              }

              return Column(
                children: alerts.map((data) {
                  final isHigh = data['riskLevel'] == 'HIGH' || data['riskLevel'] == 'CRITICAL';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isHigh ? Colors.redAccent.withValues(alpha: 0.3) : const Color(0xFF1F2937),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isHigh ? Icons.warning_amber_rounded : Icons.info_outline,
                          color: isHigh ? Colors.redAccent : Colors.cyanAccent,
                          size: 26,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data['title'] ?? data['eventType'] ?? 'Public Alert',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              Text(
                                '${data["cameraId"]?.toString().isNotEmpty == true ? data["cameraId"] : "Krishnagiri"} · Status: ${data['status'] ?? "DISPATCHED"}',
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: (isHigh ? Colors.red : Colors.cyan).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            data['riskLevel'] ?? 'INFO',
                            style: TextStyle(
                              color: isHigh ? Colors.redAccent : Colors.cyanAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: Colors.grey[400], fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Screen 3: Live Safety Radar & Area Status Tab
// ============================================================================

class LiveSafetyRadarTab extends StatefulWidget {
  final bool isTamil;
  const LiveSafetyRadarTab({super.key, required this.isTamil});
  @override
  State<LiveSafetyRadarTab> createState() => _LiveSafetyRadarTabState();
}

class _LiveSafetyRadarTabState extends State<LiveSafetyRadarTab> {
  GoogleMapController? _mapController;
  LatLng _current = const LatLng(12.5209, 78.2134);
  double _accuracy = 100;
  StreamSubscription<Position>? _positionSub;

  @override
  void initState() {
    super.initState();
    SafetyService.getCurrentLocation().then((pos) {
      if (pos == null || !mounted) return;
      setState(() {
        _current = LatLng(pos.latitude, pos.longitude);
        _accuracy = pos.accuracy;
      });
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(_current, 15));
    });
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _current = LatLng(pos.latitude, pos.longitude);
        _accuracy = pos.accuracy;
      });
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(widget.isTamil ? 'நேரடி பாதுகாப்பு வரைபடம்' : 'Live Google Safety Map', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text(widget.isTamil ? 'உங்கள் பகுதியின் நேரடி பாதுகாப்பு நிலை' : 'Google Maps view with live public location, patrols and SOS markers', style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('patrol_teams').snapshots(),
            builder: (context, patrolSnap) {
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('sos_events').where('status', whereIn: ['ACTIVE', 'DISPATCHED', 'RESPONDING', 'EN_ROUTE']).snapshots(),
                builder: (context, sosSnap) {
                  final markers = <Marker>{
                    Marker(markerId: const MarkerId('me'), position: _current, infoWindow: const InfoWindow(title: 'My live location'), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure)),
                  };
                  final circles = <Circle>{
                    Circle(circleId: const CircleId('me_accuracy'), center: _current, radius: _accuracy, fillColor: Colors.blue.withValues(alpha: 0.12), strokeColor: Colors.blueAccent, strokeWidth: 1),
                  };
                  for (final doc in patrolSnap.data?.docs ?? []) {
                    final d = doc.data() as Map<String, dynamic>;
                    final lat = (d['latitude'] as num?)?.toDouble();
                    final lng = (d['longitude'] as num?)?.toDouble();
                    if (lat == null || lng == null) continue;
                    markers.add(Marker(markerId: MarkerId('patrol_${doc.id}'), position: LatLng(lat, lng), infoWindow: InfoWindow(title: d['teamName'] ?? 'Patrol', snippet: d['status'] ?? ''), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)));
                  }
                  final polylines = <Polyline>{};
                  for (final doc in sosSnap.data?.docs ?? []) {
                    final d = doc.data() as Map<String, dynamic>;
                    final lat = (d['latitude'] as num?)?.toDouble();
                    final lng = (d['longitude'] as num?)?.toDouble();
                    if (lat == null || lng == null) continue;
                    final sosPoint = LatLng(lat, lng);
                    markers.add(Marker(markerId: MarkerId('sos_${doc.id}'), position: sosPoint, infoWindow: InfoWindow(title: 'SOS ${d['sosId'] ?? doc.id}', snippet: d['status'] ?? 'ACTIVE'), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed)));
                    circles.add(Circle(circleId: CircleId('sos_accuracy_${doc.id}'), center: sosPoint, radius: ((d['accuracy'] as num?)?.toDouble() ?? 100), fillColor: Colors.red.withValues(alpha: 0.12), strokeColor: Colors.redAccent, strokeWidth: 1));
                    final assignedPatrolId = (d['assignedPatrolId'] ?? '').toString();
                    if (assignedPatrolId.isNotEmpty) {
                      for (final pDoc in patrolSnap.data?.docs ?? []) {
                        final pData = pDoc.data() as Map<String, dynamic>;
                        if (pDoc.id != assignedPatrolId && pData['patrolId'] != assignedPatrolId) continue;
                        final pLat = (pData['latitude'] as num?)?.toDouble();
                        final pLng = (pData['longitude'] as num?)?.toDouble();
                        if (pLat == null || pLng == null) continue;
                        polylines.add(Polyline(
                          polylineId: PolylineId('route_${pDoc.id}_${doc.id}'),
                          points: [LatLng(pLat, pLng), sosPoint],
                          color: Colors.cyanAccent,
                          width: 5,
                        ));
                      }
                    }
                  }
                  return SizedBox(
                    height: 420,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(target: _current, zoom: 14),
                        myLocationEnabled: true,
                        myLocationButtonEnabled: true,
                        zoomControlsEnabled: true,
                        mapToolbarEnabled: true,
                        markers: markers,
                        circles: circles,
                        polylines: polylines,
                        onMapCreated: (c) => _mapController = c,
                      ),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 20),
          const Text('Active Response Patrol Units', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('patrol_teams').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Text('Loading patrol status...');
              return Column(children: snapshot.data!.docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF1F2937))),
                  child: Row(children: [
                    const Icon(Icons.local_police_rounded, color: Colors.greenAccent, size: 24),
                    const SizedBox(width: 12),
                    Expanded(child: Text('${data['teamName'] ?? 'Patrol Unit'} · ${data['status'] ?? 'UNKNOWN'}', style: const TextStyle(fontSize: 13))),
                  ]),
                );
              }).toList());
            },
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Screen 4: Incident Reporting Tab (Photo, Category, GPS, Description)
// ============================================================================

class IncidentReportTab extends StatefulWidget {
  final Map<String, dynamic> user;
  final bool isTamil;
  final VoidCallback onReportSent;

  const IncidentReportTab({
    super.key,
    required this.user,
    required this.isTamil,
    required this.onReportSent,
  });

  @override
  State<IncidentReportTab> createState() => _IncidentReportTabState();
}

class _IncidentReportTabState extends State<IncidentReportTab> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _locationController = TextEditingController(text: 'Krishnagiri Bus Terminal Area');
  String _selectedCategory = 'UNSAFE_AREA';
  String _selectedSeverity = 'MEDIUM';
  bool _submitting = false;

  final List<Map<String, String>> _categories = [
    {'key': 'UNSAFE_AREA', 'en': 'Unsafe / Dark Area', 'ta': 'பாதுகாப்பற்ற இருண்ட பகுதி'},
    {'key': 'PHYSICAL_ALTERCATION', 'en': 'Fight / Disturbance', 'ta': 'சண்டை / தகராறு'},
    {'key': 'SUSPICIOUS_ACTIVITY', 'en': 'Suspicious Behavior', 'ta': 'சந்தேகத்திற்கிடமான நடத்தை'},
    {'key': 'HARASSMENT', 'en': 'Harassment / Eve Teasing', 'ta': 'பெண்கள் துன்புறுத்தல்'},
    {'key': 'ROAD_HAZARD', 'en': 'Accident / Road Hazard', 'ta': 'விபத்து / சாலை இடர்'},
    {'key': 'THEFT_ATTEMPT', 'en': 'Theft / Robbery', 'ta': 'திருட்டு / வழிப்பறி'},
    {'key': 'OTHER', 'en': 'Other Issue', 'ta': 'மற்றவை'},
  ];

  Future<void> _submitIncident() async {
    if (_titleController.text.trim().isEmpty && _descController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.isTamil ? 'தயவுசெய்து விவரங்களை உள்ளிடவும்' : 'Please provide incident details'),
          backgroundColor: Colors.amber,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await SafetyService.submitReport(
        category: _selectedCategory,
        title: _titleController.text.trim().isEmpty ? _selectedCategory : _titleController.text.trim(),
        description: _descController.text.trim().isEmpty ? _selectedCategory : _descController.text.trim(),
        locationNote: _locationController.text.trim(),
        severity: _selectedSeverity,
      );

      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.isTamil ? '✅ புகார் வெற்றிகரமாக சமர்ப்பிக்கப்பட்டது!' : '✅ Incident report submitted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        _titleController.clear();
        _descController.clear();
        widget.onReportSent();
      }
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Submission failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            widget.isTamil ? 'குற்ற / சம்பவ புகார் பதிவு' : 'Report an Incident',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          Text(
            widget.isTamil ? 'பொதுமக்கள் பாதுகாப்புக்கு தகவல் தெரிவிக்கவும்' : 'Directly notifies police patrol units & control room',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 20),

          // Category Selector
          Text(widget.isTamil ? 'சம்பவ வகை' : 'Category', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedCategory,
            items: _categories.map((c) {
              return DropdownMenuItem(
                value: c['key'],
                child: Text(widget.isTamil ? c['ta']! : c['en']!),
              );
            }).toList(),
            onChanged: (val) => setState(() => _selectedCategory = val ?? 'UNSAFE_AREA'),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 16),

          // Severity Selector
          Text(widget.isTamil ? 'தீவிரத்தன்மை' : 'Urgency Level', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: ['LOW', 'MEDIUM', 'HIGH'].map((s) {
              final isSel = _selectedSeverity == s;
              final col = s == 'HIGH' ? Colors.redAccent : s == 'MEDIUM' ? Colors.amber : Colors.greenAccent;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedSeverity = s),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSel ? col.withValues(alpha: 0.2) : const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSel ? col : const Color(0xFF1F2937)),
                    ),
                    alignment: Alignment.center,
                    child: Text(s, style: TextStyle(color: isSel ? col : Colors.grey, fontWeight: FontWeight.bold)),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // Title
          Text(widget.isTamil ? 'தலைப்பு' : 'Incident Title', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              hintText: widget.isTamil ? 'எ.கா: பேருந்து நிலையத்தில் விளக்கு இல்லை' : 'e.g., Street light damaged near bus stop',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 16),

          // Description
          Text(widget.isTamil ? 'விவரம்' : 'Detailed Description', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _descController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: widget.isTamil ? 'சம்பவம் பற்றிய கூடுதல் தகவல்களை உள்ளிடவும்...' : 'Describe what happened and any urgent assistance needed...',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 16),

          // Location Field
          Text(widget.isTamil ? 'இருப்பிடம்' : 'Location & Landmark', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _locationController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.location_on, color: Colors.cyanAccent),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 24),

          // Submit Button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _submitting ? null : _submitIncident,
              icon: _submitting ? const SizedBox.shrink() : const Icon(Icons.send_rounded),
              label: _submitting
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(widget.isTamil ? 'புகாரை சமர்ப்பிக்கவும்' : 'Submit Report to Police', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF06B6D4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Screen 5: Live "My Reports" Tracker Tab (Firestore Real-time Stream)
// ============================================================================

class MyReportsTab extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool isTamil;

  const MyReportsTab({super.key, required this.user, required this.isTamil});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isTamil ? 'என் புகார்கள் & நிலை' : 'My Reports & Tracking',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              isTamil ? 'காவல்துறை நடவடிக்கைகளை நேரடியாக கண்காணிக்கலாம்' : 'Live status of your submitted safety reports',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('public_reports')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
                  }

                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(isTamil ? 'புகார்கள் எதுவும் இல்லை' : 'No reports filed yet', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(isTamil ? 'புதிய புகாரை பதிவு செய்ய "புகார்" பகுதியை பயன்படுத்தவும்' : 'Use the Report tab to submit an incident', style: const TextStyle(color: Colors.grey)),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, i) {
                      final doc = snapshot.data!.docs[i];
                      final data = doc.data() as Map<String, dynamic>;
                      final status = data['status'] ?? 'SUBMITTED';
                      final isActioned = status == 'ACTIONED' || status == 'RESOLVED';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: isActioned ? Colors.green.withValues(alpha: 0.3) : const Color(0xFF1F2937)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  data['category'] ?? 'Incident',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: (isActioned ? Colors.green : Colors.amber).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    status,
                                    style: TextStyle(
                                      color: isActioned ? Colors.greenAccent : Colors.amberAccent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              data['description'] ?? data['title'] ?? 'No description provided',
                              style: TextStyle(color: Colors.grey[300], fontSize: 13),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'ID: ${doc.id.substring(0, 8)}...',
                                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                                Text(
                                  data['locationNote'] ?? 'Krishnagiri',
                                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Screen 6: Safety Guide, Emergency Contacts & Profile Tab
// ============================================================================

class SafetyGuideTab extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool isTamil;
  final VoidCallback onLogout;
  final VoidCallback onToggleLang;

  const SafetyGuideTab({
    super.key,
    required this.user,
    required this.isTamil,
    required this.onLogout,
    required this.onToggleLang,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Profile Mini Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1F2937)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const CircleAvatar(child: Icon(Icons.person)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user['name'] ?? 'Citizen Ananya', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text(user['email'] ?? 'citizen@makkalaran.local', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      Text('Phone: ${user['phone'] ?? "+91 98765 43210"}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onToggleLang,
                  icon: const Icon(Icons.language, color: Colors.cyanAccent),
                  tooltip: 'Change Language',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 1-Tap Emergency Hotlines
          Text(
            isTamil ? 'அவசர அழைப்பு எண்கள் (1-Tap Call)' : 'Emergency Call Hotlines',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),

          _HotlineTile(
            number: '112',
            title: isTamil ? 'தேசிய அவசர உதவி எண்' : 'National Emergency Helpline',
            color: Colors.redAccent,
          ),
          _HotlineTile(
            number: '100',
            title: isTamil ? 'காவல்துறை கட்டுப்பாட்டு அறை' : 'Tamil Nadu Police',
            color: Colors.blueAccent,
          ),
          _HotlineTile(
            number: '1091',
            title: isTamil ? 'பெண்கள் பாதுகாப்பு உதவி மையம்' : 'Women Safety Helpline',
            color: Colors.purpleAccent,
          ),
          _HotlineTile(
            number: '108',
            title: isTamil ? 'மருத்துவ அவசர ஊர்தி (ஆம்புலன்ஸ்)' : 'Ambulance & Medical Emergency',
            color: Colors.greenAccent,
          ),
          const SizedBox(height: 20),

          // Safety Tips
          Text(
            isTamil ? 'பாதுகாப்பு குறிப்புகள்' : 'Essential Safety Protocols',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1F2937)),
            ),
            child: Column(
              children: [
                _TipRow(icon: Icons.lightbulb_outline, text: isTamil ? 'இரவு நேரங்களில் போதுமான வெளிச்சமுள்ள வழிகளைப் பயன்படுத்தவும்.' : 'Prefer well-lit roads and active public spaces at night.'),
                const Divider(color: Color(0xFF1F2937)),
                _TipRow(icon: Icons.sos_rounded, text: isTamil ? 'அவசர சூழ்நிலையில் SOS பட்டனை அழுத்தினால் உடனே காவல்துறைக்கு தகவல் செல்லும்.' : 'Use SOS in real danger to dispatch nearest police patrol unit.'),
                const Divider(color: Color(0xFF1F2937)),
                _TipRow(icon: Icons.share_location, text: isTamil ? 'அவசர தகவல்களை மக்கள் அரண் மூலம் உடனுக்குடன் தெரிவிக்கலாம்.' : 'Report suspicious activities with photos to prevent crime.'),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Logout Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              label: Text(isTamil ? 'வெளியேறு (Sign Out)' : 'Sign Out', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.redAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HotlineTile extends StatelessWidget {
  final String number;
  final String title;
  final Color color;

  const _HotlineTile({required this.number, required this.title, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(Icons.phone_in_talk, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(number, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ],
          ),
          FilledButton.tonal(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Dialing $number...'), backgroundColor: color),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: color.withValues(alpha: 0.2)),
            child: Text(number, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _TipRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70))),
        ],
      ),
    );
  }
}
// ============================================================================
// Settings Tab — about app, developer info, in-app update
// ============================================================================

class PublicSettingsTab extends StatefulWidget {
  final bool isTamil;
  const PublicSettingsTab({super.key, required this.isTamil});
  @override
  State<PublicSettingsTab> createState() => _PublicSettingsTabState();
}

class _PublicSettingsTabState extends State<PublicSettingsTab> {
  Map<String, dynamic>? _update;
  bool _checking = false;
  double? _progress;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      final u = await AppUpdateService.check();
      if (mounted) {
        final err = (u['error'] as String?) ?? '';
        setState(() {
          _update = u;
          _status = (u['available'] != true && err.isNotEmpty)
              ? 'No update — cloud check failed: $err'
              : '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Check failed - check internet');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    final url = (_update?['url'] ?? '') as String;
    final parts = ((_update?['parts'] as List?) ?? const []).cast<String>();
    if (url.isEmpty && parts.isEmpty) return;
    setState(() { _status = 'Downloading update...'; _progress = 0; });
    try {
      await AppUpdateService.downloadAndInstall(
        url,
        parts: parts,
        totalSize: (_update?['totalSize'] ?? 0) as int,
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
      );
      if (mounted) {
        setState(() {
          _status = 'If prompted, allow "Install unknown apps". If Play Protect '
              'warns, tap "More details" → "Install anyway" — otherwise the '
              'old version stays installed.';
          _progress = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _status = 'Update failed: $e'; _progress = null; });
      }
    }
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.isTamil;
    final update = _update;
    final available = update?['available'] == true;
    final latest = (update?['version'] as String?) ?? '';
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        title: Text(t ? 'Settings' : 'Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: const Color(0xFF111827),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.shield, color: Color(0xFF06B6D4), size: 40),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(AppMeta.appName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                        SizedBox(height: 2),
                        Text('Citizen Safety System', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ]),
                    ),
                  ]),
                  const Divider(height: 24, color: Color(0xFF1F2937)),
                  _row('App version', AppMeta.appVersion),
                  _row('Developed by', AppMeta.developer),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFF111827),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.system_update_alt, color: Color(0xFF06B6D4), size: 20),
                    SizedBox(width: 8),
                    Text('App Update', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ]),
                  const SizedBox(height: 12),
                  _row('Installed version', AppMeta.appVersion),
                  _row('Latest version', latest.isEmpty ? '-' : latest),
                  const SizedBox(height: 12),
                  if (available)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        "New version $latest available!"
                        "${(update?['notes'] as String?)?.isNotEmpty == true ? "\n${update!['notes']}" : ''}",
                        style: const TextStyle(color: Colors.greenAccent),
                      ),
                    )
                  else if (!_checking && update != null)
                    const Text('You are on the latest version.', style: TextStyle(color: Colors.grey)),
                  if (_progress != null) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 6),
                    Text('${(_progress! * 100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(_status, style: const TextStyle(color: Colors.amberAccent, fontSize: 12)),
                  ],
                  const SizedBox(height: 14),
                  Row(children: [
                    OutlinedButton.icon(
                      onPressed: _checking ? null : _check,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Check'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: (available && _progress == null) ? _install : null,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download & Install'),
                      style: FilledButton.styleFrom(
                        backgroundColor: available ? const Color(0xFF06B6D4) : Colors.grey.shade700,
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(child: Text('(c) 2026 Creative Hub Developers', style: TextStyle(color: Colors.grey, fontSize: 11))),
        ],
      ),
    );
  }
}
