import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';

/// Loaded once at startup; null if the GPU/back-end can't compile it, in which
/// case [LiquidGlass] falls back to a plain frosted panel.
ui.FragmentProgram? glassProgram;
late AppConfig appConfig;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    glassProgram =
        await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
  } catch (_) {
    glassProgram = null; // graceful fallback (e.g. if Pi can't run the shader)
  }
  appConfig = await AppConfig.load();
  runApp(const SmartDisplayApp());
}

class SmartDisplayApp extends StatelessWidget {
  const SmartDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ConfigScope(
      config: appConfig,
      child: MaterialApp(
        title: 'Tuneout Display',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'SF Pro'),
        home: const RootShell(),
      ),
    );
  }
}

/// Exposes the shared animation clock so the background and every glass card
/// refract the *same* moment of the glow field.
class GlassClock extends InheritedWidget {
  final FrameClock clock;
  const GlassClock({super.key, required this.clock, required super.child});

  static FrameClock of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassClock>()!.clock;

  @override
  bool updateShouldNotify(GlassClock old) => clock != old.clock;
}

/// Drives all looping animation from a single timer at a capped frame rate,
/// instead of repainting every vsync (60 Hz). The motion is slow, so a lower
/// cap looks identical while roughly halving continuous GPU/shader work.
/// Bump [kTargetFps] back to 60 once the Pi has active cooling.
const int kTargetFps = 30;

class FrameClock extends ChangeNotifier {
  double value = 0;
  final double periodSeconds;
  Timer? _timer;
  FrameClock({this.periodSeconds = 24});

  void start() {
    final inc = (1.0 / kTargetFps) / periodSeconds;
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / kTargetFps).round()),
      (_) {
        value = (value + inc) % 1.0;
        notifyListeners();
      },
    );
  }

  void stop() => _timer?.cancel();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ── Location (Bally, PA) — will become user-configurable later ───────────────
const double kLat = 40.4015;
const double kLon = -75.5874;
const String kLocationLabel = 'Bally, PA';

const _weekdayFull = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _hourMinute(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')}';
}

String _hourMinuteAmPm(DateTime t) =>
    '${_hourMinute(t)} ${t.hour < 12 ? 'AM' : 'PM'}';

String _fullDate(DateTime t) =>
    '${_weekdayFull[t.weekday - 1]}, ${_monthFull[t.month - 1]} ${t.day}';

/// Rebuilds its [builder] every time the wall-clock minute changes.
class ClockText extends StatefulWidget {
  final Widget Function(BuildContext, DateTime) builder;
  const ClockText({super.key, required this.builder});

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final n = DateTime.now();
      if (n.minute != _now.minute || n.hour != _now.hour) {
        setState(() => _now = n);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}

class WeatherData {
  final int tempF;
  final int feelsF;
  final String condition;
  final String iconKind;
  final String wind; // e.g. "NE 7 mph"
  final bool ok;
  const WeatherData({
    required this.tempF,
    required this.feelsF,
    required this.condition,
    required this.iconKind,
    required this.wind,
    required this.ok,
  });
}

// Open-Meteo WMO weather codes → (condition, icon kind).
const Map<int, (String, String)> _weatherCodes = {
  0: ('Clear', 'sun'),
  1: ('Mostly clear', 'sun'),
  2: ('Partly cloudy', 'partly'),
  3: ('Cloudy', 'cloud'),
  45: ('Fog', 'fog'),
  48: ('Freezing fog', 'fog'),
  51: ('Light drizzle', 'rain'),
  53: ('Drizzle', 'rain'),
  55: ('Heavy drizzle', 'rain'),
  56: ('Freezing drizzle', 'rain'),
  57: ('Freezing drizzle', 'rain'),
  61: ('Light rain', 'rain'),
  63: ('Rain', 'rain'),
  65: ('Heavy rain', 'rain'),
  66: ('Freezing rain', 'rain'),
  67: ('Freezing rain', 'rain'),
  71: ('Light snow', 'snow'),
  73: ('Snow', 'snow'),
  75: ('Heavy snow', 'snow'),
  77: ('Snow grains', 'snow'),
  80: ('Rain showers', 'rain'),
  81: ('Rain showers', 'rain'),
  82: ('Heavy showers', 'rain'),
  85: ('Snow showers', 'snow'),
  86: ('Snow showers', 'snow'),
  95: ('Thunderstorms', 'storm'),
  96: ('Thunderstorms', 'storm'),
  99: ('Thunderstorms', 'storm'),
};

IconData weatherIcon(String kind) {
  switch (kind) {
    case 'sun':
      return Icons.wb_sunny_rounded;
    case 'partly':
      return Icons.wb_cloudy_rounded;
    case 'fog':
      return Icons.foggy;
    case 'rain':
      return Icons.water_drop_rounded;
    case 'snow':
      return Icons.ac_unit_rounded;
    case 'storm':
      return Icons.thunderstorm_rounded;
    default:
      return Icons.cloud_rounded;
  }
}

String _cardinal(num? deg) {
  if (deg == null) return '';
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return dirs[(((deg + 22.5) ~/ 45) % 8).toInt()];
}

/// Fetches current conditions from Open-Meteo and refreshes every 10 minutes.
class WeatherController extends ChangeNotifier {
  WeatherData? data;
  Timer? _timer;

  void start() {
    _fetch();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _fetch());
  }

  Future<void> _fetch() async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$kLat',
      'longitude': '$kLon',
      'current':
          'temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m',
      'temperature_unit': 'fahrenheit',
      'wind_speed_unit': 'mph',
      'timezone': 'auto',
    });
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final resp = await (await client.getUrl(uri)).close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      final cur = (jsonDecode(body) as Map<String, dynamic>)['current']
          as Map<String, dynamic>;
      final (condition, kind) =
          _weatherCodes[(cur['weather_code'] as num).toInt()] ??
              ('Current weather', 'cloud');
      final wind = [
        _cardinal(cur['wind_direction_10m'] as num?),
        '${(cur['wind_speed_10m'] as num).round()}',
        'mph',
      ].where((p) => p.isNotEmpty).join(' ');
      data = WeatherData(
        tempF: (cur['temperature_2m'] as num).round(),
        feelsF: (cur['apparent_temperature'] as num).round(),
        condition: condition,
        iconKind: kind,
        wind: wind,
        ok: true,
      );
    } catch (_) {
      data = const WeatherData(
        tempF: 0,
        feelsF: 0,
        condition: 'Weather unavailable',
        iconKind: 'cloud',
        wind: '',
        ok: false,
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class WeatherScope extends InheritedNotifier<WeatherController> {
  const WeatherScope({
    super.key,
    required WeatherController controller,
    required super.child,
  }) : super(notifier: controller);

  static WeatherController of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WeatherScope>()!
          .notifier!;
}

// ── Brightness schedule ──────────────────────────────────────────────────────
// Hard rule for now: 5% from 10 PM to 6 AM, full brightness otherwise.
// Writes the DSI backlight directly (the user is in the `video` group via the
// udev rule configure.sh installs). No-ops on machines without a backlight.
class BrightnessController {
  Timer? _timer;
  int? _lastPct;

  void start() {
    _apply();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _apply());
  }

  void stop() => _timer?.cancel();

  Future<void> _apply() async {
    final h = DateTime.now().hour;
    final pct = (h >= 22 || h < 6) ? 5 : 100;
    if (pct == _lastPct) return;
    _lastPct = pct;
    try {
      final dir = Directory('/sys/class/backlight');
      if (!dir.existsSync()) return;
      final lights = dir.listSync();
      if (lights.isEmpty) return;
      final bl = lights.first.path;
      final max = int.parse(
          (await File('$bl/max_brightness').readAsString()).trim());
      final val = (max * pct / 100).round().clamp(1, max);
      await File('$bl/brightness').writeAsString('$val');
    } catch (_) {/* no backlight / not permitted — ignore */}
  }
}

// ── Home Assistant ───────────────────────────────────────────────────────────
// REST for snapshots/service calls; the WebSocket (see EntityCatalog) keeps the
// entity list live. configure.sh writes the URL+token this client reads.
class HaClient {
  String? _url;
  String? _token;
  bool get ready => _url != null && _token != null;
  String? get token => _token;

  /// WebSocket endpoint derived from the REST URL (http→ws, https→wss).
  String? get wsUrl {
    final u = _url;
    if (u == null) return null;
    final ws = u.startsWith('https')
        ? u.replaceFirst('https', 'wss')
        : u.replaceFirst('http', 'ws');
    return '$ws/api/websocket';
  }

  /// Current still frame for a camera entity (works for any HA camera).
  Future<Uint8List?> cameraSnapshot(String entityId) async {
    if (!ready) return null;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final req =
          await client.getUrl(Uri.parse('$_url/api/camera_proxy/$entityId'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }
      final bytes = await consolidateHttpClientResponseBytes(resp);
      client.close();
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// All current entity states (snapshot).
  Future<List<Map<String, dynamic>>> states() async {
    if (!ready) return const [];
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse('$_url/api/states'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode != 200) return const [];
      return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> load() async {
    try {
      final home = Platform.environment['HOME'];
      final f = File('$home/.config/smart-display/ha.json');
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final url = (j['url'] as String?)?.trim();
      final token = (j['token'] as String?)?.trim();
      if (url != null && url.isNotEmpty && token != null && token.isNotEmpty) {
        _url = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
        _token = token;
      }
    } catch (_) {/* leave unconfigured */}
  }

  Future<Map<String, dynamic>?> state(String entityId) async {
    if (!ready) return null;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse('$_url/api/states/$entityId'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode != 200) return null;
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> callService(
      String domain, String service, String entityId) async {
    if (!ready) return false;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final req =
          await client.postUrl(Uri.parse('$_url/api/services/$domain/$service'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'entity_id': entityId})));
      final resp = await req.close();
      await resp.drain<void>(null);
      client.close();
      return resp.statusCode == 200 || resp.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}

class HaScope extends InheritedWidget {
  final HaClient client;
  const HaScope({super.key, required this.client, required super.child});

  static HaClient of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HaScope>()!.client;

  @override
  bool updateShouldNotify(HaScope old) => client != old.client;
}

/// Background-maintained catalog of all HA entities. Loads a REST snapshot then
/// keeps itself current over the HA WebSocket: `state_changed` updates live
/// values, `entity_registry_updated` (a device/entity added or removed) refreshes
/// the full list. Reconnects automatically. No UI side effects — this is the
/// data layer the edit/layout mode reads from.
class EntityCatalog extends ChangeNotifier {
  final Map<String, Map<String, dynamic>> _entities = {};
  HaClient? _ha;
  WebSocket? _ws;
  int _msgId = 1;
  bool _configured = false;
  bool _connected = false;
  bool _disposed = false;

  bool get configured => _configured;
  bool get connected => _connected;
  int get count => _entities.length;
  Map<String, dynamic>? state(String entityId) => _entities[entityId];
  List<MapEntry<String, Map<String, dynamic>>> get all =>
      _entities.entries.toList();

  Future<void> start(HaClient ha) async {
    _ha = ha;
    _configured = ha.ready;
    notifyListeners();
    if (!ha.ready) return;
    await _snapshot();
    _connect();
  }

  Future<void> _snapshot() async {
    final list = await _ha!.states();
    _entities
      ..clear()
      ..addEntries(list
          .where((e) => e['entity_id'] is String)
          .map((e) => MapEntry(e['entity_id'] as String, e)));
    notifyListeners();
  }

  Future<void> _connect() async {
    final url = _ha?.wsUrl;
    if (url == null || _disposed) return;
    try {
      _ws = await WebSocket.connect(url);
      _ws!.listen(_onMessage,
          onDone: _onDisconnect,
          onError: (_) => _onDisconnect(),
          cancelOnError: true);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _send(Map<String, dynamic> m) => _ws?.add(jsonEncode(m));

  void _onMessage(dynamic raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'auth_required':
        _send({'type': 'auth', 'access_token': _ha!.token});
      case 'auth_ok':
        _connected = true;
        notifyListeners();
        _send({
          'id': _msgId++,
          'type': 'subscribe_events',
          'event_type': 'state_changed'
        });
        _send({
          'id': _msgId++,
          'type': 'subscribe_events',
          'event_type': 'entity_registry_updated'
        });
      case 'auth_invalid':
        _connected = false;
        notifyListeners();
        _ws?.close();
      case 'event':
        final ev = m['event'] as Map<String, dynamic>?;
        final type = ev?['event_type'];
        if (type == 'state_changed') {
          final data = ev!['data'] as Map<String, dynamic>;
          final id = data['entity_id'] as String;
          final ns = data['new_state'];
          if (ns == null) {
            _entities.remove(id);
          } else {
            _entities[id] = ns as Map<String, dynamic>;
          }
          notifyListeners();
        } else if (type == 'entity_registry_updated') {
          _snapshot(); // device/entity added or removed → refresh the catalog
        }
    }
  }

  void _onDisconnect() {
    _connected = false;
    _ws = null;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !_configured) return;
    Timer(const Duration(seconds: 5), _connect);
  }

  Future<void> toggle(String entityId) =>
      _ha?.callService(entityId.split('.').first, 'toggle', entityId) ??
      Future.value(false).then((_) {});

  @override
  void dispose() {
    _disposed = true;
    _ws?.close();
    super.dispose();
  }
}

class EntityScope extends InheritedNotifier<EntityCatalog> {
  const EntityScope({
    super.key,
    required EntityCatalog catalog,
    required super.child,
  }) : super(notifier: catalog);

  static EntityCatalog of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EntityScope>()!.notifier!;
}

// ── User-customizable appearance (starter foundation) ────────────────────────
// Everything visible is intended to be config-driven so the UI can be restyled
// live in edit mode and persisted. This is the first slice; more properties
// (per-element layout, fonts, etc.) build on the same model.
enum BgType { glow, waves, solid }

enum CardStyle { liquidGlass, frosted, solid, outline }

class AppConfig extends ChangeNotifier {
  BgType bg;
  CardStyle cardStyle;
  double intensity; // glass refraction / frost blur amount
  double cornerRadius;
  Color accent;
  Color cardColor;
  Color bgColor;

  AppConfig({
    this.bg = BgType.glow,
    this.cardStyle = CardStyle.liquidGlass,
    this.intensity = 22,
    this.cornerRadius = 18,
    this.accent = const Color(0xFF2E7BFF),
    this.cardColor = const Color(0xFFFFFFFF),
    this.bgColor = const Color(0xFF06080F),
  });

  static File get _file =>
      File('${Platform.environment['HOME']}/.config/smart-display/theme.json');

  static Future<AppConfig> load() async {
    try {
      final f = _file;
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return AppConfig(
          bg: BgType.values[(j['bg'] as num?)?.toInt() ?? 0],
          cardStyle: CardStyle.values[(j['cardStyle'] as num?)?.toInt() ?? 0],
          intensity: (j['intensity'] as num?)?.toDouble() ?? 22,
          cornerRadius: (j['cornerRadius'] as num?)?.toDouble() ?? 18,
          accent: Color((j['accent'] as num?)?.toInt() ?? 0xFF2E7BFF),
          cardColor: Color((j['cardColor'] as num?)?.toInt() ?? 0xFFFFFFFF),
          bgColor: Color((j['bgColor'] as num?)?.toInt() ?? 0xFF06080F),
        );
      }
    } catch (_) {/* fall back to defaults */}
    return AppConfig();
  }

  Future<void> save() async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'bg': bg.index,
        'cardStyle': cardStyle.index,
        'intensity': intensity,
        'cornerRadius': cornerRadius,
        'accent': accent.toARGB32(),
        'cardColor': cardColor.toARGB32(),
        'bgColor': bgColor.toARGB32(),
      }));
    } catch (_) {/* ignore write errors */}
  }

  /// Mutate, notify listeners, and persist in one step.
  void update(VoidCallback change) {
    change();
    notifyListeners();
    save();
  }
}

class ConfigScope extends InheritedNotifier<AppConfig> {
  const ConfigScope({
    super.key,
    required AppConfig config,
    required super.child,
  }) : super(notifier: config);

  static AppConfig of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConfigScope>()!.notifier!;
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // Idle screensaver: fade in after this much inactivity; any touch wakes it.
  static const _idleAfter = Duration(minutes: 3);
  static const _fade = Duration(milliseconds: 700);

  final FrameClock _clock = FrameClock();
  final BgTexture _bgTex = BgTexture();
  final WeatherController _weather = WeatherController();
  final HaClient _ha = HaClient();
  final EntityCatalog _catalog = EntityCatalog();
  final BrightnessController _brightness = BrightnessController();
  Timer? _idleTimer;
  bool _idle = false;
  bool _editing = false;
  double _dragStartY = 0;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _weather.start();
    _ha.load().then((_) {
      if (mounted) _catalog.start(_ha);
    });
    _brightness.start();
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _brightness.stop();
    _catalog.dispose();
    _weather.dispose();
    _clock.dispose();
    _bgTex.image?.dispose();
    super.dispose();
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleAfter, () {
      if (mounted) setState(() => _idle = true);
    });
  }

  void _onActivity(PointerEvent _) {
    if (_idle) setState(() => _idle = false);
    if (!_editing) _resetIdleTimer();
  }

  void _openEdit() {
    _idleTimer?.cancel(); // don't fall asleep while customizing
    setState(() {
      _idle = false;
      _editing = true;
    });
  }

  void _closeEdit() {
    setState(() => _editing = false);
    _resetIdleTimer();
  }

  // Swipe up from the bottom edge → enter edit mode. Swipe down → exit.
  void _onVerticalDragEnd(DragEndDetails d) {
    final h = MediaQuery.sizeOf(context).height;
    final v = d.primaryVelocity ?? 0;
    if (!_editing && v < -300 && _dragStartY > h * 0.6) {
      _openEdit();
    } else if (_editing && v > 300) {
      _closeEdit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return HaScope(
      client: _ha,
      child: EntityScope(
      catalog: _catalog,
      child: WeatherScope(
      controller: _weather,
      child: GlassClock(
      clock: _clock,
      child: BgTextureScope(
      holder: _bgTex,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onActivity,
        onPointerMove: _onActivity,
        child: MouseRegion(
          cursor: SystemMouseCursors.none,
          child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (d) => _dragStartY = d.globalPosition.dy,
          onVerticalDragEnd: _onVerticalDragEnd,
          child: Scaffold(
          backgroundColor: const Color(0xFF06080F),
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ConfiguredBackground(),
              // Active UI and idle screen cross-fade over the shared
              // background — no hard cut, just a soft dissolve.
              IgnorePointer(
                ignoring: _idle,
                child: AnimatedOpacity(
                  opacity: _idle ? 0 : 1,
                  duration: _fade,
                  curve: Curves.easeInOut,
                  child: const DashboardScreen(),
                ),
              ),
              IgnorePointer(
                ignoring: !_idle,
                child: AnimatedOpacity(
                  opacity: _idle ? 1 : 0,
                  duration: _fade,
                  curve: Curves.easeInOut,
                  child: const IdleScreen(),
                ),
              ),
              // Edit-mode panel slides up from the bottom.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: _editing ? 0 : -600,
                child: EditPanel(onClose: _closeEdit),
              ),
            ],
          ),
        ),
        ),
        ),
      ),
      ),
      ),
      ),
      ),
    );
  }
}

class IdleScreen extends StatelessWidget {
  const IdleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Opaque wavy aurora background so the idle screen fully covers the
    // dashboard as it fades in.
    return Stack(
      fit: StackFit.expand,
      children: [
        const IdleBackground(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _IdleHeader(),
                Spacer(),
                _Clock(),
                Spacer(flex: 2),
                WeatherCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _IdleHeader extends StatelessWidget {
  const _IdleHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: const [
        Text(
          "JAKE'S ROOM",
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            color: Color(0xFF5FD0FF),
          ),
        ),
        MutedMic(),
      ],
    );
  }
}

class MutedMic extends StatelessWidget {
  const MutedMic({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x1AFF4D6A),
        boxShadow: const [BoxShadow(color: Color(0x33FF4D6A), blurRadius: 16)],
      ),
      child: const Icon(Icons.mic_off_rounded, color: Color(0xFFFF5C77), size: 26),
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock();

  @override
  Widget build(BuildContext context) {
    return ClockText(
      builder: (_, now) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _hourMinute(now),
            style: const TextStyle(
              fontSize: 130,
              fontWeight: FontWeight.w700,
              height: 1,
              letterSpacing: -3,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _fullDate(now),
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w400,
              color: Color(0xCCFFFFFF),
            ),
          ),
        ],
      ),
    );
  }
}

class WeatherCard extends StatelessWidget {
  const WeatherCard({super.key});

  @override
  Widget build(BuildContext context) {
    final w = WeatherScope.of(context).data;
    final tempStr = w == null ? '--°F' : '${w.tempF}°F';
    final condition = w?.condition ?? 'Loading…';
    final details = w == null
        ? kLocationLabel
        : (w.ok
            ? '$kLocationLabel   ·   Feels like ${w.feelsF}°F   ·   Wind ${w.wind}'
            : 'Check network or location settings.');
    return LiquidGlass(
      radius: 16,
      forceFrosted: true,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x3359D0FF), Color(0x1459D0FF)],
                ),
                border: Border.all(color: const Color(0x3359D0FF)),
              ),
              child: Icon(weatherIcon(w?.iconKind ?? 'cloud'),
                  color: const Color(0xFF8FE0FF), size: 34),
            ),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(tempStr,
                        style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    const SizedBox(width: 12),
                    Text(condition,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xE6FFFFFF))),
                  ],
                ),
                const SizedBox(height: 4),
                Text(details,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0x99FFFFFF))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolution-independent scale: everything sizes off the display width so the
/// same code looks right on this monitor and on the Pi's screen.
// Resolution-independent scale. Baselined so text is comfortably large on the
// Pi's display; clamps keep it sane on very small or very large screens.
double _scale(BuildContext c) =>
    (MediaQuery.sizeOf(c).width / 1100).clamp(0.9, 2.4);

const _weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _month = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
];

/// Swipe-first dashboard: no nav bar, just horizontally swipeable pages with a
/// small page indicator. Page 0 is the Overview; the rest are placeholders for
/// now (floors/energy/printer).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _pc = PageController();
  int _page = 0;

  static const _pages = <Widget>[
    OverviewPage(),
    FloorPage(title: 'First Floor', icon: Icons.home_rounded),
    FloorPage(title: 'Second Floor', icon: Icons.weekend_rounded),
    FloorPage(title: '3D Printer', icon: Icons.print_rounded),
  ];

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          PageView(
            controller: _pc,
            onPageChanged: (i) => setState(() => _page = i),
            children: _pages,
          ),
          Positioned(
            bottom: 14,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 20 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: active
                        ? ConfigScope.of(context).accent
                        : const Color(0x40FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(24 * s, 24 * s, 24 * s, 30 * s),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _LeftColumn()),
          SizedBox(width: 18),
          Expanded(flex: 5, child: _RightColumn()),
        ],
      ),
    );
  }
}

class FloorPage extends StatelessWidget {
  final String title;
  final IconData icon;
  const FloorPage({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return Padding(
      padding: EdgeInsets.all(24 * s),
      child: Center(
        child: LiquidGlass(
          radius: 22,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 48 * s, vertical: 40 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48 * s, color: const Color(0xCCFFFFFF)),
                SizedBox(height: 16 * s),
                Text(title,
                    style: TextStyle(
                        fontSize: 28 * s,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                SizedBox(height: 6 * s),
                Text('Coming soon',
                    style: TextStyle(
                        fontSize: 15 * s, color: const Color(0x99FFFFFF))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LeftColumn extends StatelessWidget {
  const _LeftColumn();

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _WeatherStrip(),
        SizedBox(height: 16 * s),
        const Expanded(child: CameraCard()),
        SizedBox(height: 16 * s),
        Row(
          children: [
            const Expanded(
              child: _ControlButton(icon: Icons.cast_rounded, label: 'Idle'),
            ),
            SizedBox(width: 16 * s),
            const Expanded(
              child: _ControlButton(
                  icon: Icons.volume_up_rounded,
                  label: 'Volume · 60%',
                  primary: true),
            ),
          ],
        ),
      ],
    );
  }
}

class _RightColumn extends StatelessWidget {
  const _RightColumn();

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(flex: 3, child: CalendarCard()),
        SizedBox(height: 16 * s),
        const Expanded(flex: 2, child: RoomCard()),
      ],
    );
  }
}

class _WeatherStrip extends StatelessWidget {
  const _WeatherStrip();

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final w = WeatherScope.of(context).data;
    final condTemp =
        w == null ? 'Loading…' : '${w.condition}  ·  ${w.tempF} °F';
    return LiquidGlass(
      radius: 18,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 16 * s),
        child: Row(
          children: [
            Icon(weatherIcon(w?.iconKind ?? 'cloud'),
                color: Colors.white, size: 34 * s),
            SizedBox(width: 18 * s),
            ClockText(
              builder: (_, now) {
                final date = '${_weekday[now.weekday - 1]}, '
                    '${now.month}/${now.day}/${now.year % 100}';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_hourMinuteAmPm(now),
                        style: TextStyle(
                            fontSize: 24 * s,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    Text('$date  ·  $condTemp',
                        style: TextStyle(
                            fontSize: 14 * s, color: const Color(0xB3FFFFFF))),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Universal camera tile: shows a periodically-refreshed snapshot from any HA
/// camera entity (via /api/camera_proxy). Cheap and codec-agnostic — the live
/// hardware-decoded stream is a future tap-to-focus mode. Camera stays more
/// solid than the glass cards (per the design direction).
class CameraCard extends StatefulWidget {
  const CameraCard({super.key});

  @override
  State<CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<CameraCard> {
  Timer? _timer;
  Uint8List? _frame;
  String? _name;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Auto-pick a camera entity — prefer a door/front camera, else the first one.
  String? _pickCamera(EntityCatalog cat) {
    String? first;
    for (final e in cat.all) {
      if (!e.key.startsWith('camera.')) continue;
      first ??= e.key;
      final fn =
          ((e.value['attributes'] as Map?)?['friendly_name'] as String? ?? e.key)
              .toLowerCase();
      if (e.key.contains('door') ||
          e.key.contains('front') ||
          fn.contains('door') ||
          fn.contains('front')) {
        return e.key;
      }
    }
    return first;
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final ha = HaScope.of(context);
    final cat = EntityScope.of(context);
    if (!ha.ready) return;
    final id = _pickCamera(cat);
    if (id == null) return;
    final bytes = await ha.cameraSnapshot(id);
    if (!mounted || bytes == null) return;
    setState(() {
      _frame = bytes;
      _name = (cat.state(id)?['attributes'] as Map?)?['friendly_name'] as String?;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final r = BorderRadius.circular(18);
    // RepaintBoundary keeps the camera its own layer — when the feed updates it
    // won't repaint the rest of the UI, and vice versa.
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1B2A3A), Color(0xFF0B131C)],
            ),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_frame != null)
                Image.memory(_frame!, fit: BoxFit.cover, gaplessPlayback: true)
              else
                Center(
                  child: Icon(Icons.videocam_rounded,
                      size: 64 * s, color: const Color(0x33FFFFFF)),
                ),
              Positioned(
                left: 12 * s,
                top: 10 * s,
                child: ClockText(
                  builder: (_, now) => Text(
                    '${now.year}-${now.month.toString().padLeft(2, '0')}-'
                    '${now.day.toString().padLeft(2, '0')}  ${_hourMinuteAmPm(now)}',
                    style: TextStyle(
                        fontSize: 12 * s,
                        color: const Color(0xCCFFFFFF),
                        shadows: const [Shadow(blurRadius: 4)]),
                  ),
                ),
              ),
              Positioned(
                bottom: 14 * s,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(_name ?? 'Front Door',
                      style: TextStyle(
                          fontSize: 22 * s,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          shadows: const [Shadow(blurRadius: 8)])),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  const _ControlButton(
      {required this.icon, required this.label, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final child = Padding(
      padding: EdgeInsets.symmetric(vertical: 16 * s),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20 * s, color: Colors.white),
          SizedBox(width: 10 * s),
          Text(label,
              style: TextStyle(
                  fontSize: 16 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
      ),
    );
    if (primary) {
      final accent = ConfigScope.of(context).accent;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [accent, Color.lerp(accent, Colors.black, 0.25)!],
          ),
          boxShadow: [
            BoxShadow(
                color: accent.withValues(alpha: 0.33),
                blurRadius: 18,
                offset: const Offset(0, 6)),
          ],
        ),
        child: child,
      );
    }
    return LiquidGlass(radius: 16, child: child);
  }
}

class CalendarCard extends StatelessWidget {
  const CalendarCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final now = DateTime.now();
    return LiquidGlass(
      radius: 20,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 8 * s),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(4, (i) {
            final d = now.add(Duration(days: i));
            return Row(
              children: [
                SizedBox(
                  width: 64 * s,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_weekday[d.weekday - 1],
                          style: TextStyle(
                              fontSize: 14 * s, color: const Color(0xB3FFFFFF))),
                      Text('${d.day}',
                          style: TextStyle(
                              fontSize: 30 * s,
                              fontWeight: FontWeight.w700,
                              height: 1,
                              color: Colors.white)),
                      Text(_month[d.month - 1],
                          style: TextStyle(
                              fontSize: 12 * s,
                              letterSpacing: 1,
                              color: const Color(0x99FFFFFF))),
                    ],
                  ),
                ),
                Container(
                  width: 3,
                  height: 46 * s,
                  margin: EdgeInsets.only(right: 18 * s),
                  decoration: BoxDecoration(
                    color: const Color(0xFF49C2FF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(Icons.check_rounded,
                    size: 18 * s, color: const Color(0x99FFFFFF)),
                SizedBox(width: 8 * s),
                Text('No upcoming events',
                    style: TextStyle(
                        fontSize: 17 * s, color: const Color(0xCCFFFFFF))),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// Live Home Assistant status, driven by the background [EntityCatalog]. Shows
/// connection state and how many entities are currently available to place.
/// Updates instantly as the catalog changes over the WebSocket.
class RoomCard extends StatelessWidget {
  const RoomCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final cat = EntityScope.of(context);

    final String status;
    final Color dot;
    if (!cat.configured) {
      status = 'Not configured';
      dot = const Color(0x99FFFFFF);
    } else if (cat.connected) {
      status = '${cat.count} entities available';
      dot = const Color(0xFF49E07A);
    } else {
      status = 'Connecting…';
      dot = const Color(0xFFE0A53B);
    }

    return LiquidGlass(
      radius: 20,
      child: Padding(
        padding: EdgeInsets.all(22 * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Home Assistant',
                    style: TextStyle(
                        fontSize: 22 * s,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                Container(
                  width: 12 * s,
                  height: 12 * s,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Icon(Icons.hub_rounded,
                    size: 20 * s, color: const Color(0x99FFFFFF)),
                SizedBox(width: 10 * s),
                Expanded(
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 15 * s, color: const Color(0xCCFFFFFF))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Real liquid-glass surface: a fragment shader refracts the live glow field at
/// the edges (clear centre, chromatic rim). Falls back to a frosted panel if
/// the shader couldn't be loaded.
class LiquidGlass extends StatefulWidget {
  final Widget child;
  final double? height;
  final double radius;
  final double thickness;

  /// Force the BackdropFilter frosted path instead of the glow-sampling shader.
  /// Used over backgrounds the shader doesn't know about (e.g. the idle waves),
  /// so the blur reflects what's actually behind the card.
  final bool forceFrosted;

  const LiquidGlass({
    super.key,
    required this.child,
    this.height,
    this.radius = 18,
    this.thickness = 16,
    this.forceFrosted = false,
  });

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  final _paintKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final cfg = ConfigScope.of(context);
    final radius = cfg.cornerRadius;
    final r = BorderRadius.circular(radius);

    // forceFrosted (idle weather card) always blurs the real background.
    var style = widget.forceFrosted ? CardStyle.frosted : cfg.cardStyle;
    if (style == CardStyle.liquidGlass && glassProgram == null) {
      style = CardStyle.frosted;
    }

    switch (style) {
      case CardStyle.liquidGlass:
        final clock = GlassClock.of(context);
        final screen = MediaQuery.sizeOf(context);
        return SizedBox(
          height: widget.height,
          child: CustomPaint(
            key: _paintKey,
            painter: _GlassPainter(
              program: glassProgram!,
              repaint: clock,
              holder: BgTextureScope.of(context),
              screen: screen,
              radius: radius,
              thickness: cfg.intensity,
              paintKey: _paintKey,
            ),
            // Isolate the card's content so it isn't re-rasterized every time
            // the shader repaints.
            child: RepaintBoundary(child: widget.child),
          ),
        );
      case CardStyle.frosted:
        return ClipRRect(
          borderRadius: r,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
                sigmaX: cfg.intensity, sigmaY: cfg.intensity),
            child: Container(
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: r,
                color: cfg.cardColor.withValues(alpha: 0.12),
                border: Border.all(color: const Color(0x26FFFFFF)),
              ),
              child: widget.child,
            ),
          ),
        );
      case CardStyle.solid:
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: r,
            color: cfg.cardColor.withValues(alpha: 0.92),
            border: Border.all(color: const Color(0x1FFFFFFF)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 16,
                  offset: Offset(0, 6)),
            ],
          ),
          child: widget.child,
        );
      case CardStyle.outline:
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: r,
            color: const Color(0x14FFFFFF),
            border: Border.all(
                color: cfg.cardColor.withValues(alpha: 0.75), width: 1.5),
          ),
          child: widget.child,
        );
    }
  }
}

class _GlassPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final BgTexture holder;
  final Size screen;
  final double radius;
  final double thickness;
  final GlobalKey paintKey;

  _GlassPainter({
    required this.program,
    required Listenable repaint,
    required this.holder,
    required this.screen,
    required this.radius,
    required this.thickness,
    required this.paintKey,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // The background painter (drawn earlier this frame) produced the snapshot.
    final tex = holder.image;
    if (tex == null) return;

    // Where this card currently sits on screen (tracks page-swipe motion).
    var offset = Offset.zero;
    final ctx = paintKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      offset = box.localToGlobal(Offset.zero);
    }

    final shader = program.fragmentShader();
    shader
      ..setFloat(0, screen.width)
      ..setFloat(1, screen.height)
      ..setFloat(2, offset.dx)
      ..setFloat(3, offset.dy)
      ..setFloat(4, size.width)
      ..setFloat(5, size.height)
      ..setFloat(6, radius)
      ..setFloat(7, thickness)
      ..setFloat(8, -2.0)
      ..setImageSampler(0, tex);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GlassPainter old) => true;
}

/// Idle-screen background: the flowing aurora waves + drifting stars ported
/// from the original idle-v13 screen, driven by the shared clock so the motion
/// wraps seamlessly.
class IdleBackground extends StatelessWidget {
  const IdleBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final clock = GlassClock.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ScenePainter(
            clock: clock, draw: (c, s) => paintWaves(c, s, clock.value)),
        size: Size.infinite,
      ),
    );
  }
}

/// Generic animated-scene painter: repaints on the [clock] and delegates the
/// actual drawing to [draw].
class _ScenePainter extends CustomPainter {
  final FrameClock clock;
  final void Function(Canvas, Size) draw;
  _ScenePainter({required this.clock, required this.draw}) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(covariant _ScenePainter old) => true;
}

// ── Background scenes (shared by the on-screen paint and the glass texture) ───

void paintGlow(Canvas canvas, Size size, double t) {
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF06080F));
  final tau = 2 * math.pi;
  void blob(Color color, double cx, double cy, double rad) {
    final center = Offset(cx * size.width, cy * size.height);
    canvas.drawCircle(
      center,
      rad,
      Paint()
        ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: rad)),
    );
  }

  blob(const Color(0x662E6BFF), 0.25 + 0.10 * math.sin(t * tau),
      0.30 + 0.06 * math.cos(t * tau), size.shortestSide * 0.7);
  blob(const Color(0x4DFF8A3D), 0.80 + 0.08 * math.cos(t * tau),
      0.70 + 0.07 * math.sin(t * tau), size.shortestSide * 0.6);
  blob(const Color(0x3322D3A8), 0.55 + 0.06 * math.sin(t * tau + 1.5),
      0.85 + 0.05 * math.cos(t * tau + 1.5), size.shortestSide * 0.5);
}

void paintWaves(Canvas canvas, Size size, double t) {
  final w = size.width, h = size.height;
  const tau = 2 * math.pi;
  const layers = [
    (0.18, 0.026, Color(0xFF0B2631)),
    (0.285, 0.036, Color(0xFF0D3144)),
    (0.39, 0.046, Color(0xFF08202E)),
  ];

  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF04080E), Color(0xFF0C1A2C)],
      ).createShader(Offset.zero & size),
  );

  for (var li = 0; li < layers.length; li++) {
    final (baseFrac, ampFrac, color) = layers[li];
    final baseY = h * baseFrac;
    final amp = h * ampFrac;
    final phase = t * tau * (li + 1);
    final path = Path();
    const n = 64;
    for (var i = 0; i <= n; i++) {
      final x = w * i / n;
      final y = baseY + math.sin(i * 0.82 * 9 / n + phase) * amp;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(12, h * 0.045)
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  final starMax = math.max(80, (h * 0.55).toInt());
  for (var i = 0; i < 12; i++) {
    final x = (i * 137 + t * w * 2) % w;
    final y = 35 + (i * 53) % starMax;
    final pulse = (math.sin(t * tau * 3 + i) + 1) / 2;
    final color =
        pulse < 0.65 ? const Color(0xFF173849) : const Color(0xFF24586B);
    canvas.drawCircle(
        Offset(x, y.toDouble()), i % 4 == 0 ? 2 : 1, Paint()..color = color);
  }
}

void paintSolid(Canvas canvas, Size size, Color top, Color bottom) {
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      ).createShader(Offset.zero & size),
  );
}

/// Live customization panel (entered by swiping up). Mutates [AppConfig], which
/// repaints the UI and persists immediately.
class EditPanel extends StatelessWidget {
  final VoidCallback onClose;
  const EditPanel({super.key, required this.onClose});

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(t,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xB3FFFFFF))),
      );

  @override
  Widget build(BuildContext context) {
    final cfg = ConfigScope.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 26),
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: const BoxDecoration(
        color: Color(0xF2121A24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                    color: const Color(0x40FFFFFF),
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Customize',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                TextButton(
                  onPressed: onClose,
                  child: Text('Done',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cfg.accent)),
                ),
              ],
            ),
            _label('Background'),
            _ChoiceRow<BgType>(
              values: BgType.values,
              selected: cfg.bg,
              labels: const ['Glow', 'Waves', 'Solid'],
              onSelect: (v) => cfg.update(() => cfg.bg = v),
            ),
            _label('Card style'),
            _ChoiceRow<CardStyle>(
              values: CardStyle.values,
              selected: cfg.cardStyle,
              labels: const ['Liquid Glass', 'Frosted', 'Solid', 'Outline'],
              onSelect: (v) => cfg.update(() => cfg.cardStyle = v),
            ),
            _label('Intensity'),
            Slider(
              value: cfg.intensity,
              activeColor: cfg.accent,
              max: 40,
              onChanged: (v) => cfg.update(() => cfg.intensity = v),
            ),
            _label('Corner radius'),
            Slider(
              value: cfg.cornerRadius,
              activeColor: cfg.accent,
              max: 44,
              onChanged: (v) => cfg.update(() => cfg.cornerRadius = v),
            ),
            _label('Accent color'),
            _SwatchRow(
                selected: cfg.accent,
                onSelect: (c) => cfg.update(() => cfg.accent = c)),
            _label('Card color / tint'),
            _SwatchRow(
                selected: cfg.cardColor,
                onSelect: (c) => cfg.update(() => cfg.cardColor = c)),
          ],
        ),
      ),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final List<String> labels;
  final ValueChanged<T> onSelect;
  const _ChoiceRow({
    required this.values,
    required this.selected,
    required this.labels,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(values.length, (i) {
        final sel = values[i] == selected;
        return GestureDetector(
          onTap: () => onSelect(values[i]),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Color(sel ? 0x33FFFFFF : 0x14FFFFFF),
              border: Border.all(color: Color(sel ? 0x80FFFFFF : 0x1FFFFFFF)),
            ),
            child: Text(labels[i],
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ),
        );
      }),
    );
  }
}

class _SwatchRow extends StatelessWidget {
  final Color selected;
  final ValueChanged<Color> onSelect;
  const _SwatchRow({required this.selected, required this.onSelect});

  static const _colors = [
    Color(0xFF2E7BFF), Color(0xFF49E07A), Color(0xFFFF8A3D), Color(0xFFE0533B),
    Color(0xFFB45CFF), Color(0xFF22D3A8), Color(0xFFFFFFFF), Color(0xFFE0A53B),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: _colors.map((c) {
        final sel = c.toARGB32() == selected.toARGB32();
        return GestureDetector(
          onTap: () => onSelect(c),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                  color: sel ? Colors.white : const Color(0x33FFFFFF),
                  width: sel ? 3 : 1),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Renders whichever background the user picked in edit mode.
/// Holds the latest low-res snapshot of the background for the glass shader to
/// sample. Shared (one instance) between the background painter that writes it
/// and the glass painters that read it within the same frame.
class BgTexture {
  ui.Image? image;
}

class BgTextureScope extends InheritedWidget {
  final BgTexture holder;
  const BgTextureScope({super.key, required this.holder, required super.child});

  static BgTexture of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BgTextureScope>()!.holder;

  @override
  bool updateShouldNotify(BgTextureScope old) => holder != old.holder;
}

/// Draws the chosen background to the screen AND renders a small snapshot of it
/// into [BgTexture] each frame, so the liquid-glass shader can refract it with a
/// cheap texture read instead of recomputing the whole field per pixel.
class ConfiguredBackground extends StatelessWidget {
  const ConfiguredBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BackgroundPainter(
        clock: GlassClock.of(context),
        cfg: ConfigScope.of(context),
        holder: BgTextureScope.of(context),
      ),
      size: Size.infinite,
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  final FrameClock clock;
  final AppConfig cfg;
  final BgTexture holder;
  _BackgroundPainter({
    required this.clock,
    required this.cfg,
    required this.holder,
  }) : super(repaint: clock);

  void _scene(Canvas canvas, Size size) {
    switch (cfg.bg) {
      case BgType.glow:
        paintGlow(canvas, size, clock.value);
      case BgType.waves:
        paintWaves(canvas, size, clock.value);
      case BgType.solid:
        paintSolid(canvas, size, cfg.bgColor,
            Color.lerp(cfg.bgColor, Colors.black, 0.45)!);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    _scene(canvas, size); // full-res, to the screen

    if (size.width <= 0 || size.height <= 0) return;
    // Low-res copy for the shader. The background is low-frequency, so a small
    // texture refracts identically while costing a texture read, not a recompute.
    const tw = 480;
    final th = (tw * size.height / size.width).round().clamp(1, 2160);
    final recorder = ui.PictureRecorder();
    final tc = Canvas(recorder)..scale(tw / size.width, th / size.height);
    _scene(tc, size);
    final img = recorder.endRecording().toImageSync(tw, th);
    holder.image?.dispose();
    holder.image = img;
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter old) => true;
}
