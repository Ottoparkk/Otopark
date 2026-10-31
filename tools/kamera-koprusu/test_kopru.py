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
    if S.get("sifre_bekleme"):
        os.environ["SIFRE_RED_BEKLEME_SN"] = S["sifre_bekleme"]
    if S.get("yeniden_baglan"):
        os.environ["YENIDEN_BAGLAN_SN"], os.environ["YENIDEN_BAGLAN_MAX_SN"] = S["yeniden_baglan"]

    sys.path.insert(0, BURASI)
    import cv2
    import kopru
    import kesif

    global T0
    T0 = time.monotonic()

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
                return e
        return BOS

    def kare():
        t = time.monotonic() - T0
        e = evre(t)
        f = np.full((480, 640, 3), 100, np.uint8)
        if e == BOS:
            return f
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
    if S.get("tek") and len({g["id"] for g in gonderimler}) != 1:
        print(f"FAIL: 1 gönderim bekleniyordu, {len({g['id'] for g in gonderimler})}")
        hata = 1

    if not hata:
        fazla = len(gonderimler) - eslesen
        ek = f"  (+{fazla} boş şerit fotoğrafı)" if fazla else ""
        print(f"PASS: {ad}{ek}")
    return hata


if __name__ == "__main__":
    sys.exit(tek_kos(sys.argv[1]) if len(sys.argv) > 1 else hepsini_kos())
