# -*- coding: utf-8 -*-
"""
Gönderilecek araçlar kutusu (köprü 1.3.0).

1.2.x'te bir araç dört denemede (~15 sn) gönderilemezse kayboluyordu
("araç elle girilmeli") ve bellekteki kuyruk 4 araçtan sonrasını atıyordu;
internet birkaç dakika gidince o dakikaların araçları iz bırakmıyordu.
İşletme sahibinin kararı (2026-11-06; 2026-10-31'deki "çevrimdışı tampon
yok" kararını değiştirir): her araç gönderilmeden ÖNCE diske yazılır ve
sunucu KESİN bir cevap verene kadar orada kalır, sonra silinir. Sahip, plaka
ve fotoğrafın YALNIZCA gönderilene kadar diskte durmasını onayladı.

Kurallar:
  · Yazım ATOMİK: önce .tmp, sonra os.replace — elektrik kesilse bile yarım
    kayıt kalmaz.
  · Sıra KESİN: kutunun başındaki araç gitmeden sonrakine geçilmez. Aynı aracın
    girişi ve çıkışı kesinti sonrası birlikte gidiyorsa çıkış asla girişten
    önce gitmemeli (sunucu 048 ile olayın saatine bakar ama sıra da şart).
  · Silme yalnızca KESİN cevapta: kabul (bilet, kayıt ya da "yok say") veya
    düzelmeyecek bir ret. Geçici hata (internet yok, 429, 5xx, kimlik reddi)
    kaydı TUTAR; gönderici 1, 2, 4 … 60 sn bekleyip yeniden dener, internet
    dönünce (ya da yeni araç yazılınca) hemen uyanır.
  · Yeniden gönderim güvenli: kayıt kendi islem_id'sini taşır, sunucu aynı
    kimliğe ilk cevabını verir (çökme kabul ile silme arasında olsa da).
  · Birikmiş kayıtlar arasında ARA_SN beklenir: sunucunun dakikada 30 bilet /
    20 okuma sınırı bir kesinti sonrası toplu gönderimde aşılmasın.
  · Kutu dolarsa (EN_COK) uyarılır ama araç YİNE yazılır — sessizce düşen araç
    olmaz. Bozuk bir dosya sırayı tıkamaz: .bozuk adıyla YERİNDE bırakılır.

Kayıtlara plaka YAZILMAZ (yıllarca duran kayıt dosyası kişisel veri biriktirir);
araçlar islem_id ile izlenir. Klasör `kayit` altındadır ve oranın yalnızca
yönetici erişimini devralır.
"""
from __future__ import annotations

import json
import os
import re
import threading
import time

import gunluk

TAMAM = "TAMAM"       # sunucu kabul etti: bilet, kayıt ya da "yok say"
RED = "RED"           # kesin ret, tekrar denemek aynı reddi alır
TEKRAR = "TEKRAR"     # geçici: kayıt kalır, yeniden denenir

EN_COK = 2000
ARA_SN = 3.0
TAVAN_SN = 60
BOS_BEKLEME_SN = 60.0

DOLU_ISARETI = gunluk.GIDEN_DOLU_ISARETI
YAZILAMADI_ISARETI = gunluk.GIDEN_YAZILAMADI_ISARETI
BOZUK_ISARETI = gunluk.GIDEN_BOZUK_ISARETI

_AD = re.compile(r"^(\d{12})-[0-9A-Za-z-]+\.json$")


def _yazdir(s: str) -> None:
    print(s, flush=True)


def _dosyalar(klasor: str) -> list[str]:
    """Sıradaki kayıt dosyaları (adın başındaki sıra numarasına göre)."""
    try:
        adlar = os.listdir(klasor)
    except OSError:
        return []
    return sorted(a for a in adlar if _AD.match(a))


def ozet(klasor: str) -> tuple[int, str | None]:
    """(bekleyen sayısı, en eskisinin `zaman`ı). Salt okunur: `durum` kullanır."""
    adlar = _dosyalar(klasor)
    en_eski = None
    for a in adlar:
        try:
            with open(os.path.join(klasor, a), encoding="utf-8") as f:
                en_eski = json.load(f).get("zaman")
            break
        except (OSError, ValueError, AttributeError):
            continue
    return len(adlar), en_eski


class Giden:
    def __init__(self, klasor: str, en_cok: int = EN_COK, kayit=None):
        self.klasor = klasor
        self.en_cok = en_cok
        self._kayit = kayit or _yazdir
        self._kilit = threading.Lock()
        self._olay = threading.Event()
        try:
            os.makedirs(klasor, exist_ok=True)
        except OSError:
            pass                      # yaz() hatayı söyler; burada köprü düşmesin
        adlar = _dosyalar(klasor)
        self._sira = int(_AD.match(adlar[-1]).group(1)) + 1 if adlar else 1

    # ------------------------------------------------------------- yazım ---

    def yaz(self, olay: dict) -> str | None:
        """Aracı kutuya yazar; dosya yolu ya da (yazılamadıysa) None."""
        kimlik = re.sub(r"[^0-9A-Za-z-]", "", str(olay.get("islem_id", "")))[:64] or "kimliksiz"
        with self._kilit:
            ad = f"{self._sira:012d}-{kimlik}.json"
            yol = os.path.join(self.klasor, ad)
            gecici = yol + ".tmp"
            try:
                os.makedirs(self.klasor, exist_ok=True)
                sayi = len(_dosyalar(self.klasor))
                if sayi >= self.en_cok and (sayi - self.en_cok) % 100 == 0:
                    self._kayit(f"[!] {DOLU_ISARETI}: {sayi} araç bekliyor — internet bağlantısını "
                                "kontrol edin (araçlar yine de yazılıyor)")
                with open(gecici, "w", encoding="utf-8") as f:
                    json.dump(olay, f, ensure_ascii=False)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(gecici, yol)
            except OSError as e:
                try:
                    os.remove(gecici)
                except OSError:
                    pass
                self._kayit(f"[!] {YAZILAMADI_ISARETI}: {e}")
                return None
            self._sira += 1
        self.uyandir()
        return yol

    # ------------------------------------------------------------- okuma ---

    def _oku(self, ad: str) -> tuple[str, dict] | None:
        yol = os.path.join(self.klasor, ad)
        try:
            with open(yol, encoding="utf-8") as f:
                olay = json.load(f)
            if not isinstance(olay, dict):
                raise ValueError("nesne değil")
            return yol, olay
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as e:
            # Sırayı tıkamasın ama SİLİNMESİN: insan baksın.
            try:
                os.replace(yol, yol + ".bozuk")
            except OSError:
                pass
            self._kayit(f"[!] {BOZUK_ISARETI}: {ad} ({e}) — .bozuk olarak ayrıldı")
            return None

    def hepsi(self) -> list[tuple[str, dict]]:
        sonuc = []
        for ad in _dosyalar(self.klasor):
            oge = self._oku(ad)
            if oge is not None:
                sonuc.append(oge)
        return sonuc

    def ilk(self) -> tuple[str, dict] | None:
        for ad in _dosyalar(self.klasor):
            oge = self._oku(ad)
            if oge is not None:
                return oge
        return None

    def sil(self, yol: str) -> None:
        try:
            os.remove(yol)
        except FileNotFoundError:
            pass

    def sayi(self) -> int:
        return len(_dosyalar(self.klasor))

    # ------------------------------------------------------------- uyandırma -

    def uyandir(self) -> None:
        """Bekleyen göndericiyi hemen uyandırır (yeni araç, internet döndü)."""
        self._olay.set()

    def bekle(self, sn: float) -> None:
        self._olay.wait(sn)
        self._olay.clear()


def calistir(kutu: Giden, gonder, uyu=None, ara=None, dur=None) -> None:
    """
    Gönderici döngüsü (köprüde kendi iş parçacığında, sonsuza dek).

    `gonder(olay)` TAMAM / RED / TEKRAR döner. `uyu` uyandırılabilir bekleme
    (kutu.bekle), `ara` birikmiş kayıtlar arasındaki sabit aralık; testler
    ikisini de ve `dur`u verir.
    """
    uyu = uyu or kutu.bekle
    ara = ara or time.sleep
    dur = dur or (lambda: False)
    geri = 1
    while not dur():
        oge = kutu.ilk()
        if oge is None:
            uyu(BOS_BEKLEME_SN)
            continue
        yol, olay = oge
        try:
            sonuc = gonder(olay)
        except Exception as e:  # noqa: BLE001 — tek bir hata göndericiyi öldürmesin
            kutu._kayit(f"[!] gönderim hatası: {type(e).__name__}: {e}")
            sonuc = TEKRAR
        if sonuc in (TAMAM, RED):
            kutu.sil(yol)
            geri = 1
            if kutu.sayi() > 0:
                ara(ARA_SN)
        else:
            uyu(geri)
            geri = min(geri * 2, TAVAN_SN)
