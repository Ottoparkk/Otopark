# -*- coding: utf-8 -*-
"""
Kurulum tarafının birim testleri.

    python test_kurulum.py

Ayar yükleme burada test ediliyor çünkü bozulursa köprü hiç BAŞLAMAZ ve bunu
kimse fark etmez: bariyerde sessizce duran bir süreç, arabası olmayan bir
otoparka benzer. Kalanı (RTSP adres kurma, eşik önerisi) saf fonksiyon.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

# kopru içe aktarılırken `requests` gerekiyor ama kurulu olmayabilir; testin
# konusu o değil.
ONYUK = (
    "import sys,types\n"
    "r=types.ModuleType('requests')\n"
    "r.RequestException=Exception\n"
    "r.post=lambda *a,**k: None\n"
    "sys.modules['requests']=r\n"
    f"sys.path.insert(0, {BURASI!r})\n"
)


def kopru_degeri(alanlar: list[str], ayar: dict | None, env: dict | None = None,
                 argv: list[str] | None = None) -> list[str]:
    """Ayrı süreçte kopru'yu içe aktarır ve istenen modül değişkenlerini döndürür."""
    with tempfile.TemporaryDirectory() as klasor:
        yol = os.path.join(klasor, "ayar.json")
        if ayar is not None:
            with open(yol, "w", encoding="utf-8") as f:
                json.dump(ayar, f)
        kod = ONYUK + (
            "import kopru\n"
            "print('\\n'.join(str(getattr(kopru, a)) for a in "
            f"{alanlar!r}))\n"
        )
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8"}
        # Testi çalıştıran kabuktan sızabilecek değerler sonucu kirletmesin.
        for a in ("WEBHOOK_URL", "KAMERA_SECRET", "RTSP_URL", "YON", "CIHAZ",
                  "OTOPARK_AYAR"):
            ortam.pop(a, None)
        if ayar is not None and not argv:
            ortam["OTOPARK_AYAR"] = yol
        ortam.update(env or {})
        komut = [sys.executable, "-c", kod] + [
            (yol if p == "@AYAR@" else p) for p in (argv or [])
        ]
        r = subprocess.run(komut, capture_output=True, text=True,
                           encoding="utf-8", env=ortam)
        if r.returncode:
            raise AssertionError(f"alt süreç hata verdi:\n{r.stderr[-800:]}")
        return r.stdout.strip().splitlines()


def test_ayar_json() -> None:
    d = kopru_degeri(["WEBHOOK_URL", "YON", "KIRPMA"],
                     {"WEBHOOK_URL": "http://x/kamera-webhook",
                      "YON": "CIKIS", "KIRPMA": "1,2,3,4"})
    assert d == ["http://x/kamera-webhook", "CIKIS", "1,2,3,4"], d


def test_env_json_yener() -> None:
    """Gerçek ortam değişkeni dosyayı yenmeli: elle çalıştırma yolu bozulmasın."""
    d = kopru_degeri(["YON"], {"YON": "CIKIS"}, env={"YON": "GIRIS"})
    assert d == ["GIRIS"], d


def test_argv_ayar() -> None:
    d = kopru_degeri(["YON"], {"YON": "CIKIS"}, argv=["--ayar", "@AYAR@"])
    assert d == ["CIKIS"], d


def test_ayar_yoksa_patlamaz() -> None:
    """Dosya yoksa köprü yine de açılmalı — elle env ile başlatma yolu var."""
    d = kopru_degeri(["MAX_KENAR", "YON", "MAX_KENAR"], None)
    # Şeridin VARSAYILANI YOK: eskiden "GIRIS"e düşüyordu, yani YON verilmeden
    # elle başlatılan bir çıkış köprüsü giden araçlara bilet açıyordu. İçe
    # aktarma yine patlamaz (--kare / --test şerit istemez); eksik şeridi
    # main() reddeder — bkz. test_kopru_seritsiz_baslamaz.
    assert d == ["1568", "", "1568"], d      # ortadaki boş satır: YON


def test_bozuk_ayar_patlamaz() -> None:
    with tempfile.TemporaryDirectory() as klasor:
        yol = os.path.join(klasor, "bozuk.json")
        with open(yol, "w", encoding="utf-8") as f:
            f.write("{ bu json degil")
        kod = ONYUK + "import kopru\nprint(kopru.YON)\n"
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol}
        for a in ("YON", "WEBHOOK_URL"):
            ortam.pop(a, None)
        ortam["OTOPARK_AYAR"] = yol
        r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                           text=True, encoding="utf-8", env=ortam)
        assert r.returncode == 0, r.stderr[-600:]
        assert "okunamadı" in r.stdout, r.stdout


def test_rtsp_adresi_kacisi() -> None:
    import kesif
    # '@' ve ':' içeren şifre kaçırılmazsa adres tamamen başka bir host'a gider.
    u = kesif.rtsp_adresi("10.0.0.5", "admin", "p@ss:w/ord", "/stream1")
    assert u == "rtsp://admin:p%40ss%3Aw%2Ford@10.0.0.5:554/stream1", u
    assert kesif.rtsp_adresi("10.0.0.5", "", "", "/x") == "rtsp://10.0.0.5:554/x"


def test_esik_oner() -> None:
    import kirpma_sunucu
    # Az veri: kopru.py varsayılanları. Kötü bir öneri, tahminden tehlikelidir.
    assert kirpma_sunucu.esik_oner([1.0] * 10) == (2.0, 6.0)
    # Çoğu zaman durgun, arada hareket olan gerçekçi bir dağılım.
    olcum = [0.3] * 900 + [14.0] * 100
    durgun, hareket = kirpma_sunucu.esik_oner(olcum)
    assert 0.5 <= durgun < hareket, (durgun, hareket)
    assert hareket <= 14.0, hareket
    # Yalnızca DURGUN bir sahne gözlendiyse (kutu kaydedildikten sonraki birkaç
    # saniye çoğu zaman böyle) hareketin ölçeği bilinmiyor demektir. Gürültü
    # tabanından "hareket eşiği" uydurmak, eşiği gürültünün hemen üstüne koyar
    # ve şerit hiç durgun görünmez. Varsayılanlar korunur; yalnızca gürültü
    # tabanı onları AŞIYORSA yükseltilir.
    assert kirpma_sunucu.esik_oner([0.3] * 120) == (2.0, 6.0)
    assert kirpma_sunucu.esik_oner([0.0] * 120) == (2.0, 6.0)
    durgun, hareket = kirpma_sunucu.esik_oner([2.5] * 120)
    assert durgun > 2.5 and hareket >= 3 * durgun - 0.01, (durgun, hareket)


def test_teshis_kapsami() -> None:
    """Webhook'un ürettiği her ret kodunun Türkçe bir karşılığı olmalı."""
    import kurulum
    for kod in (401, 403, 409, 429, 502):
        assert kod in kurulum.TESHIS, kod


def test_kurulum_kodu_cozulur() -> None:
    import base64
    import builtins
    import kurulum

    ayar = {"WEBHOOK_URL": "http://x/functions/v1/kamera-webhook",
            "KAMERA_SECRET": "y" * 32, "YON": "CIKIS"}
    kod = base64.b64encode(json.dumps(ayar).encode()).decode().rstrip("=")
    eski = builtins.input
    builtins.input = lambda *a: kod
    try:
        import io
        from contextlib import redirect_stdout
        yakala = io.StringIO()
        with redirect_stdout(yakala):
            cikan = kurulum.sunucu_bilgisi()
    finally:
        builtins.input = eski
    assert cikan == ayar, cikan
    # Ekrana yazılan şerit de doğru olmalı: küçük harf 'yon' okuyan bir sürüm
    # sessizce GIRIS diyordu ve çıkış kamerası kuran kişi bunu fark etmezdi.
    assert "CIKIS şeridi" in yakala.getvalue(), yakala.getvalue()


def test_baglanti_teshisi() -> None:
    """
    400 BAŞARI demek: webhook gövdeyi ayrıştırmadan önce gizli anahtarı
    doğrulayıp kalp atışını günceller, yani boş POST'a 400 döner. Bunu hata
    sayan bir sihirbaz, çalışan bir kurulumu bozuk gösterirdi.
    """
    import types
    import kurulum

    class Yanit:
        def __init__(self, k):
            self.status_code = k
            self.text = ""

    def sahte(kod):
        m = types.ModuleType("requests")
        m.post = lambda *a, **k: Yanit(kod)
        return m

    ayar = {"WEBHOOK_URL": "http://x", "KAMERA_SECRET": "z" * 32}
    for kod, beklenen in ((400, True), (401, False), (403, False), (429, False)):
        sys.modules["requests"] = sahte(kod)
        assert kurulum.baglanti_testi(ayar) is beklenen, kod
    sys.modules.pop("requests", None)


def test_gorev_komutu_kopruyu_calistirir() -> None:
    """
    Paketlenmiş sürümde görev komutu `--kopru` TAŞIMAK ZORUNDA.

    Tek .exe argümansız çalıştırıldığında sihirbazı açıyor: bu bayrak
    düşerse Görev Zamanlayıcı her açılışta SYSTEM olarak görünmez bir
    kurulum sihirbazı başlatır, köprü hiç çalışmaz ve otopark kameranın
    çalıştığını sanarak bilet açmadan işler. Sessiz ve pahalı.
    """
    import kurulum
    eski = getattr(sys, "frozen", None)
    try:
        sys.frozen = True                      # type: ignore[attr-defined]
        k = kurulum.gorev_komutu(r"C:\ProgramData\Otopark\kopru-giris.json")
        assert "--kopru" in k, k
        assert "--ayar" in k and k.index("--kopru") < k.index("--ayar"), k
        # Yol boşluk içerebilir; tırnaksız komut schtasks'ta parçalanır.
        assert k.count('"') >= 4, k
    finally:
        if eski is None:
            del sys.frozen                     # type: ignore[attr-defined]
        else:
            sys.frozen = eski                  # type: ignore[attr-defined]

    # Kaynaktan çalışırken kopru.py'ye gidilmeli, sihirbaza değil.
    k = kurulum.gorev_komutu("/tmp/a.json")
    assert "kopru.py" in k and "kurulum.py" not in k, k


def test_gunluk_dondurur() -> None:
    """Kayıt dosyası sınırsız büyümemeli ve EN YENİ satır etkin dosyada kalmalı."""
    import glob
    import gunluk
    eski = gunluk.AZAMI_BOYUT
    try:
        gunluk.AZAMI_BOYUT = 200
        klasor = tempfile.mkdtemp()
        yol = os.path.join(klasor, "r.log")
        t = gunluk._Ikili(None, yol)
        for i in range(60):
            t.write(f"satir-{i:03d} xxxxxxxxxxxxxxxxxxxxxxxxxxxx\n")
        t.flush()
        dosyalar = sorted(os.path.basename(f) for f in glob.glob(yol + "*"))
        assert dosyalar == ["r.log", "r.log.1", "r.log.2"], dosyalar
        # Kaydırma yazmadan ÖNCE olmalı: sonra olursa etkin dosya boş kalır ve
        # `durum` sağlıklı bir köprüyü "kayıt yok" diye bildirir.
        assert "satir-059" in open(yol, encoding="utf-8").read()
        for f in glob.glob(yol + "*"):
            assert os.path.getsize(f) <= 280, (f, os.path.getsize(f))
    finally:
        gunluk.AZAMI_BOYUT = eski


def test_gunluk_satirlar_bolunmez() -> None:
    """
    İki iş parçacığının satırları birbirine karışmamalı.

    `print()` metni ve satır sonunu AYRI write() çağrılarıyla yazıyor; köprüde
    yakalama döngüsü ile gönderici aynı anda yazıyor ve bozulan şey elimizdeki
    tek tanı kaydı oluyor.
    """
    import re
    import threading
    import gunluk
    yol = os.path.join(tempfile.mkdtemp(), "p.log")
    t = gunluk._Ikili(None, yol)

    def yaz(ad: str) -> None:
        for i in range(300):
            print(f"{ad}-{i}", "ek", "alan", file=t)

    isler = [threading.Thread(target=yaz, args=(a,)) for a in ("A", "B", "C")]
    for x in isler:
        x.start()
    for x in isler:
        x.join()
    t.flush()
    satirlar = [s for s in open(yol, encoding="utf-8").read().split("\n") if s]
    assert len(satirlar) == 900, len(satirlar)
    bozuk = [s for s in satirlar
             if not re.match(r"\d\d\.\d\d \d\d:\d\d:\d\d  [ABC]-\d+ ek alan$", s)]
    assert not bozuk, bozuk[:3]


def _durum_senaryosu(satirlar: list[str], gorev: bool = True,
                     yas_sn: float = 0) -> tuple[bool, str]:
    import io as _io
    import time as _time
    from contextlib import redirect_stdout
    import durum
    import gunluk

    klasor = tempfile.mkdtemp()
    os.environ["PROGRAMDATA"] = klasor
    ayar = os.path.join(klasor, "Otopark", "kopru-giris.json")
    os.makedirs(os.path.dirname(ayar), exist_ok=True)
    with open(ayar, "w", encoding="utf-8") as f:
        json.dump({"YON": "GIRIS", "KAMERA_SECRET": "cok-gizli-anahtar-123",
                   "RTSP_URL": "rtsp://admin:hunter2@10.0.0.42:554/s1",
                   "KIRPMA": "1,2,3,4"}, f)
    log = gunluk.kayit_yolu("GIRIS")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "w", encoding="utf-8") as f:
        f.write("\n".join(satirlar) + "\n")
    if yas_sn:
        n = _time.time() - yas_sn
        os.utime(log, (n, n))

    onceki = durum.gorev_var_mi
    durum.gorev_var_mi = lambda y: gorev
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            ok = durum.serit_durumu(ayar)
        return ok, yakala.getvalue()
    finally:
        durum.gorev_var_mi = onceki


def test_durum_baslar_baslamaz_olen_kopru() -> None:
    """
    Başlar başlamaz ölen köprü SAĞLIKLI görünmemeli.

    Tek ölçüt kayıt dosyasının tazeliği olduğunda ölmek de dosyayı tazeliyordu:
    kameraya bağlanamayıp çıkan bir köprü on beş dakika "ÇALIŞIYOR" diyordu.
    Yanlış yönde yanılan bir gösterge, göstergesizlikten kötüdür.
    """
    bugun = time.strftime("%d.%m")
    ok, cikti = _durum_senaryosu([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] ——— köprü durdu (GIRIS) ———",
    ])
    assert ok is False, cikti
    assert "DURMUŞ" in cikti, cikti


def test_durum_yeniden_baslamis_kopru_saglikli() -> None:
    """Durduktan sonra yeniden başlamışsa son işaret 'başladı'dır — sağlıklı."""
    bugun = time.strftime("%d.%m")
    ok, cikti = _durum_senaryosu([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] ——— köprü durdu (GIRIS) ———",
        f"{bugun} 09:00:11  [i] ——— köprü başladı (GIRIS) — pid 2 ———",
        f"{bugun} 09:05:11  [i] çalışıyor — 900 kare, 3 gönderim",
    ])
    assert ok is True, cikti
    assert "ÇALIŞIYOR" in cikti, cikti


def test_durum_bayat_kayit() -> None:
    """Kalp atışı 5 dk; yazmayı kesmiş dosya ölü köprü demek."""
    ok, cikti = _durum_senaryosu(
        ["01.01 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"],
        yas_sn=3600)
    assert ok is False and "DURMUŞ" in cikti, cikti


def test_durum_gorev_yoksa_saglikli_degil() -> None:
    """Şu an koşuyor olabilir ama açılışta dönmezse otopark yarın sessizce durur."""
    bugun = time.strftime("%d.%m")
    ok, cikti = _durum_senaryosu(
        [f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"],
        gorev=False)
    assert ok is False, cikti
    assert "açılışta başlamaz" in cikti, cikti


def test_durum_sir_sizdirmaz() -> None:
    """Ne kamera şifresi ne webhook anahtarı ekrana düşmeli."""
    bugun = time.strftime("%d.%m")
    _, cikti = _durum_senaryosu([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:01:00  [+] gönderildi -> ok",
        f"{bugun} 09:02:00  [!] reddedildi 409: kapali",
    ])
    assert "hunter2" not in cikti and "cok-gizli-anahtar" not in cikti, cikti
    assert "•••" in cikti, cikti
    assert "1 gönderim, 1 reddedilme" in cikti, cikti


def test_durum_rtsp_gizle() -> None:
    import durum
    assert durum.rtsp_gizle("rtsp://a:b@1.2.3.4:554/x") == "rtsp://a:•••@1.2.3.4:554/x"
    assert durum.rtsp_gizle("rtsp://1.2.3.4:554/x") == "rtsp://1.2.3.4:554/x"
    assert durum.rtsp_gizle("") == ""


def test_bom_lu_ayar_okunur() -> None:
    """
    Not Defteri UTF-8'i BOM ile kaydeder ve düz "utf-8" onu ayrıştıramaz.

    KIRPMA'yı ya da RTSP adresini elle düzeltmek belgelenmiş bir iş: tek bir
    "Kaydet", ayar dosyasını okunamaz yapıyor, köprü sessizce varsayılanlara
    düşüyor ve "WEBHOOK_URL tanımlı olmalı" diye ölüyordu — yani hata mesajı
    insanı asıl sebepten tamamen başka bir yere gönderiyordu.
    """
    with tempfile.TemporaryDirectory() as klasor:
        yol = os.path.join(klasor, "bom.json")
        with open(yol, "w", encoding="utf-8-sig") as f:
            json.dump({"YON": "CIKIS", "KIRPMA": "9,9,9,9"}, f)
        with open(yol, "rb") as f:
            assert f.read(3) == b"\xef\xbb\xbf", "fixture BOM'suz yazıldı"

        kod = ONYUK + "import kopru\nprint(kopru.YON)\nprint(kopru.KIRPMA)\n"
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol}
        for a in ("YON", "KIRPMA", "WEBHOOK_URL"):
            ortam.pop(a, None)
        ortam["OTOPARK_AYAR"] = yol
        r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                           text=True, encoding="utf-8", env=ortam)
        assert r.returncode == 0, r.stderr[-600:]
        assert r.stdout.split() == ["CIKIS", "9,9,9,9"], (r.stdout, r.stderr[-300:])


def test_bozuk_ayar_yaniltici_mesaj_vermez() -> None:
    """
    Okunamayan ayar dosyası varken çıkış mesajı SEBEBİ söylemeli.

    Eskiden "WEBHOOK_URL ve KAMERA_SECRET tanımlı olmalı" diyordu; dosya
    oradaydı, adı doğruydu, içi doluydu — kimse bozuk olduğunu anlamıyordu.
    """
    with tempfile.TemporaryDirectory() as klasor:
        yol = os.path.join(klasor, "bozuk.json")
        with open(yol, "w", encoding="utf-8") as f:
            f.write("{ bu json degil")
        kod = ONYUK + "import kopru\nkopru.main()\n"
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol}
        for a in ("WEBHOOK_URL", "KAMERA_SECRET", "YON"):
            ortam.pop(a, None)
        ortam["OTOPARK_AYAR"] = yol
        r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                           text=True, encoding="utf-8", env=ortam)
        cikti = r.stdout + r.stderr
        assert "Ayar dosyası okunamadı" in cikti, cikti[-600:]
        assert "bozuk.json" in cikti, cikti[-600:]


def test_kayit_kamera_sifresi_sizdirmaz() -> None:
    """
    Kamera şifresi kayıt DOSYASINA yazılmamalı.

    Kayıt dosyası eklenmeden önce `kamera açılamadı: rtsp://admin:SIFRE@…`
    kimsenin bakmadığı bir konsola gidiyordu. Dosyaya yazmaya başlayınca aynı
    satır diskte KALICI hâle geldi — yani görünürlük düzeltmesi, yanında yeni
    bir sızıntı açmıştı. Süzgeç kayıt katmanında, çağrı yerinde değil: sonradan
    eklenen bir `print` de kapsansın.
    """
    import gunluk
    yol = os.path.join(tempfile.mkdtemp(), "s.log")
    t = gunluk._Ikili(None, yol)
    t.write("kamera açılamadı: rtsp://admin:hunter2@10.0.0.9:554/s1\n")
    t.write("ikinci: rtsp://kul:p@ss@10.0.0.9/x\n")   # şifrede '@' — yaygın
    t.flush()
    icerik = open(yol, encoding="utf-8").read()
    assert "hunter2" not in icerik, icerik
    assert "p@ss" not in icerik and "ss@10.0.0.9" not in icerik, icerik
    assert icerik.count("•••") == 2, icerik
    # Host ve yol DURMALI: aşırı gizleme kaydı tanı için işe yaramaz yapar.
    assert "10.0.0.9:554/s1" in icerik, icerik


def test_gizle_sinir_durumlari() -> None:
    import gunluk
    e = [
        ("rtsp://admin:hunter2@10.0.0.9:554/s1", "rtsp://admin:•••@10.0.0.9:554/s1"),
        # Son '@' ayırıyor (RFC 3986); ilkine bakan sürüm "ss"i sızdırıyordu.
        ("rtsp://admin:p@ss@10.0.0.9:554/s1",    "rtsp://admin:•••@10.0.0.9:554/s1"),
        ("rtsp://10.0.0.9:554/stream1",          "rtsp://10.0.0.9:554/stream1"),
        ("rtsp://admin@10.0.0.9/x",              "rtsp://admin@10.0.0.9/x"),
        # Yoldaki '@' yetki bölümünün dışında: kalıp oraya taşmamalı.
        ("rtsp://a:b@h/p@x",                     "rtsp://a:•••@h/p@x"),
        ("adres yok",                            "adres yok"),
    ]
    for giris, beklenen in e:
        assert gunluk.gizle(giris) == beklenen, (giris, gunluk.gizle(giris))


def _kod_metni(ayar: dict) -> str:
    import base64 as b64
    return b64.b64encode(json.dumps(ayar).encode()).decode().rstrip("=")


def _kod_dosyasiyla(ayar: dict, cevaplar: list[str]) -> tuple[dict, str, str]:
    """kurulum-kodu.txt'yi geçici klasöre koyar ve sihirbazın 1. adımını koşar."""
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    klasor = tempfile.mkdtemp()
    yol = os.path.join(klasor, kurulum.KOD_DOSYASI)
    with open(yol, "w", encoding="utf-8") as f:
        f.write(_kod_metni(ayar) + "\n")

    eski_burasi, eski_input = kurulum.BURASI, builtins.input
    sira = list(cevaplar)
    builtins.input = lambda *a: sira.pop(0) if sira else ""
    kurulum.BURASI = klasor
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            cikan = kurulum.sunucu_bilgisi()
        return cikan, yakala.getvalue(), yol
    finally:
        kurulum.BURASI, builtins.input = eski_burasi, eski_input


def test_kod_dosyasindan_okunur() -> None:
    """
    Elle yazılacak en uzun ve en hataya açık şey gizli anahtar. Yanına konmuş
    bir dosya varsa hiç sorulmamalı — 40 karakterin birindeki hata kurulumun
    SONUNDA "gizli anahtar yanlış" olarak çıkıyor ve sebebi görünmüyor.
    """
    ayar = {"WEBHOOK_URL": "https://p.supabase.co/functions/v1/kamera-webhook",
            "KAMERA_SECRET": "a" * 40, "YON": "CIKIS"}
    cikan, cikti, yol = _kod_dosyasiyla(ayar, ["h"])   # h = dosyayı silme
    assert cikan == ayar, cikan
    assert "dosyadan okundu" in cikti, cikti
    assert "CIKIS şeridi" in cikti, cikti
    assert os.path.isfile(yol), "silme reddedildiği hâlde dosya silindi"


def test_kod_dosyasi_onayla_silinir() -> None:
    """Dosya gizli anahtar taşıyor; işi bitince ortalıkta kalmamalı."""
    ayar = {"WEBHOOK_URL": "https://p.supabase.co/functions/v1/kamera-webhook",
            "KAMERA_SECRET": "b" * 40, "YON": "GIRIS"}
    _, cikti, yol = _kod_dosyasiyla(ayar, ["e"])
    assert not os.path.isfile(yol), cikti
    assert "Silindi" in cikti, cikti


def test_eksik_alanli_kod_reddedilir() -> None:
    """
    Alanları eksik bir kod kabul edilmemeli.

    Eskiden sessizce geçiyor ve bağlantı testinde `'WEBHOOK_URL'` diye anlamsız
    bir hataya dönüşüyordu — kullanıcıya kodun bozuk olduğunu söyleyen hiçbir
    şey yoktu.
    """
    import kurulum
    assert kurulum.kodu_coz(_kod_metni({"YON": "GIRIS"})) is None
    assert kurulum.kodu_coz(_kod_metni({"WEBHOOK_URL": "x"})) is None
    assert kurulum.kodu_coz("bu base64 degil!!") is None
    assert kurulum.kodu_coz("") is None
    tam = {"WEBHOOK_URL": "x", "KAMERA_SECRET": "y" * 20, "YON": "CIKIS"}
    assert kurulum.kodu_coz(_kod_metni(tam)) == tam


def _sahte_requests(kod: int, govde):
    """`eslestir` requests'i fonksiyon içinde import ediyor — modülü değiştir."""
    import types

    class Yanit:
        status_code = kod

        def __init__(self):
            self.text = str(govde)

        def json(self):
            if isinstance(govde, Exception):
                raise govde
            return govde

    gonderilen = {}

    def post(adres, json=None, timeout=None):
        gonderilen["adres"] = adres
        gonderilen["govde"] = json
        return Yanit()

    m = types.ModuleType("requests")
    m.post = post
    sys.modules["requests"] = m
    return gonderilen


def test_eslestirme_adresi() -> None:
    """
    Adres türetme düz `replace` OLMAMALI.

    Eski kurulumlarda webhook adresi gizli anahtarı YOL PARÇASI olarak
    taşıyabiliyor (VIGI'nin auth alanı yok). Düz replace o anahtarı yeni
    adrese de taşır ve eşleştirme isteğiyle birlikte sunucu kayıtlarına
    düşürürdü.
    """
    import kurulum
    t = kurulum.eslestirme_adresi
    assert t("https://p.supabase.co/functions/v1/kamera-webhook") == \
        "https://p.supabase.co/functions/v1/kamera-eslestir"
    assert t("https://p.supabase.co/functions/v1/kamera-webhook/GIZLI123/giris") == \
        "https://p.supabase.co/functions/v1/kamera-eslestir"
    # /functions/v1/ hiç yoksa yine de makul bir adres üret.
    assert t("https://p.supabase.co").endswith("/functions/v1/kamera-eslestir")


def test_kodu_coz_yeni_bicim() -> None:
    """Yeni biçim gizli anahtar TAŞIMAZ — yalnızca kısa kod ve adres."""
    import kurulum
    ham = base64.b64encode(json.dumps(
        {"WEBHOOK_URL": "https://p.supabase.co/functions/v1/kamera-webhook",
         "KOD": "7K2M9-4QX3F"}).encode()).decode().rstrip("=")
    v = kurulum.kodu_coz(ham)
    assert v == {"WEBHOOK_URL": "https://p.supabase.co/functions/v1/kamera-webhook",
                 "KOD": "7K2M9-4QX3F"}, v
    assert "KAMERA_SECRET" not in v


def test_eslestir_basarili() -> None:
    """Sunucudan dönen kimlik olduğu gibi ayara geçmeli, cihaz kimliğiyle."""
    import kurulum
    gonderilen = _sahte_requests(200, {
        "webhook_url": "https://p.supabase.co/functions/v1/kamera-webhook",
        "gizli": "a" * 64, "yon": "CIKIS", "cihaz": "11111111-2222-3333-4444-555555555555",
        "ad": "Çıkış bariyeri"})
    try:
        v = kurulum.eslestir("https://p.supabase.co/functions/v1/kamera-webhook",
                             "7K2M9-4QX3F")
    finally:
        sys.modules.pop("requests", None)
    assert v is not None
    assert v["KAMERA_SECRET"] == "a" * 64
    assert v["YON"] == "CIKIS"
    assert v["CIHAZ"] == "11111111-2222-3333-4444-555555555555"
    # Kod eşleştirme adresine gitmeli, webhook'a değil.
    assert gonderilen["adres"].endswith("/kamera-eslestir"), gonderilen["adres"]
    assert gonderilen["govde"] == {"kod": "7K2M9-4QX3F"}


def test_eslestir_serit_tahmin_etmez() -> None:
    """
    Sunucudan anlaşılmaz bir şerit gelirse kurulum DURMALI.

    'GIRIS'e düşmek, çıkış kamerasının giden araçlara bilet açmasıyla biter
    ve bunu kimse fark etmez — otopark sessizce iki kat dolu görünür.
    """
    import kurulum
    for bozuk in ({"webhook_url": "https://p/functions/v1/kamera-webhook", "gizli": "a" * 64, "yon": "SAGA"},
                  {"webhook_url": "https://p/functions/v1/kamera-webhook", "gizli": "a" * 64}):
        _sahte_requests(200, bozuk)
        try:
            v = kurulum.eslestir("https://p/functions/v1/kamera-webhook", "K")
        finally:
            sys.modules.pop("requests", None)
        assert v is None, bozuk


def test_eslestir_eksik_cevap_reddedilir() -> None:
    import kurulum
    for eksik in ({"webhook_url": "https://p/functions/v1/kamera-webhook", "yon": "GIRIS"},
                  {"gizli": "a" * 64, "yon": "GIRIS"}):
        _sahte_requests(200, eksik)
        try:
            v = kurulum.eslestir("https://p/functions/v1/kamera-webhook", "K")
        finally:
            sys.modules.pop("requests", None)
        assert v is None, eksik


def test_eslestir_sunucu_hatasini_gosterir() -> None:
    """Sunucunun Türkçe mesajı kullanıcıya AYNEN görünmeli."""
    import io as _io
    from contextlib import redirect_stdout
    import kurulum
    _sahte_requests(400, {"hata": "Bu kurulum kodu zaten kullanılmış."})
    yakala = _io.StringIO()
    try:
        with redirect_stdout(yakala):
            v = kurulum.eslestir("https://p/functions/v1/kamera-webhook", "K")
    finally:
        sys.modules.pop("requests", None)
    assert v is None
    assert "zaten kullanılmış" in yakala.getvalue(), yakala.getvalue()


def test_koddan_ayar_eski_bicim_eslestirmez() -> None:
    """
    Eski biçim AĞA ÇIKMAMALI.

    İnternetsiz ya da sunucu tarafı henüz hazır olmayan bir kurulumun tek
    yolu o; eşleştirme denemesi orada tamamen gereksiz bir başarısızlık olur.
    """
    import kurulum
    ham = base64.b64encode(json.dumps(
        {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
         "KAMERA_SECRET": "s" * 32, "YON": "CIKIS"}).encode()).decode().rstrip("=")

    def patla(*a, **k):
        raise AssertionError("eski biçimde ağa çıkıldı")

    eski = kurulum.eslestir
    kurulum.eslestir = patla
    try:
        import io as _io
        from contextlib import redirect_stdout
        with redirect_stdout(_io.StringIO()):
            v = kurulum.koddan_ayar(ham)
    finally:
        kurulum.eslestir = eski
    assert v is not None and v["YON"] == "CIKIS" and v["KAMERA_SECRET"] == "s" * 32


# ------------------------------------------------- kimlik reddi (401 / 403) ---

def _kalp_ciktisi(kodlar: list[int]) -> str:
    """Ayrı süreçte kopru.kalp()'i verilen durum kodlarıyla sırayla çağırır."""
    kod = (
        "import sys,types\n"
        "r=types.ModuleType('requests')\n"
        "r.RequestException=Exception\n"
        f"_k={kodlar!r}\n"
        "class Y:\n"
        "    def __init__(self,k):\n"
        "        self.status_code=k\n"
        "        self.text=''\n"
        "r.post=lambda *a,**k: Y(_k.pop(0))\n"
        "sys.modules['requests']=r\n"
        f"sys.path.insert(0, {BURASI!r})\n"
        "import kopru\n"
        f"for _ in range({len(kodlar)}):\n"
        "    kopru.kalp()\n"
    )
    ortam = {**os.environ, "PYTHONIOENCODING": "utf-8"}
    for a in ("WEBHOOK_URL", "KAMERA_SECRET", "RTSP_URL", "YON", "CIHAZ"):
        ortam.pop(a, None)
    ortam["OTOPARK_AYAR"] = os.path.join(tempfile.mkdtemp(), "yok.json")
    r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                       text=True, encoding="utf-8", env=ortam)
    if r.returncode:
        raise AssertionError(f"alt süreç hata verdi:\n{r.stderr[-800:]}")
    return r.stdout


def test_kalp_kimlik_reddini_kaydeder() -> None:
    """
    Kalp atışına 401 dönüyorsa köprü bunu YAZMALI.

    Uygulamadan kaldırılan ya da devre dışı bırakılan bir kameranın köprüsü
    çalışmaya devam ediyor; her kalp atışı reddediliyor ama eskiden hiçbir şey
    kaydedilmiyordu. Kayıt taze kaldığı için `durum` da "ÇALIŞIYOR" diyordu —
    oysa geçen her araç reddediliyordu.
    """
    import durum
    c = _kalp_ciktisi([401])
    assert durum.RED_ISARETI in c, c
    # 400 beklenen cevaptır: tek başına hiçbir şey yazmamalı.
    assert _kalp_ciktisi([400]).strip() == "", _kalp_ciktisi([400])
    # 403 kimlik değil ayar sorunudur ve AYRI söylenmeli.
    c = _kalp_ciktisi([403])
    assert durum.KAPALI_ISARETI in c and durum.RED_ISARETI not in c, c


def test_kalp_duzelince_bildirir() -> None:
    """Ret bittiğinde bunu söyleyen bir satır olmalı; yoksa `durum` takılı kalır."""
    import durum
    c = _kalp_ciktisi([401, 400, 400])
    assert durum.RED_ISARETI in c and durum.KABUL_ISARETI in c, c
    assert c.count(durum.KABUL_ISARETI) == 1, c        # her kalp atışında değil
    assert c.index(durum.RED_ISARETI) < c.index(durum.KABUL_ISARETI), c


def test_durum_kimlik_reddi_saglikli_degil() -> None:
    import durum
    bugun = time.strftime("%d.%m")
    ok, cikti = _durum_senaryosu([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] {durum.RED_ISARETI} (401)",
        f"{bugun} 09:05:01  [i] çalışıyor — 900 kare, 0 gönderim",
    ])
    assert ok is False, cikti
    assert "KİMLİK REDDEDİLDİ" in cikti, cikti


def test_durum_kamera_girisi_kapali_saglikli_degil() -> None:
    import durum
    bugun = time.strftime("%d.%m")
    ok, cikti = _durum_senaryosu([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] {durum.KAPALI_ISARETI} (403)",
    ])
    assert ok is False, cikti
    assert "KAMERA GİRİŞİ KAPALI" in cikti, cikti


def test_durum_ret_bittiyse_saglikli() -> None:
    """Son söz kimdeyse o: ret satırından SONRA kabul ya da gönderim varsa sağlıklı."""
    import durum
    bugun = time.strftime("%d.%m")
    bas = f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"
    red = f"{bugun} 09:00:01  [!] {durum.RED_ISARETI} (401)"
    for sonra in (f"{bugun} 09:05:01  [i] {durum.KABUL_ISARETI}",
                  f"{bugun} 09:05:01  [+] gönderildi -> ok",
                  f"{bugun} 09:05:01  [i] ——— köprü başladı (GIRIS) — pid 2 ———"):
        ok, cikti = _durum_senaryosu([bas, red, sonra])
        assert ok is True, (sonra, cikti)
        assert "ÇALIŞIYOR" in cikti, cikti


# ---------------------------------------------------- şerit tahmin edilmez ---

def test_eski_kod_seridi_tahmin_etmez() -> None:
    """
    Eski biçimli kodda şerit yoksa ya da anlaşılmıyorsa GIRIS'e DÜŞÜLMEZ.

    Çıkış kamerası için hazırlanmış ama YON'u eksik bir kod, eskiden tek
    satırlık bir uyarıyla giriş kamerası olarak kuruluyordu — giden her araca
    bilet açan bir kamera.
    """
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    taban = {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
             "KAMERA_SECRET": "s" * 32}
    for bozuk in (taban, {**taban, "YON": "CIKIŞ"}, {**taban, "YON": ""}):
        v = kurulum.kodu_coz(_kod_metni(bozuk))
        assert v is not None and v["YON"] == "", (bozuk, v)

    # Sihirbaz şeridi SORAR; boş ve anlamsız cevabı kabul etmez.
    eski = builtins.input
    sira = ["", "sağ", "cikis"]
    builtins.input = lambda *a: sira.pop(0)
    try:
        with redirect_stdout(_io.StringIO()):
            v = kurulum.koddan_ayar(_kod_metni(taban))
    finally:
        builtins.input = eski
    assert v is not None and v["YON"] == "CIKIS", v
    assert sira == [], "şerit sorusu geçerli cevabı beklemeden bitti"


# --------------------------------------------------- ayar dosyası izinleri ---

def _ayari_yaz_izle(icacls_basarili: bool):
    """ayari_yaz'ı Windows gibi koşturur; (çağrılar, çıktı, dosya içeriği) döner."""
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    klasor = tempfile.mkdtemp()
    cagrilar: list[tuple[list[str], str]] = []

    def sahte_calistir(komut):
        icerik = ""
        if os.path.isfile(komut[1]):
            with open(komut[1], encoding="utf-8") as f:
                icerik = f.read()
        cagrilar.append((komut, icerik))
        return icacls_basarili, "" if icacls_basarili else "Access is denied."

    eski = (kurulum.calistir, kurulum.WINDOWS, kurulum.AYAR_KLASORU,
            os.environ.get("PROGRAMDATA"))
    kurulum.calistir, kurulum.WINDOWS = sahte_calistir, True
    kurulum.AYAR_KLASORU = os.path.join(klasor, "Otopark")
    os.environ["PROGRAMDATA"] = klasor
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            yol = kurulum.ayari_yaz({"YON": "CIKIS", "KAMERA_SECRET": "GIZLI" * 8,
                                     "WEBHOOK_URL": "https://p"})
        with open(yol, encoding="utf-8") as f:
            return cagrilar, yakala.getvalue(), f.read(), yol
    finally:
        kurulum.calistir, kurulum.WINDOWS, kurulum.AYAR_KLASORU = eski[:3]
        if eski[3] is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski[3]


def test_ayar_dosyasi_once_kisitlanir() -> None:
    """
    Gizli anahtar, izinler DARALTILDIKTAN SONRA yazılmalı.

    ProgramData'da yeni dosya her kullanıcının okuyabildiği izinlerle doğar.
    Önce yazıp sonra kısıtlamak kısa bir pencere bırakır; kısıtlama başarısız
    olursa o pencere hiç kapanmaz.
    """
    cagrilar, _, son, yol = _ayari_yaz_izle(True)
    dosya = [c for c in cagrilar if c[0][1] == yol]
    assert dosya, cagrilar
    komut, o_anki_icerik = dosya[0]
    assert "GIZLI" not in o_anki_icerik, "anahtar izinlerden önce yazılmış"
    assert "GIZLI" in son
    # Grup ADI değil SID: 'Administrators' Windows'un diline göre değişir ve
    # tutmayan bir ad bütün komutu — devralmayı kaldırmayı da — düşürür.
    metin = " ".join(komut)
    assert "*S-1-5-18:(F)" in metin and "*S-1-5-32-544:(F)" in metin, metin
    assert "Administrators" not in metin and "SYSTEM:" not in metin, metin
    assert "/inheritance:r" in komut, komut


def test_ayar_izni_basarisizsa_uyarir() -> None:
    """icacls tutmadıysa bunu SÖYLE: sessiz kalmak, anahtarı açıkta bırakmaktır."""
    _, cikti, son, _ = _ayari_yaz_izle(False)
    assert "kısıtlanamadı" in cikti, cikti
    assert "GIZLI" in son          # kurulum yine de tamamlanabilmeli


# ----------------------------------------------- kayıtlı kimliği yeniden kullan ---

def _mevcut_kimlik(durum_kodu: int | None, cevaplar: list[str],
                   ayar: dict | None = None):
    import builtins
    import io as _io
    import types
    from contextlib import redirect_stdout
    import kurulum

    klasor = tempfile.mkdtemp()
    if ayar is not None:
        with open(os.path.join(klasor, "kopru-cikis.json"), "w", encoding="utf-8") as f:
            json.dump(ayar, f)

    class Yanit:
        status_code = durum_kodu
        text = ""

    def post(*a, **k):
        if durum_kodu is None:
            raise OSError("ağ yok")
        return Yanit()

    m = types.ModuleType("requests")
    m.post = post
    sys.modules["requests"] = m

    eski_klasor, eski_input = kurulum.AYAR_KLASORU, builtins.input
    sira = list(cevaplar)
    builtins.input = lambda *a: sira.pop(0) if sira else ""
    kurulum.AYAR_KLASORU = klasor
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            v = kurulum.mevcut_kimlik_sor()
        return v, yakala.getvalue()
    finally:
        kurulum.AYAR_KLASORU, builtins.input = eski_klasor, eski_input
        sys.modules.pop("requests", None)


_KAYITLI = {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
            "KAMERA_SECRET": "a" * 64, "YON": "CIKIS",
            "CIHAZ": "11111111-2222-3333-4444-555555555555",
            "RTSP_URL": "rtsp://admin:x@10.0.0.9:554/s1", "KIRPMA": "1,2,3,4"}


def test_kayitli_kimlik_yeniden_kullanilir() -> None:
    """
    Yarıda kalmış bir kurulum YENİ KOD istememeli.

    Eşleştirme kodu ilk denemede harcanmıştır; sihirbaz yeniden çalıştırılınca
    eskiden yine kod soruyordu ve tek çıkış yolu uygulamadan kamerayı silip
    yenisini üretmekti. Kimlik diskte duruyor ve hâlâ geçerliyse kullanılır.
    """
    v, cikti = _mevcut_kimlik(400, ["e"], _KAYITLI)
    assert v == _KAYITLI, v                 # RTSP/kırpma da korunur
    assert "CIKIS" in cikti, cikti
    # Anahtar ekrana düşmemeli.
    assert "a" * 16 not in cikti, cikti
    # 403 = kimlik doğru, kamera girişi kapalı. Kimlik yine kullanılabilir.
    v, _ = _mevcut_kimlik(403, ["e"], _KAYITLI)
    assert v == _KAYITLI


def test_kayitli_kimlik_reddedilirse_kullanilmaz() -> None:
    """Sunucunun artık tanımadığı (kaldırılmış) bir kimlik TEKLİF EDİLMEZ."""
    v, cikti = _mevcut_kimlik(401, ["e"], _KAYITLI)
    assert v is None, v
    assert "geçerli değil" in cikti, cikti


def test_kayitli_kimlik_dogrulanamazsa_kullanilmaz() -> None:
    """Sunucuya ulaşılamıyorsa kimliğin geçerli olduğu VARSAYILMAZ."""
    v, cikti = _mevcut_kimlik(None, ["e"], _KAYITLI)
    assert v is None, cikti
    v, _ = _mevcut_kimlik(500, ["e"], _KAYITLI)
    assert v is None


def test_kayitli_kimlik_istenmezse_ya_da_yoksa() -> None:
    v, _ = _mevcut_kimlik(400, ["h"], _KAYITLI)
    assert v is None
    v, cikti = _mevcut_kimlik(400, ["e"], None)
    assert v is None and cikti == "", cikti
    # Yarım / bozuk dosya: şerit ya da anahtar yoksa hiç teklif edilmez.
    for eksik in ({**_KAYITLI, "YON": "SAG"}, {"YON": "CIKIS"},
                  {**_KAYITLI, "KAMERA_SECRET": ""}):
        v, _ = _mevcut_kimlik(400, ["e"], eksik)
        assert v is None, eksik


# ------------------------------------------------------------ yalnızca https ---

def test_eslestirme_duz_http_ile_yapilmaz() -> None:
    """
    Kod ve dönen gizli anahtar düz http üzerinden GİTMEZ.

    Adres yapıştırılan bir dosyadan geliyor; `http://` ile başlayan bir adres
    kodu ve ardından gelen anahtarı ağdaki herkese okuturdu.
    """
    import io as _io
    import types
    from contextlib import redirect_stdout
    import kurulum

    def patla(*a, **k):
        raise AssertionError("düz http adresine istek atıldı")

    m = types.ModuleType("requests")
    m.post = patla
    sys.modules["requests"] = m
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            v = kurulum.eslestir("http://p.supabase.co/functions/v1/kamera-webhook", "K")
    finally:
        sys.modules.pop("requests", None)
    assert v is None
    assert "https" in yakala.getvalue(), yakala.getvalue()

    # Sunucu düz http bir webhook adresi döndürürse o da kabul edilmez.
    _sahte_requests(200, {"webhook_url": "http://p.supabase.co/functions/v1/kamera-webhook",
                          "gizli": "a" * 64, "yon": "GIRIS"})
    try:
        with redirect_stdout(_io.StringIO()):
            v = kurulum.eslestir("https://p.supabase.co/functions/v1/kamera-webhook", "K")
    finally:
        sys.modules.pop("requests", None)
    assert v is None

    # Yerel geliştirme (supabase start) bilerek serbest.
    assert kurulum.guvenli_adres("http://localhost:54321/functions/v1/kamera-webhook")
    assert kurulum.guvenli_adres("http://127.0.0.1:54321/functions/v1/x")
    assert kurulum.guvenli_adres("https://p.supabase.co/functions/v1/x")
    assert not kurulum.guvenli_adres("http://localhost.evil.com/functions/v1/x")
    assert not kurulum.guvenli_adres("ftp://p.supabase.co/x")
    assert not kurulum.guvenli_adres("")


# ---------------------------------------------------- üçüncü inceleme (10-08) ---

def _kopru_calistir(govde: str, env: dict | None = None) -> tuple[int, str]:
    """Ayrı süreçte, sahte `requests` ile kopru'yu içe aktarıp `govde`yi koşar."""
    kod = ONYUK + "import kopru\n" + govde
    ortam = {**os.environ, "PYTHONIOENCODING": "utf-8",
             "PROGRAMDATA": tempfile.mkdtemp()}
    for a in ("WEBHOOK_URL", "KAMERA_SECRET", "RTSP_URL", "YON", "CIHAZ"):
        ortam.pop(a, None)
    ortam["OTOPARK_AYAR"] = os.path.join(tempfile.mkdtemp(), "yok.json")
    ortam.update(env or {})
    try:
        r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                           text=True, encoding="utf-8", env=ortam, timeout=25)
    except subprocess.TimeoutExpired as e:
        raise AssertionError(f"alt süreç 25 sn içinde bitmedi: {e.stdout!r}")
    return r.returncode, r.stdout + r.stderr


def test_kopru_seritsiz_baslamaz() -> None:
    """
    Köprü, şerit verilmeden BAŞLAMAZ. Varsayılan GIRIS idi: ortam değişkeniyle
    elle başlatılan ve YON'u unutulan bir çıkış köprüsü, giden her araca bilet
    açıyordu. Bu projede tahmin edilmeyen tek ayar şerit.
    """
    kod, cikti = _kopru_calistir(
        "kopru.main()\n",
        {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
         "KAMERA_SECRET": "x" * 32, "RTSP_URL": "rtsp://stub/1"})
    assert kod != 0, cikti
    assert "YON" in cikti and "GIRIS" in cikti and "CIKIS" in cikti, cikti


def test_serit_uyusmazligi_kaydedilir() -> None:
    """
    Sunucu "bu kamera öbür şeride eşleştirilmiş" diye reddediyorsa (409 +
    SERIT_UYUSMAZ) köprü bunu AYRI bir satırla yazmalı. Sıradan 409 (aynı
    plakaya ikinci bilet gibi) bir arıza DEĞİL ve işaret üretmemeli.
    """
    import gunluk
    _, cikti = _kopru_calistir(
        "kopru.ret_kaydet(409, '{\"hata\":\"x\",\"kod\":\"SERIT_UYUSMAZ\"}')\n")
    assert gunluk.SERIT_ISARETI in cikti, cikti
    _, cikti = _kopru_calistir("kopru.ret_kaydet(409, '{\"hata\":\"Açık bilet var\"}')\n")
    assert gunluk.SERIT_ISARETI not in cikti, cikti


def test_durum_serit_uyusmazligi_saglikli_degil() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    bas = f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"
    kotu = f"{bugun} 09:00:09  [!] {gunluk.SERIT_ISARETI} (409)"
    ok, cikti = _durum_senaryosu([bas, kotu])
    assert ok is False and "ŞERİT UYUŞMUYOR" in cikti, cikti
    # Sonradan bir gönderim kabul edildiyse geçmiş demektir.
    ok, cikti = _durum_senaryosu([bas, kotu, f"{bugun} 09:01:00  [+] gönderildi -> ok"])
    assert ok is True, cikti


def test_baglanti_denemesi_kalp_atisi_saymaz() -> None:
    """
    Sihirbazın bağlantı testi ve kayıtlı-kimlik yoklaması `x-kamera-deneme`
    başlığını taşır; sunucu o istekte kalp atışı VURMAZ.

    Vursaydı uygulama, kurulum daha ikinci adımdayken kamerayı "Çalışıyor"
    gösterirdi (yönetici telefonu kapatır, kurulum yarıda kalır) ve aynı kod
    ile yeniden eşleştirme penceresi de o anda kapanırdı.
    """
    import types
    import kurulum

    yakalanan = {}

    class Yanit:
        status_code = 400
        text = ""

    def post(adres, json=None, headers=None, timeout=None):
        yakalanan["h"] = headers or {}
        return Yanit()

    m = types.ModuleType("requests")
    m.post = post
    sys.modules["requests"] = m
    try:
        kod, _ = kurulum.webhook_yokla({"WEBHOOK_URL": "https://p", "KAMERA_SECRET": "s" * 64})
    finally:
        sys.modules.pop("requests", None)
    assert kod == 400
    assert yakalanan["h"].get("x-kamera-deneme") == "1", yakalanan
    assert yakalanan["h"].get("x-kamera-secret") == "s" * 64


def test_kayitli_kimlik_varsayilani_hayir() -> None:
    """
    "Bu kimlik kullanılsın mı" sorusunda Enter HAYIR demek.

    İkinci şeridi kurmaya gelen kişi Enter'a basınca ilk şeridin kimliği
    kabul ediliyordu: giriş köprüsü çıkış kamerasına bağlanıyor, yeni kod hiç
    okunmuyordu. Yanlış "evet" yanlış şeride kamera bağlar; yanlış "hayır"
    yalnızca bir soru daha sordurur.
    """
    v, cikti = _mevcut_kimlik(400, [""], _KAYITLI)
    assert v is None, cikti
    # Soru hangi şeridin YENİDEN kurulacağını açıkça söylemeli.
    assert "CIKIS" in cikti and "başka" in cikti.lower(), cikti


def test_yeni_kod_dosyasi_varsa_kayitli_kimlik_sorulmaz() -> None:
    """Yanına yeni bir kurulum-kodu.txt konmuşsa niyet bellidir: YENİ eşleştirme."""
    import builtins
    import io as _io
    import types
    from contextlib import redirect_stdout
    import kurulum

    ayar_klasoru = tempfile.mkdtemp()
    with open(os.path.join(ayar_klasoru, "kopru-giris.json"), "w", encoding="utf-8") as f:
        json.dump({**_KAYITLI, "YON": "GIRIS"}, f)
    kod_klasoru = tempfile.mkdtemp()
    with open(os.path.join(kod_klasoru, kurulum.KOD_DOSYASI), "w", encoding="utf-8") as f:
        f.write("herhangi-bir-kod\n")

    # Yoklama BAŞARILI cevap verir ve soru "e" ile cevaplanır: koruma olmasa
    # kayıtlı kimlik kabul edilirdi. (İstisna atan bir taklit işe yaramaz —
    # webhook_yokla onu "ulaşılamadı" sayar ve test korumasız da geçerdi.)
    cagri: list[str] = []

    class Yanit:
        status_code = 400
        text = ""

    def post(adres, **k):
        cagri.append(adres)
        return Yanit()

    m = types.ModuleType("requests")
    m.post = post
    sys.modules["requests"] = m
    eski = (kurulum.AYAR_KLASORU, kurulum.BURASI, builtins.input)
    kurulum.AYAR_KLASORU, kurulum.BURASI = ayar_klasoru, kod_klasoru
    builtins.input = lambda *a: "e"
    try:
        with redirect_stdout(_io.StringIO()):
            v = kurulum.mevcut_kimlik_sor()
    finally:
        kurulum.AYAR_KLASORU, kurulum.BURASI, builtins.input = eski
        sys.modules.pop("requests", None)
    assert v is None, "yeni kod dosyası varken kayıtlı kimlik kabul edildi"
    assert cagri == [], "yeni kod dosyası varken kayıtlı kimlik yoklandı"


def test_kimlik_erken_yazilirken_eski_ayar_korunur() -> None:
    """
    Eşleştirmeden hemen sonraki ilk yazım, o şeridin ESKİ ayarını silmemeli.

    Dosya yalnızca kimlikle değiştiriliyordu: yeniden eşleştirilen bir şeritte
    sihirbaz kamera adımında bırakılırsa RTSP adresi ve kırpma kutusu gitmiş
    oluyor, köprü de her açılışta "RTSP_URL tanımlı değil" diye çıkıyordu.
    """
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    klasor = tempfile.mkdtemp()
    eski = (kurulum.AYAR_KLASORU, kurulum.WINDOWS, os.environ.get("PROGRAMDATA"))
    kurulum.AYAR_KLASORU, kurulum.WINDOWS = klasor, False
    os.environ["PROGRAMDATA"] = klasor
    try:
        with open(os.path.join(klasor, "kopru-cikis.json"), "w", encoding="utf-8") as f:
            json.dump(_KAYITLI, f)
        yeni = {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
                "KAMERA_SECRET": "b" * 64, "YON": "CIKIS", "CIHAZ": "yeni-cihaz"}
        with redirect_stdout(_io.StringIO()):
            yol = kurulum.kimligi_sakla(yeni)
        with open(yol, encoding="utf-8") as f:
            v = json.load(f)
        assert v["KAMERA_SECRET"] == "b" * 64 and v["CIHAZ"] == "yeni-cihaz", v
        assert v["RTSP_URL"] == _KAYITLI["RTSP_URL"] and v["KIRPMA"] == "1,2,3,4", v
        # Başka şeridin dosyasına dokunulmaz; dosya yoksa yalnızca kimlik yazılır.
        with redirect_stdout(_io.StringIO()):
            yol2 = kurulum.kimligi_sakla({**yeni, "YON": "GIRIS"})
        with open(yol2, encoding="utf-8") as f:
            assert "RTSP_URL" not in json.load(f)
    finally:
        kurulum.AYAR_KLASORU, kurulum.WINDOWS = eski[:2]
        if eski[2] is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski[2]


def test_baslangic_kamera_girisi_kapaliysa_ne_yapilacagini_soyler() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}",
        f"{bugun} 09:00:02  [!] {gunluk.KAPALI_ISARETI} (403)",
    ])
    assert ok is False, cikti
    assert "Otopark Ayarları" in cikti and "kamera girişi" in cikti.lower(), cikti


def test_baslangic_erken_baslamis_kopruyu_kacirmaz() -> None:
    """
    Zaman penceresi GÖREV BAŞLATILMADAN önce açılmalı. Pencere `schtasks /run`
    döndükten sonra açılıyordu: yavaş bir bilgisayarda köprü o sırada çoktan
    "başladı" yazıp kamerayı beklemeye geçmiş oluyor, kayıt pencereden eski
    kalıyor ve sağlıklı bir köprü "başlamadı" diye bildiriliyordu.
    """
    import io as _io
    from contextlib import redirect_stdout
    import gunluk
    import kurulum

    eski = os.environ.get("PROGRAMDATA")
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp()
    try:
        yol = gunluk.kayit_yolu("GIRIS")
        os.makedirs(os.path.dirname(yol), exist_ok=True)
        bugun = time.strftime("%d.%m")
        with open(yol, "w", encoding="utf-8") as f:
            f.write(f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———\n"
                    f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}\n")
        on_sn_once = time.time() - 10
        os.utime(yol, (on_sn_once, on_sn_once))
        with redirect_stdout(_io.StringIO()):
            ok = kurulum.baslangic_dogrula("GIRIS", azami_sn=2, kamera_sn=1,
                                           basladi=time.time() - 12)
        assert ok is True
        with redirect_stdout(_io.StringIO()):
            ok = kurulum.baslangic_dogrula("GIRIS", azami_sn=2, kamera_sn=1)
        assert ok is False, "pencereden eski kayıt bu denemeye sayıldı"
    finally:
        if eski is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski


def test_kirpma_sunucusu_bos_baglantida_takilmaz() -> None:
    """
    Tarayıcılar sayfanın adresine yedek, BOŞ bağlantılar açar. Tek iş
    parçacıklı sunucu onlardan birini okurken takılıyor; saniyede bir gelen
    kare ve hareket istekleri o soket kapanana kadar bekliyordu.
    """
    import socket
    ks, d, sunucu, sonuc, bitti, belirtec = _kirpma_sunucusu()
    port = sunucu.server_address[1]
    bos = socket.create_connection(("127.0.0.1", port))     # hiçbir şey göndermez
    try:
        t = time.monotonic()
        kod, _ = _istek(port, "/olcum")
        assert kod == 200 and time.monotonic() - t < 3, (kod, time.monotonic() - t)
    finally:
        bos.close()
        sunucu.shutdown()
        sunucu.server_close()


# ------------------------------------------------------- görev tanımı (XML) ---

def test_gorev_xml_varsayilanlari_ezer() -> None:
    """
    `schtasks /create` bayraklarıyla kurulan görev Windows varsayılanlarını
    taşır ve ikisi köprüyü SESSİZCE durdurur (bu makinede ölçüldü):

      ExecutionTimeLimit = PT72H   → üç gün sonra "çok uzun koştu" diye sonlanır
      StopIfGoingOnBatteries = true → dizüstünde elektrik kesilince durur

    İkisinde de görev bir sonraki açılışa kadar geri gelmez. Bayraklarla
    değiştirilemedikleri için görev XML'den kurulur.
    """
    import xml.etree.ElementTree as ET
    import kurulum

    x = kurulum.gorev_xml(r"C:\Program Files\Otopark & Co\OtoparkKamera.exe",
                          r'--kopru --ayar "C:\ProgramData\Otopark\kopru-giris.json"')
    kok = ET.fromstring(x)                     # geçerli XML olmalı ('&' kaçışlı)
    ns = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}

    def deger(yol: str) -> str | None:
        e = kok.find(yol, ns)
        return None if e is None else e.text

    assert deger("t:Settings/t:ExecutionTimeLimit") == "PT0S"
    assert deger("t:Settings/t:DisallowStartIfOnBatteries") == "false"
    assert deger("t:Settings/t:StopIfGoingOnBatteries") == "false"
    assert deger("t:Settings/t:MultipleInstancesPolicy") == "IgnoreNew"
    # Köprü ölürse (ya da Windows onu öldürürse) kendiliğinden dönsün.
    assert deger("t:Settings/t:RestartOnFailure/t:Interval") == "PT1M"
    assert int(deger("t:Settings/t:RestartOnFailure/t:Count") or 0) >= 100
    # Açılışta, SYSTEM olarak, en yüksek yetkiyle.
    assert kok.find("t:Triggers/t:BootTrigger", ns) is not None
    assert deger("t:Principals/t:Principal/t:UserId") == "S-1-5-18"
    assert deger("t:Principals/t:Principal/t:RunLevel") == "HighestAvailable"
    # Komut ve argümanlar AYRI alanlarda; yol boşluk ve '&' taşıyabilir.
    assert deger("t:Actions/t:Exec/t:Command") == \
        r"C:\Program Files\Otopark & Co\OtoparkKamera.exe"
    assert "--kopru" in (deger("t:Actions/t:Exec/t:Arguments") or "")


def test_gorev_kur_xml_ile_kurar() -> None:
    """gorev_kur gerçekten /xml yolunu kullanmalı ve geçici dosyayı bırakmamalı."""
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    cagrilar: list[list[str]] = []
    xml_icerik: list[str] = []

    def sahte(komut):
        cagrilar.append(komut)
        if "/xml" in komut:
            yol = komut[komut.index("/xml") + 1]
            with open(yol, encoding="utf-16") as f:
                xml_icerik.append(f.read())
            xml_icerik.append(yol)
        return True, ""

    eski = (kurulum.calistir, kurulum.baslangic_dogrula)
    kurulum.calistir = sahte
    kurulum.baslangic_dogrula = lambda yon, **k: True
    try:
        with redirect_stdout(_io.StringIO()):
            ok = kurulum.gorev_kur(r"C:\ProgramData\Otopark\kopru-cikis.json", "CIKIS")
    finally:
        kurulum.calistir, kurulum.baslangic_dogrula = eski
    assert ok is True
    olustur = [c for c in cagrilar if "/create" in c]
    assert len(olustur) == 1 and "/xml" in olustur[0], cagrilar
    assert "/sc" not in olustur[0], "bayraklı kurulum geri gelmiş"
    assert "PT0S" in xml_icerik[0] and "kopru-cikis.json" in xml_icerik[0]
    assert not os.path.exists(xml_icerik[1]), "geçici görev dosyası silinmedi"


# ------------------------------------------------------ başlangıç doğrulaması ---

def _baslangic(satirlar: list[str]) -> tuple[bool, str]:
    import io as _io
    from contextlib import redirect_stdout
    import gunluk
    import kurulum

    eski = os.environ.get("PROGRAMDATA")
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp()
    try:
        yol = gunluk.kayit_yolu("GIRIS")
        os.makedirs(os.path.dirname(yol), exist_ok=True)
        with open(yol, "w", encoding="utf-8") as f:
            f.write("\n".join(satirlar) + "\n")
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            ok = kurulum.baslangic_dogrula("GIRIS", azami_sn=2, kamera_sn=1)
        return ok, yakala.getvalue()
    finally:
        if eski is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski


def test_baslangic_duran_kopruyu_basari_saymaz() -> None:
    """
    "Köprü başladı" satırı tek başına başarı DEĞİL.

    Eskiden o satır görülünce ✓ yazılıyordu; hemen ardından duran köprü için
    de. Kurulumu yapan kişi "Kurulum tamamlandı" okuyup gidiyordu.
    """
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] YON must be GIRIS or CIKIS",
        f"{bugun} 09:00:01  [!] ——— köprü durdu (GIRIS) ———",
    ])
    assert ok is False, cikti
    assert "✓" not in cikti and "durdu" in cikti, cikti


def test_baslangic_kamera_acilamiyorsa_basari_saymaz() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] {gunluk.KAMERA_YOK_ISARETI}: rtsp://a:•••@1.2.3.4/s — 5 sn sonra",
    ])
    assert ok is False, cikti
    assert "kamera" in cikti.lower() and "✓" not in cikti, cikti


def test_baslangic_sunucu_reddediyorsa_basari_saymaz() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}",
        f"{bugun} 09:00:02  [!] {gunluk.RED_ISARETI} (401)",
    ])
    assert ok is False, cikti
    assert "✓" not in cikti, cikti


def test_baslangic_saglikli() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}",
        f"{bugun} 09:00:02  [i] çalışıyor — 1 kare, 0 gönderim",
    ])
    assert ok is True and "✓" in cikti, cikti


def test_durum_kamera_yoksa_saglikli_degil() -> None:
    """
    Görüntü alamayan köprü kayıt yazmaya devam eder (her denemede bir satır),
    yani dosya TAZE kalır. Tazelik ölçütü onu "ÇALIŞIYOR" gösterirdi.
    """
    import gunluk
    bugun = time.strftime("%d.%m")
    bas = f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"
    for kotu in (f"{bugun} 09:00:05  [!] {gunluk.KAMERA_YOK_ISARETI}: rtsp://x — 5 sn sonra",
                 f"{bugun} 09:00:05  [!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor"):
        ok, cikti = _durum_senaryosu([bas, kotu])
        assert ok is False, cikti
        assert "KAMERA YOK" in cikti, cikti
    # Sonradan görüntü geldiyse sağlıklı.
    for iyi in (f"{bugun} 09:01:00  [i] {gunluk.KAMERA_VAR_ISARETI}",
                f"{bugun} 09:05:00  [i] çalışıyor — 900 kare, 0 gönderim"):
        ok, cikti = _durum_senaryosu(
            [bas, f"{bugun} 09:00:05  [!] {gunluk.KARE_YOK_ISARETI}, yeniden", iyi])
        assert ok is True, cikti


# ------------------------------------------------------------- kırpma sayfası ---

def _kirpma_sunucusu():
    import kirpma_sunucu as ks
    d = ks._Durum()
    sunucu, sonuc, bitti, belirtec = ks.sunucu_baslat(d)
    import threading
    threading.Thread(target=sunucu.serve_forever, daemon=True).start()
    return ks, d, sunucu, sonuc, bitti, belirtec


def _istek(port: int, yol: str, govde: bytes | None = None,
           basliklar: dict | None = None) -> tuple[int, bytes]:
    import urllib.error
    import urllib.request
    r = urllib.request.Request(f"http://127.0.0.1:{port}{yol}", data=govde,
                               headers=basliklar or {},
                               method="POST" if govde is not None else "GET")
    try:
        with urllib.request.urlopen(r, timeout=5) as c:
            return c.status, c.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def test_kirpma_sunucusu_bos_port_ve_belirtec() -> None:
    """
    Kırpma sayfası sabit 8099 portuna bağlanıyordu (doluysa sihirbaz çöküyordu)
    ve /kaydet kimden gelirse gelsin kabul ediliyordu — aynı tarayıcıda açık
    herhangi bir sayfa kırpma kutusunu sessizce değiştirebilirdi.
    """
    ks, d, sunucu, sonuc, bitti, belirtec = _kirpma_sunucusu()
    ks2, d2, sunucu2, *_ = _kirpma_sunucusu()          # ikincisi de açılabilmeli
    try:
        port = sunucu.server_address[1]
        assert port != sunucu2.server_address[1] and port != 0
        assert len(belirtec) >= 32

        # Kare yokken 503: sayfa "bekleniyor" diyebilsin.
        kod, _ = _istek(port, "/kare.jpg")
        assert kod == 503, kod
        # Sayfa belirteci taşır ve bekleme mesajını içerir.
        kod, sayfa = _istek(port, "/")
        assert kod == 200 and belirtec.encode() in sayfa
        assert "görüntü bekleniyor".encode("utf-8") in sayfa

        iyi = json.dumps({"x": 10, "y": 20, "w": 300, "h": 120}).encode()
        # Belirteçsiz ve yanlış belirteçli kayıt REDDEDİLİR, sihirbaz beklemeye devam eder.
        kod, _ = _istek(port, "/kaydet", iyi, {"Content-Type": "application/json"})
        assert kod == 403 and not bitti.is_set(), kod
        kod, _ = _istek(port, "/kaydet", iyi, {"X-Otopark-Belirtec": "x" * 43})
        assert kod == 403 and not bitti.is_set(), kod
        # Başka bir sitenin Origin'i ile gelen istek, belirteç doğru olsa da reddedilir.
        kod, _ = _istek(port, "/kaydet", iyi, {"X-Otopark-Belirtec": belirtec,
                                               "Origin": "http://kotu.example"})
        assert kod == 403 and not bitti.is_set(), kod
        # DNS rebinding: Host başlığı yerel adres değilse hiçbir şey sunulmaz.
        kod, _ = _istek(port, "/kare.jpg", None, {"Host": "kotu.example"})
        assert kod == 403, kod

        # Bozuk gövdeler 400 alır; istisna atıp cevapsız KALMAZ.
        for bozuk in (b"{", b'{"x":1}', b'{"x":-5,"y":0,"w":10,"h":10}',
                      b'{"x":"a","y":0,"w":10,"h":10}', b'{"x":0,"y":0,"w":0,"h":10}',
                      b'[1,2,3,4]', b'{"x":1.5,"y":0,"w":10,"h":10}'):
            kod, _ = _istek(port, "/kaydet", bozuk, {"X-Otopark-Belirtec": belirtec})
            assert kod == 400 and not bitti.is_set(), (bozuk, kod)

        kod, _ = _istek(port, "/kaydet", iyi, {"X-Otopark-Belirtec": belirtec})
        assert kod == 200 and bitti.is_set(), kod
        assert sonuc["kutu"] == (10, 20, 300, 120), sonuc
    finally:
        sunucu.shutdown()
        sunucu2.shutdown()
        sunucu.server_close()
        sunucu2.server_close()


def test_kirpma_tum_kare_secimi() -> None:
    ks, d, sunucu, sonuc, bitti, belirtec = _kirpma_sunucusu()
    try:
        kod, _ = _istek(sunucu.server_address[1], "/kaydet", b"null",
                        {"X-Otopark-Belirtec": belirtec})
        assert kod == 200 and bitti.is_set() and sonuc["kutu"] is None
    finally:
        sunucu.shutdown()
        sunucu.server_close()


def test_esikler_kirpma_uzerinde_olculur() -> None:
    """
    Köprü hareketi KIRPILMIŞ görüntüde ölçer. Sihirbaz tüm karede ölçüyordu:
    kutunun dışındaki hareket eşiklere giriyor, içindeki hareket ise bütün
    kareye yayılıp küçülüyordu — yani eşikler başka bir sinyalden çıkıyordu.
    """
    import types
    import numpy as np
    import kirpma_sunucu as ks

    # Ölçüm kopru'nun yardımcılarını kullanıyor ve kopru `requests` ister;
    # testin konusu o değil, kurulu olmayabilir.
    if "kopru" not in sys.modules:
        try:
            import requests  # noqa: F401
        except ImportError:
            sahte = types.ModuleType("requests")
            sahte.RequestException = Exception
            sahte.post = lambda *a, **k: None
            sys.modules["requests"] = sahte
            try:
                import kopru  # noqa: F401
            finally:
                sys.modules.pop("requests", None)

    kutu = (100, 100, 200, 100)

    def kare(ic: int, dis: int):
        f = np.full((480, 640, 3), dis, np.uint8)
        f[100:200, 100:300] = ic
        return f

    # Hareket yalnızca kutunun DIŞINDA: kırpma serisi sıfır kalmalı.
    d = ks._Durum()
    d.kutu = kutu
    for dis in (10, 200, 10, 200):
        d.olcum_ekle(kare(50, dis))
    assert max(d.kirpik_hareketler) == 0.0, d.kirpik_hareketler
    assert max(d.hareketler) > 50, d.hareketler

    # Hareket yalnızca kutunun İÇİNDE: kırpmada tam şiddetiyle, tüm karede seyrelmiş.
    d = ks._Durum()
    d.kutu = kutu
    for ic in (10, 200, 10, 200):
        d.olcum_ekle(kare(ic, 50))
    assert max(d.kirpik_hareketler) > 150, d.kirpik_hareketler
    assert max(d.hareketler) < max(d.kirpik_hareketler) / 4, d.hareketler

    # Kutu yokken ("tüm kare") kırpma serisi tutulmaz; tüm kare zaten doğru sinyal.
    d = ks._Durum()
    for ic in (10, 200):
        d.olcum_ekle(kare(ic, 50))
    assert d.kirpik_hareketler == [] and len(d.hareketler) == 2

    assert ks.esik_secimi(kutu, [1.0] * 9, [2.0] * 80) == [2.0] * 80
    assert ks.esik_secimi(None, [1.0] * 9, []) == [1.0] * 9


# ----------------------------------------------------------------- port sorusu ---

def test_rtsp_portu_dogrulanir() -> None:
    """`int()` ham girdiye uygulanıyordu: tek yanlış tuş sihirbazı çökertiyordu."""
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    def sor(cevaplar: list[str]) -> int:
        sira = list(cevaplar)
        eski = builtins.input
        builtins.input = lambda *a: sira.pop(0)
        try:
            with redirect_stdout(_io.StringIO()):
                p = kurulum.port_sor()
        finally:
            builtins.input = eski
        assert sira == [], sira
        return p

    assert sor([""]) == 554
    assert sor(["8554"]) == 8554
    assert sor(["abc", "70000", "0", "-1", "554x", " 10554 "]) == 10554


# ---------------------------------------------------------------- kamera arama ---

def test_rtsp_denemesi_zaman_asimi_tasir() -> None:
    """
    Ölçüldü (opencv-python-headless 4.13.0.92): `stimeout` seçeneği denemeyi
    KISALTMIYOR — cevap vermeyen bir adreste her şablon 30 sn bekliyordu, on
    şablon beş dakika. Sınır OpenCV'nin kendi açma zaman aşımıyla konur.
    """
    import kesif

    yakalanan = {}

    class Sahte:
        def __init__(self, *a, **k):
            yakalanan["a"] = a

        def isOpened(self):
            return False

        def release(self):
            pass

    eski = kesif.cv2.VideoCapture
    kesif.cv2.VideoCapture = Sahte
    try:
        ok, _ = kesif._kare_alinabiliyor_mu("rtsp://1.2.3.4/x")
    finally:
        kesif.cv2.VideoCapture = eski
    assert ok is False
    a = yakalanan["a"]
    assert len(a) == 3, "zaman aşımı parametreleri verilmemiş"
    p = list(a[2])
    cv2 = kesif.cv2
    assert cv2.CAP_PROP_OPEN_TIMEOUT_MSEC in p and cv2.CAP_PROP_READ_TIMEOUT_MSEC in p
    acma = p[p.index(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC) + 1]
    assert 2000 <= acma <= 10000, acma
    assert "stimeout" not in kesif._PROBE_SECENEK


def test_port_acik() -> None:
    """Ulaşılamayan kamera on şablon denenmeden, tek soruda anlaşılmalı."""
    import socket
    import kesif

    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    port = s.getsockname()[1]
    try:
        assert kesif.port_acik("127.0.0.1", port, 2.0) is True
    finally:
        s.close()
    assert kesif.port_acik("127.0.0.1", port, 2.0) is False
    assert kesif.port_acik("gecersiz..ad", 554, 1.0) is False


# --------------------------------------------------------------------- kaldırma ---

def _kaldir(sonuclar: dict, ayar: dict | None = None, ad: str = "kopru-cikis.json"):
    """sonuclar: {'/query': bool, '/delete': bool}. (başarı, çıktı, ayar duruyor mu, çağrılar)"""
    import io as _io
    from contextlib import redirect_stdout
    import kaldir

    klasor = tempfile.mkdtemp()
    yol = os.path.join(klasor, ad)
    with open(yol, "w", encoding="utf-8") as f:
        if ayar is None:
            f.write("{bozuk")
        else:
            json.dump(ayar, f)
    cagrilar: list[list[str]] = []

    def sahte(komut):
        cagrilar.append(komut)
        for anahtar, deger in sonuclar.items():
            if anahtar in komut:
                return deger
        return True

    eski = (kaldir.calistir, kaldir.WINDOWS, os.environ.get("PROGRAMDATA"))
    kaldir.calistir, kaldir.WINDOWS = sahte, True
    os.environ["PROGRAMDATA"] = klasor
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            ok = kaldir.serit_kaldir(yol)
        return ok, yakala.getvalue(), os.path.isfile(yol), cagrilar
    finally:
        kaldir.calistir, kaldir.WINDOWS = eski[:2]
        if eski[2] is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski[2]


def test_kaldir_basarisizligi_gizlemez() -> None:
    """
    Görev SİLİNEMEDİYSE "zaten yoktu" denmemeli ve ayar silinmemeli.

    Eskiden her başarısızlık "zaten yoktu" diye yazılıyor, ayar da siliniyordu:
    görev her açılışta ayarsız başlayıp çıkıyor, uygulamadaki kamera da
    "haber yok" uyarısı üretmeye başlıyordu.
    """
    ayar = {"YON": "CIKIS", "KAMERA_SECRET": "x" * 32}
    ok, cikti, duruyor, _ = _kaldir({"/query": True, "/delete": False}, ayar)
    assert ok is False and duruyor, cikti
    assert "KALDIRILAMADI" in cikti and "zaten yoktu" not in cikti, cikti

    ok, cikti, duruyor, _ = _kaldir({"/query": True, "/delete": True}, ayar)
    assert ok is True and not duruyor and "kaldırıldı" in cikti, cikti

    ok, cikti, duruyor, cagrilar = _kaldir({"/query": False}, ayar)
    assert ok is True and not duruyor and "zaten yoktu" in cikti, cikti
    assert not any("/delete" in c for c in cagrilar), cagrilar


def test_kaldir_seridi_dosya_adindan_bulur() -> None:
    """Ayar bozuksa ya da YON taşımıyorsa görev adı dosya adından çıkarılır."""
    for ayar in (None, {"KAMERA_SECRET": "x"}, {"YON": "sağ"}):
        _, _, _, cagrilar = _kaldir({"/query": True, "/delete": True}, ayar)
        adlar = [c[c.index("/tn") + 1] for c in cagrilar if "/tn" in c]
        assert adlar and all(a == "Otopark Kamera Koprusu (CIKIS)" for a in adlar), adlar


if __name__ == "__main__":
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    kotu = 0
    for t in testler:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except Exception as e:
            kotu += 1
            print(f"  FAIL  {t.__name__}: {e}")
    print(f"\n{len(testler) - kotu}/{len(testler)} geçti")
    sys.exit(1 if kotu else 0)
