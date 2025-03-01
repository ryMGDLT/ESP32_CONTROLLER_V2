#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// BLE UUIDs (match Flutter app)
#define SERVICE_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"//change to your own uuid https://www.uuidgenerator.net/ use this site
#define CONFIG_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8" //change this also this is same as the service_uuid
#define CONTROL_CHAR_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e" //generate new uuid and replace this 
// replace also the one in the flutter code app in app/lib/main.dart 

// HTTP server
WebServer server(80);

// Light pins 
const int lightPins[] = {2, 4, 5, 18}; 
const int numLights = 4;


BLECharacteristic* pConfigCharacteristic;
BLECharacteristic* pControlCharacteristic;
BLEAdvertising* pAdvertising;
BLEServer* pServer; 
bool serviceAdded = false;
bool isBluetoothMode = false;

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

  server.on("/light1/on", []() { digitalWrite(lightPins[0], HIGH); server.send(200, "text/plain", "Light 1 ON"); });
  server.on("/light1/off", []() { digitalWrite(lightPins[0], LOW); server.send(200, "text/plain", "Light 1 OFF"); });
  server.on("/light2/on", []() { digitalWrite(lightPins[1], HIGH); server.send(200, "text/plain", "Light 2 ON"); });
  server.on("/light2/off", []() { digitalWrite(lightPins[1], LOW); server.send(200, "text/plain", "Light 2 OFF"); });
  server.on("/light3/on", []() { digitalWrite(lightPins[2], HIGH); server.send(200, "text/plain", "Light 3 ON"); });
  server.on("/light3/off", []() { digitalWrite(lightPins[2], LOW); server.send(200, "text/plain", "Light 3 OFF"); });
  server.on("/light4/on", []() { digitalWrite(lightPins[3], HIGH); server.send(200, "text/plain", "Light 4 ON"); });
  server.on("/light4/off", []() { digitalWrite(lightPins[3], LOW); server.send(200, "text/plain", "Light 4 OFF"); });
  server.on("/new-config", []() { 
    WiFi.disconnect(); 
    server.send(200, "text/plain", "Ready for new config"); 
    isBluetoothMode = true;
    pAdvertising->stop(); 
    delay(100); 
    pAdvertising->start();
    Serial.println("Switched to BLE mode for new config");
  });

  server.begin();
  Serial.println("HTTP server started");
}

class ConfigCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    Serial.println("Received BLE data: " + value);

    if (value.startsWith("WIFI:")) {
      isBluetoothMode = false;
      value.remove(0, 5); 
      int separatorIndex = value.indexOf(':');
      if (separatorIndex != -1) {
        String ssid = value.substring(0, separatorIndex);
        String password = value.substring(separatorIndex + 1);

        Serial.println("Connecting to Wi-Fi - SSID: " + ssid);
        WiFi.begin(ssid.c_str(), password.c_str());

        int attempts = 0;
        while (WiFi.status() != WL_CONNECTED && attempts < 20) {
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
          pAdvertising->start();
        }
      }
    } else if (value == "BLUETOOTH") {
      isBluetoothMode = true;
      WiFi.disconnect();
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
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ
  );
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
  delay(10);
} 
