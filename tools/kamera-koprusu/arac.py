# -*- coding: utf-8 -*-
"""
Araç bulucu (köprü 1.3.1): kırpıntıda bir ARAÇ var mı?

Neden: 1.3.0'ın ilk günü (2026-11-07) kameranın önünde duran iki kişi
"Çözülmemiş kayıt" oldu. 1.3.0'ın tek modeli PLAKA bulur; "bu bir araç mı"
sorusunu hareketin büyüklüğü cevaplıyordu ve yakında duran insan araç
kadar büyük. 1.3.1 her karede bu modeli de çalıştırır; karar (okuma.py)
plakası görülmeyen geçişi ancak araç görüldüyse personele bırakır.

Model: YOLOX-tiny (Megvii, Apache-2.0), resmî 0.1.1rc0 ONNX dosyası, COCO'nun
80 sınıfı. Faz 0 (2026-11-07, otoparkın 180 gerçek kamera fotoğrafı):
gerçek araçlar 0.40-0.94, insanlar en çok 0.27; YOLOX-nano yakından ve
yukarıdan görülen araçları kaçırdı (0.01-0.12), reddedildi. Bu bilgisayarda
kare başına ~55 ms (plaka bulucu ~84 ms). Sahibin kararı: atlama yok, HER
kare.

Girdi BİÇİMİ Faz 0'da ölçülerek seçildi: BGR, 0-255, normalizesiz, sol üste
yerleştirilmiş, 114 dolgu (güncel YOLOX). Eski "legacy" biçim (RGB + ImageNet
ortalama/sapma) aynı dosyada HİÇ araç bulmuyordu — hata vermeden. Öz sınama
(gerçek bir resimde aracı bulmalı) ve test_arac bu seçimi kilitler.

1.4.2: ikinci model YOLO11s (Ultralytics, AGPL-3.0 — sahibin kararı
2026-11-12: köprü yalnızca kendi otoparkımızda; satılırsa YOLOX-s). Girdisi
ve çıktısı farklı; her model kendi `Profil`ini taşır (aşağıda). Lisans:
modeller/LISANS.txt 5).

onnxruntime burada içe aktarılmaz: telemetrisi kapalı tek yol plaka._ort_yukle.
"""
from __future__ import annotations

import os
from typing import Callable, NamedTuple

import cv2
import numpy as np

import gunluk
import plaka


class AracKutu(NamedTuple):
    """Kırpıntı pikselinde bir araç kutusu ve puanı (1.3.2)."""
    x1: float
    y1: float
    x2: float
    y2: float
    skor: float
    # 1.4.3 (2026-11-20): puanı veren araç sınıfı (COCO numarası: 2/3/5/7);
    # -1 = bilinmiyor (eski 5 alanlı kurulumlar, tahmin edilen kutular).
    sinif: int = -1

MODEL = plaka.ModelDosyasi(
    "yolox_tiny.onnx",
    "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7",
    "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_tiny.onnx",
)
# Öz sınama resmi: YOLOX deposunun kendi assets/dog.jpg'si (Apache-2.0),
# 416×312'ye küçültülmüş. İçinde bir araç (sağ üstte), bir bisiklet, bir köpek.
SINAMA = plaka.ModelDosyasi(
    "arac_sinama.jpg",
    "0c32b6e8364fcd8e32385faecea52c1eaa90483d1aa40849d1be36b9cb07b956",
    "https://github.com/Megvii-BaseDetection/YOLOX/blob/main/assets/dog.jpg",
)

GIRDI = 416
ADIMLAR = (8, 16, 32)
DOLGU = 114
# COCO: 2 otomobil, 3 motosiklet, 5 otobüs, 7 kamyon. 0 insan (yalnızca kayıt için).
ARAC_SINIFLARI = (2, 3, 5, 7)
INSAN = 0
# 1.4.3 (2026-11-20): kayıt satırında ve motosiklet eşiğinde (Profil.moto_esik).
MOTOSIKLET = 3
SINIF_ADLARI = {2: "otomobil", 3: "motosiklet", 5: "otobüs", 7: "kamyon"}
# Kutusunun yarısından fazlası kesilen köşede (park etmiş araçlar) kalan aday
# sayılmaz. Plakadan (%20) gevşek: araç büyük, kesilen köşenin yanından geçen
# bir aracın kutusu oraya biraz taşabilir.
HARIC_DUSUR = 0.50

# Altın değer: SINAMA resmindeki en yüksek araç puanı (2026-11-07, onnxruntime
# 1.31.0). Ön işlem ya da model değişirse kayar.
ALTIN_ARAC = 0.80782
ALTIN_PAYI = 0.05         # sahada başka bir işlemci (AVX2/AVX512) küçük fark verebilir
# Boş sahnede bundan yüksek araç puanı = model bozuk.
BOS_SINIR = 0.10
# 1.3.2: kutu listesine girecek en düşük araç puanı. Bilerek düşük: geçişten
# önceki karedeki (park etmiş) araç zayıf görülse de listede olsun ki sonra
# "yeni araç" sanılmasın. Kararın eşikleri (0.35 / 0.60) ayrıca uygulanır.
KUTU_ALT = 0.10
NMS_ORTUSME = 0.45


# ------------------------------------------------------------- ön işlem ---

def on_isle(img: np.ndarray, n: int = GIRDI) -> tuple[np.ndarray, float]:
    """BGR kırpıntı → (1, 3, n, n) float32 (BGR, 0-255), ölçek r."""
    h, w = img.shape[:2]
    r = min(n / h, n / w)
    yeni = cv2.resize(img, (int(w * r), int(h * r)), interpolation=cv2.INTER_LINEAR)
    tuval = np.full((n, n, 3), DOLGU, np.uint8)
    tuval[: yeni.shape[0], : yeni.shape[1]] = yeni
    return np.ascontiguousarray(tuval.transpose(2, 0, 1)[None], dtype=np.float32), r


def _izgara(n: int) -> tuple[np.ndarray, np.ndarray]:
    noktalar, adimlar = [], []
    for adim in ADIMLAR:
        k = n // adim
        xv, yv = np.meshgrid(np.arange(k), np.arange(k))
        noktalar.append(np.stack((xv, yv), 2).reshape(-1, 2))
        adimlar.append(np.full((k * k, 1), adim))
    return (np.concatenate(noktalar).astype(np.float32),
            np.concatenate(adimlar).astype(np.float32))


_IZGARA, _ADIM = _izgara(GIRDI)


def coz(ham: np.ndarray, r: float, en: int, boy: int):
    """
    Ham çıktı [1, 3549, 85] → (kutular (N, 4) kırpıntı pikselinde x1 y1 x2 y2,
    araç puanı (N,), insan puanı (N,)). Puan = nesne × sınıf olasılığı.
    """
    p = np.asarray(ham, dtype=np.float32).reshape(-1, 85)
    if p.shape[0] != _IZGARA.shape[0]:
        raise ValueError(f"beklenmedik çıktı: {np.shape(ham)}")
    merkez = (p[:, :2] + _IZGARA) * _ADIM
    boyut = np.exp(np.clip(p[:, 2:4], -20.0, 20.0)) * _ADIM
    kutular = np.concatenate([merkez - boyut / 2, merkez + boyut / 2], axis=1) / r
    kutular[:, 0::2] = np.clip(kutular[:, 0::2], 0, en)
    kutular[:, 1::2] = np.clip(kutular[:, 1::2], 0, boy)
    nesne = p[:, 4]
    arac = nesne * p[:, [5 + s for s in ARAC_SINIFLARI]].max(axis=1)
    insan = nesne * p[:, 5 + INSAN]
    return kutular, arac, insan


_SINIF_DIZI = np.array(ARAC_SINIFLARI)


def sinif(ham: np.ndarray) -> np.ndarray:
    """1.4.3: YOLOX satırlarının araç sınıfı (puanı veren; `coz` sırasıyla)."""
    p = np.asarray(ham, dtype=np.float32).reshape(-1, 85)
    return _SINIF_DIZI[p[:, [5 + s for s in ARAC_SINIFLARI]].argmax(axis=1)]


# ------------------------------------------------------ YOLO11 (1.4.2) ---
# Ultralytics YOLO11 dışa aktarımı: girdi ORTALANMIŞ letterbox, RGB, /255
# (plaka bulucunun letterbox'ı birebir aynı — tek kod yolu); çıktı [1, 84, N]:
# satır 0-3 GİRDİ pikselinde (cx, cy, w, h), 4-83 sınıf olasılıkları. Nesne
# puanı YOK. YOLOX ön işlemiyle beslenirse hata vermeden zayıf görür.

def on_isle11(img: np.ndarray, n: int = GIRDI) -> tuple[np.ndarray, tuple[float, float, float]]:
    """BGR kırpıntı → ((1, 3, n, n) float32 RGB 0-1, (r, dw, dh))."""
    x, r, dw, dh = plaka.letterbox(img, n)
    return x, (r, dw, dh)


def coz11(ham: np.ndarray, donus: tuple[float, float, float], en: int, boy: int):
    """
    Ham çıktı [1, 84, N] → (kutular (N, 4) kırpıntı pikselinde x1 y1 x2 y2,
    araç puanı (N,), insan puanı (N,)). Puan = sınıf olasılığı.
    """
    p = np.asarray(ham, dtype=np.float32)
    if p.ndim != 3 or p.shape[:2] != (1, 84):
        raise ValueError(f"beklenmedik çıktı: {np.shape(ham)}")
    p = p[0].T
    r, dw, dh = donus
    merkez, yari = p[:, :2], p[:, 2:4] / 2
    kutular = np.concatenate([merkez - yari, merkez + yari], axis=1)
    kutular -= np.array([dw, dh, dw, dh], dtype=np.float32)
    kutular /= r
    kutular[:, 0::2] = np.clip(kutular[:, 0::2], 0, en)
    kutular[:, 1::2] = np.clip(kutular[:, 1::2], 0, boy)
    arac = p[:, [4 + s for s in ARAC_SINIFLARI]].max(axis=1)
    insan = p[:, 4 + INSAN]
    return kutular, arac, insan


def sinif11(ham: np.ndarray) -> np.ndarray:
    """1.4.3: YOLO11 satırlarının araç sınıfı (puanı veren; `coz11` sırasıyla)."""
    p = np.asarray(ham, dtype=np.float32)[0].T
    return _SINIF_DIZI[p[:, [4 + s for s in ARAC_SINIFLARI]].argmax(axis=1)]


def _haric_orani(kutular: np.ndarray, haric) -> np.ndarray:
    """
    plaka.haric_orani'nin vektör hâli: kutunun kesilen köşelerin BİRLEŞİMİNDE
    kalan oranı (1.3.3: en çok 3 alan; üst üste binenler iki kez sayılmaz).
    """
    kesilen = np.zeros(len(kutular), dtype=np.float64)
    for isaret, (a1, b1, a2, b2) in plaka.kesisim_parcalari(haric):
        ix = np.clip(np.minimum(kutular[:, 2], a2) - np.maximum(kutular[:, 0], a1), 0, None)
        iy = np.clip(np.minimum(kutular[:, 3], b2) - np.maximum(kutular[:, 1], b1), 0, None)
        kesilen += isaret * ix * iy
    alan = (kutular[:, 2] - kutular[:, 0]) * (kutular[:, 3] - kutular[:, 1])
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(alan > 0, kesilen / alan, 0.0)


def _tutulan(kutular: np.ndarray, haric) -> np.ndarray | None:
    """Kesilen köşelerde kalmayan adayların maskesi; None = hepsi kalır."""
    if isinstance(haric, plaka.AlanMaskesi):
        # 1.4.0: kırpma ALANI (çokgen) — "kesilen köşe" yerine alanın dışı.
        return haric.oranlar(kutular) <= HARIC_DUSUR
    if not plaka.haric_listesi(haric):
        return None
    return _haric_orani(kutular, haric) <= HARIC_DUSUR


def _haricsiz(kutular: np.ndarray, arac: np.ndarray, insan: np.ndarray, haric):
    """Kutusunun yarısından fazlası kesilen köşelerde kalan adayları atar."""
    tut = _tutulan(kutular, haric)
    if tut is None:
        return kutular, arac, insan
    return kutular[tut], arac[tut], insan[tut]


def skorla(ham: np.ndarray, r, en: int, boy: int, haric,
           profil: "Profil | None" = None) -> tuple[float, float]:
    """
    (en yüksek araç puanı, en yüksek insan puanı); kesilen köşedekiler hariç.
    `r`: profilin ön işleminin döndürdüğü dönüş bilgisi (YOLOX: ölçek).
    """
    kutular, arac, insan = _haricsiz(*(profil or YOLOX_TINY).coz(ham, r, en, boy), haric)
    a = float(arac.max()) if arac.size else 0.0
    i = float(insan.max()) if insan.size else 0.0
    return max(a, 0.0), max(i, 0.0)


def ortusme(a, b) -> float:
    """İki kutunun kesişim / birleşim oranı (IoU), 0..1."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    kesisim = ix * iy
    birlesim = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - kesisim
    return kesisim / birlesim if birlesim > 0 and kesisim > 0 else 0.0


def kutulari_coz(ham: np.ndarray, r, en: int, boy: int, haric,
                 alt: float = KUTU_ALT,
                 profil: "Profil | None" = None) -> tuple[list[AracKutu], float]:
    """
    (araç kutuları — puanı ≥ alt, aynı aracın kopyaları birleşmiş (NMS),
    puana göre azalan; en yüksek insan puanı). Kesilen köşedekiler hariç.
    """
    p = profil or YOLOX_TINY
    kutular, arac, insan = p.coz(ham, r, en, boy)
    siniflar = p.sinif(ham)                  # 1.4.3: aynı satır sırası, aynı süzgeç
    tut = _tutulan(kutular, haric)
    if tut is not None:
        kutular, arac, insan, siniflar = kutular[tut], arac[tut], insan[tut], siniflar[tut]
    i = float(insan.max()) if insan.size else 0.0
    sec = np.nonzero(arac >= alt)[0]
    if sec.size == 0:
        return [], max(i, 0.0)
    xywh = [[float(k[0]), float(k[1]), float(k[2] - k[0]), float(k[3] - k[1])] for k in kutular[sec]]
    kalan = np.array(cv2.dnn.NMSBoxes(xywh, [float(x) for x in arac[sec]], alt, NMS_ORTUSME)).reshape(-1)
    sonuc = [AracKutu(*(float(v) for v in kutular[sec[j]]), float(arac[sec[j]]),
                      int(siniflar[sec[j]])) for j in kalan]
    return sorted(sonuc, key=lambda k: -k.skor), max(i, 0.0)


# ---------------------------------------------------------------- profiller ---

class Profil(NamedTuple):
    """
    1.4.2: bir araç modeli ve ona ait her şey. Puan ölçeği modele göre değişir
    (YOLO11'inki YOLOX'tan düşük), bu yüzden eşikler ve altın değer de burada.
    """
    ad: str
    model: plaka.ModelDosyasi
    girdi: int
    hazirla: Callable    # BGR kırpıntı → (girdi, dönüş bilgisi)
    coz: Callable        # (ham, dönüş bilgisi, en, boy) → (kutular, araç, insan)
    altin: float         # SINAMA resmindeki en yüksek araç puanı (onnxruntime 1.31.0)
    esik: float          # duran / kapıdan geçen araç (ARAC_BUL_ESIK'in karşılığı)
    gecis_esik: float    # plakasız geçiş personele (ARAC_GECIS_ESIK'in karşılığı)
    esik_anahtari: str   # calisma_ayarlari'nda üstüne yazan anahtar
    gecis_anahtari: str
    yer_tutucu: bool     # True: eşikler ölçülmedi, sahada açılmaz
    sinif: Callable = sinif          # 1.4.3: ham → satır başına araç sınıfı
    # 1.4.3 (sahibin kararı 20.11): yönü bilinmeyen plakasız kapı olayı
    # (TEK_KARE / KAPIDA_KAYBOLDU) puanını MOTOSİKLETTEN alıyorsa bu eşiği
    # ister. None = kural yok. Neden: 19.11'de el arabası iten kişi 5 kart
    # oldu (0.37-0.52); sahibinin skuter fotoğrafları 0.77-0.92.
    moto_esik: float | None = None
    moto_anahtari: str | None = None


YOLOX_TINY = Profil("YOLOX-tiny", MODEL, GIRDI, on_isle, coz, ALTIN_ARAC, 0.35, 0.60,
                    "arac_esik", "arac_gecis_esik", False)

# YOLO11s (Ultralytics, AGPL-3.0). Sahibin kararı (2026-11-12): köprü yalnızca
# kendi otoparkımızda çalışır; satılırsa YOLOX-s'e dönülür. Resmî yolo11s.pt
# (assets v8.3.0), ultralytics 8.4.210 ile 640'ta ONNX'e aktarıldı.
#
# Neden 640 (2026-11-13, sahibin kararı): uygulamadaki 25 gece kanıt
# fotoğrafı (11.11 20:00'den sonra, hepsi gerçek araç; sahibi baktı) yedi
# modelle puanlandı. 416'da uzaktaki ya da kırpma kenarıyla kesilen araçları
# her model kaçırıyor (YOLO11s 416: 21/25, tiny: 20/25 ≥ 0.30); YOLO11s 640
# hepsini gördü (en düşük 0.34 — kameranın dibindeki büyük koyu araç).
# Bedeli: sahadaki GPU'da ~85 ms (416'da 37), köprü ~6-7 kare/sn.
#
# Eşikler 0.30 / 0.60: 0.30 yirmi beşinin hepsini tutar; 0.60 bugünkünün
# aynısı (640'ta 22/25 üstünde, tiny'de 12/25).
#
# Yanlış alarm (2026-11-13, aynı gün ölçüldü): 25 gece fotoğrafında araçlar
# köprünün maske grisiyle (114) örtülüp kalan şerit (far yansıması, iz,
# gölge) puanlandı → en yüksek 0.00. 48 kişili fotoğrafta YOLO11s'in her
# araç puanı gerçek bir araçtandı; kişiye araç kutusu yok. 3 el arabası
# (fıçı / kasa): YOLO11s 0.00-0.01, tiny 0.53 / 0.78 / 0.66 (tiny yanlış
# alarm veriyordu). → ölçülmüş, "otomatik"in seçtiği model (sahibin kararı).
#
# Sahada 19.11 (1.4.2, canlı): el arabası İTEN kişi 5 "Çözülmemiş kayıt"
# oldu — hepsi tek kare / kapıda kayboldu, 1-5 görünüm, plakasız, 0.37-0.52
# (fotoğraflardaki 0.00-0.01'den farklı: canlı karede kişi + araba birlikte).
# 17:38 kartının fotoğrafı motosiklet 0.50, otomobil 0.01. → 1.4.3 moto_esik
# (sahibin kararı 20.11): o olaylarda motosiklet sınıfı 0.60 ister.
GIRDI11 = 640


def on_isle11_640(img: np.ndarray):
    return on_isle11(img, GIRDI11)


YOLO11S = Profil(
    "YOLO11s",
    plaka.ModelDosyasi(
        "yolo11s_640.onnx",
        "5c56db2f3bc7baaf650ad3e55e4ec4ecda1d245f83d8968e731ad806bebc3161",
        "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11s.pt",
    ),
    # Altın 0.49103: 2026-11-13, onnxruntime 1.31.0 CPU (kutu sağ üstte). Sınama
    # resmi 416 × 312 — 640'a büyütülünce puan düşük, öz sınama yalnızca
    # kaymayı arar. GPU (f16) 0.496.
    GIRDI11, on_isle11_640, coz11, 0.49103, 0.30, 0.60,
    "arac11_esik", "arac11_gecis_esik", False,
    sinif=sinif11, moto_esik=0.60, moto_anahtari="arac11_moto_esik")


# ------------------------------------------------------------------ bulucu ---

def resim_oku(yol: str):
    """
    1.4.2: Türkçe harfli klasörde de okur. cv2.imread Windows'ta ASCII dışı
    yolu açamaz ve sessizce None döner (hız aracı 1.0 sahada böyle açılmadı).
    """
    try:
        veri = np.fromfile(yol, np.uint8)
    except OSError:
        return None
    return cv2.imdecode(veri, cv2.IMREAD_COLOR) if veri.size else None


class AracBulucu:
    """Yüklenmiş model. Köprüde yalnızca `yukle()` oluşturur."""

    def __init__(self, oturum, ayar: dict, dizin: str, profil: Profil | None = None,
                 yedek: Callable | None = None):
        self._ayar = ayar
        self._dizin = dizin
        # 1.4.2: grafik işlemcisi çalışırken bozulursa (plaka.GPU_DENEME
        # denemede) yedek() → (işlemci oturumu, YOLOX_TINY): bulucu geçer,
        # eşikleri de değişir. yedek None = işlemci kümesi (hata işçiye gider).
        self._yedek = yedek
        self._cpu = None                  # açılmış işlemci yedeği (bir kez açılır)
        self._yeni = None                 # GpuGeriDonus'un yayımladığı (oturum, profil)
        self.islemcide = False
        self._ac(oturum, profil or YOLOX_TINY)

    def _ac(self, oturum, profil: Profil) -> None:
        self.profil = profil
        self._oturum = oturum
        self._girdi = oturum.get_inputs()[0].name
        self.esik = self._esik(profil.esik_anahtari, profil.esik)
        self.gecis_esik = self._esik(profil.gecis_anahtari, profil.gecis_esik)
        self.moto_esik = (None if profil.moto_esik is None
                          else self._esik(profil.moto_anahtari, profil.moto_esik))

    def _esik(self, anahtar: str, varsayilan: float) -> float:
        v = self._ayar.get(anahtar)
        return float(varsayilan if v is None else v)

    def _yedege_gec(self, hata: Exception) -> None:
        if self._cpu is None:
            self._cpu = self._yedek()
        self._ac(*self._cpu)
        self.islemcide = True
        plaka.GPU_BIRAKILANLAR.append("araç bulucu")
        print(f"[!] {gunluk.GPU_BIRAKILDI_ISARETI}: araç bulucu ({hata}) — "
              f"{plaka.GPU_DENEME} denemede olmadı, işlemcide {self.profil.ad} ile sürüyor "
              f"(duran ≥{self.esik:.2f}, geçen ≥{self.gecis_esik:.2f})", flush=True)

    @property
    def gpu_da(self) -> bool:
        """Grafik işlemcisinde mi (ya da yayımlanmış GPU oturumunu bekliyor mu)?"""
        return self._yeni is not None or (self._yedek is not None and not self.islemcide)

    def gpu_ver(self, oturum, profil: Profil) -> None:
        """
        1.4.2: öz sınamadan geçmiş yeni GPU oturumu (GpuGeriDonus, kendi iş
        parçacığından). Bulucu onu bir sonraki karenin başında, KENDİ iş
        parçacığında devralır: profil, ön işlem ve eşikler birlikte değişir.
        """
        self._yeni = (oturum, profil)

    def _uygula(self) -> None:
        yeni = self._yeni
        if yeni is None:
            return
        self._yeni = None
        if self._yedek is None:           # işlemci kümesiyle başladı: o oturum yedek olur
            mevcut = (self._oturum, self.profil)
            self._yedek = lambda: mevcut
        self._ac(*yeni)
        self.islemcide = False

    def _ham(self, kirpik: np.ndarray):
        self._uygula()
        x, donus = self.profil.hazirla(kirpik)
        if self._yedek is None or self.islemcide:
            return self._oturum.run(None, {self._girdi: x})[0], donus
        son = None
        for _ in range(plaka.GPU_DENEME):
            try:
                return self._oturum.run(None, {self._girdi: x})[0], donus
            except plaka.HizlandiriciHatasi as e:
                son = e
        self._yedege_gec(son)
        return self._ham(kirpik)                # AYNI kare işlemcide: kaybolmaz

    def skor(self, kirpik: np.ndarray, haric) -> tuple[float, float]:
        """Kırpıntıdaki (araç, insan) puanı, 0..1 (`--plaka` ve öz sınama)."""
        ham, r = self._ham(kirpik)
        h, w = kirpik.shape[:2]
        return skorla(ham, r, w, h, haric, profil=self.profil)

    def kutular(self, kirpik: np.ndarray, haric) -> tuple[list[AracKutu], float]:
        """1.3.2: (araç kutuları, insan puanı) — köprü "araç NEREDE" diye bakar."""
        ham, r = self._ham(kirpik)
        h, w = kirpik.shape[:2]
        return kutulari_coz(ham, r, w, h, haric, profil=self.profil)

    def oz_sinama(self) -> None:
        """Dosya doğru ama ÇALIŞIYOR mu? Değilse PlakaHatasi."""
        a, _ = self.skor(np.full((668, 1568, 3), 110, np.uint8), None)
        if a >= BOS_SINIR:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: boş sahnede araç bulundu ({a:.2f})")
        img = resim_oku(os.path.join(self._dizin, SINAMA.dosya))
        if img is None:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: {SINAMA.dosya} okunamadı")
        a, _ = self.skor(img, None)
        if abs(a - self.profil.altin) > ALTIN_PAYI:
            raise plaka.PlakaHatasi(f"öz sınama başarısız: sınama resminde araç puanı {a:.3f}")


def _dogrula(d: str, *dosyalar: plaka.ModelDosyasi) -> None:
    for m in dosyalar:
        yol = os.path.join(d, m.dosya)
        if not os.path.isfile(yol):
            raise plaka.PlakaHatasi(f"araç bulucu dosyası bulunamadı: {m.dosya}")
        if plaka.sha256_dosya(yol) != m.sha256:
            raise plaka.PlakaHatasi(f"araç bulucu dosyası doğrulanamadı (özet uyuşmuyor): {m.dosya}")


def yukle(ayar: dict, dizin: str | None = None, profil: Profil | None = None,
          hiz=None) -> AracBulucu:
    """
    Modeli ve sınama resmini doğrular, açar ve sınar. Her hata PlakaHatasi
    (Türkçe sebep); köprü onu kayda yazar ve araç bulucusuz (1.3.0 kuralıyla)
    çalışmaya devam eder — asla düşmez. `profil` yoksa YOLOX-tiny (1.4.1).

    `hiz` (1.4.2): model grafik işlemcisinde (f16) açılır; çalışırken
    bozulursa bulucu işlemcideki YOLOX-tiny'ye geçer (yedek) — YOLO11s'in
    işlemcide 123 ms'si bugünkünden yavaş olurdu.
    """
    p = profil or YOLOX_TINY
    d = dizin or plaka.MODEL_DIZINI
    for m in (p.model, SINAMA):
        _dogrula(d, m)
    if hiz is None:
        try:
            plaka._ort_yukle()
        except ImportError as e:
            raise plaka.PlakaHatasi(f"onnxruntime yüklenemedi: {e}") from None
    yedek = None
    try:
        if hiz is None:
            oturum = plaka.ort_oturumu(os.path.join(d, p.model.dosya), ayar["iplik"])
        else:
            oturum = hiz.oturum(os.path.join(d, p.model.dosya))

            def yedek():
                _dogrula(d, MODEL)
                return plaka.ort_oturumu(os.path.join(d, MODEL.dosya), ayar["iplik"]), YOLOX_TINY
    except Exception as e:  # noqa: BLE001
        raise plaka.PlakaHatasi(f"araç modeli açılamadı: {type(e).__name__}: {e}") from None
    # Öz sınama YEDEKSİZ: grafik işlemcisinde bozuksa sınama işlemcide geçip
    # "GPU" denmesin (2026-11-13); yedek ancak sınama geçince takılır.
    b = AracBulucu(oturum, ayar, d, profil=p)
    try:
        b.oz_sinama()
    except plaka.PlakaHatasi:
        raise
    except Exception as e:  # noqa: BLE001
        raise plaka.PlakaHatasi(f"araç bulucu öz sınaması çalışmadı: {type(e).__name__}: {e}") from None
    b._yedek = yedek
    return b
