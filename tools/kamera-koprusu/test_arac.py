# -*- coding: utf-8 -*-
"""
Araç bulucu (1.3.1) — arac.py birim testleri.

    python test_arac.py

1.3.0'ın ilk günü (2026-11-07) kameranın önünde DURAN iki kişi araç boyunda
sayıldı ve "Çözülmemiş kayıt" oldu: köprünün araç bulucusu yoktu, "araç mı"
sorusunu hareketin büyüklüğü cevaplıyordu. 1.3.1 her karede YOLOX-tiny
(Apache-2.0) çalıştırır. Burada bir hata ya personeli boğan sahte kayıt ya da
KAYBOLAN araç demektir.

Saf parçalar (ön işlem, ızgara çözümü, sınıf ve kesilen köşe süzgeci) doğrudan
sınanır; gerçek model onnxruntime kuruluysa (paket venv'i) sınanır, değilse o
testler AÇIKÇA "atlandı" der — sürüm öncesi hepsi paket venv'inde koşmalı.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import arac  # noqa: E402
import plaka  # noqa: E402

ATLANAN: list[str] = []
N = arac.GIRDI                       # 416
ADAY = sum((N // s) ** 2 for s in arac.ADIMLAR)   # 3549
N11 = 640                            # 1.4.2: YOLO11s 640'ta (gece fotoğrafları, 2026-11-13)


def _ort_var() -> bool:
    import importlib.util
    return importlib.util.find_spec("onnxruntime") is not None


def _ham(*adaylar) -> np.ndarray:
    """
    Modelin ham çıktısı [1, 3549, 85]: her aday (indeks, sınıf, nesne, sınıf
    olasılığı, kutu=(dx, dy, ln w, ln h)) — geri kalanı sıfır.
    """
    h = np.zeros((1, ADAY, 85), np.float32)
    for i, sinif, nesne, olas, kutu in adaylar:
        h[0, i, :4] = kutu
        h[0, i, 4] = nesne
        h[0, i, 5 + sinif] = olas
    return h


# --------------------------------------------------------------- ön işlem ---

def test_on_isle_bgr_ham_sol_ust():
    # Faz 0 (2026-11-07): resmî 0.1.1rc0 ONNX dosyaları BGR, 0-255, normalizesiz
    # girdi ister; eski "legacy" girdi (RGB + ImageNet ort./std) SIFIR araç
    # buldu — hata vermeden. Bu test o seçimi kilitler.
    img = np.zeros((100, 200, 3), np.uint8)
    img[:] = (10, 20, 30)
    x, r = arac.on_isle(img)
    assert x.shape == (1, 3, N, N) and x.dtype == np.float32, (x.shape, x.dtype)
    assert r == N / 200
    assert tuple(x[0, :, 0, 0]) == (10.0, 20.0, 30.0)          # B, G, R — ham
    # İçerik SOL ÜSTTE (416×208), altı 114 dolgu.
    assert tuple(x[0, :, 207, N - 1]) == (10.0, 20.0, 30.0)
    assert tuple(x[0, :, 208, 0]) == (114.0, 114.0, 114.0)


# ------------------------------------------------------------- ızgara çözümü -

def test_coz_izgara_ve_adim():
    # Adım 8'in 5. satır 3. sütunu ve adım 32'nin 2. satır 1. sütunu.
    i8 = 52 * 5 + 3
    i32 = 52 * 52 + 26 * 26 + 13 * 2 + 1
    h = _ham((i8, 2, 1.0, 1.0, (0.5, 0.5, np.log(10), np.log(4))),
             (i32, 2, 1.0, 1.0, (0.0, 0.0, 0.0, 0.0)))
    kutular, _a, _i = arac.coz(h, r=0.5, en=400, boy=300)
    # merkez (3.5·8, 5.5·8)=(28, 44), boyut (80, 32); r=0.5 → (56, 88), (160, 64)
    # → (-24, 56, 136, 120), kırpıntıya kırpılır.
    assert np.allclose(kutular[i8], (0, 56, 136, 120)), kutular[i8]
    # merkez (1·32, 2·32)=(32, 64), boyut 32 → (64, 128), 64 → (32, 96, 96, 160)
    assert np.allclose(kutular[i32], (32, 96, 96, 160)), kutular[i32]


def test_skorla_siniflar():
    # Araç = otomobil / motosiklet / otobüs / kamyon (COCO 2, 3, 5, 7);
    # puan = nesne × sınıf. İnsan (0) ayrı tutulur; köpek (16) hiçbir şey.
    kutu = (0.0, 0.0, 0.0, 0.0)
    for sinif in arac.ARAC_SINIFLARI:
        a, i = arac.skorla(_ham((10, sinif, 0.9, 0.8, kutu)), 1.0, 640, 480, None)
        assert abs(a - 0.72) < 1e-6 and i == 0.0, (sinif, a, i)
    a, i = arac.skorla(_ham((10, 0, 0.95, 0.9, kutu), (20, 16, 0.99, 0.99, kutu)),
                       1.0, 640, 480, None)
    assert a == 0.0 and abs(i - 0.855) < 1e-6, (a, i)
    assert arac.skorla(_ham(), 1.0, 640, 480, None) == (0.0, 0.0)


def test_skorla_en_yuksegi_alir():
    kutu = (0.0, 0.0, 0.0, 0.0)
    a, _ = arac.skorla(_ham((10, 2, 0.9, 0.5, kutu), (30, 7, 0.9, 0.9, kutu),
                            (50, 3, 0.2, 0.9, kutu)), 1.0, 640, 480, None)
    assert abs(a - 0.81) < 1e-6, a


def test_skorla_kesilen_koseyi_atlar():
    # Kutusunun çoğu kesilen köşede (park etmiş araçlar) kalan aday sayılmaz.
    i8 = 52 * 5 + 3                      # r=0.5 → (0, 56, 136, 120)
    h = _ham((i8, 2, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),
             (52 * 40 + 40, 7, 1.0, 0.5, (0.5, 0.5, 0.0, 0.0)))
    assert abs(arac.skorla(h, 0.5, 800, 600, None)[0] - 0.9) < 1e-6
    a, _ = arac.skorla(h, 0.5, 800, 600, (0, 50, 200, 100))
    assert abs(a - 0.5) < 1e-6, a


# ------------------------------------------------------- kutular (1.3.2) ---

def test_ortusme():
    K = arac.AracKutu
    a = K(0, 0, 100, 100, 0.9)
    assert arac.ortusme(a, a) == 1.0
    assert arac.ortusme(a, K(200, 0, 300, 100, 0.9)) == 0.0
    assert abs(arac.ortusme(a, K(50, 0, 150, 100, 0.9)) - 50 / 150) < 1e-9
    assert arac.ortusme(a, K(10, 10, 10, 50, 0.9)) == 0.0          # alansız kutu


def test_kutulari_coz_nms_ve_esik():
    # Aynı aracın iki komşu ızgara adayı tek kutu olur (NMS); eşik altı ve
    # araç olmayan sınıf kutu vermez; insan puanı ayrıca döner.
    i8 = 52 * 5 + 3
    h = _ham((i8, 2, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),
             (i8 + 1, 2, 1.0, 0.8, (-0.5, 0.5, np.log(10), np.log(4))),   # aynı kutu, komşu hücre
             (52 * 40 + 40, 7, 1.0, 0.6, (0.5, 0.5, 0.0, 0.0)),            # başka yerde kamyon
             (52 * 20 + 20, 2, 1.0, 0.05, (0.5, 0.5, 0.0, 0.0)),           # eşik altı
             (52 * 30 + 30, 0, 1.0, 0.7, (0.5, 0.5, 0.0, 0.0)))            # insan
    kutular, insan = arac.kutulari_coz(h, 0.5, 800, 600, None)
    assert [round(k.skor, 3) for k in kutular] == [0.9, 0.6], kutular
    assert np.allclose(kutular[0][:4], (0, 56, 136, 120)), kutular[0]
    assert abs(insan - 0.7) < 1e-6
    # Kesilen köşedeki kutu düşer.
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, (0, 50, 200, 100))
    assert [round(k.skor, 3) for k in kutular] == [0.6], kutular


def test_kesilen_koseler_birden_cok():
    # 1.3.3: en çok 3 kesilen köşe; araç kutusu HERHANGİ birinin (birleşimin)
    # içinde kalıyorsa düşer — üst üste binenler iki kez sayılmaz.
    i8 = 52 * 5 + 3                      # r=0.5 → (0, 56, 136, 120)
    h = _ham((i8, 2, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),
             (52 * 40 + 40, 7, 1.0, 0.5, (0.5, 0.5, 0.0, 0.0)))
    ikinci = ((600, 500, 50, 50), (0, 50, 200, 100))              # araç 2. alanın içinde
    assert abs(arac.skorla(h, 0.5, 800, 600, ikinci)[0] - 0.5) < 1e-6
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, ikinci)
    assert [round(k.skor, 3) for k in kutular] == [0.5], kutular
    # İki yarım alan birlikte kutunun tamamını örter → düşer (tek tek %50).
    yarim = ((0, 50, 68, 100), (68, 50, 100, 100))
    assert abs(arac.skorla(h, 0.5, 800, 600, yarim)[0] - 0.5) < 1e-6
    # Aynı yarı iki kez: birleşim %50 → kalır (toplam %100 sayılsaydı düşerdi).
    ayni = ((0, 50, 68, 100), (0, 50, 68, 100))
    assert abs(arac.skorla(h, 0.5, 800, 600, ayni)[0] - 0.9) < 1e-6


def test_kirpma_alani_cokgen():
    # 1.4.0: kırpma ALANI (çokgen). Kutusunun yarısından fazlası alanın
    # DIŞINDA kalan aday düşer — hariç dikdörtgendeki kural (%50) aynen.
    i8 = 52 * 5 + 3                      # r=0.5 → (0, 56, 136, 120)
    h = _ham((i8, 2, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),
             (52 * 40 + 40, 7, 1.0, 0.5, (0.5, 0.5, 0.0, 0.0)))   # (624, 624, 688, 688)→ kırpılır
    # Sol üst köşesi kesilmiş alan: (0..200, 0..150) dışarıda → ilk kutu ~%70 dışarıda.
    alan = [(200, 0), (800, 0), (800, 600), (0, 600), (0, 150), (200, 150)]
    m = plaka.AlanMaskesi.cokgenden(alan, 800, 600)
    assert abs(arac.skorla(h, 0.5, 800, 600, m)[0] - 0.5) < 1e-6
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, m)
    assert [round(k.skor, 3) for k in kutular] == [0.5], kutular
    # Kesilen kısım küçükse (kutunun %50'sinden az) aday kalır.
    alan = [(40, 0), (800, 0), (800, 600), (0, 600), (0, 150), (40, 150)]
    m = plaka.AlanMaskesi.cokgenden(alan, 800, 600)
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, m)
    assert [round(k.skor, 3) for k in kutular] == [0.9, 0.5], kutular


# ------------------------------------------------- YOLO11s profili (1.4.2) ---
#
# 1.4.2: araç bulucu YOLO11s (Ultralytics, AGPL — sahibin kararı 2026-11-12:
# yalnızca kendi otoparkımız). Çıktısı YOLOX'tan BAŞKA: [1, 84, N], nesne
# puanı yok, kutu girdi pikselinde merkez/boyut; girdi ORTALANMIŞ letterbox,
# RGB, /255. YOLOX ön işlemiyle beslenirse hata vermeden zayıf puan verir
# (hız aracı 0.59 gördü) — bu testler o ayrımı kilitler.

def _ham11(*adaylar) -> np.ndarray:
    """
    YOLO11 ham çıktısı [1, 84, 3549]: her aday (indeks, sınıf, olasılık,
    kutu=(cx, cy, w, h) GİRDİ pikselinde) — geri kalanı sıfır.
    """
    h = np.zeros((1, 84, ADAY), np.float32)
    for i, sinif, olas, kutu in adaylar:
        h[0, :4, i] = kutu
        h[0, 4 + sinif, i] = olas
    return h


def test_profiller():
    t, y = arac.YOLOX_TINY, arac.YOLO11S
    # tiny 1.4.1 ile birebir: aynı dosya, altın değer, eşik anahtarları.
    assert t.model == arac.MODEL and t.altin == arac.ALTIN_ARAC, t
    assert (t.esik, t.gecis_esik) == (0.35, 0.60), t
    assert (t.esik_anahtari, t.gecis_anahtari) == ("arac_esik", "arac_gecis_esik"), t
    assert t.yer_tutucu is False
    # 2026-11-13: 25 gerçek gece aracında 416 uzaktaki / kırpmayla kesilen 4
    # aracı kaçırdı, 640 hepsini gördü (en düşük 0.34) → 640. Eşikler 0.30 /
    # 0.60; yanlış alarm da ölçüldü (boş şerit, insan, el arabası: 0) →
    # ölçülmüş, varsayılan (sahibin kararı).
    assert y.model.dosya == "yolo11s_640.onnx", y.model
    assert y.model.sha256 == "5c56db2f3bc7baaf650ad3e55e4ec4ecda1d245f83d8968e731ad806bebc3161"
    assert y.girdi == N11
    assert (y.esik, y.gecis_esik) == (0.30, 0.60), y
    assert y.yer_tutucu is False
    assert (y.esik_anahtari, y.gecis_anahtari) == ("arac11_esik", "arac11_gecis_esik"), y


def test_yolo11s_profili_640_besler():
    # Profilin ön işlemi 640 × 640, ortalanmış letterbox — 416'lık
    # on_isle11 varsayılanı değil (dosya 640'lık; 416 girdi hata verirdi).
    img = np.zeros((300, 400, 3), np.uint8)
    x, (r, dw, dh) = arac.YOLO11S.hazirla(img)
    assert x.shape == (1, 3, N11, N11), x.shape
    p, pr, pdw, pdh = plaka.letterbox(img, N11)
    assert np.array_equal(x, p) and (pr, pdw, pdh) == (r, dw, dh)


def test_on_isle11_ortali_rgb01():
    img = np.zeros((100, 200, 3), np.uint8)
    img[:] = (10, 20, 30)                                   # B, G, R
    x, (r, dw, dh) = arac.on_isle11(img)
    assert x.shape == (1, 3, N, N) and x.dtype == np.float32, (x.shape, x.dtype)
    assert r == N / 200 and dw == 0 and dh == 104, (r, dw, dh)
    # Ortalanmış: üstte 104 satır 114 dolgu, içerik 104..311, altı yine dolgu.
    assert np.allclose(x[0, :, 0, 0], 114 / 255), x[0, :, 0, 0]
    assert np.allclose(x[0, :, 104, 0], (30 / 255, 20 / 255, 10 / 255)), x[0, :, 104, 0]   # RGB
    assert np.allclose(x[0, :, 311, N - 1], (30 / 255, 20 / 255, 10 / 255))
    assert np.allclose(x[0, :, 312, 0], 114 / 255)
    # Plaka bulucunun Ultralytics-uyumlu letterbox'ı ile birebir (tek kod yolu).
    p, pr, pdw, pdh = plaka.letterbox(img, N)
    assert np.array_equal(x, p) and (pr, pdw, pdh) == (r, dw, dh)


def test_coz11_kutu_ters_letterbox():
    # Girdi pikselinde (cx, cy, w, h) = (108, 120, 80, 40) → (68, 100, 148, 140);
    # dolgu (8, 20) çıkar → (60, 80, 140, 120); r=0.5 → (120, 160, 280, 240).
    h = _ham11((7, 2, 0.9, (108, 120, 80, 40)),
               (9, 2, 0.8, (10, 10, 40, 40)))               # sol üstten taşan
    kutular, a, i = arac.coz11(h, (0.5, 8.0, 20.0), 400, 300)
    assert kutular.shape == (ADAY, 4), kutular.shape
    assert np.allclose(kutular[7], (120, 160, 280, 240)), kutular[7]
    # (-10, -10, 30, 30) − dolgu → (-18, -30, 22, 10) / 0.5 → kırpıntıya kırpılır.
    assert np.allclose(kutular[9], (0, 0, 44, 20)), kutular[9]
    assert abs(a[7] - 0.9) < 1e-6 and i[7] == 0.0
    # Yanlış biçim (ör. YOLOX çıktısı) sessizce çözülmez.
    try:
        arac.coz11(_ham(), (1.0, 0.0, 0.0), 400, 300)
        raise AssertionError("YOLOX çıktısı YOLO11 diye çözüldü")
    except ValueError:
        pass


def test_coz11_siniflar_nesne_puani_yok():
    # Araç puanı = 2/3/5/7 sınıf olasılıklarının en yükseği (nesne çarpanı YOK);
    # insan (0) ayrı; köpek (16) hiçbir şey.
    kutu = (50.0, 50.0, 20.0, 20.0)
    for sinif in arac.ARAC_SINIFLARI:
        a, i = arac.skorla(_ham11((10, sinif, 0.72, kutu)), (1.0, 0.0, 0.0), 640, 480,
                           None, profil=arac.YOLO11S)
        assert abs(a - 0.72) < 1e-6 and i == 0.0, (sinif, a, i)
    a, i = arac.skorla(_ham11((10, 0, 0.855, kutu), (20, 16, 0.99, kutu)),
                       (1.0, 0.0, 0.0), 640, 480, None, profil=arac.YOLO11S)
    assert a == 0.0 and abs(i - 0.855) < 1e-6, (a, i)
    assert arac.skorla(_ham11(), (1.0, 0.0, 0.0), 640, 480, None,
                       profil=arac.YOLO11S) == (0.0, 0.0)


def test_kutulari_coz11_nms_esik_ve_kesilen_kose():
    # Aynı araç iki aday → tek kutu (NMS); eşik altı ve araç olmayan sınıf
    # kutu vermez; insan ayrıca döner; kesilen köşedeki kutu düşer.
    d = (0.5, 0.0, 0.0)
    h = _ham11((10, 2, 0.9, (34, 44, 68, 32)),              # → (0, 56, 136, 120)
               (11, 2, 0.8, (36, 44, 68, 32)),              # aynı araç, 4 px kaymış
               (300, 7, 0.6, (330, 330, 20, 20)),           # başka yerde kamyon
               (400, 2, 0.05, (200, 200, 20, 20)),          # eşik altı
               (500, 0, 0.7, (100, 300, 20, 40)))           # insan
    kutular, insan = arac.kutulari_coz(h, d, 800, 600, None, profil=arac.YOLO11S)
    assert [round(k.skor, 3) for k in kutular] == [0.9, 0.6], kutular
    assert np.allclose(kutular[0][:4], (0, 56, 136, 120)), kutular[0]
    assert abs(insan - 0.7) < 1e-6
    kutular, _ = arac.kutulari_coz(h, d, 800, 600, (0, 50, 200, 100), profil=arac.YOLO11S)
    assert [round(k.skor, 3) for k in kutular] == [0.6], kutular


def test_kutular_sinifi_tasir():
    # 1.4.3 (2026-11-20): el arabası iten kişi 19.11'de 5 kez "Çözülmemiş
    # kayıt" oldu (tek kare / kapıda kayboldu, 0.37-0.52); 17:38 kartının
    # fotoğrafı YOLO11s'te motosiklet 0.50, otomobil 0.01. Sınıf kutuyla
    # gelmeli ki karar ve kayıt satırı onu bilsin. Kutunun sınıfı, araç
    # puanını veren (en yüksek) araç sınıfıdır — COCO numarasıyla.
    assert arac.MOTOSIKLET == 3
    assert arac.SINIF_ADLARI == {2: "otomobil", 3: "motosiklet", 5: "otobüs", 7: "kamyon"}
    assert arac.AracKutu(0, 0, 1, 1, 0.5).sinif == -1        # eski 5 alanlı kurulum: bilinmiyor
    i8 = 52 * 5 + 3                                           # r=0.5 → (0, 56, 136, 120)
    h = _ham((i8, 3, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),          # motosiklet
             (52 * 40 + 40, 7, 1.0, 0.6, (0.5, 0.5, 0.0, 0.0)),            # kamyon
             (52 * 20 + 20, 5, 1.0, 0.7, (0.5, 0.5, 0.0, 0.0)))            # otobüs …
    h[0, 52 * 20 + 20, 5 + 2] = 0.4                           # … otomobil 0.4 aynı satırda
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, None)
    assert [(round(k.skor, 3), k.sinif) for k in kutular] == [(0.9, 3), (0.7, 5), (0.6, 7)], kutular
    # Kesilen köşe kutuyu düşürünce sınıflar kaymaz (aynı süzgeç).
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, (0, 50, 200, 100))
    assert [(round(k.skor, 3), k.sinif) for k in kutular] == [(0.7, 5), (0.6, 7)], kutular
    # YOLO11 çıktısı: aynı kural.
    d = (0.5, 0.0, 0.0)
    h = _ham11((10, 3, 0.5, (34, 44, 68, 32)),                # → (0, 56, 136, 120) motosiklet
               (300, 2, 0.8, (330, 330, 20, 20)))             # başka yerde otomobil
    h[0, 4 + 2, 10] = 0.01                                    # 17:38 kartı: otomobil 0.01
    kutular, _ = arac.kutulari_coz(h, d, 800, 600, None, profil=arac.YOLO11S)
    assert [(round(k.skor, 3), k.sinif) for k in kutular] == [(0.8, 2), (0.5, 3)], kutular
    kutular, _ = arac.kutulari_coz(h, d, 800, 600, (0, 50, 200, 100), profil=arac.YOLO11S)
    assert [(round(k.skor, 3), k.sinif) for k in kutular] == [(0.8, 2)], kutular


# ---------------------------------------- 1.4.4: kutu içinde kutu (21.11) ---
#
# Sahada 21.11 16:30: AYNI araç (35 ALN 793) iki iz oldu — biri bilet, öteki
# plakasız "araç girdi" kartı (ikisi aynı saniyede kapıdan geçti, aynı karede
# durdu). Bulucu aracın bütün kutusunun İÇİNDE bir parça kutusu (aracın bir
# kısmı) da veriyordu: küçük kutu büyüğün içindeyken IoU düşük kalır, NMS
# (0.45) ve izcinin kopya kuralı (0.50) ikisini de tutar. Ölçü: kesişim ÷
# KÜÇÜK kutunun alanı (SAHI'nin "IOS" ölçüsü).

def _k11(x1, y1, x2, y2):
    """Kırpıntı pikselindeki kutu → YOLO11 girdisi (r=1, dolgu yok: aynı piksel)."""
    return ((x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1)


_D1 = (1.0, 0.0, 0.0)


def _kutular11(*adaylar):
    h = _ham11(*[(i, s, p, _k11(*k)) for i, (s, p, k) in enumerate(adaylar, start=10)])
    kutular, _ = arac.kutulari_coz(h, _D1, 800, 600, None, profil=arac.YOLO11S)
    return [(tuple(round(v) for v in k[:4]), round(k.skor, 3), k.sinif) for k in kutular]


def test_icindeki_parca_kutusu_ayni_arac():
    # 16:30'un biçimi: bütün araç + içinde ön yarısı. IoU 0.25 (< 0.45): bugün
    # İKİ kutu. Kalan: BÜYÜK kutunun yeri (araç oradadır), en yüksek puan ve
    # o puanı veren kutunun sınıfı.
    butun, parca = (100, 100, 500, 400), (100, 250, 300, 400)
    assert arac.ortusme(arac.AracKutu(*butun, 0.9), arac.AracKutu(*parca, 0.9)) < arac.NMS_ORTUSME
    assert _kutular11((2, 0.9, butun), (2, 0.6, parca)) == [(butun, 0.9, 2)]
    assert _kutular11((2, 0.6, butun), (7, 0.95, parca)) == [(butun, 0.95, 7)]
    # İki parça birden: yine tek kutu.
    assert _kutular11((2, 0.9, butun), (2, 0.5, parca),
                      (2, 0.4, (300, 100, 500, 250))) == [(butun, 0.9, 2)]


def test_icerme_esigi_yuzde_seksen():
    # Küçük kutunun %80'i büyüğün içinde → aynı araç; %79.5 → iki araç.
    assert arac.ICERME_ESIGI == 0.80
    kucuk = (100, 100, 300, 300)                       # alan 40 000
    assert _kutular11((2, 0.9, (140, 0, 600, 400)), (2, 0.5, kucuk)) == \
        [((140, 0, 600, 400), 0.9, 2)]                 # kesişim 160 × 200 = %80
    assert len(_kutular11((2, 0.9, (141, 0, 600, 400)), (2, 0.5, kucuk))) == 2   # %79.5


def test_iki_ayri_arac_birlesmez():
    # Yan yana iki araç; arkadan yapışık gelen (~%60'ı içeride) araç: iki kutu.
    assert len(_kutular11((2, 0.9, (100, 100, 300, 300)), (2, 0.8, (310, 100, 510, 300)))) == 2
    assert len(_kutular11((2, 0.9, (100, 100, 500, 400)), (2, 0.8, (300, 220, 600, 420)))) == 2


def test_motosiklet_arabanin_icinde_birlesmez():
    # Arabanın önünden geçen motosiklet arabanın kutusunun içinde kalabilir:
    # birleşseydi motosiklet kaybolurdu. İki yönde de (motosiklet içeride /
    # dışarıda) birleştirme yok.
    araba, moto = (100, 100, 500, 400), (200, 200, 300, 380)
    assert sorted(_kutular11((2, 0.9, araba), (3, 0.7, moto))) == \
        sorted([(araba, 0.9, 2), (moto, 0.7, 3)])
    assert len(_kutular11((3, 0.9, araba), (2, 0.7, moto))) == 2


def test_icindeki_kutu_yoloxta_da_birlesir():
    # YOLOX-tiny (GPU bozulunca yedek) aynı yoldan geçer.
    i8 = 52 * 5 + 3                      # r=0.5 → (0, 56, 136, 120)
    i8p = 52 * 6 + 3                     # aynı yerin içinde küçük kutu
    h = _ham((i8, 2, 1.0, 0.9, (0.5, 0.5, np.log(10), np.log(4))),
             (i8p, 2, 1.0, 0.5, (0.5, -0.5, np.log(4), np.log(2))))
    kutular, _ = arac.kutulari_coz(h, 0.5, 800, 600, None)
    assert [round(k.skor, 3) for k in kutular] == [0.9], kutular
    assert np.allclose(kutular[0][:4], (0, 56, 136, 120)), kutular[0]


def test_motosiklet_esigi_profilde_ve_ayarda():
    # 1.4.3 (sahibin kararı 20.11): YOLO11s'te yönü bilinmeyen plakasız kapı
    # olayı puanını motosikletten alıyorsa 0.60 ister. tiny'de kural yok.
    # 1.4.4 (sahibin kararı 21.11, el arabaları 0.61 / 0.56): 0.70.
    t, y = arac.YOLOX_TINY, arac.YOLO11S
    assert t.moto_esik is None and t.moto_anahtari is None, t
    assert (y.moto_esik, y.moto_anahtari) == (0.70, "arac11_moto_esik"), y
    b = arac.AracBulucu(_SahteOturum(_ham11(), n=N11), _ayar(), plaka.MODEL_DIZINI,
                        profil=arac.YOLO11S)
    assert b.moto_esik == 0.70, b.moto_esik
    b = arac.AracBulucu(_SahteOturum(_ham11(), n=N11), dict(_ayar(), arac11_moto_esik=0.30),
                        plaka.MODEL_DIZINI, profil=arac.YOLO11S)
    assert b.moto_esik == 0.30, b.moto_esik                 # sahada geri alma: 0.30
    b = arac.AracBulucu(_SahteOturum(_ham()), dict(_ayar(), arac11_moto_esik=0.5),
                        plaka.MODEL_DIZINI)
    assert b.moto_esik is None, b.moto_esik                 # tiny: ayar dokunmaz


def test_bulucu11_kendi_on_islemini_ve_esik_anahtarini_kullanir():
    # Bulucu profilin ön işlemini kullanmalı (RGB /255, ≤ 1) — YOLOX'unkiyle
    # (0-255) beslenen YOLO11 hata vermez, yalnızca zayıf görür.
    gelen = {}

    class O(_SahteOturum):
        def run(self, adlar, girdiler):
            gelen["x"] = girdiler["images"]
            return super().run(adlar, girdiler)

    b = arac.AracBulucu(O(_ham11((10, 2, 0.9, (100, 100, 40, 40))), n=N11), _ayar(),
                        plaka.MODEL_DIZINI, profil=arac.YOLO11S)
    a, _ = b.skor(np.full((300, 400, 3), 250, np.uint8), None)
    assert abs(a - 0.9) < 1e-6, a
    assert float(gelen["x"].max()) <= 1.0, gelen["x"].max()
    # Eşikler profilin anahtarından; anahtar yoksa profilin varsayılanı.
    assert (b.esik, b.gecis_esik) == (arac.YOLO11S.esik, arac.YOLO11S.gecis_esik)
    ayar = dict(_ayar(), arac11_esik=0.21, arac11_gecis_esik=0.44)
    b = arac.AracBulucu(O(_ham11(), n=N11), ayar, plaka.MODEL_DIZINI, profil=arac.YOLO11S)
    assert (b.esik, b.gecis_esik) == (0.21, 0.44)
    # tiny eskisi gibi ARAC_BUL_ESIK / ARAC_GECIS_ESIK'ten.
    ayar = dict(_ayar(), arac_esik=0.4, arac_gecis_esik=0.7)
    b = arac.AracBulucu(_SahteOturum(_ham()), ayar, plaka.MODEL_DIZINI)
    assert (b.esik, b.gecis_esik) == (0.4, 0.7)


def test_oz_sinama11_sacma_ciktiyi_yakalar():
    for ham in (_ham11(),
                _ham11(*[(i, 2, 0.99, (208, 208, 50, 50)) for i in range(0, ADAY, 7)])):
        b = arac.AracBulucu(_SahteOturum(ham, n=N11), _ayar(), plaka.MODEL_DIZINI,
                            profil=arac.YOLO11S)
        try:
            b.oz_sinama()
            raise AssertionError("saçma çıktılı YOLO11 öz sınamayı geçti")
        except plaka.PlakaHatasi as e:
            assert "öz sınama" in str(e), e


def test_oz_sinama11_kendi_altin_degeriyle():
    # Öz sınama profilin KENDİ altın değeriyle karşılaştırır (tiny 0.808,
    # YOLO11s 640 0.491): kendi altınının payı içindeki puan geçer.
    puan = arac.YOLO11S.altin - 0.04          # kendi altınına 0.04, tiny'ninkine çok uzak

    class O(_SahteOturum):
        def run(self, adlar, girdiler):
            x = girdiler["images"]
            bos = float(x.std()) < 0.01                    # düz gri sahne
            self._ham = _ham11() if bos else _ham11((10, 2, puan, (300, 60, 120, 50)))
            return super().run(adlar, girdiler)

    arac.AracBulucu(O(None, n=N11), _ayar(), plaka.MODEL_DIZINI,
                    profil=arac.YOLO11S).oz_sinama()


def test_gercek_yolo11s_bos_sahne_ve_altin_deger():
    if not _ort_var():
        ATLANAN.append("gerçek YOLO11s modeli (onnxruntime kurulu değil)")
        return
    b = arac.yukle(_ayar(), profil=arac.YOLO11S)         # öz sınama da koşar
    assert b.profil is arac.YOLO11S
    a, i = b.skor(np.full((668, 1568, 3), 110, np.uint8), None)
    assert a < 0.05 and i < 0.05, (a, i)
    import cv2
    img = cv2.imread(os.path.join(plaka.MODEL_DIZINI, arac.SINAMA.dosya))
    a, _ = b.skor(img, None)
    assert abs(a - arac.YOLO11S.altin) < 2e-3, a
    h, w = img.shape[:2]
    a2, _ = b.skor(img, (w // 2, 0, w - w // 2, h // 2))
    assert a2 < 0.10, (a2, a)
    kutular, _ = b.kutular(img, None)
    assert kutular and abs(kutular[0].skor - a) < 1e-6, kutular
    k = kutular[0]
    assert (k.x1 + k.x2) / 2 > w / 2 and (k.y1 + k.y2) / 2 < h / 2, k
    assert b.kutular(np.full((668, 1568, 3), 110, np.uint8), None)[0] == []


# ------------------------------------------------------------------ ayarlar ---

def _ortamsiz(f):
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        f()
    finally:
        for k, v in eski.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def test_ayarlar_varsayilan_ortam_ve_bozuk():
    def govde():
        for ad in ("ARAC_BUL", "ARAC_BUL_ESIK", "ARAC_GECIS_ESIK"):
            assert ad in plaka.AYAR_ADLARI, ad
        a, u = plaka.calisma_ayarlari()
        assert u == [] and a["arac_acik"] is True
        assert a["arac_esik"] == 0.35 and a["arac_gecis_esik"] == 0.60, a
        os.environ["ARAC_BUL"] = "0"
        a, u = plaka.calisma_ayarlari({"ARAC_BUL_ESIK": "0.4"})
        assert a["arac_acik"] is False and a["arac_esik"] == 0.4 and u == []
        a, u = plaka.calisma_ayarlari({"ARAC_BUL_ESIK": "abc", "ARAC_GECIS_ESIK": "1.5"})
        assert a["arac_esik"] == 0.35 and a["arac_gecis_esik"] == 0.60
        assert len(u) == 2 and all("ARAC_" in x for x in u), u
    _ortamsiz(govde)


# ------------------------------------------------------------------ modeller ---

def test_model_ve_sinama_dosyalari_yerinde():
    for m in (arac.MODEL, arac.SINAMA, arac.YOLO11S.model):
        yol = os.path.join(plaka.MODEL_DIZINI, m.dosya)
        assert os.path.isfile(yol), yol
        assert plaka.sha256_dosya(yol) == m.sha256, m.dosya


def _dizin(*bozuk_dosyalar: str, eksik: str | None = None) -> str:
    d = tempfile.mkdtemp(prefix="otopark-test-arac-")
    for m in (arac.MODEL, arac.SINAMA, arac.YOLO11S.model):
        if m.dosya == eksik:
            continue
        hedef = os.path.join(d, m.dosya)
        if m.dosya in bozuk_dosyalar:
            with open(hedef, "wb") as f:
                f.write(b"bozuk dosya")
            continue
        kaynak = os.path.join(plaka.MODEL_DIZINI, m.dosya)
        try:
            os.link(kaynak, hedef)
        except OSError:
            shutil.copyfile(kaynak, hedef)
    return d


def _ayar() -> dict:
    return plaka.calisma_ayarlari()[0]


# 1.4.2: her profil KENDİ model dosyasını doğrular (YOLO11s yüklenirken
# YOLOX dosyasına bakılmaz, tersi de).
_PROFIL_DOSYA = ((arac.YOLOX_TINY, arac.MODEL), (arac.YOLOX_TINY, arac.SINAMA),
                 (arac.YOLO11S, arac.YOLO11S.model), (arac.YOLO11S, arac.SINAMA))


def test_yukle_eksik_dosya():
    for p, m in _PROFIL_DOSYA:
        try:
            arac.yukle(_ayar(), dizin=_dizin(eksik=m.dosya), profil=p)
            raise AssertionError(f"{p.ad}: eksik dosyayla yüklendi")
        except plaka.PlakaHatasi as e:
            assert "bulunamadı" in str(e) and m.dosya in str(e), (p.ad, e)


def test_yukle_bozuk_dosya():
    for p, m in _PROFIL_DOSYA:
        try:
            arac.yukle(_ayar(), dizin=_dizin(m.dosya), profil=p)
            raise AssertionError(f"{p.ad}: bozuk dosyayla yüklendi")
        except plaka.PlakaHatasi as e:
            assert "doğrulanamadı" in str(e) and m.dosya in str(e), (p.ad, e)


def test_yukle_onnxruntime_yoksa():
    onceki = sys.modules.get("onnxruntime", "YOK")
    sys.modules["onnxruntime"] = None
    try:
        try:
            arac.yukle(_ayar())
            raise AssertionError("onnxruntime olmadan yüklendi")
        except plaka.PlakaHatasi as e:
            assert "onnxruntime" in str(e), e
    finally:
        if onceki == "YOK":
            sys.modules.pop("onnxruntime", None)
        else:
            sys.modules["onnxruntime"] = onceki


class _SahteOturum:
    """Model yerine: hep aynı ham çıktıyı verir."""

    def __init__(self, ham, n: int = N):
        self._ham = ham
        self._n = n                       # beklenen girdi kenarı: tiny 416, YOLO11s 640

    def get_inputs(self):
        class G:
            name = "images"
        return [G()]

    def run(self, _adlar, girdiler):
        n = self._n
        assert list(girdiler) == ["images"] and girdiler["images"].shape == (1, 3, n, n), \
            girdiler["images"].shape
        return [self._ham]


def test_oz_sinama_sacma_ciktiyi_yakalar():
    # Dosya doğru ama çıktı saçma (ör. ön işlem değişti): araç görmeyen bir
    # model sessizce her duranı "araç değil" sayardı — açılmamalı.
    b = arac.AracBulucu(_SahteOturum(_ham()), _ayar(), plaka.MODEL_DIZINI)
    try:
        b.oz_sinama()
        raise AssertionError("hiç araç görmeyen model öz sınamayı geçti")
    except plaka.PlakaHatasi as e:
        assert "öz sınama" in str(e), e
    # Her yerde araç gören model de geçmemeli (boş sahnede araç).
    hep = _ham(*[(i, 2, 1.0, 1.0, (0.5, 0.5, 0.0, 0.0)) for i in range(0, ADAY, 7)])
    try:
        arac.AracBulucu(_SahteOturum(hep), _ayar(), plaka.MODEL_DIZINI).oz_sinama()
        raise AssertionError("her yerde araç gören model öz sınamayı geçti")
    except plaka.PlakaHatasi as e:
        assert "öz sınama" in str(e), e


class _GpuHatali(_SahteOturum):
    """Grafik işlemcisi oturumu yerine: her çağrıda HizlandiriciHatasi."""

    def __init__(self):
        super().__init__(None)
        self.cagri = 0

    def run(self, _adlar, _girdiler):
        self.cagri += 1
        raise plaka.HizlandiriciHatasi("CL_DEVICE_NOT_AVAILABLE")


def test_gpu_hatasinda_islemcideki_tiny_ye_gecer():
    # 1.4.2: YOLO11s grafik işlemcisinde çalışırken bozulursa bulucu
    # işlemcideki YOLOX-tiny'ye geçer (yavaş YOLO11s-CPU değil: 123 ms) —
    # eşikleri de tiny'ninki olur; AYNI kare tiny ile ölçülür, kaybolmaz.
    import contextlib
    import io
    gpu = _GpuHatali()
    tiny = _SahteOturum(_ham((10, 2, 1.0, 0.9, (0.5, 0.5, 0.0, 0.0))))
    acilan = []

    def yedek():
        acilan.append(1)
        return tiny, arac.YOLOX_TINY

    ayar = dict(_ayar(), arac_esik=0.4, arac_gecis_esik=0.7, arac11_esik=0.2)
    b = arac.AracBulucu(gpu, ayar, plaka.MODEL_DIZINI, profil=arac.YOLO11S, yedek=yedek)
    assert (b.esik, b.profil) == (0.2, arac.YOLO11S)
    kayit = io.StringIO()
    with contextlib.redirect_stdout(kayit):
        a, _ = b.skor(np.full((300, 400, 3), 120, np.uint8), None)
    assert abs(a - 0.9) < 1e-6, a
    assert b.profil is arac.YOLOX_TINY and (b.esik, b.gecis_esik) == (0.4, 0.7), b.profil
    import gunluk
    assert gunluk.GPU_BIRAKILDI_ISARETI in kayit.getvalue(), kayit.getvalue()
    assert "YOLOX-tiny" in kayit.getvalue() and "CL_DEVICE_NOT_AVAILABLE" in kayit.getvalue()
    b.kutular(np.full((300, 400, 3), 120, np.uint8), None)
    # 1.4.2: tek hatada bırakılmaz — 3 deneme, sonra işlemci; sonraki kare
    # doğrudan işlemcide (grafik işlemcisi her karede yeniden denenmez —
    # geri dönüşü GpuGeriDonus yapar).
    assert gpu.cagri == 3 and len(acilan) == 1, (gpu.cagri, acilan)
    # Kalp satırı bunu söyler (hizlandirici.kalp_etiketi).
    assert "araç bulucu" in plaka.GPU_BIRAKILANLAR, plaka.GPU_BIRAKILANLAR
    plaka.GPU_BIRAKILANLAR.clear()


def test_gpu_iki_hatadan_sonra_gpu_da_kalir():
    # Geçici aksama (2 hata, 3. deneme başarılı): YOLO11s'te kalınır, işlemci
    # yedeği hiç açılmaz, eşikler değişmez.
    ham = _ham11((10, 2, 0.9, (100, 100, 40, 40)))

    class Aksak(_SahteOturum):
        def __init__(self):
            super().__init__(ham, n=N11)
            self.cagri = 0

        def run(self, adlar, girdiler):
            self.cagri += 1
            if self.cagri <= 2:
                raise plaka.HizlandiriciHatasi("CL_INVALID_COMMAND_QUEUE")
            return super().run(adlar, girdiler)

    gpu = Aksak()
    acilan = []
    b = arac.AracBulucu(gpu, _ayar(), plaka.MODEL_DIZINI, profil=arac.YOLO11S,
                        yedek=lambda: acilan.append(1) or (None, arac.YOLOX_TINY))
    a, _ = b.skor(np.full((300, 400, 3), 120, np.uint8), None)
    assert abs(a - 0.9) < 1e-6 and gpu.cagri == 3 and not acilan, (a, gpu.cagri, acilan)
    assert b.profil is arac.YOLO11S and "araç bulucu" not in plaka.GPU_BIRAKILANLAR


def test_gpu_hatasi_yedeksiz_isciye_gider():
    # İşlemci kümesinde (yedek yok) hata yutulmaz: işçi sayar (1.3.1 kuralı).
    b = arac.AracBulucu(_GpuHatali(), _ayar(), plaka.MODEL_DIZINI)
    try:
        b.skor(np.full((300, 400, 3), 120, np.uint8), None)
        raise AssertionError("hata yutuldu")
    except plaka.HizlandiriciHatasi:
        pass


def test_turkce_harfli_klasorde_oz_sinama():
    # 1.4.1'de öz sınama resmi cv2.imread ile okunuyordu: Windows'ta Türkçe
    # harfli klasörde okunamaz → bulucu kapanır (hız aracı 1.0 sahada tam
    # bunu yaşadı). Resim np.fromfile + cv2.imdecode ile okunmalı.
    d = tempfile.mkdtemp(prefix="hız-ölçüm-ğüşç-")
    shutil.copyfile(os.path.join(plaka.MODEL_DIZINI, arac.SINAMA.dosya),
                    os.path.join(d, arac.SINAMA.dosya))
    tutan = {"a": 0.0}

    class O(_SahteOturum):
        def run(self, adlar, girdiler):
            x = girdiler["images"]
            bos = float(x.max() - x.min()) < 10          # gri 110 + dolgu 114
            self._ham = _ham() if bos else _ham((10, 2, 1.0, arac.ALTIN_ARAC, (0.5, 0.5, 0.0, 0.0)))
            tutan["a"] += 0 if bos else 1
            return super().run(adlar, girdiler)

    arac.AracBulucu(O(None), _ayar(), d).oz_sinama()
    assert tutan["a"] == 1


def test_gercek_model_bos_sahne_ve_altin_deger():
    if not _ort_var():
        ATLANAN.append("gerçek araç modeli (onnxruntime kurulu değil)")
        return
    b = arac.yukle(_ayar())                              # öz sınama da koşar
    assert b.esik == 0.35 and b.gecis_esik == 0.60
    a, i = b.skor(np.full((668, 1568, 3), 110, np.uint8), None)
    assert a < 0.05 and i < 0.05, (a, i)
    import cv2
    img = cv2.imread(os.path.join(plaka.MODEL_DIZINI, arac.SINAMA.dosya))
    a, _ = b.skor(img, None)
    assert abs(a - arac.ALTIN_ARAC) < 2e-3, a
    # Kesilen köşe (x, y, en, boy) aracı örterse araç sayılmaz: sınama
    # resmindeki araç sağ üst çeyrekte (bisiklet araç sınıfı değil).
    h, w = img.shape[:2]
    a2, _ = b.skor(img, (w // 2, 0, w - w // 2, h // 2))
    assert a2 < 0.10, (a2, a)
    # 1.3.2: kutular — en güçlüsü aynı puanla, aracın yerinde (sağ üst).
    kutular, _ = b.kutular(img, None)
    assert kutular and abs(kutular[0].skor - a) < 1e-6, kutular
    k = kutular[0]
    assert (k.x1 + k.x2) / 2 > w / 2 and (k.y1 + k.y2) / 2 < h / 2, k
    # Boş sahnede kutu yok.
    assert b.kutular(np.full((668, 1568, 3), 110, np.uint8), None)[0] == []


if __name__ == "__main__":
    import kalinti
    kok = kalinti.klasor("otopark-test-arac-")        # tek klasörde (kalinti.py)
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    basarisiz: list[str] = []
    for t in testler:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            basarisiz.append(t.__name__)
            print(f"  FAIL  {t.__name__}: {type(e).__name__}: {e}")
    for a in ATLANAN:
        print(f"  ATLANDI  {a}")
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti"
          + (f", {len(ATLANAN)} atlandı" if ATLANAN else ""))
    print(f"Geçici dosyalar (silinmez, elle temizlenir): {kok}")
    sys.exit(1 if basarisiz else 0)
