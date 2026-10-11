# -*- coding: utf-8 -*-
"""
Kamera köprüsü kurulum sihirbazı.

    python kurulum.py

Amaç: bariyerdeki bilgisayara köprüyü kuran kişinin teknik olması gerekmesin.
Elle yapıldığında sekiz adımdı ve üçü teknik olmayan birini durduruyordu:
piksel koordinatı ölçmek, kameranın RTSP yolunu bilmek, gizli anahtarı bir
PowerShell dosyasına yapıştırmak. Sihirbaz üçünü de ortadan kaldırıyor.

Sessizce öldüren şeyleri de kendisi hallediyor: uyku, dizüstü kapağı, ve
kimse oturum açmadan yeniden başlatma.
"""
from __future__ import annotations

import base64
import ctypes
import json
import os
import subprocess
import sys
import time
import urllib.parse

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import gunluk  # noqa: E402

WINDOWS = os.name == "nt"
AYAR_KLASORU = os.path.join(
    os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark"
)


# ------------------------------------------------------------------ yardım ---

def baslik(n: int, metin: str) -> None:
    print(f"\n{'─' * 64}\n  {n}. {metin}\n{'─' * 64}", flush=True)


# Girdi akışı kapalıysa (yönlendirilmiş stdin, konsolsuz bağlam) `input()`
# EOFError atıyor ve bu, paketlenmiş sürümde ekrana bir yığın izi + "Beklenmeyen
# bir hata oluştu" olarak düşüyordu. Teknik olmayan biri için bu, kurulumun
# çöktüğü anlamına gelir; oysa olan şey sadece soruya cevap gelmemesi.

def sor(soru: str, varsayilan: str = "") -> str:
    ek = f" [{varsayilan}]" if varsayilan else ""
    try:
        c = input(f"  {soru}{ek}: ").strip()
    except EOFError:
        if varsayilan:
            print(f"  (cevap yok — varsayılan: {varsayilan})")
            return varsayilan
        sys.exit("\n  Girdi okunamadı. Kurulumu bir pencereden, çift tıklayarak "
                 "çalıştırın.")
    return c or varsayilan


def evet_mi(soru: str, varsayilan: bool = False) -> bool:
    ek = "E/h" if varsayilan else "e/H"
    try:
        c = input(f"  {soru} ({ek}): ").strip().lower()
    except EOFError:
        # Varsayılanı sessizce uygulamak yerine SÖYLE: bu dalda kullanıcı
        # hiçbir şey seçmedi ve seçilmiş gibi davranmak yanıltıcı olur.
        print(f"  (cevap yok — varsayılan: {'evet' if varsayilan else 'hayır'})")
        return varsayilan
    if not c:
        return varsayilan
    return c.startswith("e")


def yonetici_mi() -> bool:
    if not WINDOWS:
        return os.geteuid() == 0 if hasattr(os, "geteuid") else False
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


def calistir(komut: list[str]) -> tuple[bool, str]:
    try:
        r = subprocess.run(komut, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        return r.returncode == 0, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return False, str(e)


# ------------------------------------------------------------- 1. sunucu ---

KOD_DOSYASI = "kurulum-kodu.txt"


def kod_klasorleri() -> list[str]:
    """Kodun aranacağı yerler: .exe'nin yanı, sonra kaynak klasörü."""
    yerler = [BURASI]
    if getattr(sys, "frozen", False):
        yerler.insert(0, os.path.dirname(sys.executable))
    return yerler


def kodu_coz(kod: str) -> dict | None:
    """
    base64 kurulum kodunu çözer; anlaşılmazsa None.

    İKİ biçim kabul ediliyor ve ikisi de desteklenmek zorunda:

      {"WEBHOOK_URL", "KOD"}            → yeni. Kısa, tek kullanımlık bir
                                          eşleştirme kodu; gizli anahtarı
                                          sunucu üretip veriyor.
      {"WEBHOOK_URL", "KAMERA_SECRET",  → eski. Ortak anahtar dosyanın
       "YON"}                             içinde. İnternetsiz ya da sunucu
                                          tarafı henüz hazır olmayan bir
                                          kurulumun tek yolu bu, o yüzden
                                          kaldırılmıyor.

    Ayrı ve doğrulayan bir fonksiyon: eksik alanlı bir kod eskiden sessizce
    kabul edilip bağlantı testinde `'WEBHOOK_URL'` diye anlamsız bir hataya
    dönüşüyordu.
    """
    kod = kod.strip()
    if not kod:
        return None
    try:
        veri = json.loads(base64.b64decode(kod + "=" * (-len(kod) % 4)))
    except Exception:
        return None
    if not isinstance(veri, dict) or not veri.get("WEBHOOK_URL"):
        return None

    if veri.get("KOD"):
        return {"WEBHOOK_URL": str(veri["WEBHOOK_URL"]), "KOD": str(veri["KOD"])}

    if not veri.get("KAMERA_SECRET"):
        return None

    # Anahtar YON, 'yon' değil — kopru.py ortam değişkeni adlarını kullanıyor.
    # Küçük harfle okumak sessizce 'GIRIS'e düşüyordu ve çıkış kamerası kuran
    # birine "GIRIS şeridi" diyordu. Şerit bu projede tahmin edilmeyecek tek
    # ayar: yanlışı, giden araçlara bilet açar.
    #
    # Eksik ya da anlaşılmaz şerit de GIRIS'e DÜŞMEZ: boş bırakılır ve
    # koddan_ayar onu sorar. Çıkış kamerası için hazırlanmış ama şeridi eksik
    # bir kod, tek satırlık bir uyarıyla giriş kamerası olarak kurulmamalı.
    yon = str(veri.get("YON") or "").strip().upper()
    veri["YON"] = yon if yon in gunluk.SERITLER else ""
    return veri


def serit_sor() -> str:
    """
    Şeridi sorar. VARSAYILAN YOK ve bu bilerek böyle: Enter'a basıp geçmek bir
    tahmindir, ve yanlış tahmin çıkan araçlara bilet açar.
    """
    while True:
        yon = sor(f"Bu kamera hangi şerit? {gunluk.SERIT_SECENEKLERI}").strip().upper()
        if yon in gunluk.SERITLER:
            return yon
        print("  ! GIRIS, CIKIS ya da ORTAK yazın.")


def guvenli_adres(adres: str) -> bool:
    """
    https, ya da bu bilgisayarın kendisi (yerel `supabase start`).

    Eşleştirme kodu ve karşılığında dönen gizli anahtar bu adrese gidip
    geliyor; düz http ikisini de ağdaki herkese okuturdu. Adres yapıştırılan
    bir dosyadan geldiği için ona güvenilmez, bakılır.
    """
    try:
        u = urllib.parse.urlsplit(adres.strip())
    except Exception:
        return False
    if u.scheme == "https" and u.hostname:
        return True
    return u.scheme == "http" and u.hostname in ("localhost", "127.0.0.1", "::1")


def eslestirme_adresi(webhook_url: str) -> str:
    """
    kamera-webhook adresinden kamera-eslestir adresini türetir.

    Düz `replace` YETMEZ: eski kurulumlarda adres gizli anahtarı yol
    parçası olarak taşıyabiliyor (.../kamera-webhook/<gizli>/giris), ve o
    biçimde replace anahtarı da yeni adrese taşırdı.
    """
    taban, ayrac, _ = webhook_url.partition("/functions/v1/")
    if not ayrac:
        return webhook_url.rstrip("/") + "/functions/v1/kamera-eslestir"
    return taban + "/functions/v1/kamera-eslestir"


def eslestir(webhook_url: str, kod: str) -> dict | None:
    """
    Kısa kodu bu kameranın KENDİ gizli anahtarına çevirir.

    Anahtar sunucuda üretiliyor ve yalnızca sha256'sı saklanıyor; buraya
    hayatında bir kez geliyor. Kod tek kullanımlık, o yüzden başarılı bir
    eşleştirmeden sonra ayar dosyası HEMEN yazılıyor (bkz. main).
    """
    import requests

    adres = eslestirme_adresi(webhook_url)
    if not guvenli_adres(adres):
        print("  ✗ Sunucu adresi https:// ile başlamalı — kod ve gizli anahtar")
        print("    şifrelenmemiş bir bağlantıdan gönderilmez.")
        return None
    print("  Sunucuyla eşleştiriliyor…", flush=True)
    try:
        r = requests.post(adres, json={"kod": kod}, timeout=25)
    except Exception as e:
        print(f"  ✗ Sunucuya ulaşılamadı: {e}")
        print("    Bu bilgisayarın internet bağlantısını kontrol edin.")
        return None

    if r.status_code != 200:
        try:
            mesaj = r.json().get("hata") or r.text[:160]
        except Exception:
            mesaj = r.text[:160]
        print(f"  ✗ {mesaj}")
        if r.status_code == 404:
            print("    Eşleştirme servisi bulunamadı — uygulamayı kuran kişiye")
            print("    'kamera-eslestir yayına alındı mı?' diye sorun.")
        elif r.status_code >= 500:
            # Kod reddedilmedi, sunucu cevap veremedi: aynı kod hâlâ geçerli.
            print("    Sorun kodda değil. Birkaç dakika sonra AYNI kodla tekrar deneyin.")
        return None

    try:
        c = r.json()
    except Exception:
        print("  ✗ Sunucudan beklenmeyen cevap geldi.")
        return None

    if not c.get("gizli") or not c.get("webhook_url"):
        print("  ✗ Sunucudan eksik cevap geldi.")
        return None
    # Köprü gizli anahtarı HER istekte bu adrese gönderecek.
    if not guvenli_adres(str(c["webhook_url"])):
        print("  ✗ Sunucu https olmayan bir adres bildirdi; kurulum durduruldu.")
        return None

    # Şerit TAHMİN EDİLMEZ. Sunucudan anlaşılmaz bir değer gelirse kurulum
    # durur: 'GIRIS'e düşmek, çıkış kamerasının giden araçlara bilet
    # açmasıyla biter ve bunu kimse fark etmez.
    yon = str(c.get("yon", "")).upper()
    if yon not in gunluk.SERITLER:
        print(f"  ✗ Sunucudan gelen şerit anlaşılmadı: {yon or '(boş)'}")
        print("    Bu kurulum programı eski olabilir — güncel sürümü indirin.")
        return None

    ayar = {
        "WEBHOOK_URL": str(c["webhook_url"]),
        "KAMERA_SECRET": str(c["gizli"]),
        "YON": yon,
    }
    if c.get("cihaz"):
        ayar["CIHAZ"] = str(c["cihaz"])
    print(f"  ✓ Eşleştirildi — {c.get('ad') or 'kamera'} · {yon} şeridi")
    return ayar


def koddan_ayar(ham: str) -> dict | None:
    """Çözülen koda göre: ya doğrudan ayar, ya sunucuyla eşleştirme."""
    veri = kodu_coz(ham)
    if veri is None:
        return None
    if veri.get("KAMERA_SECRET"):
        if not veri["YON"]:
            print("  ! Kodda şerit bilgisi yok ya da anlaşılmıyor — elle seçin.")
            veri["YON"] = serit_sor()
        print(f"  ✓ Kod çözüldü — {veri['YON']} şeridi")
        return veri
    return eslestir(veri["WEBHOOK_URL"], veri["KOD"])


def dosyadan_kod() -> tuple[str, str] | None:
    """
    Yanına konmuş `kurulum-kodu.txt`. (kod, yol) ya da None.

    Elle yazılacak en uzun ve en hataya açık şey gizli anahtar: 40 küçük
    karakterin birinde yapılan hata, kurulumun sonunda "gizli anahtar yanlış"
    olarak çıkıyor ve sebebi görünmüyor. Yöneticinin tek satırlık bir dosya
    göndermesi, telefonda anahtar okutmaktan hem kolay hem güvenli.
    """
    for klasor in kod_klasorleri():
        yol = os.path.join(klasor, KOD_DOSYASI)
        if os.path.isfile(yol):
            try:
                with open(yol, encoding="utf-8-sig") as f:
                    kod = f.read().strip()
                if kod:
                    return kod, yol
            except Exception:
                pass
    return None


def sunucu_bilgisi() -> dict:
    """
    Webhook adresi + gizli anahtar. Üç yol: yanındaki `kurulum-kodu.txt`,
    yapıştırılan kod, ya da elle giriş. Elle giriş her zaman çalışır — sihirbaz
    sunucu tarafında hiçbir şeye ihtiyaç duymadan kurulabilmeli.
    """
    baslik(1, "Sunucu bilgileri")

    dosya = dosyadan_kod()
    if dosya:
        ham, yol = dosya
        print(f"  ✓ Kurulum kodu dosyadan okundu: {os.path.basename(yol)}")
        veri = koddan_ayar(ham)
        if veri:
            # Dosya tek kullanımlık bir kod (ya da eski biçimde doğrudan
            # gizli anahtar) taşıyor ve işi bitti. Silmek varsayılan, ama
            # sormadan silinmiyor: ikinci şeridi kuracak kişinin elinden
            # dosyayı almak, kurulumu kolaylaştırmanın tam tersi olurdu.
            if evet_mi(f"{KOD_DOSYASI} silinsin mi (artık geçersiz)", True):
                try:
                    os.remove(yol)
                    print("  ✓ Silindi.")
                except Exception as e:
                    print(f"  ! Silinemedi: {e} — elle silin.")
            return veri
        print(f"  ! {os.path.basename(yol)} kullanılamadı, elle girelim.")

    print("  Uzun kurulum kodunuz varsa yapıştırın; yoksa boş bırakın.")
    girilen = sor("Kurulum kodu", "")
    if girilen:
        veri = koddan_ayar(girilen)
        if veri:
            return veri
        print("  ! Kod kullanılamadı, elle girelim.")

    print("\n  Webhook adresi Supabase projenizin adresidir:")
    print("    https://<proje>.supabase.co/functions/v1/kamera-webhook")
    url = ""
    while not url:
        url = sor("Webhook adresi")
        if "/functions/v1/kamera-webhook" not in url:
            print("  ! Adres .../functions/v1/kamera-webhook ile bitmeli.")
            url = ""

    # Kısa kod tercih edilen yol: uygulamada Yönetim → Kamera kurulumu
    # ekranından üretiliyor, 15 dakika geçerli ve telefonda okunabiliyor.
    print("\n  Uygulamadaki Kamera Kurulumu ekranından alınan kısa kod")
    print("  (XXXXX-XXXXX). Yoksa boş bırakın, gizli anahtarı elle girersiniz.")
    kisa = sor("Kurulum kodu", "")
    if kisa:
        veri = eslestir(url, kisa)
        if veri:
            return veri
        print("  ! Eşleştirilemedi, gizli anahtarı elle girelim.")

    print("\n  Gizli anahtar: Supabase → Edge Functions → Secrets içindeki")
    print("  KAMERA_WEBHOOK_SECRET ile birebir aynı olmalı.")
    gizli = ""
    while len(gizli) < 16:
        gizli = sor("Gizli anahtar")
        if len(gizli) < 16:
            print("  ! En az 16 karakter olmalı (sunucu daha kısasını reddediyor).")

    return {"WEBHOOK_URL": url, "KAMERA_SECRET": gizli, "YON": serit_sor()}


# ------------------------------------------------------------- 2. kamera ---

def kamera_bilgisi() -> tuple[str, tuple[int, int]]:
    import kesif

    baslik(2, "Kamera")
    print("  Ağdaki kameralar aranıyor…", flush=True)
    bulunan = kesif.kameralari_ara()
    if bulunan:
        for i, ip in enumerate(bulunan, 1):
            print(f"    {i}) {ip}")
        secim = sor("Numara seçin ya da IP yazın", "1")
        ip = bulunan[int(secim) - 1] if secim.isdigit() and \
            1 <= int(secim) <= len(bulunan) else secim
    else:
        print("  Kamera bulunamadı (bazı ağlar yayını engeller). IP'yi elle girin.")
        ip = sor("Kamera IP adresi")

    kullanici = sor("Kamera kullanıcı adı", "admin")
    sifre = sor("Kamera şifresi")
    port = port_sor()

    def bildir(marka, yol):
        print(f"    · {marka:<18} {yol}", flush=True)

    # Önce tek bir bağlantı denemesi. Ulaşılamayan bir adreste on şablonun
    # her biri zaman aşımına kadar beklerdi ve sonunda yine "bulunamadı"
    # derdi — sebebini söylemeden.
    sonuc = None
    if not kesif.port_acik(ip, port):
        print(f"\n  ! {ip}:{port} adresine ulaşılamıyor. Olası sebepler:")
        print("    - IP adresi yanlış")
        print("    - kamera kapalı ya da bu bilgisayarla aynı ağda değil")
        print("    - RTSP kameranın ayarlarında kapalı ya da port farklı")
    else:
        print("\n  RTSP adresi aranıyor (markaya göre deneniyor)…", flush=True)
        sonuc = kesif.rtsp_bul(ip, kullanici, sifre, port, bildir)
        if not sonuc:
            print("\n  ! Hiçbir adres kare vermedi. Olası sebepler:")
            print("    - kullanıcı adı ya da şifre yanlış")
            print("    - kamera bu listede olmayan bir adres kullanıyor")
    if not sonuc:
        elle = sor("RTSP adresini elle yazın (boş = çık)", "")
        if not elle:
            sys.exit("  Kurulum durduruldu.")
        return elle, (0, 0)

    url, marka, boyut = sonuc
    gizlenmis = url.replace(urllib.parse.quote(sifre, safe=""), "•••") if sifre else url
    print(f"\n  ✓ {marka} — {boyut[0]}×{boyut[1]}")
    print(f"    {gizlenmis}")
    return url, boyut


def port_sor() -> int:
    """
    RTSP portu: 1–65535, boş = 554.

    Ham girdi `int()`'e veriliyordu; tek bir yanlış tuş sihirbazı yığın iziyle
    çökertiyordu — üstelik eşleştirme kodu harcandıktan SONRA.
    """
    while True:
        c = sor("RTSP portu", "554").strip()
        if c.isdigit() and 1 <= int(c) <= 65535:
            return int(c)
        print("  ! Port 1 ile 65535 arasında bir sayı olmalı (çoğu kamerada 554).")


# -------------------------------------------------------------- 3. kırpma ---

def kirpma_ve_esikler(rtsp: str) -> dict:
    import kirpma_sunucu

    baslik(3, "Kırpma kutusu")
    print("  Tarayıcı açılıyor. Bariyerde bir araç varken plakanın")
    print("  dikdörtgenini sürükleyin, sonra 'Kaydet' deyin.")
    kutu, olcumler = kirpma_sunucu.kirpma_sec(rtsp)

    ayar: dict = {}
    if kutu:
        ayar["KIRPMA"] = ",".join(str(v) for v in kutu)
        print(f"  ✓ Kırpma: {ayar['KIRPMA']}")
    else:
        print("  ! Kırpma seçilmedi — tüm kare gönderilecek, okuma daha kötü olur.")

    durgun, hareket = kirpma_sunucu.esik_oner(olcumler)
    print(f"  ✓ Ölçülen eşikler: DURGUN={durgun}  HAREKET={hareket}")
    ayar["DURGUN_ESIGI"] = durgun
    ayar["HAREKET_ESIGI"] = hareket
    return ayar


# ---------------------------------------------------------------- 4. test ---

TESHIS = {
    401: "Gizli anahtar yanlış. Supabase'deki KAMERA_WEBHOOK_SECRET ile aynı olmalı.",
    403: "Kamera girişi kapalı. Uygulamada Yönetim → Otopark Ayarları → "
         "'Kamera girişi açık' seçeneğini açın.",
    404: "Adres bulunamadı. Webhook adresini kontrol edin.",
    409: "Plaka okuma kapalı. Aynı ayarlar ekranından açın.",
    429: "Hız sınırına takıldı. Biraz bekleyip tekrar deneyin.",
    502: "Sunucu plakayı okuyamadı — ANTHROPIC_API_KEY eksik ya da geçersiz olabilir.",
}


def baglanti_testi(ayar: dict) -> bool:
    """
    Boş bir POST atar: webhook gizli anahtarı doğrular ve sonra boş gövdeyi
    reddeder, yani 400 beklenen ve BAŞARILI cevaptır. İstek `x-kamera-deneme`
    taşır; sunucu onun için kalp atışı VURMAZ (bkz. webhook_yokla).

    Bilerek fotoğraf göndermiyoruz: gerçek bir kare gerçek bir bilet açardı ve
    kurulum, kasada silinmesi gereken bir kayıt bırakmamalı.
    """
    baslik(4, "Bağlantı testi")
    kod, ayrinti = webhook_yokla(ayar)
    if kod is None:
        print(f"  ✗ Sunucuya ulaşılamadı: {ayrinti}")
        print("    Bu bilgisayarın internet bağlantısını kontrol edin.")
        return False

    if kod == 400:
        print("  ✓ Bağlantı ve gizli anahtar doğru.")
        return True
    if kod in TESHIS:
        print(f"  ✗ {TESHIS[kod]}")
        return False
    print(f"  ✗ Beklenmeyen cevap: {kod} {ayrinti[:160]}")
    return False


def webhook_yokla(ayar: dict) -> tuple[int | None, str]:
    """
    Boş POST'un durum kodu; sunucuya ulaşılamadıysa (None, sebep).

    Bağlantı testi ve "kayıtlı kimlik hâlâ geçerli mi" sorusu aynı yoklamayı
    kullanıyor — ikisi ayrı yazılsaydı biri 400'ü başarı sayarken öbürü
    saymayabilirdi.
    """
    import requests

    # `x-kamera-deneme`: sunucu bu istekte kimliği doğrular ama kalp atışı
    # VURMAZ. Vursaydı uygulama, kurulum daha ikinci adımdayken kamerayı
    # "Çalışıyor" gösterirdi ve aynı kodla yeniden eşleştirme penceresi de
    # (kameranın ilk kalp atışına kadar açık) burada kapanırdı. Kalp atışı,
    # köprünün KENDİSİ çalışmaya başlayınca gider.
    try:
        r = requests.post(ayar["WEBHOOK_URL"], json={},
                          headers={"x-kamera-secret": ayar["KAMERA_SECRET"],
                                   "x-kamera-deneme": "1"},
                          timeout=20)
    except Exception as e:
        return None, str(e)
    return r.status_code, str(getattr(r, "text", "") or "")


# Webhook'un YALNIZCA kimliği kabul ettikten sonra verdiği cevaplar. 403
# bilerek burada: "kamera girişi kapalı" kimliğin doğru olduğunu gösterir.
KIMLIK_GECERLI = (400, 403, 409, 429)


def kayitli_kimlikler() -> list[dict]:
    """Bu bilgisayarda daha önce yazılmış, eksiksiz kimlik taşıyan ayarlar."""
    import glob

    bulunan = []
    for yol in sorted(glob.glob(os.path.join(AYAR_KLASORU, "kopru-*.json"))):
        try:
            with open(yol, encoding="utf-8-sig") as f:
                veri = json.load(f)
        except Exception:
            continue
        if not isinstance(veri, dict):
            continue
        if str(veri.get("YON") or "").upper() not in gunluk.SERITLER:
            continue
        if not veri.get("WEBHOOK_URL") or not veri.get("KAMERA_SECRET"):
            continue
        veri["YON"] = str(veri["YON"]).upper()
        bulunan.append(veri)
    return bulunan


def mevcut_kimlik_sor() -> dict | None:
    """
    Yarıda kalmış ya da yenilenen bir kurulum için: diskteki kimlik hâlâ
    geçerliyse onu kullanmayı teklif eder. Kullanılacaksa ayarın TAMAMI döner
    (kamera adresi ve kırpma da), yoksa None.

    Eşleştirme kodu ilk denemede harcanmıştır. Sihirbaz yeniden çalıştırılınca
    kod sormak, kurulumu yapan kişiyi uygulamadan kamerayı silip yeni kod
    istemeye zorluyordu — oysa kimlik burada, diskte duruyor.

    Kimlik SUNUCUYA SORULUR; doğrulanamayan (ulaşılamadı, 401) teklif edilmez:
    ölü bir kimlikle sonuna kadar gidip bağlantı testinde duvara çarpmak,
    baştan kod istemekten kötüdür.
    """
    # Yanına yeni bir kurulum-kodu.txt konmuşsa niyet bellidir: YENİ bir
    # eşleştirme (çoğu zaman ikinci şerit). O durumda kayıtlı kimlik hiç
    # sorulmaz — sorulsaydı ve Enter'a basılsaydı yeni kod okunmadan İLK
    # şeridin kimliği bu kameraya bağlanırdı.
    if dosyadan_kod():
        return None

    for veri in kayitli_kimlikler():
        yon = veri["YON"]
        kod, _ = webhook_yokla(veri)
        if kod == 401:
            print(f"  ! {yon} şeridi için kayıtlı kimlik artık geçerli değil "
                  "(kamera uygulamadan kaldırılmış olabilir).")
            continue
        if kod not in KIMLIK_GECERLI:
            continue
        # Varsayılan HAYIR: yanlış "evet" yanlış şeride kamera bağlar (giden
        # araçlara bilet), yanlış "hayır" yalnızca bir soru daha sordurur.
        print(f"\n  Bu bilgisayarda {yon} şeridi için geçerli bir kimlik kayıtlı.")
        print(f"  {yon} şeridini YENİDEN kuruyorsanız Evet deyin (yeni kod gerekmez).")
        print("  Başka bir şerit kuracaksanız Hayır deyin.")
        if evet_mi(f"{yon} şeridi bu kimlikle yeniden kurulsun mu", False):
            return veri
    return None


def kimligi_sakla(ayar: dict) -> str:
    """
    Eşleştirmeden HEMEN sonraki yazım: kimlik kaybolmasın diye.

    O şeridin diskteki eski ayarının ÜSTÜNE BİNDİRİLİR, yerine geçmez. Dosya
    yalnızca kimlikle değiştirilirse, yeniden eşleştirilen bir şeritte
    sihirbaz kamera adımında bırakıldığında RTSP adresi ve kırpma kutusu
    gitmiş olur ve köprü her açılışta "RTSP_URL tanımlı değil" diye çıkar.
    Bindirince eski kamera ayarı yeni kimlikle çalışmaya devam eder.
    """
    yol = os.path.join(AYAR_KLASORU, f"kopru-{ayar['YON'].lower()}.json")
    eski: dict = {}
    try:
        with open(yol, encoding="utf-8-sig") as f:
            okunan = json.load(f)
        if isinstance(okunan, dict):
            eski = okunan
    except Exception:
        pass
    return ayari_yaz({**eski, **ayar})


# ----------------------------------------------------------------- 5. kur ---

def ayari_yaz(ayar: dict) -> str:
    os.makedirs(AYAR_KLASORU, exist_ok=True)
    yol = os.path.join(AYAR_KLASORU, f"kopru-{ayar['YON'].lower()}.json")
    kisitli = True
    if WINDOWS:
        # Dosya gizli anahtarı taşıyor. ÖNCE boş oluşturulup kısıtlanıyor,
        # anahtar SONRA yazılıyor: ProgramData'da yeni dosya her kullanıcının
        # okuyabildiği izinlerle doğar ve "yaz, sonra kısıtla" sırası bir
        # pencere bırakır — kısıtlama tutmazsa o pencere hiç kapanmaz.
        # Görev SYSTEM olarak koştuğu için dosya kullanıcı profilinde değil
        # ProgramData'da duruyor.
        if not os.path.isfile(yol):
            with open(yol, "w", encoding="utf-8"):
                pass
        kisitli = yalniz_yonetici(yol)
    with open(yol, "w", encoding="utf-8") as f:
        json.dump(ayar, f, ensure_ascii=False, indent=2)
    if not kisitli:
        print("  ! Ayar dosyasının izinleri kısıtlanamadı: gizli anahtar bu")
        print("    bilgisayardaki diğer kullanıcılar tarafından okunabilir.")
        print("    Kurulumu 'Yönetici olarak çalıştır' ile tekrarlayın.")

    # Kayıt klasörü de kısıtlanıyor. ProgramData varsayılanında her kullanıcı
    # okuyabiliyor ve kayıt, sunucunun okuduğu PLAKALARI içerebiliyor — KVKK
    # açısından kişisel veri. Klasör köprü başlamadan burada oluşturuluyor ki
    # izinler ilk satır yazılmadan önce yerinde olsun.
    kayit = gunluk.kayit_klasoru()
    try:
        os.makedirs(kayit, exist_ok=True)
        if WINDOWS and not yalniz_yonetici(kayit, klasor=True):
            print("  ! Kayıt klasörünün izinleri kısıtlanamadı (plakalar bu")
            print("    bilgisayardaki diğer kullanıcılar tarafından okunabilir).")
    except Exception as e:
        print(f"  ! Kayıt klasörü hazırlanamadı: {e}")
    return yol


def yalniz_yonetici(yol: str, klasor: bool = False) -> bool:
    """
    Devralınan izinleri kaldırır; yalnızca SYSTEM ve yöneticiler erişir.

    Grup ADI değil SID: 'Administrators' Windows'un diline göre değişir
    (Almanca 'Administratoren', Fransızca 'Administrateurs'…) ve tutmayan tek
    bir ad BÜTÜN komutu düşürür — devralmayı kaldıran kısmı da. S-1-5-18
    SYSTEM, S-1-5-32-544 yerleşik yöneticiler grubu; ikisi de her dilde aynı.

    Sonuç DÖNER ve çağıran onu kullanıcıya söyler: eskiden yok sayılıyordu ve
    yönetici olmadan çalıştırılan kurulum anahtarı sessizce açıkta bırakıyordu.
    """
    # Klasörde (OI)(CI): içine sonradan yazılan kayıt dosyaları da devralsın.
    hak = "(OI)(CI)(F)" if klasor else "(F)"
    komut = ["icacls", yol, "/inheritance:r",
             "/grant:r", f"*S-1-5-18:{hak}",
             "/grant:r", f"*S-1-5-32-544:{hak}"]
    # Yönetici OLMADAN çalıştırılan kurulum ("yine de devam et") yöneticiler
    # grubunun üyesi değildir: yalnızca yukarıdaki ikisine izin verilseydi
    # kısıtladığımız dosyaya BİZ de yazamazdık. O durumda dosyayı oluşturan
    # kullanıcı da eklenir — herkese açık kalmasından yine çok daha dar.
    if not yonetici_mi():
        kullanici = os.environ.get("USERNAME", "")
        alan = os.environ.get("USERDOMAIN", "")
        if kullanici:
            komut += ["/grant:r", f"{alan + chr(92) if alan else ''}{kullanici}:{hak}"]
    ok, _ = calistir(komut)
    return ok


def gorev_komutu(ayar_yolu: str) -> str:
    """
    Görev Zamanlayıcı'nın her açılışta çalıştıracağı komut.

    Paketlenmiş sürümde `--kopru` ŞART. Tek bir .exe var ve argümansız
    çalıştırıldığında SİHİRBAZI açıyor: onsuz bu görev her açılışta SYSTEM
    olarak görünmez bir kurulum sihirbazı başlatırdı — input() bekleyen,
    kimsenin göremediği, köprüyü hiç çalıştırmayan bir süreç. Otopark da
    kameranın çalıştığını sanarak bilet açmadan işlerdi.

    Ayrı fonksiyon olmasının tek sebebi bunun sınanabilmesi.
    """
    program, argumanlar = gorev_parcalari(ayar_yolu)
    return f'"{program}" {argumanlar}'


def gorev_parcalari(ayar_yolu: str) -> tuple[str, str]:
    """(program, argümanlar) — görev tanımı ikisini AYRI alanlarda ister."""
    if getattr(sys, "frozen", False):
        return sys.executable, f'--kopru --ayar "{ayar_yolu}"'
    return sys.executable, (f'"{os.path.join(BURASI, "kopru.py")}" '
                            f'--ayar "{ayar_yolu}"')


def gorev_xml(program: str, argumanlar: str) -> str:
    """
    Görev Zamanlayıcı tanımı.

    `schtasks /create /sc onstart ...` bayraklarıyla kurulan görev Windows'un
    varsayılanlarını taşır ve ikisi köprüyü SESSİZCE durdurur (ölçüldü):

      ExecutionTimeLimit = PT72H     üç gün sonra "çok uzun koştu" diye
                                     sonlandırılır
      StopIfGoingOnBatteries = true  önerilen kutu eski bir dizüstü; elektrik
                                     bir an kesilince görev durur

    İkisinde de görev bir sonraki açılışa kadar geri gelmez ve otopark bilet
    açmadan işler. Bu ayarlar bayrakla değiştirilemiyor, o yüzden XML.

      PT0S               süre sınırı yok
      RestartOnFailure   köprü ölürse bir dakika sonra yeniden başlar
      Delay PT30S        açılışta ağ ve kamera ayağa kalksın (köprü zaten
                         kamerayı bekler; bu yalnızca ilk denemeleri azaltır)
      IgnoreNew          aynı şerit için ikinci bir kopya başlamaz
    """
    from xml.sax.saxutils import escape

    return f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Otopark kamera koprusu. Kaldirmak icin OtoparkKamera.exe - Kaldir.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{escape(program)}</Command>
      <Arguments>{escape(argumanlar)}</Arguments>
    </Exec>
  </Actions>
</Task>
"""


def gorev_kur(ayar_yolu: str, yon: str) -> bool:
    import tempfile

    ad = f"Otopark Kamera Koprusu ({yon})"
    program, argumanlar = gorev_parcalari(ayar_yolu)

    # Yeniden kurulumda eski süreç hâlâ koşuyor olabilir. Durdurulmazsa yeni
    # ayarla başlatma isteği "zaten çalışıyor" diye yok sayılır (IgnoreNew) ve
    # köprü ESKİ ayarla koşmaya devam eder. Görev yoksa bu komut zararsız.
    calistir(["schtasks", "/end", "/tn", ad])

    # schtasks tanım dosyasını UTF-16 bekler.
    tutamac, xml_yolu = tempfile.mkstemp(prefix="otopark-gorev-", suffix=".xml")
    try:
        with os.fdopen(tutamac, "w", encoding="utf-16") as f:
            f.write(gorev_xml(program, argumanlar))
        ok, cikti = calistir(["schtasks", "/create", "/tn", ad,
                              "/xml", xml_yolu, "/f"])
    finally:
        try:
            os.remove(xml_yolu)
        except OSError:
            pass
    if not ok:
        print(f"  ✗ Görev oluşturulamadı: {cikti.strip()[:200]}")
        return False

    print(f"  ✓ Otomatik başlatma kuruldu: {ad}")
    # Zaman penceresi başlatmadan ÖNCE açılır: `schtasks /run` yavaş dönerse
    # köprü o sırada çoktan "başladı" yazmış olur ve pencere sonradan açılsaydı
    # o kayıt "bu denemeden önce" sayılırdı.
    basladi = time.time()
    calistir(["schtasks", "/run", "/tn", ad])
    return baslangic_dogrula(yon, basladi=basladi)


def _son_baslangic(yol: str, basladi: float) -> list[str] | None:
    """
    Kayıt dosyasında, BU başlatmaya ait satırlar: son "köprü başladı"
    satırından sona kadar. Dosya bu denemeden önce yazıldıysa None.

    Yalnızca son başlangıçtan sonrası okunur ki önceki bir çalışmanın hataları
    (ya da başarıları) bu kurulumun sonucu sanılmasın.
    """
    try:
        if not os.path.isfile(yol) or os.path.getmtime(yol) < basladi - 2:
            return None
        with open(yol, encoding="utf-8", errors="replace") as f:
            satirlar = f.read().splitlines()
    except Exception:
        return None
    for i in range(len(satirlar) - 1, -1, -1):
        if "köprü başladı" in satirlar[i]:
            return satirlar[i:]
    return None


def baslangic_dogrula(yon: str, azami_sn: float = 30, kamera_sn: float = 45,
                      basladi: float | None = None) -> bool:
    """
    "Görev oluşturuldu" ile "köprü çalışıyor" aynı şey DEĞİL: görev kurulup
    süreç kameraya bağlanamayabilir ve schtasks bunu başarı olarak bildirir.
    Kurulumdan çıkıp gitmiş birine bunu söyleyen hiçbir şey olmazdı.

    Kayıt dosyası uçtan uca kanıt. "Köprü başladı" satırı TEK BAŞINA başarı
    sayılmıyor (eskiden sayılıyordu — hemen ardından duran köprü için de):
    köprü durmamış, kamerayı açmış ve sunucu tarafından reddedilmemiş olmalı.
    Hüküm `durum` komutunun kullandığı aynı üç ölçütle veriliyor; ikisi ayrı
    yazılsaydı kurulum "çalışıyor" derken Durum ekranı "çalışmıyor" diyebilirdi.
    """
    import durum

    yol = gunluk.kayit_yolu(yon)
    if basladi is None:
        basladi = time.time()
    print("  · Köprünün başlaması bekleniyor…", flush=True)

    satirlar = None
    bitis = time.monotonic() + azami_sn
    while satirlar is None and time.monotonic() < bitis:
        time.sleep(0.5)
        satirlar = _son_baslangic(yol, basladi)
    if satirlar is None:
        print("  ✗ Köprü başlamadı ya da kayıt yazamadı.")
        print(f"    Kayıt dosyası: {yol}")
        print("    Bilgisayarı yeniden başlatmayı deneyin; köprü açılışta başlar.")
        return False

    def son_uyarilar() -> None:
        for x in [s for s in satirlar if "[!]" in s][-3:]:
            print(f"    ! {x[:110]}")

    # Kamera açılışı saniyeler sürebilir; sonuç belli olana kadar izlenir.
    bitis = time.monotonic() + kamera_sn
    baglandi_at = None
    while True:
        if durum.durduruldu_mu(satirlar):
            print("  ✗ Köprü başladı ama hemen durdu:")
            son_uyarilar()
            return False
        if durum.kamera_kopuk(satirlar):
            print("  ✗ Köprü çalışıyor ama kameraya bağlanamıyor (denemeye devam ediyor):")
            son_uyarilar()
            print("    Kamera şifresini ve adresini kontrol edip kurulumu tekrarlayın.")
            return False
        ret = durum.sunucu_reddi(satirlar)
        if ret == "kapali":
            # Kimlik doğru; uygulamada tek bir anahtar kapalı. Ne yapılacağı
            # açıkça söylenir — "sunucu kabul etmiyor" demek kişiyi yeni kod
            # aramaya gönderirdi.
            print("  ✗ Köprü çalışıyor ama uygulamada kamera girişi KAPALI.")
            print("    Uygulamada Yönetim → Otopark Ayarları → kamera girişini açın;")
            print("    köprü birkaç dakika içinde kendiliğinden çalışmaya başlar.")
            print("    Kurulumu tekrarlamanız GEREKMEZ.")
            return False
        if ret:
            print("  ✗ Köprü çalışıyor ama sunucu onu kabul etmiyor:")
            son_uyarilar()
            return False
        if baglandi_at is None and any(gunluk.KAMERA_VAR_ISARETI in s for s in satirlar):
            baglandi_at = time.monotonic()
        # Kamera açıldıktan sonra kısa bir süre daha: ilk kalp atışı hemen
        # ardından gider ve sunucunun reddi orada görünür.
        if baglandi_at is not None and time.monotonic() - baglandi_at >= min(2.0, kamera_sn):
            print("  ✓ Köprü çalışıyor: kamera bağlandı.")
            return True
        if time.monotonic() >= bitis:
            break
        time.sleep(0.5)
        satirlar = _son_baslangic(yol, basladi) or satirlar

    print("  ✗ Köprü başladı ama kamera bağlantısı doğrulanamadı.")
    print(f"    Kayıt dosyası: {yol}")
    print("    Birkaç dakika sonra bu programı açıp 'Durum' seçeneğine bakın.")
    return False


def guc_ayarlari() -> None:
    """
    Kurulumları haftalar sonra sessizce öldüren üç ayar. Hiçbiri teknik olmayan
    birinin aklına gelmez, ve dizüstü kapağı bunların en sinsisi: eski bir
    dizüstü öneriliyor ve ilk yapılan şey kapağı kapatmak.
    """
    adimlar = [
        (["powercfg", "/change", "standby-timeout-ac", "0"], "uyku kapatıldı"),
        (["powercfg", "/change", "hibernate-timeout-ac", "0"], "hazırda bekletme kapatıldı"),
        (["powercfg", "/setacvalueindex", "SCHEME_CURRENT",
          "SUB_BUTTONS", "LIDACTION", "0"], "kapak kapatınca uyumayacak"),
        (["powercfg", "/setactive", "SCHEME_CURRENT"], None),
    ]
    for komut, mesaj in adimlar:
        ok, _ = calistir(komut)
        if mesaj:
            print(f"  {'✓' if ok else '✗'} {mesaj}")


# ------------------------------------------------------------------- ana ---

def bagimliliklar_tamam() -> bool:
    """
    Eksik paketi en başta, Türkçe söyle.

    Yoksa kurulum ilerleyip 2. ya da 4. adımda ham bir ModuleNotFoundError ile
    patlıyor — teknik olmayan biri için bu, sihirbazın çözmek için var olduğu
    türden bir duvar. Paketlenmiş .exe'de hepsi gömülü olduğu için bu kontrol
    yalnızca kaynaktan çalıştıranları ilgilendiriyor.
    """
    eksik = []
    for ad in ("cv2", "numpy", "requests"):
        try:
            __import__(ad)
        except ImportError:
            eksik.append(ad)
    if not eksik:
        return True
    print("\n  ! Eksik paketler: " + ", ".join(eksik))
    print("    Şu komutu çalıştırıp tekrar deneyin:")
    print("        pip install -r requirements.txt")
    return False


def main() -> int:
    print("\n  OTOPARK — Kamera köprüsü kurulumu")
    print("  Bu bilgisayar kamerayla aynı ağda olmalı ve internete çıkmalı.")

    if not bagimliliklar_tamam():
        return 1

    if WINDOWS and not yonetici_mi():
        print("\n  ! Yönetici olarak çalıştırın.")
        print("    Dosyaya sağ tıklayıp 'Yönetici olarak çalıştır' deyin —")
        print("    otomatik başlatma ve uyku ayarları bunu gerektiriyor.")
        if not evet_mi("Yine de devam edilsin mi (kurulum yarım kalır)", False):
            return 1

    # Yarıda kalmış ya da yenilenen kurulum: diskteki kimlik hâlâ geçerliyse
    # yeni kod istemeden onunla devam edilir (bkz. mevcut_kimlik_sor).
    ayar = mevcut_kimlik_sor() or sunucu_bilgisi()
    ayar.setdefault("CIHAZ", f"kopru-{ayar['YON'].lower()}")

    # Kimlik ELDE EDİLİR EDİLMEZ yazılıyor, kamera ve kırpma adımlarından
    # ÖNCE. Eşleştirme kodu tek kullanımlıktır ve bu noktada harcanmıştır:
    # sihirbaz RTSP adımında yarıda bırakılırsa, dosya olmadan o kimlik
    # tamamen kaybolurdu ve kurulumu yapan kişi uygulamadan YENİ bir kod
    # istemek zorunda kalırdı. Eksik dosya zararsız — köprü WEBHOOK_URL ya da
    # RTSP_URL yoksa düzgünce çıkıyor ve görev henüz oluşturulmamış oluyor.
    try:
        kimligi_sakla(ayar)
    except Exception as e:
        print(f"  ! Ayarlar şimdilik yazılamadı: {e}")

    if not baglanti_testi(ayar):
        if not evet_mi("Test başarısız. Yine de devam edilsin mi", False):
            return 1

    rtsp, _ = kamera_bilgisi()
    ayar["RTSP_URL"] = rtsp
    ayar.update(kirpma_ve_esikler(rtsp))

    baslik(5, "Kurulum")
    yol = ayari_yaz(ayar)
    print(f"  ✓ Ayarlar yazıldı: {yol}")

    calisiyor = True
    if WINDOWS:
        guc_ayarlari()
        calisiyor = gorev_kur(yol, ayar["YON"])
    else:
        print("  ! Windows değil — systemd birimi için README'ye bakın.")

    if not calisiyor:
        # "Kurulum tamamlandı" DENMEZ: ayarlar yazıldı ama köprünün çalıştığı
        # doğrulanamadı. Bunu okuyup giden biri, bilet açmayan bir otopark
        # bırakmış olurdu.
        print(f"\n{'─' * 64}")
        print("  KURULUM TAMAMLANMADI — köprü çalışmıyor.")
        print(f"{'─' * 64}")
        print("  · Yukarıdaki ✗ satırı sebebi ve ne yapılacağını söylüyor.")
        print("  · Kurulumu tekrarlamanız gerekirse bu programı yeniden çalıştırın:")
        print("    kayıtlı kimlik teklif edilir, YENİ KURULUM KODU GEREKMEZ.")
        print("  · Sonra 'Durum' seçeneğiyle köprünün çalıştığını doğrulayın.")
        print(f"  · Kayıt dosyası: {gunluk.kayit_yolu(ayar['YON'])}")
        return 1

    print(f"\n{'─' * 64}")
    print("  Kurulum tamamlandı.")
    print(f"{'─' * 64}")
    print("  · Uygulamada Yönetim → Otopark Ayarları → 'Kamera girişi' açık olmalı.")
    print("  · Kameranın saatini NTP'ye bağlayın — saati kaymış kamera her aracı")
    print("    sessizce yanlış ücretlendirir.")
    print(f"  · Kayıt dosyası: {gunluk.kayit_yolu(ayar['YON'])}")
    print("  · Çalışıp çalışmadığını görmek için bu programı tekrar açıp")
    print("    'Durum' seçeneğini seçin. İlk gün bir kez bakmakta fayda var.")
    print("  · İkinci bir şerit (giriş/çıkış) kuracaksanız bu programı tekrar")
    print("    çalıştırın — her şerit kendi ayar dosyasını alır.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n  Kurulum iptal edildi.")
        sys.exit(1)
