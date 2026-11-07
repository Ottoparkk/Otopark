# -*- coding: utf-8 -*-
"""
Gönderilecek araçlar kutusu (1.3.0) — giden.py birim testleri.

    python test_giden.py

İnternet kesilince araç KAYBOLMAMALI: her araç gönderilmeden ÖNCE diske
yazılır ve sunucu KESİN bir cevap verene kadar orada kalır. Burada bir hata ya
kaybolan araç (bilet yok) ya da aynı aracın sırası bozulmuş iki olayı (çıkış
girişten önce) demektir.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import giden  # noqa: E402


class _Kayit:
    def __init__(self):
        self.satirlar: list[str] = []

    def __call__(self, s: str) -> None:
        self.satirlar.append(s)


def _klasor() -> str:
    return tempfile.mkdtemp(prefix="otopark-test-giden-")


def _olay(i: int) -> dict:
    return {"islem_id": f"00000000-0000-4000-8000-{i:012d}", "zaman": f"2026-11-06T10:00:{i:02d}Z",
            "yon": "ORTAK", "cihaz": "kopru-ortak", "plaka": "34ABC123"}


def test_yaz_sirali_ve_atomik():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    for i in range(3):
        assert k.yaz(_olay(i)) is not None
    assert [o["islem_id"] for _y, o in k.hepsi()] == [_olay(i)["islem_id"] for i in range(3)]
    assert not [f for f in os.listdir(d) if f.endswith(".tmp")]
    yol, olay = k.ilk()
    assert olay == _olay(0) and os.path.basename(yol).endswith(_olay(0)["islem_id"] + ".json")
    k.sil(yol)
    assert k.ilk()[1] == _olay(1)
    assert k.sayi() == 2


def test_yeniden_baslayinca_sira_devam_eder():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    k.yaz(_olay(0)); k.yaz(_olay(1))
    k2 = giden.Giden(d, kayit=_Kayit())          # köprü yeniden başladı
    k2.yaz(_olay(2))
    assert [o["islem_id"] for _y, o in k2.hepsi()] == [_olay(i)["islem_id"] for i in range(3)]


def test_dolu_kutu_alarm_ama_yazar():
    d = _klasor()
    kay = _Kayit()
    k = giden.Giden(d, en_cok=3, kayit=kay)
    for i in range(4):
        assert k.yaz(_olay(i)) is not None       # ASLA sessizce düşürmez
    assert k.sayi() == 4
    assert any(s.startswith("[!]") and giden.DOLU_ISARETI in s for s in kay.satirlar), kay.satirlar


def test_bozuk_dosya_ayrilir_silinmez():
    d = _klasor()
    kay = _Kayit()
    k = giden.Giden(d, kayit=kay)
    k.yaz(_olay(0))
    bozuk = os.path.join(d, "000000000000-bozuk.json")
    with open(bozuk, "w", encoding="utf-8") as f:
        f.write("{yarım")
    k.yaz(_olay(1))
    # Bozuk dosya sırayı tıkamaz; .bozuk olarak YERİNDE kalır (insan baksın).
    assert [o["islem_id"] for _y, o in k.hepsi()] == [_olay(0)["islem_id"], _olay(1)["islem_id"]]
    assert os.path.exists(bozuk + ".bozuk") and not os.path.exists(bozuk)
    assert any(s.startswith("[!]") and "bozuk" in s for s in kay.satirlar), kay.satirlar


def test_yazilamazsa_none():
    # Kutu klasörü açılamıyor (disk, izin...): yerinde aynı adda bir DOSYA var.
    # Köprü düşmez, yaz() None döner ve söyler. (Test hiçbir şey silmez: yol
    # baştan böyle kurulur.)
    d = os.path.join(_klasor(), "giden-giris")
    with open(d, "w") as f:
        f.write("x")
    kay = _Kayit()
    k = giden.Giden(d, kayit=kay)
    assert k.yaz(_olay(0)) is None
    assert any(s.startswith("[!]") and giden.YAZILAMADI_ISARETI in s for s in kay.satirlar)


def test_ozet():
    d = _klasor()
    assert giden.ozet(d) == (0, None)
    k = giden.Giden(d, kayit=_Kayit())
    k.yaz(_olay(5)); k.yaz(_olay(7))
    assert giden.ozet(d) == (2, "2026-11-06T10:00:05Z")
    assert giden.ozet(os.path.join(d, "yok")) == (0, None)


# ------------------------------------------------------------- gönderici ---

def _calistir(k: giden.Giden, cevaplar: list[str], en_cok_tur: int = 50):
    """Sahte gönderimle döngüyü çalıştırır; (gönderilenler, beklemeler)."""
    gonderilen: list[str] = []
    beklemeler: list[float] = []
    sira = list(cevaplar)

    def gonder(olay: dict) -> str:
        gonderilen.append(olay["islem_id"])
        return sira.pop(0) if sira else giden.TAMAM

    tur = {"n": 0}

    def dur() -> bool:
        tur["n"] += 1
        return k.sayi() == 0 or tur["n"] > en_cok_tur

    giden.calistir(k, gonder, uyu=beklemeler.append, ara=beklemeler.append, dur=dur)
    return gonderilen, beklemeler


def test_kesin_cevapta_silinir_sirayla():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    for i in range(3):
        k.yaz(_olay(i))
    gonderilen, beklemeler = _calistir(k, [giden.TAMAM, giden.RED, giden.TAMAM])
    assert gonderilen == [_olay(i)["islem_id"] for i in range(3)]
    assert k.sayi() == 0
    # Birikmiş kayıtlar arasında hız sınırına göre aralık (sonuncudan sonra yok).
    assert beklemeler == [giden.ARA_SN, giden.ARA_SN], beklemeler


def test_gecici_hatada_kalir_ve_sirayi_korur():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    k.yaz(_olay(0)); k.yaz(_olay(1))
    gonderilen, beklemeler = _calistir(
        k, [giden.TEKRAR, giden.TEKRAR, giden.TEKRAR, giden.TAMAM, giden.TAMAM])
    # İlk araç gitmeden ikincisi DENENMEZ (çıkış girişten önce gitmesin).
    assert gonderilen == [_olay(0)["islem_id"]] * 4 + [_olay(1)["islem_id"]], gonderilen
    assert beklemeler[:3] == [1, 2, 4] and beklemeler[3] == giden.ARA_SN, beklemeler
    assert k.sayi() == 0


def test_bekleme_tavani():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    k.yaz(_olay(0))
    _gonderilen, beklemeler = _calistir(k, [giden.TEKRAR] * 9 + [giden.TAMAM])
    assert beklemeler == [1, 2, 4, 8, 16, 32, 60, 60, 60], beklemeler


def test_gonderim_istisnasi_dongu_olmez():
    d = _klasor()
    kay = _Kayit()
    k = giden.Giden(d, kayit=kay)
    k.yaz(_olay(0))
    cagri = {"n": 0}

    def gonder(olay):
        cagri["n"] += 1
        if cagri["n"] == 1:
            raise RuntimeError("beklenmedik")
        return giden.TAMAM

    giden.calistir(k, gonder, uyu=lambda s: None, ara=lambda s: None,
                   dur=lambda: k.sayi() == 0)
    assert cagri["n"] == 2 and k.sayi() == 0
    assert any(s.startswith("[!]") and "beklenmedik" in s for s in kay.satirlar), kay.satirlar


def test_uyandir_beklemeyi_keser():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    bas = time.monotonic()
    threading.Timer(0.2, k.uyandir).start()
    k.bekle(10)
    assert time.monotonic() - bas < 3


def test_bos_kutuda_bekler():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    beklemeler: list[float] = []
    tur = {"n": 0}

    def dur():
        tur["n"] += 1
        return tur["n"] > 2

    giden.calistir(k, lambda o: giden.TAMAM, uyu=beklemeler.append,
                   ara=beklemeler.append, dur=dur)
    assert beklemeler == [giden.BOS_BEKLEME_SN, giden.BOS_BEKLEME_SN], beklemeler


def test_dosya_icerigi_json():
    d = _klasor()
    k = giden.Giden(d, kayit=_Kayit())
    yol = k.yaz(_olay(3))
    with open(yol, encoding="utf-8") as f:
        assert json.load(f) == _olay(3)


if __name__ == "__main__":
    # Bu çalıştırmanın geçici dosyaları tek klasörde toplanır ve SİLİNMEZ
    # (sahibin kuralı: hiçbir betik bir şey silmez); yolu sonunda yazılır.
    kok = tempfile.mkdtemp(prefix="otopark-test-giden-")
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
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti")
    print(f"Geçici dosyalar (silinmez, elle temizlenir): {kok}")
    sys.exit(1 if basarisiz else 0)
