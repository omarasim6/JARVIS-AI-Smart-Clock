# JARVIS Smart Clock Companion

Flutter companion app for the JARVIS ESP32 smart clock.

## Included

- Exact light/dark visual system based on the supplied prototype.
- Devices, Manage JARVIS, Device Management, Profile, Notifications, Alarms and AI screens.
- BLE connection to the JARVIS ESP32 firmware.
- Alarm add/edit/delete/snooze/stop controls.
- Clock screen, unit, timezone, hourly chime, connection sounds and factory reset controls.
- Phone speech-to-text and text-to-speech.
- Foreground wake-word mode using the phone speech recognizer.
- Optional local Ollama AI for general questions. No paid API key is required.
- Local notifications for JARVIS BLE events.
- Persistent app settings.

## Run on Windows

1. Install Flutter 3.38+ and make sure `flutter` works in a terminal.
2. Open this folder in Cursor.
3. Double-click `setup.bat`. It generates the current Flutter Android/iOS platform wrapper, restores the JARVIS-specific native configuration, and runs `flutter pub get`.
4. Connect your Android phone and run `flutter run`.
5. Give Bluetooth, microphone, speech recognition and notification permissions.

If you already have a complete Flutter platform wrapper in the project, you can skip `setup.bat` and run `flutter pub get` followed by `flutter run`.

## BLE firmware contract

The app uses the UUIDs from the JARVIS firmware:

- Service: `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
- RX/write: `beb5483e-36e1-4688-b7f5-ea07361b26a8`
- TX/notify: `cba1d466-344c-4be3-ab3f-189f4b5b8a3f`
- Device name: `JARVIS`

Commands are newline-terminated. The app sends the V3 command set discussed for the firmware, including `GET:STATE`, `GET:ALARMS`, `SET:UNIT:C/F`, `SET:TIMEZONE:<id>`, `SET:SCREEN:CLOCK/ALARMS`, `SET:SNOOZE:<minutes>`, `SNOOZE`, `STOP_ALARM`, `FACTORY_RESET`, `ADD:...`, `EDIT:...`, `DELETE:...` and `TIME:<unix>`.

## AI setup

The app handles device commands locally. For general questions, open **Profile → AI** and configure your local Ollama server and model. The app uses Ollama’s local chat API and does not require an API key.

Default Android emulator endpoint:
`http://10.0.2.2:11434/api/chat`

For a physical Android phone, replace `10.0.2.2` with the computer’s local network IP address running Ollama.
On Windows, run `START_OLLAMA_FOR_JARVIS.bat` in the project folder to configure Ollama for LAN access and open TCP port 11434.

Default model:
`gpt-4o-mini`

For a production deployment, put the AI call behind your own backend rather than shipping a provider API key inside a mobile application.

## Wake word note

The included wake mode uses the phone's speech recognizer and listens for short foreground sessions. It is intentionally not described as a true always-on background wake-word engine. A production always-listening "Jarvis" wake word should use a dedicated on-device wake-word SDK and a platform foreground/background audio service.
