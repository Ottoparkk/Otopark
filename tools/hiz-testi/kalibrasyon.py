# -*- coding: utf-8 -*-
"""
YOLO11s eşik kalibrasyonu (köprü 1.4.2, plan adım 4).

    <paket-venv>\\Scripts\\python kalibrasyon.py <fotoğraf klasörü>

Klasördeki alt klasörler:
    gece\\              gece kamera kanıt fotoğrafları (uygulamadan, araçlı)
    gece-arac-degil\\   araç OLMAYAN gece fotoğrafları (varsa)
    gunduz\\            karşılaştırma için gündüz fotoğrafları (isteğe bağlı)

Kanıt fotoğrafı köprünün araç bulucuya verdiği maskeli kırpıntının
küçültülmüş (≤ 1280 px, ≤ 100 KB JPEG) kopyasıdır. Her fotoğraf GERÇEK
arac.py ile iki modelde de (işlemcide, onnxruntime 1.31 — altın değerlerin
ölçüldüğü yol) puanlanır. Ekrana yazar, HİÇBİR dosya yazmaz. Fotoğraflarda
plaka var (KVKK): klasör depo dışında durur, iş bitince sahibi siler.

Öneri kuralı (esik_oner, test_kalibrasyon.py):
  · doğum: tiny'nin saydığı (≥ 0.35) araçların en düşük YOLO11s puanı,
    0.05'e aşağı yuvarlanmış; araç olmayanın en az 0.05 üstünde; en az 0.15.
    Çatışırsa öneri yok, uyarı.
  · personele: tiny'de ≥ 0.60 olan araç sayısı k → YOLO11s'in k. en yüksek
    puanı (sıra eşleşmesi), 0.05'e aşağı; doğum + 0.10'dan ve araç olmayanın
    + 0.05'inden az değil.
"""
from __future__ import annotations

import math
import os
import sys
from typing import NamedTuple

BURASI = os.path.dirname(os.path.abspath(__file__))
KOPRU = os.path.abspath(os.path.join(BURASI, "..", "kamera-koprusu"))
sys.path.insert(0, KOPRU)

TINY_DOGUM, TINY_PERSONELE = 0.35, 0.60
TABAN = 0.15
PAY = 0.05
ARALIK = 0.10
EN_AZ_FOTO = 40
ARAC_YOK_GIBI = 0.20          # tiny bunun altındaysa "araç yok gibi" listesine


class Oneri(NamedTuple):
    dogum: float | None
    personele: float | None
    kazanc: tuple[int, int]       # (YOLO11s'in sayacağı, tiny'nin saymadığı araç)
    uyarilar: list[str]


def _asagi(x: float) -> float:
    return round(math.floor(x / PAY + 1e-9) * PAY, 2)


def _yukari(x: float) -> float:
    return round(math.ceil(x / PAY - 1e-9) * PAY, 2)


def esik_oner(araclar: list[tuple[float, float]],
              degiller: list[tuple[float, float]]) -> Oneri:
    """araclar / degiller: (tiny puanı, YOLO11s puanı) çiftleri."""
    uyarilar: list[str] = []
    if not araclar:
        return Oneri(None, None, (0, 0), ["araç fotoğrafı yok — öneri yapılamaz"])
    if len(araclar) < EN_AZ_FOTO:
        uyarilar.append(f"yalnızca {len(araclar)} araç fotoğrafı (en az {EN_AZ_FOTO} önerilir) "
                        "— öneri zayıf")
    alt_sinir = _yukari(max(y for _, y in degiller) + PAY) if degiller else 0.0

    sayilan = [y for t, y in araclar if t >= TINY_DOGUM]
    dogum: float | None
    if not sayilan:
        dogum = None
        uyarilar.append("tiny'nin saydığı (≥ 0.35) araç yok — doğum eşiği önerilemez")
    else:
        dogum = _asagi(min(sayilan))
        if dogum < TABAN:
            kayip = sum(1 for y in sayilan if y < TABAN)
            uyarilar.append(f"doğum eşiği tabana ({TABAN:.2f}) çekildi: tiny'nin saydığı "
                            f"{kayip} araç YOLO11s'te bunun altında kalır")
            dogum = TABAN
        if dogum < alt_sinir:
            uyarilar.append(f"çatışma: araç olmayan fotoğraf {alt_sinir - PAY:.2f}'ye kadar "
                            f"puan alıyor, tiny'nin saydığı araç {min(sayilan):.2f} — "
                            "doğum eşiği önerilmedi, fotoğraflara birlikte bakılmalı")
            dogum = None

    k = sum(1 for t, _ in araclar if t >= TINY_PERSONELE)
    personele: float | None
    if k == 0:
        personele = None
        uyarilar.append("tiny'de ≥ 0.60 araç yok — personele eşiği önerilemez")
    else:
        sirali = sorted((y for _, y in araclar), reverse=True)
        personele = _asagi(sirali[k - 1])
        if dogum is not None:
            personele = max(personele, round(dogum + ARALIK, 2))
        personele = max(personele, alt_sinir)

    hedef = dogum if dogum is not None else None
    sayilmayan = [y for t, y in araclar if t < TINY_DOGUM]
    kazanc = (sum(1 for y in sayilmayan if hedef is not None and y >= hedef), len(sayilmayan))
    return Oneri(dogum, personele, kazanc, uyarilar)


# ------------------------------------------------------------------ liste ---

def listeden_sec(dosyalar: list[str], csv_metni: str) -> tuple[list[str], list[str]]:
    """
    (seçilenler, listede olup klasörde olmayanlar). Liste: Supabase SQL
    düzenleyicisinin CSV'si, "name" sütunu kamera/<id>.jpg. Ad karşılaştırması
    büyük/küçük harfe bakmaz; klasör öneki atılır.
    """
    import csv
    import io
    okuyucu = csv.DictReader(io.StringIO(csv_metni.lstrip("﻿")))
    if not okuyucu.fieldnames or "name" not in okuyucu.fieldnames:
        raise ValueError("listede 'name' sütunu yok — SQL sorgusunun CSV dışa aktarımını verin")
    istenen = [os.path.basename(s["name"].strip().replace("\\", "/")).lower()
               for s in okuyucu if s.get("name")]
    var = {os.path.basename(d).lower(): d for d in dosyalar}
    secilen = [var[a] for a in istenen if a in var]
    eksik = [a for a in istenen if a not in var]
    return sorted(secilen), eksik


# ------------------------------------------------------------------ ölçüm ---

def _foto_listesi(klasor: str) -> list[str]:
    if not os.path.isdir(klasor):
        return []
    return sorted(os.path.join(klasor, f) for f in os.listdir(klasor)
                  if f.lower().endswith((".jpg", ".jpeg", ".png")))


def olc(kok: str, liste: str | None = None) -> int:
    """
    `liste` verilirse "gece" fotoğrafları kok\\hepsi\\ içinden o listeyle
    (SQL sorgusunun CSV'si) seçilir; yoksa kok\\gece\\ klasöründen.
    """
    import arac
    import plaka
    gruplar = {alt: _foto_listesi(os.path.join(kok, alt))
               for alt in ("gece", "gece-arac-degil", "gunduz")}
    if liste:
        with open(liste, encoding="utf-8") as f:
            secilen, eksik = listeden_sec(_foto_listesi(os.path.join(kok, "hepsi")), f.read())
        print(f"  Listeden {len(secilen)} gece fotoğrafı seçildi"
              + (f"; listedeki {len(eksik)} dosya hepsi\\ klasöründe yok" if eksik else ""))
        degil = {os.path.basename(d).lower() for d in gruplar["gece-arac-degil"]}
        gruplar["gece"] = [d for d in secilen if os.path.basename(d).lower() not in degil]
    ayar = plaka.calisma_ayarlari()[0]
    tiny = arac.yukle(ayar, profil=arac.YOLOX_TINY)
    yolo = arac.yukle(ayar, profil=arac.YOLO11S)
    sonuc: dict[str, list[tuple[str, float, float]]] = {}
    for alt in ("gece", "gece-arac-degil", "gunduz"):
        satirlar = []
        for yol in gruplar[alt]:
            img = arac.resim_oku(yol)
            if img is None:
                print(f"  ! okunamadı: {alt}\\{os.path.basename(yol)}")
                continue
            t, _ = tiny.skor(img, None)
            y, _ = yolo.skor(img, None)
            satirlar.append((os.path.basename(yol), t, y))
        sonuc[alt] = satirlar
        if satirlar:
            print(f"\n== {alt} ({len(satirlar)} fotoğraf)        tiny   YOLO11s")
            for ad, t, y in satirlar:
                print(f"  {ad:44s} {t:5.2f}   {y:5.2f}")
    gece = [(t, y) for _, t, y in sonuc.get("gece", [])]
    degil = [(t, y) for _, t, y in sonuc.get("gece-arac-degil", [])]
    supheli = [ad for ad, t, _ in sonuc.get("gece", []) if t < ARAC_YOK_GIBI]
    o = esik_oner(gece, degil)
    print("\n== Öneri (YOLO11s)")
    print(f"  doğum eşiği     : {o.dogum if o.dogum is not None else '—'}   (tiny 0.35)")
    print(f"  personele eşiği : {o.personele if o.personele is not None else '—'}   (tiny 0.60)")
    print(f"  kazanç          : tiny'nin saymadığı {o.kazanc[1]} araçtan {o.kazanc[0]}'ini "
          "YOLO11s sayardı")
    for u in o.uyarilar:
        print(f"  ! {u}")
    if supheli:
        print(f"\n== Araç yok gibi (tiny < {ARAC_YOK_GIBI:.2f}) — bakıp araç yoksa "
              "gece-arac-degil\\ klasörüne taşıyın:")
        for ad in supheli:
            print(f"  {ad}")
    return 0


if __name__ == "__main__":
    for _a in (sys.stdout, sys.stderr):
        if hasattr(_a, "reconfigure"):
            _a.reconfigure(encoding="utf-8", errors="replace")
    if len(sys.argv) == 2:
        sys.exit(olc(sys.argv[1]))
    if len(sys.argv) == 4 and sys.argv[2] == "--liste":
        sys.exit(olc(sys.argv[1], sys.argv[3]))
    sys.exit("kullanım: python kalibrasyon.py <fotoğraf klasörü> [--liste gece.csv]")
