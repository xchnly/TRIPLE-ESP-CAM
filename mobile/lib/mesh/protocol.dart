// Format pesan mesh MeshLokal. Formatnya sama persis dengan yang dibaca
// firmware ESP32 (lihat firmware/esp32cam/mesh.h), jadi URUTAN field penting:
// node hanya mem-parse awalan {"id":"<32 hex>","ttl":<n>, ... tanpa JSON parser.
import 'dart:convert';
import 'dart:math';

/// TTL awal per jenis pesan. Penerima meneruskan hanya bila ttl > 1,
/// dengan ttl - 1, jadi pesan bisa melompat sebanyak TTL kali.
const kTtlDefault = 8;
const kTtlHello = 6;
const kTtlSos = 15;
const kTtlMax = 15;

/// Batas ukuran satu pesan di kabel (byte). Node ESP menolak yang lebih besar.
const kMaxWireBytes = 1400;
const kMaxTextChars = 500;

/// Jenis pesan.
abstract final class MsgType {
  static const hello = 'hello'; // pengumuman diri: nama, kunci X25519, lokasi opsional
  static const dm = 'dm'; // chat 1-1, terenkripsi end-to-end
  static const chan = 'chan'; // chat grup/channel, terenkripsi dengan kunci dari kode channel
  static const sos = 'sos'; // darurat, SENGAJA tidak dienkripsi
  static const ack = 'ack'; // tanda terima untuk dm
  static const all = {hello, dm, chan, sos, ack};
}

/// Alamat broadcast.
const kBroadcast = '*';

class MeshMessage {
  MeshMessage({
    required this.id,
    required this.ttl,
    required this.type,
    required this.from,
    required this.to,
    required this.ts,
    required this.body,
    this.sig = '',
  });

  final String id; // 32 hex (16 byte acak)
  final int ttl;
  final String type;
  final String from; // kunci publik Ed25519 pengirim (base64url)
  final String to; // kunci publik penerima, id channel, atau '*'
  final int ts; // waktu kirim (ms epoch) menurut jam HP pengirim
  final String body;
  final String sig; // tanda tangan Ed25519 atas [signingInput]

  /// Semua field kecuali ttl (berubah di tiap hop) dan sig.
  String get signingInput => '$id|$type|$from|$to|$ts|$body';

  MeshMessage copyWith({int? ttl, String? sig}) => MeshMessage(
        id: id,
        ttl: ttl ?? this.ttl,
        type: type,
        from: from,
        to: to,
        ts: ts,
        body: body,
        sig: sig ?? this.sig,
      );

  /// Serialisasi dengan urutan field tetap (id, ttl dulu) dan tanpa spasi.
  String toWire() => jsonEncode({
        'id': id,
        'ttl': ttl,
        't': type,
        'from': from,
        'to': to,
        'ts': ts,
        'body': body,
        'sig': sig,
      });

  static final _idRe = RegExp(r'^[0-9a-f]{32}$');

  /// Parse dan validasi bentuk pesan. Tanda tangan BELUM dicek di sini.
  static MeshMessage? tryParse(String wire) {
    if (utf8.encode(wire).length > kMaxWireBytes) return null;
    try {
      final j = jsonDecode(wire);
      if (j is! Map) return null;
      final id = j['id'], ttl = j['ttl'], t = j['t'];
      if (id is! String || !_idRe.hasMatch(id)) return null;
      if (ttl is! int || ttl < 0) return null;
      if (t is! String || !MsgType.all.contains(t)) return null;
      final from = j['from'], to = j['to'], ts = j['ts'], body = j['body'], sig = j['sig'];
      if (from is! String || to is! String || ts is! int || body is! String || sig is! String) return null;
      return MeshMessage(
        id: id,
        ttl: min(ttl, kTtlMax),
        type: t,
        from: from,
        to: to,
        ts: ts,
        body: body,
        sig: sig,
      );
    } on FormatException {
      return null;
    }
  }

  /// Perkiraan jumlah lompatan dari pengirim asli sampai ke kita.
  int get hops {
    final start = switch (type) {
      MsgType.hello => kTtlHello,
      MsgType.sos => kTtlSos,
      _ => kTtlDefault,
    };
    return max(1, start - ttl + 1);
  }
}

final _rng = Random.secure();

String newMessageId() =>
    List.generate(16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// Satu payload transport bisa berisi beberapa pesan dipisah newline (NDJSON).
/// Aman karena jsonEncode tidak pernah menghasilkan newline mentah.
List<String> splitWires(String payload) =>
    payload.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

/// Gabungkan pesan menjadi beberapa payload NDJSON, masing-masing <= [maxBytes].
List<String> batchWires(Iterable<String> wires, {int maxBytes = 30000}) {
  final out = <String>[];
  final buf = StringBuffer();
  var size = 0;
  for (final w in wires) {
    final n = utf8.encode(w).length + 1;
    if (size > 0 && size + n > maxBytes) {
      out.add(buf.toString());
      buf.clear();
      size = 0;
    }
    buf
      ..write(w)
      ..write('\n');
    size += n;
  }
  if (size > 0) out.add(buf.toString());
  return out;
}
