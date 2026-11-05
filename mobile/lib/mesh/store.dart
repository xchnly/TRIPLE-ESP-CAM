// Penyimpanan lokal (SQLite). Semua data hanya ada di HP ini.
import 'package:sqflite/sqflite.dart';

/// Status pesan keluar.
abstract final class MsgStatus {
  static const saved = 0; // tersimpan di HP, belum ada tetangga
  static const forwarded = 1; // sudah dikirim ke minimal satu tetangga
  static const delivered = 2; // penerima membalas ACK
}

class ChatMessage {
  ChatMessage(this.id, this.conv, this.from, this.senderName, this.text, this.ts, this.outgoing, this.status, this.hops);
  final String id, conv, from, senderName, text;
  final int ts, status, hops;
  final bool outgoing;

  static ChatMessage fromRow(Map<String, Object?> r) => ChatMessage(
        r['id'] as String,
        r['conv'] as String,
        r['sender'] as String,
        r['sender_name'] as String,
        r['text'] as String,
        r['ts'] as int,
        r['outgoing'] == 1,
        r['status'] as int,
        r['hops'] as int,
      );
}

class Contact {
  Contact(this.pub, this.name, this.dhPub, this.lastSeen, this.hops, this.lat, this.lon, this.locTs);
  final String pub, name, dhPub;
  final int lastSeen, hops;
  final double? lat, lon;
  final int? locTs;

  static Contact fromRow(Map<String, Object?> r) => Contact(
        r['pub'] as String,
        r['name'] as String,
        r['dh'] as String,
        r['last_seen'] as int,
        r['hops'] as int,
        r['lat'] as double?,
        r['lon'] as double?,
        r['loc_ts'] as int?,
      );
}

class SosAlert {
  SosAlert(this.id, this.from, this.name, this.lat, this.lon, this.acc, this.msg, this.ts, this.hops, this.mine);
  final String id, from, name, msg;
  final double? lat, lon, acc;
  final int ts, hops;
  final bool mine;

  static SosAlert fromRow(Map<String, Object?> r) => SosAlert(
        r['id'] as String,
        r['sender'] as String,
        r['name'] as String,
        r['lat'] as double?,
        r['lon'] as double?,
        r['acc'] as double?,
        r['msg'] as String,
        r['ts'] as int,
        r['hops'] as int,
        r['mine'] == 1,
      );
}

class Channel {
  Channel(this.id, this.name, this.code);
  final String id, name, code;
}

class Conversation {
  Conversation(this.conv, this.title, this.lastText, this.lastTs, this.isChannel);
  final String conv, title, lastText;
  final int lastTs;
  final bool isChannel;
}

class MeshStore {
  MeshStore._(this.db);
  final Database db;

  static Future<MeshStore> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
        await db.execute('''CREATE TABLE relay(
          id TEXT PRIMARY KEY, type TEXT NOT NULL, sender TEXT NOT NULL,
          wire TEXT NOT NULL, ttl INTEGER NOT NULL, received_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE messages(
          id TEXT PRIMARY KEY, conv TEXT NOT NULL, sender TEXT NOT NULL, sender_name TEXT NOT NULL,
          text TEXT NOT NULL, ts INTEGER NOT NULL, outgoing INTEGER NOT NULL,
          status INTEGER NOT NULL, hops INTEGER NOT NULL)''');
        await db.execute('CREATE INDEX messages_conv ON messages(conv, ts)');
        await db.execute('''CREATE TABLE contacts(
          pub TEXT PRIMARY KEY, name TEXT NOT NULL, dh TEXT NOT NULL,
          last_seen INTEGER NOT NULL, hops INTEGER NOT NULL,
          lat REAL, lon REAL, loc_ts INTEGER)''');
        await db.execute('CREATE TABLE channels(id TEXT PRIMARY KEY, name TEXT NOT NULL, code TEXT NOT NULL)');
        await db.execute('''CREATE TABLE sos(
          id TEXT PRIMARY KEY, sender TEXT NOT NULL, name TEXT NOT NULL,
          lat REAL, lon REAL, acc REAL, msg TEXT NOT NULL,
          ts INTEGER NOT NULL, hops INTEGER NOT NULL, mine INTEGER NOT NULL)''');
      }),
    );
    return MeshStore._(db);
  }

  // ---------- relay (store-and-forward) ----------
  Future<void> putRelay(String id, String type, String sender, String wire, int ttl) => db.insert(
        'relay',
        {'id': id, 'type': type, 'sender': sender, 'wire': wire, 'ttl': ttl, 'received_at': _now()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  Future<List<String>> relayIds() async =>
      (await db.query('relay', columns: ['id'])).map((r) => r['id'] as String).toList();

  /// Pesan yang dibawa untuk diteruskan saat bertemu tetangga baru.
  /// Hello hanya yang masih segar supaya daftar peer tidak menampilkan orang yang sudah lama pergi.
  Future<List<String>> relayBacklog({int limit = 300}) async {
    final now = _now();
    final rows = await db.query(
      'relay',
      columns: ['wire'],
      where: '(type != ? AND received_at > ?) OR (type = ? AND received_at > ?)',
      whereArgs: ['hello', now - const Duration(hours: 24).inMilliseconds, 'hello', now - const Duration(minutes: 5).inMilliseconds],
      orderBy: 'received_at DESC',
      limit: limit,
    );
    return rows.map((r) => r['wire'] as String).toList();
  }

  Future<void> pruneRelay() async {
    final now = _now();
    await db.delete('relay', where: 'received_at < ?', whereArgs: [now - const Duration(hours: 48).inMilliseconds]);
    await db.delete('relay',
        where: 'type = ? AND received_at < ?', whereArgs: ['hello', now - const Duration(minutes: 10).inMilliseconds]);
  }

  // ---------- chat ----------
  Future<bool> insertMessage(ChatMessage m) async =>
      await db.insert(
        'messages',
        {
          'id': m.id,
          'conv': m.conv,
          'sender': m.from,
          'sender_name': m.senderName,
          'text': m.text,
          'ts': m.ts,
          'outgoing': m.outgoing ? 1 : 0,
          'status': m.status,
          'hops': m.hops,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      ) >
      0;

  /// Naikkan status (tidak pernah turun, mis. ACK datang sebelum "diteruskan").
  Future<void> raiseStatus(String id, int status) =>
      db.update('messages', {'status': status}, where: 'id = ? AND outgoing = 1 AND status < ?', whereArgs: [id, status]);

  Future<List<ChatMessage>> messages(String conv) async =>
      (await db.query('messages', where: 'conv = ?', whereArgs: [conv], orderBy: 'ts ASC, rowid ASC'))
          .map(ChatMessage.fromRow)
          .toList();

  Future<List<String>> ownUnforwarded() async =>
      (await db.query('messages', columns: ['id'], where: 'outgoing = 1 AND status = 0'))
          .map((r) => r['id'] as String)
          .toList();

  Future<List<Conversation>> conversations() async {
    final rows = await db.rawQuery('''
      SELECT m.conv, m.text, m.ts, m.sender_name, m.outgoing,
             c.name AS contact_name, ch.name AS channel_name
      FROM messages m
      JOIN (SELECT conv, MAX(ts) AS mts FROM messages GROUP BY conv) last
        ON last.conv = m.conv AND last.mts = m.ts
      LEFT JOIN contacts c ON m.conv = 'dm:' || c.pub
      LEFT JOIN channels ch ON m.conv = 'chan:' || ch.id
      GROUP BY m.conv
      ORDER BY m.ts DESC''');
    final out = rows.map((r) {
      final conv = r['conv'] as String;
      final isChan = conv.startsWith('chan:');
      final title = (isChan ? r['channel_name'] : r['contact_name']) as String? ?? shortConv(conv);
      final prefix = r['outgoing'] == 1 ? 'Kamu: ' : (isChan ? '${r['sender_name']}: ' : '');
      return Conversation(conv, title, '$prefix${r['text']}', r['ts'] as int, isChan);
    }).toList();
    // Channel yang sudah diikuti tapi belum ada pesan tetap tampil.
    for (final ch in await channels()) {
      if (!out.any((c) => c.conv == 'chan:${ch.id}')) {
        out.add(Conversation('chan:${ch.id}', ch.name, 'Belum ada pesan', 0, true));
      }
    }
    return out;
  }

  static String shortConv(String conv) => conv.length > 13 ? conv.substring(3, 13) : conv;

  // ---------- kontak ----------
  Future<void> upsertContact(String pub, String name, String dh, int hops, {double? lat, double? lon, int? locTs}) async {
    final existing = await contact(pub);
    final values = <String, Object?>{'pub': pub, 'name': name, 'dh': dh, 'last_seen': _now(), 'hops': hops};
    // Jangan hapus lokasi lama kalau hello terbaru tidak membawa lokasi.
    if (lat != null && lon != null) values.addAll({'lat': lat, 'lon': lon, 'loc_ts': locTs});
    if (existing == null) {
      await db.insert('contacts', values);
    } else {
      await db.update('contacts', values, where: 'pub = ?', whereArgs: [pub]);
    }
  }

  Future<Contact?> contact(String pub) async {
    final r = await db.query('contacts', where: 'pub = ?', whereArgs: [pub]);
    return r.isEmpty ? null : Contact.fromRow(r.first);
  }

  Future<List<Contact>> contacts() async =>
      (await db.query('contacts', orderBy: 'last_seen DESC')).map(Contact.fromRow).toList();

  // ---------- channel ----------
  Future<void> addChannel(String id, String name, String code) =>
      db.insert('channels', {'id': id, 'name': name, 'code': code}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> removeChannel(String id) async {
    await db.delete('channels', where: 'id = ?', whereArgs: [id]);
    await db.delete('messages', where: 'conv = ?', whereArgs: ['chan:$id']);
  }

  Future<List<Channel>> channels() async => (await db.query('channels', orderBy: 'name'))
      .map((r) => Channel(r['id'] as String, r['name'] as String, r['code'] as String))
      .toList();

  // ---------- SOS ----------
  Future<bool> insertSos(SosAlert s) async =>
      await db.insert(
        'sos',
        {
          'id': s.id,
          'sender': s.from,
          'name': s.name,
          'lat': s.lat,
          'lon': s.lon,
          'acc': s.acc,
          'msg': s.msg,
          'ts': s.ts,
          'hops': s.hops,
          'mine': s.mine ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      ) >
      0;

  Future<List<SosAlert>> sosAlerts() async =>
      (await db.query('sos', orderBy: 'ts DESC', limit: 100)).map(SosAlert.fromRow).toList();

  /// Hapus semua data lokal (identitas dihapus terpisah oleh pemanggil).
  Future<void> wipe() async {
    for (final t in ['relay', 'messages', 'contacts', 'channels', 'sos']) {
      await db.delete(t);
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
