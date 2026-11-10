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
    # 1.4.1: dikilmeseydi çıkışı hız kuralı yine verebilirdi — dikişin
    # kendisi sınanır: araç hiç yeni iz açmadı.
    assert s.t._no == 1, s.t._no


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


# ------------------------------------- 1.4.1: kapıda görülmeyen araç (hızlı) --
# Sahada ~3-4 kare/sn: hızlı araç kapı alanını iki kare ARASINDA geçebilir,
# ya da bulucu onu kapıda (yarısı görünür, bulanık) görmez. 1.4.0 böyle bir
# aracı ilk / son kez otoparkta görür ve "otopark içi hareket" sayardı —
# giriş ya da çıkış SESSİZCE kaybolurdu. 1.4.1: aracın yolu bir kare önce /
# sonra kapı alanından geçiyorsa (hızıyla) kapıdan geldi / kapıdan gitti.

def test_hizli_giris_kapida_hic_gorulmeden():
    s = _isin(Sahne(_takipci()))
    s.kare([])                                               # kapıdaydı, bulucu göremedi
    # İlk görüldüğü yer otoparkın içi: çapa (650, 400), kapının ~136 px dışı.
    # Kare başına (+330, -120) (~1 araç boyu, 0.3 sn'de): bir kare önce çapa
    # (320, 520) — kapının içi.
    s.kare([_arac(500, 200)]).kare([_arac(830, 80)])
    son = _arac(1100, 20)
    s.kare([son]).bekle(2.5, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()
    assert "ICERIDE" not in s.turler(), s.turler()
    o = [o for o in s.olaylar if o.tur == "GIRDI"][0]
    assert o.iz.kapida_gorulmedi, "kayıtta 'kapıda görülmedi' yazmalı"


def test_hizli_giris_iki_kez_gorulup_kaybolan():
    # Kapının 20 px dışında (pay içinde) ilk görülen, bir sonraki karede
    # otoparkın içinde olan ve sonra bir şeyin arkasında kaybolan araç: iki
    # görülme yeter — kapıdan çıkışı doğduğu andır.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    s.kare([_arac(150, 230)])                                # çapa (300, 430)
    s.kare([_arac(450, 130)])                                # çapa (600, 330)
    s.bekle(6.0, [])
    assert s.turler().count("GIRDI") == 1, s.turler()


def test_hizli_giris_frenleyen_arac():
    # Kapıdan hızlı geçip hemen fren yapan araç: ikinci görülmedeki hız
    # kapıdaki hızdan düşük, geri tahmin kapının biraz dışında kalır — kapı
    # payı (aynı "kapıdan çıktı" payı) içinde olduğu için yine giriş.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    s.kare([_arac(500, 200)])                                # çapa (650, 400)
    s.kare([_arac(760, 100)])                                # (+260, -100): yavaşladı
    son = _arac(900, 60)
    s.kare([son]).bekle(2.5, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()


def test_hizli_cikis_kapida_hic_gorulmeden():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])   # park etmiş
    s.kare([_arac(750, 200)])                                # çapa (900, 400)
    s.kare([_arac(500, 250)])                                # çapa (650, 450): kapının ~107 px dışı
    son_gorulme = s.mono
    s.bekle(6.0, [])                                         # bir kare sonra kapıdaydı: gitti
    assert s.turler().count("CIKTI") == 1, s.turler()
    assert "ICERIDE" not in s.turler(), s.turler()
    o = [o for o in s.olaylar if o.tur == "CIKTI"][0]
    assert o.iz.kapida_gorulmedi
    assert abs((o.zaman - T0).total_seconds() - (son_gorulme - 100.0)) < 1e-6, o.zaman


def test_hizli_otopark_ici_sayilmaz():
    # Kapıdan uzakta doğup hızla kapıdan UZAKLAŞAN, kapıdan uzakta hızla
    # giderken kaybolan araç: ne giriş ne çıkış.
    s = _isin(Sahne(_takipci()))
    _yol(s, (800, 100), (1300, 100), adim=2)
    s.bekle(6.0, [])
    s.kare([_arac(900, 100)]).bekle(2.5, [_arac(900, 100)])
    _yol(s, (900, 100), (1300, 100), adim=2)
    s.bekle(6.0, [])
    assert not ({"GIRDI", "CIKTI"} & set(s.turler())), s.turler()


def test_kapi_yaninda_agir_kalkan_giris_sayilmaz():
    # Kapının hemen dışında (41 px) ilk görülen, kare başına 22 px ağır ağır
    # uzaklaşan araç: yolu kapıya ancak "payla" değer — hızlı geçiş değil
    # (kapının dibinde park etmiş, bulucunun o ana dek görmediği araç olabilir).
    s = _isin(Sahne(_takipci()))
    for i in range(6):
        s.kare([_arac(420 + 20 * i, 250 - 10 * i)])
    son = _arac(520, 200)
    s.kare([son]).bekle(2.5, [son])
    assert "GIRDI" not in s.turler(), s.turler()


def test_kapida_kalkan_park_arac_girdi_sayilmaz():
    # Kapı dışında DURARAK doğan araç (ilk iki görülmesi yerinde), sonra hızla
    # otoparka gider: hız kuralı yalnızca ilk iki görülmeye bakar.
    s = _isin(Sahne(_takipci()))
    a = _arac(500, 200)                                      # çapa (650, 400)
    s.kare([a]).kare([a])
    s.kare([_arac(780, 100)])                                # kare başına ~300 px: aynı iz
    son = _arac(1060, 20)
    s.kare([son]).bekle(2.5, [son])
    assert s.t._no == 1, s.t._no
    assert "GIRDI" not in s.turler(), s.turler()


def test_kapiya_giderken_otoparkta_kaybolan_cikis_sayilmaz():
    # Kapıya doğru hızla giderken otoparkın ortasında (kapıya bir kare yol
    # kala değil) bir şeyin arkasında kalan araç: çıkmış sayılmaz.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(1200, 100)]).bekle(3.0, [_arac(1200, 100)])
    s.kare([_arac(1000, 100)]).kare([_arac(800, 100)])       # çapa (950, 300)
    s.bekle(6.0, [])
    assert "CIKTI" not in s.turler(), s.turler()


def test_hizli_kapiya_gidip_otoparkta_duran_cikis_sayilmaz():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    s.kare([_arac(750, 200)])
    son = _arac(500, 250)                                    # kapının ~107 px dışında durdu
    s.kare([son]).bekle(3.0, [son])
    s.bekle(8.0, [])                                         # önünden biri geçti, uzun süre
    assert "CIKTI" not in s.turler(), s.turler()


# --------------------------------- 1.4.1: yalnızca TEK karede görülen araç ---
# Sahip (2026-11-09): "kırpmada görüldüyse yine gönderilmeli". Tek karede
# görülen aracın hızı yok, nereden geldiği bilinmez — 1.4.1'in ilk hâli onu
# sessizce düşürüyordu. Kapı alanında ya da bir kare yol yakınında ve GERÇEKTEN
# hareketli (pikselleri değişmiş) ise personele (Çözülmemiş kayıt). Otoparkın
# derinindeki tek kare (bulucunun bir an gördüğü park etmiş araç) gönderilmez.

def test_tek_karede_kapida_gorulen_hareketli_arac_personele():
    for kutu in ((500, 200), (100, 520)):                    # kapının 136 px dışı / içi
        s = _isin(Sahne(_takipci()))
        s.kare([])
        s.kare([_arac(*kutu)])
        s.bekle(6.0, [])
        assert s.turler() == ["TEK_KARE"], (kutu, s.turler())


def test_tek_karede_otoparkta_gorulen_sayilmaz():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    s.kare([_arac(1200, 100)])                               # kapıdan uzak
    s.bekle(6.0, [])
    assert "TEK_KARE" not in s.turler(), s.turler()


def test_tek_karede_kipirdamayan_park_araci_sayilmaz():
    # Kapının yanında park etmiş araç: bulucu onu yalnızca bir kare gördü,
    # pikselleri hiç değişmedi — gelen giden araç değil.
    s = _isin(Sahne(_takipci()))
    a = _arac(500, 200)
    for _ in range(4):
        s.kare([], cizim=[a])
    s.kare([a], cizim=[a])
    for _ in range(20):
        s.kare([], cizim=[a])
    assert "TEK_KARE" not in s.turler(), s.turler()


def _olaylar(s):
    return [(o.tur, o.iz.kaynak) for o in s.olaylar]


def test_tek_kare_plaka_izinde_yok_giren_araca_ikinci_kart_olmaz():
    # İnceleme (2026-11-09, ikinci tur): araç kapıdan girerken ilk karede
    # yalnızca ön plakası görüldü (gövde henüz yarısı görünmedi), sonra gövde
    # izlendi, plaka bir daha o yakında okunmadı. Plaka izcisinin tek karelik
    # izi TEK_KARE verip aracın GİRDİ'sinin yanına ikinci (personel) kart
    # açıyordu. Tek kare kuralı yalnızca ARAÇ izinde.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    yol = [(0, 600), (120, 520), (240, 440), (360, 360), (480, 300), (600, 260), (700, 240),
           (760, 230)]
    a0 = _arac(*yol[0])
    s.kare([], [plaka.Kutu(a0.x1 + 105, a0.y1 + 140, a0.x1 + 195, a0.y1 + 164, 0.9)], cizim=[a0])
    for x, y in yol[1:]:
        a = _arac(x, y)
        s.kare([a], [], cizim=[a])
    s.bekle(10.0, [a])
    assert _olaylar(s) == [("GIRDI", "arac")], _olaylar(s)


def test_tek_kare_devralinan_karari_tekrarlamaz():
    # İnceleme: koyu araç plakasıyla girdi, plaka izi GİRDİ verdi; lambanın
    # altında gövdesi BİR kez görüldü (araç izi devraldı), sonra yine karanlık
    # ve plaka okunmadı. Devralınan karar varken tek kare ikinci kart açmamalı.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    yol = [(0, 600), (120, 520), (240, 440), (360, 360), (480, 300), (600, 260), (700, 240)]
    for x, y in yol:
        s.kare([], [_pk(x, y)], cizim=[_arac(x, y)])
    x, y = yol[-1]
    for _ in range(10):
        s.kare([], [_pk(x, y)], cizim=[_arac(x, y)])
    a = _arac(x, y)
    s.kare([a], [_pk(x, y)], cizim=[a], doku={0: 120})
    for _ in range(25):
        s.kare([], [], cizim=[a], doku={0: 120})
    assert _olaylar(s) == [("GIRDI", "plaka")], _olaylar(s)


def test_tek_kare_onunden_gecilen_park_araci_sayilmaz():
    # İnceleme: kapının yanında park etmiş (izlenmeyen) araç; önünden geçen
    # aracın karesinde bulucu onu bir an gördü — pikselleri GEÇEN araç yüzünden
    # değişti. Aynı karede başka bir aracın kutusuyla örtüşen doğum "hareketli"
    # sayılmaz.
    s = _isin(Sahne(_takipci()))
    park = _arac(560, 250)
    for _ in range(4):
        s.kare([], cizim=[park], doku={0: 40})
    for i, x in enumerate([900, 800, 700, 620, 540, 460]):
        p = _arac(x, 300)
        s.kare([p] + ([park] if i == 3 else []), cizim=[park, p], doku={0: 40, 1: 120})
    for _ in range(25):
        s.kare([], cizim=[park], doku={0: 40})
    assert "TEK_KARE" not in s.turler(), _olaylar(s)


def test_tek_kare_yeniden_baglanmada_eski_goruntuyle_karsilastirmaz():
    # İnceleme: kamera koptu, 5 dk sonra geri geldi; ilk kare kopmadan önceki
    # (eski, belki başka ışıktaki) gri görüntüyle karşılaştırılıyordu — orada
    # duran her araç "hareketli" sayılıyordu.
    s = _isin(Sahne(_takipci()))
    for _ in range(3):
        s.kare([])
    s.t.kopma(s.mono)
    s.t.yeniden_baglandi()
    s.mono += 300
    park = _arac(560, 250)
    s.kare([park], cizim=[park], doku={0: 40})
    for _ in range(25):
        s.kare([], cizim=[park], doku={0: 40})
    assert "TEK_KARE" not in s.turler(), _olaylar(s)


def test_tek_karede_kapisiz_kipte_degismez():
    s = _isin(Sahne(_takipci(kapi=None)))
    s.kare([])
    s.kare([_arac(500, 200)])
    s.bekle(6.0, [])
    assert s.turler() == [], s.turler()


# -------------------------- 1.4.1: karanlıkta gövde görünmez, plaka görünür --
# Gece koyu araç: bulucu gövdeyi görmez, plaka okunur (plaka izi). Gövde bir
# lambanın altında görünür olunca iz araca GEÇMELİ (1.4.0: plaka izi silinir,
# araç izi otoparkta yeni doğar → giriş kaybolurdu); gövde kapıya yaklaşırken
# karanlığa girerse plaka aracı yaşatmalı (1.4.0: araç otoparkta kaybolur →
# çıkış kaybolurdu).

def _pk(x, y):
    """`_arac(x, y)` aracının plakası (kutunun alt orta kısmı)."""
    return plaka.Kutu(x + 105, y + 140, x + 195, y + 164, 0.9)


def test_karanlik_arac_plakayla_girip_isikta_gorunur():
    s = _isin(Sahne(_takipci()))
    for i in range(11):
        x, y = 50 + 85 * i, 600 - 45 * i
        s.kare([_arac(x, y)] if i >= 6 else [], [_pk(x, y)])   # gövde i=6'dan sonra görünür
    for _ in range(10):
        s.kare([_arac(900, 150)], [_pk(900, 150)])
    s.bekle(6.0, [_arac(900, 150)])
    assert s.turler().count("GIRDI") == 1, s.turler()
    assert "ICERIDE" not in s.turler(), s.turler()
    o = [o for o in s.olaylar if o.tur == "GIRDI"][0]
    assert o.iz.kaynak == "arac", o.iz
    # Plaka izinin kapıdaki 6 okuması da aracın oylamasında (araç kendisi 15).
    assert len(o.iz.gecis.yazilan) == 21, len(o.iz.gecis.yazilan)


def test_isikta_gorunen_arac_karanlikta_plakayla_cikar():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)], [_pk(900, 150)]).bekle(1.0, [_arac(900, 150)])
    iz = s.t.izler[0]
    # Gövde kapıdan UZAKTA (i=3'ten sonra) karanlığa girer: hız kuralı bir
    # adım ileriye bakar, kapıya yetişmez — çıkışı yalnızca plaka verebilir.
    for i in range(11):
        x, y = 900 - 84 * i, 150 + 45 * i
        s.kare([_arac(x, y)] if i < 3 else [], [_pk(x, y)])
    s.bekle(6.0, [])
    assert s.turler().count("CIKTI") == 1, s.turler()
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"] == [iz], s.olaylar
    assert not iz.kapida_gorulmedi, "çıkış plakayla izlenerek, kapıda verilmeli"
    assert "ICERIDE" not in s.turler(), s.turler()


def test_karanlikta_park_aracin_izini_gecen_plaka_alamaz():
    # Park etmiş (duran) A bir an görünmez (önünden koyu B geçiyor); B'nin
    # plakası A'nın kutusundan geçip kapıya gider. A'nın izi plakayla
    # SÜRÜKLENMEMELİ: yoksa A kapıdan "çıktı" sayılır, biletini kapatırdı.
    s = _isin(Sahne(_takipci()))
    a = _arac(900, 150)
    for _ in range(12):
        s.kare([a], [_pk(900, 150)])
    iz_a = s.t.izler[0]
    assert iz_a.duruyor
    for i in range(1, 11):
        x, y = 900 - 84 * i, 150 + 45 * i
        s.kare([] if i <= 3 else [a], [_pk(x, y)])
    s.bekle(6.0, [a])
    assert iz_a not in [o.iz for o in s.olaylar if o.tur == "CIKTI"], s.olaylar
    assert iz_a.kutu[:2] == (900, 150), iz_a.kutu


def test_karanlikta_yavas_gecen_plaka_park_araci_suruklemez():
    # Bağımsız inceleme (2026-11-09) buldu: koyu B park etmiş A'nın önünden
    # AĞIR geçerken (kare başına 50 px) ilk adım "yerinde" sayılıyor, A artık
    # "durmuyor", sonra B'nin plakası A'nın izini kapıya kadar sürüklüyordu →
    # A'nın biletini kapatan çıkış. Son GÖVDE görülmesinde duran araç plakayla
    # hiç ilerlemez.
    for adim in (50, 30):
        s = _isin(Sahne(_takipci()))
        a = _arac(900, 150)
        for _ in range(12):
            s.kare([a], [_pk(900, 150)])
        iz_a = s.t.izler[0]
        assert iz_a.duruyor
        for i in range(1, int(900 / adim) + 1):
            s.kare([], [_pk(900 - adim * i, 150 + adim * 0.54 * i)])   # A hep B'nin arkasında
        s.bekle(6.0, [a])
        assert iz_a not in [o.iz for o in s.olaylar if o.tur == "CIKTI"], (adim, s.olaylar)
        assert iz_a.kutu[:2] == (900, 150), (adim, iz_a.kutu)


def test_cikan_arac_giren_karanlik_aracin_plaka_izini_devralmaz():
    # İnceleme: çıkan A (gövdesi görünür, plakası ilk kez kapıya yakın okundu)
    # yakındaki giren koyu B'nin plaka izini devralıyor, "kapıdan doğmuş"
    # oluyor, kapıda kaybolunca U dönüşü sayılıyordu — A'nın çıkışı kayboluyordu.
    s = _isin(Sahne(_takipci()))
    for i in range(4):
        s.kare([], [_pk(60 + 10 * i, 560 - 5 * i)])
    for i in range(10):
        ax, ay = 700 - 80 * i, 250 + 40 * i
        pl = [_pk(100 + 10 * i, 540 - 5 * i)] + ([_pk(ax, ay)] if i >= 4 else [])
        s.kare([_arac(ax, ay)], pl)
    s.bekle(6.0, [])
    cikan = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
    assert len(cikan) == 1 and cikan[0].kaynak == "arac", s.olaylar


def test_yeni_gorunen_arac_kutusu_disindaki_plaka_izini_devralmaz():
    # Giren koyu B kapıda (plaka izi kapıda doğdu); çıkan A'nın gövdesi
    # kapının yakınında İLK KEZ görünür, plakası okunur. B'nin plaka izi
    # yakın (~270 px) ama A'nın kutusunda değil: A onu DEVRALMAMALI — yoksa
    # "kapıdan doğmuş" olur, kapıda kaybolunca çıkışı kaybolurdu.
    s = _isin(Sahne(_takipci()))
    for i in range(4):
        s.kare([], [_pk(410 + 3 * i, 488 - 2 * i)])
    yol = [(480, 230), (480, 230), (330, 280), (180, 330), (30, 380), (-120, 430)]
    for j, (ax, ay) in enumerate(yol, start=4):
        s.kare([_arac(ax, ay)], [_pk(ax, ay), _pk(410 + 3 * j, 488 - 2 * j)])
    s.bekle(6.0, [])
    cikan = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
    assert len(cikan) == 1 and cikan[0].kaynak == "arac", s.olaylar


def test_bosta_bekleme_sonrasi_hiz_kurali_fazla_geriye_bakmaz():
    # İnceleme: sahne boşken köprü 2 sn'de bir ölçer; ondan sonra doğan aracın
    # adımı 0.3 sn'de ölçüldüğü hâlde 1 sn geriye (3 adım) bakılıyordu —
    # kapının 128 px dışında park etmiş, bulucunun görmediği, ağır kalkan araç
    # "girdi" sayılıyordu. Geriye en çok 1.5 adım bakılır.
    s = _isin(Sahne(_takipci()))
    s.kare([], dt_sn=2.0)
    for i in range(8):
        s.kare([_arac(560 + 30 * i, 300 - 30 * i)], dt_sn=2.0 if i == 0 else 0.3)
    s.bekle(3.0, [_arac(770, 90)])
    assert "GIRDI" not in s.turler(), s.turler()


def test_otoparkta_plakasi_izlenen_arac_isikta_kalkinca_girdi_sayilmaz():
    # Koyu, park etmiş aracın plakası otoparkta (kapının 136 px dışında)
    # izleniyor; araç kalkınca gövdesi görünür oldu ve hızla kapıdan uzaklaştı.
    # Devraldığı plaka izi otoparkta doğmuştu: zaten içerideydi — hız kuralı
    # onu kapıdan gelmiş saymamalı.
    s = _isin(Sahne(_takipci()))
    for _ in range(5):
        s.kare([], [_pk(500, 200)])
    for x, y in ((500, 200), (830, 80), (1100, 20)):
        s.kare([_arac(x, y)], [_pk(x, y)])
    s.bekle(3.0, [_arac(1100, 20)])
    assert "GIRDI" not in s.turler(), s.turler()


def test_plaka_izinde_birlestirme_kapali():
    # Bağımsız inceleme (2026-11-09, B2): plaka izinin kutusu küçük — gürültüyle
    # 4 px oynayan DURAN bir plaka "yeni görünüm" sayılabilir; çok karede
    # birleştirme bağımsız bakış ister. Plaka izinde birleştirme kapalı; araç
    # izinde açık (araç izi plaka izini devralırsa onun kapalı oylamasını alır).
    class _Oy:
        birlesik = True

    def yeni():
        g = _Gecis()
        g.oylama = _Oy()
        return g

    t = takip.Takipci(EN, BOY, KAPI, yeni_gecis=yeni, yaz=_yaz)
    s = _isin(Sahne(t))
    s.kare([], [_pk(900, 150)])
    s.kare([_arac(300, 100)], [])
    assert t._plakaci.izler[0].gecis.oylama.birlesik is False
    assert t.izler[0].gecis.oylama.birlesik is True


def test_kapida_bekleyen_karanlik_arac_isiga_girince_girdi_sayilmaz():
    # Plaka izi kapıdan hiç çıkmadı (koyu araç kapıda bekledi), sonra gövdesi
    # kapıda görünür oldu ve geri gitti: giriş yok.
    s = _isin(Sahne(_takipci()))
    for _ in range(4):
        s.kare([], [_pk(100, 520)])
    for i in range(4):
        s.kare([_arac(100 - 20 * i, 520 + 20 * i)], [_pk(100 - 20 * i, 520 + 20 * i)])
    s.bekle(6.0, [])
    assert "GIRDI" not in s.turler(), s.turler()


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
    # 1.4.1: plaka izinin "kapıdan çıktı" bilgisi araca geçer — giriş kaybolmaz.
    assert s.turler().count("GIRDI") == 1, s.turler()


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
