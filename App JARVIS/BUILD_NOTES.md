# JARVIS build notes

This project was assembled against current package APIs available in September 2026.

Current package pins used:
- flutter_blue_plus 2.3.12
- speech_to_text 7.4.0
- flutter_tts 4.2.5
- flutter_local_notifications 22.3.1
- permission_handler 13.0.2
- shared_preferences 2.5.5
- http 1.6.0

The execution environment used to assemble this archive does not contain the Flutter SDK, so a local `flutter analyze` / `flutter build` could not be executed here. `setup.bat` generates the platform wrapper with the Flutter version installed on the user's machine before resolving packages.

For the cleanest first run, use Flutter 3.38+ and Android Studio with Android SDK 36 installed.
