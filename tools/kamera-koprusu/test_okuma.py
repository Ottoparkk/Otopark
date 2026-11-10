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

import gunluk  # noqa: E402
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


# --------------------------------------------- 1.3.4: tam çözünürlükten okuma -

class KayitliOkuyucu:
    """Okuyucunun HANGİ resimden HANGİ kutuyu okuduğunu kaydeder."""

    def __init__(self, kutular):
        self.kutular = list(kutular)
        self.okunan: list = []

    def bul(self, kirpik):
        return list(self.kutular)

    def oku_cift(self, img, k):
        self.okunan.append((img.shape[:2], k))
        return [("34ABC123", 0.99), ("34ABC123", 0.99)]


TAM_BOY, TAM_EN = 891, 2124        # sahadaki kırpıntı 2124 px → 1568'e küçülür


def _tam() -> np.ndarray:
    return np.zeros((TAM_BOY, TAM_EN, 3), np.uint8)


def test_kutuyu_oku_tam_cozunurlukten():
    # Sahada 2026-11-07: 2124 px'lik kırpıntı 1568'e küçülüyor, kare plakanın
    # küçük harfleri ("35CDJ06") emin okunamıyordu. Kutu küçük kırpıntıda
    # bulunur, plaka TAM çözünürlükten okunur (kutu gerçek oranla taşınır).
    p = KayitliOkuyucu([ORTA])
    sonuc = okuma.kutuyu_oku(p, _kare(1), ORTA, None, 0.95, tam=_tam())
    assert sonuc is not None and sonuc[1] == ("34ABC123", 0.99), sonuc
    assert p.okunan == [((TAM_BOY, TAM_EN), plaka.kutu_olcekle(ORTA, TAM_EN / EN, TAM_BOY / BOY))]
    # Kenar kuralı KÜÇÜK kırpıntının koordinatlarında: kesik kutu okunmaz bile.
    p = KayitliOkuyucu([KENAR])
    assert okuma.kutuyu_oku(p, _kare(1), KENAR, None, 0.95, tam=_tam()) is None and p.okunan == []
    # Tam çözünürlük verilmediyse 1.3.3 ile aynı: küçük kırpıntıdan okunur.
    p = KayitliOkuyucu([ORTA])
    okuma.kutuyu_oku(p, _kare(1), ORTA, None, 0.95)
    assert p.okunan == [((BOY, EN), ORTA)], p.okunan


def test_kare_tam_cozunurluk_her_karede_kullanilir():
    # Geçişin karesi de, geçişten önceki kare de tam çözünürlükten okunur.
    for arka in (False, True):
        p = KayitliOkuyucu([ORTA])
        g = _gecis()
        okuma.kareyi_isle(p, g, _kare(1), _z(1), 1, None, 0.95, arka=arka, tam=_tam())
        assert [s for s, _ in p.okunan] == [(TAM_BOY, TAM_EN)], (arka, p.okunan)
    assert g.arka_okunan == {"34ABC123"}


def test_isci_tam_cozunurlugu_plaka_parcacigina_iletir():
    p = KayitliOkuyucu([ORTA])
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(9), _z(0), 0, arka=True, tam=_tam()), oncelik=True)
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1, tam=_tam()))
        assert isci.bekle(g, 2.0)
        isci.ver(okuma.Is(g, _kare(2), _z(2), 2, durgun=True, tam=_tam()), oncelik=True)
        assert isci.bekle(g, 2.0)
        assert [s for s, _ in p.okunan] == [(TAM_BOY, TAM_EN)] * 3, p.okunan
    finally:
        isci.durdur()


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

def _ak(x1, y1, x2, y2, skor):
    import arac
    return arac.AracKutu(float(x1), float(y1), float(x2), float(y2), float(skor))


# 1.3.2: "önce de vardı" kontrolü YERE bakar. Kırpıntı 1568×668.
PARK = (1000, 500, 1500, 660)        # hep orada duran araç
UZAK = (0, 200, 160, 400)            # yavaş gelen aracın "geçişten önceki" karedeki yeri
YAKIN = (400, 150, 1100, 600)        # aynı araç, yaklaşınca


class SahteArac:
    """kutular: karenin numarasına göre (araç kutuları, insan puanı); hata=True ise patlar."""

    def __init__(self, kutular=None, hata=False, esik=0.35, gecis_esik=0.60, bekle=0.0):
        self.olcumler = kutular or {}
        self.hata = hata
        self.esik = esik
        self.gecis_esik = gecis_esik
        self.bekle = bekle
        self.cagrilar: list[int] = []

    def kutular(self, kirpik, haric):
        no = int(kirpik[0, 0, 0])
        self.cagrilar.append(no)
        if self.bekle:
            time.sleep(self.bekle)
        if self.hata:
            raise RuntimeError("araç modeli çöktü")
        kutular, insan = self.olcumler.get(no, ([], 0.0))
        return [_ak(*k) for k in kutular], insan


def _isle(g, no, a, p=None, **kw):
    okuma.kareyi_isle(p or SahtePlakaci(), g, _kare(no), _z(no), no, kw.pop("haric", None),
                      0.95, arac_kutulari=a.kutular, **kw)


def test_kare_arac_her_karede_olculur():
    # Sahibin kararı (2026-11-07): araç bulucu HER karede çalışır — plaka
    # kutusu olan karede de (plaka bulucu bir kez araç olmayan şeyi kutuladı).
    a = SahteArac({9: ([], 0.0), 1: ([YAKIN + (0.2,)], 0.9), 2: ([YAKIN + (0.7,)], 0.1)})
    p = SahtePlakaci({2: [ORTA]}, {(2, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.99)]})
    g = _gecis()
    _isle(g, 9, a, arka=True)
    _isle(g, 1, a, p)
    _isle(g, 2, a, p)
    assert a.cagrilar == [9, 1, 2], a.cagrilar
    assert g.arac_max == 0.7 and int(g.arac_kirpik[0, 0, 0]) == 2 and g.insan_max == 0.9
    assert g.arac_durgun is None and g.arka_araclar == []
    assert g.en_iyi["34ABC123"][0] == 0.99                # plaka okuması etkilenmedi


def test_kare_park_etmis_arac_yeni_sayilmaz():
    # Geçişten önce de AYNI YERDE duran araç bu geçişin aracı değil; yanında
    # beliren araç yenidir.
    park2 = (1010, 505, 1505, 662)                        # aynı araç, kutu biraz oynadı
    a = SahteArac({9: ([PARK + (0.47,)], 0.0),
                   1: ([park2 + (0.48,), YAKIN + (0.92,)], 0.0),
                   2: ([park2 + (0.49,)], 0.9),
                   3: ([park2 + (0.47,)], 0.8)})
    g = _gecis()
    _isle(g, 9, a, arka=True)
    assert len(g.arka_araclar) == 1 and g.arac_max is None
    _isle(g, 1, a)
    _isle(g, 2, a)
    assert g.arac_max == 0.92 and int(g.arac_kirpik[0, 0, 0]) == 1, g.arac_max
    _isle(g, 3, a, durgun=True)
    assert g.arac_durgun == 0.0 and g.insan_max == 0.9   # durulan karede YENİ araç yok


def test_kare_yavas_gelen_arac_yeni_sayilir():
    # Sahada 2026-11-07: yavaş gelen araç "geçişten önceki" kareye uzaktayken
    # girdi. Yaklaşınca başka YERDE: yenidir.
    a = SahteArac({9: ([UZAK + (0.45,)], 0.0), 1: ([YAKIN + (0.92,)], 0.0)})
    g = _gecis()
    _isle(g, 9, a, arka=True)
    _isle(g, 1, a)
    assert g.arac_max == 0.92, g.arac_max


def test_kare_biraz_ilerleyen_buyuk_arac_yeni_sayilir():
    # Büyük araç kırpıntının çoğunu kaplar: boyunun %30'u kadar ilerlemiş
    # araçla önceki kutu yine ~%54 örtüşür. Gerçek fotoğraflarda (Faz 0
    # yeniden oynatma) farklı yerlerdeki iki araç 0.48 örtüştü. Park etmiş
    # aracın kutusu kareden kareye ~0.9 örtüşür: "aynı araç" eşiği 0.7.
    a = SahteArac({9: ([(0, 0, 1000, 400, 0.9)], 0.0), 1: ([(300, 0, 1300, 400, 0.9)], 0.0)})
    g = _gecis()
    _isle(g, 9, a, arka=True)
    _isle(g, 1, a)
    assert g.arac_max == 0.9, g.arac_max


def test_kare_onceki_kare_olculmeden_bilinmez():
    # Önceki kare henüz ölçülmediyse (ya da geçişin önceki karesi yoksa) ne
    # yeni olduğu bilinemez: sayılmaz, karar 1.3.0 kuralına döner.
    a = SahteArac({1: ([YAKIN + (0.92,)], 0.0)})
    g = _gecis()
    _isle(g, 1, a, durgun=True)
    assert g.arka_araclar is None and g.arac_max is None and g.arac_durgun is None
    g = _gecis()
    _isle(g, 9, a, arka=True)                              # ölçüldü, araç yok
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(1), _z(1), 1, None, 0.95,
                      arac_kutulari=lambda k, h: None, durgun=True)   # bulucu ölçemedi
    assert g.arac_max is None and g.arac_durgun is None and g.insan_max is None
    okuma.kareyi_isle(SahtePlakaci(), g, _kare(2), _z(2), 2, None, 0.95)   # bulucu yok
    assert g.arac_max is None


def test_kare_onceki_karedeki_plaka_kutulari_sayilir():
    # Teşhis için: geçişten önceki karede kaç plaka kutusu vardı (kayıt satırı).
    g = _gecis()
    okuma.kareyi_isle(SahtePlakaci({9: [ORTA, KENAR]}, {}), g, _kare(9), _z(0), 0, None, 0.95,
                      arka=True)
    assert g.arka_kutulu is True and g.arka_plaka_sayisi == 2


def test_kare_arac_bulucuya_haric_alan_verilir():
    gorulen = []
    okuma.kareyi_isle(SahtePlakaci(), _gecis(), _kare(1), _z(1), 1, (1, 2, 3, 4), 0.95,
                      arac_kutulari=lambda k, h: gorulen.append(h) or ([], 0.0))
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
    a = SahteArac({9: ([], 0.0), 1: ([YAKIN + (0.8,)], 0.0)})
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(9), _z(0), 0, arka=True), oncelik=True)
        assert isci.bekle(g, 2.0)
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1, durgun=True), oncelik=True)
        assert isci.bekle(g, 2.0)
        assert g.arac_durgun == 0.8 and a.cagrilar == [9, 1], (g.arac_durgun, a.cagrilar)
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


def test_isci_iki_model_paralel_calisir():
    # 1.3.3: sahadaki dizüstünde bir kare, plaka okuyucu SONRA araç bulucu
    # sırayla çalışınca 410 ms sürüyordu (~2.4 kare/sn): geçen plakaya 3-4
    # şans. İki model ayrı iş parçacığında, AYNI ANDA çalışır.
    p = SahtePlakaci(bekle=0.3)
    a = SahteArac(bekle=0.3)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        bas = time.monotonic()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        assert isci.bekle(g, 3.0)
        gecen = time.monotonic() - bas
        assert p.cagrilar == [1] and a.cagrilar == [1]
        assert gecen < 0.5, gecen                      # sırayla olsaydı ≥ 0.6
    finally:
        isci.durdur()


def test_isci_yavas_arac_bulucu_plakayi_bekletmez():
    # Plaka okuyucu boşalınca yeni kare alır; araç bulucu yavaşsa EN YENİ
    # kareye atlar — plaka okuma onun yüzünden hiçbir kareyi kaçırmaz.
    p = SahtePlakaci(bekle=0.02)
    a = SahteArac(bekle=0.4)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        for i in range(1, 7):
            bitis = time.monotonic() + 2.0
            while not isci.bos_mu() and time.monotonic() < bitis:
                time.sleep(0.005)
            isci.ver(okuma.Is(g, _kare(i), _z(i), i))
        assert isci.bekle(g, 5.0)
        assert p.cagrilar == [1, 2, 3, 4, 5, 6], p.cagrilar
        assert a.cagrilar[0] == 1 and a.cagrilar[-1] == 6 and len(a.cagrilar) < 6, a.cagrilar
    finally:
        isci.durdur()


def test_isci_bekle_iki_modeli_de_bekler():
    # Karar, araç bulucunun durulan kare sonucunu da beklemeli.
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None,
                      arac=SahteArac(bekle=0.4))
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1, durgun=True), oncelik=True)
        time.sleep(0.05)
        assert not isci.bekle(g, 0.1)                  # plaka bitti, araç sürüyor
        assert isci.bekle(g, 2.0)
    finally:
        isci.durdur()


def test_isci_bekleme_suresi_yavas_modele_gore():
    isci = okuma.Isci(SahtePlakaci(bekle=0.02), haric=None, oku_esik=0.95, kayit=lambda s: None,
                      arac=SahteArac(bekle=0.3))
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        assert isci.bekle(g, 2.0)
        assert 0.7 <= isci.bekleme_suresi(0.4) <= 1.0, isci.bekleme_suresi(0.4)
    finally:
        isci.durdur()


def test_isci_takildi_arac_bulucuyu_da_gorur():
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None,
                      arac=SahteArac(bekle=0.4))
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))
        time.sleep(0.1)
        assert isci.takildi(time.monotonic(), 0.05)    # plaka bitti, araç bulucu sürüyor
        isci.bekle(g, 2.0)
        assert not isci.takildi(time.monotonic(), 0.05)
    finally:
        isci.durdur()


def test_isci_iki_oncelikli_is_sirayla():
    # Geçişten önceki kare ve durulan kare ikisi de öncelikli; çok kısa bir
    # geçişte durulan kare, henüz işlenmemiş önceki kareyi EZMEMELİ (ezseydi
    # araç bulucu "yeni araç" bilemez, 1.3.0 kuralına düşerdi).
    p = SahtePlakaci(bekle=0.15)
    a = SahteArac(bekle=0.15)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        g = _gecis()
        isci.ver(okuma.Is(g, _kare(1), _z(1), 1))                       # sürüyor
        time.sleep(0.05)
        isci.ver(okuma.Is(g, _kare(7), _z(0), 0, arka=True), oncelik=True)
        isci.ver(okuma.Is(g, _kare(8), _z(2), 2, durgun=True), oncelik=True)
        assert isci.bekle(g, 3.0)
        assert p.cagrilar == [1, 7, 8], p.cagrilar
        assert a.cagrilar == [1, 7, 8], a.cagrilar
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


def _arac(g: okuma.Gecis, durgun=None, enb=None, arka=(), insan=None, kirpik=None):
    """Geçişin ölçülmüş hâli: `durgun` / `enb` YENİ araç puanları, `arka` önceki karedeki kutular
    (None = önceki kare ölçülmedi)."""
    g.arac_durgun, g.arac_max, g.insan_max = durgun, enb, insan
    g.arka_araclar = None if arka is None else [_ak(*k) for k in arka]
    g.arac_kirpik = kirpik
    return g


def test_karar_duran_ama_arac_gorulmedi_gonderilmez():
    # Sahada 2026-11-07 (1.3.0'ın ilk günü): kameranın önünde DURAN iki kişi
    # araç boyunda sayıldı ve "Çözülmemiş kayıt" oldu.
    g = _arac(_gecis(), durgun=0.0, enb=0.27, insan=0.91)
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert gonder == [], gonder
    assert any(okuma.PLAKASIZ_ISARETI in s and okuma.ARAC_YOK_ISARETI in s for s in satir), satir


def test_karar_park_etmis_arac_yaninda_duran_yaya_gonderilmez():
    # Park etmiş araç kadrajda; yanında insan duruyor: durulan karede YENİ
    # araç yok (kareyi_isle park etmiş aracı saymadı) → hiçbir şey.
    g = _arac(_gecis(), durgun=0.0, enb=0.0, arka=[PARK + (0.47,)], insan=0.9)
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert gonder == [] and any(okuma.ARAC_YOK_ISARETI in s for s in satir), satir


def test_karar_duran_yeni_arac_personele():
    # 0.40: duran eşiğinin (0.35) üstü ama geçen eşiğinin (0.60) altı — örneğin
    # gece zayıf görülen, DURAN araç. Yalnızca kural 1 yakalar.
    g = _arac(_gecis(), durgun=0.40, enb=0.40)
    g.durgun_kirpik = _kare(8)
    gonder, _ = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 8


def test_karar_sahadaki_kacirma_personele_gider():
    # Sahada 2026-11-07 17:51 / 17:56 / 18:05 (1.3.1): araç sabit hızla geçti.
    # Yavaş gelirken "geçişten önceki" kareye uzakta girdi (plaka kutusuyla),
    # gidince boş şerit o kareye benzemedi → "araç durdu", durulan karede araç
    # yok. 1.3.1 hiçbir şey göndermedi (arka_kutulu + "önce de vardı").
    g = _arac(_gecis(), durgun=0.0, enb=0.94, arka=[UZAK + (0.45,)], insan=0.84,
              kirpik=_kare(6))
    g.arka_kutulu = True
    g.arka_plaka_sayisi = 1
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))], satir
    assert int(gonder[0].kirpik[0, 0, 0]) == 6                 # aracın göründüğü kare
    assert any(okuma.PLAKASIZ_ARAC_ISARETI in s for s in satir), satir
    # Teşhis: önceki karede ne vardı, kayda yazılır (yalnızca sayılar).
    assert any("önce: 1 araç, 1 plaka kutusu" in s for s in satir), satir


def test_karar_gecen_plakasiz_arac_personele():
    # Sahibin kararı (2026-11-07): durmadan geçen ve plakası hiç okunamayan
    # ARAÇ da personele (1.3.0'da sessizce düşüyordu). Fotoğraf = aracın en
    # iyi görüldüğü kare, son kare değil (araç gitmiş olabilir).
    g = _arac(_gecis(), enb=0.85, insan=0.1, kirpik=_kare(6))
    g.son_kirpik = _kare(9)
    gonder, satir = _karar(g, durdu=False, arac_boyu=True, **ESIK)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", None, _z(0))]
    assert int(gonder[0].kirpik[0, 0, 0]) == 6
    assert any(okuma.PLAKASIZ_ARAC_ISARETI in s for s in satir), satir
    # "Plakasız hareket" sayılmaz: durum'da iki kez sayılmasın.
    assert not any(okuma.PLAKASIZ_ISARETI in s for s in satir), satir


def test_karar_yeni_arac_kosullari():
    tamam = dict(enb=0.85)
    durumlar = [
        ("zayıf yeni araç (gölge, kenar parçası)", dict(enb=0.50), {}, []),
        ("araç ölçülmedi", dict(enb=None), {}, []),
        ("hareket küçük", tamam, dict(arac_boyu=False), []),
        ("gönderilmiş aracın ayrılışı", tamam, dict(ayrilis_sahne=True), []),
        ("araç bulucu yok / bozuk → 1.3.0 (geçen plakasız düşer)", tamam, dict(esiksiz=True), []),
        # Önceki kare ölçülmedi: ne "yeni" bilinmez → 1.3.0 kuralı.
        ("önceki kare ölçülmedi, geçti", dict(enb=0.85, arka=None), {}, []),
        ("önceki kare ölçülmedi, durdu", dict(enb=0.85, durgun=0.0, arka=None),
         dict(durdu=True), ["OKUNAMADI"]),
        ("önceki kare ölçülmedi, durdu, önceki karede plaka", dict(enb=0.85, durgun=0.0, arka=None),
         dict(durdu=True, arka_kutulu=True), []),
    ]
    for ad, alan, ek, beklenen in durumlar:
        g = _arac(_gecis(), **alan)
        g.durgun_kirpik = _kare(8)
        g.arka_kutulu = ek.pop("arka_kutulu", False)
        esik = {} if ek.pop("esiksiz", False) else ESIK
        gonder, _ = _karar(g, **{"durdu": False, "arac_boyu": True, **ek, **esik})
        assert [x.tur for x in gonder] == beklenen, f"{ad}: {gonder}"


def test_karar_bulucuyla_onceki_karedeki_plaka_engel_degil():
    # 1.3.0'ın gidiş kuralı (önceki karede plaka kutusu → gidiş) bulucu
    # varken kullanılmaz: o kuralı sahada YAVAŞ GELEN araç tetikledi. Gidişin
    # kendisi zaten kapalı: gönderilmiş araç ayrılış sayılır (yukarıda).
    g = _arac(_gecis(), enb=0.85)
    g.arka_kutulu = True
    assert [x.tur for x in _karar(g, durdu=False, arac_boyu=True, **ESIK)[0]] == ["OKUNAMADI"]


def test_karar_duran_arac_bilinmiyorsa_personele():
    # Durulan kare ölçülemedi (işçi yetişmedi): personele (kaçırmak yerine),
    # ve sahada teşhis için kayda yazılır.
    g = _arac(_gecis(), durgun=None, enb=0.10)
    g.durgun_kirpik = _kare(8)
    gonder, satir = _karar(g, durdu=True, arac_boyu=True, **ESIK)
    assert [x.tur for x in gonder] == ["OKUNAMADI"]
    assert any(okuma.ARAC_YETISMEDI_ISARETI in s for s in satir), satir
    # Araç bulucu yok / bozuk (eşik verilmedi): ölçüm ne derse desin 1.3.0 kuralı.
    g = _arac(_gecis(), durgun=0.0, enb=0.0)
    g.durgun_kirpik = _kare(8)
    assert [x.tur for x in _karar(g, durdu=True, arac_boyu=True)[0]] == ["OKUNAMADI"]


def test_karar_arac_bulucu_plakayi_engellemez():
    # Emin plaka da belirsiz plaka da araç bulucunun puanına BAKMAZ.
    g = _arac(_gecis(), durgun=0.0, enb=0.0)
    _oy(g, "34ABC123", [1, 2])
    gonder, _ = _karar(g, durdu=True, **ESIK)
    assert [(x.tur, x.plaka) for x in gonder] == [("PLAKA", "34ABC123")]
    g = _arac(_gecis(), durgun=0.0, enb=0.0)
    _oy(g, "34ABC123", [1], enk=0.96)
    g.oylama.kutu(_z(2), 1)
    gonder, _ = _karar(g, durdu=True, **ESIK)
    assert [(x.tur, x.tahmin) for x in gonder] == [("OKUNAMADI", "34ABC123")]


def test_karar_bozuk_okuyucu_arac_bulucuya_bakmaz():
    # Okuyucu bozukken işçi iş almaz, araç bulucu da çalışmaz: 1.3.0 kuralı.
    g = _arac(_gecis(), durgun=0.0, enb=0.0)
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


# ------------------------------------------- 1.4.0: araç izleme (kare işi) ---

def _gri() -> np.ndarray:
    return np.zeros((120, 160), np.uint8)


def _bekle_kare(isci, n=1, sn=3.0):
    bitis, sonuc = time.monotonic() + sn, []
    while time.monotonic() < bitis and len(sonuc) < n:
        sonuc += isci.biten_kareler()
        time.sleep(0.01)
    return sonuc


def test_isci_kare_iki_modelin_sonucunu_birlestirir():
    # İzleme bir karenin İKİ modelden sonucunu birlikte ister (plaka → araç ataması).
    p = SahtePlakaci({1: [ORTA, KENAR]}, {(1, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.99)]},
                     bekle=0.05)
    a = SahteArac({1: ([YAKIN + (0.8,)], 0.3)}, bekle=0.2)
    isci = okuma.Isci(p, haric=None, oku_esik=0.95, kayit=lambda s: None, arac=a)
    try:
        assert isci.ikisi_bos()
        isci.ver(okuma.Is(None, _kare(1), _z(1), 0, kare=okuma.KareIsi(7, 12.5, _gri())))
        time.sleep(0.1)
        assert isci.bos_mu() and not isci.ikisi_bos(), "araç bulucu sürerken ikisi boş değil"
        sonuc = _bekle_kare(isci)
        assert len(sonuc) == 1 and isci.ikisi_bos(), sonuc
        o = sonuc[0]
        assert (o.no, o.mono, o.zaman) == (7, 12.5, _z(1)) and int(o.kirpik[0, 0, 0]) == 1
        assert [round(k.skor, 2) for k in o.araclar] == [0.8], o.araclar
        assert [k for k, _ in o.plakalar] == [ORTA, KENAR], o.plakalar
        assert o.plakalar[0][1][1] == ("34ABC123", 0.99) and o.plakalar[1][1] is None, o.plakalar
        assert isci.biten_kareler() == []
    finally:
        isci.durdur()


def test_isci_kare_model_hatasi_birlesimi_bitirir():
    # Bir modelin hatası o kısmı None yapar; kare yine biter (izci "ölçülmedi" sayar).
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None,
                      arac=SahteArac(hata=True))
    try:
        isci.ver(okuma.Is(None, _kare(1), _z(1), 0, kare=okuma.KareIsi(1, 1.0, _gri())))
        o = _bekle_kare(isci)[0]
        assert o.araclar is None and o.plakalar == [], o
    finally:
        isci.durdur()
    isci = okuma.Isci(SahtePlakaci(hata=True), haric=None, oku_esik=0.95, kayit=lambda s: None,
                      arac=SahteArac({1: ([YAKIN + (0.8,)], 0.0)}))
    try:
        isci.ver(okuma.Is(None, _kare(1), _z(1), 0, kare=okuma.KareIsi(1, 1.0, _gri())))
        o = _bekle_kare(isci)[0]
        assert o.plakalar is None and len(o.araclar) == 1, o
    finally:
        isci.durdur()
    # Bulucusuz işçi: kare yalnızca plakayla biter.
    isci = okuma.Isci(SahtePlakaci(), haric=None, oku_esik=0.95, kayit=lambda s: None)
    try:
        isci.ver(okuma.Is(None, _kare(1), _z(1), 0, kare=okuma.KareIsi(1, 1.0, _gri())))
        o = _bekle_kare(isci)[0]
        assert o.araclar is None and o.plakalar == [], o
    finally:
        isci.durdur()


def test_plakalari_yaz_plaka_isle_ile_ayni():
    # İzin plaka yazımı geçişinkiyle (1.3.4) birebir: aynı kare, aynı oylama.
    okumalar = {(1, ORTA): [("34ABC123", 0.99), ("34ABC123", 0.97)],
                (1, KENAR): [("06KZ4581", 1.0), ("06KZ4581", 1.0)],
                (2, ORTA): [("34ABC123", 0.96), ("34ABC12", 0.90)]}
    p = SahtePlakaci({1: [ORTA, KENAR], 2: [ORTA]}, okumalar)
    g1, g2 = _gecis(1), _gecis(2)
    for no in (1, 2):
        okuma._plaka_isle(p, g1, _kare(no), _z(no), no, None, 0.95, False)
        olc = okuma.plakalari_olc(p, _kare(no), None, 0.95)
        okuma.plakalari_yaz(g2, _kare(no), _z(no), no, olc)
    k1, k2 = g1.oylama.karar(), g2.oylama.karar()
    assert k1 == k2, (k1, k2)
    assert g1.kutulu[0] == g2.kutulu[0] and set(g1.en_iyi) == set(g2.en_iyi)


def test_kirpma_alaninin_kenarindaki_plaka_okunmaz():
    # 1.4.0: kırpma alanının (çokgen) eğik kenarı da bir KENARDIR: ona değen
    # plaka kesik sayılır, okuyucu çağrılmaz; çoğu dışarıdaki kutu hiç sayılmaz.
    m = plaka.AlanMaskesi.cokgenden([(0, 0), (EN, 0), (0, BOY)], EN, BOY)   # sol üst üçgen
    ic = K(100, 100, 300, 145, 0.9)
    # Köşegen y = 668 − 0.426·x kutunun sağ alt köşesini kesiyor (~%8 dışarıda).
    kesik = K(700, 300, 800, 345, 0.9)
    disari = K(1300, 500, 1500, 545, 0.9)       # tamamen dışarıda
    okumalar = {(1, k): [("34ABC123", 0.99), ("34ABC123", 0.99)] for k in (ic, kesik, disari)}
    p = SahtePlakaci({1: [ic, kesik, disari]}, okumalar)
    assert okuma.kutulari_bul(p, _kare(1), m) == [ic, kesik], okuma.kutulari_bul(p, _kare(1), m)
    assert okuma.kutuyu_oku(p, _kare(1), ic, m, 0.95) is not None
    assert okuma.kutuyu_oku(p, _kare(1), kesik, m, 0.95) is None


def _iz_karari(g, **kw):
    v = dict(olay_zamani=_z(50), son_gonderilen=[], simdi=1000.0, arac_gecis_esik=0.60)
    v.update(kw)
    return okuma.iz_karari(g, **v)


def test_iz_karari():
    # Emin plaka → PLAKA; zamanı OLAYIN anı (ilk okunduğu an değil — saatlerce
    # duran aracın çıkışı eski zamanla gitmesin).
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    gonder, _ = _iz_karari(g)
    assert [(x.tur, x.plaka, x.zaman) for x in gonder] == [("PLAKA", "34ABC123", _z(50))]
    # 60 sn içinde aynı plaka gitmez (sunucunun kuralıyla aynı).
    gonder, satir = _iz_karari(g, son_gonderilen=[("34ABC123", 990.0)])
    assert gonder == [] and any(gunluk.AYRILIS_ISARETI in s for s in satir), satir
    # Personele (ısınmada kapıda olan araç): emin plaka TAHMİN olarak gider.
    gonder, _ = _iz_karari(g, personele=True)
    assert [(x.tur, x.tahmin) for x in gonder] == [("OKUNAMADI", "34ABC123")], gonder
    # Bir izde iki FARKLI emin plaka: iki araç karışmış — personele, plaka gitmez.
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    _oy(g, "06KZ4581", [3, 4])
    gonder, satir = _iz_karari(g)
    assert [x.tur for x in gonder] == ["OKUNAMADI"] and gonder[0].plaka is None, gonder
    assert any("iki plaka" in s for s in satir), satir
    for s in satir:
        assert "34ABC123" not in s and "06KZ4581" not in s, s
    # Emin + belirsiz: yalnızca emin gider.
    g = _gecis()
    _oy(g, "34ABC123", [1, 2])
    _oy(g, "06KZ4581", [3], enk=0.96)
    g.oylama.kutu(_z(9), 9)
    gonder, _ = _iz_karari(g)
    assert [(x.tur, x.plaka) for x in gonder] == [("PLAKA", "34ABC123")], gonder
    # Yalnız belirsiz → tahminle personele.
    g = _gecis()
    _oy(g, "34ABC123", [1], enk=0.96)
    g.oylama.kutu(_z(2), 1)
    g.kutulu = (0.8, _kare(5))
    gonder, _ = _iz_karari(g)
    assert [(x.tur, x.tahmin, x.zaman) for x in gonder] == [("OKUNAMADI", "34ABC123", _z(50))]
    # Plakasız: net araç (≥ 0.60) personele, en iyi göründüğü kareyle; zayıfsa hiç.
    g = _gecis()
    g.arac_max, g.arac_kirpik = 0.7, _kare(8)
    gonder, satir = _iz_karari(g)
    assert [x.tur for x in gonder] == ["OKUNAMADI"] and int(gonder[0].kirpik[0, 0, 0]) == 8
    assert any(gunluk.PLAKASIZ_ARAC_ISARETI in s for s in satir), satir
    g.arac_max = 0.5
    gonder, satir = _iz_karari(g)
    assert gonder == [] and any(gunluk.ARAC_YOK_ISARETI in s for s in satir), satir


def _birlesik_gecis() -> okuma.Gecis:
    return okuma.Gecis(1, _z(0), plaka.Oylama(k_oy=2, oran=0.6, tek_esik=0.99, m_kutu=2,
                                              birlesik=True))


def test_plakalari_yaz_yarim_oy_ve_birlesik_karar():
    # 1.4.1: iki kırpıntı AYNI metni (her biri ≥ 0.50) verdiyse yarım oy; üç
    # farklı görünüm → birleşik emin plaka (sahada 35CKM57 0.94 / 0.53 gibi).
    g = _birlesik_gecis()
    for no in (1, 2, 3):
        okuma.plakalari_yaz(g, _kare(no), _z(no), no,
                            [(ORTA, ([("35CKM57", 0.94), ("35CKM57", 0.53)], None))])
    # Daha net ama OKUNAMAYAN (kesik) bir kutunun karesi: kanıt fotoğrafı o
    # olmamalı — plakanın okunduğu kare gitmeli (bağımsız inceleme, 2026-11-09).
    okuma.plakalari_yaz(g, _kare(4), _z(4), 4,
                        [(K(ORTA.x1, ORTA.y1, ORTA.x2, ORTA.y2, 0.99), None)])
    k = g.oylama.karar()
    assert [(e.metin, e.birlesik) for e in k.eminler] == [("35CKM57", True)], k
    gonder, satir = _iz_karari(g)
    assert [(x.tur, x.plaka) for x in gonder] == [("PLAKA", "35CKM57")], gonder
    assert int(gonder[0].kirpik[0, 0, 0]) == 1, int(gonder[0].kirpik[0, 0, 0])
    assert any(gunluk.BIRLESIK_ISARETI in s for s in satir), satir
    assert all("35CKM57" not in s for s in satir), satir          # kayda plaka yazılmaz
    # Bir karede kırpıntılar anlaşmadı (35CKM51): rakip görüldü — emin değil.
    g = _birlesik_gecis()
    for no in (1, 2, 3):
        okuma.plakalari_yaz(g, _kare(no), _z(no), no,
                            [(ORTA, ([("35CKM57", 0.94), ("35CKM57", 0.53)], None))])
    okuma.plakalari_yaz(g, _kare(4), _z(4), 4,
                        [(ORTA, ([("35CKM57", 0.94), ("35CKM51", 0.93)], None))])
    assert g.oylama.karar().eminler == []
    # Kırpıntıların anlaşmadığı kare (öteki metin bambaşka) yarım oy DEĞİL:
    # iki anlaşan görünüm + bir anlaşmayan = yalnızca iki görünüm.
    g = _birlesik_gecis()
    for no in (1, 2):
        okuma.plakalari_yaz(g, _kare(no), _z(no), no,
                            [(ORTA, ([("35CKM57", 0.94), ("35CKM57", 0.53)], None))])
    okuma.plakalari_yaz(g, _kare(3), _z(3), 3,
                        [(ORTA, ([("35CKM57", 0.94), ("06KZ4581", 0.60)], None))])
    assert g.oylama.karar().eminler == []
    # Kırpıntılardan biri 0.50'nin altında: yarım oy değil.
    g = _birlesik_gecis()
    for no in (1, 2, 3):
        okuma.plakalari_yaz(g, _kare(no), _z(no), no,
                            [(ORTA, ([("35CKM57", 0.94), ("35CKM57", 0.45)], None))])
    assert g.oylama.karar().eminler == []


def test_plaka_genisligi_ve_ozet():
    # 1.4.1 kurulum yardımı (Axis'in piksel sayacı gibi): `--plaka` plakanın
    # TAM çözünürlükteki genişliğini yazar; sektör tek sıra plakada en az 130,
    # en iyi 140–160 px ister. Sahadaki kart fotoğraflarında 83–156 px.
    k = K(100, 100, 177, 120, 0.8)                       # küçültülmüş kırpıntıda 77 px
    assert abs(okuma.plaka_genisligi_tam(k, 1568, 2124) - 77 * 2124 / 1568) < 1e-6
    assert okuma.plaka_genisligi_tam(k, 1568, None) == 77.0   # küçültülmemiş
    az = okuma.plaka_boyu_ozeti([83, 92, 104, 130, 156])
    assert "104 px" in az and "yakınlaştırın" in az, az
    iyi = okuma.plaka_boyu_ozeti([140, 150, 160])
    assert "150 px" in iyi and "yakınlaştırın" not in iyi and "yeterli" in iyi, iyi
    assert okuma.plaka_boyu_ozeti([]) is None


def test_iz_arac_esigi_kapidan_gecen_plakasiz_arac():
    # Sahada 2026-11-10 (1.3.4 kaydı): plakası görülmeyen gerçek araçlar 0.46 /
    # 0.54 puanla "araç görülmedi" diye düştü — personele bile gitmedi.
    # İzleyicinin KAPIDAN geçtiğini gördüğü araç (GİRDİ / ÇIKTI) personele
    # izin doğum eşiğinden (0.35) gider; sahadaki fotoğraflarda insanlar en
    # çok 0.27 aldı. Kapı kanıtı olmayan olaylar 0.60'ta kalır.
    for tur in ("GIRDI", "CIKTI"):
        assert okuma.iz_arac_esigi(tur, 0.35, 0.60) == 0.35, tur
    for tur in ("TEK_KARE", "KAPISIZ", "ESKI_GIRDI"):
        assert okuma.iz_arac_esigi(tur, 0.35, 0.60) == 0.60, tur
    g = _gecis()
    g.arac_max, g.arac_kirpik = 0.46, _kare(8)
    gonder, _ = _iz_karari(g, arac_gecis_esik=okuma.iz_arac_esigi("GIRDI", 0.35, 0.60))
    assert [x.tur for x in gonder] == ["OKUNAMADI"], gonder
    gonder, _ = _iz_karari(g, arac_gecis_esik=okuma.iz_arac_esigi("KAPISIZ", 0.35, 0.60))
    assert gonder == [], gonder


def test_iz_personele_olaylari():
    # Plakası emin okunsa da personele giden izleme olayları: açılışta kapıda
    # olan (dışarıdan mı geldi bilinmez) ve 1.4.1'den beri yalnızca TEK karede
    # görülen (hangi yöne gitti bilinmez). Köprünün iki yeri (canlı döngü ve
    # --plaka) aynı listeyi buradan alır.
    assert okuma.iz_personele("ESKI_GIRDI") and okuma.iz_personele("TEK_KARE")
    for tur in ("GIRDI", "CIKTI", "KAPISIZ", "ICERIDE", "GERI_DONDU", "KAPIDA_BEKLIYOR"):
        assert not okuma.iz_personele(tur), tur


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
