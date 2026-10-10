# -*- coding: utf-8 -*-
"""
Kamerayı bulma ve RTSP adresini kendiliğinden çıkarma.

Kurulumdaki en zor soru "kameranızın RTSP adresi nedir?" idi ve kimse kutudan
bilmiyor: her marka farklı bir yol kullanıyor. Burası o soruyu ortadan
kaldırıyor — kullanıcı adı ve şifre yetiyor, gerisi denenerek bulunuyor.
"""
from __future__ import annotations

import os
import socket
import urllib.parse
import uuid

import cv2

# Marka başına RTSP yolları. Ana akış (main/101) önce: alt akış çoğu kamerada
# 640x360 civarı ve plakaya yetmiyor, ama bağlanabildiği için "çalıştı" gibi
# görünür. Yanlış ama bağlanan bir adres, hiç bağlanmayandan daha kötüdür.
RTSP_YOLLARI: list[tuple[str, str]] = [
    ("Hikvision", "/Streaming/Channels/101"),
    ("Dahua / Amcrest", "/cam/realmonitor?channel=1&subtype=0"),
    ("TP-Link VIGI", "/stream1"),
    ("Uniview", "/media/video1"),
    ("Axis", "/axis-media/media.amp"),
    ("Reolink", "/h264Preview_01_main"),
    ("ONVIF (genel)", "/onvif1"),
    ("Genel", "/live"),
    ("Genel", "/11"),
    ("Genel", "/live/ch0"),
]

# Tarama sırasında da TCP: köprünün kendisi öyle bağlanıyor.
_PROBE_SECENEK = "rtsp_transport;tcp"

# Bir şablonun denenmesine ayrılan süre. Sınırı OpenCV'nin KENDİ zaman aşımı
# koyuyor: FFmpeg'in `stimeout` (ve `timeout`) seçeneği burada işe YARAMIYOR —
# ölçüldü (opencv-python-headless 4.13.0.92): cevap vermeyen bir adreste ikisi
# de 30 sn bekledi, yani on şablonluk tarama beş dakika asılı kalıyordu.
# 6 sn: gerçek bir kameranın akışı açıp ilk kareyi vermesine yeter.
ACMA_ZAMAN_ASIMI_MS = 6000
OKUMA_ZAMAN_ASIMI_MS = 6000


def rtsp_adresi(ip: str, kullanici: str, sifre: str, yol: str, port: int = 554) -> str:
    """Kullanıcı adı ve şifre URL-kodlanır: '@' ya da ':' içeren şifre adresi bozar."""
    k = urllib.parse.quote(kullanici, safe="")
    s = urllib.parse.quote(sifre, safe="")
    kimlik = f"{k}:{s}@" if kullanici else ""
    return f"rtsp://{kimlik}{ip}:{port}{yol}"


def _kare_alinabiliyor_mu(url: str) -> tuple[bool, tuple[int, int] | None]:
    cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG, [
        cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, ACMA_ZAMAN_ASIMI_MS,
        cv2.CAP_PROP_READ_TIMEOUT_MSEC, OKUMA_ZAMAN_ASIMI_MS,
    ])
    try:
        if not cap.isOpened():
            return False, None
        ok, kare = cap.read()
        if not ok or kare is None:
            return False, None
        yh, yw = kare.shape[:2]
        return True, (yw, yh)
    finally:
        cap.release()


def port_acik(ip: str, port: int = 554, saniye: float = 3.0) -> bool:
    """
    Kameranın RTSP portuna TCP ile ulaşılabiliyor mu?

    Şablon taramasından ÖNCE sorulur: yanlış IP ya da kapalı RTSP'de on şablonun
    her biri zaman aşımına kadar beklerdi ve sonunda yine "bulunamadı" derdi.
    Tek bir bağlantı denemesi aynı cevabı üç saniyede ve sebebiyle verir.
    """
    try:
        with socket.create_connection((ip, port), timeout=saniye):
            return True
    except (OSError, ValueError):
        return False


def rtsp_bul(ip: str, kullanici: str, sifre: str, port: int = 554,
             bildir=None) -> tuple[str, str, tuple[int, int]] | None:
    """
    Şablonları sırayla dener, kare alabilen ilkini döndürür.

    (adres, marka, (genişlik, yükseklik)) ya da hiçbiri tutmazsa None.
    """
    onceki = os.environ.get("OPENCV_FFMPEG_CAPTURE_OPTIONS")
    os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = _PROBE_SECENEK
    try:
        for marka, yol in RTSP_YOLLARI:
            url = rtsp_adresi(ip, kullanici, sifre, yol, port)
            if bildir:
                bildir(marka, yol)
            ok, boyut = _kare_alinabiliyor_mu(url)
            if ok and boyut:
                return url, marka, boyut
        return None
    finally:
        # Geri konur: kopru.py aynı değişkeni kendi ayarıyla kullanıyor ve
        # tarama sırasındaki kısa zaman aşımı canlı akışa sızmamalı.
        if onceki is None:
            os.environ.pop("OPENCV_FFMPEG_CAPTURE_OPTIONS", None)
        else:
            os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = onceki


# ------------------------------------------------------------------ keşif ---

_PROBE = """<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<e:Header>
 <w:MessageID>uuid:{mid}</w:MessageID>
 <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
 <w:Action e:mustUnderstand="true">\
http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
</e:Header>
<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
</e:Envelope>"""


def kameralari_ara(saniye: float = 3.0) -> list[str]:
    """
    ONVIF WS-Discovery: ağa çok noktaya yayın yapıp cevap veren kameraların
    IP'lerini toplar. Bağımlılık yok, ham UDP.

    Cevap gövdesi ayrıştırılmıyor, yalnızca GÖNDEREN adresi alınıyor: bize
    lazım olan tek şey IP, ve cihazın kendi bildirdiği servis adresi çoğu kez
    NAT arkası ya da yanlış oluyor.
    """
    ip_ler: set[str] = set()
    mesaj = _PROBE.format(mid=uuid.uuid4()).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        s.settimeout(0.5)
        s.sendto(mesaj, ("239.255.255.250", 3702))
        import time
        bitis = time.monotonic() + saniye
        while time.monotonic() < bitis:
            try:
                _, adres = s.recvfrom(65535)
                ip_ler.add(adres[0])
            except socket.timeout:
                continue
            except OSError:
                break
    except OSError:
        # Çok noktaya yayın engelliyse keşif yok; elle IP girme yolu duruyor.
        pass
    finally:
        s.close()
    return sorted(ip_ler)
