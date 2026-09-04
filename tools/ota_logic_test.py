#!/usr/bin/env python3
"""
MAKKAL ARAN — OTA update-decision regression test (Public + Patrol).

Mirrors the exact decision logic implemented in:
  apps/public/lib/update_service.dart   (_readVersionCode, _manifestSection,
                                         maybeCheckAndPrompt guards)
  apps/patrol/lib/update_service.dart   (same logic)
  apps/public/lib/main.dart             (AppUpdateService.check ->
                                         available = serverCode > installedCode)

Run:  python tools/ota_logic_test.py
Exit code 0 = all cases pass.
"""

import json

failures = 0
passed = 0


def check(name, cond):
    global failures, passed
    print(("PASS  " if cond else "FAIL  ") + name)
    if cond:
        passed += 1
    else:
        failures += 1


# --- mirrors: int _readVersionCode(Object? raw) ------------------------------
def read_version_code(raw):
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, (int, float)):
        return int(raw)
    try:
        return int(str(raw).strip()) if raw is not None else 0
    except (TypeError, ValueError):
        return 0


# --- mirrors: Map<String,dynamic>? _manifestSection(...) ---------------------
def manifest_section(config, platform_key):
    if not isinstance(config, dict):
        return None
    direct = config.get(platform_key)
    if isinstance(direct, dict):
        return direct
    if platform_key.startswith("android-"):
        alias = config.get(platform_key[len("android-"):])
        if isinstance(alias, dict):
            return alias
    return None


# --- mirrors the Dart fetch: network error / bad JSON / missing section -> None
def fetch_release(manifest_text, platform_key):
    try:
        config = json.loads(manifest_text)
    except Exception:
        return None  # CASE G: malformed manifest -> no update, app continues
    section = manifest_section(config, platform_key)
    if section is None:
        return None  # CASE E: missing/invalid section -> no update
    return {
        "version": str(section.get("version", "?")),
        "versionCode": read_version_code(section.get("versionCode")),
        "apkUrl": section.get("apkUrl"),
    }


# --- mirrors: maybeCheckAndPrompt / AppUpdateService.check -------------------
def update_available(release, installed_code, skipped_code=None):
    if release is None:
        return False  # offline (CASE F) / invalid (E, G)
    server = release["versionCode"]
    if server <= installed_code:
        return False  # up-to-date (B) or downgrade (D)
    if skipped_code is not None and skipped_code == server:
        return False  # user pressed "Later" for this code
    return True


# --- mirrors: static bool _checkInProgress / _downloadInProgress -------------
class Updater:
    def __init__(self):
        self._check_in_progress = False
        self._download_in_progress = False
        self.dialogs_shown = 0
        self.downloads_started = 0

    def maybe_check_and_prompt(self, release, installed, skipped=None, in_flight=False):
        # In real Dart the flag is held for the whole check+dialog; a concurrent
        # trigger while another check is in flight is dropped. With
        # in_flight=True the flag STAYS held (mirrors an operation in progress).
        if self._check_in_progress:
            return
        self._check_in_progress = True
        try:
            if update_available(release, installed, skipped):
                self.dialogs_shown += 1
        finally:
            if not in_flight:
                self._check_in_progress = False

    def download_and_install(self):
        # Mirrors Dart: _downloadInProgress is set for the WHOLE download and
        # only released on the success path (client.close()) or in catch.
        if self._download_in_progress:
            return
        self._download_in_progress = True
        self.downloads_started += 1

    def finish_download(self):
        """Mirrors the Dart reset on success/catch (end of one download)."""
        self._download_in_progress = False


MANIFEST_104 = json.dumps({
    "patrol": {"version": "1.3.4", "versionCode": 104,
               "apkUrl": "https://example/MAKKAL-ARAN-Patrol-v1.3.4.apk"},
    "public": {"version": "1.3.4", "versionCode": 104,
               "apkUrl": "https://example/MAKKAL-ARAN-Public-v1.3.4.apk"},
})
MANIFEST_105 = MANIFEST_104.replace("1.3.4", "1.3.5").replace(": 104", ": 105")

if __name__ == "__main__":
    print("=== CASE A-H: update decision matrix ===")
    rel104 = fetch_release(MANIFEST_104, "android-patrol")
    rel105 = fetch_release(MANIFEST_105, "android-patrol")
    check("CASE A: installed 103, server 104 -> UPDATE", update_available(rel104, 103) is True)
    check("CASE B: installed 104, server 104 -> NO UPDATE", update_available(rel104, 104) is False)
    check("CASE C: installed 104, server 105 -> UPDATE", update_available(rel105, 104) is True)
    check("CASE D: installed 105, server 104 -> NO UPDATE (downgrade blocked)",
          update_available(rel104, 105) is False)

    print("=== CASE E/F/G: safe-failure paths ===")
    check("CASE E: manifest '{}' (missing section) -> NO UPDATE",
          fetch_release("{}", "android-patrol") is None
          and update_available(None, 103) is False)
    check("CASE F: network unavailable (exception path) -> NO UPDATE",
          update_available(None, 103) is False)
    check("CASE G: malformed manifest -> NO UPDATE",
          fetch_release("{ this is not json", "android-patrol") is None)

    print("=== CASE H: duplicate check / download protection ===")
    u = Updater()
    u.maybe_check_and_prompt(rel104, 103, in_flight=True)   # check #1 in flight (flag held)
    for _ in range(5):
        u.maybe_check_and_prompt(rel104, 103, in_flight=True)  # concurrent triggers dropped
    check("CASE H1: max ONE update dialog for concurrent triggers", u.dialogs_shown == 1)
    u._check_in_progress = False                             # check #1 finally completes
    u.maybe_check_and_prompt(rel104, 103)                    # a LATER, separate check may prompt again
    check("CASE H1b: a later separate check still evaluates normally", u.dialogs_shown == 2)

    u2 = Updater()
    for _ in range(5):
        u2.download_and_install()                            # double-taps while download #1 runs
    check("CASE H2: max ONE download for double-taps", u2.downloads_started == 1)
    u2.finish_download()                                     # download #1 finishes (success/catch)
    u2.download_and_install()                                # a new download is now allowed
    check("CASE H2b: new download allowed after previous completes", u2.downloads_started == 2)

    print("=== tolerant versionCode parsing (manifest robustness) ===")
    m = json.loads(MANIFEST_104)
    m["public"]["versionCode"] = 104.0
    check("versionCode as float 104.0 -> 104", read_version_code(m["public"]["versionCode"]) == 104)
    m["public"]["versionCode"] = "104"
    check("versionCode as string '104' -> 104", read_version_code(m["public"]["versionCode"]) == 104)
    del m["public"]["versionCode"]
    check("versionCode missing -> 0 -> treated as NO UPDATE",
          update_available(fetch_release(json.dumps(m), "public"), 103) is False)

    print("=== platform key alias resolution (android-* -> short key) ===")
    check("'android-patrol' resolves manifest section 'patrol'",
          manifest_section(json.loads(MANIFEST_104), "android-patrol") is not None)
    check("'patrol' resolves directly",
          manifest_section(json.loads(MANIFEST_104), "patrol") is not None)
    check("unknown platform -> None (no update)", manifest_section(json.loads(MANIFEST_104), "ios") is None)

    print()
    print(f"RESULT: {passed} passed, {failures} failed")
    raise SystemExit(1 if failures else 0)
