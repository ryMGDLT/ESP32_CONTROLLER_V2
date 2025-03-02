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
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_speech/flutter_speech.dart';

final logger = Logger(
  printer: PrettyPrinter(),
);

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
    Permission.microphone,
  ].request();
  logger.i('Permissions: $statuses');
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
  String? esp32IP;
  bool isConnected = false;
  bool isConnecting = false;
  bool isControlling = false;
  final Map<int, bool> ledStatus = {1: false, 2: false, 3: false, 4: false};
  HttpServer? _server;

  
  late SpeechRecognition _speech;
  bool _isListening = false;
  String _recognizedText = '';
  bool _speechRecognitionAvailable = false;

 
  final Map<String, int> _numberWords = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
  };

  @override
  void initState() {
    super.initState();
    _loadLastConnectionData();
    controller.initBLE();
    _startHttpServer();
    _setupControlListener();
    _initSpeech();
  }

  void _initSpeech() {
    _speech = SpeechRecognition();
    _speech.setAvailabilityHandler((bool result) {
      setState(() => _speechRecognitionAvailable = result);
      logger.i('Speech recognition available: $result');
    });
    _speech.setRecognitionStartedHandler(() {
      logger.i('Speech recognition started');
      setState(() => _isListening = true);
    });
    _speech.setRecognitionResultHandler((String text) {
      logger.i('Speech result received: "$text"');
      setState(() => _recognizedText = text);
    });
    _speech.setRecognitionCompleteHandler((String text) {
      logger.i('Speech recognition completed: "$text"');
      setState(() {
        _recognizedText = text;
        _isListening = false;
      });
      _processVoiceCommand(_recognizedText);
    });
    _speech.setErrorHandler(() {
      logger.e('Speech error occurred');
      setState(() => _isListening = false);
    });

    _speech.activate('en_US').then((result) {
      setState(() => _speechRecognitionAvailable = result);
      logger.i('Speech activated: $result');
    });
  }

  void _startListening() async {
    logger.i('Attempting to start listening...');
    var status = await Permission.microphone.status;
    logger.i('Microphone permission status: $status');
    if (status.isDenied || status.isPermanentlyDenied) {
      logger.i('Requesting microphone permission...');
      status = await Permission.microphone.request();
      logger.i('New permission status: $status');
      if (status.isDenied || status.isPermanentlyDenied) {
        logger.e('Microphone permission still denied, cannot proceed');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required for voice control'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (_speechRecognitionAvailable && !_isListening) {
      _speech.listen().then((result) {
        logger.i('Listening started: $result');
      });
    } else {
      logger.e('Speech recognition not available or already listening');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Speech recognition not available'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _stopListening() {
    if (_isListening) {
      logger.i('Stopping listening...');
      _speech.stop().then((result) {
        setState(() => _isListening = false);
        logger.i('Listening stopped: $result');
      });
    }
  }

  void _processVoiceCommand(String command) {
    logger.i('Processing command: "$command"');
    command = command.toLowerCase();

 
    if (command.contains('turn on all led') || command.contains('all led on')) {
      logger.i('Command matched: Turn on all LEDs');
      for (int i = 1; i <= 4; i++) {
        controlLight(i, true);
      }
    } else if (command.contains('turn off all led') || command.contains('all led off')) {
      logger.i('Command matched: Turn off all LEDs');
      for (int i = 1; i <= 4; i++) {
        controlLight(i, false);
      }
    } else {
   
      for (int i = 1; i <= 4; i++) {
        String digit = '$i';
        String word = _numberWords.keys.firstWhere((k) => _numberWords[k] == i);

     
        if (command.contains('turn on led $digit') ||
            command.contains('led $digit on') ||
            command.contains('turn on led $word') ||
            command.contains('led $word on')) {
          logger.i('Command matched: Turn on LED $i');
          controlLight(i, true);
        }
      
        else if (command.contains('turn off led $digit') ||
            command.contains('led $digit off') ||
            command.contains('turn off led $word') ||
            command.contains('led $word off')) {
          logger.i('Command matched: Turn off LED $i');
          controlLight(i, false);
        }
      }
    }
    setState(() => _recognizedText = '');
  }

  Future<void> _loadLastConnectionData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedType = prefs.getString('lastConnectionType');
      if (savedType != null) {
        setState(() {
          connectionType = savedType;
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
      _startHttpServer();
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
  void dispose() {
    _server?.close();
    controller.dispose();
    _speech.cancel();
    super.dispose();
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
                _buildVoiceControlCard(),
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
          if (connectionType == 'wifi' && esp32IP != null) ...[
            const SizedBox(height: 16),
            Text(
              'ESP32 IP: $esp32IP',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.green),
            ),
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

  Future<String?> _promptForPassword(BuildContext context, String ssid) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PasswordDialog(ssid: ssid),
    );
  }

  Widget _buildConnectButton() {
    return ElevatedButton(
      onPressed: isConnecting
          ? null
          : () async {
              setState(() => isConnecting = true);
              BuildContext? dialogContext;

              try {
                if (connectionType == 'wifi') {
                  final networkInfo = NetworkInfo();
                  String? ssid = await networkInfo.getWifiName();
                  if (ssid == null || ssid.isEmpty) {
                    throw Exception("Not connected to Wi-Fi or unable to retrieve SSID");
                  }
                  ssid = ssid.replaceAll('"', '');
                  logger.i("Retrieved SSID: $ssid");

                  String? password = await _promptForPassword(context, ssid);
                  if (password == null) {
                    throw Exception("Password entry cancelled by user");
                  }

                  String localIP = await _getLocalIP();

                  dialogContext = context;
                  showDialog(
                    context: dialogContext!,
                    barrierDismissible: false,
                    builder: (BuildContext ctx) {
                      return const AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(width: 20),
                            Text("Connecting to ESP32..."),
                          ],
                        ),
                      );
                    },
                  ).then((_) {
                    if (dialogContext != null && Navigator.canPop(dialogContext!)) {
                      Navigator.pop(dialogContext!);
                    }
                  });

                  logger.i("Starting Wi-Fi configuration...");
                  await controller.configureWiFi(ssid, password, localIP);
                  logger.i("Wi-Fi configuration completed.");
                  esp32IP = controller.esp32IP;

                  if (dialogContext != null && Navigator.canPop(dialogContext!)) {
                    Navigator.pop(dialogContext!);
                  }

                  if (esp32IP == "FAIL") {
                    throw Exception("ESP32 failed to connect to Wi-Fi");
                  }
                  if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(esp32IP!)) {
                    throw Exception("Invalid ESP32 IP received: $esp32IP");
                  }
                  logger.i("Using ESP32 IP: $esp32IP");
                } else {
                  logger.i("Starting Bluetooth configuration...");
                  await controller.configureBluetooth();
                  logger.i("Bluetooth configuration completed.");
                }

                if (mounted) {
                  setState(() => isConnected = true);
                  await _saveConnectionType(connectionType);
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
                  if (dialogContext != null && Navigator.canPop(dialogContext!)) {
                    Navigator.pop(dialogContext!);
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Connection failed: $e'),
                      backgroundColor: Colors.red,
                      duration: const Duration(milliseconds: 500),
                    ),
                  );
                }
              } finally {
                if (mounted) {
                  setState(() => isConnecting = false);
                }
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
          : const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10.0),
              child: Text(
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
      rethrow;
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

  Widget _buildVoiceControlCard() {
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
            'Voice Control',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.indigo),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isListening ? _stopListening : _startListening,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              backgroundColor: _isListening ? Colors.red : Colors.indigo,
              foregroundColor: Colors.white,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_isListening ? Icons.mic_off : Icons.mic),
                const SizedBox(width: 10),
                Text(
                  _isListening ? 'Stop Listening' : 'Start Voice Control',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Say: "Turn on LED 1", "Turn off LED two", "Turn on all LEDs", or "Turn off all LEDs"',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 10),
          Text(
            'Recognized: $_recognizedText',
            style: const TextStyle(fontSize: 16, color: Colors.black87),
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
                if (mounted) setState(() => isConnecting = false);
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

class _PasswordDialog extends StatefulWidget {
  final String ssid;

  const _PasswordDialog({required this.ssid});

  @override
  _PasswordDialogState createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Enter Wi-Fi Password for "${widget.ssid}"'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Password',
          prefixIcon: Icon(Icons.lock),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (_controller.text.isNotEmpty) {
              Navigator.of(context).pop(_controller.text);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please enter a password'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
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
      rethrow;
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
        rethrow;
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
        const maxWaitSeconds = 20;
        const pollInterval = Duration(seconds: 1);
        int elapsedSeconds = 0;

        while (elapsedSeconds < maxWaitSeconds) {
          BluetoothConnectionState connectionState = await esp32Device!.connectionState.first;
          if (connectionState != BluetoothConnectionState.connected) {
            throw Exception("ESP32 disconnected before IP could be read");
          }

          try {
            List<int> ipBytes = await configChar.read().timeout(const Duration(seconds: 1));
            if (ipBytes.isNotEmpty) {
              logger.i("Raw IP bytes received: $ipBytes");
              esp32IP = String.fromCharCodes(ipBytes);
              logger.i("Received ESP32 IP via BLE: $esp32IP");
              break;
            }
          } catch (e) {
            logger.i("No IP yet, waiting... ($elapsedSeconds/$maxWaitSeconds seconds)");
          }

          await Future.delayed(pollInterval);
          elapsedSeconds += pollInterval.inSeconds;
        }

        if (elapsedSeconds >= maxWaitSeconds) {
          throw Exception("Timeout waiting for ESP32 IP response");
        }

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
        rethrow;
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
        rethrow;
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
      rethrow;
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