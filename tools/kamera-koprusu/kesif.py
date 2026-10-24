# -*- coding: utf-8 -*-
"""
Kamerayı bulma ve RTSP adresini kendiliğinden çıkarma.

Kurulumdaki en zor soru "kameranızın RTSP adresi nedir?" idi ve kimse kutudan
bilmiyor: her marka farklı bir yol kullanıyor. Burası o soruyu ortadan
kaldırıyor — kullanıcı adı ve şifre yetiyor, gerisi denenerek bulunuyor.
"""
from __future__ import annotations

import base64
import contextlib
import hashlib
import os
import re
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


@contextlib.contextmanager
def _tcp_ile():
    """
    Denemeler köprünün yaptığı gibi TCP üzerinden; sonra değişken geri konur:
    kopru.py aynı değişkeni kendi ayarıyla kullanıyor ve tarama sırasındaki
    seçenek canlı akışa sızmamalı.
    """
    onceki = os.environ.get("OPENCV_FFMPEG_CAPTURE_OPTIONS")
    os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = _PROBE_SECENEK
    try:
        yield
    finally:
        if onceki is None:
            os.environ.pop("OPENCV_FFMPEG_CAPTURE_OPTIONS", None)
        else:
            os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = onceki


def dene(url: str) -> tuple[bool, tuple[int, int] | None]:
    """Tek bir adresi taramayla AYNI şekilde dener: (kare geldi mi, boyutu)."""
    with _tcp_ile():
        return _kare_alinabiliyor_mu(url)


def rtsp_bul(ip: str, kullanici: str, sifre: str, port: int = 554,
             bildir=None) -> tuple[str, str, tuple[int, int]] | None:
    """
    Şablonları sırayla dener, kare alabilen ilkini döndürür.

    (adres, marka, (genişlik, yükseklik)) ya da hiçbiri tutmazsa None.

    Şifreyi SINAMAZ: yanlış şifreyle yanlış yolu ayırt edemez ve her şablon
    bir giriş denemesidir. Önce kimlik_dogrula çağrılmalı (bkz. kurulum).
    """
    with _tcp_ile():
        for marka, yol in RTSP_YOLLARI:
            url = rtsp_adresi(ip, kullanici, sifre, yol, port)
            if bildir:
                bildir(marka, yol)
            ok, boyut = _kare_alinabiliyor_mu(url)
            if ok and boyut:
                return url, marka, boyut
        return None


# ------------------------------------------------------ şifre doğrulama ---

def _rtsp_cevabi(soket: socket.socket) -> tuple[int, dict[str, list[str]]] | None:
    """Bir RTSP cevabının durum kodu ve başlıkları (aynı ad birden çok kez gelebilir)."""
    tampon = b""
    while b"\r\n\r\n" not in tampon:
        parca = soket.recv(4096)
        if not parca:
            return None
        tampon += parca
        if len(tampon) > 65536:
            return None
    bas, _, govde = tampon.partition(b"\r\n\r\n")
    satirlar = bas.decode("utf-8", errors="replace").split("\r\n")
    ilk = satirlar[0].split()
    if len(ilk) < 2 or not ilk[0].upper().startswith("RTSP/") or not ilk[1].isdigit():
        return None
    basliklar: dict[str, list[str]] = {}
    for s in satirlar[1:]:
        if ":" in s:
            ad, _, deger = s.partition(":")
            basliklar.setdefault(ad.strip().lower(), []).append(deger.strip())
    # Gövde varsa okunup atılır ki aynı bağlantıdaki ikinci cevap kaymasın.
    try:
        kalan = int((basliklar.get("content-length") or ["0"])[0]) - len(govde)
    except ValueError:
        kalan = 0
    while kalan > 0:
        parca = soket.recv(min(kalan, 4096))
        if not parca:
            break
        kalan -= len(parca)
    return int(ilk[1]), basliklar


def _yetki_basligi(meydanlar: list[str], kullanici: str, sifre: str,
                   uri: str) -> str | None:
    """
    WWW-Authenticate meydan okumasına cevap: Digest (MD5, qop'lu ya da
    qopsuz) öncelikli, yoksa Basic. Anlaşılmayan biçim None — o zaman hüküm
    verilmez, tarama eskisi gibi sürer.
    """
    def md5(s: str) -> str:
        return hashlib.md5(s.encode("utf-8")).hexdigest()

    for m in meydanlar:
        if not m.lower().startswith("digest "):
            continue
        # Değer tırnaklı (virgül içerebilir) ya da tırnaksız olabilir. finditer:
        # findall katılmayan grubu '' verir ve ikisi ayırt edilemezdi.
        p: dict[str, str] = {}
        for e in re.finditer(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]*))', m):
            p[e.group(1).lower()] = e.group(2) if e.group(2) is not None else e.group(3)
        realm, nonce = p.get("realm"), p.get("nonce")
        algoritma = (p.get("algorithm") or "MD5").upper()
        if realm is None or not nonce or algoritma != "MD5":
            return None
        ha1 = md5(f"{kullanici}:{realm}:{sifre}")
        ha2 = md5(f"DESCRIBE:{uri}")
        alanlar = [f'username="{kullanici}"', f'realm="{realm}"', f'nonce="{nonce}"',
                   f'uri="{uri}"']
        qoplar = [q.strip().lower() for q in (p.get("qop") or "").split(",") if q.strip()]
        if "auth" in qoplar:
            nc, cnonce = "00000001", uuid.uuid4().hex[:16]
            cevap = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
            alanlar += [f'response="{cevap}"', "qop=auth", f"nc={nc}", f'cnonce="{cnonce}"']
        elif qoplar:
            return None
        else:
            alanlar.append(f'response="{md5(f"{ha1}:{nonce}:{ha2}")}"')
        if p.get("opaque") is not None:
            alanlar.append(f'opaque="{p["opaque"]}"')
        return "Digest " + ", ".join(alanlar)
    for m in meydanlar:
        if m.lower().startswith("basic"):
            jeton = base64.b64encode(f"{kullanici}:{sifre}".encode("utf-8")).decode("ascii")
            return "Basic " + jeton
    return None


def kimlik_dogrula(ip: str, port: int, kullanici: str, sifre: str,
                   zaman_asimi: float = 4.0) -> str:
    """
    Kameranın kullanıcı adını ve şifresini TEK bir kimlikli istekle sınar:
    "tamam" | "yanlis" | "bilinmiyor".

    NEDEN: rtsp_bul on yolu aynı şifreyle dener ve yanlış şifreyi yanlış
    yoldan ayıramaz, yani tek bir yazım hatası on başarısız giriş demekti.
    Kameralar bunu saldırı sayar ve hesabı kilitler (Dahua beş, Hikvision
    yedi yanlıştan sonra); doğru şifreyle yeniden deneyen kişi kilit sürerken
    yine "şifre yanlış" görüyordu ve kameranın web arayüzü de onu içeri
    almıyordu.

    Kökte bir DESCRIBE: kamera kimlik isterse (401) aynı isteği kimlikle bir
    kez daha gönderir. 401/403 → "yanlis". Başka her cevap → "tamam" (kimlik
    geçti; kökte yayın olmaması, 404, beklenen şeydir). Kimlik istemeyen, anlaşılmaz
    cevap veren ya da ulaşılamayan kamera → "bilinmiyor" ve tarama bugünkü
    gibi sürer: bu kontrol yalnızca bir yanlışı ERKEN yakalamak için var,
    kurulumu hiçbir zaman kendi başına durdurmaz.
    """
    uri = f"rtsp://{ip}:{port}/"

    def istek(soket: socket.socket, cseq: int, yetki: str | None):
        metin = (f"DESCRIBE {uri} RTSP/1.0\r\nCSeq: {cseq}\r\n"
                 "Accept: application/sdp\r\nUser-Agent: OtoparkKamera\r\n")
        if yetki:
            metin += f"Authorization: {yetki}\r\n"
        soket.sendall((metin + "\r\n").encode("utf-8"))
        return _rtsp_cevabi(soket)

    try:
        soket = socket.create_connection((ip, port), timeout=zaman_asimi)
    except (OSError, ValueError):
        return "bilinmiyor"
    try:
        soket.settimeout(zaman_asimi)
        ilk = istek(soket, 1, None)
        if ilk is None or ilk[0] != 401:
            return "bilinmiyor"
        yetki = _yetki_basligi(ilk[1].get("www-authenticate", []), kullanici, sifre, uri)
        if yetki is None:
            return "bilinmiyor"
        try:
            ikinci = istek(soket, 2, yetki)
        except OSError:
            ikinci = None
        if ikinci is None:
            # Bazı kameralar 401'den sonra bağlantıyı kapatır: aynı meydan
            # okumayla bir kez daha, yeni bir bağlantıdan (ffmpeg de böyle
            # yapar — bu kameralarda nonce bağlantıya bağlı değil).
            soket.close()
            soket = socket.create_connection((ip, port), timeout=zaman_asimi)
            soket.settimeout(zaman_asimi)
            ikinci = istek(soket, 2, yetki)
        if ikinci is None:
            return "bilinmiyor"
        # "stale" = şifre doğru ama nonce eskimiş. Yanlış şifre DEĞİLDİR:
        # yeni meydan okumayla bir kez daha.
        if ikinci[0] == 401 and any(
                "stale=true" in m.replace('"', "").replace(" ", "").lower()
                for m in ikinci[1].get("www-authenticate", [])):
            yetki = _yetki_basligi(ikinci[1].get("www-authenticate", []),
                                   kullanici, sifre, uri)
            if yetki is None:
                return "bilinmiyor"
            ikinci = istek(soket, 3, yetki)
            if ikinci is None:
                return "bilinmiyor"
        return "yanlis" if ikinci[0] in (401, 403) else "tamam"
    except (OSError, ValueError):
        return "bilinmiyor"
    finally:
        try:
            soket.close()
        except OSError:
            pass


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
