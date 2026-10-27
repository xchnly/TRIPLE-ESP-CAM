/*
 * TRIPLE-ESP-CAM - firmware node kamera
 * Board  : AI-Thinker ESP32-CAM
 * Core   : Arduino-ESP32 2.x / 3.x (Board: "AI Thinker ESP32-CAM")
 *
 * Endpoint di setiap node:
 *   http://<ip>/            -> info singkat
 *   http://<ip>/capture     -> ambil 1 foto (JPEG)
 *   http://<ip>/status      -> status JSON (id, rssi, uptime, setting kamera)
 *   http://<ip>/control?var=<nama>&val=<nilai>
 *                           -> ubah setting: framesize, quality, brightness,
 *                              contrast, saturation, vflip, hmirror, flash
 *   http://<ip>:81/stream   -> live stream MJPEG
 *
 * Node juga mengirim heartbeat ke server pusat (SERVER_URL/api/register)
 * sehingga server otomatis tahu IP & status tiap kamera.
 */

#include "esp_camera.h"
#include "esp_http_server.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include "config.h"

// ---------- Pin AI-Thinker ESP32-CAM ----------
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22
#define FLASH_LED_PIN      4

#define PART_BOUNDARY "123456789000000000000987654321"
static const char *STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char *STREAM_BOUNDARY     = "\r\n--" PART_BOUNDARY "\r\n";
static const char *STREAM_PART         = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

httpd_handle_t api_httpd    = NULL;
httpd_handle_t stream_httpd = NULL;

bool flashOn = false;
unsigned long lastHeartbeat = 0;

// ------------------------------------------------------------------
//  Kamera
// ------------------------------------------------------------------
bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode    = CAMERA_GRAB_LATEST;

  if (psramFound()) {
    config.frame_size   = FRAMESIZE_VGA;   // bisa dinaikkan lewat /control
    config.jpeg_quality = 10;
    config.fb_count     = 2;
    config.fb_location  = CAMERA_FB_IN_PSRAM;
  } else {
    config.frame_size   = FRAMESIZE_QVGA;
    config.jpeg_quality = 12;
    config.fb_count     = 1;
    config.fb_location  = CAMERA_FB_IN_DRAM;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init gagal: 0x%x\n", err);
    return false;
  }
  return true;
}

// ------------------------------------------------------------------
//  Handler HTTP
// ------------------------------------------------------------------
static esp_err_t index_handler(httpd_req_t *req) {
  char html[512];
  snprintf(html, sizeof(html),
           "<html><body style='font-family:sans-serif'>"
           "<h2>%s (%s)</h2>"
           "<p><a href='/capture'>/capture</a> | <a href='/status'>/status</a> | "
           "<a href='http://%s:81/stream'>stream</a></p>"
           "<img src='http://%s:81/stream' style='max-width:100%%'>"
           "</body></html>",
           CAM_NAME, CAM_ID,
           WiFi.localIP().toString().c_str(), WiFi.localIP().toString().c_str());
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, html, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t capture_handler(httpd_req_t *req) {
  camera_fb_t *fb = esp_camera_fb_get();
  // Buang frame lama supaya foto benar-benar "sekarang"
  if (fb) { esp_camera_fb_return(fb); fb = esp_camera_fb_get(); }
  if (!fb) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Content-Disposition", "inline; filename=capture.jpg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "X-Cam-Id", CAM_ID);
  esp_err_t res = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return res;
}

static esp_err_t stream_handler(httpd_req_t *req) {
  char part_buf[64];
  esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  while (true) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) { res = ESP_FAIL; break; }

    size_t hlen = snprintf(part_buf, sizeof(part_buf), STREAM_PART, fb->len);
    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, part_buf, hlen);
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    if (res != ESP_OK) break;   // client putus
  }
  return res;
}

static String statusJson() {
  sensor_t *s = esp_camera_sensor_get();
  char buf[512];
  snprintf(buf, sizeof(buf),
           "{\"id\":\"%s\",\"name\":\"%s\",\"ip\":\"%s\",\"mac\":\"%s\","
           "\"rssi\":%d,\"uptime\":%lu,\"heap\":%u,\"psram\":%s,"
           "\"framesize\":%d,\"quality\":%d,\"brightness\":%d,\"contrast\":%d,"
           "\"saturation\":%d,\"vflip\":%d,\"hmirror\":%d,\"flash\":%d}",
           CAM_ID, CAM_NAME, WiFi.localIP().toString().c_str(), WiFi.macAddress().c_str(),
           WiFi.RSSI(), millis() / 1000, ESP.getFreeHeap(), psramFound() ? "true" : "false",
           s->status.framesize, s->status.quality, s->status.brightness, s->status.contrast,
           s->status.saturation, s->status.vflip, s->status.hmirror, flashOn ? 1 : 0);
  return String(buf);
}

static esp_err_t status_handler(httpd_req_t *req) {
  String json = statusJson();
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, json.c_str(), json.length());
}

static esp_err_t control_handler(httpd_req_t *req) {
  char query[128], var[32], val[16];
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "var", var, sizeof(var)) != ESP_OK ||
      httpd_query_key_value(query, "val", val, sizeof(val)) != ESP_OK) {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "butuh ?var=..&val=..");
    return ESP_FAIL;
  }

  int v = atoi(val);
  sensor_t *s = esp_camera_sensor_get();
  int res = 0;

  if      (!strcmp(var, "framesize"))  { if (s->pixformat == PIXFORMAT_JPEG) res = s->set_framesize(s, (framesize_t)v); }
  else if (!strcmp(var, "quality"))    res = s->set_quality(s, v);
  else if (!strcmp(var, "brightness")) res = s->set_brightness(s, v);
  else if (!strcmp(var, "contrast"))   res = s->set_contrast(s, v);
  else if (!strcmp(var, "saturation")) res = s->set_saturation(s, v);
  else if (!strcmp(var, "vflip"))      res = s->set_vflip(s, v);
  else if (!strcmp(var, "hmirror"))    res = s->set_hmirror(s, v);
  else if (!strcmp(var, "flash"))      { flashOn = v != 0; digitalWrite(FLASH_LED_PIN, flashOn ? HIGH : LOW); }
  else {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "var tidak dikenal");
    return ESP_FAIL;
  }

  if (res != 0) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  return status_handler(req);
}

void startServers() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  config.max_uri_handlers = 8;

  httpd_uri_t index_uri   = { "/",        HTTP_GET, index_handler,   NULL };
  httpd_uri_t capture_uri = { "/capture", HTTP_GET, capture_handler, NULL };
  httpd_uri_t status_uri  = { "/status",  HTTP_GET, status_handler,  NULL };
  httpd_uri_t control_uri = { "/control", HTTP_GET, control_handler, NULL };

  if (httpd_start(&api_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(api_httpd, &index_uri);
    httpd_register_uri_handler(api_httpd, &capture_uri);
    httpd_register_uri_handler(api_httpd, &status_uri);
    httpd_register_uri_handler(api_httpd, &control_uri);
  }

  // Stream di port terpisah supaya /capture tetap responsif saat streaming
  config.server_port = 81;
  config.ctrl_port  += 1;
  httpd_uri_t stream_uri = { "/stream", HTTP_GET, stream_handler, NULL };
  if (httpd_start(&stream_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &stream_uri);
  }
}

// ------------------------------------------------------------------
//  WiFi & heartbeat ke server pusat
// ------------------------------------------------------------------
void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // latensi stream lebih rendah

  if (strlen(STATIC_IP) > 0) {
    IPAddress ip, gw, mask;
    ip.fromString(STATIC_IP);
    gw.fromString(GATEWAY_IP);
    mask.fromString(SUBNET_MASK);
    WiFi.config(ip, gw, mask, gw);
  }

  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Menghubungkan WiFi");
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    if (millis() - start > 30000) {
      Serial.println("\nGagal konek WiFi, restart...");
      ESP.restart();
    }
  }
  Serial.printf("\nTerhubung! IP: %s\n", WiFi.localIP().toString().c_str());

  if (MDNS.begin(CAM_ID)) {             // bisa diakses via http://cam1.local
    MDNS.addService("http", "tcp", 80);
  }
}

void sendHeartbeat() {
  if (WiFi.status() != WL_CONNECTED) return;

  HTTPClient http;
  http.setTimeout(3000);
  http.begin(String(SERVER_URL) + "/api/register");
  http.addHeader("Content-Type", "application/json");
  int code = http.POST(statusJson());
  if (code <= 0) {
    Serial.printf("Heartbeat gagal: %s\n", http.errorToString(code).c_str());
  }
  http.end();
}

// ------------------------------------------------------------------
void setup() {
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);  // cegah reset brownout saat WiFi+kamera aktif
  Serial.begin(115200);
  Serial.println();

  pinMode(FLASH_LED_PIN, OUTPUT);
  digitalWrite(FLASH_LED_PIN, LOW);

  if (!initCamera()) {
    delay(3000);
    ESP.restart();
  }

  connectWiFi();
  startServers();
  sendHeartbeat();

  Serial.printf("Node %s siap: http://%s  stream: http://%s:81/stream\n",
                CAM_ID, WiFi.localIP().toString().c_str(), WiFi.localIP().toString().c_str());
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi putus, reconnect...");
    WiFi.reconnect();
    delay(5000);
    return;
  }

  if (millis() - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeat = millis();
    sendHeartbeat();
  }
  delay(100);
}
