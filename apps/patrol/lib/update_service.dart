// ============================================================================
// In-app updater — INTERNET-BASED (GitHub Releases).
//
// Fetches update.json from GitHub Raw (works on ANY network globally).
// Downloads APK files directly from GitHub Releases CDN.
//
// Repo: https://github.com/DharaniSoftDeveloper/MAKKAL-ARAN
// ============================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build-time version markers (override with --dart-define).
const int kAppVersionCode = int.fromEnvironment('APP_VERSION_CODE', defaultValue: 104);
const String kAppVersionName = String.fromEnvironment('APP_VERSION_NAME', defaultValue: '1.3.4');

// ---------------------------------------------------------------------------
// REAL installed version (read from the APK at runtime).
//
// ROOT-CAUSE FIX for the "update installed, then it loops forever" bug:
// the old code compared the server's versionCode against a CONSTANT baked
// into the APK at build time (default 100). Unless every single build passed
// --dart-define=APP_VERSION_CODE, the freshly-installed APK still reported
// code 100, so server code 102 was "always newer" and the update dialog
// re-appeared on every launch. Reading the code from the installed APK makes
// the comparison always match reality and stops the loop.
// ---------------------------------------------------------------------------
PackageInfo? _packageInfo;

Future<PackageInfo> _installedInfo() async =>
    _packageInfo ??= await PackageInfo.fromPlatform();

Future<int> _installedVersionCode() async {
  try {
    final info = await _installedInfo();
    final code = int.tryParse(info.buildNumber);
    if (code != null && code > 0) return code;
  } catch (_) {}
  return kAppVersionCode; // last-resort fallback to the build-time constant.
}

Future<String> _installedVersionName() async {
  try {
    final info = await _installedInfo();
    if (info.version.isNotEmpty) return info.version;
  } catch (_) {}
  return kAppVersionName;
}

/// Picks the manifest section for [platformKey] from update.json, falling back
/// to the short alias used by the server manifests ('android-patrol' →
/// 'patrol', 'android-public' → 'public'). This makes the Supabase + GitHub
/// update.json keys ('patrol'/'public') work with the backend's keys
/// ('android-patrol'/'android-public').
Map<String, dynamic>? _manifestSection(
    Map<String, dynamic> updateConfig, String platformKey) {
  final direct = updateConfig[platformKey];
  if (direct is Map<String, dynamic>) return direct;
  if (platformKey.startsWith('android-')) {
    final alias = updateConfig[platformKey.substring('android-'.length)];
    if (alias is Map<String, dynamic>) return alias;
  }
  return null;
}

/// Tolerant versionCode reader: accepts int, double (102.0), or a numeric
/// string. Returns 0 when the field is missing/invalid so callers can safely
/// treat that as "no update available".
int _readVersionCode(Object? raw) =>
    raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;

/// SUPABASE update source — zero redirects, direct download
/// Works on ANY network: mobile data, home WiFi, office WiFi, anywhere!
const String kSupabaseUpdateUrl = 'https://wmlcnmtnvjndlzahmocc.supabase.co/storage/v1/object/public/ota/update.json';

/// Legacy Supabase URL (kept for backward compatibility)
const String kCloudUpdateBase = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://wmlcnmtnvjndlzahmocc.supabase.co',
);

/// Global navigator key so the updater can prompt from anywhere.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class _Release {
  final String version;
  final int versionCode;
  final String notes;
  final bool mandatory;
  /// CLOUD part URLs (Supabase Storage, <=50MB each) — used on any network.
  /// Empty → single-object download from the LAN backend.
  final List<String> cloudParts;
  final int totalSize;
  _Release({
    required this.version,
    required this.versionCode,
    required this.notes,
    required this.mandatory,
    this.cloudParts = const [],
    this.totalSize = 0,
  });
}

class InAppUpdater {
  InAppUpdater._();

  /// INTERNET check: Fetch update.json from Supabase (works on ANY network)
  static Future<_Release?> _fetchLatestRelease({
    required String apiBase,
    required String platformKey,
  }) async {
    // INTERNET (works on any network globally) — 3 attempts, 15s each, backoff.
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final res = await http
            .get(Uri.parse(kSupabaseUpdateUrl))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final updateConfig = jsonDecode(res.body) as Map<String, dynamic>;
          final appConfig = _manifestSection(updateConfig, platformKey);
          if (appConfig == null) {
            debugPrint('[UPDATE] No config found for platform: $platformKey');
            return null;
          }
          final vc = _readVersionCode(appConfig['versionCode']);
          final rel = _Release(
            version: '${appConfig['version'] ?? '?'}',
            versionCode: vc,
            notes: (appConfig['changelog'] as List?)?.join('\n') ?? '',
            mandatory: (appConfig['forceUpdate'] ?? false) == true,
            totalSize: (appConfig['fileSize'] as num?)?.toInt() ?? 0,
            cloudParts: appConfig['apkUrl'] != null ? [appConfig['apkUrl'] as String] : [],
          );
          debugPrint(
              '[UPDATE] Supabase manifest v${rel.version} (code ${rel.versionCode})');
          return rel;
        }
        debugPrint(
            '[UPDATE] Supabase manifest HTTP ${res.statusCode} (attempt $attempt/3)');
      } catch (e) {
        debugPrint('[UPDATE] Supabase check attempt $attempt/3 failed: $e');
        if (attempt < 3) await Future.delayed(Duration(seconds: attempt));
      }
    }    // 2) LAN BACKEND fallback.
    try {
      final res = await http
          .get(Uri.parse('$apiBase/updates/latest?platform=$platformKey'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final m = body['release'] as Map<String, dynamic>?;
      if (m == null) return null;
      return _Release(
        version: '${m['version'] ?? '?'}',
        versionCode: _readVersionCode(m['versionCode']),
        notes: '${m['notes'] ?? ''}',
        mandatory: (m['mandatory'] ?? false) == true,
      );
    } catch (_) {
      return null; // offline / no source reachable — ignore
    }
  }

  /// Guards against duplicate/concurrent checks (e.g. app-resume triggers) so
  /// at most ONE update dialog can ever be queued at a time.
  static bool _checkInProgress = false;

  /// Guards against simultaneous downloads (double-tap on "Update now").
  static bool _downloadInProgress = false;

  /// Silent check + prompt when a newer release exists. Never blocks the app:
  /// any network error is swallowed. Call ~3s after startup, passing
  /// [appNavigatorKey].currentContext.
  static Future<void> maybeCheckAndPrompt(
    BuildContext? context, {
    required String apiBase,
    required String platformKey,
  }) async {
    if (context == null || _checkInProgress) return;
    _checkInProgress = true;
    try {
      final rel = await _fetchLatestRelease(apiBase: apiBase, platformKey: platformKey);
      if (rel == null) return;
      final installedCode = await _installedVersionCode();
      if (rel.versionCode <= installedCode) {
        debugPrint(
            '[UPDATE] Up to date — installed code $installedCode, manifest ${rel.versionCode}');
        return;
      }
      if (!rel.mandatory) {
        try {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.getInt('update_skipped_code') == rel.versionCode) return;
        } catch (_) {}
      }
      if (!context.mounted) return;
      await _showUpdateDialog(context, apiBase: apiBase, platformKey: platformKey, rel: rel);
    } finally {
      _checkInProgress = false;
    }
  }


  static Future<void> _showUpdateDialog(
    BuildContext context, {
    required String apiBase,
    required String platformKey,
    required _Release rel,
  }) async {
    final installedName = await _installedVersionName();
    await showDialog<void>(
      context: context,
      barrierDismissible: !rel.mandatory,
      builder: (ctx) => PopScope(
        canPop: !rel.mandatory,
        child: AlertDialog(
          backgroundColor: const Color(0xFF111827),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.system_update_alt, color: Color(0xFF22D3EE)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Update available — v${rel.version}',
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
            ),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rel.notes.isEmpty
                    ? 'Version $installedName → ${rel.version} is available. Install it to get the latest features and fixes.'
                    : rel.notes,
                style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 10),
              const Text(
                'After download, tap INSTALL. If Play Protect shows a warning, '
                'tap "More details" → "Install anyway" — otherwise Android '
                'silently keeps the old version.',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12, height: 1.35),
              ),
            ],
          ),
          actions: [
            if (!rel.mandatory)
              TextButton(
                onPressed: () async {
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('update_skipped_code', rel.versionCode);
                  } catch (_) {}
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: const Text('Later', style: TextStyle(color: Colors.white54)),
              ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0891B2)),
              onPressed: () => _downloadAndInstall(ctx, apiBase: apiBase, platformKey: platformKey, rel: rel),
              child: const Text('Update now'),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _downloadAndInstall(
    BuildContext ctx, {
    required String apiBase,
    required String platformKey,
    required _Release rel,
  }) async {
    Navigator.of(ctx).pop(); // close the info dialog
    final progress = ValueNotifier<double>(0);
    var received = 0.0;
    var total = 0.0;

    if (!ctx.mounted) return;
    if (_downloadInProgress) return; // one download at a time
    _downloadInProgress = true;
    unawaited(showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dlgCtx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF111827),
          title: Text('Downloading v${rel.version}…',
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: total > 0 ? v : null,
                      minHeight: 8,
                      backgroundColor: const Color(0xFF1F2937),
                      color: const Color(0xFF22D3EE)),
                ),
                const SizedBox(height: 10),
                Text(
                    total > 0
                        ? '${received.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} MB'
                        : 'connecting…',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    ));

    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${dir.path}/makkalaran-$platformKey-update.apk');
      final client = http.Client();
      if (rel.cloudParts.isNotEmpty) {
        // CLOUD multi-part download — works on ANY network. Parts are
        // concatenated into the final APK; progress spans all parts.
        total = rel.totalSize / 1048576.0;
        final sink = file.openWrite();
        var received = 0.0;
        for (final partUrl in rel.cloudParts) {
          final partResp = await client
              .send(http.Request('GET', Uri.parse(partUrl)))
              .timeout(const Duration(minutes: 15));
          if (partResp.statusCode != 200) {
            await sink.close();
            throw Exception('Part download failed (HTTP ${partResp.statusCode})');
          }
          await for (final chunk in partResp.stream) {
            received += chunk.length / 1048576.0;
            sink.add(chunk);
            if (rel.totalSize > 0) progress.value = received / (rel.totalSize / 1048576.0);
          }
        }
        await sink.flush();
        await sink.close();
      } else {
        // GitHub release download (follows redirects) — used when the manifest
        // exposes a direct APK URL (apkUrl) instead of multi-part cloud parts.
        final req = http.Request('GET', Uri.parse(rel.cloudParts.first));
        req.followRedirects = true;
        req.maxRedirects = 5;
        final resp = await client.send(req).timeout(const Duration(minutes: 15));
        if (resp.statusCode != 200) throw Exception('Download failed (HTTP ${resp.statusCode})');
        total = (resp.contentLength ?? 0) / 1048576.0;
        final sink = file.openWrite();
        await for (final chunk in resp.stream) {
          received += chunk.length / 1048576.0;
          if (total > 0) progress.value = received / total;
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      }
      client.close();
      _downloadInProgress = false;
      if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop(); // close progress
      final opened = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (opened.type != ResultType.done && ctx.mounted) {
        _toast(ctx, 'Could not start installer: ${opened.message}');
      }
    } catch (e) {
      _downloadInProgress = false;
      if (ctx.mounted) {
        if (Navigator.of(ctx, rootNavigator: true).canPop()) {
          Navigator.of(ctx, rootNavigator: true).pop();
        }
        _toast(ctx, 'Update failed: $e');
      }
    }
  }

  static void _toast(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF7F1D1D)));
  }
}
