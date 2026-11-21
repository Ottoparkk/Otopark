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
#   SURUNUYOR / KACIYOR  plakasız araç önce ÇOK YAVAŞ girer (kare kare değişim
#            DURGUN_ESIGI'nin altında: "geçişten önceki" kareye kendisi girer),
#            sonra hızlanıp geçer ve gider (sahada 2026-11-07 akşamı, 1.3.1).
SURUNUYOR, KACIYOR = "surunuyor", "kaciyor"

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
    # 1.4.3: elektrik kesintisinden önce kutuya yazılmış ama gönderilememiş
    # araç, kamera açılmasını BEKLEMEDEN gider (kamera 3 sn sonra açılır).
    "kutu_kameradan_once": dict(
        sahne=[(0, 6, BOS)], sure=6.0, acilis=3.0, acilis_bekleme="0.5", pencereler=[],
        kutuda_bekleyen=1, kutu_once=1, plakalar=[(0.0, 3.0, 1)], gonderim_sayisi=1,
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
    # Plaka kırpma kutusunun alt kenarında kesik: emin okunmaz, oy almaz →
    # personele; 1.4.3 (sahibin kararı 19.11): kesik okuma kartın tahmini olur.
    "kesik_plaka": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 3.6)], kirpma="0,0,640,330",
        personele=[(1.8, 3.6, 0)], gonderim_sayisi=1,
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
    # ---- 1.3.2: "önce de vardı" kontrolü YERE bakar --------------------------
    # Sahada 2026-11-07 akşamı iki araç kayıtsız geçti: yavaş yaklaşan araç
    # "geçişten önceki" kareye girdi, köprü onu "zaten oradaydı" saydı; araç
    # gidince boş şerit o kareye benzemedi ve kayıtta "araç durdu" yazdı.
    "yavas_gelen": dict(
        sahne=[(0, 1, BOS), (1, 4, SURUNUYOR), (4, 4.9, KACIYOR), (4.9, 8, BOS)],
        sure=8.0, pencereler=[(4.9, 7.0)], personele=[(4.9, 7.0, None)],
        gonderim_sayisi=1, kayitta_sirayla=["plakasız araç geçti"],
    ),
    # Kadrajda hep duran (park etmiş) bir araç başka araçların kuralını
    # kapatmamalı: plakasız geçen araç yine personele ...
    "park_etmis_arac_gecen": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS)], park_arac=True,
        sure=6.0, pencereler=[(2.4, 4.0)], personele=[(2.4, 4.0, None)], gonderim_sayisi=1,
    ),
    # 1.3.3: en çok 3 kesilen köşe. Plakası OKUNABİLEN park etmiş araç 2.
    # alanın içinde; başka bir araç geçerken onun plakası ASLA gitmemeli
    # (tek kapıda park etmiş araca bilet açar / kapatırdı).
    "ikinci_haric_park_plakali": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR, 0), (2.4, 6, BOS)], park_plakali=3,
        sure=6.0, pencereler=[(2.4, 3.8)], plakalar=[(2.4, 3.8, 0)], gonderim_sayisi=1,
        kirpma="0,0,640,480", haric="560,0,80,60;0,395,330,85", hic_gitmez=[3],
    ),
    # 1.3.4: kırpıntı küçültülüyor (sahada 2124 → 1568 px); plaka küçük
    # kırpıntıda BULUNUR ama orada okunamayacak kadar dar — TAM çözünürlükten
    # okunur ve gider. (Kare 640 px, MAX_KENAR 320: yarıya küçülür; plaka
    # tam çözünürlükte 200 px, küçükte 100 px; okuyucu 150 px'ten darını okumaz.)
    "kucuk_kirpik_tam_okuma": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 4.0)], plakalar=[(1.8, 4.0, 0)], gonderim_sayisi=1,
        max_kenar="320", min_plaka_en=150,
    ),
    # Aynı sahne, PLAKA_TAM=0 (1.3.3 davranışı, sahadaki geri dönüş ayarı):
    # plaka okunamaz → personele.
    "kucuk_kirpik_tam_kapali": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 6, DURDU, 0)],
        sure=6.0, pencereler=[(1.8, 4.0)], personele=[(1.8, 4.0, None)], gonderim_sayisi=1,
        max_kenar="320", min_plaka_en=150, plaka_tam="0",
    ),
    # ... ve yanında duran insan, park etmiş araç yüzünden kayıt açmamalı.
    "park_etmis_arac_yaya": dict(
        sahne=[(0, 1, BOS), (1, 1.8, YAYA_GELIYOR), (1.8, 6, YAYA_DURDU)], park_arac=True,
        sure=6.0, pencereler=[], gonderim_sayisi=0, gonderilmez=[(0, 6)],
        kayitta_sirayla=["araç görülmedi"],
    ),
}

# ---- 1.4.0: araç izleme. Araçlar düz yollarda yumuşak hareket eder (izleme
# her kareyi izler); öğe: (başla, bitir, x0, y0, x1, y1, plaka no, gri değer).
# Araç 160×110; çapası (alt orta) kapı alanında mı diye bakılır. Kapı sol
# altta, karenin kenarına değer (sahadaki yeşil alan gibi).
KAPI = "0,300;300,300;380,480;0,480"
_IZ = dict(takip="1", nesne_ayri=True, model_gecikme=0.12, kapi=KAPI, pencereler=[])
GIRIS_YOLU = [(1.0, 3.0, 10, 380, 400, 60, 0, 220), (3.0, 99, 400, 60, 400, 60, 0, 220)]
CIKIS_YOLU = [(0.0, 3.0, 420, 60, 420, 60, 0, 220), (3.0, 5.0, 420, 60, 20, 400, 0, 220)]
SENARYOLAR.update({
    # Kapıdan girip otoparka geçen, duran araç: BİR plaka.
    "takip_giris": dict(_IZ, araclar=GIRIS_YOLU, sure=10.0,
                        plakalar=[(3, 10, 0)], gonderim_sayisi=1, hareketler={0: "GIRDI"},
                        yonsuz={0: False},
                        kayitta_sirayla=["araç izleme açık (kapı alanı var)", "araç girdi"]),
    # Park etmiş araç (köprü açılırken oradaydı) kapıya gidip kayboluyor: çıkış.
    "takip_cikis": dict(_IZ, araclar=CIKIS_YOLU, sure=12.0, yon="ORTAK",
                        plakalar=[(5, 12, 0)], gonderim_sayisi=1, hareketler={0: "CIKTI"},
                        kayitta_sirayla=["araç çıktı"]),
    # Otopark içinde yer değiştiren araç: kart AÇILMAZ (sahada 17 kart). 1.4.2
    # (B6, sahibin kararı): tek kapıda plakası EMİN okunduysa "içeride" ipucuyla
    # sunucuya sorulur — sunucu bileti varsa hiçbir şey yapmaz (asla kapatmaz),
    # yoksa "İçeride bileti olmayan araç" kaydı açar. Önceden: hiç gönderim.
    "takip_iceride": dict(_IZ, araclar=[(0, 3, 420, 60, 420, 60, 0, 220),
                                        (3, 4.5, 420, 60, 450, 200, 0, 220),
                                        (4.5, 99, 450, 200, 450, 200, 0, 220)],
                          sure=10.0, gonderim_sayisi=1, yon="ORTAK",
                          hareketler={0: "ICERIDE"},
                          kayitta_sirayla=["otopark içinde hareket",
                                           "içeride görülen araç sunucuya soruldu"]),
    # 1.4.3 (sahibin kararı 18.11): araç ÇIKTI diye gönderildi, az sonra aynı
    # plaka otoparkın İÇİNDE hareket etti — 60 sn belleği bu içeride sorusunu
    # yutmamalı (sunucu kameranın kapattığı bileti görür, "çıkmamış olabilir"
    # kartı açar, 072). İkinci araç aynı plakayı taşıyan sahne hilesi.
    "takip_cikip_iceride": dict(_IZ, yon="ORTAK", sure=16.0,
                                araclar=CIKIS_YOLU + [
                                    (0, 8, 450, 250, 450, 250, 0, 200),
                                    (8, 9.5, 450, 250, 480, 120, 0, 200),
                                    (9.5, 99, 480, 120, 480, 120, 0, 200)],
                                gonderim_sayisi=2, hareket_sirasi={0: ["CIKTI", "ICERIDE"]},
                                kayitta_sirayla=["araç çıktı",
                                                 "içeride görülen araç sunucuya soruldu"]),
    # Aynı sahne, plaka EMİN okunamıyor (iki kırpıntı 0.80): içeride gezen
    # araç için personele kart AÇILMAZ (17 kart dersi) — yalnızca emin plaka sorulur.
    "takip_iceride_belirsiz": dict(_IZ, guven=0.80,
                                   araclar=[(0, 3, 420, 60, 420, 60, 0, 220),
                                            (3, 4.5, 420, 60, 450, 200, 0, 220),
                                            (4.5, 99, 450, 200, 450, 200, 0, 220)],
                                   sure=10.0, gonderim_sayisi=0, yon="ORTAK",
                                   kayitta_sirayla=["otopark içinde hareket"],
                                   kayitta_yok=["sunucuya soruldu"]),
    # Aynı sahne GİRİŞ şeridinde: orada sunucu plakayla bilet AÇARDI — içeride
    # görülen araç yalnızca tek kapıda sorulur.
    "takip_iceride_giris_seridi": dict(_IZ, araclar=[(0, 3, 420, 60, 420, 60, 0, 220),
                                                     (3, 4.5, 420, 60, 450, 200, 0, 220),
                                                     (4.5, 99, 450, 200, 450, 200, 0, 220)],
                                       sure=10.0, gonderim_sayisi=0, yon="GIRIS",
                                       kayitta_sirayla=["otopark içinde hareket"],
                                       kayitta_yok=["sunucuya soruldu"]),
    # 1.4.2 (A4): sahada 11.11 19:08 — giren araç kapıdan geçerken bulucu onu
    # görmedi (koyu, plakası henüz okunmuyor), kapının hemen dışında DURURKEN
    # buldu. Kapı alanı az önce kıpırdadı, kimse açıklamıyor: kapıdan gelmiş —
    # GİRDİ (kapıda görülmedi), "girdi" ipucuyla. 1.4.1: hiçbir şey.
    "takip_gorulmeden_girip_duran": dict(
        _IZ, yon="ORTAK",
        araclar=[(1.0, 2.0, 10, 380, 150, 150, None, 150),
                 (2.0, 99, 150, 150, 150, 150, 0, 220)],
        sure=11.0, plakalar=[(2, 11, 0)], gonderim_sayisi=1, hareketler={0: "GIRDI"},
        kayitta_sirayla=["araç girdi", "kapıda görülmedi"]),
    # Aynı araç kapıdan GEÇMEDEN (kapı kıpırdamadı) orada duruyor: park etmiş
    # gibi — gönderim yok (1.4.1'in koruması aynen).
    "takip_kapi_yaninda_duran": dict(
        _IZ, yon="ORTAK", araclar=[(2.0, 99, 150, 150, 150, 150, 0, 220)],
        sure=10.0, gonderim_sayisi=0, kayitta_yok=["araç girdi"]),
    # Girip durdu, sonra park yerine ilerledi: yine BİR gönderim.
    "takip_dur_kalk": dict(_IZ, araclar=[(1, 3, 10, 380, 250, 170, 0, 220),
                                         (3, 6, 250, 170, 250, 170, 0, 220),
                                         (6, 7.5, 250, 170, 420, 60, 0, 220),
                                         (7.5, 99, 420, 60, 420, 60, 0, 220)],
                           sure=12.0, plakalar=[(3, 12, 0)], gonderim_sayisi=1),
    # Kapıdan çıkıp geri dönen: sayılmaz.
    "takip_geri_doner": dict(_IZ, araclar=[(1, 2.5, 10, 380, 330, 150, 0, 220),
                                           (2.5, 4, 330, 150, 10, 380, 0, 220)],
                             sure=10.0, gonderim_sayisi=0, yon="ORTAK",
                             kayitta_sirayla=["kapıdan geri döndü"]),
    # Kapıya giderken 1.2 sn bir şeyin arkasında kaldı: yine TEK çıkış.
    "takip_ortulme": dict(_IZ, araclar=[(0, 3, 420, 60, 420, 60, 0, 220),
                                        (3, 4, 420, 60, 250, 200, 0, 220),
                                        (5.2, 6, 150, 290, 20, 400, 0, 220)],
                          sure=12.0, yon="ORTAK", plakalar=[(6, 12, 0)], gonderim_sayisi=1),
    # Kapıda DURAN araç uzun süre görünmedi (önünde biri), sonra yine orada:
    # çıkış sayılmaz.
    "takip_kapida_park_titreme": dict(_IZ, araclar=[(0, 3, 420, 60, 420, 60, 0, 220),
                                                    (3, 5, 420, 60, 100, 330, 0, 220),
                                                    (5, 8, 100, 330, 100, 330, 0, 220),
                                                    (13, 99, 100, 330, 100, 330, 0, 220)],
                                      sure=16.0, yon="ORTAK", gonderim_sayisi=0),
    # Arka arkaya iki araç: iki plaka.
    "takip_iki_arac": dict(_IZ, araclar=GIRIS_YOLU + [(5, 7, 10, 380, 180, 40, 1, 240),
                                                      (7, 99, 180, 40, 180, 40, 1, 240)],
                           sure=12.0, plakalar=[(3, 8, 0), (7, 12, 1)], gonderim_sayisi=2),
    # Kapı alanı yok: girip duran araç bir kez; park etmiş araç hiç.
    "takip_kapisiz": dict(_IZ, kapi=None, araclar=[(0, 99, 450, 300, 450, 300, 2, 230),
                                                   (1, 3, 10, 380, 250, 100, 0, 220),
                                                   (3, 99, 250, 100, 250, 100, 0, 220)],
                          sure=10.0, plakalar=[(3, 10, 0)], gonderim_sayisi=1, hic_gitmez=[2],
                          kayitta_sirayla=["araç izleme açık (kapı alanı yok)"]),
    # Köprü açılırken kapıda duran araç otoparka geçti: dışarıdan mı geldi
    # bilinmez — personele, plaka TAHMİN olarak.
    "takip_baslangicta_kapida": dict(_IZ, araclar=[(0, 3, 50, 350, 50, 350, 0, 220),
                                                   (3, 5, 50, 350, 400, 60, 0, 220),
                                                   (5, 99, 400, 60, 400, 60, 0, 220)],
                                     sure=11.0, personele=[(5, 11, 0)], gonderim_sayisi=1),
    # 1.4.3 (sahibin kararı 17.11): aynı sahne TEK KAPIDA — emin plaka kart
    # değil PLAKA gider, yön ipucusuz, "yön bilinmiyor" işaretli; sunucu bilet
    # durumundan karar verir.
    "takip_baslangicta_kapida_tek_kapi": dict(
        _IZ, yon="ORTAK", araclar=[(0, 3, 50, 350, 50, 350, 0, 220),
                                   (3, 5, 50, 350, 400, 60, 0, 220),
                                   (5, 99, 400, 60, 400, 60, 0, 220)],
        sure=11.0, plakalar=[(5, 11, 0)], hareketler={0: None}, yonsuz={0: True},
        gonderim_sayisi=1, kayitta_sirayla=["yönü bilinmiyor — emin plaka gönderildi"]),
    # Plakasız ama net araç girdi: personele (tahminsiz).
    "takip_plakasiz_giris": dict(_IZ, araclar=[(1, 3, 10, 380, 400, 60, None, 220),
                                               (3, 99, 400, 60, 400, 60, None, 220)],
                                 sure=10.0, personele=[(3, 10, None)], gonderim_sayisi=1),
    # Kapıdan yürüyen yaya (koyu, araç değil): hiçbir şey.
    "takip_yaya": dict(_IZ, araclar=[(1, 3, 10, 380, 400, 60, None, 0),
                                     (3, 99, 400, 60, 400, 60, None, 0)],
                       sure=9.0, gonderim_sayisi=0),
    # Bulucu yok: 1.3.4 geçiş kuralı aynen (TAKIP=1 olsa da).
    "takip_bulucu_yok": dict(takip="1", arac="yok",
                             sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 7, DURDU, 0)],
                             sure=7.0, pencereler=[(1.8, 7.0)], plakalar=[(1.8, 7.0, 0)],
                             kayitta_sirayla=["araç izleme kapalı (araç bulucu yok)"]),
    # Ayar dosyasında TAKIP yok: varsayılan AÇIK.
    "takip_varsayilan": dict(_IZ, takip=None, araclar=GIRIS_YOLU, sure=10.0,
                             plakalar=[(3, 10, 0)], gonderim_sayisi=1,
                             kayitta_sirayla=["araç izleme açık"]),
    # TAKIP=0: kapı alanı verilmiş olsa da 1.3.4 geçiş kuralı.
    "takip_kapali": dict(takip="0", kapi=KAPI,
                         sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 7, DURDU, 0)],
                         sure=7.0, pencereler=[(1.8, 7.0)], plakalar=[(1.8, 7.0, 0)],
                         hareketler={0: None},           # 1.3.4 geçiş kuralı yön bilmez
                         kayitta_sirayla=["araç izleme kapalı (TAKIP=0)"]),
    # Eski kırpma (kutu + hariç alan) izlemeyle çalışır; hariç alandaki park
    # etmiş aracın plakası hiç gitmez; kanıt fotoğrafı gider (kutu var).
    "takip_eski_kirpma": dict(_IZ, kapi="380,300;640,300;640,480;400,480",
                              kirpma="0,0,640,480", haric="20,405,290,65", park_plakali=3,
                              araclar=[(1, 3, 480, 380, 250, 60, 0, 220),
                                       (3, 99, 250, 60, 250, 60, 0, 220)],
                              sure=10.0, plakalar=[(3, 10, 0)], gonderim_sayisi=1,
                              hic_gitmez=[3]),
    # Kırpma ALANI (çokgen: sol üst üçgen): alanın dışında giden araç yok sayılır.
    "takip_alan_gri": dict(_IZ, alan="0,0;640,0;0,480",
                           araclar=[(1, 4, 470, 370, 470, 250, 0, 220),
                                    (4, 99, 470, 250, 470, 250, 0, 220)],
                           sure=9.0, gonderim_sayisi=0),
    # Kırpma alanı içinde kapıdan giren araç (alan + kapı birlikte).
    "takip_alan_giris": dict(_IZ, alan="0,0;640,0;640,480;0,480",
                             araclar=GIRIS_YOLU, sure=10.0, plakalar=[(3, 10, 0)],
                             gonderim_sayisi=1, kayitta_sirayla=["kırpma alanı (4 köşe)"]),
    # Kapıdan çıkmış, karar beklerken kamera koptu: girdi sayılır (kaybolmaz).
    "takip_kopma": dict(_IZ, araclar=[(1, 3, 10, 380, 400, 60, 0, 220),
                                      (3, 99, 400, 60, 480, 80, 0, 220)],
                        kopuk=(3.4, 3.7), sure=10.0, plakalar=[(3.3, 5, 0)], gonderim_sayisi=1,
                        kayitta_sirayla=["kare alınamadı", "araç girdi", "kamera bağlandı"]),
    # Giriş şeridi çıkışı göndermez; çıkış şeridi girişi göndermez.
    "takip_giris_seridi": dict(_IZ, araclar=CIKIS_YOLU, sure=11.0, yon="GIRIS",
                               gonderim_sayisi=0, kayitta_sirayla=["yönüne ters"]),
    "takip_cikis_seridi": dict(_IZ, araclar=GIRIS_YOLU, sure=9.0, yon="CIKIS",
                               gonderim_sayisi=0, kayitta_sirayla=["yönüne ters"]),
    # Girip hemen çıkan araç: çıkış 60 sn kuralıyla gönderilmez (sunucu da yok sayar).
    "takip_ayni_plaka_60sn": dict(_IZ, yon="ORTAK",
                                  araclar=[(1, 3, 10, 380, 400, 60, 0, 220),
                                           (3, 6, 400, 60, 400, 60, 0, 220),
                                           (6, 8, 400, 60, 20, 400, 0, 220)],
                                  sure=14.0, plakalar=[(3, 8, 0)], gonderim_sayisi=1,
                                  kayitta_sirayla=["araç girdi", "araç çıktı"]),
    # Bekçi izleme kipinde de takılan döngüyü kapatır.
    "takip_takilma": dict(_IZ, araclar=[], sure=8.0, takilir=2.0, bekci="2",
                          bekci_beklenir=(3.5, 7.5),
                          kayitta_sirayla=["araç izleme açık", "köprü takıldı"]),
    # Bulucunun görmediği (koyu) araç, plakası okunuyor: plaka izinden girdi.
    "takip_sahipsiz_plaka": dict(_IZ, araclar=[(1, 3, 10, 380, 400, 60, 0, 150),
                                               (3, 99, 400, 60, 400, 60, 0, 150)],
                                 sure=10.0, plakalar=[(3, 10, 0)], gonderim_sayisi=1),
    # Bulucu çalışırken bozuldu: kapıdan geçmiş araç girdi sayılır, sonraki
    # araç 1.3.4 geçiş kuralıyla gelir.
    "takip_bulucu_bozuldu": dict(_IZ, bulucu_bozulur=3.6,
                                 araclar=GIRIS_YOLU + [(8, 9.5, 10, 380, 150, 250, 1, 240),
                                                       (9.5, 99, 150, 250, 150, 250, 1, 240)],
                                 sure=15.0, plakalar=[(3.5, 7, 0), (8, 15, 1)],
                                 gonderim_sayisi=2,
                                 kayitta_sirayla=["araç izleme açık", "araç izleme kapandı"]),
    # 1.4.3: bulucu bir an çöktü, sonra yine çalışıyor: bir sonraki geçişte
    # yeniden denenir, döner; izleme (o geçiş bitince) yeniden açılır — sonraki
    # araç yine izlenir ve yön ipucuyla gider. Önceden köprü yeniden başlayana
    # kadar 1.3.4 kuralında kalıyordu.
    "takip_bulucu_geri_geldi": dict(
        _IZ, bulucu_bozuk=(3.6, 7.5), yeniden_dene=1.0,
        araclar=GIRIS_YOLU + [(8, 9.5, 10, 380, 200, 40, 1, 240), (9.5, 99, 200, 40, 200, 40, 1, 240),
                              (17, 19, 10, 380, 20, 60, 2, 230), (19, 99, 20, 60, 20, 60, 2, 230)],
        sure=24.0, plakalar=[(3.5, 7, 0), (8, 15, 1), (17, 24, 2)], gonderim_sayisi=3,
        hareketler={0: "GIRDI", 1: None, 2: "GIRDI"},
        kayitta_sirayla=["araç izleme açık", "araç bulucu çalışmıyor", "araç izleme kapandı",
                         "araç bulucu yeniden çalışıyor", "araç izleme açık (yeniden)"]),
    # 1.4.1: kapıda GÖRÜLMEYEN araç. Yavaş dizüstü (model 0.25 sn). Araç tek
    # doğru üzerinde sabit hızla (300, -150) px/sn gider; kapıdayken bulucu
    # görmez (koyu, plakasız: bulanık / yarısı görünür), kapının kenarını 6 px
    # geçince görünür. 1.4.0: otopark içi hareket, gönderim yok.
    "takip_hizli_giris": dict(_IZ, model_gecikme=0.25,
                              araclar=[(1.0, 2.042, -80, 360, 233, 204, None, 150),
                                       (2.042, 2.842, 233, 204, 473, 84, 0, 220),
                                       (2.842, 99, 473, 84, 473, 84, 0, 220)],
                              sure=10.0, plakalar=[(2, 10, 0)], gonderim_sayisi=1,
                              kayitta_sirayla=["araç girdi", "kapıda görülmedi"]),
    # Tersi: park etmiş araç kapıya gider, kapıya 6 px kala bulucu görmez olur.
    "takip_hizli_cikis": dict(_IZ, model_gecikme=0.25, yon="ORTAK",
                              araclar=[(0.0, 3.0, 473, 84, 473, 84, 0, 220),
                                       (3.0, 3.8, 473, 84, 233, 204, 0, 220),
                                       (3.8, 4.842, 233, 204, -80, 360, None, 150)],
                              sure=12.0, plakalar=[(3.8, 12, 0)], gonderim_sayisi=1,
                              kayitta_sirayla=["araç çıktı", "kapıda görülmedi"]),
    # Gece: gövde kapıda karanlıkta (bulucu görmez), plakası okunur; otoparkta
    # lambanın altında görünür olur. 1.4.0: plaka izi silinir, araç izi
    # otoparkta doğar — gönderim yok.
    # Bulucunun yalnızca BİR karede gördüğü, kapının yanından geçen plakasız
    # araç (açık, net): yönü bilinmez — personele (tahminsiz). 1.4.1'in ilk
    # hâli: hiçbir şey. Otoparkın derinindeki tek kare gönderilmez.
    "takip_tek_kare": dict(_IZ, arac_bir_kez=True, sure=11.0,
                           araclar=[(1.0, 2.0, 330, 200, 150, 260, None, 220)],
                           personele=[(1, 11, None)], gonderim_sayisi=1,
                           kayitta_sirayla=["araç tek karede görüldü"]),
    # Plakası hiç görülmeyen, bulucunun 0.45 verdiği araç kapıdan girip durdu
    # (sahada 2026-11-10: 0.46 / 0.54 araçlar sessizce düştü). Kapıdan geçtiği
    # izlendi: personele (tahminsiz). 1.4.1'in önceki hâli (0.60): hiçbir şey.
    "takip_plakasiz_zayif": dict(_IZ, arac_puan=0.45,
                                 araclar=[(1, 3, 10, 380, 400, 60, None, 220),
                                          (3, 99, 400, 60, 400, 60, None, 220)],
                                 sure=10.0, personele=[(3, 10, None)], gonderim_sayisi=1),
    # Her karede plaka doğru ama iki kırpıntıdan biri %95'in altında (0.94 /
    # 0.60): araç kapıdan girerken farklı görünümlerde aynı okundu → birleşik
    # emin, PLAKA gider (1.4.1 öncesi: tahminle personele).
    "takip_birlesik": dict(_IZ, guven=0.94, guven_iki=0.60, araclar=GIRIS_YOLU, sure=10.0,
                           plakalar=[(3, 10, 0)], gonderim_sayisi=1,
                           kayitta_sirayla=["araç girdi", "birleşik"]),
    # Aynı sahne, PLAKA_BIRLESIK=0: bugünkü kural — personele, tahminle.
    "takip_birlesik_kapali": dict(_IZ, guven=0.94, guven_iki=0.60, araclar=GIRIS_YOLU,
                                  sure=10.0, birlesik="0", personele=[(3, 10, 0)],
                                  gonderim_sayisi=1),
    # 1.4.2 (A3): aynı tek kare, araç puanı 0.49 (sahada 11.11 13:52, plaka
    # yok): 0.60'ın altında 1.4.1 hiçbir şey göndermiyordu — doğum eşiğinden
    # (0.35) personele.
    "takip_tek_kare_zayif": dict(_IZ, arac_bir_kez=True, arac_puan=0.49, sure=11.0,
                                 araclar=[(1.0, 2.0, 330, 200, 150, 260, None, 220)],
                                 personele=[(1, 11, None)], gonderim_sayisi=1,
                                 kayitta_sirayla=["araç tek karede görüldü"]),
    # 1.4.3 (sahibin kararı 20.11): aynı tek kare, ama puanı MOTOSİKLETTEN
    # (19.11 17:38 el arabası: tek kare, 0.41, kart fotoğrafı motosiklet 0.50).
    # YOLO11s'in motosiklet eşiği (0.60) altında: kart yok, kayıtta sınıfıyla.
    "takip_tek_kare_moto": dict(_IZ, arac_bir_kez=True, arac_puan=0.49, arac_sinif=3,
                                moto_esik=0.60, sure=11.0,
                                araclar=[(1.0, 2.0, 330, 200, 150, 260, None, 220)],
                                gonderim_sayisi=0,
                                kayitta_sirayla=["araç tek karede görüldü",
                                                 "(araç 0.49 motosiklet)"]),
    # Gerçek motosiklet net görülür (sahibinin skuterleri 0.77-0.92): kart gider.
    "takip_tek_kare_moto_guclu": dict(_IZ, arac_bir_kez=True, arac_puan=0.75, arac_sinif=3,
                                      moto_esik=0.60, sure=11.0,
                                      araclar=[(1.0, 2.0, 330, 200, 150, 260, None, 220)],
                                      personele=[(1, 11, None)], gonderim_sayisi=1,
                                      kayitta_sirayla=["araç tek karede görüldü",
                                                       "(araç 0.75 motosiklet)"]),
    # Kapıdan GİRDİĞİ izlenen plakasız motosiklet: kural yalnızca yönü
    # bilinmeyen olaylarda — takip_plakasiz_zayif gibi personele.
    "takip_plakasiz_zayif_moto": dict(_IZ, arac_puan=0.45, arac_sinif=3, moto_esik=0.60,
                                      araclar=[(1, 3, 10, 380, 400, 60, None, 220),
                                               (3, 99, 400, 60, 400, 60, None, 220)],
                                      sure=10.0, personele=[(3, 10, None)], gonderim_sayisi=1,
                                      kayitta_sirayla=["araç girdi", "(araç 0.45 motosiklet)"]),
    # 1.4.2 (A3 koruması): park etmiş araç kapıdan alt kenara çıkar; çıkarken
    # aracın son kutusu tam (kenara değiyor), hemen ardından bulucu yalnızca
    # KUYRUĞUNU (kenarda 25 px'lik şerit, araç 0.40) bir kez ayrı kutu görür
    # (takip_gece_hizli_cikis'te görülen) — kutu son kutunun ~¼'ü, araca
    # dikilmez, tek karelik iz doğar.
    # Yanında az önce görülmüş araç var (komşulu): 0.60 eşiği, kart YOK.
    # A3 korumasız: plaka çıkışının yanına ikinci (personele) kart.
    "takip_kenar_kuyrugu": dict(
        _IZ, yon="ORTAK",
        araclar=[(0.0, 3.0, 420, 60, 420, 60, 0, 220),
                 (3.0, 4.9, 420, 60, 150, 370, 0, 220),
                 (4.95, 5.15, 150, 455, 150, 455, None, 230, 160, 25)],
        sure=12.0, plakalar=[(5, 12, 0)], gonderim_sayisi=1,
        kayitta_sirayla=["araç çıktı", "araç tek karede görüldü"]),
    # 1.4.3 (1a): park etmiş araç kapıdan alt kenara çıkar — kutusu ~0.6 sn
    # kenarda kesik (gerçek çıkış böyle) — ardından bulucu kuyruğunu (kenarda
    # 130×25 px şerit, 0.4 sn; son kesik kutuyla örtüşmesi ~0.20, ESLES_IOU'nun
    # altında — 160 px'te araç 400'e inerken 0.31 idi, kare zamanlamasına göre
    # kuyruk kimi koşuda araca bağlanıyor, kimi koşuda parça oluyordu) ayrı iz
    # görür. Her kutu
    # 0.70 (kuyruk da kart eşiğini geçer): bugün plakanın yanına ikinci
    # (personele) kart. PARCA_EMME=0 (varsayılan, yalnızca kayıt): iki
    # gönderim yine gider, kayıt "sayılırdı".
    "takip_kenar_kuyrugu_kayit": dict(
        _IZ, yon="ORTAK", arac_puan=0.70,
        araclar=[(0.0, 3.0, 420, 60, 420, 60, 0, 220),
                 (3.0, 4.6, 420, 60, 150, 370, 0, 220),
                 (4.6, 5.2, 150, 370, 150, 380, 0, 220),
                 (5.25, 5.65, 150, 455, 150, 455, None, 230, 130, 25)],
        sure=13.0, plakalar=[(5, 13, 0)], personele=[(5, 13, None)], gonderim_sayisi=2,
        kayitta_sirayla=["parça emme yalnızca kayıtta (PARCA_EMME=0)", "araç çıktı",
                         "aynı aracın parçası sayılırdı"]),
    # PARCA_EMME=1: kuyruğun kartı gitmez — bir araç, bir gönderim.
    "takip_kenar_kuyrugu_emme": dict(
        _IZ, yon="ORTAK", arac_puan=0.70, ortam={"PARCA_EMME": "1"},
        araclar=[(0.0, 3.0, 420, 60, 420, 60, 0, 220),
                 (3.0, 4.6, 420, 60, 150, 370, 0, 220),
                 (4.6, 5.2, 150, 370, 150, 380, 0, 220),
                 (5.25, 5.65, 150, 455, 150, 455, None, 230, 130, 25)],
        sure=13.0, plakalar=[(5, 13, 0)], gonderim_sayisi=1,
        kayitta_sirayla=["parça emme açık (PARCA_EMME=1)", "araç çıktı",
                         "aynı aracın parçası sayıldı"],
        kayitta_yok=["personele"]),
    # 1.4.2 (E12): `--video` — takip_giris'in sahnesi bir video DOSYASINA
    # yazılıp gerçek köprü döngüsünden geçirilir: plaka "girdi" ipucuyla
    # özette, hiçbir şey ağa gitmez, kayıt geçici klasörde, plaka kayıtta yok.
    "video_tekrar": dict(_IZ, yon="ORTAK", araclar=GIRIS_YOLU, video=True,
                         video_sure=6.0, kuyruk_sn=6.0, sure=30.0,
                         video_plakalar=[(0, "GIRDI")], video_gonderim=1,
                         video_sayilar={"giris": 1, "cikis": 0}),
    "takip_tek_kare_otoparkta": dict(_IZ, arac_bir_kez=True,
                                     araclar=[(1.0, 2.0, 470, 20, 470, 60, None, 220)],
                                     sure=9.0, gonderim_sayisi=0),
    # 1.4.2: eşikler YÜKLENEN bulucunun (modelin). Grafik işlemcisinde YOLO11s
    # (puan ölçeği YOLOX'tan düşük, eşikleri 0.20 / 0.45 varsayalım); 0.30 alan
    # plakasız araç kapıdan girip durdu: izlenir ve personele gider. 1.4.1
    # ayardaki 0.35'i okurdu — araç doğmaz, sessizce düşerdi.
    "takip_gpu_esikleri": dict(_IZ, gpu=True, arac_esikleri=(0.20, 0.45), arac_puan=0.30,
                               araclar=[(1, 3, 10, 380, 400, 60, None, 220),
                                        (3, 99, 400, 60, 400, 60, None, 220)],
                               sure=10.0, personele=[(3, 10, None)], gonderim_sayisi=1,
                               kayitta_sirayla=["modeller çalışıyor: GPU · YOLO11s",
                                                "araç bulucu hazır (duran ≥0.20, geçen ≥0.45)",
                                                "araç girdi"]),
    # Aynı araç, ama grafik işlemcisi araç gelmeden bozuldu ve bulucu tiny'ye
    # (0.35 / 0.60) geçti: izci de yeni doğum eşiğini kullanır — 0.30 araç
    # doğmaz (tiny ölçeğinde zayıf), hiçbir şey gönderilmez.
    "takip_gpu_tiny_ye_gecti": dict(_IZ, gpu=True, arac_esikleri=(0.20, 0.45),
                                    esik_degisir=(0.5, (0.35, 0.60)), arac_puan=0.30,
                                    araclar=[(1, 3, 10, 380, 400, 60, None, 220),
                                             (3, 99, 400, 60, 400, 60, None, 220)],
                                    sure=10.0, gonderim_sayisi=0,
                                    kayitta_yok=["araç girdi"]),
    # 1.4.2: grafik işlemcisi kayıp ve geri gelmiyor (bulucu işlemcide, her
    # deneme başarısız). Süreler kısaltıldı: 0.5 sn'de bir dener, 2 sn sonra
    # yeniden başlatma gerekir — ama ancak SAKİN anda: araç girip kararı
    # verildikten sonra, bir kez (zaman diske yazılır, saatte en çok bir).
    "takip_gpu_kayip_yeniden_baslat": dict(
        _IZ, gpu=True, gpu_kayip=True, araclar=GIRIS_YOLU, sure=10.0,
        plakalar=[(3, 10, 0)], gonderim_sayisi=1, gpu_cikis=True,
        gpu_cikis_en_erken=4.5,                   # araç 3.0'te durdu + 2 sn sakinlik
        ortam={"GPU_GERI_DENE_SN": "0.5", "GPU_YENIDEN_BASLAT_SN": "2",
               "GPU_SAKIN_SN": "2", "GPU_YENIDEN_ARALIK_SN": "3600"},
        kayitta_sirayla=["grafik işlemcisi hâlâ kullanılamıyor", "araç girdi",
                         "grafik işlemcisi için köprü yeniden başlatılıyor"]),
    # Aynısı 1.3.4 geçiş kuralında (TAKIP=0): sakin an = süren geçiş yok, iki
    # model boşta, GPU_SAKIN_SN'dir güçlü hareket yok.
    "gpu_kayip_gecis_kurali": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR, 0), (1.8, 8, DURDU, 0)],
        sure=8.0, pencereler=[(1.8, 4.0)], plakalar=[(1.8, 4.0, 0)], gonderim_sayisi=1,
        gpu=True, gpu_kayip=True, gpu_cikis=True,
        gpu_cikis_en_erken=3.5,                   # araç 1.8'de durdu + 2 sn sakinlik
        ortam={"GPU_GERI_DENE_SN": "0.5", "GPU_YENIDEN_BASLAT_SN": "2",
               "GPU_SAKIN_SN": "2", "GPU_YENIDEN_ARALIK_SN": "3600"},
        kayitta_sirayla=["grafik işlemcisi hâlâ kullanılamıyor",
                         "grafik işlemcisi için köprü yeniden başlatılıyor"]),
    "takip_karanlik_giris": dict(_IZ, araclar=[(1.0, 2.0, 10, 380, 300, 150, 0, 150),
                                               (2.0, 3.0, 300, 150, 400, 60, 0, 220),
                                               (3.0, 99, 400, 60, 400, 60, 0, 220)],
                                 sure=10.0, plakalar=[(2, 10, 0)], gonderim_sayisi=1,
                                 kayitta_sirayla=["araç girdi"]),
    # 1.4.2 (A1): GECE hızlı çıkan araç (sahada 07:38 / 19:15 / 19:39). Küçük
    # araç kadrajın dışından girer (birden belirmez) ve kapıdan kenara gider;
    # bütün kırpıntının ortalama farkı her karede < 2.0 (dusuk_fark denetler —
    # sahada gece 0.27). 1.4.1: izlenmeyen araca yalnızca 2 sn'de bir kare
    # bakılır → araç ilk kez kapıda bulunur → kayıp. Yerel kıpırtı (yama)
    # tetiği aracı otoparkta yakalar → ÇIKTI, plakasıyla. Araç yukarıdan
    # (kadraj dışından) iner, otoparkta ~0.6 sn görünür. Üç araç, aralarında
    # > 6 sn: kaybolan iz DIKIS_SN (4 sn) boyunca kare ister — araçlar sık
    # gelirse eski kod da yakalar; 2 sn'lik yoklamanın şans eseri yakalaması da
    # üç araçta birden olmasın.
    "takip_gece_hizli_cikis": dict(
        _IZ, yon="ORTAK", dusuk_fark=True,
        araclar=[(1.0, 2.45, 200, -100, 200, 480, 0, 220, 130, 100),
                 (8.5, 9.95, 200, -100, 200, 480, 1, 220, 130, 100),
                 (15.7, 17.15, 200, -100, 200, 480, 2, 220, 130, 100)],
        sure=23.0, plakalar=[(1.0, 8.5, 0), (8.5, 15.7, 1), (15.7, 23, 2)], gonderim_sayisi=3,
        # 1.4.3: üçü de ÇIKTI ipucuyla — kapıda ilk kez bulunan araç (yerel
        # tetik olmadan) emin plakasıyla yine gider ama YÖNSÜZ (1c), sayı
        # tek başına farkı göstermez.
        hareketler={0: "CIKTI", 1: "CIKTI", 2: "CIKTI"},
        kayitta_sirayla=["model karesi", "araç çıktı"]),
    # 1.4.2 (A2): araç ilk kez KAPI alanında bulunur ve kenardan çıkar (hızlı,
    # koyu). Nereden geldiği bilinmez: ÇIKTI sayılmaz — ama 1.4.1 onu sessizce
    # düşürüyordu (ne kart ne kayıt). Şimdi personele.
    "takip_kapida_dogan_cikis": dict(
        _IZ, yon="ORTAK", araclar=[(1.0, 2.0, 150, 330, 60, 480, None, 220)],
        sure=10.0, personele=[(1.0, 10.0, None)], gonderim_sayisi=1,
        kayitta_sirayla=["araç kapı alanında kayboldu"]),
    # 1.4.2 (A2): otoparkın ortasında biraz kıpırdayıp kaybolan araç: karar
    # yok, gönderim yok — ama kayıtta TEK satır (sessiz kayıp görünür olsun).
    "takip_kararsiz_iz": dict(
        _IZ, yon="ORTAK", araclar=[(1.0, 1.6, 420, 60, 470, 60, None, 220)],
        sure=10.0, gonderim_sayisi=0, kayitta_sirayla=["iz kararsız bitti"]),
})

# 1.4.3 (1d): klip kaydedici (KLIP=1) — aynı kuyruk sahnesi. "klipler": klip
# klasöründeki .avi'ler (ad sırasıyla): (olay deseni, ek) — parça bir kare
# görüldüyse TEK_KARE, iki kare KAPIDA_KAYBOLDU (zamanlamaya bağlı). ek bir gönderim türüyse
# adın sonu o türde GÖNDERİLEN olayın islem_id'sinin ilk 8'i; "emildi" ise
# parça gönderilmedi. "klipler" yoksa klip klasörü HİÇ açılmamalı (varsayılan
# kapalı: her senaryo bunu sınar). Klip olaydan 5 sn sonrasını da bekler.
SENARYOLAR.update({
    "takip_kenar_kuyrugu_klip": dict(
        SENARYOLAR["takip_kenar_kuyrugu_kayit"], ortam={"KLIP": "1"}, sure=17.0,
        plakalar=[(5, 17, 0)], personele=[(5, 17, None)],
        klipler=[("TEK_KARE|KAPIDA_KAYBOLDU", "OKUNAMADI")],
        kayitta_sirayla=["klip kaydı açık (KLIP=1)", "araç çıktı",
                         "aynı aracın parçası sayılırdı", "klip yazıldı"]),
    "takip_kenar_kuyrugu_emme_klip": dict(
        SENARYOLAR["takip_kenar_kuyrugu_emme"], ortam={"PARCA_EMME": "1", "KLIP": "1"},
        sure=17.0, plakalar=[(5, 17, 0)],
        klipler=[("TEK_KARE|KAPIDA_KAYBOLDU", "emildi")],
        kayitta_sirayla=["klip kaydı açık (KLIP=1)", "araç çıktı",
                         "aynı aracın parçası sayıldı", "klip yazıldı"]),
})

# ---- 1.4.3 PARK_GORUNUR (sahip 19.11): kırpma alanı sağ altı dışarıda bırakır
# (park yeri); kapı alanın içinde. Anahtar açıkken modeller dışarıyı da görür,
# olay yalnızca alana girmiş araçtan; fotoğraf yine maskeli ("foto_gri": o
# bölge fotoğrafta düz gri).
PG_ALAN = "0,0;640,0;640,250;420,250;420,480;0,480"
PG_PARK = (0, 99, 460, 320, 460, 320, 3, 230)          # plakalı, alanın dışında park etmiş
# Sahibin derdi: boşken giren araç kapıdan geçip mavinin DIŞINDAN gider ve
# orada durur; plakası yalnızca oradayken okunur (kapıda ve yolda bulanık).
PG_DISARIDAN = [(1.0, 2.5, 10, 380, 440, 260, None, 220),
                (2.5, 3.5, 440, 260, 470, 330, 0, 220),
                (3.5, 99, 470, 330, 470, 330, 0, 220)]
SENARYOLAR.update({
    # Bugün (anahtar kapalı): araç griye girince kaybolur, plakası hiç okunmaz
    # — personele plakasız kart (sahadaki "yarım görülen plaka").
    "takip_park_gorunur_disaridan_giris_kapali": dict(
        _IZ, alan=PG_ALAN, araclar=PG_DISARIDAN, sure=10.0,
        gonderim_sayisi=1, personele=[(4, 10, None)]),
    # Açık: araç izlenmeye devam eder, plakası alanın dışında okunur → GİRDİ.
    # Güven 0.97 (tek görünüm eşiği 0.99'un altı): plaka ancak dışarıda İKİ
    # görünümde okunursa emin — izcinin piksel ölçüsü de dışarıyı görmeli.
    "takip_park_gorunur_disaridan_giris": dict(
        _IZ, alan=PG_ALAN, araclar=PG_DISARIDAN, sure=10.0, ortam={"PARK_GORUNUR": "1"},
        guven=0.97,
        plakalar=[(4, 10, 0)], gonderim_sayisi=1, hareketler={0: "GIRDI"},
        kayitta_sirayla=["park görünür (PARK_GORUNUR=1)", "araç girdi"]),
    # Kapıdan girip alanda duran araç; dışarıda plakalı park aracı hiç gitmez,
    # fotoğrafta o bölge gri kalır.
    "takip_park_gorunur_giris": dict(
        _IZ, alan=PG_ALAN, araclar=GIRIS_YOLU + [PG_PARK], sure=10.0,
        ortam={"PARK_GORUNUR": "1"}, plakalar=[(3, 10, 0)], gonderim_sayisi=1,
        hareketler={0: "GIRDI"}, hic_gitmez=[3], foto_gri=[(460, 320, 620, 430)],
        kayitta_sirayla=["park görünür (PARK_GORUNUR=1)", "araç girdi"]),
    # takip_alan_gri anahtar açıkken: alanın dışında yürüyüp duran araç yine
    # hiçbir şey göndermez, not da düşmez. Tek kapıda (ORTAK) otopark içi
    # hareket bile sunucuya sorulurdu — alan dışındaki izden hiç olay çıkmaz.
    "takip_park_gorunur_alan_gri": dict(
        SENARYOLAR["takip_alan_gri"], ortam={"PARK_GORUNUR": "1"}, yon="ORTAK",
        kayitta_yok=["iz kararsız bitti"]),
    # TAKIP=0 (1.3.4 geçiş kuralı) maskeli kalır: park aracının plakası gitmez.
    # Araç GIRIS_YOLU'ndakinden büyük ve hızlı: 1.3.4 kuralı kare farkıyla
    # çalışır; GIRIS_YOLU'nda fark ≈ 2 (hızlıyken ≈ 5.6) HAREKET_ESIGI'nin (6)
    # altında kalıp geçişi kimi koşuda hiç başlatmıyordu.
    "takip_park_gorunur_gecis_kurali": dict(
        takip="0", nesne_ayri=True, kapi=KAPI, alan=PG_ALAN, pencereler=[],
        araclar=[(1.0, 1.5, 10, 380, 400, 60, 0, 220, 240, 160),
                 (1.5, 99, 400, 60, 400, 60, 0, 220, 240, 160), PG_PARK],
        sure=10.0, ortam={"PARK_GORUNUR": "1"},
        plakalar=[(1.5, 10, 0)], hic_gitmez=[3], foto_gri=[(460, 320, 620, 430)],
        kayitta_sirayla=["araç izleme kapalı (TAKIP=0)"],
        kayitta_yok=["park görünür"]),
    # Eski kırpma (kutu + hariç) ile anahtarın etkisi yok: takip_eski_kirpma'nın aynısı.
    "takip_park_gorunur_eski_kirpma": dict(
        SENARYOLAR["takip_eski_kirpma"], ortam={"PARK_GORUNUR": "1"},
        kayitta_sirayla=["PARK_GORUNUR=1 yalnızca kırpma alanıyla"]),
})

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
        # 1.4.1: ikinci (geniş) kırpıntının güveni ayrı — sahadaki 35CKM57
        # 0.94 / 0.53 gibi okumalar (çok karede birleştirme senaryosu).
        self.guven_iki = float(S.get("guven_iki", self.guven))
        # 1.3.4: plaka bu kadar pikselden darsa okunamaz (küçük harfler gibi).
        self.min_en = float(S.get("min_plaka_en", 0))
        # 1.4.0: sahadaki gibi yavaş model (kare başına ~0.15 sn → ~6 kare/sn).
        self.gecikme = float(S.get("model_gecikme", 0))
        self.ayri = bool(S.get("nesne_ayri"))

    @staticmethod
    def _maske(img: np.ndarray) -> np.ndarray:
        return (img[:, :, 2] >= 250) & (img[:, :, 0] <= 5) & (img[:, :, 1] >= 3)

    def bul(self, kirpik: np.ndarray):
        import plaka as _p
        if self.gecikme:
            time.sleep(self.gecikme)
        m = self._maske(kirpik)
        if int(m.sum()) < 50:
            return []
        if self.ayri:
            # 1.4.0 izleme senaryoları: kadrajda birden çok plaka olur (gerçek
            # bulucu gibi her plakaya ayrı kutu). Şeritler arası boşluk kapatılır.
            import cv2 as _cv2
            b = _cv2.dilate(m.astype(np.uint8), np.ones((1, 9), np.uint8))
            n, _, st, _ = _cv2.connectedComponentsWithStats(b)
            kutular = []
            for i in range(1, n):
                x, y, w, h, a = (int(q) for q in st[i])
                if a >= 50:
                    kutular.append(_p.Kutu(float(x), float(y), float(x + w), float(y + h), 0.9))
            return kutular
        ys, xs = np.nonzero(m)
        return [_p.Kutu(float(xs.min()), float(ys.min()), float(xs.max() + 1),
                        float(ys.max() + 1), 0.9)]

    def oku_cift(self, kirpik: np.ndarray, k):
        if k.x2 - k.x1 < self.min_en:
            return []
        bolge = kirpik[int(k.y1):int(k.y2), int(k.x1):int(k.x2)]
        m = self._maske(bolge)
        if not m.any():
            return []
        no = int(round((float(np.median(bolge[:, :, 1][m])) - 5) / 10))
        metin = PLAKALAR[no % len(PLAKALAR)]
        ikinci = metin[:-1] + ("8" if metin[-1] != "8" else "9") if self.anlasmazlik else metin
        return [(metin, self.guven), (ikinci, self.guven_iki)]


class SahteArac:
    """
    arac.AracBulucu yerine: her açık gri (≥200) bölge bir araç kutusu; puan
    bölgenin kırpıntıdaki payıyla büyür (0.3 + 1.6 × pay): tam görünen araç
    ≈0.92, park etmiş köşedeki araç ≈0.47. Koyu şekil (yaya, gölge) ve boş
    şerit hiç kutu vermez. En iyi kare aracın en büyük göründüğü karedir.
    """

    def __init__(self, S: dict | None = None):
        S = S or {}
        # 1.4.2: eşikler bulucunun (modelin) — YOLO11s'inki tiny'ninkinden farklı;
        # "esik_degisir": (t, eşikler) — grafik işlemcisi bozulup tiny'ye geçti.
        self._esikler = tuple(S.get("arac_esikleri", (0.35, 0.60)))
        self._degisir = S.get("esik_degisir")
        # 1.4.2: GpuGeriDonus'un baktığı yüz — gpu_kayip: bulucu işlemcide.
        self.gpu_da = not S.get("gpu_kayip")
        self.gecikme = float(S.get("model_gecikme", 0))
        # 1.4.0 izleme senaryoları: her araç kendi gri değeriyle (210/220/230/240)
        # AYRI nesne — yan yana iki araç tek kutu olmasın. Puan 0.3 + 8 × pay:
        # tam görünen 160×110 araç ≈0.76, yarısı görünen ≈0.53.
        self.ayri = bool(S.get("nesne_ayri"))
        self.hata_sonra = S.get("bulucu_bozulur")
        # 1.4.3: (a, b) — bulucu yalnızca bu aralıkta çöker, sonra yine çalışır.
        self.hata_aralik = S.get("bulucu_bozuk")
        # 1.4.1: bulucu aracı yalnızca İLK karede görür (hızlı / bulanık araç)
        # — gerçek zamanlı testte "tek kare" ancak böyle kesinleşir.
        self.bir_kez = bool(S.get("arac_bir_kez"))
        self._goruldu = False
        # 1.4.1: her araç kutusunun puanı sabit (sahada plakasız düşen araçlar
        # 0.46 / 0.54 aldı) — eşik kuralını gerçek zamanlı sınamak için.
        self.puan = S.get("arac_puan")
        # 1.4.3: kutuların sınıfı (COCO; None = bilinmiyor, bugünkü gibi) ve
        # bulucunun motosiklet eşiği (YOLO11s'te 0.60; None = kural yok).
        self.sinif = S.get("arac_sinif")
        self.moto_esik = S.get("moto_esik")

    def _simdiki(self) -> tuple:
        if self._degisir is not None and time.monotonic() - T0 >= self._degisir[0]:
            return tuple(self._degisir[1])
        return self._esikler

    @property
    def esik(self) -> float:
        return self._simdiki()[0]

    @property
    def gecis_esik(self) -> float:
        return self._simdiki()[1]

    def kutular(self, kirpik: np.ndarray, haric):
        kutular, insan = self._kutular(kirpik, haric)
        if self.puan is not None:
            kutular = [k._replace(skor=float(self.puan)) for k in kutular]
        if self.sinif is not None:
            kutular = [k._replace(sinif=int(self.sinif)) for k in kutular]
        if self.bir_kez:
            if self._goruldu:
                return [], insan
            self._goruldu = bool(kutular)
        return kutular, insan

    def _kutular(self, kirpik: np.ndarray, haric):
        import cv2 as _cv2
        import arac as _a
        if self.gecikme:
            time.sleep(self.gecikme)
        if self.hata_sonra is not None and time.monotonic() - T0 >= self.hata_sonra:
            raise RuntimeError("araç modeli çöktü (test)")
        if self.hata_aralik is not None and                 self.hata_aralik[0] <= time.monotonic() - T0 < self.hata_aralik[1]:
            raise RuntimeError("araç modeli çöktü (test)")
        if self.ayri:
            alan = float(kirpik.shape[0] * kirpik.shape[1])
            kutular = []
            for v in (210, 220, 230, 240):
                m = ((kirpik[:, :, 0] == v) & (kirpik[:, :, 1] == v)
                     & (kirpik[:, :, 2] == v)).astype(np.uint8)
                n, _, st, _ = _cv2.connectedComponentsWithStats(m)
                for i in range(1, n):
                    x, y, w, h, a = (int(q) for q in st[i])
                    if a / alan >= 0.01:
                        kutular.append(_a.AracKutu(float(x), float(y), float(x + w), float(y + h),
                                                   min(0.99, 0.3 + 8 * a / alan)))
            return sorted(kutular, key=lambda k: -k.skor), 0.0
        maske = (kirpik.min(axis=2) >= 200).astype(np.uint8)
        n, _, st, _ = _cv2.connectedComponentsWithStats(maske)
        alan = float(kirpik.shape[0] * kirpik.shape[1])
        kutular = []
        for i in range(1, n):
            x, y, w, h, a = (int(v) for v in st[i])
            if a / alan >= 0.01:
                kutular.append(_a.AracKutu(float(x), float(y), float(x + w), float(y + h),
                                           min(0.99, 0.3 + 1.6 * a / alan)))
        return sorted(kutular, key=lambda k: -k.skor), 0.0

    def skor(self, kirpik: np.ndarray, haric):
        kutular, insan = self.kutular(kirpik, haric)
        return (kutular[0].skor if kutular else 0.0), insan


def hepsini_kos() -> int:
    import kalinti
    kok = kalinti.klasor("otopark-test-kopru-")       # tek klasörde (kalinti.py)
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


def video_senaryosu(S: dict, kopru, izleme_karesi, gonderimler: list, kalpler: list) -> int:
    """
    1.4.2 (E12): bir kaydı GERÇEK köprü döngüsünden geçir (video.oynat).
    Senaryonun sahnesi (izleme_karesi) KAYIPSIZ bir video dosyasına yazılır
    (sahte bulucu tam gri değerlere bakar), sonra oynatılır. Beklenen:
    gidecek olan plaka (yön ipucuyla) ÖZETTE; hiçbir istek ağa — bu
    senaryonun sahte sunucusuna da — gitmez; kayıt ve kutu geçici klasörde;
    özet (plaka içerir) kayıt dosyasına YAZILMAZ.
    """
    import tempfile
    import cv2 as _cv2
    import video
    yol = os.path.join(tempfile.mkdtemp(prefix="otopark-video-"), "kayit.avi")
    fps = 25.0
    yazici = None
    for kod in ("FFV1", None):
        fourcc = _cv2.VideoWriter_fourcc(*kod) if kod else 0
        yazici = _cv2.VideoWriter(yol, fourcc, fps, (640, 480))
        if yazici.isOpened():
            break
    if yazici is None or not yazici.isOpened():
        print("FAIL: kayıpsız video yazılamadı (FFV1 / ham)")
        return 1
    n = int(S["video_sure"] * fps)
    for i in range(n):
        yazici.write(izleme_karesi(i / fps))
    yazici.release()
    okuyucu = _cv2.VideoCapture(yol)
    ok, ilk = okuyucu.read()
    okuyucu.release()
    if not ok or not np.array_equal(ilk, izleme_karesi(0.0)):
        print("FAIL: video kayıpsız değil — sahte bulucu tam gri değer bekler")
        return 1

    yazilan: list[str] = []
    ozet = video.oynat(yol, kuyruk_sn=S.get("kuyruk_sn", 6.0), yaz=yazilan.append)
    hata = 0

    def fail(m: str) -> None:
        nonlocal hata
        print(f"FAIL: {m}")
        hata = 1

    # Bu süreçte print köprünün kaydına da gider (gunluk.baslat): plaka içeren
    # satır yalnızca gerçek konsola — oynatmanın kendi özeti gibi.
    sys.__stdout__.write(f"   özet: kod={ozet.kod} gonderimler={ozet.gonderimler} "
                         f"sayilar={ozet.sayilar}\n")
    if ozet.kod != 0:
        fail(f"oynatma kodu {ozet.kod}")
    if gonderimler or kalpler:
        fail(f"oynatma ağa istek attı: {len(gonderimler)} olay, {len(kalpler)} kalp atışı")
    for no, h in S.get("video_plakalar", []):
        if not any(g["tur"] == "PLAKA" and g["plaka"] == PLAKALAR[no] and g.get("hareket") == h
                   for g in ozet.gonderimler):
            fail(f"özette {PLAKALAR[no]} ({h}) yok: {ozet.gonderimler}")
    if len(ozet.gonderimler) != S.get("video_gonderim", 0):
        fail(f"{S.get('video_gonderim', 0)} gönderim bekleniyordu, {len(ozet.gonderimler)}")
    for anahtar, deger in S.get("video_sayilar", {}).items():
        if ozet.sayilar.get(anahtar) != deger:
            fail(f"kayıt sayısı {anahtar}={ozet.sayilar.get(anahtar)} (beklenen {deger})")
    gercek_kayit = os.path.join(os.environ["PROGRAMDATA"], "Otopark", "kayit")
    if os.path.abspath(ozet.klasor).startswith(os.path.abspath(gercek_kayit)):
        fail(f"oynatma gerçek kayıt klasörüne yazdı: {ozet.klasor}")
    if os.path.isdir(gercek_kayit) and os.listdir(gercek_kayit):
        fail(f"gerçek kayıt klasöründe dosya var: {os.listdir(gercek_kayit)}")
    metin = "\n".join(yazilan)
    for no, _h in S.get("video_plakalar", []):
        if PLAKALAR[no] not in metin:
            fail(f"ekran özetinde {PLAKALAR[no]} yok")
    kayit_metni = ""
    for ad in os.listdir(ozet.klasor):
        if ad.endswith(".log"):
            with open(os.path.join(ozet.klasor, ad), encoding="utf-8", errors="replace") as f:
                kayit_metni += f.read()
    if "araç girdi" not in kayit_metni:
        fail("geçici kayıtta köprünün karar satırı yok")
    for p in PLAKALAR:
        if p in kayit_metni:
            fail(f"kayıt dosyasında plaka metni var ({p}) — kayıtlara plaka yazılmaz")
    print("TAMAM" if not hata else "")
    return hata


def tek_kos(ad: str) -> int:
    S = SENARYOLAR[ad]
    gonderimler: list[dict] = []
    kalpler: list[float] = []
    kalp_govdeleri: list[dict] = []
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
            kalp_govdeleri.append(json)
            if S.get("kalp_gecikme"):
                time.sleep(S["kalp_gecikme"])
            return Yanit(400)
        kayit = {"t": time.monotonic() - T0, "id": json["islem_id"], "yon": json.get("yon"),
                 "tur": tur, "plaka": json.get("plaka"), "tahmin": json.get("tahmin"),
                 "zaman": json.get("zaman"), "foto_var": "foto_base64" in json,
                 "hareket": json.get("hareket"), "hareket_var": "hareket" in json,
                 "yonsuz": json.get("yon_bilinmiyor"), "yonsuz_var": "yon_bilinmiyor" in json,
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
    import kalinti
    kalinti.klasor("otopark-test-kopru-")             # tek senaryo da tek klasörde
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp(prefix="otopark-test-")
    os.environ.update(WEBHOOK_URL="http://stub/kamera-webhook",
                      KAMERA_SECRET="x" * 32,
                      RTSP_URL=S.get("rtsp", "rtsp://stub/1"), YON=S.get("yon", "GIRIS"))
    for ad_s, anahtar in (("kirpma", "KIRPMA"), ("haric", "KIRPMA_HARIC"),
                          ("max_bekleme", "MAX_BEKLEME_SN"),
                          ("acilis_bekleme", "ACILIS_BEKLEME_SN"),
                          ("sifre_bekleme", "SIFRE_RED_BEKLEME_SN"),
                          ("max_kenar", "MAX_KENAR"), ("plaka_tam", "PLAKA_TAM"),
                          ("alan", "KIRPMA_ALAN"), ("kapi", "KAPI_ALANI"),
                          ("birlesik", "PLAKA_BIRLESIK")):
        if S.get(ad_s):
            os.environ[anahtar] = S[ad_s]
        else:
            os.environ.pop(anahtar, None)
    # 1.4.0: eski senaryolar 1.3.4 geçiş kuralını sınar (TAKIP=0) — izleme
    # kapalıyken davranışın BİREBİR aynı kaldığının kanıtı. İzleme senaryoları
    # "takip": "1" verir; None = ortamda hiç yok (varsayılan açık).
    if "takip" in S and S["takip"] is None:
        os.environ.pop("TAKIP", None)
    else:
        os.environ["TAKIP"] = S.get("takip", "0")
    if S.get("yeniden_baglan"):
        os.environ["YENIDEN_BAGLAN_SN"], os.environ["YENIDEN_BAGLAN_MAX_SN"] = S["yeniden_baglan"]
    os.environ["BEKCI_SN"] = S.get("bekci", "3")
    for k in ("PARCA_EMME", "KLIP", "PARK_GORUNUR"):
        os.environ.pop(k, None)
    for k, v in S.get("ortam", {}).items():
        os.environ[k] = v

    sys.path.insert(0, BURASI)
    import plaka

    # 1.4.2: eski senaryolar 1.4.1'in işlemci kümesini sınar (HIZLANDIRICI=CPU);
    # "gpu" senaryoları grafik işlemcisi kümesini — sahte Hizlandirici ile.
    if S.get("gpu"):
        os.environ["HIZLANDIRICI"] = "GPU"
        os.environ["ARAC_MODEL"] = S.get("arac_model", "yolo11s")
    else:
        os.environ["HIZLANDIRICI"] = "CPU"
        os.environ.pop("ARAC_MODEL", None)
    import hizlandirici
    hizlandirici.Hizlandirici.ac = classmethod(lambda cls, *a, **k: object())

    if S.get("okuyucu") == "yok":
        def _yukle_yok(ayar, dizin=None, hiz=None):
            raise plaka.PlakaHatasi("model dosyası bulunamadı: (test)")
        plaka.yukle = _yukle_yok
    else:
        plaka.yukle = lambda ayar, dizin=None, hiz=None: SahtePlakaci(S)

    # 1.3.1: araç bulucu her senaryoda TAKLİT edilir (gerçek model test
    # karelerindeki gri dikdörtgeni araç sanmaz); "yok" = yüklenemedi.
    import arac
    if S.get("arac") == "yok":
        def _arac_yok(ayar, dizin=None, profil=None, hiz=None):
            raise plaka.PlakaHatasi("model dosyası bulunamadı: (test)")
        arac.yukle = _arac_yok
    else:
        arac.yukle = lambda ayar, dizin=None, profil=None, hiz=None: SahteArac(S)

    import kopru
    if S.get("yeniden_dene") is not None:
        import okuma as _okuma
        _okuma.YENIDEN_DENE_SN = S["yeniden_dene"]
    import kesif

    global T0
    T0 = time.monotonic()

    bekci_cagrilari: list[float] = []
    kopru._bekci_cik = lambda: bekci_cagrilari.append(time.monotonic() - T0)
    gpu_cikislari: list[float] = []
    kopru._gpu_cik = lambda: gpu_cikislari.append(time.monotonic() - T0)

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
        f = _kare()
        if S.get("park_arac"):
            # Hep orada duran araç: alt şeritte, geçen aracın yolundan ayrık.
            f[420:480, 100:640] = 220
        if S.get("park_plakali") is not None:
            # Plakası okunabilen park etmiş araç (sol altta, 2. kesilen köşede).
            f[405:470, 20:310] = 220
            for c in range(60, 260, 12):
                f[415:455, c:c + 6] = isaret(S["park_plakali"])
        return f

    def _kare():
        t = time.monotonic() - T0
        if S.get("araclar") is not None:
            return izleme_karesi(t)
        e, a, b, no = evre(t)
        f = doku.copy() if doku is not None else np.full((480, 640, 3), 100, np.uint8)
        if e == SURUNUYOR:
            # 25 px/sn: kare kare değişim ~0.1 (DURGUN_ESIGI 2'nin çok altında).
            # Kadrajın tamamen dışından başlar: aniden belirmez.
            return gecen_ciz(f, int(-400 + 25 * (t - a)), deger=220, no=None, keskin=True)
        if e == KACIYOR:
            return gecen_ciz(f, int(-325 + 1025 * (t - a) / (b - a)), deger=220, no=None,
                             keskin=True)
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

    def izleme_karesi(t: float) -> np.ndarray:
        """
        1.4.0: araçlar düz yollarda YUMUŞAK hareket eder (izleme her kareyi
        izler). Öğe: (başla, bitir, x0, y0, x1, y1, plaka no | None, gri değer[, en, boy]).
        Gri değer < 200 (koyu): araç bulucu görmez (yaya / gölge / görülmeyen
        araç); plakası varsa yine çizilir. Kare dışına taşan kısım kırpılır.
        """
        f = np.full((480, 640, 3), 100, np.uint8)
        for oge in S["araclar"]:
            a, b, x0, y0, x1, y1, no, deger = oge[:8]
            w, h = (oge[8], oge[9]) if len(oge) > 8 else (160, 110)
            if not a <= t < b:
                continue
            r = 0.0 if b <= a else min(1.0, (t - a) / (b - a))
            x, y = int(round(x0 + (x1 - x0) * r)), int(round(y0 + (y1 - y0) * r))
            c0, c1, r0, r1 = max(0, x), min(640, x + w), max(0, y), min(480, y + h)
            if c1 <= c0 or r1 <= r0:
                continue
            f[r0:r1, c0:c1] = deger
            if no is not None:
                for c in range(x + 30, x + 130, 8):
                    p0, p1 = max(0, c), min(640, c + 4)
                    q0, q1 = max(0, y + 80), min(480, y + 100)
                    if p1 > p0 and q1 > q0:
                        f[q0:q1, p0:p1] = isaret(no)
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

    if S.get("video"):
        # 1.4.2 (E12): kamerayı oynatma kendisi değiştirir (gerçek
        # VideoCapture'ı dosyayı açmak için kullanır) — sahte kamera YOK.
        return video_senaryosu(S, kopru, izleme_karesi, gonderimler, kalpler)
    kopru.cv2.VideoCapture = lambda *a, **k: SahteKamera()

    if S.get("dusuk_fark"):
        # Senaryo gerçekten "gece" mi: ardışık iki kamera karesinin BÜTÜN
        # kırpıntı farkı (köprünün d'si) hiçbir anda DURGUN_ESIGI'ne (2.0)
        # ulaşmamalı — yoksa eski tetik de yakalar, test bir şey kanıtlamaz.
        en_cok, onceki, t = 0.0, None, 0.0
        while t < S["sure"]:
            g = kopru.gri_kucuk(izleme_karesi(t))
            en_cok = max(en_cok, kopru.fark(onceki, g))
            onceki, t = g, t + 0.04
        print(f"   en büyük bütün-kırpıntı farkı: {en_cok:.2f}")
        if en_cok >= 2.0:
            print(f"FAIL: senaryo gece değil — bütün kırpıntı farkı {en_cok:.2f} ≥ 2.0")
            return 1

    if S.get("kutuda_bekleyen") is not None:
        # 1.4.3: bir önceki çalışmadan kutuda kalmış araç (köprünün kendi gövdesi).
        import giden as _giden
        _kutu = _giden.Giden(os.path.join(os.environ["PROGRAMDATA"], "Otopark", "kayit",
                                          f"giden-{S.get('yon', 'GIRIS').lower()}"))
        _kutu.yaz({"yon": S.get("yon", "GIRIS"), "zaman": "2026-11-17T10:00:00Z",
                   "islem_id": "00000000-0000-4000-8000-000000000001", "cihaz": "test",
                   "plaka": PLAKALAR[S["kutuda_bekleyen"]]})
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
    # 1.4.2 (B5): köprünün yön ipucu. "hareketler": {plaka no: beklenen ipucu
    # (None = ipucu YOK)} — o plakanın her gönderimi. Personele giden olay hiç
    # ipucu taşımaz (yönü bilinmez).
    for no, h in S.get("hareketler", {}).items():
        bunlar = [g for g in tekil if g["plaka"] == PLAKALAR[no]]
        if not bunlar:
            fail(f"{PLAKALAR[no]} hiç gönderilmedi (ipucu denetimi)")
        for g in bunlar:
            if g["hareket"] != h or g["hareket_var"] != (h is not None):
                fail(f"{PLAKALAR[no]} yön ipucu {g['hareket']!r} (beklenen {h!r})")
    # 1.4.3 (18.11): "hareket_sirasi": {plaka no: [ipuçları, gönderim sırasıyla]}.
    for no, sira in S.get("hareket_sirasi", {}).items():
        gelen = [g["hareket"] for g in sorted(tekil, key=lambda g: g["t"])
                 if g["plaka"] == PLAKALAR[no]]
        if gelen != sira:
            fail(f"{PLAKALAR[no]} ipucu sırası {gelen!r} (beklenen {sira!r})")
    for g in gonderimler:
        if g["tur"] == "OKUNAMADI" and g["hareket_var"]:
            fail(f"personele giden olayda yön ipucu var: {g['hareket']!r}")
        # 1.4.3: "yön bilinmiyor" işareti yalnızca ipucusuz PLAKA'da, yalnızca
        # True; tek kapı dışındaki şeritte hiç.
        if g["yonsuz_var"] and (g["tur"] != "PLAKA" or g["hareket_var"]
                                or g["yonsuz"] is not True or g["yon"] != "ORTAK"):
            fail(f"yön bilinmiyor işareti yanlış yerde: {g['tur']} {g['yon']} "
                 f"{g['hareket']!r} {g['yonsuz']!r}")
    for no, beklenen in S.get("yonsuz", {}).items():
        bunlar = [g for g in tekil if g["plaka"] == PLAKALAR[no]]
        if not bunlar:
            fail(f"{PLAKALAR[no]} hiç gönderilmedi (yön bilinmiyor denetimi)")
        for g in bunlar:
            if bool(g["yonsuz"]) != beklenen:
                fail(f"{PLAKALAR[no]} yön bilinmiyor işareti {g['yonsuz']!r} (beklenen {beklenen})")
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
    for no in S.get("hic_gitmez", []):
        if any(g["plaka"] == PLAKALAR[no] for g in gonderimler):
            fail(f"{PLAKALAR[no]} (kesilen köşedeki park etmiş araç) gönderildi")
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
    if S.get("kutu_once") is not None:
        n = S["kutu_once"]
        ilk = [g for g in tekil if g["plaka"] == PLAKALAR[n]]
        if not ilk or ilk[0]["t"] >= acilis:
            fail(f"kutudaki araç kamera açılmadan gönderilmedi "
                 f"({[round(g['t'], 2) for g in ilk]}, kamera {acilis}s)")
    if acilis:
        erken = [k for k in kalpler if k < acilis]
        if erken:
            fail(f"kamera açılmadan kalp atışı gönderildi (t={erken[0]:.2f}s)")
        if not kalpler:
            fail("kamera açıldıktan sonra hiç kalp atışı gönderilmedi")
    # 1.4.3: her kalp atışı sayılarını taşır (sürüm, izleme, kuyruk).
    import gunluk as _gunluk
    for kg in kalp_govdeleri:
        b = kg.get("kalp") if isinstance(kg, dict) else None
        if (not isinstance(b, dict) or b.get("surum") != _gunluk.KOPRU_SURUMU
                or b.get("takip") not in ("acik", "kapali", "kapandi")
                or not isinstance(b.get("kuyruk"), int)):
            fail(f"kalp atışı sayısız ya da eksik: {kg!r}")
            break
    if S.get("kayitta_sirayla") or S.get("kayitta_yok"):
        import glob as _glob
        metin = ""
        for yol in _glob.glob(os.path.join(os.environ["PROGRAMDATA"], "Otopark",
                                           "kayit", "*.log")):
            with open(yol, encoding="utf-8", errors="replace") as f:
                metin += f.read()
        for parca in S.get("kayitta_yok", []):
            if parca in metin:
                fail(f"kayıtta olmamalıydı: {parca!r}")
        konum = 0
        for parca in S.get("kayitta_sirayla", []):
            i = metin.find(parca, konum)
            if i < 0:
                fail(f"kayıtta sırayla bulunamadı: {parca!r}")
                break
            konum = i + len(parca)
        for p in PLAKALAR:
            if p in metin:
                fail(f"kayıt dosyasında plaka metni var ({p}) — kayıtlara plaka yazılmaz")
                break
    # 1.4.3 (1d): klip kaydedici. Varsayılan kapalı: klasör hiç açılmaz.
    klip_klasor = os.path.join(os.environ["PROGRAMDATA"], "Otopark", "klipler")
    if "klipler" not in S:
        if os.path.exists(klip_klasor):
            fail("KLIP kapalıyken klip klasörü açıldı")
    else:
        import re as _re
        import cv2 as _cv2
        adlar = (sorted(f for f in os.listdir(klip_klasor) if f.endswith(".avi"))
                 if os.path.isdir(klip_klasor) else [])
        if len(adlar) != len(S["klipler"]):
            fail(f"{len(S['klipler'])} klip bekleniyordu, {adlar}")
        for ad, (olay, ek) in zip(adlar, S["klipler"]):
            m = _re.fullmatch(r"\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_iz\d+_([A-Z_]+)_([0-9a-z]+)\.avi", ad)
            kimlikler = [g["id"][:8] for g in tekil if g["tur"] == ek]
            if not m or not _re.fullmatch(olay, m.group(1)):
                fail(f"klip adı beklenen biçimde değil ({olay}): {ad}")
            elif ek == "emildi" and m.group(2) != "emildi":
                fail(f"emilen parçanın klibi 'emildi' değil: {ad}")
            elif ek != "emildi" and m.group(2) not in kimlikler:
                fail(f"klip adındaki kimlik gönderilen {ek} olayının değil: {ad} {kimlikler}")
            if any(p in ad for p in PLAKALAR):
                fail(f"klip adında plaka var: {ad}")
            cap = _cv2.VideoCapture(os.path.join(klip_klasor, ad))
            ok, _ = cap.read()
            cap.release()
            if not ok:
                fail(f"klip açılamadı: {ad}")
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

    if S.get("kirpma") or S.get("alan"):
        # 1.4.0: kırpma ALANI da bir kutudur (çevreleyen dikdörtgen) — fotoğraf gider.
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
    # 1.4.3 (PARK_GORUNUR): fotoğraf yine maskeli — bu bölgeler (karenin
    # pikselinde; kırpma alanı bütün kareyi çevreler) düz gri (114).
    for x0, y0, x1, y1 in S.get("foto_gri", []):
        for g in tekil:
            if not g["kanit"]:
                continue
            _, img = _coz(g["kanit"])
            sy, sx = img.shape[0] / 480.0, img.shape[1] / 640.0
            bolge = _cv2.cvtColor(img, _cv2.COLOR_BGR2GRAY)[
                int(y0 * sy) + 2:int(y1 * sy) - 2, int(x0 * sx) + 2:int(x1 * sx) - 2]
            ort = float(bolge.mean())
            if abs(ort - 114) > 6:
                fail(f"t={g['t']:.2f}s fotoğrafında alanın dışı gri değil (ortalama {ort:.0f})")
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
    # 1.4.2: GPU için yeniden başlatma — yalnızca beklendiğinde, bir kez, son
    # gönderimden SONRA (sakin an: araç kararı verilmeden kesilmez).
    if S.get("gpu_cikis"):
        son_gonderim = max((g["t"] for g in gonderimler), default=0.0)
        if len(gpu_cikislari) != 1:
            fail(f"GPU yeniden başlatması bir kez olmalıydı, {len(gpu_cikislari)} kez")
        elif gpu_cikislari[0] <= son_gonderim:
            fail(f"GPU yeniden başlatması araç kararından önce (t={gpu_cikislari[0]:.2f}s, "
                 f"son gönderim {son_gonderim:.2f}s)")
        elif gpu_cikislari[0] < S.get("gpu_cikis_en_erken", 0.0):
            fail(f"GPU yeniden başlatması sakin an gelmeden (t={gpu_cikislari[0]:.2f}s, "
                 f"en erken {S['gpu_cikis_en_erken']}s)")
    elif gpu_cikislari:
        fail(f"GPU yeniden başlatması beklenmezken oldu (t={gpu_cikislari[0]:.2f}s)")

    if not hata:
        print(f"PASS: {ad}")
    return hata


if __name__ == "__main__":
    sys.exit(tek_kos(sys.argv[1]) if len(sys.argv) > 1 else hepsini_kos())
