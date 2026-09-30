@echo off
setlocal
findstr /C:"org.jetbrains.kotlin.android" android\settings.gradle
if errorlevel 1 (
  echo ERROR: Kotlin plugin declaration not found.
  exit /b 1
)
echo.
echo Kotlin plugin declaration above should show version "2.2.20".
echo Then run:
echo   flutter clean
echo   flutter pub get
echo   flutter run
