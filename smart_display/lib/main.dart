import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Loaded once at startup; null if the GPU/back-end can't compile it, in which
/// case [LiquidGlass] falls back to a plain frosted panel.
ui.FragmentProgram? glassProgram;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    glassProgram =
        await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
  } catch (_) {
    glassProgram = null; // graceful fallback (e.g. if Pi can't run the shader)
  }
  runApp(const SmartDisplayApp());
}

class SmartDisplayApp extends StatelessWidget {
  const SmartDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tuneout Display',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'SF Pro'),
      home: const RootShell(),
    );
  }
}

/// Exposes the shared animation clock so the background and every glass card
/// refract the *same* moment of the glow field.
class GlassClock extends InheritedWidget {
  final Animation<double> clock;
  const GlassClock({super.key, required this.clock, required super.child});

  static Animation<double> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassClock>()!.clock;

  @override
  bool updateShouldNotify(GlassClock old) => clock != old.clock;
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

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  // Idle screensaver: fade in after this much inactivity; any touch wakes it.
  static const _idleAfter = Duration(minutes: 3);
  static const _fade = Duration(milliseconds: 700);

  late final AnimationController _clock;
  final WeatherController _weather = WeatherController();
  Timer? _idleTimer;
  bool _idle = false;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
    _weather.start();
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _weather.dispose();
    _clock.dispose();
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
    _resetIdleTimer();
  }

  @override
  Widget build(BuildContext context) {
    return WeatherScope(
      controller: _weather,
      child: GlassClock(
      clock: _clock,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onActivity,
        onPointerMove: _onActivity,
        child: Scaffold(
          backgroundColor: const Color(0xFF06080F),
          body: Stack(
            fit: StackFit.expand,
            children: [
              const AnimatedBackground(),
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
            ],
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
double _scale(BuildContext c) =>
    (MediaQuery.sizeOf(c).width / 1600).clamp(0.6, 1.6);

const _weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _month = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
];

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(24 * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const NavChips(),
            SizedBox(height: 18 * s),
            const Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: _LeftColumn()),
                  SizedBox(width: 18),
                  Expanded(flex: 5, child: _RightColumn()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NavChips extends StatelessWidget {
  const NavChips({super.key});

  static const _items = [
    (Icons.grid_view_rounded, 'Overview'),
    (Icons.home_rounded, 'First Floor'),
    (Icons.weekend_rounded, 'Second Floor'),
    (Icons.bed_rounded, 'Third Floor'),
    (Icons.bolt_rounded, 'Energy'),
    (Icons.print_rounded, '3D Printer'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return SizedBox(
      height: 50 * s,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _items.length,
        separatorBuilder: (_, _) => SizedBox(width: 12 * s),
        itemBuilder: (_, i) =>
            _NavChip(icon: _items[i].$1, label: _items[i].$2, active: i == 0),
      ),
    );
  }
}

class _NavChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  const _NavChip(
      {required this.icon, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 18 * s),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(25 * s),
        color: Color(active ? 0x24FFFFFF : 0x0FFFFFFF),
        border: Border.all(color: Color(active ? 0x59FFFFFF : 0x1FFFFFFF)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18 * s, color: Colors.white),
          SizedBox(width: 8 * s),
          Text(label,
              style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
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

/// Camera stays more solid than the glass cards (per the design direction).
/// Placeholder feed for the mockup; the real HA stream slots in later.
class CameraCard extends StatelessWidget {
  const CameraCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
    final r = BorderRadius.circular(18);
    return ClipRRect(
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
                child: Text('Front Door',
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
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFF2E7BFF), Color(0xFF1E5FE0)],
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x552E7BFF), blurRadius: 18, offset: Offset(0, 6)),
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

class RoomCard extends StatelessWidget {
  const RoomCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);
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
                Text("Jake's Room",
                    style: TextStyle(
                        fontSize: 22 * s,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 14 * s, vertical: 6 * s),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE0A53B)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8 * s,
                        height: 8 * s,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Color(0xFFE0A53B)),
                      ),
                      SizedBox(width: 8 * s),
                      Text('Muted',
                          style: TextStyle(
                              fontSize: 14 * s,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFE0A53B))),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Icon(Icons.speaker_rounded,
                    size: 20 * s, color: const Color(0x99FFFFFF)),
                SizedBox(width: 10 * s),
                Text('Speaker · Idle',
                    style: TextStyle(
                        fontSize: 15 * s, color: const Color(0x99FFFFFF))),
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
    final program = glassProgram;
    if (program == null || widget.forceFrosted) {
      return _FrostedFallback(widget: widget);
    }

    final clock = GlassClock.of(context);
    final screen = MediaQuery.sizeOf(context);
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        key: _paintKey,
        painter: _GlassPainter(
          program: program,
          repaint: clock,
          time: clock,
          screen: screen,
          radius: widget.radius,
          thickness: widget.thickness,
          paintKey: _paintKey,
        ),
        child: widget.child,
      ),
    );
  }
}

class _GlassPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final Animation<double> time;
  final Size screen;
  final double radius;
  final double thickness;
  final GlobalKey paintKey;

  _GlassPainter({
    required this.program,
    required Listenable repaint,
    required this.time,
    required this.screen,
    required this.radius,
    required this.thickness,
    required this.paintKey,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
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
      ..setFloat(7, time.value)
      ..setFloat(8, thickness)
      ..setFloat(9, -2.0);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GlassPainter old) => true;
}

class _FrostedFallback extends StatelessWidget {
  final LiquidGlass widget;
  const _FrostedFallback({required this.widget});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: r,
            color: const Color(0x1FFFFFFF),
            border: Border.all(color: const Color(0x24FFFFFF)),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Idle-screen background: the flowing aurora waves + drifting stars ported
/// from the original idle-v13 screen, driven by the shared clock so the motion
/// wraps seamlessly.
class IdleBackground extends StatelessWidget {
  const IdleBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final clock = GlassClock.of(context);
    return AnimatedBuilder(
      animation: clock,
      builder: (_, _) =>
          CustomPaint(painter: _IdleWavesPainter(clock.value), size: Size.infinite),
    );
  }
}

class _IdleWavesPainter extends CustomPainter {
  final double t;
  _IdleWavesPainter(this.t);

  // (baseFrac, ampFrac, color) for each aurora band.
  static const _layers = [
    (0.18, 0.026, Color(0xFF0B2631)),
    (0.285, 0.036, Color(0xFF0D3144)),
    (0.39, 0.046, Color(0xFF08202E)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const tau = 2 * math.pi;

    // Deep navy vertical gradient base.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF04080E), Color(0xFF0C1A2C)],
        ).createShader(Offset.zero & size),
    );

    // Aurora waves: thick, soft, smoothly drifting sine bands.
    for (var li = 0; li < _layers.length; li++) {
      final (baseFrac, ampFrac, color) = _layers[li];
      final baseY = h * baseFrac;
      final amp = h * ampFrac;
      final phase = t * tau * (li + 1); // integer cycles → seamless loop
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

    // Drifting stars.
    final starMax = math.max(80, (h * 0.55).toInt());
    for (var i = 0; i < 12; i++) {
      final x = (i * 137 + t * w * 2) % w;
      final y = 35 + (i * 53) % starMax;
      final pulse = (math.sin(t * tau * 3 + i) + 1) / 2;
      final color =
          pulse < 0.65 ? const Color(0xFF173849) : const Color(0xFF24586B);
      canvas.drawCircle(
        Offset(x, y.toDouble()),
        i % 4 == 0 ? 2 : 1,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _IdleWavesPainter old) => old.t != t;
}

class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final clock = GlassClock.of(context);
    return AnimatedBuilder(
      animation: clock,
      builder: (_, _) =>
          CustomPaint(painter: _GlowPainter(clock.value), size: Size.infinite),
    );
  }
}

class _GlowPainter extends CustomPainter {
  final double t;
  _GlowPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
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

  @override
  bool shouldRepaint(covariant _GlowPainter old) => old.t != t;
}
