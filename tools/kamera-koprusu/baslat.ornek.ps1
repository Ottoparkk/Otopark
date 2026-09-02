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

python kopru.py
