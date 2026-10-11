# -*- coding: utf-8 -*-
"""
Kaldırma.

Yanlış kurulmuş bir köprü, kaldırma yolu olmadığında SYSTEM olarak sonsuza dek
koşuyor ve onu durdurmanın tek yolu schtasks komutlarını bilmekten geçiyordu —
yani kurulumu kolaylaştırmak için yapılan her şeyin tersi.

Ayar dosyası GİZLİ ANAHTARI taşıyor, o yüzden kaldırma onu siler. Kayıt
dosyaları bilerek duruyor: arızayı anlamaya çalışan kişinin elindeki tek iz.
"""
from __future__ import annotations

import glob
import json
import os
import subprocess
import sys

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gunluk  # noqa: E402

AYAR_KLASORU = os.path.join(
    os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark"
)
WINDOWS = os.name == "nt"


def calistir(komut: list[str]) -> bool:
    try:
        r = subprocess.run(komut, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        return r.returncode == 0
    except Exception:
        return False


def serit_adi(ayar_yolu: str) -> str:
    """
    Şerit, ayardan; okunamıyor ya da anlamsızsa DOSYA ADINDAN. Görev adı
    şeride bağlı: boş bir şerit "Otopark Kamera Koprusu ()" diye var olmayan
    bir görevi siler ve gerçek görev yerinde kalır.
    """
    try:
        with open(ayar_yolu, encoding="utf-8-sig") as f:
            yon = str(json.load(f).get("YON") or "").strip().upper()
    except Exception:
        yon = ""
    if yon not in gunluk.SERITLER:
        ad = os.path.basename(ayar_yolu)
        yon = ad[len("kopru-"):-len(".json")].upper()
    return yon


def serit_kaldir(ayar_yolu: str) -> bool:
    """Tek bir şeridi kaldırır. Görev ve ayar gerçekten gittiyse True."""
    yon = serit_adi(ayar_yolu)

    print(f"\n  {yon} şeridi kaldırılıyor…")
    if WINDOWS:
        gorev = f"Otopark Kamera Koprusu ({yon})"
        # Önce VAR MI diye bakılır. Silme komutunun her başarısızlığını
        # "zaten yoktu" saymak, yetki olmadığı için silinemeyen bir görevi
        # gizliyordu — ve ardından ayar silindiği için o görev her açılışta
        # ayarsız başlayıp çıkıyordu.
        if not calistir(["schtasks", "/query", "/tn", gorev]):
            print("    · otomatik başlatma zaten yoktu")
        else:
            calistir(["schtasks", "/end", "/tn", gorev])
            if not calistir(["schtasks", "/delete", "/tn", gorev, "/f"]):
                print("    ✗ otomatik başlatma KALDIRILAMADI — bu programı")
                print("      'Yönetici olarak çalıştır' ile açıp tekrar deneyin.")
                print("      Ayarlar silinmedi: görev dururken ayarı silmek,")
                print("      her açılışta boşuna başlayan bir görev bırakırdı.")
                return False
            print("    ✓ otomatik başlatma kaldırıldı")

    try:
        os.remove(ayar_yolu)
        print("    ✓ ayarlar silindi (gizli anahtar dâhil)")
    except Exception as e:
        print(f"    ✗ ayar dosyası silinemedi: {e}")
        return False

    kayit = gunluk.kayit_yolu(yon)
    if os.path.isfile(kayit):
        print(f"    · kayıt dosyası duruyor: {kayit}")
    return True


def main() -> int:
    print("\n  OTOPARK — Kamera köprüsü kaldırma")
    ayarlar = sorted(glob.glob(os.path.join(AYAR_KLASORU, "kopru-*.json")))
    if not ayarlar:
        print(f"\n  Kurulu bir köprü bulunamadı ({AYAR_KLASORU}).")
        return 0

    print("\n  Bulunan kurulumlar:")
    for y in ayarlar:
        print(f"    · {os.path.basename(y)}")

    try:
        c = input("\n  Hepsi kaldırılsın mı? (e/H): ").strip().lower()
    except EOFError:
        # Cevap gelmediyse SİLME. Kaldırma geri alınamaz ve gizli anahtarı
        # yok ediyor; belirsizlikte güvenli yön hiçbir şey yapmamak.
        c = ""
    if not c.startswith("e"):
        print("  Vazgeçildi, hiçbir şey değişmedi.")
        return 0

    sonuclar = [serit_kaldir(y) for y in ayarlar]

    if not all(sonuclar):
        print("\n  ✗ Kaldırma TAMAMLANMADI — yukarıdaki satırlara bakın.")
        return 1

    print("\n  Kaldırma tamamlandı.")
    print("  · Uygulamada Yönetim → Kamera kurulumu ekranından da kamerayı kaldırın;")
    print("    yoksa uygulama o kamera için 'haber yok' uyarısı göndermeye devam eder.")
    print("  · Uyku ve kapak ayarları DEĞİŞTİRİLMEDİ — bu bilgisayarı başka bir iş")
    print("    için kullanacaksanız Denetim Masası → Güç Seçenekleri'nden geri alın.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
