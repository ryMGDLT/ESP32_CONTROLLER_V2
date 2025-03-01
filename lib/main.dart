import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http_server/http_server.dart';

final logger = Logger();

void main() {
  runApp(const MyApp());
  requestBLEPermissions();
}

Future<void> requestBLEPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.bluetooth,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();
  logger.i('BLE Permissions: $statuses');
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Light Control',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: Colors.grey[100],
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontFamily: 'Poppins', fontSize: 16),
          bodyMedium: TextStyle(fontFamily: 'Poppins', fontSize: 14),
          headlineSmall: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.bold),
        ),
        useMaterial3: true,
      ),
      home: const LightControlPage(),
    );
  }
}

class LightControlPage extends StatefulWidget {
  const LightControlPage({super.key});

  @override
  _LightControlPageState createState() => _LightControlPageState();
}

class _LightControlPageState extends State<LightControlPage> {
  final ESP32Controller controller = ESP32Controller();
  String connectionType = 'bluetooth';
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  String? esp32IP;
  bool isConnected = false;
  bool isConnecting = false;
  bool isControlling = false;
  final Map<int, bool> ledStatus = {1: false, 2: false, 3: false, 4: false};
  HttpServer? _server;

  @override
  void initState() {
    super.initState();
    _loadLastConnectionData();
    controller.initBLE();
    _startHttpServer();
    _setupControlListener();
  }

  @override
  void dispose() {
    _saveWiFiCredentialsIfNeeded();
    _server?.close();
    controller.dispose();
    ssidController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadLastConnectionData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedType = prefs.getString('lastConnectionType');
      if (savedType != null) {
        setState(() {
          connectionType = savedType;
          if (connectionType == 'wifi') {
            ssidController.text = prefs.getString('lastSSID') ?? '';
            passwordController.text = prefs.getString('lastPassword') ?? '';
          }
        });
      }
    } catch (e) {
      logger.e('Error loading last connection data: $e');
    }
  }

  Future<void> _saveConnectionType(String type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastConnectionType', type);
    } catch (e) {
      logger.e('Error saving connection type: $e');
    }
  }

  Future<void> _saveWiFiCredentialsIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (connectionType == 'wifi') {
        await prefs.setString('lastSSID', ssidController.text);
        await prefs.setString('lastPassword', passwordController.text);
        logger.i('Saved Wi-Fi credentials: SSID=${ssidController.text}, Password=${passwordController.text}');
      }
    } catch (e) {
      logger.e('Error saving Wi-Fi credentials: $e');
    }
  }

  Future<void> _startHttpServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      logger.i("HTTP server started on ${_server!.address.address}:${_server!.port}");
      await for (var request in _server!) {
        if (request.method == 'POST' && request.uri.path == '/update') {
          String content = await utf8.decoder.bind(request).join();
          var data = jsonDecode(content);
          int lightNum = data['light'];
          bool state = data['state'] == "ON";
          if (lightNum >= 1 && lightNum <= 4) {
            setState(() {
              ledStatus[lightNum] = state;
            });
            logger.i("Received HTTP update: LED $lightNum to $state");
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..write('OK')
            ..close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found')
            ..close();
        }
      }
    } catch (e) {
      logger.e("Failed to start HTTP server: $e");
      await Future.delayed(const Duration(seconds: 5));
      _startHttpServer(); // Retry on failure
    }
  }

  void _setupControlListener() {
    controller.setupBLEListener().then((_) {
      if (controller.esp32Device != null) {
        controller.esp32Device!.discoverServices().then((services) {
          var controlChar = services
              .expand((s) => s.characteristics)
              .firstWhere((c) => c.uuid.toString() == controller.controlUUID);
          controlChar.setNotifyValue(true);
          controller.controlSubscription?.cancel();
          controller.controlSubscription = controlChar.value.listen((value) {
            String command = String.fromCharCodes(value);
            if (command.startsWith("LIGHT")) {
              int lightNum = int.parse(command.substring(5, 6));
              bool state = command.substring(7) == "ON";
              if (lightNum >= 1 && lightNum <= 4) {
                setState(() {
                  ledStatus[lightNum] = state;
                });
                logger.i("Updated LED $lightNum to $state from ESP32 (BLE)");
              }
            }
          });
        });
      }
    }).catchError((e) {
      logger.e("Error setting up control listener: $e");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ESP32 LED Control',
          style: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.w600,
            color: Colors.indigo,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.indigo.shade50, Colors.white],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildConnectionCard(),
              if (isConnected) ...[
                const SizedBox(height: 20),
                _buildLEDControlCard(),
                const SizedBox(height: 20),
                _buildChangeConnectionButton(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Connection Settings',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.indigo),
          ),
          const SizedBox(height: 20),
          const Text('Connection Type:', style: TextStyle(fontSize: 16)),
          Row(
            children: [
              _buildRadioOption('Bluetooth', 'bluetooth'),
              const SizedBox(width: 20),
              _buildRadioOption('Wi-Fi', 'wifi'),
            ],
          ),
          if (connectionType == 'wifi') ...[
            const SizedBox(height: 20),
            _buildTextField(ssidController, 'Wi-Fi SSID', Icons.wifi, enabled: !isConnected),
            const SizedBox(height: 16),
            _buildTextField(passwordController, 'Wi-Fi Password', Icons.lock, obscure: true, enabled: !isConnected),
            if (esp32IP != null) ...[
              const SizedBox(height: 16),
              Text(
                'ESP32 IP: $esp32IP',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.green),
              ),
            ],
          ],
          const SizedBox(height: 20),
          if (!isConnected) _buildConnectButton(),
        ],
      ),
    );
  }

  Widget _buildRadioOption(String label, String value) {
    return Row(
      children: [
        Radio<String>(
          value: value,
          groupValue: connectionType,
          onChanged: isConnected ? null : (newValue) => setState(() => connectionType = newValue!),
          activeColor: Colors.indigo,
        ),
        Text(label, style: const TextStyle(fontSize: 16)),
      ],
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, IconData icon,
      {bool obscure = false, bool enabled = true}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.indigo),
        filled: true,
        fillColor: enabled ? Colors.grey.shade100 : Colors.grey.shade300,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildConnectButton() {
    return ElevatedButton(
      onPressed: isConnecting
          ? null
          : () async {
              setState(() => isConnecting = true);
              try {
                if (connectionType == 'wifi') {
                  if (ssidController.text.isEmpty || passwordController.text.isEmpty) {
                    throw Exception("Please enter Wi-Fi SSID and password");
                  }
                  String localIP = await _getLocalIP();
                  await controller.configureWiFi(ssidController.text, passwordController.text, localIP);
                  esp32IP = controller.esp32IP;
                  if (esp32IP == "FAIL") {
                    throw Exception("ESP32 failed to connect to Wi-Fi");
                  }
                  if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(esp32IP!)) {
                    throw Exception("Invalid ESP32 IP received: $esp32IP");
                  }
                  logger.i("Using ESP32 IP: $esp32IP");
                } else {
                  await controller.configureBluetooth();
                }
                setState(() => isConnected = true);
                await _saveConnectionType(connectionType);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Connected successfully'),
                      backgroundColor: Colors.green,
                      duration: Duration(milliseconds: 500),
                    ),
                  );
                }
              } catch (e) {
                logger.e("Connection failed: $e");
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Connection failed: $e'),
                      backgroundColor: Colors.red,
                      duration: const Duration(milliseconds: 500),
                    ),
                  );
                }
              } finally {
                setState(() => isConnecting = false);
              }
            },
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      child: isConnecting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10.0),
              child: const Text(
                'Connect',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
    );
  }

  Future<String> _getLocalIP() async {
    try {
      List<NetworkInterface> interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
      throw Exception("No local IP found");
    } catch (e) {
      logger.e("Error getting local IP: $e");
      throw e;
    }
  }

  Widget _buildLEDControlCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LED Controls',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.indigo),
          ),
          const SizedBox(height: 20),
          ...List.generate(4, (index) => _buildLightControl(index + 1)),
        ],
      ),
    );
  }

  Widget _buildLightControl(int lightNum) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'LED $lightNum',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: ledStatus[lightNum]! ? Colors.indigo : Colors.grey.shade600,
            ),
          ),
          Switch(
            value: ledStatus[lightNum]!,
            onChanged: isControlling ? null : (value) => controlLight(lightNum, value),
            activeColor: Colors.indigo,
            activeTrackColor: Colors.indigo.shade100,
            inactiveThumbColor: Colors.grey,
            inactiveTrackColor: Colors.grey.shade300,
          ),
        ],
      ),
    );
  }

  Widget _buildChangeConnectionButton() {
    return ElevatedButton(
      onPressed: isConnected && !isConnecting
          ? () async {
              setState(() {
                isConnecting = true;
                isConnected = false;
                ledStatus.updateAll((key, value) => false);
                ssidController.clear();
                passwordController.clear();
              });
              try {
                await controller.switchConfig(connectionType);
                esp32IP = null;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Ready for new connection'),
                      backgroundColor: Colors.green,
                      duration: Duration(milliseconds: 500),
                    ),
                  );
                }
              } catch (e) {
                logger.e("Switch config failed: $e");
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Switch failed: $e'),
                      backgroundColor: Colors.red,
                      duration: const Duration(milliseconds: 500),
                    ),
                  );
                }
              } finally {
                setState(() => isConnecting = false);
              }
            }
          : null,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.redAccent,
        foregroundColor: Colors.white,
      ),
      child: const Text('Change Connection', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    );
  }

  Future<void> controlLight(int lightNum, bool on) async {
    if (!mounted || !isConnected) return;
    if (lightNum < 1 || lightNum > 4) return;
    setState(() => isControlling = true);
    try {
      if (connectionType == 'wifi') {
        if (esp32IP == null) throw Exception('ESP32 IP not found');
        await controller.controlWiFi(lightNum - 1, on);
      } else {
        await controller.controlBluetooth(lightNum - 1, on);
      }
      setState(() => ledStatus[lightNum] = on);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('LED $lightNum ${on ? 'ON' : 'OFF'}'),
            backgroundColor: on ? Colors.green : Colors.red,
            duration: const Duration(milliseconds: 500),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Control failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(milliseconds: 500),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isControlling = false);
    }
  }
}

class ESP32Controller {
  String? esp32IP;
  final String configUUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  final String controlUUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  BluetoothDevice? esp32Device;
  StreamSubscription<List<ScanResult>>? subscription;
  StreamSubscription<List<int>>? controlSubscription;

  Future<void> initBLE() async {
    try {
      final BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        throw Exception("Bluetooth is not enabled");
      }
      logger.i("Starting BLE scan...");
      await subscription?.cancel();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));

      subscription = FlutterBluePlus.scanResults.listen((List<ScanResult> results) async {
        logger.i("Scanning devices: ${results.map((r) => '${r.device.platformName} (${r.device.remoteId})').toList()}");
        for (final ScanResult result in results) {
          logger.i("Found device: ${result.device.platformName}, ID: ${result.device.remoteId}, RSSI: ${result.rssi}");
          if (result.device.platformName == "ESP32_Light_Control" || result.device.remoteId.toString().contains("A0:5A")) {
            esp32Device = result.device;
            await FlutterBluePlus.stopScan();
            await subscription?.cancel();
            subscription = null;
            logger.i("ESP32 device found: ${esp32Device!.platformName} (${esp32Device!.remoteId})");
            break;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 21));
      if (esp32Device == null) {
        logger.w("No ESP32 device found after scan");
      }
    } catch (e) {
      logger.e("BLE initialization failed: $e");
      throw e;
    }
  }

  Future<void> setupBLEListener() async {
    int retries = 3;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.i("Setting up BLE listener (Attempt $attempt)...");
        await esp32Device!.connect(timeout: const Duration(seconds: 20));
        List<BluetoothService> services = await esp32Device!.discoverServices();

        BluetoothCharacteristic? controlChar;
        for (var service in services) {
          for (var char in service.characteristics) {
            if (char.uuid.toString() == controlUUID) {
              controlChar = char;
              break;
            }
          }
          if (controlChar != null) break;
        }

        if (controlChar == null) throw Exception("Control characteristic not found");

        await controlChar.setNotifyValue(true);
        break;
      } catch (e) {
        logger.e("BLE listener setup failed on attempt $attempt: $e");
        if (attempt < retries - 1) {
          await Future.delayed(const Duration(seconds: 5));
          await esp32Device?.disconnect();
          continue;
        }
        throw e;
      }
    }
  }

  Future<void> configureWiFi(String ssid, String password, String appIP) async {
    int retries = 3;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.i("Connecting to ESP32 via BLE (Attempt $attempt)...");
        await esp32Device!.connect(timeout: const Duration(seconds: 20));
        List<BluetoothService> services = await esp32Device!.discoverServices();

        BluetoothCharacteristic? configChar;
        for (var service in services) {
          for (var char in service.characteristics) {
            if (char.uuid.toString() == configUUID) {
              configChar = char;
              break;
            }
          }
          if (configChar != null) break;
        }

        if (configChar == null) throw Exception("Config characteristic not found");

        await configChar.setNotifyValue(true);
        String configString = "WIFI:$ssid:$password|$appIP";
        logger.i("Sending Wi-Fi config with app IP: $configString");
        await configChar.write(configString.codeUnits, withoutResponse: false);

        logger.i("Wi-Fi credentials sent. Waiting for IP from ESP32...");
        await Future.delayed(const Duration(seconds: 35));

        List<int> ipBytes = await configChar.read();
        esp32IP = String.fromCharCodes(ipBytes);
        logger.i("Received ESP32 IP via BLE: $esp32IP");

        if (esp32IP == null || esp32IP!.isEmpty) {
          throw Exception("ESP32 IP not received or invalid");
        }
        if (esp32IP == "FAIL") {
          throw Exception("ESP32 failed to connect to Wi-Fi");
        }
        if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(esp32IP!)) {
          throw Exception("Invalid ESP32 IP received: $esp32IP");
        }
        break;
      } catch (e) {
        logger.e("WiFi configuration failed on attempt $attempt: $e");
        if (attempt < retries - 1) {
          await Future.delayed(const Duration(seconds: 5));
          await esp32Device?.disconnect();
          continue;
        }
        throw e;
      } finally {
      }
    }
  }

  Future<void> configureBluetooth() async {
    int retries = 3;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.i("Connecting to ESP32 via BLE for Bluetooth mode (Attempt $attempt)...");
        await esp32Device!.connect(timeout: const Duration(seconds: 20));
        List<BluetoothService> services = await esp32Device!.discoverServices();

        BluetoothCharacteristic? configChar;
        for (var service in services) {
          for (var char in service.characteristics) {
            if (char.uuid.toString() == configUUID) {
              configChar = char;
              break;
            }
          }
          if (configChar != null) break;
        }

        if (configChar == null) throw Exception("Config characteristic not found");

        await configChar.write("BLUETOOTH".codeUnits);
        logger.i("Bluetooth mode configured");
        break;
      } catch (e) {
        logger.e("Bluetooth configuration failed on attempt $attempt: $e");
        if (attempt < retries - 1) {
          await Future.delayed(const Duration(seconds: 5));
          await esp32Device?.disconnect();
          continue;
        }
        throw e;
      }
    }
  }

  Future<void> controlWiFi(int lightNum, bool on) async {
    if (esp32IP == null) throw Exception("ESP32 IP not found");
    if (lightNum < 0 || lightNum > 3) throw Exception("Invalid LED number: $lightNum");
    String path = on ? "on" : "off";
    logger.i("Sending HTTP request to: http://$esp32IP/light${lightNum + 1}/$path");
    final http.Response response = await http.get(Uri.parse("http://$esp32IP/light${lightNum + 1}/$path"));
    logger.i("HTTP response: ${response.statusCode} - ${response.body}");
    if (response.statusCode != 200) throw Exception("HTTP request failed: ${response.statusCode}");
  }

  Future<void> controlBluetooth(int lightNum, bool on) async {
    if (esp32Device == null) throw Exception("ESP32 not connected");
    if (lightNum < 0 || lightNum > 3) throw Exception("Invalid LED number: $lightNum");
    List<BluetoothService> services = await esp32Device!.discoverServices();

    BluetoothCharacteristic? controlChar;
    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.uuid.toString() == controlUUID) {
          controlChar = char;
          break;
        }
      }
      if (controlChar != null) break;
    }

    if (controlChar == null) throw Exception("Control characteristic not found");
    String command = "LIGHT${lightNum + 1}:${on ? 'ON' : 'OFF'}";
    await controlChar.write(command.codeUnits);
    logger.i("Sent Bluetooth command: $command");
  }

  Future<void> switchConfig(String currentMode) async {
    try {
      if (esp32IP != null) {
        logger.i("Sending new-config request to $esp32IP");
        try {
          await http.get(Uri.parse("http://$esp32IP/new-config")).timeout(const Duration(seconds: 15));
          await Future.delayed(const Duration(seconds: 2));
        } catch (e) {
          logger.w("HTTP request failed, forcing BLE reset: $e");
          await configureBluetooth();
        }
      } else {
        logger.i("No IP available, resetting to BLE mode");
        await configureBluetooth();
      }
    } catch (e) {
      logger.e("Switch config failed: $e");
      throw e;
    }
  }

  void dispose() {
    subscription?.cancel();
    controlSubscription?.cancel();
    esp32Device?.disconnect();
    subscription = null;
    esp32Device = null;
  }
}