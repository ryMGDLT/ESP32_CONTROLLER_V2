# ESP32 Control App

A Flutter-based mobile application designed to control an ESP32 microcontroller via Bluetooth and Wi-Fi. This app allows users to manage 4 LEDs connected to an ESP32 with additional voice command functionality.

## Features

- **Bluetooth Control**: Connect to the ESP32 via Bluetooth to control 4 LEDs.
- **Wi-Fi Control**: Use Wi-Fi to manage the ESP32 remotely.
- **Auto Wi-Fi Detection**: Automatically pulls the SSID of the Wi-Fi network the user is connected to and prompts for the password (due to Android security restrictions, the app cannot access the password directly).
- **Voice Commands**: Control the ESP32 LEDs using voice input.
- **Customizable**: Modify the Bluetooth UUID for a unique connection between the app and ESP32.

## Getting Started

This project is a starting point for a Flutter application integrated with ESP32 hardware.

### Prerequisites

- **Flutter SDK**: Installed and configured (see [Flutter Installation Guide](https://flutter.dev/docs/get-started/install)).
- **Arduino IDE**: For uploading code to the ESP32 (download from [Arduino.cc](https://www.arduino.cc/en/software)).
- **ESP32 Dev Module**: Hardware required for this project.
- **Android Device**: For running the Flutter app.

### Installation and Setup

#### 1. ESP32 Firmware
1. Download the `WIFI_LED_w_bt.ino` file from this repository.
2. Open it in the Arduino IDE.
3. Go to **Tools > Board** and select **ESP32 Dev Module**.
4. Navigate to **Tools > Partition Scheme** and choose **Huge App**.
5. Upload the code to your ESP32.

#### 2. Flutter App (in terminal)
1. Clone this repository:
   ```bash
   git clone https://github.com/RyanRY27/ESP32_Flutter_APP.git 
2. Navigate to the project directory: 
  cd esp32app 
3. Install dependencies: 
  flutter pub get 
4. Connect your Android device or use an emulator. 
5. Run the app:
  flutter run

### Prebuilt APK 
Download the latest release of the app from the [Releases](https://github.com/RyanRY27/ESP32_Flutter_APP/releases/tag/v1.0.0) page and install it on your Android device. 

### Customization
To customize the Bluetooth connection:

Open WIFI_LED_w_bt.ino in the Arduino IDE and update the UUID use an UUID generator. 
Edit the UUID in your ESP32 code.
Clone the repository and open android/lib/main.dart in your Flutter editor.
Edit the UUID in main.dart to match the one in the ESP32 code.
Rebuild the app with flutter run. 

### Usage
Launch the app on your Android device.
Choose Bluetooth or Wi-Fi to connect to the ESP32.
For Wi-Fi: The app will detect your current SSID and prompt for the password.
Use the interface or voice commands to control the 4 LEDs connected to the ESP32. 

Note: This project is developed to pass an activity in Embedded Systems.

