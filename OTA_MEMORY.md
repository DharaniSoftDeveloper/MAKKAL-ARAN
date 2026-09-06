# MAKKAL ARAN — OTA UPDATE SYSTEM MEMORY
> **CRITICAL: Read this file before ANY OTA work. 5+ failed attempts documented here.**

---

## 1. ARCHITECTURE — How OTA actually works

### Three live update sources (ALL must be updated for OTA to work)

| # | Source | Used by | URL |
|---|---|---|---|
| 1 | **Supabase Storage** | Patrol app startup (`InAppUpdater`) | `https://wmlcnmtnvjndlzahmocc.supabase.co/storage/v1/object/public/ota/update.json` |
| 2 | **GitHub Raw** | Public app startup (`InAppUpdater`) | `https://raw.githubusercontent.com/DharaniSoftDeveloper/MAKKAL-ARAN/main/update.json` |
| 3 | **Firestore `settings/app`** | Patrol app Settings→App Update fallback | `https://firestore.googleapis.com/v1/projects/blind-spot-crime-detection/databases/(default)/documents/settings/app` |

### App update flow (v1.3.4+ installed apps)

**Patrol app:**
- Startup (3s delay): `InAppUpdater.maybeCheckAndPrompt()` → fetches Supabase manifest → compares `versionCode` vs installed → shows dialog
- Settings → App Update: `AppUpdateService.check()` → LAN backend (`http://192.168.1.2:3000`, usually DOWN) → Firestore `settings/app` fallback

**Public app:**
- Startup: `InAppUpdater.maybeCheckAndPrompt()` → fetches GitHub Raw manifest → compares → shows dialog

### Manifest format (JSON)
```json
{
  "patrol": {
    "version": "1.4.1",
    "versionCode": 107,
    "apkUrl": "https://github.com/DharaniSoftDeveloper/MAKKAL-ARAN/releases/download/v1.4.1/MAKKAL-ARAN-Patrol-v1.4.1.apk",
    "changelog": ["line 1", "line 2"],
    "forceUpdate": true,
    "minVersionCode": 106
  },
  "public": { ... },
  "releaseDate": "2026-09-06",
  "serverStatus": "active"
}
```

---

## 2. WHY OTA FAILED 5+ TIMES — Root causes

### Failure 1: Stale Supabase manifest
- Live manifest was stuck at v1.3.2/102 while releases shipped 104+
- **Fix:** Re-uploaded `ota/update.json` to Supabase Storage via REST PUT

### Failure 2: Stale GitHub Raw manifest
- `update.json` on `main` branch was behind
- **Fix:** Updated repo root `update.json` and pushed to BOTH `master` and `main`

### Failure 3: Stale Firestore fallback
- `settings/app` doc had old v1.3.x values
- **Fix:** PATCHed Firestore doc via REST API with v1.4.0/106

### Failure 4: `forceUpdate: false` + "Later" tapped
- When user taps "Later", app saves `update_skipped_code = 106` in SharedPreferences
- With `forceUpdate: false`, dialog is suppressed FOREVER
- **Fix:** Set `forceUpdate: true` on all sources → unskippable dialog

### Failure 5: Installed app already at manifest version
- App was v1.4.0+106, manifest said 106 → "up to date" (correct behavior!)
- **Fix:** Must bump to v1.4.1+107 (new versionCode > installed)

### Failure 6: Dart record destructuring build error
- `final { data, error } = await _client...` not supported in Dart 3.47.2
### Failure 6: Dart record destructuring build error
- `final { data, error } = await _client...` not supported in Dart 3.47.2
- **Fix:** Changed to `final res = await _client...; if (res.error != null) ...`

---

## 3. CORRECT OTA PROCEDURE (follow exactly)

### Step 1: Bump version in pubspec.yaml
```
apps/patrol/pubspec.yaml  → version: X.Y.Z+CODE
apps/public/pubspec.yaml  → version: X.Y.Z+CODE
```
`CODE` must be **greater than** the current manifest's `versionCode`.

### Step 2: Update root `update.json` (single source of truth)
```json
{
  "patrol": { "version": "X.Y.Z", "versionCode": CODE, "apkUrl": "https://github.com/.../vX.Y.Z/MAKKAL-ARAN-Patrol-vX.Y.Z.apk", "changelog": [...], "forceUpdate": true, "minVersionCode": PREVIOUS_CODE },
  "public": { ... },
  "releaseDate": "YYYY-MM-DD",
  "serverStatus": "active"
}
```

### Step 3: Build APKs
```powershell
$env:JAVA_HOME = 'C:\tools\jdk-17'
$env:ANDROID_HOME = 'C:\Users\dhara\AppData\Local\Android\Sdk'
# Patrol:
Push-Location apps/patrol; flutter build apk --release; Pop-Location
# Public:
Push-Location apps/public; flutter build apk --release; Pop-Location
```

### Step 4: Create GitHub Release + upload APKs
- Tag: `vX.Y.Z`
- Assets: `MAKKAL-ARAN-Patrol-vX.Y.Z.apk`, `MAKKAL-ARAN-Public-vX.Y.Z.apk`
- APKs are hosted on GitHub (Supabase Storage caps at 50MB)

### Step 5: Update ALL THREE live sources
1. **Supabase:** PUT `/storage/v1/object/ota/update.json` (service key auth)
2. **GitHub Raw:** commit `update.json` to BOTH `master` and `main` branches
3. **Firestore:** PATCH `settings/app` doc (service account auth)

### Step 6: Verify all sources
```powershell
# Supabase
(Invoke-WebRequest 'https://wmlcnmtnvjndlzahmocc.supabase.co/storage/v1/object/public/ota/update.json').Content
# GitHub Raw
(Invoke-WebRequest 'https://raw.githubusercontent.com/DharaniSoftDeveloper/MAKKAL-ARAN/main/update.json').Content
```

### Step 7: Test on device
- Close and reopen app
- Dialog should appear (unskippable if `forceUpdate: true`)
- Download → install → verify new versionCode

---

## 4. KEY CREDENTIALS & PATHS

| Item | Value |
|---|---|
| Supabase URL | `https://wmlcnmtnvjndlzahmocc.supabase.co` |
| Supabase service key | `sb_secret_***` (store in environment, never commit) |
| Supabase anon key | `sb_publishable_6tGiMpJoGE_6Z5gShel-JA_EmZUde6H` |
| GitHub repo | `DharaniSoftDeveloper/MAKKAL-ARAN` |
| Firestore project | `blind-spot-crime-detection` |
| Service account | `serviceAccountKey.json` (NOT tracked in git) |
| JDK | `C:\tools\jdk-17` |
| Android SDK | `C:\Users\dhara\AppData\Local\Android\Sdk` |
| Patrol app ID | `com.makkalaran.patrol` |
| Public app ID | `com.makkalaran.publicapp` |

---

## 5. GOTCHAS (don't repeat these)

1. **GitHub Raw CDN is slow** — after push, wait 2-3 minutes before verifying
2. **Firestore REST reads get 429 rate limits** — writes use different quota, prefer writes
3. **`forceUpdate: true` is mandatory** — otherwise "Later" suppresses forever
4. **versionCode must STRICTLY increase** — equal code = "up to date"
5. **Push to BOTH master AND main** — public app reads `main`, some refs point to `master`
6. **Dart 3.47.2 has NO record destructuring** — use `final res = ...; res.error` pattern
7. **Supabase Storage caps at 50MB** — always host APKs on GitHub Releases
8. **LAN backend (`http://192.168.1.2:3000`) is usually DOWN** — don't rely on it
9. **PowerShell mangles backslashes in paths** — use Node scripts for file ops
10. **`serviceAccountKey.json` is git-ignored** — safe, not exposed on GitHub

---

## 6. CURRENT STATE (as of 2026-09-06)

| App | Installed version | Manifest version | Status |
|---|---|---|---|
| Patrol | v1.4.0+106 | v1.4.1+107 | Update available |
| Public | v1.4.0+106 | v1.4.1+107 | Update available |

All three live sources serve v1.4.1/107 with `forceUpdate: true`.

---

*Last updated: 2026-09-06 by Cline. Created after 5+ failed OTA attempts to prevent future repetition.*
- **Fix:** Changed to `final res = await _client...; if (res.error != null) ...`
