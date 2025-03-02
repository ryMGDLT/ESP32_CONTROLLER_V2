#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <HTTPClient.h>

#define SERVICE_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CONFIG_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CONTROL_CHAR_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

WebServer server(80);
HTTPClient http;

const int lightPins[] = {2, 4, 5, 18};
const int buttonPins[] = {15, 21, 22, 23};
const int numLights = 4;

BLECharacteristic* pConfigCharacteristic;
BLECharacteristic* pControlCharacteristic;
BLEAdvertising* pAdvertising;
BLEServer* pServer;
bool serviceAdded = false;
bool isBluetoothMode = false;
bool lastButtonStates[numLights] = {HIGH, HIGH, HIGH, HIGH};
unsigned long lastDebounceTimes[numLights] = {0, 0, 0, 0};
const unsigned long debounceDelay = 50;
String appIP = "";

void startServices() {
  if (MDNS.begin("esp32-light-control")) {
    Serial.println("mDNS responder started");
    if (!serviceAdded) {
      MDNS.addService("http", "tcp", 80);
      serviceAdded = true;
    }
  } else {
    Serial.println("Error starting mDNS");
  }

  server.on("/light1/on", []() { digitalWrite(lightPins[0], HIGH); updateControlCharacteristic(0, true); server.send(200, "text/plain", "Light 1 ON"); });
  server.on("/light1/off", []() { digitalWrite(lightPins[0], LOW); updateControlCharacteristic(0, false); server.send(200, "text/plain", "Light 1 OFF"); });
  server.on("/light2/on", []() { digitalWrite(lightPins[1], HIGH); updateControlCharacteristic(1, true); server.send(200, "text/plain", "Light 2 ON"); });
  server.on("/light2/off", []() { digitalWrite(lightPins[1], LOW); updateControlCharacteristic(1, false); server.send(200, "text/plain", "Light 2 OFF"); });
  server.on("/light3/on", []() { digitalWrite(lightPins[2], HIGH); updateControlCharacteristic(2, true); server.send(200, "text/plain", "Light 3 ON"); });
  server.on("/light3/off", []() { digitalWrite(lightPins[2], LOW); updateControlCharacteristic(2, false); server.send(200, "text/plain", "Light 3 OFF"); });
  server.on("/light4/on", []() { digitalWrite(lightPins[3], HIGH); updateControlCharacteristic(3, true); server.send(200, "text/plain", "Light 4 ON"); });
  server.on("/light4/off", []() { digitalWrite(lightPins[3], LOW); updateControlCharacteristic(3, false); server.send(200, "text/plain", "Light 4 OFF"); });
  server.on("/new-config", []() {
    WiFi.disconnect();
    server.send(200, "text/plain", "Ready for new config");
    isBluetoothMode = true;
    appIP = "";
    pAdvertising->stop();
    delay(100);
    pAdvertising->start();
    Serial.println("Switched to BLE mode for new config");
  });

  server.begin();
  Serial.println("HTTP server started");
}

void updateControlCharacteristic(int lightNum, bool state) {
  String command = "LIGHT" + String(lightNum + 1) + ":" + (state ? "ON" : "OFF");
  pControlCharacteristic->setValue(command.c_str());
  pControlCharacteristic->notify();
  Serial.println("Notified app via BLE: " + command);

  if (!isBluetoothMode && appIP != "") {
    http.begin("http://" + appIP + "/update");
    http.addHeader("Content-Type", "application/json");
    String payload = "{\"light\":" + String(lightNum + 1) + ",\"state\":\"" + (state ? "ON" : "OFF") + "\"}";
    int httpCode = http.POST(payload);
    if (httpCode > 0) {
      Serial.println("HTTP POST to app: " + payload + " - Response: " + httpCode);
    } else {
      String error = http.errorToString(httpCode);
      Serial.println("HTTP POST failed to " + appIP + ": " + error);
    }
    http.end();
  }
}

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
        while (WiFi.status() != WL_CONNECTED && attempts < 20) { // Reduced to 10 seconds
          delay(500);
          Serial.print(".");
          attempts++;
        }

        if (WiFi.status() == WL_CONNECTED) {
          Serial.println("\nConnected to Wi-Fi");
          String ip = WiFi.localIP().toString();
          Serial.println("IP Address: " + ip);
          startServices();
          pConfigCharacteristic->setValue(ip.c_str());
          pConfigCharacteristic->notify();
          Serial.println("Sent IP via BLE: " + ip);
          pAdvertising->stop();
          delay(100);
          pAdvertising->start();
        } else {
          Serial.println("\nFailed to connect to Wi-Fi");
          pConfigCharacteristic->setValue("FAIL");
          pConfigCharacteristic->notify();
          Serial.println("Sent FAIL via BLE");
          pAdvertising->start();
        }
      }
    } else if (value == "BLUETOOTH") {
      isBluetoothMode = true;
      WiFi.disconnect();
      appIP = "";
      Serial.println("Bluetooth mode selected");
      pAdvertising->stop();
      delay(100);
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
        Serial.println("Light " + String(lightNum + 1) + " set to " + state);
      }
    }
  }
};

void setup() {
  Serial.begin(115200);

  for (int i = 0; i < numLights; i++) {
    pinMode(lightPins[i], OUTPUT);
    digitalWrite(lightPins[i], LOW);
    pinMode(buttonPins[i], INPUT_PULLUP);
  }

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

  pService->start();
  pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->start();
  Serial.println("BLE started, waiting for configuration...");
}

void loop() {
  if (!isBluetoothMode) {
    server.handleClient();
  }

  for (int i = 0; i < numLights; i++) {
    int buttonState = digitalRead(buttonPins[i]);
    if (buttonState != lastButtonStates[i]) {
      lastDebounceTimes[i] = millis();
    }

    if ((millis() - lastDebounceTimes[i]) > debounceDelay) {
      if (buttonState == LOW) {
        bool currentState = digitalRead(lightPins[i]);
        digitalWrite(lightPins[i], !currentState);
        updateControlCharacteristic(i, !currentState);
        delay(200);
      }
    }

    lastButtonStates[i] = buttonState;
  }

  delay(10);
}