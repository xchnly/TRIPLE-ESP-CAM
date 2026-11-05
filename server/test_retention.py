"""Uji algoritma pembersihan foto.  Jalankan:  python -m unittest test_retention"""

import os
import tempfile
import time
import unittest

from retention import Photo, Policy, Retention, plan_cleanup

NOW = 1_000_000.0
MB = 1024 * 1024


def photo(cam, age_h, size=100_000, name=None):
    return Photo(f"/x/{cam}/{name or f'{cam}_{age_h}'}.jpg", cam, NOW - age_h * 3600, size)


def names(photos):
    return sorted(os.path.basename(p.path) for p in photos)


class PlanCleanupTest(unittest.TestCase):
    def test_umur(self):
        photos = [photo("cam1", 1), photo("cam1", 50), photo("cam2", 80)]
        out = plan_cleanup(photos, Policy(max_age_hours=48, max_per_cam=0, max_total_mb=0), NOW)
        self.assertEqual(names(out), ["cam1_50.jpg", "cam2_80.jpg"])

    def test_jumlah_per_kamera_simpan_yang_terbaru(self):
        photos = [photo("cam1", h) for h in (5, 1, 3, 2, 4)] + [photo("cam2", 9)]
        out = plan_cleanup(photos, Policy(max_age_hours=0, max_per_cam=2, max_total_mb=0), NOW)
        self.assertEqual(names(out), ["cam1_3.jpg", "cam1_4.jpg", "cam1_5.jpg"])

    def test_total_ukuran_buang_paling_lama_dulu(self):
        photos = [photo("cam1", h, size=1 * MB) for h in (1, 2, 3)] + [photo("cam2", 4, size=1 * MB)]
        out = plan_cleanup(photos, Policy(max_age_hours=0, max_per_cam=0, max_total_mb=2), NOW)
        self.assertEqual(names(out), ["cam1_3.jpg", "cam2_4.jpg"])

    def test_semua_batas_bersama(self):
        photos = [photo("cam1", h, size=1 * MB) for h in (1, 2, 3, 100)]
        out = plan_cleanup(photos, Policy(max_age_hours=72, max_per_cam=2, max_total_mb=1), NOW)
        # 100 jam: terlalu tua; 3 jam: lebih dari 2 per kamera; 2 jam: melebihi 1 MB
        self.assertEqual(names(out), ["cam1_100.jpg", "cam1_2.jpg", "cam1_3.jpg"])

    def test_batas_nol_tidak_menghapus_apa_pun(self):
        photos = [photo("cam1", 1000, size=900 * MB)]
        self.assertEqual(plan_cleanup(photos, Policy(0, 0, 0), NOW), [])

    def test_policy_menolak_nilai_negatif(self):
        with self.assertRaises(ValueError):
            Policy.from_dict({"max_per_cam": -1})


class RetentionDiskTest(unittest.TestCase):
    def test_hapus_file_sungguhan_dan_simpan_kebijakan(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "cam1"))
            now = time.time()
            for i in range(5):
                path = os.path.join(d, "cam1", f"{i}.jpg")
                with open(path, "wb") as f:
                    f.write(b"x" * 1000)
                os.utime(path, (now - i * 60, now - i * 60))  # 0.jpg paling baru
            r = Retention(d)
            r.set_policy({"max_per_cam": 2})
            res = r.run()
            self.assertEqual(res["deleted"], 3)
            self.assertEqual(res["freed_bytes"], 3000)
            self.assertEqual(sorted(os.listdir(os.path.join(d, "cam1"))), ["0.jpg", "1.jpg"])
            # Kebijakan tersimpan dan dibaca lagi setelah restart
            self.assertEqual(Retention(d).policy.max_per_cam, 2)
            self.assertEqual(r.stats()["files"], 2)


if __name__ == "__main__":
    unittest.main()
