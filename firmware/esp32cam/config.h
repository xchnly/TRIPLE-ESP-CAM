#pragma once

// ====================================================================
//  KONFIGURASI PER NODE
//  Untuk tiap board cukup ganti CAM_NUMBER (1, 2, 3) dan CAM_NAME
//  sebelum upload.
// ====================================================================

#define CAM_NUMBER     1               // 1 / 2 / 3  -> id jadi cam1 / cam2 / cam3
#define CAM_NAME       "Kamera 1"      // nama bebas untuk ditampilkan di web

// --------------------------------------------------------------------
//  MODE JARINGAN
//   1 = WiFi dari ESP sendiri (tanpa router):
//       cam1 memancarkan hotspot, cam2/cam3 + laptop connect ke hotspot itu.
//       IP tetap: cam1 = 192.168.4.1, cam2 = 192.168.4.202, cam3 = 192.168.4.203
//       Server dijalankan dengan:  python app.py --hotspot
//   0 = Pakai router / hotspot HP (WIFI_SSID di bawah).
// --------------------------------------------------------------------
#define USE_ESP_HOTSPOT  1

// --- Mode 1: hotspot dari ESP (cam1) ---
#define AP_SSID        "TRIPLE-ESP-CAM"
#define AP_PASSWORD    "12345678"      // minimal 8 karakter
#define AP_CHANNEL     6

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
