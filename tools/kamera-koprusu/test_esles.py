# -*- coding: utf-8 -*-
"""
1.4.5 C (BYTE_ESLES) — esles.py birim testleri.

    python test_esles.py

esles.py ByteTrack'in (Ultralytics 8.4.210) iki parçasının PyTorch'suz
kopyasıdır: kutu hareketi için Kalman süzgeci (burada kare arası düzensiz:
dt saniye) ve en iyi bire bir atama (Jonker-Volgenant, saf NumPy). Buradaki
bir hata, izcinin aracı yanlış kutuyla sürmesi — ikinci iz, ikiz kart — demektir.
"""
from __future__ import annotations

import itertools
import os
import random
import sys

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import esles  # noqa: E402

INF = float("inf")


def _kaba_en_iyi(m: np.ndarray, esik: float) -> float:
    """
    Kaba kuvvet: eşiği geçmeyen çiftlerle en iyi toplam. Eşleşmeyen her satır
    ve her sütun esik / 2 (lap.lapjv'nin cost_limit'i, Ultralytics'in
    `np.minimum(maliyet, esik)` sarmalı da aynısını çözer).
    """
    n, k = m.shape
    en_iyi = INF
    for r in range(0, min(n, k) + 1):
        for satirlar in itertools.combinations(range(n), r):
            for sutunlar in itertools.permutations(range(k), r):
                if any(m[i, j] > esik for i, j in zip(satirlar, sutunlar)):
                    continue
                toplam = sum(m[i, j] for i, j in zip(satirlar, sutunlar))
                toplam += esik / 2 * ((n - r) + (k - r))
                en_iyi = min(en_iyi, toplam)
    return en_iyi


def _toplam(m: np.ndarray, esik: float, ciftler, kalan_s, kalan_k) -> float:
    return sum(m[i, j] for i, j in ciftler) + esik / 2 * (len(kalan_s) + len(kalan_k))


def test_atama_kaba_kuvvetle_ayni():
    rnd = random.Random(7)
    for _ in range(300):
        n, k = rnd.randint(1, 4), rnd.randint(1, 4)
        m = np.array([[rnd.choice([rnd.random(), rnd.random(), INF]) for _ in range(k)]
                      for _ in range(n)])
        esik = rnd.choice([0.3, 0.6, 0.9])
        ciftler, kalan_s, kalan_k = esles.atama(m, esik)
        assert all(m[i, j] <= esik for i, j in ciftler), (m, esik, ciftler)
        assert len({i for i, _ in ciftler}) == len(ciftler) == len({j for _, j in ciftler})
        assert sorted([i for i, _ in ciftler] + list(kalan_s)) == list(range(n))
        assert sorted([j for _, j in ciftler] + list(kalan_k)) == list(range(k))
        beklenen = _kaba_en_iyi(m, esik)
        assert abs(_toplam(m, esik, ciftler, kalan_s, kalan_k) - beklenen) < 1e-9, \
            (m, esik, ciftler)


def test_atama_acgozlunun_kacirdigini_bulur():
    # İz A kutu 0'la 0.6, kutu 1'le 0.5 örtüşür; iz B yalnızca kutu 0'la 0.55.
    # Açgözlü: A↔0, B boşta (ikinci iz doğar). En iyi: A↔1, B↔0.
    m = 1.0 - np.array([[0.6, 0.5], [0.55, 0.0]])
    ciftler, kalan_s, kalan_k = esles.atama(m, 0.7)
    assert sorted(ciftler) == [(0, 1), (1, 0)], ciftler
    assert not kalan_s and not kalan_k


def test_atama_hep_sonsuz_satir_patlamaz():
    m = np.array([[INF, INF], [0.2, INF]])
    ciftler, kalan_s, kalan_k = esles.atama(m, 0.7)
    assert ciftler == [(1, 0)], ciftler
    assert list(kalan_s) == [0] and list(kalan_k) == [1]
    ciftler, kalan_s, kalan_k = esles.atama(np.full((2, 3), INF), 0.7)
    assert ciftler == [] and list(kalan_s) == [0, 1] and list(kalan_k) == [0, 1, 2]


def test_atama_bos():
    for sekil in ((0, 0), (0, 3), (2, 0)):
        ciftler, kalan_s, kalan_k = esles.atama(np.zeros(sekil), 0.5)
        assert ciftler == [] and list(kalan_s) == list(range(sekil[0])) \
            and list(kalan_k) == list(range(sekil[1]))


def test_kutu_donusumu():
    k = (100.0, 50.0, 300.0, 150.0)
    x = esles.xyah(k)
    assert np.allclose(x, [200.0, 100.0, 2.0, 100.0]), x
    assert np.allclose(esles.xyxy(x), k)


def _yuru(adimlar, hiz=(300.0, -60.0), kutu=(100.0, 300.0, 400.0, 500.0)):
    """Sabit hızla (px/sn) yürüyen kutuyu düzensiz aralıklarla ölçer."""
    kf, t = esles.Kalman(kutu), 0.0
    for dt in adimlar:
        t += dt
        d = (hiz[0] * t, hiz[1] * t)
        kf.guncelle((kutu[0] + d[0], kutu[1] + d[1], kutu[2] + d[0], kutu[3] + d[1]), dt)
    return kf, t


def test_kalman_hiz_saniye_basina():
    # Model kareleri düzensiz gelir (meşgulken ~9/sn, sakinken 2 sn arayla).
    # Hız saniye başına ölçülür: aynı araç hangi aralıkla ölçülürse ölçülsün
    # tahmini aynı yere düşer.
    for adimlar in ([0.11] * 30, [0.5] * 12, [0.11, 0.5, 0.2, 0.9, 0.11, 0.3] * 4):
        kf, t = _yuru(adimlar)
        k = kf.tahmin(0.5)
        beklenen = (100 + 300 * (t + 0.5), 300 - 60 * (t + 0.5))
        assert abs(k[0] - beklenen[0]) < 12 and abs(k[1] - beklenen[1]) < 12, (adimlar[:3], k,
                                                                             beklenen)
        assert abs((k[2] - k[0]) - 300) < 3 and abs((k[3] - k[1]) - 200) < 3, k


def test_kalman_tahmin_durumu_degistirmez_ve_sinirli():
    kf, _ = _yuru([0.2] * 15)
    once = kf.tahmin(0.4)
    assert np.allclose(kf.tahmin(0.4), once)                # yan etkisiz
    assert np.allclose(kf.tahmin(0.0), kf.kutu())
    # Uzun boşlukta (köprüde TAHMIN_SN) en çok `en_cok` saniye ileri.
    assert np.allclose(kf.tahmin(30.0, en_cok=1.0), kf.tahmin(1.0))


def test_kalman_yeni_olcume_yaklasir():
    kf = esles.Kalman((0.0, 0.0, 100.0, 100.0))
    kf.guncelle((10.0, 0.0, 110.0, 100.0), 0.2)
    k = kf.kutu()
    assert 0.0 < k[0] <= 10.0 + 1e-6, k                     # ölçüye doğru, ötesine değil


if __name__ == "__main__":
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    basarisiz: list[str] = []
    for t in testler:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            basarisiz.append(t.__name__)
            print(f"  FAIL  {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti")
    sys.exit(1 if basarisiz else 0)
