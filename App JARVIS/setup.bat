@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo [JARVIS] Checking Flutter...
where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found in PATH.
  echo Install Flutter and add flutter\bin to PATH, then run this file again.
  pause
  exit /b 1
)

if not exist android\gradlew.bat (
  echo [JARVIS] Creating the platform scaffold for the Flutter version installed on this PC...
  if exist .jarvis_backup rmdir /s /q .jarvis_backup
  mkdir .jarvis_backup\android\app\src\main\kotlin\com\jarvis\smartclock >nul 2>nul
  mkdir .jarvis_backup\android\app\src\main\res\values >nul 2>nul
  mkdir .jarvis_backup\android\app\src\main\res\drawable >nul 2>nul
  mkdir .jarvis_backup\ios\Runner >nul 2>nul
  copy /Y android\settings.gradle .jarvis_backup\android\settings.gradle >nul
  copy /Y android\build.gradle .jarvis_backup\android\build.gradle >nul
  copy /Y android\gradle.properties .jarvis_backup\android\gradle.properties >nul
  copy /Y android\app\build.gradle .jarvis_backup\android\app\build.gradle >nul
  copy /Y android\app\src\main\AndroidManifest.xml .jarvis_backup\android\app\src\main\AndroidManifest.xml >nul
  copy /Y android\app\src\main\kotlin\com\jarvis\smartclock\MainActivity.kt .jarvis_backup\android\app\src\main\kotlin\com\jarvis\smartclock\MainActivity.kt >nul
  copy /Y android\app\src\main\res\values\styles.xml .jarvis_backup\android\app\src\main\res\values\styles.xml >nul
  copy /Y android\app\src\main\res\drawable\launch_background.xml .jarvis_backup\android\app\src\main\res\drawable\launch_background.xml >nul
  copy /Y ios\Runner\Info.plist .jarvis_backup\ios\Runner\Info.plist >nul

  flutter create --platforms=android,ios .
  if errorlevel 1 (
    echo Flutter platform generation failed.
    pause
    exit /b 1
  )

  copy /Y .jarvis_backup\android\settings.gradle android\settings.gradle >nul
  copy /Y .jarvis_backup\android\build.gradle android\build.gradle >nul
  copy /Y .jarvis_backup\android\gradle.properties android\gradle.properties >nul
  copy /Y .jarvis_backup\android\app\build.gradle android\app\build.gradle >nul
  copy /Y .jarvis_backup\android\app\src\main\AndroidManifest.xml android\app\src\main\AndroidManifest.xml >nul
  copy /Y .jarvis_backup\android\app\src\main\kotlin\com\jarvis\smartclock\MainActivity.kt android\app\src\main\kotlin\com\jarvis\smartclock\MainActivity.kt >nul
  copy /Y .jarvis_backup\android\app\src\main\res\values\styles.xml android\app\src\main\res\values\styles.xml >nul
  copy /Y .jarvis_backup\android\app\src\main\res\drawable\launch_background.xml android\app\src\main\res\drawable\launch_background.xml >nul
  copy /Y .jarvis_backup\ios\Runner\Info.plist ios\Runner\Info.plist >nul
  rmdir /s /q .jarvis_backup
)

echo [JARVIS] Getting packages...
flutter pub get
if errorlevel 1 (
  echo Package installation failed.
  pause
  exit /b 1
)

echo.
echo [JARVIS] Setup complete.
echo Run: flutter run
pause
