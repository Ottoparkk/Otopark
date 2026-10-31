# -*- coding: utf-8 -*-
"""
Paketlenmiş .exe'nin tek giriş noktası.

Tek dosya, çünkü opencv ~120 MB: iki ayrı .exe iki kopya ya da PyInstaller'ın
kırılgan MERGE'ü demekti. Kip ilk argümandan seçiliyor.

    OtoparkKamera.exe                  → kurulum (kuruluysa menü)
    OtoparkKamera.exe --kopru --ayar X → köprünün kendisi (Görev Zamanlayıcı)
    OtoparkKamera.exe --durum          → çalışıyor mu
    OtoparkKamera.exe --kaldir         → kaldır

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


# Geç içe aktarma bilerek: `--durum` cv2'ye hiç dokunmasın ve paketlenmemiş
# kurulumda opencv olmadan da çalışabilsin.
KIPLER = {"--durum": _durum, "--kaldir": _kaldir, "--kurulum": _kurulum}


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
        print("  Kullanım: --durum | --kaldir | --kurulum | --kopru --ayar <dosya>")
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
