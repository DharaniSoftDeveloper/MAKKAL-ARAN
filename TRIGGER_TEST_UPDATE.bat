@echo off
chcp 65001 >nul
cls
echo ╔══════════════════════════════════════════════════════════════════════════════╗
echo ║                                                                              ║
echo ║     🧪  MAKKAL ARAN OTA TEST UPDATE TRIGGER  🧪                              ║
echo ║                                                                              ║
echo ║     This will test if the OTA update system works!                          ║
echo ║                                                                              ║
echo ╚══════════════════════════════════════════════════════════════════════════════╝
echo.
echo ════════════════════════════════════════════════════════════════════════════════
echo STEP 1: Install v1.3.3 (the Current Manual Build)
echo ════════════════════════════════════════════════════════════════════════════════
echo.
echo Installing MakkalAran Patrol v1.3.3...
adb install -r "C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\SafeSight-Patrol-v1.3.3.apk"
echo.
echo Installing MakkalAran Public v1.3.3...
adb install -r "C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\SafeSight-Public-v1.3.3.apk"
echo.
echo ════════════════════════════════════════════════════════════════════════════════
echo STEP 2: Check Installed Versions
echo ════════════════════════════════════════════════════════════════════════════════
echo.
echo Checking installed app versions...
adb shell dumpsys package com.makkalaran.patrol | findstr "versionName"
adb shell dumpsys package com.makkalaran.publicapp | findstr "versionName"
echo.
echo ════════════════════════════════════════════════════════════════════════════════
echo STEP 3: Publish v1.3.4 (Build + Upload)
echo ════════════════════════════════════════════════════════════════════════════════
echo.
echo 1. Build the NEW APKs (versionCode must be 104):
echo    cd apps\public  ^&^&  flutter build apk --release
echo    cd apps\patrol  ^&^&  flutter build apk --release
echo.
echo 2. Upload to GitHub Releases as tag v1.3.4 (run UPLOAD_TO_GITHUB.bat):
echo    - MAKKAL-ARAN-Patrol-v1.3.4.apk
echo    - MAKKAL-ARAN-Public-v1.3.4.apk
echo.
echo 3. Upload update.json to GitHub main branch AND Supabase ota bucket
echo    (run UPLOAD_TO_SUPABASE.bat).
echo.
echo ════════════════════════════════════════════════════════════════════════════════
echo STEP 4: Test OTA Update (103 -^> 104)
echo ════════════════════════════════════════════════════════════════════════════════
echo.
echo 1. Open MakkalAran Patrol app, wait 3 seconds
echo 2. You should see: "Update available - v1.3.4"
echo 3. Tap "Update now" -^> download -^> INSTALL
echo 4. Reopen app -^> NO update prompt (installed 104 == server 104) <- LOOP FIXED
echo.
echo ════════════════════════════════════════════════════════════════════════════════
echo STEP 5: Verify Update Loop Is Gone
echo ════════════════════════════════════════════════════════════════════════════════
echo.
echo Close and reopen the app multiple times. There must be NO update dialog.
echo Then bump the manifest versionCode to 105 temporarily to confirm the prompt
echo comes back only for a genuinely newer release.
echo.
echo ✅ EXPECTED:  103 -^> 104 = UPDATE  ^|  104 -^> 104 = NO UPDATE  ^|  104 -^> 105 = UPDATE
echo.
dir /b "C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\MAKKAL-ARAN-*.apk"
echo.
PAUSE
