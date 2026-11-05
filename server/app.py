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
    python app.py            # mode router: buka http://<ip-komputer>:5000
    python app.py --hotspot  # mode offline (laptop connect ke WiFi "MeshLokal-cam1")
"""

import json
import os
import sys
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

# Mode hotspot ESP (USE_ESP_HOTSPOT 1 di config.h): IP kamera sudah tetap.
#   python app.py --hotspot
HOTSPOT_CAMS = "cam1=192.168.4.1,cam2=192.168.4.202,cam3=192.168.4.203"
if "--hotspot" in sys.argv and not STATIC_CAMS:
    STATIC_CAMS = HOTSPOT_CAMS

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
# MeshLokal: dashboard "basecamp" (SOS & orang aktif dari aplikasi HP)
# ----------------------------------------------------------------------
# Server menarik pesan dari node lewat /mesh/pull. Chat terenkripsi tidak bisa
# dibaca di sini; yang ditampilkan hanya SOS (sengaja terbuka) dan pengumuman
# "hello" (nama, jumlah hop, lokasi bila user mengizinkan).
# Catatan: tanda tangan pesan tidak diverifikasi server ini (verifikasi ada di HP).
mesh_lock = threading.Lock()
mesh_cursor = {}              # cam_id -> (boot, seq)
mesh_seen = set()
mesh_sos = {}                 # id -> dict
mesh_people = {}              # pub -> dict
mesh_nodes = {}               # cam_id -> /mesh/info
mesh_stats = {"messages": 0, "chat": 0}
TTL_START = {"hello": 6, "sos": 15}


def _mesh_ingest(msg, via):
    mid = msg.get("id")
    if not isinstance(mid, str) or mid in mesh_seen:
        return
    mesh_seen.add(mid)
    mesh_stats["messages"] += 1
    t = msg.get("t")
    hops = max(1, TTL_START.get(t, 8) - int(msg.get("ttl", 0)) + 1)
    try:
        body = json.loads(msg.get("body", "")) if t in ("hello", "sos") else {}
    except ValueError:
        body = {}
    if not isinstance(body, dict):
        body = {}
    if t == "sos":
        mesh_sos[mid] = {
            "id": mid, "from": msg.get("from"), "name": str(body.get("n", "?"))[:32],
            "lat": body.get("lat"), "lon": body.get("lon"), "acc": body.get("acc"),
            "msg": str(body.get("msg", ""))[:200], "ts": msg.get("ts"), "hops": hops,
            "via": via, "received": time.time(),
        }
    elif t == "hello":
        loc = body.get("loc")
        prev = mesh_people.get(msg.get("from"), {})
        mesh_people[msg.get("from")] = {
            "pub": msg.get("from"), "name": str(body.get("n", "?"))[:32], "hops": hops, "via": via,
            "last_seen": time.time(),
            "lat": loc[0] if isinstance(loc, list) and len(loc) >= 2 else prev.get("lat"),
            "lon": loc[1] if isinstance(loc, list) and len(loc) >= 2 else prev.get("lon"),
        }
    elif t in ("dm", "chan"):
        mesh_stats["chat"] += 1


def _mesh_poll_loop():
    while True:
        for cam in [c for c in _cam_snapshot() if c["online"]]:
            boot, seq = mesh_cursor.get(cam["id"], (-1, 0))
            try:
                r = requests.get(f"http://{cam['ip']}/mesh/pull", params={"boot": boot, "since": seq}, timeout=4)
                data = r.json()
                info = requests.get(f"http://{cam['ip']}/mesh/info", timeout=3).json()
            except (requests.RequestException, ValueError):
                continue  # firmware lama tanpa mesh, atau node sibuk
            with mesh_lock:
                if data.get("boot") != boot:
                    seq = 0
                mesh_cursor[cam["id"]] = (data.get("boot"), data.get("seq", seq))
                mesh_nodes[cam["id"]] = info
                for m in data.get("msgs", []):
                    if isinstance(m, dict):
                        _mesh_ingest(m, cam["id"])
        time.sleep(3)


@app.get("/api/mesh")
def api_mesh():
    now = time.time()
    with mesh_lock:
        people = sorted(mesh_people.values(), key=lambda p: -p["last_seen"])
        return jsonify(
            sos=sorted(mesh_sos.values(), key=lambda s: -(s["ts"] or 0)),
            people=[dict(p, active=now - p["last_seen"] < 180) for p in people],
            nodes=list(mesh_nodes.values()),
            stats=mesh_stats,
        )


# ----------------------------------------------------------------------
@app.get("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    _load_static_cams()
    threading.Thread(target=_poll_static_cams, daemon=True).start()
    threading.Thread(target=_scheduler_loop, daemon=True).start()
    threading.Thread(target=_mesh_poll_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), threaded=True)
