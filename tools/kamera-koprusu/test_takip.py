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
        self._isle(self.t.guncelle(o))
        self._isle(self.t.zaman_gecti(self.mono))
        return self

    def _isle(self, olaylar):
        self.olaylar += olaylar

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


def test_kapidan_cikan_izine_giren_dikilmez():
    # 1.4.6 (sahibin kararı 26.11): araç kapıdan çıktı (kenara gidiyordu,
    # kayıp); DIKIS_SN dolmadan BAŞKA araç aynı yerden giriyor. Eskiden giren
    # araç çıkanın izine dikilirdi: ÇIKTI hiç verilmez (çıkanın bileti açık
    # kalır), giren aracın plakası çıkanın oylamasına yazılır, park edince
    # yalnızca içeride sorusu giderdi (girenin bileti yok).
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])   # park etmiş
    _yol(s, (900, 150), (60, 600), adim=10)                  # kapıdan kenara, çıktı
    cikan = s.t.izler[0]
    s.bekle(2.1, [])                                         # kayıp; 4 sn dolmadı
    assert cikan.durum == "kayip", cikan.durum
    _yol(s, (60, 600), (900, 150), adim=10)                  # başkası aynı yerden giriyor
    s.bekle(4.0, [_arac(900, 150)])                          # park etti
    cikti = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
    girdi = [o.iz for o in s.olaylar if o.tur == "GIRDI"]
    assert cikti == [cikan], s.turler()
    assert len(girdi) == 1 and girdi[0] is not cikan, s.turler()


def test_kapidan_cikana_kare_araliginda_giren_dikilmez():
    # Yavaş bilgisayarda kareler seyrek: çıkan araç kenarda kayboldu, iki boş
    # kare (0.6 sn — henüz kayıp değil), sonra 1.2 sn ölçülen kare yok ve ilk
    # ölçülen karede başkası aynı yerden giriyor. "Kayıp" karenin SONUNDA
    # işaretlendiği için eskiden iz hâlâ "izleniyor"du, giren ona dikilirdi
    # (test_kopru takip_iki_yon_hizli yük altında 1/10). Kayıp, BU kare de
    # kaçırma sayılarak bu karede yargılanır.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (60, 600), adim=10)
    cikan = s.t.izler[0]
    s.kare([]).kare([])
    assert cikan.durum == "izleniyor" and cikan.kacirma == 2, (cikan.durum, cikan.kacirma)
    s.kare([_arac(60, 600)], dt_sn=1.2)                      # son görülmeden 1.8 sn sonra
    _yol(s, (60, 600), (900, 150), adim=10)
    s.bekle(4.0, [_arac(900, 150)])
    cikti = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
    girdi = [o.iz for o in s.olaylar if o.tur == "GIRDI"]
    assert cikti == [cikan], s.turler()
    assert len(girdi) == 1 and girdi[0] is not cikan, s.turler()


def test_kapidan_cikan_plaka_izine_giren_dikilmez():
    # Aynı kural yalnız plakası görülen (gövdesi bulunmayan, karanlık) araçta:
    # plaka izi kapıdan resmin kenarına gidip kayboldu; 2 sn sonra aynı
    # yerden başka plaka giriyor — ayrı iz (sahibin kararı 26.11, "Extend").
    s = _isin(Sahne(_takipci()))
    for _ in range(10):                                      # otoparkta duruyor
        s.kare([], [plaka.Kutu(900, 200, 990, 225, 0.9)])
    for i in range(1, 16):                                   # kapıdan sol alt köşeye
        x, y = 900 - 60 * i, 200 + 575 * i / 15
        s.kare([], [plaka.Kutu(x, y, x + 90, y + 25, 0.9)])
    cikan = s.t._plakaci.izler[0]
    assert any(cikan.kenar_son) and cikan.disarida_bulundu, (cikan.kenar_son, cikan.disarida_bulundu)
    s.bekle(2.1, [])
    assert cikan.durum == "kayip", cikan.durum
    for i in range(15):                                      # başkası giriyor
        x, y = 60 * i, 775 - 575 * i / 15
        s.kare([], [plaka.Kutu(x, y, x + 90, y + 25, 0.9)])
    s.bekle(6.0, [])
    cikti = [o.iz for o in s.olaylar if o.tur == "CIKTI"]
    girdi = [o.iz for o in s.olaylar if o.tur == "GIRDI"]
    assert cikti == [cikan], s.turler()
    assert len(girdi) == 1 and girdi[0] is not cikan and girdi[0].kaynak == "plaka", s.turler()


def test_cikan_arac_kapida_kisa_ortulunce_ayni_iz():
    # Aynı kural çıkan aracı bölmemeli: kapıda 2 kare (0.6 sn) örtülüp
    # (henüz "kayıp" değil) kenara devam eden araç TEK iz, TEK çıkış.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (330, 450), adim=6)                  # kapıya geldi
    iz = s.t.izler[0]
    s.bekle(0.6, [])                                         # önünden biri geçti
    assert iz.durum == "izleniyor", iz.durum
    _yol(s, (250, 500), (60, 600), adim=3)
    s.bekle(6.0, [])
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"] == [iz], s.turler()
    assert s.t._no == 1, s.t._no


def test_kapida_kenara_varmadan_kaybolan_dikilir():
    # Kapının ortasında 2 sn örtülen (kayıp) ama resmin kenarına henüz
    # VARMAMIŞ araç, yolunda yeniden görülünce aynı iz: kapıdan çıkmış
    # sayılmaz (çıkış kenarda olur).
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (330, 450), adim=6)                  # kapıda, kenarda değil
    iz = s.t.izler[0]
    assert not any(iz.kenar_son), iz.kenar_son
    s.bekle(2.1, [])
    assert iz.durum == "kayip", iz.durum
    _yol(s, (200, 520), (60, 600), adim=3)
    s.bekle(6.0, [])
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"] == [iz], s.turler()
    assert s.t._no == 1, s.t._no


def test_kenardan_cikarken_kisa_ortulen_ayni_iz():
    # Kapıda resmin alt kenarına değerek çıkan araç 1.2 sn örtülür (henüz
    # kayıp değil: 1.5 sn dolmadı) ve 400 px ileride (hızıyla tahmin edilen
    # yerin de ötesinde: olağan eşleşme değil, dikiş) yine kenarda görülür:
    # aynı iz — kayıp sayılmamış iz kapıdan çıkmış değildir.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (400, 600), adim=12)                 # kapıda, alt kenara değiyor
    iz = s.t.izler[0]
    assert s.t._no == 1, s.t._no
    assert any(iz.kenar_son) and s.t._kapida(s.t._capa(iz.kutu)), iz.kutu
    s.bekle(1.2, [])
    assert iz.durum == "izleniyor", iz.durum
    _yol(s, (0, 600), (0, 600), adim=1)
    s.bekle(6.0, [])
    assert [o.iz for o in s.olaylar if o.tur == "CIKTI"] == [iz], s.turler()
    assert s.t._no == 1, s.t._no


def test_otoparkta_kenarda_ortulen_dikilir():
    # Otoparkın sağ kenarında (kapıdan uzak) yürüyen araç 2 sn örtülür:
    # kenara değiyordu ama kapıda değildi — kapıdan çıkmış sayılmaz, dikilir.
    s = _isin(Sahne(_takipci()))
    _ = _yol(s, (1300, 60), (1300, 250), adim=4)
    iz = s.t.izler[0]
    assert any(iz.kenar_son) and not s.t._kapida(s.t._capa(iz.kutu)), iz.kutu
    s.bekle(2.1, [])
    assert iz.durum == "kayip", iz.durum
    _yol(s, (1300, 400), (1300, 420), adim=2)
    assert s.t._no == 1, s.t._no


def test_kapida_kenarda_duran_ortulunce_yerinde_dikilir():
    # Otoparktan gelip kapıda alt kenara değerek DURAN araç (bariyer) 2 sn
    # örtülür (kayıp) ve YERİNDE yeniden görülür: aynı iz, çıkış yok.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    son = _yol(s, (900, 150), (300, 600), adim=12)
    assert s.t._no == 1, s.t._no
    s.bekle(3.0, [son])                                      # duruyor
    iz = s.t.izler[0]
    assert iz.duruyor and any(iz.kenar_son), (iz.duruyor, iz.kenar_son)
    s.bekle(2.1, [])
    assert iz.durum == "kayip", iz.durum
    s.bekle(1.0, [son])
    assert s.t._no == 1 and "CIKTI" not in s.turler(), (s.t._no, s.turler())


def test_kapida_dogup_kenarda_ortulen_dikilir():
    # Kapıda (alt kenarda) doğan, otoparka hiç geçmemiş araç 2 sn örtülür:
    # kapıdan "çıkmış" sayılmaz (hiç girmedi) — yerinde yeniden görülünce
    # aynı iz (eskisi gibi).
    s = _isin(Sahne(_takipci()))
    _yol(s, (60, 600), (120, 600), adim=3)
    iz = s.t.izler[0]
    assert not iz.disarida_bulundu and any(iz.kenar_son), (iz.disarida_bulundu, iz.kenar_son)
    s.bekle(2.1, [])
    assert iz.durum == "kayip", iz.durum
    _yol(s, (120, 600), (160, 600), adim=2)
    assert s.t._no == 1, s.t._no


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


def test_kapida_durup_ortulen_cikan_arac_sonra_cikinca_cikti():
    # 1.4.3: otoparktan gelen araç kapıda durdu, ≥ 4 sn görünmedi (park
    # belleğine gitti), aynı yerde yeniden doğdu ve kenardan çıktı. Park
    # belleği "otoparkta görülmüştü"yü unutuyordu: yeniden doğan iz kapıda
    # doğduğu için hiç otoparkta görülmemiş sayılıyor, çıkışı KAPIDA_KAYBOLDU
    # kartı oluyordu. Bellek bunu taşır: ÇIKTI, kart yok.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    son = _yol(s, (900, 150), (150, 500), adim=8)            # kapıya geldi
    s.bekle(3.0, [son])                                      # bekliyor
    s.bekle(8.0, [])                                         # önünden araç geçti
    assert "CIKTI" not in s.turler(), s.turler()
    s.kare([son]).bekle(1.0, [son])                         # yeniden göründü
    _yol(s, (150, 500), (60, 600), adim=6)                   # kenardan çıkıyor
    s.bekle(6.0, [])
    assert s.turler().count("CIKTI") == 1, s.turler()
    assert "KAPIDA_KAYBOLDU" not in s.turler(), s.turler()


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


class _Olcumler(list):
    """okuma.PlakaOlcumleri gibi: liste + olcek + kirpiklar (aynı sırada)."""


def test_ize_yazilan_olcum_kirpiklarini_korur():
    # 1.4.6 L: izci karenin plaka ölçümlerini izlere bölerken her kutunun
    # tam çözünürlük kırpığı ve oranı da o ize gider (plaka kırpığı, teşhis).
    gelen = []
    t = takip.Takipci(EN, BOY, KAPI, yeni_gecis=_Gecis,
                      yaz=lambda g, kirpik, z, gor, olc: gelen.append(olc))
    s = _isin(Sahne(t))
    s.kare([_arac(900, 100)])
    a, b = _arac(900, 100), _arac(200, 100)
    pa = plaka.Kutu(1005, 240, 1095, 264, 0.9)               # a'nın plakası
    pb = plaka.Kutu(305, 240, 395, 264, 0.9)                 # b'nin plakası
    olc = _Olcumler([(pb, None), (pa, None)])
    olc.olcek, olc.kirpiklar = 2.0, ["kirpik-b", "kirpik-a"]
    s.no += 1
    s.mono += 0.3
    o = takip.Olcum(s.no, s.mono, T0 + dt.timedelta(seconds=s.mono - 100.0),
                    np.zeros((4, 4, 3), np.uint8), np.zeros((120, 160), np.uint8), [a, b], olc)
    t.guncelle(o)
    assert gelen, "plaka ize yazılmadı"
    for liste in gelen:
        assert getattr(liste, "olcek", None) == 2.0, liste
        beklenen = {pa: "kirpik-a", pb: "kirpik-b"}
        assert list(liste.kirpiklar) == [beklenen[k] for k, _ in liste], (list(liste), liste.kirpiklar)


def test_giris_bekleyen_iz_bilinir():
    # 1.4.6 E2 (sahibin kararı 25.11): içeride sorusu, kapıdan giren aracın
    # kararı beklenirken ertelenir — izci "giriş bekleyen var mı" der.
    t = _takipci()
    s = _isin(Sahne(t))
    assert not t.giris_bekliyor()
    s.kare([_arac(50, 600)]).kare([_arac(58, 594)])           # kapıda doğdu, kararsız
    assert t.giris_bekliyor()
    assert not t.giris_bekliyor(haric=t.izler[-1]), "soran iz kendini saymaz"
    son = _yol(s, (66, 588), (900, 150), adim=10)            # kapıdan geçti, durmadı
    assert "GIRDI" not in s.turler(), s.turler()
    assert t.giris_bekliyor()
    s.bekle(2.5, [son])
    assert s.turler().count("GIRDI") == 1, s.turler()
    assert not t.giris_bekliyor(), "karar verildi"
    t = _takipci()
    s = _isin(Sahne(t))
    s.kare([_arac(900, 100)]).bekle(1.0, [_arac(900, 100)])
    _yol(s, (900, 100), (1200, 300), adim=8)                 # otopark içinde gezen
    assert not t.giris_bekliyor()


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
    # 1.4.3: zamanı DOĞDUĞU an (hız kuralı) — kayıpta son görüldüğü an değil
    # (_kapidan_cikip_kayboldu_mu da GİRDİ derdi, ama son görülmenin anıyla).
    o = [o for o in s.olaylar if o.tur == "GIRDI"][0]
    assert o.zaman == o.iz.dogum_zaman, (o.zaman, o.iz.dogum_zaman)


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


def test_giris_kapidan_bir_kare_cikip_kaybolan():
    # 1.4.3 (test_kopru takip_park_gorunur_disaridan_giris_kapali, 20.11):
    # kapıda doğan araç kapının payı dışında YALNIZCA BİR karede görülüp
    # kayboldu (alanın gri yerine girdi / bir şeyin arkasına). İki kare kuralı
    # (GIRIS_KARE) dolmadığı için iz kararsız bitiyordu: ne bilet ne kart.
    # Son adımı kapıdan uzaklaşıyordu (_kapiya_gitti_mi'nin aynası): GİRDİ.
    # Pay 35.8 px; kapının eğik kenarı x = 520 + (y − 450)·240/350.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(50, 600)])                                 # çapa (200, 799.5): kapıda
    s.kare([_arac(200, 500)])                                # çapa (350, 700): kapıda
    s.kare([_arac(560, 360)])                                # çapa (710, 560): ~94 px dışarıda
    s.bekle(6.0, [])
    assert s.turler().count("GIRDI") == 1, s.turler()
    assert "ICERIDE" not in s.turler(), s.turler()


def test_giris_disari_cikip_kapiya_donerken_kaybolan_girmedi():
    # Kapıdan bir kare çıkıp kapıya DÖNERKEN (son adım kapıya doğru) kapının
    # hemen dibinde (pay içinde, tolerans dışında) kaybolan araç girdi sayılmaz.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(50, 600)])                                 # çapa (200, 799.5): kapıda
    s.kare([_arac(200, 500)])                                # çapa (350, 700): kapıda
    s.kare([_arac(560, 360)])                                # çapa (710, 560): ~94 px dışarıda
    s.kare([_arac(497, 400)])                                # çapa (647, 600): ~20 px dışarıda
    assert len(s.t.izler) == 1, s.t.izler                    # tek iz: dört kare aynı araç
    s.bekle(6.0, [])
    assert "GIRDI" not in s.turler(), s.turler()


def test_kapida_duran_aracin_kutusu_bir_kez_titreyip_kaybolan_girmedi():
    # Kapının kenarında DURAN aracın kutusu bir karede payın dışına titredi,
    # sonra yine yerinde durdu ve kayboldu: son adımı yok denecek kadar kısa.
    s = _isin(Sahne(_takipci()))
    yer = _arac(450, 400)                                    # çapa (600, 600): kapıda
    s.bekle(3.0, [yer])
    s.kare([_arac(520, 400)])                                # çapa (670, 600): ~39 px dışarıda
    s.bekle(3.0, [yer])
    s.bekle(6.0, [])
    assert "GIRDI" not in s.turler(), s.turler()


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
    # hiç ilerlemez. 1.4.5 C: iki eşlemede de (BYTE_ESLES açıkken ByteTrack
    # turları da korur; kapalıyken yalnızca bu kilit).
    for byte_esles, adim in ((True, 50), (True, 30), (False, 50), (False, 30)):
        s = _isin(Sahne(_takipci(byte_esles=byte_esles)))
        a = _arac(900, 150)
        for _ in range(12):
            s.kare([a], [_pk(900, 150)])
        iz_a = s.t.izler[0]
        assert iz_a.duruyor
        for i in range(1, int(900 / adim) + 1):
            s.kare([], [_pk(900 - adim * i, 150 + adim * 0.54 * i)])   # A hep B'nin arkasında
        s.bekle(6.0, [a])
        assert iz_a not in [o.iz for o in s.olaylar if o.tur == "CIKTI"], (byte_esles, adim,
                                                                          s.olaylar)
        assert iz_a.kutu[:2] == (900, 150), (byte_esles, adim, iz_a.kutu)


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


# ------------------------------ 1.4.2 (A2): hiçbir iz sessizce bitmez ---------
# Sahada 11.11: 07:38, 19:15, 19:39, 12:10, 12:38 çıkan araçlar ne bilet ne
# kayıt satırı bıraktı. Hızlı ya da koyu araç ilk kez kapı alanında (ya da
# kapının "pay"ı içinde) bulundu ve kenardan çıktı: hiç otoparkta görülmediği
# için ÇIKTI sayılmadı, _son_karar sessizce döndü. 1.4.2: kapıda kaybolan,
# hareketli, kararsız araç izi personele (yönü bilinmez — KAPIDA_KAYBOLDU);
# kararsız biten her başka araç izi bir kayıt notu (kararsiz_al).

def _yerler(s):
    return [yer for _, yer in s.t.kararsiz_al()]


def test_kapida_dogup_kapida_kaybolan_arac_personele():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _yol(s, (150, 480), (60, 600), adim=3)                   # çapa (300, 680) → kenar
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()
    assert s.olaylar[0].iz.kaynak == "arac"
    assert _yerler(s) == [], "personele giden iz ayrıca kararsız yazılmaz"


def test_kapida_donen_arac_isaretlenir():
    # 1.4.6 J (sahibin kararı 25.11): 23–24.11 11:14, 16:48, 05:16 (polis
    # aracı): araç kenardan kapı alanına girip AYNI kenardan geri çıktı —
    # çizgiyi hiç geçmedi. KAPIDA_KAYBOLDU olayı kalır, iz `kenarda_dondu`
    # işaretlenir (köprü plakasızsa kart açmaz).
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _yol(s, (0, 500), (150, 520), adim=4)                    # sol kenardan girer
    _yol(s, (150, 520), (0, 540), adim=4)                    # sol kenara döner
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()
    assert s.olaylar[0].iz.kenarda_dondu is True
    # Sol kenardan doğup ALT kenardan kaybolan: dönmedi (yönü bilinmez, kart).
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _yol(s, (0, 500), (200, 600), adim=6)                    # kutu alt kenara değer
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()
    assert s.olaylar[0].iz.kenarda_dondu is False
    # Kenara değmeden doğan (kapının içinde bulunan) araç: işaret yok.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _yol(s, (150, 480), (60, 600), adim=3)
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()
    assert s.olaylar[0].iz.kenarda_dondu is False
    # Kenarda tek görünümlük şerit (çıkan aracın kuyruğu, takip_kenar_kuyrugu):
    # içeri girip dönmedi — işaret yok; onu TEK_KARAR / IZ_ONAY tartar.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _yol(s, (150, BOY - 40), (150, BOY - 40), adim=2, w=260, h=40)
    s.bekle(6.0, [])
    assert s.olaylar and s.olaylar[0].iz.gorunum_no <= 1, \
        [(o.tur, o.iz.gorunum_no) for o in s.olaylar]
    assert s.olaylar[0].iz.kenarda_dondu is False


def test_kapi_payinda_dogup_kapida_kaybolan_arac_personele():
    # test_kapi_sinirinda_dogan_arac_kapida_kaybolunca_cikis_sayilmaz'ın yolu:
    # ÇIKTI hâlâ sayılmaz (nereden geldiği bilinmez) ama sessizce de düşmez.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(410, 268)])
    _yol(s, (410, 268), (60, 600), adim=4)
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()


def test_kapida_duran_arac_kaybolunca_personele_gitmez():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    son = _yol(s, (150, 480), (100, 560), adim=3)
    s.bekle(3.0, [son])                                      # durdu
    s.bekle(8.0, [])                                         # örtüldü
    assert "KAPIDA_KAYBOLDU" not in s.turler(), s.turler()
    assert _yerler(s) == [], "duran araç park belleğine gider — kararsız değil"


def test_plaka_izi_kapida_kaybolunca_personele_gitmez():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    for x, y in [(150, 480), (120, 520), (90, 560), (60, 600)]:
        s.kare([], [_pk(x, y)], cizim=[_arac(x, y)])
    s.bekle(6.0, [])
    assert "KAPIDA_KAYBOLDU" not in s.turler(), _olaylar(s)
    assert _yerler(s) == [], "plaka izi kayıt notu yazmaz"


def test_geri_donen_arac_kapida_kaybolunca_yalniz_geri_dondu():
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (520, 300), adim=4)
    _yol(s, (520, 300), (50, 600), adim=4)
    s.bekle(6.0, [])
    assert "GERI_DONDU" in s.turler() and "KAPIDA_KAYBOLDU" not in s.turler(), s.turler()


def test_kapida_tek_karede_kipirdamayan_personele_gitmez_kayda_yazilir():
    s = _isin(Sahne(_takipci()))
    a = _arac(100, 520)                                      # kapının içinde, park etmiş gibi
    for _ in range(4):
        s.kare([], cizim=[a])
    s.kare([a], cizim=[a])
    for _ in range(20):
        s.kare([], cizim=[a])
    assert s.turler() == [], s.turler()
    assert _yerler(s) == ["kapı"]


def test_kararsiz_biten_iz_kayda_yazilir():
    # Otoparkın derininde bir kare görülen araç: gönderilmez, ama kayıtta.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    s.kare([_arac(1200, 100)])
    s.bekle(6.0, [])
    assert "TEK_KARE" not in s.turler(), s.turler()
    assert _yerler(s) == ["otopark"]
    assert s.t.kararsiz_al() == [], "alınan notlar bir daha verilmez"
    # Otoparkta görülmüş, kapıda kaybolmuş ama kenara gitmiyordu: ÇIKTI değil,
    # personele kart da değil (kapı yanında manevra olabilir) — yalnızca kayıt.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(1.0, [_arac(900, 150)])
    _yol(s, (900, 150), (150, 480), adim=6)
    _yol(s, (150, 480), (260, 420), adim=2)
    s.bekle(6.0, [])
    assert not ({"CIKTI", "KAPIDA_KAYBOLDU"} & set(s.turler())), s.turler()
    assert _yerler(s) == ["kapı"]
    # Kapı alanı yokken de (olay listesi değişmez, yalnızca not).
    s = _isin(Sahne(_takipci(kapi=None)))
    s.kare([])
    s.kare([_arac(500, 200)])
    s.bekle(6.0, [])
    assert s.turler() == [], s.turler()
    assert _yerler(s) == ["otopark"]


def test_karar_verilen_ya_da_duran_iz_kararsiz_yazilmaz():
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (60, 600), adim=10)
    s.bekle(6.0, [])
    assert s.turler().count("CIKTI") == 1 and _yerler(s) == [], s.turler()
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (50, 600), (900, 150), adim=10)
    s.bekle(3.0, [son]).bekle(8.0, [])
    assert s.turler().count("GIRDI") == 1 and _yerler(s) == [], s.turler()


def test_kenardan_cikan_aracin_kuyrugu_komsulu_dogar():
    # 1.4.2 (A3 koruması): araç alt kenardan çıkarken resimde yalnızca kuyruğu
    # kalır; kutusu çok küçüldüğü için (alan oranı DIKIS_ALAN dışında) kendi
    # izine dikilmez, tek karelik YENİ iz doğar (test_kopru'da 0.39 ile
    # personele kart açtı). Bu iz "komşulu" doğar: yanında, bir saniye içinde
    # görülmüş başka bir araç izi var — tek kare eşiği onda 0.60 kalır.
    s = _isin(Sahne(_takipci()))
    s.kare([_arac(900, 150)]).bekle(3.0, [_arac(900, 150)])
    _yol(s, (900, 150), (60, 560), adim=8)                   # kapıda, kenarın dibinde
    s.kare([A(60, 740, 360, 800, 0.4)])                      # yalnızca kuyruğu (alan ×0.3)
    yeni = [z for z in s.t.izler if z.gorulme == 1]
    assert len(yeni) == 1 and yeni[0].dogumda_komsu, s.t.izler
    s.bekle(6.0, [])
    tek = [o for o in s.olaylar if o.tur == "TEK_KARE"]
    assert tek and all(o.iz.dogumda_komsu for o in tek), _olaylar(s)


def test_yalniz_tek_kare_komsusuz_dogar():
    # 13:52'deki gibi YALNIZ görülen araç: komşusuz (doğum eşiği geçerli).
    s = _isin(Sahne(_takipci()))
    s.kare([])
    s.kare([_arac(100, 520)])
    s.bekle(6.0, [])
    assert s.turler() == ["TEK_KARE"] and not s.olaylar[0].iz.dogumda_komsu
    # Uzakta park etmiş (izlenen) araç komşu sayılmaz: komşu = bir araç
    # köşegeni içinde.
    s = _isin(Sahne(_takipci()))
    park = _arac(1200, 100)
    s.kare([park]).bekle(2.0, [park])
    s.kare([park, _arac(100, 520)])
    s.bekle(6.0, [park])
    tek = [o for o in s.olaylar if o.tur == "TEK_KARE"]
    assert len(tek) == 1 and not tek[0].iz.dogumda_komsu, _olaylar(s)


# ----------------------- 1.4.2 (A4): kapıdan görülmeden girip hemen duran araç --
# Sahada 11.11 19:08: giren araç kapı alanından geçerken bulucu onu yakalamadı,
# kapının hemen dışında DURURKEN buldu. Duran doğum bilerek giriş sayılmıyor
# (kapının dibinde park etmiş araç da böyle görünür) → "otopark içinde hareket",
# hiçbir şey gönderilmedi. Ayırt eden: az önce (≤ KAPI_GECIS_SN) kapı alanının
# pikselleri değişti ve bunu izlenen hiçbir araç açıklamıyor — bir şey kapıdan
# geçti. O zaman kapının bir araç boyu yakınında, duran, yeni doğan, yanında
# başka araç olmayan iz kapıdan gelmiştir ("kapıda görülmedi"). Yalnızca B5
# ile: yanılırsa sunucu GIRDI ipucunu görür, eski bileti kapatmaz.

GECEN = [(60, 600), (100, 450), (130, 300)]                  # kapıdan içeri (çizilir, bulunmaz)
DURAN = (150, 180)                                           # çapa (300, 380): kapının 70 px dışı


def _kapidan_gorulmeden_gecer(s, ek=()):
    for x, y in GECEN:
        s.kare(list(ek), cizim=list(ek) + [_arac(x, y)])


def test_kapidan_gorulmeden_girip_duran_arac_girdi():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _kapidan_gorulmeden_gecer(s)
    a = _arac(*DURAN)
    s.kare([a]).bekle(3.0, [a])
    assert s.turler() == ["GIRDI"], s.turler()
    assert s.olaylar[0].iz.kapida_gorulmedi, "kayıtta 'kapıda görülmedi' yazmalı"


def test_kapi_yaninda_duran_dogum_kapi_kipirtisi_yoksa_girdi_degil():
    s = _isin(Sahne(_takipci()))
    for _ in range(4):
        s.kare([])
    a = _arac(*DURAN)
    s.kare([a]).bekle(3.0, [a])
    assert "GIRDI" not in s.turler(), s.turler()


def test_kapi_kipirtisi_eskiyse_girdi_degil():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _kapidan_gorulmeden_gecer(s)
    s.bekle(4.0, [])                                         # KAPI_GECIS_SN'den uzun
    a = _arac(*DURAN)
    s.kare([a]).bekle(3.0, [a])
    assert "GIRDI" not in s.turler(), s.turler()


def test_kapi_kipirtisini_izlenen_arac_aciklarsa_girdi_degil():
    # Kapıdaki değişimi kapıda İZLENEN bir araç yapıyor (sağ tarafta, yeni
    # doğanın bir araç boyundan uzağında): kimse görülmeden geçmedi.
    s = _isin(Sahne(_takipci()))
    s.kare([])
    for x in (360, 400, 440):
        s.kare([_arac(x, 600)])                              # çapa (510..590, 800): kapıda
    b = _arac(440, 600)
    a = _arac(*DURAN)
    s.kare([b, a]).bekle(3.0, [b, a])
    tur = [o.tur for o in s.olaylar if o.iz.dogum_kutu == a]
    assert "GIRDI" not in tur, _olaylar(s)


def test_kapidan_gecis_sonrasi_komsulu_duran_dogum_girdi_degil():
    # Yeni doğanın hemen yanında izlenen (park etmiş) bir araç var: kapıdaki
    # değişim ona ya da yanındaki bir harekete ait olabilir — kural uygulanmaz.
    s = _isin(Sahne(_takipci()))
    park = _arac(500, 150)                                   # çapa (650, 350)
    s.kare([park]).bekle(2.5, [park])
    _kapidan_gorulmeden_gecer(s, ek=(park,))
    a = _arac(*DURAN)
    s.kare([park, a]).bekle(3.0, [park, a])
    assert "GIRDI" not in s.turler(), _olaylar(s)


def test_kapidan_gecis_sonrasi_uzakta_duran_dogum_girdi_degil():
    s = _isin(Sahne(_takipci()))
    s.kare([])
    _kapidan_gorulmeden_gecer(s)
    a = _arac(1000, 100)                                     # kapıdan bir araç boyundan uzak
    s.kare([a]).bekle(3.0, [a])
    assert "GIRDI" not in s.turler(), s.turler()


def test_kopmada_hareketli_kararsiz_iz_kayda_yazilir():
    s = _isin(Sahne(_takipci()))
    _yol(s, (900, 100), (1100, 100), adim=3)                 # otoparkta gidiyor
    assert s.t.kopma(s.mono) == []
    assert _yerler(s) == ["otopark"]
    s = _isin(Sahne(_takipci()))
    _yol(s, (50, 600), (900, 150), adim=10)                  # GİRDİ bekliyor: olay olur
    assert [o.tur for o in s.t.kopma(s.mono)] == ["GIRDI"]
    assert _yerler(s) == []
    s = _isin(Sahne(_takipci()))
    son = _yol(s, (900, 100), (1000, 100), adim=3)
    s.bekle(3.0, [son])                                      # durmuş (park)
    s.t.kopma(s.mono)
    assert _yerler(s) == [], "duran araç kopmada kararsız sayılmaz"


# ---------------------- 1.4.5 A: bir geçiş = bir karar (takip.Gecitci) ------
# Sahada bir aracın İKİNCİ izi (lastik, köşe, kenar parçası, kutu içinde kutu)
# doğru biletin yanında ikinci bir kart açtı:
#   · kuyruk: 16.11 22:26, iz 367 ÇIKTI, 2 sn sonra iz 368 KAPIDA_KAYBOLDU (lastik);
#   · baş: 17.11 09:36, iz 448 TEK_KARE (kenar parçası), 4 sn sonra iz 449 GİRDİ;
#   · aynı karelerde: 21.11 18:10:39, iz 75 ÇIKTI plakalı + iz 77 kart;
#   · kutu içinde kutu: 21.11 16:30, iz 6 / iz 7 ikisi de GİRDİ, biri plakasız.
# 1.4.3'ün Emici'si yalnızca kenara değen, araçla aynı karede GÖRÜLMEYEN parçayı
# sayıyordu ve sahada kapalıydı (PARCA_EMME=0). Gecitci: kart olacak olay
# (plakasız / yönü bilinmeyen) bekletilir; aynı geçişin kararı (ele alınmış
# olay) varsa kartı gönderilmez, yoksa geçiş başına BİR kart gider.

class GecSahne(Sahne):
    """Olaylar Gecitci'den geçer; `gonderilen` gönderim sırası, `satirlar` kayıt."""

    def __init__(self, t, acik=True, ele_alindi=None, kart=None, ikiz_sn=None):
        super().__init__(t)
        self.gonderilen: list = []           # (olay, mono)
        self.uretilen: list = []             # (olay, mono)
        self.satirlar: list[str] = []
        self.birakilan: list = []            # (parça olayı, gerçek olay, mono) — klip için
        self.ele_alindi = ele_alindi or (lambda o: True)
        self.kart = kart
        ek = {} if ikiz_sn is None else {"ikiz_sn": ikiz_sn}
        self.e = takip.Gecitci(gonder=self._gonder, kart_mi=self._kart_mi,
                               plakalar=lambda g: getattr(g, "plakalar", set()),
                               yaz=self.satirlar.append, acik=acik,
                               birakinca=lambda p, r, m: self.birakilan.append((p, r, m)),
                               **ek)

    def _kart_mi(self, olay, mono):
        """Sahte karar: geçişin `kart`ı yoksa yönü bilinmeyen olay karttır."""
        if self.kart is not None:
            return self.kart(olay)
        return getattr(olay.iz.gecis, "kart", olay.tur in takip.YONSUZ_OLAYLAR)

    def _gonder(self, olay, mono):
        self.gonderilen.append((olay, mono))
        return self.ele_alindi(olay)

    def _isle(self, olaylar):
        self.olaylar += olaylar
        self.uretilen += [(o, self.mono) for o in olaylar]
        self.e.al(self.t, olaylar, self.mono)

    def giden(self):
        return [o.tur for o, _ in self.gonderilen]

    def sayildi(self):
        return [x for x in self.satirlar if "sayıldı" in x]


def _kuyruklu_cikis(s, tekerlek=True):
    """iz 367/368: park etmiş araç kapıdan alt kenara çıkar; ardından lastiği iki kare."""
    _isin(s)
    park = _arac(900, 150)
    s.kare([park]).bekle(3.0, [park])
    _yol(s, (900, 150), (200, 600), adim=10)                 # alt kenara değiyor
    s.kare([A(200, 650, 500, 800, 0.8)])                     # kenardan çıkıyor
    s.kare([A(200, 700, 500, 800, 0.7)])
    if tekerlek:
        s.kare([A(230, 760, 330, 800, 0.6)])                 # yalnızca lastik (alan ×0.13)
        s.kare([A(236, 762, 336, 800, 0.6)])
    return s


def _parcali_giris(s, adim=10):
    """iz 448/449: alt kenarda bir kare köşe parçası, sonra aracın kendisi girer."""
    _isin(s)
    s.kare([])
    s.kare([A(350, 760, 500, 800, 0.46)])                    # parça (aracın 1/10'u)
    s.kare([])                                               # bulucu bir kare kaçırdı
    son = _yol(s, (200, 600), (900, 150), adim=adim)         # araç kenardan doğar, girer
    return s, son


def _izler_ve_parca(s):
    return sorted(s.t.izler, key=lambda z: z.dogum_mono)


def test_gecit_kuyruk_parcasinin_karti_gitmez():
    s = _kuyruklu_cikis(GecSahne(_takipci()))
    s.bekle(8.0, [])
    assert s.turler() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.turler()
    assert s.giden() == ["CIKTI"], s.giden()
    cikti, parca = s.olaylar[0].iz, s.olaylar[1].iz
    assert len(s.sayildi()) == 1 and f"iz {parca.id} → iz {cikti.id}" in s.sayildi()[0], s.satirlar
    # 1.4.6 C'nin ikiz kuralı da bu parçayı düşürürdü: neden aynı geçiş olmalı.
    assert "ikiz" not in s.sayildi()[0], s.sayildi()
    assert s.e.son_saat(s.mono) == (0, 1)
    assert s.e.son_saat(s.mono + 3601) == (0, 0), "son bir saat"
    # Klip için bir kez: (parça olayı, gerçek izin olayı).
    assert [(p.tur, r.tur) for p, r, _ in s.birakilan] == [("KAPIDA_KAYBOLDU", "CIKTI")]
    assert s.birakilan[0][0] is s.olaylar[1] and s.birakilan[0][1] is s.olaylar[0]


def test_gecit_bas_parcasi_gercek_izin_kararini_bekler():
    s, son = _parcali_giris(GecSahne(_takipci()))
    s.bekle(3.0, [son]).bekle(8.0, [])
    assert s.turler() == ["TEK_KARE", "GIRDI"], s.turler()
    assert s.giden() == ["GIRDI"], s.giden()
    assert [(p.tur, r.tur) for p, r, _ in s.birakilan] == [("TEK_KARE", "GIRDI")]


def test_gecit_kapaliyken_her_olay_hemen_gider():
    s = _kuyruklu_cikis(GecSahne(_takipci(), acik=False))
    s.bekle(8.0, [])
    assert s.gonderilen == s.uretilen and s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"]
    assert s.sayildi() == [] and s.e.son_saat(s.mono) == (0, 0)


def test_gecit_kamera_koparsa_tutulan_bir_kez_gider():
    # Araç ağır gidiyor (6 sn): parçanın olayı geldi, araç hâlâ yürüyor — kararsız.
    s, _ = _parcali_giris(GecSahne(_takipci()), adim=20)
    assert "TEK_KARE" in s.turler() and "GIRDI" not in s.turler(), s.turler()
    assert s.giden() == [], "parça, aynı geçişteki izin kararını bekliyor"
    s.e.birak(s.mono)
    assert s.giden() == ["TEK_KARE"], s.giden()
    s.e.birak(s.mono)
    assert s.giden() == ["TEK_KARE"], "bir kez"


def test_gecit_tutma_tavani():
    # Aynı geçişteki iz hiç karar vermezse (kapıda durup bekleyen araç) parça
    # en çok TUTMA_EN_COK_SN bekletilir, sonra kartı gider.
    s = _isin(GecSahne(_takipci()))
    s.kare([])
    s.kare([A(350, 760, 500, 800, 0.46)])                    # parça
    s.kare([])
    bekleyen = _arac(200, 600)                               # kapı alanında durur
    while "TEK_KARE" not in s.turler() and s.mono < 200:
        s.kare([bekleyen])
    assert s.giden() == [], "parça, kapıda bekleyen aracın kararını bekliyor"
    gelis = s.mono
    while not s.giden() and s.mono - gelis < takip.TUTMA_EN_COK_SN + 5:
        s.kare([bekleyen], dt_sn=1.0)
    assert s.giden() == ["TEK_KARE"], s.giden()
    assert takip.TUTMA_EN_COK_SN <= s.mono - gelis <= takip.TUTMA_EN_COK_SN + 1.5, s.mono - gelis


def test_gecit_yalniz_kenar_araci_tek_kart():
    # iz 465: yalnızca kenarda görülen araç — kartı kalır.
    s = _isin(GecSahne(_takipci()))
    s.kare([])
    s.kare([A(0, 700, 200, 800, 0.91)]).kare([A(0, 705, 190, 800, 0.9)])
    s.bekle(8.0, [])
    assert s.giden() == ["KAPIDA_KAYBOLDU"], s.giden()
    assert s.sayildi() == [] and s.e.son_saat(s.mono) == (0, 0)


def test_gecit_kuyruktaki_iki_araci_birlestirmez():
    # Önde giren araç görünürken arkadakinin parçası kenarda bir kare — iki
    # kutu aynı karede, ama biri ötekinin içinde değil: iki araçtır.
    s = _isin(GecSahne(_takipci()))
    s.kare([])
    s.kare([_arac(200, 600)])
    s.kare([_arac(130, 555), A(350, 760, 500, 800, 0.5)])
    son = _yol(s, (130, 555), (900, 150), adim=9)
    s.bekle(3.0, [son]).bekle(8.0, [])
    assert sorted(s.turler()) == ["GIRDI", "TEK_KARE"], s.turler()
    assert sorted(s.giden()) == ["GIRDI", "TEK_KARE"], s.giden()
    assert s.sayildi() == [], s.satirlar


def test_gecit_cikanin_ardindan_gelen_araci_birlestirmez():
    # A alt kenardan çıktı; 0.3 sn sonra B'nin parçası kenardan İÇERİ yürüdü
    # ve kayboldu — A'nın kuyruğu değil (ters yönde yürüyor).
    s = _kuyruklu_cikis(GecSahne(_takipci()), tekerlek=False)
    s.kare([A(300, 750, 420, 800, 0.6)])
    s.kare([A(300, 730, 420, 780, 0.6)])
    s.bekle(8.0, [])
    assert s.turler() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.turler()
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()
    assert s.sayildi() == [], s.satirlar


def test_gecit_gec_gelen_parca_sayilmaz():
    # Araç çıktıktan 3 sn sonra kenarda görülen parça (GECIT_ARA_SN 2 sn): başka
    # şey — ikiz penceresi kapalıyken (IKIZ_SN=0, 1.4.5 davranışı).
    s = _kuyruklu_cikis(GecSahne(_takipci(), ikiz_sn=0), tekerlek=False)
    s.bekle(3.0, [])
    s.kare([A(230, 760, 330, 800, 0.6)]).kare([A(236, 762, 336, 800, 0.6)])
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def _karardan_sonra_parca(sn, **kw):
    """Araç çıktı (karar ele alındı); kararın `sn` saniye ardından kenarda plakasız parça."""
    s = _kuyruklu_cikis(GecSahne(_takipci(), **kw), tekerlek=False)
    s.bekle(6.0, [])                                         # ÇIKTI ~4 sn sonra
    assert s.giden() == ["CIKTI"], s.giden()
    karar = s.gonderilen[0][1]
    s.bekle(max(0.3, karar + sn - s.mono), [])
    s.kare([A(230, 760, 330, 800, 0.6)]).kare([A(236, 762, 336, 800, 0.6)])
    parca = _izler_ve_parca(s)[-1]
    s.bekle(8.0, [])
    return s, parca, parca.dogum_mono - karar


def test_gecit_ikiz_penceresi():
    # 1.4.6 C (sahibin kararı 25.11): 23–24.11'deki 7 ikizin 3'ü kararın 5–24
    # sn ARDINDAN kapıda doğup kapıda kayboldu (aracın kuyruğu sol kenarda,
    # 0.94–0.95 — B'nin eşiği tutmaz). Ele alınmış bir GİRDİ / ÇIKTI kararından
    # sonra IKIZ_SN (25) içinde doğan, plakası okunmamış KAPIDA_KAYBOLDU kartı
    # gönderilmez (emildi, klip yazılır).
    assert takip.GECIT_IKIZ_SN == 25.0
    for sn in (5.0, 20.0):
        s, parca, fark = _karardan_sonra_parca(sn)
        assert 0 < fark <= 25.0, fark
        assert s.giden() == ["CIKTI"], (sn, s.giden())
        assert len(s.sayildi()) == 1 and "ikiz" in s.sayildi()[0], s.satirlar
        assert [(p.tur, r.tur) for p, r, _ in s.birakilan] == [("KAPIDA_KAYBOLDU", "CIKTI")]
    # Pencerenin dışı: kart gider.
    s, _, fark = _karardan_sonra_parca(30.0)
    assert fark > 25.0, fark
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()
    # Pencere kapalı (IKIZ_SN=0): kart gider.
    s, _, _ = _karardan_sonra_parca(5.0, ikiz_sn=0)
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_ikiz_penceresi_plakali_parcayi_ve_karti_saymaz():
    # Parçanın plakası okunduysa (tahmin de) başka araç olabilir: kart gider.
    s = _kuyruklu_cikis(GecSahne(_takipci()), tekerlek=False)
    s.bekle(6.0, [])
    karar = s.gonderilen[0][1]
    s.bekle(max(0.3, karar + 5.0 - s.mono), [])
    s.kare([A(230, 760, 330, 800, 0.6)]).kare([A(236, 762, 336, 800, 0.6)])
    _izler_ve_parca(s)[-1].gecis.plakalar = {"35CD2"}
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()
    # Önceki olay KART idiyse (karar değil): ikiz sayılmaz, kart gider.
    s, _, _ = _karardan_sonra_parca(5.0, kart=lambda o: True)
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_aracla_ayni_karede_gorulen_parca_sayilir():
    # 21.11 18:10:39: lastik çıkan araçla AYNI karelerde, aracın kutusunun
    # içinde görüldü (Emici'nin bilinen sınırı) — aynı geçiş, kartı gitmez.
    s = _isin(GecSahne(_takipci()))
    park = _arac(900, 150)
    s.kare([park]).bekle(3.0, [park])
    _yol(s, (900, 150), (200, 600), adim=10)
    s.kare([A(200, 650, 500, 800, 0.8), A(230, 760, 330, 800, 0.6)])
    s.kare([A(200, 700, 500, 800, 0.7), A(236, 762, 336, 800, 0.6)])
    s.kare([A(242, 762, 342, 800, 0.6)])
    s.bekle(8.0, [])
    assert sorted(s.turler()) == ["CIKTI", "KAPIDA_KAYBOLDU"], s.turler()
    assert s.giden() == ["CIKTI"], s.giden()
    assert len(s.sayildi()) == 1, s.satirlar


def test_gecit_kenarin_baska_yerindeki_parca_sayilmaz():
    # Araç alt kenarın solundan (x 200–500) çıktı; parça aynı kenarın başka
    # yerinde (x 600–700): aynı araç değil.
    s = _kuyruklu_cikis(GecSahne(_takipci()), tekerlek=False)
    s.kare([A(600, 760, 700, 800, 0.6)]).kare([A(606, 762, 706, 800, 0.6)])
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_farkli_plakalari_birlestirmez():
    # Parçanın plakası (emin ya da tahmin) gerçek izde yoksa iki araçtır.
    for r_pl, p_pl, emilir in ((set(), set(), True), ({"34AB1"}, {"34AB1"}, True),
                               ({"34AB123"}, {"34AB128"}, True),     # bir karakter: aynı
                               ({"34AB1"}, {"35CD2"}, False), (set(), {"35CD2"}, False)):
        s = _kuyruklu_cikis(GecSahne(_takipci()))
        cikan, parca = _izler_ve_parca(s)[-2:]
        assert parca.gorulme == 2 and cikan.gorulme > 10, (cikan, parca)
        cikan.gecis.plakalar, parca.gecis.plakalar = r_pl, p_pl
        s.bekle(8.0, [])
        beklenen = ["CIKTI"] if emilir else ["CIKTI", "KAPIDA_KAYBOLDU"]
        assert s.giden() == beklenen, (r_pl, p_pl, s.giden())


def test_gecit_motosiklet_karti_birlestirilmez():
    # Motosiklet sınıfı kart (puanı 1.4.4'ün 0.70'ini geçmiş) hiç bekletilmez,
    # hiç düşürülmez: aracın yanından geçen gerçek bir motosiklet olabilir.
    s = _kuyruklu_cikis(GecSahne(_takipci()))
    _izler_ve_parca(s)[-1].gecis.arac_sinif = arac.MOTOSIKLET
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_ele_alinmayan_karar_parcayi_dusurmez():
    # Gerçek izin kararı hiçbir şey göndermediyse (araç puanı düşük) parça
    # tek kanıttır: kartı kalır.
    s = _kuyruklu_cikis(GecSahne(_takipci(), ele_alindi=lambda o: o.tur != "CIKTI"))
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI", "KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_iki_kart_adayi_tek_kart():
    # Parçanın ardından kenarda doğan iz de kapıda kayboldu (yönü yok): ikisi
    # aynı geçiş, hiçbiri ele alınmadı — BİR kart gider (en çok görüleni).
    s = _isin(GecSahne(_takipci()))
    s.kare([])
    s.kare([A(350, 760, 500, 800, 0.46)])
    s.kare([])
    s.kare([A(200, 600, 500, 800, 0.8)]).kare([A(190, 590, 490, 790, 0.8)])
    s.bekle(8.0, [])
    assert sorted(s.turler()) == ["KAPIDA_KAYBOLDU", "TEK_KARE"], s.turler()
    assert s.giden() == ["KAPIDA_KAYBOLDU"], s.giden()
    assert [(p.tur, r.tur) for p, r, _ in s.birakilan] == [("TEK_KARE", "KAPIDA_KAYBOLDU")]


def _iki_aday(s, tek_pl=set(), kayip_pl=set()):
    """test_gecit_iki_kart_adayi_tek_kart'ın sahnesi, izlere plaka metinleriyle."""
    s = _isin(s)
    s.kare([])
    s.kare([A(350, 760, 500, 800, 0.46)])
    s.kare([])
    s.kare([A(200, 600, 500, 800, 0.8)])
    for z in s.t.izler:
        z.gecis.plakalar = tek_pl if z.dogum_kutu[0] == 350 else kayip_pl
    s.kare([A(190, 590, 490, 790, 0.8)])
    s.bekle(8.0, [])
    assert sorted(s.turler()) == ["KAPIDA_KAYBOLDU", "TEK_KARE"], s.turler()
    return s


def test_gecit_plaka_tahmini_olan_aday_gider():
    # Aynı geçişin iki kart adayından plaka tahmini olanı gider (az görülse de).
    s = _iki_aday(GecSahne(_takipci()), tek_pl={"34ABC123"})
    assert s.giden() == ["TEK_KARE"], s.giden()


def test_gecit_farkli_plakali_iki_aday_iki_kart():
    # İki adayın da plakası var ve ayrı: iki araç — ikisi de gider.
    s = _iki_aday(GecSahne(_takipci()), tek_pl={"34ABC123"}, kayip_pl={"35DEF456"})
    assert sorted(s.giden()) == ["KAPIDA_KAYBOLDU", "TEK_KARE"], s.giden()
    # Bir karakter farkı: aynı araç — bir kart (ikisinde de plaka var: çok görülen).
    s = _iki_aday(GecSahne(_takipci()), tek_pl={"34ABC123"}, kayip_pl={"34ABC128"})
    assert s.giden() == ["KAPIDA_KAYBOLDU"], s.giden()


def test_gecit_bekleyen_kart_karari_degisirse_yeniden_bakilir():
    # Bekletilen olay artık kart değilse (iz emin plaka kazandı, 60 sn kuralı)
    # bırakılırken kart diye değil, yeni kararıyla gider.
    s, son = _parcali_giris(GecSahne(_takipci(), ele_alindi=lambda o: o.tur != "GIRDI"),
                            adim=20)
    parca = next(o for o in s.olaylar if o.tur == "TEK_KARE")
    assert s.giden() == []
    parca.iz.gecis.kart = False
    s.kare([son])
    assert s.giden() == ["TEK_KARE"], s.giden()       # aracı beklemeden
    s.bekle(3.0, [son]).bekle(8.0, [])
    assert sorted(s.giden()) == ["GIRDI", "TEK_KARE"], s.giden()
    assert s.sayildi() == []


def test_gecit_kenara_degmeyen_tek_kare_hemen_gider():
    # Yanında aynı geçişten iz olmayan tek kare: bekletilmeden gider.
    s = _isin(GecSahne(_takipci()))
    s.kare([])
    s.kare([_arac(100, 520)])
    s.bekle(6.0, [])
    assert s.gonderilen == s.uretilen and s.giden() == ["TEK_KARE"], s.giden()


def test_gecit_karar_bellegi_altmis_saniye():
    # Ele alınmış karar EMME_HAFIZA_SN hatırlanır; daha sonraki olaya sayılmaz.
    s = _kuyruklu_cikis(GecSahne(_takipci()), tekerlek=False)
    s.bekle(8.0, [])
    assert s.giden() == ["CIKTI"]
    s.e.al(s.t, [], s.mono + takip.EMME_HAFIZA_SN + 1)
    assert s.e._yonlu == [], s.e._yonlu


# Elle kurulan izler: ayni_gecis kuralının parçaları (kutu geçmişi + olay türü).

def _tarihli_iz(no, kutular, tur_sinif=2):
    """İz, kutu geçmişiyle: kutular = [(mono, (x1, y1, x2, y2)), ...]."""
    m0, k0 = kutular[0]
    o = takip.Olcum(0, m0, T0, np.zeros((4, 4, 3), np.uint8), np.zeros((120, 160), np.uint8),
                    [], [])
    z = takip.Iz(no, "arac", A(*k0, 0.8), o, _Gecis(), "kapi", True)
    for m, k in kutular:
        z.kutu_ekle(m, A(*k, 0.8, tur_sinif))
    z.son_mono, z.kutu = kutular[-1][0], A(*kutular[-1][1], 0.8)
    return z


def _cikan_arac():
    """Alt kenara doğru inen araç: üç kare, 0.3 sn arayla (10.0 / 10.3 / 10.6)."""
    return _tarihli_iz(1, [(10.0, (200, 600, 500, 800)), (10.3, (200, 650, 500, 800)),
                           (10.6, (200, 700, 500, 800))])


def test_ayni_gecis_ayni_karelerde_icinde():
    r = _cikan_arac()
    p = _tarihli_iz(2, [(10.3, (230, 760, 330, 800)), (10.6, (236, 762, 336, 800))])
    assert takip.ayni_gecis(p, r, "KAPIDA_KAYBOLDU", "CIKTI")
    assert takip.ayni_gecis(r, p, "CIKTI", "KAPIDA_KAYBOLDU"), "bakışımlı"
    # Plakasız ÇIKTI (16:30 türü) de aynı karelerde içerdeyse aynı geçiş.
    assert takip.ayni_gecis(p, r, "CIKTI", "CIKTI")
    # Ters yönler (giren / çıkan) asla aynı geçiş değildir.
    assert not takip.ayni_gecis(p, r, "GIRDI", "CIKTI")


def test_ayni_gecis_karsilasan_araclar_degil():
    # İki araç kapıda karşılaştı: aynı karelerde kutuları çok örtüşüyor ama
    # ters yöne gidiyorlar — iki araç.
    a = _tarihli_iz(1, [(10.0, (300, 300, 600, 500)), (10.3, (320, 300, 620, 500)),
                        (10.6, (340, 300, 640, 500))])
    b = _tarihli_iz(2, [(10.0, (360, 300, 660, 500)), (10.3, (340, 300, 640, 500)),
                        (10.6, (320, 300, 620, 500))])
    assert not takip.ayni_gecis(a, b, "KAPIDA_KAYBOLDU", "TEK_KARE")


def test_ayni_gecis_ayni_karelerde_icinde_degilse_degil():
    # Aynı karelerde görülen ama çoğu karede ötekinin içinde OLMAYAN iki şey.
    r = _cikan_arac()
    p = _tarihli_iz(2, [(10.0, (600, 600, 700, 700)), (10.3, (230, 760, 330, 800)),
                        (10.6, (650, 650, 750, 750))])
    assert not takip.ayni_gecis(p, r, "KAPIDA_KAYBOLDU", "CIKTI")


def test_ayni_gecis_kuyruk_ve_bas():
    r = _cikan_arac()
    kuyruk = _tarihli_iz(2, [(12.1, (230, 760, 330, 800)), (12.4, (236, 762, 336, 800))])
    assert takip.ayni_gecis(kuyruk, r, "KAPIDA_KAYBOLDU", "CIKTI")         # 1.5 sn sonra
    gec = _tarihli_iz(3, [(13.7, (230, 760, 330, 800)), (14.0, (236, 762, 336, 800))])
    assert not takip.ayni_gecis(gec, r, "KAPIDA_KAYBOLDU", "CIKTI")        # 3.1 sn sonra
    # Kuyruk/baş yalnızca yönü bilinmeyen olayla: iki yönlü olay ardışık
    # görüldüyse iki araçtır (öndeki çıktı, arkadaki çıktı).
    assert not takip.ayni_gecis(kuyruk, r, "CIKTI", "CIKTI")
    # Baş: parça aracın doğumundan 0.6 sn önce, aracın ilk kutusunun içinde.
    bas = _tarihli_iz(4, [(9.4, (350, 760, 500, 800))])
    assert takip.ayni_gecis(bas, r, "TEK_KARE", "CIKTI")
    # Başka yerde (kenarın öbür ucu): değil.
    uzak = _tarihli_iz(5, [(12.1, (600, 760, 700, 800)), (12.4, (606, 762, 706, 800))])
    assert not takip.ayni_gecis(uzak, r, "KAPIDA_KAYBOLDU", "CIKTI")
    # İçeri yürüyen (aracın gidişine ters) kuyruk: arkadan gelen başka araç.
    iceri = _tarihli_iz(6, [(12.1, (300, 750, 420, 800)), (12.4, (300, 730, 420, 780))])
    assert not takip.ayni_gecis(iceri, r, "KAPIDA_KAYBOLDU", "CIKTI")


def test_bekleyen_iz():
    # Parça, aynı geçişten KARARSIZ bir iz varken bekletilir. Kapıda / bariyerde
    # duran araç bekler; otoparkın derininde çoktan park etmiş araç beklemez.
    z = _cikan_arac()
    m = 20.0
    assert takip.bekleyen_iz(z, m)                                         # yürüyor
    z.duruyor = True
    z.dogum_mono = m - takip.TUTMA_EN_COK_SN - 1
    assert not takip.bekleyen_iz(z, m), "park etmiş"
    z.kapida = True
    assert takip.bekleyen_iz(z, m), "kapıda duruyor (bariyer)"
    z.kapida, z.gecti_mono = False, m - 5
    assert takip.bekleyen_iz(z, m), "kapıdan geçti, kararı bekliyor"
    z.giris_karari = True
    assert not takip.bekleyen_iz(z, m), "karar verildi"
    z.giris_karari, z.gecti_mono = False, None
    z.dogum_mono = m - 3
    assert takip.bekleyen_iz(z, m), "yeni doğdu"
    z.kaynak = "plaka"
    assert not takip.bekleyen_iz(z, m), "plaka izi araç değildir"


def test_kutu_gecmisi_ilk_ve_son():
    z = _tarihli_iz(1, [(float(i), (i, 0, i + 10, 10)) for i in range(300)])
    g = z.kutu_gecmisi()
    monolar = [m for m, _ in g]
    assert monolar == sorted(set(monolar)), "sıralı, tekrarsız"
    assert monolar[:takip.GECMIS_ILK] == [float(i) for i in range(takip.GECMIS_ILK)]
    assert monolar[-1] == 299.0 and len(g) == takip.GECMIS_ILK + takip.GECMIS_SON


# ------------------------- 1.4.3 PARK_GORUNUR: olay yalnızca alana girmiş izden --
# Kırpma alanı (mavi) sağ altı dışarıda bırakır: orası park yeri. Kapı (sarı)
# alanın içinde. Modeller dışarıyı da görür; dışarıda doğup hiç alana / kapıya
# girmeyen iz olay vermez, not düşmez, hareket etmedikçe kare istemez.
ALAN_SAG = [(0, 0), (1600, 0), (1600, 300), (800, 300), (800, 800), (0, 800)]
# Kapının hemen üstü dışarıda (DURAN'ın çapası (300, 380) alanın 40 px dışı).
ALAN_ALT = [(0, 420), (1600, 420), (1600, 800), (0, 800)]


def test_alan_yoksa_her_iz_alanda():
    s = _isin(Sahne(_takipci(alan=None)))
    son = _yol(s, (50, 600), (900, 150), adim=10)
    s.kare([_arac(1300, 100)])
    s.bekle(2.5, [son, _arac(1300, 100)])
    assert s.turler().count("GIRDI") == 1, s.turler()
    assert s.t.izler and all(z.alanda for z in s.t.izler), s.t.izler


def test_alana_hic_girmeyen_iz_olay_vermez():
    # Bugün (alan yok): park yerinde yer değiştirirken kaybolan araç ICERIDE.
    for alan, beklenen in ((None, ["ICERIDE"]), (ALAN_SAG, [])):
        s = _isin(Sahne(_takipci(alan=alan)))
        _yol(s, (1000, 500), (820, 500), adim=6)              # çapa (1150, 700) → (970, 700)
        s.bekle(6.0, [])
        assert s.turler() == beklenen, (alan, s.turler())
        assert s.t.kararsiz_al() == [], alan
    # İki karede görülüp kaybolan (hareket bölümü yok): bugün "otopark" notu.
    for alan, beklenen in ((None, ["otopark"]), (ALAN_SAG, [])):
        s = _isin(Sahne(_takipci(alan=alan)))
        s.kare([_arac(1000, 500)]).kare([_arac(990, 500)])
        s.bekle(6.0, [])
        assert s.turler() == [], (alan, s.turler())
        assert _yerler(s) == beklenen, alan


def test_alan_disinda_park_kapi_kipirdasa_da_girdi_degil():
    for alan in (None, ALAN_ALT):
        s = _isin(Sahne(_takipci(alan=alan)))
        s.kare([])
        _kapidan_gorulmeden_gecer(s)
        a = _arac(*DURAN)
        s.kare([a]).bekle(3.0, [a])
        if alan is None:
            assert s.turler() == ["GIRDI"], s.turler()        # bugünkü A4 kuralı
            continue
        assert "GIRDI" not in s.turler(), s.turler()
        iz = s.t.izler[0]
        assert not iz.kapidan_dogdu and not iz.alanda, iz
        son = _yol(s, DURAN, (900, 400), adim=8)               # sonra alana sürüp durdu
        s.bekle(3.0, [son])
        assert "GIRDI" not in s.turler(), s.turler()
        assert iz.alanda and not iz.kapidan_dogdu, iz


def test_alan_disinda_dogan_hiz_kurali_girdi_degil():
    # İkinci görülmede kapıdan uzaklaşıyor, bir kare öncesi kapıda (1.4.1 hız
    # kuralı): bugün GİRDİ. Alanın dışında doğduysa (gece farlarını yakan park
    # aracı) kapıdan geldi sayılmaz.
    # Sonra durmadan alana sürüp orada duruyor (olay alanda verilir).
    for alan in (None, ALAN_ALT):
        s = _isin(Sahne(_takipci(alan=alan)))
        s.kare([])
        s.kare([_arac(150, 180)])                              # çapa (300, 380)
        s.kare([_arac(150, 80)])                               # çapa (300, 280)
        son = _yol(s, (150, 80), (900, 400), adim=8)            # çapa (1050, 600): alanda
        s.bekle(3.0, [son])
        if alan is None:
            assert s.turler() == ["GIRDI"], s.turler()
        else:
            assert "GIRDI" not in s.turler() and s.t.izler[0].alanda, s.turler()


def test_alan_disindan_gelip_kapidan_cikan_cikti():
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    p = _arac(1100, 400)                                       # çapa (1250, 600): alanın dışı
    s.kare([p]).bekle(3.0, [p])
    assert not s.t.izler[0].alanda
    _yol(s, (1100, 400), (60, 600), adim=12)                   # maviden sarıya, alt kenara
    s.bekle(6.0, [])
    assert s.turler() == ["CIKTI"], s.turler()


def test_kapidan_girip_alan_disindan_gecen_girdi():
    # Sahibin derdi: boşken giren araç mavinin dışından geçip orada duruyor.
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    son = _yol(s, (50, 600), (1000, 350), adim=10)             # son çapa (1150, 550): dışarıda
    s.bekle(3.0, [son])
    assert s.turler() == ["GIRDI"], s.turler()
    assert s.olaylar[0].iz.alanda


def test_kapi_alanin_disinda_da_alandir():
    # Kapı (sarı) mavinin dışına taşabilir: kapıda doğup kapıda kaybolan araç
    # yine kart olur (alan = mavi ∪ sarı).
    s = _isin(Sahne(_takipci(alan=[(0, 0), (1600, 0), (1600, 440), (0, 440)])))
    s.kare([])
    _yol(s, (150, 480), (60, 600), adim=3)                   # çapa (300, 680) → kenar
    s.bekle(6.0, [])
    assert s.turler() == ["KAPIDA_KAYBOLDU"], s.turler()


def test_alan_disindaki_iz_kare_istemez():
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    p = _arac(1100, 400)
    s.kare([p])
    assert not s.t.kare_istiyor(), "dışarıda yeni doğan, kıpırdamayan iz kare istemez"
    s.bekle(3.0, [p])
    assert not s.t.kare_istiyor(), "dışarıda duran"
    s.kare([])
    assert s.t.izler[0].kacirma == 1 and not s.t.kare_istiyor(), "dururken kaçırılan"
    s.bekle(2.0, [])
    assert s.t.izler[0].durum == "kayip" and not s.t.kare_istiyor(), "dururken kaybolan"
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    _yol(s, (1300, 450), (1000, 450), adim=6)                  # dışarıda belirgin hareket
    assert s.t.kare_istiyor(), "dışarıda yürüyen iz kare ister"
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    s.kare([_arac(300, 100)])                                  # alanda yeni iz (bugünkü gibi)
    assert s.t.kare_istiyor()


def _genis(k, pay=0.25):
    w, h = k[2] - k[0], k[3] - k[1]
    return (k[0] - pay * w, k[1] - pay * h, k[2] + pay * w, k[3] + pay * h)


def _yakin(a, b) -> bool:
    return len(a) == len(b) and all(
        all(abs(float(x) - float(y)) < 1e-6 for x, y in zip(k, m)) for k, m in zip(a, b))


def test_okunacak_kutular():
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    assert s.t.okunacak_kutular(s.mono) == ()
    a = _arac(300, 100)
    s.kare([a])
    kutular = s.t.okunacak_kutular(s.mono)
    assert _yakin(kutular, [_genis((300, 100, 600, 300))]), kutular
    assert all(isinstance(v, float) for k in kutular for v in k), kutular
    s.bekle(3.0, [a])
    assert s.t.okunacak_kutular(s.mono) == (), "duran araç okunmaz"
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    s.kare([_arac(1100, 400)])
    assert s.t.okunacak_kutular(s.mono) == (), "dışarıda kıpırdamamış iz okunmaz"
    son = _yol(s, (1300, 450), (1000, 450), adim=6)
    assert _yakin(s.t.okunacak_kutular(s.mono), [_genis(tuple(son[:4]))]), \
        s.t.okunacak_kutular(s.mono)
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    pk = _pk(300, 100)                                         # gövdesiz plaka izi
    s.kare([], [pk])
    assert _yakin(s.t.okunacak_kutular(s.mono), [_genis((pk.x1, pk.y1, pk.x2, pk.y2))]), \
        s.t.okunacak_kutular(s.mono)


def test_park_bellegi_alanda_bilgisini_tasir():
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    s.kare([_arac(300, 100)])                                  # alanda doğdu
    son = _yol(s, (300, 100), (1100, 400), adim=8)             # alanın dışına park etti
    s.bekle(3.0, [son])
    s.bekle(6.0, [])                                           # önünden kamyon geçti
    assert not s.t.izler and len(s.t.park) == 1
    s.kare([son])
    assert len(s.t.izler) == 1 and s.t.izler[0].alanda, "park belleği 'alandaydı' bilgisini taşır"
    # Hiç alana girmemiş park aracı bellekten yine "alanda değil" döner.
    s = _isin(Sahne(_takipci(alan=ALAN_SAG)))
    p = _arac(1100, 400)
    s.kare([p]).bekle(3.0, [p]).bekle(6.0, [])
    assert not s.t.izler and len(s.t.park) == 1
    s.kare([p])
    assert len(s.t.izler) == 1 and not s.t.izler[0].alanda, s.t.izler


def test_degisti_tetik_grisine_bakar():
    # PARK_GORUNUR: izci maskesiz griyle ölçer (Olcum.gri), ama köprünün her
    # karedeki hareket tetiği maskeli griyle sorar — karşılaştırma maskeli olanla
    # (Olcum.tetik_gri); yoksa alanın dışı her karede "değişti" derdi.
    t = _takipci()
    acik = np.full((120, 160), 50, np.uint8)
    maskeli = np.full((120, 160), 114, np.uint8)
    o = takip.Olcum(1, 100.0, T0, np.zeros((4, 4, 3), np.uint8), acik, [], [], maskeli)
    t.guncelle(o)
    assert t.son_gri is acik, "izcinin kendi ölçüsü maskesiz griyle"
    assert not t.degisti(maskeli.copy())
    assert t.degisti(acik.copy()), "tetik maskeli olana göre"
    assert not t._plakaci.degisti(maskeli.copy()), "plaka izcisi de tetik grisini alır"
    # tetik_gri verilmezse (bugün) gri ikisi birden.
    t = _takipci()
    t.guncelle(takip.Olcum(1, 100.0, T0, np.zeros((4, 4, 3), np.uint8), acik, [], []))
    assert not t.degisti(acik.copy()) and t.degisti(maskeli.copy())


def test_devral_alanda_bilgisini_birlestirir():
    o = takip.Olcum(1, 100.0, T0, np.zeros((4, 4, 3), np.uint8), np.zeros((120, 160), np.uint8),
                    [], [])
    p = takip.Iz(1, "plaka", _arac(300, 100), o, _Gecis(), "kapi", True)
    z = takip.Iz(2, "arac", _arac(300, 100), o, _Gecis(), "yard", False)
    assert z.alanda and p.alanda, "kurucu varsayılanı: alanda (alan yok = her yer)"
    p.alanda, z.alanda = True, False
    z.devral(p)
    assert z.alanda


def test_iz_en_iyi_kutunun_sinifini_tutar():
    # 1.4.3 (2026-11-20): kararın motosiklet eşiği ve kayıt satırı izin EN
    # İYİ kutusunun sınıfına bakar (arac_max ile birlikte değişir).
    s = _isin(Sahne(_takipci()))
    s.kare([A(900, 100, 1200, 300, 0.45, 3)])
    g = s.t.izler[0].gecis
    assert (g.arac_max, g.arac_sinif) == (0.45, 3), vars(g)
    s.kare([A(905, 100, 1205, 300, 0.40, 2)])            # daha zayıf: sınıf değişmez
    assert (g.arac_max, g.arac_sinif) == (0.45, 3), vars(g)
    s.kare([A(910, 100, 1210, 300, 0.70, 2)])
    assert (g.arac_max, g.arac_sinif) == (0.70, 2), vars(g)


def test_devral_sinifi_tasir():
    o = takip.Olcum(1, 100.0, T0, np.zeros((4, 4, 3), np.uint8), np.zeros((120, 160), np.uint8),
                    [], [])
    p = takip.Iz(1, "plaka", _arac(300, 100), o, _Gecis(), "kapi", True)
    z = takip.Iz(2, "arac", _arac(300, 100), o, _Gecis(), "yard", False)
    z.gecis.arac_max, z.gecis.arac_sinif = 0.5, 3
    z.devral(p)
    assert (z.gecis.arac_max, z.gecis.arac_sinif) == (0.5, 3), vars(z.gecis)
    # Plaka izinin geçişi daha yüksek puanı zaten taşıyorsa onunki kalır.
    p = takip.Iz(3, "plaka", _arac(300, 100), o, _Gecis(), "kapi", True)
    p.gecis.arac_max, p.gecis.arac_sinif = 0.8, 2
    z = takip.Iz(4, "arac", _arac(300, 100), o, _Gecis(), "yard", False)
    z.gecis.arac_max, z.gecis.arac_sinif = 0.5, 3
    z.devral(p)
    assert (z.gecis.arac_max, z.gecis.arac_sinif) == (0.8, 2), vars(z.gecis)


# ------------------------------------- 1.4.4: kutu içinde kutu (21.11 16:30) --

# Sahadaki kapı alanı (kirpma_sunucu.SAHA_ONERISI["kapi"]) bu testlerin
# 1600 × 800 kırpıntısında; kart fotoğrafı 1280 × 505 idi (sx 1.25, sy 800/505).
SAHA_KAPI = [(0, 494), (1194, 590), (1124, 800), (0, 800)]
_SX, _SY = 1600 / 1280, 800 / 505


def _saha(x1, y1, x2, y2, skor, sinif=2):
    return A(x1 * _SX, y1 * _SY, x2 * _SX, y2 * _SY, skor, sinif)


def _kutu_icinde_kutu_sahnesi(suzgec, sahne=Sahne):
    """
    21.11 16:30 (35 ALN 793): araç sol alttan girer (burnu kırpıntının sol ve
    alt kenarında, kart fotoğrafındaki 0.93'lük kutu), otoparka geçer ve bilet
    fotoğrafındaki yerde durur. Bulucu HER karede bütün kutunun yanında onun
    içinde bir parça kutusu da verir. `suzgec`: kutuların izciye gitmeden
    önceki son hâli (köprüde arac.kutulari_coz'un döndürdüğü).
    """
    s = _isin(sahne(_takipci(kapi=SAHA_KAPI, dogum_esik=0.30)))
    bas, son = (0, 230, 330, 505), (407, 6, 823, 306)
    adim = 8
    for i in list(range(adim + 1)) + [adim] * 10:
        t = i / adim
        w = [bas[j] + (son[j] - bas[j]) * t for j in range(4)]
        butun = _saha(*w, 0.94)
        parca = _saha(w[0], w[1] + 0.3 * (w[3] - w[1]), w[0] + 0.5 * (w[2] - w[0]), w[3], 0.6)
        en, boy = butun.x2 - butun.x1, butun.y2 - butun.y1
        p = plaka.Kutu(butun.x1 + 0.35 * en, butun.y1 + 0.78 * boy,
                       butun.x1 + 0.65 * en, butun.y1 + 0.88 * boy, 0.9)
        s.kare(suzgec([butun, parca]), [p], cizim=[butun])
    s.bekle(8)
    return s


def test_kutu_icinde_kutu_ham_hali_iki_giris():
    # Sahadaki hata birebir: aynı anda kapıdan geçen, aynı karede duran İKİ
    # GİRDİ; plaka küçük kutunun izine gider, öteki plakasız kart olur. İzci
    # bu ham kutularla iki araç görür — düzeltme bulucuda (kutulari_coz).
    s = _kutu_icinde_kutu_sahnesi(lambda k: k)
    girdi = [o for o in s.olaylar if o.tur == "GIRDI"]
    assert len(girdi) == 2, s.turler()
    assert girdi[0].zaman == girdi[1].zaman, [o.zaman for o in girdi]
    assert sorted(bool(o.iz.gecis.yazilan) for o in girdi) == [False, True]


def test_kutu_icinde_kutu_birlesince_tek_giris_plakali():
    # 1.4.4: bulucunun birleştirmesinden geçen kutularla tek araç, tek GİRDİ,
    # plaka onda; kart yok.
    s = _kutu_icinde_kutu_sahnesi(arac.icerenleri_birlestir)
    assert s.turler() == ["GIRDI"], s.turler()
    assert s.olaylar[0].iz.gecis.yazilan


def test_kutu_icinde_kutu_gecitte_plakali_gider_kart_gitmez():
    # 1.4.5 A: bulucunun birleştirmesi kaçırsa da (parça 0.80 içermenin altında
    # kalsa da) iki GİRDİ aynı karelerde biri ötekinin içinde: aynı geçiş.
    # Plakalı olan gider; plakasızın kartı gitmez.
    s = _kutu_icinde_kutu_sahnesi(
        lambda k: k, sahne=lambda t: GecSahne(t, kart=lambda o: not o.iz.gecis.yazilan))
    assert s.turler() == ["GIRDI", "GIRDI"], s.turler()
    assert len(s.giden()) == 1 and s.gonderilen[0][0].iz.gecis.yazilan, s.giden()
    assert len(s.sayildi()) == 1, s.satirlar


def test_kutu_icinde_kutu_iki_plakasiz_tek_kart():
    # İkisi de kart olacaksa (plaka hiç okunmadı): geçiş başına BİR kart.
    s = _kutu_icinde_kutu_sahnesi(lambda k: k,
                                  sahne=lambda t: GecSahne(t, kart=lambda o: True))
    assert s.turler() == ["GIRDI", "GIRDI"], s.turler()
    assert s.giden() == ["GIRDI"], s.giden()
    assert len(s.birakilan) == 1, s.birakilan



# ------------------------------------- 1.4.5 C: ByteTrack eşlemesi (BYTE_ESLES) --

def _canli_araclar(t):
    return [z for z in t.izler if z.durum == "izleniyor" and z.kaynak == "arac"]


def _parca_sahnesi(byte_esles: bool):
    """
    Otoparkta sağa yürüyen araç (40 px / kare); sonra bir karede bulucu
    aracın gerçek kutusunu tahminin 150 px önünde (örtüşme 0.33), bir de
    doğum eşiğinin hemen altında (0.30) parça kutusunu tahminin üstünde
    (örtüşme 0.92) verir. Açgözlü eşleme — puanla harmanlanmış maliyet de —
    izi parçaya verir; gerçek kutu parçayla 0.33 örtüşür (KOPYA_IOU'nun
    altında) ve İKİNCİ iz doğar — ikiz kartın bir yolu.
    """
    t = _takipci(kapi=None, byte_esles=byte_esles)
    s = _isin(Sahne(t))
    x = 400
    for _ in range(6):
        x += 40
        s.kare([_arac(x, 100)])
    z = _canli_araclar(t)[0]
    p = z.tahmin(s.mono + 0.3)
    px, py = p[0], p[1]
    gercek = A(px + 150, py, px + 450, py + 200, 0.8)
    parca = A(px + 10, py + 10, px + 300, py + 200, 0.30)
    s.kare([gercek, parca])
    return t, z, gercek


def test_byte_yuksek_kutu_once_eslesir():
    # ByteTrack: önce yüksek puanlı kutular, düşük puanlı kutu yalnızca artan
    # izlere — iz gerçek kutuyla sürer, parça iz doğurmaz.
    t, z, gercek = _parca_sahnesi(byte_esles=True)
    canli = _canli_araclar(t)
    assert canli == [z], canli
    assert tuple(z.kutu[:4]) == tuple(gercek[:4]), (z.kutu, gercek)


def test_byte_kapaliyken_parca_ikinci_iz():
    # BYTE_ESLES=0: 1.4.4'ün açgözlü eşlemesi (bugünkü sahadaki davranış).
    t, z, _ = _parca_sahnesi(byte_esles=False)
    assert len(_canli_araclar(t)) == 2, _canli_araclar(t)


def test_byte_iki_kare_kacan_arac_ayni_iz():
    # Karanlıkta bulucu yürüyen aracı iki ölçülen karede kaçırır; üçüncüde
    # aracın gittiği yerde yine görür: aynı iz sürer, yeni iz doğmaz.
    for byte_esles in (True, False):
        t = _takipci(kapi=None, byte_esles=byte_esles)
        s = _isin(Sahne(t))
        x = 300
        for _ in range(5):
            x += 60
            s.kare([_arac(x, 100)])
        z = _canli_araclar(t)[0]
        s.kare([]).kare([])
        x += 180
        s.kare([_arac(x, 100)])
        assert _canli_araclar(t) == [z], (byte_esles, _canli_araclar(t))


def test_byte_karsilasan_iki_arac_izini_korur():
    # İki araç aynı şeritte karşılaşır (biri sağa, biri sola); kesiştikleri
    # karelerde izler yer değiştirmez.
    for byte_esles in (True, False):
        t = _takipci(kapi=None, byte_esles=byte_esles)
        s = _isin(Sahne(t))
        sag, sol = 200, 1100
        for _ in range(12):
            sag += 60
            sol -= 60
            s.kare([_arac(sag, 100), _arac(sol, 140)])
        canli = sorted(_canli_araclar(t), key=lambda z: z.id)
        assert len(canli) == 2, (byte_esles, canli)
        assert canli[0].kutu[0] > canli[1].kutu[0], (byte_esles, [z.kutu for z in canli])
        assert canli[0].hiz[0] > 0 > canli[1].hiz[0], (byte_esles, [z.hiz for z in canli])

if __name__ == "__main__":
    # 1.4.5 C: `TAKIP_BYTE_ESLES=0 python test_takip.py` — bütün testler
    # 1.4.4'ün eşlemesiyle de (BYTE_ESLES=0) geçmeli.
    takip.BYTE_ESLES = os.environ.get("TAKIP_BYTE_ESLES", "1") != "0"
    print(f"  (BYTE_ESLES={int(takip.BYTE_ESLES)})")
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
