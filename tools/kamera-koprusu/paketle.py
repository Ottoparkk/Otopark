# -*- coding: utf-8 -*-
"""
Dağıtılabilir paketi üretir: indirilip çift tıklanan bir .exe.

    python paketle.py

Bu betik GELİŞTİRİCİ tarafında çalışır, otoparktaki bilgisayarda değil. Amacı
kurulumun önündeki en büyük engeli kaldırmak: Python kurmak, `pip install`
çalıştırmak ve bir terminal açmak. Bunların üçü de teknik olmayan biri için
durdurucu ve üçü de paketleyerek ortadan kalkıyor.

    yapi/      ara dosyalar (sürüm bilgisi, PyInstaller çalışma klasörü)
    dagitim/   sonuç: OtoparkKamera-<sürüm>.zip

Neden --onedir:
  * --onefile her açılışta ~120 MB'ı geçici klasöre açıyor; köprü bir servis
    olarak sürekli yeniden başlıyor ve bu her seferinde saniyeler demek.
  * Kendini geçici klasöre açan tek dosyalı .exe, virüs tarayıcılarının
    en çok yanlış pozitif verdiği kalıp.

UPX bilerek KAPALI (`--noupx`): sıkıştırılmış bölüm, tarayıcılar için ikinci
bir şüphe sebebi ve kazanç birkaç on MB.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import zipfile
from datetime import date

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
YAPI = os.path.join(BURASI, "yapi")
DAGITIM = os.path.join(BURASI, "dagitim")
AD = "OtoparkKamera"
SURUM = "1.0.0"

# Kendi modüllerimiz. PyInstaller fonksiyon içi `import`ları da tarıyor ama
# bunlar geç içe aktarma zinciriyle bağlı (giris -> kurulum -> kirpma_sunucu
# -> kopru) ve zincirin bir halkası kaçarsa sonuç ancak SAHADA, kurulumun
# ortasında patlayan bir .exe olur. Açıkça saymak ucuz sigorta.
MODULLER = ["kopru", "kurulum", "durum", "kaldir", "kesif", "kirpma_sunucu", "gunluk"]

# Paketi küçültür ve ilgisiz bağımlılıkların içeri sızmasını engeller.
HARIC = ["tkinter", "matplotlib", "scipy", "pandas", "PyQt5", "PyQt6",
         "PySide2", "PySide6", "IPython", "pytest", "setuptools", "pip"]


def yaz(m: str = "") -> None:
    print(m, flush=True)


def surum_dosyasi() -> str:
    """
    Windows sürüm kaynağı. Ne SmartScreen'i ne de imzayı yerine koyar, ama
    özelliklerinde adı ve yayıncısı yazan bir dosya, tamamen boş olandan daha
    az şüpheli görünür.
    """
    yol = os.path.join(YAPI, "surum.txt")
    s = SURUM.split(".") + ["0"]
    dort = ", ".join(s[:4])
    icerik = f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers=({dort}), prodvers=({dort}),
    mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0),
  kids=[
    StringFileInfo([StringTable('041F04B0', [
      StringStruct('CompanyName', 'Otopark'),
      StringStruct('FileDescription', 'Otopark kamera koprusu kurulumu'),
      StringStruct('FileVersion', '{SURUM}'),
      StringStruct('InternalName', '{AD}'),
      StringStruct('OriginalFilename', '{AD}.exe'),
      StringStruct('ProductName', 'Otopark Kamera Koprusu'),
      StringStruct('ProductVersion', '{SURUM}')])]),
    VarFileInfo([VarStruct('Translation', [1055, 1200])])
  ]
)
"""
    with open(yol, "w", encoding="utf-8") as f:
        f.write(icerik)
    return yol


def simge() -> str | None:
    """PyInstaller PNG'yi Pillow varsa kendisi .ico'ya çevirir; yoksa simgesiz."""
    png = os.path.abspath(os.path.join(BURASI, "..", "..", "public", "icons", "icon-512.png"))
    if not os.path.isfile(png):
        return None
    try:
        import PIL  # noqa: F401
    except ImportError:
        yaz("  · Pillow yok — .exe simgesiz olacak (işlevsel fark yok).")
        return None
    return png


def derle() -> str:
    os.makedirs(YAPI, exist_ok=True)
    komut = [
        sys.executable, "-m", "PyInstaller",
        os.path.join(BURASI, "giris.py"),
        "--name", AD,
        "--onedir", "--console", "--noupx", "--clean", "--noconfirm",
        "--distpath", os.path.join(YAPI, "dist"),
        "--workpath", os.path.join(YAPI, "work"),
        "--specpath", YAPI,
        "--paths", BURASI,
        "--version-file", surum_dosyasi(),
    ]
    if os.name == "nt":
        # Kurulum görev oluşturuyor, uyku ayarlarını değiştiriyor ve
        # ProgramData'ya yazıyor — hepsi yönetici gerektiriyor. Manifest ile
        # UAC kendiliğinden çıkıyor; "sağ tıklayıp yönetici olarak çalıştırın"
        # adımı, atlanınca kurulumun yarısını sessizce başarısız yapıyordu.
        komut.append("--uac-admin")
    for m in MODULLER:
        komut += ["--hidden-import", m]
    for m in HARIC:
        komut += ["--exclude-module", m]
    ikon = simge()
    if ikon:
        komut += ["--icon", ikon]

    yaz("  PyInstaller çalışıyor (birkaç dakika sürebilir)…")
    r = subprocess.run(komut)
    if r.returncode:
        sys.exit("  ✗ Derleme başarısız.")
    return os.path.join(YAPI, "dist", AD)


def oku_beni(klasor: str) -> None:
    kaynak = os.path.join(BURASI, "OKU-BENI.txt")
    if os.path.isfile(kaynak):
        shutil.copy2(kaynak, os.path.join(klasor, "OKU-BENI.txt"))


def zipleyip_ozetle(klasor: str) -> str:
    os.makedirs(DAGITIM, exist_ok=True)
    hedef = os.path.join(DAGITIM, f"{AD}-{SURUM}-{date.today():%Y%m%d}.zip")
    if os.path.exists(hedef):
        os.remove(hedef)
    yaz("  Paketleniyor…")
    with zipfile.ZipFile(hedef, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for kok, _, dosyalar in os.walk(klasor):
            for d in dosyalar:
                tam = os.path.join(kok, d)
                # Zip içinde her şey tek bir klasörün altında dursun: doğrudan
                # Masaüstü'ne açılırsa 300 dosya oraya saçılırdı.
                z.write(tam, os.path.join(AD, os.path.relpath(tam, klasor)))
    return hedef


def main() -> int:
    try:
        import PyInstaller  # noqa: F401
    except ImportError:
        yaz("\n  PyInstaller kurulu değil. Derlemek için:")
        yaz("      pip install pyinstaller")
        yaz("\n  (Yalnızca paketi ÜRETEN bilgisayarda gerekli;")
        yaz("   otoparktaki bilgisayarda hiçbir şey kurulmuyor.)")
        return 1

    yaz(f"\n  OTOPARK — kamera köprüsü paketleniyor  (sürüm {SURUM})\n")
    klasor = derle()
    oku_beni(klasor)
    zip_yolu = zipleyip_ozetle(klasor)

    with open(zip_yolu, "rb") as f:
        ozet = hashlib.sha256(f.read()).hexdigest()
    mb = os.path.getsize(zip_yolu) / 1024 / 1024

    yaz(f"\n  ✓ Hazır: {zip_yolu}")
    yaz(f"    Boyut  : {mb:.0f} MB")
    yaz(f"    SHA-256: {ozet}")
    yaz("\n  Dağıtırken bu özeti de verin: indirilen dosyanın yolda")
    yaz("  değişmediğini doğrulamanın tek yolu.")
    yaz("      Get-FileHash .\\" + os.path.basename(zip_yolu) + " -Algorithm SHA256")
    return 0


if __name__ == "__main__":
    sys.exit(main())
