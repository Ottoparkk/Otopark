# -*- coding: utf-8 -*-
"""
Klip kaydedici (köprü 1.4.3, 1d).

Sahibin kararı (2026-11-17): yönü bilinmeyen her olayın kısa bir videosu —
kırpıntı kareleri, saniyede ~5, varsayılan KAPALI (KLIP=1 açar), yalnızca bu
bilgisayarda, 7 gün. Amaç 1a'nın deneme haftası: her "aynı aracın parçası
sayılırdı" satırı gerçekte ne olduğuyla karşılaştırılır.

BİLEREK İSTİSNA: giden.py'deki kural (2026-11-06) plaka ve fotoğrafın
yalnızca gönderilene kadar diskte durmasıdır. Klip görüntüde plakayı
gösterir; sahip bu kaydı 17.11'de ayrıca seçti — açıksa 7 gün, sonra
kendiliğinden silinir, hiçbir yere gönderilmez. Dosya ADINDA ve kayıt
satırında plaka YOK.

Nasıl:
  · kare(): her kamera karesinde çağrılır; en az KLIP_ARALIK_SN arayla bir
    kare tutulur (küçültülüp JPEG), KLIP_TAMPON_SN'den eskisi atılır (30–65 MB;
    ölçülen: kare başına ~0.7 ms).
  · iste(bas, son, ad): bekleyen klip; tampon `son`a ulaşınca kareleri yazıcı
    iş parçacığına verilir. bosalt(): kamera koptu — bekleyen hepsi hemen.
  · Yazıcı OpenCV'nin kendi MJPEG yazıcısıyla (FFmpeg gerekmez) .avi yazar;
    her karenin köşesinde İstanbul saati. Hata ana döngüye ÇIKMAZ: tek satır.
  · Temizlik: açılışta ve saatte bir, yalnızca klip klasöründeki .avi:
    KLIP_GUN'den eskiler, sonra toplam KLIP_EN_COK_BAYT'ı aşan en eskiler.
    Diskte KLIP_BOS_EN_AZ_BAYT'tan az yer varsa klip yazılmaz.
"""
from __future__ import annotations

import os
import queue
import re
import shutil
import threading
import time
from collections import deque
from datetime import datetime, timedelta, timezone

import cv2
import numpy as np

import gunluk

KLIP_ARALIK_SN = 0.2            # saniyede 5 kare
KLIP_TAMPON_SN = 70.0           # bellekte tutulan son süre
KLIP_MAX_KENAR = 960            # tutulan karenin uzun kenarı (px)
KLIP_JPEG = 70                  # tampondaki ve klipteki JPEG kalitesi
KLIP_ONCE_SN = 5.0              # araç ilk görülmeden önce
KLIP_SONRA_SN = 5.0             # olaydan sonra
KLIP_GERI_EN_COK_SN = 60.0      # klip olaydan en çok bu kadar geri başlar
KLIP_GUN = 7
KLIP_EN_COK_BAYT = 2 * 1024 ** 3
KLIP_BOS_EN_AZ_BAYT = 5 * 1024 ** 3
TEMIZLIK_SN = 3600.0

ISTANBUL = timezone(timedelta(hours=3))          # Türkiye 2016'dan beri UTC+3
OLAY_ADLARI = ("TEK_KARE", "KAPIDA_KAYBOLDU", "ESKI_GIRDI")
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def klip_klasoru() -> str:
    return os.path.join(
        os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark", "klipler"
    )


def pencere(dogum_mono: float, simdi: float) -> tuple[float, float]:
    """Araç ilk görülmeden KLIP_ONCE_SN önce (en çok KLIP_GERI_EN_COK_SN geri) .. olaydan KLIP_SONRA_SN sonra."""
    return (max(dogum_mono - KLIP_ONCE_SN, simdi - KLIP_GERI_EN_COK_SN),
            simdi + KLIP_SONRA_SN)


def klip_adi(zaman: datetime, iz_no: int, tur: str, islem_id: str | None,
             *, emildi: bool = False) -> str:
    """
    `2026-11-18_22-26-05_iz368_KAPIDA_KAYBOLDU_ab12cd34.avi` — İstanbul
    saati, iz, olay ve gönderilen ilk islem_id'nin ilk 8'i (kayıttaki
    "gönderildi -> ab12cd34" satırıyla eşleşir). Plaka adın parçası OLAMAZ:
    yalnızca bilinen olay adları ve uuid biçimindeki kimlik geçer.
    """
    saat = zaman.astimezone(ISTANBUL).strftime("%Y-%m-%d_%H-%M-%S")
    olay = tur if tur in OLAY_ADLARI else "OLAY"
    if emildi:
        ek = "emildi"
    elif islem_id is not None and _UUID.fullmatch(islem_id):
        ek = islem_id[:8]
    else:
        ek = "gonderimyok"
    return f"{saat}_iz{int(iz_no)}_{olay}_{ek}.avi"


def temizle(klasor: str, simdi: float, *, gun: float = KLIP_GUN,
            en_cok_bayt: int = KLIP_EN_COK_BAYT) -> int:
    """
    Klip klasöründeki .avi'lerden `gun`den eskileri, sonra toplam
    `en_cok_bayt`ı aşan en eskileri siler (başka dosyaya dokunmaz). Silinen sayı.
    """
    try:
        adlar = os.listdir(klasor)
    except OSError:
        return 0
    dosyalar = []
    for ad in adlar:
        yol = os.path.join(klasor, ad)
        if not ad.lower().endswith(".avi") or not os.path.isfile(yol):
            continue
        try:
            st = os.stat(yol)
        except OSError:
            continue
        dosyalar.append((st.st_mtime, st.st_size, yol))
    dosyalar.sort()                                   # en eski önce
    silinen = 0
    kalan = []
    for mt, boyut, yol in dosyalar:
        if simdi - mt > gun * 86400:
            silinen += _sil(yol)
        else:
            kalan.append((mt, boyut, yol))
    toplam = sum(b for _, b, _ in kalan)
    for mt, boyut, yol in kalan:
        if toplam <= en_cok_bayt:
            break
        if _sil(yol):
            silinen += 1
            toplam -= boyut
    return silinen


def _sil(yol: str) -> int:
    try:
        os.remove(yol)
        return 1
    except OSError:
        return 0


def _bos_alan(yol: str) -> int:
    hedef = yol
    while not os.path.isdir(hedef):
        ust = os.path.dirname(hedef)
        if ust == hedef:
            break
        hedef = ust
    return shutil.disk_usage(hedef).free


def _video_ac(yol: str, fps: float, boyut: tuple[int, int]):
    """OpenCV'nin kendi MJPEG yazıcısı (CAP_OPENCV_MJPEG): FFmpeg gerekmez."""
    w = cv2.VideoWriter(yol, cv2.CAP_OPENCV_MJPEG, cv2.VideoWriter_fourcc(*"MJPG"),
                        fps, boyut)
    if not w.isOpened():
        raise RuntimeError("video yazıcı açılamadı")
    w.set(cv2.VIDEOWRITER_PROP_QUALITY, KLIP_JPEG)
    return w


def _saat_yaz(img: np.ndarray, zaman: datetime) -> None:
    metin = zaman.astimezone(ISTANBUL).strftime("%d.%m.%Y %H:%M:%S")
    y = img.shape[0] - 8
    cv2.putText(img, metin, (8, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3, cv2.LINE_AA)
    cv2.putText(img, metin, (8, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1,
                cv2.LINE_AA)


class Klipci:
    """
    `yaz(satir)`: kayıt satırı. `is_parcacigi=False` yalnızca testlerde:
    yazım çağıranın içinde olur. `bos_alan(yol) -> bayt`: diskteki boş yer.
    """

    def __init__(self, klasor: str, *, yaz, is_parcacigi: bool = True, bos_alan=_bos_alan):
        self.klasor = klasor
        self._yaz, self._bos_alan = yaz, bos_alan
        self._tampon: deque[tuple[float, datetime, bytes]] = deque()
        self._son_tutulan = float("-inf")
        self._bekleyen: list[tuple[float, float, str]] = []
        self._kuyruk: queue.Queue | None = None
        if is_parcacigi:
            self._kuyruk = queue.Queue()
            threading.Thread(target=self._calis, name="klip", daemon=True).start()
        else:
            self._temizle()

    # ---- ana döngüden (tek iş parçacığı)

    @property
    def kare_sayisi(self) -> int:
        return len(self._tampon)

    def tampon_monolari(self) -> list[float]:
        return [m for m, _, _ in self._tampon]

    def kare(self, kirpik: np.ndarray, mono: float, zaman: datetime) -> None:
        if mono - self._son_tutulan >= KLIP_ARALIK_SN - 1e-6:
            self._son_tutulan = mono
            try:
                h, w = kirpik.shape[:2]
                k = KLIP_MAX_KENAR / max(h, w)
                kucuk = kirpik if k >= 1 else cv2.resize(
                    kirpik, (round(w * k), round(h * k)), interpolation=cv2.INTER_AREA)
                ok, jpeg = cv2.imencode(".jpg", kucuk, [cv2.IMWRITE_JPEG_QUALITY, KLIP_JPEG])
                if ok:
                    self._tampon.append((mono, zaman, jpeg.tobytes()))
            except Exception as e:  # noqa: BLE001 — kayıt aracı ana döngüyü düşürmez
                self._yaz(f"[!] klip karesi alınamadı: {type(e).__name__}")
        while self._tampon and mono - self._tampon[0][0] > KLIP_TAMPON_SN + 1e-6:
            self._tampon.popleft()
        self._teslim(lambda son: son <= mono)

    def iste(self, bas: float, son: float, ad: str) -> None:
        self._bekleyen.append((bas, son, ad))

    def bosalt(self, mono: float) -> None:
        """Kamera koptu: bekleyen her klip eldeki karelerle hemen yazılır."""
        self._teslim(lambda son: True)

    def _teslim(self, hazir) -> None:
        if not self._bekleyen:
            return
        kalan = []
        for bas, son, ad in self._bekleyen:
            if not hazir(son):
                kalan.append((bas, son, ad))
                continue
            kareler = [(m, z, b) for m, z, b in self._tampon if bas <= m <= son]
            if not kareler:
                continue
            if self._kuyruk is not None:
                self._kuyruk.put((ad, kareler))
            else:
                self._dosya_yaz(ad, kareler)
        self._bekleyen = kalan

    # ---- yazıcı

    def _calis(self) -> None:
        self._temizle()
        son_temizlik = time.monotonic()
        while True:
            try:
                ad, kareler = self._kuyruk.get(timeout=TEMIZLIK_SN)
                self._dosya_yaz(ad, kareler)
            except queue.Empty:
                pass
            if time.monotonic() - son_temizlik >= TEMIZLIK_SN:
                self._temizle()
                son_temizlik = time.monotonic()

    def _temizle(self) -> None:
        try:
            n = temizle(self.klasor, time.time())
            if n:
                self._yaz(f"[i] {n} eski klip silindi ({KLIP_GUN} gün / sınır)")
        except Exception as e:  # noqa: BLE001
            self._yaz(f"[!] klip temizliği yapılamadı: {type(e).__name__}")

    def _dosya_yaz(self, ad: str, kareler: list[tuple[float, datetime, bytes]]) -> None:
        try:
            if self._bos_alan(self.klasor) < KLIP_BOS_EN_AZ_BAYT:
                self._yaz(f"[!] klip yazılmadı: diskte yer az "
                          f"(<{KLIP_BOS_EN_AZ_BAYT // 1024 ** 3} GB) — {ad}")
                return
            os.makedirs(self.klasor, exist_ok=True)
            yol = os.path.join(self.klasor, ad)
            kok, uzanti = os.path.splitext(yol)
            n = 2
            while os.path.exists(yol):
                yol = f"{kok}_{n}{uzanti}"
                n += 1
            sure = kareler[-1][0] - kareler[0][0]
            fps = (len(kareler) - 1) / sure if sure > 0 else 1.0
            fps = min(max(fps, 1.0), 1.0 / KLIP_ARALIK_SN)
            ilk = cv2.imdecode(np.frombuffer(kareler[0][2], np.uint8), cv2.IMREAD_COLOR)
            boyut = (ilk.shape[1], ilk.shape[0])
            w = _video_ac(yol, fps, boyut)
            try:
                for _, z, b in kareler:
                    img = cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR)
                    if img is None:
                        continue
                    if (img.shape[1], img.shape[0]) != boyut:
                        img = cv2.resize(img, boyut, interpolation=cv2.INTER_AREA)
                    _saat_yaz(img, z)
                    w.write(img)
            finally:
                w.release()
            self._yaz(f"[i] {gunluk.KLIP_ISARETI}: {os.path.basename(yol)}")
        except Exception as e:  # noqa: BLE001 — kayıt aracı ana döngüyü düşürmez
            self._yaz(f"[!] klip yazılamadı ({ad}): {type(e).__name__}: {e}")
