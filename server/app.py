"""
TRIPLE-ESP-CAM - server pusat (koordinator) untuk beberapa node ESP32-CAM.

Fungsi:
  * Registry node: tiap ESP32-CAM mengirim heartbeat ke /api/register
  * Dashboard web: live stream semua kamera, kontrol setting, flash
  * Capture satu kamera atau SEMUA kamera secara paralel (bersamaan)
  * Galeri foto tersimpan di folder captures/<cam_id>/
  * Auto-capture terjadwal (interval detik)

Jalankan:
    pip install -r requirements.txt
    python app.py            # buka http://<ip-komputer>:5000
"""

import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

import requests
from flask import Flask, Response, abort, jsonify, render_template, request, send_from_directory

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CAPTURE_DIR = os.environ.get("CAPTURE_DIR", os.path.join(BASE_DIR, "captures"))
OFFLINE_AFTER_S = 30          # node dianggap offline jika tidak heartbeat selama ini
CAPTURE_TIMEOUT_S = 10

# Kamera bisa juga didaftarkan manual (tanpa heartbeat) lewat env, contoh:
#   STATIC_CAMS="cam1=192.168.1.51,cam2=192.168.1.52,cam3=192.168.1.53"
STATIC_CAMS = os.environ.get("STATIC_CAMS", "")

app = Flask(__name__)
os.makedirs(CAPTURE_DIR, exist_ok=True)

cameras = {}                  # id -> dict info node
cameras_lock = threading.Lock()
executor = ThreadPoolExecutor(max_workers=8)

schedule = {"enabled": False, "interval": 60, "last_run": None}
schedule_lock = threading.Lock()


# ----------------------------------------------------------------------
# Registry
# ----------------------------------------------------------------------
def _load_static_cams():
    for entry in filter(None, (e.strip() for e in STATIC_CAMS.split(","))):
        cam_id, _, ip = entry.partition("=")
        cameras[cam_id] = {"id": cam_id, "name": cam_id, "ip": ip, "static": True, "last_seen": 0}


def _is_online(cam):
    return time.time() - cam.get("last_seen", 0) < OFFLINE_AFTER_S


def _get_cam(cam_id):
    with cameras_lock:
        cam = cameras.get(cam_id)
        return dict(cam) if cam else None


def _cam_snapshot():
    with cameras_lock:
        cams = [dict(c, online=_is_online(c)) for c in cameras.values()]
    return sorted(cams, key=lambda c: c["id"])


@app.post("/api/register")
def register():
    data = request.get_json(force=True, silent=True) or {}
    cam_id = data.get("id")
    if not cam_id:
        return jsonify(error="id wajib"), 400
    data["ip"] = data.get("ip") or request.remote_addr
    data["last_seen"] = time.time()
    with cameras_lock:
        cameras.setdefault(cam_id, {}).update(data)
    return jsonify(ok=True)


@app.get("/api/cameras")
def list_cameras():
    return jsonify(_cam_snapshot())


@app.delete("/api/cameras/<cam_id>")
def remove_camera(cam_id):
    with cameras_lock:
        cameras.pop(cam_id, None)
    return jsonify(ok=True)


def _poll_static_cams():
    """Untuk kamera statis (tanpa heartbeat), cek /status secara berkala."""
    while True:
        with cameras_lock:
            static = [c for c in cameras.values() if c.get("static")]
        for cam in static:
            try:
                r = requests.get(f"http://{cam['ip']}/status", timeout=3)
                info = r.json()
                info["last_seen"] = time.time()
                info["static"] = True
                with cameras_lock:
                    cameras[cam["id"]].update(info)
            except (requests.RequestException, ValueError):
                pass
        time.sleep(10)


# ----------------------------------------------------------------------
# Capture
# ----------------------------------------------------------------------
def capture_one(cam_id, batch=None):
    cam = _get_cam(cam_id)
    if not cam:
        return {"id": cam_id, "ok": False, "error": "kamera tidak terdaftar"}
    try:
        r = requests.get(f"http://{cam['ip']}/capture", timeout=CAPTURE_TIMEOUT_S)
        r.raise_for_status()
    except requests.RequestException as e:
        return {"id": cam_id, "ok": False, "error": str(e)}

    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
    filename = f"{batch or ts}_{cam_id}.jpg"
    folder = os.path.join(CAPTURE_DIR, cam_id)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, filename), "wb") as f:
        f.write(r.content)
    return {"id": cam_id, "ok": True, "file": f"{cam_id}/{filename}", "size": len(r.content)}


def capture_all():
    """Ambil foto dari semua kamera online secara paralel (hampir bersamaan)."""
    batch = datetime.now().strftime("%Y%m%d_%H%M%S")
    ids = [c["id"] for c in _cam_snapshot() if c["online"]]
    return list(executor.map(lambda i: capture_one(i, batch), ids))


@app.post("/api/capture/<cam_id>")
def api_capture(cam_id):
    result = capture_one(cam_id)
    return jsonify(result), (200 if result["ok"] else 502)


@app.post("/api/capture-all")
def api_capture_all():
    return jsonify(capture_all())


@app.get("/api/snapshot/<cam_id>")
def api_snapshot(cam_id):
    """Ambil foto tanpa menyimpan (preview)."""
    cam = _get_cam(cam_id) or abort(404)
    try:
        r = requests.get(f"http://{cam['ip']}/capture", timeout=CAPTURE_TIMEOUT_S)
        r.raise_for_status()
    except requests.RequestException as e:
        return jsonify(error=str(e)), 502
    return Response(r.content, mimetype="image/jpeg")


# ----------------------------------------------------------------------
# Stream (proxy) & kontrol
# ----------------------------------------------------------------------
@app.get("/api/stream/<cam_id>")
def api_stream(cam_id):
    """Proxy MJPEG supaya browser cukup mengakses server (berguna jika
    browser tidak satu jaringan dengan kamera)."""
    cam = _get_cam(cam_id) or abort(404)
    try:
        upstream = requests.get(f"http://{cam['ip']}:81/stream", stream=True, timeout=(5, 30))
    except requests.RequestException as e:
        return jsonify(error=str(e)), 502

    def generate():
        try:
            for chunk in upstream.iter_content(chunk_size=4096):
                yield chunk
        except requests.RequestException:
            pass
        finally:
            upstream.close()

    return Response(generate(), content_type=upstream.headers.get("Content-Type"))


@app.post("/api/control/<cam_id>")
def api_control(cam_id):
    cam = _get_cam(cam_id) or abort(404)
    data = request.get_json(force=True, silent=True) or {}
    try:
        r = requests.get(
            f"http://{cam['ip']}/control",
            params={"var": data.get("var"), "val": data.get("val")},
            timeout=5,
        )
        r.raise_for_status()
        info = r.json()
    except (requests.RequestException, ValueError) as e:
        return jsonify(error=str(e)), 502
    with cameras_lock:
        if cam_id in cameras:
            cameras[cam_id].update(info)
    return jsonify(info)


@app.post("/api/control-all")
def api_control_all():
    data = request.get_json(force=True, silent=True) or {}
    params = {"var": data.get("var"), "val": data.get("val")}

    def send(cam):
        try:
            requests.get(f"http://{cam['ip']}/control", params=params, timeout=5).raise_for_status()
            return {"id": cam["id"], "ok": True}
        except requests.RequestException as e:
            return {"id": cam["id"], "ok": False, "error": str(e)}

    return jsonify(list(executor.map(send, [c for c in _cam_snapshot() if c["online"]])))


# ----------------------------------------------------------------------
# Galeri
# ----------------------------------------------------------------------
@app.get("/api/captures")
def list_captures():
    limit = request.args.get("limit", 60, type=int)
    files = []
    for root, _, names in os.walk(CAPTURE_DIR):
        for n in names:
            if n.lower().endswith(".jpg"):
                full = os.path.join(root, n)
                rel = os.path.relpath(full, CAPTURE_DIR).replace(os.sep, "/")
                files.append({"file": rel, "cam": rel.split("/")[0], "mtime": os.path.getmtime(full)})
    files.sort(key=lambda f: f["mtime"], reverse=True)
    return jsonify(files[:limit])


@app.get("/captures/<path:filename>")
def get_capture(filename):
    return send_from_directory(CAPTURE_DIR, filename)


@app.delete("/api/captures/<path:filename>")
def delete_capture(filename):
    full = os.path.realpath(os.path.join(CAPTURE_DIR, filename))
    if not full.startswith(os.path.realpath(CAPTURE_DIR) + os.sep) or not os.path.isfile(full):
        abort(404)
    os.remove(full)
    return jsonify(ok=True)


# ----------------------------------------------------------------------
# Auto-capture terjadwal
# ----------------------------------------------------------------------
@app.route("/api/schedule", methods=["GET", "POST"])
def api_schedule():
    if request.method == "POST":
        data = request.get_json(force=True, silent=True) or {}
        with schedule_lock:
            if "enabled" in data:
                schedule["enabled"] = bool(data["enabled"])
            if "interval" in data:
                schedule["interval"] = max(5, int(data["interval"]))
    with schedule_lock:
        return jsonify(schedule)


def _scheduler_loop():
    while True:
        with schedule_lock:
            enabled, interval, last = schedule["enabled"], schedule["interval"], schedule["last_run"]
        if enabled and (last is None or time.time() - last >= interval):
            with schedule_lock:
                schedule["last_run"] = time.time()
            capture_all()
        time.sleep(1)


# ----------------------------------------------------------------------
@app.get("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    _load_static_cams()
    threading.Thread(target=_poll_static_cams, daemon=True).start()
    threading.Thread(target=_scheduler_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), threaded=True)
