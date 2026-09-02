# Kamera köprüsü

Reads plates from an IP camera on a computer at the car park and posts them to
`kamera-webhook`. **Nothing in this folder is part of the web app** — it is not
built, typechecked or deployed with it. It runs on hardware you own.

The camera never touches the internet. It talks to this machine over the LAN;
this machine talks out. That is the whole security argument for the bridge.

## What you need

- A computer on the same network as the camera. An old laptop is the best
  choice available: it has a screen for diagnosis and the UPS is already
  inside it. A Raspberry Pi 5 works but EasyOCR runs on PyTorch, which is slow
  on ARM — expect about a second per read.
- Python 3.10+
- The camera's RTSP URL (from its own web interface).
- A plate-detection model as `plate.pt`. Do **not** train one first — there are
  free pretrained plate detectors on Roboflow Universe. Train your own only if
  a public one demonstrably fails on your gate, and only after the camera is
  installed, since a custom model is only better when trained on *your* angle
  and lighting.

## Install

```bash
pip install -r requirements.txt
```

`ultralytics` is **AGPL-3.0**. For a private box that only talks to your own
webhook this is generally fine, but it is a licence question, not a technical
one — take advice before this becomes part of a commercial offering, or swap
in a permissively licensed detector.

## Run

```bash
export WEBHOOK_URL="https://<project-ref>.supabase.co/functions/v1/kamera-webhook"
export KAMERA_SECRET="<same value as the KAMERA_WEBHOOK_SECRET function secret>"
export RTSP_URL="rtsp://user:pass@10.0.0.42:554/stream1"
export YON="GIRIS"
python kopru.py
```

**One process per lane.** Direction is configuration, never a guess — an exit
camera that thinks it is an entrance opens tickets for cars that are leaving.

On Windows, `set` instead of `export`, and use Task Scheduler ("run whether
user is logged on or not") instead of the systemd unit below.

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
  was *seen* and the server bills from it. A camera an hour off bills every
  car wrong, silently, forever.
- **Turn the camera on in the app**: Yönetim → Otopark ayarları → *Kamera
  girişi açık*. Until then the webhook refuses everything with 403.
- **Watch the first day's logs.** Every send and every refusal is printed.
- Cross-check against `plaka_okuma_log` after a week: `onerilen` vs
  `kabul_edilen` is the real accuracy rate, and it is what tells you whether
  this build is worth keeping or whether the crop should just be forwarded to
  the model instead.

## The simpler variant

If accuracy disappoints, delete the EasyOCR half. Post the **cropped JPEG** to
the same webhook (`Content-Type: image/jpeg`, raw body) and the server reads it
with the same model the phone uses. You keep the camera, the box, the crop and
the voting, and drop PyTorch, the allowlist tuning and the accuracy question —
the crop is what drives accuracy anyway, and it costs about $0.001 per read.
