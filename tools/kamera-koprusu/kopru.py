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
import sys
import time
import uuid
from datetime import datetime, timezone

import cv2
import numpy as np
import requests

# --------------------------------------------------------------- ayarlar ---

# `.get`, not `[...]`: these are read at IMPORT time, so `os.environ[...]`
# made `--kare` and `--test` — the two setup modes that never send anything —
# die with a raw KeyError traceback. That is the FIRST step the README tells
# you to run, before you would even have the webhook secret to hand. Each mode
# validates only what it actually uses, in kamera_ac() and main().
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")   # .../functions/v1/kamera-webhook
KAMERA_SECRET = os.environ.get("KAMERA_SECRET", "")  # KAMERA_WEBHOOK_SECRET ile aynı
RTSP_URL = os.environ.get("RTSP_URL", "")         # rtsp://user:pass@10.0.0.42:554/...
YON = os.environ.get("YON", "GIRIS").upper()     # GIRIS | CIKIS — bu kameranın şeridi
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

# How long the same lane is ignored after a successful send. A car waits at
# the barrier long after its ticket opened; without this it would be sent
# again every few seconds, each one an API call.
BEKLEME_SN = int(os.environ.get("BEKLEME_SN", "60"))

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
    the second. BEKLEME_SN exists to save API calls, not to protect the data.
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
            if r.status_code < 300:
                print(f"[+] gönderildi -> {r.text[:160]}", flush=True)
                return True
            # 4xx is our fault and will not fix itself: a wrong secret, reading
            # switched off, a body we built wrong. Retrying just makes noise.
            if 400 <= r.status_code < 500:
                print(f"[!] reddedildi {r.status_code}: {r.text[:200]}", flush=True)
                return False
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
        requests.post(
            WEBHOOK_URL, json={}, headers={"x-kamera-secret": KAMERA_SECRET}, timeout=10
        )
    except requests.RequestException:
        pass


# ------------------------------------------------------------------ kurulum ---


def kamera_ac() -> cv2.VideoCapture:
    if not RTSP_URL:
        sys.exit("RTSP_URL tanımlı değil — kameranın RTSP adresini verin.")
    cap = cv2.VideoCapture(RTSP_URL)
    if not cap.isOpened():
        sys.exit(f"kamera açılamadı: {RTSP_URL}")
    return cap


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
    if not WEBHOOK_URL or not KAMERA_SECRET:
        sys.exit("WEBHOOK_URL ve KAMERA_SECRET tanımlı olmalı (bkz. README).")
    if YON not in ("GIRIS", "CIKIS"):
        sys.exit("YON must be GIRIS or CIKIS")

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
    cap = kamera_ac()

    onceki: np.ndarray | None = None
    son_hareket = 0.0        # monotonic, last time the scene moved
    durgun_sayaci = 0        # consecutive still frames
    bekleme_bitis = 0.0      # monotonic, cooldown after a send
    son_kalp = 0.0
    uyarildi = False

    while True:
        ok, frame = cap.read()
        if not ok:
            # An RTSP stream drops. Reconnecting beats exiting: nobody is
            # watching this process at 03:00, and a bridge that dies silently
            # looks exactly like a car park with no cars.
            print("[!] kare alınamadı, yeniden bağlanılıyor", flush=True)
            cap.release()
            time.sleep(3)
            cap = cv2.VideoCapture(RTSP_URL)
            onceki = None
            continue

        simdi = time.monotonic()
        if simdi - son_kalp > KALP_ARALIGI_SN:
            kalp()
            son_kalp = simdi

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

        if d > HAREKET_ESIGI:
            son_hareket = simdi
            durgun_sayaci = 0
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
        if durgun_sayaci >= DURGUN_KARE and gecerli_pencere and simdi >= bekleme_bitis:
            # Şerit boş görünüyorsa bu, GELEN değil GİDEN aracın bıraktığı
            # durgunluktur. Referans yoksa bu dal hiç çalışmaz ve davranış
            # eskisiyle birebir aynıdır — kaçırmaktansa fazladan okumak.
            if bos_gri is not None and fark(bos_gri, gri) < BOS_ESIGI:
                durgun_sayaci = 0
                son_hareket = 0.0
                continue

            print(f"[i] araç durdu (fark={d:.2f}) — gönderiliyor", flush=True)
            try:
                gonder(jpeg_base64(kirpik), datetime.now(timezone.utc))
            except Exception as e:  # encoding, not network — never kill the loop
                print(f"[!] gönderilemedi: {e}", flush=True)
            bekleme_bitis = time.monotonic() + BEKLEME_SN
            durgun_sayaci = 0
            son_hareket = 0.0


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--kare":
        kare_kaydet()
    elif arg == "--bos":
        bos_kaydet()
    elif arg == "--test":
        kirpma_test()
    else:
        main()
