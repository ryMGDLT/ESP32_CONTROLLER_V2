#include <WiFi.h>
#include <ESPmDNS.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <time.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h> cxs

#define SERVICE_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CONFIG_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CONTROL_CHAR_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define SCHEDULE_CHAR_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

AsyncWebServer server(1024);
HTTPClient http;
LiquidCrystal_I2C lcd(0x27, 16, 2);

const int lightPins[] = {2, 4, 5, 18};
const int switchPins[] = {15, 21, 22, 23};
const int buttonPins[] = {19, 17, 16, 13};
const int numLights = 4;

BLECharacteristic* pConfigCharacteristic = nullptr;
BLECharacteristic* pControlCharacteristic = nullptr;
BLECharacteristic* pScheduleCharacteristic = nullptr;
BLEAdvertising* pAdvertising = nullptr;
BLEServer* pServer = nullptr;
bool serviceAdded = false;
bool isBluetoothMode = false;
bool timeSynced = false;

bool lastSwitchStates[numLights] = {HIGH, HIGH, HIGH, HIGH};
bool lastButtonStates[numLights] = {HIGH, HIGH, HIGH, HIGH};
unsigned long lastSwitchDebounceTimes[numLights] = {0, 0, 0, 0};
unsigned long lastButtonDebounceTimes[numLights] = {0, 0, 0, 0};
const unsigned long debounceDelay = 100;
String appIP = "";

const char* ntpServer = "asia.pool.ntp.org";
const long gmtOffset_sec = 28800; // GMT+8 for Manila
const int daylightOffset_sec = 0;
struct tm timeinfo;

struct LedSchedule {
  int hourOn, minuteOn, hourOff, minuteOff;
  bool scheduled;
};
LedSchedule schedules[numLights] = {{0, 0, 0, 0, false}, {0, 0, 0, 0, false}, {0, 0, 0, 0, false}, {0, 0, 0, 0, false}};

int menuState = 0;
int selectedLed = 0;
int setHour = 0, setMinute = 0;
bool settingOnTime = true;
bool settingHour = true;

struct LightUpdate {
  int lightNum;
  bool state;
};
QueueHandle_t lightUpdateQueue;

void startServices();
void updateControlCharacteristic(int lightNum, bool state, bool fromHttp = false);
void updateScheduleCharacteristic(int lightNum);
void syncTime();
void syncTimePeriodic(void* pvParameters);
void updateLCD(void* pvParameters);
void handleSwitches(void* pvParameters);
void handleButtons(void* pvParameters);
void checkSchedules(void* pvParameters);
void handleHttpUpdates(void* pvParameters);

class ConfigCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    Serial.println("Received BLE data: " + value);

    if (value.startsWith("WIFI:")) {
      isBluetoothMode = false;
      value.remove(0, 5);
      int appIPSeparator = value.indexOf('|');
      String ssid, password;
      
      if (appIPSeparator != -1) {
        String wifiData = value.substring(0, appIPSeparator);
        appIP = value.substring(appIPSeparator + 1);
        int separatorIndex = wifiData.indexOf(':');
        if (separatorIndex != -1) {
          ssid = wifiData.substring(0, separatorIndex);
          password = wifiData.substring(separatorIndex + 1);
        }
      } else {
        int separatorIndex = value.indexOf(':');
        if (separatorIndex != -1) {
          ssid = value.substring(0, separatorIndex);
          password = value.substring(separatorIndex + 1);
        }
      }

      if (ssid.length() > 0 && password.length() > 0) {
        Serial.println("Connecting to Wi-Fi - SSID: " + ssid);
        if (appIP != "") Serial.println("App IP received: " + appIP);
        
        WiFi.begin(ssid.c_str(), password.c_str());
        int attempts = 0;
        while (WiFi.status() != WL_CONNECTED && attempts < 20) {
          vTaskDelay(500 / portTICK_PERIOD_MS);
          Serial.print(".");
          attempts++;
        }

        if (WiFi.status() == WL_CONNECTED) {
          Serial.println("\nConnected to Wi-Fi");
          String ip = WiFi.localIP().toString();
          Serial.println("IP Address: " + ip);
          startServices();
          
          if (pConfigCharacteristic) {
            pConfigCharacteristic->setValue(ip.c_str());
            pConfigCharacteristic->notify();
            Serial.println("Sent IP via BLE: " + ip);
          }
          
          pAdvertising->stop();
          vTaskDelay(100 / portTICK_PERIOD_MS);
          pAdvertising->start();
          
          syncTime();
          xTaskCreate([](void* param) {
            vTaskDelay(1000 / portTICK_PERIOD_MS);
            HTTPClient testHttp;
            testHttp.begin("http://www.google.com");
            int httpCode = testHttp.GET();
            if (httpCode > 0) {
              Serial.println("Internet test: Google reachable, code " + String(httpCode));
            } else {
              Serial.println("Internet test: Failed to reach Google, error " + testHttp.errorToString(httpCode));
            }
            testHttp.end();
            for (int i = 0; i < numLights; i++) {
              updateControlCharacteristic(i, digitalRead(lightPins[i]));
            }
            vTaskDelete(NULL);
          }, "PostConnectTask", 4096, NULL, 1, NULL);
        } else {
          Serial.println("\nFailed to connect to Wi-Fi");
          if (pConfigCharacteristic) {
            pConfigCharacteristic->setValue("FAIL");
            pConfigCharacteristic->notify();
            Serial.println("Sent FAIL via BLE");
          }
          pAdvertising->start();
        }
      }
    } else if (value == "BLUETOOTH") {
      isBluetoothMode = true;
      WiFi.disconnect();
      appIP = "";
      Serial.println("Bluetooth mode selected");
      pAdvertising->stop();
      vTaskDelay(100 / portTICK_PERIOD_MS);
      pAdvertising->start();
    }
  }
};

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    Serial.println("Received control data: " + value);

    if (value.startsWith("LIGHT")) {
      int lightNum = value.substring(5, 6).toInt() - 1;
      String state = value.substring(7);
      if (lightNum >= 0 && lightNum < numLights) {
        digitalWrite(lightPins[lightNum], state == "ON" ? HIGH : LOW);
        updateControlCharacteristic(lightNum, state == "ON");
        Serial.println("Light " + String(lightNum + 1) + " set to " + state + " via BLE");
      }
    }
  }
};

class ScheduleCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    Serial.println("Received schedule data: " + value);

    if (value.startsWith("SCHEDULE")) {
      int lightNum = value.substring(8, 9).toInt() - 1;
      if (lightNum >= 0 && lightNum < numLights) {
        int colon1 = value.indexOf(':', 9);    
        int colon2 = value.indexOf(':', colon1 + 1); 
        int dash = value.indexOf('-', colon2); 
        int colon3 = value.indexOf(':', dash + 1);

        int hourOn = value.substring(colon1 + 1, colon2).toInt();   
        int minOn = value.substring(colon2 + 1, dash).toInt();      
        int hourOff = value.substring(dash + 1, colon3).toInt();    
        int minOff = value.substring(colon3 + 1).toInt();           

        schedules[lightNum].hourOn = hourOn;
        schedules[lightNum].minuteOn = minOn;
        schedules[lightNum].hourOff = hourOff;
        schedules[lightNum].minuteOff = minOff;
        schedules[lightNum].scheduled = true;

        Serial.println("Scheduled LED " + String(lightNum + 1) + ": " + 
                       hourOn + ":" + minOn + " - " + hourOff + ":" + minOff);
        updateScheduleCharacteristic(lightNum);
      }
    }
  }
};

void startServices() {
  if (MDNS.begin("esp32-light-control")) {
    Serial.println("mDNS responder started");
    if (!serviceAdded) {
      MDNS.addService("http", "tcp", 1024);
      serviceAdded = true;
    }
  } else {
    Serial.println("Error starting mDNS");
  }

  server.on("/light1/on", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[0], HIGH);
    updateControlCharacteristic(0, true, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light1/off", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[0], LOW);
    updateControlCharacteristic(0, false, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light2/on", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[1], HIGH);
    updateControlCharacteristic(1, true, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light2/off", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[1], LOW);
    updateControlCharacteristic(1, false, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light3/on", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[2], HIGH);
    updateControlCharacteristic(2, true, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light3/off", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[2], LOW);
    updateControlCharacteristic(2, false, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light4/on", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[3], HIGH);
    updateControlCharacteristic(3, true, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/light4/off", HTTP_GET, [](AsyncWebServerRequest* request) {
    digitalWrite(lightPins[3], LOW);
    updateControlCharacteristic(3, false, true);
    request->send(200, "text/plain", "OK");
  });
  server.on("/new-config", HTTP_GET, [](AsyncWebServerRequest* request) {
    WiFi.disconnect();
    request->send(200, "text/plain", "OK");
    isBluetoothMode = true;
    appIP = "";
    pAdvertising->stop();
    vTaskDelay(100 / portTICK_PERIOD_MS);
    pAdvertising->start();
    Serial.println("Switched to BLE mode for new config");
  });

  server.on("/schedule", HTTP_POST, [](AsyncWebServerRequest* request) {
    if (request->hasParam("plain", true)) {
      String body = request->getParam("plain", true)->value();
      int lightNum = body.substring(body.indexOf("light") + 7, body.indexOf(",", body.indexOf("light"))).toInt() - 1;
      int hourOn = body.substring(body.indexOf("hourOn") + 8, body.indexOf(",", body.indexOf("hourOn"))).toInt();
      int minOn = body.substring(body.indexOf("minuteOn") + 10, body.indexOf(",", body.indexOf("minuteOn"))).toInt();
      int hourOff = body.substring(body.indexOf("hourOff") + 9, body.indexOf(",", body.indexOf("hourOff"))).toInt();
      int minOff = body.substring(body.indexOf("minuteOff") + 11, body.indexOf("}")).toInt();

      if (lightNum >= 0 && lightNum < numLights) {
        schedules[lightNum].hourOn = hourOn;
        schedules[lightNum].minuteOn = minOn;
        schedules[lightNum].hourOff = hourOff;
        schedules[lightNum].minuteOff = minOff;
        schedules[lightNum].scheduled = true;
        updateScheduleCharacteristic(lightNum);
        request->send(200, "text/plain", "OK");
        Serial.println("Scheduled via HTTP: LED " + String(lightNum + 1));
      } else {
        request->send(400, "text/plain", "Invalid LED number");
      }
    } else {
      request->send(400, "text/plain", "No data");
    }
  });

  server.onNotFound([](AsyncWebServerRequest* request) {
    request->send(404, "text/plain", "Not Found");
  });

  server.on("/test", HTTP_GET, [](AsyncWebServerRequest* request) {
    request->send(200, "text/plain", "OK");
  });

  server.begin();
  Serial.println("Async HTTP server started on port 1024");
}

void updateControlCharacteristic(int lightNum, bool state, bool fromHttp) {
  if (pControlCharacteristic == nullptr) {
    Serial.println("Error: pControlCharacteristic is null");
    return;
  }
  String command = "LIGHT" + String(lightNum + 1) + ":" + (state ? "ON" : "OFF");
  pControlCharacteristic->setValue(command.c_str());
  pControlCharacteristic->notify();
  Serial.println("BLE notified: " + command);

  if (!fromHttp && !isBluetoothMode && appIP != "" && WiFi.status() == WL_CONNECTED) {
    LightUpdate update = {lightNum, state};
    if (xQueueSend(lightUpdateQueue, &update, 0) != pdTRUE) {
      Serial.println("Failed to queue light update for HTTP POST");
    }
  }
}

void updateScheduleCharacteristic(int lightNum) {
  if (pScheduleCharacteristic == nullptr) return;
  String schedule = "SCHEDULE" + String(lightNum + 1) + ":" + 
                    String(schedules[lightNum].hourOn) + ":" + String(schedules[lightNum].minuteOn) + "-" + 
                    String(schedules[lightNum].hourOff) + ":" + String(schedules[lightNum].minuteOff);
  pScheduleCharacteristic->setValue(schedule.c_str());
  pScheduleCharacteristic->notify();
  Serial.println("Schedule notified: " + schedule);

  if (!isBluetoothMode && appIP != "" && WiFi.status() == WL_CONNECTED) {
    String url = "http://" + appIP + "/schedule-update";
    http.begin(url);
    http.addHeader("Content-Type", "application/json");
    String payload = "{\"light\":" + String(lightNum + 1) + 
                     ",\"hourOn\":" + String(schedules[lightNum].hourOn) + 
                     ",\"minuteOn\":" + String(schedules[lightNum].minuteOn) + 
                     ",\"hourOff\":" + String(schedules[lightNum].hourOff) + 
                     ",\"minuteOff\":" + String(schedules[lightNum].minuteOff) + "}";
    int httpCode = http.POST(payload);
    if (httpCode > 0) {
      Serial.println("HTTP schedule update sent: " + payload);
    } else {
      Serial.println("HTTP schedule update failed: " + http.errorToString(httpCode));
    }
    http.end();
  }
}

void syncTime() {
  configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
  int retries = 10;
  for (int i = 0; i < retries; i++) {
    if (getLocalTime(&timeinfo)) {
      Serial.println("NTP time synchronized (Manila): " + String(timeinfo.tm_hour) + ":" + String(timeinfo.tm_min) + ":" + String(timeinfo.tm_sec));
      timeSynced = true;
      return;
    }
    vTaskDelay(1000 / portTICK_PERIOD_MS);
  }
  timeSynced = false;
}

void syncTimePeriodic(void* pvParameters) {
  while (1) {
    if (WiFi.status() == WL_CONNECTED) syncTime();
    vTaskDelay(3600000 / portTICK_PERIOD_MS); 
  }
}

void updateLCD(void* pvParameters) {
  while (1) {
    lcd.clear();
    if (getLocalTime(&timeinfo)) {
      switch (menuState) {
        case 0:
          lcd.setCursor(0, 0);
          lcd.print(&timeinfo, "%Y-%m-%d");
          lcd.setCursor(0, 1);
          lcd.print(&timeinfo, "%H:%M:%S");
          break;
        case 1:
          lcd.setCursor(0, 0);
          lcd.print(schedules[0].scheduled ? "L1:" + String(schedules[0].hourOn) + ":" + String(schedules[0].minuteOn) + "-" + String(schedules[0].hourOff) + ":" + String(schedules[0].minuteOff) : "L1: No Schedule");
          lcd.setCursor(0, 1);
          lcd.print(schedules[1].scheduled ? "L2:" + String(schedules[1].hourOn) + ":" + String(schedules[1].minuteOn) + "-" + String(schedules[1].hourOff) + ":" + String(schedules[1].minuteOff) : "L2: No Schedule");
          break;
        case 2:
          lcd.setCursor(0, 0);
          lcd.print(schedules[2].scheduled ? "L3:" + String(schedules[2].hourOn) + ":" + String(schedules[2].minuteOn) + "-" + String(schedules[2].hourOff) + ":" + String(schedules[2].minuteOff) : "L3: No Schedule");
          lcd.setCursor(0, 1);
          lcd.print(schedules[3].scheduled ? "L4:" + String(schedules[3].hourOn) + ":" + String(schedules[3].minuteOn) + "-" + String(schedules[3].hourOff) + ":" + String(schedules[3].minuteOff) : "L4: No Schedule");
          break;
        case 3:
          lcd.setCursor(0, 0);
          lcd.print("Schedule LED");
          lcd.setCursor(0, 1);
          lcd.print("LED " + String(selectedLed + 1));
          break;
        case 4:
          lcd.setCursor(0, 0);
          lcd.print(settingOnTime ? "Set On Time" : "Set Off Time");
          lcd.setCursor(0, 1);
          lcd.print(String(setHour) + ":" + String(setMinute));
          break;
      }
    } else {
      lcd.setCursor(0, 0);
      lcd.print("No NTP Time");
    }
    vTaskDelay(500 / portTICK_PERIOD_MS);
  }
}

void handleSwitches(void* pvParameters) {
  while (1) {
    for (int i = 0; i < numLights; i++) {
      int switchState = digitalRead(switchPins[i]);
      if (switchState != lastSwitchStates[i]) {
        lastSwitchDebounceTimes[i] = millis();
        lastSwitchStates[i] = switchState;
      }
      if (millis() - lastSwitchDebounceTimes[i] > debounceDelay && switchState == LOW) {
        bool currentState = digitalRead(lightPins[i]);
        bool newState = !currentState;
        digitalWrite(lightPins[i], newState);
        updateControlCharacteristic(i, newState);
        lastSwitchDebounceTimes[i] = millis();
      }
    }
    vTaskDelay(10 / portTICK_PERIOD_MS);
  }
}

void handleButtons(void* pvParameters) {
  while (1) {
    for (int i = 0; i < numLights; i++) {
      int buttonState = digitalRead(buttonPins[i]);
      if (buttonState != lastButtonStates[i]) {
        lastButtonDebounceTimes[i] = millis();
        lastButtonStates[i] = buttonState;
      }
      if (millis() - lastButtonDebounceTimes[i] > debounceDelay && buttonState == LOW) {
        if (i == 0) {
          menuState = (menuState + 1) % 4;
          if (menuState == 3) selectedLed = 0;
        } else if (menuState == 3 && i == 1) {
          selectedLed = (selectedLed + 1) % numLights;
        } else if (menuState == 3 && i == 2) {
          selectedLed = (selectedLed - 1 + numLights) % numLights;
        } else if (menuState == 3 && i == 3) {
          menuState = 4;
          setHour = 0;
          setMinute = 0;
          settingOnTime = true;
          settingHour = true;
          Serial.println("Entering scheduling mode for LED " + String(selectedLed + 1));
        } else if (menuState == 4 && i == 1) {
          if (settingHour) setHour = (setHour + 1) % 24;
          else setMinute = (setMinute + 1) % 60;
        } else if (menuState == 4 && i == 2) {
          if (settingHour) setHour = (setHour - 1 + 24) % 24;
          else setMinute = (setMinute - 1 + 60) % 60;
        } else if (menuState == 4 && i == 3) {
          if (settingOnTime) {
            if (settingHour) {
              settingHour = false;
            } else {
              schedules[selectedLed].hourOn = setHour;
              schedules[selectedLed].minuteOn = setMinute;
              settingOnTime = false;
              settingHour = true;
              setHour = 0;
              setMinute = 0;
              Serial.println("Set LED " + String(selectedLed + 1) + " ON time: " + String(schedules[selectedLed].hourOn) + ":" + String(schedules[selectedLed].minuteOn));
            }
          } else {
            if (settingHour) {
              settingHour = false;
            } else {
              schedules[selectedLed].hourOff = setHour;
              schedules[selectedLed].minuteOff = setMinute;
              schedules[selectedLed].scheduled = true;
              updateScheduleCharacteristic(selectedLed); 
              menuState = 0;
              Serial.println("Set LED " + String(selectedLed + 1) + " OFF time: " + String(schedules[selectedLed].hourOff) + ":" + String(schedules[selectedLed].minuteOff));
            }
          }
        }
        lastButtonDebounceTimes[i] = millis();
      }
    }
    vTaskDelay(10 / portTICK_PERIOD_MS);
  }
}

void checkSchedules(void* pvParameters) {
  while (1) {
    if (timeSynced && getLocalTime(&timeinfo)) {
      for (int i = 0; i < numLights; i++) {
        if (schedules[i].scheduled) {
          if (timeinfo.tm_hour == schedules[i].hourOn && 
              timeinfo.tm_min == schedules[i].minuteOn && 
              timeinfo.tm_sec == 0) {
            digitalWrite(lightPins[i], HIGH);
            updateControlCharacteristic(i, true);
            Serial.println("LED " + String(i + 1) + " turned ON at " + 
                           String(timeinfo.tm_hour) + ":" + String(timeinfo.tm_min) + ":" + String(timeinfo.tm_sec));
          }
          if (timeinfo.tm_hour == schedules[i].hourOff && 
              timeinfo.tm_min == schedules[i].minuteOff && 
              timeinfo.tm_sec == 0) {
            digitalWrite(lightPins[i], LOW);
            updateControlCharacteristic(i, false);
            schedules[i].hourOn = 0;
            schedules[i].minuteOn = 0;
            schedules[i].hourOff = 0;
            schedules[i].minuteOff = 0;
            schedules[i].scheduled = false;
            updateScheduleCharacteristic(i); 
            Serial.println("LED " + String(i + 1) + " turned OFF at " + 
                           String(timeinfo.tm_hour) + ":" + String(timeinfo.tm_min) + ":" + String(timeinfo.tm_sec));
            Serial.println("Schedule for LED " + String(i + 1) + " cleared");
          }
        }
      }
    }
    vTaskDelay(1000 / portTICK_PERIOD_MS);
  }
}

void handleHttpUpdates(void* pvParameters) {
  WiFiClient wifiClient;
  HTTPClient http;

  while (1) {
    LightUpdate update;
    if (xQueueReceive(lightUpdateQueue, &update, portMAX_DELAY) == pdTRUE) {
      if (!isBluetoothMode && appIP != "" && WiFi.status() == WL_CONNECTED) {
        String url = "http://" + appIP + "/update";
        http.begin(wifiClient, url);
        http.addHeader("Content-Type", "application/json");

        String payload = "{\"light\":" + String(update.lightNum + 1) + ",\"state\":\"" + (update.state ? "ON" : "OFF") + "\"}";
        Serial.println("Sending HTTP POST: " + payload);
        
        int httpCode = http.POST(payload);
        if (httpCode > 0) {
          Serial.println("HTTP POST to app: " + payload + " - Response: " + String(httpCode));
        } else {
          Serial.println("HTTP POST failed to " + appIP + ": " + http.errorToString(httpCode));
        }
        http.end();
      } else {
        Serial.println("Not sending HTTP update: Bluetooth mode or no appIP/WiFi");
      }
    }
    vTaskDelay(100 / portTICK_PERIOD_MS);
  }
}

void setup() {
  Serial.begin(115200);

  lightUpdateQueue = xQueueCreate(10, sizeof(LightUpdate));
  if (lightUpdateQueue == NULL) {
    Serial.println("Failed to create light update queue");
    while (1);
  }

  for (int i = 0; i < numLights; i++) {
    pinMode(lightPins[i], OUTPUT);
    digitalWrite(lightPins[i], LOW);
    pinMode(switchPins[i], INPUT_PULLUP);
    pinMode(buttonPins[i], INPUT_PULLUP);
  }

  Wire.begin(26, 27);
  lcd.init();
  lcd.backlight();
  lcd.setCursor(0, 0);
  lcd.print("Starting...");
  vTaskDelay(2000 / portTICK_PERIOD_MS);

  BLEDevice::init("ESP32_Light_Control");
  pServer = BLEDevice::createServer();
  BLEService* pService = pServer->createService(SERVICE_UUID);

  pConfigCharacteristic = pService->createCharacteristic(
    CONFIG_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pConfigCharacteristic->addDescriptor(new BLE2902());
  pConfigCharacteristic->setCallbacks(new ConfigCallbacks());

  pControlCharacteristic = pService->createCharacteristic(
    CONTROL_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pControlCharacteristic->addDescriptor(new BLE2902());
  pControlCharacteristic->setCallbacks(new ControlCallbacks());

  pScheduleCharacteristic = pService->createCharacteristic(
    SCHEDULE_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pScheduleCharacteristic->addDescriptor(new BLE2902());
  pScheduleCharacteristic->setCallbacks(new ScheduleCallbacks());

  pService->start();
  pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();
  Serial.println("BLE started, waiting for configuration...");

  if (xTaskCreate(updateLCD, "LCD Task", 4096, NULL, 2, NULL) != pdPASS) Serial.println("Failed to create LCD Task");
  if (xTaskCreate(handleSwitches, "Switch Task", 2048, NULL, 1, NULL) != pdPASS) Serial.println("Failed to create Switch Task");
  if (xTaskCreate(handleButtons, "Button Task", 4096, NULL, 1, NULL) != pdPASS) Serial.println("Failed to create Button Task");
  if (xTaskCreate(checkSchedules, "Schedule Task", 2048, NULL, 1, NULL) != pdPASS) Serial.println("Failed to create Schedule Task");
  if (xTaskCreate(syncTimePeriodic, "NTP Sync Task", 2048, NULL, 1, NULL) != pdPASS) Serial.println("Failed to create NTP Sync Task");
  if (xTaskCreate(handleHttpUpdates, "HTTP Update Task", 8192, NULL, 1, NULL) != pdPASS) Serial.println("Failed to create HTTP Update Task");
}

void loop() {
  vTaskDelay(portMAX_DELAY);
} 

