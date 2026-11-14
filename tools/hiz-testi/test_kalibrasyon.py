# -*- coding: utf-8 -*-
"""
kalibrasyon.py testleri — YOLO11s eşiklerini öneren kural.

    python test_kalibrasyon.py

Kural (plan, 2026-11-13): aynı gece fotoğraflarında YOLOX-tiny ve YOLO11s
puanları yan yana. YOLO11s'in doğum eşiği, tiny'nin saydığı (≥ 0.35) her
aracı saymalı; personele eşiği, tiny'nin 0.60'ının araçlar arasındaki
sırasında. Araç olmayan fotoğrafların üstünde pay bırakılır; çatışırsa
tahmin edilmez, uyarılır.
"""
from __future__ import annotations

import os
import sys

BURASI = os.path.dirname(os.path.abspath(__file__))
KOPRU = os.path.abspath(os.path.join(BURASI, "..", "kamera-koprusu"))
sys.path.insert(0, BURASI)
sys.path.insert(0, KOPRU)
for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

import kalibrasyon as k  # noqa: E402


def _araclar(n: int, tiny: float, yolo: float) -> list[tuple[float, float]]:
    return [(tiny, yolo)] * n


def test_dogum_tiny_nin_saydigi_en_zayif_araca_gore_asagi_yuvarlanir():
    # tiny ≥ 0.35 sayılan araçların en düşük YOLO11s puanı 0.234 → 0.20.
    a = _araclar(40, 0.80, 0.70) + [(0.36, 0.234), (0.50, 0.41)]
    o = k.esik_oner(a, [])
    assert o.dogum == 0.20, o
    # tiny'nin saymadığı (< 0.35) araç doğum eşiğini AŞAĞI çekmez.
    o2 = k.esik_oner(a + [(0.30, 0.05)], [])
    assert o2.dogum == 0.20, o2


def test_dogum_taban_015():
    a = _araclar(40, 0.80, 0.70) + [(0.40, 0.08)]
    o = k.esik_oner(a, [])
    assert o.dogum == 0.15 and any("0.15" in u for u in o.uyarilar), o


def test_arac_olmayan_ustunde_pay_ve_catisma_uyarisi():
    a = _araclar(40, 0.80, 0.70) + [(0.40, 0.30)]
    # Araç olmayan en yüksek 0.12 → doğum en az 0.17 olmalı; 0.30 → 0.30 yeter.
    o = k.esik_oner(a, [(0.10, 0.12)])
    assert o.dogum == 0.30 and not o.uyarilar, o
    # Araç olmayan 0.33: doğum ≥ 0.38 ister ama tiny'nin saydığı araç 0.30 →
    # çatışma: öneri yok (None), uyarı var.
    o = k.esik_oner(a, [(0.10, 0.33)])
    assert o.dogum is None and any("çatış" in u for u in o.uyarilar), o


def test_personele_sira_eslesmesi():
    # 50 araç: tiny'de 10'u ≥ 0.60 (en yüksek %20). YOLO11s'te aynı sıradaki
    # (10. en yüksek) puan 0.47 → 0.45.
    a = [(0.90, 0.80 - i * 0.03) for i in range(10)] + [(0.45, 0.30)] * 40
    a[9] = (0.90, 0.47)
    o = k.esik_oner(a, [])
    assert o.personele == 0.45, o


def test_personele_dogumdan_en_az_010_yukarida_ve_arac_olmayanin_ustunde():
    a = [(0.90, 0.32)] * 10 + [(0.45, 0.30)] * 40
    o = k.esik_oner(a, [])
    assert o.dogum == 0.30 and o.personele == 0.40, o          # 0.30 + 0.10
    o = k.esik_oner(a, [(0.20, 0.25)])
    assert o.personele >= 0.30 and o.personele >= o.dogum + 0.10, o


def test_az_fotograf_uyarisi_ve_kazanc():
    a = _araclar(12, 0.80, 0.35) + [(0.20, 0.40), (0.30, 0.10)]
    o = k.esik_oner(a, [])
    assert o.dogum == 0.35, o
    assert any("40" in u for u in o.uyarilar), o.uyarilar
    # tiny'nin saymadığı 2 aracın 1'ini (0.40 ≥ doğum 0.35) YOLO11s sayardı.
    assert o.kazanc == (1, 2), o


def test_listeden_secer():
    # Supabase SQL düzenleyicisinin CSV dışa aktarımı: "name" sütunu
    # kamera/<id>.jpg. Klasördeki dosyalardan yalnızca listedekiler seçilir
    # (büyük/küçük harf ve klasör öneki önemsiz); listede olup klasörde
    # olmayanlar ayrıca sayılır.
    csv_metni = ('name,saat\n'
                 'kamera/aaaa-1.jpg,2026-11-12 01:10:00\n'
                 '"kamera/BBBB-2.jpg","2026-11-12 19:05:00"\n'
                 'kamera/cccc-3.jpg,2026-11-12 20:00:00\n')
    dosyalar = [r"C:\x\hepsi\aaaa-1.jpg", r"C:\x\hepsi\bbbb-2.JPG", r"C:\x\hepsi\dddd-4.jpg"]
    secilen, eksik = k.listeden_sec(dosyalar, csv_metni)
    assert secilen == [r"C:\x\hepsi\aaaa-1.jpg", r"C:\x\hepsi\bbbb-2.JPG"], secilen
    assert eksik == ["cccc-3.jpg"], eksik
    try:
        k.listeden_sec(dosyalar, "saat\n2026-11-12\n")
        raise AssertionError("name sütunu olmayan liste kabul edildi")
    except ValueError:
        pass


def test_bos_girdi():
    o = k.esik_oner([], [])
    assert o.dogum is None and o.personele is None and o.uyarilar, o


if __name__ == "__main__":
    import kalinti      # bırakılanlar %TEMP%\otopark-test-kalintilari altında
    kalinti.klasor("otopark-test-kalibrasyon-")
    testler = [(ad, f) for ad, f in sorted(globals().items()) if ad.startswith("test_")]
    kalan = 0
    for ad, f in testler:
        try:
            f()
            print(f"  ✓ {ad}")
        except Exception as e:  # noqa: BLE001
            kalan += 1
            print(f"  ✗ {ad}: {type(e).__name__}: {e}")
    print(f"\n{len(testler) - kalan}/{len(testler)} geçti")
    sys.exit(1 if kalan else 0)
