// ignore_for_file: avoid_print
// Mencetak contoh pesan dalam format kabel (dipakai untuk menguji parser firmware).
import 'package:meshlokal/mesh/crypto.dart';
import 'package:meshlokal/mesh/protocol.dart';

Future<void> main() async {
  final me = await Identity.generate('Uji "kutip" \\ ok');
  for (final (type, ttl, body) in [
    (MsgType.hello, kTtlHello, '{"n":"Uji","x":"${me.dhPub}"}'),
    (MsgType.sos, kTtlSos, '{"n":"Uji","lat":-7.45,"lon":110.43,"msg":"\\"id\\":\\"x\\" ttl"}'),
  ]) {
    final m = MeshMessage(id: newMessageId(), ttl: ttl, type: type, from: me.signPub, to: kBroadcast, ts: DateTime.now().millisecondsSinceEpoch, body: body);
    print(m.copyWith(sig: await me.sign(m.signingInput)).toWire());
  }
}
