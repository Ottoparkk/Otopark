# -*- coding: utf-8 -*-
"""
"Çalışıyor mu?" sorusunun tek cevabı.

Kurulumdan sonra köprü görünmez bir SYSTEM süreci olarak koşuyor: pencere yok,
simge yok. Otoparktaki kişinin elinde arızayı anlamanın hiçbir yolu yoktu ve
okumayı kesmiş bir kamera, arabası olmayan bir otoparka benziyor.

Sağlık ölçütü kayıt dosyasının SON YAZMA ZAMANI: köprü beş dakikada bir
"çalışıyor" satırı yazdığı için taze bir dosya, koşan bir süreç demek. Satır
içindeki zaman damgası ayrıştırılmıyor — dosya damgası hem daha güvenilir hem
de biçim değişse bozulmaz.
"""
from __future__ import annotations

import glob
import json
import os
import sys
import time
import urllib.parse

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gunluk  # noqa: E402

AYAR_KLASORU = os.path.join(
    os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark"
)
# Kalp atışı 300 sn. Üç tanesini kaçırmak arızadır; biri ağ dalgalanması.
OLU_ESIGI_SN = 15 * 60


def sure_metni(saniye: float) -> str:
    saniye = int(saniye)
    if saniye < 60:
        return f"{saniye} saniye önce"
    if saniye < 3600:
        return f"{saniye // 60} dakika önce"
    if saniye < 86400:
        return f"{saniye // 3600} saat {(saniye % 3600) // 60} dakika önce"
    return f"{saniye // 86400} gün önce"


def rtsp_gizle(url: str) -> str:
    """Şifre ne ekrana ne kayıt dosyasına düşmeli — süzgeç gunluk'ta ortak."""
    return gunluk.gizle(url)


def kayit_oku(yol: str) -> tuple[list[str], float | None]:
    """
    Etkin dosya ve bir önceki yedek birlikte okunur: kaydırmadan hemen sonra
    etkin dosyada tek satır kalır ve yalnızca ona bakan bir özet, sağlıklı bir
    köprüyü sessiz gösterirdi.
    """
    satirlar: list[str] = []
    damga: float | None = None
    for p in (yol + ".1", yol):
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                satirlar += f.read().splitlines()
            damga = os.path.getmtime(p)
        except Exception:
            pass
    return satirlar, damga


def durduruldu_mu(satirlar: list[str]) -> bool:
    """
    Son işaret "durdu" ise köprü kendi isteğiyle çıkmış demektir (ayar eksik,
    kamera açılamadı, YON geçersiz). Tazelik ölçütü bunu YAKALAYAMIYOR: ölmek
    de kayıt dosyasını tazeler, yani başlar başlamaz ölen bir köprü on beş
    dakika boyunca "ÇALIŞIYOR" görünüyordu.
    """
    for satir in reversed(satirlar):
        if "köprü durdu" in satir:
            return True
        if "köprü başladı" in satir:
            return False
    return False


# Köprünün yazdığı sabit metinler — tek kaynak gunluk.py.
RED_ISARETI = gunluk.RED_ISARETI
KAPALI_ISARETI = gunluk.KAPALI_ISARETI
KABUL_ISARETI = gunluk.KABUL_ISARETI


def sunucu_reddi(satirlar: list[str]) -> str | None:
    """
    Sunucu bu köprüyü reddediyor mu? "kimlik", "kapali" ya da None.

    Tazelik ölçütü bunu YAKALAYAMIYOR: uygulamadan kaldırılan bir kameranın
    köprüsü çalışmaya ve kayıt yazmaya devam eder, yani dosya taze kalır —
    oysa geçen her araç 401 ile reddedilir. SON söz kimdeyse o geçerli: ret
    satırından sonra gelen bir kabul, başarılı bir gönderim ya da yeniden
    başlama, reddin bittiği anlamına gelir.
    """
    for satir in reversed(satirlar):
        if RED_ISARETI in satir:
            return "kimlik"
        if KAPALI_ISARETI in satir:
            return "kapali"
        if gunluk.SERIT_ISARETI in satir:
            return "serit"
        if (KABUL_ISARETI in satir or "[+] gönderildi" in satir
                or "köprü başladı" in satir):
            return None
    return None


def kamera_kopuk(satirlar: list[str]) -> bool:
    """
    Köprü koşuyor ama kameradan görüntü alamıyor mu?

    Kamerası olmayan köprü ölmez: açılışta bekler, çalışırken yeniden bağlanır
    ve her denemede bir satır yazar. Kayıt bu yüzden TAZE kalır ve tazelik
    ölçütü onu sağlıklı gösterirdi. Yine son söz geçerli: "çalışıyor" satırı
    yalnızca kare okunabildiğinde yazılır.
    """
    for satir in reversed(satirlar):
        if gunluk.KAMERA_YOK_ISARETI in satir or gunluk.KARE_YOK_ISARETI in satir:
            return True
        if (gunluk.KAMERA_VAR_ISARETI in satir or "[i] çalışıyor" in satir
                or "[i] araç durdu" in satir):
            return False
        if "köprü başladı" in satir:
            return False
    return False


def ozet(satirlar: list[str]) -> tuple[int, int, str | None]:
    """Bugünün gönderim/red sayısı ve son hata satırı."""
    bugun = time.strftime("%d.%m")
    gonderim = red = 0
    son_hata = None
    for s in satirlar:
        if s.startswith(bugun):
            if "[+] gönderildi" in s:
                gonderim += 1
            elif "[!] reddedildi" in s:
                red += 1
        if "[!]" in s and "hız sınırı" not in s:
            son_hata = s
    return gonderim, red, son_hata


def gorev_var_mi(yon: str) -> bool:
    """
    Yalnızca ÇIKIŞ KODUNA bakılır, çıktıya değil: schtasks çıktısı yerelleştirilmiş
    ("Status" / "Durum") ve makinenin diline göre ayrıştırmak sessizce yanlış
    cevap verirdi. Görevin koşup koşmadığını zaten kayıt dosyası söylüyor.
    """
    if os.name != "nt":
        return False
    import subprocess
    try:
        r = subprocess.run(
            ["schtasks", "/query", "/tn", f"Otopark Kamera Koprusu ({yon})"],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        return r.returncode == 0
    except Exception:
        return False


def serit_durumu(ayar_yolu: str) -> bool:
    """Tek bir şeridi yazdırır. Sağlıklıysa True."""
    try:
        with open(ayar_yolu, encoding="utf-8-sig") as f:
            ayar = json.load(f)
    except Exception as e:
        print(f"  ✗ Ayar dosyası okunamadı: {ayar_yolu}\n    {e}")
        return False

    yon = str(ayar.get("YON", "?")).upper()
    print(f"\n  ── {yon} şeridi " + "─" * (46 - len(yon)))
    print(f"     Ayar dosyası : {ayar_yolu}")
    print(f"     Kamera       : {rtsp_gizle(ayar.get('RTSP_URL', ''))}")
    print(f"     Kırpma       : {ayar.get('KIRPMA') or '(yok — tüm kare)'}")

    # Görev yoksa köprü BU AÇILIŞTA koşuyor olabilir ama bilgisayar yeniden
    # başlayınca bir daha dönmez — sağlıklı sayılamaz. Yalnızca Windows'ta
    # ölçülebiliyor; başka yerde systemd belgeleniyor ve hüküm verilmiyor.
    gorev = gorev_var_mi(yon) if os.name == "nt" else True
    print(f"     Otomatik başlatma: {'kurulu' if gorev else 'KURULU DEĞİL'}")

    yol = gunluk.kayit_yolu(yon)
    satirlar, damga = kayit_oku(yol)
    if damga is None:
        print(f"     Kayıt dosyası: YOK ({yol})")
        print("     Durum        : ÇALIŞMIYOR — köprü hiç başlamamış görünüyor.")
        return False

    yas = time.time() - damga
    taze = yas < OLU_ESIGI_SN
    durdu = durduruldu_mu(satirlar)
    ret = sunucu_reddi(satirlar)
    kamera_yok = kamera_kopuk(satirlar)
    saglikli = taze and not durdu and gorev and ret is None and not kamera_yok

    print(f"     Kayıt dosyası: {yol}")
    print(f"     Son hareket  : {sure_metni(yas)}")
    if durdu:
        hal = "DURMUŞ — köprü kapandı, son satırlara bakın."
    elif not taze:
        hal = "DURMUŞ — beş dakikadır yazması gerekiyordu."
    elif kamera_yok:
        hal = ("KAMERA YOK — köprü çalışıyor ama kameradan görüntü alamıyor. "
               "Kameranın fişini, ağ kablosunu ve şifresini kontrol edin.")
    elif ret == "kimlik":
        hal = ("KİMLİK REDDEDİLDİ — sunucu bu kamerayı tanımıyor. Uygulamada "
               "Kamera Kurulumu'ndan yeni kod alıp kurulumu tekrarlayın.")
    elif ret == "serit":
        hal = ("ŞERİT UYUŞMUYOR — bu kamera uygulamada öbür şeride eşleştirilmiş; "
               "araçlar reddediliyor. Uygulamadan kamerayı kaldırıp doğru "
               "şeritle yeni kod alın ve kurulumu tekrarlayın.")
    elif ret == "kapali":
        hal = ("KAMERA GİRİŞİ KAPALI — uygulamada Otopark Ayarları'ndan "
               "kamera girişini açın.")
    elif not gorev:
        hal = "ŞİMDİLİK ÇALIŞIYOR — ama açılışta başlamaz, kurulumu tekrarlayın."
    else:
        hal = "ÇALIŞIYOR"
    print(f"     Durum        : {hal}")

    gonderim, red, son_hata = ozet(satirlar)
    print(f"     Bugün        : {gonderim} gönderim, {red} reddedilme")
    if son_hata:
        print(f"     Son uyarı    : {son_hata[:110]}")
    print("     Son satırlar :")
    for s in satirlar[-6:]:
        print(f"       {s[:104]}")
    return saglikli


def main() -> int:
    print("\n  OTOPARK — Kamera köprüsü durumu")
    ayarlar = sorted(glob.glob(os.path.join(AYAR_KLASORU, "kopru-*.json")))
    if not ayarlar:
        print(f"\n  Hiç kurulum bulunamadı ({AYAR_KLASORU}).")
        print("  Kurulum için bu programı normal şekilde çalıştırın.")
        return 1

    hepsi = [serit_durumu(y) for y in ayarlar]
    print()
    if all(hepsi):
        print("  ✓ Her şey yolunda.")
        return 0
    print("  ✗ En az bir şerit çalışmıyor. Yapılacaklar:")
    print("    1) Bu bilgisayarı yeniden başlatın — köprü açılışta kendiliğinden başlar.")
    print("    2) Düzelmezse kurulumu yeniden çalıştırın.")
    print("    3) Kamera ve internet kablolarını kontrol edin.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
