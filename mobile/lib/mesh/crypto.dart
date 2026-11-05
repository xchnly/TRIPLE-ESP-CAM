// Identitas (keypair di HP, tanpa akun) dan enkripsi.
//  - Ed25519  : tanda tangan semua pesan, kunci publiknya = ID user
//  - X25519   : tukar kunci untuk chat 1-1 (end-to-end)
//  - ChaCha20-Poly1305 : enkripsi isi pesan
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _ed = Ed25519();
final _x = X25519();
final _aead = Chacha20.poly1305Aead();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _sha = Sha256();

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
Uint8List unb64(String s) => base64Url.decode(base64Url.normalize(s));

class Identity {
  Identity._(this.name, this._seed, this._signKp, this._dhKp, this.signPub, this.dhPub);

  final String name;
  final List<int> _seed;
  final SimpleKeyPair _signKp;
  final SimpleKeyPair _dhKp;

  /// Kunci publik Ed25519 (base64url). Inilah ID user di mesh.
  final String signPub;

  /// Kunci publik X25519 (base64url) untuk enkripsi chat 1-1.
  final String dhPub;

  /// ID pendek untuk ditampilkan, mis. "K3F9-2QWA".
  String get shortId => shortIdOf(signPub);

  static Future<Identity> generate(String name) async {
    final seed = SecretKeyData.random(length: 32).bytes;
    return fromSeed(name, seed);
  }

  static Future<Identity> fromSeed(String name, List<int> seed) async {
    final signKp = await _ed.newKeyPairFromSeed(seed);
    final dhKp = await _x.newKeyPairFromSeed(seed);
    final signPub = b64((await signKp.extractPublicKey()).bytes);
    final dhPub = b64((await dhKp.extractPublicKey()).bytes);
    return Identity._(name, seed, signKp, dhKp, signPub, dhPub);
  }

  Identity rename(String newName) => Identity._(newName, _seed, _signKp, _dhKp, signPub, dhPub);

  Map<String, String> toJson() => {'name': name, 'seed': b64(_seed)};

  static Future<Identity> fromJson(Map<String, dynamic> j) =>
      fromSeed(j['name'] as String, unb64(j['seed'] as String));

  Future<String> sign(String input) async =>
      b64((await _ed.sign(utf8.encode(input), keyPair: _signKp)).bytes);

  Future<SecretKey> _dmKey(String theirDhPub) async {
    final shared = await _x.sharedSecretKey(
      keyPair: _dhKp,
      remotePublicKey: SimplePublicKey(unb64(theirDhPub), type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(secretKey: shared, info: utf8.encode('meshlokal-dm-v1'));
  }

  /// Enkripsi untuk chat 1-1. [aad] diisi ID pesan supaya ciphertext tidak bisa dipindah ke pesan lain.
  Future<String> encryptFor(String theirDhPub, String plaintext, String aad) async =>
      _seal(await _dmKey(theirDhPub), plaintext, aad);

  Future<String?> decryptFrom(String theirDhPub, String data, String aad) async {
    try {
      return await _open(await _dmKey(theirDhPub), data, aad);
    } catch (_) {
      return null;
    }
  }
}

String shortIdOf(String pub) {
  final s = pub.replaceAll(RegExp(r'[-_]'), '').toUpperCase();
  return s.length < 8 ? s : '${s.substring(0, 4)}-${s.substring(4, 8)}';
}

Future<bool> verifySignature(String input, String sig, String pub) async {
  try {
    return await _ed.verify(
      utf8.encode(input),
      signature: Signature(unb64(sig), publicKey: SimplePublicKey(unb64(pub), type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

Future<String> _seal(SecretKey key, String plaintext, String aad) async {
  final box = await _aead.encrypt(utf8.encode(plaintext), secretKey: key, aad: utf8.encode(aad));
  return b64(box.concatenation());
}

Future<String> _open(SecretKey key, String data, String aad) async {
  final box = SecretBox.fromConcatenation(unb64(data), nonceLength: 12, macLength: 16);
  return utf8.decode(await _aead.decrypt(box, secretKey: key, aad: utf8.encode(aad)));
}

/// Channel: siapa pun yang tahu kodenya bisa bergabung dan membaca.
class ChannelKey {
  ChannelKey._(this.id, this._key);
  final String id; // 32 hex, dipakai sebagai field "to"
  final SecretKey _key;

  static Future<ChannelKey> fromCode(String code) async {
    final norm = code.trim().toLowerCase();
    final id = (await _sha.hash(utf8.encode('meshlokal-chan:$norm')))
        .bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final key = SecretKey((await _sha.hash(utf8.encode('meshlokal-key:$norm'))).bytes);
    return ChannelKey._(id, key);
  }

  Future<String> encrypt(String plaintext, String aad) => _seal(_key, plaintext, aad);

  Future<String?> decrypt(String data, String aad) async {
    try {
      return await _open(_key, data, aad);
    } catch (_) {
      return null;
    }
  }
}
