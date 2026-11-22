# -*- coding: utf-8 -*-
"""
1.4.5 C (BYTE_ESLES, sahibin kararı 22.11): ByteTrack'in eşleme parçaları —
PyTorch'suz, yeni pip bağımlılığı olmadan.

Kaynak: Ultralytics 8.4.210 (AGPL-3.0; köprü YOLO11s'ten beri AGPL —
sahibin kararı 12.11 / 22.11):
  · `trackers/utils/kalman_filter.py` KalmanFilterXYAH — burada kare arası
    DÜZENSİZ (dt saniye: meşgulken ~9 kare/sn, sakinken 2 sn arayla), hız
    saniye başına piksel;
  · `utils/ops.py` _linear_sum_assignment_numpy (Jonker-Volgenant, Crouse
    2016) ve `trackers/utils/matching.py` linear_assignment'ın
    `np.minimum(maliyet, eşik)` sarmalı (hep sonsuz satır patlamasın).

Yalnızca araç izcisi kullanır (takip.Takipci, BYTE_ESLES=1).
"""
from __future__ import annotations

import numpy as np

# Kalman gürültüsü kutu yüksekliğiyle ölçeklenir (Ultralytics'in ağırlıkları
# kare başına; burada REF_SN'lik "kare" başına, dt ile ölçeklenir).
REF_SN = 0.2                  # köprünün model karesi ~5/sn
_W_KONUM = 1.0 / 20
_W_HIZ = 1.0 / 160


def xyah(k) -> np.ndarray:
    """(x1, y1, x2, y2) → (merkez x, merkez y, en / boy, boy)."""
    x1, y1, x2, y2 = (float(v) for v in k[:4])
    boy = max(y2 - y1, 1e-6)
    return np.array([(x1 + x2) / 2, (y1 + y2) / 2, (x2 - x1) / boy, boy])


def xyxy(x) -> tuple[float, float, float, float]:
    """(merkez x, merkez y, en / boy, boy) → (x1, y1, x2, y2)."""
    cx, cy, a, h = (float(v) for v in x[:4])
    w = a * h
    return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)


class Kalman:
    """
    Bir izin kutusu için sabit hızlı Kalman süzgeci (durum: x, y, a, h ve
    hızları — hız SANİYE başına). `guncelle(kutu, dt)`: dt sn sonra ölçülen
    kutu; `tahmin(dt)`: dt sn sonrası (durumu değiştirmez).
    """

    def __init__(self, kutu):
        olcu = xyah(kutu)
        h = olcu[3]
        self.ort = np.r_[olcu, np.zeros(4)]
        std = [2 * _W_KONUM * h, 2 * _W_KONUM * h, 1e-2, 2 * _W_KONUM * h,
               10 * _W_HIZ * h / REF_SN, 10 * _W_HIZ * h / REF_SN, 1e-5 / REF_SN,
               10 * _W_HIZ * h / REF_SN]
        self.kov = np.diag(np.square(std))

    @staticmethod
    def _gecis(dt: float) -> np.ndarray:
        f = np.eye(8)
        for i in range(4):
            f[i, 4 + i] = dt
        return f

    def _ileri(self, dt: float) -> tuple[np.ndarray, np.ndarray]:
        dt = max(0.0, float(dt))
        h = self.ort[3]
        std = [_W_KONUM * h, _W_KONUM * h, 1e-2, _W_KONUM * h,
               _W_HIZ * h / REF_SN, _W_HIZ * h / REF_SN, 1e-5 / REF_SN, _W_HIZ * h / REF_SN]
        q = np.diag(np.square(std)) * (dt / REF_SN)
        f = self._gecis(dt)
        return f @ self.ort, f @ self.kov @ f.T + q

    def tahmin(self, dt: float, en_cok: float | None = None) -> tuple[float, float, float, float]:
        if en_cok is not None:
            dt = min(dt, en_cok)
        ort, _ = self._ileri(dt)
        return xyxy(ort)

    def kutu(self) -> tuple[float, float, float, float]:
        return xyxy(self.ort)

    def guncelle(self, kutu, dt: float) -> None:
        ort, kov = self._ileri(dt)
        h = ort[3]
        r = np.diag(np.square([_W_KONUM * h, _W_KONUM * h, 1e-1, _W_KONUM * h]))
        s = kov[:4, :4] + r
        kazanc = np.linalg.solve(s, kov[:, :4].T).T
        self.ort = ort + (xyah(kutu) - ort[:4]) @ kazanc.T
        self.kov = kov - kazanc @ s @ kazanc.T


def _jv(a: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Dikdörtgen en küçük toplamlı bire bir atama (Ultralytics'in NumPy yedeği)."""
    n, m = a.shape
    if n == 0 or m == 0:
        return np.empty(0, dtype=np.intp), np.empty(0, dtype=np.intp)
    devrik = n > m
    if devrik:
        a, n, m = a.T, m, n
    u, v = np.zeros(n + 1), np.zeros(m + 1)
    p, yol = np.zeros(m + 1, np.intp), np.zeros(m + 1, np.intp)
    for i in range(1, n + 1):
        p[0], j0 = i, 0
        minv, kullanildi = np.full(m + 1, np.inf), np.zeros(m + 1, bool)
        while True:
            kullanildi[j0] = True
            i0 = p[j0]
            cur = a[i0 - 1] - u[i0] - v[1:]
            iyi = (~kullanildi[1:]) & (cur < minv[1:])
            minv[1:][iyi], yol[1:][iyi] = cur[iyi], j0
            adaylar = np.where(kullanildi[1:], np.inf, minv[1:])
            j1 = int(np.argmin(adaylar)) + 1
            delta = adaylar[j1 - 1]
            if delta == np.inf:
                raise ValueError("maliyet matrisi çözümsüz")
            u[p[kullanildi]] += delta
            v[kullanildi] -= delta
            minv[~kullanildi] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            p[j0] = p[yol[j0]]
            j0 = yol[j0]
    sutunlar = np.nonzero(p[1:])[0]
    satirlar = p[1:][sutunlar] - 1
    s, k = (sutunlar, satirlar) if devrik else (satirlar, sutunlar)
    sira = np.argsort(s, kind="stable")
    return s[sira].astype(np.intp), k[sira].astype(np.intp)


def atama(maliyet, esik: float) -> tuple[list[tuple[int, int]], list[int], list[int]]:
    """
    En iyi bire bir eşleme: (eşleşen (satır, sütun) çiftleri, eşleşmeyen
    satırlar, eşleşmeyen sütunlar). Maliyeti `esik`'i aşan çift eşleşmez;
    sonsuz maliyet "asla" demektir (hep sonsuz satır da patlamaz).
    """
    m = np.asarray(maliyet, dtype=np.float64)
    n, k = m.shape
    if m.size == 0:
        return [], list(range(n)), list(range(k))
    satirlar, sutunlar = _jv(np.minimum(m, esik))
    ciftler = [(int(i), int(j)) for i, j in zip(satirlar, sutunlar) if m[i, j] <= esik]
    es_s, es_k = {i for i, _ in ciftler}, {j for _, j in ciftler}
    return (ciftler, [i for i in range(n) if i not in es_s],
            [j for j in range(k) if j not in es_k])
