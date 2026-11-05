// Merangkai identitas, penyimpanan, mesh, transport, lokasi, dan foreground service.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'mesh/crypto.dart';
import 'mesh/mesh_core.dart';
import 'mesh/store.dart';
import 'transport/nearby_transport.dart';
import 'transport/node_transport.dart';

late AppState app;

class AppState extends ChangeNotifier {
  AppState._(this.prefs);

  final SharedPreferences prefs;
  Identity? identity;
  MeshCore? mesh;
  NearbyTransport? nearby;
  final node = NodeTransport();

  bool shareLocation = false;
  bool emergencyOnly = false;
  Position? lastPosition;
  int unread = 0;

  Timer? _helloTimer, _pruneTimer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<MeshEvent>? _eventSub;

  /// Dipanggil UI untuk menampilkan SOS masuk segera.
  void Function(SosAlert)? onSos;

  static Future<AppState> load() async {
    final s = AppState._(await SharedPreferences.getInstance());
    s.shareLocation = s.prefs.getBool('shareLocation') ?? false;
    s.emergencyOnly = s.prefs.getBool('emergencyOnly') ?? false;
    final raw = s.prefs.getString('identity');
    if (raw != null) {
      s.identity = await Identity.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      await s._startMesh();
    }
    return s;
  }

  bool get hasIdentity => identity != null;

  Future<void> createIdentity(String name) async {
    identity = await Identity.generate(name.trim());
    await prefs.setString('identity', jsonEncode(identity!.toJson()));
    await _startMesh();
    notifyListeners();
  }

  Future<void> rename(String name) async {
    if (identity == null || name.trim().isEmpty) return;
    identity = identity!.rename(name.trim());
    mesh?.me = identity!;
    await prefs.setString('identity', jsonEncode(identity!.toJson()));
    await mesh?.sendHello();
    notifyListeners();
  }

  Future<void> _startMesh() async {
    final me = identity!;
    final store = await MeshStore.open(databaseFactory, p.join(await getDatabasesPath(), 'meshlokal.db'));
    final core = MeshCore(me, store)
      ..emergencyOnly = emergencyOnly
      ..shareLocation = () {
        final pos = lastPosition;
        return shareLocation && pos != null ? (lat: pos.latitude, lon: pos.longitude) : null;
      };
    await core.init();
    nearby = NearbyTransport(nickname: me.name, shortId: me.shortId);
    core
      ..addTransport(nearby!)
      ..addTransport(node);
    core.addListener(notifyListeners);
    mesh = core;

    _eventSub = core.events.listen((e) {
      if (e.sos != null) {
        onSos?.call(e.sos!);
        _notify('SOS dari ${e.sos!.name}');
      } else {
        unread++;
        _notify('$unread pesan baru');
      }
    });
    _restartHelloTimer();
    _pruneTimer = Timer.periodic(const Duration(hours: 1), (_) => store.pruneRelay());
    if (shareLocation) _startLocation();
  }

  void _restartHelloTimer() {
    _helloTimer?.cancel();
    final every = emergencyOnly ? const Duration(minutes: 5) : const Duration(minutes: 1);
    _helloTimer = Timer.periodic(every, (_) => mesh?.sendHello());
  }

  /// Minta izin lalu nyalakan semua transport. Aman dipanggil berulang.
  Future<String?> startNetworking() async {
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.notification,
    ].request();
    final denied = statuses.entries
        .where((e) => e.key != Permission.notification && (e.value.isDenied || e.value.isPermanentlyDenied))
        .map((e) => e.key.toString().split('.').last)
        .toList();

    await _startForegroundService();
    node.start();
    // Tetap coba jalan walau ada izin yang ditolak: di Android lama sebagian izin tidak berlaku.
    await nearby?.start();
    nearby?.setLowPower(emergencyOnly);
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Nyalakan Lokasi (GPS) di HP. Android mewajibkannya untuk mencari HP lain di sekitar.';
    }
    if (denied.isNotEmpty) {
      return 'Izin belum diberikan: ${denied.join(', ')}. Koneksi HP ke HP mungkin tidak jalan.';
    }
    return nearby?.lastError;
  }

  Future<void> stopNearby() async {
    await nearby?.stop();
    notifyListeners();
  }

  // ---------- pengaturan ----------
  Future<void> setShareLocation(bool v) async {
    shareLocation = v;
    await prefs.setBool('shareLocation', v);
    v ? _startLocation() : _stopLocation();
    if (v) await mesh?.sendHello();
    notifyListeners();
  }

  Future<void> setEmergencyOnly(bool v) async {
    emergencyOnly = v;
    await prefs.setBool('emergencyOnly', v);
    mesh?.emergencyOnly = v;
    nearby?.setLowPower(v);
    _restartHelloTimer();
    notifyListeners();
  }

  // ---------- lokasi ----------
  Future<Position?> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return lastPosition;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return lastPosition;
      // GPS tetap jalan tanpa sinyal seluler, tapi fix pertama bisa lama.
      lastPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
    } catch (_) {
      lastPosition ??= await Geolocator.getLastKnownPosition();
    }
    notifyListeners();
    return lastPosition;
  }

  void _startLocation() {
    _posSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25),
    ).listen((pos) {
      lastPosition = pos;
      notifyListeners();
    }, onError: (_) {});
  }

  void _stopLocation() {
    _posSub?.cancel();
    _posSub = null;
  }

  // ---------- foreground service: supaya relay tetap jalan saat layar mati ----------
  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshlokal_relay',
        channelName: 'Relay MeshLokal',
        channelDescription: 'Menjaga HP tetap meneruskan pesan di latar belakang.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.startService(
      serviceId: 7,
      notificationTitle: 'MeshLokal aktif',
      notificationText: 'Meneruskan pesan di sekitar',
      callback: foregroundStartCallback,
    );
  }

  void _notify(String text) {
    FlutterForegroundTask.updateService(notificationTitle: 'MeshLokal', notificationText: text);
  }

  void clearUnread() {
    if (unread == 0) return;
    unread = 0;
    _notify('Meneruskan pesan di sekitar');
  }

  /// Hapus identitas dan semua data lokal.
  Future<void> wipe() async {
    _helloTimer?.cancel();
    _pruneTimer?.cancel();
    _stopLocation();
    await _eventSub?.cancel();
    await nearby?.stop();
    node.stop();
    await mesh?.store.wipe();
    await mesh?.store.db.close();
    mesh?.removeListener(notifyListeners);
    mesh = null;
    nearby = null;
    identity = null;
    await prefs.remove('identity');
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    notifyListeners();
  }
}

// Isolate foreground service tidak melakukan apa-apa: keberadaannya saja yang menjaga
// proses aplikasi (dan mesh di isolate utama) tetap hidup.
@pragma('vm:entry-point')
void foregroundStartCallback() => FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());

class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
