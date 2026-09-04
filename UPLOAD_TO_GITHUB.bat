@echo off
:: Upload MAKKAL ARAN v1.3.4 to GitHub Releases
:: Run this file to automatically upload APKs (build them first!)

echo ==========================================
echo  MAKKAL ARAN v1.3.4 - GitHub Release Upload
echo ==========================================
echo.

:: Check if authenticated
gh auth status >nul 2>&1
if errorlevel 1 (
    echo You need to login to GitHub first.
    echo Run: gh auth login
    pause
    exit /b 1
)

echo Creating release v1.3.4...
gh release create v1.3.4 --title "MAKKAL ARAN v1.3.4 - OTA Update-Loop Fix" --notes "Update loop fixed - apps now read their real installed version" --repo DharaniSoftDeveloper/MAKKAL-ARAN

echo.
echo Uploading Patrol APK...
gh release upload v1.3.4 "C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\MAKKAL-ARAN-Patrol-v1.3.4.apk" --repo DharaniSoftDeveloper/MAKKAL-ARAN

echo.
echo Uploading Public APK...
gh release upload v1.3.4 "C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\MAKKAL-ARAN-Public-v1.3.4.apk" --repo DharaniSoftDeveloper/MAKKAL-ARAN

echo.
echo ==========================================
echo  UPLOAD COMPLETE!
echo ==========================================
echo.
echo URLs created:
echo - https://github.com/DharaniSoftDeveloper/MAKKAL-ARAN/releases/download/v1.3.4/MAKKAL-ARAN-Patrol-v1.3.4.apk
echo - https://github.com/DharaniSoftDeveloper/MAKKAL-ARAN/releases/download/v1.3.4/MAKKAL-ARAN-Public-v1.3.4.apk
echo.
echo REMINDER: upload update.json (repo root) to the GitHub main branch AND
echo           to Supabase Storage bucket "ota" - see UPLOAD_TO_SUPABASE.bat.
pause