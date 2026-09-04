@echo off
:: Upload MAKKAL ARAN v1.3.4 files to Supabase Storage using API
:: Requires: SUPABASE_URL and SUPABASE_SERVICE_KEY

echo Uploading MAKKAL ARAN v1.3.4 to Supabase Storage...
echo.

:: Set variables - the service-role key MUST come from the environment,
:: never be committed to source control.
set SUPABASE_URL=https://wmlcnmtnvjndlzahmocc.supabase.co
rem Supabase service-role key (private!) - set it before running:
rem   set SUPABASE_SERVICE_KEY=your_key_here
if "%SUPABASE_SERVICE_KEY%"=="" (
    echo ERROR: SUPABASE_SERVICE_KEY environment variable is not set.
    echo Set it first:  set SUPABASE_SERVICE_KEY=your_key_here
    pause
    exit /b 1
)
set SUPABASE_KEY=%SUPABASE_SERVICE_KEY%
set BUCKET=ota

echo Uploading update.json (must match MAKKAL-ARAN-Patrol/Public-v1.3.4.apk)...
curl -X POST "%SUPABASE_URL%/storage/v1/object/%BUCKET%/update.json" ^
  -H "Authorization: Bearer %SUPABASE_KEY%" ^
  -H "Content-Type: application/json" ^
  --data-binary @"C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\update.json"

echo.
echo Uploading Patrol APK...
curl -X POST "%SUPABASE_URL%/storage/v1/object/%BUCKET%/MAKKAL-ARAN-Patrol-v1.3.4.apk" ^
  -H "Authorization: Bearer %SUPABASE_KEY%" ^
  -H "Content-Type: application/vnd.android.package-archive" ^
  --data-binary @"C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\MAKKAL-ARAN-Patrol-v1.3.4.apk"

echo.
echo Uploading Public APK...
curl -X POST "%SUPABASE_URL%/storage/v1/object/%BUCKET%/MAKKAL-ARAN-Public-v1.3.4.apk" ^
  -H "Authorization: Bearer %SUPABASE_KEY%" ^
  -H "Content-Type: application/vnd.android.package-archive" ^
  --data-binary @"C:\Users\Dhara\OneDrive\Desktop\Sample YOLO 26\MAKKAL-ARAN-Public-v1.3.4.apk"

echo.
echo Upload complete!
pause