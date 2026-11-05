// Inti mesh: terima -> verifikasi -> simpan -> antar ke UI -> teruskan (gossip + TTL).
// Tidak bergantung pada plugin, jadi bisa diuji tanpa HP (lihat test/mesh_core_test.dart).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'protocol.dart';
import 'store.dart';

/// Satu jenis jalur ke perangkat lain (Nearby Connections, node ESP32, ...).
/// Sebuah transport punya beberapa "link" (tetangga langsung), masing-masing dengan ID unik.
abstract class MeshTransport {
  late MeshCore core;

  /// Kirim ke semua link kecuali [exceptLink]. Mengembalikan jumlah link yang dikirimi.
  Future<int> broadcast(String wire, {String? exceptLink});

  /// Kirim beberapa pesan sekaligus ke satu link (dipakai saat sinkron).
  Future<bool> sendBatch(String link, List<String> wires);

  int get linkCount;
}

class MeshEvent {
  MeshEvent.sos(this.sos) : chat = null;
  MeshEvent.chat(this.chat) : sos = null;
  final SosAlert? sos;
  final ChatMessage? chat;
}

class MeshCore extends ChangeNotifier {
  MeshCore(this.me, this.store);

  Identity me;
  final MeshStore store;
  final List<MeshTransport> transports = [];
  final _seen = <String>{};
  final _rate = <String, List<int>>{};
  final _channels = <String, ChannelKey>{}; // id -> kunci
  final _events = StreamController<MeshEvent>.broadcast();

  /// Hanya teruskan SOS (mode hemat baterai "darurat saja").
  bool emergencyOnly = false;

  /// Lokasi yang ikut dikirim di hello bila user menyalakan berbagi lokasi.
  ({double lat, double lon})? Function()? shareLocation;

  /// Pesan masuk baru (chat atau SOS) untuk notifikasi/UI.
  Stream<MeshEvent> get events => _events.stream;

  int get linkCount => transports.fold(0, (n, t) => n + t.linkCount);

  Future<void> init() async {
    await store.pruneRelay();
    _seen.addAll(await store.relayIds());
    for (final ch in await store.channels()) {
      _channels[ch.id] = await ChannelKey.fromCode(ch.code);
    }
  }

  void addTransport(MeshTransport t) {
    t.core = this;
    transports.add(t);
  }

  // =================================================================
  //  Masuk
  // =================================================================

  /// Dipanggil transport untuk setiap payload yang datang dari [link].
  Future<void> onPayload(String payload, String link) async {
    var changed = false;
    for (final w in splitWires(payload)) {
      changed |= await _onWire(w, link);
    }
    if (changed) notifyListeners();
  }

  Future<bool> _onWire(String wire, String link) async {
    final m = MeshMessage.tryParse(wire);
    if (m == null || _seen.contains(m.id)) return false;
    if (m.from == me.signPub) {
      _seen.add(m.id); // pesan sendiri yang kembali lewat jalur lain
      return false;
    }
    if (!_rateOk(m.from)) return false;
    if (!await verifySignature(m.signingInput, m.sig, m.from)) return false;
    _seen.add(m.id);

    // Pesan untuk kita tidak perlu diteruskan lagi.
    final relay = (!emergencyOnly || m.type == MsgType.sos) && m.to != me.signPub;
    if (m.ttl > 1 && relay) {
      final fwd = m.copyWith(ttl: m.ttl - 1).toWire();
      await store.putRelay(m.id, m.type, m.from, fwd, m.ttl - 1);
      await _broadcast(fwd, exceptLink: link);
    }
    await _deliver(m);
    return true;
  }

  /// Batasi 40 pesan per menit per pengirim (anti-spam).
  bool _rateOk(String from) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = _rate.putIfAbsent(from, () => [])..removeWhere((t) => now - t > 60000);
    if (list.length >= 40) return false;
    list.add(now);
    return true;
  }

  Future<void> _deliver(MeshMessage m) async {
    switch (m.type) {
      case MsgType.hello:
        final j = _json(m.body);
        if (j == null || j['x'] is! String) return;
        final loc = j['loc'];
        await store.upsertContact(
          m.from,
          _cleanName(j['n']),
          j['x'] as String,
          m.hops,
          lat: loc is List && loc.length >= 2 ? (loc[0] as num).toDouble() : null,
          lon: loc is List && loc.length >= 2 ? (loc[1] as num).toDouble() : null,
          locTs: loc is List ? m.ts : null,
        );

      case MsgType.dm:
        if (m.to != me.signPub) return;
        final dot = m.body.indexOf('.');
        if (dot < 0) return;
        final senderDh = m.body.substring(0, dot);
        final plain = await me.decryptFrom(senderDh, m.body.substring(dot + 1), m.id);
        final j = plain == null ? null : _json(plain);
        if (j == null) return;
        final name = _cleanName(j['n']);
        // Kenali pengirim walau belum pernah menerima hello-nya.
        if (await store.contact(m.from) == null) await store.upsertContact(m.from, name, senderDh, m.hops);
        final msg = ChatMessage(m.id, 'dm:${m.from}', m.from, name, '${j['m']}', m.ts, false, 0, m.hops);
        if (await store.insertMessage(msg)) _events.add(MeshEvent.chat(msg));
        await _sendAck(m);

      case MsgType.chan:
        final key = _channels[m.to];
        if (key == null) return;
        final plain = await key.decrypt(m.body, m.id);
        final j = plain == null ? null : _json(plain);
        if (j == null) return;
        final msg = ChatMessage(m.id, 'chan:${m.to}', m.from, _cleanName(j['n']), '${j['m']}', m.ts, false, 0, m.hops);
        if (await store.insertMessage(msg)) _events.add(MeshEvent.chat(msg));

      case MsgType.sos:
        final j = _json(m.body) ?? {};
        final s = SosAlert(m.id, m.from, _cleanName(j['n']), _num(j['lat']), _num(j['lon']), _num(j['acc']),
            '${j['msg'] ?? ''}', m.ts, m.hops, false);
        if (await store.insertSos(s)) _events.add(MeshEvent.sos(s));

      case MsgType.ack:
        if (m.to == me.signPub) await store.raiseStatus(m.body, MsgStatus.delivered);
    }
  }

  static Map<String, dynamic>? _json(String s) {
    try {
      final j = jsonDecode(s);
      return j is Map<String, dynamic> ? j : null;
    } on FormatException {
      return null;
    }
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  static String _cleanName(Object? n) {
    final s = (n is String ? n : '').trim();
    if (s.isEmpty) return 'Tanpa nama';
    return s.length > 32 ? s.substring(0, 32) : s;
  }

  // =================================================================
  //  Keluar
  // =================================================================

  Future<MeshMessage> _build(String type, String to, int ttl, Future<String> Function(String id) body) async {
    final id = newMessageId();
    final m = MeshMessage(
      id: id,
      ttl: ttl,
      type: type,
      from: me.signPub,
      to: to,
      ts: DateTime.now().millisecondsSinceEpoch,
      body: await body(id),
    );
    return m.copyWith(sig: await me.sign(m.signingInput));
  }

  /// Simpan untuk store-and-forward lalu sebar. Mengembalikan jumlah link yang dikirimi.
  Future<int> _originate(MeshMessage m) async {
    _seen.add(m.id);
    final wire = m.toWire();
    await store.putRelay(m.id, m.type, m.from, wire, m.ttl);
    return _broadcast(wire);
  }

  Future<int> _broadcast(String wire, {String? exceptLink}) async {
    var n = 0;
    for (final t in transports) {
      try {
        n += await t.broadcast(wire, exceptLink: exceptLink);
      } catch (e) {
        debugPrint('broadcast gagal: $e');
      }
    }
    return n;
  }

  Future<void> sendDm(Contact to, String text) async {
    text = _clip(text);
    final payload = jsonEncode({'n': me.name, 'm': text});
    final m = await _build(MsgType.dm, to.pub, kTtlDefault,
        (id) async => '${me.dhPub}.${await me.encryptFor(to.dhPub, payload, id)}');
    await store.insertMessage(ChatMessage(m.id, 'dm:${to.pub}', me.signPub, me.name, text, m.ts, true, MsgStatus.saved, 0));
    if (await _originate(m) > 0) await store.raiseStatus(m.id, MsgStatus.forwarded);
    notifyListeners();
  }

  Future<void> sendChannel(String channelId, String text) async {
    final key = _channels[channelId];
    if (key == null) return;
    text = _clip(text);
    final payload = jsonEncode({'n': me.name, 'm': text});
    final m = await _build(MsgType.chan, channelId, kTtlDefault, (id) => key.encrypt(payload, id));
    await store.insertMessage(ChatMessage(m.id, 'chan:$channelId', me.signPub, me.name, text, m.ts, true, MsgStatus.saved, 0));
    if (await _originate(m) > 0) await store.raiseStatus(m.id, MsgStatus.forwarded);
    notifyListeners();
  }

  Future<SosAlert> sendSos({double? lat, double? lon, double? acc, String msg = ''}) async {
    final body = jsonEncode({'n': me.name, 'lat': lat, 'lon': lon, 'acc': acc, 'msg': _clip(msg, 200)});
    final m = await _build(MsgType.sos, kBroadcast, kTtlSos, (_) async => body);
    final s = SosAlert(m.id, me.signPub, me.name, lat, lon, acc, msg, m.ts, 0, true);
    await store.insertSos(s);
    await _originate(m);
    notifyListeners();
    return s;
  }

  Future<void> sendHello() async {
    final loc = shareLocation?.call();
    final body = jsonEncode({
      'n': me.name,
      'x': me.dhPub,
      if (loc != null) 'loc': [double.parse(loc.lat.toStringAsFixed(5)), double.parse(loc.lon.toStringAsFixed(5))],
    });
    await _originate(await _build(MsgType.hello, kBroadcast, kTtlHello, (_) async => body));
  }

  Future<void> _sendAck(MeshMessage original) async =>
      _originate(await _build(MsgType.ack, original.from, kTtlDefault, (_) async => original.id));

  static String _clip(String s, [int max = kMaxTextChars]) {
    s = s.trim();
    return s.length > max ? s.substring(0, max) : s;
  }

  // =================================================================
  //  Link baru: kirim semua yang kita bawa (store-and-forward)
  // =================================================================

  Future<void> onLinkUp(MeshTransport t, String link) async {
    final backlog = await store.relayBacklog();
    final filtered = emergencyOnly ? backlog.where((w) => w.contains('"t":"sos"')).toList() : backlog;
    if (filtered.isNotEmpty && await t.sendBatch(link, filtered)) {
      for (final id in await store.ownUnforwarded()) {
        await store.raiseStatus(id, MsgStatus.forwarded);
      }
    }
    await sendHello();
    notifyListeners();
  }

  void onLinksChanged() => notifyListeners();

  // =================================================================
  //  Channel
  // =================================================================

  Future<String> joinChannel(String name, String code) async {
    final key = await ChannelKey.fromCode(code);
    _channels[key.id] = key;
    await store.addChannel(key.id, name.trim().isEmpty ? code.trim() : name.trim(), code.trim());
    notifyListeners();
    return key.id;
  }

  Future<void> leaveChannel(String id) async {
    _channels.remove(id);
    await store.removeChannel(id);
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
