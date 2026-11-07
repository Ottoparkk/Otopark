# -*- coding: utf-8 -*-
"""
Okuma akışı (1.3.0) — okuma.py birim testleri.

    python test_okuma.py

Modeller kullanılmaz: sahte bir okuyucu, karenin sol üst pikselindeki kare
numarasına göre önceden yazılmış kutular ve okumalar döndürür. Böylece
kurallar (kesik plaka okunmaz, kesilen köşe, iki kırpıntı, oylama, ayrılış,
60 sn, bozuk okuyucu) gerçek modelden bağımsız sınanır.
"""
from __future__ import annotations

import datetime as dt
import os
import sys
import threading
import time

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import okuma  # noqa: E402
import plaka  # noqa: E402

EN, BOY = 1568, 668
T0 = dt.datetime(2026, 11, 6, 10, 0, 0, tzinfo=dt.timezone.utc)
K = plaka.Kutu
ORTA = K(600, 300, 800, 345, 0.9)          # tam plaka
KENAR = K(600, 2, 800, 40, 0.9)            # üst kenara değiyor


def _z(sn: float) -> dt.datetime:
    return T0 + dt.timedelta(seconds=sn)


def _kare(no: int) -> np.ndarray:
    k = np.zeros((BOY, EN, 3), np.uint8)
    k[0, 0, 0] = no
    return k


class SahtePlakaci:
    """bul/oku_cift: karenin numarasına göre sabit cevaplar."""

    def __init__(self, kutular=None, okumalar=None, bekle=0.0, hata=False):
        self.kutular = kutular or {}
        self.okumalar = okumalar or {}
        self.bekle = bekle
        self.hata = hata
        self.cagrilar: list[int] = []

    def bul(self, kirpik):
        no = int(kirpik[0, 0, 0])
        self.cagrilar.append(no)
        if self.bekle:
            time.sleep(self.bekle)
        if self.hata:
            raise RuntimeError("model çöktü")
        return list(self.kutular.get(no, []))

    def oku_cift(self, kirpik, k):
        no = int(kirpik[0, 0, 0])
        return list(self.okumalar.get((no, k), []))


def _gecis(gid: int = 1) -> okuma.Gecis:
    return okuma.Gecis(gid, _z(0), plaka.Oylama(k_oy=2, oran=0.6, tek_esik=0.99, m_kutu=2))


# -------------------------------------------------------------- kare işleme --

def test_kutu_okuma_yardimcilari():
    """
    kareyi_isle'nin iki adımı ayrı yardımcılardır (kutulari_bul, kutuyu_oku):
    `--plaka` test kipi kutu kutu aynı kuralları gösterir — köprü ile test
    kipi ayrışamasın.
    """
    haric = (550, 280, 300, 100)                 # ORTA'nın tamamı kesilen köşede
    p = SahtePlakaci({1: [ORTA, KENAR]},
                     {(1, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.97)],
                      (1, KENAR): [("06KZ4581", 1.0), ("06KZ4581", 1.0)]})
    assert okuma.kutulari_bul(p, _kare(1), None) == [ORTA, KENAR]
    assert okuma.kutulari_bul(p, _kare(1), haric) == [KENAR]
    # Tam ve iki kırpıntı ≥ eşik: (okumalar, (metin, en düşük)).
    okumalar, iki = okuma.kutuyu_oku(p, _kare(1), ORTA, None, 0.95)
    assert okumalar == [("34ABC123", 0.99), ("34ABC123", 0.97)] and iki == ("34ABC123", 0.97)
    # Eşik altı: okumalar döner, emin okuma yok.
    _, iki = okuma.kutuyu_oku(p, _kare(1), ORTA, None, 0.98)
    assert iki is None
    # Kesik plaka okunmaz bile (okuyucu çağrılmaz).
    assert okuma.kutuyu_oku(p, _kare(1), KENAR, None, 0.95) is None
    # Okuyucu boş döndüyse de None.
    assert okuma.kutuyu_oku(p, _kare(2), ORTA, None, 0.95) is None


def test_kare_tam_plaka_oy_olur():
    p = SahtePlakaci({1: [ORTA]}, {(1, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.97)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, None, 0.95)
    k = g.oylama.karar()
    assert k.kutulu_kare == 1
    assert g.en_iyi["34ABC123"][0] == 0.97 and int(g.en_iyi["34ABC123"][1][0, 0, 0]) == 1
    assert g.kutulu is not None and int(g.kutulu[1][0, 0, 0]) == 1


def test_kare_kesik_plaka_okunmaz():
    p = SahtePlakaci({1: [KENAR]}, {(1, KENAR): [("34ABC123", 1.0), ("34ABC123", 1.0)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, None, 0.95)
    assert g.oylama.karar().kutulu_kare == 1 and g.en_iyi == {}


def test_kare_haric_alandaki_kutu_yok_sayilir():
    haric = (550, 280, 300, 100)                 # ORTA'nın tamamı kesilen köşede
    p = SahtePlakaci({1: [ORTA]}, {(1, ORTA): [("34ABC123", 1.0), ("34ABC123", 1.0)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, haric, 0.95)
    assert g.oylama.karar().kutulu_kare == 0 and g.en_iyi == {}


def test_kare_haric_alana_degen_kutu_okunmaz_ama_sayilir():
    haric = (0, 0, 595, 400)                     # ORTA'nın soluna bitişik (pay içinde)
    p = SahtePlakaci({1: [ORTA]}, {(1, ORTA): [("34ABC123", 1.0), ("34ABC123", 1.0)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, haric, 0.95)
    assert g.oylama.karar().kutulu_kare == 1 and g.en_iyi == {}


def test_kare_anlasmayan_okuma_tahmin_olur():
    p = SahtePlakaci({1: [ORTA]}, {(1, ORTA): [("35AEU362", 0.80), ("05AEU362", 0.96)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, None, 0.95)
    okuma.kareyi_isle(p, g, _kare(1), _z(2), 2, None, 0.95)
    k = g.oylama.karar()
    assert k.eminler == [] and k.belirsiz.tahmin == "35AEU362" and g.en_iyi == {}


def test_arka_kare_oy_vermez_yalniz_okunani_saklar():
    p = SahtePlakaci({9: [ORTA]}, {(9, ORTA): [("34ABC123", 0.9), ("34ABC123", 0.85)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(9), _z(0), 0, None, 0.95, arka=True)
    assert g.oylama.karar().kutulu_kare == 0
    assert g.arka_okunan == {"34ABC123"}


def test_arka_kare_kutu_gorulduyse_isaretlenir():
    # Geçişten ÖNCE kadrajda plakalı bir araç vardı (kesik ya da okunamasa da).
    p = SahtePlakaci({9: [KENAR]}, {})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(9), _z(0), 0, None, 0.95, arka=True)
    assert g.arka_kutulu is True and g.arka_okunan == set()
    g2 = _gecis()
    okuma.kareyi_isle(SahtePlakaci({}, {}), g2, _kare(9), _z(0), 0, None, 0.95, arka=True)
    assert g2.arka_kutulu is False


def test_karar_arka_planda_arac_vardi_plakasiz_durulma_gidistir():
    # Sahada test_kopru `kuyruk` yakaladı: duran araç gidince boş şerit durulur;
    # sahne arka plandan farklı ve araç boyunda — ama plakalı araç GİTTİ, bir
    # şey DURMADI. Personele "plakasız araç" yazılmamalı.
    g = _gecis()
    g.arka_kutulu = True
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True)
    assert gonder == [], gonder
    assert any(okuma.PLAKASIZ_ISARETI in s for s in satir), satir


def test_arka_kare_zayif_okuma_sayilmaz():
    p = SahtePlakaci({9: [ORTA]}, {(9, ORTA): [("34ABC123", 0.6), ("34ABC128", 0.9)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(9), _z(0), 0, None, 0.95, arka=True)
    assert g.arka_okunan == set()


# --------------------------------------------------------- araç bulucu (1.3.1) -

class SahteArac:
    """skor: karenin numarasına göre (araç, insan) puanı; hata=True ise patlar."""

    def __init__(self, skorlar=None, hata=False, esik=0.35, gecis_esik=0.60):
        self.skorlar = skorlar or {}
        self.hata = hata
        self.esik = esik
        self.gecis_esik = gecis_esik
        self.cagrilar: list[int] = []

    def skor(self, kirpik, haric):
        no = int(kirpik[0, 0, 0])
        self.cagrilar.append(no)
        if self.hata:
            raise RuntimeError("araç modeli çöktü")
        return self.skorlar.get(no, (0.0, 0.0))


def test_kare_arac_her_karede_olculur():
    # Sahibin kararı (2026-11-07): araç bulucu HER karede çalışır — plaka
    # kutusu olan karede de (plaka bulucu bir kez araç olmayan şeyi kutuladı).
    a = SahteArac({1: (0.2, 0.9), 2: (0.7, 0.1)})
    p = SahtePlakaci({2: [ORTA]}, {(2, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.99)]})
    g = _gecis()
    okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, None, 0.95, arac_skoru=a.skor)
    okuma.kareyi_isle(p, g, _kare(2), _z(2), 2, None, 0.95, arac_skoru=a.skor)
    assert a.cagrilar == [1, 2], a.cagrilar
    assert g.arac_max == 0.7 and int(g.arac_kirpik[0, 0, 0]) == 2 and g.insan_max == 0.9
    assert g.arac_durgun is None and g.arac_arka is None
    assert g.en_iyi["34ABC123"][0] == 0.99                # plaka okuması etkilenmedi


def test_kare_durgun_ve_arka_ayri_tutulur():
    a = SahteArac({7: (0.6, 0.0), 8: (0.1, 0.8)})
    g = _gecis()
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(7), _z(0), 0, None, 0.95, arka=True,
                      arac_skoru=a.skor)
    # Geçişten ÖNCEKİ kare geçişin aracı sayılmaz.
    assert g.arac_arka == 0.6 and g.arac_max is None and g.arac_durgun is None
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(8), _z(3), 3, None, 0.95,
                      arac_skoru=a.skor, durgun=True)
    assert g.arac_durgun == 0.1 and g.arac_max == 0.1 and g.insan_max == 0.8


def test_kare_arac_olculemediyse_bilinmez():
    g = _gecis()
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(1), _z(1), 1, None, 0.95,
                      arac_skoru=lambda k, h: None, durgun=True)
    assert g.arac_max is None and g.arac_durgun is None and g.insan_max is None
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(2), _z(2), 2, None, 0.95)   # bulucu yok
    assert g.arac_max is None


def test_kare_arac_bulucuya_haric_alan_verilir():
    gorulen = []
    okuma.kareyi_isle(SahtePlakaci(), _gecis(), _kare(1), _z(1), 1, (1, 2, 3, 4), 0.95,
                      arac_skoru=lambda k, h: gorulen.append(h) or (0.0, 0.0))
    assert gorulen == [(1, 2, 3, 4)], gorulen


# ------------------------------------------------------------------ işçi ----

def test_isci_en_yeni_kare_kazanir_oncelik_once():
    p = SahtePlakaci(bekle=0.15)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))          # hemen alınır, 0.15 sn sürer
        time.sleep(0.05)
        assert not isci.bos_mu()
        isci.ver(okuma.Is(g, _kare(2), _z(2), 2))
        isci.ver(okuma.Is(g, _kare(3), _z(3), 3))          # 2'yi ezer
        isci.ver(okuma.Is(g, _kare(7), _z(0), 0), oncelik=True)
        assert isci.bekle(g, 3.0)
        assert p.cagrilar == [1, 7, 3], p.cagrilar
        assert isci.bos_mu()
    finally:
        isci.durdur()


def test_isci_bekle_zaman_asimi():
    p = SahtePlakaci(bekle=0.5)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        time.sleep(0.05)
        bas = time.monotonic()
        assert not isci.bekle(g, 0.1)
        assert time.monotonic() - bas < 0.4
        assert isci.bekle(g, 2.0)
    finally:
        isci.durdur()


def test_isci_baska_gecis_beklenmez():
    p = SahtePlakaci(bekle=0.5)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g1, g2 = _gecis(1), _gecis(2)
        isci.ver(okuma.Is(g1, _kare(1), _z(1), 1))
        time.sleep(0.05)
        bas = time.monotonic()
        assert isci.bekle(g2, 2.0)                          # g2'nin işi yok
        assert time.monotonic() - bas < 0.2
    finally:
        isci.durdur()


def test_isci_uc_hatada_bozulur():
    satirlar: list[str] = []
    p = SahtePlakaci(hata=True)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=satirlar.append)
    try:
        g = _gecis()
        for i in range(3):
            isci.ver(okuma.Is(g, _kare(i + 1), _z(i), i))
            assert isci.bekle(g, 2.0)
        assert isci.bozuk is not None and "model çöktü" in isci.bozuk
        assert sum(1 for s in satirlar if s.startswith("[!]")) == 1, satirlar
        isci.ver(okuma.Is(g, _kare(9), _z(9), 9))           # bozukken iş alınmaz
        assert isci.bos_mu() and p.cagrilar == [1, 2, 3]
    finally:
        isci.durdur()


def test_isci_hatadan_sonra_basari_sayaci_sifirlar():
    p = SahtePlakaci()
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g = _gecis()
        for hata in (True, True, False, True, True):
            p.hata = hata
            isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
            assert isci.bekle(g, 2.0)
        assert isci.bozuk is None
    finally:
        isci.durdur()


def test_isci_okuyucusuz_bozuk_baslar():
    isci = okuma.Isci(None, haric=None, oku_esik=0.95, kayit=lambda s: None, sebep="model yok")
    try:
        assert isci.bozuk == "model yok"
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        assert isci.bos_mu() and isci.bekle(g, 0.1)
    finally:
        isci.durdur()


def test_isci_takildi():
    p = SahtePlakaci(bekle=0.4)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        time.sleep(0.1)
        assert not isci.takildi(time.monotonic(), 30)
        assert isci.takildi(time.monotonic(), 0.05)
        isci.bekle(g, 2.0)
        assert not isci.takildi(time.monotonic(), 0.05)
    finally:
        isci.durdur()


def test_isci_arac_bulucuyu_calistirir_ve_esikleri_verir():
    a = SahteArac({1: (0.8, 0.0)})
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1, durgun=True), oncelik=True)
        assert isci.bekle(g, 2.0)
        assert g.arac_durgun == 0.8 and a.cagrilar == [1], (g.arac_durgun, a.cagrilar)
        assert isci.arac_esikleri() == (0.35, 0.60)
    finally:
        isci.durdur()


def test_isci_bekleme_suresi_kare_suresine_uyar():
    # 1.3.1: her kare iki model; yavaş dizüstünde durulan karenin sonucu
    # PLAKA_BEKLE_SN (0.4) içinde yetişmezse duran yaya yine kayıt açardı.
    # Karar, işçinin ölçülen kare süresinin 2.5 katı kadar bekler (en çok 2 sn).
    isci = okuma.Isci(SahtePlakaci(bekle=0.3), haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        assert isci.bekleme_suresi(0.4) == 0.4                 # henüz ölçüm yok
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        assert isci.bekle(g, 2.0)
        s = isci.bekleme_suresi(0.4)
        assert 0.7 <= s <= 1.0, s
        assert isci.bekleme_suresi(5.0) == okuma.BEKLE_TAVAN_SN  # tavan
    finally:
        isci.durdur()


def test_isci_arac_bulucusuz_esik_yok():
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        assert isci.arac_esikleri() is None
    finally:
        isci.durdur()


def test_isci_arac_hatasi_okumayi_durdurmaz():
    # Araç bulucu bozulursa plaka okuma SÜRER; bulucu kapanır ve karar
    # bugünkü (1.3.0) kurala döner — araç bulucu yüzünden araç kaybolmaz.
    satirlar: list[str] = []
    a = SahteArac(hata=True)
    p = SahtePlakaci({4: [ORTA]}, {(4, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.99)]})
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=satirlar.append, arac=a)
    try:
        g = _gecis()
        for i in range(1, 5):
            isci.ver(okuma.Is(g, _kare(i), _z(i), i))
            assert isci.bekle(g, 2.0)
        assert isci.bozuk is None
        assert isci.arac_bozuk is not None and "araç modeli çöktü" in isci.arac_bozuk
        assert isci.arac_esikleri() is None
        assert a.cagrilar == [1, 2, 3], a.cagrilar              # bozulunca çağrılmaz
        assert p.cagrilar == [1, 2, 3, 4] and "34ABC123" in g.en_iyi
        uyarilar = [s for s in satirlar if s.startswith("[!]")]
        assert len(uyarilar) == 1 and okuma.ARAC_BOZUK_ISARETI in uyarilar[0], satirlar
    finally:
        isci.durdur()


def test_isci_arac_tek_hatasi_sayaci_sifirlanir():
    a = SahteArac()
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        for hata in (True, True, False, True, True):
            a.hata = hata
            isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
            assert isci.bekle(g, 2.0)
        assert isci.arac_bozuk is None and isci.arac_esikleri() == (0.35, 0.60)
    finally:
        isci.durdur()


# ------------------------------------------------------------------ karar ---

def _oy(g: okuma.Gecis, metin: str, gorunumler, enk=0.98):
    for i in gorunumler:
        g.oylama.kutu(_z(i), i)
        g.oylama.okuma(metin, enk, _z(i), i)
        onceki = g.en_iyi.get(metin)
        if onceki is None or enk > onceki[0]:
            g.en_iyi[metin] = (enk, _kare(i))


def _karar(g, **kw):
    v = dict(durdu=False, arac_boyu=True, ayrilis_sahne=False, son_durdu_plaka=None,
             bozuk=False, son_gonderilen=[], simdi=1000.0)
    v.update(kw)
    return okuma.karar_ver(g, **v)


def test_karar_emin_plaka():
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    gonder, _satir = _karar(g)
    assert [(x.tur, x.plaka, x.zaman) for x in gonder] == [("PLAKA", "34ABC123", _z(1))]
    assert int(gonder[0].kirpik[0, 0, 0]) in (1, 2)


def test_karar_belirsiz_personele():
    g = _gecis()
    _oy(g, "34ABC123", [1], enk=0.96)
    g.oylama.kutu(_z(2), 1)
    g.kutulu = (0.8, _kare(5))
    gonder, _satir = _karar(g)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", "34ABC123", _z(1))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 5


def test_karar_duran_arac_plakasiz_personele():
    g = _gecis()
    g.durgun_kirpik = _kare(8)
    gonder, _ = _karar(g, durdu=True, arac_boyu=True)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 8


def test_karar_plakasiz_hareket_gonderilmez():
    g = _gecis()
    assert _karar(g, durdu=False)[0] == []                 # geçip giden (yaya, gölge)
    assert _karar(g, durdu=True, arac_boyu=False)[0] == []  # duran ama küçük
    _gonder, satir = _karar(g)
    assert any(okuma.PLAKASIZ_ISARETI in s for s in satir), satir


def test_karar_ayrilis_personele_bir_sey_yazmaz():
    g = _gecis()
    g.oylama.kutu(_z(1), 1); g.oylama.kutu(_z(2), 2)        # belirsiz olurdu
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, ayrilis_sahne=True, durdu=True)
    assert gonder == [] and any(okuma.AYRILIS_ISARETI in s for s in satir), satir


def test_karar_ayrilis_gonderilen_plakayi_bastirir_digerini_gonderir():
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    _oy(g, "06KZ4581", [3, 4])
    gonder, _ = _karar(g, ayrilis_sahne=True, son_durdu_plaka="34ABC12")   # bir karakter fark
    assert [x.plaka for x in gonder] == ["06KZ4581"]


def test_karar_arka_planda_gonderilen_plaka_ayrilistir():
    # Işık değişti, sahne benzemiyor — ama geçişten ÖNCEKİ durgun karede
    # gönderilmiş plaka okunuyordu: bu, duran aracın gidişi.
    g = _gecis()
    g.arka_okunan = {"34ABC123"}
    _oy(g, "34ABC123", [1, 2])
    g.oylama.kutu(_z(3), 3)
    assert _karar(g, son_durdu_plaka="34ABC123")[0] == []


def test_karar_altmis_saniye_ayni_plaka():
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    assert _karar(g, son_gonderilen=[("34ABC123", 950.0)], simdi=1000.0)[0] == []
    assert _karar(g, son_gonderilen=[("34ABC128", 950.0)], simdi=1000.0)[0] == []
    assert len(_karar(g, son_gonderilen=[("34ABC123", 930.0)], simdi=1000.0)[0]) == 1


def test_karar_altmis_saniye_belirsiz_tahmin_de():
    g = _gecis()
    _oy(g, "34ABC123", [1], enk=0.96)
    g.oylama.kutu(_z(2), 1)
    assert _karar(g, son_gonderilen=[("34ABC123", 990.0)], simdi=1000.0)[0] == []


def test_karar_bozuk_okuyucu():
    g = _gecis()
    g.durgun_kirpik = _kare(4)
    gonder, _ = _karar(g, bozuk=True, arac_boyu=True)
    assert [(x.tur, x.tahmin) for x in gonder] == [("OKUNAMADI", None)]
    assert _karar(g, bozuk=True, arac_boyu=False)[0] == []           # yaya personeli boğmasın
    assert _karar(g, bozuk=True, arac_boyu=True, ayrilis_sahne=True)[0] == []


ESIK = dict(arac_esik=0.35, arac_gecis_esik=0.60)


def _arac(g: okuma.Gecis, durgun=None, enb=None, arka=None, insan=None, kirpik=None):
    g.arac_durgun, g.arac_max, g.arac_arka, g.insan_max = durgun, enb, arka, insan
    g.arac_kirpik = kirpik
    return g


def test_karar_duran_ama_arac_gorulmedi_gonderilmez():
    # Sahada 2026-11-07 (1.3.0'ın ilk günü): kameranın önünde DURAN iki kişi
    # araç boyunda sayıldı ve "Çözülmemiş kayıt" oldu.
    g = _arac(_gecis(), durgun=0.10, enb=0.27, arka=0.02, insan=0.91)
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert gonder == [], gonder
    assert any(okuma.PLAKASIZ_ISARETI in s and okuma.ARAC_YOK_ISARETI in s for s in satir), satir


def test_karar_duran_arac_gorulduyse_personele():
    g = _arac(_gecis(), durgun=0.80, enb=0.80, arka=0.0)
    g.durgun_kirpik = _kare(8)
    gonder, _ = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 8
    # Durulan karede araç zayıf ama geçişte NET bir araç vardı ve geçişten
    # önce yoktu (ör. gece): yine personele — önce araç kaybolmasın.
    g = _arac(_gecis(), durgun=0.10, enb=0.85, arka=0.02)
    g.durgun_kirpik = _kare(8)
    assert [x.tur for x in _karar(g, durdu=True, arac_boyu=True, **ESIK)[0]] == ["OKUNAMADI"]
    # ... ama o araç geçişten ÖNCE de oradaysa (park etmiş araç) bu geçişin
    # aracı değildir.
    g = _arac(_gecis(), durgun=0.10, enb=0.85, arka=0.70)
    g.durgun_kirpik = _kare(8)
    assert _karar(g, durdu=True, arac_boyu=True, **ESIK)[0] == []


def test_karar_duran_arac_bilinmiyorsa_bugunku_kural():
    # Durulan kare ölçülemedi (işçi yetişmedi): 1.3.0 kuralı — personele, ve
    # sahada teşhis için kayda yazılır.
    g = _arac(_gecis(), durgun=None, enb=0.10, arka=0.0)
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert [x.tur for x in gonder] == ["OKUNAMADI"]
    assert any(okuma.ARAC_YETISMEDI_ISARETI in s for s in satir), satir
    # Araç bulucu yok / bozuk (eşik verilmedi): ölçüm ne derse desin 1.3.0 kuralı.
    g = _arac(_gecis(), durgun=0.0, enb=0.0, arka=0.0)
    g.durgun_kirpik = _kare(8)
    assert [x.tur for x in _karar(g, durdu=True, arac_boyu=True)[0]] == ["OKUNAMADI"]


def test_karar_gecen_plakasiz_arac_personele():
    # Sahibin kararı (2026-11-07): durmadan geçen ve plakası hiç okunamayan
    # ARAÇ da personele (1.3.0'da sessizce düşüyordu). Fotoğraf = aracın en
    # iyi görüldüğü kare, son kare değil (araç gitmiş olabilir).
    g = _arac(_gecis(), enb=0.85, arka=0.02, insan=0.1, kirpik=_kare(6))
    g.son_kirpik = _kare(9)
    gonder, satir = _karar(g, durdu=False, arac_boyu=True, **ESIK)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 6
    assert any(okuma.PLAKASIZ_ARAC_ISARETI in s for s in satir), satir
    # "Plakasız hareket" sayılmaz: durum'da iki kez sayılmasın.
    assert not any(okuma.PLAKASIZ_ISARETI in s for s in satir), satir


def test_karar_gecen_arac_her_kosul_gerekli():
    tamam = dict(enb=0.85, arka=0.02)
    durumlar = [
        ("zayıf araç (gölge, kenar parçası)", dict(enb=0.50, arka=0.02), {}),
        ("araç ölçülmedi", dict(enb=None, arka=0.02), {}),
        ("arka plan ölçülmedi", dict(enb=0.85, arka=None), {}),
        ("araç geçişten önce de oradaydı", dict(enb=0.85, arka=0.70), {}),
        ("hareket küçük", tamam, dict(arac_boyu=False)),
        ("önceki karede plakalı araç vardı (gidiş)", tamam, dict(arka_kutulu=True)),
        ("gönderilmiş aracın ayrılışı", tamam, dict(ayrilis_sahne=True)),
        ("araç bulucu yok / bozuk", tamam, dict(esiksiz=True)),
    ]
    for ad, alan, ek in durumlar:
        g = _arac(_gecis(), **alan)
        g.arka_kutulu = ek.pop("arka_kutulu", False)
        esik = {} if ek.pop("esiksiz", False) else ESIK
        gonder, _ = _karar(g, durdu=False, **{"arac_boyu": True, **ek, **esik})
        assert gonder == [], f"{ad}: {gonder}"


def test_karar_arac_bulucu_plakayi_engellemez():
    # Emin plaka da belirsiz plaka da araç bulucunun puanına BAKMAZ.
    g = _arac(_gecis(), durgun=0.0, enb=0.0, arka=0.0)
    _oy(g, "34ABC123", [1, 2])
    gonder, _ = _karar(g, durdu=True, **ESIK)
    assert [(x.tur, x.plaka) for x in gonder] == [("PLAKA", "34ABC123")]
    g = _arac(_gecis(), durgun=0.0, enb=0.0, arka=0.0)
    _oy(g, "34ABC123", [1], enk=0.96)
    g.oylama.kutu(_z(2), 1)
    gonder, _ = _karar(g, durdu=True, **ESIK)
    assert [(x.tur, x.tahmin) for x in gonder] == [("OKUNAMADI", "34ABC123")]


def test_karar_bozuk_okuyucu_arac_bulucuya_bakmaz():
    # Okuyucu bozukken işçi iş almaz, araç bulucu da çalışmaz: 1.3.0 kuralı.
    g = _arac(_gecis(), durgun=0.0, enb=0.0, arka=0.0)
    g.durgun_kirpik = _kare(4)
    assert [x.tur for x in _karar(g, bozuk=True, arac_boyu=True, **ESIK)[0]] == ["OKUNAMADI"]


def test_karar_iki_arac_sirayla():
    g = _gecis()
    _oy(g, "06KZ4581", [3, 4])
    _oy(g, "34ABC123", [1, 2])
    gonder, _ = _karar(g)
    assert [x.plaka for x in gonder] == ["34ABC123", "06KZ4581"] or \
        [x.zaman for x in gonder] == sorted(x.zaman for x in gonder)


def test_karar_satirlarinda_plaka_yok():
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    _oy(g, "06KZ4581", [3], enk=0.96)
    g.oylama.kutu(_z(9), 9)
    _gonder, satirlar = _karar(g)
    for s in satirlar:
        assert "34ABC123" not in s and "06KZ4581" not in s, s


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
