// HP <-> HP lewat Google Nearby Connections (BLE + WiFi otomatis, tanpa internet).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../mesh/mesh_core.dart';
import '../mesh/protocol.dart';

const _serviceId = 'com.meshlokal.mesh';

class NearbyPeer {
  NearbyPeer(this.endpointId, this.name);
  final String endpointId;
  final String name;
}

class NearbyTransport extends MeshTransport {
  NearbyTransport({required this.nickname, required this.shortId});

  /// Format nama endpoint: `nama|shortId`. shortId dipakai untuk memutuskan
  /// siapa yang meminta koneksi supaya dua HP tidak saling meminta bersamaan.
  final String nickname;
  final String shortId;

  final _nearby = Nearby();
  final connected = <String, NearbyPeer>{}; // endpointId -> peer
  final _pending = <String>{};
  final _names = <String, String>{}; // endpointId -> nama, sebelum koneksi jadi
  bool running = false;
  bool lowPower = false;
  String? lastError;
  Timer? _cycle;

  String get _endpointName => '$nickname|$shortId';

  @override
  int get linkCount => connected.length;

  String _link(String endpointId) => 'nearby:$endpointId';

  Future<void> start() async {
    if (running) return;
    running = true;
    lastError = null;
    try {
      await _nearby.startAdvertising(
        _endpointName,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      lastError = 'Gagal mengiklankan: $e';
    }
    _scheduleDiscovery();
    core.onLinksChanged();
  }

  Future<void> stop() async {
    running = false;
    _cycle?.cancel();
    await _nearby.stopDiscovery();
    await _nearby.stopAdvertising();
    await _nearby.stopAllEndpoints();
    connected.clear();
    _pending.clear();
    core.onLinksChanged();
  }

  void setLowPower(bool v) {
    lowPower = v;
    if (running) _scheduleDiscovery();
  }

  /// Scanning berselang untuk hemat baterai:
  ///   normal: cari 20 detik tiap 45 detik, hemat: 15 detik tiap 3 menit.
  void _scheduleDiscovery() {
    _cycle?.cancel();
    final on = lowPower ? const Duration(seconds: 15) : const Duration(seconds: 20);
    final period = lowPower ? const Duration(minutes: 3) : const Duration(seconds: 45);
    Future<void> burst() async {
      if (!running) return;
      try {
        await _nearby.startDiscovery(
          _endpointName,
          Strategy.P2P_CLUSTER,
          serviceId: _serviceId,
          onEndpointFound: _onFound,
          onEndpointLost: (_) {},
        );
        await Future<void>.delayed(on);
      } catch (e) {
        debugPrint('discovery: $e');
      } finally {
        await _nearby.stopDiscovery();
      }
    }

    burst();
    _cycle = Timer.periodic(period, (_) => burst());
  }

  void _onFound(String endpointId, String endpointName, String serviceId) {
    if (connected.containsKey(endpointId) || _pending.contains(endpointId)) return;
    final theirShort = endpointName.split('|').last;
    // Hanya sisi dengan ID lebih kecil yang meminta koneksi.
    if (shortId.compareTo(theirShort) > 0) return;
    _pending.add(endpointId);
    _nearby
        .requestConnection(
          _endpointName,
          endpointId,
          onConnectionInitiated: _onInitiated,
          onConnectionResult: _onResult,
          onDisconnected: _onDisconnected,
        )
        .catchError((Object e) {
      _pending.remove(endpointId);
      return false;
    });
  }

  void _onInitiated(String endpointId, ConnectionInfo info) {
    _pending.add(endpointId);
    _names[endpointId] = info.endpointName.split('|').first;
    _nearby.acceptConnection(endpointId, onPayLoadRecieved: _onPayload);
  }

  void _onResult(String endpointId, Status status) {
    _pending.remove(endpointId);
    if (status == Status.CONNECTED) {
      connected[endpointId] = NearbyPeer(endpointId, _names[endpointId] ?? '?');
      core.onLinkUp(this, _link(endpointId));
    } else {
      connected.remove(endpointId);
    }
    core.onLinksChanged();
  }

  void _onDisconnected(String endpointId) {
    connected.remove(endpointId);
    _pending.remove(endpointId);
    core.onLinksChanged();
  }

  void _onPayload(String endpointId, Payload payload) {
    final bytes = payload.bytes;
    if (payload.type != PayloadType.BYTES || bytes == null) return;
    core.onPayload(utf8.decode(bytes, allowMalformed: true), _link(endpointId));
  }

  Future<bool> _send(String endpointId, String payload) async {
    try {
      await _nearby.sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(payload)));
      return true;
    } catch (e) {
      debugPrint('kirim ke $endpointId gagal: $e');
      return false;
    }
  }

  @override
  Future<int> broadcast(String wire, {String? exceptLink}) async {
    var n = 0;
    for (final id in connected.keys.toList()) {
      if (_link(id) == exceptLink) continue;
      if (await _send(id, wire)) n++;
    }
    return n;
  }

  @override
  Future<bool> sendBatch(String link, List<String> wires) async {
    final id = link.replaceFirst('nearby:', '');
    var ok = true;
    for (final p in batchWires(wires)) {
      ok &= await _send(id, p);
    }
    return ok;
  }
}
