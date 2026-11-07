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
    for m in (arac.MODEL, arac.SINAMA):
        yol = os.path.join(plaka.MODEL_DIZINI, m.dosya)
        assert os.path.isfile(yol), yol
        assert plaka.sha256_dosya(yol) == m.sha256, m.dosya


def _dizin(*bozuk_dosyalar: str, eksik: str | None = None) -> str:
    d = tempfile.mkdtemp(prefix="otopark-test-arac-")
    for m in (arac.MODEL, arac.SINAMA):
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


def test_yukle_eksik_dosya():
    for m in (arac.MODEL, arac.SINAMA):
        try:
            arac.yukle(_ayar(), dizin=_dizin(eksik=m.dosya))
            raise AssertionError("eksik dosyayla yüklendi")
        except plaka.PlakaHatasi as e:
            assert "bulunamadı" in str(e) and m.dosya in str(e), e


def test_yukle_bozuk_dosya():
    for m in (arac.MODEL, arac.SINAMA):
        try:
            arac.yukle(_ayar(), dizin=_dizin(m.dosya))
            raise AssertionError("bozuk dosyayla yüklendi")
        except plaka.PlakaHatasi as e:
            assert "doğrulanamadı" in str(e) and m.dosya in str(e), e


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

    def __init__(self, ham):
        self._ham = ham

    def get_inputs(self):
        class G:
            name = "images"
        return [G()]

    def run(self, _adlar, girdiler):
        assert list(girdiler) == ["images"] and girdiler["images"].shape == (1, 3, N, N)
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


if __name__ == "__main__":
    kok = tempfile.mkdtemp(prefix="otopark-test-arac-")
    tempfile.tempdir = kok
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
