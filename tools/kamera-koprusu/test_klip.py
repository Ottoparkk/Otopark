# -*- coding: utf-8 -*-
"""
1.4.3 (1d) klip kaydedici — klip.py birim testleri.

    python test_klip.py

Sahibin kararı (17.11): kırpıntı kareleri saniyede ~5, varsayılan KAPALI,
yalnızca bu bilgisayarda, 7 gün. Klip 1a'nın deneme haftası içindir: her
"sayılırdı" satırı gerçekte ne olduğuyla karşılaştırılır. Burada bir hata ya
aracı göstermeyen klip (pencere yanlış), ya adında plaka olan dosya, ya da
diski dolduran / ana döngüyü düşüren kaydedici demektir.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import cv2  # noqa: E402
import numpy as np  # noqa: E402

import gunluk  # noqa: E402
import klip  # noqa: E402

T0 = datetime(2026, 11, 18, 19, 26, 0, tzinfo=timezone.utc)     # 22:26 İstanbul
ISLEM = "ab12cd34-5678-4abc-8def-0123456789ab"


class _Kayit:
    def __init__(self):
        self.satirlar: list[str] = []

    def __call__(self, s: str) -> None:
        self.satirlar.append(s)


def _klasor() -> str:
    return tempfile.mkdtemp(prefix="otopark-test-klip-")


def _kare(en: int = 320, boy: int = 180, renk: int = 0) -> np.ndarray:
    img = np.zeros((boy, en, 3), np.uint8)
    img[:, :, 1] = renk % 256
    cv2.rectangle(img, (10, 10), (60, 60), (255, 255, 255), -1)
    return img


def _besle(k: klip.Klipci, bas: float, son: float, *, adim: float = 0.04,
           kare=None) -> None:
    """Kamera 25 kare/sn: bas..son (dahil) her kare kaydediciye verilir."""
    n = int(round((son - bas) / adim))
    for i in range(n + 1):
        m = bas + i * adim
        k.kare(kare if kare is not None else _kare(renk=i), m, T0 + timedelta(seconds=m))


def _klipler(d: str) -> list[str]:
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if f.endswith(".avi"))


def _oku(yol: str) -> tuple[int, tuple[int, int] | None]:
    """Yazılan dosyayı OpenCV gerçekten açabiliyor mu: (kare sayısı, (en, boy))."""
    cap = cv2.VideoCapture(yol)
    assert cap.isOpened(), f"açılamadı: {yol}"
    n, boyut = 0, None
    while True:
        ok, img = cap.read()
        if not ok:
            break
        n += 1
        b = (img.shape[1], img.shape[0])
        assert boyut is None or b == boyut, (boyut, b)
        boyut = b
    cap.release()
    return n, boyut


def _klipci(d: str, kay=None, **kw) -> klip.Klipci:
    return klip.Klipci(d, yaz=kay or _Kayit(), is_parcacigi=False, **kw)


# ---------------------------------------------------------------- tampon

def test_saniyede_5_kare_tutulur():
    k = _klipci(_klasor())
    _besle(k, 0.0, 10.0)                      # 251 kamera karesi
    assert 49 <= k.kare_sayisi <= 52, k.kare_sayisi


def test_70_sn_den_eski_kare_atilir():
    k = _klipci(_klasor())
    _besle(k, 0.0, 100.0, adim=0.2)
    monolar = k.tampon_monolari()
    assert min(monolar) >= 30.0 - 1e-6, min(monolar)
    assert max(monolar) >= 100.0 - 1e-6, max(monolar)
    assert 345 <= len(monolar) <= 352, len(monolar)


def test_kare_kucultulur_960():
    d = _klasor()
    k = _klipci(d)
    buyuk = _kare(1920, 1080)
    _besle(k, 0.0, 2.0, kare=buyuk)
    k.iste(0.0, 2.0, "a.avi")
    k.bosalt(2.0)
    n, boyut = _oku(os.path.join(d, "a.avi"))
    assert boyut == (960, 540), boyut
    assert n == 11, n


# ---------------------------------------------------------------- pencere

def test_pencere():
    # Araç ilk görülmeden 5 sn önce .. olaydan 5 sn sonra.
    assert klip.pencere(50.0, 60.0) == (45.0, 65.0)
    # En çok 60 sn geri: uzun kalan aracın klibi şişmez.
    assert klip.pencere(0.0, 100.0) == (40.0, 105.0)


def test_son_gelmeden_yazilmaz_gelince_yazilir():
    d = _klasor()
    kay = _Kayit()
    k = _klipci(d, kay)
    _besle(k, 0.0, 20.0)
    k.iste(5.0, 25.0, "x.avi")
    _besle(k, 20.04, 24.96)
    assert _klipler(d) == [], _klipler(d)
    _besle(k, 25.0, 25.0)
    assert _klipler(d) == ["x.avi"], _klipler(d)
    n, _ = _oku(os.path.join(d, "x.avi"))
    assert 100 <= n <= 102, n                 # 5..25 sn, saniyede 5
    assert any(gunluk.KLIP_ISARETI in s and "x.avi" in s for s in kay.satirlar), kay.satirlar


def test_bas_tampondan_once_ise_eldeki_kareler():
    d = _klasor()
    k = _klipci(d)
    _besle(k, 0.0, 8.0)
    k.iste(-30.0, 8.0, "y.avi")
    _besle(k, 8.04, 8.04)
    n, _ = _oku(os.path.join(d, "y.avi"))
    assert 40 <= n <= 42, n


def test_bosalt_hemen_yazar():
    d = _klasor()
    k = _klipci(d)
    _besle(k, 0.0, 10.0)
    k.iste(5.0, 30.0, "z.avi")
    assert _klipler(d) == []
    k.bosalt(10.0)                            # kamera koptu
    n, _ = _oku(os.path.join(d, "z.avi"))
    assert 25 <= n <= 27, n
    k.bosalt(11.0)                            # ikinci kez: yeni dosya yok
    assert _klipler(d) == ["z.avi"], _klipler(d)


def test_boyut_degisse_de_yazilir():
    d = _klasor()
    k = _klipci(d)
    _besle(k, 0.0, 2.0, kare=_kare(320, 180))
    _besle(k, 2.04, 4.0, kare=_kare(640, 480))
    k.iste(0.0, 4.0, "b.avi")
    k.bosalt(4.0)
    n, boyut = _oku(os.path.join(d, "b.avi"))
    assert boyut == (320, 180), boyut
    assert 20 <= n <= 21, n


def test_ayni_ad_ustune_yazmaz():
    d = _klasor()
    k = _klipci(d)
    _besle(k, 0.0, 2.0)
    k.iste(0.0, 2.0, "c.avi")
    k.iste(0.0, 2.0, "c.avi")
    k.bosalt(2.0)
    assert _klipler(d) == ["c.avi", "c_2.avi"], _klipler(d)


# ---------------------------------------------------------------- ad

def test_ad_bicimi_istanbul_saati():
    ad = klip.klip_adi(T0 + timedelta(seconds=5), 368, "KAPIDA_KAYBOLDU", ISLEM)
    assert ad == "2026-11-18_22-26-05_iz368_KAPIDA_KAYBOLDU_ab12cd34.avi", ad
    assert klip.klip_adi(T0, 5, "TEK_KARE", None) == \
        "2026-11-18_22-26-00_iz5_TEK_KARE_gonderimyok.avi"
    assert klip.klip_adi(T0, 5, "ESKI_GIRDI", None, emildi=True) == \
        "2026-11-18_22-26-00_iz5_ESKI_GIRDI_emildi.avi"


def test_ad_plaka_tasiyamaz():
    # Ne olay adı ne kimlik yerine plaka konabilir: yalnızca bilinen olay
    # adları ve uuid biçimindeki islem_id adın parçası olur.
    for tur, islem in (("34ABC123", ISLEM), ("TEK_KARE", "34ABC123"),
                       ("TEK_KARE", "34abc123-0000-4000-8000-000000000000x")):
        ad = klip.klip_adi(T0, 7, tur, islem)
        assert "ABC" not in ad.upper(), ad
        assert re.fullmatch(r"\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_iz7_"
                            r"(TEK_KARE|KAPIDA_KAYBOLDU|ESKI_GIRDI|OLAY)_"
                            r"([0-9a-f]{8}|gonderimyok|emildi)\.avi", ad), ad


# ---------------------------------------------------------------- temizlik

def _dosya(d: str, ad: str, gun_once: float, boyut: int = 10) -> str:
    os.makedirs(d, exist_ok=True)
    yol = os.path.join(d, ad)
    with open(yol, "wb") as f:
        f.write(b"\0" * boyut)
    t = time.time() - gun_once * 86400
    os.utime(yol, (t, t))
    return yol


def test_temizlik_7_gun():
    d = _klasor()
    _dosya(d, "eski.avi", 8)
    _dosya(d, "alti.avi", 6)
    _dosya(d, "dun.avi", 1)
    _dosya(d, "not.txt", 30)
    silinen = klip.temizle(d, time.time())
    assert sorted(os.listdir(d)) == ["alti.avi", "dun.avi", "not.txt"], os.listdir(d)
    assert silinen == 1, silinen


def test_temizlik_sinir_once_en_eski():
    d = _klasor()
    _dosya(d, "a.avi", 6, 300)
    _dosya(d, "b.avi", 1, 300)
    _dosya(d, "c.avi", 0, 300)
    klip.temizle(d, time.time(), en_cok_bayt=700)
    assert sorted(os.listdir(d)) == ["b.avi", "c.avi"], os.listdir(d)


def test_temizlik_klasor_yoksa_sessiz():
    assert klip.temizle(os.path.join(_klasor(), "yok"), time.time()) == 0


# ---------------------------------------------------------------- dayanıklılık

def test_disk_az_ise_yazilmaz():
    d = _klasor()
    kay = _Kayit()
    k = _klipci(d, kay, bos_alan=lambda yol: 1024)
    _besle(k, 0.0, 2.0)
    k.iste(0.0, 2.0, "d.avi")
    k.bosalt(2.0)
    assert _klipler(d) == [], _klipler(d)
    assert sum("diskte yer az" in s for s in kay.satirlar) == 1, kay.satirlar


def test_yazici_hatasi_ana_donguye_cikmaz():
    d = _klasor()
    kay = _Kayit()
    eski = klip._video_ac

    def bozuk(*a, **k):
        raise RuntimeError("bozuk yazıcı")
    klip._video_ac = bozuk
    try:
        k = _klipci(d, kay)
        _besle(k, 0.0, 2.0)
        k.iste(0.0, 2.0, "e.avi")
        k.bosalt(2.0)                          # yükselmemeli
    finally:
        klip._video_ac = eski
    assert any("klip yazılamadı" in s for s in kay.satirlar), kay.satirlar


def test_bos_pencere_dosya_acmaz():
    d = _klasor()
    kay = _Kayit()
    k = _klipci(d, kay)
    _besle(k, 0.0, 2.0)
    k.iste(50.0, 60.0, "f.avi")
    k.bosalt(2.0)
    assert _klipler(d) == []


def test_is_parcacigi_ile_yazar_ve_baslarken_temizler():
    d = _klasor()
    _dosya(d, "eski.avi", 9)
    kay = _Kayit()
    k = klip.Klipci(d, yaz=kay)               # gerçek kip: yazıcı iş parçacığı
    _besle(k, 0.0, 2.0)
    k.iste(0.0, 2.0, "g.avi")
    k.bosalt(2.0)
    son = time.monotonic() + 10
    while time.monotonic() < son and not any("g.avi" in s for s in kay.satirlar):
        time.sleep(0.05)
    assert _klipler(d) == ["g.avi"], _klipler(d)


def test_kurulunca_klasor_acmaz():
    d = os.path.join(_klasor(), "klipler")
    _klipci(d)
    assert not os.path.exists(d)


def test_klasor_programdata_altinda():
    eski = os.environ.get("PROGRAMDATA")
    os.environ["PROGRAMDATA"] = r"C:\PD"
    try:
        assert klip.klip_klasoru() == os.path.join(r"C:\PD", "Otopark", "klipler")
    finally:
        if eski is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski


if __name__ == "__main__":
    # Bu çalıştırmanın geçici dosyaları tek klasörde toplanır ve SİLİNMEZ
    # (sahibin kuralı: hiçbir betik bir şey silmez); yolu sonunda yazılır.
    import kalinti
    kok = kalinti.klasor("otopark-test-klip-")
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
    print(f"Geçici dosyalar (silinmez, elle temizlenir): {kok}")
    sys.exit(1 if basarisiz else 0)
