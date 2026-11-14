# -*- coding: utf-8 -*-
"""
`--video <dosya>` (köprü 1.4.2, E12): bir kamera kaydını GERÇEK köprü
döngüsünden geçirir — hiçbir şey göndermez.

Sahaya gitmeden "bu araç neden kaçtı?" sorusunun cevabı: kaydı (kameranın
NVR'ından ya da telefondan alınmış) bu bilgisayarda oynatın; köprünün o anda
vereceği her karar ekrana ve geçici bir kayda yazılır, sonunda neyin
GİDECEĞİ (plaka + yön ipucu, ya da personele) listelenir.

Gerçek döngü (kopru.main) değişmeden koşar; yalnızca dış dünyası değişir:
  · kamera   → `DosyaKamera`: dosyanın kendi hızında (fps) kare verir — izci
               saniye ölçer (durma, kaybolma, 60 sn kuralı), hızlı oynatma
               kararları değiştirirdi. Dosya bitince son kare `kuyruk_sn`
               boyunca tekrarlanır: kaybolan izler kapanabilsin (DIKIS_SN 4 sn);
  · ağ       → kaydeden bir sahte: hiçbir istek ağa çıkmaz (olay → 200/422
               cevabı, kalp atışı → 400 — köprü onları bekler);
  · kayıt ve gönderim kutusu → yeni bir geçici klasör (gunluk.kayit_klasoru);
               GERÇEK kayıt klasörüne ve kutuya dokunulmaz;
  · kameranın şifre denetimi, bekçinin ve GPU'nun "süreci yeniden başlat"
               çıkışları → zararsız yerine geçenler. GPU_YENIDEN_BASLAT_SN'yi
               giris yükseltir: oynatma GPU için yeniden başlatma dosyası yazmaz.
Model önbelleği (PROGRAMDATA) gerçek olanı kullanır — oynatma her seferinde
modelleri yeniden derlemesin.

Özet ekrana (sys.__stdout__) yazılır, kayda DEĞİL: plaka içerir ve kayıtlara
plaka yazılmaz (1.3.0 kuralı). Plakasız sayılar kayıttan okunur (durum).
"""
from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
import types
from typing import Callable, NamedTuple


class Ozet(NamedTuple):
    kod: int                      # 0 oynadı; 1 dosya açılamadı / köprü durdu
    gonderimler: list             # [{"t", "tur", "plaka", "tahmin", "hareket"}] — gidecek olanlar
    sayilar: dict                 # kayıttan: giris, cikis, iceride, kapida_kaybolan, kararsiz
    klasor: str                   # geçici kayıt + kutu klasörü (sahibi siler)


class _Yanit:
    def __init__(self, kod: int, metin: str):
        self.status_code = kod
        self.text = metin
        self.headers: dict = {}


FPS_VARSAYILAN = 25.0


def oynatma_suresi(fps, kare_sayisi) -> tuple[float, float | None]:
    """
    (kullanılacak fps, süre sn | None). Dosyanın fps'i ve kare sayısı yanlış
    olabilir (NVR dışa aktarımı: 0, -1, 1000): fps 1-120 dışındaysa 25 —
    DosyaKamera da AYNI değeri kullanır; kare sayısı ≤ 0 ise süre bilinmez.
    """
    try:
        f = float(fps)
    except (TypeError, ValueError):
        f = 0.0
    if not (f == f and 1.0 <= f <= 120.0):          # NaN da dışarıda
        f = FPS_VARSAYILAN
    try:
        n = float(kare_sayisi)
    except (TypeError, ValueError):
        n = 0.0
    return f, (n / f if n == n and n > 0 else None)


class DosyaKamera:
    """cv2.VideoCapture yerine: dosyayı kendi hızında okur, sonunda bekler."""

    def __init__(self, dosya: str, kuyruk_sn: float, bitti: threading.Event, saat: dict,
                 acici: Callable, dur: threading.Event | None = None):
        import cv2
        # `acici` = GERÇEK cv2.VideoCapture, değiştirilmeden ÖNCE alınmış:
        # kopru.cv2 ile cv2 aynı modül, değiştirilen fabrika burayı çağırsa
        # kendi kendini sonsuza dek açardı.
        self._cap = acici(dosya)
        fps = self._cap.get(cv2.CAP_PROP_FPS) if self._cap.isOpened() else 0.0
        self.fps, _ = oynatma_suresi(fps, 0)
        self._kuyruk_sn = kuyruk_sn
        self._bitti = bitti
        # Özet yazıldıktan sonra kamera DONAR: köprü özetin altına satır
        # yazmasın, pencere Enter beklerken işlemciyi boşuna kullanmasın.
        self._dur = dur or threading.Event()
        self._saat = saat
        self._no = 0
        self._son = None
        self._bitis: float | None = None

    def isOpened(self) -> bool:
        return self._cap.isOpened()

    def set(self, *a) -> bool:
        return True

    def release(self) -> None:
        pass                              # köprü yeniden bağlanırsa dosya baştan başlamasın

    def read(self):
        if self._dur.is_set():
            threading.Event().wait()                 # oynatma bitti: köprü burada durur
        simdi = time.monotonic()
        if self._saat.get("t0") is None:
            self._saat["t0"] = simdi
        if self._bitis is None:
            # Döngü geride kaldıysa vakti geçmiş kareler ATLANIR: canlı kamera
            # yalnızca en yeni kareyi tutar (BUFFERSIZE 1). Her kareyi işlemek
            # zamanı videoya göre uzatır, durma / kaybolma kararları kayardı.
            vakti_gelen = int((simdi - self._saat["t0"]) * self.fps)
            while self._no < vakti_gelen:
                if not self._cap.grab():
                    break
                self._no += 1
            hedef = self._saat["t0"] + self._no / self.fps
            if hedef > simdi:
                time.sleep(hedef - simdi)
            ok, kare = self._cap.read()
            if ok and kare is not None:
                self._no += 1
                self._son = kare
                return True, kare.copy()
            self._bitis = time.monotonic()
            self._saat["sure"] = self._no / self.fps
        if self._son is None:
            self._bitti.set()
            return False, None
        time.sleep(1.0 / self.fps)
        if time.monotonic() - self._bitis >= self._kuyruk_sn:
            self._bitti.set()
        return True, self._son.copy()


def _kutu_bos(klasor: str) -> bool:
    if not os.path.isdir(klasor):
        return True
    return not any(a.endswith(".json") for a in os.listdir(klasor))


def _ekran(metin: str) -> None:
    # Kayda değil, gerçek konsola: özet plaka içerir (kayıtlara plaka yazılmaz).
    hedef = sys.__stdout__ or sys.stdout
    hedef.write(metin + "\n")
    hedef.flush()


def oynat(dosya: str, *, kuyruk_sn: float = 8.0, yaz: Callable[[str], None] | None = None,
          zaman_asimi_sn: float | None = None) -> Ozet:
    """
    `dosya`yı gerçek köprü döngüsünden geçirir; hiçbir şey göndermez. Köprü
    ayarları (OTOPARK_AYAR) kopru İÇE AKTARILMADAN önce ortamda olmalı —
    giris bunu yapar. `yaz`: özet satırları (varsayılan: gerçek konsol).
    """
    import cv2
    yaz = yaz or _ekran
    acici = cv2.VideoCapture            # gerçek olanı, değiştirmeden ÖNCE
    deneme = acici(dosya)
    acildi = deneme.isOpened()
    fps = deneme.get(cv2.CAP_PROP_FPS) if acildi else 0.0
    kare_sayisi = deneme.get(cv2.CAP_PROP_FRAME_COUNT) if acildi else 0.0
    deneme.release()
    if not acildi:
        yaz(f"  ✗ Video açılamadı: {dosya}")
        return Ozet(1, [], {}, "")

    import gunluk
    import kopru

    klasor = tempfile.mkdtemp(prefix="otopark-video-")
    gunluk.kayit_klasoru = lambda: klasor
    bitti = threading.Event()
    saat: dict = {"t0": None, "sure": None}
    gidecek: list[dict] = []
    kilit = threading.Lock()

    def post(url, json=None, headers=None, timeout=None):
        g = json or {}
        if not (g.get("plaka") or g.get("okunamadi")):
            return _Yanit(400, '{"hata":"(video: kalp atışı gönderilmedi)"}')
        t0 = saat.get("t0")
        kayit = {"t": round(time.monotonic() - t0, 1) if t0 else 0.0,
                 "tur": "PLAKA" if g.get("plaka") else "OKUNAMADI",
                 "plaka": g.get("plaka"), "tahmin": g.get("tahmin"),
                 "hareket": g.get("hareket"), "islem_id": g.get("islem_id")}
        with kilit:
            if not any(x["islem_id"] == kayit["islem_id"] for x in gidecek):
                gidecek.append(kayit)
        if kayit["tur"] == "PLAKA":
            return _Yanit(200, '{"ok":true,"karar":"(video)","sebep":"(gönderilmedi)"}')
        return _Yanit(422, '{"hata":"Plaka okunamadı.","istisna":true}')

    kopru.requests = types.SimpleNamespace(post=post,
                                           RequestException=kopru.requests.RequestException)
    dur = threading.Event()
    kopru.cv2.VideoCapture = lambda *a, **k: DosyaKamera(dosya, kuyruk_sn, bitti, saat, acici,
                                                         dur)
    kopru.sifre_kabul_edilene_kadar_bekle = lambda: None
    kopru._bekci_cik = lambda: bitti.set()
    kopru._gpu_cik = lambda: None

    fps_k, sure = oynatma_suresi(fps, kare_sayisi)
    sure_s = f"~{sure:.0f} sn" if sure is not None else "süresi bilinmiyor"
    yaz(f"\n  Video: {os.path.basename(dosya)} · {sure_s} · {fps_k:.0f} kare/sn — "
        "gerçek hızında oynatılıyor, hiçbir şey gönderilmez.")
    is_ = threading.Thread(target=kopru.main, daemon=True, name="video-kopru")
    is_.start()
    # Süre bilinmiyorsa (kare sayısı yok / yanlış) cömert bir üst sınır: 6 saat.
    if zaman_asimi_sn is not None:
        sinir = zaman_asimi_sn
    else:
        sinir = (sure + kuyruk_sn + 300.0) if sure is not None else 6 * 3600.0
    bas = time.monotonic()
    while not bitti.is_set():
        if not is_.is_alive():
            yaz("  ✗ Köprü durdu (ayarlar ya da modeller) — ayrıntı geçici kayıtta: " + klasor)
            return Ozet(1, list(gidecek), {}, klasor)
        if time.monotonic() - bas > sinir:
            yaz("  ✗ Oynatma zaman aşımına uğradı — ayrıntı geçici kayıtta: " + klasor)
            return Ozet(1, list(gidecek), {}, klasor)
        bitti.wait(0.5)

    if saat.get("sure") is None:
        # Dosya açıldı ama hiç kare okunamadı (ör. bu bilgisayarın OpenCV'si
        # H.265 çözemiyor) ya da köprü takıldı: "hiçbir şey gitmezdi" DEĞİL.
        _dondur(kopru, dur)
        yaz("  ✗ Videodan kare okunamadı (biçim desteklenmiyor olabilir — MP4/H.264 "
            "olarak dışa aktarın) — ayrıntı geçici kayıtta: " + klasor)
        return Ozet(1, list(gidecek), {}, klasor)

    # Kutudaki son olaylar da "gitsin" (sahteye) — en çok 15 sn.
    son = time.monotonic() + 15.0
    kutular = [os.path.join(klasor, a) for a in os.listdir(klasor) if a.startswith("giden-")]
    while time.monotonic() < son and not all(_kutu_bos(k) for k in kutular):
        time.sleep(0.2)

    satirlar: list[str] = []
    for ad in sorted(os.listdir(klasor)):
        if ad.endswith(".log"):
            with open(os.path.join(klasor, ad), encoding="utf-8", errors="replace") as f:
                satirlar += f.read().splitlines()
    sayilar = kayit_sayilari(satirlar)
    giris, cikis, iceride = sayilar["giris"], sayilar["cikis"], sayilar["iceride"]
    kayboldu, kararsiz = sayilar["kapida_kaybolan"], sayilar["kararsiz"]

    with kilit:
        liste = sorted(gidecek, key=lambda g: g["t"])
    yaz(f"  Gidecekti (hiçbiri gönderilmedi): {len(liste)}")
    for g in liste:
        dk, sn = divmod(g["t"], 60)
        ipucu = f" ({g['hareket'].lower()})" if g.get("hareket") else ""
        if g["tur"] == "PLAKA":
            yaz(f"    {int(dk):02d}:{sn:04.1f}  {g['plaka']}{ipucu}")
        else:
            yaz(f"    {int(dk):02d}:{sn:04.1f}  personele (tahmin {g.get('tahmin') or 'yok'})")
    yaz(f"  Kayıt: {giris} giriş, {cikis} çıkış, {iceride} otopark içi hareket, "
        f"{kayboldu} kapıda kaybolan, {kararsiz} kararsız biten iz")
    yaz(f"  Bütün kayıt (köprünün her satırı): {klasor}")
    _dondur(kopru, dur)
    return Ozet(0, liste, sayilar, klasor)


def _dondur(kopru, dur: threading.Event) -> None:
    """
    Oynatma bitti: kamera donar (DosyaKamera.read bekler) ve bekçi artık
    "takıldı" demez — yoksa özetin altına "süreç kapanıyor" yazardı. Oynatma
    sürerken bekçi çalışır (takılan köprüyü yakalar).
    """
    kopru.bekci_karari = lambda *a, **k: "tamam"
    dur.set()


def kayit_sayilari(satirlar: list[str]) -> dict:
    """
    Oynatmanın kaydındaki karar satırları — `durum`un sayımıyla aynı işaretler,
    ama TARİHE bakmadan (gece yarısını geçen oynatma). Şeridin yönüne ters
    olup gönderilmeyen olay sayılmaz ("(iz" ile, durum gibi).
    """
    import gunluk
    s = {"giris": 0, "cikis": 0, "iceride": 0, "kapida_kaybolan": 0, "kararsiz": 0}
    for x in satirlar:
        if f"[i] {gunluk.GIRDI_ISARETI} (iz" in x:
            s["giris"] += 1
        elif f"[i] {gunluk.CIKTI_ISARETI} (iz" in x:
            s["cikis"] += 1
        elif gunluk.ICERIDE_ISARETI in x:
            s["iceride"] += 1
        elif f"[i] {gunluk.KAPIDA_KAYBOLDU_ISARETI} (iz" in x:
            s["kapida_kaybolan"] += 1
        elif f"[i] {gunluk.KARARSIZ_ISARETI} (iz" in x:
            s["kararsiz"] += 1
    return s
