import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart'
    show consolidateHttpClientResponseBytes, visibleForTesting;
import 'package:flutter/gestures.dart'
    show LongPressGestureRecognizer, TapGestureRecognizer;
import 'package:flutter/material.dart';

// Dev-only on-host test harness (demo entity seed + auto-open more-info). Every
// hook is gated behind SMARTDISPLAY_* env vars that are never set on the Pi, so
// this is fully inert in production. See dev_harness.dart.
part 'dev_harness.dart';

/// Display name of the app. Placeholder/working title — change this one constant
/// to rebrand the window title everywhere.
const String kAppName = 'Smart Display';

/// Loaded once at startup; null if the GPU/back-end can't compile it, in which
/// case [LiquidGlass] falls back to a plain frosted panel.
ui.FragmentProgram? glassProgram;
late AppConfig appConfig;
late AppLayout appLayout;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    glassProgram =
        await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
  } catch (_) {
    glassProgram = null; // graceful fallback (e.g. if Pi can't run the shader)
  }
  appConfig = await AppConfig.load();
  appLayout = await AppLayout.load();
  runApp(const SmartDisplayApp());
}

class SmartDisplayApp extends StatelessWidget {
  const SmartDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ConfigScope(
      config: appConfig,
      child: LayoutScope(
        layout: appLayout,
        child: MaterialApp(
          title: kAppName,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: Brightness.dark, fontFamily: 'SF Pro'),
          home: const RootShell(),
        ),
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

  /// Tick continuously at [kTargetFps]. Paused (see [stop]) while the idle
  /// screensaver is showing, so nothing animates during the long idle hours.
  void start() {
    _timer?.cancel();
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

  /// Call a service. [data] carries optional parameters (brightness_pct,
  /// position, value, option, temperature, volume_level, hvac_mode, …) merged
  /// alongside the target entity_id.
  Future<bool> callService(String domain, String service, String entityId,
      [Map<String, dynamic>? data]) async {
    if (!ready) return false;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final req =
          await client.postUrl(Uri.parse('$_url/api/services/$domain/$service'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'entity_id': entityId, ...?data})));
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
    if (!ha.ready) {
      if (_maybeSeedDemo()) notifyListeners(); // dev-only, env-gated; no-op in prod
      return;
    }
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

/// The bottom-center "handle" rect a swipe-up-to-edit must BEGIN inside. Small
/// and centered so ordinary taps near the bottom never arm edit mode.
@visibleForTesting
Rect editHandleRect(Size size) {
  const handleHeight = 64.0;
  final handleWidth = size.width * 0.30;
  return Rect.fromLTWH(
      (size.width - handleWidth) / 2, size.height - handleHeight,
      handleWidth, handleHeight);
}

/// True once a press that began in [editHandleRect] has been dragged clearly
/// UPWARD (mostly-vertical) from [start] to [current] by at least [upThreshold]
/// px — the "swipe up" that arms the hold timer.
@visibleForTesting
bool editSwipeArmed(Offset start, Offset current, {double upThreshold = 48}) {
  final up = start.dy - current.dy; // positive = moved up
  final dx = (current.dx - start.dx).abs();
  return up >= upThreshold && dx < up; // upward and not a sideways drag
}

/// Faint home-bar pill hinting where to swipe up to enter edit mode.
class _EditHandleHint extends StatelessWidget {
  const _EditHandleHint();
  @override
  Widget build(BuildContext context) => Container(
        width: 120,
        height: 5,
        decoration: BoxDecoration(
          color: const Color(0x33FFFFFF),
          borderRadius: BorderRadius.circular(3),
        ),
      );
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
  bool _showTheme = false; // theme panel (gear) open over edit mode
  double _holdProgress = 0; // swipe-up-and-hold-to-edit progress (0..1)
  Timer? _holdTimer;
  // Edit-entry gesture: a press that began inside the bottom-center handle, and
  // whether it has since been swiped clearly upward (which arms the hold).
  Offset? _editGestureStart;
  bool _editArmed = false;

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
    _maybeAutoOpenMoreInfo(); // dev-only, env-gated; no-op in production
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _holdTimer?.cancel();
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
      if (!mounted) return;
      // Idle screen is static, so freeze the animation clock entirely — the
      // hidden dashboard stops animating too. Near-zero GPU during idle hours.
      // (The live time display runs on its own timer and keeps updating.)
      setState(() => _idle = true);
      _clock.stop();
    });
  }

  // Edit mode is entered with a deliberate swipe-up-and-hold from a small handle
  // at the bottom-center of the screen: press inside the handle, slide clearly
  // upward to arm, then hold ~2s while the radial ring fills. A plain press, a
  // sideways drag, or releasing early all cancel.
  void _onPointerDown(PointerDownEvent e) {
    _onActivity(e);
    if (_editing || _idle) return;
    if (editHandleRect(MediaQuery.sizeOf(context)).contains(e.position)) {
      _editGestureStart = e.position; // start tracking; arming happens on move
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    _onActivity(e);
    final start = _editGestureStart;
    if (start == null || _editing || _idle) return;
    if (!_editArmed) {
      if (editSwipeArmed(start, e.position)) {
        _editArmed = true;
        _startEditHold();
      }
    } else if (e.position.dy > start.dy) {
      _cancelHold(); // reversed back down past the origin
    }
  }

  void _startEditHold() {
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      setState(() => _holdProgress += 40 / 2000);
      if (_holdProgress >= 1) {
        t.cancel();
        setState(() => _holdProgress = 0);
        _editGestureStart = null;
        _editArmed = false;
        _openEdit();
      }
    });
  }

  void _cancelHold([_]) {
    _holdTimer?.cancel();
    _editGestureStart = null;
    _editArmed = false;
    if (_holdProgress != 0) setState(() => _holdProgress = 0);
  }

  void _onActivity(PointerEvent _) {
    if (_idle) {
      setState(() => _idle = false);
      _clock.start(); // resume dashboard animation on wake
    }
    if (!_editing) _resetIdleTimer();
  }

  void _openEdit() {
    _idleTimer?.cancel(); // don't fall asleep while editing
    setState(() {
      _idle = false;
      _editing = true;
    });
  }

  void _closeEdit() {
    setState(() {
      _editing = false;
      _showTheme = false;
    });
    _resetIdleTimer();
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
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _cancelHold,
        onPointerCancel: _cancelHold,
        child: MouseRegion(
          cursor: SystemMouseCursors.none,
          child: Scaffold(
          backgroundColor: const Color(0xFF06080F),
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ConfiguredBackground(),
              if (_editing)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(color: Color(0x55000000)),
                  ),
                ),
              // Active UI and idle screen cross-fade over the shared
              // background — no hard cut, just a soft dissolve.
              IgnorePointer(
                ignoring: _idle,
                child: AnimatedOpacity(
                  opacity: _idle ? 0 : 1,
                  duration: _fade,
                  curve: Curves.easeInOut,
                  child: DashboardScreen(editing: _editing),
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
              if (_editing)
                _EditBar(
                  onDone: _closeEdit,
                  onTheme: () => setState(() => _showTheme = true),
                ),
              // Theme panel (gear) slides up over edit mode.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: _showTheme ? 0 : -600,
                child: EditPanel(
                    onClose: () => setState(() => _showTheme = false)),
              ),
              // Subtle home-bar handle hinting where to swipe up to edit.
              if (!_idle && !_editing && _holdProgress == 0)
                const Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _EditHandleHint(),
                    ),
                  ),
                ),
              if (_holdProgress > 0)
                Positioned(
                  bottom: 60,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: CircularProgressIndicator(
                        value: _holdProgress,
                        strokeWidth: 4,
                        color: ConfigScope.of(context).accent,
                        backgroundColor: const Color(0x33FFFFFF),
                      ),
                    ),
                  ),
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
    );
  }
}

/// Edit-mode top bar: shows while the layout editor is active.
class _EditBar extends StatelessWidget {
  final VoidCallback onDone;
  final VoidCallback onTheme;
  const _EditBar({required this.onDone, required this.onTheme});

  Widget _round(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x33FFFFFF),
            border: Border.fromBorderSide(BorderSide(color: Color(0x40FFFFFF))),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accent = ConfigScope.of(context).accent;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Text('Editing',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
              const Spacer(),
              _round(Icons.palette_rounded, onTheme),
              const SizedBox(width: 10),
              _round(Icons.add_rounded, () => _showEntityPicker(context)),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: onDone,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  decoration: BoxDecoration(
                      color: accent, borderRadius: BorderRadius.circular(22)),
                  child: const Text('Done',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the entity picker. With no [onPick] it adds a new card; pass [onPick]
/// to rebind an existing card to the chosen entity instead.
/// In-app touchscreen keyboard. The Flutter Linux (GTK) embedder does not
/// summon a system on-screen keyboard, and the Pi kiosk has no physical one,
/// so text fields drive this widget instead. Operates on a [TextEditingController].
class OnScreenKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback? onDone;
  const OnScreenKeyboard({super.key, required this.controller, this.onDone});
  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  bool _shift = false;
  bool _sym = false;

  static const _letters = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _symbols = ['1234567890', '-_.@:/', '#%&*+,?!'];

  void _insert(String s) {
    final c = widget.controller;
    final out = _shift ? s.toUpperCase() : s;
    c.text = c.text + out;
    c.selection = TextSelection.collapsed(offset: c.text.length);
    if (_shift) setState(() => _shift = false);
  }

  void _backspace() {
    final c = widget.controller;
    if (c.text.isEmpty) return;
    c.text = c.text.substring(0, c.text.length - 1);
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  Widget _key(String label, VoidCallback onTap,
      {int flex = 1, Color? bg, Widget? child}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg ?? const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child ??
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500)),
          ),
        ),
      ),
    );
  }

  Widget _row(String chars) => Row(
        children: [for (final ch in chars.split('')) _key(_shift ? ch.toUpperCase() : ch, () => _insert(ch))],
      );

  @override
  Widget build(BuildContext context) {
    final accent = ConfigScope.of(context).accent;
    final rows = _sym ? _symbols : _letters;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      decoration: const BoxDecoration(color: Color(0xFF0C131C)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(rows[0]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _row(rows[1]),
          ),
          Row(
            children: [
              if (!_sym)
                _key('', () => setState(() => _shift = !_shift),
                    flex: 2,
                    bg: _shift ? accent : const Color(0x33FFFFFF),
                    child: const Icon(Icons.arrow_upward,
                        color: Colors.white, size: 20))
              else
                const Spacer(flex: 2),
              for (final ch in rows[2].split(''))
                _key(_shift ? ch.toUpperCase() : ch, () => _insert(ch)),
              _key('', _backspace,
                  flex: 2,
                  bg: const Color(0x33FFFFFF),
                  child: const Icon(Icons.backspace_outlined,
                      color: Colors.white, size: 20)),
            ],
          ),
          Row(
            children: [
              _key(_sym ? 'ABC' : '123', () => setState(() => _sym = !_sym),
                  flex: 3, bg: const Color(0x33FFFFFF)),
              _key('space', () => _insert(' '), flex: 6),
              _key('Done', () => widget.onDone?.call(),
                  flex: 3, bg: accent),
            ],
          ),
        ],
      ),
    );
  }
}

/// A focused text-entry sheet (label + field + on-screen keyboard). Used where
/// inline keyboard space is tight (e.g. the card editor name field).
void _showTextInput(BuildContext context,
    {required String title,
    required TextEditingController controller,
    required ValueChanged<String> onChanged}) {
  // The on-screen keyboard mutates the controller programmatically, which does
  // NOT trigger TextField.onChanged — so listen to the controller and detach
  // when the sheet closes.
  void listener() => onChanged(controller.text);
  controller.addListener(listener);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xF2121A24),
    builder: (sheetCtx) => ConfigScope(
      config: ConfigScope.of(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.viewInsetsOf(sheetCtx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              readOnly: true,
              showCursor: true,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0x14FFFFFF),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 10),
            OnScreenKeyboard(
              controller: controller,
              onDone: () => Navigator.pop(sheetCtx),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(() => controller.removeListener(listener));
}

void _showEntityPicker(BuildContext context, {void Function(String)? onPick}) {
  // EntityScope lives inside RootShell, below the Navigator, so a modal route
  // can't inherit it — capture and re-inject. Caller's context must be below
  // EntityScope (the dashboard subtree or an already-injected sheet).
  final catalog = EntityScope.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => EntityScope(
      catalog: catalog,
      child: _EntityPicker(onPick: onPick),
    ),
  );
}

/// Searchable list of all HA entities; tapping one adds a card for it (or, when
/// [onPick] is given, hands the entity id back to the caller for rebinding).
class _EntityPicker extends StatefulWidget {
  final void Function(String)? onPick;
  const _EntityPicker({this.onPick});
  @override
  State<_EntityPicker> createState() => _EntityPickerState();
}

class _EntityPickerState extends State<_EntityPicker> {
  final TextEditingController _qc = TextEditingController();

  @override
  void initState() {
    super.initState();
    _qc.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _qc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cat = EntityScope.of(context);
    final layout = LayoutScope.of(context);
    final q = _qc.text.toLowerCase();
    final items = cat.all.where((e) {
      if (q.isEmpty) return true;
      final fn =
          ((e.value['attributes'] as Map?)?['friendly_name'] as String? ?? '')
              .toLowerCase();
      return e.key.toLowerCase().contains(q) || fn.contains(q);
    }).toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.92,
      decoration: const BoxDecoration(
        color: Color(0xF2121A24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
                color: const Color(0x40FFFFFF),
                borderRadius: BorderRadius.circular(3)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _qc,
              readOnly: true, // driven by the on-screen keyboard below
              showCursor: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search ${cat.count} entities…',
                hintStyle: const TextStyle(color: Color(0x80FFFFFF)),
                prefixIcon: const Icon(Icons.search, color: Color(0x80FFFFFF)),
                suffixIcon: _qc.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, color: Color(0x80FFFFFF)),
                        onPressed: () => _qc.clear(),
                      ),
                filled: true,
                fillColor: const Color(0x14FFFFFF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('No entities (is HA connected?)',
                        style: TextStyle(color: Color(0x80FFFFFF))))
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final e = items[i];
                      final fn =
                          (e.value['attributes'] as Map?)?['friendly_name']
                                  as String? ??
                              e.key;
                      final on = e.value['state'] == 'on';
                      return ListTile(
                        leading: Icon(entityIcon(e.key, on),
                            color: const Color(0xCCFFFFFF)),
                        title: Text(fn,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(e.key,
                            style: const TextStyle(color: Color(0x66FFFFFF))),
                        onTap: () {
                          if (widget.onPick != null) {
                            widget.onPick!(e.key);
                          } else {
                            layout.addEntity(e.key);
                          }
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
          ),
          OnScreenKeyboard(
            controller: _qc,
            onDone: () => FocusScope.of(context).unfocus(),
          ),
        ],
      ),
    );
  }
}

String _cardKindLabel(CardKind k) {
  switch (k) {
    case CardKind.weather:
      return 'Weather';
    case CardKind.camera:
      return 'Camera';
    case CardKind.calendar:
      return 'Calendar';
    case CardKind.haStatus:
      return 'HA Status';
    case CardKind.entity:
      return 'Entity';
  }
}

/// Opens the per-card settings sheet (resize, rebind entity, style/color
/// override). Tapping a card in edit mode lands here.
void _showCardSettings(BuildContext context, CardSpec card, AppLayout layout) {
  // ConfigScope/LayoutScope live above MaterialApp so modal routes already
  // inherit them; the rest live inside RootShell (below the Navigator), so
  // capture and re-inject them — the live preview renders the real card, which
  // reads these scopes (camera feed, glass shader, weather, background).
  final ha = HaScope.of(context);
  final catalog = EntityScope.of(context);
  final weather = WeatherScope.of(context);
  final clock = GlassClock.of(context);
  final bg = BgTextureScope.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => HaScope(
      client: ha,
      child: EntityScope(
        catalog: catalog,
        child: WeatherScope(
          controller: weather,
          child: GlassClock(
            clock: clock,
            child: BgTextureScope(
              holder: bg,
              child: _CardEditor(card: card),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Small muted helper text shown under config fields that are placeholders or
/// need a feature that isn't built yet.
class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text,
            style: const TextStyle(
                color: Color(0x80FFFFFF), fontSize: 13, height: 1.3)),
      );
}

/// HA-style per-card editor: a tabbed sheet (Config / Layout / Style) with a
/// live preview of the real card. Changes apply and persist immediately.
class _CardEditor extends StatefulWidget {
  final CardSpec card;
  const _CardEditor({required this.card});
  @override
  State<_CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<_CardEditor> {
  static const _swatches = <Color>[
    Color(0xFF2E7BFF), Color(0xFF34C759), Color(0xFFFF9F0A), Color(0xFFFF453A),
    Color(0xFFBF5AF2), Color(0xFF64D2FF), Color(0xFFFFFFFF),
  ];

  int _tab = 0; // 0 Config · 1 Layout · 2 Style
  late final TextEditingController _name =
      TextEditingController(text: widget.card.name ?? '');

  CardSpec get card => widget.card;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Mutate + persist + rebuild (so the live preview updates).
  void _set(VoidCallback fn) {
    LayoutScope.of(context).update(fn);
    setState(() {});
  }

  bool get _hasEntity =>
      card.kind == CardKind.entity || card.kind == CardKind.camera;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return Container(
      height: h * 0.9,
      decoration: const BoxDecoration(
        color: Color(0xF2121A24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                  color: const Color(0x40FFFFFF),
                  borderRadius: BorderRadius.circular(3)),
            ),
          ),
          // Header ------------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('${_cardKindLabel(card.kind)} card configuration',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xCCFFFFFF)),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // Live preview ------------------------------------------------
          _preview(),
          // Tabs --------------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                _tabBtn('Config', 0),
                _tabBtn('Layout', 1),
                _tabBtn('Style', 2),
              ],
            ),
          ),
          // Tab body ----------------------------------------------------
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
              child: switch (_tab) {
                1 => _layoutTab(),
                2 => _styleTab(),
                _ => _configTab(),
              },
            ),
          ),
          // Footer ------------------------------------------------------
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: ConfigScope.of(context).accent,
                        borderRadius: BorderRadius.circular(16)),
                    child: const Text('Done',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Preview ────────────────────────────────────────────────────────────
  Widget _preview() {
    Widget w = _cardWidget(card);
    if (card.style != null || card.color != null) {
      w = CardOverride(
        style: card.style,
        color: card.color == null ? null : Color(card.color!),
        child: w,
      );
    }
    return Container(
      height: 130,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      child: SizedBox(width: 210, height: 118, child: w),
    );
  }

  Widget _tabBtn(String label, int i) {
    final sel = _tab == i;
    final accent = ConfigScope.of(context).accent;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? accent.withValues(alpha: 0.22) : const Color(0x0DFFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: sel ? accent : const Color(0x14FFFFFF)),
          ),
          child: Text(label,
              style: TextStyle(
                  color: sel ? Colors.white : const Color(0x99FFFFFF),
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
        ),
      ),
    );
  }

  // ── Config tab ─────────────────────────────────────────────────────────
  Widget _configTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_hasEntity) ...[
          _label(card.kind == CardKind.camera ? 'Camera entity' : 'Entity'),
          const SizedBox(height: 8),
          _entityRow(),
          const SizedBox(height: 20),
        ],
        _label(card.kind == CardKind.calendar ? 'Title' : 'Name'),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _showTextInput(
            context,
            title: card.kind == CardKind.calendar ? 'Title' : 'Name',
            controller: _name,
            onChanged: (v) =>
                _set(() => card.name = v.trim().isEmpty ? null : v.trim()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    card.name?.isNotEmpty == true
                        ? card.name!
                        : 'Default (friendly name)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: card.name?.isNotEmpty == true
                            ? Colors.white
                            : const Color(0x66FFFFFF)),
                  ),
                ),
                const Icon(Icons.keyboard_alt_outlined,
                    color: Color(0x80FFFFFF), size: 20),
              ],
            ),
          ),
        ),
        if (card.kind == CardKind.entity) ...[
          const SizedBox(height: 8),
          _toggle('Show name', card.showName,
              (v) => _set(() => card.showName = v)),
          _toggle('Show state', card.showState,
              (v) => _set(() => card.showState = v)),
          _toggle('Show icon', card.showIcon,
              (v) => _set(() => card.showIcon = v)),
          _toggle('Vertical layout', card.vertical,
              (v) => _set(() => card.vertical = v)),
          _toggle('Slider % readout', card.sliderReadout,
              (v) => _set(() => card.sliderReadout = v)),
        ],
        if (card.kind == CardKind.camera) ...[
          const SizedBox(height: 8),
          _toggle('Show name', card.showName,
              (v) => _set(() => card.showName = v)),
          const SizedBox(height: 12),
          _label('Fit mode'),
          const SizedBox(height: 8),
          _options(const ['cover', 'contain', 'fill'],
              const ['Cover', 'Contain', 'Fill'], card.fit,
              (v) => _set(() => card.fit = v)),
          const SizedBox(height: 16),
          _label('Aspect ratio'),
          const SizedBox(height: 8),
          _options(const [null, '16:9', '4:3', '1:1'],
              const ['Auto', '16:9', '4:3', '1:1'], card.aspect,
              (v) => _set(() => card.aspect = v)),
        ],
        if (card.kind == CardKind.weather) ...[
          const SizedBox(height: 8),
          _toggle('Show current', card.showCurrent,
              (v) => _set(() => card.showCurrent = v)),
          _toggle('Show forecast', card.showForecast,
              (v) => _set(() => card.showForecast = v)),
          _toggle('Round temperature', card.roundTemp,
              (v) => _set(() => card.roundTemp = v)),
          const SizedBox(height: 12),
          _label('Forecast type'),
          const SizedBox(height: 8),
          _options(const ['daily', 'hourly', 'twice_daily'],
              const ['Daily', 'Hourly', 'Twice daily'], card.forecastType,
              (v) => _set(() => card.forecastType = v)),
          const _Note('Forecast options take effect once the multi-day '
              'forecast view is added.'),
        ],
        if (card.kind == CardKind.calendar) ...[
          const SizedBox(height: 12),
          _label('Initial view'),
          const SizedBox(height: 8),
          _options(const ['month', 'day', 'list'],
              const ['Month', 'Day', 'List week'], card.initialView,
              (v) => _set(() => card.initialView = v)),
          const _Note('Calendar is a placeholder; event sources (HA / CalDAV) '
              'come later. These options are saved for then.'),
        ],
        if (card.kind == CardKind.haStatus)
          const _Note('Live Home Assistant connection + entity count. '
              'No per-card options beyond name, layout, and style.'),
        if (_hasEntity) ...[
          const SizedBox(height: 16),
          _label('Tap action'),
          const SizedBox(height: 8),
          _options(const ['more-info', 'toggle', 'none'],
              const ['More info', 'Toggle', 'None'], card.tap,
              (v) => _set(() => card.tap = v)),
        ],
      ],
    );
  }

  Widget _entityRow() => GestureDetector(
        onTap: () => _showEntityPicker(context, onPick: (id) {
          _set(() => card.entityId = id);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.swap_horiz_rounded,
                  color: Color(0xCCFFFFFF), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(card.entityId ?? 'Pick an entity',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white)),
              ),
              const Icon(Icons.chevron_right, color: Color(0x80FFFFFF)),
            ],
          ),
        ),
      );

  // ── Layout tab ─────────────────────────────────────────────────────────
  Widget _layoutTab() {
    final maxW = kGridCols - card.col;
    final maxH = kGridRows - card.row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Size (grid cells)'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: _stepper('Width', card.w, 1, maxW,
                    (v) => _set(() => card.w = v))),
            const SizedBox(width: 12),
            Expanded(
                child: _stepper('Height', card.h, 1, maxH,
                    (v) => _set(() => card.h = v))),
          ],
        ),
        const SizedBox(height: 16),
        Text('Position: column ${card.col + 1}, row ${card.row + 1}',
            style: const TextStyle(color: Color(0x80FFFFFF))),
        const SizedBox(height: 6),
        const Text('Drag the card on the dashboard to move it.',
            style: TextStyle(color: Color(0x66FFFFFF), fontSize: 13)),
      ],
    );
  }

  // ── Style tab ──────────────────────────────────────────────────────────
  Widget _styleTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Card style'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip('Default', card.style == null,
                () => _set(() => card.style = null)),
            for (final st in CardStyle.values)
              _chip(_styleLabel(st), card.style == st,
                  () => _set(() => card.style = st)),
          ],
        ),
        const SizedBox(height: 20),
        _label('Color'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _swatch(null, card.color == null,
                () => _set(() => card.color = null)),
            for (final c in _swatches)
              _swatch(c, card.color == c.toARGB32(),
                  () => _set(() => card.color = c.toARGB32())),
          ],
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: GestureDetector(
            onTap: () {
              LayoutScope.of(context).remove(card.id);
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x22FF453A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x55FF453A)),
              ),
              child: const Text('Delete card',
                  style: TextStyle(
                      color: Color(0xFFFF6961), fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ],
    );
  }

  // ── Shared field widgets ────────────────────────────────────────────────
  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    final accent = ConfigScope.of(context).accent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: accent,
          ),
        ],
      ),
    );
  }

  /// A small set of mutually-exclusive options rendered as selectable chips.
  Widget _options<T>(List<T> values, List<String> labels, T current,
      ValueChanged<T> onSelect) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < values.length; i++)
          _chip(labels[i], values[i] == current, () => onSelect(values[i])),
      ],
    );
  }

  Widget _label(String t) => Text(t,
      style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0x99FFFFFF),
          letterSpacing: 0.4));

  Widget _stepper(
      String label, int value, int min, int max, ValueChanged<int> onChange) {
    Widget btn(IconData icon, bool enabled, VoidCallback onTap) =>
        GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon,
                color: enabled ? Colors.white : const Color(0x33FFFFFF),
                size: 20),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Color(0x80FFFFFF))),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              btn(Icons.remove, value > min, () => onChange(value - 1)),
              Text('$value',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
              btn(Icons.add, value < max, () => onChange(value + 1)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final accent = ConfigScope.of(context).accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? accent : const Color(0x26FFFFFF)),
        ),
        child: Text(label,
            style: TextStyle(
                color: Colors.white,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }

  Widget _swatch(Color? color, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color ?? const Color(0x14FFFFFF),
          shape: BoxShape.circle,
          border: Border.all(
              color: selected ? Colors.white : const Color(0x33FFFFFF),
              width: selected ? 3 : 1),
        ),
        child: color == null
            ? const Icon(Icons.block, color: Color(0x80FFFFFF), size: 18)
            : (selected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null),
      ),
    );
  }

  String _styleLabel(CardStyle s) {
    switch (s) {
      case CardStyle.liquidGlass:
        return 'Glass';
      case CardStyle.frosted:
        return 'Frosted';
      case CardStyle.solid:
        return 'Solid';
      case CardStyle.outline:
        return 'Outline';
    }
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
/// small page indicator. In edit mode a trailing "add page" panel lets you grow
/// the dashboard by holding past the last page.
class DashboardScreen extends StatefulWidget {
  final bool editing;
  const DashboardScreen({super.key, this.editing = false});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = LayoutScope.of(context);
    final realPages = layout.pageCount;
    // Edit mode shows one extra "add page" page at the end.
    final count = widget.editing ? realPages + 1 : realPages;

    // A deleted page (or leaving edit mode on the add-page panel) can leave the
    // controller past the end — clamp back after this frame.
    if (_page >= count) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        _controller.jumpToPage(count - 1);
        setState(() => _page = count - 1);
      });
    }

    return Stack(
      children: [
        PageView.builder(
          controller: _controller,
          itemCount: count,
          onPageChanged: (p) {
            setState(() => _page = p);
            if (p < layout.pageCount) layout.activePage = p;
          },
          itemBuilder: (ctx, i) {
            if (widget.editing && i == realPages) {
              return _AddPagePanel(onAdd: () {
                final idx = layout.addPage();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_controller.hasClients) return;
                  _controller.animateToPage(idx,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOut);
                });
              });
            }
            return GridDashboard(editing: widget.editing, page: i);
          },
        ),
        if (realPages > 1 || widget.editing)
          Positioned(
            bottom: 26,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: _PageDots(
                count: realPages,
                current: _page.clamp(0, realPages - 1),
                onAddPage: widget.editing && _page == realPages,
              ),
            ),
          ),
      ],
    );
  }
}

/// Bottom page-indicator dots; shows a faint "+" when sitting on the add-page
/// panel in edit mode.
class _PageDots extends StatelessWidget {
  final int count;
  final int current;
  final bool onAddPage;
  const _PageDots(
      {required this.count, required this.current, this.onAddPage = false});

  @override
  Widget build(BuildContext context) {
    final accent = ConfigScope.of(context).accent;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              width: i == current && !onAddPage ? 9 : 7,
              height: i == current && !onAddPage ? 9 : 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == current && !onAddPage
                    ? accent
                    : const Color(0x55FFFFFF),
              ),
            ),
          ),
        if (onAddPage)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.add_circle_outline, size: 16, color: accent),
          ),
      ],
    );
  }
}

/// Trailing "add page" panel: swipe to it in edit mode, then hold to confirm.
class _AddPagePanel extends StatefulWidget {
  final VoidCallback onAdd;
  const _AddPagePanel({required this.onAdd});
  @override
  State<_AddPagePanel> createState() => _AddPagePanelState();
}

class _AddPagePanelState extends State<_AddPagePanel> {
  Timer? _timer;
  double _progress = 0;

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      setState(() => _progress += 40 / 1500); // ~1.5s hold
      if (_progress >= 1) {
        t.cancel();
        setState(() => _progress = 0);
        widget.onAdd();
      }
    });
  }

  void _cancel([_]) {
    _timer?.cancel();
    if (_progress != 0) setState(() => _progress = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ConfigScope.of(context).accent;
    return Center(
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: _cancel,
        onTapCancel: _cancel,
        child: Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: const Color(0x14FFFFFF),
            border: Border.all(color: const Color(0x40FFFFFF), width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 66,
                height: 66,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_progress > 0)
                      SizedBox(
                        width: 66,
                        height: 66,
                        child: CircularProgressIndicator(
                          value: _progress,
                          strokeWidth: 4,
                          color: accent,
                          backgroundColor: const Color(0x22FFFFFF),
                        ),
                      ),
                    const Icon(Icons.add_rounded, color: Colors.white, size: 42),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('Hold to add page',
                  style: TextStyle(color: Color(0xB3FFFFFF))),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Editable grid layout ─────────────────────────────────────────────────────
// The dashboard is a saved list of cards on a fixed column/row grid. Edit mode
// (next phase) mutates this; for now it renders the default/saved layout.
const int kGridCols = 4;
const int kGridRows = 4;

enum CardKind { weather, camera, calendar, haStatus, entity }

class CardSpec {
  final String id;
  final CardKind kind;
  String? entityId;
  int col, row, w, h;
  int page; // which dashboard page (0-based) this card lives on

  /// Per-card style override; null = inherit the global AppConfig.cardStyle.
  CardStyle? style;

  /// Per-card color override (ARGB int); null = inherit the global accent/card
  /// color. Tints the icon (entity cards) and the card fill/border.
  int? color;

  // ── HA-style config (modeled on Lovelace tile/picture-entity cards) ──
  /// Display name override (HA `name`); null = entity friendly_name.
  String? name;
  bool showName;
  bool showState; // HA hide_state (inverted)
  bool showIcon;
  bool vertical; // HA `vertical` — icon above text
  bool sliderReadout; // show the % value while press-hold dragging to adjust
  /// Normal-mode tap action: 'more-info' | 'toggle' | 'none' (HA tap_action).
  String tap;
  /// Camera fit: 'cover' | 'contain' | 'fill' (HA fit_mode).
  String fit;
  /// Camera aspect ratio: null (fill grid) | '16:9' | '4:3' | '1:1'.
  String? aspect;

  // Weather card (HA weather-forecast card options).
  bool showCurrent;
  bool showForecast;
  String forecastType; // 'daily' | 'hourly' | 'twice_daily'
  bool roundTemp;

  // Calendar card (HA calendar card options).
  String initialView; // 'month' | 'day' | 'list'

  CardSpec({
    required this.id,
    required this.kind,
    this.entityId,
    required this.col,
    required this.row,
    required this.w,
    required this.h,
    this.page = 0,
    this.style,
    this.color,
    this.name,
    this.showName = true,
    this.showState = true,
    this.showIcon = true,
    this.vertical = false,
    this.sliderReadout = true,
    this.tap = 'more-info',
    this.fit = 'cover',
    this.aspect,
    this.showCurrent = true,
    this.showForecast = true,
    this.forecastType = 'daily',
    this.roundTemp = false,
    this.initialView = 'month',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.index,
        'entityId': entityId,
        'col': col,
        'row': row,
        'w': w,
        'h': h,
        'page': page,
        'style': style?.index,
        'color': color,
        'name': name,
        'showName': showName,
        'showState': showState,
        'showIcon': showIcon,
        'vertical': vertical,
        'sliderReadout': sliderReadout,
        'tap': tap,
        'fit': fit,
        'aspect': aspect,
        'showCurrent': showCurrent,
        'showForecast': showForecast,
        'forecastType': forecastType,
        'roundTemp': roundTemp,
        'initialView': initialView,
      };
  factory CardSpec.fromJson(Map<String, dynamic> j) => CardSpec(
        id: j['id'] as String,
        kind: CardKind.values[(j['kind'] as num).toInt()],
        entityId: j['entityId'] as String?,
        col: (j['col'] as num).toInt(),
        row: (j['row'] as num).toInt(),
        w: (j['w'] as num).toInt(),
        h: (j['h'] as num).toInt(),
        page: (j['page'] as num?)?.toInt() ?? 0,
        style: j['style'] == null
            ? null
            : CardStyle.values[(j['style'] as num).toInt()],
        color: (j['color'] as num?)?.toInt(),
        name: j['name'] as String?,
        showName: j['showName'] as bool? ?? true,
        showState: j['showState'] as bool? ?? true,
        showIcon: j['showIcon'] as bool? ?? true,
        vertical: j['vertical'] as bool? ?? false,
        sliderReadout: j['sliderReadout'] as bool? ?? true,
        tap: j['tap'] as String? ?? 'more-info',
        fit: j['fit'] as String? ?? 'cover',
        aspect: j['aspect'] as String?,
        showCurrent: j['showCurrent'] as bool? ?? true,
        showForecast: j['showForecast'] as bool? ?? true,
        forecastType: j['forecastType'] as String? ?? 'daily',
        roundTemp: j['roundTemp'] as bool? ?? false,
        initialView: j['initialView'] as String? ?? 'month',
      );
}

/// Per-card style/color override carried down to [LiquidGlass] and [_EntityCard]
/// via context, so a single card can deviate from the global theme without
/// rewriting every card widget to accept override parameters.
class CardOverride extends InheritedWidget {
  final CardStyle? style;
  final Color? color;
  const CardOverride({
    super.key,
    this.style,
    this.color,
    required super.child,
  });

  static CardOverride? maybeOf(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<CardOverride>();

  @override
  bool updateShouldNotify(CardOverride old) =>
      style != old.style || color != old.color;
}

List<CardSpec> _defaultLayout() => [
      CardSpec(id: 'weather', kind: CardKind.weather, col: 0, row: 0, w: 2, h: 1),
      CardSpec(id: 'camera', kind: CardKind.camera, col: 0, row: 1, w: 2, h: 3),
      CardSpec(id: 'calendar', kind: CardKind.calendar, col: 2, row: 0, w: 2, h: 3),
      CardSpec(id: 'hastatus', kind: CardKind.haStatus, col: 2, row: 3, w: 2, h: 1),
    ];

class AppLayout extends ChangeNotifier {
  List<CardSpec> cards;
  int pageCount;

  /// The page currently on screen. Transient view state (not persisted): set by
  /// the dashboard as you swipe. New cards are added here; "delete page" targets
  /// it.
  int activePage = 0;

  /// Disabled in tests so mutations don't write to ~/.config.
  @visibleForTesting
  bool persist = true;

  AppLayout(this.cards, {int? pageCount})
      : pageCount = pageCount ?? _derivePageCount(cards);

  static int _derivePageCount(List<CardSpec> cards) {
    var maxPage = 0;
    for (final c in cards) {
      if (c.page > maxPage) maxPage = c.page;
    }
    return maxPage + 1;
  }

  static File get _file =>
      File('${Platform.environment['HOME']}/.config/smart-display/layout.json');

  /// Parses persisted layout, tolerating both the current object form
  /// (`{pageCount, cards}`) and the legacy bare-array form (all cards on page 0).
  @visibleForTesting
  static AppLayout fromDecoded(Object? decoded) {
    if (decoded is Map) {
      final raw = decoded['cards'];
      if (raw is List) {
        final cards =
            raw.map((e) => CardSpec.fromJson(e as Map<String, dynamic>)).toList();
        if (cards.isNotEmpty) {
          final pc = (decoded['pageCount'] as num?)?.toInt();
          return AppLayout(cards,
              pageCount: pc == null ? null : (pc < 1 ? 1 : pc));
        }
      }
    } else if (decoded is List) {
      final cards = decoded
          .map((e) => CardSpec.fromJson(e as Map<String, dynamic>))
          .toList();
      if (cards.isNotEmpty) return AppLayout(cards);
    }
    return AppLayout(_defaultLayout());
  }

  static Future<AppLayout> load() async {
    try {
      final f = _file;
      if (f.existsSync()) {
        return fromDecoded(jsonDecode(await f.readAsString()));
      }
    } catch (_) {}
    return AppLayout(_defaultLayout());
  }

  Future<void> save() async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'pageCount': pageCount,
        'cards': cards.map((c) => c.toJson()).toList(),
      }));
    } catch (_) {}
  }

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
    if (persist) save();
  }

  void addEntity(String entityId) => update(() => cards.add(CardSpec(
        id: 'e${DateTime.now().millisecondsSinceEpoch}',
        kind: CardKind.entity,
        entityId: entityId,
        col: 0,
        row: 0,
        w: 1,
        h: 1,
        page: activePage,
      )));

  void remove(String id) => update(() => cards.removeWhere((c) => c.id == id));

  /// Append a new blank page; returns its index.
  int addPage() {
    final newIndex = pageCount;
    update(() => pageCount++);
    return newIndex;
  }

  /// Delete [page] and its cards, shifting later pages down. The last remaining
  /// page can't be deleted.
  void removePage(int page) {
    if (pageCount <= 1 || page < 0 || page >= pageCount) return;
    update(() {
      cards.removeWhere((c) => c.page == page);
      for (final c in cards) {
        if (c.page > page) c.page--;
      }
      pageCount--;
      if (activePage >= pageCount) activePage = pageCount - 1;
    });
  }
}

class LayoutScope extends InheritedNotifier<AppLayout> {
  const LayoutScope(
      {super.key, required AppLayout layout, required super.child})
      : super(notifier: layout);
  static AppLayout of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<LayoutScope>()!.notifier!;
}

/// Renders the saved card layout on a responsive kGridCols×kGridRows grid.
/// In edit mode, cards get an outline, a delete button, and drag-to-move with
/// grid snapping.
class GridDashboard extends StatefulWidget {
  final bool editing;
  final int page;
  const GridDashboard({super.key, this.editing = false, this.page = 0});

  @override
  State<GridDashboard> createState() => _GridDashboardState();
}

class _GridDashboardState extends State<GridDashboard> {
  String? _dragId;
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final layout = LayoutScope.of(context);
    final gap = 14 * s;
    // In edit mode the top bar (Editing / palette / add / Done) overlays the
    // top of the screen; inset the grid so the top-row cards' gear/delete
    // buttons aren't hidden behind it and stay tappable.
    final topInset = widget.editing ? 66.0 : 0.0;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(gap, gap + topInset, gap, gap),
        child: LayoutBuilder(builder: (ctx, c) {
          final cellW = (c.maxWidth - gap * (kGridCols - 1)) / kGridCols;
          final cellH = (c.maxHeight - gap * (kGridRows - 1)) / kGridRows;
          final stepX = cellW + gap;
          final stepY = cellH + gap;
          return Stack(
            children: [
              for (final card in layout.cards.where((c) => c.page == widget.page))
                _positioned(card, cellW, cellH, gap, stepX, stepY, layout),
            ],
          );
        }),
      ),
    );
  }

  Widget _positioned(CardSpec card, double cellW, double cellH, double gap,
      double stepX, double stepY, AppLayout layout) {
    final dragging = _dragId == card.id;
    final left = card.col * stepX + (dragging ? _drag.dx : 0);
    final top = card.row * stepY + (dragging ? _drag.dy : 0);
    final w = card.w * cellW + (card.w - 1) * gap;
    final h = card.h * cellH + (card.h - 1) * gap;

    Widget child = _cardWidget(card);
    if (card.style != null || card.color != null) {
      child = CardOverride(
        style: card.style,
        color: card.color == null ? null : Color(card.color!),
        child: child,
      );
    }
    if (widget.editing) {
      final accent = ConfigScope.of(context).accent;
      // Tap opens settings; press-and-hold then drag moves the card. Using
      // long-press for drag (instead of a pan recognizer) frees up plain taps,
      // which a pan recognizer would otherwise swallow on a touchscreen where
      // every contact carries slight movement.
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showCardSettings(context, card, layout),
        onLongPressStart: (_) => setState(() {
          _dragId = card.id;
          _drag = Offset.zero;
        }),
        onLongPressMoveUpdate: (d) =>
            setState(() => _drag = d.localOffsetFromOrigin),
        onLongPressEnd: (_) {
          final newCol = ((card.col * stepX + _drag.dx) / stepX)
              .round()
              .clamp(0, kGridCols - card.w);
          final newRow = ((card.row * stepY + _drag.dy) / stepY)
              .round()
              .clamp(0, kGridRows - card.h);
          layout.update(() {
            card.col = newCol;
            card.row = newRow;
          });
          setState(() {
            _dragId = null;
            _drag = Offset.zero;
          });
        },
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(ConfigScope.of(context).cornerRadius),
                    border: Border.all(color: accent, width: 2),
                  ),
                ),
              ),
            ),
            // Settings (gear) — explicit, always-reliable edit affordance.
            Positioned(
              top: 6,
              left: 6,
              child: GestureDetector(
                onTap: () => _showCardSettings(context, card, layout),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.9),
                  ),
                  child: const Icon(Icons.tune_rounded,
                      size: 18, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => layout.remove(card.id),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xCC000000),
                  ),
                  child: const Icon(Icons.close, size: 18, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Normal mode: tap runs the card's tap_action (more-info / toggle / none);
    // press-hold + horizontal drag adjusts an adjustable entity in place.
    if (!widget.editing && card.entityId != null) {
      final id = card.entityId!;
      child = _AdjustableCard(
        card: card,
        onTap: card.tap == 'none'
            ? null
            : () {
                if (card.tap == 'toggle') {
                  HaScope.of(context)
                      .callService(id.split('.').first, 'toggle', id);
                } else {
                  _showMoreInfo(context, id);
                }
              },
        child: child,
      );
    }

    return Positioned(left: left, top: top, width: w, height: h, child: child);
  }
}

/// How a dashboard card's press-hold horizontal drag maps to a live service
/// call. [value] is the entity's current primary value as a 0..100 percent.
class CardAdjust {
  final double value;
  final String service;
  final Map<String, dynamic> Function(int pct) data;
  const CardAdjust(
      {required this.value, required this.service, required this.data});
}

/// Returns the drag-to-adjust descriptor for [domain]/[attrs], or null if the
/// entity has no adjustable primary value (light brightness, media volume,
/// cover position, fan speed). Pure — unit-tested.
@visibleForTesting
CardAdjust? cardAdjustment(String domain, Map attrs) {
  switch (domain) {
    case 'light':
      final modes =
          (attrs['supported_color_modes'] as List?)?.cast<String>() ?? const [];
      // On/off-only lights aren't dimmable.
      if (modes.length == 1 && modes.first == 'onoff') return null;
      final b = (attrs['brightness'] as num?)?.toDouble();
      return CardAdjust(
          value: b == null ? 0 : b / 255 * 100,
          service: 'turn_on',
          data: (p) => {'brightness_pct': p});
    case 'media_player':
      final v = (attrs['volume_level'] as num?)?.toDouble();
      if (v == null) return null;
      return CardAdjust(
          value: v * 100,
          service: 'volume_set',
          data: (p) => {'volume_level': p / 100});
    case 'cover':
      final pos = (attrs['current_position'] as num?)?.toDouble();
      if (pos == null) return null;
      return CardAdjust(
          value: pos,
          service: 'set_cover_position',
          data: (p) => {'position': p});
    case 'fan':
      final pct = (attrs['percentage'] as num?)?.toDouble();
      if (pct == null) return null;
      return CardAdjust(
          value: pct, service: 'set_percentage', data: (p) => {'percentage': p});
  }
  return null;
}

/// The in-card slider fill color: a light's live color (rgb, else hs), otherwise
/// the theme accent. Pure — unit-tested.
@visibleForTesting
Color sliderFillColor(String domain, Map attrs, Color accent) {
  if (domain == 'light') {
    final rgb = (attrs['rgb_color'] as List?)?.cast<num>();
    if (rgb != null && rgb.length >= 3) {
      return Color.fromARGB(255, rgb[0].toInt(), rgb[1].toInt(), rgb[2].toInt());
    }
    final hs = (attrs['hs_color'] as List?)?.cast<num>();
    if (hs != null && hs.length >= 2) {
      return HSVColor.fromAHSV(1, (hs[0] % 360).toDouble(),
              (hs[1] / 100).clamp(0, 1).toDouble(), 1)
          .toColor();
    }
  }
  return accent;
}

/// Wraps an entity card so that, in normal mode, a press-hold-then-horizontal
/// drag adjusts the entity's primary value live (no menu). A quick tap still runs
/// [onTap] (toggle / more-info); a plain swipe still pages. Non-adjustable
/// entities just get the tap behavior.
class _AdjustableCard extends StatefulWidget {
  final CardSpec card;
  final Widget child;
  final VoidCallback? onTap;
  const _AdjustableCard({required this.card, required this.child, this.onTap});
  @override
  State<_AdjustableCard> createState() => _AdjustableCardState();
}

class _AdjustableCardState extends State<_AdjustableCard> {
  double? _dragPct; // non-null while dragging
  double _startPct = 0;
  double _width = 1;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  String get _id => widget.card.entityId!;
  String get _domain => entityDomain(_id);
  Map get _attrs =>
      (EntityScope.of(context).state(_id)?['attributes'] as Map?) ?? const {};

  void _commit(CardAdjust adj, int pct, {bool force = false}) {
    final now = DateTime.now();
    // Throttle live updates (~180ms); always send the final value on release.
    if (!force && now.difference(_lastSent).inMilliseconds < 180) return;
    _lastSent = now;
    HaScope.of(context).callService(_domain, adj.service, _id, adj.data(pct));
  }

  @override
  Widget build(BuildContext context) {
    final adj = cardAdjustment(_domain, _attrs);
    if (adj == null) {
      if (widget.onTap == null) return widget.child;
      return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.child);
    }
    final accent = ConfigScope.of(context).accent;
    final fill = sliderFillColor(_domain, _attrs, accent);
    final pct = (_dragPct ?? adj.value).clamp(0, 100).toDouble();
    return LayoutBuilder(builder: (ctx, c) {
      _width = c.maxWidth <= 0 ? 1 : c.maxWidth;
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          if (widget.onTap != null)
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (r) => r.onTap = widget.onTap,
            ),
          // 300ms hold "arms" the slide so it wins over the PageView's horizontal
          // drag; a quick swipe still pages.
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 300)),
            (r) {
              r.onLongPressStart = (_) =>
                  setState(() => _dragPct = _startPct = adj.value);
              r.onLongPressMoveUpdate = (d) {
                final np =
                    (_startPct + d.localOffsetFromOrigin.dx / _width * 100)
                        .clamp(0, 100)
                        .toDouble();
                setState(() => _dragPct = np);
                _commit(adj, np.round());
              };
              r.onLongPressEnd = (_) {
                _commit(adj, (_dragPct ?? adj.value).round(), force: true);
                setState(() => _dragPct = null);
              };
            },
          ),
        },
        child: Stack(
          children: [
            widget.child,
            if (_dragPct != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: _SliderFill(
                    pct: pct,
                    color: fill,
                    showValue: widget.card.sliderReadout,
                    radius: ConfigScope.of(context).cornerRadius,
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// The translucent left-to-right fill drawn over a card while adjusting it.
class _SliderFill extends StatelessWidget {
  final double pct;
  final Color color;
  final bool showValue;
  final double radius;
  const _SliderFill(
      {required this.pct,
      required this.color,
      required this.showValue,
      required this.radius});
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (pct / 100).clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(color: color.withValues(alpha: 0.35)),
              ),
            ),
            if (showValue)
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('${pct.round()}%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                ),
              ),
          ],
        ),
      );
}

/// HA-style "more info" sheet: live state, attributes, and a toggle.
void _showMoreInfo(BuildContext context, String entityId) {
  final catalog = EntityScope.of(context);
  final ha = HaScope.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => HaScope(
      client: ha,
      child: EntityScope(
        catalog: catalog,
        child: _MoreInfoSheet(entityId: entityId),
      ),
    ),
  );
}

/// Domains that show a header on/off pill.
const _kToggleable = {
  'light', 'switch', 'fan', 'input_boolean', 'siren', 'humidifier',
  'automation', 'group',
};

class _MoreInfoSheet extends StatefulWidget {
  final String entityId;
  const _MoreInfoSheet({required this.entityId});
  @override
  State<_MoreInfoSheet> createState() => _MoreInfoSheetState();
}

class _MoreInfoSheetState extends State<_MoreInfoSheet> {
  // Live slider value while dragging (keyed by control); cleared on release so
  // the control tracks the entity's real state again.
  final Map<String, double> _drag = {};
  final TextEditingController _text = TextEditingController();

  String get _id => widget.entityId;
  String get _domain => entityDomain(_id);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _svc(String service, [Map<String, dynamic>? data]) {
    // Groups toggle via the homeassistant domain; everything else via its own.
    final d =
        (_domain == 'group' && (service.startsWith('turn') || service == 'toggle'))
            ? 'homeassistant'
            : _domain;
    HaScope.of(context).callService(d, service, _id, data);
  }

  @override
  Widget build(BuildContext context) {
    final cat = EntityScope.of(context);
    final st = cat.state(_id);
    final attrs = (st?['attributes'] as Map?) ?? const {};
    final name = attrs['friendly_name'] as String? ?? _id;
    final state = st?['state'] as String? ?? '—';
    final on = state == 'on';
    final accent = ConfigScope.of(context).accent;
    final controls = _controls(attrs, state, on, accent);
    final rows = attrs.entries
        .where((e) => e.key != 'friendly_name' && e.key != 'icon')
        .take(12)
        .toList();

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.viewInsetsOf(context).bottom + 24),
      decoration: const BoxDecoration(
        color: Color(0xF2121A24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(entityIcon(_id, on),
                    color: on ? accent : const Color(0xCCFFFFFF), size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                      Text(_prettyState(state, attrs),
                          style: const TextStyle(color: Color(0x99FFFFFF))),
                    ],
                  ),
                ),
                if (_kToggleable.contains(_domain))
                  _pill(on ? 'On' : 'Off', on, accent, () => _svc('toggle')),
              ],
            ),
            if (controls != null) ...[
              const SizedBox(height: 18),
              controls,
            ],
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Divider(color: Color(0x1FFFFFFF), height: 1),
              const SizedBox(height: 12),
              ...rows.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(e.key.replaceAll('_', ' '),
                              style: const TextStyle(color: Color(0x99FFFFFF))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('${e.value}',
                              textAlign: TextAlign.right,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  String _prettyState(String state, Map attrs) {
    final unit = attrs['unit_of_measurement'];
    return unit == null ? state : '$state $unit';
  }

  // ── Per-domain control blocks ───────────────────────────────────────────
  Widget? _controls(Map attrs, String state, bool on, Color accent) {
    switch (_domain) {
      case 'light':
        if (!on) return null;
        return _light(attrs);
      case 'fan':
        if (!on) return null;
        final p = (attrs['percentage'] as num?)?.toDouble() ?? 0;
        return _slider('fan', 'Speed', p, 0, 100,
            (v) => _svc('set_percentage', {'percentage': v.round()}),
            suffix: '%');
      case 'climate':
        return _climate(attrs, state, accent);
      case 'cover':
        return _cover(attrs);
      case 'valve':
        return _valve(attrs);
      case 'water_heater':
        return _waterHeater(attrs, state, accent);
      case 'humidifier':
        return _humidifier(attrs, on, accent);
      case 'alarm_control_panel':
        return _alarm(attrs, state);
      case 'vacuum':
        return _vacuum(attrs);
      case 'media_player':
        return _media(attrs);
      case 'lock':
        return Row(children: [
          _btn('Lock', () => _svc('lock')),
          const SizedBox(width: 10),
          _btn('Unlock', () => _svc('unlock')),
        ]);
      case 'scene':
        return _wideBtn('Activate', accent, () => _svc('turn_on'));
      case 'script':
        return _wideBtn('Run', accent, () => _svc('turn_on'));
      case 'automation':
        return _wideBtn('Trigger', accent, () => _svc('trigger'));
      case 'input_button':
      case 'button':
        return _wideBtn('Press', accent, () => _svc('press'));
      case 'input_number':
      case 'number':
        final min = (attrs['min'] as num?)?.toDouble() ?? 0;
        final max = (attrs['max'] as num?)?.toDouble() ?? 100;
        final val = double.tryParse(state) ?? min;
        return _slider('num', 'Value', val, min, max,
            (v) => _svc('set_value', {'value': v}),
            step: (attrs['step'] as num?)?.toDouble());
      case 'input_select':
      case 'select':
        final opts = (attrs['options'] as List?)?.cast<String>() ?? const [];
        return _options(opts, state, (o) => _svc('select_option', {'option': o}));
      case 'input_text':
      case 'text':
        return _wideBtn('Edit text', accent, () {
          _text.text = state == '—' ? '' : state;
          _showTextInput(context,
              title: 'Set value',
              controller: _text,
              onChanged: (v) => _svc('set_value', {'value': v}));
        });
      case 'counter':
        return Row(children: [
          _btn('−', () => _svc('decrement')),
          const SizedBox(width: 10),
          _btn('Reset', () => _svc('reset')),
          const SizedBox(width: 10),
          _btn('+', () => _svc('increment')),
        ]);
      case 'timer':
        return Row(children: [
          _btn('Start', () => _svc('start')),
          const SizedBox(width: 10),
          _btn('Pause', () => _svc('pause')),
          const SizedBox(width: 10),
          _btn('Cancel', () => _svc('cancel')),
        ]);
      case 'date':
        return _wideBtn('Set date', accent, () => _pickDate(state));
      case 'time':
        return _wideBtn('Set time', accent, () => _pickTime(state));
      case 'datetime':
        return _wideBtn('Set date & time', accent, () => _pickDateTime(state));
    }
    return null;
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  Future<void> _pickDate(String state) async {
    final init = DateTime.tryParse(state) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    _svc('set_value',
        {'date': '${picked.year}-${_pad2(picked.month)}-${_pad2(picked.day)}'});
  }

  Future<void> _pickTime(String state) async {
    final p = state.split(':');
    final init = TimeOfDay(
        hour: int.tryParse(p.isNotEmpty ? p[0] : '') ?? 0,
        minute: int.tryParse(p.length > 1 ? p[1] : '') ?? 0);
    final picked = await showTimePicker(context: context, initialTime: init);
    if (picked == null || !mounted) return;
    _svc('set_value', {'time': '${_pad2(picked.hour)}:${_pad2(picked.minute)}:00'});
  }

  Future<void> _pickDateTime(String state) async {
    final init = DateTime.tryParse(state) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(init));
    if (t == null || !mounted) return;
    _svc('set_value', {
      'datetime':
          '${d.year}-${_pad2(d.month)}-${_pad2(d.day)} ${_pad2(t.hour)}:${_pad2(t.minute)}:00'
    });
  }

  Widget _climate(Map attrs, String state, Color accent) {
    final cur = attrs['current_temperature'];
    final target = (attrs['temperature'] as num?)?.toDouble();
    final step = (attrs['target_temp_step'] as num?)?.toDouble() ?? 0.5;
    final modes = (attrs['hvac_modes'] as List?)?.cast<String>() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cur != null)
          Text('Current: $cur°',
              style: const TextStyle(color: Color(0x99FFFFFF))),
        if (target != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            _btn('−',
                () => _svc('set_temperature', {'temperature': target - step})),
            const SizedBox(width: 14),
            Text('${target.toStringAsFixed(1)}°',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(width: 14),
            _btn('+',
                () => _svc('set_temperature', {'temperature': target + step})),
          ]),
        ],
        if (modes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _options(modes, state, (m) => _svc('set_hvac_mode', {'hvac_mode': m})),
        ],
      ],
    );
  }

  Widget _cover(Map attrs) {
    final pos = (attrs['current_position'] as num?)?.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _btn('Open', () => _svc('open_cover')),
          const SizedBox(width: 10),
          _btn('Stop', () => _svc('stop_cover')),
          const SizedBox(width: 10),
          _btn('Close', () => _svc('close_cover')),
        ]),
        if (pos != null)
          _slider('cover', 'Position', pos, 0, 100,
              (v) => _svc('set_cover_position', {'position': v.round()}),
              suffix: '%'),
      ],
    );
  }

  Widget _media(Map attrs) {
    final vol = (attrs['volume_level'] as num?)?.toDouble();
    final source = attrs['source'] as String?;
    final sources = (attrs['source_list'] as List?)?.cast<String>() ?? const [];
    final soundMode = attrs['sound_mode'] as String?;
    final soundModes =
        (attrs['sound_mode_list'] as List?)?.cast<String>() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _iconBtn(Icons.skip_previous, () => _svc('media_previous_track')),
          const SizedBox(width: 16),
          _iconBtn(Icons.play_arrow, () => _svc('media_play_pause'), big: true),
          const SizedBox(width: 16),
          _iconBtn(Icons.skip_next, () => _svc('media_next_track')),
        ]),
        if (vol != null)
          _slider('vol', 'Volume', vol * 100, 0, 100,
              (v) => _svc('volume_set', {'volume_level': v / 100}),
              suffix: '%'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Source', style: TextStyle(color: Color(0x99FFFFFF))),
          const SizedBox(height: 8),
          _options(sources, source ?? '',
              (s) => _svc('select_source', {'source': s})),
        ],
        if (soundModes.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Sound mode', style: TextStyle(color: Color(0x99FFFFFF))),
          const SizedBox(height: 8),
          _options(soundModes, soundMode ?? '',
              (s) => _svc('select_sound_mode', {'sound_mode': s})),
        ],
      ],
    );
  }

  // Light: brightness, plus color-temperature and/or a color swatch row when the
  // light's supported_color_modes advertise them.
  static const _kColorModes = ['hs', 'rgb', 'rgbw', 'rgbww', 'xy'];
  Widget _light(Map attrs) {
    final b = (attrs['brightness'] as num?)?.toDouble() ?? 255;
    final modes =
        (attrs['supported_color_modes'] as List?)?.cast<String>() ?? const [];
    final hasTemp = modes.contains('color_temp');
    final hasColor = modes.any(_kColorModes.contains);
    final minK = (attrs['min_color_temp_kelvin'] as num?)?.toDouble() ?? 2000;
    final maxK = (attrs['max_color_temp_kelvin'] as num?)?.toDouble() ?? 6500;
    final curK =
        (attrs['color_temp_kelvin'] as num?)?.toDouble() ?? (minK + maxK) / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _slider('bri', 'Brightness', b / 255 * 100, 0, 100,
            (v) => _svc('turn_on', {'brightness_pct': v.round()}),
            suffix: '%'),
        if (hasTemp)
          _slider('ct', 'Color temp', curK.clamp(minK, maxK), minK, maxK,
              (v) => _svc('turn_on', {'color_temp_kelvin': v.round()}),
              suffix: 'K'),
        if (hasColor) ...[
          const SizedBox(height: 12),
          const Text('Color', style: TextStyle(color: Color(0x99FFFFFF))),
          const SizedBox(height: 10),
          _colorSwatches(),
        ],
      ],
    );
  }

  Widget _colorSwatches() {
    const swatches = <List<int>>[
      [255, 0, 0], [255, 128, 0], [255, 225, 0], [0, 220, 60],
      [0, 200, 255], [0, 60, 255], [150, 0, 240], [255, 0, 200],
      [255, 255, 255],
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final c in swatches)
          GestureDetector(
            onTap: () => _svc('turn_on', {'rgb_color': c}),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Color.fromARGB(255, c[0], c[1], c[2]),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x33FFFFFF)),
              ),
            ),
          ),
      ],
    );
  }

  // Alarm/vacuum capabilities are only knowable from the supported_features
  // bitmask (no attribute reveals them). These bit values come from HA core's
  // const files; they're stable and unchanged for years. See memory note
  // "supported-features-bitmask".
  Widget _alarm(Map attrs, String state) {
    final f = (attrs['supported_features'] as num?)?.toInt() ?? 0;
    const armHome = 1, armAway = 2, armNight = 4, armCustom = 16, armVacation = 32;
    // NOTE: panels with code_arm_required / code_format need a code we don't yet
    // collect — a PIN pad is a follow-up. Works today for codeless panels.
    final btns = <Widget>[
      if (state != 'disarmed') _btn('Disarm', () => _svc('alarm_disarm')),
      if (f & armHome != 0) _btn('Arm Home', () => _svc('alarm_arm_home')),
      if (f & armAway != 0) _btn('Arm Away', () => _svc('alarm_arm_away')),
      if (f & armNight != 0) _btn('Arm Night', () => _svc('alarm_arm_night')),
      if (f & armVacation != 0)
        _btn('Arm Vacation', () => _svc('alarm_arm_vacation')),
      if (f & armCustom != 0)
        _btn('Custom Bypass', () => _svc('alarm_arm_custom_bypass')),
    ];
    return Wrap(spacing: 10, runSpacing: 10, children: btns);
  }

  Widget _vacuum(Map attrs) {
    final f = (attrs['supported_features'] as num?)?.toInt() ?? 0;
    final speed = attrs['fan_speed'] as String?;
    final speeds = (attrs['fan_speed_list'] as List?)?.cast<String>() ?? const [];
    const pause = 4,
        stop = 8,
        returnHome = 16,
        fanSpeed = 32,
        locate = 512,
        cleanSpot = 1024,
        start = 8192;
    final btns = <Widget>[
      if (f & start != 0) _btn('Start', () => _svc('start')),
      if (f & pause != 0) _btn('Pause', () => _svc('pause')),
      if (f & stop != 0) _btn('Stop', () => _svc('stop')),
      if (f & returnHome != 0) _btn('Dock', () => _svc('return_to_base')),
      if (f & locate != 0) _btn('Locate', () => _svc('locate')),
      if (f & cleanSpot != 0) _btn('Spot', () => _svc('clean_spot')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 10, runSpacing: 10, children: btns),
        if (f & fanSpeed != 0 && speeds.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Fan speed', style: TextStyle(color: Color(0x99FFFFFF))),
          const SizedBox(height: 8),
          _options(speeds, speed ?? '',
              (s) => _svc('set_fan_speed', {'fan_speed': s})),
        ],
      ],
    );
  }

  Widget _valve(Map attrs) {
    // Valve exposes current_position only when reports_position is true.
    final pos = (attrs['current_position'] as num?)?.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _btn('Open', () => _svc('open_valve')),
          const SizedBox(width: 10),
          _btn('Stop', () => _svc('stop_valve')),
          const SizedBox(width: 10),
          _btn('Close', () => _svc('close_valve')),
        ]),
        if (pos != null)
          _slider('valve', 'Position', pos, 0, 100,
              (v) => _svc('set_valve_position', {'position': v.round()}),
              suffix: '%'),
      ],
    );
  }

  Widget _waterHeater(Map attrs, String state, Color accent) {
    final cur = attrs['current_temperature'];
    final target = (attrs['temperature'] as num?)?.toDouble();
    final step = (attrs['target_temp_step'] as num?)?.toDouble() ?? 1.0;
    final lo = (attrs['min_temp'] as num?)?.toDouble();
    final hi = (attrs['max_temp'] as num?)?.toDouble();
    // water_heater state IS the current operation mode (eco, electric, …).
    final modes = (attrs['operation_list'] as List?)?.cast<String>() ?? const [];
    final away = attrs['away_mode'] as String?;
    double clampT(double t) =>
        t.clamp(lo ?? double.negativeInfinity, hi ?? double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cur != null)
          Text('Current: $cur°',
              style: const TextStyle(color: Color(0x99FFFFFF))),
        if (target != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            _btn('−',
                () => _svc('set_temperature', {'temperature': clampT(target - step)})),
            const SizedBox(width: 14),
            Text('${target.toStringAsFixed(target == target.roundToDouble() ? 0 : 1)}°',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(width: 14),
            _btn('+',
                () => _svc('set_temperature', {'temperature': clampT(target + step)})),
          ]),
        ],
        if (modes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _options(
              modes, state, (m) => _svc('set_operation_mode', {'operation_mode': m})),
        ],
        if (away != null) ...[
          const SizedBox(height: 12),
          _pill('Away', away == 'on', accent,
              () => _svc('set_away_mode', {'away_mode': away != 'on'})),
        ],
      ],
    );
  }

  Widget _humidifier(Map attrs, bool on, Color accent) {
    final cur = attrs['current_humidity'];
    final target = (attrs['humidity'] as num?)?.toDouble();
    final lo = (attrs['min_humidity'] as num?)?.toDouble() ?? 0;
    final hi = (attrs['max_humidity'] as num?)?.toDouble() ?? 100;
    final mode = attrs['mode'] as String? ?? '';
    final modes = (attrs['available_modes'] as List?)?.cast<String>() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cur != null)
          Text('Current: $cur%',
              style: const TextStyle(color: Color(0x99FFFFFF))),
        if (target != null)
          _slider('hum', 'Target', target, lo, hi,
              (v) => _svc('set_humidity', {'humidity': v.round()}),
              suffix: '%'),
        if (modes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _options(modes, mode, (m) => _svc('set_mode', {'mode': m})),
        ],
      ],
    );
  }

  // ── Shared control widgets ──────────────────────────────────────────────
  Widget _slider(String key, String label, double value, double min, double max,
      ValueChanged<double> onEnd,
      {String suffix = '', double? step}) {
    final v = (_drag[key] ?? value).clamp(min, max);
    final divisions =
        step != null && step > 0 ? ((max - min) / step).round() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(children: [
          Text(label, style: const TextStyle(color: Color(0x99FFFFFF))),
          const Spacer(),
          Text('${v.round()}$suffix',
              style: const TextStyle(color: Colors.white)),
        ]),
        Slider(
          value: v,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (nv) => setState(() => _drag[key] = nv),
          onChangeEnd: (nv) {
            onEnd(nv);
            setState(() => _drag.remove(key));
          },
        ),
      ],
    );
  }

  Widget _options(List<String> opts, String current, ValueChanged<String> onSel) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in opts)
          GestureDetector(
            onTap: () => onSel(o),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: o == current
                    ? ConfigScope.of(context).accent
                    : const Color(0x14FFFFFF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(o,
                  style: const TextStyle(color: Colors.white)),
            ),
          ),
      ],
    );
  }

  Widget _pill(String label, bool on, Color accent, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: on ? accent : const Color(0x22FFFFFF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _btn(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0x1FFFFFFF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _wideBtn(String label, Color accent, VoidCallback onTap) => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: accent, borderRadius: BorderRadius.circular(14)),
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
      );

  Widget _iconBtn(IconData icon, VoidCallback onTap, {bool big = false}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: big ? 60 : 48,
          height: big ? 60 : 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: big
                ? ConfigScope.of(context).accent
                : const Color(0x1FFFFFFF),
          ),
          child: Icon(icon, color: Colors.white, size: big ? 32 : 24),
        ),
      );
}

Widget _cardWidget(CardSpec card) {
  switch (card.kind) {
    case CardKind.weather:
      return _WeatherStrip(spec: card);
    case CardKind.camera:
      return CameraCard(spec: card);
    case CardKind.calendar:
      return CalendarCard(spec: card);
    case CardKind.haStatus:
      return const RoomCard();
    case CardKind.entity:
      return _EntityCard(spec: card);
  }
}

String entityDomain(String id) {
  final i = id.indexOf('.');
  return i < 0 ? id : id.substring(0, i);
}

IconData entityIcon(String id, bool on) {
  switch (entityDomain(id)) {
    case 'light':
      return on ? Icons.lightbulb : Icons.lightbulb_outline;
    case 'switch':
    case 'input_boolean':
      return on ? Icons.toggle_on : Icons.toggle_off_outlined;
    case 'climate':
      return Icons.thermostat;
    case 'camera':
      return Icons.videocam_rounded;
    case 'media_player':
      return Icons.speaker_rounded;
    case 'scene':
      return Icons.palette_outlined;
    case 'script':
      return Icons.code_rounded;
    case 'automation':
      return Icons.bolt_rounded;
    case 'group':
      return Icons.dashboard_customize_rounded;
    case 'sensor':
    case 'binary_sensor':
      return Icons.sensors_rounded;
    case 'fan':
      return Icons.air_rounded;
    case 'lock':
      return on ? Icons.lock_open_rounded : Icons.lock_rounded;
    case 'cover':
      return Icons.blinds_rounded;
    case 'valve':
      return Icons.water_drop_outlined;
    case 'vacuum':
      return Icons.cleaning_services_rounded;
    case 'humidifier':
      return Icons.water_drop_rounded;
    case 'water_heater':
      return Icons.water_rounded;
    case 'alarm_control_panel':
      return Icons.shield_rounded;
    case 'person':
    case 'device_tracker':
      return Icons.person_rounded;
    case 'input_number':
    case 'number':
      return Icons.tag_rounded;
    case 'input_select':
    case 'select':
      return Icons.list_rounded;
    case 'input_text':
    case 'text':
      return Icons.text_fields_rounded;
    case 'input_button':
    case 'button':
      return Icons.smart_button_rounded;
    case 'input_datetime':
    case 'date':
    case 'time':
    case 'datetime':
      return Icons.schedule_rounded;
    case 'counter':
      return Icons.exposure_rounded;
    case 'timer':
      return Icons.timer_rounded;
    case 'schedule':
      return Icons.calendar_month_rounded;
    case 'weather':
      return Icons.cloud_rounded;
    case 'update':
      return Icons.system_update_rounded;
    case 'siren':
      return Icons.notifications_active_rounded;
    case 'calendar':
      return Icons.event_rounded;
    case 'todo':
      return Icons.checklist_rounded;
  }
  return Icons.devices_other_rounded;
}

/// Generic card for a user-added HA entity; live state from the catalog.
/// Honors the HA-style per-card config (name, show name/state/icon, vertical).
class _EntityCard extends StatelessWidget {
  final CardSpec spec;
  const _EntityCard({required this.spec});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final entityId = spec.entityId ?? '';
    final st = EntityScope.of(context).state(entityId);
    final name = spec.name ??
        (st?['attributes'] as Map?)?['friendly_name'] as String? ??
        entityId;
    final state = st?['state'] as String? ?? '—';
    final on = state == 'on';
    final accent =
        CardOverride.maybeOf(context)?.color ?? ConfigScope.of(context).accent;

    final icon = Icon(entityIcon(entityId, on),
        size: 26 * s, color: on ? accent : const Color(0xCCFFFFFF));
    final texts = Column(
      crossAxisAlignment:
          spec.vertical ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spec.showName)
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: spec.vertical ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                  fontSize: 16 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        if (spec.showState)
          Text(state,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 13 * s, color: const Color(0x99FFFFFF))),
      ],
    );

    final Widget body = spec.vertical
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (spec.showIcon) ...[icon, SizedBox(height: 8 * s)],
              texts,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: spec.showIcon
                ? MainAxisAlignment.spaceBetween
                : MainAxisAlignment.end,
            children: [
              if (spec.showIcon) icon,
              texts,
            ],
          );

    return LiquidGlass(
      child: Padding(padding: EdgeInsets.all(16 * s), child: body),
    );
  }
}

class _WeatherStrip extends StatelessWidget {
  final CardSpec? spec;
  const _WeatherStrip({this.spec});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final w = WeatherScope.of(context).data;
    final showCurrent = spec?.showCurrent ?? true;
    final temp = (w != null && (spec?.roundTemp ?? false))
        ? '${w.tempF}'
        : '${w?.tempF}';
    final condTemp =
        w == null ? 'Loading…' : '${w.condition}  ·  $temp °F';
    return LiquidGlass(
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
                    if (spec?.name != null)
                      Text(spec!.name!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13 * s,
                              color: const Color(0x99FFFFFF))),
                    Text(_hourMinuteAmPm(now),
                        style: TextStyle(
                            fontSize: 24 * s,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    Text(showCurrent ? '$date  ·  $condTemp' : date,
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
  /// Optional per-card config. When null (e.g. idle/preview) the card
  /// auto-picks a camera and uses defaults.
  final CardSpec? spec;
  const CameraCard({super.key, this.spec});

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
  void didUpdateWidget(CameraCard old) {
    super.didUpdateWidget(old);
    // Refetch immediately when the bound entity changes via settings.
    if (old.spec?.entityId != widget.spec?.entityId) _tick();
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

  BoxFit get _boxFit {
    switch (widget.spec?.fit) {
      case 'contain':
        return BoxFit.contain;
      case 'fill':
        return BoxFit.fill;
      default:
        return BoxFit.cover;
    }
  }

  double? get _aspect {
    switch (widget.spec?.aspect) {
      case '16:9':
        return 16 / 9;
      case '4:3':
        return 4 / 3;
      case '1:1':
        return 1;
      default:
        return null;
    }
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final ha = HaScope.of(context);
    final cat = EntityScope.of(context);
    if (!ha.ready) return;
    // Use the bound entity if configured, else auto-pick.
    final configured = widget.spec?.entityId;
    final id = (configured != null && configured.startsWith('camera.'))
        ? configured
        : _pickCamera(cat);
    if (id == null) return;
    final bytes = await ha.cameraSnapshot(id);
    if (!mounted || bytes == null) return;
    setState(() {
      _frame = bytes;
      _name = widget.spec?.name ??
          (cat.state(id)?['attributes'] as Map?)?['friendly_name'] as String?;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final spec = widget.spec;
    final r = BorderRadius.circular(18);
    // RepaintBoundary keeps the camera its own layer — when the feed updates it
    // won't repaint the rest of the UI, and vice versa.
    Widget card = RepaintBoundary(
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
                Image.memory(_frame!, fit: _boxFit, gaplessPlayback: true)
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
              if (spec?.showName ?? true)
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
    final ar = _aspect;
    if (ar != null) {
      card = Center(child: AspectRatio(aspectRatio: ar, child: card));
    }
    return card;
  }
}

class CalendarCard extends StatelessWidget {
  final CardSpec? spec;
  const CalendarCard({super.key, this.spec});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final now = DateTime.now();
    // initial_view drives how many upcoming days to list (placeholder until the
    // real HA/CalDAV-backed calendar lands): day=1, month=4, list=7.
    final days = switch (spec?.initialView) {
      'day' => 1,
      'list' => 7,
      _ => 4,
    };
    return LiquidGlass(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 8 * s),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (spec?.name != null)
              Padding(
                padding: EdgeInsets.only(top: 8 * s, bottom: 2 * s),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(spec!.name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 16 * s,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ...List.generate(days, (i) {
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
          ],
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

  /// Force the BackdropFilter frosted path instead of the glow-sampling shader.
  /// Used over backgrounds the shader doesn't know about (e.g. the idle waves),
  /// so the blur reflects what's actually behind the card.
  final bool forceFrosted;

  const LiquidGlass({
    super.key,
    required this.child,
    this.height,
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
    final ov = CardOverride.maybeOf(context);
    final cardColor = ov?.color ?? cfg.cardColor;
    final radius = cfg.cornerRadius;
    final r = BorderRadius.circular(radius);

    // forceFrosted (idle weather card) always blurs the real background.
    // Otherwise a per-card override wins over the global cardStyle.
    var style = widget.forceFrosted
        ? CardStyle.frosted
        : (ov?.style ?? cfg.cardStyle);
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
                color: cardColor.withValues(alpha: 0.12),
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
            color: cardColor.withValues(alpha: 0.92),
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
                color: cardColor.withValues(alpha: 0.75), width: 1.5),
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
/// Idle screen uses a STATIC aurora — painted once at a fixed phase and never
/// repainted. Keeps the long idle hours at near-zero GPU. Future transient
/// idle animations (notifications, AI speaking bar) will be their own small,
/// on-demand layers rather than animating this whole background.
class IdleBackground extends StatelessWidget {
  const IdleBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _StaticScenePainter((c, s) => paintWaves(c, s, 0)),
        size: Size.infinite,
      ),
    );
  }
}

/// Paints a scene once and never repaints.
class _StaticScenePainter extends CustomPainter {
  final void Function(Canvas, Size) draw;
  _StaticScenePainter(this.draw);

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(covariant _StaticScenePainter old) => false;
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
    final layout = LayoutScope.of(context);
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
            _label('Pages'),
            Row(
              children: [
                Expanded(
                  child: Text(
                      'Page ${layout.activePage + 1} of ${layout.pageCount}',
                      style: const TextStyle(color: Color(0xB3FFFFFF))),
                ),
                TextButton.icon(
                  // Can't delete the last remaining page.
                  onPressed: layout.pageCount > 1
                      ? () {
                          layout.removePage(layout.activePage);
                          onClose();
                        }
                      : null,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete page'),
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFE0697A),
                      disabledForegroundColor: const Color(0x33FFFFFF)),
                ),
              ],
            ),
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
