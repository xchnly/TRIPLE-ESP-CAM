# TRIPLE-ESP-CAM

Sistem kamera terdistribusi dengan 3 (atau lebih) **ESP32-CAM** yang terhubung lewat WiFi ke satu **server web pusat**.

```
 ┌──────────┐  heartbeat (POST /api/register)  ┌───────────────────────┐
 │ ESP32-CAM│ ───────────────────────────────▶ │  Server pusat (Flask) │◀── Browser
 │  cam1    │ ◀─── GET /capture, /control ──── │  - registry kamera    │    (dashboard)
 └──────────┘      GET :81/stream              │  - capture paralel    │
 ┌──────────┐                                  │  - galeri foto        │
 │  cam2    │ ◀──────────────────────────────▶ │  - auto-capture       │
 └──────────┘                                  │  - proxy live stream  │
 ┌──────────┐                                  └───────────────────────┘
 │  cam3    │ ◀──────────────────────────────▶
 └──────────┘
```

Tiap node berdiri sendiri (punya web server sendiri) dan otomatis mendaftar ke server.
Server mengkoordinasi: ambil foto dari **semua kamera sekaligus**, live stream, atur setting, simpan galeri.

## Fitur
- Auto-discovery: ESP32-CAM mengirim heartbeat tiap 10 detik → status online/offline, RSSI, uptime
- Live stream MJPEG tiap kamera (diproxy lewat server)
- Capture 1 kamera atau **capture semua secara paralel** (nama file per batch sama, mudah dicocokkan)
- Galeri foto (lihat / download / hapus), file di `server/captures/<cam_id>/`
- Atur resolusi, kualitas JPEG, brightness, contrast, saturation, flip, mirror
- Flash LED per kamera atau semua
- Auto-capture terjadwal (setiap N detik)

## Pilih mode jaringan (`USE_ESP_HOTSPOT` di `config.h`)

| | Mode 1: WiFi dari ESP (default) | Mode 0: Router / hotspot HP |
|---|---|---|
| WiFi | `cam1` memancarkan hotspot `TRIPLE-ESP-CAM` (pass `12345678`) | WiFi rumah / hotspot HP 2.4 GHz |
| IP kamera | tetap: cam1 `192.168.4.1`, cam2 `192.168.4.202`, cam3 `192.168.4.203` | dari router (dideteksi via heartbeat) |
| Laptop | connect ke WiFi `TRIPLE-ESP-CAM` | connect ke WiFi yang sama |
| Jalankan server | `python app.py --hotspot` | `python app.py` |
| Yang perlu diisi | hanya `CAM_NUMBER` & `CAM_NAME` | + `WIFI_SSID`, `WIFI_PASSWORD`, `SERVER_URL` |

Catatan mode 1: nyalakan **cam1 dulu** (dia "router"-nya). Selama laptop tersambung ke hotspot ESP, laptop tidak punya internet. Jarak tiap kamera ke cam1 jangan terlalu jauh (±10–20 m tanpa halangan).

## 1. Upload firmware ke tiap ESP32-CAM

1. Arduino IDE → Boards Manager → install **esp32** by Espressif.
2. Buka `firmware/esp32cam/esp32cam.ino`.
3. Edit `firmware/esp32cam/config.h`:
   - `CAM_NUMBER` → **`1`**, lalu `2`, lalu `3` untuk board berikutnya (harus unik)
   - `CAM_NAME` → nama bebas
   - Mode 0 saja: `WIFI_SSID`, `WIFI_PASSWORD`, `SERVER_URL` (IP komputer server, mis. `http://192.168.1.100:5000`)
4. Tools → Board: **AI Thinker ESP32-CAM**, Partition Scheme: *Huge APP*, PSRAM: *Enabled*.
5. Upload (pakai FTDI / ESP32-CAM-MB; untuk FTDI: GPIO0 ke GND saat upload, lalu lepas & reset).
6. Ulangi untuk 3 board dengan `CAM_NUMBER` berbeda.

Buka Serial Monitor (115200) untuk melihat IP tiap kamera.

## 2. Jalankan server pusat

```bash
cd server
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python app.py
```

Mode hotspot ESP: sambungkan laptop ke WiFi `TRIPLE-ESP-CAM`, jalankan `python app.py --hotspot`, lalu buka `http://localhost:5000`.

Mode router: buka `http://<ip-komputer>:5000` dari browser mana pun di jaringan yang sama.
Jika firewall aktif, izinkan port 5000.

**Tanpa heartbeat?** Daftarkan kamera manual:
```bash
STATIC_CAMS="cam1=192.168.1.51,cam2=192.168.1.52,cam3=192.168.1.53" python app.py
```

## Endpoint

### Di tiap ESP32-CAM
| Endpoint | Fungsi |
|---|---|
| `GET /capture` | Foto JPEG |
| `GET /status` | Status JSON |
| `GET /control?var=framesize&val=9` | Ubah setting (`framesize`, `quality`, `brightness`, `contrast`, `saturation`, `vflip`, `hmirror`, `flash`) |
| `GET :81/stream` | Live MJPEG |

### Di server
| Endpoint | Fungsi |
|---|---|
| `POST /api/register` | Heartbeat dari node |
| `GET /api/cameras` | Daftar kamera + status |
| `POST /api/capture/<id>` | Capture & simpan 1 kamera |
| `POST /api/capture-all` | Capture semua kamera online secara paralel |
| `GET /api/snapshot/<id>` | Foto tanpa menyimpan |
| `GET /api/stream/<id>` | Proxy live stream |
| `POST /api/control/<id>` · `/api/control-all` | Body `{"var":"flash","val":1}` |
| `GET /api/captures` · `DELETE /api/captures/<file>` | Galeri |
| `GET/POST /api/schedule` | Body `{"enabled":true,"interval":60}` |

Contoh capture semua dari skrip lain:
```bash
curl -X POST http://192.168.1.100:5000/api/capture-all
```

## Tips / troubleshooting
- **Brownout / restart terus**: pakai power supply 5V ≥ 2A yang stabil, jangan dari pin 3.3V.
- **Kamera tidak muncul di web**: cek `SERVER_URL` (jangan `localhost`), pastikan komputer & ESP satu jaringan, cek firewall port 5000.
- **Stream patah-patah dengan 3 kamera**: turunkan resolusi ke VGA/QVGA, atau naikkan nilai quality (angka besar = file kecil). Jangan stream terus-menerus jika hanya perlu capture.
- **`Camera init gagal`**: cek kabel ribbon kamera dan pilih board AI Thinker.
- ESP32-CAM hanya mendukung WiFi **2.4 GHz**.
