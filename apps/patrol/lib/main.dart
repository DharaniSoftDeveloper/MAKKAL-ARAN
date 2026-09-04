import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'update_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// `MapType` is exported by both google_maps_flutter and supabase_flutter
// (storage_client iceberg types) — always take the map SDK's definition.
import 'package:supabase_flutter/supabase_flutter.dart' hide MapType;
import 'presence_service.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

// ============================================================================
// MakkalAran Patrol Application – Full Feature Build
// Features: Dashboard · Assignments · Camera Search · Live View · Profile
// ============================================================================

// PHASE 4/5/7 — Supabase configuration. Only PUBLIC values belong here:
// the URL and anon (publishable) key. Override at build time with:
//   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// The SERVICE ROLE KEY must NEVER be provided to this app.
const String kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://wmlcnmtnvjndlzahmocc.supabase.co',
);
const String kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_6tGiMpJoGE_6Z5gShel-JA_EmZUde6H',
);

/// Shared presence service instance (auth + GO ACTIVE/OFFLINE + GPS).
final presenceService = PresenceService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();   // native media player engine (libmpv)
  // PHASE 4 — Supabase is the primary auth + presence backend.
  await PresenceService.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase init (FCM transport only): $e');
  }
  runApp(const PatrolApp());

  // DB-driven in-app update check — silent unless a newer release is
  // registered in the backend database (Firestore app_releases).
  Future.delayed(const Duration(seconds: 3), () {
    InAppUpdater.maybeCheckAndPrompt(
      appNavigatorKey.currentContext,
      apiBase: kApiBase,
      platformKey: 'android-patrol',
    );
  });
}

class PatrolApp extends StatelessWidget {
  const PatrolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'MakkalAran Patrol',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF06B6D4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardColor: const Color(0xFF111827),
        dividerColor: const Color(0xFF1F2937),
        fontFamily: 'Roboto',
      ),
      home: const PatrolHome(),
    );
  }
}

// ============================================================================
// SUPABASE DATA SERVICE — Firestore database access fully removed.
// ============================================================================
/// Shape-compatible snapshot types so existing StreamBuilder UI keeps working:
/// `doc.id`, `doc.data()` — backed by live Supabase Postgres rows.
class FDoc {
  final String id;
  final Map<String, dynamic> _data;
  FDoc(this.id, this._data);
  Map<String, dynamic> data() => _data;
}

class FSnap {
  final List<FDoc> docs;
  FSnap(this.docs);
  bool get hasData => true;
}

/// Backend REST base (accept/decline dispatch, camera-access requests,
/// in-app updates). Defaults to the control-room server on the LAN so
/// phones reach it over Wi-Fi; override with
/// --dart-define=SAFESIGHT_API=http://<host>:3000.
const String kApiBase = String.fromEnvironment(
  'SAFESIGHT_API',
  defaultValue: 'http://192.168.1.2:3000',
);

String _camelKey(String s) {
  final parts = s.split('_');
  if (parts.length == 1) return s;
  return parts.first + parts.skip(1).map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join();
}

/// Flattens a Postgres row into the camelCase map the UI consumes.
/// Extra fields stored in the `data` JSONB column win over the typed columns,
/// matching how the Firestore documents were structured.
Map<String, dynamic> _flatRow(Map<dynamic, dynamic> r) {
  final out = <String, dynamic>{};
  r.forEach((k, v) {
    if (v == null || k == 'data') return;
    out[_camelKey(k.toString())] = v;
  });
  final extra = r['data'];
  if (extra is Map) extra.forEach((k, v) => out[k.toString()] = v);
  return out;
}

class FirestoreService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Supabase JWT for backend REST calls (guards resolve identity from it).
  /// Auto-refreshes an expired session FIRST — otherwise a phone resumed from
  /// background (>1h) sends a stale token and the backend rejects it with
  /// "Invalid Supabase token".
  static Future<String?> jwtToken() async {
    var s = _client.auth.currentSession;
    if (s != null && s.isExpired) {
      try {
        final r = await _client.auth.refreshSession();
        s = r.session ?? s;
      } catch (e) {
        debugPrint('[auth] session refresh failed: $e');
      }
    }
    return s?.accessToken;
  }


  /// PHASE 11 — Accept goes through the BACKEND endpoint (not a raw DB write):
  /// the engine records the attempt, timestamps, syncs the SOS record and can
  /// trigger notifications. Identity comes from the attached Supabase JWT.
  static Future<void> acceptDispatch(String dispatchId) async {
    final tok = await jwtToken() ?? '';
    final res = await http
        .post(Uri.parse('$kApiBase/dispatches/$dispatchId/accept'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $tok'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw Exception('Accept failed (${res.statusCode}): ${res.body}');
    }
  }

  /// PHASE 11 — Decline routes through the backend too, so the reason lands in
  /// dispatch_attempts and the engine immediately reassigns the next patrol.
  static Future<void> declineDispatch(String dispatchId, String reason) async {
    final tok = await jwtToken() ?? '';
    final res = await http
        .post(Uri.parse('$kApiBase/dispatches/$dispatchId/decline'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $tok'},
            body: jsonEncode({'reason': reason}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw Exception('Decline failed (${res.statusCode}): ${res.body}');
    }
  }


  // ── Camera Access Request (backend REST — identity via Supabase JWT) ─────

  static Future<void> requestCameraAccess({
    required String patrolId,
    required String patrolName,
    required String cameraId,
    required String cameraName,
    required String cameraAddress,
  }) async {
    try {
      final tok = await jwtToken() ?? '';
      final res = await http
          .post(Uri.parse('$kApiBase/cameras/access/request'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $tok'},
              body: jsonEncode({
                'patrolId': patrolId,
                'patrolName': patrolName,
                'cameraId': cameraId,
                'cameraName': cameraName,
                'cameraAddress': cameraAddress,
              }))
          .timeout(const Duration(seconds: 15));
      debugPrint('[camera-access] request → ${res.statusCode}');
    } catch (e) {
      debugPrint('[camera-access] request FAILED: $e');
    }
  }

  /// Polls the backend for this patrol's access requests (realtime polling —
  /// the list only changes when the Control Room grants/denies).
  static Stream<FSnap> listenCameraRequests(String patrolId) {
    Future<FSnap> fetch() async {
      try {
        final tok = await jwtToken() ?? '';
        final res = await http
            .get(Uri.parse('$kApiBase/cameras/access/my'),
                headers: {'Authorization': 'Bearer $tok'})
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) return FSnap(const []);
        final list = (jsonDecode(res.body) as List?) ?? const [];
        return FSnap(list
            .whereType<Map>()
            .map((m) => FDoc((m['id'] ?? m['requestId'] ?? '').toString(), m.cast<String, dynamic>()))
            .toList());
      } catch (e) {
        return FSnap(const []);
      }
    }
    return Stream<FSnap>.periodic(const Duration(seconds: 12)).asyncMap((_) => fetch());
  }

  /// FCM transport stays on Firebase (allowed exception), but the TOKEN now
  /// lives in Supabase `patrol_fcm_tokens` — the notification pipeline's
  /// canonical storage.
  static Future<void> registerFcmToken(String patrolId) async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true, criticalAlert: true);
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return;
      Future<void> store(String t) => _client.from('patrol_fcm_tokens').upsert({
            'patrol_id': patrolId,
            'token': t,
            'platform': 'android',
            'active': true,
          }, onConflict: 'token');
      await store(token);
      FirebaseMessaging.instance.onTokenRefresh.listen(store);
    } catch (e) {
      debugPrint('FCM token registration failed: $e');
    }
  }

  /// Live cameras straight from Supabase (`cameras` — id + data payload).
  static Stream<FSnap> cameraStream() {
    return _client.from('cameras').stream(primaryKey: ['id']).map((rows) =>
        FSnap(rows.map((r) => FDoc((r['id'] ?? '').toString(), _flatRow(r))).toList()));
  }

  /// Live incidents feed (latest 10 by creation time).
  static Stream<FSnap> incidentsStream() {
    return _client.from('incidents').stream(primaryKey: ['id']).map((rows) {
      final docs = rows.map((r) => FDoc((r['id'] ?? '').toString(), _flatRow(r))).toList();
      docs.sort((a, b) => ((b.data()['createdAt'] ?? '') as String)
          .compareTo(((a.data()['createdAt'] ?? '') as String)));
      return FSnap(docs.take(10).toList());
    });
  }

  /// Only THIS patrol's dispatch rows. Realtime stream + a periodic REST
  /// refetch merged together, so a dispatch NEVER "flashes and disappears"
  /// when the Supabase Realtime socket drops or reconnects.
  static Stream<FSnap> dispatchesStream(String patrolId) {
    List<FDoc> build(List<Map<String, dynamic>> rows) {
      final docs = rows.map((r) {
        final d = _flatRow(r);
        d['assignedAt'] = d['assignedAt'] ?? d['createdAt'];
        d['incidentId'] = d['incidentId'] ?? r['incident_id'];
        d['patrolId'] = r['patrol_id'];
        d['sosId'] = d['sosId'] ?? r['sos_id'];
        return FDoc((r['dispatch_id'] ?? '').toString(), d);
      }).toList();
      docs.sort((a, b) => ((b.data()['assignedAt'] ?? '') as String)
          .compareTo(((a.data()['assignedAt'] ?? '') as String)));
      return docs;
    }

    final controller = StreamController<FSnap>.broadcast();
    StreamSubscription<List<Map<String, dynamic>>>? realtimeSub;
    Timer? pollTimer;
    var streaming = false;

    Future<void> refetch() async {
      try {
        final res = await _client
            .from('dispatches')
            .select('*')
            .eq('patrol_id', patrolId)
            .order('created_at', ascending: false)
            .limit(200);
        if (res != null && controller.hasListener) {
          controller.add(FSnap(build((res as List).cast<Map<String, dynamic>>())));
        }
      } catch (e) {
        debugPrint('[dispatches] poll refetch failed: $e');
      }
    }

    controller.onListen = () {
      if (streaming) return;
      streaming = true;
      // Immediate REST snapshot so the UI never waits on the realtime socket.
      unawaited(refetch());
      pollTimer = Timer.periodic(const Duration(seconds: 6), (_) => unawaited(refetch()));
      realtimeSub = _client
          .from('dispatches')
          .stream(primaryKey: ['dispatch_id'])
          .eq('patrol_id', patrolId)
          .listen(
        (rows) {
          if (controller.hasListener) {
            controller.add(FSnap(build(rows)));
          }
        },
        onError: (e) => debugPrint('[dispatches] realtime error: $e'),
      );
    };
    controller.onCancel = () {
      streaming = false;
      realtimeSub?.cancel();
      pollTimer?.cancel();
    };

    return controller.stream;
  }
}

// ============================================================================
// Session Model
// ============================================================================

class PatrolSession {
  final String id;
  final String name;
  final String email;
  final String role;
  final String patrolId;
  const PatrolSession({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.patrolId,
  });
}

// ============================================================================
// Home Shell
// ============================================================================

// ============================================================================
// App Metadata + In-App Update System (Firebase-powered OTA updates)
// ============================================================================

class AppMeta {
  static const appName = 'MakkalAran Patrol';
  static const appVersion = '1.3.0';
  static const versionCode = 100;
  static const developer = 'Creative Hub Developers';
  static const channel = 'patrol'; // Firestore key prefix for update checks
}

class AppUpdateService {
  /// Checks the backend release registry (Firestore `app_releases` via
  /// GET /updates/latest — published with scripts/publish-release.mjs).
  /// Returns {available, version, url, notes}. Falls back to the legacy
  /// Firestore settings/app doc when the backend is unreachable.
  static Future<Map<String, dynamic>> check() async {
    try {
      final res = await http
          .get(Uri.parse('$kApiBase/updates/latest?platform=android-patrol'))
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
          'url': '$kApiBase/updates/download/android-patrol',
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

  /// Downloads the APK from the internet and hands it to the Android
  /// package installer. [onProgress] reports 0.0 → 1.0.
  static Future<void> downloadAndInstall(
    String url, {
    void Function(double progress)? onProgress,
    required String apkFileName,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$apkFileName');
    final client = http.Client();
    try {
      final req = await client.send(http.Request('GET', Uri.parse(url)));
      if (req.statusCode != 200) throw Exception('HTTP ${req.statusCode}');
      final total = req.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in req.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done) {
        throw Exception(res.message);
      }
    } finally {
      client.close();
    }
  }
}

// ============================================================================
// Settings Tab — about app, developer info, manual in-app update
// ============================================================================

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class PatrolHome extends StatefulWidget {
  const PatrolHome({super.key});
  @override
  State<PatrolHome> createState() => _PatrolHomeState();
}

class _PatrolHomeState extends State<PatrolHome> {
  bool _loading = true;
  PatrolSession? _session;
  String? _error;
  int _tab = 0;
  // Spec §3: a patrol is NEVER active just because the app is open.
  // Dispatch eligibility requires an explicit GO ACTIVE press.
  String _dutyStatus = 'OFFLINE';
  Timer? _gpsTimer;
  bool _updateChecked = false;
  String? _pendingDispatchFromNotification;

  // ── Full-screen incoming-dispatch alert (§13) ──
  // Tracks which dispatchIds we have already raised a loud alert for, so a
  // SENT dispatch popping on the stream doesn't re-dialog every rebuild. The
  // alert stays on-screen (not a snackbar) until the officer ACCEPTs or
  // DECLINEs — fixes the old "dispatch flashed and vanished" behaviour.
  final Set<String> _alertedDispatchIds = {};
  StreamSubscription<FSnap>? _dispatchAlertSub;

  @override
  void initState() {
    super.initState();
    _restoreSession();
    _setupFcmTapHandlers();
  }

  @override
  void dispose() {
    _gpsTimer?.cancel();
    _dispatchAlertSub?.cancel();
    super.dispose();
  }

  /// Watch for NEW SENT (auto) dispatches destined to this patrol and raise a
  /// persistent full-screen alert. Robust: the REST-polled stream guarantees
  /// the row is seen even if the Supabase Realtime socket briefly drops.
  void _watchIncomingDispatches(String patrolId) {
    _dispatchAlertSub?.cancel();
    _dispatchAlertSub = FirestoreService.dispatchesStream(patrolId).listen((snap) {
      if (!mounted || _session == null) return;
      final urgent = snap.docs.where((doc) {
        final d = doc.data() as Map<String, dynamic>;
        final status = (d['status'] ?? 'SENT').toString();
        final isAuto = d['autoDispatched'] == true || d['assignedBy'] == 'AUTO_SYSTEM';
        return status == 'SENT';
      }).toList()
        ..sort((a, b) => _dispatchTimeMs(b.data() as Map<String, dynamic>)
            .compareTo(_dispatchTimeMs(a.data() as Map<String, dynamic>)));
      for (final doc in urgent) {
        final d = doc.data() as Map<String, dynamic>;
        final dispatchId = (d['dispatchId'] ?? doc.id).toString();
        if (_alertedDispatchIds.contains(dispatchId)) continue;
        // If an alert dialog is already visible, queue the newest instead.
        _alertedDispatchIds.add(dispatchId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _showIncomingDispatchDialog(dispatchId, d);
        });
      }
    }, onError: (e) => debugPrint('[dispatch-alert] stream error: $e'));
  }

  /// Persistent, loud, full-screen incoming dispatch dialog.
  Future<void> _showIncomingDispatchDialog(String dispatchId, Map<String, dynamic> d) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // officer must ACT — no accidental dismissal
      builder: (ctx) => IncomingDispatchDialog(
        dispatchId: dispatchId,
        dispatch: d,
        onAccept: () async {
          try {
            await FirestoreService.acceptDispatch(dispatchId);
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (mounted) {
              setState(() {
                _pendingDispatchFromNotification = dispatchId;
                _tab = 1;
              });
            }
          } catch (e) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Accept failed: $e'), backgroundColor: Colors.red),
              );
            }
          }
        },
        onDecline: () async {
          try {
            await FirestoreService.declineDispatch(dispatchId, 'DISPATCH ALERT DISMISSED');
            if (ctx.mounted) Navigator.of(ctx).pop();
          } catch (_) {
            if (ctx.mounted) Navigator.of(ctx).pop();
          }
        },
        onSnooze: () {
          if (ctx.mounted) Navigator.of(ctx).pop();
          if (mounted) {
            setState(() {
              _pendingDispatchFromNotification = dispatchId;
              _tab = 1;
            });
          }
        },
      ),
    );
  }

  /// Spec §5: stream GPS while ACTIVE so the dispatch engine can verify
  /// location freshness. Stops immediately on GO OFFLINE.
  ///
  /// PHASE 7 — ONE stream, ONE timer, ONE Supabase row: patrol_presence is
  /// upserted in place every 5s (the previous RTDB 5s + Firestore 60s dual
  /// cadence is replaced). 5s is well inside the unchanged 180s freshness
  /// window and creates no row growth.
  void _setGpsStreaming(bool enabled) {
    _gpsTimer?.cancel();
    _gpsTimer = null;
    if (!enabled || _session == null) return;
    final patrolId = _session!.patrolId;
    // Immediate fix on activation, then periodic heartbeats.
    _pushGpsFix(patrolId);
    _gpsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pushGpsFix(patrolId));
  }

  /// One GPS publish cycle: request permission if needed, try a fresh fix,
  /// fall back to last-known, and NEVER swallow errors silently — the dispatch
  /// engine requires top-level latitude/longitude to be fresh & non-null.
  /// Invalid fixes (out of range / 0,0) are rejected by the presence service.
  Future<void> _pushGpsFix(String patrolId) async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        debugPrint('[GPS] permission denied ($perm) — cannot stream location');
        return;
      }
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint('[GPS] fresh fix failed: $e — trying last-known');
      }
      pos ??= await Geolocator.getLastKnownPosition();
      if (pos == null) {
        debugPrint('[GPS] no position available at all');
        return;
      }
      await presenceService.pushGps(patrolId, pos).timeout(const Duration(seconds: 10));
      debugPrint('[GPS] presence updated: ${pos.latitude},${pos.longitude}');
    } catch (e) {
      debugPrint('[GPS] push failed: $e');
    }
  }

  void _setupFcmTapHandlers() {
    // FCM is a transport optimisation only — if Firebase failed to initialize
    // (offline start, test sandbox, missing config) the app must still boot;
    // dispatch alerts arrive via the Supabase dispatch stream regardless.
    if (Firebase.apps.isEmpty) {
      debugPrint('[FCM] Firebase not initialized — FCM tap handlers disabled');
      return;
    }
    try {
      FirebaseMessaging.instance.getInitialMessage().then(_handleFcmMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleFcmMessage);
      FirebaseMessaging.onMessage.listen((message) {
        final dispatchId = message.data['dispatchId'];
        if (dispatchId != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(message.notification?.title ?? 'Emergency SOS dispatch received'),
            backgroundColor: Colors.red,
            action: SnackBarAction(label: 'OPEN', textColor: Colors.white, onPressed: () => setState(() { _pendingDispatchFromNotification = dispatchId.toString(); _tab = 1; })),
          ));
        }
      });
    } catch (e) {
      debugPrint('[FCM] tap handler setup failed (alerts still stream via Supabase): $e');
    }
  }

  void _handleFcmMessage(RemoteMessage? message) {
    if (message == null) return;
    if (message.data['type'] == 'SOS_DISPATCH') {
      if (mounted) {
        setState(() {
          _pendingDispatchFromNotification = message.data['dispatchId'];
          _tab = 1;
        });
      } else {
        _pendingDispatchFromNotification = message.data['dispatchId'];
      }
    }
  }

  /// PHASE 5 — GO ACTIVE / GO OFFLINE. The server CONFIRMS before the UI
  /// shows the new state: if Supabase rejects the write, the patrol stays
  /// OFFLINE and the real error is surfaced (never silently pretend ACTIVE).
  Future<void> _changeDutyStatus(String status) async {
    final goingActive = status == 'AVAILABLE';
    try {
      // Obtain a real GPS fix first — GO ACTIVE without a fix is refused
      // rather than sent with fake coordinates.
      Position? pos;
      if (goingActive) {
        pos = await _obtainFix();
        if (pos == null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Cannot GO ACTIVE: no valid GPS fix available'),
            backgroundColor: Colors.orange,
          ));
          return; // remain OFFLINE
        }
      }
      // Server write FIRST; local state only after confirmation.
      if (goingActive) {
        await presenceService.goActive(_session!.patrolId, pos);
      } else {
        await presenceService.goOffline(_session!.patrolId);
      }
      setState(() => _dutyStatus = status);
      _setGpsStreaming(goingActive); // start/stop the single GPS stream
    } catch (e) {
      debugPrint('[PATROL] duty status change FAILED: $e');
      setState(() => _dutyStatus = 'OFFLINE');
      _setGpsStreaming(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Duty status update failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  /// Real device GPS only — permission-aware, no hardcoded/mock coordinates.
  Future<Position?> _obtainFix() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        return null;
      }
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
      } catch (_) {}
      pos ??= await Geolocator.getLastKnownPosition();
      if (pos == null || !PresenceService.isValidFix(pos)) return null;
      return pos;
    } catch (e) {
      debugPrint('[GPS] obtainFix failed: $e');
      return null;
    }
  }

  Future<void> _restoreSession() async {
    try {
      // PHASE 4 — restore via Supabase session, THEN reconcile with the server.
      final profile = await PresenceService.restoreSession();
      if (profile == null) {
        setState(() => _loading = false);
        return;
      }
      // Reconcile duty state against patrol_presence (ACCEPTANCE TEST 8):
      // never blindly trust that a prior session left the patrol ACTIVE.
      final duty = await presenceService.reconcileDutyStatus(profile.patrolId);
      setState(() {
        _session = PatrolSession(
          id: profile.uid,
          name: profile.name,
          email: profile.email,
          role: profile.role,
          patrolId: profile.patrolId,
        );
        _dutyStatus = duty;
        _loading = false;
      });
      _setGpsStreaming(duty == 'AVAILABLE'); // resume one stream if still active
      _watchIncomingDispatches(profile.patrolId);
      return;
    } catch (e) {
      debugPrint('[session] restore error: $e');
    }
    setState(() => _loading = false);
  }

  Future<void> _login(String email, String password) async {
    // PHASE 4 — Supabase login; patrol ID comes from the users table.
    final profile = await PresenceService.login(email, password);
    final sess = PatrolSession(
      id: profile.uid,
      name: profile.name,
      email: profile.email,
      role: profile.role,
      patrolId: profile.patrolId,
    );
    setState(() {
      _session = sess;
      _error = null;
    });
    unawaited(FirestoreService.registerFcmToken(sess.patrolId));
    _watchIncomingDispatches(sess.patrolId);
  }

  Future<void> _logout() async {
    // Spec §3/§4: going offline on logout — never leave a ghost ACTIVE patrol.
    if (_session != null) {
      try {
        await presenceService.goOffline(_session!.patrolId);
      } catch (_) {}
    }
    _gpsTimer?.cancel();
    _gpsTimer = null;
    await PresenceService.signOut();
    setState(() {
      _session = null;
      _dutyStatus = 'OFFLINE';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4))));
    }
    if (_session == null) {
      return LoginScreen(
        onLogin: (e, p) async {
          try {
            await _login(e, p);
          } catch (err) {
            setState(() => _error = err.toString().replaceAll('Exception: ', ''));
          }
        },
        error: _error,
      );
    }

    final sess = _session!;

    // In-app update notification — checks Firebase once per launch and
    // notifies the officer when a newer version is published.
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final u = await AppUpdateService.check();
          if (u['available'] == true && mounted) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF111827),
                title: const Text('🔄 Update Available'),
                content: Text(
                    "Version ${u['version']} is available."
                    "${(u['notes'] as String).isNotEmpty ? "\n\n${u['notes']}" : ''}\n\nOpen Settings → App Update to install."),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() => _tab = 4); // jump to Settings tab
                    },
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF06B6D4)),
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            );
          }
        } catch (_) {}
      });
    }

    final tabs = [
      DashboardTab(
        session: sess,
        dutyStatus: _dutyStatus,
        onStatusChange: (s) { _changeDutyStatus(s); },
        onOpenAssignments: (dispatchId) => setState(() { _pendingDispatchFromNotification = dispatchId; _tab = 1; }),
      ),
      AssignmentsTab(session: sess, focusDispatchId: _pendingDispatchFromNotification),
      CameraSearchTab(session: sess),
      ProfileTab(session: sess, onLogout: _logout),
      const SettingsTab(),
    ];

    return Scaffold(
      body: tabs[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: const Color(0xFF0D1117),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.assignment_outlined), selectedIcon: Icon(Icons.assignment), label: 'Tasks'),
          NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: 'Cameras'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ============================================================================
// Login Screen
// ============================================================================

class LoginScreen extends StatefulWidget {
  final Future<void> Function(String, String) onLogin;
  final String? error;
  const LoginScreen({super.key, required this.onLogin, this.error});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B0F19), Color(0xFF0C1A2E), Color(0xFF0B0F19)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFF111827).withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1F2937)),
                boxShadow: [BoxShadow(color: const Color(0xFF06B6D4).withOpacity(0.08), blurRadius: 40, spreadRadius: 2)],
              ),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset('assets/logo.png', width: 96, height: 96, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 96, height: 96,
                        decoration: BoxDecoration(color: const Color(0xFF0891B2), borderRadius: BorderRadius.circular(18)),
                        child: const Icon(Icons.local_police, color: Colors.white, size: 48),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('MakkalAran Patrol', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Police & Rapid Response Unit', style: TextStyle(color: Color(0xFF06B6D4), fontSize: 13)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Officer Email',
                      prefixIcon: Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passCtrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (widget.error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.withOpacity(0.3))),
                      child: Row(children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(widget.error!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.login),
                      label: Text(_loading ? 'Signing in…' : 'Sign In to Duty'),
                      onPressed: _loading ? null : () async {
                        setState(() => _loading = true);
                        await widget.onLogin(_emailCtrl.text.trim(), _passCtrl.text);
                        if (mounted) setState(() => _loading = false);
                      },
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


int _dispatchTimeMs(Map<String, dynamic> d) {
  final v = d['assignedAt'] ?? d['updatedAt'] ?? d['createdAt'];
  if (v is Timestamp) return v.millisecondsSinceEpoch;
  if (v is String) return DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0;
  return 0;
}

bool _isActiveDispatchStatus(String? status) {
  return !['RESOLVED', 'CLOSED', 'CANCELLED', 'DECLINED', 'TIMEOUT', 'EXPIRED'].contains(status);
}

// ============================================================================
// Dashboard Tab
// ============================================================================

class DashboardTab extends StatefulWidget {
  final PatrolSession session;
  final String dutyStatus;
  final void Function(String) onStatusChange;
  final void Function(String dispatchId) onOpenAssignments;
  const DashboardTab({
    super.key,
    required this.session,
    required this.dutyStatus,
    required this.onStatusChange,
    required this.onOpenAssignments,
  });
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final dutyStatus = widget.dutyStatus;
    final onStatusChange = widget.onStatusChange;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              CircleAvatar(backgroundColor: const Color(0xFF0891B2), radius: 22, child: const Icon(Icons.local_police, color: Colors.white)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Welcome, ${session.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text(session.patrolId, style: const TextStyle(color: Color(0xFF06B6D4), fontSize: 13)),
              ])),
              _StatusBadge(dutyStatus),
            ],
          ),
          const SizedBox(height: 16),

          // ── GO ACTIVE BUTTON (spec §3) ─────────────────────────────────────
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(
                    dutyStatus == 'AVAILABLE' ? Icons.shield : Icons.shield_outlined,
                    color: dutyStatus == 'AVAILABLE' ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text('PATROL STATUS', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.2, fontSize: 12, color: Colors.grey.shade400)),
                ]),
                const SizedBox(height: 10),
                Text(
                  dutyStatus == 'AVAILABLE'
                      ? '🟢 ACTIVE — Available for Dispatch'
                      : '● OFFLINE — Not visible to Control Room',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: dutyStatus == 'AVAILABLE' ? Colors.greenAccent : Colors.grey,
                  ),
                ),
                if (dutyStatus == 'AVAILABLE')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Streaming GPS — auto-dispatch eligible', style: TextStyle(color: Color(0xFF06B6D4), fontSize: 11)),
                  ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: dutyStatus == 'AVAILABLE' ? Colors.red.shade900 : Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: Icon(dutyStatus == 'AVAILABLE' ? Icons.power_settings_new : Icons.bolt, size: 20),
                  label: Text(
                    dutyStatus == 'AVAILABLE' ? 'GO OFFLINE' : 'GO ACTIVE',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 1.5),
                  ),
                  onPressed: () => onStatusChange(dutyStatus == 'AVAILABLE' ? 'OFFLINE' : 'AVAILABLE'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // ── INCOMING DISPATCH ALERT BANNER ────────────────────────────────
          StreamBuilder<FSnap>(
            stream: FirestoreService.dispatchesStream(session.patrolId),
            builder: (ctx, snap) {
              if (!snap.hasData || snap.data!.docs.isEmpty) return const SizedBox.shrink();
              final pending = snap.data!.docs.where((doc) {
                final d = doc.data() as Map<String, dynamic>;
                return d['status'] == 'SENT';
              }).toList();
              if (pending.isEmpty) return const SizedBox.shrink();
              pending.sort((a, b) => _dispatchTimeMs(b.data() as Map<String, dynamic>).compareTo(_dispatchTimeMs(a.data() as Map<String, dynamic>)));
              final doc = pending.first;
              final d = doc.data() as Map<String, dynamic>;
              final dispatchId = (d['dispatchId'] ?? doc.id).toString();
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.red.withOpacity(0.8), width: 2),
                  color: Colors.red.withOpacity(0.06),
                  boxShadow: [BoxShadow(color: Colors.red.withOpacity(0.2), blurRadius: 12)],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.emergency, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('🚨 INCOMING DISPATCH — Go to Assignments tab', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13))),
                  ]),
                  const SizedBox(height: 8),
                  Text(d['notes'] ?? 'Auto-dispatched emergency', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: FilledButton.icon(
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Go to Assignments', style: TextStyle(fontSize: 12)),
                      onPressed: () => widget.onOpenAssignments(dispatchId),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    )),
                  ]),
                ]),
              );
            },
          ),

          // ── STATS GRID ────────────────────────────────────────────────────
          StreamBuilder<FSnap>(
            stream: FirestoreService.incidentsStream(),
            builder: (ctx, snap) {
              final count = snap.data?.docs.length ?? 0;
              final active = snap.data?.docs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                return data['status'] == 'UNVERIFIED' || data['status'] == 'DISPATCHED';
              }).length ?? 0;
              return Row(children: [
                Expanded(child: _StatCard(label: 'Live Incidents', value: '$count', icon: Icons.warning_amber_rounded, color: Colors.orange)),
                const SizedBox(width: 12),
                Expanded(child: _StatCard(label: 'Needs Action', value: '$active', icon: Icons.notification_important, color: Colors.red)),
              ]);
            },
          ),
          const SizedBox(height: 12),
          StreamBuilder<FSnap>(
            stream: FirestoreService.dispatchesStream(session.patrolId),
            builder: (ctx, snap) {
              final count = snap.data?.docs.length ?? 0;
              return Row(children: [
                Expanded(child: _StatCard(label: 'My Dispatches', value: '$count', icon: Icons.directions_car, color: Colors.blue)),
                const SizedBox(width: 12),
                Expanded(child: _StatCard(label: 'Zone', value: 'A-KR', icon: Icons.map_outlined, color: Colors.purple)),
              ]);
            },
          ),
          const SizedBox(height: 20),

          const Text('Live Incidents Feed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),

          StreamBuilder<FSnap>(
            stream: FirestoreService.incidentsStream(),
            builder: (ctx, snap) {
              if (!snap.hasData || snap.data!.docs.isEmpty) {
                return _Card(child: const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('All clear — no incidents.', style: TextStyle(color: Colors.grey)))));
              }
              return Column(
                children: snap.data!.docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final risk = d['riskLevel'] ?? 'LOW';
                  final color = risk == 'HIGH' ? Colors.red : risk == 'MEDIUM' ? Colors.orange : Colors.green;
                  return _Card(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(backgroundColor: color.withOpacity(0.15), child: Icon(Icons.warning_amber, color: color, size: 20)),
                      title: Text(d['title'] ?? d['eventType'] ?? 'Incident', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text('${d['incidentId'] ?? doc.id} · ${d['status'] ?? ''}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.3))),
                        child: Text(risk, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
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


// ============================================================================
// Assignments Tab — with Accept/Decline for auto-dispatched incidents
// ============================================================================

class _SettingsTabState extends State<SettingsTab> {
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
      if (mounted) setState(() { _update = u; _status = ''; });
    } catch (e) {
      if (mounted) setState(() => _status = 'Check failed — check internet');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    final url = (_update?['url'] ?? '') as String;
    if (url.isEmpty) return;
    setState(() { _status = 'Downloading update…'; _progress = 0; });
    try {
      await AppUpdateService.downloadAndInstall(
        url,
        apkFileName: 'MakkalAran-Patrol-update.apk',
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
      );
      if (mounted) {
        setState(() {
          _status = 'If prompted, allow "Install unknown apps" for this app.';
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
    final update = _update;
    final available = update?['available'] == true;
    final latest = (update?['version'] as String?) ?? '';
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        title: const Text('⚙️ Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── About ──
          Card(
            color: const Color(0xFF111827),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset('assets/logo.png', width: 44, height: 44, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.local_police, color: Color(0xFF06B6D4), size: 40)),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(AppMeta.appName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                        SizedBox(height: 2),
                        Text('Police & Rapid Response Unit', style: TextStyle(color: Colors.grey, fontSize: 12)),
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
          // ── Updates ──
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
                  _row('Latest version', latest.isEmpty ? '—' : latest),
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
                        "🎉 New version $latest available!"
                        "${(update?['notes'] as String?)?.isNotEmpty == true ? "\n${update!['notes']}" : ''}",
                        style: const TextStyle(color: Colors.greenAccent),
                      ),
                    )
                  else if (!_checking && update != null)
                    const Text('✅ You are on the latest version.', style: TextStyle(color: Colors.grey)),
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
          const Center(child: Text('© 2026 Creative Hub Developers', style: TextStyle(color: Colors.grey, fontSize: 11))),
        ],
      ),
    );
  }
}

class AssignmentsTab extends StatefulWidget {
  final PatrolSession session;
  final String? focusDispatchId;
  const AssignmentsTab({super.key, required this.session, this.focusDispatchId});
  @override
  State<AssignmentsTab> createState() => _AssignmentsTabState();
}

class _AssignmentsTabState extends State<AssignmentsTab> {
  // Countdown timers per dispatch { dispatchId -> secondsRemaining }
  final Map<String, int> _countdowns = {};
  final Map<String, Timer> _timers = {};

  @override
  void dispose() {
    for (final t in _timers.values) t.cancel();
    super.dispose();
  }

  void _startCountdown(String dispatchId, int seconds) {
    if (_timers.containsKey(dispatchId)) return; // Already running
    _countdowns[dispatchId] = seconds;
    _timers[dispatchId] = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _countdowns[dispatchId] = (_countdowns[dispatchId] ?? 0) - 1;
        if ((_countdowns[dispatchId] ?? 0) <= 0) {
          t.cancel();
          _timers.remove(dispatchId);
          _countdowns.remove(dispatchId);
          // Auto-timeout: system already handles this server-side
        }
      });
    });
  }


  Future<void> _syncSosForDispatch(
    Map<String, dynamic> dispatch,
    String sosStatus, {
    String? declineReason,
  }) async {
    final incidentId = (dispatch['incidentId'] ?? '').toString();
    final notes = (dispatch['notes'] ?? '').toString();
    final directSosId = (dispatch['sosId'] ?? dispatch['videoSessionId'] ?? '').toString();
    final match = RegExp(r'(SOS-[A-Za-z0-9_-]+)').firstMatch('$incidentId $notes');
    final sosId = directSosId.isNotEmpty ? directSosId : match?.group(1);
    if (sosId == null || sosId.isEmpty) return;
    final patch = <String, dynamic>{
      'status': sosStatus,
      'assigned_patrol_id': widget.session.patrolId,
      'assigned_patrol_name': widget.session.name,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final extra = <String, dynamic>{};
    if (sosStatus == 'RESPONDING') extra['acknowledgedAt'] = nowIso;
    if (declineReason != null) extra['lastDeclineReason'] = declineReason;
    try {
      final client = Supabase.instance.client;
      final row = await client.from('sos_events').select('data').eq('sos_id', sosId).maybeSingle();
      final cur = (row != null && row['data'] is Map) ? (row['data'] as Map).cast<String, dynamic>() : <String, dynamic>{};
      if (extra.isNotEmpty) patch['data'] = {...cur, ...extra};
      await client.from('sos_events').update(patch).eq('sos_id', sosId);
    } catch (e) {
      debugPrint('[supabase] SOS status sync failed (best-effort): $e');
    }
  }

  Future<void> _acceptDispatch(String docId, String dispatchId) async {
    // Cancel countdown
    _timers[dispatchId]?.cancel();
    _timers.remove(dispatchId);
    _countdowns.remove(dispatchId);

    try {
      await FirestoreService.acceptDispatch(dispatchId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('⚠️ Accept failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ));
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Dispatch ACCEPTED — En route!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ));
    }
  }

  /// Spec §14 — decline with a logged reason. The backend records the reason
  /// in the dispatch attempt audit trail and reassigns to the next patrol.
  Future<void> _declineDispatch(String docId, String dispatchId) async {
    final reason = await _pickDeclineReason();
    if (reason == null) return; // cancelled

    // Cancel countdown
    _timers[dispatchId]?.cancel();
    _timers.remove(dispatchId);
    _countdowns.remove(dispatchId);

    try {
      await FirestoreService.declineDispatch(dispatchId, reason);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('⚠️ Decline failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ));
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('❌ Declined ($reason) — System reassigning to next patrol'),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  Future<String?> _pickDeclineReason() {
    const reasons = [
      'Already responding',
      'Vehicle unavailable',
      'Emergency',
      'Outside operational area',
      'Unable to respond',
      'Other',
    ];
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('DECLINE REASON', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2, color: Colors.white70)),
            ),
            ...reasons.map((r) => ListTile(
                  title: Text(r, style: const TextStyle(color: Colors.white)),
                  onTap: () => Navigator.pop(ctx, r),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('Dispatch Assignments', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: StreamBuilder<FSnap>(
              stream: FirestoreService.dispatchesStream(widget.session.patrolId),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4)));
                }
                if (!snap.hasData || snap.data!.docs.isEmpty) {
                  return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('No assignments', style: TextStyle(fontSize: 18)),
                    Text('Auto-dispatches appear here instantly', style: TextStyle(color: Colors.grey)),
                  ]));
                }

                final docs = snap.data!.docs.where((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  return _isActiveDispatchStatus((d['status'] ?? 'SENT').toString());
                }).toList()
                  ..sort((a, b) => _dispatchTimeMs(b.data() as Map<String, dynamic>).compareTo(_dispatchTimeMs(a.data() as Map<String, dynamic>)));
                if (docs.isEmpty) {
                  return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('No active assignments', style: TextStyle(fontSize: 18)),
                    Text('New dispatches appear here instantly', style: TextStyle(color: Colors.grey)),
                  ]));
                }

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: docs.map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    final status = d['status'] ?? 'SENT';
                    final dispatchId = d['dispatchId'] ?? doc.id;
                    final isAutoDispatched = d['autoDispatched'] == true || (d['assignedBy'] == 'AUTO_SYSTEM');
                    final isUrgent = status == 'SENT' && isAutoDispatched;

                    // Start countdown for urgent pending dispatches
                    if (isUrgent) {
                      final deadline = d['declineDeadline'];
                      int secsLeft = 45;
                      if (deadline != null) {
                        final deadlineMs = deadline is Timestamp
                            ? deadline.millisecondsSinceEpoch
                            : DateTime.now().millisecondsSinceEpoch + 45000;
                        secsLeft = ((deadlineMs - DateTime.now().millisecondsSinceEpoch) / 1000).ceil().clamp(0, 45);
                      }
                      if (!_timers.containsKey(dispatchId) && secsLeft > 0) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _startCountdown(dispatchId, secsLeft);
                        });
                      }
                    }

                    return isUrgent
                        ? _UrgentDispatchCard(
                            doc: doc,
                            d: d,
                            dispatchId: dispatchId,
                            countdown: _countdowns[dispatchId] ?? 45,
                            highlighted: widget.focusDispatchId == dispatchId || widget.focusDispatchId == doc.id,
                            onAccept: () => _acceptDispatch(doc.id, dispatchId),
                            onDecline: () => _declineDispatch(doc.id, dispatchId),
                          )
                        : _NormalDispatchCard(
                            doc: doc,
                            d: d,
                            dispatchId: dispatchId,
                            highlighted: widget.focusDispatchId == dispatchId || widget.focusDispatchId == doc.id,
                            onAccept: () => _acceptDispatch(doc.id, dispatchId),
                            onDecline: () => _declineDispatch(doc.id, dispatchId),
                          );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Urgent Dispatch Card: shown for auto-dispatched SENT incidents ─────────
class _UrgentDispatchCard extends StatelessWidget {
  final FDoc doc;
  final Map<String, dynamic> d;
  final String dispatchId;
  final int countdown;
  final bool highlighted;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _UrgentDispatchCard({
    required this.doc,
    required this.d,
    required this.dispatchId,
    required this.countdown,
    this.highlighted = false,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final countdownColor = countdown <= 10 ? Colors.red : countdown <= 20 ? Colors.orange : Colors.amber;
    final distKm = d['distanceKm']?.toString() ?? '—';
    final etaMins = d['estimatedETA']?.toString() ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: highlighted ? Colors.yellowAccent : Colors.red.withOpacity(0.7), width: highlighted ? 3 : 2),
        gradient: LinearGradient(
          colors: [const Color(0xFF1A0A0A), Colors.red.withOpacity(0.08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: Colors.red.withOpacity(0.25), blurRadius: 16, spreadRadius: 2)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.15),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: Row(children: [
            const Icon(Icons.emergency_rounded, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('🚨 URGENT AUTO-DISPATCH', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.5)),
            ),
            // Countdown timer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: countdownColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: countdownColor.withOpacity(0.5)),
              ),
              child: Text('${countdown}s', style: TextStyle(color: countdownColor, fontWeight: FontWeight.bold, fontSize: 16, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
        ),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Incident info
            Text(d['notes'] ?? 'Auto-dispatched incident', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),

            // Live location map (citizen's LIVE SOS position / fixed destination)
            if ((d['destinationLatitude'] != null && d['destinationLongitude'] != null) ||
                d['sosId'] != null ||
                d['videoSessionId'] != null) ...[
              DispatchRouteMap(dispatch: d),
              const SizedBox(height: 12),
            ],

            // Live Audio/Video button
            if ((d['sosId'] ?? d['videoSessionId']) != null) ...[
              FilledButton.icon(
                icon: const Icon(Icons.video_call_outlined, size: 18),
                label: const Text('Open SOS Live Audio/Video'),
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => PatrolSosVideoDialog(
                    sosId: (d['videoSessionId'] ?? d['sosId']).toString(),
                    dispatchId: dispatchId,
                    patrolId: (d['patrolId'] ?? '').toString(),
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFBE123C),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Stats row
            Row(children: [
              _DispatchStat(icon: Icons.pin_drop_outlined, label: 'Distance', value: '$distKm km', color: Colors.cyan),
              const SizedBox(width: 16),
              _DispatchStat(icon: Icons.timer_outlined, label: 'ETA', value: '$etaMins min', color: Colors.green),
              const SizedBox(width: 16),
              _DispatchStat(icon: Icons.assignment_outlined, label: 'ID', value: dispatchId.length > 12 ? dispatchId.substring(dispatchId.length - 8) : dispatchId, color: Colors.purple),
            ]),
            const SizedBox(height: 16),

            // Accept / Decline
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('ACCEPT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1)),
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
                  label: const Text('DECLINE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1, color: Colors.red)),
                  onPressed: onDecline,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

// ── Normal dispatch card: for accepted / en-route / resolved dispatches ────
class _NormalDispatchCard extends StatelessWidget {
  final FDoc doc;
  final Map<String, dynamic> d;
  final String dispatchId;
  final bool highlighted;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _NormalDispatchCard({required this.doc, required this.d, required this.dispatchId, this.highlighted = false, required this.onAccept, required this.onDecline});

  @override
  Widget build(BuildContext context) {
    final status = d['status'] ?? 'SENT';
    final isAutoDispatched = d['autoDispatched'] == true || d['assignedBy'] == 'AUTO_SYSTEM';
    final statusColor = status == 'ACCEPTED' || status == 'RESOLVED' ? Colors.green
        : status == 'EN_ROUTE' ? Colors.blue
        : status == 'ARRIVED' || status == 'ASSESSING' ? Colors.purple
        : status == 'CANCELLED' || status == 'DECLINED' ? Colors.red
        : Colors.orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: highlighted ? Border.all(color: Colors.yellowAccent, width: 2) : null,
      ),
      child: _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d['incidentId'] ?? dispatchId, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            if (isAutoDispatched)
              const Text('🤖 Auto-dispatched by system', style: TextStyle(color: Color(0xFF06B6D4), fontSize: 11)),
          ])),
          _StatusBadge(status),
        ]),
        const SizedBox(height: 8),
        Text(d['notes'] ?? 'Respond to dispatched location', style: const TextStyle(color: Colors.grey, fontSize: 13)),
        if (status == 'SENT') ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('ACCEPT'),
                onPressed: onAccept,
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
                label: const Text('DECLINE', style: TextStyle(color: Colors.red)),
                onPressed: onDecline,
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
              ),
            ),
          ]),
        ],
        if (d['distanceKm'] != null || d['estimatedETA'] != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (d['distanceKm'] != null) ...[
              const Icon(Icons.pin_drop, size: 13, color: Colors.cyan),
              const SizedBox(width: 4),
              Text('${d['distanceKm']} km', style: const TextStyle(color: Colors.cyan, fontSize: 12)),
              const SizedBox(width: 16),
            ],
            if (d['estimatedETA'] != null) ...[
              const Icon(Icons.timer, size: 13, color: Colors.green),
              const SizedBox(width: 4),
              Text('ETA: ${d['estimatedETA']} min', style: const TextStyle(color: Colors.green, fontSize: 12)),
            ],
          ]),
        ],

        if ((d['destinationLatitude'] != null && d['destinationLongitude'] != null) || d['sosId'] != null) ...[
          const SizedBox(height: 12),
          DispatchRouteMap(dispatch: d),
        ],

        if ((d['sosId'] ?? d['videoSessionId']) != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.video_call_outlined, size: 18),
            label: const Text('Open SOS Live Audio/Video'),
            onPressed: () => showDialog(
              context: context,
              builder: (_) => PatrolSosVideoDialog(
                sosId: (d['videoSessionId'] ?? d['sosId']).toString(),
                dispatchId: dispatchId,
                patrolId: (d['patrolId'] ?? '').toString(),
              ),
            ),
          ),
        ],

        // Status update chips (for accepted dispatches only)
        if (status == 'ACCEPTED' || status == 'EN_ROUTE' || status == 'ARRIVED') ...[
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF1F2937)),
          const SizedBox(height: 8),
          const Text('Update Status:', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in ['EN_ROUTE', 'ARRIVED', 'ASSESSING', 'RESOLVED'])
              ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 11)),
                backgroundColor: status == s ? const Color(0xFF0891B2) : null,
                onPressed: () => Supabase.instance.client.from('dispatches').update({
                  'status': s,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                }).eq('dispatch_id', doc.id),
              ),
          ]),
        ],
        ]),
      ),
    );
  }
}



// ── FULL-SCREEN INCOMING DISPATCH ALERT (§13) ───────────────────────────
// Persistent, loud, non-dismissable alert with an embedded live route map,
// Accept / Decline / Snooze actions and a direct SOS live video button.
class IncomingDispatchDialog extends StatelessWidget {
  final String dispatchId;
  final Map<String, dynamic> dispatch;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;
  final VoidCallback onSnooze;

  const IncomingDispatchDialog({
    super.key,
    required this.dispatchId,
    required this.dispatch,
    required this.onAccept,
    required this.onDecline,
    required this.onSnooze,
  });

  @override
  Widget build(BuildContext context) {
    final d = dispatch;
    final sosId = (d['sosId'] ?? d['videoSessionId'] ?? '').toString();
    return Dialog(
      backgroundColor: const Color(0xFF111827),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.red.withOpacity(0.8), width: 2),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.emergency, color: Colors.red.shade500, size: 30),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '🚨 INCOMING AUTO-DISPATCH',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17, letterSpacing: 0.5),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              d['notes'] ?? 'Auto-dispatched emergency — please respond.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (d['distanceKm'] != null || d['estimatedETA'] != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                if (d['distanceKm'] != null) ...[
                  const Icon(Icons.pin_drop, color: Colors.cyan, size: 14),
                  const SizedBox(width: 4),
                  Text('${d['distanceKm']} km', style: const TextStyle(color: Colors.cyan, fontSize: 12)),
                  const SizedBox(width: 14),
                ],
                if (d['estimatedETA'] != null) ...[
                  const Icon(Icons.timer, color: Colors.green, size: 14),
                  const SizedBox(width: 4),
                  Text('ETA ${d['estimatedETA']} min', style: const TextStyle(color: Colors.green, fontSize: 12)),
                ],
              ]),
            ],
            const SizedBox(height: 12),
            // Embedded live route+satellite map.
            DispatchRouteMap(dispatch: d),
            const SizedBox(height: 14),
            if (sosId.isNotEmpty) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.videocam, size: 18),
                  label: const Text('OPEN SOS LIVE VIDEO'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    showDialog(
                      context: context,
                      builder: (_) => PatrolSosVideoDialog(
                        sosId: sosId,
                        dispatchId: dispatchId,
                        patrolId: (d['patrolId'] ?? '').toString(),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFBE123C)),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('ACCEPT'),
                  onPressed: () => onAccept(),
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
                  label: const Text('DECLINE', style: TextStyle(color: Colors.red)),
                  onPressed: () => onDecline(),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: onSnooze,
                child: const Text('VIEW IN TASKS (snooze)', style: TextStyle(color: Colors.white54)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DispatchRouteMap extends StatefulWidget {
  final Map<String, dynamic> dispatch;
  const DispatchRouteMap({super.key, required this.dispatch});

  @override
  State<DispatchRouteMap> createState() => _DispatchRouteMapState();
}
class _DispatchRouteMapState extends State<DispatchRouteMap> {
  // Live citizen position streamed from the Public app → Supabase sos_events.
  LatLng? _liveSos;
  double? _liveAccuracy;
  StreamSubscription<List<Map<String, dynamic>>>? _liveSub;

  // Satellite / road map toggle.
  MapType _mapType = MapType.normal;

  // Road route (OSRM public API — no API key needed).
  List<LatLng> _routePoints = [];
  List<String> _routeSteps = [];
  double? _routeKm;
  double? _routeMinutes;
  bool _routing = false;
  String? _routeError;
  LatLng? _lastRouteFrom;
  LatLng? _lastRouteTo;

  GoogleMapController? _mapController;

  String? get _sosId {
    final s = (widget.dispatch['sosId'] ??
            widget.dispatch['videoSessionId'] ??
            '')
        .toString();
    return s.isEmpty ? null : s;
  }

  @override
  void initState() {
    super.initState();
    final sosId = _sosId;
    if (sosId != null) {
      _liveSub = Supabase.instance.client
          .from('sos_events')
          .stream(primaryKey: ['sos_id'])
          .eq('sos_id', sosId)
          .listen((rows) {
        if (rows.isEmpty || !mounted) return;
        final data = rows.first;
        final extra =
            (data['data'] is Map) ? (data['data'] as Map).cast<String, dynamic>() : <String, dynamic>{};
        final lat = ((data['latitude'] ?? extra['lat'] ?? extra['latitude']) as num?)?.toDouble();
        final lng = ((data['longitude'] ?? extra['lng'] ?? extra['longitude']) as num?)?.toDouble();
        if (lat == null || lng == null) return;
        setState(() {
          _liveSos = LatLng(lat, lng);
          _liveAccuracy = (extra['accuracy'] as num?)?.toDouble();
        });
      });
    }
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  /// Straight-line (haversine) distance between two coordinates (km).
  double _kmBetween(LatLng a, LatLng b) {
    const R = 6371.0;
    const degToRad = math.pi / 180.0;
    final dLat = (b.latitude - a.latitude) * degToRad;
    final dLon = (b.longitude - a.longitude) * degToRad;
    final lat1 = a.latitude * degToRad;
    final lat2 = b.latitude * degToRad;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.sin(dLon / 2) * math.sin(dLon / 2) * math.cos(lat1) * math.cos(lat2);
    return R * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }
/// Fetch a real road route (polyline + steps) from the free OSRM API so the
  /// patrol navigates the actual road network instead of a straight line.
  Future<void> _fetchRoute(LatLng from, LatLng to) async {
    if (_routing) return;
    // Skip refetch if both endpoints barely moved since the last route.
    if (_lastRouteFrom != null &&
        _lastRouteTo != null &&
        _routePoints.isNotEmpty &&
        _kmBetween(_lastRouteFrom!, from) < 0.15 &&
        _kmBetween(_lastRouteTo!, to) < 0.15) {
      setState(() {
        _routeKm = _kmBetween(from, to);
        _routeMinutes = _routeKm! / 0.6; // 36 km/h urban average
      });
      return;
    }
    _routing = true;
    setState(() => _routeError = null);
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${from.longitude.toStringAsFixed(6)},${from.latitude.toStringAsFixed(6)};'
        '${to.longitude.toStringAsFixed(6)},${to.latitude.toStringAsFixed(6)}'
        '?overview=full&steps=true&geometries=geojson',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) throw Exception('OSRM HTTP ${res.statusCode}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = (body['routes'] as List?) ?? [];
      if (routes.isEmpty) throw Exception('no route');
      final route = routes.first as Map<String, dynamic>;
      final geo = route['geometry'] as Map<String, dynamic>;
      final coords = (geo['coordinates'] as List)
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      final legs = (route['legs'] as List?) ?? [];
      final steps = <String>[];
      for (final leg in legs) {
        for (final s in ((leg as Map<String, dynamic>)['steps'] as List?) ?? []) {
          final man = (s as Map<String, dynamic>)['maneuver'] as Map<String, dynamic>?;
          final mod = (s['modifier'] ?? '').toString().replaceAll('_', ' ').toUpperCase();
          final ins = (man?['instruction'] ?? '').toString();
          final name = (s['name'] ?? '').toString();
          final text = ins.isEmpty
              ? '${mod.isEmpty ? 'Go' : mod} on ${name.isEmpty ? 'road' : name}'
              : ins;
          if (text.isNotEmpty && !steps.contains(text)) steps.add(text);
        }
      }
      if (!mounted) return;
      setState(() {
        _routePoints = coords;
        _routeSteps = steps.take(12).toList();
        _lastRouteFrom = from;
        _lastRouteTo = to;
        _routeKm = ((route['distance'] as num? ?? 0.0) / 1000.0).toDouble();
        _routeMinutes = ((route['duration'] as num? ?? 0.0) / 60.0).toDouble();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _routePoints = [];
          _routeSteps = [];
          _routeError = 'Road route unavailable — using straight line';
        });
      }
    } finally {
      _routing = false;
    }
  }

  Future<void> _fitBounds(LatLng a, LatLng b) async {
    try {
      final sw = LatLng(
        a.latitude < b.latitude ? a.latitude : b.latitude,
        a.longitude < b.longitude ? a.longitude : b.longitude,
      );
      final ne = LatLng(
        a.latitude > b.latitude ? a.latitude : b.latitude,
        a.longitude > b.longitude ? a.longitude : b.longitude,
      );
      await _mapController?.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: sw, northeast: ne),
        70,
      ));
    } catch (_) {}
  }
@override
  Widget build(BuildContext context) {
    final destLat = (widget.dispatch['destinationLatitude'] as num?)?.toDouble();
    final destLng = (widget.dispatch['destinationLongitude'] as num?)?.toDouble();
    final patrolId = (widget.dispatch['patrolId'] ?? '').toString();
    final hasStaticDest = destLat != null && destLng != null;
    if (patrolId.isEmpty || (!hasStaticDest && _liveSos == null)) {
      return const Text(
        'Route map will appear when SOS location is available.',
        style: TextStyle(color: Colors.grey, fontSize: 12),
      );
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('patrol_presence')
          .stream(primaryKey: ['patrol_id'])
          .eq('patrol_id', patrolId),
      builder: (context, snap) {
        final p = (snap.data != null && snap.data!.isNotEmpty) ? snap.data!.first : null;
        final lat = (p?['latitude'] as num?)?.toDouble();
        final lng = (p?['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) {
          return const SizedBox(
            height: 120,
            child: Center(
              child: Text('Waiting for patrol GPS...', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        final patrol = LatLng(lat, lng);
        final sos = _liveSos ?? (hasStaticDest ? LatLng(destLat!, destLng!) : null);
        if (sos == null) {
          return const SizedBox(
            height: 120,
            child: Center(
              child: Text('Waiting for SOS location...', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fetchRoute(patrol, sos);
        });
        final liveKm = _routeKm ?? _kmBetween(patrol, sos);
        final liveMin = _routeMinutes ?? liveKm / 0.6;
        final routePolyline = _routePoints.isNotEmpty ? _routePoints : <LatLng>[patrol, sos];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(children: [
                  GoogleMap(
                    initialCameraPosition: CameraPosition(target: patrol, zoom: 14),
                    mapType: _mapType,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: true,
                    onMapCreated: (c) => _mapController = c,
                    markers: {
                      Marker(
                        markerId: const MarkerId('patrol'),
                        position: patrol,
                        infoWindow: const InfoWindow(title: 'PATROL (ME)'),
                        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                      ),
                      Marker(
                        markerId: const MarkerId('sos'),
                        position: sos,
                        infoWindow: InfoWindow(
                          title: _liveSos != null ? 'Citizen (LIVE)' : 'SOS destination',
                          snippet: '${liveKm.toStringAsFixed(2)} km',
                        ),
                        icon: _liveSos != null
                            ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed)
                            : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                      ),
                    },
                    polylines: {
                      Polyline(
                        polylineId: const PolylineId('patrol_to_sos'),
                        points: routePolyline,
                        width: 5,
                        color: const Color(0xFF22D3EE),
                      ),
                    },
                  ),
Positioned(
                    top: 10,
                    right: 10,
                    child: Material(
                      color: const Color(0xCC111827),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          setState(() {
                            _mapType = _mapType == MapType.satellite ? MapType.normal : MapType.satellite;
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(_mapType == MapType.satellite ? Icons.map : Icons.satellite_alt, color: Colors.cyanAccent, size: 16),
                            const SizedBox(width: 4),
                            Text(
                              _mapType == MapType.satellite ? 'ROAD' : 'SATELLITE',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Material(
                      color: const Color(0xCC111827),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _fitBounds(patrol, sos),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Icon(Icons.center_focus_strong, color: Colors.cyanAccent, size: 18),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
const SizedBox(height: 8),
            Row(children: [
              if (_liveSos != null) ...[
                const Icon(Icons.fiber_manual_record, color: Colors.red, size: 13),
                const SizedBox(width: 4),
                const Text('LIVE', style: TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.bold)),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SOS: ${sos.latitude.toStringAsFixed(5)}, ${sos.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            if (_liveAccuracy != null)
              Text(
                'Accuracy ±${_liveAccuracy!.toStringAsFixed(0)} m · ${_liveSos != null ? 'citizen is moving live' : 'fixed destination'}',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.route, color: Colors.cyanAccent, size: 14),
              const SizedBox(width: 4),
              Text(
                '${liveKm.toStringAsFixed(1)} km · ETA ~${liveMin.round()} min',
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              if (_routeError != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _routeError!,
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ]),
if (_routeSteps.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1B24),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.cyan.withOpacity(0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('DIRECTIONS', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  for (var i = 0; i < _routeSteps.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${i + 1}. ', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                        Expanded(child: Text(_routeSteps[i], style: const TextStyle(color: Colors.white70, fontSize: 11))),
                      ]),
                    ),
                ]),
              ),
            ],
          ],
        );
      },
    );
  }
}



class PatrolSosVideoDialog extends StatefulWidget {
  final String sosId;
  final String dispatchId;
  final String patrolId;

  const PatrolSosVideoDialog({
    super.key,
    required this.sosId,
    required this.dispatchId,
    required this.patrolId,
  });

  @override
  State<PatrolSosVideoDialog> createState() => _PatrolSosVideoDialogState();
}

class _PatrolSosVideoDialogState extends State<PatrolSosVideoDialog> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidateSub;
  Timer? _pingTimer;
  String _state = 'WAITING';
  bool _answerApplied = false;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize().then((_) => _connect());
  }

/// Loads admin-configured TURN relay from Firestore `settings/webrtc` so
  /// SOS live audio/video can traverse carrier-grade NAT between two phones.
  /// Falls back to STUN-only if no TURN relay is configured.
  Future<List<Map<String, dynamic>>> _loadIceServers() async {
    const stunOnly = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('settings')
          .doc('webrtc')
          .get()
          .timeout(const Duration(seconds: 6));
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
  Future<void> _connect() async {
    final viewerId = 'PATROL_${widget.patrolId}_${widget.dispatchId}';
    final viewerRef = FirebaseFirestore.instance
        .collection('webrtc_sessions')
        .doc(widget.sosId)
        .collection('viewers')
        .doc(viewerId);
    await viewerRef.set({
      'viewerId': viewerId,
      'viewerType': 'PATROL',
      'patrolId': widget.patrolId,
      'dispatchId': widget.dispatchId,
      'requestOffer': true,
      'status': 'WAITING_FOR_OFFER',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Robustness: re-assert requestOffer so the Public app's offer listener
    // re-evaluates this viewer even if it attached after we wrote the doc.
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_answerApplied) return;
      viewerRef.set({
        'requestOffer': true,
        'status': 'WAITING_FOR_OFFER',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });

    // Fallback: some flows place the SDP offer directly on the session doc.
    _sessionDocSub = FirebaseFirestore.instance
        .collection('webrtc_sessions')
        .doc(widget.sosId)
        .snapshots()
        .listen((snap) {
      if (_answerApplied) return;
      final offer = snap.data()?['offer'];
      if (offer is Map) {
        viewerRef.set({'offer': offer, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
    });

    _sessionSub = viewerRef.snapshots().listen((snap) async {
      if (_answerApplied) return;
      final data = snap.data();
      final offer = data?['offer'];
      if (offer is! Map) return;
      _answerApplied = true;
      if (mounted) setState(() => _state = 'CONNECTING');
      final pc = await createPeerConnection({
        'iceServers': await _loadIceServers(),
      });
      _pc = pc;
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams.first;
          if (mounted) setState(() => _state = 'LIVE');
        }
      };
      pc.onConnectionState = (state) {
        if (mounted) setState(() => _state = state.toString().split('.').last.toUpperCase());
        viewerRef.set({'connectionState': state.toString(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      };
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        viewerRef.collection('calleeCandidates').add(candidate.toMap());
      };
      await pc.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?));
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await viewerRef.set({
        'answer': answer.toMap(),
        'answeredAt': FieldValue.serverTimestamp(),
        'status': 'ANSWERED',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('sos_events').doc(widget.sosId).collection('timeline').add({
        'type': 'PATROL_VIDEO_OPENED',
        'message': 'Patrol opened SOS live audio/video stream',
        'dispatchId': widget.dispatchId,
        'patrolId': widget.patrolId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      _candidateSub = viewerRef.collection('callerCandidates').snapshots().listen((candidateSnap) {
        for (final change in candidateSnap.docChanges) {
          if (change.type != DocumentChangeType.added) continue;
          final c = change.doc.data();
          if (c == null) continue;
          pc.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?));
        }
      });
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _sessionSub?.cancel();
    _sessionDocSub?.cancel();
    _candidateSub?.cancel();
    _pc?.close();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF111827),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Expanded(child: Text('SOS Live Audio/Video', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            _StatusBadge(_state),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 260,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Audio plays with the live stream when the citizen device grants microphone permission.', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ── Stat widget used in UrgentDispatchCard ────────────────────────────────
class _DispatchStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _DispatchStat({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
      ]),
    ),
  );
}


// ============================================================================
// Camera Search Tab  ← New Feature
// ============================================================================

class CameraSearchTab extends StatefulWidget {
  final PatrolSession session;
  const CameraSearchTab({super.key, required this.session});
  @override
  State<CameraSearchTab> createState() => _CameraSearchTabState();
}

class _CameraSearchTabState extends State<CameraSearchTab> with SingleTickerProviderStateMixin {
  late TabController _innerTab;
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _filter = 'All';
  List<Map<String, dynamic>> _allCameras = [];
  bool _camsLoaded = false;
  StreamSubscription? _camSub;

  @override
  void initState() {
    super.initState();
    _innerTab = TabController(length: 2, vsync: this);
    _camSub = FirestoreService.cameraStream().listen((snap) {
      setState(() {
        _allCameras = snap.docs.map((d) => {'id': d.id, ...d.data() as Map<String, dynamic>}).toList();
        _camsLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _camSub?.cancel();
    _innerTab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.toLowerCase();
    return _allCameras.where((c) {
      final name = (c['name'] ?? '').toLowerCase();
      final city = (c['city'] ?? c['zoneName'] ?? '').toLowerCase();
      final street = (c['street'] ?? c['address'] ?? '').toLowerCase();
      final zone = (c['zoneId'] ?? '').toLowerCase();
      final matches = q.isEmpty || name.contains(q) || city.contains(q) || street.contains(q) || zone.contains(q);
      if (!matches) return false;
      if (_filter == 'Online') return c['status'] == 'ONLINE';
      if (_filter == 'Offline') return c['status'] != 'ONLINE';
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              const Icon(Icons.videocam, color: Color(0xFF06B6D4)),
              const SizedBox(width: 10),
              const Expanded(child: Text('MakkalAran Cameras', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              Text('${_allCameras.length} cams', style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),

          // Tab bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(12)),
              child: TabBar(
                controller: _innerTab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(color: const Color(0xFF0891B2), borderRadius: BorderRadius.circular(10)),
                tabs: const [Tab(text: '🔍 Search Cameras'), Tab(text: '📋 My Requests')],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: TabBarView(
              controller: _innerTab,
              children: [
                _SearchCameraView(
                  searchCtrl: _searchCtrl,
                  query: _query,
                  filter: _filter,
                  filtered: _filtered,
                  loaded: _camsLoaded,
                  session: widget.session,
                  onQuery: (v) => setState(() => _query = v),
                  onFilter: (f) => setState(() => _filter = f),
                ),
                _MyRequestsView(session: widget.session),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -- Camera search results view
class _SearchCameraView extends StatelessWidget {
  final TextEditingController searchCtrl;
  final String query;
  final String filter;
  final List<Map<String, dynamic>> filtered;
  final bool loaded;
  final PatrolSession session;
  final void Function(String) onQuery;
  final void Function(String) onFilter;

  const _SearchCameraView({
    required this.searchCtrl,
    required this.query,
    required this.filter,
    required this.filtered,
    required this.loaded,
    required this.session,
    required this.onQuery,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: searchCtrl,
            onChanged: onQuery,
            decoration: InputDecoration(
              hintText: 'Search by city, street or camera name…',
              hintStyle: const TextStyle(fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: Color(0xFF06B6D4)),
              suffixIcon: query.isNotEmpty ? IconButton(icon: const Icon(Icons.clear), onPressed: () { searchCtrl.clear(); onQuery(''); }) : null,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: const Color(0xFF111827),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Filter chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final f in ['All', 'Online', 'Offline'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(f, style: const TextStyle(fontSize: 12)),
                  selected: filter == f,
                  onSelected: (_) => onFilter(f),
                  selectedColor: const Color(0xFF0891B2),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: !loaded
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4)))
              : filtered.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.videocam_off_outlined, size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(query.isEmpty ? 'No cameras found' : 'No results for "$query"', style: const TextStyle(color: Colors.grey)),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final cam = filtered[i];
                        return _CameraCard(cam: cam, session: session);
                      },
                    ),
        ),
      ],
    );
  }
}

// -- Individual camera card
class _CameraCard extends StatelessWidget {
  final Map<String, dynamic> cam;
  final PatrolSession session;
  const _CameraCard({required this.cam, required this.session});

  @override
  Widget build(BuildContext context) {
    final online = cam['status'] == 'ONLINE';
    final city = cam['city'] ?? cam['zoneName'] ?? 'Unknown City';
    final street = cam['street'] ?? cam['address'] ?? 'Unknown Street';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: online ? const Color(0xFF06B6D4).withOpacity(0.25) : const Color(0xFF1F2937)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: online ? const Color(0xFF06B6D4).withOpacity(0.15) : Colors.grey.withOpacity(0.1),
            child: Icon(Icons.videocam, size: 18, color: online ? const Color(0xFF06B6D4) : Colors.grey),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cam['name'] ?? cam['cameraId'] ?? 'Camera', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(cam['cameraId'] ?? cam['id'], style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: online ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: online ? Colors.green.withOpacity(0.3) : Colors.red.withOpacity(0.3)),
            ),
            child: Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: online ? Colors.green : Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.location_city, size: 13, color: Colors.grey),
          const SizedBox(width: 4),
          Text(city, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(width: 12),
          const Icon(Icons.signpost, size: 13, color: Colors.grey),
          const SizedBox(width: 4),
          Expanded(child: Text(street, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis)),
        ]),
        if (cam['aiModel'] != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.smart_toy_outlined, size: 13, color: Colors.grey),
            const SizedBox(width: 4),
            Text('AI: ${cam['aiModel']}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            if (cam['fps'] != null) ...[
              const SizedBox(width: 12),
              const Icon(Icons.speed, size: 13, color: Colors.grey),
              const SizedBox(width: 4),
              Text('${cam['fps']} FPS', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ]),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.lock_open, size: 15),
              label: const Text('Request Access', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF06B6D4),
                side: const BorderSide(color: Color(0xFF06B6D4)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onPressed: online ? () => _showRequestDialog(context, cam, session) : null,
            ),
          ),
          if (online) ...[
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_circle_fill_outlined, size: 15),
                label: const Text('View Feed', style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: () => _openLiveView(context, cam, session),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  Future<void> _showRequestDialog(BuildContext context, Map<String, dynamic> cam, PatrolSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Request Camera Access'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Send access request to Control Room for:', style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 12),
          _InfoRowS('Camera', cam['name'] ?? cam['cameraId'] ?? cam['id']),
          _InfoRowS('City', cam['city'] ?? cam['zoneName'] ?? '—'),
          _InfoRowS('Street', cam['street'] ?? cam['address'] ?? '—'),
          const SizedBox(height: 8),
          const Text('The Control Room will approve or deny your request.', style: TextStyle(color: Colors.amber, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
    if (confirm == true && context.mounted) {
      await FirestoreService.requestCameraAccess(
        patrolId: session.patrolId,
        patrolName: session.name,
        cameraId: cam['cameraId'] ?? cam['id'],
        cameraName: cam['name'] ?? 'Camera',
        cameraAddress: '${cam['city'] ?? cam['zoneName'] ?? ''}, ${cam['street'] ?? cam['address'] ?? ''}',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Access request sent to Control Room'),
          backgroundColor: Color(0xFF0891B2),
        ));
      }
    }
  }

  void _openLiveView(BuildContext context, Map<String, dynamic> cam, PatrolSession session) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => CameraLiveViewScreen(cam: cam, session: session)));
  }
}

class _InfoRowS extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRowS(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      SizedBox(width: 60, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12))),
      Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
    ]),
  );
}

// ============================================================================
// Camera Live View Screen
// ============================================================================

class CameraLiveViewScreen extends StatefulWidget {
  final Map<String, dynamic> cam;
  final PatrolSession session;
  const CameraLiveViewScreen({super.key, required this.cam, required this.session});
  @override
  State<CameraLiveViewScreen> createState() => _CameraLiveViewScreenState();
}

class _CameraLiveViewScreenState extends State<CameraLiveViewScreen> {
  String _accessStatus = 'CHECKING';
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _checkAccess();
  }

  void _checkAccess() {
    final cameraId = widget.cam['cameraId'] ?? widget.cam['id'];
    _sub = FirebaseFirestore.instance
        .collection('camera_access_requests')
        .where('patrolId', isEqualTo: widget.session.patrolId)
        .where('cameraId', isEqualTo: cameraId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        setState(() => _accessStatus = 'NOT_REQUESTED');
        return;
      }
      final latest = snap.docs.first.data();
      setState(() => _accessStatus = latest['status'] ?? 'PENDING');
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = widget.cam;
    final online = cam['status'] == 'ONLINE';
    final approved = _accessStatus == 'APPROVED';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(cam['name'] ?? 'Camera Feed', style: const TextStyle(fontSize: 16)),
          Text(cam['cameraId'] ?? cam['id'], style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: online ? Colors.green.withOpacity(0.15) : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(online ? '● ONLINE' : '● OFFLINE', style: TextStyle(color: online ? Colors.green : Colors.red, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Video feed area
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: approved && online
                  ? _LiveFeedWidget(cam: cam)
                  : _FeedBlockedWidget(status: _accessStatus, online: online),
            ),
          ),

          // Info panel
          Expanded(
            flex: 2,
            child: Container(
              color: const Color(0xFF0B0F19),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Access status
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _accessColor(_accessStatus).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _accessColor(_accessStatus).withOpacity(0.3)),
                    ),
                    child: Row(children: [
                      Icon(_accessIcon(_accessStatus), color: _accessColor(_accessStatus), size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Access Status', style: TextStyle(color: _accessColor(_accessStatus), fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(_accessMessage(_accessStatus), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ])),
                    ]),
                  ),
                  const SizedBox(height: 12),

                  _InfoRowS('City', cam['city'] ?? cam['zoneName'] ?? '—'),
                  _InfoRowS('Street', cam['street'] ?? cam['address'] ?? '—'),
                  _InfoRowS('AI Model', cam['aiModel'] ?? 'yolo26n'),
                  _InfoRowS('FPS', '${cam['fps'] ?? '--'}'),
                  _InfoRowS('Resolution', cam['resolution'] ?? '1080p'),
                  _InfoRowS('Zone', cam['zoneId'] ?? '—'),

                  const SizedBox(height: 16),
                  if (_accessStatus != 'APPROVED')
                    FilledButton.icon(
                      icon: const Icon(Icons.lock_open),
                      label: Text(_accessStatus == 'PENDING' ? 'Request Pending…' : 'Request Access'),
                      onPressed: _accessStatus == 'PENDING' ? null : () async {
                        await FirestoreService.requestCameraAccess(
                          patrolId: widget.session.patrolId,
                          patrolName: widget.session.name,
                          cameraId: cam['cameraId'] ?? cam['id'],
                          cameraName: cam['name'] ?? 'Camera',
                          cameraAddress: '${cam['city'] ?? ''}, ${cam['street'] ?? ''}',
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Access request sent to Control Room'),
                            backgroundColor: Color(0xFF0891B2),
                          ));
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _accessColor(String status) {
    switch (status) {
      case 'APPROVED': return Colors.green;
      case 'DENIED': return Colors.red;
      case 'PENDING': return Colors.orange;
      default: return Colors.grey;
    }
  }

  IconData _accessIcon(String status) {
    switch (status) {
      case 'APPROVED': return Icons.lock_open;
      case 'DENIED': return Icons.lock;
      case 'PENDING': return Icons.hourglass_top;
      default: return Icons.lock_outlined;
    }
  }

  String _accessMessage(String status) {
    switch (status) {
      case 'APPROVED': return 'Live feed is authorized. Camera is active.';
      case 'DENIED': return 'Access was denied by Control Room.';
      case 'PENDING': return 'Waiting for Control Room approval…';
      default: return 'Request access to view this camera.';
    }
  }
}

// Real live feed: pulls the latest JPEG frame from the MakkalAran media gateway
// (pc 192.168.1.2 → gateway :8600). The gateway converts the camera's RTSP/H.265
// stream into lightweight JPEG frames, so the Patrol app just polls
//   http://<gateway>/frame/<cameraId>.jpg
class _LiveFeedWidget extends StatefulWidget {
  final Map<String, dynamic> cam;
  const _LiveFeedWidget({required this.cam});
  @override
  State<_LiveFeedWidget> createState() => _LiveFeedWidgetState();
}

class _LiveFeedWidgetState extends State<_LiveFeedWidget> {
  Timer? _retryTimer;
  final http.Client _client = http.Client();
  ui.Image? _frame;
  Uint8List? _fallbackBytes;
  String _activeGateway = '';
  String _error = '';
  List<({String url, String token})> _candidates = [];
  int _candidateIdx = 0;
  String? _streamUrl;
  bool _decoding = false;
  Uint8List _streamBuf = Uint8List(0);
  // ── Priority 1: DIRECT RTSP playback (native player, full camera fps) ──
  Player? _player;
  VideoController? _videoCtrl;
  String? _rtspUrl;
  StreamSubscription<String>? _playerErrSub;
  final List<StreamSubscription> _videoParamsSubs = [];
  bool _rtspHasVideo = false;   // true only when real video frames decode
  // ── Priority 2: Firebase RTDB live frames (internet-direct MJPEG) ──────
  StreamSubscription<DatabaseEvent>? _rtdbSub;
  int _lastSeq = 0;
  // ── Priority 3: legacy media-gateway polling ───────────────────────────
  bool _gotRtdbFrame = false;
  Timer? _gatewayFallbackTimer;

  // Lighter frames (~480px) keep streaming fast and cheap over mobile data.
  static const int _mobileWidth = 480;

  String get _cameraId => (widget.cam['cameraId'] ?? widget.cam['id'] ?? '').toString();

  /// Ordered gateway list. Public tunnel URL first (works from ANY network),
  /// then the LAN URL, then the hard-coded local fallback — so a single flaky
  /// tunnel can never freeze the feed permanently.
  static Future<List<({String url, String token})>> _candidateGateways(Map<String, dynamic> cam) async {
    final list = <({String url, String token})>[];
    void add(Object? url, Object? token) {
      if (url is String && url.trim().isNotEmpty) {
        list.add((url: url.trim(), token: token is String ? token.trim() : ''));
      }
    }
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('app').get();
      final v = doc.data();
      if (v != null) {
        // Public first — required for remote networks.
        add(v['mediaGatewayPublicUrl'], v['mediaGatewayToken']);
        add(v['mediaGatewayUrl'], v['mediaGatewayToken']);
      }
    } catch (_) {}
    add(cam['gatewayUrl'], cam['gatewayToken']);
    add('http://192.168.1.2:8600', '');
    return list;
  }

  /// Make sure we have an RTSP URL to register, even when the UI only passed
  /// {cameraId, name} (e.g. from "My Requests").
  Future<void> _ensureStreamUrl() async {
    final s = widget.cam['streamUrl'];
    if (s is String && s.trim().isNotEmpty) {
      _streamUrl = s.trim();
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance.collection('cameras').doc(_cameraId).get();
      final d = doc.data();
      if (d != null && d['streamUrl'] is String) _streamUrl = d['streamUrl'] as String;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // ── PRIORITY 1: Direct RTSP playback ──────────────────────────────────
    // The camera's own stream played natively (libmpv) at full camera fps.
    // Works over the internet because the cameras have public IPs — no PC,
    // no gateway, no tunnel, no Firebase needed for the video itself.
    try {
      final s = widget.cam['streamUrl'];
      if (s is String && s.trim().toLowerCase().startsWith('rtsp://')) {
        _rtspUrl = s.trim();
      } else {
        final doc = await FirebaseFirestore.instance.collection('cameras').doc(_cameraId).get();
        final d = doc.data();
        final u = d?['streamUrl'];
        if (u is String && u.trim().toLowerCase().startsWith('rtsp://')) {
          _rtspUrl = u.trim();
        }
      }
    } catch (_) {}
    // Cloud hub (isolated internet system): if configured in Firestore
    // settings/app.mediaServerUrl, stream smooth HLS from the cloud VM.
    String? _cloudBase;
    if (_rtspUrl == null) {
      try {
        final sdoc = await FirebaseFirestore.instance.collection('settings').doc('app').get();
        final b = sdoc.data()?['mediaServerUrl'];
        if (b is String && b.trim().isNotEmpty) _cloudBase = b.trim();
      } catch (_) {}
      if (_cloudBase != null) {
        _startNativePlayer(
          '$_cloudBase/api/stream.m3u8?src=${Uri.encodeComponent(_cameraId)}',
          'cloud-hls',
        );
        Timer(const Duration(seconds: 15), () {
          if (mounted && !_rtspHasVideo) _teardownRtsp();
        });
      }
    }
    if (_rtspUrl != null) {
      _startNativePlayer(_rtspUrl!, 'direct-rtsp');
      // If RTSP hasn't produced video in 12s (camera down / network blocked),
      // tear it down and let the fallbacks take over.
      Timer(const Duration(seconds: 12), () {
        if (mounted && !_rtspHasVideo) _teardownRtsp();
      });
    }

    // ── PRIORITY 2: Firebase RTDB live frames ─────────────────────────────
    // Frames are pushed to /live/cameras/{cameraId} by the frame publisher.
    // Works from ANY network over the internet — no gateway, tunnel, PC or
    // extra login needed (access still gated by the admin approval flow).
    _rtdbSub = FirebaseDatabase.instance
        .ref('live/cameras/$_cameraId')
        .onValue.listen((event) async {
      final v = event.snapshot.value;
      if (v is Map && v['frame'] is String && (v['frame'] as String).isNotEmpty) {
        final seq = (v['seq'] is int) ? v['seq'] as int : 0;
        if (seq > 0 && seq <= _lastSeq) return;   // drop out-of-order stale frames
        if (_rtspHasVideo) {                      // native video already smooth
          _lastSeq = seq;
          return;
        }
        try {
          final bytes = base64Decode(v['frame'] as String);
          final codec = await ui.instantiateImageCodec(bytes);
          final img = (await codec.getNextFrame()).image;
          if (!mounted) return;
          setState(() {
            _frame = img;
            _error = '';
          });
          _lastSeq = seq;
          if (!_gotRtdbFrame) {
            _gotRtdbFrame = true;
            _activeGateway = 'firebase-rtdb';
            _gatewayFallbackTimer?.cancel();
            _retryTimer?.cancel();
          }
        } catch (_) {}
      }
    }, onError: (_) {});

    // ── PRIORITY 3: legacy media-gateway polling after a grace period ─────
    _gatewayFallbackTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || _gotRtdbFrame || _rtspHasVideo) return;
      _candidates = await _candidateGateways(widget.cam);
      await _ensureStreamUrl();
      if (!mounted || _gotRtdbFrame || _rtspHasVideo) return;
      _startStreamLoop();
    });
  }

  bool get _isRtspPlaying => _player != null && _videoCtrl != null;

  void _startNativePlayer(String url, String tag) {
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    // Low-latency live tuning (libmpv properties).
    try {
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        native.setProperty('rtsp-transport', 'tcp');
        native.setProperty('network-timeout', '10');
        native.setProperty('fflags', 'nobuffer');
        native.setProperty('flags', 'low_delay');
        native.setProperty('framedrop', 'vo');
      }
    } catch (_) {}
    final controller = VideoController(player);
    _playerErrSub = player.stream.error.listen((_) {
      if (mounted) _teardownRtsp();
    });
    // Track REAL decoded video — a player can exist without ever producing
    // frames (camera down, blocked port). Only actual video counts.
    final vpSub = player.stream.videoParams.listen((vp) {
      if ((vp.w ?? 0) > 0 && mounted) {
        setState(() => _rtspHasVideo = true);
      }
    });
    _videoParamsSubs.add(vpSub);
    setState(() {
      _player = player;
      _videoCtrl = controller;
      _activeGateway = tag;   // 'direct-rtsp' | 'cloud-hls'
    });
    player.open(Media(url));
  }

  void _teardownRtsp() {
    if (!_isRtspPlaying) return;
    for (final s in _videoParamsSubs) { s.cancel(); }
    _videoParamsSubs.clear();
    _rtspHasVideo = false;
    _playerErrSub?.cancel();
    _playerErrSub = null;
    final p = _player;
    _player = null;
    _videoCtrl = null;
    if (mounted) setState(() {});
    p?.dispose();
  }

  /// Persistent raw-frame stream (length-prefixed JPEG). One connection stays
  /// open so there is NO per-frame network round-trip — smooth like a native
  /// camera app even over mobile data / long-distance links.
  Future<void> _startStreamLoop() async {
    final n = _candidates.length;
    if (n == 0) return;
    for (var attempt = 0; attempt < n; attempt++) {
      final idx = (_candidateIdx + attempt) % n;
      final c = _candidates[idx];
      try {
        // Keep the capture warm.
        if (_streamUrl != null && _streamUrl!.isNotEmpty) {
          await http
              .post(
                Uri.parse('${c.url}/api/streams'),
                headers: {
                  'Content-Type': 'application/json',
                  if (c.token.isNotEmpty) 'X-Gateway-Token': c.token,
                },
                body: jsonEncode({'cameraId': _cameraId, 'url': _streamUrl}),
              )
              .timeout(const Duration(seconds: 3));
        }
        final req = http.Request(
          'GET',
          Uri.parse('${c.url}/frames/$_cameraId.jpg?w=$_mobileWidth'),
        );
        if (c.token.isNotEmpty) req.headers['X-Gateway-Token'] = c.token;
        final resp = await _client.send(req).timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) {
          if (resp.statusCode == 401 && mounted && _error.isEmpty) {
            // ignore lint — pure diagnostic text under the feed
          }
          await resp.stream.drain<void>();
          continue;
        }
        if (mounted) {
          setState(() {
            _activeGateway = c.url;
            _candidateIdx = idx;
            _error = '';
          });
        }
        await _readStream(resp.stream);
        return;
      } catch (_) {
        continue;
      }
    }
    await _pollFallback();
    if (mounted) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) _startStreamLoop();
      });
    }
  }

  Future<void> _readStream(Stream<List<int>> stream) async {
    try {
      await for (final chunk in stream) {
        if (!mounted) return;
        _streamBuf = Uint8List.fromList(<int>[..._streamBuf, ...chunk]);
        while (_streamBuf.length >= 4) {
          final n = ((_streamBuf[0] & 0xff) << 24) |
              ((_streamBuf[1] & 0xff) << 16) |
              ((_streamBuf[2] & 0xff) << 8) |
              (_streamBuf[3] & 0xff);
          if (n <= 0 || n > 4 * 1024 * 1024) {
            _streamBuf = Uint8List(0);
            break;
          }
          if (_streamBuf.length < 4 + n) break;
          final jpg = Uint8List.fromList(_streamBuf.sublist(4, 4 + n));
          _streamBuf = Uint8List.fromList(_streamBuf.sublist(4 + n));
          _decodeJpeg(jpg);
        }
        if (_streamBuf.length > 5 * 1024 * 1024) _streamBuf = Uint8List(0);
      }
    } catch (_) {}
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _startStreamLoop();
    });
  }

  Future<void> _decodeJpeg(Uint8List jpg) async {
    if (_decoding) return;
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpg);
      final next = await codec.getNextFrame();
      codec.dispose();
      final img = next.image;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _frame?.dispose();
        _frame = img;
        _fallbackBytes = null;
        _error = '';
      });
    } catch (_) {
      // Keep last good frame.
    } finally {
      _decoding = false;
    }
  }

  Future<void> _pollFallback() async {
    for (final c in _candidates) {
      try {
        final res = await http
            .get(
              Uri.parse('${c.url}/frame/$_cameraId.jpg?w=$_mobileWidth&t=${DateTime.now().millisecondsSinceEpoch}'),
              headers: {if (c.token.isNotEmpty) 'X-Gateway-Token': c.token},
            )
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty && mounted) {
          setState(() {
            _fallbackBytes = res.bodyBytes;
            _activeGateway = c.url;
            _error = '';
          });
          return;
        }
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _rtdbSub?.cancel();
    _gatewayFallbackTimer?.cancel();
    _retryTimer?.cancel();
    _playerErrSub?.cancel();
    final p = _player;
    _player = null;
    p?.dispose();
    _client.close();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PRIORITY 1 — native RTSP video (full camera fps, smooth)
    if (_videoCtrl != null) {
      if (!_rtspHasVideo) {
        // Player exists but no decoded frames yet — show connecting state so
        // the user knows it's alive while RTSP negotiates.
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(color: Color(0xFF06B6D4)),
              SizedBox(height: 12),
              Text('Connecting to camera (direct RTSP)…',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: _videoCtrl!),
          Positioned(
            top: 10,
            left: 10,
            child: Text(
              '${widget.cam['name'] ?? 'LIVE'} · ${widget.cam['cameraId'] ?? ''} · RTSP DIRECT',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          const Positioned(top: 10, right: 10, child: _BlinkDot()),
        ],
      );
    }
    if (_frame == null && _fallbackBytes == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFF06B6D4)),
            const SizedBox(height: 12),
            Text(_error.isEmpty
                ? 'Connecting to camera feed…'
                : 'Feed unavailable — retrying…',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
              ),
            ],
          ],
        ),
      );
    }

    Widget feed;
    if (_frame != null) {
      feed = RawImage(
        image: _frame,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      );
    } else {
      feed = Image.memory(_fallbackBytes!, fit: BoxFit.contain);
    }

    return Stack(
      children: [
        Positioned.fill(child: feed),
        Positioned(
          top: 10,
          left: 10,
          child: Text(
            '${widget.cam['name'] ?? 'LIVE'} · ${widget.cam['cameraId'] ?? ''}',
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
        if (_activeGateway.isNotEmpty)
          Positioned(
            top: 26,
            left: 10,
            child: Text(
              _activeGateway.replaceFirst('https://', '').replaceFirst('http://', ''),
              style: const TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace'),
            ),
          ),
        const Positioned(top: 10, right: 10, child: _BlinkDot()),
        Positioned(
          bottom: 10,
          right: 10,
          child: Text(
            '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}',
            style: const TextStyle(color: Colors.white54, fontSize: 10, fontFamily: 'monospace'),
          ),
        ),
        if (_error.isNotEmpty)
          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.85), borderRadius: BorderRadius.circular(8)),
              child: Text(_error,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
      ],
    );
  }
}

class _BlinkDot extends StatefulWidget {
  const _BlinkDot();
  @override
  State<_BlinkDot> createState() => _BlinkDotState();
}

class _BlinkDotState extends State<_BlinkDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _anim,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(6)),
      child: const Text('● LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
    ),
  );
}

class _FeedBlockedWidget extends StatelessWidget {
  final String status;
  final bool online;
  const _FeedBlockedWidget({required this.status, required this.online});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    String msg;
    Color color;
    if (!online) {
      icon = Icons.videocam_off;
      msg = 'Camera is offline';
      color = Colors.red;
    } else if (status == 'PENDING') {
      icon = Icons.hourglass_top;
      msg = 'Waiting for Control Room approval…';
      color = Colors.orange;
    } else if (status == 'DENIED') {
      icon = Icons.lock;
      msg = 'Access denied by Control Room';
      color = Colors.red;
    } else {
      icon = Icons.lock_outlined;
      msg = 'Request access to view live feed';
      color = Colors.grey;
    }
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 64, color: color.withOpacity(0.5)),
      const SizedBox(height: 16),
      Text(msg, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    ]));
  }
}

// ============================================================================
// My Camera Requests Tab
// ============================================================================

class _MyRequestsView extends StatelessWidget {
  final PatrolSession session;
  const _MyRequestsView({required this.session});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FSnap>(
      stream: FirestoreService.listenCameraRequests(session.patrolId),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4)));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_clock, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Text('No camera access requests yet', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 4),
            Text('Search for cameras and tap "Request Access"', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: snap.data!.docs.length,
          itemBuilder: (ctx, i) {
            final doc = snap.data!.docs[i];
            final d = doc.data() as Map<String, dynamic>;
            final status = d['status'] ?? 'PENDING';
            final color = status == 'APPROVED' ? Colors.green : status == 'DENIED' ? Colors.red : Colors.orange;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withOpacity(0.25)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Expanded(child: Text(d['cameraName'] ?? d['cameraId'] ?? 'Camera', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
                    child: Text(status, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(d['cameraAddress'] ?? '', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(status == 'APPROVED' ? Icons.lock_open : status == 'DENIED' ? Icons.lock : Icons.hourglass_top, size: 13, color: color),
                  const SizedBox(width: 6),
                  Text(
                    status == 'APPROVED' ? 'Tap to view live feed' : status == 'DENIED' ? 'Contact Control Room' : 'Awaiting Control Room approval',
                    style: TextStyle(color: color.withOpacity(0.8), fontSize: 12),
                  ),
                ]),
                if (status == 'APPROVED')
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.play_circle_fill_outlined, size: 16),
                        label: const Text('Open Live Feed', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => CameraLiveViewScreen(
                            cam: {'cameraId': d['cameraId'], 'name': d['cameraName'], 'city': '', 'status': 'ONLINE'},
                            session: session,
                          )));
                        },
                      ),
                    ),
                  ),
              ]),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// Profile Tab
// ============================================================================

class ProfileTab extends StatelessWidget {
  final PatrolSession session;
  final VoidCallback onLogout;
  const ProfileTab({super.key, required this.session, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 10),
          Center(child: Column(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset('assets/logo.png', width: 90, height: 90, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => CircleAvatar(radius: 45, backgroundColor: const Color(0xFF0891B2), child: const Icon(Icons.person, size: 50, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 12),
            Text(session.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(session.role, style: const TextStyle(color: Color(0xFF06B6D4), fontSize: 13)),
          ])),
          const SizedBox(height: 24),
          _Card(child: Column(children: [
            _InfoRow2(icon: Icons.badge_outlined, label: 'Patrol ID', value: session.patrolId),
            const Divider(color: Color(0xFF1F2937)),
            _InfoRow2(icon: Icons.email_outlined, label: 'Email', value: session.email),
            const Divider(color: Color(0xFF1F2937)),
            _InfoRow2(icon: Icons.map_outlined, label: 'Zone', value: 'Zone A · Krishnagiri'),
            const Divider(color: Color(0xFF1F2937)),
            _InfoRow2(icon: Icons.directions_car_outlined, label: 'Vehicle', value: 'KA-01-MB-2024'),
            const Divider(color: Color(0xFF1F2937)),
            _InfoRow2(icon: Icons.phone_outlined, label: 'Contact', value: '+91 98765 43210'),
          ])),
          const SizedBox(height: 20),
          _Card(child: Column(children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline, color: Color(0xFF06B6D4)),
              title: const Text('App Version'),
              trailing: const Text('v2.0.0', style: TextStyle(color: Colors.grey)),
            ),
            const Divider(color: Color(0xFF1F2937)),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_outlined, color: Color(0xFF06B6D4)),
              title: const Text('MakkalAran Patrol'),
              trailing: const Text('Tamil Nadu Police', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          ])),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout, color: Colors.red),
              label: const Text('Sign Out', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: onLogout,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Shared Widgets
// ============================================================================

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: padding ?? const EdgeInsets.all(16),
    decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1F2937))),
    child: child,
  );
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(0.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(height: 8),
      Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
    ]),
  );
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    final color = status == 'AVAILABLE' || status == 'APPROVED' ? Colors.green
        : status == 'OFFLINE' || status == 'DENIED' ? Colors.red
        : status == 'PENDING' || status == 'EN_ROUTE' ? Colors.orange : Colors.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
      child: Text(status, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }
}

class _InfoRow2 extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow2({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Icon(icon, size: 16, color: const Color(0xFF06B6D4)),
      const SizedBox(width: 12),
      SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13))),
      Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
    ]),
  );
}
