# -*- coding: utf-8 -*-
"""
Okuma akışı (köprü 1.3.0): bir geçişin karelerinden plakaya, plakadan karara.

Üç parça, üçü de kameradan bağımsız sınanır (test_okuma.py):
  · Gecis      — bir geçişin (aynı aracın karelerinin) toplanan bilgisi.
  · Isci       — modelleri yakalama döngüsünden AYRI bir iş parçacığında
                 çalıştırır. Döngü ASLA beklemez: tek bir kutuya en yeni kare
                 bırakılır (eskisi ezilir), ayrıca bir öncelikli kutu vardır
                 (geçişten önceki durgun kare, aracın durduğu kare). Yavaş bir
                 dizüstünde yalnızca daha az kare okunur.
  · karar_ver  — geçiş bitince ne gönderileceğine karar verir (saf fonksiyon).

Kurallar (işletme sahibinin kararları, 2026-11-06):
  · Emin olunan plaka → sunucuya plaka (bilet / çıkış). Zaman = plakanın İLK
    okunduğu karenin anı; fotoğraf = o plakanın en iyi okunduğu kare.
  · Emin olunamayan plaka → personele (okunamadi + tahmin + fotoğraf).
  · Plaka hiç görülmedi ama araç boyutunda bir şey DURDU → yine personele.
    Geçip giden plakasız hareket (yaya, gölge) yalnızca kayda yazılır.
  · Gönderilmiş, duran aracın gidişi (ayrılış) personele bir şey yazmaz ve
    o plakayı yeniden göndermez; aynı geçişteki BAŞKA bir emin plaka gider.
  · Aynı plaka (ya da bir karakter farklısı) 60 sn içinde ikinci kez gitmez.
  · Okuyucu bozuksa (model yok / çöktü) araç boyutundaki her geçiş personele.
Kayıt satırlarına plaka YAZILMAZ.

1.3.1 — araç bulucu (arac.py, sahibin kararları 2026-11-07):
  · Her karede çalışır (plaka kutusu olan karede de); plaka okumasından
    sonra, ondan bağımsız. Çökerse plaka okuma SÜRER, bulucu kapanır.
  · Duran, araç boyunda, plakasız şey: durduğu karede araç yoksa personele
    GİTMEZ — duran insanlar. Durduğu kare ölçülemediyse personele.
  · Durmadan geçen, plakası hiç okunamayan, NET bir araç da personele gider
    (1.3.0'da sessizce düşüyordu).
  · Bulucu yok / bozuk / kapalı: kararlar 1.3.0 ile birebir aynı.
1.3.2 — "önce de vardı" YERE bakar (sahada 2026-11-07 akşamı iki araç kayıtsız
geçti: yavaş gelen araç geçişten önceki kareye kendisi girmişti):
  · Yalnızca YENİ araç sayılır: geçişten önceki karede aynı yerde duran araç
    (park etmiş) sayılmaz; aynı araç başka yerdeyse yenidir.
  · Bulucu varken 1.3.0'ın "önceki karede plaka kutusu → gidiş" kuralı
    kullanılmaz. Gönderilmiş aracın gidişi `ayrilis`le kapalıdır.
  · Önceki kare ölçülmediyse 1.3.0 kuralı.
1.4.0 — araç İZLEME (takip.py): kare işi (`Is.kare`) iki modele aynı anda
verilir; ikisi bitince sonuç tek bir takip.Olcum olarak birleşir
(`biten_kareler`) ve izci plakayı içinde durduğu araca yazar
(`plakalari_yaz` — geçişin yazımıyla birebir). Karar iz başına `iz_karari`.
Geçiş kodu (TAKIP=0, bulucu yok/bozuk) değişmedi.
"""
from __future__ import annotations

import threading
import time
from typing import NamedTuple

import numpy as np

import arac
import gunluk
import plaka
import takip

AYRILIS_ISARETI = gunluk.AYRILIS_ISARETI
PLAKASIZ_ISARETI = gunluk.PLAKASIZ_ISARETI
OKUYUCU_BOZUK_ISARETI = gunluk.OKUYUCU_BOZUK_ISARETI
ARAC_BOZUK_ISARETI = gunluk.ARAC_BOZUK_ISARETI
OKUYUCU_DONDU_ISARETI = gunluk.OKUYUCU_DONDU_ISARETI
ARAC_DONDU_ISARETI = gunluk.ARAC_DONDU_ISARETI
ARAC_YOK_ISARETI = gunluk.ARAC_YOK_ISARETI
ARAC_YETISMEDI_ISARETI = gunluk.ARAC_YETISMEDI_ISARETI
PLAKASIZ_ARAC_ISARETI = gunluk.PLAKASIZ_ARAC_ISARETI
BIRLESIK_ISARETI = gunluk.BIRLESIK_ISARETI
YON_BILINMIYOR_ISARETI = gunluk.YON_BILINMIYOR_ISARETI

# 1.3.1: karar, durulan karenin sonucunu işçinin ölçülen kare süresinin bu
# katı kadar bekler (bir süren iş + durulan kare ≈ 2 kare), en az
# PLAKA_BEKLE_SN, en çok BEKLE_TAVAN_SN (o sırada yakalama döngüsü bekler).
BEKLE_KAT = 2.5
BEKLE_TAVAN_SN = 2.0
# 1.3.2: iki araç kutusu bu kadar örtüşüyorsa (IoU) aynı yerdeki aynı araçtır.
# Park etmiş aracın kutusu kareden kareye ≥0.93 örtüşür (gerçek modelle, gürültülü
# karelerde ölçüldü, 2026-11-07); büyük bir araç
# boyunun %30u kadar ilerlese de ~0.54 örtüşür (gerçek fotoğraflarda 0.48).
# Şüphede "yeni" sayılır: kayıt açmak, aracı kaçırmaktan iyidir.
AYNI_ARAC_ORTUSME = 0.7

# Arka plan (geçişten önceki durgun kare) okuması: ayrılışı tanımak için, oy değil.
ARKA_ESIK = 0.80
ARDISIK_HATA = 3
# 1.4.3: çalışırken bozulan okuyucu / bulucu bu kadar sonra TEK kareyle yeniden
# denenir; tutmazsa bekleme ikiye katlanır (en çok tavan). Önceden köprü
# yeniden başlayana kadar kapalı kalıyordu (izleme de).
YENIDEN_DENE_SN = 60.0
YENIDEN_DENE_TAVAN_SN = 900.0
YAKIN_SN = 60.0


def _yakin(a: str | None, b: str | None) -> bool:
    return a is not None and b is not None and (a == b or plaka.bir_fark(a, b))


def _yeni_gitti(p: str | None, son_gonderilen: list, simdi: float, *,
                yalniz_emin: bool = False, cikti_haric: bool = False) -> bool:
    """
    Bu plaka (ya da bir karakter farklısı) son 60 sn içinde gönderildi mi.
    Bellek kaydı (plaka ya da tahmin, monotonic, emin mi) — `gonderim_kaydi`;
    üçüncü alanı olmayan eski kayıt emin sayılır.
    1.4.3 (sahada 16.11 16:17): `yalniz_emin` — EMİN bir okuma yalnızca emin
    gönderilmiş plakalara bakar. Personele giden kartın TAHMİNİ aynı aracın
    sonraki emin okumasını düşürmez; yalnızca ikinci bir kartı engeller.
    1.4.3 (sahibin kararı 18.11): `cikti_haric` — içeride sorusu ÇIKTI
    ipuçlu kayda takılmaz: çıktı sanılan araç içeride görülürse sunucu
    "çıkmamış olabilir" kartı açar (072). Dördüncü alan yön ipucudur.
    """
    for kayit in son_gonderilen:
        g, t = kayit[0], kayit[1]
        if yalniz_emin and not (kayit[2] if len(kayit) > 2 else True):
            continue
        if cikti_haric and len(kayit) > 3 and kayit[3] == "CIKTI":
            continue
        if _yakin(p, g) and simdi - t <= YAKIN_SN:
            return True
    return False


# ------------------------------------------------------------------ geçiş ----

class Gecis:
    """Bir geçiş. Alanlara işçi ve döngü `kilit` altında yazar."""

    def __init__(self, gid: int, baslangic, oylama: plaka.Oylama):
        self.id = gid
        self.baslangic = baslangic          # ilk hareketin karesinin anı (datetime)
        self.oylama = oylama
        self.en_iyi: dict[str, tuple[float, np.ndarray]] = {}   # metin → (enk, kırpık)
        self.kutulu: tuple[float, np.ndarray] | None = None      # (skor, kırpık)
        self.arka_okunan: set[str] = set()
        # Geçişten önceki durgun karede plaka KUTUSU vardı (kesik ya da
        # okunamamış olsa da): kadrajda zaten bir araç duruyordu.
        self.arka_kutulu = False
        self.durgun_kirpik: np.ndarray | None = None
        self.son_kirpik: np.ndarray | None = None
        # Araç bulucu (1.3.1; 1.3.2'den beri YERE bakar). None = ÖLÇÜLMEDİ
        # (bulucu yok, iş yetişmedi). Puanlar yalnızca YENİ araçların puanı:
        # geçişten önceki karede aynı yerde duran araç sayılmaz.
        self.arka_araclar: list | None = None       # geçişten ÖNCEKİ karedeki kutular
        self.arka_plaka_sayisi: int | None = None   # o karedeki plaka kutuları (teşhis)
        self.arac_max: float | None = None          # geçişin karelerinde en yüksek yeni araç
        # 1.4.3: izleyicinin yazdığı en iyi kutunun sınıfı (arac.SINIF_ADLARI);
        # None/-1 = bilinmiyor. 1.3.4 geçiş kuralı bunu doldurmaz (o yol zaten 0.60).
        self.arac_sinif: int | None = None
        self.arac_kirpik: np.ndarray | None = None  # o karenin kendisi (fotoğraf)
        self.arac_durgun: float | None = None       # durulan karedeki yeni araç
        self.insan_max: float | None = None         # yalnızca kayıt satırı için
        self.kilit = threading.Lock()


def _merkezi_icinde(k, kutular) -> bool:
    cx, cy = (k.x1 + k.x2) / 2.0, (k.y1 + k.y2) / 2.0
    return any(b[0] <= cx <= b[2] and b[1] <= cy <= b[3] for b in kutular)


def kutulari_bul(p, kirpik: np.ndarray, haric, oku_disari=()) -> list:
    """
    Kırpıntıdaki plaka kutuları; çoğu kesilen köşede kalanlar düşer.
    1.4.3 (PARK_GORUNUR): merkezi `oku_disari` kutularından birinin içindeki
    plaka (yürüyen bir izin tahmini yeri) alanın dışında da tutulur.
    """
    return [k for k in p.bul(kirpik)
            if plaka.haric_orani(k, haric) <= plaka.HARIC_DUSUR
            or _merkezi_icinde(k, oku_disari)]


def _iki_okuma(p, kirpik: np.ndarray, k, tam: np.ndarray | None):
    """Kutunun iki kırpıntı okuması; `tam` varsa ondan, kutu gerçek oranla taşınır."""
    if tam is None:
        return p.oku_cift(kirpik, k)
    h, w = kirpik.shape[:2]
    th, tw = tam.shape[:2]
    return p.oku_cift(tam, plaka.kutu_olcekle(k, tw / w, th / h))


def kutuyu_oku(p, kirpik: np.ndarray, k, haric, esik: float, tam: np.ndarray | None = None):
    """
    Tek kutunun iki kırpıntı okuması: (okumalar, emin) — emin = (metin, en
    düşük olasılık) ya da None. Kutu kesikse (kenara / kesilen köşeye değiyor)
    okuyucu hiç çağrılmaz; kesik ya da boşsa None döner.

    1.3.4: `tam` verilmişse (aynı kırpıntının küçültülmemiş hâli) plaka ONDAN
    okunur — kutu gerçek boyut oranıyla taşınır. Kesiklik kuralı yine küçük
    kırpıntının koordinatlarında (kutu orada bulundu, kesilen köşeler de orada).

    Köprü (kareyi_isle) ile `--plaka` test kipi bunu paylaşır: ikisi ayrışamaz.
    """
    h, w = kirpik.shape[:2]
    if not plaka.tam_mi(k, w, h, haric):
        return None
    okumalar = _iki_okuma(p, kirpik, k, tam)
    if len(okumalar) != 2:
        return None
    return okumalar, plaka.iki_kirpinti(okumalar[0], okumalar[1], esik)


class Kesik(NamedTuple):
    """1.4.3: plakalari_olc'de kesik kutunun okuması (yalnızca son çare tahmin)."""
    okumalar: list


def kesik_oku(p, kirpik: np.ndarray, k, haric, tam: np.ndarray | None = None):
    """
    1.4.3 (sahibin kararı 19.11): KESİK kutunun (kenara / kırpma alanının
    kenarına / kesilen köşeye değen) iki kırpıntı okuması; tam kutuda ya da
    boş okumada None. Sonuç ASLA oy değildir: yalnızca oylamanın
    `kesik_tahmin`ine gider (kartın tahmini). Sahada 19.11 14:53: plaka gri
    köşeye 1 px yakındı, okuyucu 0.997 okurdu, kart tahminsiz gitti.
    """
    h, w = kirpik.shape[:2]
    if plaka.tam_mi(k, w, h, haric):
        return None
    okumalar = _iki_okuma(p, kirpik, k, tam)
    return okumalar if len(okumalar) == 2 else None


def _onceden_vardi(k, arka_araclar: list) -> bool:
    """Bu kutu geçişten önceki karede AYNI YERDE duran bir araç mı?"""
    return any(arac.ortusme(k, a) >= AYNI_ARAC_ORTUSME for a in arka_araclar)


def kareyi_isle(p, gecis: Gecis, kirpik: np.ndarray, zaman, gorunum, haric,
                oku_esik: float, arka: bool = False, arac_kutulari=None,
                durgun: bool = False, tam: np.ndarray | None = None) -> None:
    """
    Bir kareyi okur ve sonucu geçişe yazar (işçi çağırır; testler de).
    `arac_kutulari(kirpik, haric)` → (araç kutuları, insan puanı) ya da None
    (ölçülemedi); verilmişse plaka işinden SONRA her karede çağrılır.

    1.3.2: geçişin karesinde yalnızca YENİ araç sayılır — geçişten önceki
    karede aynı yerde (örtüşme ≥ AYNI_ARAC_ORTUSME) duran araç sayılmaz.
    Sahada 2026-11-07: yavaş gelen araç önceki kareye uzaktayken girdi ve
    1.3.1 onu "zaten oradaydı" saydı; yaklaşınca başka yerdedir → yenidir.
    Önceki kare ölçülmeden işlenen karede ne yeni bilinmez: sayılmaz.
    """
    _plaka_isle(p, gecis, kirpik, zaman, gorunum, haric, oku_esik, arka, tam)
    if arac_kutulari is not None:
        araci_isle(gecis, kirpik, haric, arac_kutulari, arka=arka, durgun=durgun)


def araci_isle(gecis: Gecis, kirpik: np.ndarray, haric, arac_kutulari, *, arka: bool = False,
               durgun: bool = False) -> None:
    """Kareyi araç bulucuyla ölçer ve geçişe yazar (1.3.3: kendi iş parçacığında)."""
    olcum = arac_kutulari(kirpik, haric)
    if olcum is None:
        return
    kutular, insan = olcum
    with gecis.kilit:
        if arka:
            gecis.arka_araclar = list(kutular)
            return
        gecis.insan_max = insan if gecis.insan_max is None else max(gecis.insan_max, insan)
        if gecis.arka_araclar is None:
            return
        yeni = max((k.skor for k in kutular if not _onceden_vardi(k, gecis.arka_araclar)),
                   default=0.0)
        if gecis.arac_max is None or yeni > gecis.arac_max:
            gecis.arac_max = yeni
            gecis.arac_kirpik = kirpik
        if durgun:
            gecis.arac_durgun = yeni


def _plaka_isle(p, gecis: Gecis, kirpik: np.ndarray, zaman, gorunum, haric,
                oku_esik: float, arka: bool, tam: np.ndarray | None = None) -> None:
    kutular = kutulari_bul(p, kirpik, haric)
    if arka:
        with gecis.kilit:
            gecis.arka_plaka_sayisi = len(kutular)      # 1.3.2: yalnızca teşhis
            if kutular:
                gecis.arka_kutulu = True
        for k in kutular:
            sonuc = kutuyu_oku(p, kirpik, k, haric, ARKA_ESIK, tam=tam)
            if sonuc is not None and sonuc[1] is not None:
                with gecis.kilit:
                    gecis.arka_okunan.add(sonuc[1][0])
        return
    if not kutular:
        return
    # Kutu oyu okumadan ÖNCE yazılır: karar okuyucuyu beklerken süre dolarsa
    # "plaka görüldü" bilgisi yine geçişte olmalı.
    with gecis.kilit:
        gecis.oylama.kutu(zaman, gorunum)
        if gecis.kutulu is None or kutular[0].skor > gecis.kutulu[0]:
            gecis.kutulu = (kutular[0].skor, kirpik)
    for k in kutular:
        sonuc = kutuyu_oku(p, kirpik, k, haric, oku_esik, tam=tam)
        if sonuc is None:
            kesik = kesik_oku(p, kirpik, k, haric, tam=tam)        # 1.4.3: son çare tahmin
            if kesik is not None:
                with gecis.kilit:
                    gecis.oylama.kesik_tahmin(kesik[0][0], kesik[0][1])
            continue
        okumalar, iki = sonuc
        with gecis.kilit:
            if iki is not None:
                gecis.oylama.okuma(iki[0], iki[1], zaman, gorunum)
                _en_iyi_yaz(gecis, iki[0], iki[1], kirpik)
            else:
                gecis.oylama.tahmin(okumalar[0][0], okumalar[0][1])


# 1.4.3 (kontrol 20.11): en_iyi her FARKLI emin metin için bir kırpık (~3 MB)
# tutuyordu, sınırsız — bir gün park eden araçta yanlış okumalar yüzlerce
# kırpık demekti ve park belleği aynı Gecis'i taşır.
EN_IYI_EN_COK = 4


def _en_iyi_yaz(gecis: Gecis, metin: str, skor: float, kirpik: np.ndarray) -> None:
    """
    Metnin kanıt kırpığı: yeni metinse ya da skoru eskisini geçiyorsa yazılır
    (1.4.2 kuralı). `gecis.kilit` altında, oy YAZILDIKTAN sonra çağrılır.
    Sınır aşılırsa en az görünümlü metin düşer (tam + yarım oy, Oylama);
    görünüm eşitse en düşük skor, o da eşitse en eski. Yeni metnin kendisi de
    düşebilir. Düşen metin kazanırsa fotoğrafı _foto(gecis) olur (bugünkü gibi).
    """
    eski = gecis.en_iyi.get(metin)
    if eski is not None and skor <= eski[0]:
        return
    gecis.en_iyi[metin] = (skor, kirpik)
    if len(gecis.en_iyi) > EN_IYI_EN_COK:
        o = gecis.oylama
        dusen = min(gecis.en_iyi, key=lambda m: (o.gorunum_sayisi(m), gecis.en_iyi[m][0]))
        gecis.en_iyi.pop(dusen)


def plakalari_olc(p, kirpik: np.ndarray, haric, oku_esik: float,
                  tam: np.ndarray | None = None, *, maskesiz: bool = False,
                  oku_disari: tuple = ()) -> list:
    """
    1.4.0: bir karenin plaka ölçümleri [(kutu, kutuyu_oku sonucu | Kesik | None)] —
    kesik kutular da listede: "plaka görüldü" bilgisi oylamaya girer; 1.4.3:
    okunabildiyse Kesik(okumalar) ile (yalnızca son çare tahmin), yoksa None.
    Okuma kuralları geçişle AYNI yardımcılardan (kutulari_bul, kutuyu_oku, kesik_oku).

    1.4.3 (PARK_GORUNUR) `maskesiz`: kırpıntı maskelenmedi (alanın dışı gri
    değil, pikseller gerçek). Alanın kenarı artık plakayı kesmez (yalnızca
    kırpıntının kenarları keser); alanın çoğu dışındaki plaka yalnızca merkezi
    bir `oku_disari` kutusundaysa okunur. Maskeli kipte `oku_disari` yok sayılır.
    """
    disari = oku_disari if maskesiz else ()
    kesen = None if maskesiz else haric
    olcumler = []
    for k in kutulari_bul(p, kirpik, haric, disari):
        sonuc = kutuyu_oku(p, kirpik, k, kesen, oku_esik, tam=tam)
        if sonuc is None:
            kesik = kesik_oku(p, kirpik, k, kesen, tam=tam)        # 1.4.3: son çare tahmin
            sonuc = Kesik(kesik) if kesik is not None else None
        olcumler.append((k, sonuc))
    return olcumler


def plakalari_yaz(gecis: Gecis, kirpik: np.ndarray, zaman, gorunum, olcumler: list) -> None:
    """
    Bir izin bu karedeki plaka ölçümlerini oylamasına yazar. `_plaka_isle`nin
    (geçiş) yazımıyla birebir aynı sonuç (test_plakalari_yaz_plaka_isle_ile_ayni):
    önce "plaka görüldü" (kutu oyu), sonra her emin okuma ya da tahmin.
    """
    if not olcumler:
        return
    en_net = max(k.skor for k, _ in olcumler)
    with gecis.kilit:
        gecis.oylama.kutu(zaman, gorunum)
        if gecis.kutulu is None or en_net > gecis.kutulu[0]:
            gecis.kutulu = (en_net, kirpik)
    for _k, sonuc in olcumler:
        if isinstance(sonuc, Kesik):
            # 1.4.3: kesik kutu — oy değil, rakip değil; yalnızca son çare tahmin.
            with gecis.kilit:
                gecis.oylama.kesik_tahmin(sonuc.okumalar[0][0], sonuc.okumalar[0][1])
            continue
        if sonuc is None:
            continue
        okunan, emin = sonuc
        with gecis.kilit:
            # 1.4.1: iki kırpıntının da okuduğu her metin (birleşik kararda rakip).
            gecis.oylama.gorulen([m for m, _ in okunan])
            if emin is None:
                gecis.oylama.tahmin(okunan[0][0], okunan[0][1])
                # 1.4.1: iki kırpıntı AYNI metni, ikisi de ≥ YARIM_ESIK: yarım oy.
                if (len(okunan) == 2 and okunan[0][0] == okunan[1][0]
                        and min(okunan[0][1], okunan[1][1]) >= plaka.YARIM_ESIK):
                    dusuk = min(okunan[0][1], okunan[1][1])
                    gecis.oylama.yarim_oy(okunan[0][0], dusuk,
                                          max(okunan[0][1], okunan[1][1]), zaman, gorunum)
                    # Birleşik emin olursa kanıt fotoğrafı plakanın okunduğu kare.
                    _en_iyi_yaz(gecis, okunan[0][0], dusuk, kirpik)
                continue
            gecis.oylama.okuma(emin[0], emin[1], zaman, gorunum)
            _en_iyi_yaz(gecis, emin[0], emin[1], kirpik)


# ------------------------------------------------------------------- işçi ---

class KareIsi(NamedTuple):
    """1.4.0: izleme için bir kare — İKİ modelin sonucu birleşir (takip.Olcum)."""
    no: int
    mono: float
    gri: np.ndarray          # 160×120 gri (izcinin "yerel fark"ı)
    # 1.4.3 (PARK_GORUNUR): alanın dışındaki plakanın okunabileceği kutular
    # (Takipci.okunacak_kutular). Yalnızca `Is.acik` verilmişse kullanılır.
    oku_disari: tuple = ()
    # 1.4.3 (PARK_GORUNUR): maskesiz kırpıntının grisi — izcinin piksel ölçüsü
    # (durdu mu, yeni görünüm mü) alanın dışında da gerçek piksellere baksın.
    # `gri` (maskeli) köprünün hareket tetiği olarak kalır (Olcum.tetik_gri).
    acik_gri: np.ndarray | None = None


class Is(NamedTuple):
    gecis: Gecis
    kirpik: np.ndarray       # sahibi işçi: döngü KOPYASINI verir
    zaman: object
    gorunum: int
    arka: bool = False
    durgun: bool = False     # aracın durduğu kare (araç bulucu ayrıca saklar)
    # 1.3.4: aynı kırpıntının KÜÇÜLTÜLMEMİŞ hâli (plaka buradan okunur); None =
    # kırpıntı küçültülmedi ya da PLAKA_TAM=0. Sahibi işçi: döngü KOPYASINI verir.
    tam: np.ndarray | None = None
    # 1.4.0: izleme karesi (gecis None). Verilmişse iki modelin sonucu
    # birleşir ve biten_kareler() ile döngüye döner; geçişe hiçbir şey yazılmaz.
    kare: KareIsi | None = None
    # 1.4.3 (PARK_GORUNUR): izleme karesinin MASKESİZ kırpıntısı. Verilmişse
    # iki model bunu görür (araç bulucu alan dışını atmaz, plaka maskesiz
    # kuralla okunur); `kirpik` maskeli kalır ve Olcum'a (fotoğrafa) o gider.
    # Sahibi işçi: döngü KOPYASINI verir.
    acik: np.ndarray | None = None


# Öncelikli işler sırayla tutulur: geçişten önceki kare ve durulan kare.
# Tek yer olsaydı çok kısa bir geçişte durulan kare, işlenmemiş önceki kareyi
# ezerdi (1.3.3).
ONCELIK_EN_COK = 2


class _Kuyruk:
    """Bir modelin işleri: tek yer (en yeni kare kazanır) + sıralı öncelikliler."""

    def __init__(self) -> None:
        self.slot: Is | None = None
        self.oncelik: list[Is] = []
        self.calisan: Is | None = None
        self.basladi: float | None = None
        self.ort_sure: float | None = None       # bir işin süresi (üstel ortalama, sn)

    def koy(self, is_: Is, oncelik: bool) -> None:
        if oncelik:
            # En yeni ONCELIK_EN_COK iş, geliş sırasıyla.
            self.oncelik = (self.oncelik + [is_])[-ONCELIK_EN_COK:]
        else:
            self.slot = is_

    def al(self) -> Is | None:
        if self.oncelik:
            return self.oncelik.pop(0)
        is_, self.slot = self.slot, None
        return is_

    def bos(self) -> bool:
        return self.slot is None and not self.oncelik and self.calisan is None

    def bekleyen(self, gecis: Gecis) -> bool:
        return any(i is not None and i.gecis is gecis
                   for i in (self.slot, self.calisan, *self.oncelik))

    def temizle(self) -> None:
        self.slot = None
        self.oncelik = []

    def bitti(self) -> None:
        if self.basladi is not None:
            s = time.monotonic() - self.basladi
            self.ort_sure = s if self.ort_sure is None else 0.8 * self.ort_sure + 0.2 * s
        self.calisan = None
        self.basladi = None


class Isci:
    """
    Modelleri yakalama döngüsünden AYRI iş parçacıklarında çalıştırır.
    `plakaci` None ise (modeller yüklenemedi) baştan bozuktur ve iş almaz —
    köprü yine çalışır, araçlar personele gider.

    1.3.3: plaka okuyucu ve araç bulucu (`arac`, 1.3.1) AYRI iş parçacıklarında
    AYNI ANDA çalışır; her birinin kendi kuyruğu vardır. Plaka okuma araç
    bulucuyu hiç beklemez (sırayla sahada 410 ms/kare idi); araç bulucu
    yetişemezse en yeni kareye atlar, öncelikli kareleri (önceki / durulan)
    yine sırayla alır. Araç bulucunun hataları plaka okuyucusundan AYRI sayılır.
    """

    def __init__(self, plakaci, haric, oku_esik: float, kayit=None, sebep: str | None = None,
                 arac=None, saat=None):
        self._p = plakaci
        self.haric = haric
        self.oku_esik = oku_esik
        self._kayit = kayit or (lambda s: print(s, flush=True))
        self.bozuk: str | None = sebep if plakaci is None else None
        self._arac = arac
        self.arac_bozuk: str | None = None
        self._arac_ardisik = 0
        # 1.4.3: çalışırken bozulanın yeniden denenmesi (yüklenemeyen model
        # denenmez — `sebep` ile başlayan okuyucunun _bozuk_an'ı yok).
        self._saat = saat or time.monotonic
        self._bozuk_an: float | None = None
        self._bozuk_bekle = YENIDEN_DENE_SN
        self._denemede = False
        self._arac_bozuk_an: float | None = None
        self._arac_bekle = YENIDEN_DENE_SN
        self._arac_denemede = False
        self._kosul = threading.Condition()
        self._plaka_k = _Kuyruk()
        self._arac_k = _Kuyruk() if arac is not None else None
        self._ardisik = 0
        self._dur = False
        self.islenen = 0
        # 1.4.0: yarım kalan izleme kareleri (no → parçalar) ve bitenler.
        self._yarim: dict[int, dict] = {}
        self._biten: list = []
        self._ip = threading.Thread(target=self._plaka_dongu, daemon=True, name="plaka")
        self._ip.start()
        if self._arac_k is not None:
            threading.Thread(target=self._arac_dongu, daemon=True, name="arac").start()

    def _kuyruklar(self) -> list[_Kuyruk]:
        return [k for k in (self._plaka_k, self._arac_k) if k is not None]

    # ------------------------------------------------------------ döngü tarafı -

    def bos_mu(self) -> bool:
        """Plaka okuyucu boşta ve kutusu boş mu? (Döngü kareyi ancak o zaman kopyalar.)"""
        with self._kosul:
            return self._plaka_k.bos()

    def _yeniden_dene_belki(self) -> None:
        """1.4.3: bozulalı yeterince olduysa bu iş bir deneme olur (kilit altında)."""
        simdi = self._saat()
        if (self.bozuk is not None and self._p is not None and self._bozuk_an is not None
                and simdi - self._bozuk_an >= self._bozuk_bekle):
            self.bozuk = None
            self._ardisik = ARDISIK_HATA - 1          # tek hata yeniden bozar
            self._denemede = True
        if (self.arac_bozuk is not None and self._arac is not None
                and self._arac_bozuk_an is not None
                and simdi - self._arac_bozuk_an >= self._arac_bekle):
            self.arac_bozuk = None
            self._arac_ardisik = ARDISIK_HATA - 1
            self._arac_denemede = True

    def ver(self, is_: Is, oncelik: bool = False) -> None:
        with self._kosul:
            self._yeniden_dene_belki()
            if self.bozuk is not None or self._dur:
                return
            if is_.kare is not None:
                # Ezilecek yarım izleme karesi bir daha birleşemez: bırakılır.
                for k in self._kuyruklar():
                    if not oncelik and k.slot is not None and k.slot.kare is not None:
                        self._yarim.pop(k.slot.kare.no, None)
                bulucu = self._arac_k is not None and self.arac_bozuk is None
                self._yarim[is_.kare.no] = {"is": is_, "plaka": None, "arac": None,
                                            "bekle": {"plaka", "arac"} if bulucu else {"plaka"}}
            self._plaka_k.koy(is_, oncelik)
            if self._arac_k is not None and self.arac_bozuk is None:
                self._arac_k.koy(is_, oncelik)
            self._kosul.notify_all()

    def ikisi_bos(self) -> bool:
        """1.4.0: İKİ model de boşta mı? İzleme yeni kareyi ancak o zaman verir
        (bir karenin iki sonucu birleşmeli; bos_mu yalnızca plakaya bakar)."""
        with self._kosul:
            kuyruklar = self._kuyruklar()
            return all(k.bos() for k in kuyruklar)

    def biten_kareler(self) -> list:
        """İki modeli de biten izleme kareleri (takip.Olcum), kare sırasıyla."""
        with self._kosul:
            sonuc = sorted(self._biten, key=lambda o: o.no)
            self._biten = []
        return sonuc

    def _parca_bitti(self, no: int, ad: str, sonuc) -> None:
        """Bir modelin kare sonucu (kilit ALTINDA). İkisi de gelince kare biter."""
        e = self._yarim.get(no)
        if e is None or ad not in e["bekle"]:
            return
        e[ad] = sonuc
        e["bekle"].discard(ad)
        if e["bekle"]:
            return
        self._yarim.pop(no, None)
        is_ = e["is"]
        araclar = None if e["arac"] is None else list(e["arac"][0])
        k = is_.kare
        self._biten.append(takip.Olcum(k.no, k.mono, is_.zaman, is_.kirpik,
                                       k.gri if k.acik_gri is None else k.acik_gri,
                                       araclar, e["plaka"], k.gri))

    def _arac_parcasi_yok(self) -> None:
        """Bulucu bozuldu (kilit ALTINDA): bekleyen kareler araçsız biter."""
        for no in list(self._yarim):
            self._parca_bitti(no, "arac", None)

    def _bekleyen(self, gecis: Gecis) -> bool:
        return any(k.bekleyen(gecis) for k in self._kuyruklar())

    def bekle(self, gecis: Gecis, sn: float) -> bool:
        """Bu geçişin İKİ modeldeki bekleyen ve süren işi bitene kadar (en çok `sn`)."""
        bitis = time.monotonic() + sn
        with self._kosul:
            while self._bekleyen(gecis):
                kalan = bitis - time.monotonic()
                if kalan <= 0:
                    return False
                self._kosul.wait(kalan)
            return True

    def bekleme_suresi(self, taban: float) -> float:
        """Karar bu geçişin işlerini en çok ne kadar beklesin (sn) — yavaş modele göre."""
        with self._kosul:
            sureler = [k.ort_sure for k in self._kuyruklar() if k.ort_sure is not None]
        sure = taban if not sureler else max(taban, BEKLE_KAT * max(sureler))
        return min(sure, BEKLE_TAVAN_SN)

    def sure_ozeti(self) -> str:
        """1.4.2: kalp satırı için " · plaka 35 ms, araç 40 ms" (ölçülmediyse "")."""
        with self._kosul:
            sureler = [(ad, k.ort_sure) for ad, k in (("plaka", self._plaka_k), ("araç", self._arac_k))
                       if k is not None and k.ort_sure is not None]
        if not sureler:
            return ""
        return " · " + ", ".join(f"{ad} {s * 1000:.0f} ms" for ad, s in sureler)

    def takildi(self, simdi: float, sinir: float) -> bool:
        with self._kosul:
            return any(k.basladi is not None and simdi - k.basladi > sinir
                       for k in self._kuyruklar())

    def durdur(self) -> None:
        with self._kosul:
            self._dur = True
            self._kosul.notify_all()

    def arac_esikleri(self) -> tuple[float, float] | None:
        """
        (duran eşiği, geçen eşiği) — araç bulucu kullanılabiliyorsa; yoksa
        None ve karar 1.3.0 kuralına döner.
        """
        if self._arac is None or self.arac_bozuk is not None or self.bozuk is not None:
            return None
        return float(self._arac.esik), float(self._arac.gecis_esik)

    def _arac_kutulari(self, kirpik: np.ndarray, haric):
        """Araç bulucuyu çalıştırır (hataları _arac_dongu sayar — tek yerde)."""
        if self.arac_bozuk is not None:
            return None
        return self._arac.kutular(kirpik, haric)

    # ------------------------------------------------------------ işçi tarafı --

    def _sonraki(self, kuyruk: _Kuyruk) -> Is | None:
        """Kuyruktan sıradaki iş (kilit ALTINDA çağrılır); durdurulduysa None."""
        while not self._dur and kuyruk.slot is None and not kuyruk.oncelik:
            self._kosul.wait()
        if self._dur:
            return None
        is_ = kuyruk.al()
        kuyruk.calisan = is_
        kuyruk.basladi = time.monotonic()
        return is_

    def _plaka_dongu(self) -> None:
        while True:
            with self._kosul:
                is_ = self._sonraki(self._plaka_k)
            if is_ is None:
                return
            olcum = None                   # 1.4.0 izleme karesinin plaka sonucu
            try:
                if is_.kare is not None and is_.acik is not None:
                    olcum = plakalari_olc(self._p, is_.acik, self.haric, self.oku_esik, is_.tam,
                                          maskesiz=True, oku_disari=is_.kare.oku_disari)
                elif is_.kare is not None:
                    olcum = plakalari_olc(self._p, is_.kirpik, self.haric, self.oku_esik, is_.tam)
                else:
                    _plaka_isle(self._p, is_.gecis, is_.kirpik, is_.zaman, is_.gorunum,
                                self.haric, self.oku_esik, is_.arka, is_.tam)
                self._ardisik = 0
                if self._denemede:                                  # 1.4.3
                    self._denemede, self._bozuk_bekle = False, YENIDEN_DENE_SN
                    self._kayit(f"[i] {OKUYUCU_DONDU_ISARETI}")
            except Exception as e:  # noqa: BLE001 — bir kare okuyucuyu öldürmesin
                self._ardisik += 1
                if self._ardisik >= ARDISIK_HATA and self.bozuk is None:
                    self.bozuk = f"{type(e).__name__}: {e}"
                    if self._denemede:                              # 1.4.3
                        self._bozuk_bekle = min(self._bozuk_bekle * 2, YENIDEN_DENE_TAVAN_SN)
                    self._bozuk_an = self._saat()
                    self._kayit(f"[!] {OKUYUCU_BOZUK_ISARETI}: {self.bozuk} — araçlar "
                                f"personele gidecek ({self._bozuk_bekle:.0f} sn sonra "
                                "yeniden denenecek)")
            finally:
                with self._kosul:
                    if is_.kare is not None:
                        self._parca_bitti(is_.kare.no, "plaka", olcum)
                    self._plaka_k.bitti()
                    self.islenen += 1
                    if self.bozuk is not None:
                        # Okuyucu bozuksa araç bulucu da durur (1.3.0 kuralı).
                        for k in self._kuyruklar():
                            k.temizle()
                        self._yarim.clear()       # köprü izlemeyi bırakır (1.3.4'e döner)
                    self._kosul.notify_all()

    def _arac_dongu(self) -> None:
        while True:
            with self._kosul:
                is_ = self._sonraki(self._arac_k)
            if is_ is None:
                return
            olcum = None                   # 1.4.0 izleme karesinin araç sonucu
            try:
                if is_.kare is not None and is_.acik is not None:
                    olcum = self._arac_kutulari(is_.acik, None)       # 1.4.3: PARK_GORUNUR
                elif is_.kare is not None:
                    olcum = self._arac_kutulari(is_.kirpik, self.haric)
                else:
                    araci_isle(is_.gecis, is_.kirpik, self.haric, self._arac_kutulari,
                               arka=is_.arka, durgun=is_.durgun)
                self._arac_ardisik = 0
                if self._arac_denemede:                             # 1.4.3
                    self._arac_denemede, self._arac_bekle = False, YENIDEN_DENE_SN
                    self._kayit(f"[i] {ARAC_DONDU_ISARETI}")
            except Exception as e:  # noqa: BLE001 — bulucu okuyucuyu öldürmesin
                self._arac_ardisik += 1
                if self._arac_ardisik >= ARDISIK_HATA and self.arac_bozuk is None:
                    self.arac_bozuk = f"{type(e).__name__}: {e}"
                    if self._arac_denemede:                         # 1.4.3
                        self._arac_bekle = min(self._arac_bekle * 2, YENIDEN_DENE_TAVAN_SN)
                    self._arac_bozuk_an = self._saat()
                    self._kayit(f"[!] {ARAC_BOZUK_ISARETI}: {self.arac_bozuk} — plakasız "
                                "araçlar 1.3.0 kuralıyla personele gidecek "
                                f"({self._arac_bekle:.0f} sn sonra yeniden denenecek)")
            finally:
                with self._kosul:
                    if is_.kare is not None:
                        self._parca_bitti(is_.kare.no, "arac", olcum)
                    self._arac_k.bitti()
                    if self.arac_bozuk is not None or self.bozuk is not None:
                        self._arac_k.temizle()
                        self._arac_parcasi_yok()
                    self._kosul.notify_all()


# ------------------------------------------------------------------ karar ---

class Gonderim(NamedTuple):
    tur: str                       # "PLAKA" | "OKUNAMADI"
    plaka: str | None
    tahmin: str | None
    guven: float | None
    zaman: object
    kirpik: np.ndarray | None
    # 1.4.2 (B5): izcinin gördüğü yön — "GIRDI" | "CIKTI" | "ICERIDE" | None.
    # Köprü olayın türünden ekler (iz_karari koymaz); yalnızca PLAKA ile gider.
    hareket: str | None = None
    # 1.4.3 (sahibin kararı 17.11): tek kapıda yönü bilinmeyen olayın emin
    # plakası — kart yerine PLAKA gider, sunucu bu işaretle kaydeder.
    yon_bilinmiyor: bool = False


def gonderim_kaydi(g: Gonderim, simdi: float) -> tuple[str | None, float, bool, str | None]:
    """
    1.4.3: 60 sn belleğinin kaydı — gönderilen plaka ya da tahmin, an, emin mi,
    yön ipucu (içeride sorusu ÇIKTI kaydına takılmasın diye, 18.11).
    """
    return (g.plaka or g.tahmin, simdi, g.plaka is not None, g.hareket)


def _foto(gecis: Gecis) -> np.ndarray | None:
    if gecis.kutulu is not None:
        return gecis.kutulu[1]
    return gecis.durgun_kirpik if gecis.durgun_kirpik is not None else gecis.son_kirpik


def _puanlar(arac: float | None, insan: float | None) -> str:
    a = "?" if arac is None else f"{arac:.2f}"
    i = "?" if insan is None else f"{insan:.2f}"
    return f"araç {a}, insan {i}"


def karar_ver(gecis: Gecis, *, durdu: bool, arac_boyu: bool, ayrilis_sahne: bool,
              son_durdu_plaka: str | None, bozuk: bool,
              son_gonderilen: list, simdi: float,
              arac_esik: float | None = None,
              arac_gecis_esik: float | None = None) -> tuple[list[Gonderim], list[str]]:
    """
    (gönderilecekler, kayıt satırları). `son_gonderilen`: [(plaka, monotonic)].
    `son_durdu_plaka`: duran olarak gönderilmiş son aracın plakası (ayrılış).
    `arac_esik` / `arac_gecis_esik` (1.3.1): araç bulucu kullanılabiliyorsa
    eşikleri; None ise kararlar 1.3.0 ile birebir aynıdır. 1.3.2'den beri
    plakasız geçişte yalnızca YENİ araçlara bakılır (kareyi_isle).
    """
    satirlar: list[str] = []
    with gecis.kilit:
        k = gecis.oylama.karar()
        en_iyi = dict(gecis.en_iyi)
        arka = set(gecis.arka_okunan)
        arka_kutulu = gecis.arka_kutulu
        arac_max, arac_durgun = gecis.arac_max, gecis.arac_durgun
        insan_max, arac_kirpik = gecis.insan_max, gecis.arac_kirpik
        arka_araclar, arka_plaka = gecis.arka_araclar, gecis.arka_plaka_sayisi
    bulucu = arac_esik is not None and arac_gecis_esik is not None
    # 1.3.2: kurallar ancak geçişten önceki kare ölçüldüyse "yeni araç"
    # bilir; değilse (ya da bulucu yoksa) 1.3.0 kuralı.
    yere_bakar = bulucu and arka_araclar is not None
    ayrilis = ayrilis_sahne or (son_durdu_plaka is not None
                                and any(_yakin(son_durdu_plaka, a) for a in arka))

    def yeni_gitti(p: str | None, yalniz_emin: bool = False) -> bool:
        return _yeni_gitti(p, son_gonderilen, simdi, yalniz_emin=yalniz_emin)

    if bozuk and not k.eminler:
        if arac_boyu and not ayrilis:
            satirlar.append(f"[!] {OKUYUCU_BOZUK_ISARETI} — araç personele bırakılıyor")
            return [Gonderim("OKUNAMADI", None, None, None, gecis.baslangic, _foto(gecis))], satirlar
        return [], satirlar

    gonder: list[Gonderim] = []
    for e in k.eminler:
        if ayrilis and _yakin(son_durdu_plaka, e.metin):
            satirlar.append(f"[i] {AYRILIS_ISARETI}")
            continue
        if yeni_gitti(e.metin, yalniz_emin=True):
            satirlar.append(f"[i] {AYRILIS_ISARETI} (60 sn içinde aynı plaka)")
            continue
        foto = en_iyi.get(e.metin, (None, _foto(gecis)))[1]
        gonder.append(Gonderim("PLAKA", e.metin, None, None, e.zaman, foto))

    if k.belirsiz is not None:
        if ayrilis:
            satirlar.append(f"[i] {AYRILIS_ISARETI}")
        elif yeni_gitti(k.belirsiz.tahmin):
            satirlar.append(f"[i] {AYRILIS_ISARETI} (60 sn içinde aynı plaka)")
        else:
            gonder.append(Gonderim("OKUNAMADI", None, k.belirsiz.tahmin, k.belirsiz.guven,
                                   k.belirsiz.zaman, _foto(gecis)))
    elif not k.eminler:
        if ayrilis:
            satirlar.append(f"[i] {AYRILIS_ISARETI}")
        elif yere_bakar:
            # 1.3.2 (sahada 2026-11-07 akşamı iki araç kayıtsız geçti): YALNIZCA
            # yeni araç sayılır (kareyi_isle); 1.3.0'ın gidiş kuralı (önceki
            # karede plaka kutusu) burada KULLANILMAZ — onu yavaş gelen araç
            # tetikledi. Gönderilmiş aracın gidişi `ayrilis`le zaten kapalı.
            once = (f"önce: {len(arka_araclar)} araç, "
                    f"{'?' if arka_plaka is None else arka_plaka} plaka kutusu")
            if not arac_boyu:
                satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare) — "
                                f"{_puanlar(arac_max, insan_max)}; {once}")
            elif durdu and arac_durgun is not None and arac_durgun >= arac_esik:
                # Kural 1: durulan karede yeni araç → personele.
                satirlar.append(f"[i] plakasız araç durdu — personele "
                                f"({_puanlar(arac_durgun, insan_max)}; {once})")
                gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic,
                                       _foto(gecis)))
            elif arac_max is not None and arac_max >= arac_gecis_esik:
                # Kural 2: geçişte NET yeni araç (durdu ya da durmadı — "durdu"
                # sahada yanıldı) → personele, aracın en iyi göründüğü kareyle.
                satirlar.append(f"[i] {PLAKASIZ_ARAC_ISARETI} — personele "
                                f"({_puanlar(arac_max, insan_max)}; {once})")
                foto = arac_kirpik if arac_kirpik is not None else _foto(gecis)
                gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic, foto))
            elif durdu and arac_durgun is None:
                # Durulan kare ölçülemedi: kaçırmak yerine personele.
                satirlar.append(f"[i] {ARAC_YETISMEDI_ISARETI} — personele ({once})")
                gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic,
                                       _foto(gecis)))
            else:
                # Kural 3: yeni araç yok (insanlar, gölge, park etmiş araç).
                satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare) — "
                                f"{ARAC_YOK_ISARETI} ({_puanlar(arac_max, insan_max)}; {once})")
        elif durdu and arac_boyu and not arka_kutulu:
            # 1.3.0 kuralı (bulucu yok / bozuk / kapalı, ya da önceki kare
            # ölçülmedi). Geçişten önce kadrajda plakalı bir araç VARDIYSA ve
            # şimdi hiç plaka yoksa değişen şey o aracın GİDİŞİdir (test_kopru
            # `kuyruk`): personele yazılmaz.
            gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic, _foto(gecis)))
        else:
            ek = "" if arac_max is None else f" — {_puanlar(arac_max, insan_max)}"
            satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare){ek}")

    gonder.sort(key=lambda g: g.zaman)
    return gonder, satirlar


def emin_plakalar(gecis: Gecis) -> set[str]:
    """1.4.3 (1a): izin emin plakaları (Oylama.karar yalnızca okur)."""
    with gecis.kilit:
        return {e.metin for e in gecis.oylama.karar().eminler}


IKI_PLAKA_SATIRI = "iki plaka tek izde — iki araç karışmış olabilir, personele"


def iz_personele(tur: str) -> bool:
    """
    Plakası emin okunsa da personele giden izleme olayı mı: açılışta kapıda
    olan araç (ESKI_GIRDI — dışarıdan mı geldi bilinmez) ve 1.4.1'den beri
    yalnızca TEK karede görülen araç (TEK_KARE — hangi yöne gitti bilinmez);
    1.4.2'den beri kapı alanında kararsız kaybolan araç (KAPIDA_KAYBOLDU —
    kapıda doğdu, otoparkta hiç görülmedi: girdi mi çıktı mı bilinmez).
    """
    return tur in ("ESKI_GIRDI", "TEK_KARE", "KAPIDA_KAYBOLDU")


# 1.4.1 kurulum yardımı: sektörün tek sıra plaka genişliği (Axis en az 130 px;
# Dahua 130–170, en iyi 140–160). `--plaka` ölçer, kamera yakınlaştırması buna göre.
PLAKA_EN_AZ_PX = 130
PLAKA_EN_IYI_PX = (140, 160)


def plaka_genisligi_tam(k, kirpik_en: int, tam_en: int | None) -> float:
    """Plaka kutusunun TAM çözünürlükteki genişliği (kutu küçültülmüş kırpıntıda bulunur)."""
    en = float(k.x2 - k.x1)
    return en * tam_en / kirpik_en if tam_en else en


def plaka_boyu_ozeti(genislikler: list[float]) -> str | None:
    """`--plaka` sonundaki plaka genişliği satırı (ortanca); ölçüm yoksa None."""
    if not genislikler:
        return None
    s = sorted(genislikler)
    orta = s[len(s) // 2] if len(s) % 2 else (s[len(s) // 2 - 1] + s[len(s) // 2]) / 2
    alt, ust = PLAKA_EN_IYI_PX
    if orta < PLAKA_EN_AZ_PX:
        return (f"Plaka genişliği: ortanca {orta:.0f} px — AZ (en az {PLAKA_EN_AZ_PX}, en iyi "
                f"{alt}–{ust} px). Kamerayı aracın durduğu yere yakınlaştırın.")
    return f"Plaka genişliği: ortanca {orta:.0f} px — yeterli ({alt}–{ust} px önerilir)."


def sinif_eki(sinif: int | None) -> str:
    """1.4.3: kayıt satırında puanın ardına " motosiklet" gibi; bilinmiyorsa ""."""
    ad = arac.SINIF_ADLARI.get(sinif) if sinif is not None else None
    return f" {ad}" if ad else ""


def iz_arac_esigi(tur: str, arac_esik: float, arac_gecis_esik: float,
                  komsu: bool = False, sinif: int | None = None,
                  moto_esik: float | None = None) -> float:
    """
    1.4.1: plakası hiç okunamayan aracın personele gitmesi için gereken araç
    puanı. İzleyicinin KAPIDAN geçtiğini gördüğü araç (GIRDI / CIKTI) izin
    doğum eşiğinden (ARAC_BUL_ESIK, 0.35) gider — sahada 2026-11-10 gerçek
    araçlar 0.46 / 0.54 ile düşüyordu; insanlar sahadaki fotoğraflarda en çok
    0.27 aldı. 1.4.2: kapı alanında kaybolan araç (KAPIDA_KAYBOLDU) da kapıda
    görüldü — aynı eşik; tek karede kapıda / yakınında görülen hareketli araç
    (TEK_KARE) da — sahada 11.11 13:52 araç 0.49 ile hiçbir şey gönderilmedi.
    Ama `komsu` (iz doğarken yanında başka araç izi vardı: alt kenardan çıkan
    aracın kuyruğu ayrı tek kare olabilir) TEK_KARE 1.4.1 gibi 0.60'ta kalır.
    Kapı kanıtı olmayan olaylar ARAC_GECIS_ESIK'te (0.60) kalır.
    1.4.3 (sahibin kararı 20.11): yönü bilinmeyen kapı olayı (TEK_KARE /
    KAPIDA_KAYBOLDU) puanını MOTOSİKLETTEN (`sinif`, izin en iyi kutusu)
    alıyorsa en az `moto_esik` ister (YOLO11s 0.60; tiny'de None = kural yok).
    19.11'de el arabası iten kişi bu olaylarla 5 kart oldu (0.37-0.52).
    """
    if tur == "TEK_KARE" and komsu:
        esik = arac_gecis_esik
    elif tur in ("GIRDI", "CIKTI", "KAPIDA_KAYBOLDU", "TEK_KARE"):
        esik = arac_esik
    else:
        esik = arac_gecis_esik
    if (moto_esik is not None and sinif == arac.MOTOSIKLET
            and tur in ("TEK_KARE", "KAPIDA_KAYBOLDU")):
        esik = max(esik, moto_esik)
    return esik


def iz_karari(gecis: Gecis, *, olay_zamani, son_gonderilen: list, simdi: float,
              arac_gecis_esik: float, personele: bool = False, tek_kapi: bool = False,
              iceride: bool = False) -> tuple[list[Gonderim], list[str]]:
    """
    1.4.0: BİR izin (aracın) kararı — izci "girdi / çıktı / durdu" dediğinde.
    Zaman OLAYIN anıdır (kapıdan çıktığı / son görüldüğü an), plakanın ilk
    okunduğu an değil: saatlerce duran aracın çıkışı eski zamanla gitmesin.

      · Tek emin plaka → PLAKA (60 sn kuralı geçişteki gibi).
      · Bir izde iki FARKLI emin plaka → iki araç karışmış olabilir: personele,
        plaka GÖNDERİLMEZ (yanlış araca bilet olmasın).
      · Emin plaka yok, belirsiz okuma (ya da okunamayan plaka kutuları) →
        tahminle personele.
      · Plaka hiç görülmedi: araç puanı ≥ arac_gecis_esik ise personele (en
        iyi göründüğü kareyle), değilse yalnızca kayıt.
    `personele`: emin plaka da olsa personele (ısınmada kapıda olan araç —
    dışarıdan mı geldi bilinmez); plaka tahmin olarak gider.
    1.4.3 `tek_kapi` (sahibin kararı 17.11): `personele` olayın emin plakası
    tek kapıda kart OLMAZ — PLAKA, yön ipucusuz, `yon_bilinmiyor` işaretli
    gider (sunucu bilet durumundan karar verir; 60 sn kuralı aynen). Belirsiz
    ve plakasız araç yine kart.
    1.4.3 `iceride` (sahibin kararı 18.11): içeride sorusu — emin plaka, az
    önce ÇIKTI ipucuyla gönderilmiş kayda takılmaz (`_yeni_gitti`).
    Kayıt satırlarına plaka YAZILMAZ.
    """
    satirlar: list[str] = []
    with gecis.kilit:
        k = gecis.oylama.karar()
        en_iyi = dict(gecis.en_iyi)
    arac_max = getattr(gecis, "arac_max", None)
    arac_kirpik = getattr(gecis, "arac_kirpik", None)
    foto = _foto(gecis)

    if len(k.eminler) >= 2:
        e = k.eminler[0]
        satirlar.append(f"[i] {IKI_PLAKA_SATIRI}")
        return [Gonderim("OKUNAMADI", None, e.metin, e.guven, olay_zamani,
                         en_iyi.get(e.metin, (None, foto))[1])], satirlar
    if k.eminler:
        e = k.eminler[0]
        if e.birlesik:
            satirlar.append(f"[i] {BIRLESIK_ISARETI}")
        if k.belirsiz is not None:
            satirlar.append("[i] emin plakanın yanındaki belirsiz okuma yok sayıldı")
        if personele and not tek_kapi:
            return [Gonderim("OKUNAMADI", None, e.metin, e.guven, olay_zamani,
                             en_iyi.get(e.metin, (None, foto))[1])], satirlar
        if _yeni_gitti(e.metin, son_gonderilen, simdi, yalniz_emin=True, cikti_haric=iceride):
            satirlar.append(f"[i] {AYRILIS_ISARETI} (60 sn içinde aynı plaka)")
            return [], satirlar
        if personele:
            satirlar.append(f"[i] {YON_BILINMIYOR_ISARETI}")
        return [Gonderim("PLAKA", e.metin, None, None, olay_zamani,
                         en_iyi.get(e.metin, (None, foto))[1],
                         yon_bilinmiyor=personele)], satirlar
    if k.belirsiz is not None:
        if not personele and _yeni_gitti(k.belirsiz.tahmin, son_gonderilen, simdi):
            satirlar.append(f"[i] {AYRILIS_ISARETI} (60 sn içinde aynı plaka)")
            return [], satirlar
        return [Gonderim("OKUNAMADI", None, k.belirsiz.tahmin, k.belirsiz.guven,
                         olay_zamani, foto)], satirlar
    puan = "?" if arac_max is None else f"{arac_max:.2f}"
    puan += sinif_eki(getattr(gecis, "arac_sinif", None))          # 1.4.3
    if arac_max is not None and arac_max >= arac_gecis_esik:
        satirlar.append(f"[i] {PLAKASIZ_ARAC_ISARETI} — personele (araç {puan})")
        return [Gonderim("OKUNAMADI", None, None, None, olay_zamani,
                         arac_kirpik if arac_kirpik is not None else foto)], satirlar
    satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare) — "
                    f"{ARAC_YOK_ISARETI} (araç {puan})")
    return [], satirlar
