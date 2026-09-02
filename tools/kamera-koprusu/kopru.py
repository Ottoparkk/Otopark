"""
Kamera köprüsü — reads plates locally, posts them to kamera-webhook.

Runs on a computer at the car park, on the same LAN as the camera. Nothing
about it is trusted by the server: it authenticates with a shared secret and
can only reach the webhook, which can only open tickets. It never touches the
database, the tariffs or the till.

WHY A BRIDGE AT ALL: a plain IP camera can see a plate but cannot read one.
This closes that gap without exposing the camera to the internet — the camera
talks only to this machine, and only this machine talks out.

Pipeline, per frame:

    RTSP frame -> YOLO finds the plate box -> crop -> EasyOCR reads characters
    -> Turkish format check -> vote across frames -> POST once per vehicle

The two steps people skip are the two that matter. The CROP is what makes OCR
work at all — a plate is 2% of the frame, and reading the whole scene is how
you get "78" out of a road sign. The VOTE is what makes it reliable: a car
sits at a barrier for seconds, so we read it many times and take the answer
that keeps coming back, instead of trusting one frame that might have caught
a headlight flare.
"""

from __future__ import annotations

import os
import re
import sys
import time
import uuid
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone

import cv2
import easyocr
import requests
from ultralytics import YOLO

# --------------------------------------------------------------- ayarlar ---

WEBHOOK_URL = os.environ["WEBHOOK_URL"]          # .../functions/v1/kamera-webhook
KAMERA_SECRET = os.environ["KAMERA_SECRET"]      # KAMERA_WEBHOOK_SECRET ile aynı
RTSP_URL = os.environ["RTSP_URL"]                # rtsp://user:pass@10.0.0.42:554/...
YON = os.environ.get("YON", "GIRIS").upper()     # GIRIS | CIKIS — bu kameranın şeridi
CIHAZ = os.environ.get("CIHAZ", "kopru-1")
MODEL_PATH = os.environ.get("MODEL_PATH", "plate.pt")

# A plate must be read this many times, and agree, before it is believed.
# Lower = faster but jumpier; higher = surer but can miss a car that does not
# linger. Three is a good starting point at a barrier.
GEREKLI_OY = int(os.environ.get("GEREKLI_OY", "3"))

# How long the same plate is ignored after a successful send. A car waiting at
# the barrier stays in frame long after its ticket opened; without this it
# would be sent again every few seconds.
BEKLEME_SN = int(os.environ.get("BEKLEME_SN", "60"))

# Anything read fewer than this many seconds ago is still part of the same
# vehicle's visit. Older observations are dropped so two cars in a row do not
# vote in each other's ballot.
OY_PENCERESI_SN = 8

# The watchdog on the server marks a camera dead if it has not heard anything.
# A quiet night is not a fault, so ping on a timer as well as on events.
KALP_ARALIGI_SN = 300

TR_PLAKA = re.compile(
    r"^(0[1-9]|[1-7][0-9]|8[01])"      # il kodu 01-81
    r"(?:[A-Z]\d{4}|[A-Z]{2}\d{3}|[A-Z]{3}\d{2})$"  # harf+rakam toplamı hep 5
)

TR_FOLD = str.maketrans("ıİçÇğĞöÖşŞüÜ", "IIcCgGoOsSuU")

# EasyOCR reads Latin text in general; a plate contains exactly these. Telling
# it so removes a whole class of errors before they happen — it can no longer
# return a lowercase l where a 1 belongs, or a Turkish ş.
ALLOWLIST = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


def temizle(ham: str) -> str:
    """Same normalisation the server does, so what we send is what it stores."""
    return re.sub(r"[^A-Z0-9]", "", ham.translate(TR_FOLD).upper())


def gecerli(plaka: str) -> bool:
    return bool(TR_PLAKA.match(plaka))


# ---------------------------------------------------------------- gönderim ---


def gonder(plaka: str, gorulme: datetime) -> bool:
    """
    One vehicle, one POST.

    `islem_id` is generated ONCE and reused across retries — that is what makes
    a retry safe. bilet_ac is idempotent on it, so a request that actually
    succeeded but whose response we never saw cannot become a second ticket.

    `zaman` is when the car was SEEN, not when we finished thinking about it.
    The server bills from this timestamp, so sending "now" after a slow read
    would quietly shorten every stay.
    """
    islem_id = str(uuid.uuid4())
    govde = {
        "plaka": plaka,
        "yon": YON,
        "zaman": gorulme.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "islem_id": islem_id,
        "cihaz": CIHAZ,
    }

    for deneme in range(4):
        try:
            r = requests.post(
                WEBHOOK_URL,
                json=govde,
                headers={"x-kamera-secret": KAMERA_SECRET},
                timeout=15,
            )
            if r.status_code < 300:
                print(f"[+] {plaka} gönderildi -> {r.text[:120]}", flush=True)
                return True
            # 4xx is our fault and will not fix itself: a bad plate, a closed
            # camera setting, a wrong secret. Retrying just makes noise.
            if 400 <= r.status_code < 500:
                print(f"[!] {plaka} reddedildi {r.status_code}: {r.text[:160]}", flush=True)
                return False
            print(f"[!] sunucu {r.status_code}, tekrar denenecek", flush=True)
        except requests.RequestException as e:
            print(f"[!] ağ hatası: {e}", flush=True)
        time.sleep(2**deneme)

    print(f"[!] {plaka} gönderilemedi — elle girilmeli", flush=True)
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


# ------------------------------------------------------------------- oylama ---


@dataclass
class Oylama:
    """Readings for the vehicle currently in front of the camera."""

    oylar: Counter = field(default_factory=Counter)
    ilk_gorulme: datetime | None = None
    son_okuma: float = 0.0

    def ekle(self, plaka: str) -> None:
        simdi = time.monotonic()
        # A gap means the previous car left. Starting fresh keeps two cars from
        # voting in the same ballot, which is how you get a plate that belongs
        # to neither of them.
        if simdi - self.son_okuma > OY_PENCERESI_SN:
            self.oylar.clear()
            self.ilk_gorulme = None
        self.son_okuma = simdi
        if self.ilk_gorulme is None:
            self.ilk_gorulme = datetime.now(timezone.utc)
        self.oylar[plaka] += 1

    def kazanan(self) -> tuple[str, datetime] | None:
        if not self.oylar:
            return None
        plaka, sayi = self.oylar.most_common(1)[0]
        if sayi < GEREKLI_OY:
            return None
        return plaka, self.ilk_gorulme or datetime.now(timezone.utc)

    def temizle(self) -> None:
        self.oylar.clear()
        self.ilk_gorulme = None


# --------------------------------------------------------------------- ana ---


def main() -> None:
    if YON not in ("GIRIS", "CIKIS"):
        sys.exit("YON must be GIRIS or CIKIS")

    print(f"[i] model yükleniyor: {MODEL_PATH}", flush=True)
    dedektor = YOLO(MODEL_PATH)
    okuyucu = easyocr.Reader(["en"], gpu=False)

    print(f"[i] kamera açılıyor ({YON})", flush=True)
    cap = cv2.VideoCapture(RTSP_URL)

    oylama = Oylama()
    gonderilen: dict[str, float] = {}
    son_kalp = 0.0

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
            continue

        if time.monotonic() - son_kalp > KALP_ARALIGI_SN:
            kalp()
            son_kalp = time.monotonic()

        for kutu in dedektor(frame, verbose=False)[0].boxes:
            x1, y1, x2, y2 = (int(v) for v in kutu.xyxy[0])
            kirpik = frame[max(y1, 0) : y2, max(x1, 0) : x2]
            if kirpik.size == 0:
                continue

            for _, metin, guven in okuyucu.readtext(kirpik, allowlist=ALLOWLIST):
                if guven < 0.4:
                    continue
                aday = temizle(metin)
                # The format check is the second half of the allowlist. It is
                # what turns "read some characters" into "read a plate", and it
                # is why a road sign or a bumper sticker never reaches the app.
                if gecerli(aday):
                    oylama.ekle(aday)

        sonuc = oylama.kazanan()
        if sonuc:
            plaka, gorulme = sonuc
            gecen = time.monotonic() - gonderilen.get(plaka, -1e9)
            if gecen > BEKLEME_SN:
                if gonder(plaka, gorulme):
                    gonderilen[plaka] = time.monotonic()
            oylama.temizle()


if __name__ == "__main__":
    main()
