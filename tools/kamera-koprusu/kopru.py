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
  * The plate finder is not YOLOv8 / Ultralytics (AGPL-3.0): it is
    open-image-models' YOLOv9 export (code MIT; the weights' licence is not
    stated — owner accepted the risk) and the reader's weights are MIT.
    Since 1.4.2 the VEHICLE finder can be YOLO11s, which IS Ultralytics /
    AGPL-3.0 — owner decision 2026-11-12: this bridge runs only at our own
    car park; if it is ever sold, switch to YOLOX-s (modeller/LISANS.txt 5).
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

import arac
import giden
import gunluk
import hizlandirici
import kesif
import klip
import okuma
import plaka
import takip

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

# 1.4.0: kırpma ALANI — kırpma sayfasında köşeleri tıklanan çokgen ("x,y;x,y;…",
# tam kare pikseli, 3-8 köşe). KIRPMA + KIRPMA_HARIC'in yerine geçer: köprü
# alanın çevreleyen dikdörtgenini kırpar, alanın DIŞINI griye boyar. Verilmişse
# KIRPMA / KIRPMA_HARIC yok sayılır (uyarıyla). Boş = eski kırpma geçerli.
KIRPMA_ALAN = os.environ.get("KIRPMA_ALAN", "").strip()

# 1.4.0: KAPI alanı — kapının önü, araçların girip çıktığı yer (çokgen, aynı
# biçim). Araç izleme bir aracı ancak buradan girip avluya geçtiyse "girdi",
# avludan buraya gelip burada kaybolduysa "çıktı" sayar; avlu içindeki
# hareket sayılmaz. Boş = kapı kuralı yok (araç durunca / kaybolunca karar).
KAPI_ALANI = os.environ.get("KAPI_ALANI", "").strip()

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
# 1.4.3: canlı kameranın açma / okuma zaman aşımı (ms). 20 kare/sn akışta 10 sn
# kare gelmemesi akışın koptuğu demektir; kısası ağdaki kısa takılmada gereksiz
# yeniden bağlanırdı.
KAMERA_ACMA_MS = 10000
KAMERA_OKUMA_MS = 10000
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

# 1.4.0 araç izleme: son kıpırtıdan sonra bu kadar süre model karesi istenir
# (aracın durduğu / kaybolduğu görülsün); hiçbir şey değişmese de en az bu
# aralıkla bir model karesi (güvenlik ağı; ~0.25 sn işlem / 2 sn).
KUYRUK_SN = 3.0
YOKLAMA_SN = 2.0

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


def haric_metni_coz(metin: str, kutu) -> tuple[tuple | None, str | None]:
    """
    KIRPMA_HARIC metni → (kesilen köşeler ((x, y, w, h), …) ya da None,
    uyarı ya da None). 1.3.3: en çok plaka.HARIC_EN_COK alan, ";" ile;
    tek alanlı metin 1.3.0 ile aynıdır.

    Bozuk biçim, fazla alan ve kutunun TAMAMINI (birlikte) kaplayan alanlar
    ValueError — köprü hiçbir şey göremezdi. Kutu yoksa hepsi, kutunun
    dışındaki alan tek başına yok sayılır, bir uyarıyla. Kurallar kırpma
    sayfasınınkiyle aynı (kirpma_sunucu._kutu_coz).
    """
    metin = (metin or "").strip()
    if not metin:
        return None, None
    if kutu is None:
        return None, "KIRPMA_HARIC verildi ama KIRPMA yok — kesilen köşe yok sayılıyor"
    parcalar = [p.strip() for p in metin.split(";")]
    if len(parcalar) > plaka.HARIC_EN_COK:
        raise ValueError(f"KIRPMA_HARIC en çok {plaka.HARIC_EN_COK} alan olabilir (\";\" ile ayrılır)")
    kx, ky, kw, kh = kutu
    alanlar: list[tuple[int, int, int, int]] = []
    disarida = 0
    for parca in parcalar:
        try:
            x, y, w, h = (int(p) for p in parca.split(","))
        except ValueError:
            raise ValueError('KIRPMA_HARIC "x,y,w,h" biçiminde olmalı (piksel; en çok 3 alan '
                             '";" ile), örn. "0,0,500,200"')
        if w <= 0 or h <= 0:
            raise ValueError("KIRPMA_HARIC genişlik ve yükseklik pozitif olmalı")
        if x >= kx + kw or y >= ky + kh or x + w <= kx or y + h <= ky:
            disarida += 1
            continue
        alanlar.append((x, y, w, h))
    uyari = None
    if disarida and not alanlar:
        uyari = "KIRPMA_HARIC kırpma kutusunun dışında — kesilen köşe yok sayılıyor"
    elif disarida:
        uyari = f"KIRPMA_HARIC: {disarida} alan kırpma kutusunun dışında — o alan yok sayılıyor"
    if not alanlar:
        return None, uyari
    if plaka.kesilen_alan(kx, ky, kx + kw, ky + kh, alanlar) >= kw * kh:
        raise ValueError("KIRPMA_HARIC kırpma kutusunun tamamını kaplıyor — köprü hiçbir şey göremezdi")
    return tuple(alanlar), uyari


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


def kirpma_haric(kutu: tuple[int, int, int, int] | None) -> tuple | None:
    """KIRPMA_HARIC → ((x, y, w, h), …) tam kare pikseli, ya da None."""
    try:
        haric, uyari = haric_metni_coz(KIRPMA_HARIC, kutu)
    except ValueError as e:
        sys.exit(str(e))
    if uyari:
        print(f"[!] {uyari}", flush=True)
    return haric


def _haric_kirpintida(frame_sekli: tuple, kutu, haric) -> tuple:
    """
    Kesilen köşeler, kırpıntının (ölçeklenmeden önce) kendi koordinatlarında:
    ((x, y, w, h), …); kırpıntıyla kesişmeyen düşer. 1.3.3: en çok 3 alan.
    """
    if kutu is None:
        return ()
    yh, yw = frame_sekli[:2]
    x, y, w, h = kutu
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    x1, y1 = max(x0 + 1, min(x + w, yw)), max(y0 + 1, min(y + h, yh))
    sonuc = []
    for hx, hy, hw, hh in plaka.haric_listesi(haric):
        a0, b0 = max(hx - x0, 0), max(hy - y0, 0)
        a1, b1 = min(hx + hw - x0, x1 - x0), min(hy + hh - y0, y1 - y0)
        if a1 > a0 and b1 > b0:
            sonuc.append((a0, b0, a1 - a0, b1 - b0))
    return tuple(sonuc)


def alan_metni_coz(metin: str) -> tuple | None:
    """KIRPMA_ALAN metni → ((x, y), …), boşsa None; bozuksa ValueError (Türkçe)."""
    try:
        return plaka.cokgen_metinden(metin)
    except ValueError as e:
        raise ValueError(f"KIRPMA_ALAN geçersiz: {e}") from None


def alan_kutusu(alan) -> tuple[int, int, int, int]:
    """Alanın çevreleyen dikdörtgeni (x, y, w, h) — köprü bunu kırpar."""
    return plaka.cokgen_kutusu(alan)


def kirpma_alani() -> tuple | None:
    try:
        return alan_metni_coz(KIRPMA_ALAN)
    except ValueError as e:
        sys.exit(str(e))


def _kirpinti_koken(frame_sekli: tuple, kutu) -> tuple[int, int, int, int]:
    """kirp()'in gerçekten kestiği parça: (x0, y0, en, boy) — kirp ile aynı sıkıştırma."""
    yh, yw = frame_sekli[:2]
    if kutu is None:
        return 0, 0, yw, yh
    x, y, w, h = kutu
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    x1, y1 = max(x0 + 1, min(x + w, yw)), max(y0 + 1, min(y + h, yh))
    return x0, y0, x1 - x0, y1 - y0


def _alan_kirpintida(frame_sekli: tuple, kutu, noktalar, kirpik_sekli: tuple | None = None):
    """Köşeler kırpıntının (kirpik_sekli verilirse ölçeklenmiş) pikselinde (N, 2)."""
    x0, y0, cw, ch = _kirpinti_koken(frame_sekli, kutu)
    sx = 1.0 if kirpik_sekli is None else kirpik_sekli[1] / cw
    sy = 1.0 if kirpik_sekli is None else kirpik_sekli[0] / ch
    p = np.asarray(noktalar, dtype=np.float64).reshape(-1, 2)
    return np.stack([(p[:, 0] - x0) * sx, (p[:, 1] - y0) * sy], axis=1)


# Tam çözünürlüklü dış maske her karede yeniden çizilmez: (şekil, köken, alan) başına bir kez.
_ALAN_DIS_ONBELLEK: dict = {}


def _alan_dis_maskesi(parca_sekli: tuple, frame_sekli: tuple, kutu, alan) -> np.ndarray:
    anahtar = (parca_sekli[:2], frame_sekli[:2], kutu, alan)
    m = _ALAN_DIS_ONBELLEK.get(anahtar)
    if m is None:
        # AlanMaskesi.cokgenden ile AYNI çizim (plaka.cokgen_dis_maskesi): griye
        # boyanan yer ile kuralların "alanın dışı" dediği yer ayrışamaz.
        # Saklanan: İÇ maske (255 = alanın içi) — cv2.copyTo'nun maskesi.
        dis = plaka.cokgen_dis_maskesi(_alan_kirpintida(frame_sekli, kutu, alan),
                                       parca_sekli[1], parca_sekli[0])
        m = np.where(dis == 0, np.uint8(255), np.uint8(0))
        _ALAN_DIS_ONBELLEK.clear()           # alan ya da kamera çözünürlüğü değişti
        _ALAN_DIS_ONBELLEK[anahtar] = m
    return m


def alan_maskesi(frame_sekli: tuple, kutu, alan, kirpik_sekli: tuple) -> plaka.AlanMaskesi:
    """Kırpma alanı, ölçeklenmiş kırpıntının (kirpik) pikselinde — okuyucu ve bulucu için."""
    return plaka.AlanMaskesi.cokgenden(_alan_kirpintida(frame_sekli, kutu, alan, kirpik_sekli),
                                       kirpik_sekli[1], kirpik_sekli[0])


def kapi_kirpikta(frame_sekli: tuple, kutu, kapi, kirpik_sekli: tuple) -> np.ndarray:
    """Kapı alanı, ölçeklenmiş kırpıntının pikselinde, KIRPILMADAN (dışa taşabilir)."""
    return _alan_kirpintida(frame_sekli, kutu, kapi, kirpik_sekli).astype(np.float32)


def kirp_maskeli(frame: np.ndarray, kutu, haric, alan=None) -> np.ndarray:
    """
    kirp() + her kesilen köşe düz griye (114) boyanır. Kesilen köşe varsa
    KOPYA döner (kirp bir görünüm verir; kameranın karesi değişmemeli), yoksa
    kirp()'in kendisi — davranış 1.2.x ile birebir. 1.4.0: `alan` (çokgen)
    verilmişse alanın DIŞI boyanır ve `haric` kullanılmaz.
    """
    if alan is not None:
        # Gri tuvale yalnızca alanın içi kopyalanır (sahadaki 2124 px'lik
        # kırpıntıda ~3 ms; boolean indeksleme ~12 ms idi — her karede).
        kaynak = np.ascontiguousarray(kirp(frame, kutu))
        parca = np.full(kaynak.shape, 114, np.uint8)
        cv2.copyTo(kaynak, _alan_dis_maskesi(kaynak.shape, frame.shape, kutu, alan), parca)
        return parca
    parca = kirp(frame, kutu)
    alanlar = _haric_kirpintida(frame.shape, kutu, haric)
    if not alanlar:
        return parca
    parca = parca.copy()
    for a, b, w, hh in alanlar:
        parca[b:b + hh, a:a + w] = 114
    return parca


def haric_olcekli(frame_sekli: tuple, kutu, haric, kirpik_sekli: tuple):
    """
    Kesilen köşeler, ölçeklenmiş kırpıntının (kirpik) koordinatlarında —
    okuyucu ve araç bulucu için: ((x, y, w, h), …) ya da None.
    """
    alanlar = _haric_kirpintida(frame_sekli, kutu, haric)
    if not alanlar:
        return None
    yh, yw = frame_sekli[:2]
    x, y, w, hh_ = kutu
    x0, y0 = max(0, min(x, yw - 1)), max(0, min(y, yh - 1))
    cw = max(x0 + 1, min(x + w, yw)) - x0
    ch = max(y0 + 1, min(y + hh_, yh)) - y0
    sx, sy = kirpik_sekli[1] / cw, kirpik_sekli[0] / ch
    return tuple((a * sx, b * sy, ww * sx, hh * sy) for a, b, ww, hh in alanlar)


def acik_kirpik(frame: np.ndarray, kutu, tam_var: bool) -> tuple[np.ndarray, np.ndarray | None]:
    """
    1.4.3 (PARK_GORUNUR): modellerin MASKESİZ kırpıntısı (olcekle(kirp)) ve
    istenirse küçültülmemiş hâli — ikisi de kameranın karesinin KOPYASI (işçi
    sahiplenir; kirp ve olcekle görünüm döndürebilir). Boyutu maskeli
    kırpıntınınkiyle aynı: kutular aynı pikselde.
    """
    parca = kirp(frame, kutu)
    kucuk = olcekle(parca)
    if np.shares_memory(kucuk, frame):
        kucuk = kucuk.copy()
    return kucuk, (parca.copy() if tam_var else None)


def izci_alani(park_gorunur: bool, frame_sekli: tuple, kutu, alan,
               kirpik_sekli: tuple) -> np.ndarray | None:
    """
    1.4.3 (PARK_GORUNUR): izcinin olay alanı (kırpma çokgeni, ölçeklenmiş
    kırpıntının pikselinde). Anahtar kapalıysa ya da çokgen yoksa None —
    bütün kırpıntı alandır, izci bugünkü gibi.
    """
    if not park_gorunur or alan is None:
        return None
    return _alan_kirpintida(frame_sekli, kutu, alan, kirpik_sekli).astype(np.float32)


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


# 1.4.2 (A1): yerel kıpırtının yama ızgarası — 160×120 gri → 10×8 yama (16×15 px).
YAMA_IZGARA = (10, 8)


def yerel_kipirti(a: np.ndarray, b: np.ndarray) -> float:
    """
    1.4.2 (A1): iki gri kırpıntının YEREL farkı — 16×15 px'lik yamaların en
    büyük ortalama farkı. Sahada gece hareket eden aracın bütün kırpıntı farkı
    (`fark`) 0.27'de kaldı (DURGUN_ESIGI ≥ 2.0): araç kırpıntının küçük bir
    parçası, ortalama onu boğuyor. Kırpma dışı (114 gri) iki karede aynıdır,
    farkı 0 — maske gerekmez.
    """
    if a is None or b is None or a.shape != b.shape:
        return 0.0
    return float(cv2.resize(cv2.absdiff(a, b), YAMA_IZGARA, interpolation=cv2.INTER_AREA).max())


def model_karesi_istenir(izci, gri, *, simdi: float, son_kipirti: float, son_yerel: float,
                         son_kare_t: float) -> bool:
    """
    İzleme döngüsü bu kareyi modellere istiyor mu (iki model de boşsa verilir):
    izci istiyorsa (hareketli / kaybolan / ısınma); bir aracın ya da kapı
    alanının pikselleri SON MODEL karesinden beri değiştiyse (`degisti` — kare
    başına ~1 px'ten yavaş sürünen araç: yalnızca o yakalar); son kıpırtıdan —
    bütün kırpıntıda ya da 1.4.2'den beri YEREL — sonra KUYRUK_SN boyunca; ve
    her durumda en az YOKLAMA_SN'de bir (güvenlik ağı). test_model_karesi_istegi.
    """
    return (izci.kare_istiyor() or izci.degisti(gri)
            or simdi - son_kipirti < KUYRUK_SN or simdi - son_yerel < KUYRUK_SN
            or simdi - son_kare_t >= YOKLAMA_SN)


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
        # 1.4.2 (B5): izcinin gördüğü yön; sunucu yalnızca yanlış tahmini
        # durdurmak için kullanır (056). Yoksa anahtar hiç yazılmaz.
        if g.hareket:
            govde["hareket"] = g.hareket
        # 1.4.6 K: aynı iz kapıdan girip AYNI_IZ_SN içinde çıktı. Yoksa
        # anahtar hiç yazılmaz.
        if g.ayni_iz_dondu:
            govde["ayni_iz_dondu"] = True
        # 1.4.3 (sahibin kararı 17.11): tek kapıda yönü bilinmeyen olayın emin
        # plakası. Sunucu kaydeder (webhook gövdeyi `ham` olarak taşır); kararı
        # değiştirmez. Yoksa anahtar hiç yazılmaz.
        if g.yon_bilinmiyor:
            govde["yon_bilinmiyor"] = True
    else:
        govde["okunamadi"] = True
        if g.tahmin:
            govde["tahmin"] = g.tahmin
        if g.guven is not None:
            govde["guven"] = round(float(g.guven), 4)
        # 1.4.6 D (sahibin kararı 25.11): kapıdan GİRDİ / ÇIKTI diye izlenen
        # aracın kartı yönünü taşır — sunucu çıkış tahminiyle bileti kapatır
        # (yalnızca benzeri yoksa), içeride okunan plakayı giriş kartına bağlar.
        if g.hareket:
            govde["hareket"] = g.hareket
    # 1.4.7 F4: aynı izin giriş kartı (PLAKA da kart da). Sunucu 090 kartı
    # bulur; eski sunucu gövdeyi `ham` olarak saklar, kararı değişmez.
    # Yoksa anahtar hiç yazılmaz.
    if g.giris_islem_id:
        govde["giris_islem_id"] = g.giris_islem_id
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


# 1.4.3: kesin ret alan (giden.RED) araçların zamanı (monotonic). 071'den sonra
# sunucunun reddettiği araç kart olur ve 200 döner; geriye kalan kayıp yolu
# şerit uyuşmazlığı, bozuk gövde ve eski sunucu. Son saatin sayısı kalp
# atışıyla gider (070): Gişe şeridi ve Yönetici uyarısı. Plaka TUTULMAZ.
_reddedilenler: list[float] = []
_ret_kilit = threading.Lock()


def _reddedildi_say() -> None:
    with _ret_kilit:
        _reddedilenler.append(time.monotonic())


def son_saat_reddedilen(simdi: float) -> int:
    with _ret_kilit:
        _reddedilenler[:] = [t for t in _reddedilenler if t > simdi - 3600]
        return len(_reddedilenler)


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
        _reddedildi_say()
        return giden.RED
    if r.status_code == 429:
        print("[!] hız sınırı (429), tekrar denenecek", flush=True)
        return giden.TEKRAR
    if r.status_code in (401, 403):
        # ret_kaydet söyledi; araç KUTUDA kalır, kamera yeniden açılınca gider.
        return giden.TEKRAR
    if r.status_code == 410 and "KAMERA_KAPALI" in metin:
        # Sahip kararı 20.11: kamera girişi kapalıyken görülen araç ATILIR,
        # kuyrukta beklemez. _reddedildi_say YOK: kalbin `reddedilen` sayısı
        # artsaydı Gişe yanlış bir "sunucu reddediyor" uyarısı gösterirdi.
        # Kapalılığı `durum` kalbin 403'ünden bilir (ret_kaydet).
        print(f"[!] {gunluk.KAMERA_KAPALI_ATILDI_ISARETI} ({kimlik})", flush=True)
        return giden.RED
    if 400 <= r.status_code < 500:
        print(f"[!] reddedildi {r.status_code} ({kimlik}): {_plakasiz(metin)[:120]}", flush=True)
        _reddedildi_say()
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


def araci_gonder(g: okuma.Gonderim, kutu) -> str | None:
    """
    Kararı kutuya yazar (gönderici iş parçacığı yollar). Döndürdüğü olayın
    islem_id'si (1.4.3, 1d: klibin adı); hiçbir şey gitmediyse None.
    """
    global _gonderim_sayaci
    if g.tur == "OKUNAMADI" and YON == "CIKIS":
        print(f"[i] {gunluk.CIKIS_OKUNAMADI_ISARETI} — sunucuya gönderilmedi, "
              "personel kapıda görür", flush=True)
        return None
    _gonderim_sayaci += 1
    govde = olay_govdesi(g, kutu)
    if _giden is None or _giden.yaz(govde) is None:
        threading.Thread(target=_yedek_gonder, args=(govde,), daemon=True).start()
    return govde["islem_id"]


def kalp_bilgisi(*, model_kare: int, sure_sn: float, izleme: bool, istendi: bool,
                 kume: str, kuyruk: tuple[int, str | None], simdi: datetime,
                 reddedilen: int, saat_farki: float | None,
                 parca: tuple[int, int] | None = None) -> dict:
    """
    1.4.3: the heartbeat's numbers (server 070, kamera_kalp_bilgi filters them).

    `fps` is tracking frames given to the models per second since the last
    heartbeat — only while tracking runs. The queue's oldest age is measured
    from that car's own `zaman`. A value that is not known is LEFT OUT, never
    sent as 0: the health line would read it as a fact.
    """
    b: dict = {"surum": gunluk.KOPRU_SURUMU}
    if izleme and sure_sn > 0:
        b["fps"] = round(model_kare / sure_sn, 1)
    sayi, en_eski = kuyruk
    yas = 0
    if sayi and en_eski:
        try:
            t = datetime.fromisoformat(str(en_eski).replace("Z", "+00:00"))
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            yas = max(0, int((simdi - t).total_seconds()))
        except ValueError:
            yas = 0
    b["kuyruk"] = int(sayi)
    b["kuyruk_en_eski_sn"] = yas
    b["takip"] = "acik" if izleme else ("kapandi" if istendi else "kapali")
    b["kume"] = str(kume)[:40]
    b["reddedilen"] = int(reddedilen)
    if saat_farki is not None:
        b["saat_farki_sn"] = round(float(saat_farki), 1)
    # 1.4.3 (1a): son saatte aynı aracın parçası sayılırdı / sayıldı (izlemede).
    # 1.4.5 A (Gecitci): emilirdi hep 0; emildi = gönderilmeyen kart.
    if izleme and parca is not None:
        b["emilirdi"], b["emildi"] = int(parca[0]), int(parca[1])
    return b


def kalp(bilgi: dict | None = None) -> None:
    """
    Keepalive.

    The webhook bumps the heartbeat for any request that clears the secret,
    BEFORE it parses the body — so an empty POST is a valid ping. It answers
    400 and that is the expected result, not an error.

    1.4.3: the body carries the numbers (`{"kalp": bilgi}`, kalp_bilgisi). A
    server with 070 stores them and answers 200; an older one answers 400 as
    before — both are fine.

    Runs on its own short-lived thread (see main): it used to run on the
    capture thread, and a slow answer froze the camera for up to 20 s — long
    enough for a car to arrive, stop and go unseen.
    """
    global _sunucu_dogrulandi
    try:
        r = requests.post(
            WEBHOOK_URL, json={"kalp": bilgi} if bilgi else {},
            headers={"x-kamera-secret": KAMERA_SECRET}, timeout=10
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
# 1.4.3: the last measured clock offset (s), sent with the next heartbeat.
_saat_farki: float | None = None


def saat_kontrol(r) -> None:
    """
    Compare this PC's clock with the server's `Date` header.

    Every vehicle is stamped with THIS clock and billed from that stamp. More
    than five minutes fast and every entry becomes a "future" exception
    instead of a ticket; slow, and every stay is billed long. Logged with `[!]`
    so `durum` shows it as the last warning; at most once an hour.
    """
    global _son_saat_uyarisi, _saat_farki
    fark = gunluk.saat_farki((getattr(r, "headers", None) or {}).get("Date"), time.time())
    if fark is not None:
        _saat_farki = fark            # 1.4.3: bir sonraki kalp atışıyla gider
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


# 1.4.2: the GPU stayed lost (hizlandirici.GpuGeriDonus.yeniden_baslat_gerek):
# restart only at a quiet moment — no car being tracked or decided, both
# models idle, no movement for GPU_SAKIN_SN. The outbox is on disk; the task
# brings the bridge back within about a minute with a fresh GPU connection.
GPU_SAKIN_SN = float(os.environ.get("GPU_SAKIN_SN", "10"))
# 1.4.3: bulucu / okuyucu geri gelince kapanmış izleme ancak sahne bu kadar
# kıpırtısızsa yeniden açılır (geçen araç ısınmada yeni olay olmasın).
IZLEME_SAKIN_SN = 5.0


def _gpu_cik() -> None:
    # Same exit as the watchdog, its own hook (and its own log marker: the
    # status screen must not show this as "stuck"). Replaced in tests.
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
    # 1.4.3: açma ve okuma zaman aşımı (kurulumun yoklaması gibi, kesif.py).
    # OpenCV ikisini yalnızca yakalama KURULURKEN alır. Olmadan takılan bir
    # akışta read() FFmpeg'in varsayılanı kadar bekliyordu; şimdi o süre
    # dolunca read() False döner ve döngünün yeniden bağlanma yolu çalışır.
    cap = cv2.VideoCapture(url or RTSP_URL, cv2.CAP_FFMPEG, [
        cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, KAMERA_ACMA_MS,
        cv2.CAP_PROP_READ_TIMEOUT_MSEC, KAMERA_OKUMA_MS,
    ])
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

# İzcinin olayları (takip.OLAY_TURLERI). Canlı döngü: gönderilenler (karar →
# plaka / personele) ve yalnız kayda yazılanlar. `--plaka`: ekrandaki adları.
# Her tür ikisinde de olmalı — eksiği KeyError (test_kurulum denetler).
OLAY_ADLARI = {"GIRDI": gunluk.GIRDI_ISARETI, "CIKTI": gunluk.CIKTI_ISARETI,
               "ESKI_GIRDI": gunluk.ESKI_GIRDI_ISARETI, "KAPISIZ": gunluk.KAPISIZ_ISARETI,
               "TEK_KARE": gunluk.TEK_KARE_ISARETI,
               "KAPIDA_KAYBOLDU": gunluk.KAPIDA_KAYBOLDU_ISARETI}
YALNIZ_KAYIT = {"ICERIDE": gunluk.ICERIDE_ISARETI, "GERI_DONDU": gunluk.GERI_DONDU_ISARETI,
                "KAPIDA_BEKLIYOR": gunluk.KAPIDA_BEKLIYOR_ISARETI}
# 1.4.2 (B5): plakası emin okunan olayla gönderilen yön ipucu (yalnızca bu
# ikisi yönü bilir; tek kare / kapıda kaybolan / kapısız / açılışta kapıdaki
# yönü bilinmeyen olaylardır). ICERIDE ayrı (iceride_sor).
HAREKET_IPUCU = {"GIRDI": "GIRDI", "CIKTI": "CIKTI"}
# 1.4.6 A, kapıda kaybolan da (sahibin kararı 26.11; sahada 23.11 13:06: gri
# Fiat içeriden kapıya gelip çıktı — kapıda yönü bilinmeden kayboldu, az
# önceki içeride sorusuna takıldı, bileti açık kaldı): kapıda EN AZ bu kadar
# görünümle kaybolan araç da kapı olayıdır. Tek görünüm (park etmiş aracın
# kutusunun kapıya bir kare sıçraması olabilir) ve TEK_KARE eskisi gibi değil.
KAPI_OLAYI_GORUNUM = 2


def kapi_olayi_mi(olay) -> bool:
    """1.4.6 A: içeride sorusuna (ICERIDE kaydı) takılmayan kapı olayı mı."""
    return olay.tur in HAREKET_IPUCU or (
        olay.tur == "KAPIDA_KAYBOLDU" and olay.iz.gorunum_no >= KAPI_OLAYI_GORUNUM)
# 1.4.6 K (sahibin kararı 25.11; 24.11 09:32/09:34): aynı iz bu süre içinde
# girip çıktıysa çıkış `ayni_iz_dondu` işaretiyle gider.
AYNI_IZ_SN = 120.0
# 1.4.6 E2 (sahibin kararı 25.11): ertelenen içeride sorusu en çok bu kadar
# bekler; sonra kapıdaki karar beklenmeden gider.
ICERIDE_ERTELEME_SN = 120.0
# 1.4.7 F5: içeride sorusu son kapı olayından en az bu kadar sonra gider
# (bekletilen kart varken hiç gitmez; ICERIDE_ERTELEME_SN tavanı aynen).
ICERIDE_KAPI_SN = 5.0
PLAKA_OLAY_ADLARI = {
    "GIRDI": "ARAÇ GİRDİ", "CIKTI": "ARAÇ ÇIKTI",
    "ESKI_GIRDI": "ARAÇ KAPIDAN GEÇTİ (açılışta kapıdaydı, yönü bilinmez)",
    "KAPISIZ": "ARAÇ HAREKETİ BİTTİ (kapı alanı yok)",
    "ICERIDE": "otopark içinde hareket — sayılmaz",
    "GERI_DONDU": "kapıdan geri döndü — sayılmaz",
    "KAPIDA_BEKLIYOR": "kapı alanında uzun bekleyen araç (alan park yerine mi çizildi?)",
    "TEK_KARE": "ARAÇ TEK KAREDE GÖRÜLDÜ (yönü bilinmez)",
    "KAPIDA_KAYBOLDU": "ARAÇ KAPI ALANINDA KAYBOLDU (yönü bilinmez)"}


def olay_arac_esigi(olay: takip.Olay, bulucu) -> float:
    """
    Plakası görülmeyen izin personele gitmesi için gereken araç puanı —
    canlı döngü ve `--plaka` ikisi de buradan. 1.4.3: izin en iyi kutusunun
    sınıfı ve bulucunun motosiklet eşiği (YOLO11s 0.70 — 1.4.4, her plakasız
    olayda; tiny'de yok).
    1.4.7 F7 (sahibin kararı 28.11): plakasız şunlar hiç kart olmaz (kayıt
    satırı ve klip kalır): motosiklet sınıfı iz (26–28.11'de 4 kartın 4'ü
    polis), kapıda tek görünümde kaybolan parça, kapıda hiç görülmeyen çıkış.
    Plakası okunan ya da tahmin edilen olay bu eşiğe bakmaz, eskisi gibi gider.
    """
    iz = olay.iz
    if (getattr(iz.gecis, "arac_sinif", None) == arac.MOTOSIKLET
            or (olay.tur == "KAPIDA_KAYBOLDU" and iz.gorunum_no < 2)
            or (olay.tur == "CIKTI" and iz.kapida_gorulmedi)):
        return float("inf")
    return okuma.iz_arac_esigi(olay.tur, bulucu.esik, bulucu.gecis_esik,
                               komsu=olay.iz.dogumda_komsu,
                               sinif=getattr(olay.iz.gecis, "arac_sinif", None),
                               moto_esik=getattr(bulucu, "moto_esik", None),
                               kart_esik=getattr(bulucu, "kart_esik", None))   # 1.4.6 B


def kararsiz_satiri(iz, yer: str) -> str:
    """
    1.4.2 (A2): karar vermeden biten araç izinin kayıt satırı — nerede bitti,
    kaç görünüm, en iyi araç puanı, plaka kutusu görüldü mü. Plaka YAZILMAZ.
    1.4.3: puanın ardında sınıfı ("araç 0.47 motosiklet").
    """
    g = iz.gecis
    a = getattr(g, "arac_max", None)
    arac_s = (f"araç {a:.2f}{okuma.sinif_eki(getattr(g, 'arac_sinif', None))}"
              if a is not None else "araç —")
    plaka_s = "plaka görüldü" if getattr(g, "kutulu", None) is not None else "plaka görülmedi"
    return (f"[i] {gunluk.KARARSIZ_ISARETI} (iz {iz.id}, yer {yer}, {iz.gorunum_no} görünüm, "
            f"{arac_s}, {plaka_s})")


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
        # 1.4.0: kırpma ALANI (çokgen) varsa o; yoksa eski kutu + hariç alanlar.
        alan = alan_metni_coz(str(ayar.get("KIRPMA_ALAN") or ""))
        if alan is not None:
            kutu, haric, uyari = alan_kutusu(alan), None, None
        else:
            kutu = kutu_metni_coz(str(ayar.get("KIRPMA") or ""))
            haric, uyari = haric_metni_coz(str(ayar.get("KIRPMA_HARIC") or ""), kutu)
    except ValueError as e:
        print(f"  ✗ Ayar dosyasında hatalı kırpma: {e}")
        return 1
    try:
        kapi = plaka.cokgen_metinden(str(ayar.get("KAPI_ALANI") or ""))
    except ValueError as e:
        print(f"  ✗ Ayar dosyasında hatalı KAPI_ALANI: {e}")
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
    # 1.4.2: köprüyle AYNI küme (önce grafik işlemcisi, olmazsa işlemci).
    kume = hizlandirici.modelleri_yukle(p_ayar, p_ayar["arac_acik"])
    p, bulucu = kume.plakaci, kume.bulucu
    if p is None:
        print(f"  ✗ Plaka okuyucu çalışmıyor: {kume.plaka_hata}")
        return 1
    print(f"  ✓ Plaka okuyucu hazır ({kume.ad}).")
    # 1.3.1: araç bulucu da — çalışmasa test sürer (köprü de 1.3.0 kuralıyla sürer).
    if not p_ayar["arac_acik"]:
        print("  ! ARAC_BUL=0: köprü bu şeritte araç bulucuyu kullanmıyor.")
    elif bulucu is not None:
        print(f"  ✓ Araç bulucu hazır (duran ≥{bulucu.esik:.2f}, geçen ≥{bulucu.gecis_esik:.2f}).")
    else:
        print(f"  ! Araç bulucu çalışmıyor: {kume.arac_hata} — köprü plakasız duranları 1.3.0 "
              "kuralıyla personele bırakır.")

    # Adres şifre taşır: ekrana yalnızca kameranın adresi yazılır.
    try:
        host = urlparse(rtsp).hostname or "?"
    except ValueError:
        host = "?"
    print(f"  Kamera: {host}   ({int(sure_sn)} sn; Ctrl+C ile erken bitirebilirsiniz)")
    print("  Araç geçirin. Her satır: saat · süre · kutu skoru → okuma (iki kırpıntı)"
          + (" · araç / insan puanı" if bulucu else "") + ".")
    print("  1.3.3: köprüde iki model AYNI ANDA çalışır; satırdaki ms ikisinden yavaş\n"
          "  olanıdır (burada sırayla ölçülür — gerçekte işlemciyi paylaşırlar).")
    if bulucu is not None:
        # 1.4.0: köprünün izleyicisi burada da çalışır — kapı alanının doğru
        # çizildiğini görmek için: "ARAÇ GİRDİ / ÇIKTI" satırları.
        print(f"  Araç izleme: kapı alanı {'var' if kapi else 'yok'} — araç girip "
              "durunca / kapıda kaybolunca '→' satırı yazılır.")
        # 1.4.5: köprüdeki üç anahtar (kopru-ortak.json).
        print("  1.4.5: " + ", ".join(
            f"{ad}={int(bool(p_ayar[k]))}" for ad, k in
            (("TEK_KARAR", "tek_karar"), ("IZ_ONAY", "iz_onay"), ("BYTE_ESLES", "byte_esles"))))
    # 1.4.3 (PARK_GORUNUR): köprü gibi — yalnızca kırpma alanıyla.
    park_gorunur = bool(p_ayar["park_gorunur"]) and alan is not None
    if p_ayar["park_gorunur"] and alan is None:
        print("  ! PARK_GORUNUR=1 yalnızca kırpma alanıyla (KIRPMA_ALAN) çalışır — kapalı.")
    elif park_gorunur:
        print("  Park görünür (PARK_GORUNUR=1): modeller alanın dışını da görür; dışarıdaki "
              "plaka yalnızca yürüyen araçta okunur, olay yalnızca alana girmiş araçtan.")
    print()
    olay_adi = PLAKA_OLAY_ADLARI
    # 1.4.3: tek kapıda yönü bilinmeyen olayın emin plakası PLAKA gider.
    tek_kapi = str(ayar.get("YON") or YON).strip().upper() == "ORTAK"
    olay_sayisi = {k: 0 for k in olay_adi}
    izci: takip.Takipci | None = None

    def olay_karari(olay: takip.Olay, simdi: float) -> list:
        """Köprünün kararı (gönderimler) — köprüdeki gibi, IZ_ONAY'la."""
        gon, _ = okuma.iz_karari(olay.iz.gecis, olay_zamani=olay.zaman,
                                 son_gonderilen=[], simdi=simdi,
                                 arac_gecis_esik=olay_arac_esigi(olay, bulucu),
                                 personele=okuma.iz_personele(olay.tur),
                                 tek_kapi=tek_kapi,
                                 plaka_sart=p_ayar["iz_onay"] and olay.tur == "TEK_KARE")
        return gon

    def olay_kart_mi(olay: takip.Olay, simdi: float) -> bool:
        """1.4.5 A: olay şimdi gönderilse personele kart mı olurdu."""
        return olay.tur in OLAY_ADLARI and any(
            g.tur != "PLAKA" for g in olay_karari(olay, simdi))

    def olay_goster(olay: takip.Olay, simdi: float) -> bool:
        """Bir izleme olayının '→' satırı; döndürdüğü: bir şey gönderilirdi mi."""
        ek, gonderilirdi = "", False
        if olay.tur in OLAY_ADLARI:
            gon = olay_karari(olay, simdi)
            gonderilirdi = bool(gon)
            if not gon:
                ek = ": gönderilmezdi"
            elif gon[0].tur == "PLAKA":
                ek = f": {gon[0].plaka} gönderilirdi"
            else:
                ek = f": personele (tahmin {gon[0].tahmin or 'yok'})"
        kapida = (f", {gunluk.KAPIDA_GORULMEDI_ISARETI}"
                  if olay.iz.kapida_gorulmedi else "")
        print(f"  {time.strftime('%H:%M:%S')}  → {olay_adi[olay.tur]} "
              f"(iz {olay.iz.id}{kapida}){ek}", flush=True)
        return gonderilirdi

    # 1.4.5 A: köprüdeki gibi (TEK_KARAR): sahadaki kaydı oynatınca "aynı
    # aracın parçası sayıldı" satırları da görünür, kart satırı bir kez.
    gecitci = takip.Gecitci(
        gonder=olay_goster, kart_mi=olay_kart_mi, plakalar=okuma.iz_plakalari,
        acik=p_ayar["tek_karar"], ikiz_sn=p_ayar["ikiz_sn"],
        yaz=lambda x: print(f"  {time.strftime('%H:%M:%S')}  → {x.removeprefix('[i] ')}",
                            flush=True))
    durgun_esik = DURGUN_ESIGI
    try:
        durgun_esik = float(ayar.get("DURGUN_ESIGI") or DURGUN_ESIGI)
    except (TypeError, ValueError):
        pass

    cap = (kamera or kamera_baglan)(rtsp)
    kareler = kutulu = bos = 0
    arac_kare = 0
    arac_enb = 0.0
    emin: dict[str, int] = {}
    sureler: list[float] = []        # kare başına: iki modelden yavaş olanı
    sureler_p: list[float] = []      # plaka okuyucu
    sureler_a: list[float] = []      # araç bulucu
    karsilastirma = False            # 1.3.4: kırpıntı küçültüldü, iki yoldan okundu
    emin_tam_kare = emin_kucuk_kare = 0
    genislikler: list[float] = []    # 1.4.1: plakaların tam çözünürlükteki genişliği (px)
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
            maskeli = kirp_maskeli(frame, kutu, haric, alan)
            kirpik = olcekle(maskeli)
            # 1.3.4: köprü gibi — kırpıntı küçültüldüyse plaka TAM çözünürlükten
            # okunur; karşılaştırma için küçükten de okunur (süreye sayılmaz).
            tam = maskeli if (p_ayar["tam"] and maskeli.shape[:2] != kirpik.shape[:2]) else None
            if haric is not None and sekil != kirpik.shape:
                sekil = kirpik.shape
                haric_k = haric_olcekli(frame.shape, kutu, haric, kirpik.shape)
            elif alan is not None and sekil != kirpik.shape:
                sekil = kirpik.shape
                haric_k = alan_maskesi(frame.shape, kutu, alan, kirpik.shape)
            if bulucu is not None and (izci is None or (izci.en, izci.boy) != kirpik.shape[1::-1]):
                if izci is not None:
                    gecitci.birak(time.monotonic())
                izci = takip.Takipci(
                    kirpik.shape[1], kirpik.shape[0],
                    None if kapi is None else kapi_kirpikta(frame.shape, kutu, kapi, kirpik.shape),
                    dogum_esik=bulucu.esik, durgun_esik=durgun_esik,
                    yeni_gecis=lambda: okuma.Gecis(0, datetime.now(timezone.utc),
                                                   plaka.Oylama(tek_esik=p_ayar["tek_esik"],
                                                                birlesik=p_ayar["birlesik"])),
                    yaz=okuma.plakalari_yaz,
                    alan=izci_alani(park_gorunur, frame.shape, kutu, alan, kirpik.shape),
                    byte_esles=p_ayar["byte_esles"])
            # 1.4.3 (PARK_GORUNUR): modeller maskesiz kırpıntıyı görür; alanın
            # kenarı plakayı kesmez; dışarıdaki plaka yalnızca yürüyen izin
            # kutusunda okunur. İzci (fotoğraf) maskeli kırpıntıyı alır.
            if park_gorunur:
                model_k, model_tam = acik_kirpik(frame, kutu, tam is not None)
                kesen = None
                disari = izci.okunacak_kutular(time.monotonic()) if izci is not None else ()
            else:
                model_k, model_tam, kesen, disari = kirpik, tam, haric_k, ()
            t0 = time.perf_counter()
            try:
                parcalar = []
                kutular = okuma.kutulari_bul(p, model_k, haric_k, disari)
                okumalar = [okuma.kutuyu_oku(p, model_k, k, kesen, p_ayar["oku_esik"],
                                             tam=model_tam)
                            for k in kutular]
                ms_p = (time.perf_counter() - t0) * 1000
                kucukler = ([okuma.kutuyu_oku(p, model_k, k, kesen, p_ayar["oku_esik"])
                             for k in kutular] if model_tam is not None else [None] * len(kutular))
                for k, s, sk in zip(kutular, okumalar, kucukler):
                    gen = okuma.plaka_genisligi_tam(k, kirpik.shape[1], maskeli.shape[1])
                    genislikler.append(gen)
                    if s is None:
                        parcalar.append(f"{k.skor:.2f} kesik (kenara değiyor, okunmaz) · {gen:.0f} px")
                        continue
                    (m1, e1), (m2, e2) = s[0]
                    if s[1] is not None:
                        emin[s[1][0]] = emin.get(s[1][0], 0) + 1
                        metin = f"{k.skor:.2f} → {s[1][0]} ({e1:.3f} / {e2:.3f}) EMİN"
                    else:
                        metin = f"{k.skor:.2f} → belirsiz: {m1} ({e1:.3f}) / {m2} ({e2:.3f})"
                    if tam is not None:
                        if sk is None:
                            metin += " · küçük: okunamadı"
                        elif sk[1] is not None:
                            metin += f" · küçük: {sk[1][0]} EMİN"
                        else:
                            metin += f" · küçük: belirsiz {sk[0][0][0]} ({sk[0][0][1]:.3f})"
                    parcalar.append(metin + f" · {gen:.0f} px")
                if tam is not None:
                    karsilastirma = True
                    if any(s is not None and s[1] is not None for s in okumalar):
                        emin_tam_kare += 1
                    if any(sk is not None and sk[1] is not None for sk in kucukler):
                        emin_kucuk_kare += 1
            except Exception as e:  # noqa: BLE001 — test kipi: sebebi göster, dur
                print(f"  ✗ Plaka okuyucu hata verdi: {type(e).__name__}: {e}")
                return 1
            sureler_p.append(ms_p)
            ms_a = 0.0
            puan = ""
            arac_var = False
            araclar = None
            if bulucu is not None:
                t1 = time.perf_counter()
                try:
                    araclar, i = bulucu.kutular(model_k, None if park_gorunur else haric_k)
                except Exception as e:  # noqa: BLE001 — köprüde de plaka okumayı durdurmaz
                    print(f"  ! Araç bulucu hata verdi: {type(e).__name__}: {e}")
                    bulucu = None
                    if izci is not None:
                        gecitci.birak(time.monotonic())      # 1.4.5 A: bekleyen kaybolmasın
                    izci = None
                else:
                    ms_a = (time.perf_counter() - t1) * 1000
                    sureler_a.append(ms_a)
                    a = max((k.skor for k in araclar), default=0.0)
                    puan = f"araç {a:.2f} / insan {i:.2f}"
                    arac_enb = max(arac_enb, a)
                    if a >= bulucu.esik:
                        arac_var = True
                        arac_kare += 1
            ms = max(ms_p, ms_a)
            sureler.append(ms)
            simdi = time.monotonic()
            if izci is not None and araclar is not None:
                o = takip.Olcum(kareler, simdi, datetime.now(timezone.utc), kirpik,
                                gri_kucuk(model_k), list(araclar), list(zip(kutular, okumalar)))
                olaylar = izci.guncelle(o) + izci.zaman_gecti(simdi)
                for olay in olaylar:
                    olay_sayisi[olay.tur] += 1
                gecitci.al(izci, olaylar, simdi)
                for z, yer in izci.kararsiz_al():          # 1.4.2 (A2)
                    print(f"  {time.strftime('%H:%M:%S')}  → "
                          f"{kararsiz_satiri(z, yer).removeprefix('[i] ')}", flush=True)
            if parcalar or arac_var:
                if parcalar:
                    kutulu += 1
                print(f"  {time.strftime('%H:%M:%S')}  {ms:5.0f} ms  "
                      + " · ".join((parcalar or ["plaka yok"]) + ([puan] if puan else [])),
                      flush=True)
                son_satir = simdi
            elif simdi - son_satir >= PLAKA_TEST_SESSIZ_SN:
                print(f"  {time.strftime('%H:%M:%S')}  {ms:5.0f} ms  plaka yok"
                      + (f" · {puan}" if puan else ""), flush=True)
                son_satir = simdi
            if ara_sn:
                time.sleep(ara_sn)
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
    if izci is not None and bulucu is not None:
        gecitci.birak(time.monotonic())           # 1.4.5 A: bekleyen kart satırı yazılır

    print()
    if not kareler:
        print("  ✗ Kameradan hiç görüntü gelmedi.")
        return 1
    print(f"  {kareler} kare · {kutulu} karede plaka kutusu")
    ort_p = sum(sureler_p) / len(sureler_p)
    satir = (f"  Süre: plaka okuyucu ortalama {ort_p:.0f} ms (en çok {max(sureler_p):.0f})")
    yavas = ort_p
    if sureler_a:
        ort_a = sum(sureler_a) / len(sureler_a)
        satir += f", araç bulucu ortalama {ort_a:.0f} ms (en çok {max(sureler_a):.0f})"
        yavas = max(yavas, ort_a)
    print(satir)
    hiz = 1000.0 / yavas if yavas > 0 else float("inf")
    print(f"  Köprüde iki model aynı anda çalışır: kare başına ~{yavas:.0f} ms "
          f"(~{min(hiz, 99.0):.1f} kare/sn; işlemciyi paylaştıkları için biraz daha az olabilir).")
    if bulucu is not None:
        print(f"  Araç bulucu: {arac_kare} karede araç (≥{bulucu.esik:.2f}), "
              f"en yüksek puan {arac_enb:.2f}.")
        print(f"  İzleme: {olay_sayisi['GIRDI']} giriş, {olay_sayisi['CIKTI']} çıkış, "
              f"{olay_sayisi['ICERIDE']} otopark içi hareket, {olay_sayisi['ESKI_GIRDI']} "
              f"açılışta kapıdaki, {olay_sayisi['KAPISIZ']} kapısız, "
              f"{olay_sayisi['GERI_DONDU']} geri dönen, {olay_sayisi['TEK_KARE']} tek karede.")
        _, sayildi = gecitci.son_saat(time.monotonic())
        print(f"  Tek karar (TEK_KARAR={int(gecitci.acik)}): "
              + (f"{sayildi} kart aynı geçişin parçası sayıldı (gönderilmezdi)."
                 if gecitci.acik else "kapalı — her izin kartı ayrı gönderilirdi."))
    if karsilastirma:
        print(f"  Emin okuma: tam çözünürlükte {emin_tam_kare} kare, küçültülmüşte "
              f"{emin_kucuk_kare} kare. (Köprü tam çözünürlüğü kullanır; PLAKA_TAM=0 "
              "küçültülmüşe döner.)")
    boy_ozeti = okuma.plaka_boyu_ozeti(genislikler)
    if boy_ozeti:
        print(f"  {boy_ozeti}")
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

    # 1.4.0: kırpma ALANI (çokgen) varsa o geçerli; eski kutu / hariç yok sayılır.
    alan = kirpma_alani()
    if alan is not None:
        if KIRPMA or KIRPMA_HARIC:
            print("[!] KIRPMA_ALAN verildi — KIRPMA / KIRPMA_HARIC yok sayılıyor", flush=True)
        kutu = alan_kutusu(alan)
        haric = None
        print(f"[i] kırpma alanı ({len(alan)} köşe) — dışı griye boyanır, orada hareket "
              "ve plaka yok sayılır", flush=True)
    else:
        kutu = kirpma_kutusu()
        haric = kirpma_haric(kutu)
    if kutu is None:
        print("[!] KIRPMA verilmedi — tüm kare okunacak, plaka küçük kalır", flush=True)
        # `[i]`: not a fault, durum must not show it as the last error.
        print("[i] kırpma kutusu yok — bu şeritte araç fotoğrafı saklanmayacak", flush=True)
    if haric is not None:
        print(f"[i] kesilen köşe {'; '.join(','.join(str(v) for v in h) for h in haric)} — "
              "orada hareket ve plaka "
              "yok sayılır", flush=True)
    # 1.4.0: kapı alanı. Bozuksa köprü DÜŞMEZ: kapı kuralı olmadan izler.
    try:
        kapi = plaka.cokgen_metinden(KAPI_ALANI)
    except ValueError as e:
        kapi = None
        print(f"[!] {gunluk.KAPI_ALANI_YOK_ISARETI}: KAPI_ALANI geçersiz ({e}) — araçlar "
              "durunca / kaybolunca sayılacak", flush=True)

    # ---- 1.3.0: plaka okuyucu. Yüklenemezse köprü DÜŞMEZ: araçlar personele.
    p_ayar, p_uyarilar = plaka.calisma_ayarlari()
    for u in p_uyarilar:
        print(f"[!] {u}", flush=True)
    plakaci = None
    sebep: str | None = None
    # ---- 1.3.1: araç bulucu. Yüklenemezse köprü DÜŞMEZ: 1.3.0 kuralıyla sürer
    # (duran plakasız her şey personele) — araç kaybolmaz.
    bulucu = None
    # ---- 1.4.2: modeller önce grafik işlemcisinde; olmazsa işlemcide (1.4.1).
    model_kumesi = "—"
    if p_ayar["acik"]:
        kume = hizlandirici.modelleri_yukle(p_ayar, p_ayar["arac_acik"])
        model_kumesi = kume.ad
        plakaci, bulucu = kume.plakaci, kume.bulucu
        if plakaci is not None:
            print(f"[i] {gunluk.PLAKA_HAZIR_ISARETI} ({kume.ad})", flush=True)
        else:
            sebep = kume.plaka_hata
            print(f"[!] {gunluk.OKUYUCU_BOZUK_ISARETI}: {sebep} — araçlar personele gidecek",
                  flush=True)
    else:
        sebep = "kapalı (PLAKA_BUL=0)"
        print(f"[i] {gunluk.PLAKA_KAPALI_ISARETI} (PLAKA_BUL=0) — araçlar personele gidecek",
              flush=True)
    if plakaci is None:
        pass        # okuyucu yoksa işçi iş almaz; bulucu da çalışamaz
    elif not p_ayar["arac_acik"]:
        print(f"[i] {gunluk.ARAC_KAPALI_ISARETI} (ARAC_BUL=0)", flush=True)
    elif bulucu is not None:
        # Eşikler YÜKLENEN bulucunun (modelin): YOLO11s'inki tiny'ninkinden farklı.
        print(f"[i] {gunluk.ARAC_HAZIR_ISARETI} (duran ≥{bulucu.esik:.2f}, "
              f"geçen ≥{bulucu.gecis_esik:.2f})", flush=True)
    else:
        print(f"[!] {gunluk.ARAC_BOZUK_ISARETI}: {kume.arac_hata} — plakasız araçlar 1.3.0 "
              "kuralıyla personele gidecek", flush=True)
    # ---- 1.4.0: araç izleme. Bulucu ve okuyucu ŞART; yoksa 1.3.4 geçiş kuralı.
    if not p_ayar["takip"]:
        takip_sebep = "TAKIP=0"
    elif plakaci is None:
        takip_sebep = "plaka okuyucu yok"
    elif bulucu is None:
        takip_sebep = "araç bulucu yok"
    else:
        takip_sebep = None
    izleme = takip_sebep is None
    # 1.4.3: çalışırken kapanan izleme, bulucu / okuyucu yeniden çalışınca açılır.
    izleme_istendi = izleme
    if izleme:
        print(f"[i] {gunluk.TAKIP_ACIK_ISARETI} (kapı alanı {'var' if kapi else 'yok'})",
              flush=True)
    else:
        print(f"[i] {gunluk.TAKIP_KAPALI_ISARETI} ({takip_sebep}) — 1.3.4 geçiş kuralı",
              flush=True)
    # 1.4.3 (PARK_GORUNUR, sahip 19.11): izleme karelerinde modeller kırpma
    # alanının DIŞINI da görür (Frigate: maske nesneyi kaybettirir); olay
    # yalnızca alana / kapıya girmiş izden. 1.4.5 (sahip 22.11): fotoğraf ve
    # klip de maskesiz (alanın dışındaki araç gri katmanın arkasında kalmasın);
    # hareket ve 1.3.4 geçiş kuralı maskeli kalır. Yalnızca çokgenle.
    park_gorunur = bool(p_ayar["park_gorunur"]) and alan is not None
    if p_ayar["park_gorunur"] and alan is None:
        print("[!] PARK_GORUNUR=1 yalnızca kırpma alanıyla (KIRPMA_ALAN) çalışır — kapalı",
              flush=True)
    elif park_gorunur and izleme_istendi:        # TAKIP=0: 1.3.4 kuralı maskeli kalır
        print("[i] park görünür (PARK_GORUNUR=1) — modeller kırpma alanının dışını da görür; "
              "olay yalnızca alana girmiş araçtan; fotoğraf ve klip de maskesiz", flush=True)
    global _isci, _giden
    isci = okuma.Isci(plakaci, haric=None, oku_esik=p_ayar["oku_esik"], sebep=sebep,
                      arac=bulucu)
    _isci = isci
    # 1.4.2: grafik işlemcisi istendiyse onu geri getirmeye çalışan denetçi —
    # açılışta GPU yoksa da, çalışırken bırakılırsa da (30 sn'de bir).
    geri = None
    gpu_adi = (f"GPU · {hizlandirici.arac_profili(p_ayar).ad}" if p_ayar["arac_acik"]
               else "GPU")
    if plakaci is not None and p_ayar["hizlandirici"] == "GPU":
        geri = hizlandirici.GpuGeriDonus(plakaci, bulucu, ayar=p_ayar)

    def kume_etiketi() -> str:
        return geri.etiket(gpu_adi) if geri is not None else \
            hizlandirici.kalp_etiketi(model_kumesi)

    def gpu_yeniden_baslat_belki(sakin: bool) -> None:
        """GPU 10 dk'dır dönmüyorsa ve an sakinse: kayıt, zaman, çıkış."""
        if geri is None or not sakin or not geri.yeniden_baslat_gerek():
            return
        geri.yeniden_baslatiliyor()
        print(f"[!] {gunluk.GPU_YENIDEN_BASLAT_ISARETI} — {kume_etiketi()}; son hata: "
              f"{geri.son_hata}; görev birkaç dakika içinde yeniden açar", flush=True)
        _gpu_cik()

    # Before the first camera wait: a startup that hangs is as blind as a loop
    # that hangs. The waits themselves stamp through uyu().
    canli()
    threading.Thread(target=bekci, daemon=True).start()

    # ---- 1.3.0: gönderim kutusu. Her araç ÖNCE diske, sonra sunucuya.
    # 1.4.3: kamera açılmadan ÖNCE başlar — elektrik kesintisinden önce kutuda
    # kalan araçlar kamera / switch gelene kadar beklemesin. Bedeli: o araçların
    # her gönderimi sunucuda bir kalp sayılır (webhook her doğrulanmış isteği
    # sayar); bekçinin "kamera yok" uyarısı en çok son gönderimden itibaren
    # gecikir, kamera açılmazsa yine gelir.
    _giden = giden.Giden(os.path.join(gunluk.kayit_klasoru(), f"giden-{YON.lower()}"))
    bekleyen, _en_eski = giden.ozet(_giden.klasor)
    if bekleyen:
        print(f"[i] gönderim kutusunda {bekleyen} araç bekliyordu — gönderiliyor", flush=True)
    threading.Thread(target=giden.calistir, args=(_giden, gonder_olay), daemon=True,
                     name="gonderici").start()

    print(f"[i] kamera açılıyor ({YON})", flush=True)
    cap = kamera_ac(bekle=True)
    print(f"[i] {gunluk.KAMERA_VAR_ISARETI}", flush=True)

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
    son_durgun_tam: np.ndarray | None = None   # 1.3.4: aynı karenin tam çözünürlüğü
    plaka_tam = bool(p_ayar["tam"])

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
    # 1.4.3: (plaka ya da tahmin, monotonic, emin mi, yön ipucu) — okuma.gonderim_kaydi.
    son_gonderilen: list[tuple[str | None, float, bool, str | None]] = []
    # 1.4.6 K: iz kimliği → (GİRDİ diye gönderilen emin plaka, monotonic).
    giris_izleri: dict[int, tuple[str, float]] = {}
    # 1.4.6 E2: ertelenen içeride soruları — (olay, ilk soruluş anı).
    ertelenen_iceride: list[tuple[takip.Olay, float]] = []
    # 1.4.6 L: plaka kırpığı klasörünün son temizlendiği an (monotonic).
    kirpik_temizlik = [float("-inf")]
    haric_sekli: tuple | None = None

    # ---- 1.4.0: araç izleme durumu (izleme=False iken hiç kullanılmaz).
    izci: takip.Takipci | None = None
    izci_sekli: tuple | None = None
    kare_no = 0                       # işçiye verilen son izleme karesi
    son_biten = 0                     # izciye işlenen son kare (eskisi atlanır)
    son_kare_t = float("-inf")        # son izleme karesinin verildiği an
    son_kipirti = float("-inf")       # kırpıntıda son kıpırtı (d ≥ DURGUN_ESIGI)
    # 1.4.2 (A1): son YEREL kıpırtı (bir yamanın farkı ≥ DURGUN_ESIGI). Yalnız
    # model karesi tetiği; son_kipirti GPU'nun "sakin an"ına da bakar, o değişmez
    # (gece gürültüsü sakin anı hiç gelmez yapmasın).
    son_yerel = float("-inf")
    kare_no_kalp = 0                  # son "çalışıyor" satırındaki kare_no

    def izci_kur(frame_sekli: tuple, kirpik_sekli: tuple) -> takip.Takipci:
        en, boy = kirpik_sekli[1], kirpik_sekli[0]
        k = None
        if kapi is not None:
            k = kapi_kirpikta(frame_sekli, kutu, kapi, kirpik_sekli)
            ic = plaka.cokgen_dis_maskesi(k, en, boy) == 0
            if alan is not None:
                ic &= plaka.cokgen_dis_maskesi(
                    _alan_kirpintida(frame_sekli, kutu, alan, kirpik_sekli), en, boy) == 0
            if not ic.any():
                print(f"[!] {gunluk.KAPI_ALANI_YOK_ISARETI}: kapı alanı kırpmayla kesişmiyor "
                      "— araçlar durunca / kaybolunca sayılacak", flush=True)
                k = None
        return takip.Takipci(
            en, boy, k, dogum_esik=bulucu.esik, durgun_esik=DURGUN_ESIGI,
            yeni_gecis=lambda: okuma.Gecis(0, datetime.now(timezone.utc),
                                           plaka.Oylama(tek_esik=p_ayar["tek_esik"],
                                                        birlesik=p_ayar["birlesik"])),
            yaz=okuma.plakalari_yaz,
            alan=izci_alani(park_gorunur, frame_sekli, kutu, alan, kirpik_sekli),
            byte_esles=p_ayar["byte_esles"])        # 1.4.5 C

    olay_adlari, yalniz_kayit = OLAY_ADLARI, YALNIZ_KAYIT

    def kararsizlari_yaz() -> None:
        """1.4.2 (A2): izcinin kararsız biten araç izleri — her biri bir kayıt satırı."""
        if izci is not None:
            for z, yer in izci.kararsiz_al():
                print(kararsiz_satiri(z, yer), flush=True)

    def yonune_ters(olay: takip.Olay) -> bool:
        """Şeridin yönü: giriş şeridi çıkışı, çıkış şeridi girişi göndermez
        (tek kapıda ORTAK ikisini de gönderir; yönü sunucu bilet durumundan bilir)."""
        return (YON == "GIRIS" and olay.tur == "CIKTI") or (
            YON == "CIKIS" and olay.tur in ("GIRDI", "ESKI_GIRDI"))

    def iz_karari(olay: takip.Olay, simdi: float):
        """
        Olayın kararı (okuma.iz_karari) — yan etkisiz: hem gönderirken hem
        1.4.5 A'nın "kart mı olurdu" sorusunda. 1.4.5 B (IZ_ONAY): tek karede
        görülen aracın kartı ancak plakası okunduysa.
        """
        return okuma.iz_karari(
            olay.iz.gecis, olay_zamani=olay.zaman, son_gonderilen=donus_bellegi(olay, simdi),
            simdi=simdi,
            arac_gecis_esik=olay_arac_esigi(olay, bulucu),
            personele=okuma.iz_personele(olay.tur), tek_kapi=YON == "ORTAK",
            plaka_sart=p_ayar["iz_onay"] and olay.tur == "TEK_KARE",
            kapi_olayi=kapi_olayi_mi(olay))                       # 1.4.6 A

    def donus_girisi(olay: takip.Olay, simdi: float) -> str | None:
        """1.4.6 K: bu ÇIKTI'nın izi AYNI_IZ_SN içinde GİRDİ diye gönderildiyse o plaka."""
        kayit = giris_izleri.get(olay.iz.id) if olay.tur == "CIKTI" else None
        return kayit[0] if kayit is not None and simdi - kayit[1] <= AYNI_IZ_SN else None

    def donus_bellegi(olay: takip.Olay, simdi: float) -> list:
        """
        1.4.6 K: aynı izin az önceki GİRDİ kaydı kendi ÇIKTI'sını 60 sn
        kuralıyla düşürmesin — araç gerçekten döndü. Başka kayıtlar aynen.
        """
        p = donus_girisi(olay, simdi)
        if p is None:
            return son_gonderilen
        return [k for k in son_gonderilen if not (k[0] == p and len(k) > 3 and k[3] == "GIRDI")]

    def kapida_dondu(olay: takip.Olay, gonderimler: list) -> bool:
        """
        1.4.6 J (sahibin kararı 25.11): kenardan kapı alanına girip aynı
        kenardan dönen araç (takip: `kenarda_dondu`) KART olacaksa gönderilmez.
        Emin plakası okunduysa eskisi gibi gider (sunucu bilet durumundan bilir).
        """
        return (olay.tur == "KAPIDA_KAYBOLDU" and getattr(olay.iz, "kenarda_dondu", False)
                and any(g.tur != "PLAKA" for g in gonderimler))

    def iz_kart_mi(olay: takip.Olay, simdi: float) -> bool:
        """1.4.5 A: olay ŞİMDİ gönderilse personele kart mı olurdu (Gecitci bekletir)."""
        if olay.tur in yalniz_kayit or yonune_ters(olay):
            return False
        gonderimler, _ = iz_karari(olay, simdi)
        if kapida_dondu(olay, gonderimler):
            return False
        return any(g.tur != "PLAKA" for g in gonderimler)

    def iz_gonder(olay: takip.Olay, simdi: float) -> bool:
        """
        1.4.0: izcinin bir olayı → karar (okuma.iz_karari) → gönderim kutusu.
        1.4.3 (1a): döndürdüğü "ele alındı" — bir şey gönderildi ya da bilerek
        gönderilmedi (şeridin yönü, 60 sn kuralı). 1.4.5 A: Gecitci ele
        alınmış kararı aynı geçişin bekleyen kartlarına karşı hatırlar.
        """
        nonlocal son_gonderilen
        if olay.tur in yalniz_kayit:
            print(f"[i] {yalniz_kayit[olay.tur]} (iz {olay.iz.id})", flush=True)
            if olay.tur == "ICERIDE" and YON == "ORTAK":
                iceride_sor(olay, simdi)
            return False
        adi = olay_adlari[olay.tur]
        if yonune_ters(olay):
            print(f"[i] {adi} — {gunluk.YON_DISI_ISARETI} (iz {olay.iz.id})", flush=True)
            return True
        gonderimler, satirlar = iz_karari(olay, simdi)
        teshis = (f"[i] {okuma.plaka_teshisi(olay.iz.gecis, p_ayar['oku_esik'])} "
                  f"(iz {olay.iz.id})")                           # 1.4.6 L
        if kapida_dondu(olay, gonderimler):                     # 1.4.6 J
            print(f"[i] {gunluk.KAPIDA_DONDU_ISARETI} (iz {olay.iz.id}, "
                  f"{olay.iz.gorunum_no} görünüm)", flush=True)
            print(teshis, flush=True)
            klip_iste(olay, simdi, None)
            return True
        plaka_sayisi = sum(1 for g in gonderimler if g.tur == "PLAKA")
        personel = len(gonderimler) - plaka_sayisi
        ozet = (f"{plaka_sayisi} plaka" if plaka_sayisi else "") + \
            (", " if plaka_sayisi and personel else "") + \
            (f"{personel} personele" if personel else "")
        kapida = f", {gunluk.KAPIDA_GORULMEDI_ISARETI}" if olay.iz.kapida_gorulmedi else ""
        print(f"[i] {adi} (iz {olay.iz.id}, {olay.iz.gorunum_no} görünüm{kapida}) — "
              f"{ozet + ' gönderiliyor' if ozet else 'gönderim yok'}", flush=True)
        for s in satirlar:
            print(s, flush=True)
        print(teshis, flush=True)
        ipucu = HAREKET_IPUCU.get(olay.tur)              # 1.4.2 (B5); 1.4.6 D: kart da
        donen = donus_girisi(olay, simdi)                # 1.4.6 K
        kimlikler = []
        for g in gonderimler:
            if ipucu:
                g = g._replace(hareket=ipucu)
            if g.tur == "PLAKA" and donen is not None and g.plaka == donen:
                g = g._replace(ayni_iz_dondu=True)
                print(f"[i] {gunluk.AYNI_IZ_DONDU_ISARETI} (iz {olay.iz.id})", flush=True)
            if g.tur == "PLAKA" and olay.tur == "GIRDI":
                giris_izleri[olay.iz.id] = (g.plaka, simdi)
            if olay.iz.giris_karti:                          # 1.4.7 F4
                g = g._replace(giris_islem_id=olay.iz.giris_karti)
            kimlik = araci_gonder(g, kutu)
            if kimlik is not None:
                kimlikler.append(kimlik)
                if olay.tur == "GIRDI" and g.tur == "OKUNAMADI" and not olay.iz.giris_karti:
                    olay.iz.giris_karti = kimlik             # 1.4.7 F4
                if g.tur != "PLAKA" and p_ayar["plaka_kirpik"]:    # 1.4.6 L
                    kirpik_kaydet(olay, simdi, kimlik)
            son_gonderilen.append(okuma.gonderim_kaydi(g, simdi))
        son_gonderilen = [k for k in son_gonderilen if simdi - k[1] <= okuma.YAKIN_SN]
        for eski in [i for i, k in giris_izleri.items() if simdi - k[1] > AYNI_IZ_SN]:
            giris_izleri.pop(eski)
        # 1.4.3 (1d): yönü bilinmeyen olay; 1.4.4 (sahibin kararı 21.11): HER
        # personel kartı — kapıdan girdiği / çıktığı izlenen plakasız araç da
        # (bir olay en çok bir gönderim: iz_karari) — ve HER çıkış, plakası
        # okunup bileti kapatan da (gece çıkışları kliplerden denetlensin).
        if (olay.tur in takip.YONSUZ_OLAYLAR or olay.tur == "CIKTI"
                or any(g.tur != "PLAKA" for g in gonderimler)):
            klip_iste(olay, simdi, kimlikler[0] if kimlikler else None)
        return bool(gonderimler) or any(gunluk.AYRILIS_ISARETI in s for s in satirlar)

    def kirpik_kaydet(olay: takip.Olay, simdi: float, islem_id: str) -> None:
        """
        1.4.6 L (sahibin kararı 25.11): kartın en iyi plaka kırpığı (tam
        çözünürlük) bu bilgisayara — adı klibinki gibi, plaka adda YOK; asla
        gönderilmez. Klasör KLIP_GUN gün / KIRPIK_EN_COK_BAYT ile saatte bir temizlenir.
        """
        img = okuma.plaka_kirpigi(olay.iz.gecis)
        if img is None:
            return
        zaman = olay.zaman if isinstance(olay.zaman, datetime) else datetime.now(timezone.utc)
        klasor = klip.kirpik_klasoru()
        yol = klip.kirpik_yaz(klasor, klip.kirpik_adi(zaman, olay.iz.id, olay.tur, islem_id), img)
        if yol is not None:
            print(f"[i] {gunluk.PLAKA_KIRPIK_YAZILDI_ISARETI} (iz {olay.iz.id})", flush=True)
        if simdi - kirpik_temizlik[0] >= klip.TEMIZLIK_SN:
            kirpik_temizlik[0] = simdi
            klip.temizle(klasor, time.time(), uzanti=".jpg", en_cok_bayt=klip.KIRPIK_EN_COK_BAYT)

    def klip_iste(olay: takip.Olay, simdi: float, islem_id: str | None,
                  gercek: takip.Olay | None = None) -> None:
        """
        1.4.3 (1d): olayın klibi (KLIP=1; kapalıysa hiçbir şey). Araç ilk
        görülmeden 5 sn önce .. olaydan 5 sn sonra. `gercek`: 1.4.5 A — kart
        aynı geçişin parçası sayıldı (gönderilmedi); klip iki izin erken
        doğanından başlar.
        """
        if klipci is None:
            return
        dogum = olay.iz.dogum_mono if gercek is None else min(olay.iz.dogum_mono,
                                                              gercek.iz.dogum_mono)
        bas, son = klip.pencere(dogum, simdi)
        zaman = olay.zaman if isinstance(olay.zaman, datetime) else datetime.now(timezone.utc)
        klipci.iste(bas, son, klip.klip_adi(zaman, olay.iz.id, olay.tur, islem_id,
                                            emildi=gercek is not None))

    def ertelenenleri_sor(simdi: float) -> None:
        """
        1.4.6 E2: ertelenen içeride soruları, kapıda karar bekleyen araç
        kalmayınca (ya da ICERIDE_ERTELEME_SN dolunca) sorulur. 60 sn kuralı
        o anki bellekle: giren aracın plakası az önce gittiyse soru düşer;
        giren araç kart olduysa soru kartın ardından gider (sunucu bağlar).
        """
        for olay, ilk in list(ertelenen_iceride):
            if simdi - ilk > ICERIDE_ERTELEME_SN or not kapi_bekliyor(olay, simdi):
                ertelenen_iceride.remove((olay, ilk))
                iceride_sor(olay, simdi, ertelendi=True)

    def kapi_bekliyor(olay: takip.Olay, simdi: float) -> bool:
        """
        İçeride sorusu beklesin mi: 1.4.6 E2 kapıda karar bekleyen canlı iz;
        1.4.7 F5 Gecitci'nin bekletilen kartı ya da ICERIDE_KAPI_SN içinde
        bir kapı olayı (kopan parçanın kartı sorudan önce gitsin).
        """
        if izci is not None and izci.giris_bekliyor(haric=olay.iz):
            return True
        return gecitci.kapi_yakin(simdi, ICERIDE_KAPI_SN)

    def iceride_sor(olay: takip.Olay, simdi: float, ertelendi: bool = False) -> None:
        """
        1.4.2 (B6, sahibin kararı): tek kapıda otoparkın İÇİNDE gezen aracın
        plakası EMİN okunduysa "içeride" ipucuyla sunucuya sorulur — sunucu
        bileti varsa hiçbir şey yapmaz (asla kapatmaz), yoksa "İçeride bileti
        olmayan araç" kaydı açar (056). Yalnızca emin plaka: ne personele kart
        (plakasız / belirsiz araç burada gönderilmez) ne de giriş şeridinde
        (orada sunucu plakayla bilet AÇARDI). 60 sn kuralı aynen: az önce
        giren araç durunca ikinci kez gitmez. 1.4.3 (sahibin kararı 18.11):
        az önce ÇIKTI diye gönderilen araç bu kurala takılmaz — sunucu
        kameranın kapattığı bileti görür ve "çıkmamış olabilir" kartı açar.
        """
        nonlocal son_gonderilen
        gonderimler, _ = okuma.iz_karari(
            olay.iz.gecis, olay_zamani=olay.zaman, son_gonderilen=son_gonderilen, simdi=simdi,
            arac_gecis_esik=float("inf"), personele=False, iceride=True)
        plakalar = [g._replace(hareket="ICERIDE", giris_islem_id=olay.iz.giris_karti)
                    for g in gonderimler if g.tur == "PLAKA"]             # 1.4.7 F4
        if not plakalar:
            if ertelendi:
                print(f"[i] {gunluk.AYRILIS_ISARETI} — ertelenen içeride sorusu "
                      f"(60 sn içinde aynı plaka, iz {olay.iz.id})", flush=True)
            return
        # 1.4.6 E2 (sahibin kararı 25.11): kapıdan giren aracın kararı
        # bekleniyorsa soru ertelenir (ertelenenleri_sor).
        if not ertelendi and kapi_bekliyor(olay, simdi):
            print(f"[i] {gunluk.ICERIDE_ERTELENDI_ISARETI} (iz {olay.iz.id})", flush=True)
            ertelenen_iceride.append((olay, simdi))
            return
        print(f"[i] {gunluk.ICERIDE_SORULDU_ISARETI} (iz {olay.iz.id})", flush=True)
        for g in plakalar:
            araci_gonder(g, kutu)
            son_gonderilen.append(okuma.gonderim_kaydi(g, simdi))
        son_gonderilen = [k for k in son_gonderilen if simdi - k[1] <= okuma.YAKIN_SN]

    # 1.4.3 (1d, sahibin kararı 17.11): yönü bilinmeyen olayın klibi — KLIP=1,
    # yalnızca bu bilgisayarda, 7 gün. Kapalıyken ne nesne ne klasör ne iş.
    klipci = None
    if p_ayar["klip"]:
        klipci = klip.Klipci(klip.klip_klasoru(), yaz=lambda s: print(s, flush=True))
        print(f"[i] klip kaydı açık (KLIP=1) — {klipci.klasor}, {klip.KLIP_GUN} gün",
              flush=True)
    # 1.4.5 A (TEK_KARAR, sahibin kararı 22.11): bir geçiş = bir karar — aynı
    # aracın ikinci izinin kartı gönderilmez (takip.Gecitci); klibi yazılır.
    gecitci = takip.Gecitci(gonder=iz_gonder, kart_mi=iz_kart_mi,
                            plakalar=okuma.iz_plakalari, yaz=lambda s: print(s, flush=True),
                            acik=p_ayar["tek_karar"], ikiz_sn=p_ayar["ikiz_sn"],   # 1.4.6 C
                            birakinca=lambda p, r, m: klip_iste(p, m, None, gercek=r))
    if izleme_istendi:
        print(f"[i] tek karar {'açık' if gecitci.acik else 'kapalı'} "
              f"(TEK_KARAR={int(gecitci.acik)})", flush=True)
        print(f"[i] iz onayı {'açık' if p_ayar['iz_onay'] else 'kapalı'} "
              f"(IZ_ONAY={int(bool(p_ayar['iz_onay']))})", flush=True)
        print(f"[i] ByteTrack eşleme {'açık' if p_ayar['byte_esles'] else 'kapalı'} "
              f"(BYTE_ESLES={int(bool(p_ayar['byte_esles']))})", flush=True)

    kopuk = False
    bekleme = YENIDEN_BAGLAN_SN

    def yeni_gecis(zaman: datetime) -> okuma.Gecis:
        nonlocal gecis_no
        gecis_no += 1
        return okuma.Gecis(gecis_no, zaman, plaka.Oylama(tek_esik=p_ayar["tek_esik"]))

    def bitir(durdu: bool, simdi: float, gri_simdi: np.ndarray | None, d: float) -> bool:
        """Geçişi karara bağlar ve sonucu kutuya yazar. Bir şey gönderildi mi."""
        nonlocal gecis, gecis_arka, son_gonderim_gri, son_durdu_plaka, son_gonderilen
        # 1.3.1: bekleme kare süresine uyar — yavaş dizüstünde de durulan
        # karenin araç ölçümü karara yetişsin (yetişmezse 1.3.0 kuralı).
        isci.bekle(gecis, isci.bekleme_suresi(p_ayar["bekle_sn"]))
        esikler = isci.arac_esikleri()          # None: bulucu yok/bozuk → 1.3.0 kuralı
        gonderimler, satirlar = okuma.karar_ver(
            gecis, durdu=durdu, arac_boyu=kapsam >= ARAC_KAPSAM_ESIGI,
            ayrilis_sahne=ayrilis_sahne, son_durdu_plaka=son_durdu_plaka,
            bozuk=isci.bozuk is not None, son_gonderilen=son_gonderilen, simdi=simdi,
            arac_esik=esikler[0] if esikler else None,
            arac_gecis_esik=esikler[1] if esikler else None)
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
            son_gonderilen.append(okuma.gonderim_kaydi(g, simdi))
        son_gonderilen = [k for k in son_gonderilen if simdi - k[1] <= okuma.YAKIN_SN]
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
            if izleme and izci is not None:
                # 1.4.0: kapıdan çıkmış, kararı bekleyen araç girdi sayılır;
                # öteki izler bırakılır (dönüşte ısınma: kimse "girdi" sayılmaz).
                m = time.monotonic()                   # 1.4.5 A: kopmanın olayları da
                gecitci.al(izci, izci.kopma(m), m)     # aynı katmandan; bekleyen hemen
                gecitci.birak(m)
                kararsizlari_yaz()
            if klipci is not None:
                klipci.bosalt(time.monotonic())        # 1.4.3 (1d): eldeki karelerle
            elif gecis is not None:
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
            if izleme and izci is not None:
                # Kopmadan önceki kareler bayat: atlanır; ilk kareler ısınmadır.
                izci.yeniden_baglandi()
                isci.biten_kareler()
                son_biten = kare_no

        simdi = time.monotonic()
        zaman = datetime.now(timezone.utc)
        kare_sayaci += 1
        if geri is not None:
            geri.tik()                    # işlemcideyse en çok 30 sn'de bir GPU'yu dener
        if simdi - son_kalp > KALP_ARALIGI_SN:
            if kalp_isi is None or not kalp_isi.is_alive():
                bilgi = kalp_bilgisi(
                    model_kare=kare_no - kare_no_kalp,
                    sure_sn=simdi - son_kalp if son_kalp != float("-inf") else 0.0,
                    izleme=izleme, istendi=izleme_istendi, kume=kume_etiketi(),
                    kuyruk=giden.ozet(_giden.klasor) if _giden is not None else (0, None),
                    simdi=datetime.now(timezone.utc),
                    reddedilen=son_saat_reddedilen(simdi), saat_farki=_saat_farki,
                    parca=gecitci.son_saat(simdi))
                kalp_isi = threading.Thread(target=kalp, args=(bilgi,), daemon=True)
                kalp_isi.start()
            son_kalp = simdi
            # 1.4.2 (A1): son satırdan beri modellere verilen izleme karesi — gece
            # gürültüsü yerel tetiği sürekli ateşliyorsa burada görünür. SONA
            # eklenir: durum.py'nin "N kare, M gönderim" okuması değişmez.
            model_s = f" · {kare_no - kare_no_kalp} model karesi" if izleme else ""
            kare_no_kalp = kare_no
            print(f"[i] çalışıyor — {kare_sayaci} kare, "
                  f"{_gonderim_sayaci} gönderim · {kume_etiketi()}"
                  f"{isci.sure_ozeti()}{model_s}", flush=True)

        maskeli = kirp_maskeli(frame, kutu, haric, alan)
        kirpik = olcekle(maskeli)
        if klipci is not None:                         # 1.4.3 (1d): saniyede ~5, bellekte
            # 1.4.5 (PARK_GORUNUR): klip maskesiz — yalnızca klip bu kareyi
            # tutacaksa hazırlanır (her kamera karesinde değil).
            klipci.kare(olcekle(kirp(frame, kutu))
                        if park_gorunur and klipci.kare_gerek(simdi) else kirpik,
                        simdi, zaman)
        # 1.3.4: kırpıntı küçültüldüyse plaka TAM çözünürlükten okunur (sahada
        # 2124 → 1568 px; kare plakanın küçük harfleri emin okunamıyordu).
        tam_var = plaka_tam and maskeli.shape[:2] != kirpik.shape[:2]
        if haric is not None and haric_sekli != kirpik.shape:
            haric_sekli = kirpik.shape
            isci.haric = haric_olcekli(frame.shape, kutu, haric, kirpik.shape)
        elif alan is not None and haric_sekli != kirpik.shape:
            # 1.4.0: kırpma alanı — okuyucu ve bulucu "alanın dışı"na bakar.
            haric_sekli = kirpik.shape
            isci.haric = alan_maskesi(frame.shape, kutu, alan, kirpik.shape)
        if not uyarildi:
            yh, yw = kirpik.shape[:2]
            if max(yh, yw) < MIN_KENAR_UYARI:
                print(f"[!] kırpma {yw}x{yh} — {MIN_KENAR_UYARI}px altında plaka küçük kalır",
                      flush=True)
            uyarildi = True

        gri = gri_kucuk(kirpik)
        d = fark(onceki, gri)
        yerel = yerel_kipirti(onceki, gri)        # 1.4.2 (A1)
        onceki = gri

        # ---- 1.4.0: araç izleme. Bu kipte aşağıdaki geçiş kodu HİÇ çalışmaz.
        # 1.4.3: kapandıysa ve işçi bozulanı yeniden deneyip geri getirdiyse
        # (okuma.YENIDEN_DENE_SN) izleme yeniden açılır — ama 1.3.4 kuralının
        # sürmekte olan geçişi bitmeden değil (o araç kendi kuralıyla karara
        # bağlanır) ve sahne IZLEME_SAKIN_SN'dir kıpırdamadan değil: ısınmada
        # hâlâ hareket eden, az önce gönderilmiş araç yeni bir olay (kart) olurdu.
        # İzci aşağıda sıfırdan kurulur (ısınma).
        if (not izleme and izleme_istendi and gecis is None
                and simdi - son_kipirti >= IZLEME_SAKIN_SN
                and isci.arac_esikleri() is not None):
            izleme = True
            print(f"[i] {gunluk.TAKIP_ACIK_ISARETI} (yeniden)", flush=True)
        if izleme and isci.arac_esikleri() is None:
            # Bulucu ya da okuyucu çalışırken bozuldu: TEK YÖN, 1.3.4 kuralına dönülür.
            if izci is not None:
                gecitci.al(izci, izci.kopma(simdi), simdi)
                gecitci.birak(simdi)
                kararsizlari_yaz()
            izci = None
            izleme = False
            print(f"[!] {gunluk.TAKIP_KAPANDI_ISARETI} — 1.3.4 geçiş kuralı", flush=True)
        if izleme:
            if izci is None or izci_sekli != kirpik.shape:
                if izci is not None:          # kamera çözünürlüğü değişti
                    gecitci.al(izci, izci.kopma(simdi), simdi)
                    gecitci.birak(simdi)
                    kararsizlari_yaz()
                izci, izci_sekli = izci_kur(frame.shape, kirpik.shape), kirpik.shape
            # 1.4.2: grafik işlemcisi bozulup bulucu tiny'ye geçtiyse doğum
            # eşiği de onunki olur (puan ölçeği değişti).
            izci.dogum_esik = bulucu.esik
            for o in isci.biten_kareler():
                if o.no <= son_biten:
                    continue                  # bayat (kopmadan önceki) kare
                son_biten = o.no
                gecitci.al(izci, izci.guncelle(o), simdi)
            gecitci.al(izci, izci.zaman_gecti(simdi), simdi)
            kararsizlari_yaz()
        ertelenenleri_sor(simdi)                     # 1.4.6 E2
        if izleme:
            if d >= DURGUN_ESIGI:
                son_kipirti = simdi
            if yerel >= DURGUN_ESIGI:
                son_yerel = simdi
            # Model karesi: koşullar model_karesi_istenir'de. İki model de
            # boştayken verilir: bir karenin iki sonucu birleşmeli.
            istek = model_karesi_istenir(izci, gri, simdi=simdi, son_kipirti=son_kipirti,
                                         son_yerel=son_yerel, son_kare_t=son_kare_t)
            if istek and isci.ikisi_bos():
                kare_no += 1
                if park_gorunur:
                    # 1.4.3: modeller maskesiz kırpıntıyı görür; 1.4.5: fotoğraf da.
                    acik, acik_tam = acik_kirpik(frame, kutu, tam_var)
                    isci.ver(okuma.Is(None, kirpik.copy(), zaman, 0, tam=acik_tam, acik=acik,
                                      kare=okuma.KareIsi(kare_no, simdi, gri,
                                                         izci.okunacak_kutular(simdi),
                                                         gri_kucuk(acik))))
                else:
                    isci.ver(okuma.Is(None, kirpik.copy(), zaman, 0,
                                      tam=maskeli.copy() if tam_var else None,
                                      kare=okuma.KareIsi(kare_no, simdi, gri)))
                son_kare_t = simdi
            if d < DURGUN_ESIGI:
                # İzleme kapanırsa geçiş kuralı arka planı hemen bilsin.
                son_durgun_gri, son_durgun_kirpik = gri, kirpik
                son_durgun_tam = maskeli if tam_var else None
            if isci.takildi(simdi, OKUYUCU_TAKILMA_SN):
                print(f"[!] {gunluk.TAKILDI_ISARETI}: plaka okuyucu {OKUYUCU_TAKILMA_SN:.0f} sn'dir "
                      "dönmüyor — köprü yeniden başlatılıyor", flush=True)
                _bekci_cik()
            # 1.4.2: sakin an — izlenen / kararı bekleyen araç yok, iki model
            # boşta, GPU_SAKIN_SN'dir kıpırtı yok.
            gpu_yeniden_baslat_belki(not izci.kare_istiyor() and isci.ikisi_bos()
                                     and simdi - son_kipirti >= GPU_SAKIN_SN)
            continue

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
                isci.ver(okuma.Is(gecis, son_durgun_kirpik.copy(), zaman, 0, arka=True,
                                  tam=None if son_durgun_tam is None else son_durgun_tam.copy()),
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
                isci.ver(okuma.Is(gecis, kirpik.copy(), zaman, gorunum,
                                  tam=maskeli.copy() if tam_var else None))
        if isci.takildi(simdi, OKUYUCU_TAKILMA_SN):
            print(f"[!] {gunluk.TAKILDI_ISARETI}: plaka okuyucu {OKUYUCU_TAKILMA_SN:.0f} sn'dir "
                  "dönmüyor — köprü yeniden başlatılıyor", flush=True)
            _bekci_cik()
        # 1.4.2: sakin an (1.3.4 kuralı) — süren geçiş yok, iki model boşta,
        # GPU_SAKIN_SN'dir kıpırtı yok. son_hareket DEĞİL: o gönderimden sonra
        # 0'a çekiliyor (sakinlik sanılırdı — test_kopru gpu_kayip_gecis_kurali).
        if d >= DURGUN_ESIGI:
            son_kipirti = simdi
        gpu_yeniden_baslat_belki(gecis is None and isci.ikisi_bos()
                                 and simdi - son_kipirti >= GPU_SAKIN_SN)

        if d < DURGUN_ESIGI and gecis is None:
            son_durgun_gri = gri
            son_durgun_kirpik = kirpik
            son_durgun_tam = maskeli if tam_var else None

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
                isci.ver(okuma.Is(gecis, gecis.durgun_kirpik, zaman, gorunum, durgun=True,
                                  tam=maskeli.copy() if tam_var else None),
                         oncelik=True)
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
