import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart' as shelfRouter;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_speech/flutter_speech.dart';
import 'package:syncfusion_flutter_datepicker/datepicker.dart';

final Logger logger = Logger('ESP32App');

void startHttpServer() async {
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 1024);
    print("INFO: ${DateTime.now()}: HTTP server started on 0.0.0.0:1024");
    await for (var request in server) {
      if (request.method == 'POST' && request.uri.path == '/schedule-update') {
        final body = await request.cast<List<int>>().transform(utf8.decoder).join();
        print("INFO: ${DateTime.now()}: Received schedule update: $body");
        request.response
          ..statusCode = HttpStatus.ok
          ..write("OK")
          ..close();
      } else if (request.method == 'POST' && request.uri.path == '/update') {
        final body = await request.cast<List<int>>().transform(utf8.decoder).join();
        print("INFO: ${DateTime.now()}: Received light update: $body");
        request.response
          ..statusCode = HttpStatus.ok
          ..write("OK")
          ..close();
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write("Not Found")
          ..close();
      }
    }
  } catch (e) {
    print("SEVERE: ${DateTime.now()}: Failed to start HTTP server: $e");
  }
}
void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });
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
  logger.info('Permissions: $statuses');
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Light Control',
      debugShowCheckedModeBanner: false,
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
  final Map<int, Map<String, int>> schedules = {
    1: {"hourOn": 0, "minuteOn": 0, "hourOff": 0, "minuteOff": 0, "scheduled": 0},
    2: {"hourOn": 0, "minuteOn": 0, "hourOff": 0, "minuteOff": 0, "scheduled": 0},
    3: {"hourOn": 0, "minuteOn": 0, "hourOff": 0, "minuteOff": 0, "scheduled": 0},
    4: {"hourOn": 0, "minuteOn": 0, "hourOff": 0, "minuteOff": 0, "scheduled": 0},
  };

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
    _setupScheduleListener();
    _initSpeech();
  }

  void _initSpeech() {
    _speech = SpeechRecognition();
    _speech.setAvailabilityHandler((bool result) {
      setState(() => _speechRecognitionAvailable = result);
      logger.info('Speech recognition available: $result');
    });
    _speech.setRecognitionStartedHandler(() {
      logger.info('Speech recognition started');
      setState(() => _isListening = true);
    });
    _speech.setRecognitionResultHandler((String text) {
      logger.info('Speech result received: "$text"');
      setState(() => _recognizedText = text);
    });
    _speech.setRecognitionCompleteHandler((String text) {
      logger.info('Speech recognition completed: "$text"');
      setState(() {
        _recognizedText = text;
        _isListening = false;
      });
      _processVoiceCommand(_recognizedText);
    });
    _speech.setErrorHandler(() {
      logger.severe('Speech error occurred');
      setState(() => _isListening = false);
    });

    _speech.activate('en_US').then((result) {
      setState(() => _speechRecognitionAvailable = result);
      logger.info('Speech activated: $result');
    });
  }

  void _startListening() async {
    logger.info('Attempting to start listening...');
    var status = await Permission.microphone.status;
    logger.info('Microphone permission status: $status');
    if (status.isDenied || status.isPermanentlyDenied) {
      logger.info('Requesting microphone permission...');
      status = await Permission.microphone.request();
      logger.info('New permission status: $status');
      if (status.isDenied || status.isPermanentlyDenied) {
        logger.severe('Microphone permission still denied, cannot proceed');
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
        logger.info('Listening started: $result');
      });
    } else {
      logger.severe('Speech recognition not available or already listening');
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
      logger.info('Stopping listening...');
      _speech.stop().then((result) {
        setState(() => _isListening = false);
        logger.info('Listening stopped: $result');
      });
    }
  }

  void _processVoiceCommand(String command) {
    logger.info('Processing command: "$command"');
    command = command.toLowerCase().trim();

    if (command.contains('turn on all led') || command.contains('all led on')) {
      logger.info('Command matched: Turn on all LEDs');
      for (int i = 1; i <= 4; i++) {
        controlLight(i, true);
      }
    } else if (command.contains('turn off all led') || command.contains('all led off')) {
      logger.info('Command matched: Turn off all LEDs');
      for (int i = 1; i <= 4; i++) {
        controlLight(i, false);
      }
    } else {
      List<String> words = command.split(RegExp(r'\s+'));
      bool isTurnOn = command.contains('turn on') || command.contains('on');
      bool isTurnOff = command.contains('turn off') || command.contains('off');
      
      if (!isTurnOn && !isTurnOff) {
        logger.info('No valid turn on/off command detected');
        return;
      }
      Set<int> ledsToControl = {};

      for (int i = 0; i < words.length; i++) {
        String word = words[i];
        if (RegExp(r'^[1-4]$').hasMatch(word)) {
          ledsToControl.add(int.parse(word));
        } else if (_numberWords.containsKey(word)) {
          ledsToControl.add(_numberWords[word]!);
        } else if (word == 'led' && i + 1 < words.length) {
          String nextWord = words[i + 1];
          if (RegExp(r'^[1-4]$').hasMatch(nextWord)) {
            ledsToControl.add(int.parse(nextWord));
          } else if (_numberWords.containsKey(nextWord)) {
            ledsToControl.add(_numberWords[nextWord]!);
          }
        }
      }

      if (ledsToControl.isNotEmpty) {
        for (int led in ledsToControl) {
          logger.info('Command matched: ${isTurnOn ? "Turn on" : "Turn off"} LED $led');
          controlLight(led, isTurnOn);
        }
      } else {
        logger.info('No valid LED numbers detected in command');
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
      logger.severe('Error loading last connection data: $e');
    }
  }

  Future<void> _saveConnectionType(String type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastConnectionType', type);
    } catch (e) {
      logger.severe('Error saving connection type: $e');
    }
  }

  Future<void> _startHttpServer() async {
    try {
      final router = shelfRouter.Router();
      router.post('/update', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        int lightNum = data['light'];
        bool state = data['state'] == "ON";
        if (lightNum >= 1 && lightNum <= 4) {
          setState(() {
            ledStatus[lightNum] = state;
          });
          logger.info("Received HTTP update from ESP32: LED $lightNum to ${state ? 'ON' : 'OFF'}");
        }
        return Response.ok('OK');
      });

      router.post('/schedule-update', (Request request) async {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        int lightNum = data['light'];
        setState(() {
          schedules[lightNum] = {
            "hourOn": data['hourOn'],
            "minuteOn": data['minuteOn'],
            "hourOff": data['hourOff'],
            "minuteOff": data['minuteOff'],
            "scheduled": 1,
          };
        });
        logger.info("Received schedule update: LED $lightNum");
        return Response.ok('OK');
      });

      final server = await io.serve(router, InternetAddress.anyIPv4, 1024);
      logger.info("HTTP server started on ${server.address.host}:${server.port}");
    } catch (e) {
      logger.severe("Failed to start HTTP server: $e");
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
                logger.info("Updated LED $lightNum to $state from ESP32 (BLE)");
              }
            }
          });
        });
      }
    }).catchError((e) {
      logger.severe("Error setting up control listener: $e");
    });
  }

  void _setupScheduleListener() {
    controller.setupBLEListener().then((_) {
      if (controller.esp32Device != null) {
        controller.esp32Device!.discoverServices().then((services) {
          var scheduleChar = services
              .expand((s) => s.characteristics)
              .firstWhere((c) => c.uuid.toString() == controller.scheduleUUID);
          scheduleChar.setNotifyValue(true);
          controller.scheduleSubscription?.cancel();
          controller.scheduleSubscription = scheduleChar.value.listen((value) {
            String command = String.fromCharCodes(value);
            if (command.startsWith("SCHEDULE")) {
              int lightNum = int.parse(command.substring(8, 9));
              var parts = command.substring(10).split('-');
              var onTime = parts[0].split(':');
              var offTime = parts[1].split(':');
              setState(() {
                schedules[lightNum] = {
                  "hourOn": int.parse(onTime[0]),
                  "minuteOn": int.parse(onTime[1]),
                  "hourOff": int.parse(offTime[0]),
                  "minuteOff": int.parse(offTime[1]),
                  "scheduled": 1,
                };
              });
            }
          });
        });
      }
    });
  }

  @override
  void dispose() {
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
                if (connectionType == 'wifi') _buildScheduleCard(),
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
                  logger.info("Retrieved SSID: $ssid");

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

                  logger.info("Starting Wi-Fi configuration...");
                  await controller.configureWiFi(ssid, password, localIP);
                  logger.info("Wi-Fi configuration completed.");
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
                  logger.info("Using ESP32 IP: $esp32IP");
                } else {
                  logger.info("Starting Bluetooth configuration...");
                  await controller.configureBluetooth();
                  logger.info("Bluetooth configuration completed.");
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
                logger.severe("Connection failed: $e");
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
      logger.severe("Error getting local IP: $e");
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
        Row(  
          children: [
            Text(
              'LED $lightNum ',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: ledStatus[lightNum]! ? Colors.indigo : Colors.grey.shade600,
              ),
            ),
            Text(
              ledStatus[lightNum]! ? 'ON' : 'OFF',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: ledStatus[lightNum]! ? Colors.green : Colors.red,
              ),
            ),
          ],
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

  Widget _buildScheduleCard() {
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
            'Schedule LEDs',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.indigo),
          ),
          const SizedBox(height: 20),
          ...List.generate(4, (index) => _buildScheduleControl(index + 1)),
        ],
      ),
    );
  }

Widget _buildScheduleControl(int lightNum) {
  bool isScheduled = schedules[lightNum]!["scheduled"] == 1;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'LED $lightNum Schedule',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            ElevatedButton(
              onPressed: connectionType == 'wifi' && isConnected
                  ? () => _showScheduleDialog(lightNum)
                  : null,
              child: Text(isScheduled ? 'Edit Schedule' : 'Set Schedule'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
        if (isScheduled)
          Text(
            'ON: ${_formatTime(schedules[lightNum]!["hourOn"]!, schedules[lightNum]!["minuteOn"]!)} - '
            'OFF: ${_formatTime(schedules[lightNum]!["hourOff"]!, schedules[lightNum]!["minuteOff"]!)}',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
      ],
    ),
  );
}


String _formatTime(int hour, int minute) {
  String period = hour >= 12 ? 'PM' : 'AM';
  int displayHour = hour % 12 == 0 ? 12 : hour % 12;
  return '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
}

void _showScheduleDialog(int lightNum) {
  DateTime? onDateTime = schedules[lightNum]!["scheduled"] == 1
      ? DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
          schedules[lightNum]!["hourOn"]!,
          schedules[lightNum]!["minuteOn"]!,
        )
      : null;
  DateTime? offDateTime = schedules[lightNum]!["scheduled"] == 1
      ? DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
          schedules[lightNum]!["hourOff"]!,
          schedules[lightNum]!["minuteOff"]!,
        )
      : null;
  bool isSettingOnTime = true;

  void showTimePickerDialog(BuildContext context, Function(DateTime) onTimeSet) {
    showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
          child: child!,
        );
      },
    ).then((pickedTime) {
      if (pickedTime != null) {
        DateTime now = DateTime.now();
        int hour24 = pickedTime.hourOfPeriod +
            (pickedTime.period == DayPeriod.pm && pickedTime.hour != 12 ? 12 : 0) -
            (pickedTime.period == DayPeriod.am && pickedTime.hour == 12 ? 12 : 0);
        onTimeSet(DateTime(now.year, now.month, now.day, hour24, pickedTime.minute));
      }
    });
  }

  showDialog(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(isSettingOnTime ? 'ON Schedule' : 'OFF Schedule'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SfDateRangePicker(
                    selectionMode: DateRangePickerSelectionMode.single,
                    initialSelectedDate: isSettingOnTime
                        ? (onDateTime ?? DateTime.now())
                        : (offDateTime ?? DateTime.now()),
                    minDate: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day), 
                    maxDate: DateTime.now().add(const Duration(days: 365)),
                    onSelectionChanged: (DateRangePickerSelectionChangedArgs args) {
                      final DateTime? pickedDate = args.value as DateTime?;
                      if (pickedDate != null) {
                        showTimePickerDialog(context, (selectedTime) {
                          setDialogState(() {
                            if (isSettingOnTime) {
                              onDateTime = selectedTime;
                            } else {
                              offDateTime = selectedTime;
                            }
                          });
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (isSettingOnTime && onDateTime != null) {
                    setDialogState(() => isSettingOnTime = false);
                  } else if (!isSettingOnTime && offDateTime != null) {
                    try {
                      controller.setScheduleWiFi(
                        lightNum - 1,
                        onDateTime!.hour,
                        onDateTime!.minute,
                        offDateTime!.hour,
                        offDateTime!.minute,
                      );
                      setState(() {
                        schedules[lightNum] = {
                          "hourOn": onDateTime!.hour,
                          "minuteOn": onDateTime!.minute,
                          "hourOff": offDateTime!.hour,
                          "minuteOff": offDateTime!.minute,
                          "scheduled": 1,
                        };
                      });
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Schedule set for LED $lightNum'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to set schedule: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please select a time'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },
                child: Text(isSettingOnTime ? 'Next' : 'Save'),
              ),
            ],
          );
        },
      );
    },
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
                logger.severe("Switch config failed: $e");
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
  final String scheduleUUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
  BluetoothDevice? esp32Device;
  StreamSubscription<List<ScanResult>>? subscription;
  StreamSubscription<List<int>>? controlSubscription;
  StreamSubscription<List<int>>? scheduleSubscription;
  final http.Client _httpClient = http.Client();

  Future<void> initBLE() async {
    try {
      final BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        throw Exception("Bluetooth is not enabled");
      }
      logger.info("Starting BLE scan...");
      await subscription?.cancel();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));

      subscription = FlutterBluePlus.scanResults.listen((List<ScanResult> results) async {
        for (final ScanResult result in results) {
          logger.info("Found device: ${result.device.platformName}, ID: ${result.device.remoteId}, RSSI: ${result.rssi}");
          if (result.device.platformName == "ESP32_Light_Control" || result.device.remoteId.toString().contains("A0:5A")) {
            esp32Device = result.device;
            await FlutterBluePlus.stopScan();
            await subscription?.cancel();
            subscription = null;
            logger.info("ESP32 device found: ${esp32Device!.platformName} (${esp32Device!.remoteId})");
            break;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 21));
      if (esp32Device == null) {
        logger.warning("No ESP32 device found after scan");
      }
    } catch (e) {
      logger.severe("BLE initialization failed: $e");
      rethrow;
    }
  }

  Future<void> setupBLEListener() async {
    int retries = 3;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.info("Setting up BLE listener (Attempt $attempt)...");
        await esp32Device!.connect(timeout: const Duration(seconds: 20));
        List<BluetoothService> services = await esp32Device!.discoverServices();

        BluetoothCharacteristic? controlChar;
        BluetoothCharacteristic? scheduleChar;
        for (var service in services) {
          for (var char in service.characteristics) {
            if (char.uuid.toString() == controlUUID) {
              controlChar = char;
            } else if (char.uuid.toString() == scheduleUUID) {
              scheduleChar = char;
            }
            if (controlChar != null && scheduleChar != null) break;
          }
          if (controlChar != null && scheduleChar != null) break;
        }

        if (controlChar == null) throw Exception("Control characteristic not found");
        if (scheduleChar == null) throw Exception("Schedule characteristic not found");

        await controlChar.setNotifyValue(true);
        controlSubscription?.cancel();
        controlSubscription = controlChar.value.listen((value) {
          String command = String.fromCharCodes(value);
          if (command.startsWith("LIGHT")) {
            int lightNum = int.parse(command.substring(5, 6));
            bool state = command.substring(7) == "ON";
            if (lightNum >= 1 && lightNum <= 4) {
              logger.info("Updated LED $lightNum to $state from ESP32 (BLE)");
            }
          }
        });

        await scheduleChar.setNotifyValue(true);
        scheduleSubscription?.cancel();
        scheduleSubscription = scheduleChar.value.listen((value) {
          String command = String.fromCharCodes(value);
          if (command.startsWith("SCHEDULE")) {
            int lightNum = int.parse(command.substring(8, 9));
            var parts = command.substring(10).split('-');
            var onTime = parts[0].split(':');
            var offTime = parts[1].split(':');
            logger.info("Received schedule update: LED $lightNum - ${onTime[0]}:${onTime[1]} to ${offTime[0]}:${offTime[1]}");
          }
        });
        break;
      } catch (e) {
        logger.severe("BLE listener setup failed on attempt $attempt: $e");
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
    const int maxRetries = 3;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.info("Connecting to ESP32 via BLE (Attempt $attempt)...");
        await esp32Device!.connect(timeout: const Duration(seconds: 15));
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
        Completer<String> ipCompleter = Completer();
        configChar.value.listen((value) {
          if (value.isNotEmpty && !ipCompleter.isCompleted) {
            String received = String.fromCharCodes(value);
            logger.info("Received via BLE: $received");
            if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(received)) {
              ipCompleter.complete(received);
            }
          }
        });

        String configString = "WIFI:$ssid:$password|$appIP:1024";
        logger.info("Sending Wi-Fi config: $configString");
        await configChar.write(configString.codeUnits, withoutResponse: false);
        await Future.delayed(const Duration(milliseconds: 500));

        esp32IP = await ipCompleter.future.timeout(const Duration(seconds: 15), onTimeout: () {
          throw Exception("Timeout waiting for valid ESP32 IP");
        });

        if (esp32IP == "FAIL") throw Exception("ESP32 failed to connect to Wi-Fi");
        logger.info("Wi-Fi configuration successful. ESP32 IP: $esp32IP");
        break;
      } catch (e) {
        logger.severe("WiFi configuration failed on attempt $attempt: $e");
        if (attempt < maxRetries - 1) {
          await Future.delayed(const Duration(seconds: 2));
          await esp32Device?.disconnect();
          if (Platform.isAndroid) {
            await FlutterBluePlus.stopScan();
            await Future.delayed(const Duration(milliseconds: 1000));
          }
          continue;
        }
        rethrow;
      } finally {
        await Future.delayed(const Duration(milliseconds: 500));
        await esp32Device?.disconnect();
      }
    }
  }

  Future<void> configureBluetooth() async {
    int retries = 3;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        if (esp32Device == null) await initBLE();
        if (esp32Device == null) throw Exception("No ESP32 device found");

        logger.info("Connecting to ESP32 via BLE for Bluetooth mode (Attempt $attempt)...");
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
        logger.info("Bluetooth mode configured");
        break;
      } catch (e) {
        logger.severe("Bluetooth configuration failed on attempt $attempt: $e");
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
    String url = "http://$esp32IP:1024/light${lightNum + 1}/$path";

    try {
      final stopwatch = Stopwatch()..start();
      final response = await _httpClient.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode != 200) {
        throw Exception("HTTP request failed: ${response.statusCode} - ${response.body}");
      }
      logger.info("LED ${lightNum + 1} ${on ? 'ON' : 'OFF'} via HTTP in ${stopwatch.elapsedMilliseconds}ms");
    } catch (e) {
      logger.severe("HTTP control failed: $e");
      await controlBluetooth(lightNum, on); 
    }
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
    final stopwatch = Stopwatch()..start();
    await controlChar.write(command.codeUnits);
    stopwatch.stop();
    logger.info("LED ${lightNum + 1} ${on ? 'ON' : 'OFF'} via BLE in ${stopwatch.elapsedMilliseconds}ms");
  }

  Future<void> setScheduleWiFi(int lightNum, int hourOn, int minOn, int hourOff, int minOff) async {
    if (esp32IP == null) throw Exception("ESP32 IP not found");
    String url = "http://$esp32IP:1024/schedule";
    try {
      final response = await _httpClient.post(
        Uri.parse(url),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "light": lightNum + 1,
          "hourOn": hourOn,
          "minuteOn": minOn,
          "hourOff": hourOff,
          "minuteOff": minOff,
        }),
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) throw Exception("HTTP schedule failed: ${response.statusCode}");
      logger.info("Schedule set via HTTP for LED ${lightNum + 1}");
    } catch (e) {
      logger.severe("HTTP schedule failed: $e");
      await setScheduleBluetooth(lightNum, hourOn, minOn, hourOff, minOff);
    }
  }

  Future<void> setScheduleBluetooth(int lightNum, int hourOn, int minOn, int hourOff, int minOff) async {
    if (esp32Device == null) throw Exception("ESP32 not connected");
    var services = await esp32Device!.discoverServices();
    var scheduleChar = services
        .expand((s) => s.characteristics)
        .firstWhere((c) => c.uuid.toString() == scheduleUUID, orElse: () => throw Exception("Schedule characteristic not found"));
    
    String command = "SCHEDULE${lightNum + 1}:${hourOn}:${minOn}-${hourOff}:${minOff}";
    await scheduleChar.write(command.codeUnits);
    logger.info("Schedule set via BLE: $command");
  }

  Future<void> switchConfig(String currentMode) async {
    try {
      if (esp32IP != null) {
        logger.info("Sending new-config request to $esp32IP");
        try {
          await _httpClient.get(Uri.parse("http://$esp32IP:1024/new-config")).timeout(const Duration(seconds: 15));
          await Future.delayed(const Duration(seconds: 2));
        } catch (e) {
          logger.warning("HTTP request failed, forcing BLE reset: $e");
          await configureBluetooth();
        }
      } else {
        logger.info("No IP available, resetting to BLE mode");
        await configureBluetooth();
      }
      esp32IP = null;
    } catch (e) {
      logger.severe("Switch config failed: $e");
      rethrow;
    }
  }

  void dispose() {
    subscription?.cancel();
    controlSubscription?.cancel();
    scheduleSubscription?.cancel();
    esp32Device?.disconnect();
    _httpClient.close();
    subscription = null;
    esp32Device = null;
  }
}