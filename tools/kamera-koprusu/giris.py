# -*- coding: utf-8 -*-
"""
Paketlenmiş .exe'nin tek giriş noktası.

Tek dosya, çünkü opencv ~120 MB: iki ayrı .exe iki kopya ya da PyInstaller'ın
kırılgan MERGE'ü demekti. Kip ilk argümandan seçiliyor.

    OtoparkKamera.exe                  → kurulum (kuruluysa menü)
    OtoparkKamera.exe --kopru --ayar X → köprünün kendisi (Görev Zamanlayıcı)
    OtoparkKamera.exe --durum          → çalışıyor mu
    OtoparkKamera.exe --kaldir         → kaldır
    OtoparkKamera.exe --plaka [dakika] → plaka okumayı ve araç bulucuyu canlı göster (1-60, varsayılan 2)
    OtoparkKamera.exe --plaka-sina     → plaka okuyucu ve araç bulucu yükleniyor mu (öz sınama)
    OtoparkKamera.exe --video <dosya>  → bir kaydı gerçek köprüden geçir, hiçbir şey gönderme

Çift tıklayan kişi hiçbir argüman bilmek zorunda değil: ilk kurulumda doğrudan
sihirbaz açılır, sonrasında menü çıkar.
"""
from __future__ import annotations

import glob
import os
import sys

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

DONMUS = getattr(sys, "frozen", False)

# 1.4.2 (E12): komutun yazıldığı klasör — aşağıdaki chdir'den ÖNCE. `--video
# kayit.mp4` gibi göreli bir yol buna göre çözülür, .exe'nin klasörüne değil.
try:
    BASLANGIC_KLASORU = os.getcwd()
except OSError:
    BASLANGIC_KLASORU = ""

if DONMUS:
    # UAC ile yükseltilen bir süreç System32'de başlayabiliyor. `--kare`
    # kipinin kaydettiği kare.jpg oraya düşerdi ve kimse bulamazdı.
    try:
        os.chdir(os.path.dirname(sys.executable))
    except Exception:
        pass
else:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _ayar_klasoru() -> str:
    return os.path.join(
        os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark"
    )


def bekle() -> None:
    """
    Çift tıklanan pencere iş bitince kapanır ve okunacak şey ekranda kalmaz —
    hata mesajı da dâhil. Görev Zamanlayıcı'nın başlattığı köprüde (`--kopru`)
    ASLA çağrılmaz — çökme yolu dâhil (1.2.4): orada Enter'a basacak kimse
    yok ve beklemek süreci sonsuza dek "çalışıyor" bırakırdı.
    """
    try:
        input("\n  Kapatmak için Enter'a basın… ")
    except Exception:
        pass


def menu() -> str:
    print("\n  OTOPARK — Kamera köprüsü")
    print("  Bu bilgisayarda kurulu bir köprü var.\n")
    print("    1) Durum — çalışıyor mu?")
    print("    2) Yeniden kur / ayarları değiştir")
    print("    3) Kaldır")
    print("    0) Çıkış")
    try:
        c = input("\n  Seçiminiz [1]: ").strip() or "1"
    except Exception:
        return "--durum"
    return {"1": "--durum", "2": "--kurulum", "3": "--kaldir"}.get(c, "--cik")


def _durum() -> int:
    import durum
    return durum.main()


def _kaldir() -> int:
    import kaldir
    return kaldir.main()


def _kurulum() -> int:
    import kurulum
    return kurulum.main()


PLAKA_DAKIKA_VARSAYILAN = 2
PLAKA_DAKIKA_EN_COK = 60


def _plaka_dakikasi(args: list[str]) -> int | None:
    """
    1.4.2 (E11): `--plaka [dakika]`. Verilmezse 2; 1-60 arası tam sayı.
    Geçersizse None (çağıran ne yazılacağını söyler).
    """
    if not args:
        return PLAKA_DAKIKA_VARSAYILAN
    d = args[0].strip()
    if not d.isdigit():
        return None
    n = int(d)
    return n if 1 <= n <= PLAKA_DAKIKA_EN_COK else None


def _plaka() -> int:
    """
    Kurulu her şeridin kamerasında plaka bulma ve okumayı sırayla gösterir
    (yönetici olarak açılmalı: ayar dosyası yalnızca yöneticilere açık).
    Hiçbir şey göndermez ve kaydetmez — köprü çalışırken de güvenle koşar.
    1.4.2: `--plaka 10` → her şerit 10 dakika (1-60; verilmezse 2).
    """
    dakika = _plaka_dakikasi(sys.argv[2:])
    if dakika is None:
        print(f"\n  Süre 1-{PLAKA_DAKIKA_EN_COK} dakika olmalı: --plaka 10")
        return 2
    ayarlar = sorted(glob.glob(os.path.join(_ayar_klasoru(), "kopru-*.json")))
    if not ayarlar:
        print("\n  Kurulu bir köprü bulunamadı — önce kurulumu çalıştırın.")
        return 1
    import kopru
    kod = 0
    for yol in ayarlar:
        print(f"\n  ── {os.path.basename(yol)} ──")
        kod = kopru.plaka_testi(yol, sure_sn=dakika * 60.0) or kod
    return kod


def _video() -> int:
    """
    1.4.2 (E12): `--video <dosya> [GIRIS|CIKIS|ORTAK]` — bir kamera kaydını
    gerçek köprü döngüsünden geçirir, hiçbir şey göndermez (video.py). Tek
    şerit kuruluysa o; birden çoksa şerit yazılmalı. Ayar dosyası kopru İÇE
    AKTARILMADAN önce ortama yazılır: kopru ayarlarını içe aktarılırken okur.
    """
    args = sys.argv[2:]
    if not args:
        print("\n  Kullanım: --video <dosya> [GIRIS|CIKIS|ORTAK]")
        return 2
    dosya = os.path.join(BASLANGIC_KLASORU, args[0]) if BASLANGIC_KLASORU else args[0]
    if not os.path.isfile(dosya):
        print(f"\n  Video dosyası bulunamadı: {dosya}")
        return 2
    ayarlar = sorted(glob.glob(os.path.join(_ayar_klasoru(), "kopru-*.json")))
    if not ayarlar:
        print("\n  Kurulu bir köprü bulunamadı — önce kurulumu çalıştırın.")
        return 1
    kurulu = {os.path.basename(y)[len("kopru-"):-len(".json")].upper(): y for y in ayarlar}
    if len(args) > 1:
        serit = args[1].strip().upper()
        if serit not in kurulu:
            print(f"\n  {serit} şeridi kurulu değil. Kurulu: {', '.join(sorted(kurulu))}")
            return 2
        yol = kurulu[serit]
    elif len(kurulu) == 1:
        yol = next(iter(kurulu.values()))
    else:
        print(f"\n  Birden çok şerit kurulu — hangisi? --video <dosya> "
              f"{'|'.join(sorted(kurulu))}")
        return 2
    os.environ["OTOPARK_AYAR"] = yol
    # Oynatma GPU için köprüyü yeniden başlatmasın (gerçek dosyaya yazardı).
    os.environ["GPU_YENIDEN_BASLAT_SN"] = "1000000000"
    import video
    return video.oynat(dosya).kod


def _plaka_sina() -> int:
    """
    Modelleri doğrular, yükler ve öz sınamayı çalıştırır — kamera, ağ ya da
    kurulum gerekmez. paketle derlenmiş .exe'yi bununla sınar; sahada da
    "plaka okuyucu çalışıyor mu" sorusunun en kısa cevabıdır.
    """
    import arac
    import plaka
    ayar, uyarilar = plaka.calisma_ayarlari()
    for u in uyarilar:
        print(f"  ! {u}")
    try:
        plaka.yukle(ayar)
    except plaka.PlakaHatasi as e:
        print(f"\n  ✗ Plaka okuyucu çalışmıyor: {e}")
        return 1
    print("\n  ✓ Plaka okuyucu hazır (modeller doğrulandı, öz sınama geçti).")
    # 1.3.1: paketteki araç modeli de sınanır (eksik DLL / model derlemede görülsün).
    try:
        arac.yukle(ayar)
    except plaka.PlakaHatasi as e:
        print(f"  ✗ Araç bulucu çalışmıyor: {e}")
        return 1
    print("  ✓ Araç bulucu hazır (model doğrulandı, öz sınama geçti).")
    return _gpu_sina(ayar)


def _gpu_sina(ayar: dict) -> int:
    """
    1.4.2: grafik işlemcisi kümesi — okuyucu ve İKİ araç modeli (tiny, YOLO11s)
    GPU'da öz sınamadan geçmeli. GPU YOKSA geçer (köprü işlemcide çalışır) ama
    söylenir; GPU varken bir model tutmazsa 1 (paketteki OpenVINO bozuk olabilir).
    """
    import arac
    import hizlandirici
    import plaka
    try:
        hiz = hizlandirici.Hizlandirici.ac()
    except plaka.HizlandiriciHatasi as e:
        print(f"  ! Grafik işlemcisi kullanılamıyor: {e} — köprü işlemcide çalışır.")
        return 0
    try:
        plaka.yukle(ayar, hiz=hiz)
    except plaka.PlakaHatasi as e:
        print(f"  ✗ Grafik işlemcisinde plaka okuyucu çalışmıyor: {e}")
        return 1
    for p in (arac.YOLOX_TINY, arac.YOLO11S):
        try:
            arac.yukle(ayar, profil=p, hiz=hiz)
        except plaka.PlakaHatasi as e:
            print(f"  ✗ Grafik işlemcisinde {p.ad} çalışmıyor: {e}")
            return 1
    print("  ✓ Grafik işlemcisi hazır (plaka okuyucu, YOLOX-tiny ve YOLO11s öz sınamayı geçti).")
    return 0


# Geç içe aktarma bilerek: `--durum` cv2'ye hiç dokunmasın ve paketlenmemiş
# kurulumda opencv olmadan da çalışabilsin.
KIPLER = {"--durum": _durum, "--kaldir": _kaldir, "--kurulum": _kurulum,
          "--plaka": _plaka, "--plaka-sina": _plaka_sina, "--video": _video}


def main() -> int:
    kip = sys.argv[1] if len(sys.argv) > 1 else ""

    if kip == "--kopru":
        # kopru.py sys.argv'yi KENDİSİ okuyor (--ayar, --kare, --test) ve bunu
        # içe aktarılırken yapıyor: ayarlar modül düzeyinde yükleniyor. Bu
        # yüzden argv içe aktarmadan ÖNCE düzeltilmek zorunda.
        del sys.argv[1]
        import kopru
        kopru.cli()
        return 0

    if not kip:
        kurulu = glob.glob(os.path.join(_ayar_klasoru(), "kopru-*.json"))
        kip = menu() if kurulu else "--kurulum"

    if kip == "--cik":
        return 0

    if kip not in KIPLER:
        # Duraklamadan ÖNCE yazılmalı: ters sırada mesaj "Enter'a basın"ın
        # altında kalır ve kullanıcı neyi yanlış yazdığını göremez.
        print(f"\n  Bilinmeyen seçenek: {kip}")
        print("  Kullanım: --durum | --kaldir | --kurulum | --plaka [dakika] | --plaka-sina | "
              "--video <dosya> [şerit] | "
              "--kopru --ayar <dosya>")
        if DONMUS:
            bekle()
        return 2

    try:
        return KIPLER[kip]()
    finally:
        if DONMUS:
            bekle()


if __name__ == "__main__":
    # Read BEFORE main(): the --kopru branch deletes argv[1] before importing
    # kopru, so afterwards nothing says which mode crashed.
    KOPRU_KIPI = len(sys.argv) > 1 and sys.argv[1] == "--kopru"
    try:
        kod = main()
    except KeyboardInterrupt:
        print("\n  İptal edildi.")
        kod = 1
    except Exception:
        # Çift tıklanan bir pencerede işlenmemiş hata, pencere kapandığı için
        # "hiçbir şey olmadı" gibi görünür. Önce yazdır, sonra beklet.
        import traceback
        print("\n  ! Beklenmeyen bir hata oluştu:\n")
        traceback.print_exc()
        if KOPRU_KIPI:
            # The bridge itself (Task Scheduler, SYSTEM): nobody is there to
            # press Enter. Waiting here kept a crashed bridge "running" forever
            # — IgnoreNew then blocked a fresh copy and the lane stayed blind
            # until a reboot. Exit instead; the task starts it again within a
            # minute (1.2.4). The traceback above is already in the log.
            print("\n  Köprü durdu; Görev Zamanlayıcı yeniden başlatacak.")
        else:
            print("\n  Bu ekranın fotoğrafını çekip iletin.")
            if DONMUS:
                bekle()
        kod = 1
    sys.exit(kod)
