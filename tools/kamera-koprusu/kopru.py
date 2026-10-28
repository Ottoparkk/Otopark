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
import json
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
import kesif

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

# Boş şeridi KENDİ öğrenme (1.2.0) — bkz. BosOgrenme. Varsayılan AÇIK; "0"
# sahada kapatma anahtarıdır ve davranışı birebir 1.1.0'a döndürür.
#
# Kurulumda "şerit şu an boş" fotoğrafı çekmek yerine bu: o fotoğraf yanlışlıkla
# araç varken çekilirse benzer bir aracı GİZLEYEBİLİRDİ. Burada referans yalnızca
# sunucudaki modelin "görselde HİÇ ARAÇ yok" dediği fotoğraflardan doğar; gece
# ve gündüz için ayrı ayrı, kendiliğinden.
BOS_OGREN = os.environ.get("BOS_OGREN", "1").strip() != "0"

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


class BosOgrenme:
    """
    What the EMPTY lane looks like, learned from the server's own answers.

    Every departure leaves the empty lane behind, and to the motion logic that
    is "motion, then stillness" — so it gets photographed and paid for like a
    car. Once this knows what the empty lane looks like, a settled picture that
    matches is not sent.

    THE RULE THAT KEEPS IT SAFE: a picture becomes a reference only when
      1. the server's model said "no vehicle at all" (`arac_yok`, not merely
         "plate unreadable") about it, AND
      2. a LATER picture got the same answer and looks the same, AND
      3. at least one car was READ (a 2xx) in between.
    (3) is what stops one parked, unreadable car photographed twice from
    becoming "the empty lane". A car changes the crop a lot, so a reference can
    only ever stop pictures that look like the empty road; the worst a bad one
    can do is cost the reads it was meant to save — never a missed car.

    Several references, because the empty lane looks different by day, at dusk,
    under infrared at night and on a wet road. Kept in memory only: after a
    restart the first departures are paid for again and the references come
    back by themselves.

    Shared by the capture thread (eslesir) and the sender thread (the rest),
    hence the lock.
    """

    ADAY_EN_COK = 8
    REFERANS_EN_COK = 6

    def __init__(self, esik: float, sabit: np.ndarray | None = None, ogren: bool = True):
        self.esik = esik
        self.ogren = ogren
        self._sabit = sabit            # elle verilen BOS_REFERANS — hiç düşmez
        self._adaylar: list[tuple[np.ndarray, int]] = []   # (görüntü, o anki okunan)
        self._referanslar: list[list] = []                  # [görüntü, son kullanım]
        self._okunan = 0
        self._sira = 0
        self._kilit = threading.Lock()

    @staticmethod
    def _fark(a: np.ndarray | None, b: np.ndarray | None) -> float | None:
        # NOT kopru.fark(): that returns 0.0 ("identical") for a size mismatch,
        # harmless for motion but here it would mean "empty lane" — a skipped
        # car. Different sizes are simply not comparable.
        if a is None or b is None or a.shape != b.shape:
            return None
        return float(np.mean(cv2.absdiff(a, b)))

    def _benzer(self, a: np.ndarray | None, b: np.ndarray | None) -> bool:
        d = self._fark(a, b)
        return d is not None and d < self.esik

    def referans_sayisi(self) -> int:
        with self._kilit:
            return len(self._referanslar)

    def okundu(self) -> None:
        """A car's plate was read (any 2xx for a photo)."""
        with self._kilit:
            self._okunan += 1

    def arac_yok_geldi(self, gri: np.ndarray | None) -> bool:
        """The server said "no vehicle" about `gri`. True when it became a reference."""
        if not self.ogren or gri is None:
            return False
        with self._kilit:
            # Already covered (the reference may have been learned while this
            # picture waited in the send queue): nothing to do.
            if any(self._benzer(r[0], gri) for r in self._referanslar):
                return False
            for i, (aday, okunan_o_an) in enumerate(self._adaylar):
                if not self._benzer(aday, gri):
                    continue
                if self._okunan <= okunan_o_an:
                    # Same picture, but no car read since: keep waiting.
                    return False
                del self._adaylar[i]
                if len(self._referanslar) >= self.REFERANS_EN_COK:
                    # Drop the one unused for longest, so the night reference
                    # survives a sunny week instead of the newest one winning.
                    eski = min(range(len(self._referanslar)),
                               key=lambda k: self._referanslar[k][1])
                    del self._referanslar[eski]
                self._sira += 1
                self._referanslar.append([gri, self._sira])
                return True
            self._adaylar.append((gri, self._okunan))
            if len(self._adaylar) > self.ADAY_EN_COK:
                del self._adaylar[0]
            return False

    def eslesir(self, gri: np.ndarray | None) -> tuple[bool, float, str]:
        """(does `gri` look like the empty lane, how close, which reference)."""
        with self._kilit:
            d = self._fark(self._sabit, gri)
            if d is not None and d < self.esik:
                return True, d, "sabit"
            for i, r in enumerate(self._referanslar):
                d = self._fark(r[0], gri)
                if d is not None and d < self.esik:
                    self._sira += 1
                    r[1] = self._sira
                    return True, d, f"öğrenilen-{i + 1}"
            return False, 0.0, ""


# --------------------------------------------------------------- gönderim ---


# Set by main(); None in the setup modes and in tests that call gonder alone.
_bos: BosOgrenme | None = None

# Tries per vehicle, all with the same islem_id (replay-safe on the server).
DENEME_SAYISI = 4


def _arac_yok_mu(govde: str) -> bool:
    """Did the webhook's 422 say "no vehicle at all"? Anything unparseable: no."""
    try:
        return json.loads(govde).get("arac_yok") is True
    except (ValueError, AttributeError):
        return False


def gonder(foto_base64: str, gorulme: datetime, gri: np.ndarray | None = None) -> bool:
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

    for deneme in range(DENEME_SAYISI):
        basliklar = {"x-kamera-secret": KAMERA_SECRET}
        # The LAST try says so. If plate reading itself is down, the server
        # turns the car into an exception row only on this request (039):
        # written on an earlier try, it would make the single gate refuse a
        # later try that DID read the plate, and that car would never get its
        # ticket. Earlier tries only raise the hourly alert.
        if deneme == DENEME_SAYISI - 1:
            basliklar["x-kamera-son-gonderim"] = "1"
        try:
            r = requests.post(
                WEBHOOK_URL,
                json=govde,
                headers=basliklar,
                timeout=30,  # a plate read happens server-side inside this call
            )
            # Before anything else: a refused bridge must be visible to `durum`
            # whichever request discovers it, and an accepted one must clear it.
            ret_kaydet(r.status_code, getattr(r, "text", "") or "")
            if r.status_code < 300:
                print(f"[+] gönderildi -> {r.text[:160]}", flush=True)
                if _bos is not None:
                    _bos.okundu()
                return True
            # Not a refusal: the model looked and saw an empty lane. Logged as
            # information, so `durum` does not count it as a rejection, and
            # handed to the learner. A 422 WITHOUT the flag ("a car I cannot
            # read") falls through to the ordinary refusal below and is never
            # learned from.
            if r.status_code == 422 and _arac_yok_mu(getattr(r, "text", "") or ""):
                print(f"[i] {gunluk.BOS_GORUNTU_ISARETI}", flush=True)
                if _bos is not None and _bos.arac_yok_geldi(gri):
                    print(f"[i] {gunluk.BOS_OGRENILDI_ISARETI} "
                          f"({_bos.referans_sayisi()} referans)", flush=True)
                return False
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
        return
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


# ------------------------------------------------------------------ kuyruk ---

# Sending happens OFF the capture thread. Inline, a slow webhook blocked
# cap.read() for up to ~134s (a 30s timeout x 4 attempts, plus backoff) and
# every vehicle arriving in that window was lost — the same silent loss the
# re-arm fix exists to stop.
#
# Bounded, and full means DROP rather than block: falling behind must never
# turn back into the capture loop stalling, which is the whole point of this.
_kuyruk: "queue.Queue[tuple[str, datetime, np.ndarray | None]]" = queue.Queue(maxsize=4)


def gonderici() -> None:
    while True:
        foto, gorulme, gri = _kuyruk.get()
        try:
            gonder(foto, gorulme, gri)
        except Exception as e:  # one bad send must never kill the worker
            print(f"[!] gönderim hatası: {e}", flush=True)
        finally:
            _kuyruk.task_done()


def kuyruga_al(foto: str, gorulme: datetime, gri: np.ndarray | None = None) -> None:
    """
    `gorulme` is stamped by the CALLER, at the moment the car settled — never
    by the worker. The server bills from this timestamp, so letting a queued
    item pick up the time it was finally dequeued would quietly shorten every
    stay by however long the backlog happened to be.

    `gri` is the small grey version of the SAME picture, so the answer can be
    learned against exactly what was sent (BosOgrenme).
    """
    try:
        _kuyruk.put_nowait((foto, gorulme, gri))
    except queue.Full:
        print("[!] gönderim kuyruğu dolu — bu araç atlandı", flush=True)


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
        time.sleep(SIFRE_RED_BEKLEME_SN)


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
    global _bos
    _bos = BosOgrenme(BOS_ESIGI, sabit=bos_gri, ogren=BOS_OGREN)
    if not BOS_OGREN:
        print("[i] boş şerit öğrenme kapalı (BOS_OGREN=0)", flush=True)

    print(f"[i] kamera açılıyor ({YON})", flush=True)
    cap = kamera_ac(bekle=True)
    print(f"[i] {gunluk.KAMERA_VAR_ISARETI}", flush=True)

    threading.Thread(target=gonderici, daemon=True).start()

    onceki: np.ndarray | None = None
    son_hareket = 0.0        # monotonic, last time the scene moved
    durgun_sayaci = 0        # consecutive still frames
    # -inf, not 0.0: monotonic() counts from boot, so 0.0 delayed the first
    # heartbeat until the PC had been up five minutes — after a power cut the
    # server heard nothing for that long. The first frame now sends one.
    son_kalp = float("-inf")
    kalp_isi: threading.Thread | None = None
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
    # Wait before the next reconnect: doubles while the camera stays away,
    # back to the base on the first good frame (see YENIDEN_BAGLAN_SN).
    bekleme = YENIDEN_BAGLAN_SN

    while True:
        ok, frame = cap.read()
        if not ok:
            # An RTSP stream drops. Reconnecting beats exiting: nobody is
            # watching this process at 03:00, and a bridge that dies silently
            # looks exactly like a car park with no cars.
            print(f"[!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor "
                  f"({_sure(bekleme)} sonra)", flush=True)
            kopuk = True
            cap.release()
            time.sleep(bekleme)
            bekleme = min(bekleme * 2, YENIDEN_BAGLAN_MAX_SN)
            # Every reconnect is a login. Ask about the password once first;
            # a rejected one is never tried on the stream (1.2.2).
            sifre_kabul_edilene_kadar_bekle()
            cap = kamera_baglan()
            onceki = None
            continue
        if kopuk:
            kopuk = False
            bekleme = YENIDEN_BAGLAN_SN
            print(f"[i] {gunluk.KAMERA_VAR_ISARETI} (yeniden)", flush=True)

        simdi = time.monotonic()
        kare_sayaci += 1
        if simdi - son_kalp > KALP_ARALIGI_SN:
            # WHEN to beat stays here, below the reconnect `continue`: no
            # frames, no heartbeat — a dead camera must go quiet, that is all
            # the server watchdog sees. Only the network call leaves this
            # thread; a slow answer used to freeze the camera for up to 20 s
            # and a car arriving meanwhile was never seen. One in flight at
            # most.
            if kalp_isi is None or not kalp_isi.is_alive():
                kalp_isi = threading.Thread(target=kalp, daemon=True)
                kalp_isi.start()
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
            # durgunluktur. Referans yoksa (elle verilmemiş, henüz öğrenilmemiş)
            # bu dal hiç çalışmaz ve davranış eskisiyle birebir aynıdır —
            # kaçırmaktansa fazladan okumak. Satır her yerleşmede BİR kez
            # yazılır (son_hareket sıfırlanınca bir sonraki harekete kadar bu
            # dala girilmez); `fark` değeri sahada eşiği ayarlamanın ölçüsüdür.
            bos_mu, bos_fark, bos_ref = _bos.eslesir(gri)
            if bos_mu:
                print(f"[i] {gunluk.BOS_ATLANDI_ISARETI} "
                      f"(fark={bos_fark:.2f}, ref={bos_ref})", flush=True)
                durgun_sayaci = 0
                son_hareket = 0.0
                continue

            print(f"[i] araç durdu (fark={d:.2f}) — gönderiliyor", flush=True)
            gonderim_sayaci += 1
            try:
                kuyruga_al(jpeg_base64(kirpik), datetime.now(timezone.utc), gri)
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
