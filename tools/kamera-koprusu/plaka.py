# -*- coding: utf-8 -*-
"""
Plaka bulucu + okuyucu (köprü 1.3.0).

Köprü 1.2.x her aracın fotoğrafını sunucuya gönderiyor, plakayı bulutta bir
model okuyordu. 1.3.0'dan beri plakayı BU BİLGİSAYAR okur (işletme sahibinin
kararı, 2026-11-06): kamera menüsü (SMD) ayarı yok, okuma başına ücret yok,
internet beklemesi yok. Sunucuya yalnızca EMİN olunan plaka metni ve saklanan
fotoğraf gider; emin olunamayan araç personele düşer ("Çözülmemiş kayıtlar").

İki model, ikisi de ONNX, ikisi de onnxruntime ile işlemcide:
  · bulucu  — open-image-models `yolo-v9-t-640-license-plate-end2end`
              (kod MIT; ağırlıkların lisansı yazılı değil — sahip bu riski
              kabul etti). Karede plakanın KUTUSUNU bulur, okumaz. 640 seçildi:
              sahadaki küçük arka plakalar (kırpıntıda 65–110 px) 512'de
              kaçıyor, 640 %94–99.5 buluyor (Faz 0, 2026-11-06).
  · okuyucu — fast-plate-ocr `cct-s-v2-global` (kod ve ağırlıklar MIT,
              yazarı 2026-10-20). 66 bölge, Türkiye dahil; 2.359 Türk
              plakasında tek karede %97.5 tam doğru.

Ön işlem upstream paketlerle BİREBİR (open-image-models 0.5.1 letterbox,
fast-plate-ocr 1.1.0 resize); paketlerin kendisi gömülmez — yalnızca modeller
ve bu dosya. Modellerin SHA-256'sı sabit: değişmiş dosya yüklenmez.

Emin olma kuralları — tek karede bile yanlış plakaya bilet açılmasın:
  1. Yalnızca TAM plaka okunur: kutu kırpıntının (ve L şeklindeki kesik
     köşenin) kenarlarından uzak. Kenara değen plakada okuyucu eksik haneyi
     "tahmin eder" ve emin görünür (Faz 0'da görüldü).
  2. Okuma İKİ kez yapılır — dar kutu ve %10/%15 genişletilmiş kutu — ve
     ikisi aynı plakayı her karakterde ≥ PLAKA_OKU_ESIK ile vermelidir. Dar
     kutu son haneyi kesebilir, geniş kutu eğik plakada araba gövdesini
     görüp şaşırabilir; ikisi birden aynı yanlışı yapmadı (Faz 0).
  3. Kısıtlı çözüm: karakterler Türk plaka biçimine göre seçilir (il 01–81,
     harf yerinde harf, rakam yerinde rakam) ama körlemesine "O→0" düzeltmesi
     YOK — zorla seçilen karakterin olasılığı düşük kalır, okuma emin sayılmaz.
  4. Oylama: aynı aracın en az iki FARKLI görünümü (Oylama) aynı plakayı
     vermeli; tek görünümde ancak her karakter ≥ PLAKA_TEK_ESIK ise.

Ayarlar içe aktarmada değil BAŞLATIRKEN okunur (köprü bu modülü ayar dosyasını
yüklemeden önce içe aktarır): bozuk bir değer köprüyü düşürmez, varsayılana
döner ve uyarılır.
"""
from __future__ import annotations

import hashlib
import itertools
import math
import os
import re
from typing import NamedTuple

import cv2
import numpy as np

# ------------------------------------------------------------------ modeller ---


class ModelDosyasi(NamedTuple):
    dosya: str
    sha256: str
    kaynak: str


BULUCU = ModelDosyasi(
    "yolo-v9-t-640-license-plates-end2end.onnx",
    "c3c1026ca7d0585dd88084d68182dd897113712fa734ae1557ca70174440c076",
    "https://github.com/ankandrew/open-image-models/releases/download/assets/"
    "yolo-v9-t-640-license-plates-end2end.onnx",
)
OKUYUCU = ModelDosyasi(
    "cct_s_v2_global.onnx",
    "384bbbd2cea3ef54761d3df70822ef3a349ee1a112aeafddbe0e3ba06bc6e47b",
    "https://github.com/ankandrew/cnn-ocr-lp/releases/download/arg-plates/cct_s_v2_global.onnx",
)
# Paketlenmiş sürümde bu dosya _internal\ içindedir ve modeller _internal\modeller\
# altına konur (paketle.py --add-data); kaynaktan çalışırken yanındaki modeller\.
MODEL_DIZINI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "modeller")

BULUCU_BOYUT = 640
# cct_s_v2_global_plate_config.yaml'dan (fast-plate-ocr): 64×128, RGB, oran
# korunmaz, doğrusal ara değerleme, 10 slot, dolgu "_".
OKUYUCU_EN, OKUYUCU_BOY = 128, 64
ALFABE = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_"
DOLGU = "_"
SLOT = 10

# Sunucuyla AYNI desen (supabase/functions/_shared/vlm.ts TR_PLAKA; test_plaka
# metni karşılaştırır). Q, W, X yönetmelikte yok.
TR_PLAKA = re.compile(
    r"^(?:0[1-9]|[1-7][0-9]|8[01])(?:[A-PR-VYZ][0-9]{4,5}|[A-PR-VYZ]{2}[0-9]{3,4}"
    r"|[A-PR-VYZ]{3}[0-9]{2,3})$"
)
HARFLER = "ABCDEFGHIJKLMNOPRSTUVYZ"
_RAKAM_I = [ALFABE.index(c) for c in "0123456789"]
_HARF_I = [ALFABE.index(c) for c in HARFLER]
_DOLGU_I = ALFABE.index(DOLGU)
_YAPILAR = ((1, 4), (1, 5), (2, 3), (2, 4), (3, 2), (3, 3))     # (harf, rakam)
_ILLER = [f"{i:02d}" for i in range(1, 82)]

# Okumadan önce genişletme (her yana): kural 2'nin ikinci kırpıntısı.
PAY_X, PAY_Y = 0.10, 0.15
# Kutunun bu kadarı kesilen köşede kalıyorsa kutu hiç sayılmaz (L şekli).
HARIC_DUSUR = 0.20

# Oylama varsayılanları (Faz 0).
K_OY, ORAN, M_KUTU = 2, 0.6, 2


class PlakaHatasi(Exception):
    """Okuyucu kullanılamıyor — sebep kullanıcıya gösterilecek Türkçe metin."""


# ------------------------------------------------------------------ ayarlar ----

AYAR_ADLARI = ("PLAKA_BUL", "PLAKA_BUL_ESIK", "PLAKA_OKU_ESIK", "PLAKA_TEK_ESIK",
               "PLAKA_IPLIK", "PLAKA_BEKLE_SN",
               "ARAC_BUL", "ARAC_BUL_ESIK", "ARAC_GECIS_ESIK", "PLAKA_TAM", "TAKIP",
               "PLAKA_BIRLESIK")


def _oran(alt_dahil: bool):
    def gecerli(v: float) -> bool:
        return (v >= 0 if alt_dahil else v > 0) and v <= 1
    return gecerli


_KURALLAR = (
    # ortam adı, anahtar, varsayılan, çevirici, geçerlilik
    ("PLAKA_BUL", "acik", True, lambda s: {"1": True, "0": False}[s.strip()], lambda v: True),
    ("PLAKA_BUL_ESIK", "bul_esik", 0.30, float, lambda v: 0 < v < 1),
    ("PLAKA_OKU_ESIK", "oku_esik", 0.95, float, _oran(False)),
    ("PLAKA_TEK_ESIK", "tek_esik", 0.99, float, _oran(False)),
    # 1.3.2: sahadaki dizüstünde (8 mantıksal işlemci) kare başına plaka + araç
    # bulucu 1 iplikte 410 ms, 2 iplikte 268 ms, 4 iplikte 241 ms (2026-11-07).
    ("PLAKA_IPLIK", "iplik", 2, int, lambda v: 1 <= v <= 8),
    ("PLAKA_BEKLE_SN", "bekle_sn", 0.4, float, lambda v: 0 <= v <= 5),
    # 1.3.4: plaka küçültülmüş kırpıntıda BULUNUR, TAM çözünürlükten okunur
    # (sahada 2124 px'lik kırpıntı 1568'e küçülüyordu). 0 = 1.3.3 davranışı.
    ("PLAKA_TAM", "tam", True, lambda s: {"1": True, "0": False}[s.strip()], lambda v: True),
    # 1.3.1 araç bulucu (arac.py). Faz 0: araçlar 0.40-0.94, insanlar ≤0.27.
    # Duran şey ARAC_BUL_ESIK altındaysa araç sayılmaz; durmadan geçen plakasız
    # şey ancak ARAC_GECIS_ESIK'i geçerse araç sayılır (gölge kart açmasın).
    ("ARAC_BUL", "arac_acik", True, lambda s: {"1": True, "0": False}[s.strip()], lambda v: True),
    ("ARAC_BUL_ESIK", "arac_esik", 0.35, float, lambda v: 0 < v < 1),
    ("ARAC_GECIS_ESIK", "arac_gecis_esik", 0.60, float, lambda v: 0 < v < 1),
    # 1.4.0: her aracı izle (takip.py), karar araç başına bir kez. 0 = 1.3.4
    # geçiş kuralı birebir. Araç bulucu yok/bozuksa zaten 1.3.4'e döner.
    ("TAKIP", "takip", True, lambda s: {"1": True, "0": False}[s.strip()], lambda v: True),
    # 1.4.1: çok karede birleştirme (Oylama.birlesik; yalnızca izleme kipinde).
    # 0 = yalnızca tek karede %95 iki görünüm kuralı.
    ("PLAKA_BIRLESIK", "birlesik", True, lambda s: {"1": True, "0": False}[s.strip()],
     lambda v: True),
)


def calisma_ayarlari(ek: dict | None = None) -> tuple[dict, list[str]]:
    """
    (ayarlar, uyarılar). Ortam önce gelir (kopru'nun `setdefault` kuralı),
    sonra `ek` (`--plaka` kipinde şeridin ayar dosyası). Bozuk değer ASLA
    istisna fırlatmaz: varsayılan kullanılır ve uyarı satırı döner.
    """
    ayar: dict = {}
    uyarilar: list[str] = []
    for ad, anahtar, varsayilan, cevir, gecerli in _KURALLAR:
        ham = os.environ.get(ad)
        if ham is None and ek is not None and ek.get(ad) is not None:
            ham = str(ek[ad])
        if ham is None or ham.strip() == "":
            ayar[anahtar] = varsayilan
            continue
        try:
            deger = cevir(ham)
            if isinstance(deger, float) and not math.isfinite(deger):
                raise ValueError
            if not gecerli(deger):
                raise ValueError
            ayar[anahtar] = deger
        except (ValueError, KeyError, TypeError):
            ayar[anahtar] = varsayilan
            uyarilar.append(f"{ad}={ham!r} geçersiz — varsayılan {varsayilan} kullanılıyor")
    return ayar, uyarilar


# --------------------------------------------------------------- plaka kuralı --

def bir_fark(a: str | None, b: str | None) -> bool:
    """supabase 037 `plaka_yakin` ile birebir: tek değişim / tek eksik-fazla."""
    if a is None or b is None or len(a) < 5 or len(b) < 5 or a == b:
        return False
    if len(a) == len(b):
        return sum(1 for x, y in zip(a, b) if x != y) == 1
    if abs(len(a) - len(b)) == 1:
        uzun, kisa = (a, b) if len(a) > len(b) else (b, a)
        return any(uzun[:i] + uzun[i + 1:] == kisa for i in range(len(uzun)))
    return False


# ----------------------------------------------------------- görüntü hazırlığı -

class Kutu(NamedTuple):
    """Kırpıntı (kirpik) piksellerinde plaka kutusu."""
    x1: float
    y1: float
    x2: float
    y2: float
    skor: float


def letterbox(img: np.ndarray, n: int = BULUCU_BOYUT):
    """open-image-models 0.5.1 `preprocess` ile birebir: (girdi, r, dw, dh)."""
    h, w = img.shape[:2]
    r = min(n / h, n / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    dw, dh = (n - nw) / 2, (n - nh) / 2
    if (w, h) != (nw, nh):
        img = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    ust, alt = int(round(dh - 0.1)), int(round(dh + 0.1))
    sol, sag = int(round(dw - 0.1)), int(round(dw + 0.1))
    img = cv2.copyMakeBorder(img, ust, alt, sol, sag, cv2.BORDER_CONSTANT, value=(114, 114, 114))
    x = (img.transpose((2, 0, 1))[::-1] / 255.0).astype(np.float32)     # BGR → RGB, CHW
    return np.ascontiguousarray(x[None]), r, dw, dh


def kutulari_coz(cikti: np.ndarray, r: float, dw: float, dh: float, esik: float,
                 en: int, boy: int) -> list[Kutu]:
    """Model satırları [b, x1, y1, x2, y2, sınıf, skor] → kırpıntı kutuları (skora göre)."""
    kutular = []
    for satir in np.asarray(cikti).reshape(-1, 7).tolist():
        skor = float(satir[6])
        if skor < esik:
            continue
        x1 = min(max((satir[1] - dw) / r, 0.0), float(en))
        y1 = min(max((satir[2] - dh) / r, 0.0), float(boy))
        x2 = min(max((satir[3] - dw) / r, 0.0), float(en))
        y2 = min(max((satir[4] - dh) / r, 0.0), float(boy))
        if x2 - x1 <= 0 or y2 - y1 <= 0:
            continue
        kutular.append(Kutu(x1, y1, x2, y2, skor))
    kutular.sort(key=lambda k: -k.skor)
    return kutular


def _paylar(en: int, boy: int) -> tuple[float, float]:
    return max(3.0, 0.01 * en), max(3.0, 0.01 * boy)


# 1.3.3: en çok bu kadar kesilen köşe (park etmiş araçların üstü).
HARIC_EN_COK = 3


def haric_listesi(haric) -> tuple:
    """
    Kesilen köşe(ler) → dikdörtgen demeti ((x, y, w, h), …).

    İKİ biçimi ayıran TEK yer: None → (), tek dikdörtgen (dört sayı — 1.3.0
    biçimi) → bir elemanlı demet, dikdörtgen dizisi → demet. Kesilen köşeyi
    açan her fonksiyon bunu çağırır; eski çağıranlar değişmeden çalışır.
    """
    if haric is None:
        return ()
    if isinstance(haric, AlanMaskesi):
        # 1.4.0: çokgen alan dikdörtgen listesi DEĞİLDİR. Onu buraya getiren
        # yol çokgen dalını unutmuştur — sessizce "kesilen köşe yok" saymak
        # yerine düşer (test_haric_listesi_alan_maskesini_kabul_etmez).
        raise TypeError("AlanMaskesi dikdörtgen listesi değildir")
    ogeler = list(haric)
    if len(ogeler) == 4 and all(isinstance(v, (int, float, np.integer, np.floating)) for v in ogeler):
        return (tuple(v.item() if hasattr(v, "item") else v for v in ogeler),)
    return tuple(tuple(r) for r in ogeler)


def kesisim_parcalari(haric):
    """
    Birleşim alanı için (işaret, (x1, y1, x2, y2)) parçaları: dikdörtgenlerin
    boş olmayan her alt kümesinin kesişimi (içerme-dışlama). Üst üste binen
    kesilen köşeler böylece İKİ KEZ sayılmaz. En çok 3 alan → en çok 7 parça.
    """
    kutular = [(x, y, x + w, y + h) for x, y, w, h in haric_listesi(haric)]
    for n in range(1, len(kutular) + 1):
        for grup in itertools.combinations(kutular, n):
            x1, y1 = max(g[0] for g in grup), max(g[1] for g in grup)
            x2, y2 = min(g[2] for g in grup), min(g[3] for g in grup)
            if x2 > x1 and y2 > y1:
                yield (1 if n % 2 else -1), (x1, y1, x2, y2)


def kesilen_alan(x1: float, y1: float, x2: float, y2: float, haric) -> float:
    """(x1, y1, x2, y2) kutusunun kesilen köşelerin BİRLEŞİMİNDE kalan alanı."""
    toplam = 0.0
    for isaret, (a1, b1, a2, b2) in kesisim_parcalari(haric):
        ix = max(0.0, min(x2, a2) - max(x1, a1))
        iy = max(0.0, min(y2, b2) - max(y1, b1))
        toplam += isaret * ix * iy
    return toplam


def tam_mi(k: Kutu, en: int, boy: int, haric: tuple | None = None) -> bool:
    """
    Kutu kırpıntının her kenarından (ve HER kesilen köşeden) en az
    max(3 px, %1) uzakta mı? Değiyorsa plaka büyük olasılıkla kesik: okunmaz.
    """
    if isinstance(haric, AlanMaskesi):
        return haric.tam_mi(k)
    px, py = _paylar(en, boy)
    if k.x1 < px or k.y1 < py or k.x2 > en - px or k.y2 > boy - py:
        return False
    for hx, hy, hw, hh in haric_listesi(haric):
        ex1, ey1, ex2, ey2 = hx - px, hy - py, hx + hw + px, hy + hh + py
        if k.x1 < ex2 and k.x2 > ex1 and k.y1 < ey2 and k.y2 > ey1:
            return False
    return True


def haric_orani(k: Kutu, haric: tuple | None) -> float:
    """Kutunun kesilen köşelerde (birleşimlerinde) kalan alan oranı (0..1)."""
    if isinstance(haric, AlanMaskesi):
        return haric.oran(k)
    alan = (k.x2 - k.x1) * (k.y2 - k.y1)
    if alan <= 0:
        return 0.0
    return kesilen_alan(k.x1, k.y1, k.x2, k.y2, haric) / alan


# ------------------------------------------- 1.4.0: kırpma ALANI (çokgen) ----

# Kırpma sayfasında tıklanan alanın en çok köşesi.
COKGEN_EN_COK = 8
# Bundan küçük alan çizim hatasıdır (8×8 px): köprü hiçbir şey göremezdi.
COKGEN_EN_AZ_ALAN = 64
# Kayan nokta payı (piksel): sınırdaki kutu yuvarlama hatasıyla dışarı taşmasın.
_KAYAN = 1e-6


def _yon(a, b, c) -> int:
    v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    return (v > 0) - (v < 0)


def _uzerinde(a, b, c) -> bool:
    """c, a-b doğru parçasının üzerinde mi (üç nokta aynı doğrudayken)."""
    return min(a[0], b[0]) <= c[0] <= max(a[0], b[0]) and min(a[1], b[1]) <= c[1] <= max(a[1], b[1])


def _parcalar_kesisir(a, b, c, d) -> bool:
    """a-b ile c-d doğru parçaları kesişiyor ya da DEĞİYOR mu."""
    y1, y2, y3, y4 = _yon(a, b, c), _yon(a, b, d), _yon(c, d, a), _yon(c, d, b)
    if y1 != y2 and y3 != y4:
        return True
    return ((y1 == 0 and _uzerinde(a, b, c)) or (y2 == 0 and _uzerinde(a, b, d))
            or (y3 == 0 and _uzerinde(c, d, a)) or (y4 == 0 and _uzerinde(c, d, b)))


def cokgen_alani(noktalar) -> float:
    """Ayakkabı bağı formülü: çokgenin alanı (px²), yönden bağımsız."""
    n = len(noktalar)
    return abs(sum(noktalar[i][0] * noktalar[(i + 1) % n][1] - noktalar[(i + 1) % n][0] * noktalar[i][1]
                   for i in range(n))) / 2.0


def cokgen_coz(noktalar) -> tuple:
    """
    Tıklanan köşeler → ((x, y), …) tamsayı tuple; geçersizse ValueError
    (Türkçe). Kurallar: 3..COKGEN_EN_COK köşe, eksi olmayan tamsayılar (bool
    değil), aynı köşe iki kez yok, kenarlar birbirini KESMEZ (papyon şekli
    içini belirsiz bırakır), alan ≥ COKGEN_EN_AZ_ALAN. Köprü (KIRPMA_ALAN,
    KAPI_ALANI) ve kırpma sayfası bunu paylaşır: iki taraf ayrışamaz.
    """
    try:
        liste = [tuple(n) for n in noktalar]
    except TypeError:
        raise ValueError("alan köşelerin listesi olmalı") from None
    if not 3 <= len(liste) <= COKGEN_EN_COK:
        raise ValueError(f"alan 3 ile {COKGEN_EN_COK} arasında köşeden oluşmalı")
    for n in liste:
        if len(n) != 2 or any(isinstance(v, bool) or not isinstance(v, (int, np.integer)) for v in n):
            raise ValueError("alan köşeleri tamsayı (x, y) piksel olmalı")
        if n[0] < 0 or n[1] < 0:
            raise ValueError("alan köşeleri eksi olamaz")
    liste = [(int(x), int(y)) for x, y in liste]
    if len(set(liste)) != len(liste):
        raise ValueError("alanda aynı köşe iki kez var")
    k = len(liste)
    for i in range(k):
        for j in range(i + 1, k):
            if j == i + 1 or (i == 0 and j == k - 1):
                continue                      # komşu kenarlar köşede buluşur
            if _parcalar_kesisir(liste[i], liste[(i + 1) % k], liste[j], liste[(j + 1) % k]):
                raise ValueError("alanın kenarları birbirini kesiyor — köşeleri sırayla tıklayın")
    if cokgen_alani(liste) < COKGEN_EN_AZ_ALAN:
        raise ValueError("alan çok küçük")
    return tuple(liste)


def cokgen_kutusu(noktalar) -> tuple[int, int, int, int]:
    """Çokgenin çevreleyen dikdörtgeni (x, y, w, h) — köprü bunu kırpar."""
    xs, ys = [p[0] for p in noktalar], [p[1] for p in noktalar]
    return min(xs), min(ys), max(1, max(xs) - min(xs)), max(1, max(ys) - min(ys))


def cokgen_metni(noktalar) -> str:
    """((x, y), …) → ayar dosyasındaki "x,y;x,y;…" metni."""
    return ";".join(f"{x},{y}" for x, y in noktalar)


def cokgen_metinden(metin: str | None) -> tuple | None:
    """Ayar metni → doğrulanmış köşeler; boşsa None; bozuksa ValueError (Türkçe)."""
    metin = (metin or "").strip()
    if not metin:
        return None
    noktalar = []
    for parca in metin.split(";"):
        try:
            x, y = (int(v) for v in parca.split(","))
        except ValueError:
            raise ValueError('alan "x,y;x,y;x,y" biçiminde olmalı (piksel, en az 3 köşe)') from None
        noktalar.append((x, y))
    return cokgen_coz(noktalar)


def cokgen_dis_maskesi(noktalar, en: int, boy: int) -> np.ndarray:
    """
    (boy, en) uint8: 1 = çokgenin DIŞI. Köşeler kesirli olabilir (1/16 px
    hassasiyetle çizilir). Griye boyama (kopru.kirp_maskeli) ve kurallar
    (AlanMaskesi) bu TEK çizimi kullanır.
    """
    maske = np.ones((int(boy), int(en)), np.uint8)
    nokta = np.round(np.asarray(noktalar, dtype=np.float64) * 16).astype(np.int32)
    cv2.fillPoly(maske, [nokta.reshape(-1, 1, 2)], 0, cv2.LINE_8, 4)
    return maske


class AlanMaskesi:
    """
    1.4.0: kırpma ALANI (tıklanan çokgen), ölçeklenmiş kırpıntının
    pikselinde. Hariç dikdörtgenlerin genellemesi: alanın dışı griye boyanır
    ve plaka / araç kuralları "kesilen köşe" yerine "alanın dışı"na bakar.

    Kenar kuralı (tam_mi) eskisiyle aynı ölçüdedir: kutu, `_paylar` kadar
    genişletildiğinde alanın dışına (ya da kırpıntının dışına) TEK piksel
    taşımıyorsa tamdır. Dikdörtgen ve L şekilli alanlarda eski kuralla
    birebir aynı sonucu verir (test_alan_maskesi_*). Sayım tümleşik görüntü
    ile O(1): her karede onlarca kutu için ucuz.
    """

    def __init__(self, dis: np.ndarray):
        dis = np.asarray(dis) != 0                       # True = alanın DIŞI
        self.boy, self.en = dis.shape[:2]
        self._ii = cv2.integral(dis.astype(np.uint8))    # (boy+1, en+1)

    @classmethod
    def cokgenden(cls, noktalar, en: int, boy: int) -> "AlanMaskesi":
        """Köşeler (bu maskenin pikselinde, kesirli olabilir) → maske."""
        return cls(cokgen_dis_maskesi(noktalar, en, boy))

    def _say(self, x1: int, y1: int, x2: int, y2: int) -> int:
        ii = self._ii
        return int(ii[y2, x2]) - int(ii[y1, x2]) - int(ii[y2, x1]) + int(ii[y1, x1])

    def disarida_px(self, x1: float, y1: float, x2: float, y2: float) -> int:
        """Kutunun (dışa yuvarlanmış) piksellerinden alanın DIŞINDA kalanlar;
        kırpıntının dışına taşan pikseller de dışarıda sayılır. _KAYAN: tam
        sınırdaki kutu (515.68 − 15.68 = 499.99999999999994) eski kuraldaki
        gibi içeride sayılsın."""
        a1, b1 = math.floor(x1 + _KAYAN), math.floor(y1 + _KAYAN)
        a2, b2 = math.ceil(x2 - _KAYAN), math.ceil(y2 - _KAYAN)
        if a2 <= a1 or b2 <= b1:
            return 0
        toplam = (a2 - a1) * (b2 - b1)
        c1, d1, c2, d2 = max(a1, 0), max(b1, 0), min(a2, self.en), min(b2, self.boy)
        if c2 <= c1 or d2 <= d1:
            return toplam
        return toplam - (c2 - c1) * (d2 - d1) + self._say(c1, d1, c2, d2)

    def tam_mi(self, k) -> bool:
        px, py = _paylar(self.en, self.boy)
        return self.disarida_px(k.x1 - px, k.y1 - py, k.x2 + px, k.y2 + py) == 0

    def oran(self, k) -> float:
        """Kutunun (kırpıntı içinde kalan kısmının) alanın dışındaki oranı."""
        return float(self.oranlar(np.array([[k.x1, k.y1, k.x2, k.y2]], dtype=np.float64))[0])

    def oranlar(self, kutular: np.ndarray) -> np.ndarray:
        """(N, ≥4) x1 y1 x2 y2 → (N,) dışarıda kalan oran (vektör)."""
        k = np.asarray(kutular, dtype=np.float64)
        if k.size == 0:
            return np.zeros(0)
        k = k.reshape(-1, k.shape[-1])
        x1 = np.clip(np.floor(k[:, 0] + _KAYAN), 0, self.en).astype(np.int64)
        y1 = np.clip(np.floor(k[:, 1] + _KAYAN), 0, self.boy).astype(np.int64)
        x2 = np.clip(np.ceil(k[:, 2] - _KAYAN), 0, self.en).astype(np.int64)
        y2 = np.clip(np.ceil(k[:, 3] - _KAYAN), 0, self.boy).astype(np.int64)
        alan = np.clip(x2 - x1, 0, None) * np.clip(y2 - y1, 0, None)
        ii = self._ii.astype(np.int64)
        x2, y2 = np.maximum(x2, x1), np.maximum(y2, y1)
        dis = ii[y2, x2] - ii[y1, x2] - ii[y2, x1] + ii[y1, x1]
        with np.errstate(divide="ignore", invalid="ignore"):
            return np.where(alan > 0, dis / np.maximum(alan, 1), 0.0)


def kutu_olcekle(k: Kutu, sx: float, sy: float) -> Kutu:
    """
    1.3.4: küçültülmüş kırpıntıda bulunan kutu → tam çözünürlüklü kırpıntının
    pikselleri (sx, sy = gerçek boyut oranları). Skor değişmez.
    """
    return Kutu(k.x1 * sx, k.y1 * sy, k.x2 * sx, k.y2 * sy, k.skor)


def genislet(k: Kutu, px: float, py: float, en: int, boy: int) -> Kutu:
    w, h = k.x2 - k.x1, k.y2 - k.y1
    return Kutu(max(0.0, k.x1 - px * w), max(0.0, k.y1 - py * h),
                min(float(en), k.x2 + px * w), min(float(boy), k.y2 + py * h), k.skor)


def okuyucu_girdisi(img: np.ndarray, k: Kutu) -> np.ndarray | None:
    """Kutunun içi → okuyucunun girdisi (64×128 RGB uint8); boşsa None."""
    h, w = img.shape[:2]
    x1, y1 = int(max(0.0, k.x1)), int(max(0.0, k.y1))
    x2, y2 = int(min(float(w), k.x2)), int(min(float(h), k.y2))
    if x2 <= x1 or y2 <= y1:
        return None
    parca = cv2.cvtColor(img[y1:y2, x1:x2], cv2.COLOR_BGR2RGB)
    return cv2.resize(parca, (OKUYUCU_EN, OKUYUCU_BOY), interpolation=cv2.INTER_LINEAR)


# ------------------------------------------------------------- kısıtlı çözüm --

def kisitli_coz(p: np.ndarray) -> tuple[str, float]:
    """
    (10, 37) olasılık → en olası GEÇERLİ Türk plakası ve seçilen her karakterin
    (boş slotlar dahil) en düşük olasılığı. Zorla seçilen karakter düşük
    olasılık taşır, yani okuma emin sayılmaz — sessiz düzeltme yoktur.
    """
    p = np.asarray(p, dtype=np.float64)
    lp = np.log(np.clip(p, 1e-12, 1.0))
    il_lp, il = max((lp[0, ALFABE.index(a)] + lp[1, ALFABE.index(b)], a + b) for a, b in _ILLER)
    en_iyi: tuple[float, str] | None = None
    for harf, rakam in _YAPILAR:
        n = 2 + harf + rakam
        s, metin = il_lp, il
        for i in range(2, 2 + harf):
            j = max(_HARF_I, key=lambda c: lp[i, c])
            s += lp[i, j]
            metin += ALFABE[j]
        for i in range(2 + harf, n):
            j = max(_RAKAM_I, key=lambda c: lp[i, c])
            s += lp[i, j]
            metin += ALFABE[j]
        s += lp[n:, _DOLGU_I].sum()
        if en_iyi is None or s > en_iyi[0]:
            en_iyi = (s, metin)
    metin = en_iyi[1]
    enk = min(float(p[i, ALFABE.index(c)]) for i, c in enumerate(metin))
    if len(metin) < SLOT:
        enk = min(enk, float(p[len(metin):, _DOLGU_I].min()))
    return metin, enk


def iki_kirpinti(o1: tuple[str, float], o2: tuple[str, float],
                 esik: float) -> tuple[str, float] | None:
    """Kural 2: iki kırpıntı aynı plakayı, ikisi de ≥ eşik verdiyse (metin, en düşük)."""
    if o1[0] == o2[0] and min(o1[1], o2[1]) >= esik:
        return o1[0], min(o1[1], o2[1])
    return None


# ------------------------------------------------------------------ oylama ----

class Emin(NamedTuple):
    metin: str
    zaman: object          # ilk okunduğu karenin yakalanma anı (datetime)
    guven: float
    birlesik: bool = False  # 1.4.1: çok karede birleştirmeyle emin (kayda yazılır)


# 1.4.1 çok karede birleştirme (Oylama.birlesik). Sektör: Rekor "plate groups",
# Axis "Update" olayları; kare oylaması makalesi %66.7 → %81.8 tam doğru.
YARIM_ESIK = 0.50          # iki kırpıntı AYNI metin, her biri en az bu: yarım oy
BIRLESIK_GORUNUM = 3       # yarım + tam oylar en az bu kadar FARKLI görünümden
BIRLESIK_TEPE = 0.90       # metnin en az bir kırpıntısı bu kadar net olmalı


class Belirsiz(NamedTuple):
    tahmin: str | None
    guven: float | None
    zaman: object


class Karar(NamedTuple):
    eminler: list
    belirsiz: Belirsiz | None
    kutulu_kare: int


class Oylama:
    """
    Bir geçişin (aynı aracın karelerinin) okumalarını toplar.

    `gorunum`: köprünün verdiği görünüm kimliği. Duran aracın birbirinin aynı
    kareleri AYNI görünümdür — aynı hatayı tekrarlamaları bağımsız oy değildir.
    """

    def __init__(self, k_oy: int = K_OY, oran: float = ORAN, tek_esik: float = 0.99,
                 m_kutu: int = M_KUTU, birlesik: bool = False):
        self.k_oy, self.oran, self.tek_esik, self.m_kutu = k_oy, oran, tek_esik, m_kutu
        self.birlesik = bool(birlesik)
        self._kutulu = 0
        self._ilk_kutu = None
        self._okumalar: dict[str, dict] = {}
        self._tahminler: dict[str, float] = {}
        self._tahmin_sayi: dict[str, int] = {}
        self._yarim: dict[str, dict] = {}      # 1.4.1: metin → {gorunum, tepe, zaman, sira}
        self._gorulen: set[str] = set()        # 1.4.1: izde okunan HER metin (iki kırpıntı)
        self._sira = 0

    def kutu(self, zaman, gorunum) -> None:
        """Bu karede en az bir plaka kutusu görüldü (tam ya da kesik)."""
        self._kutulu += 1
        if self._ilk_kutu is None:
            self._ilk_kutu = zaman

    def okuma(self, metin: str, enk: float, zaman, gorunum) -> None:
        """İki kırpıntının anlaştığı, eşiği geçen okuma (oy)."""
        o = self._okumalar.get(metin)
        if o is None:
            self._sira += 1
            o = self._okumalar[metin] = {"gorunum": set(), "enk": 0.0, "zaman": zaman, "sira": self._sira}
        o["gorunum"].add(gorunum)
        o["enk"] = max(o["enk"], enk)

    def tahmin(self, metin: str, enk: float) -> None:
        """Emin olunmayan okuma: oy değil, yalnızca personele tahmin."""
        self._tahminler[metin] = max(self._tahminler.get(metin, 0.0), enk)
        self._tahmin_sayi[metin] = self._tahmin_sayi.get(metin, 0) + 1

    def gorulen(self, metinler) -> None:
        """1.4.1: bu karede okunan metinler (iki kırpıntı da) — birleşik kararda rakip."""
        self._gorulen.update(m for m in metinler if m)

    def yarim_oy(self, metin: str, enk: float, tepe: float, zaman, gorunum) -> None:
        """
        1.4.1: iki kırpıntının AYNI metni verdiği ama eşiğin altında kalan kare
        (`enk` iki kırpıntının düşüğü, `tepe` yükseği). Tek başına hiçbir şey
        değildir; `birlesik` açıksa karar() bunları görünümlerle birleştirir.
        """
        y = self._yarim.get(metin)
        if y is None:
            self._sira += 1
            y = self._yarim[metin] = {"gorunum": set(), "tepe": 0.0, "zaman": zaman,
                                      "sira": self._sira}
        y["gorunum"].add(gorunum)
        y["tepe"] = max(y["tepe"], tepe)

    def _sira_al(self, metin: str) -> int:
        kayit = self._okumalar.get(metin) or self._yarim.get(metin)
        return kayit["sira"] if kayit else 0

    def _birlesik_eminler(self, emin_metinler: set[str]) -> list[Emin]:
        """KATI birleşik kural (bkz. YARIM_ESIK / BIRLESIK_*)."""
        rakipler = (self._gorulen | set(self._okumalar) | set(self._yarim)
                    | set(self._tahminler) | emin_metinler)
        cikti: list[Emin] = []
        for m in sorted(self._yarim, key=self._sira_al):
            if m in emin_metinler:
                continue
            tam = self._okumalar.get(m)
            gorunum = self._yarim[m]["gorunum"] | (tam["gorunum"] if tam else set())
            tepe = max(self._yarim[m]["tepe"], tam["enk"] if tam else 0.0)
            if len(gorunum) < BIRLESIK_GORUNUM or tepe < BIRLESIK_TEPE:
                continue
            if any(r != m and bir_fark(r, m) for r in rakipler):
                continue
            # Bağımsız inceleme (2026-11-09): izde BAŞKA bir plakanın oyu, yarım
            # oyu ya da ≥ YARIM_ESIK tahmini varsa iki araç karışmış olabilir
            # (sürüklenen iz, arkadaki aracın ön plakası) — birleştirme yok.
            if any(r != m for r in set(self._okumalar) | set(self._yarim)) or any(
                    r != m and g >= YARIM_ESIK for r, g in self._tahminler.items()):
                continue
            zaman = tam["zaman"] if tam and tam["sira"] < self._yarim[m]["sira"] \
                else self._yarim[m]["zaman"]
            cikti.append(Emin(m, zaman, tepe, True))
        return cikti

    def _kumeler(self) -> list[list[str]]:
        metinler = sorted(self._okumalar, key=lambda m: self._okumalar[m]["sira"])
        ata = {m: m for m in metinler}

        def kok(m: str) -> str:
            while ata[m] != m:
                ata[m] = ata[ata[m]]
                m = ata[m]
            return m

        for i, a in enumerate(metinler):
            for b in metinler[i + 1:]:
                if bir_fark(a, b):
                    ata[kok(b)] = kok(a)
        kumeler: dict[str, list[str]] = {}
        for m in metinler:
            kumeler.setdefault(kok(m), []).append(m)
        return list(kumeler.values())

    def karar(self) -> Karar:
        eminler: list[Emin] = []
        adaylar: list[tuple] = []                # emin olmayan kümeler: ((toplam, sıra, üst), küme)
        for kume in self._kumeler():
            ok = self._okumalar
            ust = max(kume, key=lambda m: (len(ok[m]["gorunum"]), -ok[m]["sira"]))
            ust_g = len(ok[ust]["gorunum"])
            toplam = sum(len(ok[m]["gorunum"]) for m in kume)
            emin = (ust_g >= self.k_oy and ust_g >= self.oran * toplam) or (
                len(kume) == 1 and ust_g == 1 and ok[ust]["enk"] >= self.tek_esik)
            if emin:
                eminler.append(Emin(ust, ok[ust]["zaman"], ok[ust]["enk"]))
            else:
                adaylar.append(((toplam, -ok[ust]["sira"], ust), set(kume)))
        if self.birlesik:
            # 1.4.1: olağan kuralla emin olmayan metin çok karede birleşerek
            # emin olabilir; o metnin kümesi artık "belirsiz" adayı değildir.
            birlesik = self._birlesik_eminler({e.metin for e in eminler})
            eminler += birlesik
            yeni = {e.metin for e in birlesik}
            adaylar = [a for a in adaylar if not (a[1] & yeni)]
        belirsiz_kume: tuple | None = max((a[0] for a in adaylar), default=None)
        eminler.sort(key=lambda e: self._sira_al(e.metin))

        belirsiz: Belirsiz | None = None
        if eminler:
            # İkinci, emin olunamayan bir araç (emin plakadan ≥2 karakter uzak).
            if belirsiz_kume is not None and belirsiz_kume[0] >= self.m_kutu:
                m = belirsiz_kume[2]
                belirsiz = Belirsiz(m, self._okumalar[m]["enk"], self._okumalar[m]["zaman"])
        elif self._kutulu >= self.m_kutu:
            if belirsiz_kume is not None:
                m = belirsiz_kume[2]
                belirsiz = Belirsiz(m, self._okumalar[m]["enk"], self._ilk_kutu)
            elif self._tahminler:
                m = max(self._tahminler, key=lambda t: (self._tahmin_sayi[t], self._tahminler[t]))
                belirsiz = Belirsiz(m, self._tahminler[m], self._ilk_kutu)
            else:
                belirsiz = Belirsiz(None, None, self._ilk_kutu)
        return Karar(eminler, belirsiz, self._kutulu)


# ------------------------------------------------------------------ modeller ---

def sha256_dosya(yol: str) -> str:
    h = hashlib.sha256()
    with open(yol, "rb") as f:
        for parca in iter(lambda: f.read(1 << 20), b""):
            h.update(parca)
    return h.hexdigest()


def sabit_okuyucu_girdisi() -> np.ndarray:
    """
    Öz sınama ve altın test için SABİT girdi: kodla çizilmiş, kenar
    yumuşatmasız (LINE_8 — sürümden sürüme aynı pikseller) bir plaka.
    Çizim bilerek seçildi: okuyucu bu yazı tipinde "34ABC123"ü üç Hershey
    yazı tipinde de doğru okuyor (bazı çizimler, ör. DUPLEX "35 PA 052",
    "35PA051" diye okunuyordu — kodla çizilen "2" ona belirsiz). Gerçek
    plakadaki doğruluğu bu girdi ÖLÇMEZ (Faz 0 ölçtü); yalnızca model ve ön
    işlem değişmedi mi, ona bakar.
    """
    gen, yuk = 300, 66
    p = np.full((yuk, gen, 3), 245, np.uint8)
    cv2.rectangle(p, (0, 0), (gen - 1, yuk - 1), (20, 20, 20), 3)
    cv2.rectangle(p, (3, 3), (24, yuk - 4), (160, 60, 0), -1)
    cv2.putText(p, "34 ABC 123", (34, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (15, 15, 15), 3, cv2.LINE_8)
    p = cv2.cvtColor(p, cv2.COLOR_BGR2RGB)
    return cv2.resize(p, (OKUYUCU_EN, OKUYUCU_BOY), interpolation=cv2.INTER_LINEAR)


# Altın değer: sabit_okuyucu_girdisi() → okuyucu. Upstream fast-plate-ocr 1.1.0
# (LicensePlateRecognizer) aynı girdide aynı metni ve olasılığı verdi.
ALTIN_METIN = "34ABC123"
ALTIN_ENK = 0.99969       # 2026-11-06, onnxruntime 1.31.0, upstream ile fark 0.0
ALTIN_PAYI = 0.05         # sahada başka bir işlemci (AVX2/AVX512) küçük fark verebilir


class Plakaci:
    """Yüklenmiş iki model. Yalnızca `yukle()` oluşturur."""

    def __init__(self, bulucu, okuyucu, ayar: dict):
        self._bulucu = bulucu
        self._okuyucu = okuyucu
        self.ayar = ayar
        self._bulucu_girdi = bulucu.get_inputs()[0].name

    def bul(self, img: np.ndarray) -> list[Kutu]:
        """Kırpıntıdaki plaka kutuları (skor ≥ PLAKA_BUL_ESIK), skora göre."""
        x, r, dw, dh = letterbox(img, BULUCU_BOYUT)
        cikti = self._bulucu.run(None, {self._bulucu_girdi: x})[0]
        h, w = img.shape[:2]
        return kutulari_coz(cikti, r, dw, dh, self.ayar["bul_esik"], w, h)

    def ham_oku(self, girdi: np.ndarray) -> np.ndarray:
        """(N, 64, 128, 3) uint8 RGB → (N, 10, 37) olasılık."""
        return self._okuyucu.run(["plate"], {"input": np.ascontiguousarray(girdi, dtype=np.uint8)})[0]

    def oku_cift(self, img: np.ndarray, k: Kutu) -> list[tuple[str, float]]:
        """Kural 2: dar ve genişletilmiş kırpıntı, TEK çağrıda. Kutu boşsa []."""
        h, w = img.shape[:2]
        g1 = okuyucu_girdisi(img, k)
        g2 = okuyucu_girdisi(img, genislet(k, PAY_X, PAY_Y, w, h))
        if g1 is None or g2 is None:
            return []
        p = self.ham_oku(np.stack([g1, g2]))
        return [kisitli_coz(p[0]), kisitli_coz(p[1])]

    def oz_sinama(self) -> None:
        """Model dosyası doğru ama ÇALIŞIYOR mu? Değilse PlakaHatasi."""
        bos = np.full((668, 1568, 3), 110, np.uint8)
        if self.bul(bos):
            raise PlakaHatasi("öz sınama başarısız: boş sahnede plaka bulundu")
        p = self.ham_oku(sabit_okuyucu_girdisi()[None])
        if p.shape != (1, SLOT, len(ALFABE)) or not np.allclose(p.sum(axis=-1), 1.0, atol=1e-3):
            raise PlakaHatasi(f"öz sınama başarısız: okuyucu çıktısı beklenmedik ({p.shape})")
        metin, enk = kisitli_coz(p[0])
        if metin != ALTIN_METIN or (ALTIN_ENK is not None and abs(enk - ALTIN_ENK) > ALTIN_PAYI):
            raise PlakaHatasi(f"öz sınama başarısız: sabit plaka {metin} ({enk:.3f}) okundu")


def _ort_yukle():
    """
    onnxruntime'ı TELEMETRİSİ KAPALI açar — köprüde onu içe aktaran TEK yer.

    Resmî paket telemetriyi varsayılan AÇIK gönderir (Microsoft'a, HTTPS;
    paketin Privacy.md'si). Otoparkın bilgisayarı kimseye veri göndermemeli.
    ORT_DISABLE_TELEMETRY=1 ancak onnxruntime İLK kez yüklenmeden önce
    kurulursa işe yarar ve ortam ne derse desin zorla kurulur; API'nin
    kapatması da ayrıca çağrılır (yalnızca "zorunlu olmayan" olayları keser).
    """
    os.environ["ORT_DISABLE_TELEMETRY"] = "1"
    import onnxruntime as ort
    kapat = getattr(ort, "disable_telemetry_events", None)
    if callable(kapat):
        try:
            kapat()
        except Exception:  # noqa: BLE001 — telemetri API'si okumayı durduramaz
            pass
    return ort


def oturum_ayarlari(ort, iplik: int):
    """Köprünün iki modülünün (plaka, araç) ortak onnxruntime oturum ayarları."""
    so = ort.SessionOptions()
    so.intra_op_num_threads = int(iplik)
    so.inter_op_num_threads = 1
    so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    so.log_severity_level = 3
    # Boşta dönen iş parçacığı bir çekirdeği yakar; köprü 7/24 çalışıyor.
    so.add_session_config_entry("session.intra_op.allow_spinning", "0")
    return so


def yukle(ayar: dict, dizin: str | None = None) -> Plakaci:
    """
    İki modeli doğrular, açar ve sınar. Her hata PlakaHatasi (Türkçe sebep);
    köprü bunu yakalar, kayda yazar ve plaka okuyucusuz (araçlar personele)
    çalışmaya devam eder — asla düşmez.
    """
    d = dizin or MODEL_DIZINI
    for m in (BULUCU, OKUYUCU):
        yol = os.path.join(d, m.dosya)
        if not os.path.isfile(yol):
            raise PlakaHatasi(f"model dosyası bulunamadı: {m.dosya}")
        if sha256_dosya(yol) != m.sha256:
            raise PlakaHatasi(f"model doğrulanamadı (özet uyuşmuyor): {m.dosya}")
    try:
        ort = _ort_yukle()
    except ImportError as e:
        raise PlakaHatasi(f"onnxruntime yüklenemedi: {e}") from None
    try:
        so = oturum_ayarlari(ort, ayar["iplik"])
        saglayici = ["CPUExecutionProvider"]
        bulucu = ort.InferenceSession(os.path.join(d, BULUCU.dosya), so, providers=saglayici)
        okuyucu = ort.InferenceSession(os.path.join(d, OKUYUCU.dosya), so, providers=saglayici)
    except Exception as e:  # noqa: BLE001
        raise PlakaHatasi(f"model açılamadı: {type(e).__name__}: {e}") from None
    p = Plakaci(bulucu, okuyucu, ayar)
    try:
        p.oz_sinama()
    except PlakaHatasi:
        raise
    except Exception as e:  # noqa: BLE001
        raise PlakaHatasi(f"öz sınama çalışmadı: {type(e).__name__}: {e}") from None
    return p
