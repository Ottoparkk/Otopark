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
    tur: str          # GIRDI | CIKTI | ESKI_GIRDI | KAPISIZ | ICERIDE | GERI_DONDU | KAPIDA_BEKLIYOR
    iz: "Iz"
    zaman: object


def _merkez(k) -> tuple[float, float]:
    return (k[0] + k[2]) / 2.0, (k[1] + k[3]) / 2.0


def _kosegen(k) -> float:
    return math.hypot(k[2] - k[0], k[3] - k[1])


def _alan(k) -> float:
    return max(0.0, k[2] - k[0]) * max(0.0, k[3] - k[1])


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

    def tahmin(self, mono: float):
        dt = mono - self.son_mono
        if self.duruyor or dt <= 0 or dt > TAHMIN_SN:
            return self.kutu
        dx, dy = self.hiz[0] * dt, self.hiz[1] * dt
        k = self.kutu
        return (k[0] + dx, k[1] + dy, k[2] + dx, k[3] + dy)

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
        z = Iz(self._no, self.kaynak, a, o, self._yeni_gecis(), koken, self._kapida(capa))
        self.izler.append(z)
        return z

    # ---------------------------------------------------------------- kare ---

    def guncelle(self, o: Olcum) -> list[Olay]:
        """Bir ölçülen kare. Araç sonucu yoksa (None) hiçbir iz ilerlemez."""
        if o.araclar is None:
            return []
        self.son_gri = o.gri
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
                if z.kacirma >= KAYIP_KARE and o.mono - z.son_mono >= KAYIP_SN:
                    z.durum = "kayip"
        for z, a in guncellenen:
            self._ilerle(z, a, o, olaylar)
        if self._isinma > 0:
            self._isinma -= 1
        if o.plakalar is not None:
            olaylar += self._plakalari_ata(o, guncellenen)
        return olaylar

    def _ilerle(self, z: Iz, a, o: Olcum, olaylar: list[Olay]) -> None:
        """Eşleşen iz: hız, durma, görünüm, kapı kuralları."""
        dt = o.mono - z.son_mono
        if 0 < dt <= KAYIP_SN:
            (ex, ey), (yx, yy) = _merkez(z.kutu), _merkez(a)
            v = ((yx - ex) / dt, (yy - ey) / dt)
            z.hiz = (0.5 * (z.hiz[0] + v[0]), 0.5 * (z.hiz[1] + v[1])) if z.kacirma == 0 else v
        elif dt > KAYIP_SN:
            z.hiz = (0.0, 0.0)
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
        if self.kaynak == "arac" and (getattr(g, "arac_max", None) is None or a.skor > g.arac_max):
            g.arac_max = a.skor
            g.arac_kirpik = o.kirpik
        if z.bolum_capa is None:
            z.bolum_capa = capa
        if math.dist(capa, z.bolum_capa) >= EN_AZ_YOL * _kosegen(z.dogum_kutu):
            z.bolum_hareketli = True
        if self.kapi is None:
            self._kapisiz(z, capa, o, olaylar)
        else:
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
        for z, olcumler in ize.values():
            self._yaz(z.gecis, o.kirpik, o.zaman, z.gorunum_no, olcumler)
        if self._plakaci is None:
            return []
        # Bir araca yazılan plakanın sahipsiz izi bırakılır: çift karar olmasın.
        self._plakaci._birak(sahipli, o.mono)
        po = Olcum(o.no, o.mono, o.zaman, o.kirpik, o.gri,
                   [arac.AracKutu(k.x1, k.y1, k.x2, k.y2, max(float(k.skor), self.dogum_esik))
                    for k, _ in sahipsiz], sahipsiz)
        return self._plakaci.guncelle(po)

    def _birak(self, plakalar: list, mono: float) -> None:
        for k in plakalar:
            for z in list(self.izler):
                t = z.tahmin(mono)
                kat = max(PLAKA_MERKEZ_KAT * _kosegen(t), 0.05 * math.hypot(self.en, self.boy))
                if math.dist(_merkez(t), _merkez(k)) <= kat:
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
        if self._plakaci is not None:
            olaylar += self._plakaci.kopma(mono)
        return olaylar

    def yeniden_baglandi(self) -> None:
        self._isinma = ISINMA_KARE
        if self._plakaci is not None:
            self._plakaci.yeniden_baglandi()
