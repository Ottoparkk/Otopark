# Copy this to `baslat.ps1` and fill it in, then run:  .\baslat.ps1
#
# `baslat.ps1` is gitignored on purpose — it holds the webhook secret, and a
# secret in the repository is a secret you have to rotate.

$env:WEBHOOK_URL   = "https://<project-ref>.supabase.co/functions/v1/kamera-webhook"
$env:KAMERA_SECRET = "<KAMERA_WEBHOOK_SECRET ile aynı değer>"
$env:RTSP_URL      = "rtsp://kullanici:sifre@10.0.0.42:554/stream1"

# GIRIS or CIKIS. One launcher per lane — direction is configuration, never a
# guess: an exit camera that thinks it is an entrance opens tickets for cars
# that are leaving.
$env:YON   = "GIRIS"
$env:CIHAZ = "giris-kamerasi"

# The crop box, "x,y,w,h" in pixels. Find it once:
#   python kopru.py --kare   -> saves kare.jpg, measure the plate rectangle
#   python kopru.py --test   -> saves kirpik.jpg, confirm the plate is inside
# Leave it empty and the whole frame is sent, which works but reads worse.
$env:KIRPMA = "820,540,600,220"

# Opsiyonel. Şerit BOŞKEN `python kopru.py --bos` ile çekin. Gelen araçla giden
# araç kameradan aynı görünür; bu referans olmadan her araç için bir de boş
# şerit fotoğrafı okunur. Yanlış bir referans yalnızca fazladan okuma yaptırır,
# araç kaçırtmaz — o yüzden emin değilseniz boş bırakın.
# $env:BOS_REFERANS = "bos.jpg"

python kopru.py
