# -*- coding: utf-8 -*-
"""
Araç izleme (1.4.0) — takip.py birim testleri.

    python test_takip.py

Köprü 1.4.0 her aracı kareler boyunca İZLER ve araç başına bir kez karar
verir; kapı alanı varsa aracı ancak kapıdan girip otoparka geçtiyse "girdi",
otoparktan gelip kapıda kaybolduysa "çıktı" sayar. Buradaki bir hata ya
kaçan araç ya da yanlış bilet (park etmiş aracın biletini kapatan sahte
"çıkış") demektir. Sahte kareler: gri görüntüde her araç kendi dokusuyla
çizilir — duran araç pikselleri değişmez, hareket eden aracınkiler değişir
(köprünün "yerel fark" ölçüsü budur).
"""
from __future__ import annotations

import datetime as dt
import os
import sys

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import arac  # noqa: E402
import plaka  # noqa: E402
import takip  # noqa: E402

EN, BOY = 1600, 800
# Kapı alanı sol altta, kırpıntının kenarına değiyor (sahadaki yeşil alan gibi).
KAPI = [(0, 450), (520, 450), (760, 800), (0, 800)]
T0 = dt.datetime(2026, 11, 8, 12, 0, 0, tzinfo=dt.timezone.utc)
A = arac.AracKutu


class _Gecis:
    """okuma.Gecis yerine: yalnızca yazılan plaka ölçümlerini tutar."""
    sayac = 0

    def __init__(self):
        _Gecis.sayac += 1
        self.no = _Gecis.sayac
        self.yazilan: list = []


def _yaz(gecis, kirpik, zaman, gorunum, olcumler):
    gecis.yazilan.append((gorunum, [k for k, _ in olcumler]))


def _takipci(kapi=KAPI, **ek):
    return takip.Takipci(EN, BOY, kapi, yeni_gecis=_Gecis, yaz=_yaz, **ek)


class Sahne:
    """Kareleri sırayla üretir; her araç gri görüntüde kendi dokusuyla çizilir."""

    def __init__(self, t: takip.Takipci):
        self.t = t
        self.mono = 100.0
        self.no = 0
        self.olaylar: list[takip.Olay] = []

    def kare(self, araclar, plakalar=(), dt_sn=0.3, olculmedi=False, doku=None, cizim=None):
        """`cizim`: görüntüye çizilecek GERÇEK araçlar (verilmezse bulunan kutular)."""
        self.no += 1
        self.mono += dt_sn
        gri = np.zeros((120, 160), np.uint8)
        for i, a in enumerate(araclar if cizim is None else cizim):
            x1, y1 = max(0, int(a.x1 * 160 / EN)), max(0, int(a.y1 * 120 / BOY))
            x2 = min(160, max(x1 + 1, int(a.x2 * 160 / EN)))
            y2 = min(120, max(y1 + 1, int(a.y2 * 120 / BOY)))
            # Doku araca bağlı: araç kayınca bölgenin pikselleri değişir.
            yy, xx = np.mgrid[y1:y2, x1:x2]
            d = (doku or {}).get(i, 40 + 30 * i)
            gri[y1:y2, x1:x2] = (d + ((xx - x1) * 7 + (yy - y1) * 13) % 90).astype(np.uint8)
        o = takip.Olcum(self.no, self.mono, T0 + dt.timedelta(seconds=self.mono - 100.0),
                        np.zeros((4, 4, 3), np.uint8), gri,
                        None if olculmedi else list(araclar),
                        None if olculmedi else [(k, None) for k in plakalar])
        self.olaylar += self.t.guncelle(o)
        self.olaylar += self.t.zaman_gecti(self.mono)
        return self

    def bekle(self, sn: float, araclar=(), adim=0.3):
        n = max(1, int(round(sn / adim)))
        for _ in range(n):
            self.kare(araclar, dt_sn=adim)
        return self

    def turler(self):
        return [o.tur for o in self.olaylar]


def _isin(s: Sahne, araclar=()):
    """Isınma: ilk iki ölçülen kare (köprü başlarken) — boş sahne."""
    s.kare(list(araclar)).kare(list(araclar))
    return s


def _arac(x, y, w=300, h=200, skor=0.8):
    return A(x, y, x + w, y + h, skor)


def _yol(s: Sahne, bas, son, adim=8, w=300, h=200, skor=0.8, plaka_ile=False, dt_sn=0.3):
    """(x, y) kutu sol üstünden (x, y)'ye `adim` karede düz yol."""
    for i in range(adim + 1):
        x = bas[0] + (son[0] - bas[0]) * i / adim
        y = bas[1] + (son[1] - bas[1]) * i / adim
        a = _arac(x, y, w, h, skor)
        p = [plaka.Kutu(x + w * 0.35, y + h * 0.7, x + w * 0.65, y + h * 0.82, 0.9)] if plaka_ile else []
        s.kare([a], p, dt_sn=dt_sn)
    return _arac(son[0], son[1], w, h, skor)


# --------------------------------------------------------------- eşleştirme --

def test_dogum_esigi_ve_devam_esigi():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 100, skor=0.30)])
    assert not s.t.izler, "0.35 altı yeni iz açmamalı"
    s.kare([_arac(900, 100, skor=0.50)])
    assert len(s.t.izler) == 1
    iz = s.t.izler[0]
    s.kare([_arac(905, 100, skor=0.15)])          # zayıf ama süren
    assert len(s.t.izler) == 1 and s.t.izler[0] is iz and iz.kacirma == 0


def test_kopya_kutu_yeni_iz_acmaz():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 100), _arac(940, 110, 300, 200, 0.6)])     # IoU ~0.6: aynı araç
    assert len(s.t.izler) == 1, s.t.izler


def test_olculmeyen_kare_kacirma_saymaz_ve_bostayken_donar():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 100)])
    iz = s.t.izler[0]
    for _ in range(10):
        s.kare([], olculmedi=True)                 # araç bulucu sonucu yok
    assert iz.kacirma == 0 and iz.durum == "izleniyor"
    s.kare([_arac(900, 100)], dt_sn=120.0)         # iki dakika model çalışmadı
    assert s.t.izler == [iz] and iz.kacirma == 0


def test_kayip_uc_kare_ve_bir_bucuk_saniye():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 100)])
    iz = s.t.izler[0]
    for _ in range(3):
        s.kare([], dt_sn=0.2)                      # 3 kaçırma ama 0.6 sn
    assert iz.durum == "izleniyor", iz.durum
    s.kare([], dt_sn=1.0)
    assert iz.durum == "kayip", iz.durum


def test_karsilikli_gecen_iki_arac_kimligini_korur():
    s = _isin(Sahne(_takipci(kapi=None)))
    for i in range(10):
        s.kare([_arac(100 + i * 120, 100, 300, 200), _arac(1200 - i * 120, 160, 300, 200)])
        if i == 0:
            ilk = list(s.t.izler)
    assert len(s.t.izler) == 2 and set(map(id, s.t.izler)) == set(map(id, ilk))
    sol = min(s.t.izler, key=lambda z: z.dogum_kutu.x1)
    assert sol.kutu.x1 > 1000, sol.kutu                # soldan doğan sağda


def test_ortulme_dikisi_ayni_izi_surdurur():
    s = _isin(Sahne(_takipci(kapi=None)))
    _yol(s, (100, 100), (500, 100), adim=5)
    iz = s.t.izler[0]
    s.bekle(2.5, [])                                   # önünden biri geçti: 2.5 sn yok
    _yol(s, (650, 100), (900, 100), adim=3)
    canli = [z for z in s.t.izler if z.durum == "izleniyor"]
    assert canli == [iz], s.t.izler


def test_kisa_ortulme_kayip_olmadan_da_dikilir():
    # 1 sn görünmedi (henüz "kayıp" değil: 1.5 sn dolmadı) ve ilerleyip uzakta
    # yeniden göründü: YENİ iz değil aynı iz. Yoksa kapıya giderken yarı
    # yolda bir yayanın arkasında kalan araç kapıda "yeni doğmuş" sayılır ve
    # çıkışı kaybolurdu.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    _yol(s, (900, 150), (600, 300), adim=4)
    iz = s.t.izler[0]
    s.bekle(1.0, [], adim=0.25)                              # 4 kaçırma, 1 sn
    assert iz.durum == "izleniyor" and iz.kacirma >= 3, (iz.durum, iz.kacirma)
    # ~310 px ileride (kapının içinde) yeniden: olağan eşleşme payının
    # (0.6 × köşegen = 216 px) dışı, dikiş payının (1 × köşegen) içi.
    _yol(s, (330, 450), (60, 600), adim=3)
    s.bekle(6.0, [])
    canli_veya_biten = {z.id for z in s.t.izler}
    assert s.turler().count("CIKTI") == 1, s.turler()
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"][0] is iz, canli_veya_biten


def test_ortulmede_hizla_tahmin_edilen_yerde_dikilir():
    # Yavaş dizüstünde (az kare) araç son görüldüğü yerden bir araç boyundan
    # FAZLA ilerlemiş olarak yeniden görünür — ama hızıyla tahmin edilen yerde.
    # Aynı iz sayılmalı (gerçek izleyiciler de kayıp izin yerini hızıyla
    # tahmin eder); yoksa kapıda "yeni doğmuş" sayılıp çıkışı kaybolurdu.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    for i in range(1, 3):                                    # 0.5 sn arayla, 150 px/kare sola-aşağı
        s.kare([_arac(900 - 150 * i, 150 + 70 * i)], dt_sn=0.5)
    iz = s.t.izler[0]
    assert s.t._kapi_mesafe(s.t._capa(iz.kutu)) < -100, "son görüldüğü yer otoparkın içi"
    s.bekle(1.8, [], adim=0.6)                               # 1.8 sn görünmedi
    # Son görülen kutu (600, 290) (merkez 750, 390); hız ~(-300, 140) px/sn →
    # 2 sn sonra tahmin merkez ~(150, 670). Araç (60, 560)'ta (merkez 210, 660)
    # yeniden görülür: son yerden 604 px (> köşegen 360), tahmine ~60 px.
    _yol(s, (60, 560), (40, 600), adim=2, dt_sn=0.3)
    s.bekle(6.0, [])
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"] == [iz], s.turler()
    assert len({id(o.iz) for o in s.olaylar}) == 1, s.olaylar


def test_yavas_dizustunde_buyuk_adimlar_tek_iz():
    # 2 kare/sn (yoğun dizüstü): araç kare başına kendi boyunun ~0.7'si kadar
    # ilerler — olağan eşleşme payının (0.6 köşegen) dışı. Yine TEK iz ve
    # tek "girdi" olmalı (her kare yeni iz olsaydı kapıdan doğan iz otoparka
    # hiç geçmez, giriş kaybolurdu).
    s = _isin(Sahne(_takipci()))
    # Kare başına (225, −120): 255 px — köşegen 360, olağan pay 216 px.
    son = _yol(s, (50, 600), (950, 120), adim=4, dt_sn=0.5)
    s.bekle(3.0, [son], adim=0.5)
    assert len(s.t.izler) == 1, s.t.izler
    assert s.turler().count("GIRDI") == 1, s.turler()


def test_duran_aracin_izini_yanindan_gecen_alamaz():
    # Park etmiş (duran) A, yanından geçen B'nin arkasında bir an görünmez.
    # B'nin kutusu A'nın izine DİKİLMEMELİ: B kapıdan çıkınca A'nın plakası
    # "çıktı" diye gitmesin (A'nın biletini kapatırdı). Duran iz yalnızca
    # yerinde (aynı yerde, örtüşerek) sürer.
    # B'nin merkezi A'nınkine 269 px (dikiş payı, köşegen 360) ve 212 px
    # (olağan eşleşme payı 216 px) — iki eşleşme yolu da ayrı ayrı sınanır.
    for bx, by in ((1100, 330), (1050, 300)):
        s = _isin(Sahne(_takipci()))
        a = _arac(900, 150)
        pa = plaka.Kutu(1005, 290, 1095, 314, 0.9)
        for _ in range(12):
            s.kare([a], [pa])
        iz_a = s.t.izler[0]
        assert iz_a.duruyor
        s.kare([_arac(bx, by)], dt_sn=0.3, cizim=[a, _arac(bx, by)])   # A görünmez, B yanında
        assert iz_a.kutu[:2] == (900, 150), (bx, iz_a.kutu)
        _yol(s, (bx, by), (60, 600), adim=8)
        s.bekle(6.0, [a], adim=0.3)
        cikan = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
        assert iz_a not in cikan, (bx, s.olaylar)


# ------------------------------------------------------------ durma, görünüm --

def test_duran_aracin_kutu_titremesi_hareket_sayilmaz():
    # Sahada ölçüldü: duran aracın kutusu gürültüyle IoU 0.85'e kadar oynar;
    # pikseller değişmez. Durmuş sayılmalı ve yeni GÖRÜNÜM açmamalı (iki
    # görünüm kuralı aynı karenin iki okumasıyla delinmesin).
    s = _isin(Sahne(_takipci(kapi=None)))
    rng = np.random.default_rng(3)
    for _ in range(12):
        j = rng.integers(-12, 13, 4)
        s.kare([A(900 + j[0], 100 + j[1], 1200 + j[2], 300 + j[3], 0.8)],
               doku={0: 40}, dt_sn=0.3, cizim=[A(900, 100, 1200, 300, 0.8)])
    iz = s.t.izler[0]
    assert iz.duruyor, "titreyen duran araç durmuş sayılmalı"
    assert iz.gorunum_no == 1, iz.gorunum_no


def test_kenarda_kesik_hareketli_arac_durmus_sayilmaz():
    # Kenardan giren aracın kutusu alttan kesik: çapa kenara yapışık kalır,
    # ama araç (pikseller) hareket ediyor — durmuş SAYILMAMALI.
    s = _isin(Sahne(_takipci(kapi=None)))
    for i in range(10):
        s.kare([A(100, 700 - i * 30, 400, 800, 0.8)])
    assert not s.t.izler[0].duruyor


def test_surunen_arac_durmus_sayilmaz():
    # Çok yavaş ilerleyen araç (2 sn'de ~56 px: kutusu hâlâ IoU ≥ 0.6 ile
    # örtüşür) — ama PİKSELLERİ değişiyor: durmuş SAYILMAMALI.
    s = _isin(Sahne(_takipci(kapi=None)))
    for i in range(14):
        s.kare([_arac(600 + 8 * i, 150)])
    assert not s.t.izler[0].duruyor


def test_duran_aracin_gorunumu_baska_arac_kiprdayinca_artmaz():
    s = _isin(Sahne(_takipci(kapi=None)))
    for i in range(10):
        s.kare([_arac(900, 100), _arac(100 + i * 60, 450, 250, 150)])
    duran = min(s.t.izler, key=lambda z: abs(z.kutu.x1 - 900))
    giden = max(s.t.izler, key=lambda z: abs(z.kutu.x1 - 900))
    assert duran.gorunum_no == 1, duran.gorunum_no
    assert giden.gorunum_no >= 5, giden.gorunum_no


# -------------------------------------------------------------- kapı kuralı --

def test_giris_kapidan_otoparka_gecip_durunca():
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (50, 600), (900, 150), adim=10)           # sol alttan otoparka
    assert "GIRDI" not in s.turler(), "durmadan karar yok"
    s.bekle(2.5, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()
    o = [o for o in s.olaylar if o.tur == "GIRDI"][0]
    assert o.zaman < T0 + dt.timedelta(seconds=4), o.zaman   # kapıdan çıktığı an
    s.bekle(5.0, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()       # bir kez


def test_giris_kaybolunca_ve_otuz_saniyede_karar():
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (900, 150), adim=10)
    s.bekle(5.0, [])                                         # otoparkın derinliğinde kayboldu
    assert s.turler().count("GIRDI") == 1, s.turler()
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (700, 150), adim=6)
    for i in range(110):                                     # 33 sn ağır ağır dolaşıyor
        s.kare([_arac(700 + (i % 20) * 15, 150)], dt_sn=0.3)
    assert s.turler().count("GIRDI") == 1, s.turler()


def test_kapidan_girip_geri_donen_sayilmaz():
    s = _isin(Sahne(_takipci()))
    # Çapa (670, 500): kapının eğik kenarının ~96 px dışı (pay 36 px) — iki
    # kare (yolun sonu ve dönüşün başı) dışarıda: kapıdan ÇIKTI sayılır …
    _yol(s, (50, 600), (520, 300), adim=4)
    _yol(s, (520, 300), (50, 600), adim=4)                   # … ama geri döndü
    s.bekle(6.0, [])                                         # kapıda kayboldu
    assert "GIRDI" not in s.turler() and "CIKTI" not in s.turler(), s.turler()
    assert "GERI_DONDU" in s.turler(), s.turler()


def test_kapi_sinirinda_titreme_gecis_sayilmaz():
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (200, 270), adim=3)                   # çapa (350, 470): kapının içi
    for i in range(12):                                      # sınırda ±12 px titriyor
        y = 245 + (24 if i % 2 else 0)
        s.kare([_arac(200, y)])
    s.bekle(6.0, [])
    assert "GIRDI" not in s.turler(), s.turler()
    # Kapının hemen dışında (payın içinde, ~20 px) duran araç otoparka
    # geçmiş sayılmaz: kapı alanı bir araç boyu derin çizilir, gerçek giriş
    # bu payı rahatça aşar.
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (50, 600), (200, 230), adim=3)            # çapa (350, 430): üst kenarın 20 px dışı
    s.bekle(4.0, [son])
    assert "GIRDI" not in s.turler(), s.turler()


def test_cikis_otoparktan_kapida_kaybolunca():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])   # park etmiş (ısınmadan sonra doğdu)
    _yol(s, (900, 150), (60, 600), adim=10)                  # kapıya, kenara değerek
    son_gorulme = s.mono
    s.bekle(6.0, [])
    assert s.turler().count("CIKTI") == 1, s.turler()
    o = [o for o in s.olaylar if o.tur == "CIKTI"][0]
    assert abs((o.zaman - T0).total_seconds() - (son_gorulme - 100.0)) < 1e-6, o.zaman


def test_kapida_duran_arac_ortulunce_cikis_sayilmaz():
    # Kapı alanında DURAN araç (bekliyor) bir yayanın arkasında kaybolursa
    # "çıktı" SAYILMAZ: duruyorken kaybolan araç park belleğine gider.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    son = _yol(s, (900, 150), (150, 500), adim=8)            # kapıya geldi
    s.bekle(3.0, [son])                                      # bekliyor
    s.bekle(8.0, [])                                         # uzun süre görünmedi
    assert "CIKTI" not in s.turler(), s.turler()
    s.kare([son]).bekle(1.0, [son])                         # yeniden göründü: aynı araç
    assert "GIRDI" not in s.turler(), s.turler()
    # Resmin kenarına DEĞEREK duran araç da (kapının tam ağzında bekliyor):
    # kenara değiyor ama duruyordu — gitmiş sayılmaz.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    son = _yol(s, (900, 150), (100, 600), adim=8)            # kutunun altı kenarda
    s.bekle(3.0, [son])
    s.bekle(8.0, [])
    assert "CIKTI" not in s.turler(), s.turler()


def test_kapida_kenardan_uzaklasirken_kaybolan_cikis_sayilmaz():
    # Kapı alanında kayboldu ama KENARA doğru gitmiyordu (otoparka dönüyordu).
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    _yol(s, (900, 150), (150, 480), adim=6)
    _yol(s, (150, 480), (260, 420), adim=2)                  # geri, otoparka doğru
    s.bekle(6.0, [])
    assert "CIKTI" not in s.turler(), s.turler()


def test_otoparkta_hareketliyken_kaybolan_cikis_sayilmaz():
    # Kapı alanında DEĞİL, otoparkın içinde (ör. kırpmanın kenarından park
    # yerine) giderken kaybolan araç çıkmış sayılmaz.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    _yol(s, (900, 150), (1290, 150), adim=6)                  # sağ kenara, kapıdan uzak
    s.bekle(6.0, [])
    assert "CIKTI" not in s.turler(), s.turler()


def test_kapi_sinirinda_dogan_arac_kapida_kaybolunca_cikis_sayilmaz():
    # Kapının hemen dışında (pay içinde) doğan, hiç gerçekten otoparkta
    # görülmeyen araç kapıda kaybolursa çıkmış sayılmaz: nereden geldiği belli değil.
    s = _isin(Sahne(_takipci()))
    # Çapa (560, 468): eğik kenarın ~23 px dışı — tolerans (9 px) dışında,
    # "kapıdan çıktı" payının (36 px) içinde.
    s.kare([_arac(410, 268)])                                  # çapa = kutunun alt ORTASI
    _yol(s, (410, 268), (60, 600), adim=4)
    s.bekle(6.0, [])
    assert "CIKTI" not in s.turler(), s.turler()


def test_park_bellegi_karar_tekrarlanmaz():
    # Girip duran (GİRDİ gönderilmiş) araç uzun süre görünmez olup aynı yerde
    # yeniden doğarsa ikinci kez "girdi" sayılmaz — kararı park belleğinden alır.
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (50, 600), (900, 150), adim=10)
    s.bekle(3.0, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()
    s.bekle(8.0, [])                                           # önünde kamyon durdu
    s.kare([son]).bekle(3.0, [son])                           # yine orada
    _yol(s, (900, 150), (1000, 140), adim=3)                  # biraz kıpırdadı
    s.bekle(3.0, [_arac(1000, 140)])
    assert s.turler().count("GIRDI") == 1, s.turler()


def test_isinmada_kapida_olan_arac_personele():
    # Köprü açıldığında kapı alanında duran araç: dışarıdan mı geldi bilinmez.
    s = Sahne(_takipci())
    a = _arac(60, 560)
    s.kare([a]).kare([a])                                    # ısınma kareleri
    _yol(s, (60, 560), (900, 150), adim=8)
    s.bekle(3.0, [_arac(900, 150)])
    assert "GIRDI" not in s.turler(), s.turler()
    assert s.turler().count("ESKI_GIRDI") == 1, s.turler()


def test_otopark_icinde_hareket_sayilmaz():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 100)]).bekle(1.0, [_arac(900, 100)])
    son = _yol(s, (900, 100), (1200, 300), adim=8)           # park yeri değiştirdi
    s.bekle(3.0, [son])
    s.bekle(6.0, [])
    assert not ({"GIRDI", "CIKTI", "ESKI_GIRDI", "KAPISIZ"} & set(s.turler())), s.turler()
    assert "ICERIDE" in s.turler(), s.turler()


def test_kapida_uzun_bekleyen_uyarisi():
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (50, 600), (120, 520), adim=3)
    s.bekle(65.0, [son], adim=1.0)
    assert s.turler().count("KAPIDA_BEKLIYOR") == 1, s.turler()


def test_kopma_kapidan_cikmis_karar_bekleyen_girdi_sayilir():
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (900, 150), adim=10)
    olay = s.t.kopma(s.mono)
    assert [o.tur for o in olay] == ["GIRDI"], olay
    s.t.yeniden_baglandi()
    assert not [z for z in s.t.izler if z.durum == "izleniyor"]
    assert s.t.kare_istiyor()                                # ısınma kareleri istenir


# -------------------------------------------------------------- kapı yoksa ---

def test_kapisiz_durunca_bir_kez_sonra_giderken_bir_kez():
    s = _isin(Sahne(_takipci(kapi=None)))
    son = _yol(s, (50, 600), (900, 150), adim=10)
    s.bekle(3.0, [son])
    assert s.turler().count("KAPISIZ") == 1, s.turler()
    s.bekle(5.0, [son])
    assert s.turler().count("KAPISIZ") == 1, s.turler()
    _yol(s, (900, 150), (50, 600), adim=8)
    s.bekle(6.0, [])
    assert s.turler().count("KAPISIZ") == 2, s.turler()


def test_kapisiz_kipirdama_ve_hic_kiprdamayan_sayilmaz():
    s = Sahne(_takipci(kapi=None))
    a = _arac(900, 150)
    s.kare([a]).kare([a])
    for i in range(20):
        s.kare([_arac(900 + (i % 3) * 10, 150)])            # yerinde kıpırdıyor (< %30 köşegen)
    s.bekle(3.0, [a])
    assert "KAPISIZ" not in s.turler(), s.turler()


# ------------------------------------------------------------ plaka ataması --

def test_plaka_alttaki_en_kucuk_araca_yazilir():
    s = _isin(Sahne(_takipci(kapi=None)))
    buyuk, kucuk = A(100, 100, 900, 700, 0.9), A(600, 120, 800, 260, 0.7)
    p = plaka.Kutu(660, 220, 740, 245, 0.9)                  # küçük aracın altında
    s.kare([buyuk, kucuk], [p])
    izk = min(s.t.izler, key=lambda z: (z.kutu.x2 - z.kutu.x1))
    izb = max(s.t.izler, key=lambda z: (z.kutu.x2 - z.kutu.x1))
    assert izk.gecis.yazilan and not izb.gecis.yazilan, (izk.gecis.yazilan, izb.gecis.yazilan)


def test_plaka_iki_esit_araca_belirsizse_kimseye_yazilmaz():
    s = _isin(Sahne(_takipci(kapi=None)))
    a, b = A(100, 100, 500, 400, 0.9), A(130, 110, 520, 420, 0.4)   # neredeyse aynı boy
    # Kopya korumasına takılmasınlar: ikinci kutu AYRI bir araç olsun diye kaydırılmış.
    b = A(350, 150, 760, 460, 0.8)
    p = plaka.Kutu(380, 330, 460, 350, 0.9)                  # ikisinin de alt kısmında
    s.kare([a, b], [p])
    assert all(not z.gecis.yazilan for z in s.t.izler), [z.gecis.yazilan for z in s.t.izler]
    assert s.t.belirsiz_plaka == 1, s.t.belirsiz_plaka


def test_plaka_genis_payla_ve_sahipsiz_plaka_izi():
    s = _isin(Sahne(_takipci(kapi=None)))
    a = A(100, 100, 500, 400, 0.9)
    s.kare([a], [plaka.Kutu(300, 410, 380, 430, 0.9)])       # kutunun hemen altı (+%25)
    assert s.t.izler[0].gecis.yazilan, "geniş payla araca yazılmalı"
    # Bulucunun görmediği araç: plaka kendi izinde (ticari ANPR gibi).
    s = _isin(Sahne(_takipci()))
    for i in range(9):
        x, y = 100 + i * 90, 700 - i * 60
        s.kare([], [plaka.Kutu(x, y, x + 90, y + 25, 0.9)])
    s.bekle(6.0, [])
    assert s.turler().count("GIRDI") == 1, s.turler()
    o = [o for o in s.olaylar if o.tur == "GIRDI"][0]
    assert o.iz.kaynak == "plaka" and o.iz.gecis.yazilan, o


def test_araca_ait_plaka_izi_duser():
    # Plaka önce sahipsizdi; araç bulunduğunda plaka izi bırakılır (çift karar yok).
    # Plaka izi kapıdan çıkmış (karar bekliyor) olsun: bırakılmasaydı bu iz de
    # "girdi" derdi (aynı araç iki kez).
    s = _isin(Sahne(_takipci()))
    for i in range(7):
        x, y = 100 + i * 90, 700 - i * 60
        s.kare([], [plaka.Kutu(x, y, x + 90, y + 25, 0.9)])
    assert any(z.gecti_mono is not None for z in s.t._plakaci.izler), s.t._plakaci.izler
    for i in range(7, 12):
        x, y = 100 + i * 90, 700 - i * 60
        s.kare([A(x - 100, y - 160, x + 190, y + 40, 0.8)], [plaka.Kutu(x, y, x + 90, y + 25, 0.9)])
    s.bekle(6.0, [])
    assert not [o for o in s.olaylar if o.iz.kaynak == "plaka"], s.olaylar


# --------------------------------------------------------- kare isteği ------

def test_kare_istegi():
    t = _takipci()
    assert t.kare_istiyor(), "ısınma kareleri istenir"
    s = _isin(Sahne(t))
    assert not t.kare_istiyor(), "boş sahne: istek yok"
    s.kare([_arac(900, 100)])
    assert t.kare_istiyor(), "yeni iz: istek var"
    s.bekle(3.0, [_arac(900, 100)])
    assert not t.kare_istiyor(), "duran araç: istek yok"


def test_degisti_aracin_ya_da_kapinin_bolgesine_bakar():
    # Köprü model karesini yalnızca TÜM kareden ölçülen kıpırtıyla isteseydi
    # yavaş kalkan park etmiş araç (kareler arası fark küçük) hiç görülmez,
    # kapıya gidip kaybolurdu — çıkışı kaçardı (test_kopru takip_ortulme).
    # Araç ya da kapı bölgesi son ölçülen kareden beri değiştiyse kare istenir.
    t = _takipci()
    s = _isin(Sahne(t))
    s.kare([_arac(900, 100)]).bekle(3.0, [_arac(900, 100)])
    assert not t.kare_istiyor()
    ayni = s.t.son_gri.copy()
    assert not t.degisti(ayni), "hiçbir şey değişmedi"
    kaydi = ayni.copy()
    kaydi[15:45, 92:120] = 255 - kaydi[15:45, 92:120]          # aracın bölgesi değişti
    assert t.degisti(kaydi), "duran aracın pikselleri değişti"
    kapi = ayni.copy()
    kapi[100:118, 5:30] = 200                                   # kapı alanında bir şey belirdi
    assert t.degisti(kapi), "kapı alanı değişti"
    uzak = ayni.copy()
    uzak[2:6, 150:156] = 255                                    # alakasız küçük köşe
    assert not t.degisti(uzak)


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
