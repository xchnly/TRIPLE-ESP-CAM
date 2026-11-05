import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlokal/mesh/crypto.dart';
import 'package:meshlokal/mesh/mesh_core.dart';
import 'package:meshlokal/mesh/protocol.dart';
import 'package:meshlokal/mesh/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Transport palsu: menghubungkan beberapa MeshCore di memori.
class LoopTransport extends MeshTransport {
  final links = <String, LoopTransport>{};
  int sent = 0;

  static void connect(LoopTransport a, String aName, LoopTransport b, String bName) {
    a.links[bName] = b;
    b.links[aName] = a;
  }

  String nameOf(LoopTransport t) => links.entries.firstWhere((e) => e.value == t).key;

  @override
  int get linkCount => links.length;

  @override
  Future<int> broadcast(String wire, {String? exceptLink}) async {
    var n = 0;
    for (final e in links.entries.toList()) {
      if (e.key == exceptLink) continue;
      sent++;
      n++;
      final back = e.value.nameOf(this);
      await e.value.core.onPayload(wire, back);
    }
    return n;
  }

  @override
  Future<bool> sendBatch(String link, List<String> wires) async {
    final peer = links[link];
    if (peer == null) return false;
    for (final p in batchWires(wires)) {
      await peer.core.onPayload(p, peer.nameOf(this));
    }
    return true;
  }
}

Future<(MeshCore, LoopTransport)> node(String name) async {
  final store = await MeshStore.open(databaseFactoryFfi, '${Directory.systemTemp.createTempSync('mesh').path}/m.db');
  final core = MeshCore(await Identity.generate(name), store);
  await core.init();
  final t = LoopTransport();
  core.addTransport(t);
  return (core, t);
}

void main() {
  sqfliteFfiInit();

  test('format kabel: id dan ttl selalu di depan (dibaca firmware ESP32)', () async {
    final (a, _) = await node('A');
    await a.sendHello();
    final wire = (await a.store.relayBacklog()).single;
    expect(RegExp(r'^\{"id":"[0-9a-f]{32}","ttl":\d+,').hasMatch(wire), isTrue);
  });

  test('chat 1-1 lewat 3 relay (A-B-C-D), ACK kembali ke A', () async {
    final (a, ta) = await node('Ani');
    final (b, tb) = await node('Budi');
    final (c, tc) = await node('Cici');
    final (d, td) = await node('Dodi');
    LoopTransport.connect(ta, 'a', tb, 'b');
    LoopTransport.connect(tb, 'b', tc, 'c');
    LoopTransport.connect(tc, 'c', td, 'd');

    await d.sendHello(); // A mengenal kunci D dari hello yang melompat
    final contactD = await a.store.contact(d.me.signPub);
    expect(contactD, isNotNull);
    expect(contactD!.name, 'Dodi');
    expect(contactD.hops, 3);

    await a.sendDm(contactD, 'halo dari puncak');
    final got = await d.store.messages('dm:${a.me.signPub}');
    expect(got.single.text, 'halo dari puncak');
    expect(got.single.senderName, 'Ani');

    // Relay tidak bisa membaca isi
    expect(await b.store.messages('dm:${a.me.signPub}'), isEmpty);
    expect((await b.store.relayBacklog()).any((w) => w.contains('halo dari puncak')), isFalse);

    final mine = await a.store.messages('dm:${d.me.signPub}');
    expect(mine.single.status, MsgStatus.delivered);
  });

  test('TTL membatasi jumlah lompatan', () async {
    final nodes = [for (var i = 0; i < kTtlHello + 2; i++) await node('N$i')];
    for (var i = 0; i < nodes.length - 1; i++) {
      LoopTransport.connect(nodes[i].$2, 'n$i', nodes[i + 1].$2, 'n${i + 1}');
    }
    await nodes.first.$1.sendHello();
    final pub = nodes.first.$1.me.signPub;
    expect(await nodes[kTtlHello].$1.store.contact(pub), isNotNull);
    expect(await nodes[kTtlHello + 1].$1.store.contact(pub), isNull);
  });

  test('pesan yang dipalsukan ditolak dan tidak diteruskan', () async {
    final (a, _) = await node('A');
    final (b, _) = await node('B');
    await a.sendHello();
    final wire = (await a.store.relayBacklog()).single;
    final forged = MeshMessage.tryParse(wire)!;
    final tampered = MeshMessage(
      id: newMessageId(),
      ttl: forged.ttl,
      type: forged.type,
      from: forged.from,
      to: forged.to,
      ts: forged.ts,
      body: forged.body.replaceFirst('"A"', '"Penipu"'),
      sig: forged.sig,
    );
    await b.onPayload(tampered.toWire(), 'x');
    expect(await b.store.contact(a.me.signPub), isNull);
    expect(await b.store.relayBacklog(), isEmpty);
  });

  test('channel: hanya yang tahu kodenya bisa membaca', () async {
    final (a, ta) = await node('A');
    final (b, tb) = await node('B');
    final (c, tc) = await node('C');
    LoopTransport.connect(ta, 'a', tb, 'b');
    LoopTransport.connect(tb, 'b', tc, 'c');
    final id = await a.joinChannel('Rombongan', 'merbabu-2026');
    await c.joinChannel('Rombongan', 'Merbabu-2026 ');
    await a.sendChannel(id, 'kumpul di pos 3');
    expect((await c.store.messages('chan:$id')).single.text, 'kumpul di pos 3');
    expect(await b.store.messages('chan:$id'), isEmpty); // B meneruskan tapi tidak bisa baca
  });

  test('SOS menyebar ke semua, termasuk dalam mode darurat saja', () async {
    final (a, ta) = await node('A');
    final (b, tb) = await node('B');
    final (c, tc) = await node('C');
    LoopTransport.connect(ta, 'a', tb, 'b');
    LoopTransport.connect(tb, 'b', tc, 'c');
    b.emergencyOnly = true;
    await a.sendSos(lat: -7.45, lon: 110.43, acc: 12, msg: 'kaki terkilir');
    final s = (await c.store.sosAlerts()).single;
    expect(s.name, 'A');
    expect(s.lat, -7.45);
    expect(s.msg, 'kaki terkilir');
    expect(s.hops, 2);

    await a.sendHello(); // bukan SOS: B dalam mode darurat tidak meneruskan
    expect(await c.store.contact(a.me.signPub), isNull);
  });

  test('store-and-forward: pesan menunggu sampai bertemu tetangga', () async {
    final (a, ta) = await node('A');
    final (b, tb) = await node('B');
    final (c, tc) = await node('C');
    LoopTransport.connect(ta, 'a', tb, 'b');
    LoopTransport.connect(tb, 'b', tc, 'c');
    await c.sendHello();
    final contactC = (await a.store.contact(c.me.signPub))!;

    // C pergi. A mengirim; pesan hanya sampai B.
    tb.links.remove('c');
    tc.links.remove('b');
    await a.sendDm(contactC, 'nanti dibaca ya');
    expect(await c.store.messages('dm:${a.me.signPub}'), isEmpty);

    // C kembali: B mengirim backlog saat link baru terbentuk.
    LoopTransport.connect(tb, 'b', tc, 'c');
    await b.onLinkUp(tb, 'c');
    expect((await c.store.messages('dm:${a.me.signPub}')).single.text, 'nanti dibaca ya');
    expect((await a.store.messages('dm:${c.me.signPub}')).single.status, MsgStatus.delivered);
  });

  test('batchWires memecah sesuai ukuran dan splitWires mengembalikan semuanya', () {
    final wires = List.generate(50, (i) => '{"id":"$i","x":"${'a' * 100}"}');
    final batches = batchWires(wires, maxBytes: 1000);
    expect(batches.length, greaterThan(1));
    expect(batches.expand(splitWires).toList(), wires);
  });
}
