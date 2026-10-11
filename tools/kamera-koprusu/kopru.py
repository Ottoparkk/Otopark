"""
Kamera köprüsü — sends plate photos to kamera-webhook; the server reads them.

Runs on a computer at the car park, on the same LAN as the camera. Nothing
about it is trusted by the server: it authenticates with a shared secret and
can only reach the webhook, which can only open tickets. It never touches the
database, the tariffs or the till.

WHY A BRIDGE AT ALL: a plain IP camera can see a plate but cannot read one,
and the camera must not be exposed to the internet. The camera talks only to
this machine, and only this machine talks out.

Pipeline, per frame:

    RTSP frame -> fixed crop -> wait for the car to SETTLE -> POST the JPEG
    -> the server reads it with the same model the phone app uses

WHAT THIS DELIBERATELY DOES NOT DO, and why:

  * It does not read the plate. An earlier version ran YOLOv8 + EasyOCR here.
    Two reasons that is gone. Ultralytics' licence (AGPL-3.0) requires an
    enterprise licence for proprietary internal use, and a second OCR engine
    means a second accuracy question nobody has measured on Turkish plates —
    while the server's engine is the one we tune, log and can improve. Now the
    camera path and the phone path read plates identically, by construction.

  * It does not detect the plate either. The camera is fixed, aimed at one
    lane, at cars that STOP at a barrier, so the plate lands in the same
    rectangle of every frame. A configured crop box does what a detector would
    do here, with no model, no GPU and no licence. Set KIRPMA once with
    `--kare` and `--test`.

The one thing measured to matter is how much of the frame the plate fills: the
same car photographed far away read three characters wrong, and framed close
read perfectly. That is what the crop is for — it is not a bandwidth
optimisation, it is the accuracy lever.
"""

from __future__ import annotations

import base64
import os
import queue
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

import cv2
import numpy as np
import requests

import gunluk

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

# The model downscales anything longer than this, so sending more is wasted
# upload and latency. 1568 for Haiku 4.5; 2576 if plaka_model is a
# high-resolution model (Claude 4.7 and later, e.g. claude-sonnet-5) — keep in
# step with ocrMaxEdge() in src/lib/image.ts.
MAX_KENAR = int(os.environ.get("MAX_KENAR", "1568"))

# Gentle: heavy JPEG compression makes text hard to read, and a plate read is
# text reading. This is the same reasoning as compressForOcr() in the app.
JPEG_KALITE = int(os.environ.get("JPEG_KALITE", "92"))

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
# MIN stops a flickering scene machine-gunning the API. Kept SHORT on purpose:
# without BOS_REFERANS a departing car produces a photo of the empty lane it
# left behind, and that send disarms us — measured, a 5s floor was long enough
# for the next vehicle to arrive, settle and leave again entirely unseen. The
# floor has to be shorter than a plausible dwell at the barrier.
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

# OPSİYONEL boş şerit referansı, `--bos` ile kaydedilir.
#
# Bir aracın GELMESİ ile GİTMESİ kameradan aynı görünür: hareket, sonra
# durgunluk. Referans olmadan köprü ikisini de gönderir, yani her araç için
# bir de boş şerit fotoğrafı okunur — araç başına maliyet iki katına çıkar.
#
# Ayarlanmadığında davranış aynen eskisi gibidir ve bu bilinçli: yanlış
# ayarlanmış bir referans ARAÇ KAÇIRMAMALI. Referans yanlışsa (içinde araç
# varken çekilmişse, ya da gündüz çekilip gece kullanılıyorsa) boş şerit de
# ondan farklı görünür ve köprü yine gönderir — yani en kötü ihtimalle bugünkü
# davranışa düşer, hiçbir aracı atlamaz.
BOS_REFERANS = os.environ.get("BOS_REFERANS", "").strip()
BOS_ESIGI = float(os.environ.get("BOS_ESIGI", "3.0"))

# The watchdog marks a camera dead if it has not heard anything. A quiet night
# is not a fault, so ping on a timer as well as on events.
KALP_ARALIGI_SN = 300


# ---------------------------------------------------------------- görüntü ---


def kirpma_kutusu() -> tuple[int, int, int, int] | None:
    if not KIRPMA:
        return None
    try:
        x, y, w, h = (int(p) for p in KIRPMA.split(","))
    except ValueError:
        sys.exit('KIRPMA "x,y,w,h" biçiminde olmalı (piksel), örn. "820,540,600,220"')
    if w <= 0 or h <= 0:
        sys.exit("KIRPMA genişlik ve yükseklik pozitif olmalı")
    return x, y, w, h


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


def olcekle(img: np.ndarray) -> np.ndarray:
    yh, yw = img.shape[:2]
    uzun = max(yh, yw)
    if uzun <= MAX_KENAR:
        return img
    k = MAX_KENAR / uzun
    return cv2.resize(img, (int(yw * k), int(yh * k)), interpolation=cv2.INTER_AREA)


def jpeg_base64(img: np.ndarray) -> str:
    ok, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_KALITE])
    if not ok:
        raise RuntimeError("JPEG kodlanamadı")
    return base64.b64encode(buf.tobytes()).decode("ascii")


def fark(a: np.ndarray, b: np.ndarray) -> float:
    """Mean absolute difference of two crops, as a rough motion measure."""
    if a is None or b is None or a.shape != b.shape:
        return 0.0
    return float(np.mean(cv2.absdiff(a, b)))


def gri_kucuk(img: np.ndarray) -> np.ndarray:
    """Downscaled grayscale — motion detection needs neither colour nor detail."""
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return cv2.resize(g, (160, 120), interpolation=cv2.INTER_AREA)


# --------------------------------------------------------------- gönderim ---


def gonder(foto_base64: str, gorulme: datetime) -> bool:
    """
    One vehicle, one POST.

    `islem_id` is generated ONCE and reused across retries — that is what makes
    a retry safe. bilet_ac is idempotent on it, so a request that actually
    succeeded but whose response we never saw cannot become a second ticket.

    `zaman` is when the car was SEEN, not when the server finished reading it.
    The server bills from this timestamp, so sending "now" after a slow read
    would quietly shorten every stay.

    Sending the same car twice is safe beyond the retry too: the plate resolves
    to the same value and the one-open-ticket-per-plate unique index refuses
    the second. The disarm in main() saves API calls; it is not what protects
    the data, which is why it may re-arm early on a lighting change.

    On the single-gate lane (YON=ORTAK) the same holds for a different reason:
    there the server ignores a plate whose ticket was opened or closed in the
    last few minutes (037 kamera_tek_kapi), so a repeat send is neither a
    second ticket nor a false "leaving" flag.
    """
    islem_id = str(uuid.uuid4())
    govde = {
        "yon": YON,
        "zaman": gorulme.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "islem_id": islem_id,
        "cihaz": CIHAZ,
        "foto_base64": foto_base64,
    }

    for deneme in range(4):
        try:
            r = requests.post(
                WEBHOOK_URL,
                json=govde,
                headers={"x-kamera-secret": KAMERA_SECRET},
                timeout=30,  # a plate read happens server-side inside this call
            )
            # Before anything else: a refused bridge must be visible to `durum`
            # whichever request discovers it, and an accepted one must clear it.
            ret_kaydet(r.status_code, getattr(r, "text", "") or "")
            if r.status_code < 300:
                print(f"[+] gönderildi -> {r.text[:160]}", flush=True)
                return True
            # 429 is the ONE 4xx that DOES fix itself — the webhook's 30/min
            # and 2000/day caps. Lumping it in with the rest meant a
            # rate-limited vehicle was thrown away instead of retried.
            if r.status_code == 429:
                print("[!] hız sınırı (429), tekrar denenecek", flush=True)
            # The rest of 4xx is our fault and will not fix itself: a wrong
            # secret, reading switched off, a body we built wrong. Retrying
            # just makes noise.
            elif 400 <= r.status_code < 500:
                print(f"[!] reddedildi {r.status_code}: {r.text[:200]}", flush=True)
                return False
            else:
                print(f"[!] sunucu {r.status_code}, tekrar denenecek", flush=True)
        except requests.RequestException as e:
            print(f"[!] ağ hatası: {e}", flush=True)
        time.sleep(2**deneme)

    print("[!] gönderilemedi — araç elle girilmeli", flush=True)
    return False


def kalp() -> None:
    """
    Keepalive.

    The webhook bumps the heartbeat for any request that clears the secret,
    BEFORE it parses the body — so an empty POST is a valid ping. It answers
    400 and that is the expected result, not an error.
    """
    try:
        r = requests.post(
            WEBHOOK_URL, json={}, headers={"x-kamera-secret": KAMERA_SECRET}, timeout=10
        )
    except requests.RequestException as e:
        # Swallowed so a dead link never kills the capture loop, but LOGGED:
        # from here a silently failing ping looks exactly like a healthy
        # bridge, and whoever is reading this console is the only one who can
        # tell the difference.
        print(f"[!] kalp gönderilemedi: {e}", flush=True)
        return
    ret_kaydet(getattr(r, "status_code", None), getattr(r, "text", "") or "")


# Whether the server's last answer was a refusal of this bridge itself. Only
# ever touched through ret_kaydet, from the capture thread (kalp) and the
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


# ------------------------------------------------------------------ kuyruk ---

# Sending happens OFF the capture thread. Inline, a slow webhook blocked
# cap.read() for up to ~134s (a 30s timeout x 4 attempts, plus backoff) and
# every vehicle arriving in that window was lost — the same silent loss the
# re-arm fix exists to stop.
#
# Bounded, and full means DROP rather than block: falling behind must never
# turn back into the capture loop stalling, which is the whole point of this.
_kuyruk: "queue.Queue[tuple[str, datetime]]" = queue.Queue(maxsize=4)


def gonderici() -> None:
    while True:
        foto, gorulme = _kuyruk.get()
        try:
            gonder(foto, gorulme)
        except Exception as e:  # one bad send must never kill the worker
            print(f"[!] gönderim hatası: {e}", flush=True)
        finally:
            _kuyruk.task_done()


def kuyruga_al(foto: str, gorulme: datetime) -> None:
    """
    `gorulme` is stamped by the CALLER, at the moment the car settled — never
    by the worker. The server bills from this timestamp, so letting a queued
    item pick up the time it was finally dequeued would quietly shorten every
    stay by however long the backlog happened to be.
    """
    try:
        _kuyruk.put_nowait((foto, gorulme))
    except queue.Full:
        print("[!] gönderim kuyruğu dolu — bu araç atlandı", flush=True)


# ------------------------------------------------------------------ kurulum ---


def kamera_baglan() -> cv2.VideoCapture:
    """
    The ONE place a capture is constructed.

    main()'s reconnect used to build its own `cv2.VideoCapture(RTSP_URL)`, so
    anything configured here was silently dropped the first time the stream
    did — and a stream that just dropped is precisely when the settings matter.
    Non-fatal on purpose: exiting is right at startup and wrong at 03:00, so
    the caller decides which it is.
    """
    cap = cv2.VideoCapture(RTSP_URL)
    # Keep only the newest frame. Without this OpenCV hands back whatever
    # queued up while we were busy, so the frame we judged "settled" can be
    # seconds stale — the wrong moment, and blurrier than the one we wanted.
    # Not every backend honours it; setting it costs nothing where ignored.
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return cap


def kamera_ac(bekle: bool = False) -> cv2.VideoCapture:
    """
    Startup path.

    `bekle=False` (the setup modes --kare / --bos / --test): a camera that will
    not open is fatal, because someone is sitting in front of the screen and
    needs the answer now.

    `bekle=True` (the bridge itself): keep trying. After a power cut the PC is
    up long before the camera or the switch, and this process is started ONCE
    per boot — exiting here left the lane dark until somebody rebooted the PC.
    No heartbeat is sent while waiting (the caller has not reached its loop):
    a camera that is not there must stay visible to the server watchdog.

    A missing RTSP_URL is fatal either way; waiting cannot fix a config.
    """
    if not RTSP_URL:
        sys.exit("RTSP_URL tanımlı değil — kameranın RTSP adresini verin.")
    bekleme = ACILIS_BEKLEME_SN
    while True:
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
        time.sleep(bekleme)
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


def bos_kaydet() -> None:
    """`--bos`: ŞERİT BOŞKEN bir referans karesi kaydeder."""
    cap = kamera_ac()
    ok, frame = cap.read()
    cap.release()
    if not ok:
        sys.exit("kare alınamadı")
    cv2.imwrite("bos.jpg", frame)
    print("bos.jpg yazıldı — şerit BOŞKEN çekildiğinden emin olun.", flush=True)
    print('Sonra BOS_REFERANS="bos.jpg" verin. Yanlış bir referans yalnızca')
    print("fazladan okuma yaptırır; hiçbir aracı atlatmaz.")


def kirpma_test() -> None:
    """`--test`: save the cropped region and print live motion values."""
    kutu = kirpma_kutusu()
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
            k = olcekle(kirp(frame, kutu))
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
    if kutu is None:
        print("[!] KIRPMA verilmedi — tüm kare gönderilecek, okuma daha kötü olur", flush=True)

    # Tam kare olarak saklanır ve burada aynı kutuyla kırpılır: KIRPMA
    # değişirse referans yeniden çekilmek zorunda kalmaz.
    bos_gri: np.ndarray | None = None
    if BOS_REFERANS:
        ref = cv2.imread(BOS_REFERANS)
        if ref is None:
            print(f"[!] boş referans okunamadı: {BOS_REFERANS} — referanssız devam",
                  flush=True)
        else:
            bos_gri = gri_kucuk(olcekle(kirp(ref, kutu)))
            print("[i] boş şerit referansı yüklendi", flush=True)

    print(f"[i] kamera açılıyor ({YON})", flush=True)
    cap = kamera_ac(bekle=True)
    print(f"[i] {gunluk.KAMERA_VAR_ISARETI}", flush=True)

    threading.Thread(target=gonderici, daemon=True).start()

    onceki: np.ndarray | None = None
    son_hareket = 0.0        # monotonic, last time the scene moved
    durgun_sayaci = 0        # consecutive still frames
    son_kalp = 0.0
    uyarildi = False
    kare_sayaci = 0          # yalnızca düzenli "çalışıyor" satırı için
    gonderim_sayaci = 0

    # Re-arm state. `silahli` False means we are still looking at a vehicle we
    # have already sent, and must not send again until it leaves.
    silahli = True
    gonderilen_gri: np.ndarray | None = None
    bekleme_bitis = 0.0      # monotonic, earliest possible re-arm
    zorunlu_arm = 0.0        # monotonic, re-arm regardless once past this

    # Motion seen since the last send. A SECOND re-arm signal beside the scene
    # change, and it is the one that saves a car: if the next vehicle stops in
    # roughly the same spot and looks similar, the crop may not differ enough
    # to trip SAHNE_ESIGI, and without this we would sit disarmed until
    # MAX_BEKLEME_SN — two silent minutes at a barrier.
    hareket_oldu = False

    # True from a failed read until the next good one. The recovery is LOGGED:
    # without that line the last camera entry in the log stays "kare alınamadı"
    # and `durum` reports KAMERA YOK for up to five minutes (until the next
    # "çalışıyor" line) about a camera that came back three seconds later.
    kopuk = False

    while True:
        ok, frame = cap.read()
        if not ok:
            # An RTSP stream drops. Reconnecting beats exiting: nobody is
            # watching this process at 03:00, and a bridge that dies silently
            # looks exactly like a car park with no cars.
            print(f"[!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor", flush=True)
            kopuk = True
            cap.release()
            time.sleep(3)
            cap = kamera_baglan()
            onceki = None
            continue
        if kopuk:
            kopuk = False
            print(f"[i] {gunluk.KAMERA_VAR_ISARETI} (yeniden)", flush=True)

        simdi = time.monotonic()
        kare_sayaci += 1
        if simdi - son_kalp > KALP_ARALIGI_SN:
            kalp()
            son_kalp = simdi
            # Sağlıklı bir köprü saatlerce TEK SATIR yazmayabilir: boş bir
            # otoparkta ne gönderim olur ne hata. O sessizlik ölü bir köprüden
            # ayırt edilemiyordu — kayıt dosyasına bakan kişi de, `durum`
            # komutu da "çalışıyor mu" sorusuna cevap veremiyordu. Düzenli iz
            # aynı zamanda arızanın SAATİNİ veriyor: son satır, öldüğü an.
            print(f"[i] çalışıyor — {kare_sayaci} kare, "
                  f"{gonderim_sayaci} gönderim", flush=True)

        kirpik = olcekle(kirp(frame, kutu))
        if not uyarildi:
            yh, yw = kirpik.shape[:2]
            if max(yh, yw) < MIN_KENAR_UYARI:
                print(
                    f"[!] kırpma {yw}x{yh} — {MIN_KENAR_UYARI}px altında okuma güvenilmez",
                    flush=True,
                )
            uyarildi = True

        gri = gri_kucuk(kirpik)
        d = fark(onceki, gri)
        onceki = gri

        # Has the vehicle we photographed actually gone? Checked BEFORE the
        # motion branch below on purpose: a car driving off IS motion, and that
        # branch `continue`s, so testing after it would skip exactly the frames
        # where the scene changes most.
        if not silahli and simdi >= bekleme_bitis:
            ayrildi = gonderilen_gri is None or fark(gri, gonderilen_gri) > SAHNE_ESIGI
            if ayrildi or hareket_oldu or simdi >= zorunlu_arm:
                if not (ayrildi or hareket_oldu):
                    print("[!] sahne değişmedi ama süre doldu — yeniden kuruldu",
                          flush=True)
                silahli = True
                gonderilen_gri = None
                hareket_oldu = False

        if d > HAREKET_ESIGI:
            son_hareket = simdi
            durgun_sayaci = 0
            hareket_oldu = True
            continue

        if d < DURGUN_ESIGI:
            durgun_sayaci += 1
        else:
            durgun_sayaci = 0

        # A car ARRIVED (there was motion recently) and has now SETTLED (still
        # for several frames). That settled frame is both the moment the plate
        # is in position and the sharpest one available — a moving car is the
        # blurry one, and blur is what costs characters.
        gecerli_pencere = simdi - son_hareket < HAREKET_PENCERESI_SN
        if silahli and durgun_sayaci >= DURGUN_KARE and gecerli_pencere:
            # Şerit boş görünüyorsa bu, GELEN değil GİDEN aracın bıraktığı
            # durgunluktur. Referans yoksa bu dal hiç çalışmaz ve davranış
            # eskisiyle birebir aynıdır — kaçırmaktansa fazladan okumak.
            if bos_gri is not None and fark(bos_gri, gri) < BOS_ESIGI:
                durgun_sayaci = 0
                son_hareket = 0.0
                continue

            print(f"[i] araç durdu (fark={d:.2f}) — gönderiliyor", flush=True)
            gonderim_sayaci += 1
            try:
                kuyruga_al(jpeg_base64(kirpik), datetime.now(timezone.utc))
            except Exception as e:  # encoding, not network — never kill the loop
                print(f"[!] gönderilemedi: {e}", flush=True)
            # Disarmed until this vehicle leaves the frame, not until a clock
            # runs out. `gri` is a fresh array from gri_kucuk() every frame, so
            # holding the reference cannot alias with `onceki`.
            silahli = False
            gonderilen_gri = gri
            bekleme_bitis = simdi + MIN_BEKLEME_SN
            zorunlu_arm = simdi + MAX_BEKLEME_SN
            durgun_sayaci = 0
            son_hareket = 0.0
            # Cleared here or the flag means "motion since the last re-arm"
            # rather than "since the last send": the motion that BROUGHT this
            # car would otherwise still be set and re-arm us the instant
            # MIN_BEKLEME_SN elapsed, while the car is still sitting there.
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
    elif arg == "--bos":
        bos_kaydet()
    elif arg == "--test":
        kirpma_test()
    else:
        main()


if __name__ == "__main__":
    cli()
