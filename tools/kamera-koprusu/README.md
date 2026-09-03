# Kamera köprüsü

Grabs a cropped plate photo from an IP camera on a computer at the car park and
posts it to `kamera-webhook`, which reads it with **the same model the phone app
uses**. **Nothing in this folder is part of the web app** — it is not built,
typechecked or deployed with it. It runs on hardware you own.

The camera never touches the internet. It talks to this machine over the LAN;
this machine talks out. That is the whole security argument for the bridge.

## Why it does not read plates itself

An earlier version ran YOLOv8 + EasyOCR on this box. Both halves are gone, for
different reasons:

- **The OCR** is gone because a second engine is a second accuracy question
  nobody has measured on Turkish plates, while the server's engine is the one
  that gets tuned, logged and improved. The camera path and the phone path now
  read plates identically, by construction.
- **The detector** is gone because Ultralytics' licence (AGPL-3.0) requires an
  enterprise licence for proprietary internal use — and because it was not
  needed. The camera is fixed, aimed at one lane, at cars that *stop* at a
  barrier, so the plate lands in the same rectangle of every frame. A crop box
  you configure once does the same job with no model, no GPU and no licence.

What remains is the part that was actually carrying the accuracy: **the crop.**
Measured on one car photographed twice, far away it read three of eight
characters wrong and close it read perfectly. The crop is not a bandwidth
optimisation.

## What you need

- A computer on the same network as the camera. An old laptop is the best
  choice available: it has a screen for diagnosis and the UPS is already inside
  it. A Raspberry Pi is now genuinely enough — nothing here does inference.
- Python 3.10+
- The camera's RTSP URL (from its own web interface).

## Install

```bash
pip install -r requirements.txt
```

Three permissive-licence packages, no PyTorch, no model file, about 60 MB.

## Set the crop box — do this first

```bash
python kopru.py --kare
```

Saves `kare.jpg` and prints the frame size. Open it, measure the rectangle the
plate sits in when a car is stopped at the barrier, and pass it as `x,y,w,h` in
pixels. Frame it **generously** — a box cropped to the plate's exact edges
loses the context the model uses, and one that only just fits will miss a tall
van or a low sports car.

```bash
export KIRPMA="820,540,600,220"
python kopru.py --test
```

Saves `kirpik.jpg` — confirm the plate is actually inside it — and then prints
live `hareket` values. Watch them with the lane empty and with a car pulling
in: that tells you what to set `HAREKET_ESIGI` (moving) and `DURGUN_ESIGI`
(still) to, instead of guessing.

If `kirpik.jpg` comes back under 200 px on its long edge, the bridge warns you.
That is the size at which the model's own documentation says reads become
unreliable — move the camera closer or zoom in; no amount of prompt tuning
recovers pixels that were never captured.

## Optional: skip the empty lane

A car **arriving** and a car **leaving** look identical to the bridge — motion,
then stillness — so by default it sends a photo for both, and every vehicle
costs two reads instead of one.

Point it at a reference of the empty lane and it stops paying for departures:

```bash
python kopru.py --bos      # run this while the lane is EMPTY
export BOS_REFERANS="bos.jpg"
```

**This cannot cause a missed vehicle, by design.** If the reference is wrong —
taken with a car in it, or in daylight and used at night — then an empty lane
also looks different from it and the bridge sends anyway. The worst case is the
behaviour you already have without it. That asymmetry is deliberate: a wasted
read costs a fraction of a cent, a missed car costs a free park.

Leave `BOS_REFERANS` unset and nothing changes.

## Run

```bash
export WEBHOOK_URL="https://<project-ref>.supabase.co/functions/v1/kamera-webhook"
export KAMERA_SECRET="<same value as the KAMERA_WEBHOOK_SECRET function secret>"
export RTSP_URL="rtsp://user:pass@10.0.0.42:554/stream1"
export YON="GIRIS"
export KIRPMA="820,540,600,220"
python kopru.py
```

**One process per lane.** Direction is configuration, never a guess — an exit
camera that thinks it is an entrance opens tickets for cars that are leaving.

On Windows, `set` instead of `export`, and use Task Scheduler ("run whether user
is logged on or not") instead of the systemd unit below.

### When it sends

One photo per car, taken at the moment the car **stops**: the bridge waits for
motion in the crop box and then for several still frames. That frame is both
the moment the plate is in position and the sharpest one available — a moving
car is the blurry one, and blur is what costs characters.

After a send it ignores the lane for `BEKLEME_SN` (60s). That is an API-cost
guard, not a data guard: if the same car were sent twice, the plate resolves to
the same value and the one-open-ticket-per-plate index refuses the second.

### Tuning

| Variable | Default | What it does |
|---|---|---|
| `KIRPMA` | *(none)* | `x,y,w,h` in pixels. Unset = send the whole frame, which works but reads worse. |
| `MAX_KENAR` | `1568` | Long-edge cap. Raise to `2576` only if `plaka_model` is a high-resolution model (Claude 4.7 and later). |
| `JPEG_KALITE` | `92` | Deliberately gentle — heavy JPEG makes text hard to read. |
| `HAREKET_ESIGI` | `6.0` | Above this, something is moving. |
| `DURGUN_ESIGI` | `2.0` | Below this, the scene is still. |
| `DURGUN_KARE` | `5` | Still frames required before believing the car stopped. |
| `BEKLEME_SN` | `60` | Lane ignored this long after a send. |
| `BOS_REFERANS` | *(none)* | Path to an empty-lane frame from `--bos`. Unset = send on every settle. |
| `BOS_ESIGI` | `3.0` | How close to the reference counts as "empty". |

## Keep it alive

The expensive failure is silent: if this process dies at 03:00, entries simply
stop being recorded, and a camera that stopped reading looks exactly like a car
park with no cars. Two things guard against it:

1. **systemd restarts it.** Save as `/etc/systemd/system/kopru.service`:

   ```ini
   [Unit]
   Description=Otopark kamera koprusu
   After=network-online.target

   [Service]
   EnvironmentFile=/etc/kopru.env
   ExecStart=/usr/bin/python3 /opt/kopru/kopru.py
   Restart=always
   RestartSec=10

   [Install]
   WantedBy=multi-user.target
   ```

   ```bash
   sudo systemctl enable --now kopru
   ```

2. **The server notices anyway.** The bridge pings every five minutes, and
   `run_kamera_kontrol` raises a Yönetici notification when the heartbeat goes
   stale — so a box that is off, unplugged or off the network surfaces as a
   push notification rather than as revenue that quietly stopped.

## Before you trust it

- **Set the camera's clock, and set NTP.** The bridge sends the time the car
  was *seen* and the server bills from it. A camera an hour off bills every car
  wrong, silently, forever.
- **Turn the camera on in the app**: Yönetim → Otopark ayarları → *Kamera girişi
  açık*. Until then the webhook refuses everything with 403.
- **Plate reading must be on too** (`plaka_saglayici` ≠ `KAPALI`) and the API
  key set. A photo arriving with reading switched off is refused with 409 —
  unlike the old build, this bridge has no local fallback.
- **Watch the first day's logs.** Every send and every refusal is printed.
- Cross-check `plaka_okuma_log` after a week: `onerilen` versus `kabul_edilen`
  is the real accuracy rate. Camera reads have no operator to confirm them, so
  this log is the only place a drift in accuracy will show up.
