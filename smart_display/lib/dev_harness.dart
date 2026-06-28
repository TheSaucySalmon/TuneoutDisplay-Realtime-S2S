part of 'main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Dev-only on-host test harness.
//
// The dev host has no Home Assistant connection (no ~/.config/smart-display/
// ha.json — the token lives only on the Pi), and no input-automation tooling to
// tap cards. These hooks let us exercise the real UI on this machine:
//
//   SMARTDISPLAY_DEMO=1
//       When HA is NOT configured, seed the EntityCatalog with representative
//       fake entities (one per controllable domain) so pickers/sheets have data.
//
//   SMARTDISPLAY_MOREINFO=<entity_id>
//       After first frame, open that entity's more-info sheet — via the exact
//       same scope-re-injection path as a real tap — so a single launch +
//       screenshot shows the control widget under test.
//
// Both are gated on env vars that are never set on the Pi, so production is
// completely unaffected. The seed only runs when HA is unconfigured, which is
// itself never true on the device.
// ─────────────────────────────────────────────────────────────────────────────

extension _DevHarnessCatalog on EntityCatalog {
  void _fillDemo() {
    _entities
      ..clear()
      ..addEntries(
          _kDemoEntities.map((e) => MapEntry(e['entity_id'] as String, e)));
  }

  /// Returns true if the demo set was seeded (caller should notify listeners).
  bool _maybeSeedDemo() {
    if (Platform.environment['SMARTDISPLAY_DEMO'] != '1') return false;
    _fillDemo();
    return true;
  }
}

/// Builds the real [_MoreInfoSheet] for a demo entity, fully scoped, for headless
/// widget tests. The GUI app can't render on the dev host (no GL), so this is how
/// Phase 2 controls are verified here; live visual checks happen on the Pi.
@visibleForTesting
Widget buildDemoMoreInfoSheet(String entityId) {
  final catalog = EntityCatalog().._fillDemo();
  return ConfigScope(
    config: AppConfig(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0E14),
        body: HaScope(
          client: HaClient(),
          child: EntityScope(
            catalog: catalog,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _MoreInfoSheet(entityId: entityId),
            ),
          ),
        ),
      ),
    ),
  );
}

extension _DevHarnessShell on _RootShellState {
  void _maybeAutoOpenMoreInfo() {
    final id = Platform.environment['SMARTDISPLAY_MOREINFO'];
    if (id == null || id.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Mirror _showMoreInfo: re-inject HaScope + EntityScope around the sheet
      // (modal bottom sheets don't inherit RootShell's scopes).
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => HaScope(
          client: _ha,
          child: EntityScope(
            catalog: _catalog,
            child: _MoreInfoSheet(entityId: id),
          ),
        ),
      );
    });
  }
}

/// Wraps an [_AdjustableCard] for a demo (adjustable) light at a fixed size so a
/// widget test can assert the card fills its slot. Pass a `LayoutBuilder` as
/// [child] to capture the constraints the card hands down.
@visibleForTesting
Widget buildAdjustableCardForTest({
  required Widget child,
  Size size = const Size(200, 100),
  String entityId = 'light.demo_light',
}) {
  final catalog = EntityCatalog().._fillDemo();
  return ConfigScope(
    config: AppConfig(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: HaScope(
              client: HaClient(),
              child: EntityScope(
                catalog: catalog,
                child: _AdjustableCard(
                  card: CardSpec(
                      id: 't',
                      kind: CardKind.entity,
                      entityId: entityId,
                      col: 0,
                      row: 0,
                      w: 2,
                      h: 1),
                  onTap: () {},
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Representative fake entities, one per controllable domain, in HA state shape
/// (`{entity_id, state, attributes}`). Attribute values are chosen so the
/// per-domain control widgets render their full surface.
const List<Map<String, dynamic>> _kDemoEntities = [
  {
    'entity_id': 'light.demo_light',
    'state': 'on',
    'attributes': {
      'friendly_name': 'Demo Light',
      'brightness': 180,
      'color_mode': 'color_temp',
      'supported_color_modes': ['color_temp', 'hs'],
      'color_temp_kelvin': 3200,
      'min_color_temp_kelvin': 2000,
      'max_color_temp_kelvin': 6500,
      'hs_color': [35.0, 90.0],
      'rgb_color': [255, 180, 60],
    },
  },
  {
    'entity_id': 'valve.demo_valve',
    'state': 'open',
    'attributes': {
      'friendly_name': 'Demo Water Valve',
      'device_class': 'water',
      'current_position': 70,
      'supported_features': 15, // OPEN|CLOSE|SET_POSITION|STOP
    },
  },
  {
    'entity_id': 'water_heater.demo_tank',
    'state': 'eco',
    'attributes': {
      'friendly_name': 'Demo Water Heater',
      'current_temperature': 48.0,
      'temperature': 50.0,
      'min_temp': 40.0,
      'max_temp': 65.0,
      'target_temp_step': 1.0,
      'operation_list': ['eco', 'electric', 'performance', 'off'],
      'operation_mode': 'eco',
      'away_mode': 'off',
      'supported_features': 11, // TARGET_TEMPERATURE|OPERATION_MODE|ON_OFF
    },
  },
  {
    'entity_id': 'humidifier.demo_humidifier',
    'state': 'on',
    'attributes': {
      'friendly_name': 'Demo Humidifier',
      'current_humidity': 41,
      'humidity': 50,
      'min_humidity': 30,
      'max_humidity': 70,
      'mode': 'normal',
      'available_modes': ['normal', 'eco', 'baby', 'auto'],
      'action': 'humidifying',
      'supported_features': 1, // MODES
    },
  },
  {
    'entity_id': 'date.demo_date',
    'state': '2026-06-25',
    'attributes': {'friendly_name': 'Demo Date'},
  },
  {
    'entity_id': 'time.demo_time',
    'state': '08:30:00',
    'attributes': {'friendly_name': 'Demo Time'},
  },
  {
    'entity_id': 'datetime.demo_datetime',
    'state': '2026-06-25 08:30:00',
    'attributes': {'friendly_name': 'Demo Datetime'},
  },
  {
    'entity_id': 'media_player.demo_player',
    'state': 'playing',
    'attributes': {
      'friendly_name': 'Demo Speaker',
      'volume_level': 0.4,
      'source': 'Spotify',
      'source_list': ['Spotify', 'Radio', 'TV', 'Aux'],
      'sound_mode': 'Stereo',
      'sound_mode_list': ['Stereo', 'Surround', 'Night'],
      'media_title': 'Demo Track',
      'media_artist': 'Demo Artist',
    },
  },
  {
    'entity_id': 'alarm_control_panel.demo_alarm',
    'state': 'disarmed',
    'attributes': {
      'friendly_name': 'Demo Alarm',
      'code_arm_required': false,
      // ARM_HOME|ARM_AWAY|ARM_NIGHT|TRIGGER|ARM_VACATION
      'supported_features': 47,
    },
  },
  {
    'entity_id': 'vacuum.demo_vacuum',
    'state': 'docked',
    'attributes': {
      'friendly_name': 'Demo Vacuum',
      'fan_speed': 'medium',
      'fan_speed_list': ['quiet', 'medium', 'turbo', 'max'],
      // START|STATE|CLEAN_SPOT|LOCATE|FAN_SPEED|RETURN_HOME|STOP|PAUSE
      // = 8192+4096+1024+512+32+16+8+4
      'supported_features': 13884,
    },
  },
];
