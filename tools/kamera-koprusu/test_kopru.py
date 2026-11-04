# -*- coding: utf-8 -*-
"""
Yakalama döngüsü regresyon testleri.

    python test_kopru.py            # hepsi
    python test_kopru.py iki_arac   # tek senaryo

Bu dosya GERÇEK main() döngüsünü çalıştırır; kamera ve ağ taklit edilir, karar
mantığı taklit EDİLMEZ. Test edilen şey kodun kopyası değil, kodun kendisidir.

Neden kalıcı bir test: buradaki hatalar sessizce ARAÇ DÜŞÜRÜYORDU. Düşen araç
bilet de üretmez, istisna satırı da — haftalar sonra "sayılar tutmuyor" olarak
ortaya çıkar. Sessiz para kaybı, kalıcı testi hak eder.

`requests` taklit edildiği için kurulu olması gerekmez; yalnızca cv2 ve numpy.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
import types

import numpy as np

# kopru.py ile aynı sebep: bu dosyanın çıktısı da Türkçe ve Windows konsolu
# cp1252 olabilir. Alt süreçlere PYTHONIOENCODING veriyoruz ama bu süreç kendi
# özetini yazarken de aynı duvara toslar.
for _akis in (sys.stdout, sys.stderr):
    if hasattr(_akis, "reconfigure"):
        _akis.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))

# Her senaryo: (sahne, kaç saniye koşulacak, aracın YERLEŞİK olduğu pencereler)
#
# İddia PENCERE üzerinedir, gönderim SAYISI üzerine değil: BOS_REFERANS
# ayarlanmadığında giden aracın ardında kalan boş şerit de yerleşip
# fotoğraflanır. O fazladan okuma belgelenmiş davranış; fotoğrafı HİÇ
# çekilmeyen araç ise hatadır.
BOS, GELIYOR, DURDU = "bos", "geliyor", "durdu"

# 1.2.5 — bariyersiz kapı: araç DURMADAN geçer (~10 km/sa).
#   GECIYOR  araç kadrajın solundan girer, sağından çıkar; hiç durmaz. Yalnızca
#            ortaya yakınken KESKİN, geri kalan her karede bulanık — köprünün
#            en keskin kareyi seçtiği böylece ölçülebilir.
#   GOLGE    araç OLMAYAN bir hareket (yürüyen biri, gölge): koyu, kadrajdan
#            geçip gider. Sunucu ona "araç yok" der.
#   GURULTU  araç gittikten sonra sahne hiç DURULMAZ (yağmur, gece kumlanması):
#            kareler arası fark "durgun" eşiğinin üstünde, "hareket" eşiğinin
#            altında kalır.
GECIYOR, GOLGE, GURULTU = "geciyor", "golge", "gurultu"

# Kimlik taşıyan bir köprü adresi, sihirbazın yazdığı gibi URL-kodlu ('@' ve
# ':' şifrenin içinde). Köprünün şifre sınaması bunu ÇÖZÜP kendi yoluna sormalı.
_KIMLIKLI_RTSP = ("rtsp://admin:Gizli%40Sifre%3A1@10.0.0.5:554"
                  "/cam/realmonitor?channel=1&subtype=0")
_KIMLIKLI_SINAMA = ("10.0.0.5", 554, "admin", "Gizli@Sifre:1",
                    "/cam/realmonitor?channel=1&subtype=0")

SENARYOLAR = {
    # Asıl regresyon: 60sn'lik sabit bekleme, 12sn'lik hareket penceresini
    # aşıyordu; ikinci araç ikisinin arasına düşüp tamamen kayboluyordu.
    "iki_arac": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 8, BOS),
               (8, 8.8, GELIYOR), (8.8, 14, DURDU)],
        sure=14.0, pencereler=[(1.8, 3.6), (8.8, 14.1)],
    ),
    # 429 tek geçici 4xx'tir (webhook'un 30/dk ve 2000/gün sınırı). Kalıcı
    # sayılırsa hız sınırına takılan araç çöpe gider.
    "429": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 6, DURDU)],
        sure=7.0, pencereler=[(1.8, 6.0)], kodlar=[429, 429, 200], tekrar=3,
    ),
    # Gönderim yakalama iş parçacığında olsaydı yavaş bir webhook kamerayı
    # ~134sn kör bırakırdı.
    "yavas": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 8, BOS),
               (8, 8.8, GELIYOR), (8.8, 13, DURDU)],
        sure=14.0, pencereler=[(1.8, 3.5), (8.8, 13.0)], yavas=3.0,
    ),
    # Bariyerde bekleyen araç MAX_BEKLEME_SN dolunca tekrar gönderilmemeli.
    "park": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 14, DURDU)],
        sure=13.0, pencereler=[(1.8, 13.0)], max_bekleme="5", tek=True,
    ),
    # Sırayla bariyere ilerleyen üç araç.
    "kuyruk": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.3, GELIYOR), (4.3, 9.5, DURDU),
               (9.5, 10.3, GELIYOR), (10.3, 15, DURDU)],
        sure=16.0, pencereler=[(1.8, 3.5), (4.3, 9.5), (10.3, 15.0)],
    ),
    # Elektrik kesintisinden sonra bilgisayar kameradan ONCE acilir. Kopru
    # eskiden ilk denemede cikiyordu ve gorev acilista yalnizca bir kez
    # kostugu icin biri bilgisayari yeniden baslatana kadar donmuyordu.
    # Kamera 3. saniyede aciliyor; arac ondan SONRA geliyor ve gonderilmeli.
    # Kamera yokken kalp atisi da GITMEMELI: olu kamerayi sunucuya canli
    # gosteren bir kopru, nobetcinin tek isaretini yok eder.
    "gec_kamera": dict(
        sahne=[(0, 5, BOS), (5, 5.8, GELIYOR), (5.8, 10, DURDU)],
        sure=10.0, pencereler=[(5.8, 10.0)], acilis=3.0, acilis_bekleme="0.5",
    ),
    # Akis bir an kopup geri geliyor. Kopru yeniden baglaniyordu ama bunu
    # YAZMIYORDU: kayittaki son kamera satiri "kare alinamadi" olarak kaliyor,
    # `durum` bes dakikaya kadar "KAMERA YOK" diyordu — kamera calisirken.
    # Kopmadan SONRA gelen arac da gonderilmeli.
    "kopma": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR), (6.8, 11, DURDU)],
        sure=11.0, pencereler=[(6.8, 11.0)], kopuk=(2.0, 2.3),
        kayitta_sirayla=["kare alınamadı", "kamera bağlandı"],
    ),
    # Tek kapi (037): giris ve cikis ayni yerden. Kopru ORTAK seridiyle
    # BASLAMALI ve gonderdigi her olay o seridi tasimali — yonu sunucu bilet
    # durumundan cikarir. Kopru burada GIRIS'e "yuvarlasaydi" odeyip cikan
    # her araca yeniden bilet acilirdi; bu modun kapattigi hata tam o.
    "tek_kapi": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 6, DURDU)],
        sure=7.0, pencereler=[(1.8, 6.0)], yon="ORTAK",
    ),
    # 1.2.3: kırpma kutusu varsa her araçla plakanın sıkıştırılmış bir kopyası
    # da gider (042 onu bilete/istisnaya bağlar). İki kopya AYNI kırpıktan
    # doğar. Kutusuz senaryoların hiçbiri bu alanı göndermemeli (genel kontrol,
    # aşağıda): sahibin kararı, kutu yoksa fotoğraf yok — sokak görüntüsü değil.
    "kanit_fotografi": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 8, BOS),
               (8, 8.8, GELIYOR), (8.8, 12, DURDU)],
        sure=12.5, pencereler=[(1.8, 3.6), (8.8, 12.1)],
        kirpma="100,80,400,300",
    ),
    # Boş şerit öğrenme (1.2.0). Sunucu fotoğrafa bakıp karar veriyor (araç
    # varsa 200; yoksa 422 + arac_yok). Üç araç gelip gidiyor; her gidişin
    # ardında boş şerit yerleşiyor. Birinci boş fotoğraf ADAY olur, ikincisi
    # (arada bir araç OKUNDU) onu doğrular ve referans yapar, ÜÇÜNCÜSÜ HİÇ
    # GÖNDERİLMEMELİ. Üçüncü araç yine de gönderilmeli: öğrenilmiş bir boş
    # şerit asla bir aracı gizlememeli.
    "bos_ogrenme": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 7, BOS),
               (7, 7.8, GELIYOR), (7.8, 9.5, DURDU),
               (9.5, 10.2, GELIYOR), (10.2, 13, BOS),
               (13, 13.8, GELIYOR), (13.8, 15.5, DURDU),
               (15.5, 16.2, GELIYOR), (16.2, 19.5, BOS)],
        sure=19.5, pencereler=[(1.8, 3.5), (7.8, 9.5), (13.8, 15.5)],
        goruntu_sunucu=True, arac_yok=True,
        bos_gonderilir=[(4.2, 7.0), (10.2, 13.0)],
        bos_gonderilmez=[(16.2, 19.5)],
        # 1.2.5: üç araç, TAM üç araç fotoğrafı. Duran araç giderken köprü
        # yeniden silahlanabiliyor; o gidişin karesi ikinci kez gönderilseydi
        # (öğrenilmiş boş şeride "araç gitti" denip) tek kapıda girişin hemen
        # ardından sahte bir çıkış olurdu.
        arac_gonderim_sayisi=3,
        kayitta_sirayla=["boş şerit görüntüsü (sunucu: araç yok)",
                         "boş şerit öğrenildi",
                         "boş şerit — gönderilmedi"],
    ),
    # Sunucu "araç var ama plaka okunamadı" diyor (arac_yok YOK): bu bir boş
    # şerit kanıtı DEĞİL, öğrenilmemeli — üçüncü boş fotoğraf yine gider.
    "bos_belirsiz": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 7, BOS),
               (7, 7.8, GELIYOR), (7.8, 9.5, DURDU),
               (9.5, 10.2, GELIYOR), (10.2, 13, BOS),
               (13, 13.8, GELIYOR), (13.8, 15.5, DURDU),
               (15.5, 16.2, GELIYOR), (16.2, 19.5, BOS)],
        sure=19.5, pencereler=[(1.8, 3.5), (7.8, 9.5), (13.8, 15.5)],
        goruntu_sunucu=True, arac_yok=False,
        bos_gonderilir=[(4.2, 7.0), (10.2, 13.0), (16.2, 19.5)],
    ),
    # İki "araç yok" cevabı arka arkaya, arada OKUNAN araç yok (yalnızca biri
    # kadrajdan geçti). Kural: arada okunmuş bir araç olmadan aday doğrulanmaz
    # — aynı park etmiş, okunamayan aracın iki fotoğrafı referans olamasın.
    "bos_arada_okuma_yok": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 7, BOS),
               (7, 7.6, GELIYOR), (7.6, 10.5, BOS),
               (10.5, 11.1, GELIYOR), (11.1, 14, BOS)],
        sure=14.0, pencereler=[(1.8, 3.5)],
        goruntu_sunucu=True, arac_yok=True,
        bos_gonderilir=[(4.2, 7.0), (7.6, 10.5), (11.1, 14.0)],
    ),
    # Kalp atışı yakalama iş parçacığını BLOKLAMAMALI (1.2.1). Kalp atışı
    # senkron koşuyordu: yavaş bir sunucu (soğuk başlangıç, kopuk Wi-Fi)
    # döngüyü 10-20 sn donduruyordu ve o arada gelip duran araç hiç
    # görülmüyordu. Burada ilk kalp atışı 5 sn sürüyor; araç 1.8. saniyede
    # duruyor ve kalp atışı bitmeden GÖNDERİLMELİ. Kabul edilen ilk kalp
    # atışı da kayda bir kez "sunucu bağlantısı doğrulandı" yazmalı —
    # kurulum sihirbazı bu satırı bekliyor.
    "kalp_bloklamaz": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 8, DURDU)],
        sure=8.0, pencereler=[(1.8, 4.0)], kalp_gecikme=5.0,
        kayitta_sirayla=["kamera bağlandı", "sunucu bağlantısı doğrulandı"],
    ),
    # Okuma servisi çöktü (502): köprü aynı islem_id ile dört kez dener ve
    # YALNIZCA sonuncusu `x-kamera-son-gonderim: 1` taşır. Sunucu aracı ancak
    # o denemede "okunamadı" kaydına çevirir; daha erken yazsaydı başarılı bir
    # yeniden denemenin biletini tek kapıda keserdi.
    "son_gonderim": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 12, DURDU)],
        sure=11.0, pencereler=[(1.8, 3.0)], kodlar=[502, 502, 502, 502], tekrar=4,
        son_baslik=True,
    ),
    # 1.2.2 (A). Kameranın şifresi değişti: akış koptu ve kamera eski şifreyle
    # bir daha AÇILMIYOR. Köprü eskiden ~3 sn'de bir eski şifreyle giriş
    # deniyordu; Dahua beş yanlışta hesabı kilitler ve köprü onu sonsuza dek
    # kilitli tutardı. Artık önce TEK bir şifre sınaması: "yanlis" ise akış hiç
    # açılmaz, SIFRE_RED_BEKLEME_SN beklenir (gerçekte 10 dk'da en çok bir
    # başarısız giriş). Kalıcı durmaz: sınama "tamam"a dönünce (kilit bitti,
    # şifre geri alındı) köprü kendiliğinden döner ve sonraki araç gönderilir.
    "sifre_degisti": dict(
        sahne=[(0, 10.5, BOS), (10.5, 11.3, GELIYOR), (11.3, 15, DURDU)],
        sure=15.0, pencereler=[(11.3, 15.0)],
        rtsp=_KIMLIKLI_RTSP, gitti=[(2.0, 9.0)],
        sifre=[(2.0, "tamam"), (9.0, "yanlis"), (99.0, "tamam")], sifre_bekleme="1.0",
        yeniden_baglan=("0.2", "1.6"),
        sifreyle_acilmaz=(2.0, 9.0), sinama_en_cok=(2.0, 9.0, 8),
        kayitta_sirayla=["kare alınamadı", "kamera şifreyi reddetti",
                         "kamera bağlandı"],
    ),
    # Aynı kural açılışta (kamera_ac): kamera eski şifreyi reddediyorsa köprü
    # açılışta da akışı hiç açmaz; sınama düzelince kendiliğinden başlar.
    "sifre_acilista": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR), (6.8, 10, DURDU)],
        sure=10.0, pencereler=[(6.8, 10.0)],
        rtsp=_KIMLIKLI_RTSP, gitti=[(0.0, 4.0)],
        sifre=[(4.0, "yanlis"), (99.0, "tamam")], sifre_bekleme="1.0",
        acilis_bekleme="0.5",
        sifreyle_acilmaz=(0.0, 4.0), sinama_en_cok=(0.0, 4.0, 5),
        kayitta_sirayla=["kamera şifreyi reddetti", "kamera bağlandı"],
    ),
    # 1.2.2 (A). Kamera tamamen gitti (fiş, kablo) ve şifre sınaması bir şey
    # söyleyemiyor ("bilinmiyor"): yeniden bağlanma aralığı her denemede ikiye
    # katlanır ve tavanda durur. İlk iyi karede TABANA döner: sonraki kopmada
    # köprü yine hızlı dener, tavan kadar beklemez.
    "kopma_geri_cekilme": dict(
        sahne=[(0, 99, BOS)], sure=12.0, pencereler=[],
        rtsp=_KIMLIKLI_RTSP, gitti=[(2.0, 7.2), (10.0, 99.0)],
        sifre=[(99.0, "bilinmiyor")], yeniden_baglan=("0.2", "1.6"),
        geri_cekilme=(2.0, 7.2), sifirlama=10.0,
    ),
    # 1.2.4 bekçi. Kameranın okuması bir anda SONSUZA DEK takılıyor (FFmpeg'in
    # kendi zaman aşımını da aşan ölü bir soket). Süreç canlı ama döngü durdu:
    # eskiden Görev Zamanlayıcı onu "çalışıyor" görüyor, IgnoreNew yeni kopyayı
    # engelliyordu — şerit yeniden başlatılana kadar kör. Bekçi bunu
    # BEKCI_SN içinde görüp süreci kapatmalı (testte kapatma yerine kaydedilir)
    # ve kayda "köprü takıldı" yazmalı. Öbür bütün senaryolar bekçi KISA (3 sn)
    # iken koşar ve onu HİÇ tetiklememeli — uzun meşru beklemeler (yeniden
    # bağlanma, şifre beklemesi) yanlış alarm vermesin.
    "takilma": dict(
        sahne=[(0, 99, BOS)], sure=8.0, pencereler=[],
        takilir=2.0, bekci="2", bekci_beklenir=(3.5, 7.5),
        kayitta_sirayla=["kamera bağlandı", "köprü takıldı"],
    ),
    # 1.2.5. Bariyersiz kapı: araç durmadan geçiyor. 1.2.4 ancak sahne
    # DURULUNCA gönderiyordu, o da araç gittikten SONRA oluyordu — boş şerit
    # gidiyor, araç hiç okunmuyordu. Artık geçiş boyunca en keskin kare
    # tutulur ve araç gidince O gönderilir: tam bir gönderim, içinde araç var,
    # ve bulanık değil.
    "gecen_arac": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS)],
        sure=6.0, pencereler=[(2.4, 3.8)], gonderim_sayisi=1, keskin=True,
    ),
    # Arka arkaya iki geçen araç (aralarında 3 sn'den fazla): ikisi de.
    "gecen_iki_arac": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS),
               (6, 6.9, GECIYOR), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(2.4, 3.8), (6.9, 8.3)], gonderim_sayisi=2, keskin=True,
    ),
    # Araç gitti ama sahne hiç durulmuyor: "durdu" anı hiç gelmez. Güvenlik
    # ağı: sahne geçişten önceki hâline döndüyse ve 2 sn güçlü hareket yoksa
    # tutulan kare yine gönderilir.
    "gecen_gurultu": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 8, GURULTU)],
        sure=8.0, pencereler=[(3.4, 5.2)], gonderim_sayisi=1, keskin=True,
    ),
    # Gerçek sunucu gibi cevap veren bir sunucuyla: geçen araçlar okunur;
    # araç olmayan hareketin (gölge) "araç yok" cevabı, gölge değil gölge
    # GİTTİKTEN SONRAKİ sahneyi (gerçekten boş şerit) öğretir — iki kez, arada
    # okunan bir araçla, öğrenme kuralı gibi. Öğrenilmiş boş şerit sonraki
    # geçen aracı GİZLEMEMELİ.
    "gecen_bos_ogrenme": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 5, BOS),
               (5, 5.9, GOLGE), (5.9, 8.5, BOS),
               (8.5, 9.4, GECIYOR), (9.4, 12, BOS),
               (12, 12.9, GOLGE), (12.9, 15.5, BOS),
               (15.5, 16.4, GECIYOR), (16.4, 19, BOS)],
        sure=19.0, pencereler=[(9.4, 10.8), (16.4, 17.8), (2.4, 3.8)],
        goruntu_sunucu=True, arac_yok=True, keskin=True, arac_gonderim_sayisi=3,
        kayitta_sirayla=["boş şerit görüntüsü (sunucu: araç yok)",
                         "boş şerit öğrenildi"],
    ),
    # Duran araç değişmez: gelir, DURUR, sonra gider. 1.2.4 gibi TEK araç
    # fotoğrafı (durduğu kare); giderken ikinci kez araç gönderilmemeli —
    # tek kapıda bu, girişin hemen ardından sahte bir "çıkış" olurdu.
    "duran_arac_degismez": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 4.5, DURDU),
               (4.5, 5.2, GELIYOR), (5.2, 9, BOS)],
        sure=9.0, pencereler=[(1.8, 3.0)], arac_gonderim_sayisi=1,
    ),
    # Sahada kapatma anahtarı: GECIS_YAKALA=0 → 1.2.4 davranışı aynen; geçen
    # araç kaçırılır (eski hatanın belgesi).
    "gecis_kapali": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS)],
        sure=6.0, pencereler=[], gecis_yakala="0", arac_gonderim_sayisi=0,
    ),
    # ---- 1.2.6: kameranın kendi araç olayları (olay.py) ---------------------
    # Olaylar HTTP olmadan, `olay.kaydet` dikişinden verilir; gerçek dinleyici
    # (olay.baslat) her senaryoda devre dışı — hiçbir test ağa çıkmaz.
    # `olay`: bagli=akış sağlıklı mı, olaylar=[(saniye, kod, eylem)].
    # İlk olay (0.2-0.3 sn) yalnızca KAPIYI DOĞRULAR: kamera bu adla araç
    # olayı gönderiyor. Geçişler ondan en az 5 sn sonra başlar ki o doğrulama
    # olayı hiçbir geçişin penceresine düşmesin.
    "olay_gecen_arac": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(6.9, 8.3)], gonderim_sayisi=1, keskin=True, atlanan=0,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.3, "SmartMotionVehicle", "Start"),
                                      (7.0, "SmartMotionVehicle", "Stop")]),
        kayitta_sirayla=["araç olayları doğrulandı", "araç geçti"],
    ),
    # Araç OLMAYAN geçiş (yürüyen biri): kamera olay üretmez → gönderilmez.
    # 1.2.5 bunu gönderiyor, sunucu "okunamadı" kaydı + bildirim üretiyordu.
    "olay_yok_gonderilmez": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GOLGE), (6.9, 14, BOS)],
        sure=14.0, pencereler=[], gonderim_sayisi=0, gonderilmez=[(0, 14)], atlanan=1,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop")]),
        kayitta_sirayla=["araç olayları doğrulandı", "araç olayı yok — gönderilmedi"],
    ),
    # Olay GEÇ geliyor (gece, kızılötesi): karar anından ~2.5 sn sonra. Karar
    # 5 sn bekletilir; olay gelince fotoğraf gider.
    "olay_gec_gelir": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 13, BOS)],
        sure=13.0, pencereler=[(9.6, 10.6)], gonderim_sayisi=1, keskin=True,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (9.7, "SmartMotionVehicle", "Start")]),
    ),
    # Akış sağlıklı ama yalnızca VideoMotion geliyor (araç adı farklı ya da
    # SMD kapalı): kapı DOĞRULANMAZ → 1.2.5 gibi gönderir. Yanlış bir olay adı
    # hiçbir zaman bütün araçları durduramaz.
    "olay_dogrulanmadi": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(6.9, 8.3)], gonderim_sayisi=1,
        olay=dict(bagli=True, olaylar=[(6.3, "VideoMotion", "Start")]),
    ),
    # Akış yok (bağlantı kurulamadı): doğrulanmış olsa da kapı kapalı → 1.2.5.
    "olay_akisi_yok": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GOLGE), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(6.9, 8.3)], gonderim_sayisi=1,
        olay=dict(bagli=False, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                       (0.3, "SmartMotionVehicle", "Stop")]),
    ),
    # Gelen araç DURUR (gönderilir), sonra gider. Gidişte kamera yine araç
    # olayı üretir; 1.2.5 gidişin ardından boş şeridi gönderiyordu (sunucuda
    # "okunamadı" kaydı). Kapı açıkken: TEK gönderim, gidişte hiçbir şey.
    "olay_duran_ayrilan": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR), (6.8, 9.6, DURDU),
               (9.6, 10.3, GELIYOR), (10.3, 16, BOS)],
        sure=16.0, pencereler=[(6.8, 8.0)], gonderim_sayisi=1, arac_gonderim_sayisi=1,
        gonderilmez=[(8.5, 16)],
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.2, "SmartMotionVehicle", "Start"),
                                      (7.5, "SmartMotionVehicle", "Stop"),
                                      (9.7, "SmartMotionVehicle", "Start"),
                                      (10.5, "SmartMotionVehicle", "Stop")]),
        kayitta_sirayla=["araç durdu", "gönderilmiş araç — tekrar gönderilmedi"],
    ),
    # Duran aracın yerine, şerit hiç boşalmadan AYNI GÖRÜNÜŞTE ikinci bir araç
    # gelip duruyor (sahte karelerde iki araç birebir aynı — en kötü durum).
    # Pikselden "aynı araç mı" ayırt edilemez; 1.2.5 bunu gönderiyordu ve
    # kapı da göndermeli — araç kaçırmak, bir tekrardan pahalıdır.
    "olay_arac_yerine_arac": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR), (6.8, 9.6, DURDU),
               (9.6, 10.3, GELIYOR), (10.3, 14, DURDU)],
        sure=14.0, pencereler=[(6.8, 8.0), (10.3, 11.5)], gonderim_sayisi=2,
        arac_gonderim_sayisi=2,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.2, "SmartMotionVehicle", "Start"),
                                      (7.0, "SmartMotionVehicle", "Stop"),
                                      (9.7, "SmartMotionVehicle", "Start"),
                                      (10.5, "SmartMotionVehicle", "Stop")]),
    ),
    # Duran araç silahsızken (MIN_BEKLEME_SN içinde) gidiyor: gidişi hiçbir
    # karar üretmez, kapı aracı hâlâ "duran" diye hatırlar. Sonra başka bir
    # araç durmadan geçer — onun ardından sahne yine boş şeride döner, ama bu
    # bir AYRILIŞ değildir (geçiş duran aracın görüntüsünden başlamadı):
    # gönderilmeli.
    "olay_hizli_ayrilan_sonra_gecen": dict(
        sahne=[(0, 6, BOS), (6, 6.8, GELIYOR), (6.8, 7.8, DURDU),
               (7.8, 8.5, GELIYOR), (8.5, 12, BOS),
               (12, 12.9, GECIYOR), (12.9, 16, BOS)],
        sure=16.0, pencereler=[(6.8, 7.6), (12.9, 14.3)], gonderim_sayisi=2,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.2, "SmartMotionVehicle", "Start"),
                                      (8.6, "SmartMotionVehicle", "Stop"),
                                      (12.3, "SmartMotionVehicle", "Start"),
                                      (13.0, "SmartMotionVehicle", "Stop")]),
    ),
    # Araç geçer (gönderilir), hemen ardından kutudan bir yaya geçer. Yayanın
    # geçişi aracın olayından 5 sn sonra başlıyor; olay penceresi bir önceki
    # kararın gerisine uzanmadığı için aracın olayı yayaya yetki vermez.
    "olay_arac_ardindan_yaya": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 9.6, BOS),
               (9.6, 10.5, GOLGE), (10.5, 17, BOS)],
        sure=17.0, pencereler=[(6.9, 8.3)], gonderim_sayisi=1, gonderilmez=[(8.5, 17)],
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.3, "SmartMotionVehicle", "Start"),
                                      (7.0, "SmartMotionVehicle", "Stop")]),
        kayitta_sirayla=["araç geçti", "araç olayı yok — gönderilmedi"],
    ),
    # Karar olay beklerken akış KOPAR: olay kaybolmuş olabilir — atlanmaz,
    # 1.2.5 gibi gönderilir (olay sorunu hiçbir aracı kaybettirmez).
    "olay_beklerken_koptu": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 13, BOS)],
        sure=13.0, pencereler=[(7.9, 9.0)], gonderim_sayisi=1, atlanan=0,
        olay=dict(bagli=True, koptu=8.0,
                  olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                           (0.3, "SmartMotionVehicle", "Stop")]),
    ),
    # Arka arkaya iki araç, kamera ikisi için TEK bir Start…Stop üretiyor:
    # ikisi de gönderilmeli (olay "tüketilmez", aralık ikisini de kapsar).
    "olay_iki_arac_tek_aralik": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 9.5, BOS),
               (9.5, 10.4, GECIYOR), (10.4, 14, BOS)],
        sure=14.0, pencereler=[(6.9, 8.3), (10.4, 11.8)], gonderim_sayisi=2, keskin=True,
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (6.2, "SmartMotionVehicle", "Start"),
                                      (10.6, "SmartMotionVehicle", "Stop")]),
    ),
    # Pencere sınırlı: kamera 3.0-3.5'te bir araç gördü (kadrajın dışında,
    # sokakta) ama kutuda hiçbir şey kıpırdamadı. 9'da kutudan araç OLMAYAN
    # bir şey geçiyor — o eski olay bu geçişe yetki vermemeli.
    "olay_pencere_sinirli": dict(
        sahne=[(0, 9, BOS), (9, 9.9, GOLGE), (9.9, 17, BOS)],
        sure=17.0, pencereler=[], gonderim_sayisi=0, gonderilmez=[(0, 17)],
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop"),
                                      (3.0, "SmartMotionVehicle", "Start"),
                                      (3.5, "SmartMotionVehicle", "Stop")]),
    ),
    # Biri kameranın araç algılamasını kapattı, akış sağlıklı kalıyor: araç
    # boyutunda üç geçiş üst üste olaysız atlanır ve son araç olayından beri
    # OLAY_GERI_DONUS_SN geçmiştir → kapı kendini kapatır, sonraki araç gider.
    "olay_geri_donus": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GECIYOR), (6.9, 10, BOS),
               (10, 10.9, GECIYOR), (10.9, 14, BOS),
               (14, 14.9, GECIYOR), (14.9, 18, BOS),
               (18, 18.9, GECIYOR), (18.9, 22, BOS)],
        sure=22.0, pencereler=[(18.9, 20.5)], gonderim_sayisi=1, gonderilmez=[(0, 18)],
        atlanan=3,
        olay_bekle="2", olay_geri_donus="4",
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop")]),
        kayitta_sirayla=["araç olayı yok — gönderilmedi",
                         "araç olayı gelmiyor — hareketle çalışılıyor"],
    ),
    # Sahada kapatma anahtarı: OLAY_KAPISI=0 → olaylar ne derse desin 1.2.5.
    "olay_kapisi_kapali": dict(
        sahne=[(0, 6, BOS), (6, 6.9, GOLGE), (6.9, 10, BOS)],
        sure=10.0, pencereler=[(6.9, 8.3)], gonderim_sayisi=1, olay_kapisi="0",
        olay=dict(bagli=True, olaylar=[(0.2, "SmartMotionVehicle", "Start"),
                                      (0.3, "SmartMotionVehicle", "Stop")]),
    ),
    # Desenli zemin (asfalt dokusu): 1.2.5 kadrajın en çok ayrıntılı karesini
    # seçiyordu — desenli zeminde bu, aracın kutuyu EN AZ kapladığı karedir.
    # Gönderilen kare aracın TAMAMINI içermeli.
    "dokulu_zemin": dict(
        sahne=[(0, 1.5, BOS), (1.5, 2.4, GECIYOR), (2.4, 6, BOS)],
        sure=6.0, pencereler=[(2.4, 3.8)], gonderim_sayisi=1, tam_arac=True, doku=True,
    ),
    # Sahada kapatma anahtarı: BOS_OGREN=0 → bugünkü davranış aynen.
    "bos_ogren_kapali": dict(
        sahne=[(0, 1, BOS), (1, 1.8, GELIYOR), (1.8, 3.5, DURDU),
               (3.5, 4.2, GELIYOR), (4.2, 7, BOS),
               (7, 7.8, GELIYOR), (7.8, 9.5, DURDU),
               (9.5, 10.2, GELIYOR), (10.2, 13, BOS),
               (13, 13.8, GELIYOR), (13.8, 15.5, DURDU),
               (15.5, 16.2, GELIYOR), (16.2, 19.5, BOS)],
        sure=19.5, pencereler=[(1.8, 3.5), (7.8, 9.5), (13.8, 15.5)],
        goruntu_sunucu=True, arac_yok=True, bos_ogren="0",
        bos_gonderilir=[(4.2, 7.0), (10.2, 13.0), (16.2, 19.5)],
    ),
}


# GECIYOR: aracın ORTASI kadraj ortasına bu kadar yakınken kare keskin, yoksa
# bulanık (hareket bulanıklığının yerine). ~5 kare keskin düşer.
KESKIN_ARALIK = 130


def gecen_ciz(f: np.ndarray, x: int, deger: int, plaka: bool, keskin: bool) -> np.ndarray:
    """
    Kadrajdan geçen bir araç (ya da gölge). `x` sol kenar; kadrajın dışına
    taşan kısım kırpılır. Plaka: gövdenin altında koyu dikey çizgiler — keskin
    karede çok kenar, bulanıkta neredeyse hiç.
    """
    import cv2 as _cv2
    x0, x1 = max(0, x), min(640, x + 400)
    if x1 > x0:
        f[90:390, x0:x1] = deger
        if plaka:
            for c in range(x + 100, x + 300, 12):
                c0, c1 = max(0, c), min(640, c + 6)
                if c1 > c0:
                    f[300:350, c0:c1] = 30
    return f if keskin else _cv2.GaussianBlur(f, (0, 0), 6)


def keskinlik_olc(img_gri: np.ndarray) -> float:
    """Testin kendi ölçüsü: Laplacian varyansı (köprünün ölçüsünden bağımsız)."""
    import cv2 as _cv2
    return float(_cv2.Laplacian(img_gri, _cv2.CV_64F).var())


def hepsini_kos() -> int:
    # Her senaryo kendi PROGRAMDATA klasörünü açar (kaydı orada). Hepsi bu
    # çalıştırmanın TEK klasöründe toplanır — eskiden her senaryo %TEMP%'e ayrı
    # bir klasör bırakıyordu. Klasör SİLİNMEZ; sonunda yolu yazılır. Python önce
    # TMPDIR'a bakar (Git Bash onu kurabilir), o yüzden üçü birden verilir.
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

    def arac_var_mi(foto_base64: str) -> bool:
        # Sunucudaki modelin yerine: sahte sahnede boş şerit düz 100 gri,
        # araç 220'lik bir dikdörtgen — ortalama parlaklık ikisini ayırır.
        import base64 as _b64
        import cv2 as _cv2
        img = _cv2.imdecode(np.frombuffer(_b64.b64decode(foto_base64), np.uint8),
                            _cv2.IMREAD_GRAYSCALE)
        return float(img.mean()) > 120

    def post(url, json=None, headers=None, timeout=None):
        # Kalp atışı: 400 beklenen cevaptır ve sıradaki durum kodunu
        # TÜKETMEMELİ. kopru açılışta bir kalp atışı yollar (son_kalp = 0.0'a
        # karşı monotonic(), yani sistem çalışma süresi).
        if not (json and json.get("foto_base64")):
            kalpler.append(time.monotonic() - T0)
            if S.get("kalp_gecikme"):
                time.sleep(S["kalp_gecikme"])
            return Yanit(400)
        # Yapay gecikmeden ÖNCE kaydedilir: ölçtüğümüz şey köprünün göndermeye
        # karar verdiği an, taklit ağın yavaşlığı değil.
        gonderimler.append({"t": time.monotonic() - T0, "id": json["islem_id"],
                            "yon": json.get("yon"), "basliklar": dict(headers or {}),
                            "foto": json["foto_base64"],
                            "kanit_var": "foto_kanit_base64" in json,
                            "kanit": json.get("foto_kanit_base64")})
        if S.get("yavas"):
            time.sleep(S["yavas"])
        if S.get("goruntu_sunucu"):
            if arac_var_mi(json["foto_base64"]):
                return Yanit(200)
            # kamera-webhook'un plaka çıkmayınca verdiği cevap (vlm.ts aracYokMu).
            govde = {"hata": "Plaka okunamadı.", "guven": None,
                     "arac_yok": bool(S.get("arac_yok"))}
            import json as _json
            return Yanit(422, _json.dumps(govde))
        kod = kodlar.pop(0) if kodlar else 200
        if kod == 0:
            raise RequestException("ağ yok")
        return Yanit(kod)

    sahte.RequestException = RequestException
    sahte.post = post
    sys.modules["requests"] = sahte

    # Köprü artık gerçek bir kayıt dosyası açıyor. Testin makinedeki
    # C:\ProgramData\Otopark'a yazma hakkı olmayabilir ve olsa da orayı
    # kirletmemeli — PROGRAMDATA geçici klasöre çevriliyor.
    import tempfile
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp(prefix="otopark-test-")

    # Kimliksiz adreste ("rtsp://stub/1") köprü şifre sınaması YAPMAZ — eski
    # senaryolar bu yüzden ağa çıkmadan aynen koşar.
    os.environ.update(WEBHOOK_URL="http://stub/kamera-webhook",
                      KAMERA_SECRET="x" * 32,
                      RTSP_URL=S.get("rtsp", "rtsp://stub/1"), YON=S.get("yon", "GIRIS"))
    if S.get("kirpma"):
        os.environ["KIRPMA"] = S["kirpma"]
    else:
        os.environ.pop("KIRPMA", None)
    if S.get("max_bekleme"):
        os.environ["MAX_BEKLEME_SN"] = S["max_bekleme"]
    if S.get("acilis_bekleme"):
        os.environ["ACILIS_BEKLEME_SN"] = S["acilis_bekleme"]
    if S.get("bos_ogren"):
        os.environ["BOS_OGREN"] = S["bos_ogren"]
    if S.get("gecis_yakala"):
        os.environ["GECIS_YAKALA"] = S["gecis_yakala"]
    if S.get("olay_kapisi"):
        os.environ["OLAY_KAPISI"] = S["olay_kapisi"]
    if S.get("olay_bekle"):
        os.environ["OLAY_BEKLE_SN"] = S["olay_bekle"]
    if S.get("olay_geri_donus"):
        os.environ["OLAY_GERI_DONUS_SN"] = S["olay_geri_donus"]
    if S.get("sifre_bekleme"):
        os.environ["SIFRE_RED_BEKLEME_SN"] = S["sifre_bekleme"]
    if S.get("yeniden_baglan"):
        os.environ["YENIDEN_BAGLAN_SN"], os.environ["YENIDEN_BAGLAN_MAX_SN"] = S["yeniden_baglan"]
    # Bekçi (1.2.4) her senaryoda kısa süreyle açık: takılmayan bir döngüde
    # hiç tetiklenmemeli. Gerçek değer 900 sn.
    os.environ["BEKCI_SN"] = S.get("bekci", "3")

    sys.path.insert(0, BURASI)
    import cv2
    import olay
    # Gerçek olay dinleyicisi HİÇBİR senaryoda başlamaz: bazı senaryoların
    # RTSP adresi kullanıcı taşıyor ve dinleyici ağa çıkardı. Olaylar, varsa,
    # aşağıda `olay.kaydet` dikişinden verilir.
    olay.baslat = lambda *a, **k: False
    import kopru
    import kesif

    global T0
    T0 = time.monotonic()

    # Bekçinin os._exit(3)'ü test sürecini öldürürdü; yerine an kaydedilir.
    bekci_cagrilari: list[float] = []
    kopru._bekci_cik = lambda: bekci_cagrilari.append(time.monotonic() - T0)

    # Kameranın şifre sınaması (RTSP DESCRIBE) taklit edilir: sonucu saate göre
    # S["sifre"]'den gelir — [(şu ana kadar, sonuç), ...]. Her çağrı kaydedilir;
    # gerçekte her "yanlis" kamerada bir başarısız giriştir.
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
        for a, b, e in S["sahne"]:
            if a <= t < b:
                return e, a, b
        return BOS, 0.0, 0.0

    # GURULTU: her karede bir aşağı bir yukarı (fark 4 — durgun eşiği 2'nin
    # üstünde, hareket eşiği 6'nın altında). Sayaç zamana değil KAREYE bağlı;
    # zamana bağlansaydı iki kare aynı yarıma düşüp sahte bir "durgun" verirdi.
    titresim = [0]

    # Desenli zemin: sabit bir asfalt dokusu (kareden kareye DEĞİŞMEZ, yani
    # hareket sayılmaz) — ince ayrıntısı bol, araç gövdesi ise düz.
    doku = None
    if S.get("doku"):
        rs = np.random.RandomState(7)
        g = rs.randint(40, 160, (480, 640)).astype(np.uint8)
        doku = np.dstack([g, g, g])

    def kare():
        t = time.monotonic() - T0
        e, a, b = evre(t)
        f = doku.copy() if doku is not None else np.full((480, 640, 3), 100, np.uint8)
        if e == BOS:
            return f
        if e == GURULTU:
            titresim[0] ^= 1
            return f + np.uint8(4 * titresim[0])
        if e in (GECIYOR, GOLGE):
            # Soldan girer, sağdan çıkar, hiç durmaz: 1080 px faz boyunca.
            x = int(-420 + 1080 * (t - a) / (b - a))
            if e == GOLGE:
                # Tam koyu (0): 40 gibi soluk bir gölgenin kareler arası farkı
                # (~5.6) HAREKET_ESIGI'nin (6) altında kalıyordu — köprü onu
                # hiç hareket saymıyor, ki doğru; ama bu senaryo araç OLMAYAN
                # bir hareketin öğrenmeyi nasıl beslediğini sınamak için var.
                return gecen_ciz(f, x, deger=0, plaka=False, keskin=True)
            keskin = abs(x + 200 - 320) < KESKIN_ARALIK
            if doku is not None:
                # Gerçekte hareket bulanıklığı yalnızca ARACI bozar; zemin
                # keskin kalır. Araç ayrı bir katmanda çizilip (gerekirse)
                # bulanıklaştırılır, sonra yalnızca kendi dikdörtgeninde
                # desenin üstüne konur.
                katman = gecen_ciz(np.full((480, 640, 3), 220, np.uint8), x, deger=220,
                                   plaka=True, keskin=keskin)
                x0, x1 = max(0, x), min(640, x + 400)
                if x1 > x0:
                    f[90:390, x0:x1] = katman[90:390, x0:x1]
                return f
            return gecen_ciz(f, x, deger=220, plaka=True, keskin=keskin)
        # DURDU'da sabit konum: kareler birebir aynı, durgun_sayaci artar.
        # GELIYOR'da kayar: ardışık fark HAREKET_ESIGI'yi geçer.
        x = 120 if e == DURDU else int((t * 2000) % 400)
        f[90:390, x:x + 400] = 220
        return f

    acilis = S.get("acilis", 0.0)

    def gitti_mi(t: float) -> bool:
        return any(a <= t < b for a, b in S.get("gitti", []))

    # Her açma denemesinin anı. Gerçek kamerada kimlikli bir adresle açmak bir
    # GİRİŞ demektir; eski şifreyle her biri başarısız giriş.
    acilislar: list[float] = []

    class SahteKamera:
        def __init__(self):
            t = time.monotonic() - T0
            acilislar.append(t)
            # `gitti` penceresinde açılan bağlantı ölü doğar ve ölü kalır —
            # kamera sonra gelse de (FFmpeg'in açamadığı akış gibi).
            self.olu = gitti_mi(t)

        def isOpened(self):
            # Kamera `acilis` saniyesinden once HIC acilmiyor.
            return not self.olu and time.monotonic() - T0 >= acilis

        def set(self, *a):
            return True

        def read(self):
            time.sleep(0.04)          # ~25 fps, gerçek zamanlı
            t = time.monotonic() - T0
            if S.get("takilir") is not None and t >= S["takilir"]:
                threading.Event().wait()      # ölü soket: hiç dönmez
            a, b = S.get("kopuk", (0, 0))
            if self.olu or a <= t < b or gitti_mi(t):
                return False, None
            return True, kare()

        def release(self):
            pass

    kopru.cv2.VideoCapture = lambda *a, **k: SahteKamera()

    # Kameranın olay akışının yerine: sağlık (bagli) her 0.2 sn tazelenir,
    # olaylar zamanı gelince deftere yazılır — gerçek zamanla, köprüyle aynı
    # monotonic saatte.
    O = S.get("olay")
    if O:
        def olay_akisi() -> None:
            d = olay.defter()
            bekleyen = sorted(O.get("olaylar", []))
            while True:
                t = time.monotonic() - T0
                # `koptu`: bu saniyeden sonra akış kopuk (dinleyici bağlantıyı
                # kaybetti) — sağlık o an düşer.
                if O.get("koptu") is not None and t >= O["koptu"]:
                    d.baglanti(False, time.monotonic())
                elif O.get("bagli"):
                    d.baglanti(True, time.monotonic())
                while bekleyen and bekleyen[0][0] <= t:
                    _, kod, eylem = bekleyen.pop(0)
                    olay.kaydet(kod, eylem, time.monotonic())
                time.sleep(0.05)
        threading.Thread(target=olay_akisi, daemon=True).start()

    threading.Thread(target=kopru.main, daemon=True).start()
    time.sleep(S["sure"])

    for g in gonderimler:
        print(f"   t={g['t']:5.2f}s  {g['id'][:8]}")

    hata = 0
    eslesen = 0
    for i, (a, b) in enumerate(S["pencereler"], 1):
        icinde = [g for g in gonderimler if a <= g["t"] <= b]
        eslesen += len(icinde)
        if not icinde:
            print(f"FAIL: {i}. araç ({a}-{b}s) hiç gönderilmedi")
            hata = 1

    if S.get("tekrar"):
        benzersiz = {g["id"] for g in gonderimler}
        en_cok = max((sum(1 for g in gonderimler if g["id"] == i)
                      for i in benzersiz), default=0)
        if en_cok != S["tekrar"]:
            print(f"FAIL: aynı islem_id ile {S['tekrar']} deneme bekleniyordu, {en_cok}")
            hata = 1
    if acilis:
        erken = [k for k in kalpler if k < acilis]
        if erken:
            print(f"FAIL: kamera acilmadan kalp atisi gonderildi (t={erken[0]:.2f}s)")
            hata = 1
        if not kalpler:
            print("FAIL: kamera acildiktan sonra hic kalp atisi gonderilmedi")
            hata = 1
    if S.get("kayitta_sirayla"):
        import glob as _glob
        metin = ""
        for yol in _glob.glob(os.path.join(os.environ["PROGRAMDATA"], "Otopark",
                                           "kayit", "*.log")):
            with open(yol, encoding="utf-8", errors="replace") as f:
                metin += f.read()
        konum = 0
        for parca in S["kayitta_sirayla"]:
            # Ilk parca kopmayi, sonraki ONDAN SONRA gelen satiri arar.
            i = metin.find(parca, konum)
            if i < 0:
                print(f"FAIL: kayitta sirayla bulunamadi: {parca!r}")
                hata = 1
                break
            konum = i + len(parca)
    if S.get("yon"):
        yanlis = sorted({str(g["yon"]) for g in gonderimler if g["yon"] != S["yon"]})
        if yanlis:
            print(f"FAIL: olaylar {S['yon']} şeridiyle gitmeliydi, giden: {yanlis}")
            hata = 1
    # Boş şerit pencereleri: öğrenilmiş bir boş şerit gönderilMEMELİ, henüz
    # öğrenilmemiş (ya da öğrenilmemesi gereken) boş şerit gönderilMELİ.
    for a, b in S.get("bos_gonderilmez", []):
        icinde = [g for g in gonderimler if a <= g["t"] <= b]
        if icinde:
            print(f"FAIL: boş şerit ({a}-{b}s) öğrenilmiş olmalıydı ama "
                  f"{len(icinde)} kez gönderildi")
            hata = 1
    for a, b in S.get("bos_gonderilir", []):
        if not [g for g in gonderimler if a <= g["t"] <= b]:
            print(f"FAIL: boş şerit ({a}-{b}s) gönderilmeliydi — öğrenilmemesi "
                  "gereken bir şey öğrenildi")
            hata = 1
    if S.get("son_baslik"):
        isaretli = [g.get("basliklar", {}).get("x-kamera-son-gonderim") == "1"
                    for g in sorted(gonderimler, key=lambda g: g["t"])]
        if isaretli != [False] * (len(isaretli) - 1) + [True]:
            print(f"FAIL: yalnızca son deneme işaretli olmalıydı: {isaretli}")
            hata = 1
    # 1.2.2 (A): kamera şifreyi reddederken akış HİÇ açılmamalı ve sınama
    # seyrek olmalı (her sınama gerçekte bir başarısız giriş).
    if S.get("sifreyle_acilmaz"):
        a, b = S["sifreyle_acilmaz"]
        acilan = [t for t in acilislar if a < t < b]
        if acilan:
            print(f"FAIL: kamera şifreyi reddederken akış {len(acilan)} kez açıldı "
                  f"(t={', '.join(f'{t:.2f}' for t in acilan)}) — her biri eski "
                  "şifreyle bir giriş denemesi")
            hata = 1
    if S.get("sinama_en_cok"):
        a, b, n = S["sinama_en_cok"]
        say = len([t for t, _ in sinamalar if a < t < b])
        if not 1 <= say <= n:
            print(f"FAIL: {a}-{b}s arasında 1..{n} şifre sınaması bekleniyordu, {say}")
            hata = 1
    if S.get("rtsp") == _KIMLIKLI_RTSP and S.get("sifre"):
        yanlis_arg = sorted({str(x) for _, x in sinamalar if x != _KIMLIKLI_SINAMA})
        if not sinamalar or yanlis_arg:
            print(f"FAIL: şifre sınaması köprünün kendi adresini çözüp sormalıydı "
                  f"{_KIMLIKLI_SINAMA}; gelen: {yanlis_arg or 'hiç sınama yok'}")
            hata = 1
    if S.get("geri_cekilme"):
        # Akış `a`da koptu: açma denemeleri arasındaki boşluklar tabandan
        # başlayıp ikiye katlanmalı, tavanda durmalı.
        a, b = S["geri_cekilme"]
        taban, tavan = (float(x) for x in S["yeniden_baglan"])
        anlar = [t for t in acilislar if a < t < b]
        bosluklar = [y - x for x, y in zip([a] + anlar, anlar)]
        beklenen = [min(taban * 2 ** k, tavan) for k in range(len(bosluklar))]
        uymayan = [(round(g, 2), e) for g, e in zip(bosluklar, beklenen)
                   if not e * 0.75 <= g <= e + 0.5]
        if len(anlar) < 5 or uymayan:
            print(f"FAIL: yeniden bağlanma aralıkları {[round(g, 2) for g in bosluklar]}, "
                  f"beklenen ~{beklenen} (uymayan: {uymayan})")
            hata = 1
    if S.get("sifirlama"):
        # Kamera döndükten sonraki İLK kopma: bekleme tabana dönmüş olmalı.
        x = S["sifirlama"]
        taban = float(S["yeniden_baglan"][0])
        sonraki = [t for t in acilislar if t > x]
        if not sonraki or not x + taban * 0.75 <= sonraki[0] <= x + taban + 0.5:
            ilk = f"{sonraki[0]:.2f}" if sonraki else "yok"
            print(f"FAIL: {x}s'deki kopmadan sonra ilk deneme ~{x + taban:.2f}s "
                  f"bekleniyordu, {ilk} — bekleme iyi karede sıfırlanmamış")
            hata = 1
    # 1.2.3 kanıt fotoğrafı: kutu varsa HER gönderimde geçerli bir JPEG
    # (≤ 100 KB, sunucunun sınırı) ve okuma kopyasıyla aynı boyutta; kutu
    # yoksa alan hiç yok.
    if S.get("kirpma"):
        import base64 as _b64
        import cv2 as _cv2

        def _coz(s: str):
            b = _b64.b64decode(s, validate=True)
            img = _cv2.imdecode(np.frombuffer(b, np.uint8), _cv2.IMREAD_COLOR)
            return b, img

        for g in gonderimler:
            if not g["kanit"]:
                print(f"FAIL: t={g['t']:.2f}s gönderiminde kanıt fotoğrafı yok")
                hata = 1
                continue
            b, img = _coz(g["kanit"])
            _, okuma = _coz(g["foto"])
            if b[:3] != b"\xff\xd8\xff" or len(b) > 102_400 or img is None:
                print(f"FAIL: t={g['t']:.2f}s kanıt fotoğrafı geçersiz "
                      f"({len(b)} bayt, başı {b[:3]!r})")
                hata = 1
            elif img.shape[:2] != okuma.shape[:2]:
                print(f"FAIL: kanıt {img.shape[:2]} okuma kopyası {okuma.shape[:2]} "
                      "ile aynı kırpıktan gelmiyor")
                hata = 1
    else:
        olan = [g for g in gonderimler if g["kanit_var"]]
        if olan:
            print(f"FAIL: kırpma kutusu yokken {len(olan)} gönderim kanıt fotoğrafı "
                  "taşıdı — kutusuz şeritte fotoğraf saklanmamalı")
            hata = 1
    if S.get("bekci_beklenir"):
        a, b = S["bekci_beklenir"]
        if not bekci_cagrilari or not a <= bekci_cagrilari[0] <= b:
            ilk = f"{bekci_cagrilari[0]:.2f}s" if bekci_cagrilari else "hiç"
            print(f"FAIL: bekçi takılan döngüyü {a}-{b}s içinde kapatmalıydı, {ilk}")
            hata = 1
    elif bekci_cagrilari:
        print(f"FAIL: bekçi takılmayan döngüde tetiklendi (t={bekci_cagrilari[0]:.2f}s) "
              "— meşru bir bekleme canlılık damgası basmıyor")
        hata = 1
    if S.get("tek") and len({g["id"] for g in gonderimler}) != 1:
        print(f"FAIL: 1 gönderim bekleniyordu, {len({g['id'] for g in gonderimler})}")
        hata = 1

    # ---- 1.2.5 geçen araç kontrolleri -------------------------------------
    # Aynı islem_id'nin yeniden denemeleri TEK gönderim sayılır.
    import base64 as _b64
    import cv2 as _cv2

    def _gri(foto: str) -> np.ndarray:
        return _cv2.imdecode(np.frombuffer(_b64.b64decode(foto), np.uint8),
                             _cv2.IMREAD_GRAYSCALE)

    ilk_deneme: dict[str, dict] = {}
    for g in sorted(gonderimler, key=lambda g: g["t"]):
        ilk_deneme.setdefault(g["id"], g)
    tekil = list(ilk_deneme.values())
    # Sunucudaki modelin yerine aynı ölçü (arac_var_mi): içinde araç var mı.
    aracli = [g for g in tekil if float(_gri(g["foto"]).mean()) > 120]

    if "gonderim_sayisi" in S and len(tekil) != S["gonderim_sayisi"]:
        print(f"FAIL: {S['gonderim_sayisi']} gönderim bekleniyordu, {len(tekil)} "
              f"(t={', '.join('%.2f' % g['t'] for g in tekil)})")
        hata = 1
    if "arac_gonderim_sayisi" in S and len(aracli) != S["arac_gonderim_sayisi"]:
        print(f"FAIL: içinde araç olan {S['arac_gonderim_sayisi']} gönderim "
              f"bekleniyordu, {len(aracli)} "
              f"(t={', '.join('%.2f' % g['t'] for g in aracli)})")
        hata = 1
    # 1.2.6: bu pencerelerde HİÇBİR gönderim olmamalı (araç olmayan geçiş,
    # gönderilmiş aracın gidişi, olaysız atlanan geçişler).
    for a, b in S.get("gonderilmez", []):
        icinde = [g for g in tekil if a <= g["t"] <= b]
        if icinde:
            print(f"FAIL: {a}-{b}s arasında gönderim olmamalıydı, "
                  f"{len(icinde)} var (t={', '.join('%.2f' % g['t'] for g in icinde)})")
            hata = 1
    # 1.2.6: gönderilen kare aracın TAMAMINI içermeli — gövde (220) satırları
    # 90:390 boyunca 400 piksel genişliğinde; kadrajın %62.5'i. Kısmi kare
    # (aracın yalnızca bir dilimi) bu oranın çok altında kalır.
    if S.get("tam_arac"):
        for i, (a, b) in enumerate(S["pencereler"], 1):
            icinde = [g for g in tekil if a <= g["t"] <= b]
            for g in icinde:
                gri = _gri(g["foto"])
                bant = gri[120:360, :]
                oran = float((bant >= 180).mean())
                if oran < 0.55:
                    print(f"FAIL: {i}. araç kısmi gönderildi — gövdenin kapladığı oran "
                          f"{oran:.2f} (tam araç ≈0.62)")
                    hata = 1
    # 1.2.6: olaysız atlanan her geçişin kırpığı kayıt klasörünün altındaki
    # `atlanan` klasörüne saklanmalı (sahada "gerçek araç atlandı mı" kanıtı).
    if "atlanan" in S:
        import glob as _glob
        atl = _glob.glob(os.path.join(os.environ["PROGRAMDATA"], "Otopark", "kayit",
                                      "atlanan", "*.jpg"))
        if len(atl) != S["atlanan"]:
            print(f"FAIL: atlanan klasöründe {S['atlanan']} kırpık bekleniyordu, "
                  f"{len(atl)} var")
            hata = 1
    if S.get("keskin"):
        # Ölçüt: aynı aracın en keskin hâli, köprünün yolundan (JPEG 92) geçmiş.
        ornek = gecen_ciz(np.full((480, 640, 3), 100, np.uint8), 120, 220, True, True)
        ok_, buf = _cv2.imencode(".jpg", ornek, [int(_cv2.IMWRITE_JPEG_QUALITY), 92])
        ref = keskinlik_olc(_cv2.imdecode(buf, _cv2.IMREAD_GRAYSCALE))
        for i, (a, b) in enumerate(S["pencereler"], 1):
            icinde = [g for g in aracli if a <= g["t"] <= b]
            if not icinde:
                print(f"FAIL: {i}. geçen araç ({a}-{b}s) için içinde ARAÇ olan "
                      "gönderim yok — boş şerit ya da yarım araç gitti")
                hata = 1
                continue
            en_iyi = max(keskinlik_olc(_gri(g["foto"])) for g in icinde)
            if en_iyi < 0.5 * ref:
                print(f"FAIL: {i}. geçen araç bulanık gönderildi (keskinlik "
                      f"{en_iyi:.0f}, en keskin hâli {ref:.0f}) — en keskin kare seçilmedi")
                hata = 1

    if not hata:
        fazla = len(gonderimler) - eslesen
        ek = f"  (+{fazla} boş şerit fotoğrafı)" if fazla else ""
        print(f"PASS: {ad}{ek}")
    return hata


if __name__ == "__main__":
    sys.exit(tek_kos(sys.argv[1]) if len(sys.argv) > 1 else hepsini_kos())
