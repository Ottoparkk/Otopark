# -*- coding: utf-8 -*-
"""
Köprünün ekrana yazdığı her şeyi bir dosyaya da yazar.

NEDEN: kurulan hâlinde köprüyü Görev Zamanlayıcı SYSTEM olarak başlatıyor ve o
sürecin konsolu YOK. `print()` çıktısı hiçbir yere gitmiyor — README'nin
"ilk günün kayıtlarını izleyin" tavsiyesi de, her gönderim ve reddin
yazdırılması da, kurulmuş sistemde karşılığı olmayan cümlelerdi.

Bu, sessiz arızanın en pahalı hâli: köprü 03:00'te ölürse girişler kaydedilmeyi
bırakır ve okumayı kesmiş bir kamera, arabası olmayan bir otoparka benzer.

`print` çağrılarını `logging`e çevirmek yerine `sys.stdout` sarmalanıyor: 60'tan
fazla çağrı yerine dokunmadan hepsi kayda giriyor, elle çalıştırma yolu da
birebir aynı kalıyor.
"""
from __future__ import annotations

import atexit
import io
import os
import re
import sys
import threading
import time

AZAMI_BOYUT = 2 * 1024 * 1024      # 2 MB; ~5 günlük yoğun trafik
YEDEK_SAYISI = 2                   # toplam ~6 MB tavan


# rtsp://kullanici:sifre@host[:port]/yol — yalnızca YETKİ bölümü, ilk "/"ye
# kadar. Yolun içine taşan bir kalıp, şifreyi gizlerken adresin tamamını da
# gizler ve kayıt tanı için işe yaramaz hâle gelir.
_YETKI = re.compile(r"(rtsp://)([^/\s]+)", re.IGNORECASE)


def _maskele(m: "re.Match[str]") -> str:
    sema, yetki = m.group(1), m.group(2)
    if "@" not in yetki:
        return m.group(0)
    # SON "@" — RFC 3986: kimlik bilgisi orada biter. `partition` ile ilki
    # alınsaydı "p@ss" gibi bir şifrenin "ss" kısmı kayda düşerdi ve "@"
    # şifrelerde yaygın.
    kimlik, _, host = yetki.rpartition("@")
    kullanici, ayrac, _ = kimlik.partition(":")
    if not ayrac:
        return m.group(0)                       # şifre yok, gizlenecek bir şey yok
    return f"{sema}{kullanici}:•••@{host}"


def gizle(metin: str) -> str:
    """
    Kamera şifresini RTSP adresinden siler.

    Kayıt dosyası eklenmeden önce bu şifre kimsenin bakmadığı bir konsola
    yazılıyordu; artık diske YAZILIYOR ve orada kalıyor — yani kaydı eklemek,
    düzelttiği görünürlük sorununun yanında yeni bir sızıntı açıyordu. Tek tek
    çağrı yerlerini düzeltmek yerine burada süzülüyor: sonradan eklenen bir
    `print` de kendiliğinden kapsanıyor.
    """
    return _YETKI.sub(_maskele, metin)


# Sunucunun köprüyü REDDETTİĞİNİ söyleyen satırların sabit metinleri. Köprü
# (kopru.py) bunları yazar, `durum` (durum.py) bunları arar; ikisi aynı sabiti
# kullanmazsa bir taraftaki küçük bir yazım değişikliği, reddedilen bir köprüyü
# yeniden "ÇALIŞIYOR" gösterirdi.
RED_ISARETI = "sunucu kimliği reddetti"          # 401: kamera kaldırıldı / devre dışı
KAPALI_ISARETI = "sunucu kamera girişini kapalı bildirdi"   # 403: ayar kapalı
KABUL_ISARETI = "sunucu kimliği yeniden kabul etti"
# 409 + SERIT_UYUSMAZ: kamera uygulamada ÖBÜR şeride eşleştirilmiş.
SERIT_ISARETI = "sunucu şeridi reddetti"
# Kamera tarafı: köprü çalışıyor ve kayıt yazıyor ama görüntü alamıyor.
KAMERA_YOK_ISARETI = "kamera açılamadı"
KARE_YOK_ISARETI = "kare alınamadı"
KAMERA_VAR_ISARETI = "kamera bağlandı"


def kayit_klasoru() -> str:
    return os.path.join(
        os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark", "kayit"
    )


def kayit_yolu(yon: str) -> str:
    ad = (yon or "kopru").lower().replace(os.sep, "_")
    return os.path.join(kayit_klasoru(), f"kopru-{ad}.log")


class _Ikili(io.TextIOBase):
    """
    Hem asıl akışa hem dosyaya yazar. Hiçbir hata köprüyü öldürmemeli:
    dosya yazılamazsa sessizce devre dışı kalır ve konsol yolu sürer.
    """

    def __init__(self, akis, yol: str) -> None:
        self._akis = akis                      # None olabilir (konsolsuz .exe)
        self._yol = yol
        self._dosya = None
        self._boyut = 0
        self._satir_basi = True
        self._kilit = threading.Lock()         # gönderici iş parçacığı da yazar
        self._yerel = threading.local()        # yarım satırlar, iş parçacığı başına
        self._ac()

    # -- dosya --------------------------------------------------------------

    def _ac(self) -> None:
        try:
            os.makedirs(os.path.dirname(self._yol), exist_ok=True)
            self._dosya = open(self._yol, "a", encoding="utf-8", errors="replace")
            self._boyut = self._dosya.tell()
        except Exception as e:
            self._dosya = None
            # Asıl akışa yaz, kendimize değil: kendimize yazmak sonsuz döngü.
            if self._akis is not None:
                try:
                    self._akis.write(f"[!] kayıt dosyası açılamadı ({self._yol}): {e}\n")
                except Exception:
                    pass

    def _dondur(self) -> None:
        """
        Dosyayı sırayla kaydırır. Windows açık dosyayı yeniden adlandıramaz, o
        yüzden önce kapatılır; `os.replace` hedefin üstüne yazar (`os.rename`
        var olan dosyada patlar).

        Kaydırma başarısız olursa (biri dosyayı `Get-Content -Wait` ile
        izliyorsa olur) kayıt tutmaya devam edilir: dönmeyen bir dosya,
        kaybolan kayıtlardan iyidir.
        """
        try:
            self._dosya.close()
        except Exception:
            pass
        self._dosya = None
        try:
            # En eskiden başlayarak kaydır: .1 -> .2, sonra log -> .1.
            # Ters yönde dönülürse log her turda aynı .1'in üstüne yazar ve
            # YEDEK_SAYISI kaç olursa olsun tek yedek tutulur.
            for i in range(YEDEK_SAYISI, 0, -1):
                kaynak = f"{self._yol}.{i - 1}" if i > 1 else self._yol
                hedef = f"{self._yol}.{i}"
                if os.path.exists(kaynak):
                    os.replace(kaynak, hedef)   # rename var olan hedefte patlar
        except Exception:
            pass
        self._ac()

    # -- TextIOBase ---------------------------------------------------------

    def write(self, s: str) -> int:  # type: ignore[override]
        if not s:
            return 0
        if self._akis is not None:
            try:
                self._akis.write(s)
            except Exception:
                self._akis = None       # konsol gittiyse dosya yolu sürsün
        if self._dosya is None:
            return len(s)

        # Satırlar İŞ PARÇACIĞI BAŞINA tamponlanıyor. `print()` metni, ayracı
        # ve satır sonunu AYRI write() çağrılarıyla yazar: kilit tek çağrıyı korur
        # ama iki çağrı arasında öteki iş parçacığı araya girer ve satırlar
        # birbirinin içine geçer. Köprüde bu gerçek bir durum — yakalama
        # döngüsü "[i] araç durdu" yazarken gönderici "[+] gönderildi"
        # yazıyor — ve bozulan şey tek tanı kaydı oluyor.
        tampon = getattr(self._yerel, "metin", "") + s
        *tam, kalan = tampon.split("\n")
        self._yerel.metin = kalan
        if tam:
            damga = time.strftime("%d.%m %H:%M:%S")
            self._dosyaya(
                "".join((f"{damga}  {gizle(r)}\n" if r else "\n") for r in tam)
            )
        return len(s)

    def _dosyaya(self, metin: str) -> None:
        with self._kilit:
            if self._dosya is None:
                return
            try:
                # Kaydırma yazmadan ÖNCE: sonra kaydırılırsa taşıran satır da
                # yedeğe gider ve etkin dosya BOŞ kalır. O an `durum` komutu
                # tail'i boş görür ve sağlıklı bir köprüyü "kayıt yok" diye
                # bildirir.
                if self._boyut and self._boyut + len(metin) > AZAMI_BOYUT:
                    self._dondur()
                if self._dosya is None:
                    return
                self._dosya.write(metin)
                self._dosya.flush()
                self._boyut += len(metin)
            except Exception:
                try:
                    self._dosya.close()
                except Exception:
                    pass
                self._dosya = None      # bir daha denenmez; köprü sürer

    def flush(self) -> None:  # type: ignore[override]
        kalan = getattr(self._yerel, "metin", "")
        if kalan:
            self._yerel.metin = ""
            damga = time.strftime("%d.%m %H:%M:%S")
            self._dosyaya(f"{damga}  {gizle(kalan)}\n")
        with self._kilit:
            for h in (self._akis, self._dosya):
                if h is not None:
                    try:
                        h.flush()
                    except Exception:
                        pass

    def isatty(self) -> bool:  # type: ignore[override]
        return bool(self._akis is not None and getattr(self._akis, "isatty", bool)())


def baslat(yon: str) -> str | None:
    """
    stdout/stderr'i kayıt dosyasına bağlar. Köprünün başında bir kez çağrılır.
    Dosya yolunu döndürür (açılamadıysa yine de yol döner — `durum` onu arar).
    """
    yol = kayit_yolu(yon)
    try:
        sys.stdout = _Ikili(sys.stdout, yol)
        sys.stderr = _Ikili(sys.stderr, yol)
    except Exception:
        return None
    print(f"[i] ——— köprü başladı ({yon}) — pid {os.getpid()} ———", flush=True)

    # Çıkış izi. Bunsuz `durum` komutu, başlar başlamaz ölmüş bir köprüyü
    # SAĞLIKLI gösteriyordu: tek ölçüt kayıt dosyasının tazeliğiydi ve ölmek
    # de dosyayı tazeler. Yanlış yönde yanılan bir sağlık göstergesi,
    # göstergesizlikten kötüdür — kimse bakmayı bırakır.
    #
    # `atexit` sys.exit ve normal dönüşte çalışır; taskkill ya da elektrik
    # kesintisinde çalışmaz, ama o durumda dosya zaten bayatlar ve tazelik
    # ölçütü yakalar. İki kontrol birbirinin açığını kapatıyor.
    atexit.register(_bitis, yon)
    return yol


def _bitis(yon: str) -> None:
    try:
        print(f"[!] ——— köprü durdu ({yon}) ———", flush=True)
    except Exception:
        pass
