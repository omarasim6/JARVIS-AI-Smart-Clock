import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

const String bleServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String bleRxUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String bleTxUuid = 'cba1d466-344c-4be3-ab3f-189f4b5b8a3f';
const String jarvisDeviceName = 'JARVIS';
const String defaultOllamaEndpoint = 'http://10.0.2.2:11434/api/chat';
const String defaultOllamaModel = 'llama3.2:3b';

const Color ink = Color(0xFF323530);
const Color stone = Color(0xFF88857D);
const Color sand = Color(0xFFE3D6CA);
const Color olive = Color(0xFF595421);
const Color darkBg = Color(0xFF111311);
const Color darkCard = Color(0xFF222522);
const Color darkSoft = Color(0xFF2C2F2B);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = JarvisController();
  await controller.initialize();
  runApp(JarvisApp(controller: controller));
}

class AlarmModel {
  int id;
  int hour;
  int minute;
  bool enabled;
  String label;

  AlarmModel({
    required this.id,
    required this.hour,
    required this.minute,
    required this.enabled,
    required this.label,
  });

  String get time {
    final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final suffix = hour >= 12 ? 'PM' : 'AM';
    return '${h12.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $suffix';
  }
}

class JarvisController extends ChangeNotifier {
  final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
  final stt.SpeechToText speech = stt.SpeechToText();
  final FlutterTts tts = FlutterTts();

  SharedPreferences? _prefs;
  BluetoothDevice? device;
  BluetoothCharacteristic? rx;
  BluetoothCharacteristic? tx;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<dynamic>? _speechStatusSub;
  Timer? _wakeTimer;
  Timer? _sensorPollTimer;
  bool _sensorRequestInFlight = false;
  String _bleBuffer = '';
  bool initialized = false;
  bool connecting = false;
  bool scanning = false;
  bool connected = false;
  bool listening = false;
  bool wakeMode = false;
  bool darkMode = false;
  bool notificationsEnabled = true;
  bool voiceEnabled = true;
  bool hourlyChime = true;
  bool connectionSounds = true;
  String temperatureUnit = 'C';
  String timezone = 'PK';
  String currentScreen = 'CLOCK';
  int snoozeMinutes = 5;
  double temperature = 0;
  double humidity = 0;
  bool hasTemperatureReading = false;
  bool hasHumidityReading = false;
  String lastDeviceEvent = 'Ready';
  String lastSeen = '--';
  String deviceModel = 'JARVIS V3';
  String ollamaEndpoint = defaultOllamaEndpoint;
  String ollamaModel = defaultOllamaModel;
  String speechLocale = 'en-US';
  final List<AlarmModel> alarms = [];
  final List<JarvisMessage> messages = [];
  final List<JarvisEvent> events = [];

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    darkMode = _prefs!.getBool('darkMode') ?? false;
    notificationsEnabled = _prefs!.getBool('notificationsEnabled') ?? true;
    voiceEnabled = _prefs!.getBool('voiceEnabled') ?? true;
    hourlyChime = _prefs!.getBool('hourlyChime') ?? true;
    connectionSounds = _prefs!.getBool('connectionSounds') ?? true;
    temperatureUnit = _prefs!.getString('temperatureUnit') ?? 'C';
    timezone = _prefs!.getString('timezone') ?? 'PK';
    currentScreen = _prefs!.getString('currentScreen') ?? 'CLOCK';
    snoozeMinutes = _prefs!.getInt('snoozeMinutes') ?? 5;
    final savedOllamaEndpoint = _prefs!.getString('ollamaEndpoint');
    if (savedOllamaEndpoint != null && savedOllamaEndpoint.trim().isNotEmpty) {
      ollamaEndpoint = savedOllamaEndpoint;
    }
    final savedOllamaModel = _prefs!.getString('ollamaModel');
    if (savedOllamaModel != null && savedOllamaModel.trim().isNotEmpty) {
      ollamaModel = savedOllamaModel;
    }
    speechLocale = _prefs!.getString('speechLocale') ?? 'en-US';
    _loadDemoAlarms();
    await _initializeNotifications();
    await _initializeTts();
    await _initializeSpeech();
    initialized = true;
    notifyListeners();
  }

  void _loadDemoAlarms() {
    final raw = _prefs?.getString('alarms_cache');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      alarms
        ..clear()
        ..addAll(list.map((e) => AlarmModel(
              id: e['id'] as int,
              hour: e['hour'] as int,
              minute: e['minute'] as int,
              enabled: e['enabled'] as bool,
              label: e['label'] as String,
            )));
    } catch (_) {}
  }

  Future<void> _saveCachedAlarms() async {
    final raw = alarms
        .map((a) => {'id': a.id, 'hour': a.hour, 'minute': a.minute, 'enabled': a.enabled, 'label': a.label})
        .toList();
    await _prefs?.setString('alarms_cache', jsonEncode(raw));
  }

  Future<void> _initializeNotifications() async {
    const android = AndroidInitializationSettings('notification_icon');
    const ios = DarwinInitializationSettings();
    await notifications.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
    final androidPlugin = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    final iosPlugin = notifications.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    const channel = AndroidNotificationChannel(
      'jarvis_events',
      'JARVIS Events',
      description: 'Notifications from your JARVIS smart clock.',
      importance: Importance.high,
    );
    await androidPlugin?.createNotificationChannel(channel);
  }

  Future<void> _initializeTts() async {
    await tts.setLanguage(speechLocale);
    await tts.setSpeechRate(0.48);
    await tts.setVolume(1.0);
    await tts.setPitch(0.95);
  }

  Future<void> _initializeSpeech() async {
    await _requestSpeechPermissions();
    await speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          listening = false;
          notifyListeners();
          if (wakeMode) _scheduleWakeCycle();
        }
      },
      onError: (_) {
        listening = false;
        notifyListeners();
        if (wakeMode) _scheduleWakeCycle();
      },
    );
  }

  Future<bool> _requestSpeechPermissions() async {
    final mic = await Permission.microphone.request();
    final speechPermission = await Permission.speech.request();
    return mic.isGranted && speechPermission.isGranted;
  }

  ThemeMode get themeMode => darkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> setDarkMode(bool value) async {
    darkMode = value;
    await _prefs?.setBool('darkMode', value);
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    await _prefs?.setBool('notificationsEnabled', value);
    notifyListeners();
  }

  Future<void> setVoiceEnabled(bool value) async {
    voiceEnabled = value;
    await _prefs?.setBool('voiceEnabled', value);
    if (!value) await stopWakeMode();
    notifyListeners();
  }

  Future<void> setOllamaConfig({String? endpoint, String? model}) async {
    if (endpoint != null && endpoint.trim().isNotEmpty) {
      ollamaEndpoint = endpoint.trim();
    }
    if (model != null && model.trim().isNotEmpty) {
      ollamaModel = model.trim();
    }
    await _prefs?.setString('ollamaEndpoint', ollamaEndpoint);
    await _prefs?.setString('ollamaModel', ollamaModel);
    notifyListeners();
  }

  Future<void> scanAndConnect() async {
    if (connecting) return;
    if (await Permission.bluetoothScan.isDenied) await Permission.bluetoothScan.request();
    if (await Permission.bluetoothConnect.isDenied) await Permission.bluetoothConnect.request();
    connecting = true;
    scanning = true;
    notifyListeners();
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 8),
      );
      _scanSub?.cancel();
      final completer = Completer<BluetoothDevice?>();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final name = result.device.platformName.trim();
          if (name.toUpperCase() == jarvisDeviceName || result.advertisementData.serviceUuids.contains(Guid(bleServiceUuid))) {
            if (!completer.isCompleted) completer.complete(result.device);
          }
        }
      });
      device = await completer.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
      await _scanSub?.cancel();
      _scanSub = null;
      await FlutterBluePlus.stopScan();
      scanning = false;
      if (device == null) {
        _addEvent('JARVIS not found', 'No nearby JARVIS BLE device was found.');
        return;
      }
      await _connectDevice(device!);
    } catch (e) {
      _addEvent('Connection failed', _cleanError(e));
    } finally {
      scanning = false;
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> _connectDevice(BluetoothDevice target) async {
    try {
      await target.connect(license: License.nonprofit, timeout: const Duration(seconds: 15), autoConnect: false);
    } catch (e) {
      final text = _cleanError(e).toLowerCase();
      if (!text.contains('already connected')) rethrow;
    }
    connected = true;
    lastSeen = _clockText();
    _connectionSub?.cancel();
    _connectionSub = target.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        connected = true;
        lastSeen = _clockText();
        notifyListeners();
      } else if (state == BluetoothConnectionState.disconnected) {
        connected = false;
        _sensorPollTimer?.cancel();
        _sensorPollTimer = null;
        _sensorRequestInFlight = false;
        _bleBuffer = '';
        rx = null;
        tx = null;
        hasTemperatureReading = false;
        hasHumidityReading = false;
        lastDeviceEvent = 'Disconnected';
        _addEvent('JARVIS disconnected', 'The clock is no longer connected to this phone.');
        notifyListeners();
      }
    });
    final services = await target.discoverServices();
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != bleServiceUuid) continue;
      for (final characteristic in service.characteristics) {
        final id = characteristic.uuid.toString().toLowerCase();
        if (id == bleRxUuid) rx = characteristic;
        if (id == bleTxUuid) tx = characteristic;
      }
    }
    if (tx != null && (tx!.properties.notify || tx!.properties.indicate)) {
      await tx!.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = tx!.onValueReceived.listen((data) => _handleBleData(utf8.decode(data, allowMalformed: true)));
    }
    lastDeviceEvent = 'Connected';
    _addEvent('JARVIS connected', 'JARVIS is online and ready.');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _startSensorPolling();
    await _requestCurrentSensorState();
    await sendCommand('GET:ALARMS');
    await sendCommand('GET:TIMEZONES');
    await syncTime();
    notifyListeners();
  }

  void _startSensorPolling() {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _requestCurrentSensorState();
    });
  }

  Future<void> _requestCurrentSensorState() async {
    if (!connected || rx == null || _sensorRequestInFlight) return;
    _sensorRequestInFlight = true;
    try {
      await sendCommand('GET:STATE');
    } finally {
      _sensorRequestInFlight = false;
    }
  }

  Future<void> disconnect() async {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = null;
    _sensorRequestInFlight = false;
    _bleBuffer = '';
    try {
      await device?.disconnect();
    } catch (_) {}
    connected = false;
    rx = null;
    tx = null;
    hasTemperatureReading = false;
    hasHumidityReading = false;
    notifyListeners();
  }

  Future<void> sendCommand(String command) async {
    if (!connected || rx == null) return;
    final bytes = Uint8List.fromList(utf8.encode('$command\n'));
    try {
      if (rx!.properties.writeWithoutResponse) {
        await rx!.write(bytes.toList(), withoutResponse: true);
      } else {
        await rx!.write(bytes.toList(), withoutResponse: false);
      }
    } catch (e) {
      _addEvent('BLE error', _cleanError(e));
    }
  }

  void _handleBleData(String raw) {
    _bleBuffer += raw.replaceAll('\r', '');
    final lines = _bleBuffer.split('\n');
    _bleBuffer = lines.removeLast();
    for (final line in lines) {
      final message = line.trim();
      if (message.isEmpty) continue;
      lastSeen = _clockText();
      lastDeviceEvent = message;
      _parseBleLine(message);
    }
    notifyListeners();
  }

  double? _parseSensorNumber(String value) {
    final match = RegExp(r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)').firstMatch(value);
    return match == null ? null : double.tryParse(match.group(0)!);
  }

  void _parseBleLine(String line) {
    final upper = line.toUpperCase();
    if (upper.startsWith('TEMP:')) {
      final parsed = _parseSensorNumber(line.substring(5));
      if (parsed != null) {
        temperature = parsed;
        hasTemperatureReading = true;
      }
    } else if (upper.startsWith('HUM:') || upper.startsWith('HUMIDITY:')) {
      final value = upper.startsWith('HUM:') ? line.substring(4) : line.substring(9);
      final parsed = _parseSensorNumber(value);
      if (parsed != null) {
        humidity = parsed;
        hasHumidityReading = true;
      }
    } else if (upper.startsWith('ALARM:RINGING')) {
      _addEvent('Alarm ringing', 'JARVIS alarm is active.');
      speak('Your JARVIS alarm is ringing.');
    } else if (upper.startsWith('ALARM:ACTIVE:')) {
      _addEvent('Alarm active', line);
    } else if (upper.startsWith('TIMEZONE:')) {
      timezone = line.substring(9).trim();
    } else if (upper.startsWith('UNIT:')) {
      temperatureUnit = line.substring(5).trim().toUpperCase();
    } else if (upper.startsWith('SCREEN:')) {
      currentScreen = line.substring(7).trim().toUpperCase();
    } else if (upper.startsWith('STATE:')) {
      _parseState(line.substring(6));
    } else if (upper.startsWith('ALARM:')) {
      _parseAlarmLine(line);
    } else if (upper.contains('FACTORY') && upper.contains('RESET')) {
      _addEvent('Factory reset', 'JARVIS settings were reset.');
    }
  }

  void _parseState(String value) {
    final parts = value.split(RegExp(r'[;|,]'));
    for (final part in parts) {
      final kv = part.split('=');
      if (kv.length < 2) continue;
      final key = kv.first.trim().toUpperCase();
      final val = kv.sublist(1).join('=').trim();
      if (key == 'TEMP') {
        final parsed = _parseSensorNumber(val);
        if (parsed != null) {
          temperature = parsed;
          hasTemperatureReading = true;
        }
      }
      if (key == 'HUM' || key == 'HUMIDITY') {
        final parsed = _parseSensorNumber(val);
        if (parsed != null) {
          humidity = parsed;
          hasHumidityReading = true;
        }
      }
      if (key == 'UNIT') temperatureUnit = val.toUpperCase();
      if (key == 'TIMEZONE') timezone = val;
      if (key == 'SCREEN') currentScreen = val.toUpperCase();
      if (key == 'SNOOZE') snoozeMinutes = int.tryParse(val) ?? snoozeMinutes;
    }
  }

  void _parseAlarmLine(String line) {
    // Accepts common forms such as ALARM:0:07:30:1:Wake Up or ALARM:0,07,30,1,Wake Up.
    final data = line.substring(6).replaceAll(',', ':');
    final parts = data.split(':');
    if (parts.length < 4) return;
    final id = int.tryParse(parts[0]);
    final hour = int.tryParse(parts[1]);
    final minute = int.tryParse(parts[2]);
    if (id == null || hour == null || minute == null) return;
    final enabled = parts[3] == '1' || parts[3].toLowerCase() == 'true';
    final label = parts.length > 4 ? parts.sublist(4).join(':') : 'Alarm';
    final existing = alarms.where((a) => a.id == id).toList();
    if (existing.isEmpty) {
      alarms.add(AlarmModel(id: id, hour: hour, minute: minute, enabled: enabled, label: label));
    } else {
      final alarm = existing.first;
      alarm.hour = hour;
      alarm.minute = minute;
      alarm.enabled = enabled;
      alarm.label = label;
    }
    _saveCachedAlarms();
  }

  Future<void> syncTime() async {
    if (!connected) return;
    final nowUtc = DateTime.now().toUtc();
    await sendCommand('TIME:${nowUtc.millisecondsSinceEpoch ~/ 1000}');
  }

  Future<void> addAlarm({required TimeOfDay time, required String label}) async {
    final id = _nextAlarmId();
    final alarm = AlarmModel(id: id, hour: time.hour, minute: time.minute, enabled: true, label: label.isEmpty ? 'Alarm' : label);
    alarms.add(alarm);
    await _saveCachedAlarms();
    await sendCommand('ADD:${_two(time.hour)}:${_two(time.minute)}:1:${alarm.label}');
    notifyListeners();
  }

  Future<void> editAlarm(AlarmModel alarm) async {
    await _saveCachedAlarms();
    await sendCommand('EDIT:${alarm.id}:${_two(alarm.hour)}:${_two(alarm.minute)}:${alarm.enabled ? 1 : 0}:${alarm.label}');
    notifyListeners();
  }

  Future<void> deleteAlarm(AlarmModel alarm) async {
    alarms.removeWhere((a) => a.id == alarm.id);
    await _saveCachedAlarms();
    await sendCommand('DELETE:${alarm.id}');
    notifyListeners();
  }

  Future<void> setAlarmEnabled(AlarmModel alarm, bool value) async {
    alarm.enabled = value;
    await editAlarm(alarm);
  }

  Future<void> setUnit(String value) async {
    temperatureUnit = value;
    await _prefs?.setString('temperatureUnit', value);
    await sendCommand('SET:UNIT:$value');
    notifyListeners();
  }

  Future<void> setTimezone(String value) async {
    timezone = value;
    await _prefs?.setString('timezone', value);
    await sendCommand('SET:TIMEZONE:$value');
    notifyListeners();
  }

  Future<void> setScreen(String value) async {
    currentScreen = value;
    await _prefs?.setString('currentScreen', value);
    await sendCommand('SET:SCREEN:$value');
    notifyListeners();
  }

  Future<void> setSnooze(int value) async {
    snoozeMinutes = value;
    await _prefs?.setInt('snoozeMinutes', value);
    await sendCommand('SET:SNOOZE:$value');
    notifyListeners();
  }

  Future<void> setHourlyChime(bool value) async {
    hourlyChime = value;
    await _prefs?.setBool('hourlyChime', value);
    await sendCommand('SET:HOURLY:$value');
    notifyListeners();
  }

  Future<void> setConnectionSounds(bool value) async {
    connectionSounds = value;
    await _prefs?.setBool('connectionSounds', value);
    await sendCommand('SET:CONNECTION_SOUNDS:$value');
    notifyListeners();
  }

  Future<void> factoryReset() async {
    await sendCommand('FACTORY_RESET');
    alarms.clear();
    currentScreen = 'CLOCK';
    temperatureUnit = 'C';
    timezone = 'PK';
    snoozeMinutes = 5;
    hourlyChime = true;
    connectionSounds = true;
    await _prefs?.remove('alarms_cache');
    await _prefs?.setString('temperatureUnit', temperatureUnit);
    await _prefs?.setString('timezone', timezone);
    await _prefs?.setString('currentScreen', currentScreen);
    await _prefs?.setInt('snoozeMinutes', snoozeMinutes);
    notifyListeners();
  }

  int _nextAlarmId() {
    for (var i = 0; i < 10; i++) {
      if (!alarms.any((a) => a.id == i)) return i;
    }
    return alarms.length;
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  String _clockText() {
    final now = DateTime.now();
    final h = now.hour == 0 ? 12 : (now.hour > 12 ? now.hour - 12 : now.hour);
    final suffix = now.hour >= 12 ? 'PM' : 'AM';
    return '${_two(h)}:${_two(now.minute)} $suffix';
  }

  Future<void> speak(String text) async {
    if (!voiceEnabled) return;
    await tts.stop();
    await tts.speak(text);
  }

  Future<void> listenForCommand({bool detectWakeWord = false}) async {
    if (!voiceEnabled) return;
    if (!speech.isAvailable) {
      await _initializeSpeech();
    }
    if (listening) {
      await speech.stop();
      listening = false;
      notifyListeners();
      return;
    }
    final granted = await _requestSpeechPermissions();
    if (!granted) {
      _addEvent('Microphone permission', 'Allow microphone and speech recognition in Settings.');
      return;
    }
    listening = true;
    notifyListeners();
    await speech.listen(
      onResult: (result) async {
        final text = result.recognizedWords.trim();
        if (text.isEmpty) return;
        if (detectWakeWord) {
          if (_containsWakeWord(text)) {
            await speech.stop();
            listening = false;
            wakeMode = false;
            notifyListeners();
            await speak('Yes?');
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await listenForCommand();
          }
        } else if (result.finalResult) {
          await speech.stop();
          listening = false;
          notifyListeners();
          await processUserText(text, fromVoice: true);
        }
      },
      localeId: speechLocale,
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
      ),
      listenFor: const Duration(seconds: 7),
      pauseFor: const Duration(seconds: 2),
    );
  }

  bool _containsWakeWord(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), ' ');
    return normalized.contains('jarvis') || normalized.contains('jarvis'.replaceAll(' ', ''));
  }

  Future<void> startWakeMode() async {
    if (!voiceEnabled) return;
    wakeMode = true;
    notifyListeners();
    await speak('Wake mode enabled. Say Jarvis.');
    _scheduleWakeCycle(delay: const Duration(milliseconds: 500));
  }

  Future<void> stopWakeMode() async {
    wakeMode = false;
    _wakeTimer?.cancel();
    await speech.stop();
    listening = false;
    notifyListeners();
  }

  void _scheduleWakeCycle({Duration delay = const Duration(milliseconds: 250)}) {
    _wakeTimer?.cancel();
    if (!wakeMode) return;
    _wakeTimer = Timer(delay, () {
      if (wakeMode && !listening) listenForCommand(detectWakeWord: true);
    });
  }

  bool _isDeviceCommand(String text) {
    final lower = text.toLowerCase();
    const keys = [
      'alarm',
      'snooze',
      'stop alarm',
      'factory reset',
      'clock screen',
      'alarm screen',
      'celsius',
      'fahrenheit',
      'temperature',
      'humidity',
      'timezone',
      'time zone',
      'hourly chime',
      'jarvis status',
      'connect jarvis',
    ];
    return keys.any(lower.contains);
  }

  Future<void> processUserText(String text, {bool fromVoice = false}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    messages.add(JarvisMessage(text: clean, fromUser: true, time: DateTime.now()));
    notifyListeners();
    final response = await _handleLocalIntent(clean);
    if (response != null) {
      messages.add(JarvisMessage(text: response, fromUser: false, time: DateTime.now()));
      notifyListeners();
      if (fromVoice) await speak(response);
      return;
    }
    if (_isDeviceCommand(clean)) {
      const response = 'I could not map that device command. Try “set an alarm for 7:30”, “show alarms”, or “switch to clock”.';
      messages.add(JarvisMessage(text: response, fromUser: false, time: DateTime.now()));
      notifyListeners();
      if (fromVoice) await speak(response);
      return;
    }
    final answer = await _askAi(clean);
    messages.add(JarvisMessage(text: answer, fromUser: false, time: DateTime.now()));
    notifyListeners();
    if (fromVoice) await speak(answer);
  }

  Future<String?> _handleLocalIntent(String text) async {
    final lower = text.toLowerCase();
    if (lower.contains('what time') || lower == 'time') {
      return 'It is ${_clockText()}.';
    }
    if (lower.contains('show alarms') || lower.contains('list alarms')) {
      if (alarms.isEmpty) return 'There are no saved alarms.';
      return alarms.map((a) => '${a.time} ${a.label}${a.enabled ? '' : ' disabled'}').join('. ');
    }
    if (lower.contains('stop alarm') || lower.contains('dismiss alarm')) {
      await sendCommand('STOP_ALARM');
      return 'Alarm stopped.';
    }
    if (lower.contains('snooze')) {
      await sendCommand('SNOOZE');
      return 'Alarm snoozed for $snoozeMinutes minutes.';
    }
    if (lower.contains('clock screen') || lower.contains('show clock')) {
      await setScreen('CLOCK');
      return 'Clock screen selected.';
    }
    if (lower.contains('alarm screen') || lower.contains('show alarms screen')) {
      await setScreen('ALARMS');
      return 'Alarm screen selected.';
    }
    if (lower.contains('celsius')) {
      await setUnit('C');
      return 'Temperature is now in Celsius.';
    }
    if (lower.contains('fahrenheit')) {
      await setUnit('F');
      return 'Temperature is now in Fahrenheit.';
    }
    if (lower.contains('temperature')) {
      final unit = temperatureUnit == 'C' ? 'degrees Celsius' : 'degrees Fahrenheit';
      return 'The latest JARVIS temperature is ${temperature.toStringAsFixed(1)} $unit.';
    }
    if (lower.contains('humidity')) {
      return 'The latest humidity is ${humidity.toStringAsFixed(0)} percent.';
    }
    final alarmMatch = RegExp(r'(?:set|add|create).*alarm.*?(\d{1,2})(?::|\s)(\d{2})?\s*(am|pm)?', caseSensitive: false).firstMatch(lower);
    if (alarmMatch != null) {
      var hour = int.tryParse(alarmMatch.group(1)!) ?? 0;
      final minute = int.tryParse(alarmMatch.group(2) ?? '0') ?? 0;
      final ampm = alarmMatch.group(3)?.toLowerCase();
      if (ampm == 'pm' && hour < 12) hour += 12;
      if (ampm == 'am' && hour == 12) hour = 0;
      if (hour <= 23 && minute <= 59) {
        await addAlarm(time: TimeOfDay(hour: hour, minute: minute), label: 'JARVIS Alarm');
        return 'Alarm set for ${AlarmModel(id: 0, hour: hour, minute: minute, enabled: true, label: '').time}.';
      }
    }
    if (lower.contains('factory reset')) {
      await factoryReset();
      return 'JARVIS has been reset. Your clock time was preserved.';
    }
    if (lower.contains('jarvis status') || lower == 'status') {
      return connected ? 'JARVIS is connected. Temperature is ${temperature.toStringAsFixed(1)} degrees and humidity is ${humidity.toStringAsFixed(0)} percent.' : 'JARVIS is currently disconnected.';
    }
    return null;
  }

  Uri _ollamaChatUri() {
    var raw = ollamaEndpoint.trim();
    if (raw.isEmpty) raw = defaultOllamaEndpoint;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    raw = raw.replaceFirst(RegExp(r'/+$'), '');
    if (raw.endsWith('/api/chat')) return Uri.parse(raw);
    if (raw.endsWith('/api')) return Uri.parse('$raw/chat');
    return Uri.parse('$raw/api/chat');
  }

  Future<String> _askAi(String prompt) async {
    final endpoint = ollamaEndpoint.trim();
    final modelName = ollamaModel.trim();
    if (endpoint.isEmpty || modelName.isEmpty) {
      return 'Ollama is not configured. Open Profile → AI settings and enter your Ollama address and model.';
    }

    final uri = _ollamaChatUri();
    final client = http.Client();
    try {
      // Check the Ollama server first. This avoids waiting a full minute when
      // the phone cannot reach the computer running Ollama.
      try {
        final tagsUri = uri.replace(path: '/api/tags', query: '');
        final probe = await client.get(tagsUri).timeout(const Duration(seconds: 5));
        if (probe.statusCode < 200 || probe.statusCode >= 300) {
          return 'Ollama is reachable, but its server returned HTTP ${probe.statusCode}. Make sure Ollama is running.';
        }
      } on TimeoutException {
        return 'JARVIS could not reach Ollama at ${uri.host}:${uri.port}. If this is a physical Android phone, make sure the phone and PC are on the same Wi-Fi and Ollama is listening on 0.0.0.0:11434.';
      } on SocketException catch (e) {
        return 'JARVIS could not connect to Ollama at ${uri.host}:${uri.port}. Ollama is likely listening only on localhost. Start Ollama with OLLAMA_HOST=0.0.0.0:11434 and allow TCP port 11434 through Windows Firewall. (${e.message})';
      }

      final response = await client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': modelName,
              'messages': [
                {
                  'role': 'system',
                  'content': 'You are JARVIS, a concise, calm phone assistant for a smart clock. Answer naturally. Never claim to have performed a device action unless the app confirms it.'
                },
                {'role': 'user', 'content': prompt}
              ],
              'stream': false,
              'options': {'temperature': 0.4},
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 404) {
          return 'Ollama could not find the model "$modelName". Run `ollama pull $modelName` on the Ollama computer, then try again.';
        }
        return 'Ollama returned HTTP ${response.statusCode}. ${response.body.isNotEmpty ? response.body : 'Check that the Ollama server is running.'}';
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return 'Ollama returned an unexpected response.';
      }
      final message = decoded['message'];
      final content = message is Map<String, dynamic> ? message['content']?.toString() : null;
      return content?.trim().isNotEmpty == true
          ? content!.trim()
          : 'Ollama did not return a usable answer.';
    } on TimeoutException {
      return 'Ollama connected, but the model took too long to answer. Check that "$modelName" is installed and that the Ollama computer has enough resources.';
    } on SocketException catch (e) {
      return 'JARVIS lost its connection to Ollama at ${uri.host}:${uri.port}. (${e.message})';
    } on FormatException {
      return 'Ollama returned invalid JSON. Restart Ollama and try again.';
    } catch (e) {
      return 'JARVIS could not complete the Ollama request. ${_cleanError(e)}';
    } finally {
      client.close();
    }
  }

  void _addEvent(String title, String body) {
    events.insert(0, JarvisEvent(title: title, body: body, time: DateTime.now()));
    if (events.length > 50) events.removeLast();
    if (notificationsEnabled) _showNotification(title, body);
    notifyListeners();
  }

  Future<void> _showNotification(String title, String body) async {
    final details = NotificationDetails(
      android: const AndroidNotificationDetails(
        'jarvis_events',
        'JARVIS Events',
        channelDescription: 'Notifications from JARVIS.',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await notifications.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  String _cleanError(Object error) {
    final text = error.toString();
    return text.replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
  }

  @override
  void dispose() {
    _wakeTimer?.cancel();
    _scanSub?.cancel();
    _connectionSub?.cancel();
    _notifySub?.cancel();
    _speechStatusSub?.cancel();
    _sensorPollTimer?.cancel();
    _bleBuffer = '';
    tts.stop();
    super.dispose();
  }
}

class JarvisMessage {
  final String text;
  final bool fromUser;
  final DateTime time;
  JarvisMessage({required this.text, required this.fromUser, required this.time});
}

class JarvisEvent {
  final String title;
  final String body;
  final DateTime time;
  JarvisEvent({required this.title, required this.body, required this.time});
}

extension FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class JarvisApp extends StatefulWidget {
  final JarvisController controller;
  const JarvisApp({super.key, required this.controller});

  @override
  State<JarvisApp> createState() => _JarvisAppState();
}

class _JarvisAppState extends State<JarvisApp> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.controller.themeMode;
    widget.controller.addListener(_handleControllerChanged);
  }

  void _handleControllerChanged() {
    final nextThemeMode = widget.controller.themeMode;
    if (nextThemeMode == _themeMode || !mounted) return;
    setState(() {
      _themeMode = nextThemeMode;
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JARVIS',
      themeMode: _themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: AppShell(controller: widget.controller),
    );
  }
}

class AppTheme {
  static ThemeData light() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFDFBF9),
        colorScheme: ColorScheme.fromSeed(seedColor: olive, brightness: Brightness.light).copyWith(primary: olive, surface: const Color(0xFFFDFBF9)),
        fontFamily: 'sans',
        dividerColor: sand.withOpacity(.65),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: ink, centerTitle: true),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: darkBg,
        colorScheme: ColorScheme.fromSeed(seedColor: olive, brightness: Brightness.dark).copyWith(primary: sand, surface: darkBg),
        fontFamily: 'sans',
        dividerColor: darkSoft,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.white, centerTitle: true),
      );
}

class AppShell extends StatefulWidget {
  final JarvisController controller;
  const AppShell({super.key, required this.controller});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DevicesPage(controller: widget.controller, openManage: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ManageJarvisPage(controller: widget.controller)))),
      DeviceManagementPage(controller: widget.controller),
      ProfilePage(controller: widget.controller),
    ];
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: AppNavBar(
        index: tab,
        onChanged: (value) => setState(() => tab = value),
      ),
    );
  }
}

class AppNavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;
  const AppNavBar({super.key, required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(22, 0, 22, 20),
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: dark ? darkCard : sand.withOpacity(.75),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _navItem(context, 0, Icons.home_outlined),
            _navItem(context, 1, Icons.settings_outlined),
            _navItem(context, 2, Icons.person_outline),
          ],
        ),
      ),
    );
  }

  Widget _navItem(BuildContext context, int item, IconData icon) {
    final selected = item == index;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => onChanged(item),
      child: SizedBox(
        width: 90,
        height: 58,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? olive : (dark ? darkSoft : const Color(0xFFF7F1EB)),
            ),
            child: Icon(icon, size: 21, color: selected ? Colors.white : (dark ? Colors.white70 : ink)),
          ),
        ),
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onNotification;
  const PageHeader({super.key, required this.title, this.onBack, this.onNotification});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -.3),
              ),
            ),
          ),
          if (onBack != null)
            Positioned(
              top: 0,
              left: 8,
              child: IconButton(
                onPressed: onBack,
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
            ),
          if (onNotification != null)
            Positioned(
              top: 4,
              right: 18,
              child: IconButton(
                onPressed: onNotification,
                icon: const Icon(Icons.notifications_none_rounded, size: 26),
              ),
            ),
        ],
      ),
    );
  }
}

class DevicesPage extends StatelessWidget {
  final JarvisController controller;
  final VoidCallback openManage;
  const DevicesPage({super.key, required this.controller, required this.openManage});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final connected = controller.connected;
        return ListView(
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            PageHeader(title: 'Devices', onNotification: () => _showNotifications(context, controller)),
            const SizedBox(height: 42),
            DeviceHero(connected: connected),
            const SizedBox(height: 12),
            Text('JARVIS', textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -.7)),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: 11, height: 11, decoration: BoxDecoration(color: connected ? Colors.green.shade700 : Colors.grey.shade300, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Text(connected ? 'Connected' : 'Disconnected', style: TextStyle(fontSize: 17, color: connected ? Colors.green.shade700 : stone, fontWeight: FontWeight.w600)),
            ]),
            if (connected) ...[
              const SizedBox(height: 24),
              _DeviceQuickSummary(controller: controller),
              const SizedBox(height: 30),
            ] else
              const SizedBox(height: 55),
            Center(
              child: AppButton(
                label: connected ? 'MANAGE  ›' : (controller.scanning ? 'SEARCHING…' : 'CONNECT'),
                onTap: controller.scanning ? null : (connected ? openManage : controller.scanAndConnect),
                width: 224,
              ),
            ),
            const SizedBox(height: 28),
          ],
        );
      },
    );
  }
}

class DeviceHero extends StatelessWidget {
  final bool connected;
  const DeviceHero({super.key, required this.connected});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 245,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 330,
            height: 150,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(100),
              boxShadow: connected ? [BoxShadow(color: Colors.green.withOpacity(.35), blurRadius: 42, spreadRadius: 15)] : [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 22, spreadRadius: 3)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 25),
            child: Image.asset('assets/jarvis_device.png', fit: BoxFit.contain, height: 230),
          ),
        ],
      ),
    );
  }
}

class _DeviceQuickSummary extends StatelessWidget {
  final JarvisController controller;
  const _DeviceQuickSummary({required this.controller});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(children: [
        Expanded(child: InfoChip(
          icon: Icons.thermostat_outlined,
          label: 'Temperature',
          value: controller.hasTemperatureReading ? '${controller.temperature.toStringAsFixed(1)}°${controller.temperatureUnit}' : '--',
        )),
        const SizedBox(width: 10),
        Expanded(child: InfoChip(
          icon: Icons.water_drop_outlined,
          label: 'Humidity',
          value: controller.hasHumidityReading ? '${controller.humidity.toStringAsFixed(0)}%' : '--',
        )),
      ]),
    );
  }
}

class InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const InfoChip({super.key, required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(context),
      child: Row(children: [Icon(icon, size: 19), const SizedBox(width: 9), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 10, color: stone)), Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))]))]),
    );
  }
}

class ManageJarvisPage extends StatelessWidget {
  final JarvisController controller;

  const ManageJarvisPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                PageHeader(
                  title: 'Manage JARVIS',
                  onBack: () => Navigator.of(context).pop(),
                  onNotification: () => _showNotifications(context, controller),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                    children: [
                      _manageDeviceCard(context, controller),
                      const SizedBox(height: 12),
                      _dots(),
                      const SizedBox(height: 22),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.25,
                        children: [
                          ActionTile(
                            icon: Icons.psychology_outlined,
                            label: 'AI',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatPage(controller: controller),
                              ),
                            ),
                          ),
                          ActionTile(
                            icon: Icons.schedule_outlined,
                            label: 'Clock settings',
                            onTap: () => _showClockSettings(context, controller),
                          ),
                          ActionTile(
                            icon: Icons.restart_alt_rounded,
                            label: 'Factory Reset',
                            onTap: () => _confirmReset(context, controller),
                          ),
                          ActionTile(
                            icon: Icons.alarm_outlined,
                            label: 'Alarm',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AlarmPage(controller: controller),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _manageDeviceCard(BuildContext context, JarvisController c) {
    return Container(
      height: 168,
      padding: const EdgeInsets.all(12),
      decoration: cardDecoration(context, radius: 20),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Image.asset('assets/jarvis_device.png', fit: BoxFit.contain),
          ),
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'JARVIS',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: c.connected ? Colors.green : stone,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      c.connected ? 'Connected' : 'Disconnected',
                      style: TextStyle(
                        color: c.connected ? Colors.green.shade700 : stone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  c.connected ? 'Online • ${c.lastSeen}' : 'Offline',
                  style: const TextStyle(fontSize: 11, color: stone),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: stone,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: sand,
            shape: BoxShape.circle,
          ),
        ),
      ],
    );
  }
}

class DeviceManagementPage extends StatelessWidget {
  final JarvisController controller;
  const DeviceManagementPage({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final rows = <Widget>[
          DeviceCardHeader(controller: controller),
          SettingRow(icon: Icons.desktop_windows_outlined, title: 'Display / Screen', subtitle: controller.currentScreen == 'CLOCK' ? 'Clock Screen' : 'Alarm Screen', onTap: () => _showScreenPicker(context, controller)),
          SettingRow(icon: Icons.thermostat, title: 'Temperature Unit', subtitle: controller.temperatureUnit == 'C' ? 'Celsius (°C)' : 'Fahrenheit (°F)', onTap: () => _showUnitPicker(context, controller)),
          SettingRow(icon: Icons.language_outlined, title: 'Timezone', subtitle: timezoneName(controller.timezone), onTap: () => _showTimezonePicker(context, controller)),
          SettingRow(icon: Icons.notifications_none_rounded, title: 'Hourly Chime', subtitle: controller.hourlyChime ? 'On' : 'Off', trailing: Switch.adaptive(value: controller.hourlyChime, onChanged: controller.setHourlyChime)),
          SettingRow(icon: Icons.volume_up_outlined, title: 'Connection Sounds', subtitle: controller.connectionSounds ? 'On' : 'Off', trailing: Switch.adaptive(value: controller.connectionSounds, onChanged: controller.setConnectionSounds)),
          SettingRow(icon: Icons.alarm_outlined, title: 'Alarms', subtitle: '${controller.alarms.length} saved alarms', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlarmPage(controller: controller)))),
          SettingRow(icon: Icons.timer_outlined, title: 'Snooze Duration', subtitle: '${controller.snoozeMinutes} minutes', onTap: () => _showSnoozePicker(context, controller)),
          SettingRow(icon: Icons.restart_alt_rounded, title: 'Factory Reset', subtitle: 'Reset device settings', onTap: () => _confirmReset(context, controller)),
          SettingRow(icon: Icons.info_outline, title: 'Device Information', subtitle: controller.deviceModel, onTap: () => _showDeviceInfo(context, controller)),
        ];
        return ListView(
          padding: const EdgeInsets.only(bottom: 18),
          children: [
            const PageHeader(title: 'Device Management'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  ...rows.sublist(0, 1),
                  ...rows.sublist(1),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class DeviceCardHeader extends StatelessWidget {
  final JarvisController controller;
  const DeviceCardHeader({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: cardDecoration(context, radius: 18),
      child: Row(children: [
        SizedBox(width: 88, height: 64, child: Image.asset('assets/jarvis_device.png', fit: BoxFit.contain)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('JARVIS', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 3), Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: controller.connected ? Colors.green : stone, shape: BoxShape.circle)), const SizedBox(width: 6), Text(controller.connected ? 'Connected' : 'Disconnected', style: TextStyle(fontSize: 12, color: controller.connected ? Colors.green.shade700 : stone))]), const SizedBox(height: 2), Text(controller.connected ? 'Last seen: ${controller.lastSeen}' : 'Connect to manage', style: const TextStyle(fontSize: 9.5, color: stone))])),
      ]),
    );
  }
}

class SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  const SettingRow({super.key, required this.icon, required this.title, required this.subtitle, this.onTap, this.trailing});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 66),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [
          SizedBox(width: 38, child: Icon(icon, size: 21)),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)), const SizedBox(height: 2), Text(subtitle, style: const TextStyle(fontSize: 10, color: stone))])),
          trailing ?? (onTap != null ? const Icon(Icons.chevron_right_rounded, color: stone) : const SizedBox(width: 8)),
        ]),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  final JarvisController controller;
  const ProfilePage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            PageHeader(
              title: 'Profile',
              onNotification: () => _showNotifications(context, controller),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: cardDecoration(context, radius: 20),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 29,
                          backgroundColor: dark ? sand : const Color(0xFFE8DED4),
                          child: Icon(
                            Icons.person,
                            color: dark ? ink : olive,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Omar Asim',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Your personal JARVIS profile',
                                style: TextStyle(color: stone, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: stone),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Appearance',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ThemeChoice(
                          icon: Icons.light_mode_outlined,
                          label: 'Light',
                          selected: !controller.darkMode,
                          onTap: () => controller.setDarkMode(false),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: ThemeChoice(
                          icon: Icons.dark_mode_outlined,
                          label: 'Dark',
                          selected: controller.darkMode,
                          onTap: () => controller.setDarkMode(true),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: ThemeChoice(
                          icon: Icons.brightness_auto_outlined,
                          label: 'System',
                          selected: false,
                          onTap: () => controller.setDarkMode(true)
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SettingRow(
                    icon: Icons.notifications_none_rounded,
                    title: 'Notifications',
                    subtitle: controller.notificationsEnabled ? 'On' : 'Off',
                    trailing: Switch.adaptive(
                      value: controller.notificationsEnabled,
                      onChanged: controller.setNotificationsEnabled,
                    ),
                  ),
                  SettingRow(
                    icon: Icons.mic_none_rounded,
                    title: 'Voice & Wake Word',
                    subtitle: controller.wakeMode ? 'Wake mode active' : 'Jarvis',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VoiceSettingsPage(controller: controller),
                      ),
                    ),
                  ),
                  SettingRow(
                    icon: Icons.psychology_outlined,
                    title: 'AI',
                    subtitle: controller.ollamaModel.isEmpty ? 'Not configured' : controller.ollamaModel,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AiSettingsPage(controller: controller),
                      ),
                    ),
                  ),
                  SettingRow(
                    icon: Icons.shield_outlined,
                    title: 'Privacy',
                    subtitle: 'Microphone, speech and notification controls',
                    onTap: () => _showPrivacy(context),
                  ),
                  SettingRow(
                    icon: Icons.info_outline,
                    title: 'App Information',
                    subtitle: 'JARVIS Companion 1.0.0',
                    onTap: () => _showAbout(context),
                  ),
                  const SizedBox(height: 18),
                  AppButton(
                    label: 'SIGN OUT',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'There is no account system in this local build.',
                        ),
                      ),
                    ),
                    width: double.infinity,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class ThemeChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const ThemeChoice({super.key, required this.icon, required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: AnimatedContainer(duration: const Duration(milliseconds: 180), height: 58, decoration: BoxDecoration(color: selected ? olive : (Theme.of(context).brightness == Brightness.dark ? darkCard : sand.withOpacity(.55)), borderRadius: BorderRadius.circular(13)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 19, color: selected ? Colors.white : null), const SizedBox(height: 4), Text(label, style: TextStyle(fontSize: 10.5, color: selected ? Colors.white : null, fontWeight: FontWeight.w600))])));
  }
}

class VoiceSettingsPage extends StatelessWidget {
  final JarvisController controller;
  const VoiceSettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Voice & Wake Word')),
        body: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            SettingRow(
              icon: Icons.mic_none,
              title: 'Voice assistant',
              subtitle: controller.voiceEnabled ? 'Enabled' : 'Disabled',
              trailing: Switch.adaptive(
                value: controller.voiceEnabled,
                onChanged: controller.setVoiceEnabled,
              ),
            ),
            SettingRow(
              icon: Icons.record_voice_over_outlined,
              title: 'Wake mode',
              subtitle: controller.wakeMode ? 'Listening for “Jarvis”' : 'Off',
              trailing: Switch.adaptive(
                value: controller.wakeMode,
                onChanged: (v) => v
                    ? controller.startWakeMode()
                    : controller.stopWakeMode(),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'How it works',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'The microphone belongs to the phone. Say “Jarvis” in wake mode, or tap the microphone in the AI screen for a command. Device commands are handled locally; general questions use your local Ollama model.',
              style: TextStyle(color: stone, height: 1.5),
            ),
            const SizedBox(height: 22),
            AppButton(
              label: controller.listening ? 'STOP LISTENING' : 'TEST MICROPHONE',
              onTap: controller.listenForCommand,
              width: double.infinity,
            ),
          ],
        ),
      ),
    );
  }
}

class AiSettingsPage extends StatefulWidget {
  final JarvisController controller;
  const AiSettingsPage({super.key, required this.controller});
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late final TextEditingController endpoint;
  late final TextEditingController model;

  @override
  void initState() {
    super.initState();
    endpoint = TextEditingController(text: widget.controller.ollamaEndpoint);
    model = TextEditingController(text: widget.controller.ollamaModel);
  }

  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Settings')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          TextField(
            controller: endpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Ollama server',
              hintText: 'http://10.0.2.2:11434',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: model,
            decoration: const InputDecoration(
              labelText: 'Ollama model',
              hintText: 'llama3.2:3b',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'JARVIS uses Ollama locally. No API key is required. Run Ollama on your computer with the selected model. For the Android emulator, use 10.0.2.2; on a physical phone, enter the computer’s local network address.',
            style: TextStyle(color: stone, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 22),
          AppButton(
            label: 'SAVE',
            onTap: () async {
              final endpointValue = endpoint.text.trim();
              final modelValue = model.text.trim();
              await widget.controller.setOllamaConfig(
                endpoint: endpointValue,
                model: modelValue,
              );
              if (mounted) Navigator.pop(context);
            },
            width: double.infinity,
          ),
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final JarvisController controller;
  const ChatPage({super.key, required this.controller});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  @override
  void dispose() { input.dispose(); scroll.dispose(); super.dispose(); }
  Future<void> submit([String? value]) async {
    final text = (value ?? input.text).trim();
    if (text.isEmpty) return;
    input.clear();
    await widget.controller.processUserText(text, fromVoice: false);
    if (!mounted) return;
    setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted || !scroll.hasClients) return;
    await scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: widget.controller, builder: (_, __) => Scaffold(appBar: AppBar(title: const Text('JARVIS AI')), body: Column(children: [
      Expanded(
        child: widget.controller.messages.isEmpty
            ? const Center(
                child: Text(
                  'Say or type a command for JARVIS.',
                  style: TextStyle(color: stone),
                ),
              )
            : ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(18),
                itemCount: widget.controller.messages.length,
                itemBuilder: (_, i) {
                  final m = widget.controller.messages[i];
                  return Align(
                    alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                      constraints: const BoxConstraints(maxWidth: 320),
                      decoration: BoxDecoration(
                        color: m.fromUser
                            ? olive
                            : (Theme.of(context).brightness == Brightness.dark
                                ? darkCard
                                : sand.withOpacity(.55)),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        m.text,
                        style: TextStyle(
                          color: m.fromUser ? Colors.white : null,
                          height: 1.35,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(14, 6, 14, 14), child: Row(children: [Expanded(child: TextField(controller: input, onSubmitted: (_) => submit(), decoration: InputDecoration(hintText: 'Ask JARVIS…', filled: true, fillColor: Theme.of(context).brightness == Brightness.dark ? darkCard : sand.withOpacity(.45), border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 18)))), const SizedBox(width: 8), IconButton.filled(onPressed: widget.controller.listening ? () => widget.controller.listenForCommand() : () => widget.controller.listenForCommand(), icon: Icon(widget.controller.listening ? Icons.stop_rounded : Icons.mic_none_rounded)), const SizedBox(width: 4), IconButton.filled(onPressed: submit, icon: const Icon(Icons.arrow_upward_rounded))]))
    ])));
  }
}

class AlarmPage extends StatelessWidget {
  final JarvisController controller;
  const AlarmPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('Alarms')),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _addAlarmDialog(context, controller),
          backgroundColor: olive,
          foregroundColor: Colors.white,
          child: const Icon(Icons.add),
        ),
        body: controller.alarms.isEmpty
            ? const Center(child: Text('No alarms yet.'))
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: controller.alarms.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final alarm = controller.alarms[i];
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: cardDecoration(context, radius: 18),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                alarm.time,
                                style: const TextStyle(
                                  fontSize: 27,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                alarm.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: stone,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: alarm.enabled,
                          onChanged: (v) => controller.setAlarmEnabled(alarm, v),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'edit') {
                              await _editAlarmDialog(context, controller, alarm);
                            }
                            if (value == 'delete') {
                              await controller.deleteAlarm(alarm);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final double? width;
  const AppButton({super.key, required this.label, required this.onTap, this.width});
  @override
  Widget build(BuildContext context) => SizedBox(width: width, height: 46, child: ElevatedButton(onPressed: onTap, style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).brightness == Brightness.dark ? olive : sand, foregroundColor: ink, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: .7))));
}

class ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const ActionTile({super.key, required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(18), child: Container(decoration: cardDecoration(context, radius: 18), padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [Icon(icon, size: 25), const Spacer(), Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))])));
}

BoxDecoration cardDecoration(BuildContext context, {double radius = 14}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(color: dark ? darkCard : sand.withOpacity(.48), borderRadius: BorderRadius.circular(radius));
}

String timezoneName(String id) {
  const map = {
    'UTC': 'UTC (UTC+0)', 'PK': 'Pakistan (UTC+5)', 'AE': 'UAE (UTC+4)', 'SA': 'Saudi Arabia (UTC+3)', 'TR': 'Türkiye (UTC+3)', 'ZA': 'South Africa (UTC+2)', 'IN': 'India (UTC+5:30)', 'BD': 'Bangladesh (UTC+6)', 'TH': 'Thailand (UTC+7)', 'CN': 'China (UTC+8)', 'JP': 'Japan (UTC+9)', 'KR': 'South Korea (UTC+9)', 'GB': 'United Kingdom (UTC+0)', 'DE': 'Germany (UTC+1)', 'US-NY': 'US New York (UTC-5)', 'US-CHI': 'US Chicago (UTC-6)', 'US-DEN': 'US Denver (UTC-7)', 'US-LA': 'US Los Angeles (UTC-8)', 'BR': 'Brazil (UTC-3)', 'AU-SYD': 'Australia Sydney (UTC+10)',
  };
  return map[id] ?? id;
}

Future<void> _showNotifications(BuildContext context, JarvisController controller) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * .7,
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
            children: [
              const Text(
                'Notifications',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              if (controller.events.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: Center(
                    child: Text(
                      'No JARVIS events yet.',
                      style: TextStyle(color: stone),
                    ),
                  ),
                )
              else
                ...controller.events.map(
                  (e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: sand,
                      child: Icon(Icons.notifications_none, color: olive),
                    ),
                    title: Text(
                      e.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(e.body),
                    trailing: Text(
                      _relative(e.time),
                      style: const TextStyle(color: stone, fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _relative(DateTime t) { final d = DateTime.now().difference(t); if (d.inMinutes < 1) return 'now'; if (d.inMinutes < 60) return '${d.inMinutes}m'; if (d.inHours < 24) return '${d.inHours}h'; return '${d.inDays}d'; }

Future<void> _addAlarmDialog(BuildContext context, JarvisController controller) async {
  TimeOfDay time = TimeOfDay.now();
  final label = TextEditingController(text: 'JARVIS Alarm');

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add alarm'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  time.format(context),
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                ),
                trailing: const Icon(Icons.access_time),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null && context.mounted) {
                    setState(() => time = picked);
                  }
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: label,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final alarmLabel = label.text.trim().isEmpty
                    ? 'Alarm'
                    : label.text.trim();
                await controller.addAlarm(time: time, label: alarmLabel);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  } finally {
    label.dispose();
  }
}

Future<void> _editAlarmDialog(
  BuildContext context,
  JarvisController controller,
  AlarmModel alarm,
) async {
  TimeOfDay time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
  final label = TextEditingController(text: alarm.label);
  bool enabled = alarm.enabled;

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit alarm'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  time.format(context),
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                ),
                trailing: const Icon(Icons.access_time),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null && context.mounted) {
                    setState(() => time = picked);
                  }
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: label,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled'),
                value: enabled,
                onChanged: (value) => setState(() => enabled = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final updatedLabel = label.text.trim().isEmpty
                    ? 'Alarm'
                    : label.text.trim();
                alarm.hour = time.hour;
                alarm.minute = time.minute;
                alarm.label = updatedLabel;
                alarm.enabled = enabled;
                await controller.editAlarm(alarm);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  } finally {
    label.dispose();
  }
}

Future<void> _showUnitPicker(BuildContext context, JarvisController c) async {
  await showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: ['C', 'F'].map((v) => ListTile(title: Text(v == 'C' ? 'Celsius (°C)' : 'Fahrenheit (°F)'), trailing: c.temperatureUnit == v ? const Icon(Icons.check, color: olive) : null, onTap: () { c.setUnit(v); Navigator.pop(context); })).toList())));
}

Future<void> _showScreenPicker(BuildContext context, JarvisController c) async {
  await showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: ['CLOCK', 'ALARMS'].map((v) => ListTile(title: Text(v == 'CLOCK' ? 'Clock Screen' : 'Alarm Screen'), trailing: c.currentScreen == v ? const Icon(Icons.check, color: olive) : null, onTap: () { c.setScreen(v); Navigator.pop(context); })).toList())));
}

Future<void> _showTimezonePicker(BuildContext context, JarvisController c) async {
  const ids = ['UTC','PK','AE','SA','TR','ZA','IN','BD','TH','CN','JP','KR','GB','DE','US-NY','US-CHI','US-DEN','US-LA','BR','AU-SYD'];
  await showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => SafeArea(child: SizedBox(height: MediaQuery.of(context).size.height * .75, child: ListView.builder(itemCount: ids.length, itemBuilder: (_, i) { final id = ids[i]; return ListTile(title: Text(timezoneName(id)), trailing: c.timezone == id ? const Icon(Icons.check, color: olive) : null, onTap: () { c.setTimezone(id); Navigator.pop(context); }); }))));
}

Future<void> _showSnoozePicker(BuildContext context, JarvisController c) async {
  const values = [1, 5, 10, 15, 20, 30];
  await showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: values.map((v) => ListTile(title: Text('$v minutes'), trailing: c.snoozeMinutes == v ? const Icon(Icons.check, color: olive) : null, onTap: () { c.setSnooze(v); Navigator.pop(context); })).toList())));
}

Future<void> _showClockSettings(BuildContext context, JarvisController c) async {
  await showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Clock settings', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)), const SizedBox(height: 12), SettingRow(icon: Icons.desktop_windows_outlined, title: 'Screen', subtitle: c.currentScreen, onTap: () { Navigator.pop(context); _showScreenPicker(context, c); }), SettingRow(icon: Icons.language_outlined, title: 'Timezone', subtitle: timezoneName(c.timezone), onTap: () { Navigator.pop(context); _showTimezonePicker(context, c); }), SettingRow(icon: Icons.thermostat_outlined, title: 'Temperature unit', subtitle: c.temperatureUnit, onTap: () { Navigator.pop(context); _showUnitPicker(context, c); })]))));
}

Future<void> _confirmReset(BuildContext context, JarvisController c) async {
  final yes = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Factory reset JARVIS?'), content: const Text('This resets alarms and device settings. The RTC time is preserved by the firmware.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset'))]));
  if (yes == true) await c.factoryReset();
}

Future<void> _showDeviceInfo(BuildContext context, JarvisController c) async {
  await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Device information'), content: Text('Model: ${c.deviceModel}\nName: JARVIS\nBLE service: $bleServiceUuid\n\nConnection: ${c.connected ? 'Connected' : 'Disconnected'}'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]));
}

Future<void> _showPrivacy(BuildContext context) async {
  await showDialog(context: context, builder: (_) => const AlertDialog(title: Text('Privacy'), content: Text('JARVIS uses the phone microphone only when voice features are active. Speech recognition is handled by the device speech service. BLE communication stays between the phone and your JARVIS clock. General AI questions are sent only when an AI provider is configured and you submit a question.'), actions: []));
}

Future<void> _showAbout(BuildContext context) async {
  showAboutDialog(
    context: context,
    applicationName: 'JARVIS Companion',
    applicationVersion: '1.0.0',
    applicationLegalese: 'JARVIS Smart Clock companion app.',
  );
}
