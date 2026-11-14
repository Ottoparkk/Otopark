# -*- coding: utf-8 -*-
"""
Hız testi (hiz_testi.py) — testler.

    <venv>\\Scripts\\python test_hiz_testi.py

Araç ölçüm aracıdır, köprünün parçası değildir; ama verdiği sayılarla model ve
GPU kararı verilecek, o yüzden:
  · her model KÖPRÜNÜN beslediği gibi beslenmeli (YOLOX ön işlemesi köprüyle
    birebir),
  · ölçülen her bulucu öz sınama resmindeki ARACI gerçekten bulmalı (bozuk bir
    dışa aktarım hızlı ama yanlış ölçülürdü),
  · GPU ya da model dosyası yoksa satır "yok" der, araç durmaz,
  · rapor her model × her çalıştırıcı satırını ve birleşik senaryoları içerir.

Modeller: HIZ_MODELLER (varsayılan C:\\Users\\Lrx\\hiz-modeller\\hazir).
Hiçbir dosya silinmez; geçici klasörler scratch'te kalır.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile

import numpy as np

BURASI = os.path.dirname(os.path.abspath(__file__))
KOPRU = os.path.join(BURASI, "..", "kamera-koprusu")
sys.path.insert(0, BURASI)
sys.path.insert(0, KOPRU)
for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

import cv2  # noqa: E402

import hiz_testi as h  # noqa: E402

MODELLER = os.environ.get("HIZ_MODELLER", r"C:\Users\Lrx\hiz-modeller\hazir")
SINAMA = os.path.join(MODELLER, h.SINAMA_RESMI)


def _arkalar() -> list[str]:
    return h.kullanilabilir_arkalar(h.ov_cihazlari())


def test_yolox_hazirligi_kopruyle_ayni():
    import arac
    img = cv2.imread(SINAMA)
    x, r = arac.on_isle(img)
    y, r2 = h.yolox_hazirla(img, 416)
    assert x.shape == y.shape and np.array_equal(x, y) and r == r2


def test_her_bulucu_araci_bulur():
    arkalar = _arkalar()
    assert "ORT-CPU" in arkalar and "OV-CPU" in arkalar, arkalar
    for m in h.MODELLER:
        if m.tur not in ("yolox", "yolo11", "dfine"):
            continue
        for arka in arkalar:
            puan = h.arac_puani(MODELLER, m, arka)
            assert puan >= 0.5, (m.ad, arka, puan)


def test_gpu_ve_dosya_yoksa_durmaz():
    d = tempfile.mkdtemp(prefix="hiz-eksik-")
    for dosya in ("yolox_tiny.onnx", h.SINAMA_RESMI):
        shutil.copy(os.path.join(MODELLER, dosya), d)
    rapor = h.calistir(d, cihazlar=["CPU"], n=2, isinma=1, senaryo_sn=0.5)
    assert "GPU yok" in rapor, rapor
    assert "dosya yok" in rapor, rapor
    assert "YOLOX-tiny 416" in rapor, rapor


def test_turkce_harfli_klasorde_calisir():
    # Sahada 2026-11-11: C:\OtoparkKameraHız\… → "Öz sınama resmi bulunamadı".
    # cv2.imread Windows'ta ASCII dışı yolu açamıyor; OpenVINO ve onnxruntime
    # da aynı yoldan model ve önbellek açıyor — hepsi denenir.
    d = tempfile.mkdtemp(prefix="hız-ölçüm-ğüşç-")
    for dosya in ("yolox_tiny.onnx", h.SINAMA_RESMI):
        shutil.copy(os.path.join(MODELLER, dosya), d)
    m = h._MODEL["YOLOX-tiny 416"]
    eski = h.ONBELLEK
    h.ONBELLEK = os.path.join(d, "ov-önbellek")       # programın yanı da Türkçe harfli olabilir
    try:
        for arka in _arkalar():
            puan = h.arac_puani(d, m, arka)
            assert puan >= 0.5, (arka, puan)
    finally:
        h.ONBELLEK = eski
    if "OV-GPU" in _arkalar():
        assert os.listdir(h.ONBELLEK or os.path.join(d, "ov-önbellek")), "önbellek yazılmadı"


def test_rapor_tum_satirlari_icerir():
    rapor = h.calistir(MODELLER, n=2, isinma=1, senaryo_sn=0.5)
    for m in h.MODELLER:
        for arka in h.ARKALAR:
            assert any(m.ad in s and arka in s for s in rapor.splitlines()), (m.ad, arka)
    for s in h.SENARYOLAR:
        assert s.ad in rapor, s.ad
    assert "İşlemci" in rapor and "Sürümler" in rapor


if __name__ == "__main__":
    import kalinti      # köprünün; bırakılanlar %TEMP%\otopark-test-kalintilari altında
    kalinti.klasor("otopark-test-hiz-testi-")
    testler = [(ad, f) for ad, f in sorted(globals().items()) if ad.startswith("test_")]
    kalan = 0
    for ad, f in testler:
        try:
            f()
            print(f"  ✓ {ad}")
        except Exception as e:  # noqa: BLE001
            kalan += 1
            print(f"  ✗ {ad}: {type(e).__name__}: {e}")
    print(f"{len(testler) - kalan}/{len(testler)} geçti")
    sys.exit(1 if kalan else 0)
