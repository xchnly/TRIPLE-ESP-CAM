#pragma once

// ====================================================================
//  KONFIGURASI PER NODE
//  Ubah CAM_ID / CAM_NAME untuk tiap ESP32-CAM (cam1, cam2, cam3)
//  sebelum meng-upload ke masing-masing board.
// ====================================================================

// --- WiFi ---
#define WIFI_SSID      "NAMA_WIFI_ANDA"
#define WIFI_PASSWORD  "PASSWORD_WIFI_ANDA"

// --- Identitas node ---
#define CAM_ID         "cam1"          // cam1 / cam2 / cam3 (harus unik)
#define CAM_NAME       "Kamera Depan"  // nama bebas untuk ditampilkan di web

// --- Server pusat (PC/laptop/Raspberry Pi yang menjalankan server/app.py) ---
// Gunakan IP LAN komputer server, BUKAN "localhost".
#define SERVER_URL     "http://192.168.1.100:5000"

// Interval heartbeat/registrasi ke server (ms)
#define HEARTBEAT_INTERVAL_MS  10000

// --- (Opsional) IP statis. Kosongkan STATIC_IP ("") untuk DHCP ---
#define STATIC_IP      ""              // contoh: "192.168.1.51"
#define GATEWAY_IP     "192.168.1.1"
#define SUBNET_MASK    "255.255.255.0"
