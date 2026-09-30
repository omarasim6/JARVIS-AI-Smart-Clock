#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <DHT.h>
#include <RTClib.h>
#include <Preferences.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>


// ============================================================
// PIN CONFIGURATION
// ============================================================

#define OLED_SDA       21
#define OLED_SCL       22

#define DHT_PIN        4
#define DHT_TYPE       DHT22

#define BUTTON_PIN     27
#define BUZZER_PIN     25


// ============================================================
// OLED CONFIGURATION
// ============================================================

#define SCREEN_WIDTH   128
#define SCREEN_HEIGHT  64
#define OLED_RESET     -1
#define OLED_ADDRESS   0x3C


// ============================================================
// BLE CONFIGURATION
// ============================================================

#define BLE_DEVICE_NAME "JARVIS"

#define SERVICE_UUID \
  "4fafc201-1fb5-459e-8fcc-c5c9c331914b"

#define RX_CHARACTERISTIC_UUID \
  "beb5483e-36e1-4688-b7f5-ea07361b26a8"

#define TX_CHARACTERISTIC_UUID \
  "cba1d466-344c-4be3-ab3f-189f4b5b8a3f"


// ============================================================
// CONSTANTS
// ============================================================

#define MAX_ALARMS 10

#define DHT_INTERVAL       2500UL
#define DISPLAY_INTERVAL    500UL
#define BUTTON_DEBOUNCE      50UL

#define ALARM_DURATION      10000UL

#define DEFAULT_SNOOZE_MIN      5

#define ALARM_FREQUENCY      1500
#define ALARM_VOLUME         128

#define HOURLY_CHIME_FREQUENCY  1200
#define CONNECTION_CHIME_FREQ   1600
#define DISCONNECT_CHIME_FREQ   900

#define HOURLY_CHIME_DURATION   180
#define CONNECTION_CHIME_DURATION 120
#define DISCONNECT_CHIME_DURATION 120


// ============================================================
// OBJECTS
// ============================================================

Adafruit_SSD1306 display(
  SCREEN_WIDTH,
  SCREEN_HEIGHT,
  &Wire,
  OLED_RESET
);

DHT dht(DHT_PIN, DHT_TYPE);
RTC_DS3231 rtc;
Preferences preferences;


// ============================================================
// SCREEN SYSTEM
// ============================================================

enum Screen {
  SCREEN_CLOCK = 0,
  SCREEN_ALARMS = 1
};

Screen currentScreen = SCREEN_CLOCK;


// ============================================================
// ALARM STRUCTURE
// ============================================================

struct Alarm {
  uint8_t hour;
  uint8_t minute;
  bool enabled;
  String label;
};

Alarm alarms[MAX_ALARMS];
uint8_t alarmCount = 0;


// ============================================================
// TIMEZONE SYSTEM
// ============================================================

struct TimezoneInfo {
  const char* id;
  const char* name;
  int16_t offsetMinutes;
};


/*
  These are fixed UTC offsets.

  They intentionally do not attempt automatic DST calculation.
  The app can select the appropriate offset.

  Example:
  UK summer time would require manually selecting UTC+1
  if daylight-saving behavior is desired.
*/

const TimezoneInfo timezones[] = {

  { "UTC",     "UTC",                    0   },

  { "PK",      "Pakistan",              300  },
  { "AE",      "UAE",                    240  },
  { "SA",      "Saudi Arabia",            180  },
  { "TR",      "Turkey",                 180  },
  { "ZA",      "South Africa",            120  },

  { "IN",      "India",                  330  },
  { "BD",      "Bangladesh",              360 },
  { "TH",      "Thailand",                420 },
  { "CN",      "China",                   480 },
  { "JP",      "Japan",                   540 },
  { "KR",      "South Korea",             540 },

  { "GB",      "United Kingdom",             0 },
  { "DE",      "Germany",                  60 },

  { "US-NY",   "New York",               -300 },
  { "US-CHI",  "Chicago",                -360 },
  { "US-DEN",  "Denver",                 -420 },
  { "US-LA",   "Los Angeles",            -480 },

  { "BR",      "Brazil",                 -180 },

  { "AU-SYD",  "Sydney",                  600 }
};

const uint8_t TIMEZONE_COUNT =
  sizeof(timezones) / sizeof(timezones[0]);

uint8_t timezoneIndex = 1; // Pakistan


// ============================================================
// SETTINGS
// ============================================================

bool useFahrenheit = false;

uint8_t snoozeMinutes = DEFAULT_SNOOZE_MIN;

bool hourlyChimeEnabled = true;
bool connectionChimeEnabled = true;
bool disconnectionChimeEnabled = true;


// ============================================================
// RTC STATE
// ============================================================

bool rtcAvailable = false;
bool rtcInitialized = false;

const long PAKISTAN_UTC_OFFSET =
  5L * 60L * 60L;


// ============================================================
// BLE STATE
// ============================================================

BLEServer* bleServer = nullptr;
BLECharacteristic* txCharacteristic = nullptr;
BLECharacteristic* rxCharacteristic = nullptr;

bool deviceConnected = false;
bool oldDeviceConnected = false;


// ============================================================
// SENSOR STATE
// ============================================================

float temperatureC = NAN;
float humidity = NAN;

unsigned long lastDHTRead = 0;


// ============================================================
// DISPLAY STATE
// ============================================================

unsigned long lastDisplayUpdate = 0;


// ============================================================
// BUTTON STATE
// ============================================================

bool lastButtonReading = HIGH;
bool stableButtonState = HIGH;

unsigned long lastButtonChange = 0;


// ============================================================
// ALARM RUNTIME STATE
// ============================================================

bool alarmSoundActive = false;

unsigned long alarmStartedMillis = 0;

int activeAlarmIndex = -1;

int lastTriggeredAlarmIndex = -1;
uint32_t lastTriggeredAlarmDay = 0;


// ============================================================
// SNOOZE STATE
// ============================================================

bool snoozeActive = false;

int snoozedAlarmIndex = -1;

uint32_t snoozeUntilUnix = 0;


// ============================================================
// HOURLY CHIME PROTECTION
// ============================================================

uint32_t lastHourlyChimeKey = 0;


// ============================================================
// BLE CHIME PROTECTION
// ============================================================

unsigned long lastConnectionChimeMillis = 0;
unsigned long lastDisconnectChimeMillis = 0;


// ============================================================
// FORWARD DECLARATIONS
// ============================================================

void saveSettings();
void loadSettings();

void saveAlarms();
void loadAlarms();

void displayCurrentScreen();

void processBLECommand(String command);

void startAlarmSound(int alarmIndex);
void stopAlarmSound();

void playShortChime(
  int frequency,
  int duration
);

void checkAlarmSystem();

void checkHourlyChime();

DateTime getLocalDateTime();

long getTimezoneOffsetSeconds();

void sendBLEMessage(String message);


// ============================================================
// BLE SERVER CALLBACKS
// ============================================================

class JARVISServerCallbacks : public BLEServerCallbacks {

  void onConnect(BLEServer* server) override {

    deviceConnected = true;

    Serial.println();
    Serial.println("[BLE] Device connected.");

    /*
      IMPORTANT:

      Whenever JARVIS connects again, ALWAYS return to
      the Clock screen.

      This prevents the OLED from reopening on the
      Alarm screen after reconnecting.
    */

    currentScreen = SCREEN_CLOCK;
    saveSettings();

    /*
      Connection itself must NEVER start the full alarm.

      We only give a short connection confirmation chime.
    */

    stopAlarmSound();

    if (connectionChimeEnabled) {

      playShortChime(
        CONNECTION_CHIME_FREQ,
        CONNECTION_CHIME_DURATION
      );
    }

    sendBLEMessage("CONNECTED");
    sendBLEMessage("SCREEN:CLOCK");
  }


  void onDisconnect(BLEServer* server) override {

    deviceConnected = false;

    Serial.println();
    Serial.println("[BLE] Device disconnected.");

    /*
      IMPORTANT:

      Immediately return to Clock.

      This is also saved so the next screen state is
      guaranteed to be Clock.
    */

    currentScreen = SCREEN_CLOCK;
    saveSettings();

    /*
      Never allow an accidental BLE event to leave
      an alarm tone running.
    */

    stopAlarmSound();

    if (disconnectionChimeEnabled) {

      playShortChime(
        DISCONNECT_CHIME_FREQ,
        DISCONNECT_CHIME_DURATION
      );
    }

    server->startAdvertising();

    Serial.println("[BLE] Advertising restarted.");
  }
};


// ============================================================
// BLE RX CALLBACK
// ============================================================

class JARVISRXCallbacks : public BLECharacteristicCallbacks {

  void onWrite(BLECharacteristic* characteristic) override {

    String value = characteristic->getValue();

    value.trim();

    if (value.length() == 0) {
      return;
    }

    Serial.print("[BLE RX] ");
    Serial.println(value);

    processBLECommand(value);
  }
};


// ============================================================
// BLE MESSAGE FUNCTION
// ============================================================

void sendBLEMessage(String message) {

  if (!deviceConnected) {
    return;
  }

  if (txCharacteristic == nullptr) {
    return;
  }

  txCharacteristic->setValue(message.c_str());
  txCharacteristic->notify();

  Serial.print("[BLE TX] ");
  Serial.println(message);
}


// ============================================================
// PREFERENCES INITIALIZATION
// ============================================================

void initializePreferences() {

  if (!preferences.begin("jarvis", false)) {

    Serial.println(
      "[PREF] Failed to initialize Preferences."
    );

  } else {

    Serial.println(
      "[PREF] Preferences initialized."
    );
  }
}


// ============================================================
// BUILD TIME
// ============================================================

DateTime getBuildTimePakistan() {

  const char* buildDate = __DATE__;
  const char* buildTime = __TIME__;

  char monthString[4];

  int day;
  int year;

  int hour;
  int minute;
  int second;

  sscanf(
    buildDate,
    "%3s %d %d",
    monthString,
    &day,
    &year
  );

  sscanf(
    buildTime,
    "%d:%d:%d",
    &hour,
    &minute,
    &second
  );

  int month = 1;

  if (strcmp(monthString, "Jan") == 0) month = 1;
  else if (strcmp(monthString, "Feb") == 0) month = 2;
  else if (strcmp(monthString, "Mar") == 0) month = 3;
  else if (strcmp(monthString, "Apr") == 0) month = 4;
  else if (strcmp(monthString, "May") == 0) month = 5;
  else if (strcmp(monthString, "Jun") == 0) month = 6;
  else if (strcmp(monthString, "Jul") == 7) month = 7;
  else if (strcmp(monthString, "Aug") == 0) month = 8;
  else if (strcmp(monthString, "Sep") == 0) month = 9;
  else if (strcmp(monthString, "Oct") == 0) month = 10;
  else if (strcmp(monthString, "Nov") == 0) month = 11;
  else if (strcmp(monthString, "Dec") == 0) month = 12;

  /*
    __DATE__ / __TIME__ are treated as Pakistan local time
    for this project.

    Convert them to UTC before storing in DS3231.
  */

  DateTime pakistanTime(
    year,
    month,
    day,
    hour,
    minute,
    second
  );

  uint32_t utcUnix =
    pakistanTime.unixtime() - PAKISTAN_UTC_OFFSET;

  return DateTime(utcUnix);
}


// ============================================================
// RTC INITIALIZATION
// ============================================================

void initializeRTC() {

  if (!rtc.begin()) {

    Serial.println(
      "[RTC] DS3231 not detected."
    );

    rtcAvailable = false;
    return;
  }

  rtcAvailable = true;

  bool lostPower = rtc.lostPower();

  bool storedInitialized =
    preferences.getBool("rtc_init", false);

  bool storedAsUTC =
    preferences.getBool("rtc_utc", false);

  DateTime now = rtc.now();

  bool invalidYear =
    now.year() < 2024 ||
    now.year() > 2099;


  /*
    ==========================================================
    FIRST INITIALIZATION / LOST POWER / INVALID RTC
    ==========================================================
  */

  if (
    lostPower ||
    !storedInitialized ||
    invalidYear
  ) {

    Serial.println(
      "[RTC] Initializing RTC from firmware build time..."
    );

    DateTime buildUTC =
      getBuildTimePakistan();

    rtc.adjust(buildUTC);

    preferences.putBool(
      "rtc_init",
      true
    );

    preferences.putBool(
      "rtc_utc",
      true
    );

    rtcInitialized = true;

    Serial.println(
      "[RTC] RTC initialized in UTC."
    );

    return;
  }


  /*
    ==========================================================
    V2.5 -> V3.0 MIGRATION

    V2.5 stored Pakistan LOCAL time.

    V3.0 stores UTC.

    Convert the existing value exactly once.
    ==========================================================
  */

  if (!storedAsUTC) {

    Serial.println(
      "[RTC] Existing V2.5 RTC detected."
    );

    Serial.println(
      "[RTC] Migrating Pakistan local time -> UTC..."
    );

    DateTime oldPakistanTime = rtc.now();

    uint32_t utcUnix =
      oldPakistanTime.unixtime()
      - PAKISTAN_UTC_OFFSET;

    DateTime convertedUTC(utcUnix);

    rtc.adjust(convertedUTC);

    preferences.putBool(
      "rtc_utc",
      true
    );

    preferences.putBool(
      "rtc_init",
      true
    );

    Serial.println(
      "[RTC] RTC migration completed."
    );
  }


  rtcInitialized = true;

  Serial.println(
    "[RTC] RTC is running."
  );
}


// ============================================================
// SETTINGS SAVE
// ============================================================

void saveSettings() {

  preferences.putBool(
    "fahrenheit",
    useFahrenheit
  );

  preferences.putUChar(
    "snooze",
    snoozeMinutes
  );

  preferences.putUChar(
    "tz",
    timezoneIndex
  );

  preferences.putUChar(
    "screen",
    (uint8_t)currentScreen
  );

  preferences.putBool(
    "hour_chime",
    hourlyChimeEnabled
  );

  preferences.putBool(
    "conn_chime",
    connectionChimeEnabled
  );

  preferences.putBool(
    "disc_chime",
    disconnectionChimeEnabled
  );
}


// ============================================================
// SETTINGS LOAD
// ============================================================

void loadSettings() {

  useFahrenheit =
    preferences.getBool(
      "fahrenheit",
      false
    );

  snoozeMinutes =
    preferences.getUChar(
      "snooze",
      DEFAULT_SNOOZE_MIN
    );

  timezoneIndex =
    preferences.getUChar(
      "tz",
      1
    );

  if (timezoneIndex >= TIMEZONE_COUNT) {
    timezoneIndex = 1;
  }

  /*
    The requested behavior is that JARVIS always comes
    back to Clock after a BLE connection/disconnection.

    Therefore even if an old preference says Alarm screen,
    startup begins on Clock.
  */

  currentScreen = SCREEN_CLOCK;

  hourlyChimeEnabled =
    preferences.getBool(
      "hour_chime",
      true
    );

  connectionChimeEnabled =
    preferences.getBool(
      "conn_chime",
      true
    );

  disconnectionChimeEnabled =
    preferences.getBool(
      "disc_chime",
      true
    );

  Serial.println(
    "[SETTINGS] Settings loaded."
  );
}


// ============================================================
// SAVE ALARMS
// ============================================================

void saveAlarms() {

  preferences.putUChar(
    "count",
    alarmCount
  );

  for (uint8_t i = 0; i < MAX_ALARMS; i++) {

    String hKey = "h" + String(i);
    String mKey = "m" + String(i);
    String eKey = "e" + String(i);
    String lKey = "l" + String(i);

    if (i < alarmCount) {

      preferences.putUChar(
        hKey.c_str(),
        alarms[i].hour
      );

      preferences.putUChar(
        mKey.c_str(),
        alarms[i].minute
      );

      preferences.putBool(
        eKey.c_str(),
        alarms[i].enabled
      );

      preferences.putString(
        lKey.c_str(),
        alarms[i].label
      );

    } else {

      preferences.remove(hKey.c_str());
      preferences.remove(mKey.c_str());
      preferences.remove(eKey.c_str());
      preferences.remove(lKey.c_str());
    }
  }

  Serial.println(
    "[ALARMS] Alarms saved."
  );
}


// ============================================================
// LOAD ALARMS
// ============================================================

void loadAlarms() {

  alarmCount =
    preferences.getUChar(
      "count",
      0
    );

  if (alarmCount > MAX_ALARMS) {
    alarmCount = 0;
  }

  for (uint8_t i = 0; i < alarmCount; i++) {

    String hKey = "h" + String(i);
    String mKey = "m" + String(i);
    String eKey = "e" + String(i);
    String lKey = "l" + String(i);

    alarms[i].hour =
      preferences.getUChar(
        hKey.c_str(),
        0
      );

    alarms[i].minute =
      preferences.getUChar(
        mKey.c_str(),
        0
      );

    alarms[i].enabled =
      preferences.getBool(
        eKey.c_str(),
        true
      );

    alarms[i].label =
      preferences.getString(
        lKey.c_str(),
        ""
      );

    if (alarms[i].hour > 23) {
      alarms[i].hour = 0;
    }

    if (alarms[i].minute > 59) {
      alarms[i].minute = 0;
    }
  }

  Serial.print("[ALARMS] Loaded ");
  Serial.print(alarmCount);
  Serial.println(" alarm(s).");
}


// ============================================================
// TIMEZONE OFFSET
// ============================================================

long getTimezoneOffsetSeconds() {

  return (
    (long)timezones[timezoneIndex].offsetMinutes
    * 60L
  );
}


// ============================================================
// GET LOCAL DATE/TIME
// ============================================================

DateTime getLocalDateTime() {

  if (!rtcAvailable) {

    return DateTime(
      2026,
      1,
      1,
      0,
      0,
      0
    );
  }

  DateTime utcNow = rtc.now();

  int64_t localUnix =
    (int64_t)utcNow.unixtime()
    + getTimezoneOffsetSeconds();

  return DateTime(
    (uint32_t)localUnix
  );
}


// ============================================================
// BUZZER SETUP
// ============================================================

void initializeBuzzer() {

  /*
    ESP32 Arduino Core 3.x LEDC API
  */

  ledcAttach(
    BUZZER_PIN,
    ALARM_FREQUENCY,
    8
  );

  ledcWriteTone(
    BUZZER_PIN,
    0
  );

  ledcWrite(
    BUZZER_PIN,
    0
  );

  Serial.println(
    "[BUZZER] Initialized."
  );
}


// ============================================================
// START ALARM SOUND
// ============================================================

void startAlarmSound(int alarmIndex) {

  if (
    alarmIndex < 0 ||
    alarmIndex >= alarmCount
  ) {
    return;
  }

  alarmSoundActive = true;

  activeAlarmIndex = alarmIndex;

  alarmStartedMillis = millis();

  ledcWriteTone(
    BUZZER_PIN,
    ALARM_FREQUENCY
  );

  ledcWrite(
    BUZZER_PIN,
    ALARM_VOLUME
  );

  Serial.print("[ALARM] Ringing alarm ");
  Serial.println(alarmIndex);

  sendBLEMessage("ALARM:RINGING");

  sendBLEMessage(
    "ALARM:ACTIVE:" + String(alarmIndex)
  );
}


// ============================================================
// STOP ALARM SOUND
// ============================================================

void stopAlarmSound() {

  ledcWriteTone(
    BUZZER_PIN,
    0
  );

  ledcWrite(
    BUZZER_PIN,
    0
  );

  alarmSoundActive = false;

  activeAlarmIndex = -1;
}


// ============================================================
// SHORT CHIME
// ============================================================

void playShortChime(
  int frequency,
  int duration
) {

  /*
    Safety:
    Stop the full alarm tone first.

    This guarantees a connection/disconnection/hourly
    chime never overlaps the alarm tone.
  */

  bool wasAlarmActive = alarmSoundActive;

  if (wasAlarmActive) {
    return;
  }

  ledcWriteTone(
    BUZZER_PIN,
    frequency
  );

  ledcWrite(
    BUZZER_PIN,
    ALARM_VOLUME
  );

  delay(duration);

  ledcWriteTone(
    BUZZER_PIN,
    0
  );

  ledcWrite(
    BUZZER_PIN,
    0
  );
}


// ============================================================
// HOURLY CHIME
// ============================================================

void checkHourlyChime() {

  if (!rtcAvailable) {
    return;
  }

  if (!hourlyChimeEnabled) {
    return;
  }

  /*
    Do not hourly-chime while a real alarm is currently
    ringing.
  */

  if (alarmSoundActive) {
    return;
  }

  DateTime now = getLocalDateTime();

  /*
    Exactly XX:00:00
  */

  if (
    now.minute() != 0 ||
    now.second() != 0
  ) {
    return;
  }

  /*
    Unique key for this specific hour/day.

    This prevents the hourly chime from firing multiple
    times because loop() executes many times during
    second zero.
  */

  uint32_t hourKey =
    now.year() * 100000UL +
    now.month() * 1000UL +
    now.day() * 10UL +
    now.hour();

  if (hourKey == lastHourlyChimeKey) {
    return;
  }

  lastHourlyChimeKey = hourKey;

  Serial.print("[CHIME] Hourly chime: ");
  Serial.print(now.hour());
  Serial.println(":00");

  playShortChime(
    HOURLY_CHIME_FREQUENCY,
    HOURLY_CHIME_DURATION
  );

  sendBLEMessage("CHIME:HOURLY");
}


// ============================================================
// ALARM SYSTEM
// ============================================================

void checkAlarmSystem() {

  if (!rtcAvailable) {
    return;
  }

  /*
    Handle currently active alarm first.
  */

  if (alarmSoundActive) {

    if (
      millis() - alarmStartedMillis
      >= ALARM_DURATION
    ) {

      Serial.println(
        "[ALARM] Automatic stop after 10 seconds."
      );

      stopAlarmSound();

      sendBLEMessage(
        "ALARM:STOPPED"
      );
    }

    return;
  }


  // ==========================================================
  // SNOOZE CHECK
  // ==========================================================

  if (snoozeActive) {

    uint32_t currentUTC =
      rtc.now().unixtime();

    if (
      currentUTC >= snoozeUntilUnix
    ) {

      Serial.print(
        "[ALARM] Snoozed alarm is due: "
      );

      Serial.println(
        snoozedAlarmIndex
      );

      int index = snoozedAlarmIndex;

      snoozeActive = false;
      snoozedAlarmIndex = -1;
      snoozeUntilUnix = 0;

      if (
        index >= 0 &&
        index < alarmCount &&
        alarms[index].enabled
      ) {

        startAlarmSound(index);

      } else {

        sendBLEMessage(
          "ALARM:SNOOZE_CANCELLED"
        );
      }

      return;
    }
  }


  // ==========================================================
  // NORMAL ALARM CHECK
  // ==========================================================

  DateTime now = getLocalDateTime();

  /*
    Alarms trigger exactly at XX:XX:00.
  */

  if (now.second() != 0) {
    return;
  }

  uint32_t dayKey =
    now.year() * 10000UL +
    now.month() * 100UL +
    now.day();

  for (uint8_t i = 0; i < alarmCount; i++) {

    if (!alarms[i].enabled) {
      continue;
    }

    if (
      alarms[i].hour == now.hour() &&
      alarms[i].minute == now.minute()
    ) {

      /*
        Prevent duplicate trigger within the same day.
      */

      if (
        lastTriggeredAlarmIndex == i &&
        lastTriggeredAlarmDay == dayKey
      ) {
        continue;
      }

      lastTriggeredAlarmIndex = i;
      lastTriggeredAlarmDay = dayKey;

      Serial.print(
        "[ALARM] Alarm triggered: "
      );

      Serial.println(i);

      /*
        If an alarm occurs exactly at the top of an hour,
        the full alarm takes priority over the hourly chime.
      */

      startAlarmSound(i);

      break;
    }
  }
}


// ============================================================
// FORMAT 12-HOUR TIME
// ============================================================

void format12Hour(
  uint8_t hour24,
  uint8_t minute,
  char* output,
  size_t outputSize
) {

  uint8_t hour12 = hour24 % 12;

  if (hour12 == 0) {
    hour12 = 12;
  }

  const char* period =
    hour24 >= 12 ? "PM" : "AM";

  snprintf(
    output,
    outputSize,
    "%02d:%02d %s",
    hour12,
    minute,
    period
  );
}


// ============================================================
// DRAW CLOCK SCREEN
// ============================================================

void drawClockScreen() {

  display.clearDisplay();

  display.setTextColor(
    SSD1306_WHITE
  );


  // ----------------------------------------------------------
  // HEADER
  // ----------------------------------------------------------

  display.setTextSize(1);

  display.setCursor(
    0,
    0
  );

  display.print(
    "JARVIS"
  );

  display.setCursor(
    88,
    0
  );

  display.print(
    timezones[timezoneIndex].id
  );


  // ----------------------------------------------------------
  // TIME
  // ----------------------------------------------------------

  if (rtcAvailable) {

    DateTime now =
      getLocalDateTime();

    char timeBuffer[16];

    format12Hour(
      now.hour(),
      now.minute(),
      timeBuffer,
      sizeof(timeBuffer)
    );

    display.setTextSize(2);

    display.setCursor(
      5,
      13
    );

    display.print(
      timeBuffer
    );


    // --------------------------------------------------------
    // DATE
    // --------------------------------------------------------

    display.setTextSize(1);

    display.setCursor(
      0,
      36
    );

    const char* days[] = {
      "Sun",
      "Mon",
      "Tue",
      "Wed",
      "Thu",
      "Fri",
      "Sat"
    };

    display.print(
      days[now.dayOfTheWeek()]
    );

    display.print(
      " "
    );

    if (now.day() < 10) {
      display.print("0");
    }

    display.print(
      now.day()
    );

    display.print(
      "/"
    );

    if (now.month() < 10) {
      display.print("0");
    }

    display.print(
      now.month()
    );

    display.print(
      "/"
    );

    display.print(
      now.year()
    );


    // --------------------------------------------------------
    // TEMPERATURE
    // --------------------------------------------------------

    display.setCursor(
      0,
      49
    );

    if (!isnan(temperatureC)) {

      float temperature =
        temperatureC;

      display.print(
        "T:"
      );

      if (useFahrenheit) {

        float temperatureF =
          temperatureC * 9.0 / 5.0 + 32.0;

        display.print(
          temperatureF,
          1
        );

        display.print(
          "F"
        );

      } else {

        display.print(
          temperature,
          1
        );

        display.print(
          "C"
        );
      }

    } else {

      display.print(
        "T:--"
      );
    }


    // --------------------------------------------------------
    // HUMIDITY
    // --------------------------------------------------------

    display.setCursor(
      67,
      49
    );

    if (!isnan(humidity)) {

      display.print(
        "H:"
      );

      display.print(
        humidity,
        1
      );

      display.print(
        "%"
      );

    } else {

      display.print(
        "H:--"
      );
    }

  } else {

    display.setTextSize(1);

    display.setCursor(
      20,
      27
    );

    display.print(
      "RTC ERROR"
    );
  }


  display.display();
}


// ============================================================
// DRAW ALARM SCREEN
// ============================================================

void drawAlarmScreen() {

  display.clearDisplay();

  display.setTextColor(
    SSD1306_WHITE
  );

  display.setTextSize(1);

  display.setCursor(
    0,
    0
  );

  display.print(
    "ALARMS "
  );

  display.print(
    alarmCount
  );

  display.print(
    "/"
  );

  display.print(
    MAX_ALARMS
  );


  /*
    OLED can display approximately 4 alarm rows.
  */

  uint8_t visibleCount =
    alarmCount > 4 ? 4 : alarmCount;


  if (alarmCount == 0) {

    display.setCursor(
      22,
      28
    );

    display.print(
      "No alarms set"
    );

  } else {

    for (
      uint8_t i = 0;
      i < visibleCount;
      i++
    ) {

      int y =
        13 + i * 12;

      char timeBuffer[16];

      format12Hour(
        alarms[i].hour,
        alarms[i].minute,
        timeBuffer,
        sizeof(timeBuffer)
      );

      display.setCursor(
        0,
        y
      );

      display.print(
        String(i + 1)
      );

      display.print(
        " "
      );

      display.print(
        timeBuffer
      );


      display.setCursor(
        83,
        y
      );

      if (alarms[i].enabled) {
        display.print(
          "ON"
        );
      } else {
        display.print(
          "OFF"
        );
      }
    }
  }


  display.display();
}


// ============================================================
// DISPLAY CURRENT SCREEN
// ============================================================

void displayCurrentScreen() {

  if (currentScreen == SCREEN_CLOCK) {

    drawClockScreen();

  } else {

    drawAlarmScreen();
  }
}


// ============================================================
// BUTTON HANDLER
// ============================================================

void handleButton() {

  bool reading =
    digitalRead(BUTTON_PIN);


  if (reading != lastButtonReading) {

    lastButtonChange = millis();
  }


  if (
    millis() - lastButtonChange
    > BUTTON_DEBOUNCE
  ) {

    if (
      reading != stableButtonState
    ) {

      stableButtonState = reading;


      if (
        stableButtonState == LOW
      ) {

        /*
          Button still toggles Clock <-> Alarms.

          This existing behavior is preserved.
        */

        if (
          currentScreen == SCREEN_CLOCK
        ) {

          currentScreen =
            SCREEN_ALARMS;

        } else {

          currentScreen =
            SCREEN_CLOCK;
        }

        saveSettings();

        displayCurrentScreen();

        Serial.print(
          "[BUTTON] Screen changed to "
        );

        Serial.println(
          currentScreen ==
          SCREEN_CLOCK
          ? "CLOCK"
          : "ALARMS"
        );
      }
    }
  }


  lastButtonReading = reading;
}


// ============================================================
// DHT SENSOR
// ============================================================

void updateDHT() {

  if (
    millis() - lastDHTRead
    < DHT_INTERVAL
  ) {
    return;
  }

  lastDHTRead = millis();

  float newHumidity =
    dht.readHumidity();

  float newTemperature =
    dht.readTemperature();


  if (
    isnan(newHumidity) ||
    isnan(newTemperature)
  ) {

    Serial.println(
      "[DHT] Failed to read sensor."
    );

    return;
  }


  humidity =
    newHumidity;

  temperatureC =
    newTemperature;


  Serial.print(
    "[DHT] Temperature: "
  );

  Serial.print(
    temperatureC
  );

  Serial.print(
    " C | Humidity: "
  );

  Serial.print(
    humidity
  );

  Serial.println(
    " %"
  );


  if (deviceConnected) {

    float displayedTemperature =
      useFahrenheit
      ? temperatureC * 9.0 / 5.0 + 32.0
      : temperatureC;

    String sensorMessage =
      "SENSOR:T=" +
      String(displayedTemperature, 1) +
      (useFahrenheit ? "F" : "C") +
      ",H=" +
      String(humidity, 1);

    sendBLEMessage(
      sensorMessage
    );
  }
}


// ============================================================
// BLE COMMAND: SEND STATE
// ============================================================

void sendState() {

  sendBLEMessage(
    "STATE:UNIT:" +
    String(
      useFahrenheit ? "F" : "C"
    )
  );

  sendBLEMessage(
    "STATE:TZ:" +
    String(
      timezones[timezoneIndex].id
    )
  );

  sendBLEMessage(
    "STATE:SCREEN:" +
    String(
      currentScreen ==
      SCREEN_CLOCK
      ? "CLOCK"
      : "ALARMS"
    )
  );

  sendBLEMessage(
    "STATE:ALARM_COUNT:" +
    String(alarmCount)
  );

  sendBLEMessage(
    "STATE:SNOOZE:" +
    String(snoozeMinutes)
  );

  sendBLEMessage(
    "STATE:CHIME:" +
    String(
      hourlyChimeEnabled
      ? "ON"
      : "OFF"
    )
  );

  sendBLEMessage(
    "STATE:CONNECTION_CHIME:" +
    String(
      connectionChimeEnabled
      ? "ON"
      : "OFF"
    )
  );

  sendBLEMessage(
    "STATE:DISCONNECT_CHIME:" +
    String(
      disconnectionChimeEnabled
      ? "ON"
      : "OFF"
    )
  );


  if (rtcAvailable) {

    DateTime local =
      getLocalDateTime();

    char timeString[32];

    snprintf(
      timeString,
      sizeof(timeString),
      "%04d-%02d-%02d %02d:%02d:%02d",
      local.year(),
      local.month(),
      local.day(),
      local.hour(),
      local.minute(),
      local.second()
    );

    sendBLEMessage(
      "TIME:" +
      String(timeString)
    );
  }


  if (alarmSoundActive) {

    sendBLEMessage(
      "STATE:ALARM_RINGING:" +
      String(activeAlarmIndex)
    );

  } else {

    sendBLEMessage(
      "STATE:ALARM_RINGING:-1"
    );
  }
}


// ============================================================
// BLE COMMAND: SEND ALARMS
// ============================================================

void sendAlarms() {

  sendBLEMessage(
    "ALARMS:COUNT=" +
    String(alarmCount)
  );


  for (
    uint8_t i = 0;
    i < alarmCount;
    i++
  ) {

    String message =
      "ALARM:" +
      String(i) +
      "," +
      (alarms[i].hour < 10
        ? "0"
        : "") +
      String(alarms[i].hour) +
      ":" +
      (alarms[i].minute < 10
        ? "0"
        : "") +
      String(alarms[i].minute) +
      "," +
      String(
        alarms[i].enabled
        ? "1"
        : "0"
      ) +
      "," +
      alarms[i].label;

    sendBLEMessage(
      message
    );
  }
}


// ============================================================
// FIND TIMEZONE
// ============================================================

int findTimezone(
  String id
) {

  id.trim();

  for (
    uint8_t i = 0;
    i < TIMEZONE_COUNT;
    i++
  ) {

    if (
      id.equalsIgnoreCase(
        timezones[i].id
      )
    ) {

      return i;
    }
  }

  return -1;
}


// ============================================================
// SEND TIMEZONES
// ============================================================

void sendTimezones() {

  sendBLEMessage(
    "TIMEZONES:COUNT=" +
    String(TIMEZONE_COUNT)
  );


  for (
    uint8_t i = 0;
    i < TIMEZONE_COUNT;
    i++
  ) {

    String message =
      "TIMEZONE:" +
      String(i) +
      "," +
      String(timezones[i].id) +
      "," +
      String(timezones[i].name) +
      "," +
      String(timezones[i].offsetMinutes);

    sendBLEMessage(
      message
    );
  }
}


// ============================================================
// PARSE INTEGER SAFELY
// ============================================================

bool isValidHour(
  int hour
) {

  return (
    hour >= 0 &&
    hour <= 23
  );
}


bool isValidMinute(
  int minute
) {

  return (
    minute >= 0 &&
    minute <= 59
  );
}


// ============================================================
// BLE COMMAND PROCESSOR
// ============================================================

void processBLECommand(
  String command
) {

  command.trim();


  // ==========================================================
  // PING
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "PING"
    )
  ) {

    sendBLEMessage(
      "PONG"
    );

    return;
  }


  // ==========================================================
  // STATUS
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "STATUS"
    )
  ) {

    sendState();

    return;
  }


  // ==========================================================
  // GET STATE
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "GET:STATE"
    )
  ) {

    sendState();

    return;
  }


  // ==========================================================
  // GET ALARMS
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "GET:ALARMS"
    )
  ) {

    sendAlarms();

    return;
  }


  // ==========================================================
  // GET TIMEZONES
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "GET:TIMEZONES"
    )
  ) {

    sendTimezones();

    return;
  }


  // ==========================================================
  // SCREEN:CLOCK
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "SCREEN:CLOCK"
    ) ||
    command.equalsIgnoreCase(
      "SET:SCREEN:CLOCK"
    )
  ) {

    currentScreen =
      SCREEN_CLOCK;

    saveSettings();

    displayCurrentScreen();

    sendBLEMessage(
      "OK:SCREEN:CLOCK"
    );

    return;
  }


  // ==========================================================
  // SCREEN:ALARMS
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "SCREEN:ALARMS"
    ) ||
    command.equalsIgnoreCase(
      "SET:SCREEN:ALARMS"
    )
  ) {

    currentScreen =
      SCREEN_ALARMS;

    saveSettings();

    displayCurrentScreen();

    sendBLEMessage(
      "OK:SCREEN:ALARMS"
    );

    return;
  }


  // ==========================================================
  // SET UNIT
  // ==========================================================

  if (
    command.startsWith(
      "SET:UNIT:"
    )
  ) {

    String unit =
      command.substring(
        9
      );

    unit.trim();
    unit.toUpperCase();


    if (unit == "C") {

      useFahrenheit = false;

      saveSettings();

      sendBLEMessage(
        "OK:UNIT:C"
      );

      return;
    }


    if (unit == "F") {

      useFahrenheit = true;

      saveSettings();

      sendBLEMessage(
        "OK:UNIT:F"
      );

      return;
    }


    sendBLEMessage(
      "ERROR:INVALID_UNIT"
    );

    return;
  }


  // ==========================================================
  // SET TIMEZONE
  // ==========================================================

  if (
    command.startsWith(
      "SET:TIMEZONE:"
    )
  ) {

    String id =
      command.substring(
        13
      );

    int index =
      findTimezone(id);


    if (index < 0) {

      sendBLEMessage(
        "ERROR:INVALID_TIMEZONE"
      );

      return;
    }


    timezoneIndex =
      index;

    saveSettings();

    displayCurrentScreen();

    sendBLEMessage(
      "OK:TIMEZONE:" +
      String(
        timezones[timezoneIndex].id
      )
    );

    return;
  }


  // ==========================================================
  // SET SNOOZE
  // ==========================================================

  if (
    command.startsWith(
      "SET:SNOOZE:"
    )
  ) {

    String value =
      command.substring(
        11
      );

    int minutes =
      value.toInt();


    if (
      minutes < 1 ||
      minutes > 60
    ) {

      sendBLEMessage(
        "ERROR:INVALID_SNOOZE"
      );

      return;
    }


    snoozeMinutes =
      minutes;

    saveSettings();

    sendBLEMessage(
      "OK:SNOOZE:" +
      String(snoozeMinutes)
    );

    return;
  }


  // ==========================================================
  // SET HOURLY CHIME
  // ==========================================================

  if (
    command.startsWith(
      "SET:CHIME:"
    )
  ) {

    String value =
      command.substring(
        10
      );

    value.toUpperCase();


    if (value == "ON") {

      hourlyChimeEnabled = true;

    } else if (value == "OFF") {

      hourlyChimeEnabled = false;

    } else {

      sendBLEMessage(
        "ERROR:INVALID_CHIME_STATE"
      );

      return;
    }


    saveSettings();

    sendBLEMessage(
      "OK:CHIME:" +
      String(
        hourlyChimeEnabled
        ? "ON"
        : "OFF"
      )
    );

    return;
  }


  // ==========================================================
  // CONNECTION CHIME
  // ==========================================================

  if (
    command.startsWith(
      "SET:CONNECTION_CHIME:"
    )
  ) {

    String value =
      command.substring(
        21
      );

    value.toUpperCase();


    if (value == "ON") {

      connectionChimeEnabled = true;

    } else if (value == "OFF") {

      connectionChimeEnabled = false;

    } else {

      sendBLEMessage(
        "ERROR:INVALID_CHIME_STATE"
      );

      return;
    }


    saveSettings();

    sendBLEMessage(
      "OK:CONNECTION_CHIME:" +
      String(
        connectionChimeEnabled
        ? "ON"
        : "OFF"
      )
    );

    return;
  }


  // ==========================================================
  // DISCONNECT CHIME
  // ==========================================================

  if (
    command.startsWith(
      "SET:DISCONNECT_CHIME:"
    )
  ) {

    String value =
      command.substring(
        21
      );

    value.toUpperCase();


    if (value == "ON") {

      disconnectionChimeEnabled = true;

    } else if (value == "OFF") {

      disconnectionChimeEnabled = false;

    } else {

      sendBLEMessage(
        "ERROR:INVALID_CHIME_STATE"
      );

      return;
    }


    saveSettings();

    sendBLEMessage(
      "OK:DISCONNECT_CHIME:" +
      String(
        disconnectionChimeEnabled
        ? "ON"
        : "OFF"
      )
    );

    return;
  }


  // ==========================================================
  // ADD ALARM
  //
  // ADD:07:30:1:Wake Up
  // ==========================================================

  if (
    command.startsWith(
      "ADD:"
    )
  ) {

    if (
      alarmCount >= MAX_ALARMS
    ) {

      sendBLEMessage(
        "ERROR:MAX_ALARMS"
      );

      return;
    }


    String remaining =
      command.substring(4);


    int firstColon =
      remaining.indexOf(':');

    if (firstColon < 0) {

      sendBLEMessage(
        "ERROR:INVALID_ADD"
      );

      return;
    }


    int secondColon =
      remaining.indexOf(
        ':',
        firstColon + 1
      );

    if (secondColon < 0) {

      sendBLEMessage(
        "ERROR:INVALID_ADD"
      );

      return;
    }


    int thirdColon =
      remaining.indexOf(
        ':',
        secondColon + 1
      );

    if (thirdColon < 0) {

      sendBLEMessage(
        "ERROR:INVALID_ADD"
      );

      return;
    }


    String hourString =
      remaining.substring(
        0,
        firstColon
      );

    String minuteString =
      remaining.substring(
        firstColon + 1,
        secondColon
      );

    String enabledString =
      remaining.substring(
        secondColon + 1,
        thirdColon
      );

    String label =
      remaining.substring(
        thirdColon + 1
      );


    int hour =
      hourString.toInt();

    int minute =
      minuteString.toInt();

    int enabled =
      enabledString.toInt();


    if (
      !isValidHour(hour) ||
      !isValidMinute(minute) ||
      (enabled != 0 && enabled != 1)
    ) {

      sendBLEMessage(
        "ERROR:INVALID_ADD"
      );

      return;
    }


    alarms[alarmCount].hour =
      hour;

    alarms[alarmCount].minute =
      minute;

    alarms[alarmCount].enabled =
      enabled == 1;

    alarms[alarmCount].label =
      label;


    int newIndex =
      alarmCount;

    alarmCount++;


    saveAlarms();

    sendBLEMessage(
      "OK:ADD:" +
      String(newIndex)
    );

    sendAlarms();

    displayCurrentScreen();

    return;
  }


  // ==========================================================
  // DELETE ALARM
  //
  // DELETE:0
  // ==========================================================

  if (
    command.startsWith(
      "DELETE:"
    )
  ) {

    int index =
      command.substring(7).toInt();


    if (
      index < 0 ||
      index >= alarmCount
    ) {

      sendBLEMessage(
        "ERROR:INVALID_INDEX"
      );

      return;
    }


    for (
      int i = index;
      i < alarmCount - 1;
      i++
    ) {

      alarms[i] =
        alarms[i + 1];
    }


    alarmCount--;

    if (alarmCount == 0) {

      alarms[0].label = "";
    }


    /*
      Clear runtime alarm state if the deleted alarm
      was active or snoozed.
    */

    if (
      activeAlarmIndex == index
    ) {

      stopAlarmSound();
    }


    if (
      snoozedAlarmIndex == index
    ) {

      snoozeActive = false;
      snoozedAlarmIndex = -1;
      snoozeUntilUnix = 0;
    }


    saveAlarms();

    sendBLEMessage(
      "OK:DELETE"
    );

    sendAlarms();

    displayCurrentScreen();

    return;
  }


  // ==========================================================
  // EDIT ALARM
  //
  // EDIT:0:07:30:1:Wake Up
  // ==========================================================

  if (
    command.startsWith(
      "EDIT:"
    )
  ) {

    String remaining =
      command.substring(5);


    int firstColon =
      remaining.indexOf(':');

    int secondColon =
      remaining.indexOf(
        ':',
        firstColon + 1
      );

    int thirdColon =
      remaining.indexOf(
        ':',
        secondColon + 1
      );

    int fourthColon =
      remaining.indexOf(
        ':',
        thirdColon + 1
      );


    if (
      firstColon < 0 ||
      secondColon < 0 ||
      thirdColon < 0 ||
      fourthColon < 0
    ) {

      sendBLEMessage(
        "ERROR:INVALID_EDIT"
      );

      return;
    }


    int index =
      remaining
        .substring(
          0,
          firstColon
        )
        .toInt();

    int hour =
      remaining
        .substring(
          firstColon + 1,
          secondColon
        )
        .toInt();

    int minute =
      remaining
        .substring(
          secondColon + 1,
          thirdColon
        )
        .toInt();

    int enabled =
      remaining
        .substring(
          thirdColon + 1,
          fourthColon
        )
        .toInt();

    String label =
      remaining.substring(
        fourthColon + 1
      );


    if (
      index < 0 ||
      index >= alarmCount ||
      !isValidHour(hour) ||
      !isValidMinute(minute) ||
      (enabled != 0 && enabled != 1)
    ) {

      sendBLEMessage(
        "ERROR:INVALID_EDIT"
      );

      return;
    }


    alarms[index].hour =
      hour;

    alarms[index].minute =
      minute;

    alarms[index].enabled =
      enabled == 1;

    alarms[index].label =
      label;


    /*
      Editing an alarm cancels an active/snoozed state
      for that alarm.
    */

    if (
      activeAlarmIndex == index
    ) {

      stopAlarmSound();
    }


    if (
      snoozedAlarmIndex == index
    ) {

      snoozeActive = false;
      snoozedAlarmIndex = -1;
      snoozeUntilUnix = 0;
    }


    saveAlarms();

    sendBLEMessage(
      "OK:EDIT"
    );

    sendAlarms();

    displayCurrentScreen();

    return;
  }


  // ==========================================================
  // SNOOZE CURRENT ALARM
  //
  // SNOOZE
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "SNOOZE"
    )
  ) {

    if (
      !alarmSoundActive ||
      activeAlarmIndex < 0
    ) {

      sendBLEMessage(
        "ERROR:NO_ACTIVE_ALARM"
      );

      return;
    }


    snoozeActive = true;

    snoozedAlarmIndex =
      activeAlarmIndex;

    snoozeUntilUnix =
      rtc.now().unixtime()
      + ((uint32_t)snoozeMinutes * 60UL);


    int index =
      activeAlarmIndex;


    stopAlarmSound();


    Serial.print(
      "[ALARM] Snoozed alarm "
    );

    Serial.print(
      index
    );

    Serial.print(
      " for "
    );

    Serial.print(
      snoozeMinutes
    );

    Serial.println(
      " minute(s)."
    );


    sendBLEMessage(
      "OK:ALARM_SNOOZED:" +
      String(snoozeMinutes)
    );

    return;
  }


  // ==========================================================
  // SNOOZE WITH EXPLICIT MINUTES
  //
  // SNOOZE:10
  // ==========================================================

  if (
    command.startsWith(
      "SNOOZE:"
    )
  ) {

    if (
      !alarmSoundActive ||
      activeAlarmIndex < 0
    ) {

      sendBLEMessage(
        "ERROR:NO_ACTIVE_ALARM"
      );

      return;
    }


    int minutes =
      command.substring(7).toInt();


    if (
      minutes < 1 ||
      minutes > 60
    ) {

      sendBLEMessage(
        "ERROR:INVALID_SNOOZE"
      );

      return;
    }


    snoozeActive = true;

    snoozedAlarmIndex =
      activeAlarmIndex;

    snoozeUntilUnix =
      rtc.now().unixtime()
      + ((uint32_t)minutes * 60UL);


    stopAlarmSound();


    sendBLEMessage(
      "OK:ALARM_SNOOZED:" +
      String(minutes)
    );

    return;
  }


  // ==========================================================
  // STOP ALARM
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "STOP_ALARM"
    ) ||
    command.equalsIgnoreCase(
      "ALARM:STOP"
    )
  ) {

    if (alarmSoundActive) {

      stopAlarmSound();

      sendBLEMessage(
        "OK:ALARM_STOPPED"
      );

    } else {

      sendBLEMessage(
        "ERROR:NO_ACTIVE_ALARM"
      );
    }

    return;
  }


  // ==========================================================
  // TIME SYNC
  //
  // Existing command preserved:
  //
  // TIME:<unix_timestamp>
  //
  // V3.0 stores UTC directly.
  // ==========================================================

  if (
    command.startsWith(
      "TIME:"
    )
  ) {

    String value =
      command.substring(5);

    uint32_t unixTime =
      strtoul(
        value.c_str(),
        nullptr,
        10
      );


    /*
      Basic sanity check.
    */

    if (
      unixTime < 1700000000UL ||
      unixTime > 4102444800UL
    ) {

      sendBLEMessage(
        "ERROR:INVALID_TIME"
      );

      return;
    }


    if (!rtcAvailable) {

      sendBLEMessage(
        "ERROR:RTC_UNAVAILABLE"
      );

      return;
    }


    rtc.adjust(
      DateTime(unixTime)
    );


    preferences.putBool(
      "rtc_init",
      true
    );

    preferences.putBool(
      "rtc_utc",
      true
    );


    /*
      Reset alarm duplicate protection after a time sync.

      This allows the newly synchronized clock to correctly
      evaluate its current minute.
    */

    lastTriggeredAlarmIndex = -1;
    lastTriggeredAlarmDay = 0;

    lastHourlyChimeKey = 0;


    sendBLEMessage(
      "OK:TIME_SYNC"
    );

    displayCurrentScreen();

    Serial.println(
      "[RTC] Time synchronized from phone."
    );

    return;
  }


  // ==========================================================
  // SET:TIME:<unix>
  // ==========================================================

  if (
    command.startsWith(
      "SET:TIME:"
    )
  ) {

    String value =
      command.substring(9);

    uint32_t unixTime =
      strtoul(
        value.c_str(),
        nullptr,
        10
      );


    if (
      unixTime < 1700000000UL ||
      unixTime > 4102444800UL
    ) {

      sendBLEMessage(
        "ERROR:INVALID_TIME"
      );

      return;
    }


    if (!rtcAvailable) {

      sendBLEMessage(
        "ERROR:RTC_UNAVAILABLE"
      );

      return;
    }


    rtc.adjust(
      DateTime(unixTime)
    );


    preferences.putBool(
      "rtc_init",
      true
    );

    preferences.putBool(
      "rtc_utc",
      true
    );


    lastTriggeredAlarmIndex = -1;
    lastTriggeredAlarmDay = 0;
    lastHourlyChimeKey = 0;


    sendBLEMessage(
      "OK:TIME_SYNC"
    );

    displayCurrentScreen();

    return;
  }


  // ==========================================================
  // FACTORY RESET
  // ==========================================================

  if (
    command.equalsIgnoreCase(
      "FACTORY_RESET"
    )
  ) {

    Serial.println();
    Serial.println(
      "[SYSTEM] FACTORY RESET REQUESTED"
    );


    /*
      IMPORTANT:

      Do NOT erase the RTC.

      Factory reset restores JARVIS configuration,
      alarms and preferences but keeps the correct clock.

      This prevents a factory reset from unexpectedly
      changing the current time.
    */


    // --------------------------------------------------------
    // STOP ACTIVE SOUND
    // --------------------------------------------------------

    stopAlarmSound();


    // --------------------------------------------------------
    // CLEAR ALL ALARMS
    // --------------------------------------------------------

    alarmCount = 0;

    for (
      uint8_t i = 0;
      i < MAX_ALARMS;
      i++
    ) {

      alarms[i].hour = 0;
      alarms[i].minute = 0;
      alarms[i].enabled = false;
      alarms[i].label = "";

      String hKey =
        "h" + String(i);

      String mKey =
        "m" + String(i);

      String eKey =
        "e" + String(i);

      String lKey =
        "l" + String(i);

      preferences.remove(
        hKey.c_str()
      );

      preferences.remove(
        mKey.c_str()
      );

      preferences.remove(
        eKey.c_str()
      );

      preferences.remove(
        lKey.c_str()
      );
    }


    preferences.putUChar(
      "count",
      0
    );


    // --------------------------------------------------------
    // RESET SETTINGS
    // --------------------------------------------------------

    useFahrenheit = false;

    timezoneIndex = 1;

    snoozeMinutes =
      DEFAULT_SNOOZE_MIN;

    hourlyChimeEnabled = true;

    connectionChimeEnabled = true;

    disconnectionChimeEnabled = true;

    currentScreen =
      SCREEN_CLOCK;


    // --------------------------------------------------------
    // RESET RUNTIME
    // --------------------------------------------------------

    snoozeActive = false;

    snoozedAlarmIndex = -1;

    snoozeUntilUnix = 0;

    lastTriggeredAlarmIndex = -1;

    lastTriggeredAlarmDay = 0;

    lastHourlyChimeKey = 0;


    saveSettings();


    displayCurrentScreen();


    sendBLEMessage(
      "OK:FACTORY_RESET"
    );

    sendBLEMessage(
      "SCREEN:CLOCK"
    );

    sendBLEMessage(
      "ALARMS:COUNT=0"
    );


    Serial.println(
      "[SYSTEM] Factory reset complete."
    );

    return;
  }


  // ==========================================================
  // UNKNOWN COMMAND
  // ==========================================================

  sendBLEMessage(
    "ERROR:UNKNOWN_COMMAND"
  );

  Serial.print(
    "[BLE] Unknown command: "
  );

  Serial.println(
    command
  );
}


// ============================================================
// STARTUP ANIMATION
// ============================================================

void startupAnimation() {

  for (
    int progress = 10;
    progress <= 100;
    progress += 10
  ) {

    display.clearDisplay();

    display.setTextColor(
      SSD1306_WHITE
    );

    display.setTextSize(2);

    display.setCursor(
      36,
      8
    );

    display.print(
      "JARVIS"
    );


    display.setTextSize(1);

    display.setCursor(
      45,
      31
    );

    display.print(
      "BOOT"
    );


    // --------------------------------------------------------
    // Progress bar
    // --------------------------------------------------------

    display.drawRect(
      10,
      45,
      108,
      10,
      SSD1306_WHITE
    );

    int barWidth =
      map(
        progress,
        0,
        100,
        0,
        104
      );

    display.fillRect(
      12,
      47,
      barWidth,
      6,
      SSD1306_WHITE
    );


    display.setCursor(
      56,
      57
    );

    display.print(
      progress
    );

    display.print(
      "%"
    );


    display.display();

    delay(70);
  }
}


// ============================================================
// BLE INITIALIZATION
// ============================================================

void initializeBLE() {

  BLEDevice::init(
    BLE_DEVICE_NAME
  );


  bleServer =
    BLEDevice::createServer();


  bleServer->setCallbacks(
    new JARVISServerCallbacks()
  );


  BLEService* service =
    bleServer->createService(
      SERVICE_UUID
    );


  // ----------------------------------------------------------
  // TX
  // ----------------------------------------------------------

  txCharacteristic =
    service->createCharacteristic(
      TX_CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );


  txCharacteristic->addDescriptor(
    new BLE2902()
  );


  // ----------------------------------------------------------
  // RX
  // ----------------------------------------------------------

  rxCharacteristic =
    service->createCharacteristic(
      RX_CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_WRITE |
      BLECharacteristic::PROPERTY_WRITE_NR
    );


  rxCharacteristic->setCallbacks(
    new JARVISRXCallbacks()
  );


  service->start();


  BLEAdvertising* advertising =
    BLEDevice::getAdvertising();


  advertising->addServiceUUID(
    SERVICE_UUID
  );

  advertising->setScanResponse(
    true
  );

  advertising->setMinPreferred(
    0x06
  );

  advertising->setMinPreferred(
    0x12
  );


  BLEDevice::startAdvertising();


  Serial.println(
    "[BLE] JARVIS BLE advertising."
  );
}


// ============================================================
// SETUP
// ============================================================

void setup() {

  Serial.begin(
    115200
  );

  delay(300);


  Serial.println();
  Serial.println();
  Serial.println(
    "================================"
  );
  Serial.println(
    "       JARVIS SMART CLOCK"
  );
  Serial.println(
    "           V3.0"
  );
  Serial.println(
    "================================"
  );


  // ==========================================================
  // I2C
  // ==========================================================

  Wire.begin(
    OLED_SDA,
    OLED_SCL
  );


  // ==========================================================
  // OLED
  // ==========================================================

  if (
    !display.begin(
      SSD1306_SWITCHCAPVCC,
      OLED_ADDRESS
    )
  ) {

    Serial.println(
      "[OLED] OLED initialization failed."
    );

  } else {

    Serial.println(
      "[OLED] OLED initialized."
    );
  }


  display.clearDisplay();

  display.setTextColor(
    SSD1306_WHITE
  );

  display.display();


  // ==========================================================
  // DHT
  // ==========================================================

  dht.begin();

  Serial.println(
    "[DHT] DHT22 initialized."
  );


  // ==========================================================
  // PREFERENCES
  // ==========================================================

  initializePreferences();


  // ==========================================================
  // LOAD SETTINGS
  // ==========================================================

  loadSettings();


  // ==========================================================
  // RTC
  // ==========================================================

  initializeRTC();


  // ==========================================================
  // LOAD ALARMS
  // ==========================================================

  loadAlarms();


  // ==========================================================
  // BUTTON
  // ==========================================================

  pinMode(
    BUTTON_PIN,
    INPUT_PULLUP
  );


  // ==========================================================
  // BUZZER
  // ==========================================================

  initializeBuzzer();


  // ==========================================================
  // BLE
  // ==========================================================

  initializeBLE();


  // ==========================================================
  // INITIAL DHT READ
  // ==========================================================

  delay(500);

  temperatureC =
    dht.readTemperature();

  humidity =
    dht.readHumidity();


  if (
    isnan(temperatureC) ||
    isnan(humidity)
  ) {

    Serial.println(
      "[DHT] Initial read failed."
    );

  } else {

    Serial.print(
      "[DHT] Initial temperature: "
    );

    Serial.print(
      temperatureC
    );

    Serial.println(
      " C"
    );

    Serial.print(
      "[DHT] Initial humidity: "
    );

    Serial.print(
      humidity
    );

    Serial.println(
      " %"
    );
  }


  // ==========================================================
  // STARTUP ANIMATION
  // ==========================================================

  startupAnimation();


  // ==========================================================
  // FINAL RTC REPORT
  // ==========================================================

  if (rtcAvailable) {

    DateTime utc =
      rtc.now();

    DateTime local =
      getLocalDateTime();


    Serial.println();
    Serial.println(
      "[RTC] Current UTC:"
    );

    Serial.print(
      utc.year()
    );

    Serial.print("-");

    Serial.print(
      utc.month()
    );

    Serial.print("-");

    Serial.print(
      utc.day()
    );

    Serial.print(" ");

    Serial.print(
      utc.hour()
    );

    Serial.print(":");

    Serial.print(
      utc.minute()
    );

    Serial.print(":");

    Serial.println(
      utc.second()
    );


    Serial.println(
      "[RTC] Current local time:"
    );

    Serial.print(
      local.year()
    );

    Serial.print("-");

    Serial.print(
      local.month()
    );

    Serial.print("-");

    Serial.print(
      local.day()
    );

    Serial.print(" ");

    Serial.print(
      local.hour()
    );

    Serial.print(":");

    Serial.print(
      local.minute()
    );

    Serial.print(":");

    Serial.println(
      local.second()
    );


    Serial.print(
      "[RTC] Timezone: "
    );

    Serial.println(
      timezones[timezoneIndex].name
    );
  }


  // ==========================================================
  // ALWAYS START ON CLOCK
  // ==========================================================

  currentScreen =
    SCREEN_CLOCK;

  saveSettings();

  displayCurrentScreen();


  Serial.println();
  Serial.println(
    "================================"
  );
  Serial.println(
    "      JARVIS STARTUP COMPLETE"
  );
  Serial.println(
    "================================"
  );
  Serial.println();
}


// ============================================================
// MAIN LOOP
// ============================================================

void loop() {

  // ----------------------------------------------------------
  // PHYSICAL BUTTON
  // ----------------------------------------------------------

  handleButton();


  // ----------------------------------------------------------
  // DHT22
  // ----------------------------------------------------------

  updateDHT();


  // ----------------------------------------------------------
  // NORMAL ALARMS + SNOOZED ALARMS
  // ----------------------------------------------------------

  checkAlarmSystem();


  // ----------------------------------------------------------
  // HOURLY CHIME
  // ----------------------------------------------------------

  checkHourlyChime();


  // ----------------------------------------------------------
  // OLED UPDATE
  // ----------------------------------------------------------

  if (
    millis() - lastDisplayUpdate
    >= DISPLAY_INTERVAL
  ) {

    lastDisplayUpdate =
      millis();

    displayCurrentScreen();
  }


  // ----------------------------------------------------------
  // BLE CONNECTION STATE
  // ----------------------------------------------------------

  if (
    deviceConnected &&
    !oldDeviceConnected
  ) {

    oldDeviceConnected = true;

    Serial.println(
      "[BLE] Connection state confirmed."
    );
  }


  if (
    !deviceConnected &&
    oldDeviceConnected
  ) {

    oldDeviceConnected = false;

    Serial.println(
      "[BLE] Connection state lost."
    );

    /*
      Safety guarantee:

      Regardless of how the disconnect occurred,
      always return to Clock.
    */

    currentScreen =
      SCREEN_CLOCK;

    saveSettings();

    stopAlarmSound();

    displayCurrentScreen();
  }


  delay(20);
}