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
import importlib.metadata as md
import os
import re
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
SURUM = "1.3.1"   # 1.3.1: araç bulucu (YOLOX-tiny, Apache-2.0) her karede: duran
                  #        yaya kayıt açmaz; durmadan geçen plakasız araç personele
                  # 1.3.0: plaka bu bilgisayarda okunur (YOLOv9 + fast-plate-ocr, ONNX);
                  #        kameranın SMD olayları ve sunucuda okuma yok; L biçimli alan
                  #        (KIRPMA_HARIC); internet yokken araçlar diskte bekler (giden.py)
                  # 1.1.0: tek kapı (ORTAK şeridi) · 1.2.0: boş şeridi kendi öğrenir · 1.2.3: sıkıştırılmış plaka fotoğrafı · 1.2.5: durmadan geçen araç
                  # 1.2.6: yalnızca kameranın araç olayı olan geçiş gönderilir (olay.py),
                  #        olaylar yoksa 1.2.5 gibi; desenli zeminde tam araç karesi
                  # 1.2.1: kurulum günü düzeltmeleri (şifre kilidi, saat, gece eşiği,
                  #        kalp atışı, kayıt döndürme, program klasörü, son deneme başlığı)
                  # 1.2.4: kendini toparlama (çökmede beklemez, dakikada bir yeniden
                  #        başlatma, bekçi, durum ekranında İNTERNET YOK)
                  # 1.2.2: kamera hesabını kilitlememek (şifre reddinde köprü bekler,
                  #        yeniden kurulum eski köprüyü durdurur, şifre akış yolunda
                  #        sınanır, kamera her ağdan aranır; kırpma sayfası
                  #        reddettiği isteğin gövdesini okur)

# Kendi modüllerimiz. PyInstaller fonksiyon içi `import`ları da tarıyor ama
# bunlar geç içe aktarma zinciriyle bağlı (giris -> kurulum -> kirpma_sunucu
# -> kopru) ve zincirin bir halkası kaçarsa sonuç ancak SAHADA, kurulumun
# ortasında patlayan bir .exe olur. Açıkça saymak ucuz sigorta.
MODULLER = ["kopru", "kurulum", "durum", "kaldir", "kesif", "kirpma_sunucu", "gunluk",
            "plaka", "okuma", "giden", "arac"]

# Paketi küçültür ve ilgisiz bağımlılıkların içeri sızmasını engeller.
HARIC = ["tkinter", "matplotlib", "scipy", "pandas", "PyQt5", "PyQt6",
         "PySide2", "PySide6", "IPython", "pytest", "setuptools", "pip"]

GEREKSINIM = os.path.join(BURASI, "requirements.txt")
MODEL_KLASORU = os.path.join(BURASI, "modeller")
# 1.3.0: pakete giren model klasörü dosyaları — açık liste (klasördeki
# .gitattributes ve ileride bırakılabilecek başka bir şey pakete girmesin).
MODEL_DOSYALARI = ["yolo-v9-t-640-license-plates-end2end.onnx", "cct_s_v2_global.onnx",
                   "cct_s_v2_global_plate_config.yaml", "LISANS.txt",
                   # 1.3.1: araç bulucu ve öz sınama resmi
                   "yolox_tiny.onnx", "arac_sinama.jpg"]

# Lisans dosyası sayılan adlar (dist-info içinde).
_LISANS_ADI = re.compile(r"(LICEN[CS]E|COPYING|NOTICE)", re.I)
# Paket klasörünün KENDİSİNDE (dist-info dışında) duran bildirimler.
EK_BILDIRIMLER = {"onnxruntime": ["LICENSE", "ThirdPartyNotices.txt", "Privacy.md"]}
# Tekerleği lisans METNİ taşımayan paket → aynı lisansın tam metnini taşıyan
# başka bir paket (derlemede doğrulanır: "Apache License / Version 2.0").
METINSIZ = {"flatbuffers": ("Apache-2.0", "requests", "LICENSE")}


def yaz(m: str = "") -> None:
    print(m, flush=True)


# ------------------------------------------------------------ ön kontrol ---

def sabitlenenler(yol: str = GEREKSINIM) -> dict[str, str | None]:
    """requirements.txt → {ad: sürüm}; `==` ile sabitlenmemiş satırın sürümü None."""
    pins: dict[str, str | None] = {}
    with open(yol, encoding="utf-8") as f:
        for satir in f:
            satir = satir.split("#", 1)[0].strip()
            if not satir:
                continue
            m = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([A-Za-z0-9.+!-]+)", satir)
            if m:
                pins[m.group(1).lower()] = m.group(2)
            else:
                pins[satir] = None
    return pins


def surum_sorunlari(yol: str = GEREKSINIM) -> list[str]:
    """
    Sabitlenen her sürüm, DERLEYEN Python'da kurulu olanla aynı mı? Başka
    sürümle derlenmiş bir .exe sınanmamış bir okuyucu demektir (plaka.py'nin
    altın çıktısı onnxruntime 1.31.0 ile ölçüldü).
    """
    sorunlar = []
    for ad, surum in sabitlenenler(yol).items():
        if surum is None:
            sorunlar.append(f"{ad}: sürüm sabitlenmemiş (ad==sürüm yazın)")
            continue
        try:
            kurulu = md.version(ad)
        except md.PackageNotFoundError:
            sorunlar.append(f"{ad}=={surum} bu Python'da kurulu değil")
            continue
        if kurulu != surum:
            sorunlar.append(f"{ad}: requirements.txt {surum}, kurulu {kurulu}")
    return sorunlar


def model_sorunlari(dizin: str = MODEL_KLASORU) -> list[str]:
    """Modeller yerinde ve özetleri plaka.py / arac.py'deki sabitlerle aynı mı?"""
    import arac
    import plaka
    sorunlar = []
    for m in (plaka.BULUCU, plaka.OKUYUCU, arac.MODEL, arac.SINAMA):
        yol = os.path.join(dizin, m.dosya)
        if not os.path.isfile(yol):
            sorunlar.append(f"model yok: {m.dosya}")
        elif plaka.sha256_dosya(yol) != m.sha256:
            sorunlar.append(f"model özeti kodla (plaka.py / arac.py) tutmuyor: {m.dosya}")
    return sorunlar


# --------------------------------------------------------------- lisanslar ---

def _normal(ad: str) -> str:
    return re.sub(r"[-_.]+", "-", ad).lower()


def calisma_paketleri(kokler) -> list:
    """
    Kökler ve çalışma bağımlılıkları (DERLEYEN Python'dan): pakete girenler.
    `extra` bağımlılıkları alınmaz; ortam işaretli olanlar yalnızca kuruluysa.
    """
    bulunan: dict = {}
    yigin = list(kokler)
    while yigin:
        ad = yigin.pop()
        if _normal(ad) in bulunan:
            continue
        try:
            dist = md.distribution(ad)
        except md.PackageNotFoundError:
            sys.exit(f"  ✗ {ad} kurulu değil — lisansı toplanamadı")
        bulunan[_normal(ad)] = dist
        for gereken in dist.requires or []:
            if re.search(r"extra\s*==", gereken):
                continue
            alt = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", gereken).group(1)
            if ";" in gereken:
                try:
                    md.distribution(alt)
                except md.PackageNotFoundError:
                    continue
            yigin.append(alt)
    return sorted(bulunan.values(), key=lambda d: _normal(d.metadata["Name"]))


def _lisans_adi(dist) -> str:
    m = dist.metadata
    if m.get("License-Expression"):
        return m["License-Expression"]
    siniflar = [c.split("::")[-1].strip() for c in (m.get_all("Classifier") or [])
                if c.startswith("License ::")]
    if siniflar:
        return ", ".join(siniflar)
    ilk = (m.get("License") or "").strip().splitlines()
    return ilk[0] if ilk and len(ilk[0]) <= 60 else "metne bakın"


def _kopyala(kaynak: str, hedef: str, ust: str = "") -> None:
    with open(kaynak, "rb") as a:
        veri = a.read()
    with open(hedef, "wb") as b:
        b.write(ust.encode("utf-8"))
        b.write(veri)


def lisanslari_topla(hedef: str, kokler) -> str:
    """
    Pakete giren her üçüncü taraf paketin lisans metni, DERLEME ANINDA kurulu
    sürümden `<hedef>/lisanslar/` klasörüne; dizin LISANSLAR.txt. Elle
    kopyalanmış metin sürüm değişince ayrışırdı. Lisans metni bulunamayan paket
    derlemeyi durdurur: lisanssız dağıtılmaz. Modellerin lisansı (modeller/
    LISANS.txt) ve Python'un kendi lisansı da eklenir.
    """
    klasor = os.path.join(hedef, "lisanslar")
    os.makedirs(klasor, exist_ok=True)
    dagitimlar = calisma_paketleri(kokler)
    satirlar = ["Otopark kamera köprüsü — üçüncü taraf lisansları",
                f"(paketle.py {SURUM} derlemesinde, kurulu sürümlerden toplandı)", ""]
    for dist in dagitimlar:
        ad = dist.metadata["Name"]
        dosyalar: list[str] = []
        ekler = EK_BILDIRIMLER.get(_normal(ad), [])
        for f in dist.files or []:
            parcalar = str(f).replace("\\", "/").split("/")
            dist_info = parcalar[0].endswith(".dist-info") and _LISANS_ADI.search(parcalar[-1])
            ek = len(parcalar) == 2 and parcalar[1] in ekler
            if dist_info or ek:
                ad_hedef = f"{ad}-" + "_".join(parcalar[1:])
                _kopyala(str(dist.locate_file(f)), os.path.join(klasor, ad_hedef))
                dosyalar.append(ad_hedef)
        if not dosyalar and _normal(ad) in METINSIZ:
            lisans, veren, veren_dosya = METINSIZ[_normal(ad)]
            vd = md.distribution(veren)
            yol = next((vd.locate_file(f) for f in vd.files or []
                        if str(f).split("/")[0].endswith(".dist-info")
                        and str(f).endswith("/" + veren_dosya)), None)
            metin = open(yol, encoding="utf-8").read() if yol else ""
            if "Apache License" not in metin or "Version 2.0" not in metin:
                sys.exit(f"  ✗ {ad}: {lisans} metni {veren} paketinden alınamadı")
            ad_hedef = f"{ad}-LICENSE.txt"
            _kopyala(str(yol), os.path.join(klasor, ad_hedef),
                     ust=f"{ad} {dist.version}: tekerleği lisans metni taşımıyor; lisansı "
                         f"{lisans} (paket bilgisi: {_lisans_adi(dist)}). Tam metin:\n\n")
            dosyalar.append(ad_hedef)
        if not dosyalar:
            sys.exit(f"  ✗ {ad} {dist.version}: lisans metni bulunamadı — lisanssız dağıtılmaz")
        satirlar.append(f"{ad} {dist.version}  —  {_lisans_adi(dist)}")
        satirlar += [f"    {x}" for x in dosyalar]
    py = os.path.join(sys.base_prefix, "LICENSE.txt")
    if os.path.isfile(py):
        _kopyala(py, os.path.join(klasor, "Python-LICENSE.txt"))
        satirlar.append(f"Python {sys.version.split()[0]}  —  PSF License")
        satirlar.append("    Python-LICENSE.txt")
    _kopyala(os.path.join(MODEL_KLASORU, "LISANS.txt"), os.path.join(klasor, "modeller-LISANS.txt"))
    satirlar.append("Plaka modelleri (open-image-models, fast-plate-ocr)  —  MIT")
    satirlar.append("Araç bulucu (YOLOX-tiny, Megvii) ve öz sınama resmi  —  Apache-2.0")
    satirlar.append("    modeller-LISANS.txt")
    with open(os.path.join(klasor, "LISANSLAR.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(satirlar) + "\n")
    return klasor


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
    # 1.3.0: modeller `_internal\modeller` klasörüne (plaka.MODEL_DIZINI =
    # plaka modülünün klasörü + "modeller"; paketlenmişte o `_internal`).
    for ad in MODEL_DOSYALARI:
        komut += ["--add-data", f"{os.path.join(MODEL_KLASORU, ad)}{os.pathsep}modeller"]
    # onnxruntime'ın paket bilgisi de girsin (sürümünü okuyan kod çökmesin).
    komut += ["--copy-metadata", "onnxruntime"]
    ikon = simge()
    if ikon:
        komut += ["--icon", ikon]

    yaz("  PyInstaller çalışıyor (birkaç dakika sürebilir)…")
    r = subprocess.run(komut)
    if r.returncode:
        sys.exit("  ✗ Derleme başarısız.")
    return os.path.join(YAPI, "dist", AD)


def derleme_sinamasi(klasor: str) -> None:
    """
    Derlenmiş .exe'yi GERÇEKTEN çalıştırır: modeller pakette ve özetleri doğru
    mu, onnxruntime (DLL'leriyle) açılıyor mu, öz sınama geçiyor mu
    (`--plaka-sina`). Eksik bir DLL ya da model sahada değil burada görülür.

    `__COMPAT_LAYER=RunAsInvoker`: .exe yönetici izni ister (--uac-admin);
    öz sınama için gerekmez ve izinsiz süreç onu başka türlü başlatamaz.
    """
    sorunlar = model_sorunlari(os.path.join(klasor, "_internal", "modeller"))
    if sorunlar:
        sys.exit("  ✗ Pakette model sorunu:\n    " + "\n    ".join(sorunlar))
    exe = os.path.join(klasor, f"{AD}.exe")
    yaz("  Derlenen .exe sınanıyor (--plaka-sina)…")
    try:
        r = subprocess.run([exe, "--plaka-sina"], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=300,
                           env={**os.environ, "__COMPAT_LAYER": "RunAsInvoker"})
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f"  ✗ Derlenen .exe çalıştırılamadı: {e}")
    if r.returncode != 0 or "hazır" not in r.stdout:
        sys.exit(f"  ✗ Derlenen .exe'de plaka okuyucu çalışmıyor (çıkış {r.returncode}):\n"
                 f"{(r.stdout + r.stderr)[-1500:]}")
    yaz("  ✓ Derlenen .exe'de plaka okuyucu hazır.")


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
    sorunlar = surum_sorunlari() + model_sorunlari()
    if sorunlar:
        yaz("  ✗ Derlemeden önce düzeltilmeli:")
        for s in sorunlar:
            yaz(f"    · {s}")
        yaz("\n  Paket venv'inde: <venv>\\Scripts\\python -m pip install -r requirements.txt")
        return 1
    yaz("  ✓ Sürümler ve model özetleri doğru.")
    klasor = derle()
    derleme_sinamasi(klasor)
    lisanslari_topla(klasor, list(sabitlenenler()))
    yaz("  ✓ Lisanslar eklendi (lisanslar\\LISANSLAR.txt).")
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
