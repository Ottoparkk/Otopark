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
  · Duran, araç boyunda, plakasız şey: durduğu karede araç yoksa (ve geçişte
    önceden olmayan net bir araç da görülmediyse) personele GİTMEZ — duran
    insanlar. Durduğu kare ölçülemediyse 1.3.0 kuralı (personele).
  · Durmadan geçen, plakası hiç okunamayan, NET bir araç (geçişten önce
    orada olmayan) da personele gider (1.3.0'da sessizce düşüyordu).
  · Bulucu yok / bozuk / kapalı: kararlar 1.3.0 ile birebir aynı.
"""
from __future__ import annotations

import threading
import time
from typing import NamedTuple

import numpy as np

import gunluk
import plaka

AYRILIS_ISARETI = gunluk.AYRILIS_ISARETI
PLAKASIZ_ISARETI = gunluk.PLAKASIZ_ISARETI
OKUYUCU_BOZUK_ISARETI = gunluk.OKUYUCU_BOZUK_ISARETI
ARAC_BOZUK_ISARETI = gunluk.ARAC_BOZUK_ISARETI
ARAC_YOK_ISARETI = gunluk.ARAC_YOK_ISARETI
ARAC_YETISMEDI_ISARETI = gunluk.ARAC_YETISMEDI_ISARETI
PLAKASIZ_ARAC_ISARETI = gunluk.PLAKASIZ_ARAC_ISARETI

# 1.3.1: karar, durulan karenin sonucunu işçinin ölçülen kare süresinin bu
# katı kadar bekler (bir süren iş + durulan kare ≈ 2 kare), en az
# PLAKA_BEKLE_SN, en çok BEKLE_TAVAN_SN (o sırada yakalama döngüsü bekler).
BEKLE_KAT = 2.5
BEKLE_TAVAN_SN = 2.0

# Arka plan (geçişten önceki durgun kare) okuması: ayrılışı tanımak için, oy değil.
ARKA_ESIK = 0.80
ARDISIK_HATA = 3
YAKIN_SN = 60.0


def _yakin(a: str | None, b: str | None) -> bool:
    return a is not None and b is not None and (a == b or plaka.bir_fark(a, b))


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
        # 1.3.1 araç bulucu: None = ÖLÇÜLMEDİ (bulucu yok, iş yetişmedi).
        self.arac_max: float | None = None          # geçişin karelerinde en yüksek
        self.arac_kirpik: np.ndarray | None = None  # o karenin kendisi (fotoğraf)
        self.arac_durgun: float | None = None       # durulan karede
        self.arac_arka: float | None = None         # geçişten ÖNCEKİ durgun karede
        self.insan_max: float | None = None         # yalnızca kayıt satırı için
        self.kilit = threading.Lock()


def kutulari_bul(p, kirpik: np.ndarray, haric) -> list:
    """Kırpıntıdaki plaka kutuları; çoğu kesilen köşede kalanlar düşer."""
    return [k for k in p.bul(kirpik) if plaka.haric_orani(k, haric) <= plaka.HARIC_DUSUR]


def kutuyu_oku(p, kirpik: np.ndarray, k, haric, esik: float):
    """
    Tek kutunun iki kırpıntı okuması: (okumalar, emin) — emin = (metin, en
    düşük olasılık) ya da None. Kutu kesikse (kenara / kesilen köşeye değiyor)
    okuyucu hiç çağrılmaz; kesik ya da boşsa None döner.

    Köprü (kareyi_isle) ile `--plaka` test kipi bunu paylaşır: ikisi ayrışamaz.
    """
    h, w = kirpik.shape[:2]
    if not plaka.tam_mi(k, w, h, haric):
        return None
    okumalar = p.oku_cift(kirpik, k)
    if len(okumalar) != 2:
        return None
    return okumalar, plaka.iki_kirpinti(okumalar[0], okumalar[1], esik)


def kareyi_isle(p, gecis: Gecis, kirpik: np.ndarray, zaman, gorunum, haric,
                oku_esik: float, arka: bool = False, arac_skoru=None,
                durgun: bool = False) -> None:
    """
    Bir kareyi okur ve sonucu geçişe yazar (işçi çağırır; testler de).
    `arac_skoru(kirpik, haric)` → (araç, insan) ya da None (ölçülemedi);
    verilmişse plaka işinden SONRA her karede çağrılır.
    """
    _plaka_isle(p, gecis, kirpik, zaman, gorunum, haric, oku_esik, arka)
    if arac_skoru is None:
        return
    olcum = arac_skoru(kirpik, haric)
    if olcum is None:
        return
    a, i = olcum
    with gecis.kilit:
        if arka:
            # Geçişten önceki sahne: bu geçişin aracı DEĞİL, karşılaştırma için.
            gecis.arac_arka = a if gecis.arac_arka is None else max(gecis.arac_arka, a)
            return
        if gecis.arac_max is None or a > gecis.arac_max:
            gecis.arac_max = a
            gecis.arac_kirpik = kirpik
        gecis.insan_max = i if gecis.insan_max is None else max(gecis.insan_max, i)
        if durgun:
            gecis.arac_durgun = a


def _plaka_isle(p, gecis: Gecis, kirpik: np.ndarray, zaman, gorunum, haric,
                oku_esik: float, arka: bool) -> None:
    kutular = kutulari_bul(p, kirpik, haric)
    if arka:
        if kutular:
            with gecis.kilit:
                gecis.arka_kutulu = True
        for k in kutular:
            sonuc = kutuyu_oku(p, kirpik, k, haric, ARKA_ESIK)
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
        sonuc = kutuyu_oku(p, kirpik, k, haric, oku_esik)
        if sonuc is None:
            continue
        okumalar, iki = sonuc
        with gecis.kilit:
            if iki is not None:
                gecis.oylama.okuma(iki[0], iki[1], zaman, gorunum)
                onceki = gecis.en_iyi.get(iki[0])
                if onceki is None or iki[1] > onceki[0]:
                    gecis.en_iyi[iki[0]] = (iki[1], kirpik)
            else:
                gecis.oylama.tahmin(okumalar[0][0], okumalar[0][1])


# ------------------------------------------------------------------- işçi ---

class Is(NamedTuple):
    gecis: Gecis
    kirpik: np.ndarray       # sahibi işçi: döngü KOPYASINI verir
    zaman: object
    gorunum: int
    arka: bool = False
    durgun: bool = False     # aracın durduğu kare (araç bulucu ayrıca saklar)


class Isci:
    """
    Modelleri kendi iş parçacığında çalıştırır. `plakaci` None ise (modeller
    yüklenemedi) baştan bozuktur ve iş almaz — köprü yine çalışır, araçlar
    personele gider. `arac` (1.3.1, arac.AracBulucu ya da None) her karede
    plaka işinden sonra çalışır; hataları plaka okuyucusundan AYRI sayılır.
    """

    def __init__(self, plakaci, haric, oku_esik: float, kayit=None, sebep: str | None = None,
                 arac=None):
        self._p = plakaci
        self.haric = haric
        self.oku_esik = oku_esik
        self._kayit = kayit or (lambda s: print(s, flush=True))
        self.bozuk: str | None = sebep if plakaci is None else None
        self._arac = arac
        self.arac_bozuk: str | None = None
        self._arac_ardisik = 0
        self._ort_sure: float | None = None      # bir işin süresi (üstel ortalama, sn)
        self._kosul = threading.Condition()
        self._slot: Is | None = None
        self._oncelik: Is | None = None
        self._calisan: Is | None = None
        self._basladi: float | None = None
        self._ardisik = 0
        self._dur = False
        self.islenen = 0
        self._ip = threading.Thread(target=self._dongu, daemon=True, name="plaka")
        self._ip.start()

    # ------------------------------------------------------------ döngü tarafı -

    def bos_mu(self) -> bool:
        """İşçi boşta ve kutusu boş mu? (Döngü kareyi ancak o zaman kopyalar.)"""
        with self._kosul:
            return self._slot is None and self._oncelik is None and self._calisan is None

    def ver(self, is_: Is, oncelik: bool = False) -> None:
        with self._kosul:
            if self.bozuk is not None or self._dur:
                return
            if oncelik:
                self._oncelik = is_
            else:
                self._slot = is_
            self._kosul.notify_all()

    def _bekleyen(self, gecis: Gecis) -> bool:
        return any(i is not None and i.gecis is gecis for i in (self._slot, self._oncelik, self._calisan))

    def bekle(self, gecis: Gecis, sn: float) -> bool:
        """Bu geçişin bekleyen ve süren işi bitene kadar (en çok `sn`)."""
        bitis = time.monotonic() + sn
        with self._kosul:
            while self._bekleyen(gecis):
                kalan = bitis - time.monotonic()
                if kalan <= 0:
                    return False
                self._kosul.wait(kalan)
            return True

    def bekleme_suresi(self, taban: float) -> float:
        """Karar bu geçişin işlerini en çok ne kadar beklesin (sn)."""
        with self._kosul:
            ort = self._ort_sure
        sure = taban if ort is None else max(taban, BEKLE_KAT * ort)
        return min(sure, BEKLE_TAVAN_SN)

    def takildi(self, simdi: float, sinir: float) -> bool:
        with self._kosul:
            return self._basladi is not None and simdi - self._basladi > sinir

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

    def _arac_skoru(self, kirpik: np.ndarray, haric):
        """Araç bulucuyu çalıştırır; hatası plaka okumasını ASLA durdurmaz."""
        if self.arac_bozuk is not None:
            return None
        try:
            olcum = self._arac.skor(kirpik, haric)
        except Exception as e:  # noqa: BLE001 — bulucu okuyucuyu öldürmesin
            self._arac_ardisik += 1
            if self._arac_ardisik >= ARDISIK_HATA:
                self.arac_bozuk = f"{type(e).__name__}: {e}"
                self._kayit(f"[!] {ARAC_BOZUK_ISARETI}: {self.arac_bozuk} — plakasız "
                            "araçlar 1.3.0 kuralıyla personele gidecek")
            return None
        self._arac_ardisik = 0
        return olcum

    # ------------------------------------------------------------ işçi tarafı --

    def _dongu(self) -> None:
        while True:
            with self._kosul:
                while not self._dur and self._slot is None and self._oncelik is None:
                    self._kosul.wait()
                if self._dur:
                    return
                if self._oncelik is not None:
                    is_, self._oncelik = self._oncelik, None
                else:
                    is_, self._slot = self._slot, None
                self._calisan = is_
                self._basladi = time.monotonic()
            try:
                kareyi_isle(self._p, is_.gecis, is_.kirpik, is_.zaman, is_.gorunum,
                            self.haric, self.oku_esik, arka=is_.arka,
                            arac_skoru=self._arac_skoru if self._arac is not None else None,
                            durgun=is_.durgun)
                self._ardisik = 0
            except Exception as e:  # noqa: BLE001 — bir kare okuyucuyu öldürmesin
                self._ardisik += 1
                if self._ardisik >= ARDISIK_HATA and self.bozuk is None:
                    self.bozuk = f"{type(e).__name__}: {e}"
                    self._kayit(f"[!] {OKUYUCU_BOZUK_ISARETI}: {self.bozuk} — araçlar "
                                "personele gidecek")
            finally:
                with self._kosul:
                    if self._basladi is not None:
                        s = time.monotonic() - self._basladi
                        self._ort_sure = s if self._ort_sure is None else 0.8 * self._ort_sure + 0.2 * s
                    self._calisan = None
                    self._basladi = None
                    self.islenen += 1
                    if self.bozuk is not None:
                        self._slot = self._oncelik = None
                    self._kosul.notify_all()


# ------------------------------------------------------------------ karar ---

class Gonderim(NamedTuple):
    tur: str                       # "PLAKA" | "OKUNAMADI"
    plaka: str | None
    tahmin: str | None
    guven: float | None
    zaman: object
    kirpik: np.ndarray | None


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
    eşikleri; None ise kararlar 1.3.0 ile birebir aynıdır.
    """
    satirlar: list[str] = []
    with gecis.kilit:
        k = gecis.oylama.karar()
        en_iyi = dict(gecis.en_iyi)
        arka = set(gecis.arka_okunan)
        arka_kutulu = gecis.arka_kutulu
        arac_max, arac_durgun = gecis.arac_max, gecis.arac_durgun
        arac_arka, insan_max = gecis.arac_arka, gecis.insan_max
        arac_kirpik = gecis.arac_kirpik
    bulucu = arac_esik is not None and arac_gecis_esik is not None
    # Bu geçişte NET bir araç görüldü ve geçişten önce orada değildi.
    net_arac = (bulucu and arac_max is not None and arac_max >= arac_gecis_esik
                and arac_arka is not None and arac_arka < arac_esik)
    ayrilis = ayrilis_sahne or (son_durdu_plaka is not None
                                and any(_yakin(son_durdu_plaka, a) for a in arka))

    def yeni_gitti(p: str | None) -> bool:
        return any(_yakin(p, g) and simdi - t <= YAKIN_SN for g, t in son_gonderilen)

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
        if yeni_gitti(e.metin):
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
        elif durdu and arac_boyu and not arka_kutulu:
            # Geçişten önce kadrajda plakalı bir araç VARDIYSA ve şimdi hiç
            # plaka yoksa değişen şey o aracın GİDİŞİdir, bir şey durmadı
            # (test_kopru `kuyruk`): personele yazılmaz.
            arac_yok = (bulucu and arac_durgun is not None
                        and arac_durgun < arac_esik and not net_arac)
            if arac_yok:
                # 1.3.1: duran şey araç değil (sahada: kameranın önünde duran insanlar).
                satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare) — "
                                f"{ARAC_YOK_ISARETI} ({_puanlar(arac_durgun, insan_max)})")
            else:
                if bulucu and arac_durgun is None and not net_arac:
                    satirlar.append(f"[i] {ARAC_YETISMEDI_ISARETI} — 1.3.0 kuralı: personele")
                gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic,
                                       _foto(gecis)))
        elif not durdu and arac_boyu and not arka_kutulu and net_arac:
            # 1.3.1: durmadan geçen, plakası hiç okunamayan araç → personele.
            # Fotoğraf aracın en iyi görüldüğü kare (son kare boş şerit olabilir).
            satirlar.append(f"[i] {PLAKASIZ_ARAC_ISARETI} — personele "
                            f"({_puanlar(arac_max, insan_max)})")
            foto = arac_kirpik if arac_kirpik is not None else _foto(gecis)
            gonder.append(Gonderim("OKUNAMADI", None, None, None, gecis.baslangic, foto))
        else:
            ek = "" if arac_max is None else f" — {_puanlar(arac_max, insan_max)}"
            satirlar.append(f"[i] {PLAKASIZ_ISARETI} ({k.kutulu_kare} kutulu kare){ek}")

    gonder.sort(key=lambda g: g.zaman)
    return gonder, satirlar
