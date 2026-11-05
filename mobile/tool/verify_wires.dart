// ignore_for_file: avoid_print
// Memastikan pesan yang TTL-nya diubah firmware tetap valid (tanda tangan & parse).
import 'dart:io';
import 'package:meshlokal/mesh/crypto.dart';
import 'package:meshlokal/mesh/protocol.dart';

Future<void> main(List<String> args) async {
  for (final line in File(args.first).readAsLinesSync().where((l) => l.isNotEmpty)) {
    final m = MeshMessage.tryParse(line);
    print(m == null ? 'PARSE FAIL' : 'ttl=${m.ttl} sig ok=${await verifySignature(m.signingInput, m.sig, m.from)}');
  }
}
