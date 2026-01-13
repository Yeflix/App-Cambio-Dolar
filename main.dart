import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:html/parser.dart' as parser;
import 'dart:io';
import 'package:clipboard/clipboard.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';  // Para WidgetsBindingObserver



// ========== VARIABLES GLOBALES ==========
final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();
const String backgroundTaskName = "com.tuapp.actualizar_tasas_task";

// ========== CALLBACK DISPATCHER ==========

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    
    debugPrint("🔵 Ejecutando tarea en background: $task");
    
    if (task == backgroundTaskName) {
      try {
        // Verificar si el servicio está habilitado
        final prefs = await SharedPreferences.getInstance();
        final isEnabled = prefs.getBool('background_service_enabled') ?? true;
        
        if (!isEnabled) {
          debugPrint("🛑 Servicio de background deshabilitado - saltando ejecución");
          return Future.value(false);
        }
        
        // Obtener intervalo configurado
        final interval = prefs.getInt('notification_interval') ?? 60;
        
        if (interval == 0) {
          debugPrint("🛑 Intervalo configurado como 0 - saltando ejecución");
          return Future.value(false);
        }
        
        // Obtener tipo de notificación (0 = siempre, 1 = solo cambios)
        final notificationType = prefs.getInt('notification_type') ?? 0;
        
        // Inicializar notificaciones en background también
        const AndroidInitializationSettings androidInitSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        const InitializationSettings initSettings =
            InitializationSettings(android: androidInitSettings);
        await notificationsPlugin.initialize(initSettings);
        
        // Obtener precios
        final dolar = await BcvService.getDolarPrice();
        final euro = await BcvService.getEuroPrice();
        final usdt = await BinanceService.getUsdtPrice();
        
        if (dolar != null && euro != null) {
          // Obtener los precios anteriores del caché
          final previousCache = await LocalStorage.getPriceCache();
          double? previousDolar;
          double? previousEuro;
          
          if (previousCache != null) {
            previousDolar = previousCache['dolar'];
            previousEuro = previousCache['euro'];
          }
          
          // Guardar en cache (siempre guardamos los nuevos precios)
          await LocalStorage.savePriceCache(dolar, euro, usdt);
          
          // Guardar en historial
          final history = ExchangeHistory(
            date: DateTime.now(),
            dolarPrice: dolar,
            euroPrice: euro,
            usdtPrice: usdt,
          );
          await LocalStorage.saveToHistory(history);
          
          // Determinar si debemos mostrar la notificación
          bool shouldNotify = false;
          String notificationTitle = '';
          String notificationBody = '';
          
          if (notificationType == 0) {
            // Opción 1: Siempre notificar precio del día
            shouldNotify = true;
            notificationTitle = '📊 Precio del Día';
            notificationBody = 'Dólar: ${dolar.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
                'Euro: ${euro.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n';
          } else if (notificationType == 1) {
            // Opción 2: Solo notificar si hay cambio
            if (previousDolar == null || previousEuro == null) {
              // Primera vez o no hay datos anteriores, notificar
              shouldNotify = true;
              notificationTitle = '📊 Nuevos Precios Disponibles';
              notificationBody = 'Dólar: ${dolar.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
                  'Euro: ${euro.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
                  '🆕 Primera actualización del día';
            } else {
              // Comparar con los precios anteriores
              final dolarChanged = (dolar - previousDolar).abs() > 0.01;
              final euroChanged = (euro - previousEuro).abs() > 0.01;
              
              if (dolarChanged || euroChanged) {
                shouldNotify = true;
                notificationTitle = '⚠️ Cambio en los Precios';
                
                String changes = '';
                if (dolarChanged) {
                  final change = dolar - previousDolar;
                  changes += 'Dólar: ${change > 0 ? '📈' : '📉'} ${change.abs().toStringAsFixed(2).replaceAll('.', ',')} Bs.\n';
                }
                if (euroChanged) {
                  final change = euro - previousEuro;
                  changes += 'Euro: ${change > 0 ? '📈' : '📉'} ${change.abs().toStringAsFixed(2).replaceAll('.', ',')} Bs.\n';
                }
                
                notificationBody = 'Nuevo precio:\n'
                    'Dólar: ${dolar.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
                    'Euro: ${euro.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n\n'
                    'Cambios:\n$changes'
                    '🕒 Actualización automática';
              } else {
                debugPrint("🟡 Precios sin cambios - No se envía notificación");
              }
            }
          }
          
          // Mostrar notificación si corresponde
          if (shouldNotify) {
            await _showBackgroundNotification(
              notificationTitle,
              notificationBody,
              dolar,
              euro,
              usdt
            );
          }
          
          debugPrint("✅ Tarea de background completada exitosamente - Tipo: $notificationType, Intervalo: $interval minutos");
          return Future.value(true);
        }
      } catch (e) {
        debugPrint("❌ Error en tarea de background: $e");
      }
    }
    return Future.value(false);
  });
}

// ========== FUNCIONES DE INICIALIZACIÓN ==========
Future<void> _createNotificationChannel() async {
  if (Platform.isAndroid) {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'dolar_background_channel',
      'Actualizaciones en Background',
      description: 'Notificaciones automáticas de tasas',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification_dolar'),
    );

    await notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }
}

Future<void> askNotificationPermissionOnce() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final asked = prefs.getBool('asked_notifications') ?? false;

    if (!asked) {
      if (Platform.isAndroid) {
        // Para Android 13+
        if (await Permission.notification.isDenied) {
          final status = await Permission.notification.request();
          
          if (status.isGranted) {
            debugPrint("✅ Permiso de notificaciones concedido");
          } else {
            debugPrint("❌ Permiso de notificaciones denegado");
          }
        }
        
        // Para Android 12+, pedir permiso de exact alarms
        if (await Permission.scheduleExactAlarm.isDenied) {
          await Permission.scheduleExactAlarm.request();
        }
      }
      
      await prefs.setBool('asked_notifications', true);
    }
  } catch (e) {
    debugPrint("Error pidiendo permisos: $e");
  }
}

Future<void> _registerBackgroundTask() async {
  try {
    // Verificar si el servicio está habilitado
    final isEnabled = await LocalStorage.getBackgroundServiceEnabled();
    if (!isEnabled) {
      debugPrint("🛑 Servicio de background deshabilitado por el usuario");
      await Workmanager().cancelAll();
      return;
    }

    // Obtener intervalo configurado
    final intervalMinutes = await LocalStorage.getNotificationInterval();
    
    // Configurar constraints para Android
    final constraints = Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    );
    
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        "backgroundTask_${DateTime.now().millisecondsSinceEpoch}",
        backgroundTaskName,
        frequency: Duration(minutes: intervalMinutes),
        initialDelay: Duration(minutes: 5), // Empezar después de 5 minutos
        constraints: constraints,
        inputData: {
          'type': 'background_update',
          'interval': intervalMinutes,
        },
      );
      debugPrint("✅ Tarea periódica registrada para Android - Intervalo: $intervalMinutes minutos");
    } else if (Platform.isIOS) {
      await Workmanager().registerPeriodicTask(
        "backgroundTask",
        backgroundTaskName,
        frequency: Duration(minutes: intervalMinutes),
        initialDelay: const Duration(seconds: 10),
        constraints: constraints,
      );
      debugPrint("✅ Tarea periódica registrada para iOS - Intervalo: $intervalMinutes minutos");
    }
  } catch (e) {
    debugPrint("❌ Error registrando tarea de background: $e");
  }
}

// MethodChannel para comunicarse con Android
final MethodChannel _widgetChannel = MethodChannel('com.example.dolargo/widget');

Future<void> savePricesForWidget(double dolar, double euro) async {
  try {
    if (Platform.isAndroid) {
      print('🚀 Actualizando widget Android...');
      
      // Enviar datos al widget
      final result = await _widgetChannel.invokeMethod('saveAndUpdateWidget', {
        'dolar': dolar,
        'euro': euro,
        'timestamp': '${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
      });
      
      if (result == true) {
        print('✅ Widget actualizado: Dólar: $dolar, Euro: $euro');
      }
    }
  } catch (e) {
    print('⚠️ Error actualizando widget: $e');
    // No bloquear el flujo si falla el widget
  }
}
// Agrega esto después de la definición de _widgetChannel
Future<void> refreshWidgetPrices() async {
  try {
    if (Platform.isAndroid) {
      print('🔄 Solicitando refresco de precios desde widget...');
      
      final result = await _widgetChannel.invokeMethod('refreshPricesForWidget');
      
      if (result == true) {
        print('✅ Precios refrescados desde widget');
      }
    }
  } catch (e) {
    print('⚠️ Error refrescando precios desde widget: $e');
  }
}

// ========== FUNCIÓN MAIN CORREGIDA ==========
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    // 1. Inicializar Workmanager
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    
    // 2. Configurar notificaciones
    const AndroidInitializationSettings androidInitSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidInitSettings);
    await notificationsPlugin.initialize(initSettings);
    
    // 3. Crear canal de notificación
    await _createNotificationChannel();
    
    // 4. Pedir permisos
    await askNotificationPermissionOnce();

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt('notification_type') == null) {
      await prefs.setInt('notification_type', 0); // Por defecto: siempre notificar
    }
    
    // 5. Registrar tarea inicial
    await _registerBackgroundTask();
    
    // 6. Iniciar la app
    runApp(const MonitorDolarApp());
    
  } catch (e) {
    debugPrint("❌ Error crítico en inicialización: $e");
    // Iniciar app incluso si hay error en servicios de background
    runApp(const MonitorDolarApp());
  }
}

// ========== FUNCIONES DE BACKGROUND SERVICE ==========
Future<void> _showBackgroundNotification(
    String title, String body, double dolarPrice, double euroPrice, double? usdtPrice) async {
  try {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'dolar_background_channel',
      'Actualizaciones en Background',
      channelDescription: 'Notificaciones automáticas de tasas',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound('notification_dolar'),
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    // Agregar USDT si está disponible
    String finalBody = body;
    if (usdtPrice != null && title.contains('Precio del Día')) {
      finalBody += '\nUSDT: ${usdtPrice.toStringAsFixed(2).replaceAll('.', ',')} Bs.';
    }

    await notificationsPlugin.show(
      0,
      title,
      finalBody,
      details,
    );
  } catch (e) {
    debugPrint("Error en notificación de background: $e");
  }
}

Future<void> stopBackgroundService() async {
  try {
    await Workmanager().cancelAll();
    await LocalStorage.saveBackgroundServiceEnabled(false);
    debugPrint("🛑 Servicio de background detenido y deshabilitado");
  } catch (e) {
    debugPrint("Error deteniendo servicio: $e");
  }
}

Future<bool> isBackgroundServiceRunning() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('background_service_enabled') ?? false;
  } catch (e) {
    debugPrint("Error verificando estado del servicio: $e");
    return false;
  }
}
// ========== MODELO DE HISTORIAL ==========
class ExchangeHistory {
  final DateTime date;
  final double dolarPrice;
  final double euroPrice;
  final double? usdtPrice; // nuevo campo opcional

  ExchangeHistory({
    required this.date,
    required this.dolarPrice,
    required this.euroPrice,
    this.usdtPrice,
  });

  Map<String, dynamic> toJson() {
    return {
      'date': date.toIso8601String(),
      'dolarPrice': dolarPrice,
      'euroPrice': euroPrice,
      'usdtPrice': usdtPrice,
    };
  }

  
  factory ExchangeHistory.fromJson(Map<String, dynamic> json) {
    return ExchangeHistory(
      date: DateTime.parse(json['date']),
      dolarPrice: json['dolarPrice'],
      euroPrice: json['euroPrice'],
      usdtPrice: json['usdtPrice'],
    );
  }
}

// ========== SERVICIO DE ALMACENAMIENTO LOCAL ==========
class LocalStorage {
  static const String _historyKey = 'exchange_history';
  static const String _cacheKey = 'price_cache';
  static const String _themeKey = 'app_theme';
  static const String _notificationIntervalKey = 'notification_interval';
  static const String _backgroundServiceKey = 'background_service_enabled';
  static const int _maxHistoryItems = 100;
  static const String _notificationTypeKey = 'notification_type'; // 0 = siempre, 1 = solo cambios

  // Guardar intervalo de notificaciones
  static Future<void> saveNotificationInterval(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_notificationIntervalKey, minutes);
  }

  // Obtener intervalo de notificaciones
  static Future<int> getNotificationInterval() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_notificationIntervalKey) ?? 60; // 60 minutos por defecto
  }

  // Guardar estado del servicio de background
  static Future<void> saveBackgroundServiceEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundServiceKey, enabled);
  }

  // Obtener estado del servicio de background
  static Future<bool> getBackgroundServiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backgroundServiceKey) ?? true;
  }


  // Guardar en historial
  static Future<void> saveToHistory(ExchangeHistory history) async {
    final prefs = await SharedPreferences.getInstance();
    final historyList = await getHistory();
    
    // Insertar al principio
    historyList.insert(0, history);
    
    // Limitar el tamaño del historial
    if (historyList.length > _maxHistoryItems) {
      historyList.removeLast();
    }
    
    // Guardar
    final historyJson = historyList.map((h) => h.toJson()).toList();
    await prefs.setStringList(_historyKey, 
        historyJson.map((json) => jsonEncode(json)).toList());
  }

  // Obtener historial
  static Future<List<ExchangeHistory>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyStrings = prefs.getStringList(_historyKey) ?? [];
    
    return historyStrings.map((string) {
      final json = jsonDecode(string);
      return ExchangeHistory.fromJson(json);
    }).toList();
  }

  // Guardar cache de precios
  static Future<void> savePriceCache(double dolar, double euro, double? usdt) async {
    final prefs = await SharedPreferences.getInstance();
    final cache = {
      'dolar': dolar,
      'euro': euro,
      'usdt': usdt,
      'timestamp': DateTime.now().toIso8601String(),
    };
    await prefs.setString(_cacheKey, jsonEncode(cache));
  }

  // Obtener cache de precios
  static Future<Map<String, dynamic>?> getPriceCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheString = prefs.getString(_cacheKey);

    if (cacheString != null) {
      final cache = jsonDecode(cacheString);
      final timestamp = DateTime.parse(cache['timestamp']);
      final now = DateTime.now();

      // Verificar si el cache tiene menos de 24 horas
      if (now.difference(timestamp).inHours < 24) {
        return cache;
      }
    }
    return null;
  }

  static Future<void> saveTheme(bool isDarkMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, isDarkMode);
  }

  static Future<bool> getTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_themeKey) ?? true; // true = modo oscuro por defecto
  }
  
  static Future<void> saveNotificationType(int type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_notificationTypeKey, type);
  }

  // Obtener tipo de notificación
  static Future<int> getNotificationType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_notificationTypeKey) ?? 0; // Por defecto: siempre notificar
  }
}

class MonitorDolarApp extends StatefulWidget {
  const MonitorDolarApp({super.key});

  @override
  _MonitorDolarAppState createState() => _MonitorDolarAppState();
}

Future<http.Response> hacerPeticionConTimeout(String url) async {
  try {
    final response = await http.get(
      Uri.parse(url),
    ).timeout(const Duration(seconds: 10));
    
    return response;
  } on SocketException catch (e) {
    print('Error de conexión: $e');
    throw Exception('No hay conexión a internet');
  } on TimeoutException catch (e) {
    print('Timeout: $e');
    throw Exception('Tiempo de espera agotado');
  }
}

class _MonitorDolarAppState extends State<MonitorDolarApp> {
  bool _isDarkMode = true;

  @override
  void initState() {
    super.initState();
    _loadTheme(); // Cargar tema guardado al iniciar
  }

  Future<void> _loadTheme() async {
    try {
      final savedTheme = await LocalStorage.getTheme();
      setState(() {
        _isDarkMode = savedTheme;
      });
    } catch (e) {
      print('Error cargando tema: $e');
      // Mantener el valor por defecto si hay error
    }
  }

  void _toggleTheme() {
    final newTheme = !_isDarkMode;
    
    setState(() {
      _isDarkMode = newTheme;
    });
    
    // Guardar automáticamente cuando cambie
    _saveTheme();
    
    // Opcional: Mostrar snackbar de confirmación
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newTheme ? 'Modo oscuro activado' : 'Modo claro activado',
            textAlign: TextAlign.center,
          ),
          backgroundColor: newTheme ? Colors.grey[800] : Colors.green,
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(20),
        ),
      );
    }
  }

  Future<void> _saveTheme() async {
    try {
      await LocalStorage.saveTheme(_isDarkMode);
    } catch (e) {
      print('Error guardando tema: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tasas BCV Monitor',
      theme: _isDarkMode 
          ? ThemeData(
              primarySwatch: Colors.green,
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF121212),
              cardColor: const Color(0xFF1E1E1E),
              textTheme: const TextTheme(
                bodyLarge: TextStyle(color: Colors.white),
                bodyMedium: TextStyle(color: Colors.white70),
                titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              iconTheme: const IconThemeData(color: Colors.white),
            )
          : ThemeData(
              primarySwatch: Colors.green,
              brightness: Brightness.light,
              scaffoldBackgroundColor: Colors.grey[100],
              cardColor: Colors.white,
              textTheme: const TextTheme(
                bodyLarge: TextStyle(color: Colors.black87),
                bodyMedium: TextStyle(color: Colors.black54),
              ),
            ),
      home: HomeScreen(
        toggleTheme: _toggleTheme,
        isDarkMode: _isDarkMode,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

// Función para calcular el múltiplo comparado con el dólar BCV

class BinanceService {
  static const String url = 'https://monitorvenezuela.com/tasa/binance/';

  static Future<double?> getUsdtPrice() async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final document = parser.parse(response.body);

        // Buscar el <p> que contiene la tasa USDT
        final element = document.querySelector('p.text-5xl.font-bold.text-blue-400.mb-2');
        if (element != null) {
          final text = element.text.trim();
          print('Texto USDT encontrado: $text');

          final regex = RegExp(r'(\d{1,3}(?:\.\d{3})*(?:,\d{2}))');
          final match = regex.firstMatch(text);

          if (match != null) {
            final priceStr = match.group(1)!
                .replaceAll('.', '')   // quitar separadores de miles
                .replaceAll(',', '.'); // convertir coma en punto decimal
            final price = double.tryParse(priceStr);
            print('💱 Precio USDT Binance extraído: $price Bs.');
            return price;
          }
        }
      } else {
        print('Error HTTP: ${response.statusCode}');
      }
    } catch (e) {
      print('Error obteniendo precio USDT Binance: $e');
    }
    return null;
  }
}

class BcvService {
  static const String url = 'https://www.bcv.org.ve/';
  
  static Future<Map<String, double?>> getAllPrices() async {
  try {
    final dolar = await getDolarPrice();
    final euro = await getEuroPrice();
    
    return {
      'dolar': dolar,
      'euro': euro,
    };
  } catch (e) {
    print('Error obteniendo todos los precios: $e');
    return {'dolar': null, 'euro': null};
  }
}

  static Future<String> _getWithRetry() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final client = HttpClient();
        client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
        
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('User-Agent', 
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36');
        request.headers.set('Accept', 
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8');
        request.headers.set('Accept-Language', 'es-ES,es;q=0.9,en;q=0.8');
        
        final response = await request.close();
        
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>([], (prev, element) => prev..addAll(element));
          
          try {
            return utf8.decode(bytes);
          } catch (e) {
            try {
              return latin1.decode(bytes);
            } catch (e) {
              return String.fromCharCodes(bytes);
            }
          }
        } else {
          print('Error HTTP: ${response.statusCode}');
        }
      } catch (e) {
        print('Intento ${attempt + 1} fallido: $e');
        if (attempt == 2) rethrow;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception('No se pudo conectar después de 3 intentos');
  }
  
  static Future<String> _getWithHttpPackage() async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'es-ES,es;q=0.9',
        },
      );
      
      if (response.statusCode == 200) {
        return response.body;
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      print('Error con paquete http: $e');
      rethrow;
    }
  }
  
  static Future<double?> getDolarPrice() async {
    try {
      String html;
      
      try {
        html = await _getWithRetry();
      } catch (e) {
        html = await _getWithHttpPackage();
      }
      
      print('HTML obtenido exitosamente (${html.length} caracteres)');
      
      final document = parser.parse(html);
      
      final selectors = [
        () => document.getElementById('dolar'),
        () {
          final elements = document.querySelectorAll('*');
          for (var element in elements) {
            if (element.text.contains('USD') && element.text.contains(RegExp(r'\d'))) {
              return element;
            }
          }
          return null;
        },
        () => document.querySelector('div[class*="dolar"]'),
        () {
          final strongs = document.querySelectorAll('strong');
          for (var strong in strongs) {
            final text = strong.text.trim();
            if (text.contains(RegExp(r'\d+,\d+'))) {
              final parent = strong.parent;
              if (parent != null && parent.text.toLowerCase().contains('usd')) {
                return parent;
              }
            }
          }
          return null;
        },
      ];
      
      for (var selector in selectors) {
        try {
          final element = selector();
          if (element != null) {
            final text = element.text;
            print('Elemento encontrado: $text');
            
            final regex = RegExp(r'(\d{1,3}(?:\.\d{3})*(?:,\d{2}))');
            final match = regex.firstMatch(text);
            
            if (match != null) {
              final priceStr = match.group(1)!
                  .replaceAll('.', '')
                  .replaceAll(',', '.');
              final price = double.tryParse(priceStr);
              print('Precio extraído: $price');
              return price;
            }
          }
        } catch (e) {
          print('Error en selector: $e');
        }
      }
      
      print('No se pudo encontrar el precio del dólar');
      return null;
      
    } catch (e) {
      print('Error crítico obteniendo precio dólar: $e');
      return null;
    }
  }
  
  static Future<double?> getEuroPrice() async {
    try {
      String html;
      
      try {
        html = await _getWithRetry();
      } catch (e) {
        html = await _getWithHttpPackage();
      }
      
      final document = parser.parse(html);
      
      final selectors = [
        () => document.getElementById('euro'),
        () {
          final elements = document.querySelectorAll('*');
          for (var element in elements) {
            if (element.text.contains('EUR') && element.text.contains(RegExp(r'\d'))) {
              return element;
            }
          }
          return null;
        },
        () => document.querySelector('div[class*="euro"]'),
      ];
      
      for (var selector in selectors) {
        try {
          final element = selector();
          if (element != null) {
            final text = element.text;
            final regex = RegExp(r'(\d{1,3}(?:\.\d{3})*(?:,\d{2}))');
            final match = regex.firstMatch(text);
            
            if (match != null) {
              final priceStr = match.group(1)!
                  .replaceAll('.', '')
                  .replaceAll(',', '.');
              return double.tryParse(priceStr);
            }
          }
        } catch (e) {
          print('Error en selector euro: $e');
        }
      }
      
      return null;
      
    } catch (e) {
      print('Error crítico obteniendo precio euro: $e');
      return null;
    }
  }
}

// ========== PANTALLA DE HISTORIAL ==========
class HistoryScreen extends StatefulWidget {
  final bool isDarkMode;

  const HistoryScreen({super.key, required this.isDarkMode});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ExchangeHistory> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await LocalStorage.getHistory();
    setState(() {
      _history = history;
      _isLoading = false;
    });
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatPrice(double price) {
    return '${price.toStringAsFixed(2).replaceAll('.', ',')} Bs.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode ? const Color(0xFF121212) : Colors.grey[100],
      appBar: AppBar(
        title: Text(
          'Historial de Tasas',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black87,
          ),
        ),
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        iconTheme: IconThemeData(
          color: widget.isDarkMode ? Colors.white : Colors.black87,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: widget.isDarkMode ? Colors.green : Colors.green[700],
              ),
            )
          : _history.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history,
                        size: 64,
                        color: widget.isDarkMode ? Colors.white38 : Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No hay historial disponible',
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white38 : Colors.grey[600],
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    return Card(
                      color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                      elevation: 2,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDate(item.date),
                                  style: TextStyle(
                                    color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: widget.isDarkMode ? Colors.green[800] : Colors.green[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${item.date.hour.toString().padLeft(2, '0')}:${item.date.minute.toString().padLeft(2, '0')}',
                                    style: TextStyle(
                                      color: widget.isDarkMode ? Colors.white : Colors.green[800],
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildPriceItem(
                                    'Dólar',
                                    _formatPrice(item.dolarPrice),
                                    Icons.attach_money,
                                    widget.isDarkMode ? Colors.green : Colors.green[700]!,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildPriceItem(
                                    'Euro',
                                    _formatPrice(item.euroPrice),
                                    Icons.euro,
                                    widget.isDarkMode ? Colors.blue : Colors.blue[700]!,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildPriceItem(
                                    'Binance',
                                    _formatPrice(item.usdtPrice!),
                                    Icons.currency_bitcoin,
                                    widget.isDarkMode ? Colors.orange : Colors.orange[700]!,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildPriceItem(String title, String price, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? Colors.black26 : Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                title,
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            price,
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white : Colors.black87,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}


// ========== PANTALLA DE CONFIGURACIÓN ==========
// ========== PANTALLA DE CONFIGURACIÓN RESPONSIVE ==========
class SettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onServiceToggle;
  final Function(int) onIntervalChanged;

  const SettingsScreen({
    super.key,
    required this.isDarkMode,
    required this.onServiceToggle,
    required this.onIntervalChanged,
  });

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _backgroundServiceEnabled = true;
  int _selectedInterval = 60;
  int _selectedNotificationType = 0;
  bool _isLoading = true;

  final List<Map<String, dynamic>> _notificationTypeOptions = [
    {'type': 0, 'label': 'Notificar precio del día', 'description': 'Recibir notificación con los precios en cada actualización'},
    {'type': 1, 'label': 'Solo notificar cambios', 'description': 'Recibir notificación solo cuando cambien los precios'},
  ];

  final List<Map<String, dynamic>> _intervalOptions = [
    {'minutes': 15, 'label': '15 minutos', 'description': 'Actualizaciones frecuentes'},
    {'minutes': 30, 'label': '30 minutos', 'description': 'Actualizaciones estándar'},
    {'minutes': 60, 'label': '1 hora', 'description': 'Actualizaciones periódicas'},
    {'minutes': 120, 'label': '2 horas', 'description': 'Actualizaciones espaciadas'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final isEnabled = await LocalStorage.getBackgroundServiceEnabled();
      final interval = await LocalStorage.getNotificationInterval();
      final notificationType = await LocalStorage.getNotificationType();
      
      int finalInterval = interval;
      if (isEnabled && (interval < 15 && interval != 0)) {
        finalInterval = 15;
        await LocalStorage.saveNotificationInterval(15);
      }
      
      setState(() {
        _backgroundServiceEnabled = isEnabled;
        _selectedInterval = finalInterval;
        _selectedNotificationType = notificationType;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error cargando configuraciones: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveNotificationType(int type) async {
    await LocalStorage.saveNotificationType(type);
    
    if (type == 1) {
      await LocalStorage.saveNotificationInterval(60);
      setState(() {
        _selectedInterval = 60;
      });
      widget.onIntervalChanged(60);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('✅ Intervalo fijado a 60 minutos para "Solo notificar cambios"'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _saveServiceStatus(bool enabled) async {
    await LocalStorage.saveBackgroundServiceEnabled(enabled);
    widget.onServiceToggle(enabled);
  }

  Future<void> _saveInterval(int minutes) async {
    if (_selectedNotificationType == 1) {
      minutes = 60;
    }
    
    await LocalStorage.saveNotificationInterval(minutes);
    widget.onIntervalChanged(minutes);
  }

  void _showVersionNotes() {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.8,
              maxWidth: isSmallScreen ? mediaQuery.size.width * 0.95 : 500,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.update,
                          size: isLargeFont ? 32 : 40,
                          color: widget.isDarkMode ? Colors.green : Colors.green[700],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Notas de Versión',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white : Colors.black87,
                            fontSize: isLargeFont ? 18 : 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  Flexible(
                    child: _buildVersionCard(
                      'v1.3.0',
                      'Actual',
                      [
                        '✓ Widget para pantalla de inicio',
                        '✓ Soporte técnico integrado',
                        '✓ Mejoras en notificaciones',
                        '✓ Rendimiento optimizado',
                      ],
                      Colors.green,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: _buildVersionCard(
                      'v1.2.0',
                      'Mejoras importantes',
                      [
                        '✓ Calculadora mejorada',
                        '✓ Historial detallado',
                        '✓ Tema oscuro/claro',
                        '✓ Interfaz renovada',
                      ],
                      Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: _buildVersionCard(
                      'v1.1.0',
                      'Características iniciales',
                      [
                        '✓ Monitoreo BCV en tiempo real',
                        '✓ Precios de Binance (USDT)',
                        '✓ Notificaciones automáticas',
                        '✓ Conversor integrado',
                      ],
                      Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: EdgeInsets.symmetric(horizontal: isSmallScreen ? 4 : 0),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[900]!.withOpacity(0.2) : Colors.blue[50],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Próximamente: Más características y mejoras. ¡Gracias por usar la app!',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.blue[200] : Colors.blue[800],
                        fontSize: isLargeFont ? 12 : 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: isSmallScreen ? 20 : 32,
                          vertical: isSmallScreen ? 12 : 16,
                        ),
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Cerrar',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isLargeFont ? 14 : 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVersionCard(String version, String title, List<String> features, Color color) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? color.withOpacity(0.1) : color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 6 : 8,
                    vertical: isSmallScreen ? 3 : 4,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    version,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isLargeFont ? 11 : 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SizedBox(width: isSmallScreen ? 8 : 12),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w600,
                    fontSize: isLargeFont ? 14 : 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: isSmallScreen ? 6 : 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: features.map((feature) {
              return Padding(
                padding: EdgeInsets.only(bottom: isSmallScreen ? 3 : 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: isLargeFont ? 14 : 16,
                      color: color,
                    ),
                    SizedBox(width: isSmallScreen ? 6 : 8),
                    Expanded(
                      child: Text(
                        feature,
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                          fontSize: isLargeFont ? 12 : 13,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showDonationDialog() {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.85,
              maxWidth: isSmallScreen ? mediaQuery.size.width * 0.95 : 500,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.coffee,
                          size: isLargeFont ? 40 : 50,
                          color: widget.isDarkMode ? Colors.orange : Colors.orange[700],
                        ),
                        SizedBox(height: isSmallScreen ? 8 : 10),
                        Text(
                          '¡Invítame un café! ',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white : Colors.black87,
                            fontSize: isLargeFont ? 18 : 22,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Flexible(
                    child: Text(
                      'Esta aplicación es totalmente gratuita y sin anuncios. Si te está siendo útil y quieres apoyar el desarrollo, ¡invítame un cafe!',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                        fontSize: isLargeFont ? 13 : 14,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 12 : 15),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.2) : Colors.green[50],
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: widget.isDarkMode ? Colors.green : Colors.green[300]!,
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.favorite,
                          color: Colors.red,
                          size: isLargeFont ? 24 : 30,
                        ),
                        SizedBox(height: isSmallScreen ? 8 : 10),
                        Text(
                          'Tu apoyo nos motiva a seguir mejorando la app',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.w500,
                            fontSize: isLargeFont ? 14 : 15,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Text(
                    'Selecciona tu método de donación preferido:',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                      fontSize: isLargeFont ? 13 : 14,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 15),
                  
                  Flexible(
                    child: _buildDonationOption(
                      'USDT (Binance) trc20',
                      'TNhGA8SHoKmR77qsnJ6To8zgQztsaYpQo8',
                      Icons.payment,
                      Colors.blue,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 10 : 12),
                  Flexible(
                    child: _buildDonationOption(
                      'Binance ID',
                      '771258055',
                      Icons.currency_bitcoin,
                      Colors.orange,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[900]!.withOpacity(0.1) : Colors.blue[50],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '¡Gracias por considerar apoyar el proyecto! ❤️',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.blue[200] : Colors.blue[800],
                        fontSize: isLargeFont ? 12 : 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 20 : 24),
                  
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            backgroundColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Tal vez después',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                              fontSize: isLargeFont ? 12 : 15,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: isSmallScreen ? 12 : 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('¡Gracias por tu apoyo! Tu contribución hace la diferencia.'),
                                backgroundColor: Colors.green,
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            '¡Donar ahora!',
                            style: TextStyle(
                              fontSize: isLargeFont ? 12 : 15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDonationOption(String title, String details, IconData icon, Color color) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    return GestureDetector(
      onTap: () {
        FlutterClipboard.copy(details).then((_) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Información de $title copiada al portapapeles'),
              backgroundColor: Colors.green,
            ),
          );
        });
      },
      child: Container(
        padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? color.withOpacity(0.1) : color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(isSmallScreen ? 6 : 8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: color,
                size: isLargeFont ? 20 : 24,
              ),
            ),
            SizedBox(width: isSmallScreen ? 10 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w600,
                      fontSize: isLargeFont ? 14 : 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: isSmallScreen ? 2 : 4),
                  Flexible(
                    child: Text(
                      details,
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                        fontSize: isLargeFont ? 11 : 12,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: isSmallScreen ? 8 : 10),
            Icon(
              Icons.content_copy,
              size: isLargeFont ? 16 : 18,
              color: color,
            ),
          ],
        ),
      ),
    );
  }

  void _showTechnicalSupport() {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.8,
              maxWidth: isSmallScreen ? mediaQuery.size.width * 0.95 : 500,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Soporte Técnico',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: isLargeFont ? 18 : 20,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 16),
                  
                  Flexible(
                    child: Text(
                      'Para soporte técnico, comunicarse al correo:',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                        fontSize: isLargeFont ? 14 : 15,
                      ),
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 16),
                  
                  GestureDetector(
                    onTap: () {
                      FlutterClipboard.copy('Yefiiix@gmail.com').then((_) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Correo copiado al portapapeles'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                      decoration: BoxDecoration(
                        color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.3) : Colors.green[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: widget.isDarkMode ? Colors.green : Colors.green[300]!,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.mail,
                            color: widget.isDarkMode ? Colors.lightGreenAccent : Colors.green[700],
                            size: isLargeFont ? 20 : 24,
                          ),
                          SizedBox(width: isSmallScreen ? 8 : 10),
                          Expanded(
                            child: SelectableText(
                              'Yefiiix@gmail.com',
                              style: TextStyle(
                                color: widget.isDarkMode ? Colors.lightGreenAccent : Colors.green[700],
                                fontSize: isLargeFont ? 15 : 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          SizedBox(width: isSmallScreen ? 8 : 10),
                          Icon(
                            Icons.content_copy,
                            size: isLargeFont ? 18 : 20,
                            color: widget.isDarkMode ? Colors.lightGreenAccent : Colors.green[700],
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 16),
                  
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[900]!.withOpacity(0.2) : Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                              size: isLargeFont ? 18 : 20,
                            ),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Flexible(
                              child: Text(
                                'Tipos de soporte que ofrecemos:',
                                style: TextStyle(
                                  color: widget.isDarkMode ? Colors.blue[200] : Colors.blue[800],
                                  fontWeight: FontWeight.w500,
                                  fontSize: isLargeFont ? 14 : 15,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isSmallScreen ? 8 : 10),
                        _buildSupportItem('🚀 Problemas técnicos'),
                        _buildSupportItem('💡 Sugerencias de mejora'),
                        _buildSupportItem('🐛 Reporte de errores'),
                        _buildSupportItem('📱 Compatibilidad de dispositivos'),
                        _buildSupportItem('🙌 Mucho mas'),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 16),
                  
                  Flexible(
                    child: Text(
                      'Estaremos encantados de ayudarte con cualquier problema o sugerencia.',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                        fontSize: isLargeFont ? 13 : 14,
                      ),
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 20 : 24),
                  
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            backgroundColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Cerrar',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                              fontSize: isLargeFont ? 14 : 15,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: isSmallScreen ? 12 : 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            // Aquí podrías abrir el cliente de correo
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Enviar correo',
                            style: TextStyle(
                              fontSize: isLargeFont ? 12 : 15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSupportItem(String text) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    return Padding(
      padding: EdgeInsets.only(bottom: isSmallScreen ? 3 : 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.arrow_right,
            size: isLargeFont ? 18 : 20,
            color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
          ),
          SizedBox(width: isSmallScreen ? 4 : 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                fontSize: isLargeFont ? 13 : 14,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.8,
              maxWidth: isSmallScreen ? mediaQuery.size.width * 0.95 : 500,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    children: [
                      Container(
                        width: isLargeFont ? 60 : 80,
                        height: isLargeFont ? 60 : 80,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(isLargeFont ? 15 : 20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withOpacity(0.3),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.attach_money,
                          color: Colors.white,
                          size: isLargeFont ? 30 : 40,
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 8 : 10),
                      Text(
                        'Cambio Dolar BCV',
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white : Colors.black87,
                          fontSize: isLargeFont ? 18 : 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'v1.0.8',
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                          fontSize: isLargeFont ? 13 : 14,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Flexible(
                    child: Text(
                      'La aplicación más confiable para monitorear las tasas de cambio en Venezuela',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                        fontSize: isLargeFont ? 14 : 15,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.2) : Colors.green[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: isLargeFont ? 18 : 20,
                            ),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Flexible(
                              child: Text(
                                'Características principales:',
                                style: TextStyle(
                                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                  fontSize: isLargeFont ? 15 : 16,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isSmallScreen ? 8 : 10),
                        _buildFeatureItem('📊 Precios del BCV en tiempo real'),
                        _buildFeatureItem('💱 Tasa de Binance (USDT)'),
                        _buildFeatureItem('🔔 Notificaciones automáticas'),
                        _buildFeatureItem('🧮 Calculadora integrada'),
                        _buildFeatureItem('📱 Widget para pantalla de inicio'),
                        _buildFeatureItem('🌙 Modo oscuro/claro'),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                  
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[900]!.withOpacity(0.2) : Colors.blue[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.code,
                              color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                              size: isLargeFont ? 18 : 20,
                            ),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Flexible(
                              child: Text(
                                'Información técnica:',
                                style: TextStyle(
                                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                  fontSize: isLargeFont ? 15 : 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isSmallScreen ? 8 : 10),
                        Flexible(
                          child: Text(
                            'Desarrollado con Flutter\n© 2026 Cambio Dolar BCV',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white60 : Colors.grey[500],
                              fontSize: isLargeFont ? 12 : 13,
                              fontStyle: FontStyle.italic,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 20 : 24),
                  
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            backgroundColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Cerrar',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                              fontSize: isLargeFont ? 14 : 15,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: isSmallScreen ? 12 : 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _showVersionNotes();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 12 : 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Ver novedades',
                            style: TextStyle(
                              fontSize: isLargeFont ? 14 : 15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFeatureItem(String text) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    return Padding(
      padding: EdgeInsets.only(bottom: isSmallScreen ? 4 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle,
            size: isLargeFont ? 16 : 18,
            color: Colors.green,
          ),
          SizedBox(width: isSmallScreen ? 6 : 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                fontSize: isLargeFont ? 13 : 14,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
    Widget? trailing,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    
    return ListTile(
      leading: Container(
        width: isLargeFont ? 44 : 40,
        height: isLargeFont ? 44 : 40,
        decoration: BoxDecoration(
          color: iconColor?.withOpacity(0.2) ?? Colors.grey.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: iconColor ?? Colors.grey,
          size: isLargeFont ? 20 : 22,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: widget.isDarkMode ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w500,
          fontSize: isLargeFont ? 15 : 16,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
          fontSize: isLargeFont ? 12 : 13,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ?? Icon(
        Icons.arrow_forward_ios,
        size: isLargeFont ? 14 : 16,
        color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
      ),
      onTap: onTap,
      contentPadding: EdgeInsets.symmetric(
        vertical: isLargeFont ? 10 : 8,
        horizontal: isSmallScreen ? 12 : 16,
      ),
      minVerticalPadding: 12,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isLargeFont = mediaQuery.textScaler.scale(1) > 1.3;
    final isSmallScreen = mediaQuery.size.width < 360;
    final isExtraSmallScreen = mediaQuery.size.width < 320;

    return Scaffold(
      backgroundColor: widget.isDarkMode ? const Color(0xFF121212) : Colors.grey[100],
      appBar: AppBar(
        title: Text(
          'Configuración',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black87,
            fontSize: isLargeFont ? 18 : 20,
          ),
        ),
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        iconTheme: IconThemeData(
          color: widget.isDarkMode ? Colors.white : Colors.black87,
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            size: isLargeFont ? 24 : 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: widget.isDarkMode ? Colors.green : Colors.green[700],
              ),
            )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sección de Notificaciones
                  Container(
                    margin: EdgeInsets.only(bottom: isSmallScreen ? 16 : 20),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 8 : 12,
                          ),
                          child: Text(
                            'NOTIFICACIONES',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                              fontSize: isLargeFont ? 11 : 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        // Estado del servicio
                        SwitchListTile(
                          dense: isSmallScreen,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isSmallScreen ? 16 : 20,
                            vertical: isLargeFont ? 8 : 4,
                          ),
                          title: Text(
                            'Monitoreo automático',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white : Colors.black87,
                              fontWeight: FontWeight.w500,
                              fontSize: isLargeFont ? 15 : 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _backgroundServiceEnabled
                                ? 'Actualizaciones activadas'
                                : 'Actualizaciones desactivadas',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                              fontSize: isLargeFont ? 12 : 13,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: _backgroundServiceEnabled,
                          onChanged: (value) async {
                            setState(() {
                              _backgroundServiceEnabled = value;
                            });
                            await _saveServiceStatus(value);
                            
                            if (value) {
                              await _saveInterval(_selectedInterval);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('✅ Monitoreo activado (cada $_selectedInterval min)'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              }
                            } else {
                              await stopBackgroundService();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('🛑 Monitoreo desactivado'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                          activeColor: Colors.green,
                          inactiveThumbColor: Colors.grey[600],
                          secondary: Icon(
                            _backgroundServiceEnabled
                                ? Icons.notifications_active
                                : Icons.notifications_off,
                            color: _backgroundServiceEnabled ? Colors.green : Colors.grey,
                            size: isLargeFont ? 22 : 24,
                          ),
                        ),
                        Divider(
                          height: 1,
                          indent: isSmallScreen ? 16 : 20,
                          endIndent: isSmallScreen ? 16 : 20,
                          color: widget.isDarkMode ? Colors.white12 : Colors.grey[200],
                        ),
                        
                        // Configuración avanzada
                        _buildSettingItem(
                          icon: Icons.settings,
                          title: 'Configuración de notificaciones',
                          subtitle: 'Personaliza frecuencia y tipo de alertas',
                          iconColor: Colors.blue,
                          onTap: () {
  showModalBottomSheet(
    context: context,
    backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.9,
              ),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Container(
                  padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: EdgeInsets.only(bottom: isSmallScreen ? 16 : 20),
                          decoration: BoxDecoration(
                            color: Colors.grey[400],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'Configuración de Notificaciones',
                        style: TextStyle(
                          fontSize: isLargeFont ? 18 : 20,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 16 : 20),
                      
                      // Tipo de notificación
                      Text(
                        'Tipo de notificación:',
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                          fontSize: isLargeFont ? 14 : 15,
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 12 : 16),
                      
                      ..._notificationTypeOptions.map((option) {
                        final type = option['type'] as int;
                        final label = option['label'] as String;
                        final description = option['description'] as String;
                        final isSelected = _selectedNotificationType == type;
                        
                        return Column(
                          children: [
                            RadioListTile<int>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: TextStyle(
                                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                                      fontWeight: FontWeight.w500,
                                      fontSize: isLargeFont ? 14 : 15,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  SizedBox(height: isSmallScreen ? 2 : 4),
                                  Text(
                                    description,
                                    style: TextStyle(
                                      color: widget.isDarkMode ? Colors.white54 : Colors.grey[600],
                                      fontSize: isLargeFont ? 11 : 12,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                              value: type,
                              groupValue: _selectedNotificationType,
                              onChanged: _backgroundServiceEnabled
                                  ? (value) async {
                                      if (value != null) {
                                        setModalState(() {
                                          _selectedNotificationType = value;
                                        });
                                        await _saveNotificationType(value);
                                        
                                        // Mostrar snackbar sin cerrar el modal
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(value == 0 
                                                  ? '✅ Se notificará el precio en cada actualización'
                                                  : '✅ Solo se notificarán cambios en los precios'),
                                              backgroundColor: Colors.green,
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  : null,
                              activeColor: Colors.green,
                              secondary: type == 0
                                  ? Icon(
                                      Icons.notifications_active,
                                      color: isSelected
                                          ? Colors.green
                                          : widget.isDarkMode
                                              ? Colors.white54
                                              : Colors.grey[500],
                                      size: isLargeFont ? 22 : 24,
                                    )
                                  : Icon(
                                      Icons.notifications_paused,
                                      color: isSelected
                                          ? Colors.blue
                                          : widget.isDarkMode
                                              ? Colors.white54
                                              : Colors.grey[500],
                                      size: isLargeFont ? 22 : 24,
                                    ),
                            ),
                            if (type != _notificationTypeOptions.last['type'])
                              Divider(
                                height: 1,
                                color: widget.isDarkMode ? Colors.white12 : Colors.grey[200],
                              ),
                          ],
                        );
                      }).toList(),
                      
                      SizedBox(height: isSmallScreen ? 16 : 20),
                      
                      // Frecuencia (solo para tipo 0)
                      if (_selectedNotificationType == 0) ...[
                        Text(
                          'Frecuencia de actualización:',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                            fontSize: isLargeFont ? 14 : 15,
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        
                        ..._intervalOptions.map((option) {
                          final minutes = option['minutes'] as int;
                          final label = option['label'] as String;
                          final description = option['description'] as String;
                          final isSelected = _selectedInterval == minutes;

                          return Column(
                            children: [
                              RadioListTile<int>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                      style: TextStyle(
                                        color: widget.isDarkMode ? Colors.white : Colors.black87,
                                        fontWeight: FontWeight.w500,
                                        fontSize: isLargeFont ? 14 : 15,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    SizedBox(height: isSmallScreen ? 2 : 4),
                                    Text(
                                      description,
                                      style: TextStyle(
                                        color: widget.isDarkMode ? Colors.white54 : Colors.grey[600],
                                        fontSize: isLargeFont ? 11 : 12,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                                value: minutes,
                                groupValue: _selectedInterval,
                                onChanged: _backgroundServiceEnabled && _selectedNotificationType == 0
                                    ? (value) async {
                                        if (value != null) {
                                          setModalState(() {
                                            _selectedInterval = value;
                                          });
                                          await _saveInterval(value);
                                          
                                          // Mostrar snackbar sin cerrar el modal
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('✅ Intervalo actualizado a $value minutos'),
                                                backgroundColor: Colors.green,
                                                duration: const Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                        }
                                      }
                                    : null,
                                activeColor: Colors.green,
                                secondary: Icon(
                                  Icons.timer,
                                  color: isSelected
                                      ? Colors.green
                                      : widget.isDarkMode
                                          ? Colors.white54
                                          : Colors.grey[500],
                                  size: isLargeFont ? 22 : 24,
                                ),
                              ),
                              if (minutes != _intervalOptions.last['minutes'])
                                Divider(
                                  height: 1,
                                  color: widget.isDarkMode ? Colors.white12 : Colors.grey[200],
                                ),
                            ],
                          );
                        }).toList(),
                      ],
                      
                      if (_selectedNotificationType == 1) ...[
                        Container(
                          padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                          margin: EdgeInsets.only(bottom: isSmallScreen ? 12 : 16),
                          decoration: BoxDecoration(
                            color: widget.isDarkMode
                                ? Colors.blue[900]!.withOpacity(0.2)
                                : Colors.blue[50],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                                size: isLargeFont ? 18 : 20,
                              ),
                              SizedBox(width: isSmallScreen ? 6 : 8),
                              Expanded(
                                child: Text(
                                  'En "Solo notificar cambios" el intervalo está fijado en 60 minutos.',
                                  style: TextStyle(
                                    color: widget.isDarkMode ? Colors.blue[200] : Colors.blue[800],
                                    fontSize: isLargeFont ? 12 : 13,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      
                      SizedBox(height: isSmallScreen ? 20 : 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              vertical: isSmallScreen ? 14 : 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Cerrar configuración',
                            style: TextStyle(
                              fontSize: isLargeFont ? 14 : 16,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 8 : 12),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
                          },
                        ),
                      ],
                    ),
                  ),                      

                  // Sección de Información
                  Container(
                    margin: EdgeInsets.only(bottom: isSmallScreen ? 16 : 20),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 8 : 12,
                          ),
                          child: Text(
                            'INFORMACIÓN',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                              fontSize: isLargeFont ? 11 : 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        _buildSettingItem(
                          icon: Icons.update,
                          title: 'Notas de versión',
                          subtitle: 'Descubre las novedades de cada actualización',
                          iconColor: Colors.green,
                          onTap: _showVersionNotes,
                        ),
                        Divider(
                          height: 1,
                          indent: isSmallScreen ? 16 : 20,
                          endIndent: isSmallScreen ? 16 : 20,
                          color: widget.isDarkMode ? Colors.white12 : Colors.grey[200],
                        ),
                        _buildSettingItem(
                          icon: Icons.info_outline,
                          title: 'Acerca de la app',
                          subtitle: 'Información sobre Cambio Dolar BCV',
                          iconColor: Colors.blue,
                          onTap: _showAboutDialog,
                        ),
                      ],
                    ),
                  ),

                  // Sección de Soporte
                  Container(
                    margin: EdgeInsets.only(bottom: isSmallScreen ? 16 : 20),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 16 : 20,
                            isSmallScreen ? 8 : 12,
                          ),
                          child: Text(
                            'SOPORTE',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                              fontSize: isLargeFont ? 11 : 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        _buildSettingItem(
                          icon: Icons.coffee,
                          title: 'Invítanos un café',
                          subtitle: 'Apoya el desarrollo de la app',
                          iconColor: Colors.orange,
                          onTap: _showDonationDialog,
                        ),
                        Divider(
                          height: 1,
                          indent: isSmallScreen ? 16 : 20,
                          endIndent: isSmallScreen ? 16 : 20,
                          color: widget.isDarkMode ? Colors.white12 : Colors.grey[200],
                        ),
                        _buildSettingItem(
                          icon: Icons.support_agent,
                          title: 'Soporte técnico',
                          subtitle: '¿Necesitas ayuda? Contáctanos',
                          iconColor: Colors.red,
                          onTap: _showTechnicalSupport,
                        ),
                      ],
                    ),
                  ),

                  // Información adicional
                  Container(
                    padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
                    margin: EdgeInsets.only(bottom: isSmallScreen ? 16 : 20),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.2) : Colors.green[50],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.green.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.security,
                          color: widget.isDarkMode ? Colors.green[300] : Colors.green[700],
                          size: isLargeFont ? 20 : 22,
                        ),
                        SizedBox(width: isSmallScreen ? 10 : 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tu privacidad es importante',
                                style: TextStyle(
                                  color: widget.isDarkMode ? Colors.white : Colors.green[900],
                                  fontWeight: FontWeight.w600,
                                  fontSize: isLargeFont ? 14 : 15,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(height: isSmallScreen ? 2 : 4),
                              Text(
                                'Esta app no recopila datos personales. Los precios se obtienen directamente de BCV y Binance.',
                                style: TextStyle(
                                  color: widget.isDarkMode ? Colors.white70 : Colors.green[800],
                                  fontSize: isLargeFont ? 11 : 12,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Footer
                  Center(
                    child: Column(
                      children: [
                        Text(
                          'Cambio Dolar BCV v1.3.0',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                            fontSize: isLargeFont ? 11 : 12,
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 2 : 4),
                        Text(
                          '© 2026 - Desarrollado Por YefriDev',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white60 : Colors.grey[500],
                            fontSize: isLargeFont ? 10 : 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 20),
                ],
              ),
            ),
    );
  }
}

// ========== CALCULADORA ==========
class CalculatorScreen extends StatefulWidget {
  final double? dolarPrice;
  final double? euroPrice;
  final bool isDarkMode;

  const CalculatorScreen({
    super.key,
    required this.dolarPrice,
    required this.euroPrice,
    required this.isDarkMode,
  });

  @override
  _CalculatorScreenState createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  String _display = '0';
  String _expression = '';
  double? _firstNumber;
  double? _secondNumber;
  String _operator = '';
  bool _shouldResetDisplay = false;
  
  // Variables para almacenar precios con respaldo del cache
  double? _dolarCalculadora;
  double? _euroCalculadora;
  late Future<Map<String, dynamic>?> _cacheFuture;

  @override
  void initState() {
    super.initState();
    _cacheFuture = LocalStorage.getPriceCache();
    _loadPricesFromCache();
  }

  Future<void> _loadPricesFromCache() async {
    try {
      final cache = await LocalStorage.getPriceCache();
      if (cache != null) {
        setState(() {
          // Si no tenemos precios de los parámetros, usamos el cache
          if (widget.dolarPrice == null && cache['dolar'] != null) {
            _dolarCalculadora = cache['dolar'];
          } else {
            _dolarCalculadora = widget.dolarPrice;
          }
          
          if (widget.euroPrice == null && cache['euro'] != null) {
            _euroCalculadora = cache['euro'];
          } else {
            _euroCalculadora = widget.euroPrice;
          }
        });
      } else {
        // Si no hay cache, usamos los parámetros
        setState(() {
          _dolarCalculadora = widget.dolarPrice;
          _euroCalculadora = widget.euroPrice;
        });
      }
    } catch (e) {
      print('Error cargando cache en calculadora: $e');
      // En caso de error, usamos los parámetros
      setState(() {
        _dolarCalculadora = widget.dolarPrice;
        _euroCalculadora = widget.euroPrice;
      });
    }
  }

  void _onNumberPressed(String number) {
    setState(() {
      if (_shouldResetDisplay || _display == '0') {
        _display = number;
        _shouldResetDisplay = false;
      } else {
        _display += number;
      }
    });
  }

  void _onDecimalPressed() {
    setState(() {
      if (_shouldResetDisplay) {
        _display = '0,';
        _shouldResetDisplay = false;
      } else if (!_display.contains(',')) {
        _display += ',';
      }
    });
  }

  void _onOperatorPressed(String op) {
    setState(() {
      if (_firstNumber == null) {
        _firstNumber = _parseDisplay();
        _operator = op;
        _expression = '${_formatNumber(_firstNumber!)} $op ';
        _shouldResetDisplay = true;
      } else {
        _calculate();
        _operator = op;
        _expression = '${_formatNumber(_firstNumber!)} $op ';
        _shouldResetDisplay = true;
      }
    });
  }

  void _calculate() {
    if (_firstNumber != null && _operator.isNotEmpty) {
      _secondNumber = _parseDisplay();
      
      double result = 0;
      switch (_operator) {
        case '+':
          result = _firstNumber! + _secondNumber!;
          break;
        case '-':
          result = _firstNumber! - _secondNumber!;
          break;
        case '×':
          result = _firstNumber! * _secondNumber!;
          break;
        case '÷':
          if (_secondNumber != 0) {
            result = _firstNumber! / _secondNumber!;
          } else {
            setState(() {
              _display = 'Error';
              _firstNumber = null;
              _operator = '';
              _expression = '';
              _shouldResetDisplay = true;
            });
            return;
          }
          break;
      }

      setState(() {
        _display = _formatNumber(result);
        _firstNumber = result;
        _operator = '';
        _expression = '';
        _shouldResetDisplay = true;
      });
    }
  }

  void _copyResult() {
    String textToCopy = _display.replaceAll('.', '').replaceAll(',', '.');
    FlutterClipboard.copy(textToCopy).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Resultado copiado: $textToCopy'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  double _parseDisplay() {
    String numberStr = _display.replaceAll('.', '').replaceAll(',', '.');
    return double.tryParse(numberStr) ?? 0;
  }

  String _formatNumber(double number) {
    String formatted = number.toString();
    
    if (number == number.truncateToDouble()) {
      formatted = number.truncate().toString();
    } else {
      formatted = number.toStringAsFixed(6).replaceAll(RegExp(r'0*$'), '');
      if (formatted.endsWith('.')) {
        formatted = formatted.substring(0, formatted.length - 1);
      }
    }
    
    formatted = formatted.replaceAll('.', ',');
    
    final parts = formatted.split(',');
    String integerPart = parts[0];
    final decimalPart = parts.length > 1 ? ',${parts[1]}' : '';
    
    String newIntegerPart = '';
    for (int i = integerPart.length - 1, count = 0; i >= 0; i--) {
      if (count > 0 && count % 3 == 0) {
        newIntegerPart = '.$newIntegerPart';
      }
      newIntegerPart = integerPart[i] + newIntegerPart;
      count++;
    }
    
    return newIntegerPart + decimalPart;
  }

  void _clear() {
    setState(() {
      _display = '0';
      _expression = '';
      _firstNumber = null;
      _secondNumber = null;
      _operator = '';
      _shouldResetDisplay = false;
    });
  }

  void _insertCurrencyValue(double value) {
    setState(() {
      _display = _formatNumber(value);
      _shouldResetDisplay = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode ? const Color(0xFF2D2D2D) : Colors.grey[100],
      appBar: AppBar(
        title: Text(
          'Calculadora de Conversión',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black87,
          ),
        ),
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        iconTheme: IconThemeData(
          color: widget.isDarkMode ? Colors.white : Colors.black87,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          // Display
          Container(
            margin: const EdgeInsets.all(20),
            child: Column(
              children: [
                // Display principal con ancho fijo
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(
                    minHeight: 100,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 15,
                        offset: const Offset(5, 5),
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.1),
                        blurRadius: 15,
                        offset: const Offset(-5, -5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Expresión (operación en curso)
                      Text(
                        _expression,
                        style: TextStyle(
                          fontSize: 16,
                          color: widget.isDarkMode ? Colors.white60 : Colors.grey[600],
                          fontStyle: FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      const SizedBox(height: 8),
                      // Resultado principal
                      Text(
                        _display,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: widget.isDarkMode ? Colors.white : Colors.black87,
                          letterSpacing: 1.0,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                
                // Botón de copiar debajo del display
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _display == '0' || _display == 'Error' ? null : _copyResult,
                    icon: const Icon(Icons.content_copy, size: 18),
                    label: const Text(
                      'COPIAR RESULTADO',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isDarkMode ? Colors.blue[800] : Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Botones de monedas
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                // Botón DÓLAR con FutureBuilder para cargar desde cache si es necesario
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>?>(
                    future: _cacheFuture,
                    builder: (context, snapshot) {
                      double? precioDolar = _dolarCalculadora;
                      
                      if (precioDolar == null && snapshot.hasData && snapshot.data!['dolar'] != null) {
                        precioDolar = snapshot.data!['dolar'];
                      }
                      
                      String buttonText = 'DÓLAR';
                      if (precioDolar != null) {
                        buttonText = 'DÓLAR\n${_formatNumber(precioDolar)}';
                      } else {
                        buttonText = 'DÓLAR\nEsperando...';
                      }
                      
                      return _buildCurrencyButton(
                        buttonText,
                        precioDolar,
                        Icons.attach_money,
                        precioDolar != null ? () => _insertCurrencyValue(precioDolar!) : null,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                
                // Botón EURO con FutureBuilder para cargar desde cache si es necesario
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>?>(
                    future: _cacheFuture,
                    builder: (context, snapshot) {
                      double? precioEuro = _euroCalculadora;
                      
                      if (precioEuro == null && snapshot.hasData && snapshot.data!['euro'] != null) {
                        precioEuro = snapshot.data!['euro'];
                      }
                      
                      String buttonText = 'EURO';
                      if (precioEuro != null) {
                        buttonText = 'EURO\n${_formatNumber(precioEuro)}';
                      } else {
                        buttonText = 'EURO\nEsperando...';
                      }
                      
                      return _buildCurrencyButton(
                        buttonText,
                        precioEuro,
                        Icons.euro,
                        precioEuro != null ? () => _insertCurrencyValue(precioEuro!) : null,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                
                // Botón USDT (existente)
                Expanded(
                  child: FutureBuilder<double?>(
                    future: BinanceService.getUsdtPrice(),
                    builder: (context, snapshot) {
                      double? usdtPrice;
                      String buttonText = 'USDT';
                      
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        buttonText = 'Cargando USDT...';
                      } else if (snapshot.hasError || !snapshot.hasData) {
                        buttonText = 'USDT: Error';
                      } else {
                        usdtPrice = snapshot.data!;
                        buttonText = 'Binance\n${_formatNumber(usdtPrice)}';
                      }
                      
                      return _buildCurrencyButton(
                        buttonText,
                        usdtPrice,
                        Icons.currency_bitcoin,
                        usdtPrice != null ? () => _insertCurrencyValue(usdtPrice!) : () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('No se pudo obtener el precio de USDT'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          
          // Teclado
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              child: GridView.count(
                crossAxisCount: 4,
                mainAxisSpacing: 15,
                crossAxisSpacing: 15,
                children: _buildCalcButtons(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyButton(String title, double? price, IconData icon, VoidCallback? onPressed) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: widget.isDarkMode ? const Color(0xFF2D2D2D) : Colors.grey[200],
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(4, 4),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: onPressed != null 
                ? (widget.isDarkMode ? Colors.blue[300] : Colors.blue[700])
                : Colors.grey,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: onPressed != null 
              ? (widget.isDarkMode ? Colors.blue[300] : Colors.blue[700])
              : Colors.grey,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCalcButtons() {
    return [
      _buildCalcButton('C', _clear, isSpecial: true),
      _buildCalcButton('⌫', () {
        setState(() {
          if (_display.length > 1) {
            _display = _display.substring(0, _display.length - 1);
          } else {
            _display = '0';
          }
        });
      }, isSpecial: true),
      _buildCalcButton('÷', () => _onOperatorPressed('÷'), isOperator: true),
      _buildCalcButton('×', () => _onOperatorPressed('×'), isOperator: true),
      
      _buildCalcButton('7', () => _onNumberPressed('7')),
      _buildCalcButton('8', () => _onNumberPressed('8')),
      _buildCalcButton('9', () => _onNumberPressed('9')),
      _buildCalcButton('-', () => _onOperatorPressed('-'), isOperator: true),
      
      _buildCalcButton('4', () => _onNumberPressed('4')),
      _buildCalcButton('5', () => _onNumberPressed('5')),
      _buildCalcButton('6', () => _onNumberPressed('6')),
      _buildCalcButton('+', () => _onOperatorPressed('+'), isOperator: true),
      
      _buildCalcButton('1', () => _onNumberPressed('1')),
      _buildCalcButton('2', () => _onNumberPressed('2')),
      _buildCalcButton('3', () => _onNumberPressed('3')),
      _buildCalcButton('=', _calculate, isOperator: true, rowSpan: 2),
      
      _buildCalcButton('0', () => _onNumberPressed('0'), colSpan: 2),
      _buildCalcButton(',', _onDecimalPressed),
    ];
  }

  Widget _buildCalcButton(
    String text, 
    VoidCallback onPressed, {
    bool isOperator = false,
    bool isSpecial = false,
    int colSpan = 1,
    int rowSpan = 1,
  }) {
    bool isNumber = !isOperator && !isSpecial && text != ',' && text != '=' && text != '⌫' && text != 'C';

// Podrías usarla para un estilo diferente:
Color getButtonColor() {
  if (isSpecial) return widget.isDarkMode ? const Color(0xFF4A1E1E) : Colors.red;
  if (isOperator) return widget.isDarkMode ? const Color(0xFF1E3A4A) : Colors.green;
  if (isNumber) return widget.isDarkMode ? const Color(0xFF2A2A2A) : Colors.blue[100]!; // Color diferente para números
  return widget.isDarkMode ? const Color(0xFF3D3D3D) : Colors.grey[200]!;
}

    Color getTextColor() {
      if (isSpecial) return widget.isDarkMode ? Colors.red[300]! : Colors.white;
      if (isOperator) return widget.isDarkMode ? Colors.blue[300]! : Colors.white;
      return widget.isDarkMode ? Colors.white : Colors.black87;
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: widget.isDarkMode ? const Color(0xFF2D2D2D) : Colors.transparent,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 15,
            offset: const Offset(5, 5),
          ),
          BoxShadow(
            color: Colors.white.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(-5, -5),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: getButtonColor(),
          foregroundColor: getTextColor(),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(15),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ========== PANTALLA PRINCIPAL MEJORADA ==========
class HomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final bool isDarkMode;

  const HomeScreen({
    super.key,
    required this.toggleTheme,
    required this.isDarkMode,
  });

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _precioDolar = 'Cargando...';
  String _precioEuro = 'Cargando...';
  String _precioUsdt = 'Cargando...';
  String _ultimaVerificacion = 'Nunca';
  bool _isLoading = false;
  double? _dolarValue;
  double? _euroValue;
  double? _usdtValue;
  bool _usingCachedData = false;
  final TextEditingController _usdController = TextEditingController();
  final TextEditingController _bsController = TextEditingController();
  bool _backgroundServiceEnabled = true;
  bool _useDollar = true;           // true = USD, false = EUR
  bool _isConvertingUSD = false;    // guardas anti-loop
  bool _isConvertingBS = false;     // guardas anti-loop
  bool _isUsdtExpanded = false;

  int _notificationInterval = 60;

  double? _getActiveRate() => _useDollar ? _dolarValue : _euroValue;

  double? _parseNumber(String text) {
    if (text.isEmpty) return null;
    String t = text.trim();

    // Unifica coma a punto para decimales
    t = t.replaceAll(',', '.');

    // Elimina todos los puntos excepto el último (para quitar miles conservando el decimal)
    final lastDot = t.lastIndexOf('.');
    if (lastDot != -1) {
      final withoutDots = t.replaceAll('.', '');
      t = withoutDots.substring(0, lastDot) + '.' + withoutDots.substring(lastDot);
    } else {
      // Solo dígitos
      t = t.replaceAll(RegExp(r'[^0-9]'), '');
    }

    return double.tryParse(t);
  }

  void _setTextSafe(TextEditingController c, String value) {
    final old = c.text;
    if (old == value) return;
    c.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _usdController.addListener(_onUSDChanged);
    _bsController.addListener(_onBSChanged);
    _initializePrices();
    _checkBackgroundServiceStatus();
    
    // Agregar THIS como observer (ahora sí puede porque implementa WidgetsBindingObserver)
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
    });
  }

  Future<void> _showWelcomeDialog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasShownWelcome = prefs.getBool('has_shown_welcome') ?? false;
      
      if (!hasShownWelcome && context.mounted) {
        await Future.delayed(const Duration(seconds: 1)); // Pequeña pausa para mejor UX
        
        showDialog(
          context: context,
          barrierDismissible: false, // Obliga al usuario a interactuar
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Column(
                children: [
                  Icon(
                    Icons.widgets,
                    size: 60,
                    color: widget.isDarkMode ? Colors.green : Colors.green[700],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '¡Bienvenido/a!',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '¿Sabías que puedes agregar un widget a tu pantalla de inicio?',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.2) : Colors.green[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tips_and_updates,
                          color: widget.isDarkMode ? Colors.green[300] : Colors.green[700],
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Mantén los precios del dólar y euro siempre visibles en tu pantalla principal',
                            style: TextStyle(
                              color: widget.isDarkMode ? Colors.green[200] : Colors.green[800],
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '¡Así podrás ver las tasas sin necesidad de abrir la app!',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    // Guardar que ya se mostró el diálogo
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('has_shown_welcome', true);
                    
                    // Cerrar diálogo
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                    
                    // Mostrar instrucciones del widget si es Android
                    if (Platform.isAndroid) {
                      await _showWidgetInstructions();
                    }
                  },
                  child: Text(
                    '¡Entendido!',
                    style: TextStyle(
                      color: widget.isDarkMode ? Colors.green[300] : Colors.green[700],
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      debugPrint("Error mostrando diálogo de bienvenida: $e");
    }
  }

  Widget _buildExpandableUsdtCard() {
  return AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeInOut,
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          widget.isDarkMode ? Colors.orange[900]! : Colors.orange[800]!,
          widget.isDarkMode ? Colors.orange[700]! : Colors.orange[600]!,
        ],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.3),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // CABECERA - Siempre visible
        GestureDetector(
          onTap: () {
            setState(() {
              _isUsdtExpanded = !_isUsdtExpanded;
            });
          },
          child: Container(
            padding: const EdgeInsets.all(25),
            child: Row(
              children: [
                // Ícono
                Icon(
                  Icons.currency_bitcoin,
                  size: 32,
                  color: Colors.white,
                ),
                const SizedBox(width: 15),
                
                // Título y subtítulo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'USDT (Binance)',
                        style: const TextStyle(
                          fontSize: 18,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isUsdtExpanded ? 'Toque para ocultar' : 'Toque para ver el precio',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Indicador de expansión
                Icon(
                  _isUsdtExpanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white,
                  size: 28,
                ),
                
                // Copiar (solo en cabecera)
                const SizedBox(width: 15),
                GestureDetector(
                  onTap: () => _copiarPrecio('USDT', _precioUsdt),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.content_copy,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // CONTENIDO DESPLEGABLE
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _isUsdtExpanded
              ? Container(
                  padding: const EdgeInsets.fromLTRB(25, 0, 25, 25),
                  child: Column(
                    children: [
                      // Línea divisoria
                      Container(
                        height: 1,
                        color: Colors.white.withOpacity(0.3),
                        margin: const EdgeInsets.only(bottom: 20),
                      ),
                      
                      // Precio principal
                      Text(
                        _precioUsdt,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              blurRadius: 10.0,
                              color: Colors.black45,
                              offset: Offset(2.0, 2.0),
                            ),
                          ],
                        ),
                      ),
                      
                      // Multiplicador
                      if (_calcularMultiplicador(_usdtValue) != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _calcularMultiplicador(_usdtValue)!,
                            style: const TextStyle(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                      
                      // Advertencia legal
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            // Ícono de advertencia
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.warning_amber,
                                  color: Colors.orange[300],
                                  size: 24,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'IMPORTANTE',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.orange[300],
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            
                            const SizedBox(height: 12),
                            
                            // Texto de advertencia
                            Text(
                              'Este precio corresponde al mercado P2P de Binance y NO es el tipo de cambio oficial del BCV.',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.9),
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            
                            const SizedBox(height: 10),
                            
                            // Texto adicional
                            Text(
                              'Es un precio informativo basado en la oferta y demanda de la Cotización en plataformas de intercambio. Úsalo solo como referencia.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withOpacity(0.7),
                                fontStyle: FontStyle.italic,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            
                            // Botón para cerrar
                            const SizedBox(height: 15),
                            ElevatedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _isUsdtExpanded = false;
                                });
                              },
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Entendido'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange.withOpacity(0.8),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      // Botones de acción
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _copiarPrecio('USDT', _precioUsdt),
                              icon: const Icon(Icons.content_copy, size: 18),
                              label: const Text('Copiar'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white.withOpacity(0.2),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                // Acción para más información
                                _showUsdtInfoDialog();
                              },
                              icon: const Icon(Icons.info_outline, size: 18),
                              label: const Text('Más info'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue.withOpacity(0.8),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

void _showUsdtInfoDialog() {
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            Icon(
              Icons.currency_bitcoin,
              color: widget.isDarkMode ? Colors.orange[300] : Colors.orange[700],
            ),
            const SizedBox(width: 10),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '¿Qué es USDT?',
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'USDT (Tether) es una criptomoneda estable (stablecoin) vinculada al dólar.',
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                ),
              ),
              
              const SizedBox(height: 16),
              
              Text(
                '¿Cómo se obtiene este precio?',
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Se extrae automáticamente de la plataforma Binance P2P (peer-to-peer), que es un mercado donde los usuarios intercambian directamente.',
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                ),
              ),
              
              const SizedBox(height: 16),
              
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.isDarkMode ? Colors.orange[900]!.withOpacity(0.2) : Colors.orange[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.isDarkMode ? Colors.orange : Colors.orange[300]!,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 18,
                          color: widget.isDarkMode ? Colors.orange[300] : Colors.orange[700],
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Aviso legal importante',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.orange[300] : Colors.orange[700],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Este precio NO es el tipo de cambio oficial del BCV. '
                      'Es un precio de referencia de la Cotización en plataformas de intercambio que puede variar significativamente.',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.orange[200] : Colors.orange[800],
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cerrar',
              style: TextStyle(
                color: widget.isDarkMode ? Colors.orange[300] : Colors.orange[700],
              ),
            ),
          ),
        ],
      );
    },
  );
}

  // Mostrar instrucciones para agregar el widget (solo Android)
  Future<void> _showWidgetInstructions() async {
    await Future.delayed(const Duration(milliseconds: 500)); // Pequeña pausa
    
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.phone_android,
                  color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                ),
                const SizedBox(width: 10),
                Text(
                  '¿Cómo agregar el widget?',
                  style: TextStyle(
                      color: widget.isDarkMode ? Colors.white70 : Colors.grey[700],
                      fontSize: 14  ,
                      fontWeight: FontWeight.w400,
                    ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInstructionStep(
                    '1. Ve a tu pantalla de inicio',
                    'Mantén presionada un área vacía',
                  ),
                  const SizedBox(height: 10),
                  _buildInstructionStep(
                    '2. Toca "Widgets" o "Aplicaciones"',
                    'Busca "Cambio Dolar BCV"',
                  ),
                  const SizedBox(height: 10),
                  _buildInstructionStep(
                    '3. Arrástralo a tu pantalla',
                    'Escoge el tamaño que prefieras',
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[900]!.withOpacity(0.2) : Colors.blue[50],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: widget.isDarkMode ? Colors.blue[700]! : Colors.blue[300]!,
                      ),
                    ),
                    child: Text(
                      '💡 Consejo: El widget se actualiza automáticamente cada vez que abres la app',
                      style: TextStyle(
                        color: widget.isDarkMode ? Colors.blue[200] : Colors.blue[800],
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: Text(
                  'Cerrar',
                  style: TextStyle(
                    color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // Mostrar snackbar confirmando
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('¡Disfruta de tu widget! Los precios se actualizan automáticamente'),
                      backgroundColor: Colors.green,
                      duration: const Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.all(20),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.isDarkMode ? Colors.blue[700] : Colors.blue,
                  foregroundColor: Colors.white,
                ),
                child: const Text('¡Listo!'),
              ),
            ],
          );
        },
      );
    }
  }

  Widget _buildInstructionStep(String title, String description) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? Colors.grey[800]!.withOpacity(0.5) : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white : Colors.black87,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(
              color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSettings() async {
    try {
      final isEnabled = await LocalStorage.getBackgroundServiceEnabled();
      final interval = await LocalStorage.getNotificationInterval();
      
      setState(() {
        _backgroundServiceEnabled = isEnabled;
        _notificationInterval = interval;
      });
    } catch (e) {
      debugPrint("Error cargando configuración: $e");
    }
  }

  void _onUSDChanged() {
  if (_isConvertingBS) return;
  
  final text = _usdController.text.replaceAll('.', '').replaceAll(',', '.');
  final value = double.tryParse(text);
  
  if (value != null) {
    final rate = _getActiveRate(); // ✅ Usar tasa activa (dólar o euro)
    if (rate != null && rate > 0) {
      _isConvertingUSD = true;
      final converted = value * rate;
      _bsController.text = _formatConverterNumber(converted);
      _isConvertingUSD = false;
    }
  }
}

  void _onBSChanged() {
    if (_isConvertingUSD || _dolarValue == null) return;
    
    final text = _bsController.text.replaceAll('.', '').replaceAll(',', '.');
    final value = double.tryParse(text);
    
    if (value != null && value >= 0) {
      _isConvertingBS = true;
      final converted = value / _dolarValue!;
      _usdController.text = _formatConverterNumber(converted);
      _isConvertingBS = false;
    } else if (_bsController.text.isEmpty) {
      _isConvertingBS = true;
      _usdController.clear();
      _isConvertingBS = false;
    }
  }
  

  Future<void> _checkBackgroundServiceStatus() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _backgroundServiceEnabled = prefs.getBool('background_service_enabled') ?? true;
    });
  }

   Future<void> _toggleBackgroundService(bool value) async {
    setState(() {
      _backgroundServiceEnabled = value;
    });
    
    await LocalStorage.saveBackgroundServiceEnabled(value);
    
    if (value) {
      // Si se activa, usar el intervalo actual
      await _registerBackgroundTask(_notificationInterval);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Monitoreo activado (cada $_notificationInterval min)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      // Si se desactiva, detener el servicio
      await stopBackgroundService();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('🛑 Monitoreo desactivado'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _updateNotificationInterval(int minutes) async {
    setState(() {
      _notificationInterval = minutes;
    });
    
    await LocalStorage.saveNotificationInterval(minutes);
    
    // Si el servicio está activo, reiniciarlo con el nuevo intervalo
    if (_backgroundServiceEnabled) {
      await _registerBackgroundTask(minutes);
      if (context.mounted && minutes > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Intervalo actualizado a $minutes minutos'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _registerBackgroundTask(int intervalMinutes) async {
    try {
      // Cancelar tareas existentes primero
      await Workmanager().cancelAll();
      
      // Si el intervalo es 0, no registrar tarea
      if (intervalMinutes == 0) return;
      
      final constraints = Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      );
      
      if (Platform.isAndroid) {
        await Workmanager().registerPeriodicTask(
          "backgroundTask_${DateTime.now().millisecondsSinceEpoch}",
          backgroundTaskName,
          frequency: Duration(minutes: intervalMinutes),
          initialDelay: Duration(minutes: 1),
          constraints: constraints,
          inputData: {
            'type': 'background_update',
            'interval': intervalMinutes,
          },
        );
        debugPrint("✅ Tarea registrada para Android - Intervalo: $intervalMinutes minutos");
      } else if (Platform.isIOS) {
        await Workmanager().registerPeriodicTask(
          "backgroundTask",
          backgroundTaskName,
          frequency: Duration(minutes: intervalMinutes),
          initialDelay: const Duration(seconds: 10),
          constraints: constraints,
        );
        debugPrint("✅ Tarea registrada para iOS - Intervalo: $intervalMinutes minutos");
      }
    } catch (e) {
      debugPrint("❌ Error registrando tarea: $e");
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          isDarkMode: widget.isDarkMode,
          onServiceToggle: _toggleBackgroundService,
          onIntervalChanged: _updateNotificationInterval,
        ),
      ),
    );
  }
  // Nuevo método para inicializar precios de forma ordenada
  Future<void> _initializePrices() async {
    // Primero cargar desde cache para mostrar algo inmediatamente
    await _loadCachedPrices();
    
    // Luego verificar precios actualizados en segundo plano
    _verificarPrecios();
  }

  @override
  void dispose() {
    // Remover THIS como observer
    WidgetsBinding.instance.removeObserver(this);
    
    _usdController.dispose();
    _bsController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('🔄 App reanudada - actualizando widget si es necesario');
      _updateWidgetOnResume();
    }
  }
  
  // Método asíncrono para actualizar el widget
  Future<void> _updateWidgetOnResume() async {
    try {
      final cache = await LocalStorage.getPriceCache();
      if (cache != null && cache['dolar'] != null && cache['euro'] != null) {
        print('📊 Datos en cache encontrados, actualizando widget...');
        await savePricesForWidget(cache['dolar'], cache['euro']);
      }
    } catch (e) {
      print('⚠️ Error en updateWidgetOnResume: $e');
    }
  }

  String _formatConverterNumber(double number) {
    if (number == 0) return '0';
    
    // Para números grandes, usar formato simplificado
    if (number >= 1000) {
      return number.toStringAsFixed(2).replaceAll('.', ',');
    }
    
    // Para números más pequeños, mostrar más decimales si es necesario
    String formatted;
    if (number == number.truncateToDouble()) {
      formatted = number.truncate().toString();
    } else {
      formatted = number.toStringAsFixed(4)
          .replaceAll(RegExp(r'0*$'), '')
          .replaceAll(RegExp(r'\.$'), '');
      if (formatted.endsWith('.')) {
        formatted = formatted.substring(0, formatted.length - 1);
      }
    }
    
    // Agregar separadores de miles
    final parts = formatted.split('.');
    String integerPart = parts[0];
    final decimalPart = parts.length > 1 ? ',${parts[1]}' : '';
    
    String newIntegerPart = '';
    for (int i = integerPart.length - 1, count = 0; i >= 0; i--) {
      if (count > 0 && count % 3 == 0) {
        newIntegerPart = '.$newIntegerPart';
      }
      newIntegerPart = integerPart[i] + newIntegerPart;
      count++;
    }
    
    return newIntegerPart + decimalPart;
  }

  // Cargar precios desde cache
  Future<void> _loadCachedPrices() async {
  try {
    final cache = await LocalStorage.getPriceCache();
    if (cache != null && cache['dolar'] != null && cache['euro'] != null) {
      setState(() {
        _dolarValue = cache['dolar'];
        _euroValue = cache['euro'];
        _usdtValue = cache['usdt'];
        _precioDolar = _formatearPrecio(_dolarValue!);
        _precioEuro = _formatearPrecio(_euroValue!);
        if (_usdtValue != null) {
          _precioUsdt = _formatearPrecio(_usdtValue!);
        }
        _ultimaVerificacion = 'Cache';
        // Solo marcamos como cache al cargar inicialmente
        _usingCachedData = true;
      });
      
      // Verificar si el cache es muy viejo (más de 1 hora)
      final timestamp = DateTime.parse(cache['timestamp']);
      final ahora = DateTime.now();
      final diferenciaHoras = ahora.difference(timestamp).inHours;
      
      if (diferenciaHoras >= 1) {
        // El cache es viejo, mostrar alerta especial
        setState(() {
          _usingCachedData = true;
        });
      }
    } else {
      setState(() {
        _precioDolar = 'Esperando datos...';
        _precioEuro = 'Esperando datos...';
      });
    }
  } catch (e) {
    print('Error cargando cache: $e');
    setState(() {
      _precioDolar = 'Error cache';
      _precioEuro = 'Error cache';
      _precioUsdt = 'Error cache';
    });
  }
}

Future<void> _verificarPrecios() async {
  if (_isLoading) return;
  
  setState(() {
    _isLoading = true;
  });

  try {
    final dolar = await BcvService.getDolarPrice();
    final euro = await BcvService.getEuroPrice();
    final usdt = await BinanceService.getUsdtPrice();
    
    final now = DateTime.now();
    
    bool dolarObtenido = dolar != null;
    bool euroObtenido = euro != null;
    bool usdtObtenido = usdt != null;
    
    setState(() {
      if (dolar != null) {
        _precioDolar = _formatearPrecio(dolar);
        _dolarValue = dolar;
      } else if (_dolarValue != null) {
        _precioDolar = _formatearPrecio(_dolarValue!);
      } else {
        _precioDolar = 'Error';
      }
      
      if (euro != null) {
        _precioEuro = _formatearPrecio(euro);
        _euroValue = euro;
      } else if (_euroValue != null) {
        _precioEuro = _formatearPrecio(_euroValue!);
      } else {
        _precioEuro = 'Error';
      }

      if (usdt != null) {
        _precioUsdt = _formatearPrecio(usdt);
        _usdtValue = usdt;
      } else if (_usdtValue != null) {
        _precioUsdt = _formatearPrecio(_usdtValue!);
      } else {
        _precioUsdt = 'Error';
      }
      
      _ultimaVerificacion = '${now.hour}:${now.minute.toString().padLeft(2, '0')}';
      _usingCachedData = !(dolarObtenido || euroObtenido || usdtObtenido);
    });

    // Guardar en cache e historial si los precios son válidos
    if (dolar != null && euro != null) {
      await LocalStorage.savePriceCache(dolar, euro, usdt);
      
      // ✅ GUARDAR PARA EL WIDGET
      await savePricesForWidget(dolar, euro);
      
      final history = ExchangeHistory(
        date: now,
        dolarPrice: dolar,
        euroPrice: euro,
        usdtPrice: usdt,
      );
      await LocalStorage.saveToHistory(history);

      await _showLocalNotification(dolar, euro, usdt);
    }
    
  } catch (e) {
    print('Error verificando precios: $e');
  } finally {
    setState(() {
      _isLoading = false;
    });
  }
}

// Nueva función para notificaciones locales
Future<void> _showLocalNotification(double dolar, double euro, double? usdt) async {
  try {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'dolar_local_channel',
      'Actualizaciones Manuales',
      channelDescription: 'Notificaciones cuando actualizas manualmente',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification_dolar'),
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    String usdtText = usdt != null 
        ? 'USDT: ${usdt.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
        : '';

    await notificationsPlugin.show(
      2,
      '✅ Precios Actualizados',
      'Dólar: ${dolar.toStringAsFixed(2).replaceAll('.', ',')} Bs.'
      'Euro: ${euro.toStringAsFixed(2).replaceAll('.', ',')} Bs.\n'
      '$usdtText'
      '🕒 Actualización manual',
      details,
    );
  } catch (e) {
    print('Error en notificación local: $e');
  }
}

  String _formatearPrecio(double precio) {
    return '${precio.toStringAsFixed(2).replaceAll('.', ',')} Bs.';
  }

  // Copiar precio individual al portapapeles
  void _copiarPrecio(String moneda, String precio) {
  String? multiplicador;
  String disclaimer = '';
  
  if (moneda == 'Dólar') {
    multiplicador = '1.00x';
  } else if (moneda == 'Euro') {
    multiplicador = _calcularMultiplicador(_euroValue);
  } else if (moneda == 'USDT') {
    multiplicador = _calcularMultiplicador(_usdtValue);
    disclaimer = '\n⚠️ PRECIO BINANCE - NO ES OFICIAL';
  }
  
  final texto = '💱 **Monitor Dólar BCV**\n\n'
      '💰 $moneda: $precio\n'
      '${multiplicador != null ? '📊 Multiplicador: $multiplicador (vs Dólar BCV)\n' : ''}'
      '$disclaimer\n'
      '🕐 Actualizado: $_ultimaVerificacion\n\n'
      '¡Mantente informado con la app más confiable!';
  
  FlutterClipboard.copy(texto).then((_) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Precio del $moneda copiado${moneda == "USDT" ? " (con advertencia)" : ""}'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  });
}

  void _compartirPrecios() {
  final multiplicadorEuro = _calcularMultiplicador(_euroValue);
  final multiplicadorUsdt = _calcularMultiplicador(_usdtValue);
  
  final texto = '💱 **Cambio Dolar BCV**\n\n'
      '💰 Dólar: $_precioDolar (1.00x)\n'
      '💶 Euro: $_precioEuro ${multiplicadorEuro != null ? "($multiplicadorEuro)" : ""}\n'
      '💎 USDT: $_precioUsdt ${multiplicadorUsdt != null ? "($multiplicadorUsdt)" : ""}\n'
      '🕐 Actualizado: $_ultimaVerificacion\n\n'
      '📊 *Multiplicadores comparados con el Dólar BCV*\n\n'
      '📲 ¡Descarga la app para estar siempre informado sobre las tasas de cambio en Venezuela!\n\n'
      '✨ Características:\n'
      '• Monitoreo en tiempo real\n'
      '• Calculadora integrada\n'
      '• Historial de precios\n'
      '• Modo oscuro/claro\n'
      '• Funciona sin conexión\n\n';
  
  Share.share(texto);
}

  // Abrir historial
  void _abrirHistorial() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => HistoryScreen(isDarkMode: widget.isDarkMode),
      ),
    );
  }

  void _abrirCalculadora() {
    // Verificar que tenemos los precios antes de abrir la calculadora
    if (_dolarValue == null || _euroValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Esperando precios del dólar y euro...'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CalculatorScreen(
          dolarPrice: _dolarValue,
          euroPrice: _euroValue,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    );
  }

  Widget _buildCurrencyConverter() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.currency_exchange,
                    color: widget.isDarkMode ? Colors.green : Colors.green[700]),
                const SizedBox(width: 8),
                Text(
                  'Conversor Instantáneo',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Casilla USD/EUR
            Text(
              _useDollar ? 'Dólares (USD)' : 'Euros (EUR)',
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: widget.isDarkMode ? const Color(0xFF2D2D2D) : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.isDarkMode ? Colors.blue[700]! : Colors.blue[300]!,
                ),
              ),
              child: TextField(
                controller: _usdController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  if (_isConvertingBS) return;
                  final amount = _parseNumber(value);
                  final r = _getActiveRate();
                  if (amount != null && r != null && r > 0) {
                    _isConvertingUSD = true;
                    final bs = amount * r;
                    _setTextSafe(_bsController, _formatConverterNumber(bs));
                    _isConvertingUSD = false;
                  } else if (value.isEmpty) {
                    _isConvertingUSD = true;
                    _setTextSafe(_bsController, '');
                    _isConvertingUSD = false;
                  }
                },
                decoration: InputDecoration(
                  hintText: '0,00',
                  hintStyle: TextStyle(
                    color: widget.isDarkMode ? Colors.white38 : Colors.grey[400],
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  prefixIcon: Icon(
                    _useDollar ? Icons.attach_money : Icons.euro,
                    color: widget.isDarkMode ? Colors.blue[300] : Colors.blue,
                    size: 20,
                  ),
                ),
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            // Casilla Bolívares
            Text(
              'Bolívares (Bs.)',
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: widget.isDarkMode ? const Color(0xFF2D2D2D) : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.isDarkMode ? Colors.green[700]! : Colors.green[300]!,
                ),
              ),
              child: TextField(
                controller: _bsController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  if (_isConvertingUSD) return;
                  final amount = _parseNumber(value);
                  final r = _getActiveRate();
                  if (amount != null && r != null && r > 0) {
                    _isConvertingBS = true;
                    final unit = amount / r;
                    _setTextSafe(_usdController, _formatConverterNumber(unit));
                    _isConvertingBS = false;
                  } else if (value.isEmpty) {
                    _isConvertingBS = true;
                    _setTextSafe(_usdController, '');
                    _isConvertingBS = false;
                  }
                },
                decoration: InputDecoration(
                  hintText: '0,00',
                  hintStyle: TextStyle(
                    color: widget.isDarkMode ? Colors.white38 : Colors.grey[400],
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  prefixIcon: Icon(
                    Icons.paid,
                    color: widget.isDarkMode ? Colors.green[300] : Colors.green,
                    size: 20,
                  ),
                ),
                style: TextStyle(
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Botones de copiar
                ElevatedButton.icon(
                  onPressed: () {
                    final text = _usdController.text;
                    if (text.isNotEmpty) {
                      FlutterClipboard.copy(text);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Valor en ${_useDollar ? "USD" : "EUR"} copiado: $text')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: Text(" ${_useDollar ? "USD" : "EUR"}"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.isDarkMode ? Colors.blue[700] : Colors.blue[300],
                    foregroundColor: Colors.white,
                  ),
                ),

                // Botón de intercambio
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _useDollar = !_useDollar;
                      final amount = _parseNumber(_usdController.text);
                      final rate = _getActiveRate();
                      if (amount != null && rate != null && rate > 0) {
                        _bsController.text = _formatConverterNumber(amount * rate);
                      }
                    });
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom:14),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.blue[800] : Colors.blue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.swap_horiz, color: Colors.white, size: 28),
                  ),
                ),  
                ElevatedButton.icon(
                  onPressed: () {
                    final text = _bsController.text;
                    if (text.isNotEmpty) {
                      FlutterClipboard.copy(text);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Valor en Bs. copiado: $text')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text("Bs."),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.isDarkMode ? Colors.green[700] : Colors.green[300],
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Cambio Dolar BCV',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        backgroundColor: widget.isDarkMode 
      ? const Color(0xFF0F4C5C)  // Verde oscuro para modo oscuro
      : const Color(0xFF2A6B97), // Verde para modo claro
  elevation: 0,
  iconTheme: IconThemeData(
    color: widget.isDarkMode ? Colors.white : Colors.black87,
  ),
        actions: [
          IconButton(
            icon: Icon(
              widget.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: widget.isDarkMode ? Colors.amber : Colors.grey[800],
            ),
            onPressed: widget.toggleTheme,
            tooltip: widget.isDarkMode ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro',
          ),
          // En el AppBar de HomeScreen, reemplaza el IconButton actual por:
IconButton(
  icon: const Icon(Icons.settings),
  onPressed: () {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          isDarkMode: widget.isDarkMode,
          onServiceToggle: (value) {
            setState(() {
              _backgroundServiceEnabled = value;
            });
          },
          onIntervalChanged: (minutes) {
            setState(() {
              _notificationInterval = minutes;
            });
          },
        ),
      ),
    );
  },
  tooltip: 'Configuración',
),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: widget.isDarkMode
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF121212),
                    Color(0xFF1E1E1E),
                    Color(0xFF2D2D2D),
                  ],
                )
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.grey[100]!,
                    Colors.grey[200]!,
                    Colors.grey[300]!,
                  ],
                ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Indicador de datos en cache - SOLO cuando realmente hay fallo de conexión
              if (_usingCachedData) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode ? Colors.orange[900]!.withOpacity(0.3) : Colors.orange[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.isDarkMode ? Colors.orange : Colors.orange[300]!,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.wifi_off,
                        color: widget.isDarkMode ? Colors.orange : Colors.orange[700],
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mostrando datos de respaldo. Esto puede deberse a problemas de red o la página de BCV. Actualiza más tarde o cuando tengas conexión.',
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.orange[200] : Colors.orange[800],
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              

// En el método build de _HomeScreenState, reemplaza las tarjetas existentes con:
_buildPriceCard(
  'Precio del Dólar',
  _precioDolar,
  Icons.attach_money,
  widget.isDarkMode ? Colors.green[800]! : Colors.green[600]!,
  widget.isDarkMode ? Colors.green[600]! : Colors.green[400]!,
  'Dólar',
  multiplicador: '1.00x', // Dólar siempre es 1x
),
const SizedBox(height: 8),

_buildPriceCard(
  'Precio del Euro',
  _precioEuro,
  Icons.euro,
  widget.isDarkMode ? Colors.blue[800]! : Colors.blue[600]!,
  widget.isDarkMode ? Colors.blue[600]! : Colors.blue[400]!,
  'Euro',
  multiplicador: _calcularMultiplicador(_euroValue), // Euro comparado con dólar
),
const SizedBox(height: 8),

// Tarjeta desplegable de USDT
_buildExpandableUsdtCard(),
const SizedBox(height: 8),
              
              // Conversor Instantáneo
              _buildCurrencyConverter(),
              const SizedBox(height: 8),
              
              // Acciones Rápidas
              _buildActionButtons(),
              const SizedBox(height: 8),
              
              // Monitor Card
              _buildMonitorCard(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
  onPressed: _abrirCalculadora,
  backgroundColor: widget.isDarkMode 
      ? const Color(0xFF0F4C5C)  // Verde oscuro para modo oscuro
      : const Color(0xFF2A6B97), // Verde para modo claro
  foregroundColor: Colors.white,
  tooltip: 'Calculadora de conversión',
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  ),
  child: const Icon(Icons.calculate, size: 38),
),
    );
  }

  Widget _buildActionButtons() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.flash_on,
                  color: widget.isDarkMode ? Colors.amber : Colors.amber[700],
                ),
                const SizedBox(width: 8),
                Text(
                  'Acciones Rápidas',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
             
            const SizedBox(height: 12),
            // Botón Calculadora
            ElevatedButton.icon(
              onPressed: _abrirCalculadora,
              icon: const Icon(Icons.calculate, size: 24),
              label: const Text(
                'Calculadora',
                style: TextStyle(fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.isDarkMode ? const Color.fromARGB(255, 255, 132, 0) : const Color.fromARGB(255, 255, 123, 0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
            const SizedBox(height: 12),

            // Fila Copiar y Compartir
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final texto = '💱 **Cambio Dolar BCV**\n\n'
                          '💰 Dólar: $_precioDolar\n'
                          '💶 Euro: $_precioEuro\n'
                          '🕐 Actualizado: $_ultimaVerificacion\n\n'
                          '¡Mantente informado con la app más confiable!';
                      FlutterClipboard.copy(texto).then((_) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Todos los precios copiados'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      });
                    },
                    icon: const Icon(Icons.copy, size: 20),
                    label: const Text('Copiar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isDarkMode ? Colors.blue[800] : Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _compartirPrecios,
                    icon: const Icon(Icons.share, size: 20),
                    label: const Text('Compartir'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isDarkMode ? Colors.green[800] : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _calcularMultiplicador(double? precio) {
  if (_dolarValue == null || precio == null || _dolarValue! <= 0) {
    return null;
  }
  final multiplicador = precio / _dolarValue!;
  return '${multiplicador.toStringAsFixed(2)}x';
}

  Widget _buildPriceCard(
  String title, 
  String price, 
  IconData icon, 
  Color gradientStart, 
  Color gradientEnd, 
  String moneda,
  {String? multiplicador}
) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          gradientStart,
          gradientEnd,
        ],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.3),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Stack(
      children: [
        Card(
          elevation: 0,
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(25),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 28,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Text(
                  price,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        blurRadius: 10.0,
                        color: Colors.black45,
                        offset: Offset(2.0, 2.0),
                      ),
                    ],
                  ),
                ),
                // Mostrar multiplicador si está disponible
                if (multiplicador != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      multiplicador,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        
        // Botón de copiar en esquina superior derecha
        Positioned(
          top: 12,
          right: 12,
          child: GestureDetector(
            onTap: () => _copiarPrecio(moneda, price),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.content_copy,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

  Widget _buildMonitorCard() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.update,
                  color: widget.isDarkMode ? Colors.green : Colors.green[700],
                ),
                const SizedBox(width: 8),
                Text(
                  'Estado del Monitor',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: widget.isDarkMode ? Colors.green[900]!.withOpacity(0.2) : Colors.green[50],
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: widget.isDarkMode ? Colors.green : Colors.green[300]!,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Última verificación:',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: widget.isDarkMode ? Colors.white70 : Colors.grey[600],
                        ),
                      ),
                      if (_usingCachedData) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Usando datos de respaldo',
                          style: TextStyle(
                            fontSize: 12,
                            color: widget.isDarkMode ? Colors.orange[300] : Colors.orange[700],
                          ),
                        ),
                      ],
                    ],
                  ),
                  
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _getStatusColor(),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        if (_isLoading) ...[
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          _isLoading ? 'Actualizando...' : _ultimaVerificacion,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: _isLoading ? 10 : 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // BOTONES EN LA MISMA LÍNEA
            Row(
              children: [
                // Botón Verificar Ahora
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _verificarPrecios,
                    icon: Icon(
                      _isLoading ? Icons.hourglass_top : Icons.refresh,
                      color: Colors.white,
                      size: 20,
                    ),
                    label: Text(
                      _isLoading ? 'Actualizando...' : 'Verificar Ahora',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isDarkMode ? Colors.green[700] : Colors.green,
                      foregroundColor: Colors.white,
                      elevation: 3,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(width: 12),
                
                // Botón Historial de Tasas
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _abrirHistorial,
                    icon: const Icon(Icons.history, size: 20),
                    label: const Text(
                      'Historial de Tasas',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isDarkMode ? Colors.blue[800] : Colors.blue,
                      foregroundColor: Colors.white,
                      elevation: 3,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor() {
    if (_isLoading) {
      return widget.isDarkMode ? Colors.blue[800]! : Colors.blue;
    } else if (_usingCachedData) {
      return widget.isDarkMode ? Colors.orange[800]! : Colors.orange;
    } else {
      return widget.isDarkMode ? Colors.green[800]! : Colors.green;
    }
  }
} 