# -*- coding: utf-8 -*-
"""
Plaka bulucu + okuyucu (1.3.0) — plaka.py birim testleri.

    python test_plaka.py

Köprü 1.3.0 plakayı dizüstünde okur ve EMİN olduğu plakayı metin olarak
gönderir; sunucu bir daha okumaz. Burada bir hata ya yanlış plakaya bilet
(para!) ya da gereksiz yere personele düşen araç demektir. Saf parçalar
doğrudan sınanır; gerçek modeller onnxruntime kuruluysa (paket venv'i) sınanır,
kurulu değilse o testler AÇIKÇA "atlandı" der — sürüm kontrolünde hepsi
koşmalı (paketle.py ön kontrolü).
"""
from __future__ import annotations

import datetime as dt
import os
import re
import sys
import tempfile

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import plaka  # noqa: E402

ATLANAN: list[str] = []


def _ort_var() -> bool:
    # İçe AKTARMADAN bakar: onnxruntime yalnızca plaka._ort_yukle() ile, telemetri
    # kapatılarak açılmalı (bkz. test_onnxruntime_telemetrisi_kapali).
    import importlib.util
    return importlib.util.find_spec("onnxruntime") is not None


# ------------------------------------------------------------ plaka kuralı ---

def test_tr_plaka_sunucuyla_ayni():
    # Sunucunun kuralı (vlm.ts TR_PLAKA) ile köprününki AYNI metin olmalı:
    # köprünün "geçerli" saydığını sunucu da geçerli saymalı.
    yol = os.path.join(BURASI, "..", "..", "supabase", "functions", "_shared", "vlm.ts")
    kaynak = open(yol, encoding="utf-8").read()
    m = re.search(r"TR_PLAKA\s*=\s*\n?\s*/(\^.+?\$)/", kaynak)
    assert m, "vlm.ts içinde TR_PLAKA bulunamadı"
    assert plaka.TR_PLAKA.pattern == m.group(1), (plaka.TR_PLAKA.pattern, m.group(1))


def test_tr_plaka_ornekler():
    for p in ("34ABC123", "06KZ4581", "35PA052", "81Z9999", "01A12345", "34AB1234"):
        assert plaka.TR_PLAKA.match(p), p
    for p in ("00ABC12", "82ABC12", "34QAB12", "34ABCD12", "34ABC1", "34A123", "ABC123", "34ABC12345"):
        assert not plaka.TR_PLAKA.match(p), p


def test_bir_fark_veritabaniyla_ayni():
    # supabase 037 plaka_yakin ile birebir (PASS 58b örnekleri).
    assert not plaka.bir_fark("34ABC123", "34ABC123")
    assert plaka.bir_fark("34ABC123", "34ABC128")
    assert plaka.bir_fark("34ABC123", "34ABC12") and plaka.bir_fark("34ABC12", "34ABC123")
    assert plaka.bir_fark("34ABC123", "4ABC123") and plaka.bir_fark("34ABC123", "34ABC1234")
    assert not plaka.bir_fark("34ABC123", "34ABD128")
    assert not plaka.bir_fark("34ABC123", "43ABC123")
    assert not plaka.bir_fark("34ABC123", "34ABC1")
    assert not plaka.bir_fark("AB12", "AB13")
    assert not plaka.bir_fark(None, "34ABC123") and not plaka.bir_fark("34ABC123", None)


# --------------------------------------------------------- görüntü hazırlığı -

def test_letterbox_kirpintida():
    img = np.zeros((668, 1568, 3), np.uint8)
    img[:, :] = (255, 0, 0)                       # BGR mavi
    x, r, dw, dh = plaka.letterbox(img, 640)
    assert x.shape == (1, 3, 640, 640) and x.dtype == np.float32
    assert abs(r - 640 / 1568) < 1e-9
    assert dw == 0.0 and abs(dh - (640 - 273) / 2) < 1e-9, (dw, dh)
    # İçerik RGB: mavi 3. kanalda (indeks 2), dolgu 114/255.
    orta = x[0, :, 320, 320]
    assert abs(orta[2] - 1.0) < 1e-6 and orta[0] == 0.0, orta
    ust = x[0, :, 0, 320]
    assert np.allclose(ust, 114 / 255), ust
    # Dolgu bütün kalıp: 183 + 273 + 184 = 640 (upstream yuvarlama).
    assert np.allclose(x[0, :, 182, 0], 114 / 255) and np.allclose(x[0, :, 640 - 184, 0], 114 / 255)
    assert x[0, 0, 183, 0] == 1.0 * 0 and x[0, 2, 183, 0] == 1.0


def test_kutu_esleme_gidis_donus():
    en, boy = 1568, 668
    r = 640 / 1568
    dh = (640 - round(boy * r)) / 2
    gercek = (100.0, 200.0, 300.0, 260.0)
    satir = [0, gercek[0] * r, gercek[1] * r + dh, gercek[2] * r, gercek[3] * r + dh, 0, 0.8]
    kutular = plaka.kutulari_coz(np.array([satir], np.float32), r, 0.0, dh, 0.3, en, boy)
    assert len(kutular) == 1
    k = kutular[0]
    for a, b in zip((k.x1, k.y1, k.x2, k.y2), gercek):
        assert abs(a - b) < 1e-2, (k, gercek)
    assert abs(k.skor - 0.8) < 1e-6


def test_kutu_esik_ve_kirpma():
    satirlar = np.array([
        [0, 10, 10, 50, 30, 0, 0.29],     # eşiğin altında
        [0, -20, 5, 40, 30, 0, 0.9],      # soldan taşar → kırpılır
        [0, 30, 30, 30, 50, 0, 0.9],      # sıfır genişlik → atılır
    ], np.float32)
    kutular = plaka.kutulari_coz(satirlar, 1.0, 0.0, 0.0, 0.30, 100, 100)
    assert len(kutular) == 1, kutular
    assert kutular[0].x1 == 0.0 and kutular[0].x2 == 40.0
    assert plaka.kutulari_coz(np.zeros((0, 7), np.float32), 1.0, 0, 0, 0.3, 100, 100) == []


def test_tam_plaka_kenar_payi():
    en, boy = 1568, 668                           # pay: x 15.68, y 6.68
    K = plaka.Kutu
    assert plaka.tam_mi(K(20, 100, 200, 140, 0.9), en, boy)
    assert not plaka.tam_mi(K(10, 100, 200, 140, 0.9), en, boy)          # sol kenara yakın
    assert not plaka.tam_mi(K(20, 5, 200, 40, 0.9), en, boy)             # üst kenara yakın
    assert not plaka.tam_mi(K(20, 100, en - 10, 140, 0.9), en, boy)      # sağ
    assert not plaka.tam_mi(K(20, 100, 200, boy - 5, 0.9), en, boy)      # alt
    assert plaka.tam_mi(K(20, 100, 200, boy - 8, 0.9), en, boy)
    # Küçük kırpıntıda pay en az 3 px.
    assert not plaka.tam_mi(K(2, 10, 50, 20, 0.9), 100, 40)
    assert plaka.tam_mi(K(3.5, 10, 50, 20, 0.9), 100, 40)


def test_tam_plaka_haric_alan():
    # Kesilen köşe (L şekli) bir KENAR gibidir: değen plaka okunmaz.
    en, boy = 1568, 668
    K = plaka.Kutu
    haric = (0, 0, 500, 200)                     # kırpıntı koordinatı: x, y, w, h
    assert not plaka.tam_mi(K(400, 150, 600, 190, 0.9), en, boy, haric)   # içine taşıyor
    assert not plaka.tam_mi(K(510, 150, 700, 190, 0.9), en, boy, haric)   # sağ kenarına çok yakın
    assert plaka.tam_mi(K(520, 150, 700, 190, 0.9), en, boy, haric)
    assert plaka.tam_mi(K(100, 210, 300, 250, 0.9), en, boy, haric)       # altında, payın dışında
    assert not plaka.tam_mi(K(100, 203, 300, 250, 0.9), en, boy, haric)   # altına çok yakın
    assert plaka.tam_mi(K(100, 210, 300, 250, 0.9), en, boy, None)


def test_haric_orani():
    K = plaka.Kutu
    assert plaka.haric_orani(K(0, 0, 100, 10, 0.9), (0, 0, 50, 10)) == 0.5
    assert plaka.haric_orani(K(0, 0, 100, 10, 0.9), (200, 0, 50, 10)) == 0.0
    assert plaka.haric_orani(K(0, 0, 100, 10, 0.9), None) == 0.0
    assert plaka.haric_orani(K(10, 10, 10, 10, 0.9), (0, 0, 50, 50)) == 0.0   # alansız kutu


# ---- 1.3.3: en çok 3 kesilen köşe (park etmiş araçların plakaları) --------

def test_haric_listesi_tek_ve_cok():
    # TEK yer iki biçimi ayırır: tek dikdörtgen (eski) ya da dikdörtgen listesi.
    assert plaka.haric_listesi(None) == ()
    assert plaka.haric_listesi(()) == ()
    assert plaka.haric_listesi((0, 0, 50, 10)) == ((0, 0, 50, 10),)
    assert plaka.haric_listesi((0.5, 0.0, 50.0, 10.0)) == ((0.5, 0.0, 50.0, 10.0),)
    assert plaka.haric_listesi(np.array([1, 2, 3, 4])) == ((1, 2, 3, 4),)
    iki = ((0, 0, 50, 10), (60, 0, 5, 5))
    assert plaka.haric_listesi(iki) == iki
    assert plaka.haric_listesi([[0, 0, 50, 10], [60, 0, 5, 5]]) == iki


def test_haric_orani_birlesim_cift_sayilmaz():
    # Üst üste binen iki kesilen köşe: kesişim BİR kez sayılır (toplam değil).
    K = plaka.Kutu
    k = K(0, 0, 100, 100, 0.9)
    assert plaka.haric_orani(k, ((0, 0, 60, 100), (40, 0, 60, 100))) == 1.0   # toplam 1.2 olurdu
    assert plaka.haric_orani(k, ((0, 0, 50, 100), (200, 0, 10, 10))) == 0.5   # ikincisi uzakta
    uc = ((0, 0, 50, 50), (25, 25, 50, 50), (0, 25, 50, 25))
    # Birleşim: 2500 + 2500 + 1250 − (625 + 625 + 1250) + 625 = 4375.
    assert abs(plaka.haric_orani(k, uc) - 0.4375) < 1e-12
    assert plaka.kesilen_alan(0, 0, 100, 100, uc) == 4375


def test_tam_plaka_ikinci_ve_ucuncu_haric_alan():
    en, boy = 1568, 668
    K = plaka.Kutu
    haric = ((0, 0, 100, 100), (1000, 400, 300, 200), (600, 0, 100, 50))
    assert not plaka.tam_mi(K(1100, 450, 1250, 490, 0.9), en, boy, haric)   # 2. alanın içinde
    assert not plaka.tam_mi(K(560, 52, 640, 90, 0.9), en, boy, haric)       # 3. alana 2 px (pay 6.7)
    assert plaka.tam_mi(K(560, 60, 640, 90, 0.9), en, boy, haric)           # 10 px: payın dışında
    assert plaka.tam_mi(K(300, 300, 450, 340, 0.9), en, boy, haric)         # hepsinden uzak


# ---- 1.4.0: kırpma ALANI = tıklanan çokgen (hariç dikdörtgenlerin yerine) ---

def _l_alani(en: int, boy: int):
    """(0, 0, 500, 200) kesilmiş dikdörtgen kırpıntının çokgen hâli (L şekli)."""
    return [(500, 0), (en, 0), (en, boy), (0, boy), (0, 200), (500, 200)]


def _izgara_kutular(en: int, boy: int):
    K = plaka.Kutu
    for x1 in (0, 2.5, 3, 3.5, 14, 15.68, 16, 480, 499, 499.5, 500, 514, 515.68, 516, 520, 1500):
        for y1 in (0, 2, 6.68, 7, 150, 190, 199, 199.5, 200, 205, 206.68, 207, 300, 640):
            for w, h in ((40, 20), (200, 40), (60.5, 13.3)):
                x2, y2 = x1 + w, y1 + h
                if x2 <= en + 30 and y2 <= boy + 30:
                    yield K(x1, y1, x2, y2, 0.9)


def test_alan_maskesi_dikdortgen_eski_kuralla_ayni():
    # Kırpıntının tamamı alan → eski kenar kuralıyla (hariçsiz) BİREBİR aynı.
    en, boy = 1568, 668
    m = plaka.AlanMaskesi.cokgenden([(0, 0), (en, 0), (en, boy), (0, boy)], en, boy)
    for k in _izgara_kutular(en, boy):
        assert plaka.tam_mi(k, en, boy, m) == plaka.tam_mi(k, en, boy, None), k


def test_alan_maskesi_l_sekli_eski_haric_kuraliyla_ayni():
    # Kesilmiş köşenin çokgen hâli: tam kuralı eski hariç kuralıyla BİREBİR aynı
    # (kesirli koordinatlar dahil) — sahada çizilmiş eski kırpmalar aynı okunur.
    en, boy = 1568, 668
    m = plaka.AlanMaskesi.cokgenden(_l_alani(en, boy), en, boy)
    n = 0
    for k in _izgara_kutular(en, boy):
        assert plaka.tam_mi(k, en, boy, m) == plaka.tam_mi(k, en, boy, (0, 0, 500, 200)), k
        n += 1
    assert n > 500, n
    # Dışarıda kalan oran: tamsayı kutularda eski hesapla aynı.
    K = plaka.Kutu
    for k in (K(400, 100, 600, 300, 0.9), K(0, 0, 500, 200, 0.9), K(600, 300, 700, 400, 0.9),
              K(450, 150, 550, 250, 0.9)):
        assert abs(plaka.haric_orani(k, m) - plaka.haric_orani(k, (0, 0, 500, 200))) < 1e-9, k


def test_alan_maskesi_egik_kenar():
    # Eğik kenar (üçgen): kenara değen plaka kesik sayılır, içeridekiler tam.
    en, boy = 1000, 600
    # İçi: y ≤ 600 − 0.6·x. Pay: x 10 px, y 6 px.
    m = plaka.AlanMaskesi.cokgenden([(0, 0), (1000, 0), (0, 600)], en, boy)
    K = plaka.Kutu
    assert plaka.tam_mi(K(50, 50, 150, 80, 0.9), en, boy, m)
    assert plaka.tam_mi(K(400, 250, 480, 280, 0.9), en, boy, m)          # köşegenin 30 px içinde
    assert not plaka.tam_mi(K(800, 400, 900, 440, 0.9), en, boy, m)     # tamamen dışarıda
    assert not plaka.tam_mi(K(400, 300, 480, 315, 0.9), en, boy, m)     # köşegeni kesiyor
    assert not plaka.tam_mi(K(400, 290, 480, 305, 0.9), en, boy, m)     # içeride ama payın içinde
    assert plaka.haric_orani(K(800, 400, 900, 440, 0.9), m) == 1.0
    assert plaka.haric_orani(K(50, 50, 150, 80, 0.9), m) == 0.0
    # Köşegen kutunun içinden: içerisi ∫500→666.7 (400 − 0.6x) dx = 8333 px²
    # / 40000 → dışarısı 0.7917 (piksel ızgarası ± %1).
    o = plaka.haric_orani(K(500, 200, 700, 400, 0.9), m)
    assert abs(o - 0.7917) < 0.01, o


def test_alan_maskesi_kare_disi_disarida_sayilir():
    # Kırpıntının dışına taşan kutu TAM değildir (eski kenar kuralı gibi).
    en, boy = 400, 300
    m = plaka.AlanMaskesi.cokgenden([(0, 0), (en, 0), (en, boy), (0, boy)], en, boy)
    K = plaka.Kutu
    assert not plaka.tam_mi(K(-5, 50, 60, 70, 0.9), en, boy, m)
    assert not plaka.tam_mi(K(350, 50, 410, 70, 0.9), en, boy, m)


def test_alan_maskesi_oranlar_vektor_tekiyle_ayni():
    en, boy = 1000, 600
    m = plaka.AlanMaskesi.cokgenden([(100, 0), (1000, 0), (1000, 600), (0, 600), (0, 300)], en, boy)
    kutular = np.array([[0, 0, 200, 200], [500, 100, 700, 300], [0, 200, 100, 400],
                        [10.5, 10.5, 90.2, 250.7], [990, 590, 1000, 600]], dtype=np.float64)
    tekler = [plaka.haric_orani(plaka.Kutu(*k, 0.9), m) for k in kutular]
    assert np.allclose(m.oranlar(kutular), tekler), (m.oranlar(kutular), tekler)


def test_haric_listesi_alan_maskesini_kabul_etmez():
    # Çokgen yolunu unutan bir yer sessizce "kesilen köşe yok" saymasın: yüksek sesle düşsün.
    m = plaka.AlanMaskesi.cokgenden([(0, 0), (10, 0), (10, 10)], 10, 10)
    try:
        plaka.haric_listesi(m)
    except TypeError:
        pass
    else:
        raise AssertionError("haric_listesi AlanMaskesi'ni kabul etmemeli")


def test_cokgen_coz():
    ok = plaka.cokgen_coz([(0, 0), (100, 0), (100, 50), (0, 50)])
    assert ok == ((0, 0), (100, 0), (100, 50), (0, 50)), ok
    assert plaka.cokgen_coz([[5, 5], [60, 5], [30, 40]]) == ((5, 5), (60, 5), (30, 40))
    hatalar = (
        [(0, 0), (10, 0)],                                              # 2 köşe
        [(i * 10, (i % 2) * 10) for i in range(9)],                     # 9 köşe
        [(0, 0), (100, 0), (0, 100), (100, 100)],                       # kendini kesiyor (papyon)
        # Kendini kesiyor ama alanı SIFIR değil (yalnızca alan kuralına takılmasın).
        [(0, 200), (300, 200), (300, 400), (0, 400), (150, 100)],
        [(0, 0), (5, 0), (5, 5)],                                       # çok küçük (12.5 px²)
        [(0, 0), (100, 0), (-1, 50)],                                   # eksi
        [(0, 0), (100.5, 0), (50, 50)],                                 # tamsayı değil
        [(0, 0), (True, 0), (50, 50)],                                  # bool
        [(0, 0), (100, 0), (50, 50, 1)],                                # 3 sayı
        [(0, 0), (100, 0), (100, 0), (50, 50)],                         # aynı köşe iki kez
        [(0, 0), (50, 0), (100, 0)],                                    # düz çizgi (alan 0)
    )
    for h in hatalar:
        try:
            plaka.cokgen_coz(h)
        except ValueError as e:
            assert str(e), h
        else:
            raise AssertionError(f"kabul edilmemeliydi: {h}")


def test_cokgen_metni():
    assert plaka.cokgen_metni(((1, 2), (30, 4), (5, 60))) == "1,2;30,4;5,60"
    assert plaka.cokgen_metinden("1,2;30,4;5,60") == ((1, 2), (30, 4), (5, 60))
    assert plaka.cokgen_metinden("") is None and plaka.cokgen_metinden("  ") is None
    for bozuk in ("1,2;3", "a,b;1,2;3,4", "1,2,3;4,5;6,7"):
        try:
            plaka.cokgen_metinden(bozuk)
        except ValueError:
            pass
        else:
            raise AssertionError(bozuk)


def test_ayar_takip():
    # 1.4.0: TAKIP=1 (varsayılan) her aracı izler; 0 = 1.3.4 geçiş kuralı.
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        assert "TAKIP" in plaka.AYAR_ADLARI
        a, u = plaka.calisma_ayarlari()
        assert a["takip"] is True and u == []
        a, u = plaka.calisma_ayarlari({"TAKIP": "0"})
        assert a["takip"] is False and u == []
        a, u = plaka.calisma_ayarlari({"TAKIP": "acik"})
        assert a["takip"] is True and len(u) == 1 and "TAKIP" in u[0], u
    finally:
        for k, v in eski.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def test_ayar_plaka_tam():
    # 1.3.4: PLAKA_TAM=1 (varsayılan) plakayı tam çözünürlükten okur; 0 = 1.3.3.
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        assert "PLAKA_TAM" in plaka.AYAR_ADLARI
        a, u = plaka.calisma_ayarlari()
        assert a["tam"] is True and u == []
        a, u = plaka.calisma_ayarlari({"PLAKA_TAM": "0"})
        assert a["tam"] is False and u == []
        a, u = plaka.calisma_ayarlari({"PLAKA_TAM": "evet"})
        assert a["tam"] is True and len(u) == 1 and "PLAKA_TAM" in u[0], u
    finally:
        for k, v in eski.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def test_kutu_olcekle():
    # 1.3.4: kutu küçültülmüş kırpıntıda bulunur, plaka tam çözünürlükten
    # okunur — kutu gerçek boyut oranlarıyla taşınır, skoru değişmez.
    K = plaka.Kutu
    k = plaka.kutu_olcekle(K(100, 50, 200, 80, 0.83), 2124 / 1568, 1046 / 772)
    assert abs(k.x1 - 135.459) < 1e-3 and abs(k.x2 - 270.918) < 1e-3, k
    assert abs(k.y1 - 67.746) < 1e-3 and abs(k.y2 - 108.394) < 1e-3, k
    assert k.skor == 0.83
    assert plaka.kutu_olcekle(K(1, 2, 3, 4, 0.5), 1.0, 1.0) == K(1, 2, 3, 4, 0.5)


def test_genislet():
    K = plaka.Kutu
    g = plaka.genislet(K(100, 100, 200, 120, 0.7), 0.10, 0.15, 1000, 1000)
    assert (g.x1, g.y1, g.x2, g.y2, g.skor) == (90, 97, 210, 123, 0.7), g
    g = plaka.genislet(K(2, 2, 98, 20, 0.7), 0.10, 0.15, 100, 21)
    assert (g.x1, g.y1, g.x2, g.y2) == (0, 0, 100, 21), g


def test_okuyucu_girdisi():
    img = np.zeros((100, 200, 3), np.uint8)
    img[:, :] = (255, 0, 0)                       # BGR mavi
    g = plaka.okuyucu_girdisi(img, plaka.Kutu(10, 10, 110, 40, 0.9))
    assert g.shape == (64, 128, 3) and g.dtype == np.uint8
    assert (g[..., 2] == 255).all() and (g[..., 0] == 0).all()            # RGB
    assert plaka.okuyucu_girdisi(img, plaka.Kutu(50, 50, 50, 60, 0.9)) is None
    assert plaka.okuyucu_girdisi(img, plaka.Kutu(-5, -5, 300, 300, 0.9)).shape == (64, 128, 3)


# ----------------------------------------------------- kısıtlı çözüm -------

def _olasilik(metin: str, p: float = 1.0) -> np.ndarray:
    """Her slotta istenen karakter p, kalan olasılık eşit dağıtılır."""
    a = plaka.ALFABE
    m = np.full((plaka.SLOT, len(a)), (1 - p) / (len(a) - 1), np.float32)
    dolu = metin.ljust(plaka.SLOT, plaka.DOLGU)
    for i, c in enumerate(dolu):
        m[i, :] = (1 - p) / (len(a) - 1)
        m[i, a.index(c)] = p
    return m


def test_kisitli_coz_temiz():
    metin, enk = plaka.kisitli_coz(_olasilik("34ABC123"))
    assert metin == "34ABC123" and abs(enk - 1.0) < 1e-6
    metin, enk = plaka.kisitli_coz(_olasilik("35PA052", 0.97))
    assert metin == "35PA052" and abs(enk - 0.97) < 1e-5


def test_kisitli_coz_gecersizi_zorlamaz():
    # Harf beklenen yerde model "8" diyor (B ikinci sırada): kısıtlı çözüm B'yi
    # SEÇER ama olasılığı DÜŞÜK kalır — emin sayılmaz, körlemesine düzeltme yok.
    p = _olasilik("34ABC123")
    a = plaka.ALFABE
    p[3, :] = 0.0
    p[3, a.index("8")] = 0.7
    p[3, a.index("B")] = 0.3
    metin, enk = plaka.kisitli_coz(p)
    assert metin == "34ABC123" and abs(enk - 0.3) < 1e-5, (metin, enk)
    # İl kodu 00 geçersiz: en olası GEÇERLİ il seçilir, olasılığı düşük.
    p = _olasilik("00ABC123")
    metin, enk = plaka.kisitli_coz(p)
    assert plaka.TR_PLAKA.match(metin) and enk < 0.5, (metin, enk)


def test_kisitli_coz_dolgu_olasiligi():
    # Plakadan sonraki slotlar boş olmalı; "boş" belirsizse emin değil.
    p = _olasilik("35PA052")
    a = plaka.ALFABE
    p[7, :] = 0.0
    p[7, a.index(plaka.DOLGU)] = 0.6
    p[7, a.index("8")] = 0.4
    metin, enk = plaka.kisitli_coz(p)
    assert metin == "35PA052" and abs(enk - 0.6) < 1e-5, (metin, enk)


def test_iki_kirpinti():
    assert plaka.iki_kirpinti(("34ABC123", 0.99), ("34ABC123", 0.96), 0.95) == ("34ABC123", 0.96)
    assert plaka.iki_kirpinti(("34ABC123", 0.99), ("34ABC12", 1.0), 0.95) is None
    assert plaka.iki_kirpinti(("34ABC123", 0.99), ("34ABC123", 0.94), 0.95) is None
    assert plaka.iki_kirpinti(("34ABC123", 0.94), ("34ABC123", 0.99), 0.95) is None


# ------------------------------------------------------------- oylama -------

T0 = dt.datetime(2026, 11, 6, 10, 0, 0, tzinfo=dt.timezone.utc)


def _z(sn: float) -> dt.datetime:
    return T0 + dt.timedelta(seconds=sn)


def _oylama() -> plaka.Oylama:
    return plaka.Oylama(k_oy=2, oran=0.6, tek_esik=0.99, m_kutu=2)


def test_oylama_iki_gorunum_emin():
    o = _oylama()
    o.kutu(_z(1), 1); o.okuma("34ABC123", 0.97, _z(1), 1)
    o.kutu(_z(2), 2); o.okuma("34ABC123", 0.98, _z(2), 2)
    k = o.karar()
    assert [(e.metin, e.zaman) for e in k.eminler] == [("34ABC123", _z(1))], k
    assert k.belirsiz is None


def test_oylama_tek_gorunum_cok_kare_emin_degil():
    # Duran araç: aynı görünümün kareleri bağımsız oy DEĞİL.
    o = _oylama()
    for i in range(6):
        o.kutu(_z(i), 7); o.okuma("34ABC123", 0.97, _z(i), 7)
    k = o.karar()
    assert k.eminler == [] and k.belirsiz is not None
    assert k.belirsiz.tahmin == "34ABC123" and abs(k.belirsiz.guven - 0.97) < 1e-9
    assert k.belirsiz.zaman == _z(0)


def test_oylama_tek_gorunum_cok_net_emin():
    o = _oylama()
    o.kutu(_z(1), 3); o.okuma("35PA052", 0.995, _z(1), 3)
    o.kutu(_z(2), 3); o.okuma("35PA052", 0.97, _z(2), 3)
    k = o.karar()
    assert [e.metin for e in k.eminler] == ["35PA052"], k


def test_oylama_anlasmazlik_personele():
    o = _oylama()
    for g, m in ((1, "34ABC123"), (2, "34ABC128"), (3, "34ABC123"), (4, "34ABC128")):
        o.kutu(_z(g), g); o.okuma(m, 0.97, _z(g), g)
    k = o.karar()
    assert k.eminler == [] and k.belirsiz is not None, k
    assert k.belirsiz.tahmin in ("34ABC123", "34ABC128")


def test_oylama_cogunluk_yeter():
    o = _oylama()
    for g, m in ((1, "34ABC123"), (2, "34ABC123"), (3, "34ABC128"), (4, "34ABC123")):
        o.kutu(_z(g), g); o.okuma(m, 0.97, _z(g), g)
    k = o.karar()
    assert [e.metin for e in k.eminler] == ["34ABC123"] and k.belirsiz is None, k


def test_oylama_iki_arac():
    o = _oylama()
    for g, m in ((1, "34ABC123"), (2, "34ABC123"), (3, "06KZ4581"), (4, "06KZ4581")):
        o.kutu(_z(g), g); o.okuma(m, 0.98, _z(g), g)
    k = o.karar()
    assert [(e.metin, e.zaman) for e in k.eminler] == [("34ABC123", _z(1)), ("06KZ4581", _z(3))], k


def test_oylama_ikinci_arac_belirsiz():
    o = _oylama()
    for g, m in ((1, "34ABC123"), (2, "34ABC123"), (3, "06KZ4581"), (4, "06KZ4587")):
        o.kutu(_z(g), g); o.okuma(m, 0.97, _z(g), g)
    k = o.karar()
    assert [e.metin for e in k.eminler] == ["34ABC123"], k
    assert k.belirsiz is not None and k.belirsiz.tahmin in ("06KZ4581", "06KZ4587"), k


def test_oylama_yalniz_kesik_kutular():
    o = _oylama()
    o.kutu(_z(1), 1); o.kutu(_z(2), 2); o.kutu(_z(3), 3)
    k = o.karar()
    assert k.eminler == [] and k.belirsiz is not None
    assert k.belirsiz.tahmin is None and k.belirsiz.guven is None and k.belirsiz.zaman == _z(1)


def test_oylama_tek_kare_hic():
    o = _oylama()
    o.kutu(_z(1), 1)
    k = o.karar()
    assert k.eminler == [] and k.belirsiz is None and k.kutulu_kare == 1
    assert _oylama().karar().kutulu_kare == 0


def test_oylama_tahmin_kaydi():
    # İki kırpıntının anlaşamadığı okumalar oy değildir ama personele tahmin olur.
    o = _oylama()
    o.kutu(_z(1), 1); o.tahmin("35AEU362", 0.75)
    o.kutu(_z(2), 2); o.tahmin("35AEU362", 0.80); o.tahmin("05AEU362", 0.60)
    k = o.karar()
    assert k.eminler == [] and k.belirsiz.tahmin == "35AEU362" and abs(k.belirsiz.guven - 0.80) < 1e-9


# ------------------------------------------------------------ ayarlar -------

def test_ayarlar_varsayilan_ve_ortam():
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        a, uyarilar = plaka.calisma_ayarlari()
        assert uyarilar == [] and a["acik"] is True
        assert a["bul_esik"] == 0.30 and a["oku_esik"] == 0.95 and a["tek_esik"] == 0.99
        # 1.3.2: sahadaki dizüstünde 1 iplik 410 ms, 2 iplik 268 ms (2026-11-07).
        assert a["iplik"] == 2 and a["bekle_sn"] == 0.4
        os.environ["PLAKA_BUL"] = "0"
        os.environ["PLAKA_OKU_ESIK"] = "0.97"
        a, uyarilar = plaka.calisma_ayarlari({"PLAKA_OKU_ESIK": "0.5", "PLAKA_IPLIK": "2"})
        assert a["acik"] is False and a["oku_esik"] == 0.97 and a["iplik"] == 2 and uyarilar == []
    finally:
        for k, v in eski.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def test_ayarlar_bozuk_deger_cokmez():
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        a, uyarilar = plaka.calisma_ayarlari({"PLAKA_OKU_ESIK": "abc", "PLAKA_IPLIK": "0",
                                               "PLAKA_BUL_ESIK": "1.5", "PLAKA_BEKLE_SN": "-1"})
        assert a["oku_esik"] == 0.95 and a["iplik"] == 2 and a["bul_esik"] == 0.30 and a["bekle_sn"] == 0.4
        assert len(uyarilar) == 4 and all("PLAKA_" in u for u in uyarilar), uyarilar
    finally:
        for k, v in eski.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


# ------------------------------------------------------------ modeller ------

def test_model_dosyalari_ve_ozetleri_yerinde():
    for m in (plaka.BULUCU, plaka.OKUYUCU):
        yol = os.path.join(plaka.MODEL_DIZINI, m.dosya)
        assert os.path.isfile(yol), yol
        assert plaka.sha256_dosya(yol) == m.sha256, m.dosya


def test_yukle_eksik_model():
    d = tempfile.mkdtemp(prefix="otopark-test-plaka-")
    try:
        plaka.yukle(plaka.calisma_ayarlari()[0], dizin=d)
        raise AssertionError("eksik modelle yüklendi")
    except plaka.PlakaHatasi as e:
        assert "bulunamadı" in str(e), e


def _gercek_model(d: str, m) -> None:
    """Gerçek modeli d'ye bağlar: sabit bağlantı (yer kaplamaz), olmazsa kopya."""
    kaynak = os.path.join(plaka.MODEL_DIZINI, m.dosya)
    hedef = os.path.join(d, m.dosya)
    try:
        os.link(kaynak, hedef)
    except OSError:
        with open(kaynak, "rb") as a, open(hedef, "wb") as b:
            b.write(a.read())


def test_yukle_bozuk_model():
    # Adı doğru, içeriği farklı model dosyası: özet tutmaz, açılmaz — iki model
    # için ayrı ayrı (öbürü gerçek dosya, yani hata gerçekten bozuk olandan).
    for bozuk in (plaka.BULUCU, plaka.OKUYUCU):
        d = tempfile.mkdtemp(prefix="otopark-test-plaka-")
        for m in (plaka.BULUCU, plaka.OKUYUCU):
            if m is bozuk:
                with open(os.path.join(d, m.dosya), "wb") as f:
                    f.write(b"bozuk model")
            else:
                _gercek_model(d, m)
        try:
            plaka.yukle(plaka.calisma_ayarlari()[0], dizin=d)
            raise AssertionError("bozuk modelle yüklendi")
        except plaka.PlakaHatasi as e:
            assert "doğrulanamadı" in str(e) and bozuk.dosya in str(e), e


def test_onnxruntime_telemetrisi_kapali():
    """
    onnxruntime'ın resmî paketi telemetriyi VARSAYILAN AÇIK gönderir (Microsoft'a,
    HTTPS — paketin kendi Privacy.md'si). Otoparkın bilgisayarı kimseye veri
    göndermemeli: ORT_DISABLE_TELEMETRY=1, onnxruntime İLK kez içe aktarılmadan
    ÖNCE kurulmalı (sonra kurulursa işe yaramaz) — ortam başka bir şey dese
    bile — ve ayrıca API ile de kapatılır.
    """
    import builtins
    import types
    sahte = types.ModuleType("onnxruntime")
    cagri: list[str] = []
    sahte.disable_telemetry_events = lambda: cagri.append("kapat")
    gorulen: dict = {}
    gercek = builtins.__import__

    def ice_aktar(ad, *a, **k):
        if ad == "onnxruntime":
            gorulen["env"] = os.environ.get("ORT_DISABLE_TELEMETRY")
            return sahte
        return gercek(ad, *a, **k)

    eski = os.environ.get("ORT_DISABLE_TELEMETRY")
    os.environ["ORT_DISABLE_TELEMETRY"] = "0"
    builtins.__import__ = ice_aktar
    try:
        ort = plaka._ort_yukle()
    finally:
        builtins.__import__ = gercek
        os.environ.pop("ORT_DISABLE_TELEMETRY", None)
        if eski is not None:
            os.environ["ORT_DISABLE_TELEMETRY"] = eski
    assert ort is sahte and gorulen == {"env": "1"} and cagri == ["kapat"], (gorulen, cagri)
    # Köprünün hiçbir modülü onnxruntime'ı plaka._ort_yukle dışında içe aktarmaz.
    for ad in sorted(os.listdir(BURASI)):
        if ad.endswith(".py") and not ad.startswith("test_"):
            with open(os.path.join(BURASI, ad), encoding="utf-8") as f:
                metin = f.read()
            n = len(re.findall(r"^\s*(?:import onnxruntime|from onnxruntime)", metin, re.M))
            assert n == (1 if ad == "plaka.py" else 0), (ad, n)


def test_yukle_onnxruntime_yoksa():
    onceki = sys.modules.get("onnxruntime", "YOK")
    sys.modules["onnxruntime"] = None               # içe aktarma ImportError verir
    try:
        try:
            plaka.yukle(plaka.calisma_ayarlari()[0])
            raise AssertionError("onnxruntime olmadan yüklendi")
        except plaka.PlakaHatasi as e:
            assert "onnxruntime" in str(e), e
    finally:
        if onceki == "YOK":
            sys.modules.pop("onnxruntime", None)
        else:
            sys.modules["onnxruntime"] = onceki


def test_gercek_model_yuklenir_ve_bos_sahnede_plaka_yok():
    if not _ort_var():
        ATLANAN.append("gerçek model (onnxruntime kurulu değil)")
        return
    p = plaka.yukle(plaka.calisma_ayarlari()[0])
    bos = np.full((668, 1568, 3), 110, np.uint8)
    assert p.bul(bos) == []
    # Okuyucu iki kırpıntıyı TEK çağrıda okur; sonuçlar sırayla döner.
    img = np.full((200, 400, 3), 200, np.uint8)
    sonuc = p.oku_cift(img, plaka.Kutu(100, 80, 300, 125, 0.9))
    assert len(sonuc) == 2 and all(isinstance(m, str) and 0.0 <= e <= 1.0 for m, e in sonuc), sonuc


def test_gercek_okuyucu_sabit_girdide_sabit_cikti():
    # Ön işlem ya da çalışma zamanı sürümü değişirse bu kırılır (altın değer:
    # upstream fast-plate-ocr 1.1.0 aynı girdide aynı olasılıkları verdi).
    if not _ort_var():
        ATLANAN.append("altın çıktı (onnxruntime kurulu değil)")
        return
    p = plaka.yukle(plaka.calisma_ayarlari()[0])
    girdi = plaka.sabit_okuyucu_girdisi()
    ham = p.ham_oku(girdi[None])[0]
    metin, enk = plaka.kisitli_coz(ham)
    assert metin == plaka.ALTIN_METIN, metin
    assert abs(enk - plaka.ALTIN_ENK) < 2e-3, enk


if __name__ == "__main__":
    # Bu çalıştırmanın geçici dosyaları tek klasörde toplanır ve SİLİNMEZ
    # (sahibin kuralı: hiçbir betik bir şey silmez); yolu sonunda yazılır.
    kok = tempfile.mkdtemp(prefix="otopark-test-plaka-")
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
