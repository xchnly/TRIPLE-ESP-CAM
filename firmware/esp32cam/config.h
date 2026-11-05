#pragma once

// ====================================================================
//  KONFIGURASI PER NODE
//  Untuk tiap board cukup ganti CAM_NUMBER (1, 2, 3, ...) dan CAM_NAME
//  sebelum upload.
// ====================================================================

#define CAM_NUMBER     1               // 1 / 2 / 3  -> id jadi cam1 / cam2 / cam3
#define CAM_NAME       "Pos 1"         // nama bebas untuk ditampilkan di web & aplikasi

// --------------------------------------------------------------------
//  MODE JARINGAN
//   1 = Offline penuh (default). SETIAP node memancarkan WiFi sendiri untuk HP:
//         cam1 -> "MeshLokal-cam1" (192.168.4.1)
//         camN -> "MeshLokal-camN" (192.168.(10+N).1)
//       Antar node saling meneruskan pesan lewat ESP-NOW, jadi jangkauan
//       bertambah setiap ada node baru (tidak perlu saling tersambung WiFi).
//       Laptop dashboard: connect ke "MeshLokal-cam1", jalankan  python app.py --hotspot
//   0 = Pakai router / hotspot HP (WIFI_SSID di bawah). ESP-NOW tetap jalan.
// --------------------------------------------------------------------
#define USE_ESP_HOTSPOT  1

// --- Mode 1 ---
#define AP_SSID_PREFIX "MeshLokal-cam" // SSID = prefix + CAM_NUMBER
#define AP_PASSWORD    "12345678"      // minimal 8 karakter, sama untuk semua node
#define AP_CHANNEL     6               // HARUS sama di semua node (syarat ESP-NOW)

// cam2, cam3, ... juga ikut tersambung ke WiFi cam1 (IP 192.168.4.20N) bila
// terjangkau. Ini membuat dashboard laptop & kamera node lain bisa dilihat dari
// satu tempat. Set 0 bila node jauh dari cam1 (lebih hemat & stabil).
#define JOIN_CAM1_WIFI 1

// --- Mode 0: router / hotspot HP ---
#define WIFI_SSID      "NAMA_WIFI_ANDA"
#define WIFI_PASSWORD  "PASSWORD_WIFI_ANDA"

// Server pusat untuk heartbeat (hanya mode 0). Pakai IP LAN laptop, BUKAN "localhost".
#define SERVER_URL     "http://192.168.1.100:5000"
#define HEARTBEAT_INTERVAL_MS  10000

// (Opsional, mode 0) IP statis. Kosongkan ("") untuk DHCP.
#define STATIC_IP      ""              // contoh: "192.168.1.51"
#define GATEWAY_IP     "192.168.1.1"
#define SUBNET_MASK    "255.255.255.0"
