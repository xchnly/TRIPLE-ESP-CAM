#pragma once
/*
 * MeshLokal relay untuk ESP32-CAM.
 *
 *  - Antar node : ESP-NOW broadcast (tanpa router, tanpa internet). Pesan dipecah
 *                 jadi beberapa frame karena 1 frame ESP-NOW maks 250 byte.
 *  - HP -> node : HTTP di WiFi AP node:
 *        POST /mesh/push                     kirim pesan (satu per baris / NDJSON)
 *        GET  /mesh/pull?boot=<b>&since=<s>  ambil pesan baru (maks 16 per panggilan)
 *        GET  /mesh/info                     info node + tetangga
 *        GET  /peer/capture?id=camN          foto dari kamera node lain (lewat WiFi cam1)
 *
 * Node TIDAK memeriksa isi atau tanda tangan pesan (itu tugas HP). Node hanya membaca
 * awalan tetap {"id":"<32 hex>","ttl":<n>, untuk deduplikasi dan TTL, lalu meneruskan.
 * Aturan TTL sama dengan aplikasi: diteruskan hanya bila ttl > 1, dengan ttl - 1.
 */

#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_heap_caps.h>
#include <esp_arduino_version.h>
#include <HTTPClient.h>
#include "freertos/queue.h"
#include "freertos/semphr.h"

#define MESH_MAX_MSG     1400
#define MESH_STORE_N     64      // pesan yang disimpan untuk HP (ring buffer, di PSRAM)
#define MESH_SEEN_N      512     // ID pesan yang sudah pernah dilihat
#define MESH_PULL_MAX    16
#define MESH_RESEND_AGE  (30UL * 60 * 1000)   // pesan < 30 menit dikirim ulang ke node baru
#define FRAG_HDR         8
#define FRAG_DATA        240
#define MAX_FRAGS        6       // 6 x 240 >= 1400
#define BEACON_MS        5000
#define NEIGHBOR_TTL_MS  30000

static const uint8_t BCAST[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

struct MeshEntry { uint32_t seq; uint32_t at; uint16_t len; char *data; };
struct Neighbor  { bool used; char id[12]; char name[33]; uint32_t lastSeen; };
struct RxFrame   { uint8_t mac[6]; uint8_t len; uint8_t data[250]; };
struct Reasm     { bool used; uint8_t mac[6]; uint32_t key; uint8_t count; uint8_t gotMask;
                   uint16_t lastLen; uint32_t at; char buf[MAX_FRAGS * FRAG_DATA + 1]; };

static MeshEntry meshStore[MESH_STORE_N];
static uint32_t  meshSeq = 0, meshBoot = 0;
static uint32_t  seenRing[MESH_SEEN_N];
static int       seenPos = 0;
static Neighbor  neighbors[8];
static Reasm     reasm[4];
static QueueHandle_t     rxQueue;
static SemaphoreHandle_t meshMutex;
static uint32_t  resendAt = 0, lastBeacon = 0;
static uint32_t  meshRelayed = 0;
static wifi_interface_t meshIf = WIFI_IF_AP;

// ------------------------------------------------------------------
//  Utilitas
// ------------------------------------------------------------------
static uint32_t fnv1a(const char *s, size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) { h ^= (uint8_t)s[i]; h *= 16777619u; }
  return h ? h : 1;  // 0 dipakai sebagai "kosong"
}

static void *bigAlloc(size_t n) {
  void *p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  return p ? p : malloc(n);
}

// Ambil hash ID dan TTL dari awalan pesan. ttlStart/ttlEnd = posisi angka TTL.
static bool parseHeader(const char *m, size_t len, uint32_t &key, int &ttl, size_t &ttlStart, size_t &ttlEnd) {
  static const char P1[] = "{\"id\":\"";   // 7 karakter
  static const char P2[] = "\",\"ttl\":";  // 8 karakter
  if (len < 60 || len > MESH_MAX_MSG || memcmp(m, P1, 7) != 0) return false;
  for (int i = 7; i < 39; i++) {
    char c = m[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  if (memcmp(m + 39, P2, 8) != 0) return false;
  ttlStart = 47;
  ttl = 0;
  size_t i = ttlStart;
  while (i < len && i < ttlStart + 2 && m[i] >= '0' && m[i] <= '9') ttl = ttl * 10 + (m[i++] - '0');
  if (i == ttlStart || i >= len || m[i] != ',') return false;
  ttlEnd = i;
  key = fnv1a(m + 7, 32);
  return true;
}

// Salin pesan dengan TTL baru. Mengembalikan panjang baru.
static size_t withTtl(const char *m, size_t len, size_t ttlStart, size_t ttlEnd, int ttl, char *out) {
  memcpy(out, m, ttlStart);
  size_t n = ttlStart + sprintf(out + ttlStart, "%d", ttl);
  memcpy(out + n, m + ttlEnd, len - ttlEnd);
  n += len - ttlEnd;
  out[n] = 0;
  return n;
}

static bool seenHas(uint32_t key) {
  for (int i = 0; i < MESH_SEEN_N; i++) if (seenRing[i] == key) return true;
  return false;
}

static void seenAdd(uint32_t key) {
  seenRing[seenPos] = key;
  seenPos = (seenPos + 1) % MESH_SEEN_N;
}

// Salin string ke buffer, buang karakter yang merusak JSON.
static void cleanCopy(char *dst, const char *src, size_t cap) {
  size_t j = 0;
  for (size_t i = 0; src[i] && j + 1 < cap; i++) {
    char c = src[i];
    if (c >= 0x20 && c != '"' && c != '\\') dst[j++] = c;
  }
  dst[j] = 0;
}

// ------------------------------------------------------------------
//  ESP-NOW: kirim (dipecah per frame)
// ------------------------------------------------------------------
static void espnowSend(const uint8_t *data, size_t len) {
  for (int attempt = 0; attempt < 5; attempt++) {
    if (esp_now_send(BCAST, data, len) == ESP_OK) return;
    delay(3);  // antrean TX penuh
  }
}

static void meshBroadcast(const char *m, size_t len, uint32_t key) {
  uint8_t frame[FRAG_HDR + FRAG_DATA];
  uint8_t count = (len + FRAG_DATA - 1) / FRAG_DATA;
  for (uint8_t i = 0; i < count; i++) {
    size_t off = (size_t)i * FRAG_DATA;
    size_t n = min((size_t)FRAG_DATA, len - off);
    frame[0] = 'M'; frame[1] = 'F';
    memcpy(frame + 2, &key, 4);
    frame[6] = i; frame[7] = count;
    memcpy(frame + FRAG_HDR, m + off, n);
    espnowSend(frame, FRAG_HDR + n);
    delay(2);
  }
  meshRelayed++;
}

static void sendBeacon() {
  uint8_t frame[3 + 12 + 33] = {'M', 'B', 1};
  strncpy((char *)frame + 3, camId, 11);
  strncpy((char *)frame + 15, CAM_NAME, 32);
  espnowSend(frame, sizeof(frame));
}

// ------------------------------------------------------------------
//  Terima pesan utuh (dari HP via HTTP atau dari node lain via ESP-NOW)
// ------------------------------------------------------------------
// Mengembalikan true bila pesan baru (belum pernah dilihat).
static bool meshAccept(const char *m, size_t len) {
  uint32_t key; int ttl; size_t ts, te;
  if (!parseHeader(m, len, key, ttl, ts, te)) return false;

  char *copy = (char *)bigAlloc(len + 1);
  if (!copy) return false;
  memcpy(copy, m, len);
  copy[len] = 0;

  xSemaphoreTake(meshMutex, portMAX_DELAY);
  if (seenHas(key)) {
    xSemaphoreGive(meshMutex);
    free(copy);
    return false;
  }
  seenAdd(key);
  MeshEntry &e = meshStore[meshSeq % MESH_STORE_N];
  free(e.data);
  e.seq = ++meshSeq;
  e.at = millis();
  e.len = len;
  e.data = copy;
  xSemaphoreGive(meshMutex);

  if (ttl > 1) {
    char *fwd = (char *)bigAlloc(len + 4);
    if (fwd) {
      size_t n = withTtl(m, len, ts, te, ttl - 1, fwd);
      meshBroadcast(fwd, n, key);
      free(fwd);
    }
  }
  return true;
}

// Kirim ulang pesan yang masih segar saat ada node baru (store-and-forward antar node).
static void meshResendRecent() {
  int sent = 0;
  for (uint32_t s = meshSeq; s > 0 && s + MESH_STORE_N > meshSeq && sent < 32; s--) {
    char *buf = NULL; size_t len = 0;
    xSemaphoreTake(meshMutex, portMAX_DELAY);
    MeshEntry &e = meshStore[s % MESH_STORE_N];
    if (e.data && e.seq == s && millis() - e.at < MESH_RESEND_AGE) {
      len = e.len;
      buf = (char *)bigAlloc(len + 4);
      if (buf) memcpy(buf, e.data, len);
    }
    xSemaphoreGive(meshMutex);
    if (!buf) continue;
    uint32_t key; int ttl; size_t ts, te;
    if (parseHeader(buf, len, key, ttl, ts, te) && ttl > 1) {
      char *fwd = (char *)bigAlloc(len + 4);
      if (fwd) {
        meshBroadcast(fwd, withTtl(buf, len, ts, te, ttl - 1, fwd), key);
        free(fwd);
        sent++;
      }
    }
    free(buf);
  }
}

// ------------------------------------------------------------------
//  ESP-NOW: terima frame (callback berjalan di task WiFi -> cukup antrekan)
// ------------------------------------------------------------------
#if ESP_ARDUINO_VERSION_MAJOR >= 3
static void onEspNowRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  const uint8_t *mac = info->src_addr;
#else
static void onEspNowRecv(const uint8_t *mac, const uint8_t *data, int len) {
#endif
  if (len < 3 || len > 250 || data[0] != 'M') return;
  RxFrame f;
  memcpy(f.mac, mac, 6);
  f.len = len;
  memcpy(f.data, data, len);
  xQueueSend(rxQueue, &f, 0);
}

static void handleBeacon(const RxFrame &f) {
  if (f.len < 3 + 12 + 33) return;
  char id[12], name[33];
  memcpy(id, f.data + 3, 11); id[11] = 0;
  memcpy(name, f.data + 15, 32); name[32] = 0;
  Neighbor *slot = NULL, *oldest = &neighbors[0];
  for (auto &n : neighbors) {
    if (n.used && !strcmp(n.id, id)) { slot = &n; break; }
    if (!n.used || n.lastSeen < oldest->lastSeen) oldest = &n;
  }
  bool isNew = !slot || millis() - slot->lastSeen > NEIGHBOR_TTL_MS;
  if (!slot) slot = oldest;
  slot->used = true;
  cleanCopy(slot->id, id, sizeof(slot->id));
  cleanCopy(slot->name, name, sizeof(slot->name));
  slot->lastSeen = millis();
  // Jeda acak supaya node-node tidak mengirim ulang bersamaan.
  if (isNew && meshSeq > 0) resendAt = millis() + 300 + (esp_random() % 1500);
}

static void handleFragment(const RxFrame &f) {
  if (f.len <= FRAG_HDR) return;
  uint32_t key;
  memcpy(&key, f.data + 2, 4);
  uint8_t idx = f.data[6], count = f.data[7];
  if (count == 0 || count > MAX_FRAGS || idx >= count) return;
  if (seenHas(key)) return;  // sudah punya, abaikan sisa frame

  Reasm *r = NULL, *freeSlot = NULL;
  for (auto &s : reasm) {
    if (s.used && s.key == key && !memcmp(s.mac, f.mac, 6)) { r = &s; break; }
    if (!s.used || millis() - s.at > 2000) freeSlot = &s;
  }
  if (!r) {
    if (!freeSlot) return;
    r = freeSlot;
    r->used = true; r->key = key; r->count = count; r->gotMask = 0; r->lastLen = 0;
    memcpy(r->mac, f.mac, 6);
  }
  r->at = millis();
  size_t n = f.len - FRAG_HDR;
  memcpy(r->buf + (size_t)idx * FRAG_DATA, f.data + FRAG_HDR, n);
  if (idx == count - 1) r->lastLen = n;
  r->gotMask |= (1 << idx);
  if (r->gotMask == (1 << count) - 1) {
    size_t total = (size_t)(count - 1) * FRAG_DATA + r->lastLen;
    r->used = false;
    meshAccept(r->buf, total);
  }
}

// ------------------------------------------------------------------
//  HTTP untuk HP
// ------------------------------------------------------------------
static esp_err_t mesh_push_handler(httpd_req_t *req) {
  size_t total = req->content_len;
  if (total == 0 || total > 8192) {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body 1..8192 byte");
    return ESP_FAIL;
  }
  char *body = (char *)bigAlloc(total + 1);
  if (!body) { httpd_resp_send_500(req); return ESP_FAIL; }
  size_t got = 0;
  while (got < total) {
    int r = httpd_req_recv(req, body + got, total - got);
    if (r <= 0) { free(body); httpd_resp_send_500(req); return ESP_FAIL; }
    got += r;
  }
  body[total] = 0;

  int accepted = 0;
  char *line = body;
  while (line && *line) {
    char *nl = strchr(line, '\n');
    size_t len = nl ? (size_t)(nl - line) : strlen(line);
    while (len && (line[len - 1] == '\r' || line[len - 1] == ' ')) len--;
    if (len && meshAccept(line, len)) accepted++;
    line = nl ? nl + 1 : NULL;
  }
  free(body);

  char resp[32];
  snprintf(resp, sizeof(resp), "{\"accepted\":%d}", accepted);
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, resp, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t mesh_pull_handler(httpd_req_t *req) {
  char query[64], val[16];
  uint32_t since = 0, boot = 0;
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
    if (httpd_query_key_value(query, "since", val, sizeof(val)) == ESP_OK) since = strtoul(val, NULL, 10);
    if (httpd_query_key_value(query, "boot", val, sizeof(val)) == ESP_OK) boot = strtoul(val, NULL, 10);
  }
  if (boot != meshBoot) since = 0;  // node baru restart: kirim dari awal

  // Salin pesan di bawah mutex, kirim setelah dilepas.
  char *buf = (char *)bigAlloc(MESH_PULL_MAX * (MESH_MAX_MSG + 1) + 64);
  if (!buf) { httpd_resp_send_500(req); return ESP_FAIL; }
  size_t n = 0;
  uint32_t last = since;
  int count = 0;
  xSemaphoreTake(meshMutex, portMAX_DELAY);
  uint32_t oldest = meshSeq > MESH_STORE_N ? meshSeq - MESH_STORE_N + 1 : 1;
  for (uint32_t s = max(since + 1, oldest); s <= meshSeq && count < MESH_PULL_MAX; s++) {
    MeshEntry &e = meshStore[s % MESH_STORE_N];
    if (!e.data || e.seq != s) continue;
    if (count++) buf[n++] = ',';
    memcpy(buf + n, e.data, e.len);
    n += e.len;
    last = s;
  }
  if (count == 0) last = meshSeq > since ? meshSeq : since;
  xSemaphoreGive(meshMutex);

  char head[64];
  snprintf(head, sizeof(head), "{\"boot\":%lu,\"seq\":%lu,\"msgs\":[", (unsigned long)meshBoot, (unsigned long)last);
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_send_chunk(req, head, strlen(head));
  if (n) httpd_resp_send_chunk(req, buf, n);
  httpd_resp_send_chunk(req, "]}", 2);
  free(buf);
  return httpd_resp_send_chunk(req, NULL, 0);
}

// IP node lain di jaringan WiFi cam1 (lihat config.h).
static String peerIp(int n) {
  return n == 1 ? String("192.168.4.1") : String("192.168.4.") + String(200 + n);
}

static esp_err_t mesh_info_handler(httpd_req_t *req) {
  String j;
  j.reserve(768);
  j += "{\"id\":\""; j += camId;
  j += "\",\"name\":\""; j += CAM_NAME;
  j += "\",\"ap\":\""; j += WiFi.softAPSSID();
  j += "\",\"uplink\":"; j += (WiFi.status() == WL_CONNECTED || CAM_NUMBER == 1) ? "true" : "false";
  j += ",\"boot\":"; j += meshBoot;
  j += ",\"seq\":"; j += meshSeq;
  j += ",\"relayed\":"; j += meshRelayed;
  j += ",\"neighbors\":[";
  bool first = true;
  for (auto &n : neighbors) {
    if (!n.used || millis() - n.lastSeen > NEIGHBOR_TTL_MS) continue;
    if (!first) j += ",";
    first = false;
    int num = atoi(n.id + 3);
    j += "{\"id\":\""; j += n.id;
    j += "\",\"name\":\""; j += n.name;
    j += "\",\"age\":"; j += (millis() - n.lastSeen) / 1000;
    j += ",\"ip\":\""; j += peerIp(num);
    j += "\"}";
  }
  j += "]}";
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// Ambil foto dari node lain lewat jaringan WiFi cam1 lalu teruskan ke HP.
// Bisa bila node ini cam1, atau node ini tersambung ke WiFi cam1 (JOIN_CAM1_WIFI).
static esp_err_t peer_capture_handler(httpd_req_t *req) {
  char query[32], id[12];
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "id", id, sizeof(id)) != ESP_OK || strncmp(id, "cam", 3) != 0) {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "butuh ?id=camN");
    return ESP_FAIL;
  }
  int num = atoi(id + 3);
  if (num == CAM_NUMBER) return capture_handler(req);
  if (CAM_NUMBER != 1 && WiFi.status() != WL_CONNECTED) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_send(req, "node ini tidak tersambung ke WiFi cam1", HTTPD_RESP_USE_STRLEN);
  }

  HTTPClient http;
  http.setTimeout(6000);
  http.begin("http://" + peerIp(num) + "/capture");
  int code = http.GET();
  if (code != 200) {
    http.end();
    httpd_resp_set_status(req, "502 Bad Gateway");
    return httpd_resp_send(req, "kamera tidak terjangkau", HTTPD_RESP_USE_STRLEN);
  }
  httpd_resp_set_type(req, "image/jpeg");
  WiFiClient *s = http.getStreamPtr();
  int remaining = http.getSize();  // -1 bila tidak diketahui
  uint8_t chunk[1460];
  uint32_t lastData = millis();
  while (http.connected() && (remaining > 0 || remaining == -1) && millis() - lastData < 6000) {
    size_t avail = s->available();
    if (!avail) { delay(2); continue; }
    int r = s->readBytes(chunk, min(avail, sizeof(chunk)));
    if (r <= 0) break;
    lastData = millis();
    if (httpd_resp_send_chunk(req, (const char *)chunk, r) != ESP_OK) break;
    if (remaining > 0) remaining -= r;
  }
  http.end();
  return httpd_resp_send_chunk(req, NULL, 0);
}

static void meshRegisterHttp(httpd_handle_t h) {
  static httpd_uri_t push = {"/mesh/push", HTTP_POST, mesh_push_handler, NULL};
  static httpd_uri_t pull = {"/mesh/pull", HTTP_GET, mesh_pull_handler, NULL};
  static httpd_uri_t info = {"/mesh/info", HTTP_GET, mesh_info_handler, NULL};
  static httpd_uri_t peer = {"/peer/capture", HTTP_GET, peer_capture_handler, NULL};
  httpd_register_uri_handler(h, &push);
  httpd_register_uri_handler(h, &pull);
  httpd_register_uri_handler(h, &info);
  httpd_register_uri_handler(h, &peer);
}

// ------------------------------------------------------------------
//  Init & loop
// ------------------------------------------------------------------
static void meshBegin(wifi_interface_t iface) {
  meshIf = iface;
  meshBoot = esp_random() & 0x7FFFFFFF;
  meshMutex = xSemaphoreCreateMutex();
  rxQueue = xQueueCreate(48, sizeof(RxFrame));

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW gagal init");
    return;
  }
  esp_now_register_recv_cb(onEspNowRecv);
  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, BCAST, 6);
  peer.channel = 0;  // ikut channel WiFi saat ini
  peer.ifidx = iface;
  peer.encrypt = false;
  if (esp_now_add_peer(&peer) != ESP_OK) Serial.println("ESP-NOW: gagal tambah peer broadcast");
  Serial.println("Mesh ESP-NOW aktif");
}

static void meshLoop() {
  RxFrame f;
  int budget = 16;
  while (budget-- && xQueueReceive(rxQueue, &f, 0) == pdTRUE) {
    if (f.data[1] == 'B') handleBeacon(f);
    else if (f.data[1] == 'F') handleFragment(f);
  }
  if (millis() - lastBeacon >= BEACON_MS) {
    lastBeacon = millis();
    sendBeacon();
  }
  if (resendAt && (int32_t)(millis() - resendAt) >= 0) {
    resendAt = 0;
    meshResendRecent();
  }
}
