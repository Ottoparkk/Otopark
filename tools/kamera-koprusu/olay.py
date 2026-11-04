# -*- coding: utf-8 -*-
"""
Kameranın kendi araç olayları (1.2.6).

Dahua kamerası "Akıllı Hareket Algılama — Motorlu Araç" açıkken her geçen araç
için bir olay üretir; insanlar, gölgeler, ışık değişimi için üretmez. Köprü
1.2.6'dan beri bir fotoğrafı ancak böyle bir olay o geçişe denk geldiyse
gönderir (kopru.py, OLAY_KAPISI). Bu modül olayları dinler ve bir deftere
yazar; karar kopru.py'de.

Neden `requests` değil, `http.client`: kamera adres satırında `codes=[All]`
istiyor ve `%5BAll%5D`'ye 400 veriyor (sahada PowerShell'le görüldü).
`requests` köşeli parantezi HER ZAMAN kodluyor (yerel bir dinleyiciyle
ölçüldü); `http.client` yazıldığı gibi gönderiyor.

Neden kendi digest'imiz: `urllib.request`'in digest işleyicisi reddedilen
girişi beş kereye kadar yeniden dener — Dahua tam beş yanlışta hesabı
kilitler ve aynı hesap görüntüyü de taşır. Burada bir oturum en çok BİR
doğrulanmış istek yapar; şifre reddedilirse SIFRE_RED_BEKLEME_SN beklenir
(köprünün görüntü tarafındaki 1.2.2 kuralıyla aynı).

Hiçbir kayıt satırı ve hiçbir adres kimlik taşımaz: kullanıcı/şifre yalnızca
Authorization başlığına girer.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import threading
import time
from collections import deque

import gunluk

# ------------------------------------------------------------------ ayarlar ---


def calisma_ayarlari(ek: dict | None = None) -> dict:
    """
    Dinleyicinin ayarları — İÇE AKTARMADA değil, BAŞLATIRKEN okunur: kopru bu
    modülü şeridin ayar dosyasını ortama yüklemeden önce içe aktarıyor, ayar
    dosyasına yazılan bir düzeltme aksi hâlde sessizce yok sayılırdı.
    Ortam önce gelir (kopru'nun `setdefault` kuralıyla aynı), sonra `ek`
    (`--olay` kipinde şeridin ayar dosyası). Bozuk sayı ValueError fırlatır.
    """
    def al(ad: str, varsayilan: str) -> str:
        v = os.environ.get(ad)
        if v is None and ek is not None and ek.get(ad) is not None:
            v = str(ek[ad])
        return varsayilan if v is None else v
    # SmartMotionVehicle: Dahua SMD'nin araç olayı (sahada --olay ile
    # doğrulanacak). Ad farklı çıkarsa şeridin ayar dosyasına
    # OLAY_ARAC_KODLARI yazılır; yeni sürüm gerekmez. Boş bırakılırsa varsayılan.
    kodlar = tuple(k.strip() for k in al("OLAY_ARAC_KODLARI", "").split(",") if k.strip())
    return dict(
        kodlar=kodlar or ("SmartMotionVehicle",),
        port=int(al("OLAY_PORT", "80")),
        okuma=float(al("OLAY_OKUMA_SN", "15")),         # sessiz akış = kopuk
        saglik=float(al("OLAY_SAGLIK_SN", "20")),
        sifre_bekleme=float(al("SIFRE_RED_BEKLEME_SN", "600")),
    )


# Varsayılanlar (testler ve ayarsız çağrılar için); gerçek değerler baslat()'ta.
# Düz sabitler, ortamdan okunmaz: içe aktarma ASLA patlamamalı — bozuk bir
# ortam değişkeni burada köprüyü açılışta düşürürdü.
ARAC_KODLARI = ("SmartMotionVehicle",)
# IVS (çizgi/bölge) olayları: araç mı insan mı, gövdedeki ObjectType söyler.
NOKTA_KODLARI = ("CrossLineDetection", "CrossRegionDetection")
ARAC_NESNELERI = ("Vehicle", "MotorVehicle")       # "NonMotorVehicle" = bisiklet, DEĞİL

PORT = 80
HEARTBEAT_SN = 5
OKUMA_SN = 15.0
SAGLIK_SN = 20.0
ARALIK_TAVANI_SN = 60.0          # Stop gelmeyen bir araç aralığı en çok bu kadar sürer

SIFRE_RED_BEKLEME_SN = 600.0
YETKI_BEKLEME_SN = 3600.0        # izin eksikliği 10 dakikada kendiliğinden düzelmez
DESTEK_BEKLEME_SN = 600.0
YENIDEN_MAX_SN = 60.0


# ------------------------------------------------------------------- digest ---

def _ozet(algoritma: str):
    if algoritma.upper().startswith("SHA-256"):
        return lambda s: hashlib.sha256(s.encode("utf-8")).hexdigest()
    return lambda s: hashlib.md5(s.encode("utf-8")).hexdigest()


def _tirnak(s: str) -> str:
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


def digest_basligi(kullanici: str, sifre: str, yontem: str, uri: str, meydan: dict,
                   cnonce: str | None = None, nc: str = "00000001") -> str:
    """RFC 2617/7616 Authorization değeri. `uri` istek satırındakiyle AYNI olmalı."""
    algoritma = meydan.get("algorithm", "MD5")
    H = _ozet(algoritma)
    realm, nonce = meydan.get("realm", ""), meydan.get("nonce", "")
    ha1 = H(f"{kullanici}:{realm}:{sifre}")
    ha2 = H(f"{yontem}:{uri}")
    qoplar = [q.strip() for q in meydan.get("qop", "").split(",") if q.strip()]
    alanlar = [f'username="{_tirnak(kullanici)}"', f'realm="{_tirnak(realm)}"',
               f'nonce="{_tirnak(nonce)}"', f'uri="{uri}"']
    if "auth" in qoplar:
        cnonce = cnonce or secrets.token_hex(8)
        cevap = H(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        alanlar += [f'response="{cevap}"', "qop=auth", f"nc={nc}", f'cnonce="{cnonce}"']
    else:
        alanlar.append(f'response="{H(f"{ha1}:{nonce}:{ha2}")}"')
    if "opaque" in meydan:
        alanlar.append(f'opaque="{_tirnak(meydan["opaque"])}"')
    if "algorithm" in meydan:
        alanlar.append(f"algorithm={algoritma}")
    return "Digest " + ", ".join(alanlar)


_MEYDAN_ALAN = re.compile(r'(\w+)=(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))')


def meydan_sec(basliklar: list[str]) -> dict | None:
    """WWW-Authenticate başlıklarından bir Digest meydan okuması; MD5 tercih edilir."""
    adaylar = []
    for b in basliklar or []:
        if not b or not b.strip().lower().startswith("digest"):
            continue
        alan = {m.group(1): (m.group(2) if m.group(2) is not None else m.group(3))
                for m in _MEYDAN_ALAN.finditer(b.strip()[6:])}
        if "nonce" in alan:
            adaylar.append(alan)
    for a in adaylar:
        if a.get("algorithm", "MD5").upper() == "MD5":
            return a
    for a in adaylar:
        if a.get("algorithm", "").upper().startswith("SHA-256"):
            return a
    return None


# ------------------------------------------------------------- parça ayırma ---

def sinir_bul(content_type: str) -> str | None:
    m = re.search(r'boundary=(?:"([^"]+)"|([^;\s]+))', content_type or "", re.I)
    if not m:
        return None
    return m.group(1) or m.group(2)


_OLAY = re.compile(r"Code=([^;]+);action=([^;]+)(?:;index=[^;]*)?(?:;data=(.*))?\Z", re.S)


def olay_coz(govde: str) -> tuple[str, str, str] | None:
    s = (govde or "").strip()
    if s == "Heartbeat":
        return ("Heartbeat", "", "")
    m = _OLAY.match(s)
    if not m:
        return None
    return (m.group(1).strip(), m.group(2).strip(), (m.group(3) or "").strip())


def arac_turu(kod: str, veri: str, arac_kodlari=ARAC_KODLARI) -> str | None:
    """"aralik" (Start…Stop), "nokta" (tek an) ya da None (araç değil)."""
    if kod in arac_kodlari:
        return "aralik"
    if kod in NOKTA_KODLARI:
        m = re.search(r'"ObjectType"\s*:\s*"([^"]+)"', veri or "")
        if m and m.group(1) in ARAC_NESNELERI:
            return "nokta"
    return None


class ParcaAyirici:
    """
    multipart akışını parçalara ayırır. Parça SINIRDA biter; Content-Length'e
    güvenilmez (bazı yazılımlar çok satırlı veride yanlış sayar). Tek istisna,
    gecikmesin diye: Content-Length doymuşsa ve gövde verisi gerekmeyen bir
    olaysa (araç kodu, Heartbeat) parça sınır beklenmeden ERKEN çıkar — sınır
    ancak bir SONRAKİ parçayla, yani ~5 sn sonra gelir.
    """

    def __init__(self, sinir: str):
        s = sinir.encode("latin-1")
        self._sinirlar = [b"--" + s] + ([s] if sinir.startswith("--") else [])
        self._buf = b""
        self._icinde = False
        self._erken = False

    def _sinir_ara(self, baslangic: int = 0) -> tuple[int, int] | None:
        """(indeks, uzunluk) — yalnızca satır başındaki sınır sayılır."""
        en_iyi = None
        for s in self._sinirlar:
            i = self._buf.find(s, baslangic)
            while i != -1 and not (i == 0 or self._buf[i - 1:i] == b"\n"):
                i = self._buf.find(s, i + 1)
            if i != -1 and (en_iyi is None or i < en_iyi[0]):
                en_iyi = (i, len(s))
        return en_iyi

    @staticmethod
    def _bol(icerik: bytes) -> tuple[dict, bytes]:
        for ayrac in (b"\r\n\r\n", b"\n\n"):
            if ayrac in icerik:
                bas, govde = icerik.split(ayrac, 1)
                satirlar = [s for s in bas.decode("latin-1").splitlines() if s.strip()]
                if satirlar and all(":" in s for s in satirlar):
                    basliklar = {}
                    for s in satirlar:
                        k, v = s.split(":", 1)
                        basliklar[k.strip().lower()] = v.strip()
                    return basliklar, govde
        return {}, icerik

    @staticmethod
    def _metin(b: bytes) -> str:
        return b.decode("utf-8", errors="replace").strip()

    def besle(self, veri: bytes) -> list[str]:
        self._buf += veri
        cikti: list[str] = []
        while True:
            if not self._icinde:
                bul = self._sinir_ara()
                if bul is None:
                    uzun = max(len(s) for s in self._sinirlar)
                    self._buf = self._buf[-uzun:] if len(self._buf) > uzun else self._buf
                    return cikti
                i, n = bul
                satir_sonu = self._buf.find(b"\n", i + n)
                if satir_sonu == -1:
                    self._buf = self._buf[i:]
                    return cikti
                self._buf = self._buf[satir_sonu + 1:]
                self._icinde, self._erken = True, False
                continue
            bul = self._sinir_ara()
            if bul is None:
                if not self._erken:
                    erken = self._erken_govde(self._buf)
                    if erken is not None:
                        cikti.append(erken)
                        self._erken = True
                return cikti
            i, _n = bul
            icerik, self._buf = self._buf[:i], self._buf[i:]
            self._icinde = False
            if not self._erken:
                _b, govde = self._bol(icerik)
                metin = self._metin(govde)
                if metin:
                    cikti.append(metin)

    def _erken_govde(self, icerik: bytes) -> str | None:
        basliklar, govde = self._bol(icerik)
        try:
            n = int(basliklar.get("content-length", ""))
        except ValueError:
            return None
        if len(govde) < n:
            return None
        aday = self._metin(govde[:n])
        ev = olay_coz(aday)
        if ev is None or ev[0] in NOKTA_KODLARI:
            return None          # çözülemedi ya da IVS (veri gerek): sınırı bekle
        return aday


# ------------------------------------------------------------------- defter ---

class OlayDefteri:
    """Araç olaylarının zamanları (time.monotonic, dizüstünün saati) ve akışın sağlığı."""

    def __init__(self, arac_kodlari=ARAC_KODLARI, aralik_tavani: float = ARALIK_TAVANI_SN,
                 saglik_sn: float = SAGLIK_SN):
        self._kodlar = tuple(arac_kodlari)
        self._tavan = aralik_tavani
        self._saglik = saglik_sn
        self._kilit = threading.Lock()
        self._acik: dict[str, float] = {}
        self._kapali: deque[tuple[float, float]] = deque(maxlen=500)
        self._nokta: deque[float] = deque(maxlen=500)
        self._dogrulandi = False
        self._son_arac: float | None = None
        self._bagli = False
        self._son_parca = float("-inf")

    def ayarla(self, arac_kodlari, saglik_sn: float) -> None:
        """Başlatırken okunan ayarlar (bkz. calisma_ayarlari)."""
        with self._kilit:
            self._kodlar = tuple(arac_kodlari)
            self._saglik = saglik_sn

    def kaydet(self, kod: str, eylem: str, veri: str, t: float) -> bool:
        """Araç olayıysa kaydeder ve True döner."""
        tur = arac_turu(kod, veri, self._kodlar)
        if tur is None:
            return False
        e = (eylem or "").lower()
        with self._kilit:
            self._dogrulandi = True
            self._son_arac = t
            if tur == "nokta":
                self._nokta.append(t)
            elif e == "stop":
                bas = self._acik.pop(kod, None)
                self._kapali.append((t if bas is None else bas, t))
            else:                                  # Start / Pulse
                bas = self._acik.get(kod)
                if bas is not None and t - bas > self._tavan:
                    self._kapali.append((bas, bas + self._tavan))
                    bas = None
                if bas is None:
                    self._acik[kod] = t
        return True

    def arac_var(self, bas: float, bit: float) -> bool:
        with self._kilit:
            if any(a <= bit and b >= bas for a, b in self._kapali):
                return True
            if any(a <= bit and a + self._tavan >= bas for a in self._acik.values()):
                return True
            return any(bas <= t <= bit for t in self._nokta)

    def dogrulandi(self) -> bool:
        with self._kilit:
            return self._dogrulandi

    def son_arac(self) -> float | None:
        with self._kilit:
            return self._son_arac

    def baglanti(self, bagli: bool, t: float) -> None:
        with self._kilit:
            self._bagli = bagli
            if bagli:
                self._son_parca = t

    def parca_geldi(self, t: float) -> None:
        with self._kilit:
            self._son_parca = t

    def saglikli(self, simdi: float) -> bool:
        with self._kilit:
            return self._bagli and simdi - self._son_parca <= self._saglik


# ---------------------------------------------------------------- bağlantı ---

def olay_yollari(heartbeat: int = HEARTBEAT_SN) -> list[str]:
    taban = "/cgi-bin/eventManager.cgi?action=attach&codes={}&heartbeat=" + str(heartbeat)
    return [taban.format("[All]"), taban.format("%5BAll%5D")]


def kimlik(rtsp_url: str) -> tuple[str, str, str] | None:
    """(ip, kullanıcı, şifre) — köprünün zaten kullandığı RTSP adresinden."""
    import kesif           # geç: kesif cv2'yi içe aktarır
    p = kesif.rtsp_parcala(rtsp_url or "")
    if not p or not p[2]:
        return None
    return (p[0], p[2], p[3])


def sebep_metni(sebep: str) -> str:
    return {
        "sifre": "kamera şifreyi kabul etmedi",
        "yetki": "kamera kullanıcısının Olay izni yok",
        "desteklenmiyor": "kamera olay aboneliğini kabul etmedi (400/404)",
        "hata": "kameraya bağlanılamadı",
        "koptu": "olay bağlantısı koptu",
    }.get(sebep, sebep)


def oturum(ip: str, port: int, kullanici: str, sifre: str, defter: OlayDefteri,
           okuma_sn: float = OKUMA_SN, heartbeat: int = HEARTBEAT_SN,
           yazdir=None, bagli_bildir=None) -> str:
    """
    Tek bağlantı denemesi ve (açılırsa) akış. Sonuç: "koptu" (akış açıldı,
    sonra bitti/sustu), "sifre", "yetki", "desteklenmiyor" ya da "hata".
    En çok BİR doğrulanmış istek (adres biçimi başına) — yanlış şifrede biri.
    """
    yollar = olay_yollari(heartbeat)
    for sira, yol in enumerate(yollar):
        try:
            c1 = http.client.HTTPConnection(ip, port, timeout=okuma_sn)
            c1.request("GET", yol, headers={"Connection": "close"})
            r1 = c1.getresponse()
            r1.read()
            c1.close()
            if r1.status in (400, 404):
                if sira == 0:
                    continue
                return "desteklenmiyor"
            if r1.status != 401:
                return "hata"
            meydan = meydan_sec(r1.headers.get_all("WWW-Authenticate") or [])
            if meydan is None:
                return "hata"
            c2 = http.client.HTTPConnection(ip, port, timeout=okuma_sn)
            c2.request("GET", yol, headers={
                "Authorization": digest_basligi(kullanici, sifre, "GET", yol, meydan)})
            r2 = c2.getresponse()
            if r2.status in (401, 403):
                govde = r2.read()
                c2.close()
                if b"Invalid Authority" in govde or r2.status == 403:
                    return "yetki"
                return "sifre"
            if r2.status in (400, 404):
                r2.read()
                c2.close()
                if sira == 0:
                    continue
                return "desteklenmiyor"
            if r2.status != 200:
                r2.read()
                c2.close()
                return "hata"
            if yazdir:
                yazdir(f"bağlandı: {yol}  (Content-Type: {r2.getheader('Content-Type')}, "
                       f"Transfer-Encoding: {r2.getheader('Transfer-Encoding')})")
            return _akis_oku(r2, c2, defter, yazdir, bagli_bildir)
        except (OSError, http.client.HTTPException):
            return "hata"
    return "desteklenmiyor"


def _akis_oku(r, conn, defter: OlayDefteri, yazdir, bagli_bildir) -> str:
    ayirici = ParcaAyirici(sinir_bul(r.getheader("Content-Type", "")) or "myboundary")
    defter.baglanti(True, time.monotonic())
    if bagli_bildir:
        bagli_bildir()
    ilk = True
    try:
        while True:
            veri = r.read1(4096)
            if not veri:
                return "koptu"
            if ilk and b"Invalid Authority" in veri:
                return "yetki"
            ilk = False
            t = time.monotonic()
            for govde in ayirici.besle(veri):
                defter.parca_geldi(t)
                ev = olay_coz(govde)
                arac = False
                if ev and ev[0] != "Heartbeat":
                    arac = defter.kaydet(ev[0], ev[1], ev[2], t)
                if yazdir:
                    ilk_satir = govde.splitlines()[0] if govde else ""
                    yazdir(f"{ilk_satir[:150]}{'   ← ARAÇ' if arac else ''}")
    except (OSError, http.client.HTTPException):
        return "koptu"
    finally:
        defter.baglanti(False, time.monotonic())
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def dinle(ip: str, port: int, kullanici: str, sifre: str, defter: OlayDefteri,
          uyu=time.sleep, sifre_bekleme: float = SIFRE_RED_BEKLEME_SN,
          okuma_sn: float = OKUMA_SN, kayit=None) -> None:
    """Sonsuz döngü: bağlan, oku, bekle. Kayda yalnızca DURUM DEĞİŞİMİ yazılır."""
    kayit = kayit or (lambda s: print(s, flush=True))
    son = {"sebep": None, "bagli": False}
    geri = 1.0

    def bagli_bildir() -> None:
        if not son["bagli"]:
            kayit(f"[i] {gunluk.OLAY_BAGLI_ISARETI}")
        son["bagli"], son["sebep"] = True, None

    while True:
        bas = time.monotonic()
        sebep = oturum(ip, port, kullanici, sifre, defter, okuma_sn=okuma_sn,
                       bagli_bildir=bagli_bildir)
        sure = time.monotonic() - bas
        if sebep != son["sebep"] or (sebep == "koptu" and son["bagli"]):
            kayit(f"[!] {gunluk.OLAY_YOK_ISARETI}: {sebep_metni(sebep)}")
        son["sebep"], son["bagli"] = sebep, False
        if sebep == "sifre":
            bekle = sifre_bekleme
        elif sebep == "yetki":
            bekle = YETKI_BEKLEME_SN
        elif sebep == "desteklenmiyor":
            bekle = DESTEK_BEKLEME_SN
        elif sebep == "koptu" and sure >= 30:
            geri = 1.0                     # uzun süre açık kaldı: hemen yeniden
            bekle = geri
        else:
            bekle = geri
            geri = min(geri * 2, YENIDEN_MAX_SN)
        uyu(bekle)


# --------------------------------------------------------------- tek örnek ---

_defter = OlayDefteri()


def defter() -> OlayDefteri:
    return _defter


def kaydet(kod: str, eylem: str, t: float, veri: str = "") -> bool:
    """Test dikişi: test_kopru olayları HTTP olmadan buradan verir."""
    return _defter.kaydet(kod, eylem, veri, t)


def baslat(rtsp_url: str, kayit=None) -> bool:
    """Dinleyiciyi arka planda başlatır. Kimlik yoksa False (köprü 1.2.5 gibi çalışır)."""
    k = kimlik(rtsp_url)
    if k is None:
        return False
    try:
        a = calisma_ayarlari()
    except ValueError as e:
        # Bozuk bir ayar köprüyü düşürmemeli: dinleyici başlamaz, köprü 1.2.5 gibi.
        (kayit or (lambda s: print(s, flush=True)))(
            f"[!] {gunluk.OLAY_YOK_ISARETI}: ayar hatalı ({e})")
        return False
    ip, kullanici, sifre = k
    _defter.ayarla(a["kodlar"], a["saglik"])
    threading.Thread(target=dinle, args=(ip, a["port"], kullanici, sifre, _defter),
                     kwargs={"kayit": kayit, "sifre_bekleme": a["sifre_bekleme"],
                             "okuma_sn": a["okuma"]},
                     daemon=True, name="olay").start()
    return True


# --------------------------------------------------------------- --olay kipi ---

def test_kipi(ayar_yolu: str, sure_sn: float = 120.0) -> int:
    """`OtoparkKamera.exe --olay`: kameranın olaylarını canlı gösterir."""
    try:
        with open(ayar_yolu, encoding="utf-8-sig") as f:
            ayar = json.load(f)
    except (OSError, ValueError) as e:
        print(f"  Ayar dosyası okunamadı ({ayar_yolu}): {e}")
        return 1
    k = kimlik(str(ayar.get("RTSP_URL", "")))
    if k is None:
        print("  Kamera adresinde kullanıcı adı yok — olay dinlenemez.")
        return 1
    try:
        a = calisma_ayarlari(ayar)
    except ValueError as e:
        print(f"  Ayar dosyasında hatalı değer: {e}")
        return 1
    ip, kullanici, sifre = k
    print(f"\n  Kameranın olayları dinleniyor: {ip}  (kullanıcı: {kullanici})")
    print(f"  Araç olayı adları: {', '.join(a['kodlar'])}")
    print(f"  {int(sure_sn)} saniye sürer; Ctrl+C ile erken bitirebilirsiniz.")
    print("  Bir araç ve bir insan geçirin. Araç olayları '← ARAÇ' ile işaretlenir.\n")
    d = OlayDefteri(arac_kodlari=a["kodlar"], saglik_sn=a["saglik"])
    sonuc: dict = {}

    def yazdir(s: str) -> None:
        print(f"  {time.strftime('%H:%M:%S')}  {s}", flush=True)

    def calis() -> None:
        sonuc["sebep"] = oturum(ip, a["port"], kullanici, sifre, d, okuma_sn=a["okuma"],
                                yazdir=yazdir)

    t = threading.Thread(target=calis, daemon=True)
    t.start()
    try:
        t.join(sure_sn)
    except KeyboardInterrupt:
        pass
    print()
    if "sebep" in sonuc and sonuc["sebep"] != "koptu":
        print(f"  ✗ {sebep_metni(sonuc['sebep'])}")
        return 1
    if d.dogrulandi():
        print("  ✓ Kamera araç olaylarını gönderiyor. Köprü yalnızca araçları gönderecek.")
        return 0
    print("  ! Bağlantı var ama bu sürede tanınan bir araç olayı gelmedi.")
    print("    Araç geçti mi? Geçtiyse yukarıdaki satırlardaki olay adını Claude'a iletin.")
    return 2
