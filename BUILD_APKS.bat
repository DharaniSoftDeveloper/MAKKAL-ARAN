@echo off
chcp 65001 >nul
echo ================================================================
echo   MAKKAL ARAN v1.3.4 - Build Release APKs (versionCode 104)
echo ================================================================
echo.
echo 1. Build Public app...
pushd "%~dp0apps\public"
call flutter pub get
call flutter build apk --release
popd

echo.
echo 2. Build Patrol app...
pushd "%~dp0apps\patrol"
call flutter pub get
call flutter build apk --release
popd

echo.
echo 3. Copy APKs to repo root with release names...
copy /Y "%~dp0apps\public\build\app\outputs\flutter-apk\app-release.apk" "%~dp0MAKKAL-ARAN-Public-v1.3.4.apk"
copy /Y "%~dp0apps\patrol\build\app\outputs\flutter-apk\app-release.apk" "%~dp0MAKKAL-ARAN-Patrol-v1.3.4.apk"

echo.
echo ================================================================
echo  DONE - Verify versionCode before uploading:
echo    aapt dump badging "%~dp0MAKKAL-ARAN-Public-v1.3.4.apk" | findstr version
echo    aapt dump badging "%~dp0MAKKAL-ARAN-Patrol-v1.3.4.apk" | findstr version
echo    (Or: apkanalyzer manifest version-code ...apk)
echo.
echo  Next: run UPLOAD_TO_GITHUB.bat  and  UPLOAD_TO_SUPABASE.bat
echo ================================================================
pause