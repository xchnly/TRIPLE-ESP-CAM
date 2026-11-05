# TRIPLE-ESP-CAM · MeshLokal

Jaringan komunikasi **offline penuh**: tanpa internet, tanpa router, tanpa server di cloud.

- **Aplikasi Android (Flutter)**: chat 1-1 terenkripsi, channel rombongan, dan tombol **SOS** dengan koordinat GPS. Setiap HP ikut meneruskan pesan orang lain.
- **Node ESP32-CAM**: tiap node memancarkan WiFi untuk HP, meneruskan pesan ke node lain lewat **ESP-NOW**, dan sekaligus berfungsi sebagai **kamera**.
- **Dashboard laptop (basecamp)**: melihat semua kamera, mengambil foto, serta memantau **SOS** dan orang yang aktif di jaringan.

Setiap HP atau node yang ditambahkan memperluas jangkauan. Pesan melompat dari perangkat ke perangkat (multi-hop) sampai tujuan.

```
   HP A ──Bluetooth/WiFi──▶ HP B ──▶ HP C          (Nearby Connections, HP ↔ HP)
                              │
                              │ WiFi "MeshLokal-cam2"
                              ▼
   ┌────────┐  ESP-NOW  ┌────────┐  ESP-NOW  ┌────────┐
   │  cam1  │◀─────────▶│  cam2  │◀─────────▶│  cam3  │     node relay + kamera
   └────────┘           └────────┘           └────────┘
        ▲ WiFi "MeshLokal-cam1"                   ▲ WiFi "MeshLokal-cam3"
        │                                         │
   Laptop basecamp                              HP D, HP E ...
   (dashboard: kamera, SOS, orang aktif)
```

## Isi repo

| Folder | Isi |
|---|---|
| `firmware/esp32cam/` | Firmware ESP32-CAM: kamera + WiFi AP + relay mesh (`mesh.h`) |
| `mobile/` | Aplikasi Android **MeshLokal** (Flutter). Panduan: [`mobile/README.md`](mobile/README.md) |
| `server/` | Dashboard laptop (Python/Flask) |
| `firmware/test/` | Uji di PC: memastikan parser firmware cocok dengan format pesan aplikasi |

## Cara kerja singkat

- **Identitas**: tanpa akun. Saat pertama dibuka, aplikasi membuat keypair di HP. Kunci publik itulah ID-mu.
- **Pesan**: setiap pesan ditandatangani (Ed25519). Pesan palsu atau yang isinya diubah ditolak.
- **Chat 1-1**: dienkripsi end-to-end (X25519 + ChaCha20-Poly1305). HP dan node yang meneruskan tidak bisa membacanya.
- **Channel**: dienkripsi dengan kunci dari kode channel. Siapa pun yang tahu kodenya bisa bergabung.
- **SOS**: sengaja tidak dienkripsi, supaya semua HP, node, dan dashboard bisa membacanya.
- **Relay (gossip + TTL)**: setiap pesan punya ID unik dan TTL. Penerima meneruskan ke semua tetangga dengan TTL − 1 sampai TTL habis (chat 8 hop, SOS 15 hop). Pesan yang sudah pernah dilihat dibuang.
- **Store-and-forward**: pesan disimpan. Saat bertemu HP atau node baru, pesan yang dibawa (sampai 24 jam di HP, 30 menit di node) dikirim ulang. Jadi pesan tetap bisa sampai walau tujuan sedang di luar jangkauan.
- **Status pesan**: tersimpan (jam) → diteruskan (✓) → diterima (✓✓, ACK dari penerima).

## 1. Firmware ESP32-CAM

1. Arduino IDE → Boards Manager → install **esp32** by Espressif.
2. Buka `firmware/esp32cam/esp32cam.ino`. Tab `config.h` dan `mesh.h` ikut terbuka.
3. Di `config.h`, untuk tiap board ganti:
   - `CAM_NUMBER` → `1`, lalu `2`, lalu `3` (harus unik)
   - `CAM_NAME` → nama bebas, misalnya `"Pos 1"` atau `"Basecamp"`
4. Tools:
   - Board **AI Thinker ESP32-CAM**
   - Partition Scheme **Huge APP**
5. Upload. Ulangi untuk setiap board.

Hasilnya:

| Node | WiFi untuk HP | IP | Tambahan |
|---|---|---|---|
| cam1 | `MeshLokal-cam1` | 192.168.4.1 | laptop dashboard connect ke sini |
| cam2 | `MeshLokal-cam2` | 192.168.12.1 | juga ikut WiFi cam1 sebagai 192.168.4.202 bila terjangkau |
| cam3 | `MeshLokal-cam3` | 192.168.13.1 | juga ikut WiFi cam1 sebagai 192.168.4.203 bila terjangkau |

Semua WiFi memakai sandi `12345678`. Semua node **wajib di channel WiFi yang sama** (`AP_CHANNEL`, default 6), karena itu syarat ESP-NOW.

Node yang jauh dari cam1 tetap meneruskan pesan lewat ESP-NOW. Yang hilang hanya kameranya di dashboard laptop. Untuk node seperti itu, set `JOIN_CAM1_WIFI 0` supaya lebih stabil.

## 2. Aplikasi Android

Lihat [`mobile/README.md`](mobile/README.md). Ringkasnya:

```bash
cd mobile
flutter pub get
flutter build apk --release      # hasil: build/app/outputs/flutter-apk/app-release.apk
```

## 3. Dashboard laptop (basecamp)

Jalankan `pip install` **sebelum** pindah ke WiFi ESP, karena WiFi ESP tidak punya internet:

```bash
cd server
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

Lalu sambungkan laptop ke WiFi `MeshLokal-cam1` dan jalankan:

```bash
python app.py --hotspot
```

Buka `http://localhost:5000`.

- **Panel kamera**: live, ambil foto satu kamera atau semua sekaligus, galeri, setting, flash, dan ambil foto otomatis.
- **Tab Mesh**:
  - **SOS** dari HP, lengkap dengan koordinat. Muncul tanda merah di bar atas.
  - **Orang di jaringan**: nama, jumlah hop, dan lokasi bila mereka berbagi lokasi.
  - **Node**: tiap node beserta tetangga ESP-NOW-nya.
  - Chat tidak bisa dibaca di dashboard karena terenkripsi.

Mode lama dengan router masih ada: set `USE_ESP_HOTSPOT 0` lalu jalankan `python app.py`.

## Endpoint

### Di tiap ESP32-CAM
| Endpoint | Fungsi |
|---|---|
| `GET /capture` | Foto JPEG |
| `GET /status` | Status JSON |
| `GET /control?var=framesize&val=9` | Ubah setting (`framesize`, `quality`, `brightness`, `contrast`, `saturation`, `vflip`, `hmirror`, `flash`) |
| `GET :81/stream` | Live MJPEG |
| `POST /mesh/push` | Kirim pesan mesh (NDJSON, maks 8 KB) |
| `GET /mesh/pull?boot=&since=` | Ambil pesan baru (maks 16 per panggilan) |
| `GET /mesh/info` | Info node + tetangga ESP-NOW |
| `GET /peer/capture?id=cam2` | Foto kamera node lain, lewat WiFi cam1 |

### Di server
| Endpoint | Fungsi |
|---|---|
| `GET /api/cameras` | Daftar kamera + status |
| `POST /api/capture/<id>` · `/api/capture-all` | Ambil & simpan foto (semua kamera paralel) |
| `GET /api/snapshot/<id>` · `/api/stream/<id>` | Foto tanpa simpan · proxy live stream |
| `POST /api/control/<id>` · `/api/control-all` | Body `{"var":"flash","val":1}` |
| `GET /api/captures` · `DELETE /api/captures/<file>` | Galeri |
| `GET/POST /api/schedule` | Body `{"enabled":true,"interval":60}` |
| `GET /api/mesh` | SOS, orang aktif, node |
| `POST /api/register` | Heartbeat node (mode router) |

## Format pesan mesh

Satu pesan = satu baris JSON. **Urutan field wajib seperti ini**, karena firmware hanya membaca awalan `{"id":"…","ttl":N,` tanpa JSON parser:

```json
{"id":"<32 hex>","ttl":8,"t":"dm|chan|sos|hello|ack","from":"<kunci publik>","to":"<kunci|id channel|*>","ts":1793102085000,"body":"…","sig":"…"}
```

Tanda tangan mencakup `id|t|from|to|ts|body`. TTL tidak ikut ditandatangani karena berubah di setiap hop. Uji kecocokan firmware dengan aplikasi:

```bash
bash firmware/test/run_parser_test.sh
```

## Batasan

- Aplikasi ini **bukan pengganti alat darurat resmi atau tim SAR**.
- Jangkauan nyata belum diukur. Perkiraan: HP ke HP sekitar 10–50 m, HP ke node sekitar 30–80 m, node ke node (ESP-NOW) sekitar 50–150 m di area terbuka. Perlu diukur di lapangan.
- Node ESP32 tidak memverifikasi tanda tangan; ia hanya meneruskan. Verifikasi dilakukan di HP. Dashboard laptop juga belum memverifikasi, jadi SOS di dashboard sebaiknya dikonfirmasi.
- Nearby Connections butuh Google Play Services. iOS belum didukung.
- Bila aplikasi ditutup paksa (di-swipe dari recent apps), HP berhenti meneruskan pesan.

## Tips / troubleshooting
- **Brownout / restart terus**: pakai power supply 5V ≥ 2A yang stabil, jangan dari pin 3.3V.
- **Node tidak saling melihat (tab Mesh, "tetangga" kosong)**: pastikan `AP_CHANNEL` sama di semua node dan jaraknya tidak terlalu jauh.
- **HP tersambung WiFi node tapi aplikasi bilang "tanpa node"**: matikan data seluler sebentar, atau tekan "Sambung camN" di tab Jaringan agar Android memakai WiFi node.
- **Stream patah-patah**: turunkan resolusi ke VGA/QVGA, atau pakai mode Snapshot.
- **`Camera init gagal`**: cek kabel ribbon kamera dan pilih board AI Thinker.
- ESP32-CAM hanya mendukung WiFi **2.4 GHz**.
