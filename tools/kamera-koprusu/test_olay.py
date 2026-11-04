# -*- coding: utf-8 -*-
"""
Kameranın araç olayları (1.2.6) — olay.py birim testleri.

    python test_olay.py

Neden kalıcı bir test: köprü 1.2.6'dan beri bir fotoğrafı ancak kamera
"araç gördüm" dediyse gönderiyor. Bu dinleyici yanlış çalışırsa iki kötü şeyden
biri olur: ya gerçek araçlar sessizce düşer (bilet yok), ya da kameranın
hesabı kilitlenir (yanlış şifreyle beş deneme) ve görüntü de gider. İkisi de
haftalar sonra "sayılar tutmuyor" diye ortaya çıkar.

Saf parçalar doğrudan, dinleyici ise bu süreçte açılan SAHTE bir Dahua
kamerasına karşı (gerçek soket, gerçek HTTP) sınanır. İnternet gerekmez.
"""
from __future__ import annotations

import hashlib
import os
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import olay  # noqa: E402


def _md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


# ------------------------------------------------------------------ digest ---

def test_digest_rfc2617_ornegi() -> None:
    """RFC 2617 §3.5'in kendi örneği: response 6629fae4…"""
    meydan = {"realm": "testrealm@host.com", "qop": "auth,auth-int",
              "nonce": "dcd98b7102dd2f0e8b11d0f600bfb0c093",
              "opaque": "5ccc069c403ebaf9f0171e9517f40e41"}
    h = olay.digest_basligi("Mufasa", "Circle Of Life", "GET", "/dir/index.html",
                            meydan, cnonce="0a4f113b", nc="00000001")
    assert 'response="6629fae49393a05397450978507c4ef1"' in h, h
    assert 'opaque="5ccc069c403ebaf9f0171e9517f40e41"' in h, h
    assert "qop=auth," in h or h.rstrip().endswith("qop=auth") or "qop=auth" in h, h
    assert 'uri="/dir/index.html"' in h, h


def test_digest_uri_koseli_parantezi_aynen_tasir() -> None:
    """Kamera `[All]`'u yalnızca yazıldığı gibi kabul ediyor (%5B ile 400)."""
    yol = "/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=5"
    h = olay.digest_basligi("otopark", "s", "GET", yol,
                            {"realm": "Login to X", "nonce": "n", "qop": "auth"},
                            cnonce="c", nc="00000001")
    assert f'uri="{yol}"' in h, h
    assert "%5B" not in h


def test_digest_qopsuz_eski_bicim() -> None:
    meydan = {"realm": "r", "nonce": "n"}
    h = olay.digest_basligi("u", "p", "GET", "/x", meydan, cnonce="c", nc="00000001")
    beklenen = _md5(f"{_md5('u:r:p')}:n:{_md5('GET:/x')}")
    assert f'response="{beklenen}"' in h, h
    assert "qop=" not in h and "cnonce" not in h, h


def test_meydan_coz_md5_tercih_edilir() -> None:
    """Dahua iki başlık gönderebilir (SHA-256 ve MD5); MD5 tercih edilir."""
    m = olay.meydan_sec([
        'Digest realm="Login to 1", qop="auth", nonce="aaa", opaque="o", algorithm=SHA-256',
        'Digest realm="Login to 1", qop="auth", nonce="bbb", opaque="o", algorithm=MD5',
    ])
    assert m is not None and m["nonce"] == "bbb", m
    m2 = olay.meydan_sec(['Digest realm="R", nonce="n1", qop="auth"'])
    assert m2 == {"realm": "R", "nonce": "n1", "qop": "auth"}, m2
    assert olay.meydan_sec(['Basic realm="x"']) is None
    assert olay.meydan_sec([]) is None


def test_meydan_yalniz_sha256_de_kullanilir() -> None:
    m = olay.meydan_sec(['Digest realm="R", nonce="n", qop="auth", algorithm=SHA-256'])
    h = olay.digest_basligi("u", "p", "GET", "/x", m, cnonce="c", nc="00000001")
    sha = lambda s: hashlib.sha256(s.encode()).hexdigest()  # noqa: E731
    ha1, ha2 = sha("u:R:p"), sha("GET:/x")
    assert f'response="{sha(f"{ha1}:n:00000001:c:auth:{ha2}")}"' in h, h
    assert "algorithm=SHA-256" in h, h


# ------------------------------------------------------------ parça ayırıcı ---

def _parca(govde: str, uzunluk: int | None = None, sinir: str = "myboundary") -> bytes:
    cl = len(govde.encode()) if uzunluk is None else uzunluk
    return (f"--{sinir}\r\nContent-Type: text/plain\r\nContent-Length: {cl}\r\n\r\n"
            f"{govde}\r\n").encode()


def test_sinir_bul() -> None:
    assert olay.sinir_bul("multipart/x-mixed-replace; boundary=myboundary") == "myboundary"
    assert olay.sinir_bul('multipart/x-mixed-replace; boundary="myboundary"') == "myboundary"
    assert olay.sinir_bul("multipart/x-mixed-replace;boundary=--abc") == "--abc"
    assert olay.sinir_bul("text/plain") is None


def test_ayirici_parcalari_cikarir() -> None:
    a = olay.ParcaAyirici("myboundary")
    akis = (_parca("Heartbeat") + _parca("Code=SmartMotionVehicle;action=Start;index=0")
            + _parca("Code=SmartMotionVehicle;action=Stop;index=0"))
    govdeler = a.besle(akis)
    # Son parça Content-Length'i doyurduğu için sınır beklemeden çıkar.
    assert govdeler == ["Heartbeat", "Code=SmartMotionVehicle;action=Start;index=0",
                        "Code=SmartMotionVehicle;action=Stop;index=0"], govdeler


def test_ayirici_bayt_bayt_beslense_de_ayni() -> None:
    """Parçalar sınırın, başlığın ortasından bölünerek gelir."""
    akis = (_parca("Heartbeat") + _parca("Code=SmartMotionVehicle;action=Start;index=0"))
    a = olay.ParcaAyirici("myboundary")
    cikti: list[str] = []
    for i in range(len(akis)):
        cikti += a.besle(akis[i:i + 1])
    assert cikti == ["Heartbeat", "Code=SmartMotionVehicle;action=Start;index=0"], cikti


def test_ayirici_yanlis_uzunlukta_sinira_guvenir() -> None:
    """Content-Length KISA yazılmış çok satırlı veri: gövde sınırda tamamlanır."""
    govde = ('Code=CrossLineDetection;action=Start;index=0;data={\n'
             '   "Object" : { "ObjectType" : "Vehicle" },\n   "Direction" : "A;B"\n}')
    a = olay.ParcaAyirici("myboundary")
    cikti = a.besle(_parca(govde, uzunluk=20) + _parca("Heartbeat"))
    tam = [c for c in cikti if c.startswith("Code=CrossLine")]
    assert tam and "ObjectType" in tam[-1], cikti
    # IVS parçası erken (kısa) hâliyle de bir kez çıkmamalı: tek kayıt.
    assert len([c for c in cikti if c.startswith("Code=CrossLine")]) == 1, cikti


def test_ayirici_uzunluksuz_parcada_sinira_kadar_bekler() -> None:
    a = olay.ParcaAyirici("myboundary")
    p1 = b"--myboundary\r\nContent-Type: text/plain\r\n\r\nCode=SmartMotionVehicle;action=Start;index=0\r\n"
    assert a.besle(p1) == []
    assert a.besle(b"--myboundary\r\n") == ["Code=SmartMotionVehicle;action=Start;index=0"]


def test_ayirici_basliksiz_parca() -> None:
    """Bazı yazılımlar parça başlığı yazmaz: gövde doğrudan sınırdan sonra."""
    a = olay.ParcaAyirici("myboundary")
    out = a.besle(b"--myboundary\r\nHeartbeat\r\n--myboundary\r\n")
    assert out == ["Heartbeat"], out


# ------------------------------------------------------------- olay çözme ---

def test_olay_coz() -> None:
    assert olay.olay_coz("Heartbeat") == ("Heartbeat", "", "")
    assert olay.olay_coz("Code=SmartMotionVehicle;action=Start;index=0") == \
        ("SmartMotionVehicle", "Start", "")
    k, e, v = olay.olay_coz('Code=CrossLineDetection;action=Pulse;index=0;data={"a":"x;y"}')
    assert (k, e) == ("CrossLineDetection", "Pulse") and v == '{"a":"x;y"}', (k, e, v)
    assert olay.olay_coz("rastgele metin") is None


def test_arac_siniflandirma() -> None:
    kodlar = ("SmartMotionVehicle",)
    assert olay.arac_turu("SmartMotionVehicle", "", kodlar) == "aralik"
    assert olay.arac_turu("SmartMotionHuman", "", kodlar) is None
    assert olay.arac_turu("VideoMotion", "", kodlar) is None
    assert olay.arac_turu("CrossLineDetection", '{"ObjectType":"Vehicle"}', kodlar) == "nokta"
    assert olay.arac_turu("CrossRegionDetection", '"ObjectType" : "MotorVehicle"', kodlar) == "nokta"
    assert olay.arac_turu("CrossLineDetection", '{"ObjectType":"Human"}', kodlar) is None
    # Bisiklet: adında "Vehicle" geçiyor ama araç DEĞİL.
    assert olay.arac_turu("CrossLineDetection", '{"ObjectType":"NonMotorVehicle"}', kodlar) is None
    assert olay.arac_turu("Heartbeat", "", kodlar) is None


# ------------------------------------------------------------------ defter ---

def test_defter_aralik_ve_nokta() -> None:
    d = olay.OlayDefteri(arac_kodlari=("SmartMotionVehicle",), aralik_tavani=60.0)
    assert not d.dogrulandi()
    d.kaydet("SmartMotionVehicle", "Start", "", 100.0)
    assert d.dogrulandi()
    assert d.arac_var(90.0, 101.0)          # aralık açık, pencere içinde başladı
    assert d.arac_var(110.0, 120.0)         # aralık hâlâ açık (Stop yok)
    d.kaydet("SmartMotionVehicle", "Stop", "", 105.0)
    assert d.arac_var(104.0, 110.0)         # 100-105 aralığı kesişir
    assert not d.arac_var(106.0, 120.0)     # kapandıktan sonraki pencere
    d.kaydet("CrossLineDetection", "Pulse", '{"ObjectType":"Vehicle"}', 200.0)
    assert d.arac_var(199.0, 201.0) and not d.arac_var(201.0, 205.0)
    # VideoMotion hiçbir şey açmaz.
    d.kaydet("VideoMotion", "Start", "", 300.0)
    assert not d.arac_var(299.0, 400.0)


def test_defter_stopsuz_aralik_tavanla_kapanir() -> None:
    d = olay.OlayDefteri(arac_kodlari=("SmartMotionVehicle",), aralik_tavani=60.0)
    d.kaydet("SmartMotionVehicle", "Start", "", 0.0)
    assert d.arac_var(59.0, 59.5)
    assert not d.arac_var(61.0, 62.0)


def test_defter_dogrulama_yalniz_tanidik_aracla() -> None:
    d = olay.OlayDefteri(arac_kodlari=("SmartMotionVehicle",))
    d.kaydet("VideoMotion", "Start", "", 1.0)
    d.kaydet("SmartMotionHuman", "Start", "", 2.0)
    assert not d.dogrulandi()


def test_defter_saglik() -> None:
    d = olay.OlayDefteri(saglik_sn=20.0)
    assert not d.saglikli(10.0)
    d.baglanti(True, 10.0)
    assert d.saglikli(25.0)                 # bağlandı, 15 sn — hâlâ taze
    assert not d.saglikli(31.0)             # 21 sn hiç parça yok
    d.parca_geldi(30.0)
    assert d.saglikli(31.0)
    d.baglanti(False, 32.0)
    assert not d.saglikli(32.5)
    # Doğrulama bağlantı kopsa da sürer (süreç boyunca).
    d.kaydet("SmartMotionVehicle", "Start", "", 33.0)
    d.baglanti(False, 34.0)
    assert d.dogrulandi()


def test_yollar_once_koseli_sonra_kodlu() -> None:
    y = olay.olay_yollari(5)
    assert y == ["/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=5",
                 "/cgi-bin/eventManager.cgi?action=attach&codes=%5BAll%5D&heartbeat=5"], y


# ------------------------------------------------------------- sahte kamera ---

class SahteKamera:
    """
    Dahua gibi davranan küçük bir HTTP sunucusu. `kip`:
      tamam        doğru digest → 200 multipart, olayları akıtır
      sifre        her doğrulanmış istek 401 (yanlış şifre)
      yetki        doğrulanmış istek 401 + "Invalid Authority"
      koseli_400   `[All]` ile 400, `%5BAll%5D` ile çalışır
      sessiz       200 döner, sonra hiçbir şey yazmaz
    """

    def __init__(self, kip: str, kullanici="otopark", sifre="Dogru#1", parcalar=None,
                 kapat=True):
        self.kip = kip
        self.kullanici, self.sifre = kullanici, sifre
        self.parcalar = parcalar or []
        self.kapat = kapat
        self.istekler: list[tuple[str, bool]] = []     # (istek yolu, Authorization var mı)
        self.basarisiz_giris = 0
        dis = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _yanit(self, kod, govde=b"", basliklar=None):
                self.send_response(kod)
                for k, v in (basliklar or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(govde)))
                self.end_headers()
                self.wfile.write(govde)

            def do_GET(self):
                yetkili = self.headers.get("Authorization")
                dis.istekler.append((self.path, bool(yetkili)))
                if dis.kip == "koseli_400" and "[All]" in self.path:
                    return self._yanit(400, b"Error\r\nBad Request!\r\n")
                if not yetkili:
                    return self._yanit(401, b"", {
                        "WWW-Authenticate": 'Digest realm="Login to TEST", qop="auth", '
                                            'nonce="n0nce", opaque="0paque"'})
                if dis.kip == "yetki":
                    return self._yanit(401, b"Error\r\nInvalid Authority!\r\n")
                if dis.kip == "sifre" or not dis._digest_dogru(yetkili, self.path):
                    dis.basarisiz_giris += 1
                    return self._yanit(401, b"", {
                        "WWW-Authenticate": 'Digest realm="Login to TEST", qop="auth", '
                                            'nonce="n0nce2", opaque="0paque"'})
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=myboundary")
                self.send_header("Connection", "close")
                self.end_headers()
                if dis.kip == "sessiz":
                    time.sleep(3)
                    return
                for gecikme, govde in dis.parcalar:
                    time.sleep(gecikme)
                    try:
                        self.wfile.write(_parca(govde))
                        self.wfile.flush()
                    except OSError:
                        return
                if not dis.kapat:
                    time.sleep(3)

        self.sunucu = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.sunucu.server_address[1]
        threading.Thread(target=self.sunucu.serve_forever, daemon=True).start()

    def _digest_dogru(self, baslik: str, yol: str) -> bool:
        alan = dict(re.findall(r'(\w+)="?([^",]*)"?', baslik))
        if alan.get("username") != self.kullanici or alan.get("uri") != yol:
            return False
        ha1 = _md5(f"{self.kullanici}:{alan.get('realm')}:{self.sifre}")
        ha2 = _md5(f"GET:{yol}")
        if "qop" in alan:
            beklenen = _md5(f"{ha1}:{alan['nonce']}:{alan['nc']}:{alan['cnonce']}:{alan['qop']}:{ha2}")
        else:
            beklenen = _md5(f"{ha1}:{alan['nonce']}:{ha2}")
        return alan.get("response") == beklenen and alan.get("opaque") == "0paque"

    def kapat_(self) -> None:
        self.sunucu.shutdown()


def test_oturum_dogru_sifreyle_olaylari_kaydeder() -> None:
    k = SahteKamera("tamam", parcalar=[
        (0, "Heartbeat"),
        (0, "Code=VideoMotion;action=Start;index=0"),
        (0, "Code=SmartMotionVehicle;action=Start;index=0"),
        (0, "Code=SmartMotionVehicle;action=Stop;index=0"),
    ])
    try:
        d = olay.OlayDefteri(arac_kodlari=("SmartMotionVehicle",))
        sonuc = olay.oturum("127.0.0.1", k.port, "otopark", "Dogru#1", d, okuma_sn=2)
        assert sonuc == "koptu", sonuc          # sunucu akışı kapattı
        assert d.dogrulandi()
        # Her istek yolu köşeli parantezi AYNEN taşıdı.
        assert all("[All]" in yol for yol, _ in k.istekler), k.istekler
        assert k.basarisiz_giris == 0
    finally:
        k.kapat_()


def test_oturum_yanlis_sifrede_tek_basarisiz_giris() -> None:
    """Dahua beş yanlışta hesabı kilitler; bir oturum en çok BİR yanlış dener."""
    k = SahteKamera("sifre")
    try:
        d = olay.OlayDefteri()
        assert olay.oturum("127.0.0.1", k.port, "otopark", "Yanlis", d, okuma_sn=2) == "sifre"
        assert k.basarisiz_giris == 1, k.basarisiz_giris
        assert not d.saglikli(time.monotonic())
    finally:
        k.kapat_()


def test_oturum_yetki_yoksa_yetki_der() -> None:
    k = SahteKamera("yetki")
    try:
        assert olay.oturum("127.0.0.1", k.port, "otopark", "Dogru#1",
                           olay.OlayDefteri(), okuma_sn=2) == "yetki"
    finally:
        k.kapat_()


def test_oturum_400de_kodlu_yolu_dener() -> None:
    k = SahteKamera("koseli_400", parcalar=[(0, "Code=SmartMotionVehicle;action=Start;index=0")])
    try:
        d = olay.OlayDefteri(arac_kodlari=("SmartMotionVehicle",))
        sonuc = olay.oturum("127.0.0.1", k.port, "otopark", "Dogru#1", d, okuma_sn=2)
        assert sonuc == "koptu", sonuc
        assert d.dogrulandi()
        assert any("%5BAll%5D" in yol for yol, _ in k.istekler), k.istekler
    finally:
        k.kapat_()


def test_oturum_sessiz_akista_zaman_asimi() -> None:
    k = SahteKamera("sessiz")
    try:
        d = olay.OlayDefteri()
        t0 = time.monotonic()
        assert olay.oturum("127.0.0.1", k.port, "otopark", "Dogru#1", d, okuma_sn=1) == "koptu"
        assert time.monotonic() - t0 < 5
    finally:
        k.kapat_()


def test_oturum_kamera_yoksa_hata() -> None:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()                                   # dinleyen yok: bağlantı reddedilir
    assert olay.oturum("127.0.0.1", port, "u", "p", olay.OlayDefteri(), okuma_sn=1) == "hata"


def test_dinleyici_yanlis_sifrede_bekler_kilitlemez() -> None:
    """Döngü yanlış şifreden sonra SIFRE bekleme süresi boyunca yeniden denemez."""
    k = SahteKamera("sifre")
    beklemeler: list[float] = []
    dur = threading.Event()

    def uyu(sn: float) -> None:
        beklemeler.append(sn)
        dur.wait(0.05)
        if len(beklemeler) >= 3:
            dur.set()
            raise SystemExit

    try:
        try:
            olay.dinle("127.0.0.1", k.port, "otopark", "Yanlis", olay.OlayDefteri(),
                       uyu=uyu, sifre_bekleme=600.0, okuma_sn=1)
        except SystemExit:
            pass
        # Her denemeden sonra 600 sn beklendi; deneme başına tek yanlış giriş.
        assert beklemeler and all(b >= 600 for b in beklemeler), beklemeler
        assert k.basarisiz_giris == len(beklemeler), (k.basarisiz_giris, beklemeler)
    finally:
        k.kapat_()


def test_dinleyici_yetki_hatasinda_uzun_bekler() -> None:
    k = SahteKamera("yetki")
    beklemeler: list[float] = []

    def uyu(sn: float) -> None:
        beklemeler.append(sn)
        raise SystemExit

    try:
        try:
            olay.dinle("127.0.0.1", k.port, "otopark", "Dogru#1", olay.OlayDefteri(),
                       uyu=uyu, okuma_sn=1)
        except SystemExit:
            pass
        assert beklemeler == [olay.YETKI_BEKLEME_SN], beklemeler
        assert olay.YETKI_BEKLEME_SN >= 3600
    finally:
        k.kapat_()


def test_dinleyici_kopunca_yeniden_baglanir() -> None:
    k = SahteKamera("tamam", parcalar=[(0, "Heartbeat")])
    sayac = []

    def uyu(sn: float) -> None:
        sayac.append(sn)
        if len(sayac) >= 2:
            raise SystemExit
        time.sleep(0.01)

    try:
        try:
            olay.dinle("127.0.0.1", k.port, "otopark", "Dogru#1", olay.OlayDefteri(),
                       uyu=uyu, okuma_sn=1)
        except SystemExit:
            pass
        bagli_istekler = [y for y, yetkili in k.istekler if yetkili]
        assert len(bagli_istekler) >= 2, k.istekler    # koptu → yeniden bağlandı
        assert all(s <= 60 for s in sayac), sayac
    finally:
        k.kapat_()


def test_kimlik_rtsp_adresinden() -> None:
    k = olay.kimlik("rtsp://otopark:Gizli%40Sifre%3A1@192.168.50.20:554/cam/realmonitor?channel=1")
    assert k == ("192.168.50.20", "otopark", "Gizli@Sifre:1"), k
    assert olay.kimlik("rtsp://192.168.50.20:554/x") is None      # kullanıcı yok
    assert olay.kimlik("") is None


def test_kayitlarda_sifre_yok() -> None:
    """Hiçbir durum metni şifreyi taşımamalı."""
    for sebep in ("sifre", "yetki", "desteklenmiyor", "hata", "koptu"):
        metin = olay.sebep_metni(sebep)
        assert metin and "Dogru#1" not in metin


def test_ayarlar_baslatirken_okunur() -> None:
    """
    Ayarlar İÇE AKTARMADA değil BAŞLATIRKEN okunur. kopru olay'ı, şeridin
    ayar dosyasını ortama yüklemeden ÖNCE içe aktarır: dosyaya yazılan
    OLAY_ARAC_KODLARI / OLAY_PORT aksi hâlde sessizce yok sayılırdı — sahada
    "olay adı farklı çıktı, ayar dosyasına yazın" düzeltmesi hiç işlemezdi.
    """
    adlar = ("OLAY_ARAC_KODLARI", "OLAY_PORT", "SIFRE_RED_BEKLEME_SN", "OLAY_SAGLIK_SN")
    eski = {k: os.environ.get(k) for k in adlar}
    onceki_dinle = olay.dinle
    eski_kodlar, eski_saglik = olay.defter()._kodlar, olay.defter()._saglik
    cagri: dict = {}
    olay.dinle = lambda ip, port, k, s, d, **kw: cagri.update(ip=ip, port=port, kw=kw, d=d)
    try:
        # olay ZATEN içe aktarılmış; ayarlar ancak şimdi ortama giriyor.
        os.environ.update(OLAY_ARAC_KODLARI="AracX, AracY", OLAY_PORT="8081",
                          SIFRE_RED_BEKLEME_SN="900", OLAY_SAGLIK_SN="33")
        assert olay.baslat("rtsp://u:p@10.0.0.5:554/x") is True
        bitis = time.monotonic() + 5
        while not cagri and time.monotonic() < bitis:
            time.sleep(0.01)
        assert cagri["ip"] == "10.0.0.5" and cagri["port"] == 8081, cagri
        assert cagri["kw"].get("sifre_bekleme") == 900, cagri["kw"]
        assert cagri["d"] is olay.defter()
        d = olay.defter()
        assert d._saglik == 33, d._saglik
        assert d.kaydet("AracY", "Start", "", 1.0) is True
        assert d.kaydet("SmartMotionVehicle", "Start", "", 1.0) is False
        # Bozuk bir sayı köprüyü düşürmez: dinleyici başlamaz, köprü 1.2.5 gibi.
        os.environ["OLAY_PORT"] = "sekizyuz"
        cagri.clear()
        assert olay.baslat("rtsp://u:p@10.0.0.5:554/x", kayit=lambda s: None) is False
    finally:
        olay.dinle = onceki_dinle
        olay.defter()._kodlar, olay.defter()._saglik = eski_kodlar, eski_saglik
        for k, v in eski.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def test_olay_kipi_serit_dosyasini_okur() -> None:
    """`--olay` da şeridin ayar dosyasındaki olay adını ve portu kullanır."""
    import io
    import json as _json
    import tempfile
    from contextlib import redirect_stdout
    onceki = olay.oturum
    cagri: dict = {}

    def sahte(ip, port, kullanici, sifre, d, **kw):
        cagri.update(port=port, kodlar=d._kodlar)
        return "koptu"
    olay.oturum = sahte
    yol = os.path.join(tempfile.mkdtemp(), "kopru-ortak.json")
    with open(yol, "w", encoding="utf-8") as f:
        _json.dump({"RTSP_URL": "rtsp://u:p@10.0.0.5:554/x",
                    "OLAY_ARAC_KODLARI": "AracZ", "OLAY_PORT": 8082}, f)
    try:
        with redirect_stdout(io.StringIO()):
            olay.test_kipi(yol, sure_sn=2)
        assert cagri == {"port": 8082, "kodlar": ("AracZ",)}, cagri
    finally:
        olay.oturum = onceki


if __name__ == "__main__":
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    basarisiz: list[str] = []
    for t in testler:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            basarisiz.append(t.__name__)
            print(f"  FAIL  {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti")
    sys.exit(1 if basarisiz else 0)
