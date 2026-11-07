"""
Kamera köprüsü — reads plates on this computer and sends them to kamera-webhook.

Runs on a computer at the car park, on the same LAN as the camera. Nothing
about it is trusted by the server: it authenticates with a shared secret and
can only reach the webhook, which can only record vehicles (entries, exits,
exception rows). It never touches the database, the tariffs or the till.

WHY A BRIDGE AT ALL: a plain IP camera cannot read plates, and the camera must
not be exposed to the internet. The camera talks only to this machine, and
only this machine talks out.

Pipeline (1.3.0, owner decision 2026-11-06):

    RTSP frame -> crop box (KIRPMA) with a grey cut-out (KIRPMA_HARIC) over
    parked cars -> motion starts a "pass" -> plaka.py finds plate boxes
    (YOLOv9, ONNX) and reads complete ones twice (fast-plate-ocr, ONNX) ->
    okuma.py votes across frames -> one decision per pass:
      * SURE plate        -> {plaka, zaman, photo}
      * unsure / no plate -> {okunamadi: true, photo}: the server writes an
                             exception row and staff decide ("Çözülmemiş
                             kayıtlar"). Never a guess, never a cloud read.
    -> written to the on-disk outbox (giden.py) FIRST, then sent; the file is
       deleted only on a definitive answer, so an internet outage loses no car.

WHAT THIS DELIBERATELY DOES NOT DO:

  * It does not send a photo for the server to read (`foto_base64`). The
    camera's own SMD events and the cloud reader were dropped in 1.3.0: tuning
    them cost more than they saved and photos were often taken at the wrong
    moment. The only photo sent is the compressed evidence copy.
  * It does not use YOLOv8 / Ultralytics (AGPL-3.0). The detector is
    open-image-models' YOLOv9 export (code MIT; the weights' licence is not
    stated — owner accepted the risk) and the reader's weights are MIT.
  * It does not log plate text: logs rotate by size only, so correlation is by
    `islem_id`.

The crop is still the accuracy lever: the plate must fill enough of it. Set
KIRPMA (and the cut-out) with the installer's crop page; check with `--plaka`.
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

import cv2
import numpy as np
import requests

import giden
import gunluk
import kesif
import okuma
import plaka

# Read by FFMPEG when a VideoCapture is CONSTRUCTED, so it has to be set before
# the first one exists. The default is UDP, which drops packets on a busy link
# and hands back torn frames — and half a plate costs the same as no plate.
# `setdefault` so an operator debugging a stubborn camera can still override it.
os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")

# Every message this bridge prints is Turkish, and the target machine is a
# Windows box at a car park. A console on cp1252 — the default outside Turkish
# Windows, and what a scheduled task gets when output is redirected to a file —
# cannot encode ı, ğ or ş, so the FIRST such print raises UnicodeEncodeError.
# That print is in main() and is not guarded, so the bridge would die on
# startup, in the one deployment we are actually planning for.
# `errors="replace"` because a mangled character is always better than a dead
# bridge.
for _akis in (sys.stdout, sys.stderr):
    if hasattr(_akis, "reconfigure"):
        _akis.reconfigure(encoding="utf-8", errors="replace")

# --------------------------------------------------------------- ayarlar ---

# Where the installer writes its config. One file per lane, because giriş and
# çıkış are two processes with two directions and must not share.
VARSAYILAN_AYAR = os.path.join(
    os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark", "kopru.json"
)


def _ayar_yolu() -> str:
    """
    `--ayar <yol>` beats OTOPARK_AYAR beats the default.

    argv rather than only an env var because Task Scheduler passes arguments
    cleanly but has no per-task environment, and two lanes on one PC need two
    different files.
    """
    if "--ayar" in sys.argv:
        i = sys.argv.index("--ayar")
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
        sys.exit("--ayar bir dosya yolu bekliyor")
    return os.environ.get("OTOPARK_AYAR", VARSAYILAN_AYAR)


# Ayar dosyası VARDI ama okunamadıysa sebebi burada durur. Bunsuz köprü
# "WEBHOOK_URL tanımlı olmalı" diye ölüyordu ve bu, insanı asıl sorundan
# (bozuk ya da BOM'lu dosya) tamamen başka bir yere gönderiyordu.
_AYAR_HATASI: str | None = None


def _ayarlari_yukle() -> None:
    """
    Fill os.environ from the JSON the installer wrote, then let the reads below
    work exactly as they always have.

    `setdefault`, so a real environment variable still wins: that keeps the
    documented manual/`baslat.ps1` setup working unchanged, and lets anyone
    override one value for a single run without editing the file.
    """
    global _AYAR_HATASI
    yol = _ayar_yolu()
    if not os.path.isfile(yol):
        return
    try:
        import json
        # utf-8-sig: Not Defteri UTF-8'i BOM ile kaydediyor ve düz "utf-8"
        # onu ayrıştıramıyor. KIRPMA ya da RTSP adresini elle düzeltmek
        # belgelenmiş bir iş; tek bir Kaydet, köprüyü sessizce öldürüyordu.
        # BOM yoksa bu kodlama düz utf-8 ile birebir aynı davranır.
        with open(yol, encoding="utf-8-sig") as f:
            veri = json.load(f)
    except Exception as e:
        _AYAR_HATASI = f"{yol}: {e}"
        # Not fatal: a corrupt config must not stop someone starting the bridge
        # by hand with environment variables to get the barrier working again.
        print(f"[!] ayar dosyası okunamadı ({yol}): {e}", flush=True)
        return
    if isinstance(veri, dict):
        for k, v in veri.items():
            if v is not None:
                os.environ.setdefault(str(k), str(v))


_ayarlari_yukle()

# `.get`, not `[...]`: these are read at IMPORT time, so `os.environ[...]`
# made `--kare` and `--test` — the two setup modes that never send anything —
# die with a raw KeyError traceback. That is the FIRST step the README tells
# you to run, before you would even have the webhook secret to hand. Each mode
# validates only what it actually uses, in kamera_ac() and main().
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")   # .../functions/v1/kamera-webhook
KAMERA_SECRET = os.environ.get("KAMERA_SECRET", "")  # KAMERA_WEBHOOK_SECRET ile aynı
RTSP_URL = os.environ.get("RTSP_URL", "")         # rtsp://user:pass@10.0.0.42:554/...
# GIRIS | CIKIS | ORTAK — bu kameranın şeridi (liste: gunluk.SERITLER).
# VARSAYILANI YOK: "GIRIS"e düşmek, YON'u unutulmuş bir çıkış köprüsünün giden
# araçlara bilet açması demekti. İçe aktarma boş değerle de çalışır (--kare /
# --test şerit istemez); eksik şeridi main() reddeder.
#
# ORTAK = tek kapı (giriş ve çıkış aynı yerden). Köprünün yaptığı iş AYNI:
# gördüğü aracı fotoğraflayıp gönderir. Giriş mi çıkış mı olduğuna sunucu
# bilet durumundan karar verir. Aynı aracın ikinci kez gönderilmesini (kadrajda
# bir şey kıpırdayıp durulunca olur — bkz. main'deki yeniden kurma bloğu) de
# orada, biletin açılış/kapanış anına bakarak yok sayar.
YON = os.environ.get("YON", "").strip().upper()
CIHAZ = os.environ.get("CIHAZ", "kopru-1")

# "x,y,w,h" in pixels of the full frame. Run `--kare` to save a frame and read
# the numbers off it, then `--test` to confirm the box really holds the plate.
# Empty = send the whole frame, which works but reads worse.
KIRPMA = os.environ.get("KIRPMA", "").strip()

# 1.3.0, L şekli: kutunun içinden KESİLEN tek bir dikdörtgen ("x,y,w,h", tam
# kare pikseli) — sahada park etmiş araçların köşesi. Orası düz griye boyanır:
# hareket, plaka ve saklanan fotoğraf için yok. Boş = kesilen köşe yok.
KIRPMA_HARIC = os.environ.get("KIRPMA_HARIC", "").strip()

# The crop is downscaled to this long edge before anything looks at it. 1.3.0:
# the plate finder sees the crop at 640 px (plaka.BULUCU_BOYUT), so this no
# longer follows a cloud model's limit; 1568 keeps motion thresholds measured
# by the installer valid and the stored photo the same size as before.
MAX_KENAR = int(os.environ.get("MAX_KENAR", "1568"))

# 1.2.3: the COMPRESSED copy of the same crop, stored by the server as the
# ticket / exception photo (042, `foto_kanit_base64`). The phone's model: the
# device compresses, the server only stores. Not settable from the
# environment on purpose — KANIT_EN_COK_BAYT is the SAME number as
# KANIT_FOTO_EN_COK_BAYT in supabase/functions/_shared/serit.ts, which drops a
# larger photo, so a bigger setting here would only lose photos silently.
# Measured 2026-10-28 on 4 MP-like scenes: plate crops 13–56 KB at the first
# quality; pure noise needs the step-down. Sent ONLY with a KIRPMA box (owner,
# KVKK): no box means the whole street view, so no photo at all.
KANIT_EN_COK_BAYT = 102_400
KANIT_MAX_KENAR = 1280
KANIT_KALITELER = (80, 70, 60, 50, 40)
KANIT_KUCULTME = 0.75
KANIT_TUR = 4

# Below this the crop is too small to read reliably — the vision docs name
# images under 200 px as a hallucination risk. Warned about at startup, not
# enforced, because a wrong warning must never stop a barrier working.
MIN_KENAR_UYARI = 200

# After a send the lane is DISARMED until the vehicle we photographed leaves —
# see the re-arm block in main(). A fixed 60s timer used to do this job and it
# silently ate cars: the cooldown outlived HAREKET_PENCERESI_SN (12s), so the
# NEXT car settled while sending was still blocked and was already outside the
# motion window by the time it lifted. Anything arriving ~5-49s behind another
# vehicle was dropped with no ticket and no istisnalar row to find later.
#
# MIN stops a flickering scene firing decision after decision. Kept SHORT on
# purpose: measured in 1.2.x, a 5s floor was long enough for the next vehicle
# to arrive, settle and leave again entirely unseen. The floor has to be
# shorter than a plausible dwell at the barrier.
#
# MAX is pure insurance: if scene-change detection ever wedged, the failure mode
# would be every subsequent car lost, so time forces a re-arm regardless.
# Re-arming while the same car is still there costs one call, refused by the
# one-open-ticket index.
MIN_BEKLEME_SN = float(os.environ.get("MIN_BEKLEME_SN", "2"))
MAX_BEKLEME_SN = float(os.environ.get("MAX_BEKLEME_SN", "120"))

# How different the crop must look from the frame we sent before we believe
# that vehicle has moved off. Same units as HAREKET_ESIGI: mean absolute pixel
# difference of the downscaled grey crop.
SAHNE_ESIGI = float(os.environ.get("SAHNE_ESIGI", "6.0"))

# Startup only: how long to wait between attempts to open a camera that is not
# answering yet, doubling up to the cap. See kamera_ac.
ACILIS_BEKLEME_SN = float(os.environ.get("ACILIS_BEKLEME_SN", "5"))
ACILIS_BEKLEME_MAX_SN = float(os.environ.get("ACILIS_BEKLEME_MAX_SN", "60"))

# Running: after the stream drops, the wait before reconnecting doubles from
# YENIDEN_BAGLAN_SN up to the cap and goes back to the base on the first good
# frame. It used to be a flat 3 s forever — and every reconnect is a camera
# LOGIN, so a camera whose password had changed got ~20 failed logins a
# minute. Dahua locks the account after five and the bridge kept it locked.
YENIDEN_BAGLAN_SN = float(os.environ.get("YENIDEN_BAGLAN_SN", "3"))
YENIDEN_BAGLAN_MAX_SN = float(os.environ.get("YENIDEN_BAGLAN_MAX_SN", "60"))

# Before each (re)connect the bridge asks the camera ONE question: does it
# accept the stored password (kesif.kimlik_dogrula, one authenticated RTSP
# DESCRIBE on our own stream path)? If not, the stream is not opened at all
# and this long wait follows — at most one failed login per wait. NOT a
# permanent stop: a lockout caused by someone else answers the same way, and
# the lane must come back by itself once it ends. Keep it under durum's
# 15-minute staleness limit: each wait writes one log line.
SIFRE_RED_BEKLEME_SN = float(os.environ.get("SIFRE_RED_BEKLEME_SN", "600"))

# Watchdog (1.2.4). A process that is alive but no longer looping — a read
# blocked past FFmpeg's own timeout, a deadlock — used to sit there forever:
# Task Scheduler sees it running and IgnoreNew refuses a fresh copy. If the
# capture loop has not moved for BEKCI_SN, the process exits and the task's
# one-minute repetition starts a new one. Legitimate long waits (reconnect,
# the 10-minute password wait) go through uyu(), which keeps stamping, so the
# limit only has to beat a genuinely stuck call — FFmpeg gives up on a dead
# socket in ~30 s, 15 minutes is far beyond any honest stall.
BEKCI_SN = max(float(os.environ.get("BEKCI_SN", "900")), 0.3)
BEKCI_ARALIK_SN = min(30.0, BEKCI_SN / 3)

# Motion, as mean absolute pixel difference between consecutive crops.
# Above HAREKET_ESIGI something is moving; below DURGUN_ESIGI the scene is
# still. Both are scene-dependent — `--test` prints live values so they can be
# set by looking rather than guessing.
HAREKET_ESIGI = float(os.environ.get("HAREKET_ESIGI", "6.0"))
DURGUN_ESIGI = float(os.environ.get("DURGUN_ESIGI", "2.0"))

# Consecutive still frames before we believe the car has actually stopped.
DURGUN_KARE = int(os.environ.get("DURGUN_KARE", "5"))

# Motion older than this is a car that already left, not one still arriving.
HAREKET_PENCERESI_SN = float(os.environ.get("HAREKET_PENCERESI_SN", "12"))

# Güvenlik ağı: araç gitti ama sahne hiç DURULMUYOR (yağmur, gece kumlanması,
# sallanan ağaç) — "durdu" anı hiç gelmez. Açık bir geçiş varsa, bu kadar
# süre güçlü hareket olmadıysa VE sahne geçişten önceki hâline döndüyse yine
# karara bağlanır. "Döndüyse" şartı bilerek: duran, sonra gürültülü havada giden bir
# araçta tutulan kare GİDEN aracın karesidir — gönderilseydi tek kapıda girişin
# hemen ardından sahte bir "çıkış" olurdu.
GECIS_BEKLE_SN = float(os.environ.get("GECIS_BEKLE_SN", "2"))

# Araç boyu: bir geçiş boyunca kırpık, geçişten önceki hâlinden en az bu
# kadar (fark ölçüsü) değiştiyse geçiş araç boyutundadır. Duran ama plakası
# görülmeyen araç ve bozuk okuyucuda personele gidecek geçişler bununla
# ayrılır — yaya ve gölge personeli boğmaz.
ARAC_KAPSAM_ESIGI = float(os.environ.get("ARAC_KAPSAM_ESIGI", "15"))

# 1.3.0: plaka okuyucunun TEK bir karesi bu kadar sürerse okuyucu takılmıştır
# (model, sürücü) — bekçi gibi süreç kapatılır, Görev Zamanlayıcı yeniden açar.
OKUYUCU_TAKILMA_SN = 30.0

# The watchdog marks a camera dead if it has not heard anything. A quiet night
# is not a fault, so ping on a timer as well as on events.
KALP_ARALIGI_SN = 300


# ---------------------------------------------------------------- görüntü ---


def kutu_metni_coz(metin: str) -> tuple[int, int, int, int] | None:
    """
    KIRPMA metni → (x, y, w, h), boşsa None; bozuksa ValueError (Türkçe).

    Köprü (kirpma_kutusu) ile `--plaka` test kipi bunu paylaşır.
    """
    metin = (metin or "").strip()
    if not metin:
        return None
    try:
        x, y, w, h = (int(p) for p in metin.split(","))
    except ValueError:
        raise ValueError('KIRPMA "x,y,w,h" biçiminde olmalı (piksel), örn. "820,540,600,220"')
    if w <= 0 or h <= 0:
        raise ValueError("KIRPMA genişlik ve yükseklik pozitif olmalı")
    return x, y, w, h


def haric_metni_coz(metin: str, kutu) -> tuple[tuple[int, int, int, int] | None, str | None]:
    """
    KIRPMA_HARIC metni → (hariç alan ya da None, uyarı ya da None).

    Bozuk biçim ve kutunun TAMAMINI kaplayan alan ValueError — köprü hiçbir
    şey göremezdi. Kutu yoksa ya da alan kutunun dışındaysa yok sayılır, bir
    uyarıyla. Kurallar kırpma sayfasınınkiyle aynı (kirpma_sunucu._kutu_coz).
    """
    metin = (metin or "").strip()
    if not metin:
        return None, None
    if kutu is None:
        return None, "KIRPMA_HARIC verildi ama KIRPMA yok — kesilen köşe yok sayılıyor"
    try:
        x, y, w, h = (int(p) for p in metin.split(","))
    except ValueError:
        raise ValueError('KIRPMA_HARIC "x,y,w,h" biçiminde olmalı (piksel), örn. "0,0,500,200"')
    if w <= 0 or h <= 0:
        raise ValueError("KIRPMA_HARIC genişlik ve yükseklik pozitif olmalı")
    kx, ky, kw, kh = kutu
    if x >= kx + kw or y >= ky + kh or x + w <= kx or y + h <= ky:
        return None, "KIRPMA_HARIC kırpma kutusunun dışında — kesilen köşe yok sayılıyor"
    if x <= kx and y <= ky and x + w >= kx + kw and y + h >= ky + kh:
        raise ValueError("KIRPMA_HARIC kırpma kutusunun tamamını kaplıyor — köprü hiçbir şey göremezdi")
    return (x, y, w, h), None


def kirpma_kutusu() -> tuple[int, int, int, int] | None:
    try:
        return kutu_metni_coz(KIRPMA)
    except ValueError as e:
        sys.exit(str(e))


def kirp(frame: np.ndarray, kutu: tuple[int, int, int, int] | None) -> np.ndarray:
    if kutu is None:
        return frame
    x, y, w, h = kutu
    # Clamped rather than validated against the frame: a camera that changes
    # resolution after a firmware update should degrade to a smaller crop, not
    # crash at 3am.
    yh, yw = frame.shape[:2]
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    x1, y1 = max(x0 + 1, min(x + w, yw)), max(y0 + 1, min(y + h, yh))
    return frame[y0:y1, x0:x1]


def kirpma_haric(kutu: tuple[int, int, int, int] | None) -> tuple[int, int, int, int] | None:
    """KIRPMA_HARIC → (x, y, w, h) tam kare pikseli, ya da None."""
    try:
        haric, uyari = haric_metni_coz(KIRPMA_HARIC, kutu)
    except ValueError as e:
        sys.exit(str(e))
    if uyari:
        print(f"[!] {uyari}", flush=True)
    return haric


def _haric_kirpintida(frame_sekli: tuple, kutu, haric) -> tuple[int, int, int, int] | None:
    """Kesilen köşe, kırpıntının (ölçeklenmeden önce) kendi koordinatlarında."""
    if haric is None or kutu is None:
        return None
    yh, yw = frame_sekli[:2]
    x, y, w, h = kutu
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    x1, y1 = max(x0 + 1, min(x + w, yw)), max(y0 + 1, min(y + h, yh))
    hx, hy, hw, hh = haric
    a0, b0 = max(hx - x0, 0), max(hy - y0, 0)
    a1, b1 = min(hx + hw - x0, x1 - x0), min(hy + hh - y0, y1 - y0)
    if a1 <= a0 or b1 <= b0:
        return None
    return a0, b0, a1 - a0, b1 - b0


def kirp_maskeli(frame: np.ndarray, kutu, haric) -> np.ndarray:
    """
    kirp() + kesilen köşe düz griye (114) boyanır. Kesilen köşe varsa KOPYA
    döner (kirp bir görünüm verir; kameranın karesi değişmemeli), yoksa
    kirp()'in kendisi — davranış 1.2.x ile birebir.
    """
    parca = kirp(frame, kutu)
    h = _haric_kirpintida(frame.shape, kutu, haric)
    if h is None:
        return parca
    parca = parca.copy()
    a, b, w, hh = h
    parca[b:b + hh, a:a + w] = 114
    return parca


def haric_olcekli(frame_sekli: tuple, kutu, haric, kirpik_sekli: tuple):
    """Kesilen köşe, ölçeklenmiş kırpıntının (kirpik) koordinatlarında — okuyucu için."""
    h = _haric_kirpintida(frame_sekli, kutu, haric)
    if h is None:
        return None
    yh, yw = frame_sekli[:2]
    x, y, w, hh_ = kutu
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    cw = max(x0 + 1, min(x + w, yw)) - x0
    ch = max(y0 + 1, min(y + hh_, yh)) - y0
    sx, sy = kirpik_sekli[1] / cw, kirpik_sekli[0] / ch
    a, b, ww, hh = h
    return a * sx, b * sy, ww * sx, hh * sy


def olcekle(img: np.ndarray) -> np.ndarray:
    yh, yw = img.shape[:2]
    uzun = max(yh, yw)
    if uzun <= MAX_KENAR:
        return img
    k = MAX_KENAR / uzun
    return cv2.resize(img, (int(yw * k), int(yh * k)), interpolation=cv2.INTER_AREA)


def kanit_base64(img: np.ndarray | None) -> str | None:
    """
    The stored photo: at most KANIT_MAX_KENAR px and KANIT_EN_COK_BAYT bytes.
    Each quality in turn, then shrink by KANIT_KUCULTME and try again, at most
    KANIT_TUR rounds. None when nothing fits or encoding fails — NEVER raises:
    a missing photo must not cost the car its ticket. `img` is not modified
    (the same crop also makes the reading copy).
    """
    try:
        if img is None:
            return None
        yh, yw = img.shape[:2]
        k = min(1.0, KANIT_MAX_KENAR / max(yh, yw))
        for _ in range(KANIT_TUR):
            w, h = max(1, int(yw * k)), max(1, int(yh * k))
            kopya = img if (w, h) == (yw, yh) else cv2.resize(
                img, (w, h), interpolation=cv2.INTER_AREA)
            for kalite in KANIT_KALITELER:
                ok, buf = cv2.imencode(".jpg", kopya, [int(cv2.IMWRITE_JPEG_QUALITY), kalite])
                if ok and buf is not None and len(buf) <= KANIT_EN_COK_BAYT:
                    return base64.b64encode(buf.tobytes()).decode("ascii")
            k *= KANIT_KUCULTME
    except Exception:
        pass
    return None


def fark(a: np.ndarray, b: np.ndarray) -> float:
    """Mean absolute difference of two crops, as a rough motion measure."""
    if a is None or b is None or a.shape != b.shape:
        return 0.0
    return float(np.mean(cv2.absdiff(a, b)))


def gri_kucuk(img: np.ndarray) -> np.ndarray:
    """Downscaled grayscale — motion detection needs neither colour nor detail."""
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return cv2.resize(g, (160, 120), interpolation=cv2.INTER_AREA)


def _arkaya_dondu(gri: np.ndarray, gecis_arka: np.ndarray | None) -> bool:
    """
    Has the scene gone back to how it looked before THIS pass began? True means
    the vehicle came and LEFT without stopping: the pass is decided as a
    rolling car, not a stopped one.

    Deliberately compared with THIS pass's start, never with some "empty lane"
    picture. A car that STOPPED, was sent, and then drives off can re-arm the
    bridge mid-departure: that pass starts from the stopped car. When the lane
    empties it no longer looks like that start, so the pass is not mistaken
    for a new car that came and went (1.2.x lesson: a second send of the
    departing car is an exit right after the entry at a single gate).
    """
    return gecis_arka is not None and fark(gri, gecis_arka) <= SAHNE_ESIGI


_gonderim_sayaci = 0


# --------------------------------------------------------------- gönderim ---


# Tries of the in-memory fallback (_yedek_gonder: the outbox could not be
# written), all with the same islem_id — replay-safe on the server.
DENEME_SAYISI = 4


# ------------------------------------------------- 1.3.0 gönderim (kutu) ---

# main() kurar; testlerde ve kurulum kiplerinde None.
_giden: giden.Giden | None = None
_isci: okuma.Isci | None = None


def olay_govdesi(g: okuma.Gonderim, kutu) -> dict:
    """
    Bir araç olayının gövdesi — kutuya YAZILAN ve her denemede AYNEN giden.
    islem_id bir kez üretilir (sunucu aynı kimliğe ilk cevabını verir).
    Okunacak fotoğraf (foto_base64) YOK: 1.3.0 plakayı burada okur, sunucu
    okutmaz. Saklanan fotoğraf yalnızca kırpma kutusu varsa (KVKK, 1.2.3).
    """
    govde = {
        "yon": YON,
        "zaman": g.zaman.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "islem_id": str(uuid.uuid4()),
        "cihaz": CIHAZ,
    }
    if g.tur == "PLAKA":
        govde["plaka"] = g.plaka
    else:
        govde["okunamadi"] = True
        if g.tahmin:
            govde["tahmin"] = g.tahmin
        if g.guven is not None:
            govde["guven"] = round(float(g.guven), 4)
    if kutu is not None and g.kirpik is not None:
        kanit = kanit_base64(g.kirpik)
        if kanit is not None:
            govde["foto_kanit_base64"] = kanit
    return govde


# Kayda plaka YAZILMAZ (1.3.0): kayıt yalnızca boyutla döner. Sunucunun ret
# mesajı plakayı içerebilir ("… açık bir bilet var: 34ABC123"); harf ve rakamı
# birlikte taşıyan her sözcük ve boşluklu plaka biçimi maskelenir.
_PLAKA_GIBI = re.compile(
    r"\b\d{2}\s+[A-Za-zÇĞİÖŞÜçğıöşü]{1,3}\s+\d{2,5}\b"
    r"|\b(?=\w*\d)(?=\w*[A-Za-zÇĞİÖŞÜçğıöşü])\w{4,}\b")


def _plakasiz(metin: str) -> str:
    return _PLAKA_GIBI.sub("•••", metin)


def _karar_metni(govde_metni: str) -> str:
    try:
        v = json.loads(govde_metni)
        return f"{v.get('karar') or ''} {v.get('sebep') or ''}".strip()
    except (ValueError, AttributeError):
        return ""


def gonder_olay(govde: dict) -> str:
    """
    TEK bir POST: giden.TAMAM / RED / TEKRAR. Yeniden deneme kutunun işi
    (giden.calistir) — araç kesin cevaba kadar diskte kalır. Kayda plaka
    YAZILMAZ: islem_id ve sunucunun kararı yeter.
    """
    kimlik = str(govde.get("islem_id", ""))[:8]
    try:
        r = requests.post(WEBHOOK_URL, json=govde,
                          headers={"x-kamera-secret": KAMERA_SECRET}, timeout=30)
    except requests.RequestException as e:
        print(f"[!] {gunluk.AG_HATASI_ISARETI}: {e}", flush=True)
        _ag_gitti()
        return giden.TEKRAR
    _ag_geldi()
    metin = getattr(r, "text", "") or ""
    ret_kaydet(r.status_code, metin)
    if r.status_code < 300:
        print(f"[+] gönderildi -> {kimlik} {_karar_metni(metin)}".rstrip(), flush=True)
        return giden.TAMAM
    if r.status_code == 422 and govde.get("okunamadi"):
        try:
            istisna = json.loads(metin).get("istisna") is True
        except (ValueError, AttributeError):
            istisna = False
        if istisna:
            print(f"[+] gönderildi -> {kimlik} {gunluk.PERSONELE_ISARETI}", flush=True)
            return giden.TAMAM
        print(f"[!] {gunluk.ESKI_SUNUCU_ISARETI} ({kimlik}) — kamera-webhook güncel değil; "
              "bu araç elle girilmeli", flush=True)
        return giden.RED
    if r.status_code == 429:
        print("[!] hız sınırı (429), tekrar denenecek", flush=True)
        return giden.TEKRAR
    if r.status_code in (401, 403):
        # ret_kaydet söyledi; araç KUTUDA kalır, kamera yeniden açılınca gider.
        return giden.TEKRAR
    if 400 <= r.status_code < 500:
        print(f"[!] reddedildi {r.status_code} ({kimlik}): {_plakasiz(metin)[:120]}", flush=True)
        return giden.RED
    print(f"[!] sunucu {r.status_code}, tekrar denenecek", flush=True)
    return giden.TEKRAR


def _yedek_gonder(govde: dict) -> None:
    """Kutuya yazılamadıysa (disk): 1.2.x gibi bellekten, sınırlı deneme."""
    for deneme in range(DENEME_SAYISI):
        if gonder_olay(govde) != giden.TEKRAR:
            return
        time.sleep(2 ** deneme)
    print("[!] gönderilemedi — araç elle girilmeli", flush=True)


def araci_gonder(g: okuma.Gonderim, kutu) -> None:
    """Kararı kutuya yazar (gönderici iş parçacığı yollar)."""
    global _gonderim_sayaci
    if g.tur == "OKUNAMADI" and YON == "CIKIS":
        print(f"[i] {gunluk.CIKIS_OKUNAMADI_ISARETI} — sunucuya gönderilmedi, "
              "personel kapıda görür", flush=True)
        return
    _gonderim_sayaci += 1
    govde = olay_govdesi(g, kutu)
    if _giden is None or _giden.yaz(govde) is None:
        threading.Thread(target=_yedek_gonder, args=(govde,), daemon=True).start()


def kalp() -> None:
    """
    Keepalive.

    The webhook bumps the heartbeat for any request that clears the secret,
    BEFORE it parses the body — so an empty POST is a valid ping. It answers
    400 and that is the expected result, not an error.

    Runs on its own short-lived thread (see main): it used to run on the
    capture thread, and a slow answer froze the camera for up to 20 s — long
    enough for a car to arrive, stop and go unseen.
    """
    global _sunucu_dogrulandi
    try:
        r = requests.post(
            WEBHOOK_URL, json={}, headers={"x-kamera-secret": KAMERA_SECRET}, timeout=10
        )
    except requests.RequestException as e:
        # Swallowed so a dead link never kills the capture loop, but LOGGED:
        # from here a silently failing ping looks exactly like a healthy
        # bridge, and whoever is reading this console is the only one who can
        # tell the difference.
        print(f"[!] {gunluk.KALP_YOK_ISARETI}: {e}", flush=True)
        _ag_gitti()
        return
    _ag_geldi()
    kod = getattr(r, "status_code", None)
    ret_kaydet(kod, getattr(r, "text", "") or "")
    # Said ONCE, the first time the server accepts this bridge: the installer
    # waits for this line before it calls the setup finished (1.2.1). Before,
    # it declared success two seconds after the camera connected, and a
    # refusal arriving later went unseen.
    if (not _sunucu_dogrulandi and kod is not None and kod not in (401, 403)
            and (kod < 300 or kod in _KIMLIK_SONRASI)):
        _sunucu_dogrulandi = True
        print(f"[i] {gunluk.SUNUCU_TAMAM_ISARETI}", flush=True)
    saat_kontrol(r)


# Whether the server has accepted a heartbeat since start (one log line).
_sunucu_dogrulandi = False

# 1.2.4. True from a request that never reached the server (no Wi-Fi, no DNS,
# timeout) until the next one that got ANY answer. The return is logged once
# (gunluk.AG_DONDU_ISARETI): without it the last network word in the log
# stayed the failure and `durum` could not tell a past outage from a current
# one. Both the heartbeat thread and the sender call these, hence the lock —
# exactly one "back" line per outage.
_ag_yok = False
_ag_kilit = threading.Lock()


def _ag_gitti() -> None:
    global _ag_yok
    with _ag_kilit:
        _ag_yok = True


def _ag_geldi() -> None:
    global _ag_yok
    with _ag_kilit:
        if not _ag_yok:
            return
        _ag_yok = False
    print(f"[i] {gunluk.AG_DONDU_ISARETI}", flush=True)
    # 1.3.0: kutuda bekleyen araçlar beklemeden gitsin.
    if _giden is not None:
        _giden.uyandir()


# Monotonic time of the last clock warning: at most one an hour.
_son_saat_uyarisi: float | None = None


def saat_kontrol(r) -> None:
    """
    Compare this PC's clock with the server's `Date` header.

    Every vehicle is stamped with THIS clock and billed from that stamp. More
    than five minutes fast and every entry becomes a "future" exception
    instead of a ticket; slow, and every stay is billed long. Logged with `[!]`
    so `durum` shows it as the last warning; at most once an hour.
    """
    global _son_saat_uyarisi
    fark = gunluk.saat_farki((getattr(r, "headers", None) or {}).get("Date"), time.time())
    if fark is None or abs(fark) <= gunluk.SAAT_TOLERANS_SN:
        return
    simdi = time.monotonic()
    if _son_saat_uyarisi is not None and simdi - _son_saat_uyarisi < 3600:
        return
    _son_saat_uyarisi = simdi
    print(f"[!] {gunluk.SAAT_ISARETI}: {gunluk.saat_farki_metni(fark)} — Windows "
          "saatini otomatik ayarlayın, yoksa araçlar yanlış ücretlendirilir", flush=True)


# Whether the server's last answer was a refusal of this bridge itself. Only
# ever touched through ret_kaydet, from the heartbeat thread (kalp) and the
# sender thread (gonder); the worst a race can do is print one line twice.
_reddedildi = False

# Status codes kamera-webhook returns only once the credential has cleared:
# bad body, lane/ticket conflict, body too large, unreadable plate, rate limit.
_KIMLIK_SONRASI = (400, 409, 413, 422, 429)


def ret_kaydet(kod: int | None, govde: str = "") -> None:
    """
    Turn "the server refuses THIS BRIDGE" into a line `durum` can find.

    Nothing used to look at the heartbeat's status. A camera removed or
    disabled in the app keeps a running bridge whose every request answers
    401, and it logged nothing — the log stayed fresh, so `durum` reported
    ÇALIŞIYOR while every vehicle was being refused.

      401  the credential is not accepted (camera removed or disabled)
      403  the credential is fine, camera input is switched off in the app
      an answer the webhook only gives AFTER accepting the credential means
      the refusal is over, and says so ONCE — otherwise `durum` would stay
      stuck on the old refusal. A 5xx or a 404 proves nothing either way.

    One more refusal is told apart by its BODY, not its status: 409 with
    `SERIT_UYUSMAZ` means this camera is paired to the other lane in the app
    (kamera-webhook, _shared/serit.ts). A plain 409 is ordinary business — a
    second ticket for a plate already inside — and must not mark the bridge
    unhealthy. Not folded into `_reddedildi`: only vehicle sends carry a lane,
    so a heartbeat's 400 says nothing about whether the lane is right, and the
    marker is cleared by the next accepted send instead (see durum.py).

    The texts are constants in gunluk because durum.py searches for them.
    """
    global _reddedildi
    if kod == 409 and "SERIT_UYUSMAZ" in govde:
        print(f"[!] {gunluk.SERIT_ISARETI} (409) — bu kamera uygulamada öbür şeride "
              "eşleştirilmiş; kamerayı kaldırıp doğru şeritle yeniden kurun", flush=True)
        return
    if kod == 401:
        _reddedildi = True
        print(f"[!] {gunluk.RED_ISARETI} (401) — kamera uygulamadan kaldırılmış ya da "
              "devre dışı bırakılmış olabilir", flush=True)
    elif kod == 403:
        _reddedildi = True
        print(f"[!] {gunluk.KAPALI_ISARETI} (403) — uygulamada Otopark Ayarları → "
              "kamera girişini açın", flush=True)
    elif _reddedildi and kod is not None and (kod < 300 or kod in _KIMLIK_SONRASI):
        _reddedildi = False
        print(f"[i] {gunluk.KABUL_ISARETI}", flush=True)


# ------------------------------------------------------------------- bekçi ---

# Monotonic time the capture side last proved it is moving (see BEKCI_SN).
_son_canli = time.monotonic()


def canli() -> None:
    """The capture loop is moving. Called every frame and by uyu()."""
    global _son_canli
    _son_canli = time.monotonic()


def uyu(saniye: float) -> None:
    """
    time.sleep for the bridge's own waits — in slices, stamping liveness on
    each, so a legitimate long wait (the 10-minute password wait) never looks
    stuck to the watchdog.
    """
    bitis = time.monotonic() + saniye
    while True:
        canli()
        kalan = bitis - time.monotonic()
        if kalan <= 0:
            return
        time.sleep(min(kalan, BEKCI_ARALIK_SN))


def bekci_karari(simdi: float, son_canli: float, son_kontrol: float,
                 esik: float, aralik: float) -> str:
    """
    "tamam" | "uyandi" | "takildi". Pure, so it is tested without a camera.

    "uyandi" comes FIRST: if the watchdog itself woke far later than its own
    interval, the whole machine was asleep (lid, hibernate) or starved, and the
    capture loop could not have stamped either. Killing a sound bridge on
    resume would be a false alarm — the window starts again instead. Whether
    Windows' monotonic clock counts sleep does not matter: either way this
    check, or the loop's own first frame, resets the window.
    """
    if simdi - son_kontrol > 3 * aralik:
        return "uyandi"
    if simdi - son_canli > esik:
        return "takildi"
    return "tamam"


def _bekci_cik() -> None:
    # os._exit, not sys.exit: this runs on the watchdog thread, and the stuck
    # main thread is exactly what a normal shutdown would wait on. The log
    # line is already on disk (gunluk flushes every write). Replaced in tests.
    os._exit(3)


def bekci() -> None:
    """Watchdog thread (1.2.4): exits the process if the capture loop is stuck."""
    global _son_canli
    son_kontrol = time.monotonic()
    while True:
        time.sleep(BEKCI_ARALIK_SN)
        simdi = time.monotonic()
        karar = bekci_karari(simdi, _son_canli, son_kontrol, BEKCI_SN, BEKCI_ARALIK_SN)
        son_kontrol = simdi
        if karar == "uyandi":
            _son_canli = simdi
            print("[i] bekçi geç uyandı (bilgisayar uykudaydı ya da çok yoğundu) — "
                  "süre yeniden başladı", flush=True)
        elif karar == "takildi":
            print(f"[!] {gunluk.TAKILDI_ISARETI} — yakalama {_sure(simdi - _son_canli)} "
                  "ilerlemedi; süreç kapanıyor, görev yeniden başlatacak", flush=True)
            _bekci_cik()


# ------------------------------------------------------------------ kurulum ---


def kamera_baglan(url: str | None = None) -> cv2.VideoCapture:
    """
    The ONE place a capture is constructed — for the bridge AND for the
    installer's crop page (kirpma_sunucu._kamera), so both reach the camera
    the same way.

    main()'s reconnect used to build its own `cv2.VideoCapture(RTSP_URL)`, so
    anything configured here was silently dropped the first time the stream
    did — and a stream that just dropped is precisely when the settings matter.
    Non-fatal on purpose: exiting is right at startup and wrong at 03:00, so
    the caller decides which it is.
    """
    # TCP is set HERE as well as at import: the installer's camera scan puts
    # the variable back the way it found it, so in the installer process the
    # import-time default may already be gone when the crop page connects.
    # FFMPEG reads it when the capture is constructed. `setdefault`, as above.
    os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")
    cap = cv2.VideoCapture(url or RTSP_URL)
    # Keep only the newest frame. Without this OpenCV hands back whatever
    # queued up while we were busy, so the frame we judged "settled" can be
    # seconds stale — the wrong moment, and blurrier than the one we wanted.
    # Not every backend honours it; setting it costs nothing where ignored.
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return cap


def _sure(saniye: float) -> str:
    return f"{saniye / 60:.0f} dakika" if saniye >= 60 else f"{saniye:.0f} sn"


def kamera_sifresi_kontrol(url: str | None = None) -> str:
    """
    Does the camera accept the password in our RTSP address? "tamam" |
    "yanlis" | "bilinmiyor".

    Asked on our OWN stream path, with the credentials decoded (the installer
    stores them percent-encoded). No credentials in the address → nothing to
    check and no network at all: answering a challenge with empty credentials
    would itself be a failed login. Any error → "bilinmiyor", which means
    "connect the way we always did" — this check must never kill the bridge.
    """
    parca = kesif.rtsp_parcala(url or RTSP_URL)
    if parca is None:
        return "bilinmiyor"
    ip, port, kullanici, sifre, yol = parca
    try:
        return kesif.kimlik_dogrula(ip, port, kullanici, sifre, yol=yol)
    except Exception:
        return "bilinmiyor"


def sifre_kabul_edilene_kadar_bekle() -> None:
    """
    Blocks while the camera rejects our password: one check, then a long
    wait, never an open (see SIFRE_RED_BEKLEME_SN). Logged on every round so
    `durum` shows the reason and the log stays fresh.
    """
    while kamera_sifresi_kontrol() == "yanlis":
        print(f"[!] {gunluk.SIFRE_RED_ISARETI} — {_sure(SIFRE_RED_BEKLEME_SN)} sonra "
              "yeniden denenecek. Kameranın şifresi değiştiyse programı açıp "
              "'Yeniden kur' deyin.", flush=True)
        uyu(SIFRE_RED_BEKLEME_SN)


def kamera_ac(bekle: bool = False) -> cv2.VideoCapture:
    """
    Startup path.

    `bekle=False` (the setup modes --kare / --test): a camera that will
    not open is fatal, because someone is sitting in front of the screen and
    needs the answer now.

    `bekle=True` (the bridge itself): keep trying. After a power cut the PC is
    up long before the camera or the switch, and this process is started ONCE
    per boot — exiting here left the lane dark until somebody rebooted the PC.
    No heartbeat is sent while waiting (the caller has not reached its loop):
    a camera that is not there must stay visible to the server watchdog.

    A missing RTSP_URL is fatal either way; waiting cannot fix a config.

    While waiting, every attempt is preceded by the password check: a bridge
    started at boot with a changed camera password must not lock the account
    (1.2.2). The setup modes skip it — one attempt, then they exit anyway.
    """
    if not RTSP_URL:
        sys.exit("RTSP_URL tanımlı değil — kameranın RTSP adresini verin.")
    bekleme = ACILIS_BEKLEME_SN
    while True:
        if bekle:
            sifre_kabul_edilene_kadar_bekle()
        cap = kamera_baglan()
        if cap.isOpened():
            return cap
        cap.release()
        # Adres şifre taşıyor. Kayıt süzgeci bunu zaten yakalıyor ama mesaj
        # konsola da gidiyor ve sebebi burada görünmeli.
        if not bekle:
            sys.exit(f"{gunluk.KAMERA_YOK_ISARETI}: {gunluk.gizle(RTSP_URL)}")
        print(f"[!] {gunluk.KAMERA_YOK_ISARETI}: {gunluk.gizle(RTSP_URL)} — "
              f"{bekleme:.0f} sn sonra tekrar denenecek", flush=True)
        uyu(bekleme)
        bekleme = min(bekleme * 2, ACILIS_BEKLEME_MAX_SN)


def kare_kaydet() -> None:
    """`--kare`: save one full frame so the crop box can be measured off it."""
    cap = kamera_ac()
    ok, frame = cap.read()
    cap.release()
    if not ok:
        sys.exit("kare alınamadı")
    cv2.imwrite("kare.jpg", frame)
    yh, yw = frame.shape[:2]
    print(f"kare.jpg yazıldı — {yw}x{yh} piksel", flush=True)
    print("Plakanın bulunduğu dikdörtgeni ölçün ve KIRPMA=\"x,y,w,h\" olarak verin.")


def kirpma_test() -> None:
    """`--test`: save the cropped region and print live motion values."""
    kutu = kirpma_kutusu()
    # 1.3.0: hariç alan köprüdeki gibi griye boyanır — kaydedilen kırpık ve
    # hareket değerleri köprünün gördüğüyle aynı olsun.
    haric = kirpma_haric(kutu)
    cap = kamera_ac()
    onceki = None
    # Bir bayrakla, `i == 0` ile DEĞİL: ilk kare düşerse (RTSP'de bağlandıktan
    # hemen sonra sık olur) `continue` yazma adımını atlar ve i bir daha 0
    # olmadığı için kirpik.jpg hiç yazılmazdı — yani modun tek amacı sessizce
    # gerçekleşmezdi.
    yazildi = False
    print("Ctrl+C ile çıkın. hareket = ardışık kareler arası fark.", flush=True)
    try:
        for i in range(600):
            ok, frame = cap.read()
            if not ok:
                continue
            k = olcekle(kirp_maskeli(frame, kutu, haric))
            if not yazildi:
                yazildi = True
                cv2.imwrite("kirpik.jpg", k)
                yh, yw = k.shape[:2]
                print(f"kirpik.jpg yazıldı — {yw}x{yh} piksel", flush=True)
                if max(yh, yw) < MIN_KENAR_UYARI:
                    print(
                        f"[!] kırpma {MIN_KENAR_UYARI}px altında — okuma güvenilmez olur",
                        flush=True,
                    )
            g = gri_kucuk(k)
            print(f"hareket={fark(onceki, g):6.2f}", flush=True)
            onceki = g
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    cap.release()


PLAKA_TEST_SN = 120.0
PLAKA_TEST_SESSIZ_SN = 10.0     # plaka yokken bu aralıkla "plaka yok" satırı


def plaka_testi(ayar_yolu: str, sure_sn: float = PLAKA_TEST_SN, *, ara_sn: float = 0.3,
                en_cok_kare: int | None = None, kamera=None) -> int:
    """
    `OtoparkKamera.exe --plaka` (1.3.0): şeridin kamerasında plaka bulma ve
    okumayı canlı gösterir — kurulum günü, gündüz ve gece, araç geçirerek.

    Köprünün KENDİ adımlarını kullanır (kirp_maskeli, olcekle,
    okuma.kutulari_bul, okuma.kutuyu_oku): burada EMİN görünen okuma köprüde
    de emin sayılır. Hiçbir şey göndermez, hiçbir dosya yazmaz, günlük açmaz
    (gunluk.baslat çağrılmaz) — köprü çalışırken de güvenle koşar. Plaka
    metni yalnızca bu ekrana yazılır, hiçbir kayda geçmez.

    0: en az bir emin okuma · 1: çalıştırılamadı · 2: bu sürede emin okuma yok.
    """
    import json
    from urllib.parse import urlparse

    try:
        with open(ayar_yolu, encoding="utf-8-sig") as f:
            ayar = json.load(f)
    except (OSError, ValueError) as e:
        print(f"  ✗ Ayar dosyası okunamadı ({ayar_yolu}): {e}")
        return 1
    if not isinstance(ayar, dict):
        print(f"  ✗ Ayar dosyası bozuk ({ayar_yolu}).")
        return 1
    try:
        kutu = kutu_metni_coz(str(ayar.get("KIRPMA") or ""))
        haric, uyari = haric_metni_coz(str(ayar.get("KIRPMA_HARIC") or ""), kutu)
    except ValueError as e:
        print(f"  ✗ Ayar dosyasında hatalı kırpma: {e}")
        return 1
    if uyari:
        print(f"  ! {uyari}")
    if kutu is None:
        print("  ! Kırpma kutusu yok — tüm kare okunacak, plaka küçük kalır.")
    rtsp = str(ayar.get("RTSP_URL") or "")
    if not rtsp:
        print("  ✗ Ayar dosyasında kamera adresi (RTSP_URL) yok.")
        return 1

    p_ayar, uyarilar = plaka.calisma_ayarlari(ayar)
    for u in uyarilar:
        print(f"  ! {u}")
    if not p_ayar["acik"]:
        print("  ! PLAKA_BUL=0: köprü bu şeritte plaka okumuyor — test yine de yapılıyor.")
    try:
        p = plaka.yukle(p_ayar)
    except plaka.PlakaHatasi as e:
        print(f"  ✗ Plaka okuyucu çalışmıyor: {e}")
        return 1
    print("  ✓ Plaka okuyucu hazır.")

    # Adres şifre taşır: ekrana yalnızca kameranın adresi yazılır.
    try:
        host = urlparse(rtsp).hostname or "?"
    except ValueError:
        host = "?"
    print(f"  Kamera: {host}   ({int(sure_sn)} sn; Ctrl+C ile erken bitirebilirsiniz)")
    print("  Araç geçirin. Her satır: saat · süre · kutu skoru → okuma (iki kırpıntı).\n")

    cap = (kamera or kamera_baglan)(rtsp)
    kareler = kutulu = bos = 0
    emin: dict[str, int] = {}
    sureler: list[float] = []
    haric_k = None
    sekil: tuple | None = None
    son_satir = time.monotonic()
    bitis = time.monotonic() + sure_sn
    try:
        while time.monotonic() < bitis and (en_cok_kare is None or kareler < en_cok_kare):
            ok, frame = cap.read()
            if not ok or frame is None:
                bos += 1
                if bos >= 50:
                    print("  ✗ Kameradan görüntü alınamıyor.")
                    return 1
                time.sleep(0.1)
                continue
            bos = 0
            kareler += 1
            kirpik = olcekle(kirp_maskeli(frame, kutu, haric))
            if haric is not None and sekil != kirpik.shape:
                sekil = kirpik.shape
                haric_k = haric_olcekli(frame.shape, kutu, haric, kirpik.shape)
            t0 = time.perf_counter()
            try:
                parcalar = []
                for k in okuma.kutulari_bul(p, kirpik, haric_k):
                    s = okuma.kutuyu_oku(p, kirpik, k, haric_k, p_ayar["oku_esik"])
                    if s is None:
                        parcalar.append(f"{k.skor:.2f} kesik (kenara değiyor, okunmaz)")
                        continue
                    (m1, e1), (m2, e2) = s[0]
                    if s[1] is not None:
                        emin[s[1][0]] = emin.get(s[1][0], 0) + 1
                        parcalar.append(f"{k.skor:.2f} → {s[1][0]} ({e1:.3f} / {e2:.3f}) EMİN")
                    else:
                        parcalar.append(f"{k.skor:.2f} → belirsiz: {m1} ({e1:.3f}) / {m2} ({e2:.3f})")
            except Exception as e:  # noqa: BLE001 — test kipi: sebebi göster, dur
                print(f"  ✗ Plaka okuyucu hata verdi: {type(e).__name__}: {e}")
                return 1
            ms = (time.perf_counter() - t0) * 1000
            sureler.append(ms)
            simdi = time.monotonic()
            if parcalar:
                kutulu += 1
                print(f"  {time.strftime('%H:%M:%S')}  {ms:5.0f} ms  " + " · ".join(parcalar),
                      flush=True)
                son_satir = simdi
            elif simdi - son_satir >= PLAKA_TEST_SESSIZ_SN:
                print(f"  {time.strftime('%H:%M:%S')}  {ms:5.0f} ms  plaka yok", flush=True)
                son_satir = simdi
            if ara_sn:
                time.sleep(ara_sn)
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()

    print()
    if not kareler:
        print("  ✗ Kameradan hiç görüntü gelmedi.")
        return 1
    print(f"  {kareler} kare · {kutulu} karede plaka kutusu · süre ortalama "
          f"{sum(sureler) / len(sureler):.0f} ms, en çok {max(sureler):.0f} ms")
    if emin:
        print("  ✓ Emin okunan plakalar: "
              + ", ".join(f"{m} ×{n}" for m, n in sorted(emin.items(), key=lambda x: -x[1])))
        print("    Geçen araçların plakasıyla karşılaştırın; yanlış olan varsa Claude'a iletin.")
        return 0
    print("  ! Bu sürede emin okunan plaka olmadı. Araç geçti mi, plaka kutunun içinde mi?")
    print("    Okunamayan araçlar köprüde personele düşer.")
    return 2


# --------------------------------------------------------------------- ana ---


def main() -> None:
    # Kurulan hâlinde bu süreci Görev Zamanlayıcı SYSTEM olarak başlatıyor ve
    # o sürecin konsolu YOK — buradaki her print hiçbir yere gitmiyordu.
    # Ayarlar okunduktan sonra çağrılıyor ki dosya doğru şeride yazılsın.
    gunluk.baslat(YON)

    if not WEBHOOK_URL or not KAMERA_SECRET:
        if _AYAR_HATASI:
            sys.exit(f"Ayar dosyası okunamadı — {_AYAR_HATASI}\n"
                     "Dosyayı düzeltin ya da kurulumu yeniden çalıştırın.")
        sys.exit("WEBHOOK_URL ve KAMERA_SECRET tanımlı olmalı (bkz. README).")
    if YON not in gunluk.SERITLER:
        sys.exit("YON tanımlı değil ya da geçersiz: "
                 f"{gunluk.SERIT_SECENEKLERI} olmalı. "
                 "Şerit tahmin edilmez — yanlışı, çıkan araçlara bilet açar.")

    kutu = kirpma_kutusu()
    haric = kirpma_haric(kutu)
    if kutu is None:
        print("[!] KIRPMA verilmedi — tüm kare okunacak, plaka küçük kalır", flush=True)
        # `[i]`: not a fault, durum must not show it as the last error.
        print("[i] kırpma kutusu yok — bu şeritte araç fotoğrafı saklanmayacak", flush=True)
    if haric is not None:
        print(f"[i] kesilen köşe {','.join(str(v) for v in haric)} — orada hareket ve plaka "
              "yok sayılır", flush=True)

    # ---- 1.3.0: plaka okuyucu. Yüklenemezse köprü DÜŞMEZ: araçlar personele.
    p_ayar, p_uyarilar = plaka.calisma_ayarlari()
    for u in p_uyarilar:
        print(f"[!] {u}", flush=True)
    plakaci = None
    sebep: str | None = None
    if p_ayar["acik"]:
        try:
            plakaci = plaka.yukle(p_ayar)
            print(f"[i] {gunluk.PLAKA_HAZIR_ISARETI} ({p_ayar['iplik']} iş parçacığı)", flush=True)
        except plaka.PlakaHatasi as e:
            sebep = str(e)
            print(f"[!] {gunluk.OKUYUCU_BOZUK_ISARETI}: {sebep} — araçlar personele gidecek",
                  flush=True)
    else:
        sebep = "kapalı (PLAKA_BUL=0)"
        print(f"[i] {gunluk.PLAKA_KAPALI_ISARETI} (PLAKA_BUL=0) — araçlar personele gidecek",
              flush=True)
    global _isci, _giden
    isci = okuma.Isci(plakaci, haric=None, oku_esik=p_ayar["oku_esik"], sebep=sebep)
    _isci = isci

    # Before the first camera wait: a startup that hangs is as blind as a loop
    # that hangs. The waits themselves stamp through uyu().
    canli()
    threading.Thread(target=bekci, daemon=True).start()

    print(f"[i] kamera açılıyor ({YON})", flush=True)
    cap = kamera_ac(bekle=True)
    print(f"[i] {gunluk.KAMERA_VAR_ISARETI}", flush=True)

    # ---- 1.3.0: gönderim kutusu. Her araç ÖNCE diske, sonra sunucuya.
    _giden = giden.Giden(os.path.join(gunluk.kayit_klasoru(), f"giden-{YON.lower()}"))
    bekleyen, _en_eski = giden.ozet(_giden.klasor)
    if bekleyen:
        print(f"[i] gönderim kutusunda {bekleyen} araç bekliyordu — gönderiliyor", flush=True)
    threading.Thread(target=giden.calistir, args=(_giden, gonder_olay), daemon=True,
                     name="gonderici").start()

    onceki: np.ndarray | None = None
    son_hareket = 0.0        # monotonic, last time the scene moved
    durgun_sayaci = 0        # consecutive still frames
    son_kalp = float("-inf")
    kalp_isi: threading.Thread | None = None
    uyarildi = False
    kare_sayaci = 0

    # Re-arm state (1.2.x, değişmedi). `silahli` False: gönderilmiş aracı hâlâ
    # görüyoruz, o gidene kadar yeni karar yok.
    silahli = True
    gonderilen_gri: np.ndarray | None = None
    bekleme_bitis = 0.0
    zorunlu_arm = 0.0
    hareket_oldu = False

    # Bir geçişin DIŞINDA görülen son durgun sahne (gri + kırpık): geçişin
    # arka planı ve ayrılışı tanımak için okunan kare.
    son_durgun_gri: np.ndarray | None = None
    son_durgun_kirpik: np.ndarray | None = None

    # ---- 1.3.0 geçiş (okuma.Gecis): ilk güçlü hareketten karara kadar.
    gecis: okuma.Gecis | None = None
    gecis_no = 0
    gecis_arka: np.ndarray | None = None
    kapsam = 0.0                 # geçiş boyunca arka plandan en büyük fark (araç boyu)
    ayrilis_sahne = False        # geçiş, gönderilmiş DURAN aracın görüntüsünden başladı
    gorunum = 0                  # sahne değiştikçe artar: duran aracın kareleri tek görünüm
    # Durarak gönderilmiş son araç (ayrılışını tanımak için) ve son 60 sn'de
    # gidenler (aynı plaka ikinci kez gitmesin).
    son_gonderim_gri: np.ndarray | None = None
    son_durdu_plaka: str | None = None
    son_gonderilen: list[tuple[str | None, float]] = []
    haric_sekli: tuple | None = None

    kopuk = False
    bekleme = YENIDEN_BAGLAN_SN

    def yeni_gecis(zaman: datetime) -> okuma.Gecis:
        nonlocal gecis_no
        gecis_no += 1
        return okuma.Gecis(gecis_no, zaman, plaka.Oylama(tek_esik=p_ayar["tek_esik"]))

    def bitir(durdu: bool, simdi: float, gri_simdi: np.ndarray | None, d: float) -> bool:
        """Geçişi karara bağlar ve sonucu kutuya yazar. Bir şey gönderildi mi."""
        nonlocal gecis, gecis_arka, son_gonderim_gri, son_durdu_plaka, son_gonderilen
        isci.bekle(gecis, p_ayar["bekle_sn"])
        gonderimler, satirlar = okuma.karar_ver(
            gecis, durdu=durdu, arac_boyu=kapsam >= ARAC_KAPSAM_ESIGI,
            ayrilis_sahne=ayrilis_sahne, son_durdu_plaka=son_durdu_plaka,
            bozuk=isci.bozuk is not None, son_gonderilen=son_gonderilen, simdi=simdi)
        plaka_sayisi = sum(1 for g in gonderimler if g.tur == "PLAKA")
        personel = len(gonderimler) - plaka_sayisi
        ozet = (f"{plaka_sayisi} plaka" if plaka_sayisi else "") + \
            (", " if plaka_sayisi and personel else "") + \
            (f"{personel} personele" if personel else "")
        olay_adi = "araç durdu" if durdu else gunluk.ARAC_GECTI_ISARETI
        print(f"[i] {olay_adi} (fark={d:.2f}, kapsam={kapsam:.1f}) — "
              f"{ozet + ' gönderiliyor' if ozet else 'gönderim yok'}", flush=True)
        for s in satirlar:
            print(s, flush=True)
        for g in gonderimler:
            araci_gonder(g, kutu)
            son_gonderilen.append((g.plaka or g.tahmin, simdi))
        son_gonderilen = [(p, t) for p, t in son_gonderilen if simdi - t <= okuma.YAKIN_SN]
        if durdu and gonderimler and gri_simdi is not None:
            son_gonderim_gri = gri_simdi
            son_durdu_plaka = next((g.plaka for g in gonderimler if g.tur == "PLAKA"), None)
        else:
            son_gonderim_gri = None
            son_durdu_plaka = None
        gecis = None
        gecis_arka = None
        return bool(gonderimler)

    while True:
        canli()
        ok, frame = cap.read()
        if not ok:
            print(f"[!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor "
                  f"({_sure(bekleme)} sonra)", flush=True)
            kopuk = True
            cap.release()
            # Süren geçiş uzun beklemeden ÖNCE karara bağlanır (atılmaz).
            if gecis is not None:
                bitir(False, time.monotonic(), onceki, 0.0)
            uyu(bekleme)
            bekleme = min(bekleme * 2, YENIDEN_BAGLAN_MAX_SN)
            sifre_kabul_edilene_kadar_bekle()
            cap = kamera_baglan()
            onceki = None
            continue
        if kopuk:
            kopuk = False
            bekleme = YENIDEN_BAGLAN_SN
            print(f"[i] {gunluk.KAMERA_VAR_ISARETI} (yeniden)", flush=True)

        simdi = time.monotonic()
        zaman = datetime.now(timezone.utc)
        kare_sayaci += 1
        if simdi - son_kalp > KALP_ARALIGI_SN:
            if kalp_isi is None or not kalp_isi.is_alive():
                kalp_isi = threading.Thread(target=kalp, daemon=True)
                kalp_isi.start()
            son_kalp = simdi
            print(f"[i] çalışıyor — {kare_sayaci} kare, "
                  f"{_gonderim_sayaci} gönderim", flush=True)

        kirpik = olcekle(kirp_maskeli(frame, kutu, haric))
        if haric is not None and haric_sekli != kirpik.shape:
            haric_sekli = kirpik.shape
            isci.haric = haric_olcekli(frame.shape, kutu, haric, kirpik.shape)
        if not uyarildi:
            yh, yw = kirpik.shape[:2]
            if max(yh, yw) < MIN_KENAR_UYARI:
                print(f"[!] kırpma {yw}x{yh} — {MIN_KENAR_UYARI}px altında plaka küçük kalır",
                      flush=True)
            uyarildi = True

        gri = gri_kucuk(kirpik)
        d = fark(onceki, gri)
        onceki = gri

        if not silahli and simdi >= bekleme_bitis:
            ayrildi = gonderilen_gri is None or fark(gri, gonderilen_gri) > SAHNE_ESIGI
            if ayrildi or hareket_oldu or simdi >= zorunlu_arm:
                if not (ayrildi or hareket_oldu):
                    print("[!] sahne değişmedi ama süre doldu — yeniden kuruldu", flush=True)
                silahli = True
                gonderilen_gri = None
                hareket_oldu = False

        # ---- 1.3.0 geçiş: silahlıyken ilk güçlü hareket başlatır.
        if gecis is None and silahli and d > HAREKET_ESIGI:
            gecis = yeni_gecis(zaman)
            gecis_arka = son_durgun_gri
            kapsam = 0.0
            ayrilis_sahne = (son_gonderim_gri is not None and gecis_arka is not None
                             and fark(gecis_arka, son_gonderim_gri) <= SAHNE_ESIGI)
            # Geçişten önce kadrajda bir araç duruyor muydu? Önceki durgun kare
            # her geçişte okunur (oy değil): gönderilmiş aracın gidişi ışık
            # değişse de tanınır, ve plakalı araç gidince durulan boş şerit
            # "plakasız araç durdu" sanılmaz (test_kopru `kuyruk`).
            if son_durgun_kirpik is not None:
                isci.ver(okuma.Is(gecis, son_durgun_kirpik.copy(), zaman, 0, arka=True),
                         oncelik=True)
        if gecis is not None:
            if gecis_arka is not None:
                kapsam = max(kapsam, fark(gri, gecis_arka))
            if d >= DURGUN_ESIGI:
                gorunum += 1
            gecis.son_kirpik = kirpik
            # Okuyucu boştaysa en yeni kare verilir (kopyası: kameranın karesi
            # değişebilir). Meşgulse bu kare atlanır — döngü ASLA beklemez.
            if isci.bos_mu():
                isci.ver(okuma.Is(gecis, kirpik.copy(), zaman, gorunum))
        if isci.takildi(simdi, OKUYUCU_TAKILMA_SN):
            print(f"[!] {gunluk.TAKILDI_ISARETI}: plaka okuyucu {OKUYUCU_TAKILMA_SN:.0f} sn'dir "
                  "dönmüyor — köprü yeniden başlatılıyor", flush=True)
            _bekci_cik()

        if d < DURGUN_ESIGI and gecis is None:
            son_durgun_gri = gri
            son_durgun_kirpik = kirpik

        if d > HAREKET_ESIGI:
            son_hareket = simdi
            durgun_sayaci = 0
            hareket_oldu = True
            continue

        if d < DURGUN_ESIGI:
            durgun_sayaci += 1
        else:
            durgun_sayaci = 0

        gonderildi = None
        gecerli_pencere = simdi - son_hareket < HAREKET_PENCERESI_SN
        if silahli and durgun_sayaci >= DURGUN_KARE and gecerli_pencere:
            # Sahne DURULDU. Geçiş yoksa (köprü bir aracın ortasında açıldı, ya
            # da hareket silahsızken başladı) burada açılır.
            if gecis is None:
                gecis = yeni_gecis(zaman)
                gecis_arka = None
                kapsam = fark(gri, son_durgun_gri) if son_durgun_gri is not None else 0.0
                ayrilis_sahne = son_gonderim_gri is not None
            # Sahne geçişten önceki hâline döndüyse araç DURMADAN geçti; yoksa
            # bir şey durdu — onun karesi öncelikle okunur.
            durdu = not _arkaya_dondu(gri, gecis_arka)
            if durdu:
                gecis.durgun_kirpik = kirpik.copy()
                isci.ver(okuma.Is(gecis, gecis.durgun_kirpik, zaman, gorunum), oncelik=True)
            gonderildi = bitir(durdu, simdi, gri, d)
        elif (gecis is not None and simdi - son_hareket >= GECIS_BEKLE_SN
              and _arkaya_dondu(gri, gecis_arka)):
            # Güvenlik ağı: araç gitti ama sahne durulmuyor (yağmur, kumlanma).
            gonderildi = bitir(False, simdi, gri, d)
        elif gecis is not None and simdi - son_hareket >= HAREKET_PENCERESI_SN:
            # Bayat geçiş: atılmaz, karara bağlanır (1.2.x'te düşüyordu).
            gonderildi = bitir(False, simdi, gri, d)

        if gonderildi is not None:
            durgun_sayaci = 0
            son_hareket = 0.0
            if gonderildi:
                # Disarmed until this vehicle leaves the frame (1.2.x).
                silahli = False
                gonderilen_gri = gri
                bekleme_bitis = simdi + MIN_BEKLEME_SN
                zorunlu_arm = simdi + MAX_BEKLEME_SN
                hareket_oldu = False


def cli() -> None:
    """
    Kip seçimi. Ayrı bir fonksiyon, çünkü paketlenmiş .exe tek bir giriş
    noktasından çağırıyor ve `--kare` / `--test` kipleri orada da çalışmalı —
    kırpma kutusunu elle ölçmek hâlâ belgelenmiş yol.
    """
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--kare":
        kare_kaydet()
    elif arg == "--test":
        kirpma_test()
    else:
        main()


if __name__ == "__main__":
    cli()
