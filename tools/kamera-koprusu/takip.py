# -*- coding: utf-8 -*-
"""
Araç izleme (köprü 1.4.0): her aracı kareler boyunca izler, araç başına BİR
kez karar verir.

Neden: 1.3.x kararı "geçiş" başına veriyordu — kırpıntıda herhangi bir
hareket bir geçiş açıyordu. Sahada (2026-11-08 öğle) 75 dakikada 13 plaka
gönderildi ama 17 "Çözülmemiş kayıt" açıldı (13 saniyede 4): otopark içinde
dur-kalk eden, park eden araçların her kıpırtısı yeni bir geçişti. Personelin
park etmiş bir aracı kaydırması ise o aracın biletini "çıkış" diye
kapatabiliyordu.

Nasıl: araç bulucunun (YOLOX) kutuları kareden kareye eşleştirilir (iz);
plaka kutusu içinde durduğu araca yazılır; her izin kendi oylaması vardır
(okuma.Gecis). KAPI ALANI çizilmişse:
  · GİRDİ  — iz kapı alanında DOĞDU (dışarıdan geldi) ve otoparka geçti;
             karar araç durunca / kaybolunca / en geç 30 sn sonra.
  · ÇIKTI  — iz otoparktan kapı alanına geldi ve ORADA, hareket ederken,
             resmin kenarına giderek kayboldu.
  · Otopark içindeki hareket SAYILMAZ (kayda "içeride" yazılır).
Kapı alanı yoksa: araç yeterince yol alıp durunca ya da hareket ederken
kaybolunca karar (her hareket bölümünde bir kez).

Sahada ölçülenler (2026-11-08, 180 gerçek fotoğraf): DURAN aracın kutusu
gürültüyle IoU 0.85'e kadar oynar, çapası köşegenin %3'ü kadar kayar; bu
yüzden "duruyor" ve "yeni görünüm" kutuya değil aracın PİKSELLERİNE bakar
(köprünün DURGUN_ESIGI'si, kurulumda ölçülen). Kenardan giren araç yarısı
görünür olunca bulunur (puan ≥ 0.35) — kapı alanı en az bir araç boyu
derin çizilmeli.

Saf mantık: kamera, iş parçacığı yok. Plaka yazımı (`yaz`) ve izin oylama
kabı (`yeni_gecis`) dışarıdan verilir (köprüde okuma.plakalari_yaz /
okuma.Gecis); testler sahtelerini verir.
"""
from __future__ import annotations

import math
from collections import deque
from typing import NamedTuple

import cv2
import numpy as np

import arac
import gunluk
import plaka

# ---------------------------------------------------------------- sabitler ---

ESLES_IOU = 0.30          # tahmin edilen kutuyla bu kadar örtüşen kutu aynı araç
MERKEZ_KAT = 0.6          # örtüşmeyen: merkez ≤ köşegen × bu ve alan oranı ALAN_ORAN içinde
ALAN_ORAN = (0.5, 2.0)
KOPYA_IOU = 0.5           # eşleşmiş bir kutuyla bu kadar örtüşen aday yeni iz açmaz
KAYIP_KARE = 3            # en az bu kadar ÖLÇÜLEN karede görülmedi …
KAYIP_SN = 1.5            # … ve en az bu kadar süre: iz kayıp
DIKIS_SN = 4.0            # kayıp iz bu süre içinde yakında yeniden görülürse aynı iz
DIKIS_KAT = 1.0           # dikiş: merkez ≤ köşegen × bu (son yere ya da hızla tahmin edilen yere)
DIKIS_TAHMIN_SN = 2.0     # görünmez aracın yeri hızıyla en çok bu kadar ileri tahmin edilir
DIKIS_ALAN = (0.4, 2.5)
PARK_IOU = 0.5            # duruyorken kaybolan araç bu kadar örtüşen yerde doğarsa o araçtır
PARK_SN = 1800.0
PARK_EN_COK = 50
DURAN_SN = 2.0            # bu süre boyunca pikselleri değişmeyen araç duruyor
DURAN_IOU = 0.6           # … ve kutusu (titreme payıyla) yerinde: ölçülen en kötü 0.845
TAHMIN_SN = 1.0           # bundan uzun aradan sonra hızla tahmin yapılmaz
ADIM_KAT = 1.5            # 1.4.1 hız kuralı: geriye / ileriye en çok bu kadar ölçülmüş adım
TEK_KARE_ORTUSME = 0.10   # 1.4.1 tek kare: başka kutuyla kendi alanının bu payından çok örtüşen "hareketli" değil
ISINMA_KARE = 2           # açılış / yeniden bağlanma: bu karelerde görülen araç "eski"
GIRIS_KARE = 2            # kapının dışında art arda bu kadar kare: kapıdan çıktı
GIRIS_TAVAN_SN = 30.0     # kapıdan çıkıp hiç durmayan araç için en geç karar
KAPIDA_BEKLEME_SN = 60.0  # kapı alanında bu kadar duran araç: uyarı (alan yanlış çizilmiş olabilir)
# 1.4.2 (A4): kapı alanı en çok bu kadar önce, izlenen hiçbir aracın
# açıklamadığı biçimde kıpırdadıysa kapının dibinde DURURKEN doğan araç
# kapıdan gelmiştir (sahada 11.11 19:08).
KAPI_GECIS_SN = 3.0
EN_AZ_YOL = 0.30          # kapısız kipte bir hareket bölümü: çapa ≥ köşegen × bu
KENAR_PX = 2.0            # kutu kırpıntının kenarına bu kadar yakınsa kenara değiyor
KENAR_KARE = 3            # son bu kadar ölçülen karede kenara değdiyse "kenardan çıkıyordu"
IZ_EN_COK = 20
YEREL_EN_AZ = 6           # yerel farkın gri görüntüdeki en küçük bölgesi (piksel)
# Sahipsiz plaka izi: plaka küçük, kare başına kendi boyunun katları kadar kayar.
PLAKA_MERKEZ_KAT = 3.0
PLAKA_ALAN_ORAN = (0.33, 3.0)
PLAKA_PAY = (0.05, 0.25)  # plaka → araç: önce %5, bulunamazsa %25 genişletilmiş kutu
PLAKA_ALT = 0.4           # plaka merkezi kutunun alt %60'ındaysa öncelikli
BELIRSIZ_ORAN = 1.3       # iki aday alan oranı bundan küçükse: hangisi bilinmez
# 1.4.3 (1a): tut ve em (Emici). Değerler benim seçimim, sahada ayarlanır —
# kayıt satırı aralığı yazar.
EMME_SN = 2.0             # parça, gerçek izin son görülmesinden en çok bu kadar sonra (kuyruk)
                          # ya da ilk görülmesinden en çok bu kadar önce (baş) görüldü
EMME_KENAR_SN = 5.0       # aynı kenardaki iki kutunun en büyük zaman farkı
EMME_PAY = 0.15           # parçanın kenar boyu açıklığı, gerçek izinkinin bu payıyla içinde
TUTMA_EN_COK_SN = 40.0    # parça, eşleşebilecek canlı izin kararını en çok bu kadar bekler
EMME_HAFIZA_SN = 60.0     # kararı verilmiş (ele alınmış) GİRDİ / ÇIKTI izi bu kadar hatırlanır
KENAR_KUTU_SAYI = 30      # izin kenara değen ilk ve son bu kadar kutusu saklanır
YONSUZ_OLAYLAR = ("TEK_KARE", "KAPIDA_KAYBOLDU", "ESKI_GIRDI")
YONLU_OLAYLAR = ("GIRDI", "CIKTI")


class Olcum(NamedTuple):
    """Bir karenin iki modelden sonucu. araclar / plakalar None = ölçülmedi."""
    no: int
    mono: float
    zaman: object
    kirpik: np.ndarray
    gri: np.ndarray                  # 160×120 gri (köprünün hareket ölçüsü)
    araclar: list | None             # [AracKutu]
    plakalar: list | None            # [(plaka.Kutu, kutuyu_oku sonucu | okuma.Kesik | None)]
    # 1.4.3 (PARK_GORUNUR): köprünün hareket tetiğinin (maskeli) grisi —
    # `gri` maskesizken degisti() bununla karşılaştırır. None = gri'nin kendisi.
    tetik_gri: np.ndarray | None = None


class Olay(NamedTuple):
    # GIRDI | CIKTI | ESKI_GIRDI | KAPISIZ | ICERIDE | GERI_DONDU | KAPIDA_BEKLIYOR
    # | TEK_KARE (1.4.1: kapıda yalnızca bir karede görülen hareketli araç → personele)
    # | KAPIDA_KAYBOLDU (1.4.2: kapıda kaybolan, kararsız, hareketli araç → personele)
    tur: str
    iz: "Iz"
    zaman: object


# İzcinin verebileceği bütün olay türleri: köprünün iki yeri (canlı döngü ve
# --plaka) her birinin adını bilmeli (test_kurulum denetler).
OLAY_TURLERI = ("GIRDI", "CIKTI", "ESKI_GIRDI", "KAPISIZ", "ICERIDE", "GERI_DONDU",
                "KAPIDA_BEKLIYOR", "TEK_KARE", "KAPIDA_KAYBOLDU")


def _sayildi(olaylar: list[Olay]) -> list[Olay]:
    """Her olayın izine işler (kararsız biten iz = hiç olayı olmayan iz)."""
    for o in olaylar:
        o.iz.olay_sayisi += 1
    return olaylar


def _alandakiler(olaylar: list[Olay]) -> list[Olay]:
    """
    1.4.3 (PARK_GORUNUR): çapası hiç kırpma alanına ya da kapıya girmemiş izin
    olayı düşer — modellerin gördüğü alan dışındaki park araçları (kararı
    alana girmiş izler verir). Alan yoksa her iz alandadır: hiçbir şey düşmez.
    """
    return [o for o in olaylar if o.iz.alanda]


def _merkez(k) -> tuple[float, float]:
    return (k[0] + k[2]) / 2.0, (k[1] + k[3]) / 2.0


def _kosegen(k) -> float:
    return math.hypot(k[2] - k[0], k[3] - k[1])


def _alan(k) -> float:
    return max(0.0, k[2] - k[0]) * max(0.0, k[3] - k[1])


def _kesisim(a, b) -> float:
    return (max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
            * max(0.0, min(a[3], b[3]) - max(a[1], b[1])))


def yerel_fark(a: np.ndarray, b: np.ndarray, k, en: int, boy: int) -> float:
    """İki gri karenin `k` kutusu bölgesindeki ortalama mutlak farkı."""
    gh, gw = a.shape[:2]
    x1, x2 = k[0] * gw / en, k[2] * gw / en
    y1, y2 = k[1] * gh / boy, k[3] * gh / boy
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    w, h = max(x2 - x1, YEREL_EN_AZ), max(y2 - y1, YEREL_EN_AZ)
    a1, a2 = int(max(0, math.floor(cx - w / 2))), int(min(gw, math.ceil(cx + w / 2)))
    b1, b2 = int(max(0, math.floor(cy - h / 2))), int(min(gh, math.ceil(cy + h / 2)))
    if a2 <= a1 or b2 <= b1:
        return 0.0
    return float(np.mean(cv2.absdiff(a[b1:b2, a1:a2], b[b1:b2, a1:a2])))


class Iz:
    """Bir aracın (ya da sahipsiz bir plakanın) izi."""

    def __init__(self, no: int, kaynak: str, kutu, o: Olcum, gecis, koken: str,
                 kapidan: bool):
        self.id = no
        self.kaynak = kaynak                 # "arac" | "plaka"
        self.gecis = gecis
        self.kutu = kutu
        self.dogum_kutu = kutu
        self.dogum_mono = o.mono
        self.son_mono, self.son_zaman = o.mono, o.zaman
        self.hiz = (0.0, 0.0)
        self.kacirma = 0
        self.durum = "izleniyor"             # izleniyor | kayip | bitti
        self.koken = koken                   # kapi | yard | eski
        self.kapidan_dogdu = kapidan
        self.gecmis: deque = deque()         # (mono, kutu, gri)
        self.duruyor = False
        self.durma_bas: float | None = None
        self.uyarildi = False
        self.gorunum_no = 0
        self.gorunum_capa: tuple | None = None
        self.gorunum_gri: np.ndarray | None = None
        self.disari_kare = 0
        self.disarida_bulundu = False
        self.gecti_mono: float | None = None
        self.gecti_zaman = None
        self.geri_dondu = False
        self.kapida = False
        self.giris_karari = False
        self.cikis_karari = False
        self.bolum_capa: tuple | None = None
        self.bolum_hareketli = False
        self.kenar_son: deque = deque(maxlen=KENAR_KARE)   # son ölçülen karelerde kenara değdi mi
        # 1.4.1: kapıda görülmeyen araç (hız kuralı) ve plaka ↔ araç devri.
        self.dogum_zaman = o.zaman
        self.gorulme = 0                     # kaç ölçülen karede görüldü (doğduğu dahil)
        self.onceki_bosluk: float | None = None   # doğmadan önceki ölçülen kareden beri (sn)
        self.son_adim: tuple | None = None   # (önceki çapa, çapa, sn): son iki görülme
        self.ilk_kacirma_mono: float | None = None  # son görülmeden sonraki ilk ölçülen kare
        self.kapida_gorulmedi = False        # karar hız kuralıyla verildi (kayda yazılır)
        # 1.4.2 (A4): doğduğu kareden ÖNCEKİ son "açıklanmamış kapı kıpırtısı"nın anı.
        self.kapi_kipirti_once: float | None = None
        self.plaka_ofset: tuple | None = None    # araç kutusu − plaka kutusu (x1, y1, x2, y2)
        self.sentetik = False                # son kutu plakadan kuruldu (gövde görünmedi)
        self.plaka_yazildi = False           # bu izin oylamasına plaka yazıldı
        self.devraldi = False                # bir plaka izinin yerini aldı
        self.taze = False                    # yeni doğdu (dikiş / park belleği değil)
        self.dogum_hareketli = False         # doğduğu karede pikselleri bir öncekinden farklı
        self.plaka_kilit = False             # durdu: gövde yeniden görülene dek plaka sürükleyemez
        self.olay_sayisi = 0                 # 1.4.2: bu izin verdiği olaylar (kararsız mı?)
        # 1.4.2 (A3): doğduğunda yanında (bir araç köşegeni, TAHMIN_SN içinde
        # görülmüş) başka bir araç izi vardı — kenardan çıkan aracın kuyruğu olabilir.
        self.dogumda_komsu = False
        # 1.4.3 (1a): kırpıntının kenarına değen kutular (an, kutu, kenarlar) —
        # ilk KENAR_KUTU_SAYI ve son KENAR_KUTU_SAYI (Emici "aynı araç mı" bakar).
        self.kenar_ilk: list = []
        self.kenar_sonra: deque = deque(maxlen=KENAR_KUTU_SAYI)
        # 1.4.3 (PARK_GORUNUR): çapası kırpma alanına ya da kapıya girdi mi
        # (alanda) / orada mı doğdu (dogum_alanda). Alan yoksa her yer alandır.
        self.alanda = True
        self.dogum_alanda = True

    def kenar_kutulari(self) -> list:
        return self.kenar_ilk + list(self.kenar_sonra)

    def tahmin(self, mono: float):
        dt = mono - self.son_mono
        if self.duruyor or dt <= 0 or dt > TAHMIN_SN:
            return self.kutu
        dx, dy = self.hiz[0] * dt, self.hiz[1] * dt
        k = self.kutu
        return (k[0] + dx, k[1] + dy, k[2] + dx, k[3] + dy)

    def devral(self, p: "Iz") -> None:
        """
        1.4.1: karanlıkta yalnızca plakası görülen araç (plaka izi `p`) bir
        lambanın altında gövdesiyle görünür oldu: bu araç izi onun yerini alır.
        Kapı bilgisi (nereden geldi, kapıdan çıktı mı, karar verildi mi) ve
        plaka okumaları (oylama kabı) bu ize geçer — 1.4.0'da plaka izi
        silinir, araç izi otoparkta "yeni doğmuş" sayılır, giriş kaybolurdu.
        """
        g = p.gecis
        a_max = getattr(self.gecis, "arac_max", None)
        if a_max is not None and (getattr(g, "arac_max", None) is None or a_max > g.arac_max):
            g.arac_max = a_max
            g.arac_sinif = getattr(self.gecis, "arac_sinif", None)    # 1.4.3
            g.arac_kirpik = getattr(self.gecis, "arac_kirpik", None)
        son = getattr(self.gecis, "son_kirpik", None)
        if son is not None:
            g.son_kirpik = son
        self.gecis = g
        for ad in ("koken", "kapidan_dogdu", "gecti_mono", "gecti_zaman", "geri_dondu",
                   "giris_karari", "cikis_karari", "kapida_gorulmedi"):
            setattr(self, ad, getattr(p, ad))
        self.disarida_bulundu = self.disarida_bulundu or p.disarida_bulundu
        self.alanda = self.alanda or p.alanda          # 1.4.3 (PARK_GORUNUR)
        self.olay_sayisi += p.olay_sayisi
        # Görünüm numarası geri gitmesin: aynı numara iki ayrı görünüm sayılmaz
        # (ihtiyatlı — en kötü bir görünüm eksik sayılır, fazla değil).
        self.gorunum_no = max(self.gorunum_no, p.gorunum_no)
        self.plaka_yazildi = self.plaka_yazildi or p.plaka_yazildi
        self.devraldi = True

    def __repr__(self) -> str:
        return f"Iz({self.id}, {self.kaynak}, {self.koken}, {self.durum})"


class Takipci:
    """
    `en`, `boy`: ölçeklenmiş kırpıntının boyutu (kutuların pikseli). `kapi`:
    kapı alanının köşeleri aynı pikselde (None = kapı kuralı yok).
    `yeni_gecis()`: izin oylama kabı; `yaz(gecis, kirpik, zaman, gorunum,
    olcumler)`: o ize düşen plaka ölçümlerini yazar.
    """

    def __init__(self, en: int, boy: int, kapi=None, *, yeni_gecis, yaz,
                 dogum_esik: float = 0.35, durgun_esik: float = 2.0,
                 kaynak: str = "arac", alan=None):
        self.en, self.boy = int(en), int(boy)
        self.kapi = None if kapi is None else np.asarray(kapi, dtype=np.float32).reshape(-1, 1, 2)
        # 1.4.3 (PARK_GORUNUR): kırpma alanının köşeleri aynı pikselde. None =
        # bütün kırpıntı alandır (bugünkü davranış birebir).
        self.alan = None if alan is None else np.asarray(alan, dtype=np.float32).reshape(-1, 1, 2)
        self._yeni_gecis, self._yaz = yeni_gecis, yaz
        self.dogum_esik = float(dogum_esik)
        self.durgun_esik = float(durgun_esik)
        self.kaynak = kaynak
        self.izler: list[Iz] = []
        self.park: list[tuple] = []
        self._no = 0
        self._isinma = ISINMA_KARE
        self.belirsiz_plaka = 0
        self.tasan_iz = 0
        # 1.4.2 (A2): kararsız biten araç izleri [(iz, "kapı" | "otopark")] —
        # köprü her birine bir kayıt satırı yazar (kararsiz_al).
        self._kararsizlar: list[tuple[Iz, str]] = []
        # 1.4.2 (A4): kapı alanının pikselleri son ölçülen kareye göre değişti ve
        # o karede kapıda izlenen hiçbir iz (araç ya da plaka) yoktu — son anı.
        self._kapi_kipirti_mono: float | None = None
        self.son_gri: np.ndarray | None = None    # son ÖLÇÜLEN karenin grisi
        self._son_olcum_mono: float | None = None  # son ölçülen karenin anı
        self._onceki_gri: np.ndarray | None = None  # bu kareden bir önceki ölçülenin grisi
        self._tetik_gri: np.ndarray | None = None   # 1.4.3: son ölçülenin tetik (maskeli) grisi
        if self.kapi is None:
            self._kapi_kutu = None
        else:
            p = self.kapi.reshape(-1, 2)
            self._kapi_kutu = (max(0.0, float(p[:, 0].min())), max(0.0, float(p[:, 1].min())),
                               min(float(self.en), float(p[:, 0].max())),
                               min(float(self.boy), float(p[:, 1].max())))
        kosegen = math.hypot(self.en, self.boy)
        self.kapi_tolerans = max(2.0, 0.005 * kosegen)
        self._giris_payi_taban = 0.02 * kosegen
        self._plakaci = None if kaynak == "plaka" else Takipci(
            en, boy, kapi, yeni_gecis=yeni_gecis, yaz=yaz, dogum_esik=dogum_esik,
            durgun_esik=durgun_esik, kaynak="plaka", alan=alan)

    # ------------------------------------------------------------ geometri --

    def _kapi_mesafe(self, capa) -> float:
        """İçeride +, dışarıda − (piksel)."""
        return float(cv2.pointPolygonTest(self.kapi, (float(capa[0]), float(capa[1])), True))

    def _kapida(self, capa) -> bool:
        return self.kapi is not None and self._kapi_mesafe(capa) >= -self.kapi_tolerans

    def _alanda(self, capa) -> bool:
        """
        1.4.3 (PARK_GORUNUR): çapa kırpma alanında ya da kapıda mı (kapının
        payıyla). Frigate'in bölgeleri gibi: alt orta nokta.
        """
        if self.alan is None:
            return True
        nokta = (float(capa[0]), float(capa[1]))
        return (cv2.pointPolygonTest(self.alan, nokta, True) >= -self.kapi_tolerans
                or self._kapida(capa))

    def _capa(self, k) -> tuple[float, float]:
        return (k[0] + k[2]) / 2.0, min(k[3], self.boy - 0.5)

    def _kenarda(self, k) -> bool:
        return (k[0] <= KENAR_PX or k[1] <= KENAR_PX or k[2] >= self.en - KENAR_PX
                or k[3] >= self.boy - KENAR_PX)

    def _kenarlari(self, k) -> frozenset:
        """1.4.3 (1a): kutunun değdiği kırpıntı kenarları (_kenarda ile aynı pay)."""
        e = set()
        if k[0] <= KENAR_PX:
            e.add("sol")
        if k[2] >= self.en - KENAR_PX:
            e.add("sag")
        if k[1] <= KENAR_PX:
            e.add("ust")
        if k[3] >= self.boy - KENAR_PX:
            e.add("alt")
        return frozenset(e)

    def _kenara_gidiyor(self, iz: Iz) -> bool:
        """Kayıptan önce resmin kenarına değiyordu ya da en yakın kenara gidiyordu."""
        if any(iz.kenar_son):
            return True
        x, y = self._capa(iz.kutu)
        uzak = {(-1, 0): x, (1, 0): self.en - x, (0, -1): y, (0, 1): self.boy - y}
        yon = min(uzak, key=uzak.get)
        hiz = iz.hiz[0] * yon[0] + iz.hiz[1] * yon[1]
        return hiz > 0.02 * _kosegen(iz.kutu)

    # ------------------------------------- 1.4.1: kapıda görülmeyen araç ---
    # Sahada ~3-4 kare/sn: hızlı araç kapı alanını iki kare ARASINDA geçer, ya
    # da bulucu onu kapıda (yarısı görünür, bulanık, karanlık) görmez. Aracın
    # son iki görülmesinden hızı bilinir: bir kare ÖNCESİ (giriş) ya da
    # SONRASI (çıkış) kapı alanından geçiyorsa kapıdan gelmiş / gitmiştir.
    # Pay, "kapıdan çıktı" payının aynısı: frenleyen / hızlanan araçta tahmin
    # birkaç piksel şaşar.

    def _payi(self, k) -> float:
        return max(self._giris_payi_taban, 0.10 * (k[3] - k[1]))

    def _yol_kapiya_degiyor(self, p, q, pay: float) -> bool:
        """p → q doğru parçası kapı alanına (pay içinde) değiyor mu."""
        n = int(min(200, math.dist(p, q) / max(1.0, pay / 2))) + 2
        for i in range(n):
            t = i / (n - 1)
            if self._kapi_mesafe((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)) >= -pay:
                return True
        return False

    def _kapidan_geldi_mi(self, z: Iz) -> bool:
        """
        İkinci görülmede: otoparkta DOĞMUŞ araç kapıdan uzaklaşıyor ve bir kare
        önceki yeri (hızıyla) kapı alanında mı. Duran / ağır kalkan araç
        (adım < pay) sayılmaz: kapının dibinde park etmiş, bulucunun o ana dek
        görmediği araç olabilir.
        """
        # Plaka izini devralan araç: nereden geldiği o izden biliniyor
        # (otoparkta izlenmiş plaka = zaten içerideydi).
        if (z.koken != "yard" or z.kapidan_dogdu or z.giris_karari or z.devraldi
                or z.son_adim is None or not z.onceki_bosluk):
            return False
        if not z.dogum_alanda:
            # 1.4.3 (PARK_GORUNUR): alan dışında doğan araç (gece farını yakan
            # park aracı) kapıdan geldi sayılmaz.
            return False
        a, b, dt = z.son_adim
        pay = self._payi(z.kutu)
        if math.dist(a, b) < pay or self._kapi_mesafe(b) >= self._kapi_mesafe(a):
            return False
        # Sahne boşken köprü seyrek ölçer (2 sn): doğmadan önceki boşluk uzun
        # olabilir. Geriye en çok ADIM_KAT ölçülmüş adım bakılır.
        g = min(z.onceki_bosluk, ADIM_KAT * dt, TAHMIN_SN)
        geri = (a[0] - (b[0] - a[0]) / dt * g, a[1] - (b[1] - a[1]) / dt * g)
        return self._yol_kapiya_degiyor(geri, a, pay)

    def _kapiya_gitti_mi(self, z: Iz) -> bool:
        """Kayıpta: kapıya doğru gidiyordu ve bir kare sonraki yeri kapı alanında mı."""
        if z.son_adim is None or z.ilk_kacirma_mono is None:
            return False
        a, b, dt = z.son_adim
        pay = self._payi(z.kutu)
        if math.dist(a, b) < pay or self._kapi_mesafe(b) <= self._kapi_mesafe(a):
            return False
        g = min(z.ilk_kacirma_mono - z.son_mono, ADIM_KAT * dt, TAHMIN_SN)
        if g <= 0:
            return False
        ileri = (b[0] + (b[0] - a[0]) / dt * g, b[1] + (b[1] - a[1]) / dt * g)
        return self._yol_kapiya_degiyor(b, ileri, pay)

    def _kapidan_cikip_kayboldu_mu(self, z: Iz) -> bool:
        """
        1.4.3, kayıpta (_kapiya_gitti_mi'nin aynası): kapıda doğan araç kapının
        dışında GIRIS_KARE'den az karede görülüp kayboldu ve son adımı kapıdan
        uzaklaşıyordu — kapıdan çıkıp otoparka girdi. Hızlı araç kapı ile
        alanın gri yeri (ya da bir engel) arasını bir iki karede geçer; iki
        kare kuralı dolmazsa iz kararsız biterdi: ne bilet ne kart (test_kopru
        takip_park_gorunur_disaridan_giris_kapali, 20.11). İki kare kuralı
        aynen durur: bu yalnızca KAYBOLAN, HAREKETLİ izde, kapının dışında.
        """
        if (not z.kapidan_dogdu or z.koken not in ("kapi", "eski") or z.giris_karari
                or z.gecti_mono is not None or z.geri_dondu or z.duruyor
                or z.son_adim is None):
            return False
        a, b, _dt = z.son_adim
        if self._kapida(b) or math.dist(a, b) < self._payi(z.kutu):
            return False
        return self._kapi_mesafe(b) < self._kapi_mesafe(a)

    # ----------------------------------------------------------- eşleştirme -

    def _canli(self) -> list[Iz]:
        return [z for z in self.izler if z.durum == "izleniyor"]

    def _esles(self, o: Olcum, araclar: list) -> tuple[list[tuple[Iz, object]], list]:
        canli = self._canli()
        tahmin = {id(z): z.tahmin(o.mono) for z in canli}
        adaylar = [a for a in araclar if a.skor >= arac.KUTU_ALT]
        ciftler = []
        for z in canli:
            for j, a in enumerate(adaylar):
                i = arac.ortusme(tahmin[id(z)], a)
                if i >= ESLES_IOU:
                    ciftler.append((i, z, j))
        ciftler.sort(key=lambda c: -c[0])
        eslesen: list[tuple[Iz, object]] = []
        kullanilan_iz, kullanilan = set(), set()
        for _, z, j in ciftler:
            if id(z) in kullanilan_iz or j in kullanilan:
                continue
            eslesen.append((z, adaylar[j]))
            kullanilan_iz.add(id(z))
            kullanilan.add(j)
        # İkinci tur: örtüşmeyen (hızlı) araçlar merkez uzaklığıyla.
        plaka_mi = self.kaynak == "plaka"
        kat = PLAKA_MERKEZ_KAT if plaka_mi else MERKEZ_KAT
        oran = PLAKA_ALAN_ORAN if plaka_mi else ALAN_ORAN
        taban = 0.05 * math.hypot(self.en, self.boy) if plaka_mi else 0.0
        ciftler = []
        for z in canli:
            # Duran araç yalnızca örtüşerek (birinci tur) sürer: duruştan kalkan
            # araç bir sonraki karede hâlâ eski yeriyle örtüşür; yanından geçen
            # başka bir aracın kutusu onun izini almasın.
            if id(z) in kullanilan_iz or z.duruyor:
                continue
            t = tahmin[id(z)]
            for j, a in enumerate(adaylar):
                if j in kullanilan:
                    continue
                d = math.dist(_merkez(t), _merkez(a))
                r = _alan(a) / max(_alan(t), 1e-9)
                if d <= max(kat * _kosegen(t), taban) and oran[0] <= r <= oran[1]:
                    ciftler.append((d, z, j))
        ciftler.sort(key=lambda c: c[0])
        for _, z, j in ciftler:
            if id(z) in kullanilan_iz or j in kullanilan:
                continue
            eslesen.append((z, adaylar[j]))
            kullanilan_iz.add(id(z))
            kullanilan.add(j)
        kalan = [a for j, a in enumerate(adaylar) if j not in kullanilan]
        return eslesen, kalan

    def _dogur(self, o: Olcum, a, bu_karede: set) -> Iz | None:
        """Eşleşmeyen kutu: dikiş, park belleği, ya da yeni iz."""
        # Dikiş: bu karede eşleşmemiş bir iz yakında yeniden görüldü. Üç durum:
        #   · kayıp iz (önünden biri geçti),
        #   · henüz kayıp sayılmamış iz (1 sn'lik örtülmede araç kapıya varmış
        #     olabilir — yeni iz olsaydı kapıda "doğmuş" sayılır, çıkışı kaybolurdu),
        #   · bu kare de görülen ama olağan payın dışına sıçrayan iz (yoğun
        #     dizüstünde 2 kare/sn: araç kare başına kendi boyunun ~0.7'si kadar
        #     ilerler — her kare yeni iz olsaydı girişi de çıkışı da kaybolurdu).
        en_iyi, en_d = None, None
        for z in self.izler:
            gorunmez = z.durum in ("izleniyor", "kayip")
            if not gorunmez or id(z) in bu_karede or o.mono - z.son_mono >= DIKIS_SN:
                continue
            # Görünmezken ilerlemiş olabilir: son yeri ya da HIZIYLA tahmin
            # edilen yeri (en çok DIKIS_TAHMIN_SN) — yavaş dizüstünde (az kare)
            # araç son görüldüğü yerden bir araç boyundan fazla ilerleyebilir.
            if z.duruyor and arac.ortusme(z.kutu, a) < PARK_IOU:
                # DURAN araç (park etmiş) yalnızca YERİNDE sürer: yanından geçen
                # aracın kutusu onun izine dikilseydi, o araç kapıdan çıkınca
                # park etmiş aracın plakası "çıktı" diye gider, biletini kapatırdı.
                continue
            gecen = 0.0 if z.duruyor else min(o.mono - z.son_mono, DIKIS_TAHMIN_SN)
            mx, my = _merkez(z.kutu)
            tahmin = (mx + z.hiz[0] * gecen, my + z.hiz[1] * gecen)
            d = min(math.dist((mx, my), _merkez(a)), math.dist(tahmin, _merkez(a)))
            r = _alan(a) / max(_alan(z.kutu), 1e-9)
            if d <= DIKIS_KAT * _kosegen(z.kutu) and DIKIS_ALAN[0] <= r <= DIKIS_ALAN[1]:
                if en_d is None or d < en_d:
                    en_iyi, en_d = z, d
        if en_iyi is not None:
            en_iyi.durum = "izleniyor"
            return en_iyi
        if a.skor < self.dogum_esik:
            return None
        if len(self._canli()) >= IZ_EN_COK:
            self.tasan_iz += 1
            return None
        capa = self._capa(a)
        # Park belleği: duruyorken kaybolan araç aynı yerde yeniden doğdu.
        for i, p in enumerate(self.park):
            kutu = p[0]
            if (arac.ortusme(kutu, a) >= PARK_IOU
                    and math.dist(_merkez(kutu), _merkez(a)) <= 0.3 * _kosegen(kutu)):
                self.park.pop(i)
                _, koken, kapidan, giris, cikis, gecis, _m, disarida, alanda = p
                self._no += 1
                z = Iz(self._no, self.kaynak, a, o, gecis, koken, kapidan)
                z.giris_karari, z.cikis_karari = giris, cikis
                # 1.4.3 (PARK_GORUNUR): "alana girmişti" bellekten gelir.
                z.alanda = z.dogum_alanda = alanda or self._alanda(capa)
                # 1.4.3: "otoparkta görülmüştü" bellekten gelir — kapıda durup
                # örtülen, otoparktan gelen araç yeniden doğunca kapıda doğdu
                # diye unutulmasın (çıkışı KAPIDA_KAYBOLDU kartı oluyordu).
                z.disarida_bulundu = disarida or not self._kapida(capa)
                self.izler.append(z)
                return z
        if self._isinma > 0:
            koken = "eski"
        elif self._kapida(capa):
            koken = "kapi"
        else:
            koken = "yard"
        self._no += 1
        gecis = self._yeni_gecis()
        if self.kaynak == "plaka" and getattr(getattr(gecis, "oylama", None), "birlesik", False):
            # 1.4.1: plaka izinde çok karede birleştirme YOK — küçük kutu
            # gürültüyle oynar, duran plaka "yeni görünüm" sayılabilirdi
            # (bağımsız inceleme, 2026-11-09). Olağan %95 kuralı aynen.
            gecis.oylama.birlesik = False
        z = Iz(self._no, self.kaynak, a, o, gecis, koken, self._kapida(capa))
        z.alanda = z.dogum_alanda = self._alanda(capa)
        if self._son_olcum_mono is not None:
            z.onceki_bosluk = o.mono - self._son_olcum_mono
        z.taze = True
        z.kapi_kipirti_once = self._kapi_kipirti_mono       # 1.4.2 (A4): bu kareden önce
        # Pikselleri bir önceki ölçülen kareden farklı — ama aynı karedeki başka
        # bir aracın kutusuyla örtüşmüyorsa: önünden geçen araç park etmiş
        # aracın piksellerini değiştirir, o araç gelmiş gitmiş değildir
        # (bağımsız inceleme, 2026-11-09).
        z.dogum_hareketli = (
            self._onceki_gri is not None
            and yerel_fark(o.gri, self._onceki_gri, a, self.en, self.boy) >= self.durgun_esik
            and not any(b is not a and _kesisim(a, b) > TEK_KARE_ORTUSME * _alan(a)
                        for b in o.araclar))
        z.dogumda_komsu = self._komsu_var(a, o.mono)
        self.izler.append(z)
        return z

    def _komsu_var(self, a, mono: float) -> bool:
        """
        1.4.2 (A3): yeni doğan kutunun yanında — merkezler arası en çok bir araç
        köşegeni, son TAHMIN_SN içinde görülmüş — başka bir iz var mı. Alt
        kenardan çıkan aracın kuyruğu: kutusu çok küçüldüğü için kendi izine
        dikilmez, tek karelik yeni iz doğar; o iz personele tek kare eşiğinin
        düşüğüyle (doğum eşiği) gitmemeli (okuma.iz_arac_esigi).
        """
        for y in self.izler:
            if y.durum == "bitti" or mono - y.son_mono > TAHMIN_SN:
                continue
            k = y.tahmin(mono)
            if math.dist(_merkez(k), _merkez(a)) <= max(_kosegen(k), _kosegen(a)):
                return True
        return False

    # ---------------------------------------------------------------- kare ---

    def guncelle(self, o: Olcum) -> list[Olay]:
        """Bir ölçülen kare. Araç sonucu yoksa (None) hiçbir iz ilerlemez."""
        if o.araclar is None:
            return []
        # 1.4.2 (A4): kapı alanı bir önceki ölçülen kareye göre kıpırdadı mı
        # (kim açıkladı, karenin sonunda bakılır).
        kapi_kipirdadi = (self.kaynak == "arac" and self._kapi_kutu is not None
                          and self.son_gri is not None
                          and yerel_fark(o.gri, self.son_gri, self._kapi_kutu, self.en, self.boy)
                          >= self.durgun_esik)
        self._onceki_gri, self.son_gri = self.son_gri, o.gri
        self._tetik_gri = o.gri if o.tetik_gri is None else o.tetik_gri
        olaylar: list[Olay] = []
        eslesen, kalan = self._esles(o, list(o.araclar))
        guncellenen: list[tuple[Iz, object]] = list(eslesen)
        eslesmis_kutular = [a for _, a in eslesen]
        for a in sorted(kalan, key=lambda k: -k.skor):
            if any(arac.ortusme(a, b) >= KOPYA_IOU for b in eslesmis_kutular):
                continue
            z = self._dogur(o, a, {id(g) for g, _ in guncellenen})
            if z is None:
                continue
            if any(z is g for g, _ in guncellenen):
                continue
            guncellenen.append((z, a))
            eslesmis_kutular.append(a)
        gorulen = {id(z) for z, _ in guncellenen}
        for z in self._canli():
            if id(z) not in gorulen:
                z.kacirma += 1
                if z.kacirma == 1:
                    z.ilk_kacirma_mono = o.mono
                if z.kacirma >= KAYIP_KARE and o.mono - z.son_mono >= KAYIP_SN:
                    z.durum = "kayip"
        for z, a in guncellenen:
            self._ilerle(z, a, o, olaylar)
        if self._isinma > 0:
            self._isinma -= 1
        if o.plakalar is not None:
            olaylar += self._plakalari_ata(o, guncellenen)
        if kapi_kipirdadi and not self._kapida_iz_var():
            self._kapi_kipirti_mono = o.mono          # 1.4.2 (A4): kimse açıklamıyor
        self._son_olcum_mono = o.mono
        return _sayildi(_alandakiler(olaylar))

    def _kapida_iz_var(self) -> bool:
        """1.4.2 (A4): kapı alanında yaşayan bir araç ya da plaka izi var mı."""
        izciler = [self] + ([self._plakaci] if self._plakaci is not None else [])
        return any(z.kapida for t in izciler for z in t.izler if z.durum != "bitti")

    def _ilerle(self, z: Iz, a, o: Olcum, olaylar: list[Olay], sentetik: bool = False) -> None:
        """
        Eşleşen iz: hız, durma, görünüm, kapı kuralları. `sentetik`: kutu
        gövdeden değil plakadan kuruldu (1.4.1, karanlık araç) — araç kanıtı
        sayılmaz.
        """
        dt = o.mono - z.son_mono
        if 0 < dt <= KAYIP_SN:
            (ex, ey), (yx, yy) = _merkez(z.kutu), _merkez(a)
            v = ((yx - ex) / dt, (yy - ey) / dt)
            z.hiz = (0.5 * (z.hiz[0] + v[0]), 0.5 * (z.hiz[1] + v[1])) if z.kacirma == 0 else v
        elif dt > KAYIP_SN:
            z.hiz = (0.0, 0.0)
        onceki_capa = self._capa(z.kutu)
        z.son_adim = (onceki_capa, self._capa(a), dt) if z.gorulme and 0 < dt <= KAYIP_SN else None
        z.gorulme += 1
        z.ilk_kacirma_mono = None
        z.sentetik = sentetik
        z.kutu = a
        z.kacirma = 0
        z.son_mono, z.son_zaman = o.mono, o.zaman
        z.gecmis.append((o.mono, a, o.gri))
        # "Duruyor": DURAN_SN boyunca HER karede kutusu (titreme payıyla)
        # yerinde ve pikselleri DURAN_SN öncesine göre değişmemiş. Daha genç
        # iz bilinmez = hareketli. "Her karede": yalnızca iki ana bakılsaydı
        # gidip aynı yere dönen araç (U dönüşü) duruyor sanılırdı.
        once = None
        while len(z.gecmis) >= 2 and z.gecmis[1][0] <= o.mono - DURAN_SN:
            z.gecmis.popleft()
        if z.gecmis and z.gecmis[0][0] <= o.mono - DURAN_SN:
            once = z.gecmis[0]
        z.duruyor = (once is not None
                     and all(arac.ortusme(g[1], a) >= DURAN_IOU for g in z.gecmis)
                     and yerel_fark(o.gri, once[2], a, self.en, self.boy) < self.durgun_esik)
        # 1.4.1: duran araç, gövdesi yeniden (hareketli) görülene dek plakayla
        # ilerletilmez — önünden AĞIR geçen koyu aracın plakası ilk adımda
        # "yerinde" görünür, sonra izini kapıya kadar sürüklerdi (bağımsız
        # inceleme, 2026-11-09).
        if z.duruyor:
            z.plaka_kilit = True
        elif not sentetik:
            z.plaka_kilit = False
        z.kenar_son.append(self._kenarda(a))
        kenarlar = self._kenarlari(a)
        if kenarlar:
            kayit = (o.mono, a, kenarlar)
            if len(z.kenar_ilk) < KENAR_KUTU_SAYI:
                z.kenar_ilk.append(kayit)
            else:
                z.kenar_sonra.append(kayit)
        # Görünüm: aracın PİKSELLERİ değişti ve çapası kaydı (yalnızca kutu
        # titremesi yeni görünüm değildir — iki görünüm kuralı delinmesin).
        capa = self._capa(a)
        pay = max(4.0, 0.03 * _kosegen(a))
        if z.gorunum_gri is None:
            z.gorunum_no, z.gorunum_capa, z.gorunum_gri = 1, capa, o.gri
        elif (yerel_fark(o.gri, z.gorunum_gri, a, self.en, self.boy) >= self.durgun_esik
              and math.dist(capa, z.gorunum_capa) >= pay):
            z.gorunum_no += 1
            z.gorunum_capa, z.gorunum_gri = capa, o.gri
        g = z.gecis
        g.son_kirpik = o.kirpik
        if (self.kaynak == "arac" and not sentetik
                and (getattr(g, "arac_max", None) is None or a.skor > g.arac_max)):
            g.arac_max = a.skor
            g.arac_sinif = a.sinif               # 1.4.3: motosiklet eşiği ve kayıt satırı
            g.arac_kirpik = o.kirpik
        if not z.alanda and self._alanda(capa):
            z.alanda = True
        if z.bolum_capa is None:
            z.bolum_capa = capa
        if math.dist(capa, z.bolum_capa) >= EN_AZ_YOL * _kosegen(z.dogum_kutu):
            z.bolum_hareketli = True
        if self.kapi is None:
            self._kapisiz(z, capa, o, olaylar)
        else:
            if z.gorulme == 2 and self._kapidan_geldi_mi(z):
                # Kapıdan geldi ama kapıda görülmedi: kapıda doğmuş gibi; şu an
                # kapının payı dışındaysa kapıdan çıkışı doğduğu andır.
                z.koken, z.kapidan_dogdu, z.kapida_gorulmedi = "kapi", True, True
                if self._kapi_mesafe(capa) <= -self._payi(a):
                    z.disarida_bulundu = True
                    z.gecti_mono, z.gecti_zaman = z.dogum_mono, z.dogum_zaman
            elif z.gorulme == 2 and self._durarak_kapidan_geldi_mi(z):
                # 1.4.2 (A4): kapıdan görülmeden geçip hemen dibinde durdu.
                self._kapidan_gorulmeden_geldi(z, a, capa)
            self._kapi_kurali(z, a, capa, o, olaylar)

    def _bolum_bitti(self, z: Iz, capa) -> None:
        z.bolum_capa = capa
        z.bolum_hareketli = False

    def _kapisiz(self, z: Iz, capa, o: Olcum, olaylar: list[Olay]) -> None:
        if z.duruyor and z.bolum_hareketli:
            olaylar.append(Olay("KAPISIZ", z, o.zaman))
            self._bolum_bitti(z, capa)
        elif z.duruyor:
            self._bolum_bitti(z, capa)

    def _kapi_kurali(self, z: Iz, a, capa, o: Olcum, olaylar: list[Olay]) -> None:
        mesafe = self._kapi_mesafe(capa)
        ic = mesafe >= -self.kapi_tolerans
        payi = max(self._giris_payi_taban, 0.10 * (a[3] - a[1]))
        z.disari_kare = z.disari_kare + 1 if mesafe <= -payi else 0
        if z.disari_kare >= GIRIS_KARE:
            z.disarida_bulundu = True
            if (z.kapidan_dogdu and z.koken in ("kapi", "eski") and not z.giris_karari
                    and z.gecti_mono is None):
                z.gecti_mono, z.gecti_zaman = o.mono, o.zaman
        if ic and z.gecti_mono is not None and not z.giris_karari:
            # Kapıdan çıkıp geri döndü (U dönüşü): geçiş iptal.
            z.gecti_mono, z.gecti_zaman = None, None
            z.geri_dondu = True
        z.kapida = ic
        if z.gecti_mono is not None and not z.giris_karari and z.duruyor:
            self._giris(z, olaylar)
            self._bolum_bitti(z, capa)
        elif z.duruyor and not ic:
            # Otopark içinde yer değiştirdi: sayılmaz, kayda yazılır. Kapıdan
            # doğup kararı bekleyen araç burada değildir (o yukarıdaki dal).
            if z.bolum_hareketli and not (z.kapidan_dogdu and not z.giris_karari):
                olaylar.append(Olay("ICERIDE", z, o.zaman))
            self._bolum_bitti(z, capa)
        elif z.duruyor:
            self._bolum_bitti(z, capa)
        # Kapı alanında uzun süre duran araç: alan yanlış çizilmiş olabilir.
        if ic and z.duruyor:
            if z.durma_bas is None:
                z.durma_bas = o.mono
            elif o.mono - z.durma_bas >= KAPIDA_BEKLEME_SN and not z.uyarildi:
                z.uyarildi = True
                olaylar.append(Olay("KAPIDA_BEKLIYOR", z, o.zaman))
        else:
            z.durma_bas = None

    def _giris(self, z: Iz, olaylar: list[Olay]) -> None:
        z.giris_karari = True
        tur = "ESKI_GIRDI" if z.koken == "eski" else "GIRDI"
        olaylar.append(Olay(tur, z, z.gecti_zaman))

    # ------------------------------------------------------- plaka ataması --

    def _plakalari_ata(self, o: Olcum, guncellenen) -> list[Olay]:
        """Her plaka kutusu içinde durduğu ize; sahipsizler plaka izcisine."""
        adaylar = [(z, z.kutu) for z, _ in guncellenen]
        adaylar += [(z, z.tahmin(o.mono)) for z in self._canli()
                    if z.kacirma > 0 and all(z is not g for g, _ in guncellenen)]
        ize: dict[int, tuple[Iz, list]] = {}
        sahipsiz = []
        sahipli = []
        for olcum in o.plakalar:
            k = olcum[0]
            px, py = _merkez(k)
            secilen = None
            for pay in PLAKA_PAY:
                icinde = []
                for z, b in adaylar:
                    w, h = b[2] - b[0], b[3] - b[1]
                    if b[0] - pay * w <= px <= b[2] + pay * w and b[1] - pay * h <= py <= b[3] + pay * h:
                        icinde.append((z, b))
                if not icinde:
                    continue
                alt = [(z, b) for z, b in icinde if py >= b[1] + PLAKA_ALT * (b[3] - b[1])]
                sira = sorted(alt or icinde, key=lambda c: _alan(c[1]))
                if len(sira) >= 2 and _alan(sira[1][1]) / max(_alan(sira[0][1]), 1e-9) < BELIRSIZ_ORAN:
                    self.belirsiz_plaka += 1
                    secilen = False
                else:
                    secilen = sira[0][0]
                break
            if secilen is None:
                sahipsiz.append(olcum)
            elif secilen is not False:
                ize.setdefault(id(secilen), (secilen, []))[1].append(olcum)
                sahipli.append(k)
        olaylar: list[Olay] = []
        gorulen = {id(z) for z, _ in guncellenen}
        for z, olcumler in ize.values():
            if self.kaynak == "arac" and len(olcumler) == 1:
                k = olcumler[0][0]
                if id(z) not in gorulen:
                    # 1.4.1: gövdesi görünmeyen (karanlık) aracın plakası onun
                    # tahmini kutusunda: araç plakayla sürer (yoksa otoparkta
                    # kaybolur, kapıdan çıkışı kaçardı).
                    self._plakayla_ilerlet(z, k, o, olaylar)
                elif not z.sentetik:
                    z.plaka_ofset = (z.kutu[0] - k.x1, z.kutu[1] - k.y1,
                                     z.kutu[2] - k.x2, z.kutu[3] - k.y2)
                    if self._plakaci is not None and self._devralabilir(z):
                        eski = [p for p in self._plakaci._plaka_izleri(k, o.mono)
                                if p.dogum_mono < z.dogum_mono
                                and self._kutuda(_merkez(p.tahmin(o.mono)), z.kutu)]
                        if eski:
                            # Yakındaki başka bir koyu aracın izi değil: en yakını.
                            z.devral(min(eski, key=lambda p: math.dist(
                                _merkez(p.tahmin(o.mono)), _merkez(k))))
            self._yaz(z.gecis, o.kirpik, o.zaman, z.gorunum_no, olcumler)
            z.plaka_yazildi = True
        if self._plakaci is None:
            return olaylar
        # Bir araca yazılan plakanın sahipsiz izi bırakılır: çift karar olmasın.
        self._plakaci._birak(sahipli, o.mono)
        po = Olcum(o.no, o.mono, o.zaman, o.kirpik, o.gri,
                   [arac.AracKutu(k.x1, k.y1, k.x2, k.y2, max(float(k.skor), self.dogum_esik))
                    for k, _ in sahipsiz], sahipsiz, o.tetik_gri)
        return olaylar + self._plakaci.guncelle(po)

    @staticmethod
    def _devralabilir(z: Iz) -> bool:
        """
        Yalnızca YENİ doğmuş (ilk iki görülme), henüz hiçbir şeye karar
        verilmemiş araç izi bir plaka izini devralır. Bağımsız inceleme
        (2026-11-09): çıkan aracın izi yakındaki giren koyu aracın plaka izini
        devralıp "kapıdan doğmuş" oluyor, çıkışı kayboluyordu.
        """
        return (z.taze and z.gorulme <= GIRIS_KARE and not z.devraldi and not z.plaka_yazildi
                and z.gecti_mono is None and not z.giris_karari and not z.cikis_karari)

    @staticmethod
    def _kutuda(p, k) -> bool:
        """Nokta, plaka atamasının geniş payıyla araç kutusunun içinde mi."""
        pay = PLAKA_PAY[-1]
        w, h = k[2] - k[0], k[3] - k[1]
        return k[0] - pay * w <= p[0] <= k[2] + pay * w and k[1] - pay * h <= p[1] <= k[3] + pay * h

    def _plakayla_ilerlet(self, z: Iz, k, o: Olcum, olaylar: list[Olay]) -> None:
        """Gövdesi görünmeyen aracın kutusunu plakasından kurar ve izi ilerletir."""
        # DURMUŞ araç plakayla hiç ilerlemez: önünden geçen koyu aracın plakası
        # onu sürükleseydi, o araç kapıdan çıkınca park etmiş aracın biletini
        # kapatırdı. (Durup karanlıkta kalkan araç gövdesi görülmezse plaka
        # izinden sürer.)
        if z.plaka_ofset is None or z.plaka_kilit:
            return
        d = z.plaka_ofset
        yeni = arac.AracKutu(k.x1 + d[0], k.y1 + d[1], k.x2 + d[2], k.y2 + d[3], self.dogum_esik)
        self._ilerle(z, yeni, o, olaylar, sentetik=True)

    def _plaka_izleri(self, k, mono: float) -> list[Iz]:
        """Bu plaka kutusunun (tahmini yeriyle) yakınındaki plaka izleri."""
        yakin = []
        for z in self.izler:
            t = z.tahmin(mono)
            kat = max(PLAKA_MERKEZ_KAT * _kosegen(t), 0.05 * math.hypot(self.en, self.boy))
            if math.dist(_merkez(t), _merkez(k)) <= kat:
                yakin.append(z)
        return yakin

    def _birak(self, plakalar: list, mono: float) -> None:
        for k in plakalar:
            for z in self._plaka_izleri(k, mono):
                self.izler.remove(z)

    # -------------------------------------------------------------- zaman ---

    def zaman_gecti(self, mono: float) -> list[Olay]:
        """Kayıp izlerin son kararı ve kapıdan çıkıp durmayan aracın tavanı."""
        olaylar: list[Olay] = []
        for z in list(self.izler):
            if (z.durum == "izleniyor" and z.gecti_mono is not None and not z.giris_karari
                    and mono - z.gecti_mono >= GIRIS_TAVAN_SN):
                self._giris(z, olaylar)
            if z.durum == "kayip" and mono - z.son_mono >= DIKIS_SN:
                z.durum = "bitti"
                self.izler.remove(z)
                n = len(olaylar)
                self._son_karar(z, olaylar)
                if len(olaylar) == n:
                    self._kararsiz(z)
        if len(self.park) > PARK_EN_COK or (self.park and mono - self.park[0][6] > PARK_SN):
            self.park = [p for p in self.park if mono - p[6] <= PARK_SN][-PARK_EN_COK:]
        if self._plakaci is not None:
            olaylar += self._plakaci.zaman_gecti(mono)
        return _sayildi(_alandakiler(olaylar))

    def _kararsiz(self, z: Iz) -> None:
        """
        1.4.2 (A2): hiçbir olay vermeden, hareket hâlinde biten ARAÇ izi kayda
        geçer (sahada 11.11 beş araç iz bırakmadan kayboldu). Duran araç park
        belleğine gider (bitmedi); plaka izinin tek başına anlamı yok.
        """
        if (self.kaynak != "arac" or z.duruyor or z.olay_sayisi
                or z.giris_karari or z.cikis_karari):
            return
        if not z.alanda:
            return              # 1.4.3: alan dışındaki park yerinin izi not düşmez
        ic = self.kapi is not None and self._kapida(self._capa(z.kutu))
        self._kararsizlar.append((z, "kapı" if ic else "otopark"))

    def kararsiz_al(self) -> list[tuple[Iz, str]]:
        """Kararsız biten araç izleri [(iz, "kapı" | "otopark")]; alınan bir daha verilmez."""
        k, self._kararsizlar = self._kararsizlar, []
        return k

    def _son_karar(self, z: Iz, olaylar: list[Olay]) -> None:
        capa = self._capa(z.kutu)
        if self.kapi is None:
            if not z.duruyor and z.bolum_hareketli:
                olaylar.append(Olay("KAPISIZ", z, z.son_zaman))
            elif z.duruyor:
                self._parka(z)
            return
        # 1.4.1: YALNIZCA bir karede görülen, o karede gerçekten hareketli
        # (pikselleri değişmiş) araç kapı alanında ya da ona bir kare yol
        # (kutunun köşegeni) yakınında: hızı yok, nereden geldiği bilinmez,
        # ama sessizce kaybolmasın — personele. Otoparkın derinindeki tek kare
        # (bulucunun bir an gördüğü park etmiş araç) gönderilmez.
        # Yalnızca ARAÇ izinde: plaka izcisinin tek karelik izi çoğu zaman
        # gövdesi bir kare sonra bulunan aracın ön plakasıdır — o aracın kendi
        # kararının yanına ikinci kart açardı. Devralınmış bir karar da
        # tekrarlanmaz (bağımsız inceleme, 2026-11-09).
        if (self.kaynak == "arac" and z.gorulme == 1 and z.dogum_hareketli
                and not (z.devraldi or z.giris_karari or z.cikis_karari
                         or z.gecti_mono is not None)
                and self._kapi_mesafe(capa) >= -_kosegen(z.kutu)):
            olaylar.append(Olay("TEK_KARE", z, z.son_zaman))
            return
        ic = self._kapida(capa)
        if z.gecti_mono is not None and not z.giris_karari and not ic:
            self._giris(z, olaylar)
            return
        if not ic and self._kapidan_cikip_kayboldu_mu(z):
            z.gecti_mono, z.gecti_zaman = z.son_mono, z.son_zaman
            self._giris(z, olaylar)
            return
        u_donusu = z.kapidan_dogdu and not z.giris_karari
        if ic and not z.duruyor and u_donusu:
            if z.geri_dondu:
                olaylar.append(Olay("GERI_DONDU", z, z.son_zaman))
            elif self._kapida_kayboldu_mu(z):
                olaylar.append(Olay("KAPIDA_KAYBOLDU", z, z.son_zaman))
            return
        if (ic and not z.duruyor and z.disarida_bulundu and not z.cikis_karari
                and self._kenara_gidiyor(z)):
            z.cikis_karari = True
            olaylar.append(Olay("CIKTI", z, z.son_zaman))
            return
        # 1.4.1: otoparkta son görüldü ama kapıya doğru hızla gidiyordu ve bir
        # kare sonraki yeri kapı alanındaydı: kapıda görülmeden çıktı.
        if (not ic and not z.duruyor and z.disarida_bulundu and not z.cikis_karari
                and not u_donusu and self._kapiya_gitti_mi(z)):
            z.cikis_karari, z.kapida_gorulmedi = True, True
            olaylar.append(Olay("CIKTI", z, z.son_zaman))
            return
        # 1.4.2 (A2): kapının "pay"ı içinde doğmuş, hiç otoparkta (payın
        # dışında) görülmemiş araç kapıda kayboldu — ÇIKTI değil (nereden
        # geldiği bilinmez) ama sessizce de düşmez: personele.
        if (ic and not z.duruyor and not z.disarida_bulundu
                and self._kapida_kayboldu_mu(z)):
            olaylar.append(Olay("KAPIDA_KAYBOLDU", z, z.son_zaman))
            return
        if z.duruyor:
            self._parka(z)
        elif not ic and z.bolum_hareketli and not u_donusu:
            olaylar.append(Olay("ICERIDE", z, z.son_zaman))

    def _kapidan_gorulmeden_geldi(self, z: Iz, a, capa) -> None:
        """
        1.4.2 (A4): yukarıdaki hız kuralının işaretlerinin aynısı — kapıda
        doğmuş gibi (kayıtta "kapıda görülmedi"); şu an kapının payı dışındaysa
        kapıdan çıkışı doğduğu andır (duruyorsa _kapi_kurali GİRDİ der).
        """
        z.koken, z.kapidan_dogdu, z.kapida_gorulmedi = "kapi", True, True
        if self._kapi_mesafe(capa) <= -self._payi(a):
            z.disarida_bulundu = True
            z.gecti_mono, z.gecti_zaman = z.dogum_mono, z.dogum_zaman

    def _durarak_kapidan_geldi_mi(self, z: Iz) -> bool:
        """
        1.4.2 (A4), ikinci görülmede: otoparkta DURURKEN doğan araç kapıdan mı
        geldi (sahada 11.11 19:08 — bulucu onu kapıdan geçerken görmedi,
        hemen dibinde dururken buldu). Hepsi gerekir:
          · yeni doğmuş araç izi (park belleği / dikiş / plaka devri değil),
            otoparkta, yanında başka iz yok, doğduğu karede pikselleri değişmiş;
          · duruyor (ilk adımı paydan küçük — yürüyen _kapidan_geldi_mi'nin);
          · doğduğu yer kapının DIŞINDA ama bir araç köşegeni içinde;
          · doğmadan en çok KAPI_GECIS_SN önce kapı alanı, orada izlenen hiçbir
            iz olmadan kıpırdadı — bir şey kapıdan geçti.
        Kapı kıpırdamadıysa 1.4.1'in koruması aynen: kapının dibinde park
        etmiş, bulucunun o ana dek görmediği araç girdi sayılmaz. Yanılırsa
        (B5) sunucu GIRDI ipucunu görür ve eski bileti kapatmaz (056).
        """
        if (self.kaynak != "arac" or z.koken != "yard" or not z.taze or z.kapidan_dogdu
                or z.giris_karari or z.devraldi or z.dogumda_komsu or not z.dogum_hareketli
                or z.son_adim is None or z.kapi_kipirti_once is None):
            return False
        if not z.dogum_alanda:
            return False        # 1.4.3: alan dışında duran araç kapı kıpırdasa da girmedi
        a, b, _dt = z.son_adim
        if math.dist(a, b) >= self._payi(z.kutu):
            return False
        mesafe = self._kapi_mesafe(a)
        if mesafe >= -self.kapi_tolerans or -mesafe > _kosegen(z.dogum_kutu):
            return False
        return z.dogum_mono - z.kapi_kipirti_once <= KAPI_GECIS_SN

    def _kapida_kayboldu_mu(self, z: Iz) -> bool:
        """
        1.4.2 (A2): kapı alanında hareketliyken kaybolan, en az iki karede
        görülmüş, hiçbir kararı olmayan ARAÇ izi (sahada 07:38 / 19:15 / 19:39 /
        12:10 / 12:38 — hızlı ya da koyu araç ilk kez kapıda bulundu ve kenardan
        çıktı). Yönü bilinmez: personele (iz_personele).
        """
        return (self.kaynak == "arac" and z.gorulme >= 2
                and not (z.giris_karari or z.cikis_karari or z.devraldi
                         or z.gecti_mono is not None))

    def _parka(self, z: Iz) -> None:
        self.park.append((z.kutu, z.koken, z.kapidan_dogdu, z.giris_karari, z.cikis_karari,
                          z.gecis, z.son_mono, z.disarida_bulundu, z.alanda))

    # ------------------------------------------------------------- yaşam ---

    def kare_istiyor(self) -> bool:
        """Model karesi gerekiyor mu (hareket olmasa da)."""
        if self._isinma > 0:
            return True
        for z in self.izler:
            if not z.alanda:
                # 1.4.3 (PARK_GORUNUR): alan dışındaki iz yalnızca belirgin
                # hareket ederken kare ister (park aracı titrese de istemez).
                if z.bolum_hareketli and not z.duruyor:
                    return True
                continue
            if z.durum == "kayip":
                return True
            if not z.duruyor or z.kacirma > 0:
                return True
            if z.gecti_mono is not None and not z.giris_karari:
                return True
        return self._plakaci is not None and self._plakaci.kare_istiyor()

    def okunacak_kutular(self, mono: float) -> tuple[tuple[float, float, float, float], ...]:
        """
        1.4.3 (PARK_GORUNUR): kırpma alanının dışındaki plaka yalnızca bu
        kutulardan birinin içindeyse okunur — yürüyen (durmamış) ve alana girmiş
        ya da belirgin hareket etmiş izlerin bu andaki tahmini kutusu, plaka
        atamasının geniş payıyla (PLAKA_PAY[-1]) her yönde genişletilmiş.
        Duran park aracının plakası hiç okunmaz.
        """
        pay = PLAKA_PAY[-1]
        kutular = []
        for z in self._canli():
            if z.duruyor or not (z.alanda or z.bolum_hareketli):
                continue
            k = z.tahmin(mono)
            w, h = k[2] - k[0], k[3] - k[1]
            kutular.append((float(k[0] - pay * w), float(k[1] - pay * h),
                            float(k[2] + pay * w), float(k[3] + pay * h)))
        sonuc = tuple(kutular)
        if self._plakaci is not None:
            sonuc += self._plakaci.okunacak_kutular(mono)
        return sonuc

    def degisti(self, gri: np.ndarray) -> bool:
        """
        Son ölçülen kareden beri izlenen bir aracın ya da kapı alanının
        PİKSELLERİ değişti mi? Köprü model karesini buna göre de ister: tüm
        kareden ölçülen kıpırtı, yavaş kalkan aracı (kareler arası fark küçük)
        göremiyordu — park etmiş araç kapıya gidip görülmeden kaybolurdu.
        """
        if self._tetik_gri is None:
            return True
        bolgeler = [z.kutu for z in self.izler if z.durum == "izleniyor"]
        if self._kapi_kutu is not None:
            bolgeler.append(self._kapi_kutu)
        if any(yerel_fark(gri, self._tetik_gri, k, self.en, self.boy) >= self.durgun_esik
               for k in bolgeler):
            return True
        return self._plakaci is not None and self._plakaci.degisti(gri)

    def kopma(self, mono: float) -> list[Olay]:
        """Kamera koptu: kapıdan çıkmış, kararı bekleyen araç girdi sayılır; izler bırakılır."""
        olaylar: list[Olay] = []
        for z in self.izler:
            if z.gecti_mono is not None and not z.giris_karari:
                self._giris(z, olaylar)
            elif z.durum != "bitti" and not z.duruyor:
                # 1.4.2 (A2): hareket hâlindeyken kopan iz de kayda geçer.
                self._kararsiz(z)
        self.izler = []
        # Kopmadan önceki görüntü (dakikalar önce, belki başka ışıkta) ile
        # karşılaştırılmasın: her duran araç "hareketli" sayılırdı.
        self.son_gri = self._onceki_gri = self._tetik_gri = None
        if self._plakaci is not None:
            olaylar += self._plakaci.kopma(mono)
        return _sayildi(_alandakiler(olaylar))

    def yeniden_baglandi(self) -> None:
        self._isinma = ISINMA_KARE
        self.son_gri = self._onceki_gri = self._tetik_gri = None
        if self._plakaci is not None:
            self._plakaci.yeniden_baglandi()


# ------------------------------------------- 1.4.3 (1a): tut ve em (Emici) ---

_DISA = {"sol": (-1.0, 0.0), "sag": (1.0, 0.0), "ust": (0.0, -1.0), "alt": (0.0, 1.0)}
_PARCA_ADI = {"TEK_KARE": "tek kare", "KAPIDA_KAYBOLDU": "kapıda kayboldu",
              "ESKI_GIRDI": "açılışta kapıdaydı"}
_KARAR_ADI = {"GIRDI": "girdi", "CIKTI": "çıktı"}
SAAT_SN = 3600.0


def _aciklik(k, kenar: str) -> tuple[float, float]:
    """Kutunun o kenar boyunca açıklığı (alt / üst: x; sol / sağ: y)."""
    return (k[0], k[2]) if kenar in ("ust", "alt") else (k[1], k[3])


class Emici:
    """
    1.4.3 (1a): bir araç → bir karar. Sahada bir aracın kenardaki PARÇASI
    (lastiği, köşesi) ayrı iz oldu ve ikinci kart açtı (16.11 iz 367/368
    kuyruk, 17.11 iz 448/449 baş): kenarda kesik kutu, aracın kutusundan çok
    küçük olduğu için dikilmez (DIKIS_ALAN).

    Yönü bilinmeyen olay (TEK_KARE / KAPIDA_KAYBOLDU / ESKI_GIRDI), kenara
    değmiş bir araç izinden geldiyse bekletilir ve ele alınmış bir GİRDİ /
    ÇIKTI izinin parçası mı diye bakılır. Aynı araç (hepsi gerekir):
      · sıra: ÇIKTI'da parça gerçek izin son görülmesinden SONRA (kuyruk),
        GİRDİ'de ilk görülmesinden ÖNCE (baş) görüldü, en çok EMME_SN arayla —
        hiçbir karede ikisi birlikte görülmedi (kuyrukta iki araç iki araçtır);
      · yer: ikisi de aynı kenara değdi (en çok EMME_KENAR_SN arayla) ve
        parçanın o kenar boyunca açıklığı gerçek izinkinin içinde (EMME_PAY);
      · yön: kuyruk açıkça içeri, baş açıkça dışarı yürümüyor (çıkan A'nın
        ardından kenardan giren B'nin parçası A'nın kuyruğu sayılmaz);
      · plaka: parçanın emin plakaları gerçek izinkilerin içinde (iki farklı
        emin plaka asla; gerçek izde olmayan emin plaka da asla).
    Parçanın okumaları gerçek ize KATILMAZ: iki görünüm kuralı (%95) değişmez.

    `emer` kapalı (PARCA_EMME=0, varsayılan): her olay bugünkü gibi ve aynı
    anda gönderilir; yalnızca "sayılırdı" satırı yazılır, sayılır. Açık:
    parça gönderilmez ("sayıldı"); eşleşebilecek canlı iz varsa onun kararı
    en çok TUTMA_EN_COK_SN beklenir, yoksa parça hemen gider. Kamera koparsa
    (birak) bekleyen her olay hemen gider.

    `gonder(olay, mono) -> bool`: olayı köprünün karar yoluna verir; döndürdüğü
    "ele alındı" (gönderildi, ya da bilerek gönderilmedi: 60 sn kuralı, şeridin
    yönü). Ele alınmamış karar (araç puanı düşük, hiçbir şey gitmedi) parçayı
    saymaz: parça tek kanıttır. `eminler(gecis) -> set`: izin emin plakaları.
    `yaz(satir)`: kayıt satırı (plaka YAZILMAZ). `sayinca(parca, gercek, mono)`
    (1d, isteğe bağlı): parça GÖNDERİLMEDİ (emer açık) — köprü klibini ister;
    yalnızca kayıt kipinde parça gönderildiği için klibi gönderim yolundan çıkar.
    """

    def __init__(self, *, gonder, eminler, yaz, emer: bool = False, sayinca=None):
        self._gonder, self._eminler, self._yaz = gonder, eminler, yaz
        self._sayinca = sayinca
        self.emer = bool(emer)
        self._tutulan: list[tuple[Olay, float]] = []
        self._yonlu: list[tuple[Olay, float]] = []
        self._emilirdi: list[float] = []
        self._emildi: list[float] = []

    def al(self, izci, olaylar: list[Olay], mono: float) -> None:
        """İzcinin olayları (boş liste de: bekleyenlere bakılır)."""
        for o in olaylar:
            if o.tur in YONSUZ_OLAYLAR and o.iz.kaynak == "arac" and o.iz.kenar_kutulari():
                self._tutulan.append((o, mono))
                if not self.emer:
                    self._gonder(o, mono)
            elif self._gonder(o, mono) and o.tur in YONLU_OLAYLAR and o.iz.kaynak == "arac":
                self._yonlu.append((o, mono))
        self._coz(izci, mono)

    def birak(self, mono: float) -> None:
        """Kamera koptu / izleme kapandı / izci yeniden kuruldu: bekleyen hemen gider."""
        tutulan, self._tutulan = self._tutulan, []
        self._yonlu = []
        if self.emer:
            for o, _ in tutulan:
                self._gonder(o, mono)

    def son_saat(self, mono: float) -> tuple[int, int]:
        """Son bir saatte (sayılırdı, sayıldı)."""
        self._emilirdi = [m for m in self._emilirdi if mono - m <= SAAT_SN]
        self._emildi = [m for m in self._emildi if mono - m <= SAAT_SN]
        return len(self._emilirdi), len(self._emildi)

    def _coz(self, izci, mono: float) -> None:
        self._yonlu = [(o, m) for o, m in self._yonlu if mono - m <= EMME_HAFIZA_SN]
        canli = [] if izci is None else [
            z for z in izci.izler
            if z.durum != "bitti" and z.kaynak == "arac" and not (z.giris_karari or z.cikis_karari)]
        kalan = []
        for o, geldi in self._tutulan:
            p = o.iz
            bulunan = None
            for r, _ in self._yonlu:
                aralik = self._ayni_arac(p, r.iz, r.tur)
                if aralik is not None:
                    bulunan = (r, aralik)
                    break
            if bulunan is not None:
                self._sayildi(o, *bulunan, mono)
                continue
            if mono - geldi < TUTMA_EN_COK_SN and any(
                    self._ayni_arac(p, z, None) is not None for z in canli if z is not p):
                kalan.append((o, geldi))
                continue
            if self.emer:
                self._gonder(o, mono)
        self._tutulan = kalan

    def _sayildi(self, o: Olay, r: Olay, aralik: float, mono: float) -> None:
        ne = f"iz {o.iz.id} → iz {r.iz.id} ({_KARAR_ADI[r.tur]}, {aralik:.1f} sn arayla)"
        parca = _PARCA_ADI[o.tur]
        if self.emer:
            self._emildi.append(mono)
            self._yaz(f"[i] {gunluk.EMILDI_ISARETI}: {ne} — {parca} gönderilmedi")
            if self._sayinca is not None:
                self._sayinca(o, r, mono)
        else:
            self._emilirdi.append(mono)
            self._yaz(f"[i] {gunluk.EMILIRDI_ISARETI}: {ne} — {parca} yine gönderildi "
                      "(PARCA_EMME=0)")

    def _ayni_arac(self, p: Iz, r: Iz, tur: str | None) -> float | None:
        """
        Parça `p`, `r` izinin (kararı `tur`; None = canlı, henüz kararsız)
        parçası olabilir mi: olabilirse aralık (sn), yoksa None.
        """
        if r is p or r.kaynak != "arac":
            return None
        kuyruk = p.dogum_mono - r.son_mono
        bas = r.dogum_mono - p.son_mono
        if tur in ("CIKTI", None) and 0 < kuyruk <= EMME_SN:
            aralik = kuyruk
        elif tur in ("GIRDI", None) and 0 < bas <= EMME_SN:
            aralik = bas
        else:
            return None
        if tur is not None and not self._eminler(p.gecis) <= self._eminler(r.gecis):
            return None
        for pm, pk, pe in p.kenar_kutulari():
            for rm, rk, re_ in r.kenar_kutulari():
                if abs(pm - rm) > EMME_KENAR_SN:
                    continue
                for kenar in pe & re_:
                    a, b = _aciklik(pk, kenar)
                    c, d = _aciklik(rk, kenar)
                    pay = EMME_PAY * (d - c)
                    if a >= c - pay and b <= d + pay and self._yon_uyar(p, kenar, tur):
                        return aralik
        return None

    @staticmethod
    def _yon_uyar(p: Iz, kenar: str, tur: str | None) -> bool:
        """Kuyruk açıkça içeri, baş açıkça dışarı yürümüyor (hız ölçülmediyse 0)."""
        if tur is None:
            return True
        n = _DISA[kenar]
        disa = p.hiz[0] * n[0] + p.hiz[1] * n[1]
        esik = 0.02 * _kosegen(p.kutu)
        return disa >= -esik if tur == "CIKTI" else disa <= esik
