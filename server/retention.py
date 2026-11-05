"""
Pembersihan otomatis foto lama di folder captures/ supaya penyimpanan tidak penuh.

Algoritma (dijalankan setiap selesai capture dan tiap 60 detik):
  1. Umur   : hapus foto yang lebih tua dari max_age_hours.
  2. Jumlah : tiap kamera hanya menyimpan max_per_cam foto terbaru.
  3. Ukuran : selama total ukuran > max_total_mb, hapus foto paling lama
              (dari kamera mana pun) sampai di bawah batas.
Setiap batas bernilai 0 berarti tidak dipakai. Foto terbaru tidak pernah
dihapus lebih dulu daripada foto yang lebih lama.
"""

import json
import os
import threading
import time
from dataclasses import asdict, dataclass

POLICY_FILE = "retention.json"


@dataclass
class Policy:
    max_age_hours: float = 72      # 3 hari
    max_per_cam: int = 300
    max_total_mb: float = 500

    @classmethod
    def from_dict(cls, d):
        p = cls()
        for k in ("max_age_hours", "max_per_cam", "max_total_mb"):
            if k in d:
                v = float(d[k])
                if v < 0:
                    raise ValueError(f"{k} tidak boleh negatif")
                setattr(p, k, int(v) if k == "max_per_cam" else v)
        return p


@dataclass
class Photo:
    path: str       # path lengkap
    cam: str
    mtime: float
    size: int


def scan(capture_dir):
    """Daftar semua foto .jpg di captures/<cam>/."""
    photos = []
    for cam in os.listdir(capture_dir):
        folder = os.path.join(capture_dir, cam)
        if not os.path.isdir(folder):
            continue
        for name in os.listdir(folder):
            if not name.lower().endswith(".jpg"):
                continue
            full = os.path.join(folder, name)
            try:
                st = os.stat(full)
            except FileNotFoundError:
                continue
            photos.append(Photo(full, cam, st.st_mtime, st.st_size))
    return photos


def plan_cleanup(photos, policy, now=None):
    """Tentukan foto mana yang dihapus. Fungsi murni: tidak menyentuh disk."""
    now = time.time() if now is None else now
    delete = set()

    # 1. Umur
    if policy.max_age_hours > 0:
        cutoff = now - policy.max_age_hours * 3600
        delete.update(p.path for p in photos if p.mtime < cutoff)

    # 2. Jumlah per kamera: simpan N terbaru
    if policy.max_per_cam > 0:
        by_cam = {}
        for p in photos:
            if p.path not in delete:
                by_cam.setdefault(p.cam, []).append(p)
        for items in by_cam.values():
            items.sort(key=lambda p: p.mtime, reverse=True)
            delete.update(p.path for p in items[policy.max_per_cam:])

    # 3. Total ukuran: buang yang paling lama dulu
    if policy.max_total_mb > 0:
        limit = policy.max_total_mb * 1024 * 1024
        remaining = sorted((p for p in photos if p.path not in delete), key=lambda p: p.mtime)
        total = sum(p.size for p in remaining)
        for p in remaining:
            if total <= limit:
                break
            delete.add(p.path)
            total -= p.size

    return [p for p in photos if p.path in delete]


class Retention:
    """Menyimpan kebijakan (di captures/retention.json) dan menjalankan pembersihan."""

    def __init__(self, capture_dir, defaults=None):
        self.capture_dir = capture_dir
        self.policy = defaults or Policy()
        self.last = {"at": None, "deleted": 0, "freed_bytes": 0}
        self._lock = threading.Lock()
        try:
            with open(os.path.join(capture_dir, POLICY_FILE)) as f:
                self.policy = Policy.from_dict(json.load(f))
        except (OSError, ValueError):
            pass

    def set_policy(self, data):
        policy = Policy.from_dict({**asdict(self.policy), **data})
        with self._lock:
            self.policy = policy
            with open(os.path.join(self.capture_dir, POLICY_FILE), "w") as f:
                json.dump(asdict(policy), f)
        return policy

    def run(self):
        """Hapus foto sesuai kebijakan. Aman dipanggil dari banyak thread."""
        with self._lock:
            victims = plan_cleanup(scan(self.capture_dir), self.policy)
            freed = 0
            deleted = 0
            for p in victims:
                try:
                    os.remove(p.path)
                    freed += p.size
                    deleted += 1
                except FileNotFoundError:
                    pass
            self.last = {"at": time.time(), "deleted": deleted, "freed_bytes": freed}
            return self.last

    def stats(self):
        photos = scan(self.capture_dir)
        per_cam = {}
        for p in photos:
            c = per_cam.setdefault(p.cam, {"files": 0, "bytes": 0})
            c["files"] += 1
            c["bytes"] += p.size
        return {
            "policy": asdict(self.policy),
            "files": len(photos),
            "bytes": sum(p.size for p in photos),
            "per_cam": per_cam,
            "last_cleanup": self.last,
        }
