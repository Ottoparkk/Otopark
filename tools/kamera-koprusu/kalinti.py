# -*- coding: utf-8 -*-
"""
Testlerin bıraktıkları TEK bir klasörde: %TEMP%\\otopark-test-kalintilari.

Testler hiçbir şey silmez (sahibin kuralı: hata olursa ne olduğu görülebilsin,
silme kararı sahibinin). Eskiden her koşu %TEMP%'in tepesine kendi klasörünü
açıyordu; 2026-11-12'de 850 dağınık klasör 25 GB olmuştu. Şimdi hepsi bu
kökün altında; sahibi tek klasörü siler:

    Remove-Item "$env:TEMP\\otopark-test-kalintilari" -Recurse -Force

Yalnızca testler kullanır; köprü (paket) bu dosyayı içermez.
"""
from __future__ import annotations

import os
import tempfile

KOK_AD = "otopark-test-kalintilari"


def _kok() -> str:
    """Kök klasör. Zaten onun altındaysak (alt süreç, iç içe çağrı) aynı kök."""
    simdiki = os.path.abspath(tempfile.gettempdir())
    parcalar = simdiki.split(os.sep)
    if KOK_AD in parcalar:
        return os.sep.join(parcalar[:parcalar.index(KOK_AD) + 1])
    return os.path.join(simdiki, KOK_AD)


def klasor(on_ek: str) -> str:
    """
    Kökün altında bu koşunun klasörünü açar ve bu süreçle başlatacağı her
    alt sürecin geçici klasörünü oraya çevirir (TEMP / TMP / TMPDIR ve
    tempfile). Klasörün yolunu döndürür; hiçbir şey silmez.
    """
    kok = _kok()
    os.makedirs(kok, exist_ok=True)
    k = tempfile.mkdtemp(prefix=on_ek, dir=kok)
    for ad in ("TEMP", "TMP", "TMPDIR"):
        os.environ[ad] = k
    tempfile.tempdir = k
    return k
