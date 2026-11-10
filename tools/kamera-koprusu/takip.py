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


class Olcum(NamedTuple):
    """Bir karenin iki modelden sonucu. araclar / plakalar None = ölçülmedi."""
    no: int
    mono: float
    zaman: object
    kirpik: np.ndarray
    gri: np.ndarray                  # 160×120 gri (köprünün hareket ölçüsü)
    araclar: list | None             # [AracKutu]
    plakalar: list | None            # [(plaka.Kutu, kutuyu_oku sonucu | None)]


class Olay(NamedTuple):
    # GIRDI | CIKTI | ESKI_GIRDI | KAPISIZ | ICERIDE | GERI_DONDU | KAPIDA_BEKLIYOR
    # | TEK_KARE (1.4.1: kapıda yalnızca bir karede görülen hareketli araç → personele)
    tur: str
    iz: "Iz"
    zaman: object


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
        self.plaka_ofset: tuple | None = None    # araç kutusu − plaka kutusu (x1, y1, x2, y2)
        self.sentetik = False                # son kutu plakadan kuruldu (gövde görünmedi)
        self.plaka_yazildi = False           # bu izin oylamasına plaka yazıldı
        self.devraldi = False                # bir plaka izinin yerini aldı
        self.taze = False                    # yeni doğdu (dikiş / park belleği değil)
        self.dogum_hareketli = False         # doğduğu karede pikselleri bir öncekinden farklı
        self.plaka_kilit = False             # durdu: gövde yeniden görülene dek plaka sürükleyemez

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
            g.arac_kirpik = getattr(self.gecis, "arac_kirpik", None)
        son = getattr(self.gecis, "son_kirpik", None)
        if son is not None:
            g.son_kirpik = son
        self.gecis = g
        for ad in ("koken", "kapidan_dogdu", "gecti_mono", "gecti_zaman", "geri_dondu",
                   "giris_karari", "cikis_karari", "kapida_gorulmedi"):
            setattr(self, ad, getattr(p, ad))
        self.disarida_bulundu = self.disarida_bulundu or p.disarida_bulundu
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
                 kaynak: str = "arac"):
        self.en, self.boy = int(en), int(boy)
        self.kapi = None if kapi is None else np.asarray(kapi, dtype=np.float32).reshape(-1, 1, 2)
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
        self.son_gri: np.ndarray | None = None    # son ÖLÇÜLEN karenin grisi
        self._son_olcum_mono: float | None = None  # son ölçülen karenin anı
        self._onceki_gri: np.ndarray | None = None  # bu kareden bir önceki ölçülenin grisi
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
            durgun_esik=durgun_esik, kaynak="plaka")

    # ------------------------------------------------------------ geometri --

    def _kapi_mesafe(self, capa) -> float:
        """İçeride +, dışarıda − (piksel)."""
        return float(cv2.pointPolygonTest(self.kapi, (float(capa[0]), float(capa[1])), True))

    def _kapida(self, capa) -> bool:
        return self.kapi is not None and self._kapi_mesafe(capa) >= -self.kapi_tolerans

    def _capa(self, k) -> tuple[float, float]:
        return (k[0] + k[2]) / 2.0, min(k[3], self.boy - 0.5)

    def _kenarda(self, k) -> bool:
        return (k[0] <= KENAR_PX or k[1] <= KENAR_PX or k[2] >= self.en - KENAR_PX
                or k[3] >= self.boy - KENAR_PX)

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
                _, koken, kapidan, giris, cikis, gecis, _m = p
                self._no += 1
                z = Iz(self._no, self.kaynak, a, o, gecis, koken, kapidan)
                z.giris_karari, z.cikis_karari = giris, cikis
                z.disarida_bulundu = not self._kapida(capa)
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
        if self._son_olcum_mono is not None:
            z.onceki_bosluk = o.mono - self._son_olcum_mono
        z.taze = True
        # Pikselleri bir önceki ölçülen kareden farklı — ama aynı karedeki başka
        # bir aracın kutusuyla örtüşmüyorsa: önünden geçen araç park etmiş
        # aracın piksellerini değiştirir, o araç gelmiş gitmiş değildir
        # (bağımsız inceleme, 2026-11-09).
        z.dogum_hareketli = (
            self._onceki_gri is not None
            and yerel_fark(o.gri, self._onceki_gri, a, self.en, self.boy) >= self.durgun_esik
            and not any(b is not a and _kesisim(a, b) > TEK_KARE_ORTUSME * _alan(a)
                        for b in o.araclar))
        self.izler.append(z)
        return z

    # ---------------------------------------------------------------- kare ---

    def guncelle(self, o: Olcum) -> list[Olay]:
        """Bir ölçülen kare. Araç sonucu yoksa (None) hiçbir iz ilerlemez."""
        if o.araclar is None:
            return []
        self._onceki_gri, self.son_gri = self.son_gri, o.gri
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
        self._son_olcum_mono = o.mono
        return olaylar

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
            g.arac_kirpik = o.kirpik
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
                    for k, _ in sahipsiz], sahipsiz)
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
                self._son_karar(z, olaylar)
        if len(self.park) > PARK_EN_COK or (self.park and mono - self.park[0][6] > PARK_SN):
            self.park = [p for p in self.park if mono - p[6] <= PARK_SN][-PARK_EN_COK:]
        if self._plakaci is not None:
            olaylar += self._plakaci.zaman_gecti(mono)
        return olaylar

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
        u_donusu = z.kapidan_dogdu and not z.giris_karari
        if ic and not z.duruyor and u_donusu:
            if z.geri_dondu:
                olaylar.append(Olay("GERI_DONDU", z, z.son_zaman))
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
        if z.duruyor:
            self._parka(z)
        elif not ic and z.bolum_hareketli and not u_donusu:
            olaylar.append(Olay("ICERIDE", z, z.son_zaman))

    def _parka(self, z: Iz) -> None:
        self.park.append((z.kutu, z.koken, z.kapidan_dogdu, z.giris_karari, z.cikis_karari,
                          z.gecis, z.son_mono))

    # ------------------------------------------------------------- yaşam ---

    def kare_istiyor(self) -> bool:
        """Model karesi gerekiyor mu (hareket olmasa da)."""
        if self._isinma > 0:
            return True
        for z in self.izler:
            if z.durum == "kayip":
                return True
            if not z.duruyor or z.kacirma > 0:
                return True
            if z.gecti_mono is not None and not z.giris_karari:
                return True
        return self._plakaci is not None and self._plakaci.kare_istiyor()

    def degisti(self, gri: np.ndarray) -> bool:
        """
        Son ölçülen kareden beri izlenen bir aracın ya da kapı alanının
        PİKSELLERİ değişti mi? Köprü model karesini buna göre de ister: tüm
        kareden ölçülen kıpırtı, yavaş kalkan aracı (kareler arası fark küçük)
        göremiyordu — park etmiş araç kapıya gidip görülmeden kaybolurdu.
        """
        if self.son_gri is None:
            return True
        bolgeler = [z.kutu for z in self.izler if z.durum == "izleniyor"]
        if self._kapi_kutu is not None:
            bolgeler.append(self._kapi_kutu)
        if any(yerel_fark(gri, self.son_gri, k, self.en, self.boy) >= self.durgun_esik
               for k in bolgeler):
            return True
        return self._plakaci is not None and self._plakaci.degisti(gri)

    def kopma(self, mono: float) -> list[Olay]:
        """Kamera koptu: kapıdan çıkmış, kararı bekleyen araç girdi sayılır; izler bırakılır."""
        olaylar: list[Olay] = []
        for z in self.izler:
            if z.gecti_mono is not None and not z.giris_karari:
                self._giris(z, olaylar)
        self.izler = []
        # Kopmadan önceki görüntü (dakikalar önce, belki başka ışıkta) ile
        # karşılaştırılmasın: her duran araç "hareketli" sayılırdı.
        self.son_gri = self._onceki_gri = None
        if self._plakaci is not None:
            olaylar += self._plakaci.kopma(mono)
        return olaylar

    def yeniden_baglandi(self) -> None:
        self._isinma = ISINMA_KARE
        self.son_gri = self._onceki_gri = None
        if self._plakaci is not None:
            self._plakaci.yeniden_baglandi()
