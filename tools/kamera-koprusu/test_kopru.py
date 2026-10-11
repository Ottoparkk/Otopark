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
}


def hepsini_kos() -> int:
    kotu = []
    for ad in SENARYOLAR:
        print(f"\n{'=' * 62}\n{ad}\n{'=' * 62}", flush=True)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), ad],
                           env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        if r.returncode:
            kotu.append(ad)
    print("\n" + "=" * 62)
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
        def __init__(self, kod):
            self.status_code = kod
            self.text = '{"ok":true}'

    def post(url, json=None, headers=None, timeout=None):
        # Kalp atışı: 400 beklenen cevaptır ve sıradaki durum kodunu
        # TÜKETMEMELİ. kopru açılışta bir kalp atışı yollar (son_kalp = 0.0'a
        # karşı monotonic(), yani sistem çalışma süresi).
        if not (json and json.get("foto_base64")):
            kalpler.append(time.monotonic() - T0)
            return Yanit(400)
        # Yapay gecikmeden ÖNCE kaydedilir: ölçtüğümüz şey köprünün göndermeye
        # karar verdiği an, taklit ağın yavaşlığı değil.
        gonderimler.append({"t": time.monotonic() - T0, "id": json["islem_id"],
                            "yon": json.get("yon")})
        if S.get("yavas"):
            time.sleep(S["yavas"])
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

    os.environ.update(WEBHOOK_URL="http://stub/kamera-webhook",
                      KAMERA_SECRET="x" * 32,
                      RTSP_URL="rtsp://stub/1", YON=S.get("yon", "GIRIS"))
    if S.get("max_bekleme"):
        os.environ["MAX_BEKLEME_SN"] = S["max_bekleme"]
    if S.get("acilis_bekleme"):
        os.environ["ACILIS_BEKLEME_SN"] = S["acilis_bekleme"]

    sys.path.insert(0, BURASI)
    import cv2
    import kopru

    global T0
    T0 = time.monotonic()

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

    class SahteKamera:
        def isOpened(self):
            # Kamera `acilis` saniyesinden once HIC acilmiyor.
            return time.monotonic() - T0 >= acilis

        def set(self, *a):
            return True

        def read(self):
            time.sleep(0.04)          # ~25 fps, gerçek zamanlı
            a, b = S.get("kopuk", (0, 0))
            if a <= time.monotonic() - T0 < b:
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
    if S.get("tek") and len({g["id"] for g in gonderimler}) != 1:
        print(f"FAIL: 1 gönderim bekleniyordu, {len({g['id'] for g in gonderimler})}")
        hata = 1

    if not hata:
        fazla = len(gonderimler) - eslesen
        ek = f"  (+{fazla} boş şerit — BOS_REFERANS ile sıfırlanır)" if fazla else ""
        print(f"PASS: {ad}{ek}")
    return hata


if __name__ == "__main__":
    sys.exit(tek_kos(sys.argv[1]) if len(sys.argv) > 1 else hepsini_kos())
