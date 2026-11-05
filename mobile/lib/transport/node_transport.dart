// HP <-> node ESP32-CAM lewat WiFi AP milik node (tanpa internet).
// API node: lihat firmware/esp32cam/mesh.h
//   GET  /mesh/info                      info node + tetangga node
//   GET  /mesh/pull?boot=<b>&since=<s>   pesan baru sejak urutan s
//   POST /mesh/push                      kirim pesan (NDJSON)
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_iot/wifi_iot.dart';

import '../mesh/mesh_core.dart';
import '../mesh/protocol.dart';

/// IP AP tiap node: cam1 = 192.168.4.1, camN = 192.168.(10+N).1
const kKnownNodeIps = ['192.168.4.1', '192.168.12.1', '192.168.13.1', '192.168.14.1', '192.168.15.1'];
const kNodeSsidPrefix = 'MeshLokal-cam';
const kNodePassword = '12345678';

class NodeNeighbor {
  NodeNeighbor(this.id, this.name, this.ageSec, this.ip);
  final String id, name;
  final int ageSec;
  final String? ip;
}

class NodeInfo {
  NodeInfo(this.id, this.name, this.ip, this.ssid, this.neighbors);
  final String id, name, ip, ssid;
  final List<NodeNeighbor> neighbors;

  static NodeInfo fromJson(Map<String, dynamic> j, String ip) => NodeInfo(
        '${j['id']}',
        '${j['name'] ?? j['id']}',
        ip,
        '${j['ap'] ?? ''}',
        [
          for (final n in (j['neighbors'] as List? ?? const []))
            if (n is Map) NodeNeighbor('${n['id']}', '${n['name'] ?? n['id']}', (n['age'] as num?)?.toInt() ?? 0, n['ip'] as String?),
        ],
      );
}

class NodeTransport extends MeshTransport {
  NodeInfo? node;
  String? manualIp;
  int _boot = -1, _since = 0, _fails = 0;
  Timer? _timer;
  bool _busy = false;
  bool _wifiForced = false;
  final _client = http.Client();

  String? get baseUrl => node == null ? null : 'http://${node!.ip}';
  String get _link => 'node:${node?.id}';

  @override
  int get linkCount => node == null ? 0 : 1;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    node = null;
  }

  /// Minta Android menyambung ke WiFi node (muncul dialog sistem di Android 10+).
  static Future<bool> joinNodeWifi(int camNumber) async {
    final ok = await WiFiForIoTPlugin.connect(
      '$kNodeSsidPrefix$camNumber',
      password: kNodePassword,
      security: NetworkSecurity.WPA,
      joinOnce: true,
      withInternet: false,
    );
    if (ok) await WiFiForIoTPlugin.forceWifiUsage(true);
    return ok;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      if (node == null) {
        await _detect();
      } else {
        await _pull();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _detect() async {
    // Tanpa ini, Android bisa mengirim request lewat data seluler karena WiFi node "tanpa internet".
    if (!_wifiForced) {
      try {
        _wifiForced = await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {}
    }
    String? gateway;
    try {
      gateway = await NetworkInfo().getWifiGatewayIP();
    } catch (_) {}
    final ips = <String>{
      if (manualIp != null && manualIp!.isNotEmpty) manualIp!,
      if (gateway != null && gateway.isNotEmpty && gateway != '0.0.0.0') gateway,
      ...kKnownNodeIps,
    };
    for (final ip in ips) {
      final info = await fetchInfo(ip);
      if (info != null) {
        node = info;
        _boot = -1;
        _since = 0;
        _fails = 0;
        await core.onLinkUp(this, _link);
        return;
      }
    }
  }

  Future<NodeInfo?> fetchInfo(String ip) async {
    try {
      final r = await _client.get(Uri.parse('http://$ip/mesh/info')).timeout(const Duration(milliseconds: 1500));
      if (r.statusCode != 200) return null;
      return NodeInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>, ip);
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshInfo() async {
    final ip = node?.ip;
    if (ip == null) return;
    final info = await fetchInfo(ip);
    if (info != null) {
      node = info;
      core.onLinksChanged();
    }
  }

  Future<void> _pull() async {
    try {
      final r = await _client
          .get(Uri.parse('$baseUrl/mesh/pull?boot=$_boot&since=$_since'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      _fails = 0;
      final boot = (j['boot'] as num).toInt();
      if (boot != _boot) {
        // Node baru dinyalakan ulang: urutan dimulai dari awal.
        final rebooted = _boot != -1;
        _boot = boot;
        _since = 0;
        if (rebooted) await core.onLinkUp(this, _link);
      }
      _since = (j['seq'] as num).toInt();
      final msgs = (j['msgs'] as List? ?? const []).map((m) => jsonEncode(m)).toList();
      if (msgs.isNotEmpty) await core.onPayload(msgs.join('\n'), _link);
    } catch (e) {
      if (++_fails >= 3) {
        debugPrint('node terputus: $e');
        node = null;
        core.onLinksChanged();
      }
    }
  }

  Future<bool> _push(String payload) async {
    final url = baseUrl;
    if (url == null) return false;
    try {
      final r = await _client
          .post(Uri.parse('$url/mesh/push'), body: utf8.encode(payload), headers: {'Content-Type': 'application/x-ndjson'})
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> broadcast(String wire, {String? exceptLink}) async {
    if (node == null || exceptLink == _link) return 0;
    return await _push(wire) ? 1 : 0;
  }

  @override
  Future<bool> sendBatch(String link, List<String> wires) async {
    var ok = true;
    // Batch kecil: buffer HTTP node terbatas (8 KB).
    for (final p in batchWires(wires, maxBytes: 7000)) {
      ok &= await _push(p);
    }
    return ok;
  }
}
