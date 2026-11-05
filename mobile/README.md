# MeshLokal (Android, Flutter)

Aplikasi chat offline untuk jaringan mesh TRIPLE-ESP-CAM. Tidak butuh internet, akun, atau server.

## Fitur

| Tab | Isi |
|---|---|
| **Chat** | Chat 1-1 terenkripsi end-to-end. Channel rombongan: gabung dengan kode yang sama. Status pesan: tersimpan → diteruskan → diterima. |
| **SOS** | Tahan tombol 2 detik untuk mengirim SOS + koordinat GPS ke semua perangkat. Daftar SOS masuk dengan jarak & arah dari posisimu. Saklar **Bagikan lokasi ke rombongan** dan **Mode darurat saja** (hemat baterai: hanya meneruskan SOS, scanning lebih jarang). |
| **Jaringan** | ID-mu, HP yang terhubung langsung, node ESP32 yang tersambung beserta tetangganya, dan daftar orang di jaringan (jumlah hop, terakhir aktif, lokasi). |
| **Kamera** | Live stream kamera node yang sedang tersambung, foto dari kamera node lain, ambil foto, flash, dan foto tersimpan di HP. |

HP terhubung ke perangkat lain lewat dua jalur sekaligus:
- **HP ke HP**: Google Nearby Connections (Bluetooth + WiFi langsung), otomatis tanpa pairing.
- **HP ke node ESP32**: WiFi `MeshLokal-camN` (sandi `12345678`). Aplikasi menemukan node secara otomatis.

## Build

Butuh Flutter 3.32 atau lebih baru (dikembangkan dengan 3.47) dan Android SDK (lewat Android Studio).

```bash
cd mobile
flutter pub get
flutter run                     # ke HP yang tersambung USB (USB debugging aktif)
flutter build apk --release     # build/app/outputs/flutter-apk/app-release.apk
```

Salin APK ke HP lain lalu install. Untuk menguji multi-hop, butuh minimal 3–4 HP Android.

## Izin yang diminta

Lokasi, Perangkat di sekitar (Bluetooth/WiFi), dan Notifikasi.

- Android mewajibkan izin lokasi dan **GPS menyala** untuk mencari HP lain.
- Aplikasi menjalankan *foreground service* (notifikasi "MeshLokal aktif") supaya tetap meneruskan pesan saat layar mati.
- Jangan tutup paksa aplikasi dari recent apps. Kalau ditutup paksa, HP berhenti meneruskan pesan.

## Struktur kode

```
lib/
  mesh/protocol.dart     format pesan (harus sama dengan firmware/esp32cam/mesh.h)
  mesh/crypto.dart       identitas keypair, tanda tangan, enkripsi DM & channel
  mesh/store.dart        SQLite: relay (store-and-forward), chat, kontak, channel, SOS
  mesh/mesh_core.dart    terima → verifikasi → simpan → teruskan (gossip + TTL), ACK
  transport/nearby_transport.dart   HP ↔ HP (scanning berselang untuk hemat baterai)
  transport/node_transport.dart     HP ↔ node ESP32 (HTTP push/pull di WiFi node)
  app_state.dart         merangkai semuanya + lokasi + foreground service
  ui/                    layar Chat, SOS, Jaringan, Kamera
test/mesh_core_test.dart simulasi beberapa HP di memori
```

## Uji

```bash
flutter test
```

Tes mensimulasikan beberapa HP di memori:
- chat lewat 3 relay (A → B → C → D) beserta ACK-nya;
- relay tidak bisa membaca isi pesan;
- TTL membatasi jumlah lompatan;
- pesan palsu ditolak;
- channel hanya terbaca oleh yang tahu kodenya;
- SOS tetap menyebar dalam mode darurat;
- store-and-forward saat tujuan sempat di luar jangkauan.
