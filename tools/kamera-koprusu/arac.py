# -*- coding: utf-8 -*-
"""
Araç bulucu (köprü 1.3.1): kırpıntıda bir ARAÇ var mı?

Neden: 1.3.0'ın ilk günü (2026-11-07) kameranın önünde duran iki kişi
"Çözülmemiş kayıt" oldu. 1.3.0'ın tek modeli PLAKA bulur; "bu bir araç mı"
sorusunu hareketin büyüklüğü cevaplıyordu ve yakında duran insan araç
kadar büyük. 1.3.1 her karede bu modeli de çalıştırır; karar (okuma.py)
plakası görülmeyen geçişi ancak araç görüldüyse personele bırakır.

Model: YOLOX-tiny (Megvii, Apache-2.0), resmî 0.1.1rc0 ONNX dosyası, COCO'nun
80 sınıfı. Faz 0 (2026-11-07, otoparkın 180 gerçek kamera fotoğrafı):
gerçek araçlar 0.40-0.94, insanlar en çok 0.27; YOLOX-nano yakından ve
yukarıdan görülen araçları kaçırdı (0.01-0.12), reddedildi. Bu bilgisayarda
kare başına ~55 ms (plaka bulucu ~84 ms). Sahibin kararı: atlama yok, HER
kare.

Girdi BİÇİMİ Faz 0'da ölçülerek seçildi: BGR, 0-255, normalizesiz, sol üste
yerleştirilmiş, 114 dolgu (güncel YOLOX). Eski "legacy" biçim (RGB + ImageNet
ortalama/sapma) aynı dosyada HİÇ araç bulmuyordu — hata vermeden. Öz sınama
(gerçek bir resimde aracı bulmalı) ve test_arac bu seçimi kilitler.

onnxruntime burada içe aktarılmaz: telemetrisi kapalı tek yol plaka._ort_yukle.
"""
from __future__ import annotations

import os
from typing import NamedTuple

import cv2
import numpy as np

import plaka


class AracKutu(NamedTuple):
    """Kırpıntı pikselinde bir araç kutusu ve puanı (1.3.2)."""
    x1: float
    y1: float
    x2: float
    y2: float
    skor: float

MODEL = plaka.ModelDosyasi(
    "yolox_tiny.onnx",
    "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7",
    "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_tiny.onnx",
)
# Öz sınama resmi: YOLOX deposunun kendi assets/dog.jpg'si (Apache-2.0),
# 416×312'ye küçültülmüş. İçinde bir araç (sağ üstte), bir bisiklet, bir köpek.
SINAMA = plaka.ModelDosyasi(
    "arac_sinama.jpg",
    "0c32b6e8364fcd8e32385faecea52c1eaa90483d1aa40849d1be36b9cb07b956",
    "https://github.com/Megvii-BaseDetection/YOLOX/blob/main/assets/dog.jpg",
)

GIRDI = 416
ADIMLAR = (8, 16, 32)
DOLGU = 114
# COCO: 2 otomobil, 3 motosiklet, 5 otobüs, 7 kamyon. 0 insan (yalnızca kayıt için).
ARAC_SINIFLARI = (2, 3, 5, 7)
INSAN = 0
# Kutusunun yarısından fazlası kesilen köşede (park etmiş araçlar) kalan aday
# sayılmaz. Plakadan (%20) gevşek: araç büyük, kesilen köşenin yanından geçen
# bir aracın kutusu oraya biraz taşabilir.
HARIC_DUSUR = 0.50

# Altın değer: SINAMA resmindeki en yüksek araç puanı (2026-11-07, onnxruntime
# 1.31.0). Ön işlem ya da model değişirse kayar.
ALTIN_ARAC = 0.80782
ALTIN_PAYI = 0.05         # sahada başka bir işlemci (AVX2/AVX512) küçük fark verebilir
# Boş sahnede bundan yüksek araç puanı = model bozuk.
BOS_SINIR = 0.10
# 1.3.2: kutu listesine girecek en düşük araç puanı. Bilerek düşük: geçişten
# önceki karedeki (park etmiş) araç zayıf görülse de listede olsun ki sonra
# "yeni araç" sanılmasın. Kararın eşikleri (0.35 / 0.60) ayrıca uygulanır.
KUTU_ALT = 0.10
NMS_ORTUSME = 0.45


# ------------------------------------------------------------- ön işlem ---

def on_isle(img: np.ndarray, n: int = GIRDI) -> tuple[np.ndarray, float]:
    """BGR kırpıntı → (1, 3, n, n) float32 (BGR, 0-255), ölçek r."""
    h, w = img.shape[:2]
    r = min(n / h, n / w)
    yeni = cv2.resize(img, (int(w * r), int(h * r)), interpolation=cv2.INTER_LINEAR)
    tuval = np.full((n, n, 3), DOLGU, np.uint8)
    tuval[: yeni.shape[0], : yeni.shape[1]] = yeni
    return np.ascontiguousarray(tuval.transpose(2, 0, 1)[None], dtype=np.float32), r


def _izgara(n: int) -> tuple[np.ndarray, np.ndarray]:
    noktalar, adimlar = [], []
    for adim in ADIMLAR:
        k = n // adim
        xv, yv = np.meshgrid(np.arange(k), np.arange(k))
        noktalar.append(np.stack((xv, yv), 2).reshape(-1, 2))
        adimlar.append(np.full((k * k, 1), adim))
    return (np.concatenate(noktalar).astype(np.float32),
            np.concatenate(adimlar).astype(np.float32))


_IZGARA, _ADIM = _izgara(GIRDI)


def coz(ham: np.ndarray, r: float, en: int, boy: int):
    """
    Ham çıktı [1, 3549, 85] → (kutular (N, 4) kırpıntı pikselinde x1 y1 x2 y2,
    araç puanı (N,), insan puanı (N,)). Puan = nesne × sınıf olasılığı.
    """
    p = np.asarray(ham, dtype=np.float32).reshape(-1, 85)
    if p.shape[0] != _IZGARA.shape[0]:
        raise ValueError(f"beklenmedik çıktı: {np.shape(ham)}")
    merkez = (p[:, :2] + _IZGARA) * _ADIM
    boyut = np.exp(np.clip(p[:, 2:4], -20.0, 20.0)) * _ADIM
    kutular = np.concatenate([merkez - boyut / 2, merkez + boyut / 2], axis=1) / r
    kutular[:, 0::2] = np.clip(kutular[:, 0::2], 0, en)
    kutular[:, 1::2] = np.clip(kutular[:, 1::2], 0, boy)
    nesne = p[:, 4]
    arac = nesne * p[:, [5 + s for s in ARAC_SINIFLARI]].max(axis=1)
    insan = nesne * p[:, 5 + INSAN]
    return kutular, arac, insan


def _haric_orani(kutular: np.ndarray, haric) -> np.ndarray:
    """
    plaka.haric_orani'nin vektör hâli: kutunun kesilen köşelerin BİRLEŞİMİNDE
    kalan oranı (1.3.3: en çok 3 alan; üst üste binenler iki kez sayılmaz).
    """
    kesilen = np.zeros(len(kutular), dtype=np.float64)
    for isaret, (a1, b1, a2, b2) in plaka.kesisim_parcalari(haric):
        ix = np.clip(np.minimum(kutular[:, 2], a2) - np.maximum(kutular[:, 0], a1), 0, None)
        iy = np.clip(np.minimum(kutular[:, 3], b2) - np.maximum(kutular[:, 1], b1), 0, None)
        kesilen += isaret * ix * iy
    alan = (kutular[:, 2] - kutular[:, 0]) * (kutular[:, 3] - kutular[:, 1])
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(alan > 0, kesilen / alan, 0.0)


def _haricsiz(kutular: np.ndarray, arac: np.ndarray, insan: np.ndarray, haric):
    """Kutusunun yarısından fazlası kesilen köşelerde kalan adayları atar."""
    if isinstance(haric, plaka.AlanMaskesi):
        # 1.4.0: kırpma ALANI (çokgen) — "kesilen köşe" yerine alanın dışı.
        tut = haric.oranlar(kutular) <= HARIC_DUSUR
        return kutular[tut], arac[tut], insan[tut]
    if not plaka.haric_listesi(haric):
        return kutular, arac, insan
    tut = _haric_orani(kutular, haric) <= HARIC_DUSUR
    return kutular[tut], arac[tut], insan[tut]


def skorla(ham: np.ndarray, r: float, en: int, boy: int, haric) -> tuple[float, float]:
    """(en yüksek araç puanı, en yüksek insan puanı); kesilen köşedekiler hariç."""
    kutular, arac, insan = _haricsiz(*coz(ham, r, en, boy), haric)
    a = float(arac.max()) if arac.size else 0.0
    i = float(insan.max()) if insan.size else 0.0
    return max(a, 0.0), max(i, 0.0)


def ortusme(a, b) -> float:
    """İki kutunun kesişim / birleşim oranı (IoU), 0..1."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    kesisim = ix * iy
    birlesim = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - kesisim
    return kesisim / birlesim if birlesim > 0 and kesisim > 0 else 0.0


def kutulari_coz(ham: np.ndarray, r: float, en: int, boy: int, haric,
                 alt: float = KUTU_ALT) -> tuple[list[AracKutu], float]:
    """
    (araç kutuları — puanı ≥ alt, aynı aracın kopyaları birleşmiş (NMS),
    puana göre azalan; en yüksek insan puanı). Kesilen köşedekiler hariç.
    """
    kutular, arac, insan = _haricsiz(*coz(ham, r, en, boy), haric)
    i = float(insan.max()) if insan.size else 0.0
    sec = np.nonzero(arac >= alt)[0]
    if sec.size == 0:
        return [], max(i, 0.0)
    xywh = [[float(k[0]), float(k[1]), float(k[2] - k[0]), float(k[3] - k[1])] for k in kutular[sec]]
    kalan = np.array(cv2.dnn.NMSBoxes(xywh, [float(x) for x in arac[sec]], alt, NMS_ORTUSME)).reshape(-1)
    sonuc = [AracKutu(*(float(v) for v in kutular[sec[j]]), float(arac[sec[j]])) for j in kalan]
    return sorted(sonuc, key=lambda k: -k.skor), max(i, 0.0)


# ------------------------------------------------------------------ bulucu ---

class AracBulucu:
    """Yüklenmiş model. Köprüde yalnızca `yukle()` oluşturur."""

    def __init__(self, oturum, ayar: dict, dizin: str):
        self._oturum = oturum
        self._girdi = oturum.get_inputs()[0].name
        self.esik = float(ayar["arac_esik"])
        self.gecis_esik = float(ayar["arac_gecis_esik"])
        self._dizin = dizin

    def _ham(self, kirpik: np.ndarray):
        x, r = on_isle(kirpik)
        return self._oturum.run(None, {self._girdi: x})[0], r

    def skor(self, kirpik: np.ndarray, haric) -> tuple[float, float]:
        """Kırpıntıdaki (araç, insan) puanı, 0..1 (`--plaka` ve öz sınama)."""
        ham, r = self._ham(kirpik)
        h, w = kirpik.shape[:2]
        return skorla(ham, r, w, h, haric)

    def kutular(self, kirpik: np.ndarray, haric) -> tuple[list[AracKutu], float]:
        """1.3.2: (araç kutuları, insan puanı) — köprü "araç NEREDE" diye bakar."""
        ham, r = self._ham(kirpik)
        h, w = kirpik.shape[:2]
        return kutulari_coz(ham, r, w, h, haric)

    def oz_sinama(self) -> None:
        """Dosya doğru ama ÇALIŞIYOR mu? Değilse PlakaHatasi."""
        a, _ = self.skor(np.full((668, 1568, 3), 110, np.uint8), None)
        if a >= BOS_SINIR:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: boş sahnede araç bulundu ({a:.2f})")
        img = cv2.imread(os.path.join(self._dizin, SINAMA.dosya))
        if img is None:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: {SINAMA.dosya} okunamadı")
        a, _ = self.skor(img, None)
        if abs(a - ALTIN_ARAC) > ALTIN_PAYI:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: sınama resminde araç puanı {a:.3f}")


def yukle(ayar: dict, dizin: str | None = None) -> AracBulucu:
    """
    Modeli ve sınama resmini doğrular, açar ve sınar. Her hata PlakaHatasi
    (Türkçe sebep); köprü onu kayda yazar ve araç bulucusuz (1.3.0 kuralıyla)
    çalışmaya devam eder — asla düşmez.
    """
    d = dizin or plaka.MODEL_DIZINI
    for m in (MODEL, SINAMA):
        yol = os.path.join(d, m.dosya)
        if not os.path.isfile(yol):
            raise plaka.PlakaHatasi(f"araç bulucu dosyası bulunamadı: {m.dosya}")
        if plaka.sha256_dosya(yol) != m.sha256:
            raise plaka.PlakaHatasi(f"araç bulucu dosyası doğrulanamadı (özet uyuşmuyor): {m.dosya}")
    try:
        ort = plaka._ort_yukle()
    except ImportError as e:
        raise plaka.PlakaHatasi(f"onnxruntime yüklenemedi: {e}") from None
    try:
        oturum = ort.InferenceSession(os.path.join(d, MODEL.dosya),
                                      plaka.oturum_ayarlari(ort, ayar["iplik"]),
                                      providers=["CPUExecutionProvider"])
    except Exception as e:  # noqa: BLE001
        raise plaka.PlakaHatasi(f"araç modeli açılamadı: {type(e).__name__}: {e}") from None
    b = AracBulucu(oturum, ayar, d)
    try:
        b.oz_sinama()
    except plaka.PlakaHatasi:
        raise
    except Exception as e:  # noqa: BLE001
        raise plaka.PlakaHatasi(f"araç bulucu öz sınaması çalışmadı: {type(e).__name__}: {e}") from None
    return b
