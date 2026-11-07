# -*- coding: utf-8 -*-
"""
Yakalama döngüsü regresyon testleri (köprü 1.3.0).

    python test_kopru.py            # hepsi
    python test_kopru.py iki_arac   # tek senaryo

Bu dosya GERÇEK main() döngüsünü çalıştırır; kamera, ağ ve plaka MODELLERİ
taklit edilir, karar mantığı taklit EDİLMEZ (okuma.py, plaka.Oylama, giden.py
gerçek). Test edilen şey kodun kopyası değil, kodun kendisidir.

Sahte plaka: aracın gövdesinin altında, işaret renginde (BGR 0, 10·no+5, 255)
dikey çizgiler. Sahte okuyucu (`plaka.yukle` yerine) işaret pikselini bulur
(bulanık karede işaret bozulur → bulunmaz, gerçekte de bulanık plaka okunmaz),
kutuyu verir ve `no`'ya göre PLAKALAR'dan metni okur. Sahte sunucu gövdeyi
plaka / okunamadı / kalp atışı diye ayırır.

1.2.x'in kamera olayı (olay_*) ve boş şerit öğrenme (bos_*) senaryoları 1.3.0
ile kalktı: o kapılar yok (sahibin kararı, 2026-11-06).
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
import types

import numpy as np

for _akis in (sys.stdout, sys.stderr):
    if hasattr(_akis, "reconfigure"):
        _akis.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))

BOS, GELIYOR, DURDU = "bos", "geliyor", "durdu"
#   GECIYOR  araç soldan girer, sağdan çıkar, hiç durmaz; yalnızca ortaya yakınken
#            KESKİN (plaka okunabilir), geri kalan karelerde bulanık.
#   GOLGE    araç OLMAYAN hareket (yürüyen biri, gölge): koyu, plakasız.
#   GURULTU  araç gittikten sonra sahne hiç DURULMAZ (yağmur, gece kumlanması).
GECIYOR, GOLGE, GURULTU = "geciyor", "golge", "gurultu"
#   YAYA_GELIYOR / YAYA_DURDU  araç boyunda ama araç OLMAYAN bir şey (koyu,
#            plakasız) gelir ve DURUR — kameranın önünde duran insanlar (1.3.1).
YAYA_GELIYOR, YAYA_DURDU = "yaya_geliyor", "yaya_durdu"

PLAKALAR = ["34ABC123", "06KZ4581", "35PA052", "81Z9999", "01A12345"]

_KIMLIKLI_RTSP = ("rtsp://admin:Gizli%40Sifre%3A1@10.0.0.5:554"
                  "/cam/realmonitor?channel=1&subtype=0")
_KIMLIKLI_SINAMA = ("10.0.0.5", 554, "admin", "Gizli@Sifre:1",
                    "/cam/realmonitor?channel=1&subtype=0")

# sahne öğesi: (başla, bitir, evre[, plaka no]) — plaka no yoksa plakasız.
SENARYOLAR = {
    # Asıl regresyon (1.2.x): ikinci araç iki bekleme arasına düşüp kayboluyordu.
    # 1.3.0: ilk aracın GİDİŞİ (3.5-4.2) aynı plakayı yeniden okur ama ayrılıştır,
    # gönderilmez.
    "iki_arac": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 3.5, DURDU, 0),
               (3.5, 4.2, GELIYOR, 0), (4.2, 8, BOS),
               (8, 8.8, GELIYOR, 1), (8.8, 14, DURDU, 1)],
        sure=14.0, pencereler=[(1.8, 3.6), (8.8, 14.1)],
        plakalar=[(1.8, 3.6, 0), (8.8, 14.1, 1)], gonderim_sayisi=2,
    ),
    # 429 geçicidir: kayıt kutuda kalır, aynı islem_id ile yeniden denenir.
    "429": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 8, DURDU, 0)],
        sure=8.0, pencereler=[(1.8, 6.5)], kodlar=[429, 429, 200], tekrar=3,
        giden_bos=True,
    ),
    # Yavaş sunucu kamerayı kör bırakmamalı (gönderim ayrı iş parçacığında).
    "yavas": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 3.5, DURDU, 0),
               (3.5, 4.2, GELIYOR, 0), (4.2, 8, BOS),
               (8, 8.8, GELIYOR, 1), (8.8, 13, DURDU, 1)],
        sure=14.0, pencereler=[(1.8, 3.5), (8.8, 13.0)], yavas=3.0,
        plakalar=[(1.8, 3.5, 0), (8.8, 13.0, 1)],
    ),
    # Bariyerde bekleyen araç MAX_BEKLEME_SN dolunca tekrar gönderilmemeli.
    "park": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 14, DURDU, 0)],
        sure=13.0, pencereler=[(1.8, 13.0)], max_bekleme="5", tek=True,
    ),
    # Sırayla bariyere ilerleyen üç araç: her yeni araç öncekinin yerine gelir.
    # İkinci ve üçüncü geçiş, gönderilmiş duran aracın görüntüsünden başlar
    # (ayrılış) — ama okunan plaka FARKLI: gönderilir.
    "kuyruk": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 3.5, DURDU, 0),
               (3.5, 4.3, GELIYOR, 1), (4.3, 9.5, DURDU, 1),
               (9.5, 10.3, GELIYOR, 2), (10.3, 15, DURDU, 2)],
        sure=16.0, pencereler=[(1.8, 3.5), (4.3, 9.5), (10.3, 15.0)],
        plakalar=[(1.8, 3.5, 0), (4.3, 9.5, 1), (10.3, 15.0, 2)], gonderim_sayisi=3,
    ),
    # Elektrik kesintisinden sonra bilgisayar kameradan ÖNCE açılır.
    "gec_kamera": dict(
        sahne=[(0, 5, BOS), (5, 5.8, GELIYOR, 0), (5.8, 10, DURDU, 0)],
        sure=10.0, pencereler=[(5.8, 10.0)], acilis=3.0, acilis_bekleme="0.5",
    ),
    # Akış bir an kopup geri geliyor; dönüş kayda yazılmalı.
    "kopma": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR, 0), (6.8, 11, DURDU, 0)],
        sure=11.0, pencereler=[(6.8, 11.0)], kopuk=(2.0, 2.3),
        kayitta_sirayla=["kare alınamadı", "kamera bağlandı"],
    ),
    # Tek kapı (037): her olay ORTAK şeridini taşımalı.
    "tek_kapi": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=7.0, pencereler=[(1.8, 6.0)], yon="ORTAK", plakalar=[(1.8, 6.0, 0)],
    ),
    # Kırpma kutusu varsa her gönderim sıkıştırılmış fotoğrafı taşır (≤100 KB).
    "kanit_fotografi": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 3.5, DURDU, 0),
               (3.5, 4.2, GELIYOR, 0), (4.2, 8, BOS),
               (8, 8.8, GELIYOR, 1), (8.8, 12, DURDU, 1)],
        sure=12.5, pencereler=[(1.8, 3.6), (8.8, 12.1)],
        kirpma="100,80,400,300",
    ),
    # Kalp atışı yakalama iş parçacığını BLOKLAMAMALI (1.2.1).
    "kalp_bloklamaz": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 8, DURDU, 0)],
        sure=8.0, pencereler=[(1.8, 4.0)], kalp_gecikme=5.0,
        kayitta_sirayla=["kamera bağlandı", "sunucu bağlantısı doğrulandı"],
    ),
    # 1.3.0: internet yok — kayıt KUTUDA kalır, aynı islem_id ile 1, 2, 4 sn
    # arayla yeniden denenir ve gider (1.2.x dört denemede atardı).
    "ag_yok_bekler": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 12, DURDU, 0)],
        sure=12.0, pencereler=[(1.8, 3.0)], kodlar=[0, 0, 0, 200], tekrar=4,
        giden_bos=True, kayitta_sirayla=["ağ hatası"],
    ),
    # Kameranın şifresi değişti: eski şifreyle akış HİÇ açılmamalı (1.2.2).
    "sifre_degisti": dict(
        sahne=[(0, 10.5, BOS), (10.5, 11.3, GELIYOR, 0), (11.3, 15, DURDU, 0)],
        sure=15.0, pencereler=[(11.3, 15.0)],
        rtsp=_KIMLIKLI_RTSP, gitti=[(2.0, 9.0)],
        sifre=[(2.0, "tamam"), (9.0, "yanlis"), (99.0, "tamam")], sifre_bekleme="1.0",
        yeniden_baglan=("0.2", "1.6"),
        sifreyle_acilmaz=(2.0, 9.0), sinama_en_cok=(2.0, 9.0, 8),
        kayitta_sirayla=["kare alınamadı", "kamera şifreyi reddetti", "kamera bağlandı"],
    ),
    "sifre_acilista": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR, 0), (6.8, 10, DURDU, 0)],
        sure=10.0, pencereler=[(6.8, 10.0)],
        rtsp=_KIMLIKLI_RTSP, gitti=[(0.0, 4.0)],
        sifre=[(4.0, "yanlis"), (99.0, "tamam")], sifre_bekleme="1.0",
        acilis_bekleme="0.5",
        sifreyle_acilmaz=(0.0, 4.0), sinama_en_cok=(0.0, 4.0, 5),
        kayitta_sirayla=["kamera şifreyi reddetti", "kamera bağlandı"],
    ),
    "kopma_geri_cekilme": dict(
        sahne=[(0, 99, BOS)], sure=12.0, pencereler=[],
        rtsp=_KIMLIKLI_RTSP, gitti=[(2.0, 7.2), (10.0, 99.0)],
        sifre=[(99.0, "bilinmiyor")], yeniden_baglan=("0.2", "1.6"),
        geri_cekilme=(2.0, 7.2), sifirlama=10.0,
    ),
    # 1.2.4 bekçi: takılan döngü kapatılır; öbür senaryolar onu tetiklememeli.
    "takilma": dict(
        sahne=[(0, 99, BOS)], sure=8.0, pencereler=[],
        takilir=2.0, bekci="2", bekci_beklenir=(3.5, 7.5),
        kayitta_sirayla=["kamera bağlandı", "köprü takıldı"],
    ),
    # Bariyersiz kapı: araç durmadan geçer. Plaka keskin karelerde okunur;
    # gönderilen fotoğraf o karedir (bulanık değil).
    "gecen_arac": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 6, BOS)],
        sure=6.0, pencereler=[(2.4, 3.8)], gonderim_sayisi=1, keskin=True,
        kirpma="0,0,640,480", plakalar=[(2.4, 3.8, 0)],
    ),
    "gecen_iki_arac": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 6, BOS),
               (6, 6.9, GECIYOR, 1), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(2.4, 3.8), (6.9, 8.3)], gonderim_sayisi=2, keskin=True,
        kirpma="0,0,640,480", plakalar=[(2.4, 3.8, 0), (6.9, 8.3, 1)],
    ),
    # Araç gitti ama sahne hiç durulmuyor: güvenlik ağı karar verir.
    "gecen_gurultu": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 8, GURULTU)],
        sure=8.0, pencereler=[(3.4, 5.2)], gonderim_sayisi=1, plakalar=[(3.4, 5.2, 0)],
    ),
    # Duran araç: gelir, DURUR (gönderilir), gider. Gidişte plaka yine okunur
    # ama bu AYRILIŞ: ikinci gönderim yok (tek kapıda sahte çıkış olurdu).
    "duran_arac_degismez": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 4.5, DURDU, 0),
               (4.5, 5.2, GELIYOR, 0), (5.2, 9, BOS)],
        sure=9.0, pencereler=[(1.8, 3.0)], gonderim_sayisi=1, gonderilmez=[(3.2, 9)],
        kayitta_sirayla=["araç durdu", "gönderilmiş araç — tekrar gönderilmedi"],
    ),
    # Desenli zemin: gönderilen kare aracın TAMAMINI içermeli.
    "dokulu_zemin": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 6, BOS)],
        sure=6.0, pencereler=[(2.4, 3.8)], gonderim_sayisi=1, tam_arac=True, doku=True,
        kirpma="0,0,640,480",
    ),
    # ---- 1.3.0 -------------------------------------------------------------
    # Araç boyutunda bir şey DURDU ama plakası hiç görülmedi: personele.
    "plakasiz_duran": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 6, DURDU)],
        sure=6.0, pencereler=[(1.8, 3.6)], personele=[(1.8, 3.6, None)], gonderim_sayisi=1,
    ),
    # Plakasız, durmayan hareket (yaya, gölge): hiçbir şey gönderilmez.
    "yaya_gecer": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GOLGE), (2.4, 7, BOS)],
        sure=7.0, pencereler=[], gonderim_sayisi=0, gonderilmez=[(0, 7)],
        kayitta_sirayla=["hareket — plaka görülmedi"],
    ),
    # İki kırpıntı aynı plakayı vermiyor: emin değil → personele, tahminle.
    "anlasmazlik": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 3.6)], anlasmazlik=True,
        personele=[(1.8, 3.6, 0)], gonderim_sayisi=1,
    ),
    # Plaka kırpma kutusunun alt kenarında kesik: hiç okunmaz → personele.
    "kesik_plaka": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 3.6)], kirpma="0,0,640,330",
        personele=[(1.8, 3.6, None)], gonderim_sayisi=1,
    ),
    # Eski sunucu "okunamadi"yı tanımıyor (422, istisna yok): araç kaybolmasın
    # diye kayda [!] düşer.
    "eski_sunucu": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 6, DURDU)],
        sure=6.0, pencereler=[(1.8, 3.6)], eski_sunucu=True,
        kayitta_sirayla=["sunucu okunamadı kaydını yazmadı"],
    ),
    # Plaka okuyucu yüklenemedi: köprü DÜŞMEZ, duran araç personele gider.
    "okuyucu_yok": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 3.6)], okuyucu="yok",
        personele=[(1.8, 3.6, None)],
        kayitta_sirayla=["plaka okuyucu çalışmıyor"],
    ),
    # İnternet kesik iken iki araç: kutuda bekler, SIRAYLA gider.
    "internet_kesintisi": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 3.5, DURDU, 0),
               (3.5, 4.2, GELIYOR, 0), (4.2, 5.5, BOS),
               (5.5, 6.3, GELIYOR, 1), (6.3, 16, DURDU, 1)],
        sure=16.0, pencereler=[(1.8, 3.6)], kodlar=[0, 0, 0],
        plakalar=[(1.8, 16, 0), (6.3, 16, 1)], sirali_teslim=True, giden_bos=True,
    ),
    # Çıkış şeridinde okunamayan araç sunucuya gönderilmez (orada para insanda).
    "cikis_belirsiz": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 6, DURDU)],
        sure=6.0, pencereler=[], yon="CIKIS", gonderim_sayisi=0,
        kayitta_sirayla=["çıkış şeridinde okunamayan araç"],
    ),
    # L şekli: kesilen köşede duran (park etmiş) araç hiçbir şey üretmez.
    "haric_alan": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[], kirpma="0,0,640,480", haric="0,60,640,400",
        gonderim_sayisi=0,
    ),
    # Aynı plaka 60 sn içinde ikinci kez gitmez.
    "ayni_plaka_60sn": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 5, BOS),
               (5, 5.9, GECIYOR, 0), (5.9, 9, BOS)],
        sure=9.0, pencereler=[(2.4, 3.8)], gonderim_sayisi=1, gonderilmez=[(5, 9)],
    ),
    # ---- 1.3.1 (araç bulucu) -----------------------------------------------
    # Sahada 2026-11-07: kameranın önünde DURAN iki kişi "Çözülmemiş kayıt"
    # oldu. Araç bulucu araç görmüyor: hiçbir şey gönderilmez.
    "yaya_durur": dict(
        sahne=[(0, 1, BOS), (1, 1.8, YAYA_GELIYOR), (1.8, 6, YAYA_DURDU)],
        sure=6.0, pencereler=[], gonderim_sayisi=0, gonderilmez=[(0, 6)],
        kayitta_sirayla=["araç bulucu hazır", "araç görülmedi"],
    ),
    # Araç bulucu yüklenemedi: köprü DÜŞMEZ ve 1.3.0 kuralına döner (duran,
    # araç boyunda, plakasız → personele) — araç bulucu yüzünden araç kaybolmaz.
    "yaya_durur_bulucusuz": dict(
        sahne=[(0, 1, BOS), (1, 1.8, YAYA_GELIYOR), (1.8, 6, YAYA_DURDU)],
        sure=6.0, pencereler=[(1.8, 3.6)], arac="yok",
        personele=[(1.8, 3.6, None)], gonderim_sayisi=1,
        kayitta_sirayla=["araç bulucu çalışmıyor"],
    ),
    # Sahibin kararı (2026-11-07): durmadan geçen, plakası hiç okunamayan ARAÇ
    # personele (1.3.0'da sessizce düşüyordu). Fotoğraf aracın TAMAMINI
    # gösteren kare olmalı, araç gittikten sonraki boş şerit değil.
    "plakasiz_gecen": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS)],
        sure=6.0, pencereler=[(2.4, 4.0)], personele=[(2.4, 4.0, None)],
        gonderim_sayisi=1, kirpma="0,0,640,480", tam_arac=True,
        kayitta_sirayla=["plakasız araç geçti"],
    ),
}

KESKIN_ARALIK = 130


def isaret(no: int) -> tuple[int, int, int]:
    return (0, 10 * no + 5, 255)


def plaka_ciz(f: np.ndarray, x: int, no: int) -> None:
    for c in range(x + 100, x + 300, 12):
        c0, c1 = max(0, c), min(640, c + 6)
        if c1 > c0:
            f[300:350, c0:c1] = isaret(no)


def gecen_ciz(f: np.ndarray, x: int, deger: int, no: int | None, keskin: bool) -> np.ndarray:
    import cv2 as _cv2
    x0, x1 = max(0, x), min(640, x + 400)
    if x1 > x0:
        f[90:390, x0:x1] = deger
        if no is not None:
            plaka_ciz(f, x, no)
    return f if keskin else _cv2.GaussianBlur(f, (0, 0), 6)


def keskinlik_olc(img_gri: np.ndarray) -> float:
    import cv2 as _cv2
    return float(_cv2.Laplacian(img_gri, _cv2.CV_64F).var())


class SahtePlakaci:
    """plaka.Plakaci yerine: işaret renkli pikselleri bulur ve okur."""

    def __init__(self, S: dict):
        self.anlasmazlik = bool(S.get("anlasmazlik"))
        self.guven = float(S.get("guven", 0.99))

    @staticmethod
    def _maske(img: np.ndarray) -> np.ndarray:
        return (img[:, :, 2] >= 250) & (img[:, :, 0] <= 5) & (img[:, :, 1] >= 3)

    def bul(self, kirpik: np.ndarray):
        import plaka as _p
        m = self._maske(kirpik)
        if int(m.sum()) < 50:
            return []
        ys, xs = np.nonzero(m)
        return [_p.Kutu(float(xs.min()), float(ys.min()), float(xs.max() + 1),
                        float(ys.max() + 1), 0.9)]

    def oku_cift(self, kirpik: np.ndarray, k):
        bolge = kirpik[int(k.y1):int(k.y2), int(k.x1):int(k.x2)]
        m = self._maske(bolge)
        if not m.any():
            return []
        no = int(round((float(np.median(bolge[:, :, 1][m])) - 5) / 10))
        metin = PLAKALAR[no % len(PLAKALAR)]
        ikinci = metin[:-1] + ("8" if metin[-1] != "8" else "9") if self.anlasmazlik else metin
        return [(metin, self.guven), (ikinci, self.guven)]


class SahteArac:
    """
    arac.AracBulucu yerine: araç gövdesi (açık gri, ≥200) kırpıntının ne
    kadarını kaplıyorsa o kadar "araç". Koyu şekil (yaya, gölge) ve boş
    şerit 0. Tam görünen araç ≈0.94, yarısı görünen ≈0.47 — en iyi kare
    aracın tamamını gösteren karedir.
    """

    esik, gecis_esik = 0.35, 0.60

    def skor(self, kirpik: np.ndarray, haric):
        oran = float((kirpik.min(axis=2) >= 200).mean())
        return (0.0 if oran < 0.05 else min(0.95, oran * 2.4)), 0.0


def hepsini_kos() -> int:
    import tempfile
    kok = tempfile.mkdtemp(prefix="otopark-test-kopru-")
    kotu = []
    for ad in SENARYOLAR:
        print(f"\n{'=' * 62}\n{ad}\n{'=' * 62}", flush=True)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), ad],
                           env={**os.environ, "PYTHONIOENCODING": "utf-8",
                                "TMPDIR": kok, "TEMP": kok, "TMP": kok})
        if r.returncode:
            kotu.append(ad)
    print("\n" + "=" * 62)
    print(f"Geçici dosyalar: {kok}")
    if kotu:
        print("BAŞARISIZ: " + ", ".join(kotu))
        return 1
    print(f"TÜM TESTLER GEÇTİ ({len(SENARYOLAR)} senaryo)")
    return 0


def tek_kos(ad: str) -> int:
    S = SENARYOLAR[ad]
    gonderimler: list[dict] = []
    kalpler: list[float] = []
    kodlar = list(S.get("kodlar", []))

    # ---- `requests` taklidi, kopru import EDİLMEDEN önce -------------------
    sahte = types.ModuleType("requests")

    class RequestException(Exception):
        pass

    class Yanit:
        def __init__(self, kod, text='{"ok":true}'):
            self.status_code = kod
            self.text = text
            self.headers = {}

    import json as _json

    def post(url, json=None, headers=None, timeout=None):
        json = json or {}
        tur = "PLAKA" if json.get("plaka") else ("OKUNAMADI" if json.get("okunamadi") else None)
        if tur is None:
            kalpler.append(time.monotonic() - T0)
            if S.get("kalp_gecikme"):
                time.sleep(S["kalp_gecikme"])
            return Yanit(400)
        kayit = {"t": time.monotonic() - T0, "id": json["islem_id"], "yon": json.get("yon"),
                 "tur": tur, "plaka": json.get("plaka"), "tahmin": json.get("tahmin"),
                 "zaman": json.get("zaman"), "foto_var": "foto_base64" in json,
                 "kanit_var": "foto_kanit_base64" in json, "kanit": json.get("foto_kanit_base64")}
        gonderimler.append(kayit)
        if S.get("yavas"):
            time.sleep(S["yavas"])
        kod = kodlar.pop(0) if kodlar else (200 if tur == "PLAKA" else 422)
        kayit["kod"] = kod
        if kod == 0:
            raise RequestException("ağ yok")
        if kod == 422:
            return Yanit(422, _json.dumps({"hata": "Plaka okunamadı.",
                                           "istisna": not S.get("eski_sunucu")}))
        return Yanit(kod, '{"ok":true,"karar":"GIRIS"}')

    sahte.RequestException = RequestException
    sahte.post = post
    sys.modules["requests"] = sahte

    import tempfile
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp(prefix="otopark-test-")
    os.environ.update(WEBHOOK_URL="http://stub/kamera-webhook",
                      KAMERA_SECRET="x" * 32,
                      RTSP_URL=S.get("rtsp", "rtsp://stub/1"), YON=S.get("yon", "GIRIS"))
    for ad_s, anahtar in (("kirpma", "KIRPMA"), ("haric", "KIRPMA_HARIC"),
                          ("max_bekleme", "MAX_BEKLEME_SN"),
                          ("acilis_bekleme", "ACILIS_BEKLEME_SN"),
                          ("sifre_bekleme", "SIFRE_RED_BEKLEME_SN")):
        if S.get(ad_s):
            os.environ[anahtar] = S[ad_s]
        else:
            os.environ.pop(anahtar, None)
    if S.get("yeniden_baglan"):
        os.environ["YENIDEN_BAGLAN_SN"], os.environ["YENIDEN_BAGLAN_MAX_SN"] = S["yeniden_baglan"]
    os.environ["BEKCI_SN"] = S.get("bekci", "3")

    sys.path.insert(0, BURASI)
    import plaka

    if S.get("okuyucu") == "yok":
        def _yukle_yok(ayar, dizin=None):
            raise plaka.PlakaHatasi("model dosyası bulunamadı: (test)")
        plaka.yukle = _yukle_yok
    else:
        plaka.yukle = lambda ayar, dizin=None: SahtePlakaci(S)

    # 1.3.1: araç bulucu her senaryoda TAKLİT edilir (gerçek model test
    # karelerindeki gri dikdörtgeni araç sanmaz); "yok" = yüklenemedi.
    import arac
    if S.get("arac") == "yok":
        def _arac_yok(ayar, dizin=None):
            raise plaka.PlakaHatasi("model dosyası bulunamadı: (test)")
        arac.yukle = _arac_yok
    else:
        arac.yukle = lambda ayar, dizin=None: SahteArac()

    import kopru
    import kesif

    global T0
    T0 = time.monotonic()

    bekci_cagrilari: list[float] = []
    kopru._bekci_cik = lambda: bekci_cagrilari.append(time.monotonic() - T0)

    sinamalar: list[tuple[float, tuple]] = []

    def sahte_sinama(ip, port, kullanici, sifre, zaman_asimi=4.0, yol="/"):
        t = time.monotonic() - T0
        sinamalar.append((t, (ip, port, kullanici, sifre, yol)))
        for son, sonuc in S.get("sifre", []):
            if t < son:
                return sonuc
        return "bilinmiyor"

    kesif.kimlik_dogrula = sahte_sinama

    def evre(t):
        for oge in S["sahne"]:
            a, b, e = oge[:3]
            if a <= t < b:
                return e, a, b, (oge[3] if len(oge) > 3 else None)
        return BOS, 0.0, 0.0, None

    titresim = [0]
    doku = None
    if S.get("doku"):
        rs = np.random.RandomState(7)
        g = rs.randint(40, 160, (480, 640)).astype(np.uint8)
        doku = np.dstack([g, g, g])

    def kare():
        t = time.monotonic() - T0
        e, a, b, no = evre(t)
        f = doku.copy() if doku is not None else np.full((480, 640, 3), 100, np.uint8)
        if e == BOS:
            return f
        if e == GURULTU:
            titresim[0] ^= 1
            return f + np.uint8(4 * titresim[0])
        if e in (GECIYOR, GOLGE):
            x = int(-420 + 1080 * (t - a) / (b - a))
            if e == GOLGE:
                return gecen_ciz(f, x, deger=0, no=None, keskin=True)
            keskin = abs(x + 200 - 320) < KESKIN_ARALIK
            if doku is not None:
                katman = gecen_ciz(np.full((480, 640, 3), 220, np.uint8), x, deger=220,
                                   no=no, keskin=keskin)
                x0, x1 = max(0, x), min(640, x + 400)
                if x1 > x0:
                    f[90:390, x0:x1] = katman[90:390, x0:x1]
                return f
            return gecen_ciz(f, x, deger=220, no=no, keskin=keskin)
        if e in (YAYA_GELIYOR, YAYA_DURDU):
            # GELIYOR/DURDU ile aynı hareket ve boyut, ama koyu ve plakasız.
            x = 120 if e == YAYA_DURDU else int((t * 2000) % 400)
            f[90:390, x:x + 400] = 0
            return f
        x = 120 if e == DURDU else int((t * 2000) % 400)
        f[90:390, x:x + 400] = 220
        if no is not None:
            plaka_ciz(f, x, no)
        return f

    acilis = S.get("acilis", 0.0)

    def gitti_mi(t: float) -> bool:
        return any(a <= t < b for a, b in S.get("gitti", []))

    acilislar: list[float] = []

    class SahteKamera:
        def __init__(self):
            t = time.monotonic() - T0
            acilislar.append(t)
            self.olu = gitti_mi(t)

        def isOpened(self):
            return not self.olu and time.monotonic() - T0 >= acilis

        def set(self, *a):
            return True

        def read(self):
            time.sleep(0.04)
            t = time.monotonic() - T0
            if S.get("takilir") is not None and t >= S["takilir"]:
                threading.Event().wait()
            a, b = S.get("kopuk", (0, 0))
            if self.olu or a <= t < b or gitti_mi(t):
                return False, None
            return True, kare()

        def release(self):
            pass

    kopru.cv2.VideoCapture = lambda *a, **k: SahteKamera()

    threading.Thread(target=kopru.main, daemon=True).start()
    time.sleep(S["sure"])

    for g in gonderimler:
        print(f"   t={g['t']:5.2f}s  {g['id'][:8]}  {g['tur']:9s} {g.get('kod')}")

    hata = 0

    def fail(m: str) -> None:
        nonlocal hata
        print(f"FAIL: {m}")
        hata = 1

    ilk_deneme: dict[str, dict] = {}
    for g in sorted(gonderimler, key=lambda g: g["t"]):
        ilk_deneme.setdefault(g["id"], g)
    tekil = list(ilk_deneme.values())

    for i, (a, b) in enumerate(S["pencereler"], 1):
        if not [g for g in gonderimler if a <= g["t"] <= b]:
            fail(f"{i}. araç ({a}-{b}s) hiç gönderilmedi")
    for a, b, no in S.get("plakalar", []):
        if not [g for g in tekil if a <= g["t"] <= b and g["plaka"] == PLAKALAR[no]]:
            fail(f"{a}-{b}s arasında {PLAKALAR[no]} plakası gönderilmedi")
    for a, b, no in S.get("personele", []):
        uyan = [g for g in tekil if a <= g["t"] <= b and g["tur"] == "OKUNAMADI"]
        if not uyan:
            fail(f"{a}-{b}s arasında personele (okunamadı) gönderim yok")
        elif no is not None and not any(g["tahmin"] == PLAKALAR[no] for g in uyan):
            fail(f"personele giden kaydın tahmini {PLAKALAR[no]} değil: "
                 f"{[g['tahmin'] for g in uyan]}")
        elif no is None and any(g["tahmin"] for g in uyan):
            fail(f"plakasız araçta tahmin olmamalıydı: {[g['tahmin'] for g in uyan]}")
    if "gonderim_sayisi" in S and len(tekil) != S["gonderim_sayisi"]:
        fail(f"{S['gonderim_sayisi']} gönderim bekleniyordu, {len(tekil)} "
             f"(t={', '.join('%.2f' % g['t'] for g in tekil)})")
    for a, b in S.get("gonderilmez", []):
        icinde = [g for g in tekil if a <= g["t"] <= b]
        if icinde:
            fail(f"{a}-{b}s arasında gönderim olmamalıydı, {len(icinde)} var "
                 f"(t={', '.join('%.2f' % g['t'] for g in icinde)})")
    if any(g["foto_var"] for g in gonderimler):
        fail("okunacak fotoğraf (foto_base64) gönderildi — 1.3.0 bulutta okutmaz")
    if S.get("tek") and len(tekil) != 1:
        fail(f"1 gönderim bekleniyordu, {len(tekil)}")
    if S.get("tekrar"):
        en_cok = max((sum(1 for g in gonderimler if g["id"] == i) for i in ilk_deneme), default=0)
        if en_cok != S["tekrar"]:
            fail(f"aynı islem_id ile {S['tekrar']} deneme bekleniyordu, {en_cok}")
    if S.get("sirali_teslim"):
        basarili = [g for g in sorted(gonderimler, key=lambda g: g["t"]) if g.get("kod") == 200]
        zamanlar = [g["zaman"] for g in basarili]
        if len(basarili) < 2 or zamanlar != sorted(zamanlar):
            fail(f"kutudaki araçlar sırayla teslim edilmedi: {zamanlar}")
    yon = S.get("yon", "GIRIS")
    giden_klasor = os.path.join(os.environ["PROGRAMDATA"], "Otopark", "kayit",
                                f"giden-{yon.lower()}")
    if S.get("giden_bos"):
        kalan = [f for f in os.listdir(giden_klasor) if f.endswith(".json")] \
            if os.path.isdir(giden_klasor) else []
        if kalan:
            fail(f"gönderim kutusunda {len(kalan)} araç kaldı")
    if acilis:
        erken = [k for k in kalpler if k < acilis]
        if erken:
            fail(f"kamera açılmadan kalp atışı gönderildi (t={erken[0]:.2f}s)")
        if not kalpler:
            fail("kamera açıldıktan sonra hiç kalp atışı gönderilmedi")
    if S.get("kayitta_sirayla"):
        import glob as _glob
        metin = ""
        for yol in _glob.glob(os.path.join(os.environ["PROGRAMDATA"], "Otopark",
                                           "kayit", "*.log")):
            with open(yol, encoding="utf-8", errors="replace") as f:
                metin += f.read()
        konum = 0
        for parca in S["kayitta_sirayla"]:
            i = metin.find(parca, konum)
            if i < 0:
                fail(f"kayıtta sırayla bulunamadı: {parca!r}")
                break
            konum = i + len(parca)
        for p in PLAKALAR:
            if p in metin:
                fail(f"kayıt dosyasında plaka metni var ({p}) — kayıtlara plaka yazılmaz")
                break
    if S.get("yon"):
        yanlis = sorted({str(g["yon"]) for g in gonderimler if g["yon"] != S["yon"]})
        if yanlis:
            fail(f"olaylar {S['yon']} şeridiyle gitmeliydi, giden: {yanlis}")
    if S.get("sifreyle_acilmaz"):
        a, b = S["sifreyle_acilmaz"]
        acilan = [t for t in acilislar if a < t < b]
        if acilan:
            fail(f"kamera şifreyi reddederken akış {len(acilan)} kez açıldı")
    if S.get("sinama_en_cok"):
        a, b, n = S["sinama_en_cok"]
        say = len([t for t, _ in sinamalar if a < t < b])
        if not 1 <= say <= n:
            fail(f"{a}-{b}s arasında 1..{n} şifre sınaması bekleniyordu, {say}")
    if S.get("rtsp") == _KIMLIKLI_RTSP and S.get("sifre"):
        yanlis_arg = sorted({str(x) for _, x in sinamalar if x != _KIMLIKLI_SINAMA})
        if not sinamalar or yanlis_arg:
            fail(f"şifre sınaması köprünün kendi adresini çözüp sormalıydı; gelen: "
                 f"{yanlis_arg or 'hiç sınama yok'}")
    if S.get("geri_cekilme"):
        a, b = S["geri_cekilme"]
        taban, tavan = (float(x) for x in S["yeniden_baglan"])
        anlar = [t for t in acilislar if a < t < b]
        bosluklar = [y - x for x, y in zip([a] + anlar, anlar)]
        beklenen = [min(taban * 2 ** k, tavan) for k in range(len(bosluklar))]
        uymayan = [(round(g, 2), e) for g, e in zip(bosluklar, beklenen)
                   if not e * 0.75 <= g <= e + 0.5]
        if len(anlar) < 5 or uymayan:
            fail(f"yeniden bağlanma aralıkları {[round(g, 2) for g in bosluklar]}, "
                 f"beklenen ~{beklenen}")
    if S.get("sifirlama"):
        x = S["sifirlama"]
        taban = float(S["yeniden_baglan"][0])
        sonraki = [t for t in acilislar if t > x]
        if not sonraki or not x + taban * 0.75 <= sonraki[0] <= x + taban + 0.5:
            fail(f"{x}s'deki kopmadan sonra ilk deneme ~{x + taban:.2f}s bekleniyordu")

    import base64 as _b64
    import cv2 as _cv2

    def _coz(s: str):
        b = _b64.b64decode(s, validate=True)
        return b, _cv2.imdecode(np.frombuffer(b, np.uint8), _cv2.IMREAD_COLOR)

    if S.get("kirpma"):
        for g in gonderimler:
            if not g["kanit"]:
                fail(f"t={g['t']:.2f}s gönderiminde kanıt fotoğrafı yok")
                continue
            b, img = _coz(g["kanit"])
            if b[:3] != b"\xff\xd8\xff" or len(b) > 102_400 or img is None:
                fail(f"t={g['t']:.2f}s kanıt fotoğrafı geçersiz ({len(b)} bayt)")
    else:
        if [g for g in gonderimler if g["kanit_var"]]:
            fail("kırpma kutusu yokken kanıt fotoğrafı gönderildi")
    if S.get("tam_arac"):
        for g in tekil:
            _, img = _coz(g["kanit"])
            oran = float((_cv2.cvtColor(img, _cv2.COLOR_BGR2GRAY)[120:360, :] >= 180).mean())
            if oran < 0.50:
                fail(f"araç kısmi gönderildi — gövdenin oranı {oran:.2f} (tam araç ≈0.6)")
    if S.get("keskin"):
        ornek = gecen_ciz(np.full((480, 640, 3), 100, np.uint8), 120, 220, 0, True)
        ok_, buf = _cv2.imencode(".jpg", ornek, [int(_cv2.IMWRITE_JPEG_QUALITY), 80])
        ref = keskinlik_olc(_cv2.imdecode(buf, _cv2.IMREAD_GRAYSCALE))
        for g in tekil:
            _, img = _coz(g["kanit"])
            k = keskinlik_olc(_cv2.cvtColor(img, _cv2.COLOR_BGR2GRAY))
            if k < 0.5 * ref:
                fail(f"geçen araç bulanık gönderildi (keskinlik {k:.0f}, en keskin {ref:.0f})")
    if S.get("bekci_beklenir"):
        a, b = S["bekci_beklenir"]
        if not bekci_cagrilari or not a <= bekci_cagrilari[0] <= b:
            fail(f"bekçi takılan döngüyü {a}-{b}s içinde kapatmalıydı")
    elif bekci_cagrilari:
        fail(f"bekçi takılmayan döngüde tetiklendi (t={bekci_cagrilari[0]:.2f}s)")

    if not hata:
        print(f"PASS: {ad}")
    return hata


if __name__ == "__main__":
    sys.exit(tek_kos(sys.argv[1]) if len(sys.argv) > 1 else hepsini_kos())
