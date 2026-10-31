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
        # PROGRAMDATA da çevrilir: ayar verilmediğinde kopru varsayılan yola,
        # yani makinenin gerçek %PROGRAMDATA%\Otopark\kopru.json dosyasına bakar.
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "PROGRAMDATA": klasor}
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
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol,
                 "PROGRAMDATA": klasor}
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
    eski_pd = os.environ.get("PROGRAMDATA")
    os.environ["PROGRAMDATA"] = klasor
    onceki = durum.gorev_var_mi
    try:
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

        durum.gorev_var_mi = lambda y: gorev
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            ok = durum.serit_durumu(ayar)
        return ok, yakala.getvalue()
    finally:
        durum.gorev_var_mi = onceki
        # durum.serit_durumu PROGRAMDATA'yı okuyarak koştu; ancak şimdi geri konur.
        if eski_pd is None:
            os.environ.pop("PROGRAMDATA", None)
        else:
            os.environ["PROGRAMDATA"] = eski_pd


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
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol,
                 "PROGRAMDATA": klasor}
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
        ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "OTOPARK_AYAR": yol,
                 "PROGRAMDATA": klasor}
        for a in ("WEBHOOK_URL", "KAMERA_SECRET", "YON"):
            ortam.pop(a, None)
        ortam["OTOPARK_AYAR"] = yol
        r = subprocess.run([sys.executable, "-c", kod], capture_output=True,
                           text=True, encoding="utf-8", env=ortam)
        cikti = r.stdout + r.stderr
        assert "Ayar dosyası okunamadı" in cikti, cikti[-600:]
        assert "bozuk.json" in cikti, cikti[-600:]
        # kopru.main() ilk iş kayıt dosyasını açar (gunluk.baslat). O dosya bu
        # testin KENDİ klasöründe olmalı: PROGRAMDATA devralındığında köprü,
        # testi çalıştıran makinenin gerçek C:\ProgramData\Otopark\kayit
        # klasörüne yazıyordu — her koşuda dört satır.
        kayit = os.path.join(klasor, "Otopark", "kayit", "kopru-kopru.log")
        assert os.path.isfile(kayit), f"kayıt testin klasörüne yazılmadı: {kayit}"
        with open(kayit, encoding="utf-8") as f:
            assert "köprü başladı" in f.read()


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

def _kalp_ciktisi(kodlar: list[int], tarih: str | None = None) -> str:
    """
    Ayrı süreçte kopru.kalp()'i verilen durum kodlarıyla sırayla çağırır.
    `tarih`: cevabın HTTP `Date` başlığı (saat kayması testi için).
    """
    kod = (
        "import sys,types\n"
        "r=types.ModuleType('requests')\n"
        "r.RequestException=Exception\n"
        f"_k={kodlar!r}\n"
        f"_t={tarih!r}\n"
        "class Y:\n"
        "    def __init__(self,k):\n"
        "        self.status_code=k\n"
        "        self.text=''\n"
        "        self.headers={'Date': _t} if _t else {}\n"
        "r.post=lambda *a,**k: Y(_k.pop(0))\n"
        "sys.modules['requests']=r\n"
        f"sys.path.insert(0, {BURASI!r})\n"
        "import kopru\n"
        f"for _ in range({len(kodlar)}):\n"
        "    kopru.kalp()\n"
    )
    gecici = tempfile.mkdtemp()
    ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "PROGRAMDATA": gecici}
    for a in ("WEBHOOK_URL", "KAMERA_SECRET", "RTSP_URL", "YON", "CIHAZ"):
        ortam.pop(a, None)
    ortam["OTOPARK_AYAR"] = os.path.join(gecici, "yok.json")
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
    import gunluk
    c = _kalp_ciktisi([401])
    assert durum.RED_ISARETI in c, c
    # 400 beklenen cevaptır. Yalnızca İLK seferinde bağlantının doğrulandığını
    # bir kez yazar (1.2.1: kurulum sihirbazı bu satırı bekler); başka hiçbir
    # şey yazmaz ve sonraki kalp atışları sessizdir.
    c = _kalp_ciktisi([400, 400])
    assert c.strip().splitlines() == [f"[i] {gunluk.SUNUCU_TAMAM_ISARETI}"], c
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
        kod, _, _ = kurulum.webhook_yokla({"WEBHOOK_URL": "https://p", "KAMERA_SECRET": "s" * 64})
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
                    f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}\n"
                    f"{bugun} 09:00:02  [i] {gunluk.SUNUCU_TAMAM_ISARETI}\n")
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

def _baslangic(satirlar: list[str], gecikme_sn: float = 0) -> tuple[bool, str]:
    import io as _io
    from contextlib import redirect_stdout
    import gunluk
    import kurulum

    eski = os.environ.get("PROGRAMDATA")
    os.environ["PROGRAMDATA"] = tempfile.mkdtemp()
    try:
        yol = gunluk.kayit_yolu("GIRIS")
        os.makedirs(os.path.dirname(yol), exist_ok=True)
        # Pencere kayıt yazılmadan ÖNCE açılır — sihirbazın `schtasks /run`dan
        # önce açtığı gibi. Sonra açılsaydı arada 2 sn'yi aşan bir takılma kaydı
        # bayat gösterirdi.
        basladi = time.time()
        with open(yol, "w", encoding="utf-8") as f:
            f.write("\n".join(satirlar) + "\n")
        if gecikme_sn:
            time.sleep(gecikme_sn)     # makine kayıttan sonra takıldı
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            ok = kurulum.baslangic_dogrula("GIRIS", azami_sn=2, kamera_sn=1,
                                           basladi=basladi)
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
    # 1.2.1: sağlıklı = kamera bağlandı VE sunucu ilk kalp atışını kabul etti.
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}",
        f"{bugun} 09:00:02  [i] çalışıyor — 1 kare, 0 gönderim",
        f"{bugun} 09:00:02  [i] {gunluk.SUNUCU_TAMAM_ISARETI}",
    ])
    assert ok is True and "✓" in cikti, cikti


def test_baslangic_yazim_gecikse_de_saglikli() -> None:
    """
    Kayıt yazıldıktan sonra makine bir an takılsa da (yük, antivirüs taraması)
    sağlıklı köprü sağlıklı görünmeli. `_son_baslangic` pencerenin açılışından
    2 sn'den eski kaydı bayat sayar; yardımcı pencereyi kaydı yazdıktan SONRA
    açıyordu, yani 2 sn'yi aşan bir takılma sağlıklı köprüyü "başlamadı"
    gösteriyordu. Gerçek sihirbazda pencere `schtasks /run`dan önce açılır.
    """
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}",
        f"{bugun} 09:00:02  [i] {gunluk.SUNUCU_TAMAM_ISARETI}",
    ], gecikme_sn=2.5)
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


def test_kirpma_sunucusu_reddederken_govdeyi_okur() -> None:
    """
    Reddedilen /kaydet isteğinin gövdesi ÖNCE okunur, 403 ONDAN SONRA yazılır.

    Sunucu 403'ü gövdeyi okumadan yazıp bağlantıyı kapatıyordu. Windows,
    okunmamış veri bekleyen bir soketi kapatınca bağlantıyı SIFIRLAR (RST);
    gövde başlıklardan biraz sonra geldiyse istemci 403'ü okuyamadan
    "WinError 10053/10054" alıyordu. test_kirpma_sunucusu_bos_port_ve_belirtec
    bu yüzden ara sıra düşüyordu (1.2.1'de de: 15 tekte 2, tam koşuda 2'de 2).

    Yarışı beklemeden sınar: başlıklar gider, gövde GİTMEZ — sunucu henüz
    cevap vermemeli; gövde gidince 403 tam ve temiz gelmeli.
    """
    import socket
    ks, d, sunucu, sonuc, bitti, belirtec = _kirpma_sunucusu()
    port = sunucu.server_address[1]
    govde = json.dumps({"x": 10, "y": 20, "w": 300, "h": 120}).encode()
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        # Belirteç yok: reddedilecek bir istek.
        s.sendall((f"POST /kaydet HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                   f"Content-Type: application/json\r\nContent-Length: {len(govde)}\r\n"
                   "\r\n").encode("ascii"))
        s.settimeout(0.5)
        try:
            erken = s.recv(4096)
        except socket.timeout:
            erken = None
        assert erken is None, f"sunucu gövdeyi okumadan cevap verdi: {erken[:40]!r}"
        s.settimeout(5)
        s.sendall(govde)
        cevap = b""
        while True:
            parca = s.recv(4096)          # sıfırlanan bağlantıda burada patlardı
            if not parca:
                break
            cevap += parca
    finally:
        s.close()
        sunucu.shutdown()
        sunucu.server_close()
    assert cevap.split(b"\r\n", 1)[0].split(b" ")[1:2] == [b"403"], cevap[:80]
    assert not bitti.is_set()


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


# ------------------------------------------------------------ tek kapı (037) ---
#
# ORTAK üçüncü bir şerittir: giriş ve çıkış aynı kapıdan. Kurulumun şeridi
# tanıdığı ALTI yer var ve biri unutulursa sonuç sessizdir — o yüzden her biri
# kendi testini taşıyor.

def test_tek_kapi_eski_bicim_kodda_korunur() -> None:
    """Elle hazırlanmış kodda YON=ORTAK boşaltılıp yeniden SORULMAMALI."""
    import kurulum
    v = kurulum.kodu_coz(_kod_metni(
        {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
         "KAMERA_SECRET": "s" * 32, "YON": "ortak"}))
    assert v is not None and v["YON"] == "ORTAK", v


def test_tek_kapi_serit_sorusunda_secilebilir() -> None:
    """Şerit sorusu ORTAK'ı kabul etmeli ve soruda adını söylemeli."""
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    sorulan: list[str] = []
    eski = builtins.input
    sira = ["ortak"]

    def cevapla(*a):
        sorulan.append(" ".join(str(x) for x in a))
        return sira.pop(0)

    builtins.input = cevapla
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            yon = kurulum.serit_sor()
    finally:
        builtins.input = eski
    assert yon == "ORTAK", yon
    assert "ORTAK" in (" ".join(sorulan) + yakala.getvalue()), sorulan


def test_tek_kapi_eslestirmede_tasinir() -> None:
    """
    Sunucu ORTAK dediyse ayara ORTAK yazılır. Eskiden "şerit anlaşılmadı" diye
    duruyordu — yani tek kapılı bir otoparkta kurulum HİÇ bitmezdi.
    """
    import kurulum
    _sahte_requests(200, {
        "webhook_url": "https://p.supabase.co/functions/v1/kamera-webhook",
        "gizli": "a" * 64, "yon": "ORTAK",
        "cihaz": "11111111-2222-3333-4444-555555555555", "ad": "Tek kapı"})
    try:
        v = kurulum.eslestir("https://p.supabase.co/functions/v1/kamera-webhook",
                             "7K2M9-4QX3F")
    finally:
        sys.modules.pop("requests", None)
    assert v is not None and v["YON"] == "ORTAK", v


def test_tek_kapi_kayitli_kimligi_taninir() -> None:
    """Yarıda kalan tek kapı kurulumunun diskteki kimliği teklif edilmeli."""
    ayar = {**_KAYITLI, "YON": "ORTAK"}
    v, cikti = _mevcut_kimlik(400, ["e"], ayar)
    assert v == ayar, (v, cikti)
    assert "ORTAK" in cikti, cikti


def test_tek_kapi_kaldirirken_dogru_gorev() -> None:
    """
    Görev adı şeride bağlı. ORTAK tanınmasaydı şerit DOSYA ADINDAN okunur,
    var olmayan bir görev "silinir" ve gerçek görev her açılışta ayarsız
    başlamak üzere yerinde kalırdı.
    """
    _, _, _, cagrilar = _kaldir({"/query": True, "/delete": True},
                                {"YON": "ORTAK", "KAMERA_SECRET": "x" * 32})
    adlar = [c[c.index("/tn") + 1] for c in cagrilar if "/tn" in c]
    assert adlar and all(a == "Otopark Kamera Koprusu (ORTAK)" for a in adlar), adlar


def test_tek_kapi_seritler_tek_yerde() -> None:
    """
    Şerit listesi TEK yerde durur (gunluk.SERITLER). Altı ayrı demet,
    dördüncü bir şerit eklendiği gün beşinin güncellenip birinin unutulması
    demektir — bu testin yakaladığı hata tam olarak öyle başladı.
    """
    import re
    import gunluk
    assert gunluk.SERITLER == ("GIRIS", "CIKIS", "ORTAK"), gunluk.SERITLER
    burasi = os.path.dirname(os.path.abspath(__file__))
    for ad in ("kurulum.py", "kaldir.py", "kopru.py", "durum.py", "giris.py"):
        with open(os.path.join(burasi, ad), encoding="utf-8") as f:
            metin = f.read()
        elle = re.findall(r'\(\s*"GIRIS"\s*,\s*"CIKIS"\s*(?:,\s*"ORTAK"\s*)?\)', metin)
        assert not elle, f"{ad}: şerit listesi elle yazılmış: {elle}"


# ------------------------------------------ boş şerit öğrenme (1.2.0) ---

# Ortak hazırlık: 160x120 gri boş şerit ve aynı yerde duran bir "araç".
_BOS_HAZIRLIK = r"""
import numpy as np
bos = np.full((120, 160), 100, np.uint8)
araba = bos.copy(); araba[20:100, 30:130] = 220
def seviye(v):
    return np.full((120, 160), v, np.uint8)
"""


def _bos_kos(govde: str, env: dict | None = None) -> str:
    kod, cikti = _kopru_calistir(_BOS_HAZIRLIK + govde + "\nprint('TAMAM')\n", env)
    assert kod == 0 and "TAMAM" in cikti, cikti
    return cikti


def test_bos_ogrenme_arada_okuma_ister() -> None:
    """
    Bir boş şerit fotoğrafı ancak ikinci bir "araç yok" cevabıyla ve ARADA
    OKUNMUŞ bir araçla referans olur. Arada okuma olmadan iki aynı fotoğraf,
    aynı yerde duran ve okunamayan tek bir aracın iki fotoğrafı da olabilir —
    onu öğrenmek o aracı ve benzerlerini görünmez yapardı.
    """
    _bos_kos(r"""
b = kopru.BosOgrenme(3.0)
assert not b.eslesir(bos)[0]
assert b.arac_yok_geldi(bos) is False          # aday
assert b.arac_yok_geldi(bos.copy()) is False   # arada okuma yok: doğrulanmaz
assert not b.eslesir(bos)[0]
b.okundu()
assert b.arac_yok_geldi(bos.copy()) is True    # şimdi referans
ok, d, kaynak = b.eslesir(bos)
assert ok and d < 3.0 and kaynak.startswith('öğrenilen'), (ok, d, kaynak)
assert not b.eslesir(araba)[0], 'araç boş şeritle eşleşti'
""")


def test_bos_ogrenme_esik_ve_bicim() -> None:
    """Eşiğin altı eşleşir, üstü eşleşmez; boyutu farklı görüntü ASLA eşleşmez.

    kopru.fark() boyut farkında 0.0 döner ("aynı"); hareket için zararsız ama
    burada "boş şerit" demek olurdu — o yüzden eşleştirme kendi kontrolünü yapar.
    """
    _bos_kos(r"""
b = kopru.BosOgrenme(3.0)
b.arac_yok_geldi(bos); b.okundu(); assert b.arac_yok_geldi(bos)
assert b.eslesir(seviye(102))[0]               # fark 2 < 3
assert not b.eslesir(seviye(104))[0]           # fark 4 > 3
assert not b.eslesir(np.full((60, 80), 100, np.uint8))[0], 'farklı boyut eşleşti'
assert not b.eslesir(None)[0]
assert b.arac_yok_geldi(np.full((60, 80), 100, np.uint8)) is False

# Öğrenirken de AYNI eşik: adaydan eşik kadar farklı bir "araç yok" fotoğrafı
# o adayı doğrulamaz (başka bir sahnedir), yeni aday olur.
c = kopru.BosOgrenme(3.0)
c.arac_yok_geldi(seviye(100)); c.okundu()
assert c.arac_yok_geldi(seviye(104)) is False      # fark 4 > 3
assert c.referans_sayisi() == 0
assert c.arac_yok_geldi(seviye(102)) is True       # fark 2 < 3, arada okuma var
""")


def test_bos_ogrenme_kapali_ve_sabit_referans() -> None:
    """BOS_OGREN=0 hiçbir şey öğrenmez; elle verilen BOS_REFERANS yine çalışır."""
    _bos_kos(r"""
b = kopru.BosOgrenme(3.0, ogren=False)
b.arac_yok_geldi(bos); b.okundu()
assert b.arac_yok_geldi(bos) is False
assert not b.eslesir(bos)[0]
s = kopru.BosOgrenme(3.0, sabit=bos, ogren=False)
ok, d, kaynak = s.eslesir(bos)
assert ok and kaynak == 'sabit', (ok, kaynak)
assert not s.eslesir(araba)[0]
""")


def test_bos_ogrenme_sinirlar() -> None:
    """
    En fazla 8 aday, en fazla 6 referans. Yer açmak için EN UZUN SÜREDİR
    eşleşmeyen referans düşer — kullanılan (örn. gece) referansı yeni gelen
    atmasın.
    """
    _bos_kos(r"""
b = kopru.BosOgrenme(3.0)
for v in range(0, 250, 25):                     # 10 farklı aday
    b.arac_yok_geldi(seviye(v))
assert len(b._adaylar) == kopru.BosOgrenme.ADAY_EN_COK == 8, len(b._adaylar)

b = kopru.BosOgrenme(3.0)
seviyeler = [10, 40, 70, 100, 130, 160, 190]
for v in seviyeler[:6]:
    b.arac_yok_geldi(seviye(v)); b.okundu(); assert b.arac_yok_geldi(seviye(v)), v
assert b.referans_sayisi() == 6
assert b.eslesir(seviye(10))[0]                 # ilki yeniden kullanıldı
b.arac_yok_geldi(seviye(190)); b.okundu(); assert b.arac_yok_geldi(seviye(190))
assert b.referans_sayisi() == kopru.BosOgrenme.REFERANS_EN_COK == 6
assert b.eslesir(seviye(10))[0], 'kullanılan referans atıldı'
assert not b.eslesir(seviye(40))[0], 'en eski kullanılmayan referans atılmadı'
assert b.eslesir(seviye(190))[0]
""")


def test_gonder_arac_yok_cevabini_ogrenir() -> None:
    """
    422 + arac_yok: hata değil, boş şerit görüntüsü — "[!] reddedildi" yazılmaz
    (durum onu reddedilme sayardı) ve aday olarak kaydedilir. arac_yok olmayan
    422 eskisi gibi reddedilmedir ve ÖĞRENİLMEZ; bozuk gövde de köprüyü
    düşürmez. 2xx bir okumadır.
    """
    import gunluk
    cikti = _bos_kos(r"""
from datetime import datetime, timezone
import json as _j
class Y:
    def __init__(s, kod, govde): s.status_code = kod; s.text = govde
cevap = []
kopru.requests.post = lambda *a, **k: cevap.pop(0)
kopru._bos = kopru.BosOgrenme(3.0)
simdi = datetime.now(timezone.utc)

cevap.append(Y(422, _j.dumps({'hata': 'Plaka okunamadı.', 'guven': None, 'arac_yok': True})))
assert kopru.gonder('eA==', simdi, bos) is False
assert len(kopru._bos._adaylar) == 1

cevap.append(Y(422, _j.dumps({'hata': 'Plaka okunamadı.', 'guven': 0.4, 'arac_yok': False})))
assert kopru.gonder('eA==', simdi, seviye(200)) is False
cevap.append(Y(422, 'bu json degil'))
assert kopru.gonder('eA==', simdi, seviye(150)) is False
assert len(kopru._bos._adaylar) == 1, 'arac_yok olmayan 422 öğrenildi'

cevap.append(Y(200, '{"ok":true}'))
assert kopru.gonder('eA==', simdi, araba) is True
assert kopru._bos._okunan == 1

cevap.append(Y(422, _j.dumps({'hata': 'x', 'guven': None, 'arac_yok': True})))
assert kopru.gonder('eA==', simdi, bos.copy()) is False
assert kopru._bos.referans_sayisi() == 1

kopru._bos = None                                  # öğrenme nesnesi yokken de çalışmalı
cevap.append(Y(422, _j.dumps({'hata': 'x', 'guven': None, 'arac_yok': True})))
assert kopru.gonder('eA==', simdi, bos) is False
""")
    assert gunluk.BOS_GORUNTU_ISARETI in cikti, cikti
    assert gunluk.BOS_OGRENILDI_ISARETI in cikti, cikti
    assert cikti.count("[!] reddedildi 422") == 2, cikti


# 1.2.3: her araçla birlikte plakanın SIKIŞTIRILMIŞ bir kopyası gider
# (`foto_kanit_base64`); sunucu onu bilete/istisnaya fotoğraf olarak bağlar (042).
# Okuma kopyası (`foto_base64`) değişmez — ağır sıkıştırma okumayı bozardı.
_KANIT_HAZIRLIK = r"""
import base64 as _b64
import cv2, numpy as np
def coz(s):
    b = _b64.b64decode(s, validate=True)
    assert b[:3] == b'\xff\xd8\xff', b[:3]
    assert len(b) <= 102_400, len(b)
    img = cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR)
    assert img is not None
    return img
"""


def _kanit_kos(govde: str) -> str:
    kod, cikti = _kopru_calistir(_KANIT_HAZIRLIK + govde + "\nprint('TAMAM')\n")
    assert kod == 0 and "TAMAM" in cikti, cikti
    return cikti


def test_kanit_fotografi_sinirda() -> None:
    """
    Kanıt kopyası her zaman sunucunun kabul ettiği şeydir: geçerli JPEG,
    en fazla 100 KB, uzun kenarı en fazla 1280, en-boy oranı korunur. Gürültü
    gibi sıkışmayan bir görüntü de kalite/boyut düşürülerek sığdırılır. Aynı
    kırpık okuma kopyasını da beslediği için girdi DEĞİŞTİRİLMEZ.
    """
    _kanit_kos(r"""
rng = np.random.default_rng(7)
kirpik = rng.integers(0, 255, (220, 600, 3), dtype=np.uint8)
kirpik[60:160, 100:500] = 235
once = kirpik.copy()
img = coz(kopru.kanit_base64(kirpik))
assert img.shape[:2] == (220, 600), img.shape
assert np.array_equal(kirpik, once), 'girdi değişti'

buyuk = np.full((1520, 2688, 3), 90, np.uint8)
img = coz(kopru.kanit_base64(buyuk))
assert max(img.shape[:2]) == 1280, img.shape
assert abs(img.shape[1] / img.shape[0] - 2688 / 1520) < 0.01, img.shape

gurultu = rng.integers(0, 255, (900, 1568, 3), dtype=np.uint8)
ilk = cv2.imencode('.jpg', kopru.olcekle(gurultu), [int(cv2.IMWRITE_JPEG_QUALITY), 80])[1]
assert len(ilk) > 102_400, 'gürültü sınırı aşmıyor — test kademeyi sınamıyor'
coz(kopru.kanit_base64(gurultu))
assert kopru.KANIT_EN_COK_BAYT == 102_400
""")


def test_kanit_fotografi_sigmazsa_yok() -> None:
    """
    Sığmayan ya da kodlanamayan fotoğraf None'dır, ASLA istisna değil:
    fotoğraf yüzünden araç kaybedilmez, yalnızca fotoğrafsız gider.
    """
    _kanit_kos(r"""
img = np.full((220, 600, 3), 120, np.uint8)
kopru.KANIT_EN_COK_BAYT = 50
assert kopru.kanit_base64(img) is None
kopru.KANIT_EN_COK_BAYT = 102_400
gercek = kopru.cv2.imencode
kopru.cv2.imencode = lambda *a, **k: (False, None)
assert kopru.kanit_base64(img) is None
def patla(*a, **k): raise RuntimeError('kodlayıcı yok')
kopru.cv2.imencode = patla
assert kopru.kanit_base64(img) is None
kopru.cv2.imencode = gercek
assert kopru.kanit_base64(None) is None
assert kopru.kanit_base64(img) is not None
""")


def test_kanit_siniri_sunucuyla_ayni() -> None:
    """
    Köprü sınırı sunucunun sınırıyla AYNI sayı olmalı: köprü daha büyüğüne izin
    verirse sunucu fotoğrafı sessizce atar (kanitFotoCoz), personel hiç görmez.
    """
    import re
    yol = os.path.join(BURASI, "..", "..", "supabase", "functions", "_shared", "serit.ts")
    with open(yol, encoding="utf-8") as f:
        m = re.search(r"export const KANIT_FOTO_EN_COK_BAYT = ([\d_]+)", f.read())
    assert m, "serit.ts içinde KANIT_FOTO_EN_COK_BAYT bulunamadı"
    sunucu = int(m.group(1).replace("_", ""))
    deger = kopru_degeri(["KANIT_EN_COK_BAYT"], None)
    assert deger == [str(sunucu)], (deger, sunucu)


def test_gonder_kanit_alani() -> None:
    """
    Kanıt kopyası verilirse HER denemede aynısı gider (gövde bir kez kurulur);
    verilmezse alan hiç gönderilmez. Okuma kopyası her durumda aynı kalır.
    """
    _kanit_kos(r"""
from datetime import datetime, timezone
class Y:
    def __init__(s, kod): s.status_code = kod; s.text = '{"ok":true}'
cevap, giden = [], []
def post(*a, json=None, **k):
    giden.append(dict(json)); return cevap.pop(0)
kopru.requests.post = post
kopru.time.sleep = lambda s: None
simdi = datetime.now(timezone.utc)

cevap.extend([Y(503), Y(500), Y(200)])
assert kopru.gonder('b2t1bWE=', simdi, None, 'a2FuaXQ=') is True
assert len(giden) == 3, giden
assert all(g.get('foto_kanit_base64') == 'a2FuaXQ=' for g in giden), giden
assert all(g['foto_base64'] == 'b2t1bWE=' for g in giden), giden
assert len({g['islem_id'] for g in giden}) == 1

giden.clear(); cevap.append(Y(200))
assert kopru.gonder('b2t1bWE=', simdi) is True
assert 'foto_kanit_base64' not in giden[0], giden[0]
giden.clear(); cevap.append(Y(200))
assert kopru.gonder('b2t1bWE=', simdi, None, None) is True
assert 'foto_kanit_base64' not in giden[0], giden[0]
""")


def test_durum_bos_serit_satirlari() -> None:
    """
    Gece boyunca yalnızca atlanan boş şerit satırları olabilir: bu, kameranın
    görüntü verdiğinin kanıtıdır (KAMERA YOK değil). Boş şerit görüntüsü bir
    reddedilme de değildir; özet onları ayrı sayar.
    """
    import durum
    import gunluk
    bugun = time.strftime("%d.%m")
    assert durum.kamera_kopuk([
        f"{bugun} 01:00:00  [!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor",
        f"{bugun} 01:00:09  [i] {gunluk.BOS_ATLANDI_ISARETI} (fark=0.40, ref=öğrenilen-1)",
    ]) is False
    satirlar = [
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:01:00  [+] gönderildi -> ok",
        f"{bugun} 09:02:00  [i] {gunluk.BOS_GORUNTU_ISARETI}",
        f"{bugun} 09:03:00  [i] {gunluk.BOS_ATLANDI_ISARETI} (fark=0.10, ref=öğrenilen-1)",
        f"{bugun} 09:04:00  [i] {gunluk.BOS_ATLANDI_ISARETI} (fark=0.20, ref=öğrenilen-1)",
    ]
    assert durum.bos_ozet(satirlar) == (1, 2), durum.bos_ozet(satirlar)
    ok, cikti = _durum_senaryosu(satirlar)
    assert ok is True, cikti
    assert "1 gönderim, 0 reddedilme" in cikti, cikti
    assert "Boş şerit    : 1 okundu, 2 atlandı" in cikti, cikti


# ------------------------------------------------ 1.2.1: kurulum günü ---

def _kopru_yuklu() -> None:
    """kopru'yu bir kez içe aktarır; `requests` kurulu değilse sahtesiyle."""
    import types
    if "kopru" in sys.modules:
        return
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
        return
    import kopru  # noqa: F401,F811


def test_esik_oner_gece_icin_varsayilanin_altina_inmez() -> None:
    """
    Eşikler yalnızca YUKARI çekilebilir, varsayılanın (2.0 / 6.0) altına inmez.

    Kutu gündüz, altı saniyelik bir örnekle ölçülüyor. O sırada bir araç
    kıpırdarsa öneri DURGUN'u 0.5'e, HAREKET'i ~2'ye indiriyordu. Gece kızıl
    ötesi gürültüsü ikisinin ARASINA düşer: her kare durgun sayacını sıfırlar,
    hiçbir araç "durmaz", hiçbir şey gönderilmez — kalp atışı sürdüğü için de
    sunucu ve `durum` köprüyü sağlıklı gösterir. Her gece bütün girişler
    sessizce kaybolurdu.
    """
    import kirpma_sunucu
    for olcum in ([0.3] * 900 + [14.0] * 100, [0.1] * 950 + [4.0] * 50):
        durgun, hareket = kirpma_sunucu.esik_oner(olcum)
        assert durgun >= 2.0 and hareket >= 6.0, (durgun, hareket)
        assert durgun < hareket, (durgun, hareket)


def test_tum_kare_eski_kirpmayi_temizler() -> None:
    """
    "Tüm kareyi kullan" eski kırpma kutusunu SİLMELİ.

    Kayıtlı kimlikle yeniden kurulumda ayar eski dosyadan gelir ve KIRPMA
    taşır. Tüm kare seçilince yeni kutu yazılmıyordu, yani ekranda "tüm kare
    gönderilecek" denirken eski kutu — artık plakayı içermeyen bir bölge —
    köprüye geri yazılıyordu.
    """
    import io as _io
    from contextlib import redirect_stdout
    import kirpma_sunucu
    import kurulum

    eski = (kirpma_sunucu.kirpma_sec, kirpma_sunucu.esik_oner)
    kirpma_sunucu.kirpma_sec = lambda rtsp: (None, [])
    kirpma_sunucu.esik_oner = lambda olcum: (2.0, 6.0)
    try:
        with redirect_stdout(_io.StringIO()):
            yeni = kurulum.kirpma_ve_esikler("rtsp://x/1")
    finally:
        kirpma_sunucu.kirpma_sec, kirpma_sunucu.esik_oner = eski
    ayar = dict(_KAYITLI)              # KIRPMA "1,2,3,4"
    ayar.update(yeni)
    assert ayar.get("KIRPMA") == "", ayar


def test_kod_dosyasi_en_yenisi_okunur() -> None:
    """
    Tarayıcı ikinci indirmeyi "kurulum-kodu (1).txt" diye kaydeder.

    İlk kodun süresi dolup yenisi indirildiğinde sihirbaz yalnızca tam adı
    arıyordu: ya hiç bulamıyordu ya da yanındaki ESKİ, süresi dolmuş dosyayı
    okuyup "kodun süresi dolmuş" diyordu.
    """
    import kurulum

    def klasor_kur(dosyalar: dict[str, tuple[str, float]]) -> str:
        k = tempfile.mkdtemp()
        for ad, (icerik, yas) in dosyalar.items():
            yol = os.path.join(k, ad)
            with open(yol, "w", encoding="utf-8") as f:
                f.write(icerik)
            os.utime(yol, (time.time() - yas, time.time() - yas))
        return k

    eski = kurulum.BURASI
    try:
        k = klasor_kur({"kurulum-kodu.txt": ("ESKI\n", 600),
                        "kurulum-kodu (1).txt": ("YENI\n", 0)})
        kurulum.BURASI = k
        assert kurulum.dosyadan_kod() == ("YENI", os.path.join(k, "kurulum-kodu (1).txt"))

        k = klasor_kur({"kurulum-kodu (1).txt": ("YALNIZ\n", 0)})
        kurulum.BURASI = k
        assert kurulum.dosyadan_kod() == ("YALNIZ", os.path.join(k, "kurulum-kodu (1).txt"))

        # Boş bir yeni dosya, dolu eskisini gölgelememeli.
        k = klasor_kur({"kurulum-kodu.txt": ("DOLU\n", 600),
                        "kurulum-kodu (1).txt": ("\n", 0)})
        kurulum.BURASI = k
        assert kurulum.dosyadan_kod() == ("DOLU", os.path.join(k, "kurulum-kodu.txt"))

        k = klasor_kur({"baska.txt": ("X\n", 0)})
        kurulum.BURASI = k
        assert kurulum.dosyadan_kod() is None
    finally:
        kurulum.BURASI = eski


def test_gunluk_iki_akis_birlikte_dondurur() -> None:
    """
    Kayıt dosyası, stdout VE stderr açıkken de döndürülmeli.

    İkisi aynı dosyayı AYRI tutamaçlarla açıyordu. Windows'ta Python dosyayı
    silme/yeniden adlandırma paylaşımı olmadan açar; biri döndürmeye kalkınca
    öbürünün açık tutamacı yüzünden yeniden adlandırma başarısız oluyor, hata
    yutuluyor ve dosya sınırsız büyüyordu — üstelik o andan sonra HER satırda
    kapat/aç yapılıyordu. Tek akışlı test bunu göremezdi.
    """
    klasor = tempfile.mkdtemp()
    kod = (
        "import sys\n"
        f"sys.path.insert(0, {BURASI!r})\n"
        "import gunluk\n"
        "gunluk.AZAMI_BOYUT = 400\n"
        "gunluk.baslat('GIRIS')\n"
        "for i in range(60):\n"
        "    print(f'[i] satir {i:03d} ' + 'x' * 20, flush=True)\n"
        "sys.stderr.write('[!] stderr satiri\\n')\n"
        "sys.stderr.flush()\n"
    )
    ortam = {**os.environ, "PYTHONIOENCODING": "utf-8", "PROGRAMDATA": klasor}
    r = subprocess.run([sys.executable, "-c", kod], capture_output=True, text=True,
                       encoding="utf-8", env=ortam)
    assert r.returncode == 0, r.stderr[-800:]
    yol = os.path.join(klasor, "Otopark", "kayit", "kopru-giris.log")
    assert os.path.isfile(yol + ".1"), "kayıt hiç döndürülmedi"
    assert os.path.getsize(yol) < 1000, os.path.getsize(yol)
    hepsi = ""
    for p in (yol + ".2", yol + ".1", yol):
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                hepsi += f.read()
    assert "stderr satiri" in hepsi, "stderr kayda düşmedi"
    assert "satir 059" in hepsi, "son satır kayboldu"


def test_kirpma_sayfasi_tcp_ile_baglanir() -> None:
    """
    Kırpma sayfası kameraya köprüyle AYNI yoldan (RTSP üzerinden TCP) bağlanmalı.

    Kendi VideoCapture'ını kuruyordu; kamera taraması seçeneği geri almış ve
    kopru henüz içe aktarılmamış oluyordu, yani sayfa UDP ile bağlanıyordu.
    Windows Güvenlik Duvarı yeni programın gelen UDP paketlerini engellerse
    sayfa "görüntü bekleniyor"da kalıyordu — tarama ve köprü (ikisi de TCP)
    çalışırken.
    """
    import cv2
    import kirpma_sunucu
    _kopru_yuklu()

    gorulen: list[str | None] = []

    class Sahte:
        def set(self, *a):
            return True

    def yakala(*a, **k):
        gorulen.append(os.environ.get("OPENCV_FFMPEG_CAPTURE_OPTIONS"))
        return Sahte()

    eski_vc = cv2.VideoCapture
    eski_ortam = os.environ.pop("OPENCV_FFMPEG_CAPTURE_OPTIONS", None)
    cv2.VideoCapture = yakala
    try:
        kirpma_sunucu._kamera("rtsp://1.2.3.4/x")
    finally:
        cv2.VideoCapture = eski_vc
        if eski_ortam is None:
            os.environ.pop("OPENCV_FFMPEG_CAPTURE_OPTIONS", None)
        else:
            os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = eski_ortam
    assert gorulen == ["rtsp_transport;tcp"], gorulen


def test_elle_rtsp_adresi_dogrulanir() -> None:
    """
    Elle yazılan RTSP adresi rtsp:// ile başlamalı ve kare vermeli.

    Keşif kamerayı bulamayınca yazılan adres hiç denenmeden kabul ediliyordu.
    Hemen üstteki soru IP istediği için kişi çoğu kez yalnızca IP yazar;
    kırpma sayfası sonsuza dek kare bekliyordu.
    """
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kesif
    import kurulum

    denenen: list[str] = []

    def dene(url):
        denenen.append(url)
        return (True, (2688, 1520)) if url.endswith("/dogru") else (False, None)

    eski = (builtins.input, kesif.dene)
    sira = ["192.168.50.20", "rtsp://admin:Gizli1@1.2.3.4:554/yanlis",
            "rtsp://admin:Gizli1@1.2.3.4:554/dogru"]
    builtins.input = lambda *a: sira.pop(0) if sira else ""
    kesif.dene = dene
    try:
        yakala = _io.StringIO()
        with redirect_stdout(yakala):
            sonuc = kurulum.elle_rtsp_sor()
        builtins.input = lambda *a: ""
        with redirect_stdout(_io.StringIO()):
            bos = kurulum.elle_rtsp_sor()
    finally:
        builtins.input, kesif.dene = eski
    cikti = yakala.getvalue()
    assert sonuc == ("rtsp://admin:Gizli1@1.2.3.4:554/dogru", (2688, 1520)), sonuc
    assert denenen == ["rtsp://admin:Gizli1@1.2.3.4:554/yanlis",
                       "rtsp://admin:Gizli1@1.2.3.4:554/dogru"], denenen
    assert "rtsp://" in cikti, cikti
    assert "Gizli1" not in cikti, "kamera şifresi ekrana yazıldı"
    assert bos is None


def _sahte_rtsp(mod: str, kapat_401: bool = False):
    """
    Küçük bir RTSP sunucusu: DESCRIBE'a kimlik ister, sonra doğrular.

    mod: "digest" | "digest_qop" | "basic" | "meydan_yok" (kimlik istemez) |
         "stale" (ilk kimlikli isteğe "nonce eskidi" der, yeni nonce verir) |
         "yol_meydan" (kökte ve başka yollarda kimlik İSTEMEZ, 404 der; yalnızca
         Dahua akış yolunda ister — 1.2.1'in kök sınamasının göremediği kamera).
    kapat_401: ilk 401'den sonra bağlantıyı kapatır (bazı kameralar böyle).
    Döndürür: (port, sayaç, durdur). sayaç["istekler"]: gelen her isteğin
    (yol, kimlikli mi) çifti, geliş sırasıyla.
    """
    import base64 as _b64
    import hashlib
    import re
    import socket
    import threading

    sifre = "Gizli@Sifre:1"
    realm = "Login to TEST"
    durum = {"nonce": "abc123nonce", "stale_verildi": False}
    sayac: dict = {"yetkili": 0, "istekler": []}
    meydan_yolu = "/cam/realmonitor?channel=1&subtype=0"
    sunucu = socket.socket()
    sunucu.bind(("127.0.0.1", 0))
    sunucu.listen(5)
    sunucu.settimeout(0.2)
    port = sunucu.getsockname()[1]
    dur = threading.Event()

    def md5(s: str) -> str:
        return hashlib.md5(s.encode("utf-8")).hexdigest()

    def dogru_mu(baslik: str) -> bool:
        if baslik.lower().startswith("basic "):
            return _b64.b64decode(baslik[6:]).decode("utf-8") == "admin:" + sifre
        p = dict(re.findall(r'(\w+)="?([^",]*)"?', baslik[7:]))
        nonce = durum["nonce"]
        ha1 = md5(f"{p.get('username')}:{realm}:{sifre}")
        ha2 = md5(f"DESCRIBE:{p.get('uri')}")
        if p.get("qop"):
            beklenen = md5(f"{ha1}:{nonce}:{p.get('nc')}:{p.get('cnonce')}:{p['qop']}:{ha2}")
        else:
            beklenen = md5(f"{ha1}:{nonce}:{ha2}")
        return (p.get("username") == "admin" and p.get("nonce") == nonce
                and p.get("response") == beklenen)

    def cevap(b, cseq: str, kod: int, ek: str = "") -> None:
        ad = {200: "OK", 401: "Unauthorized", 404: "Not Found"}[kod]
        b.sendall(f"RTSP/1.0 {kod} {ad}\r\nCSeq: {cseq}\r\n{ek}\r\n".encode("utf-8"))

    def isle(b) -> None:
        tampon = b""
        with b:
            b.settimeout(3)
            while True:
                try:
                    veri = b.recv(4096)
                except OSError:
                    return
                if not veri:
                    return
                tampon += veri
                while b"\r\n\r\n" in tampon:
                    istek, tampon = tampon.split(b"\r\n\r\n", 1)
                    satirlar = istek.decode("utf-8").split("\r\n")
                    basliklar = {s.split(":", 1)[0].strip().lower(): s.split(":", 1)[1].strip()
                                 for s in satirlar[1:] if ":" in s}
                    cseq = basliklar.get("cseq", "0")
                    yetki = basliklar.get("authorization")
                    # İstek satırı: "DESCRIBE rtsp://127.0.0.1:<port><yol> RTSP/1.0"
                    uri = satirlar[0].split(" ")[1] if " " in satirlar[0] else ""
                    yol = uri.split(f":{port}", 1)[1] if f":{port}" in uri else uri
                    sayac["istekler"].append((yol, bool(yetki)))
                    if mod == "meydan_yok":
                        cevap(b, cseq, 404)
                        continue
                    if mod == "yol_meydan" and yol != meydan_yolu:
                        # Korumasız kök / olmayan yol: kimliğe hiç bakmadan 404.
                        # Kimlikli bir istek buraya gelirse "geçti" sanılır — şifre
                        # yanlış olsa bile; testin yakaladığı hata tam bu.
                        cevap(b, cseq, 404)
                        continue
                    if not yetki:
                        if mod == "basic":
                            ek = f'WWW-Authenticate: Basic realm="{realm}"\r\n'
                        else:
                            qop = ', qop="auth"' if mod == "digest_qop" else ""
                            ek = (f'WWW-Authenticate: Digest realm="{realm}", '
                                  f'nonce="{durum["nonce"]}"{qop}\r\n')
                        cevap(b, cseq, 401, ek)
                        if kapat_401:
                            return
                        continue
                    sayac["yetkili"] += 1
                    if mod == "stale" and not durum["stale_verildi"]:
                        # Şifreye bakmadan: "nonce eskidi, şununla tekrar dene".
                        durum["stale_verildi"] = True
                        durum["nonce"] = "yeni456nonce"
                        cevap(b, cseq, 401, f'WWW-Authenticate: Digest realm="{realm}", '
                                            f'nonce="{durum["nonce"]}", stale=TRUE\r\n')
                        continue
                    # Kimlik doğruysa "/" yolu yok: 404 (yol_meydan'da akış var:
                    # 200). Yanlışsa yine 401.
                    if not dogru_mu(yetki):
                        cevap(b, cseq, 401)
                    else:
                        cevap(b, cseq, 200 if mod == "yol_meydan" else 404)

    def dongu() -> None:
        while not dur.is_set():
            try:
                b, _ = sunucu.accept()
            except OSError:
                continue
            threading.Thread(target=isle, args=(b,), daemon=True).start()
        sunucu.close()

    threading.Thread(target=dongu, daemon=True).start()
    return port, sayac, dur.set


def test_kamera_sifresi_tek_denemeyle_dogrulanir() -> None:
    """
    Şifre, şablon taramasından ÖNCE ve TEK bir kimlikli istekle sınanır.

    Tarama on yolu aynı şifreyle deniyor ve yanlış şifreyle yanlış yolu
    ayırt edemiyordu: tek bir yazım hatası on başarısız giriş demekti. Dahua
    beş, Hikvision yedi yanlıştan sonra hesabı kilitler; doğru şifreyle
    yeniden deneyen kişi de kilit sürerken "şifre yanlış" görüyordu.
    """
    import socket
    import kesif

    for mod in ("digest", "digest_qop", "basic"):
        for kapat in (False, True):
            port, sayac, durdur = _sahte_rtsp(mod, kapat)
            try:
                s = kesif.kimlik_dogrula("127.0.0.1", port, "admin", "Gizli@Sifre:1")
                assert s == "tamam" and sayac["yetkili"] == 1, (mod, kapat, s, sayac)
                sayac["yetkili"] = 0
                s = kesif.kimlik_dogrula("127.0.0.1", port, "admin", "yanlis")
                assert s == "yanlis" and sayac["yetkili"] == 1, (mod, kapat, s, sayac)
            finally:
                durdur()

    # "stale": şifre doğru ama nonce eskimiş. Bu YANLIŞ ŞİFRE DEĞİLDİR —
    # yanlış sayılsaydı doğru şifre reddedilir, kurulum boşuna takılırdı.
    for sifre, beklenen in (("Gizli@Sifre:1", "tamam"), ("yanlis", "yanlis")):
        port, sayac, durdur = _sahte_rtsp("stale")
        try:
            s = kesif.kimlik_dogrula("127.0.0.1", port, "admin", sifre)
            assert s == beklenen and sayac["yetkili"] == 2, (sifre, s, sayac)
        finally:
            durdur()

    # Kimlik istemeyen sunucu: bilinmiyor → bugünkü tarama aynen sürer.
    port, sayac, durdur = _sahte_rtsp("meydan_yok")
    try:
        assert kesif.kimlik_dogrula("127.0.0.1", port, "admin", "x") == "bilinmiyor"
        assert sayac["yetkili"] == 0
    finally:
        durdur()

    # Kapalı port da bilinmiyor; sihirbaz durmaz.
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    bos_port = s.getsockname()[1]
    s.close()
    assert kesif.kimlik_dogrula("127.0.0.1", bos_port, "admin", "x", zaman_asimi=1.0) == "bilinmiyor"


def _kamera_bilgisi(dogrulamalar: list[str], girdiler: list[str],
                    bulunan: list[str] | None = None, sorular: list[str] | None = None):
    """
    kurulum.kamera_bilgisi'ni ağsız koşar. `sorular` verilirse sorulan her
    sorunun metni oraya eklenir; seçilen IP'ler `secilen` olarak döner.
    """
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kesif
    import kurulum

    taranan: list[str] = []
    kalan = list(dogrulamalar)
    sira = list(girdiler)
    secilen: list[str] = []

    def bul(ip, kullanici, sifre, port=554, bildir=None):
        taranan.append(sifre)
        return f"rtsp://{kullanici}:{sifre}@{ip}:{port}/x", "Dahua / Amcrest", (2688, 1520)

    def girdi(soru=""):
        if sorular is not None:
            sorular.append(soru)
        if not sira:
            raise EOFError                      # cevap kalmadı: sonsuz soru döngüsü olmasın
        return sira.pop(0)

    def dogrula(*a, **k):
        return kalan.pop(0)

    # Şifre sınaması iki adla da taklit edilir: kurulum hangisini çağırırsa
    # çağırsın test ağa çıkmaz (1.2.2 öncesi `kimlik_dogrula`, sonrası
    # `kimlik_dogrula_yollar`).
    adlar = ("kameralari_ara", "port_acik", "kimlik_dogrula", "kimlik_dogrula_yollar", "rtsp_bul")
    eski_input = builtins.input
    eski = {ad: getattr(kesif, ad, None) for ad in adlar}
    builtins.input = girdi
    kesif.kameralari_ara = lambda *a, **k: list(bulunan if bulunan is not None else ["10.0.0.5"])
    kesif.port_acik = lambda ip, *a, **k: secilen.append(ip) or True
    kesif.kimlik_dogrula = dogrula
    kesif.kimlik_dogrula_yollar = dogrula
    kesif.rtsp_bul = bul
    yakala = _io.StringIO()
    try:
        with redirect_stdout(yakala):
            try:
                sonuc = kurulum.kamera_bilgisi()
            except SystemExit as e:
                sonuc = ("cikis", str(e.code))
    finally:
        builtins.input = eski_input
        for ad, deger in eski.items():
            if deger is None:
                delattr(kesif, ad)
            else:
                setattr(kesif, ad, deger)
    return sonuc, taranan, yakala.getvalue(), secilen


def test_yanlis_kamera_sifresi_taramayi_baslatmaz() -> None:
    # Girdiler: kamera seçimi, kullanıcı, şifre, port; her yanlıştan sonra
    # kullanıcı (Enter = aynısı) ve şifre yeniden sorulur.
    # Üç FARKLI yanlış: tarama HİÇ başlamaz, kilit uyarısıyla durur.
    sonuc, taranan, cikti, _ = _kamera_bilgisi(
        ["yanlis"] * 3, ["1", "admin", "s1", "554", "", "s2", "", "s3"])
    assert taranan == [], taranan
    assert sonuc[0] == "cikis", sonuc
    assert "kilit" in (sonuc[1] + cikti).lower(), cikti
    # Yanlış, sonra doğru: tarama DOĞRU şifreyle ve bir kez.
    sonuc, taranan, cikti, _ = _kamera_bilgisi(
        ["yanlis", "tamam"], ["1", "admin", "s1", "554", "", "s2"])
    assert taranan == ["s2"], taranan
    assert str(sonuc[0]).startswith("rtsp://"), sonuc
    # Kamera doğrulamaya cevap vermiyorsa bugünkü tarama aynen.
    sonuc, taranan, _, _ = _kamera_bilgisi(["bilinmiyor"], ["1", "admin", "s1", "554"])
    assert taranan == ["s1"], taranan
    # Kontrol kurulumu ASLA tek başına durdurmaz: kişi aynı şifrede ısrar
    # ederse (Enter) tarama o şifreyle sürer. Kontrolün bir kameranın
    # tuhaflığı yüzünden yanılması, doğru şifreyle kurulumu kilitlememeli.
    sonuc, taranan, cikti, _ = _kamera_bilgisi(
        ["yanlis"], ["1", "admin", "s1", "554", "", ""])
    assert taranan == ["s1"], (taranan, cikti)
    assert str(sonuc[0]).startswith("rtsp://"), sonuc


def test_saat_farki() -> None:
    from email.utils import formatdate
    import gunluk

    simdi = time.time()
    f = gunluk.saat_farki(formatdate(simdi - 600, usegmt=True), simdi)
    assert f is not None and abs(f - 600) < 2, f          # bu bilgisayar İLERİ
    f = gunluk.saat_farki(formatdate(simdi + 300, usegmt=True), simdi)
    assert f is not None and abs(f + 300) < 2, f          # bu bilgisayar GERİ
    for bozuk in (None, "", "dün", "Mon, 99 Foo 2026"):
        assert gunluk.saat_farki(bozuk, simdi) is None, bozuk
    assert "10 dakika ileri" in gunluk.saat_farki_metni(600)
    assert "5 dakika geri" in gunluk.saat_farki_metni(-300)


def test_baglanti_testi_saat_farkini_yakalar() -> None:
    """
    Bağlantı testi bu bilgisayarın saatini sunucununkiyle karşılaştırır.

    Köprü her aracın zamanını BU bilgisayarın saatiyle damgalar ve ücret o
    damgadan hesaplanır. Saat beş dakikadan fazla ileriyse her giriş "ileri
    tarihli" kayda düşer, geriyse her araç fazla ücretlendirilir. Sihirbaz bunu
    hiç sınamıyor, kapanışta da yanlış cihazın (kameranın) saatini söylüyordu.
    """
    import io as _io
    import types
    from contextlib import redirect_stdout
    from email.utils import formatdate
    import kurulum

    class Yanit:
        def __init__(self, tarih):
            self.status_code = 400
            self.text = ""
            self.headers = {"Date": tarih} if tarih else {}

    ayar = {"WEBHOOK_URL": "https://x/functions/v1/kamera-webhook", "KAMERA_SECRET": "z" * 32}
    durumlar = (
        (formatdate(time.time() - 600, usegmt=True), False, "ileri"),
        (formatdate(time.time() + 600, usegmt=True), False, "geri"),
        (formatdate(time.time(), usegmt=True), True, None),
        (None, True, None),                       # başlık yoksa sınanamaz, durdurmaz
    )
    try:
        for tarih, beklenen, kelime in durumlar:
            m = types.ModuleType("requests")
            m.post = lambda *a, _t=tarih, **k: Yanit(_t)
            sys.modules["requests"] = m
            yakala = _io.StringIO()
            with redirect_stdout(yakala):
                ok = kurulum.baglanti_testi(ayar)
            cikti = yakala.getvalue()
            assert ok is beklenen, (tarih, cikti)
            if kelime:
                assert kelime in cikti and "saat" in cikti.lower(), cikti
    finally:
        sys.modules.pop("requests", None)


def test_kalp_saat_farkini_yazar() -> None:
    """Köprü de saat kaymasını yazar — saatte en çok bir kez, `durum` görsün."""
    from email.utils import formatdate
    import gunluk
    c = _kalp_ciktisi([400, 400], tarih=formatdate(time.time() - 600, usegmt=True))
    assert c.count(gunluk.SAAT_ISARETI) == 1, c
    assert "ileri" in c, c
    c = _kalp_ciktisi([400], tarih=formatdate(time.time(), usegmt=True))
    assert gunluk.SAAT_ISARETI not in c, c


def test_kalp_sunucu_dogrulandi_bir_kez() -> None:
    """
    Kabul edilen ilk kalp atışı BİR KEZ "sunucu bağlantısı doğrulandı" yazar.

    Kurulum sihirbazı bunu bekler: kamera bağlandıktan iki saniye sonra
    "çalışıyor" deniyordu; ilk kalp atışının cevabı (TLS + soğuk başlangıç)
    daha geç gelirse sunucunun reddi görülmeden kurulum "tamamlandı" oluyordu.
    """
    import gunluk
    c = _kalp_ciktisi([400, 400, 400])
    assert c.count(gunluk.SUNUCU_TAMAM_ISARETI) == 1, c
    c = _kalp_ciktisi([401])
    assert gunluk.SUNUCU_TAMAM_ISARETI not in c, c


def test_baslangic_sunucu_cevabini_bekler() -> None:
    import gunluk
    bugun = time.strftime("%d.%m")
    bas = f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"
    kamera = f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}"
    ok, cikti = _baslangic([bas, kamera, f"{bugun} 09:00:02  [i] çalışıyor — 1 kare, 0 gönderim"])
    assert ok is False and "sunucu" in cikti.lower() and "✓" not in cikti, cikti
    ok, cikti = _baslangic([bas, kamera, f"{bugun} 09:00:03  [!] {gunluk.KALP_YOK_ISARETI}: ağ yok"])
    assert ok is False and "internet" in cikti.lower(), cikti


def _program_klasoru(ad: str, dosyalar: list[str]) -> str:
    klasor = os.path.join(tempfile.mkdtemp(), ad)
    os.makedirs(os.path.join(klasor, "_internal"))
    for d in dosyalar:
        with open(os.path.join(klasor, d), "w", encoding="utf-8"):
            pass
    return klasor


def _kisitla(klasor: str, donmus: bool = True):
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    komutlar: list[list[str]] = []
    eski = (kurulum.calistir, sys.executable, getattr(sys, "frozen", None))
    kurulum.calistir = lambda k: (komutlar.append(k), (True, ""))[1]
    sys.executable = os.path.join(klasor, "OtoparkKamera.exe")
    if donmus:
        sys.frozen = True                          # type: ignore[attr-defined]
    yakala = _io.StringIO()
    try:
        with redirect_stdout(yakala):
            sonuc = kurulum.program_klasorunu_kisitla()
    finally:
        kurulum.calistir, sys.executable = eski[0], eski[1]
        if eski[2] is None:
            if hasattr(sys, "frozen"):
                del sys.frozen                     # type: ignore[attr-defined]
        else:
            sys.frozen = eski[2]                   # type: ignore[attr-defined]
    return sonuc, komutlar, yakala.getvalue()


def test_program_klasoru_yalnizca_kendi_klasorumuzse_kisitlanir() -> None:
    """
    Görev SYSTEM olarak OtoparkKamera.exe'yi çalıştırıyor. Önerilen C:\\Otopark
    C:\\'den "Authenticated Users: Değiştir" devralır: o bilgisayardaki HERHANGİ
    bir hesap .exe'yi ya da _internal'daki bir DLL'i değiştirip bir sonraki
    açılışta SYSTEM olarak çalıştırabilirdi.

    Ama ASLA bizim olmayan bir klasöre dokunulmaz: program Masaüstü'ne ya da
    İndirilenler'e çıkarılmışsa o klasörü kısıtlamak, kişiyi kendi klasörünün
    dışında bırakırdı. Yalnızca adı OtoparkKamera olan ve içinde yalnızca
    paket dosyaları bulunan klasör kısıtlanır.
    """
    k = _program_klasoru("OtoparkKamera", ["OtoparkKamera.exe", "OKU-BENI.txt",
                                           "kurulum-kodu (1).txt", "kare.jpg", "desktop.ini"])
    sonuc, komutlar, cikti = _kisitla(k)
    assert sonuc is True and len(komutlar) == 1, (komutlar, cikti)
    c = komutlar[0]
    assert c[0] == "icacls" and c[1] == k and "/inheritance:r" in c, c
    for hak in ("*S-1-5-18:(OI)(CI)(F)", "*S-1-5-32-544:(OI)(CI)(F)",
                "*S-1-5-32-545:(OI)(CI)(RX)"):
        assert hak in c, (hak, c)

    for ad, dosyalar in (("OtoparkKamera", ["OtoparkKamera.exe", "Belgem.docx"]),
                         ("Masaüstü", ["OtoparkKamera.exe"]),
                         ("Downloads", ["OtoparkKamera.exe", "OKU-BENI.txt"])):
        k = _program_klasoru(ad, dosyalar)
        sonuc, komutlar, cikti = _kisitla(k)
        assert sonuc is False and komutlar == [], (ad, dosyalar, komutlar)
        assert "C:\\Otopark" in cikti, cikti

    # Kaynaktan çalışırken (paketlenmemiş) hiçbir şeye dokunulmaz.
    k = _program_klasoru("OtoparkKamera", ["OtoparkKamera.exe"])
    sonuc, komutlar, _ = _kisitla(k, donmus=False)
    assert sonuc is None and komutlar == [], komutlar


def test_gorev_kur_program_klasorunu_kisitlar() -> None:
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    cagri: list[int] = []
    eski = (kurulum.calistir, kurulum.baslangic_dogrula,
            kurulum.program_klasorunu_kisitla, getattr(sys, "frozen", None))
    kurulum.calistir = lambda k: (True, "")
    kurulum.baslangic_dogrula = lambda yon, **k: True
    kurulum.program_klasorunu_kisitla = lambda: cagri.append(1) or True
    try:
        sys.frozen = True                          # type: ignore[attr-defined]
        with redirect_stdout(_io.StringIO()):
            assert kurulum.gorev_kur(r"C:\ProgramData\Otopark\kopru-giris.json", "GIRIS")
    finally:
        kurulum.calistir, kurulum.baslangic_dogrula, kurulum.program_klasorunu_kisitla = eski[:3]
        if eski[3] is None:
            del sys.frozen                         # type: ignore[attr-defined]
        else:
            sys.frozen = eski[3]                   # type: ignore[attr-defined]
    assert cagri == [1], cagri


# ---------------------------------- 1.2.2: kamera hesabını kilitlememek ---
# Kurulum öncesi check-up (handoff 14): A köprü eski şifreyle durmadan dener,
# B yeniden kurulum o yüzden çıkmaza girer, C şifre sınaması yalnızca kökü
# soruyor, D kamera araması yanlış ağdan çıkıyor.

_DAHUA_YOLU = "/cam/realmonitor?channel=1&subtype=0"


def test_kamera_sifresi_kokte_meydan_yoksa_yolda_sinanir() -> None:
    """
    (C) Kamera kökte (`/`) şifre İSTEMİYORSA şifre akış yollarında sınanır —
    yine TEK kimlikli istekle.

    1.2.1 yalnızca kökü soruyordu. Kökte şifre istemeyen bir kamerada sonuç
    "bilinmiyor" oluyor ve tarama on yolu yazılan şifreyle deniyordu: tek bir
    yazım hatası on başarısız giriş, Dahua beşte kilitler. Her yolun İLK isteği
    şifresiz gider; şifre isteyen ilk yola tek kimlikli istek gider ve cevabı
    kesindir.
    """
    import kesif

    port, sayac, durdur = _sahte_rtsp("yol_meydan")
    try:
        # 1.2.1'in kök sınaması bu kamerada kör — kapatılan açık bu.
        assert kesif.kimlik_dogrula("127.0.0.1", port, "admin", "yanlis") == "bilinmiyor"
        assert sayac["yetkili"] == 0, sayac
        for kapat in (False, True):
            for sifre, beklenen in (("Gizli@Sifre:1", "tamam"), ("yanlis", "yanlis")):
                sayac["yetkili"] = 0
                sayac["istekler"].clear()
                s = kesif.kimlik_dogrula_yollar("127.0.0.1", port, "admin", sifre)
                assert s == beklenen and sayac["yetkili"] == 1, (sifre, s, sayac)
                # Kimlikli istek YALNIZCA şifre isteyen yola, en sonda, bir kez;
                # öncekilerin hepsi şifresiz ve ilk sorulan yer kök.
                ist = sayac["istekler"]
                assert ist[0] == ("/", False) and ist[-1] == (_DAHUA_YOLU, True), ist
                assert all(not y for _, y in ist[:-1]), ist
    finally:
        durdur()

    # Kökte şifre isteyen kamerada davranış 1.2.1 ile aynı: yalnızca kök.
    for mod in ("digest", "basic"):
        port, sayac, durdur = _sahte_rtsp(mod, kapat_401=True)
        try:
            for sifre, beklenen in (("Gizli@Sifre:1", "tamam"), ("yanlis", "yanlis")):
                sayac["yetkili"] = 0
                sayac["istekler"].clear()
                s = kesif.kimlik_dogrula_yollar("127.0.0.1", port, "admin", sifre)
                assert s == beklenen and sayac["yetkili"] == 1, (mod, sifre, s, sayac)
                assert {y for y, _ in sayac["istekler"]} == {"/"}, sayac["istekler"]
        finally:
            durdur()

    # Hiçbir yolda şifre istemeyen kamera: bilinmiyor, SIFIR kimlikli istek.
    port, sayac, durdur = _sahte_rtsp("meydan_yok")
    try:
        assert kesif.kimlik_dogrula_yollar("127.0.0.1", port, "admin", "x") == "bilinmiyor"
        assert sayac["yetkili"] == 0, sayac
        assert len(sayac["istekler"]) == 1 + len(kesif.RTSP_YOLLARI), sayac["istekler"]
    finally:
        durdur()


def test_kurulum_sifreyi_akis_yolunda_sinar() -> None:
    """
    (C) Sihirbaz da yol taramalı sınamayı kullanır: kökte şifre istemeyen
    kamerada yanlış şifre BİR başarısız girişle reddedilir ve soru geri gelir;
    yanlış şifreyle tarama hiç başlamaz.
    """
    import builtins
    import io as _io
    from contextlib import redirect_stdout
    import kesif
    import kurulum

    port, sayac, durdur = _sahte_rtsp("yol_meydan")
    sira = ["", "Gizli@Sifre:1"]          # kullanıcı (Enter = aynı), yeni şifre

    def girdi(*a):
        if not sira:
            raise EOFError
        return sira.pop(0)

    eski = builtins.input
    builtins.input = girdi
    yakala = _io.StringIO()
    try:
        with redirect_stdout(yakala):
            sonuc = kurulum.kamera_kimligi_dogrula(kesif, "127.0.0.1", port, "admin", "yanlis")
    finally:
        builtins.input = eski
        durdur()
    cikti = yakala.getvalue()
    assert sonuc == ("admin", "Gizli@Sifre:1"), (sonuc, cikti)
    assert "kabul etmedi" in cikti, cikti
    assert sayac["yetkili"] == 2, sayac          # bir yanlış + bir doğru


def test_rtsp_adresi_cozulur() -> None:
    """
    (A) Köprü kendi RTSP adresinden kameranın kimliğini geri çıkarır (şifre
    sınaması için). Sihirbaz kullanıcı adını ve şifreyi URL-kodlu yazar;
    '@' ya da ':' içeren bir şifre yanlış çözülürse köprü DOĞRU şifreyi
    "yanlış" sanar ve kendini on dakika bekletir.
    """
    import kesif

    for kullanici, sifre in (("admin", "Gizli@Sifre:1"), ("ad min", "p@ss:w/rd%1?#")):
        url = kesif.rtsp_adresi("10.0.0.5", kullanici, sifre, _DAHUA_YOLU)
        assert kesif.rtsp_parcala(url) == ("10.0.0.5", 554, kullanici, sifre, _DAHUA_YOLU), url
    assert kesif.rtsp_parcala("rtsp://admin:x@192.168.50.20:8554/stream1") == \
        ("192.168.50.20", 8554, "admin", "x", "/stream1")
    assert kesif.rtsp_parcala("rtsp://admin:x@10.0.0.5") == ("10.0.0.5", 554, "admin", "x", "/")
    # Kimliksiz ya da anlaşılmaz adres: sınanacak kimlik yok → None. Kimliksiz
    # bir DESCRIBE'a boş kimlikle cevap vermek kendi başına başarısız giriş olurdu.
    for adres in ("rtsp://10.0.0.5:554/x", "rtsp://stub/1", "rtsp://:x@10.0.0.5/",
                  r"C:\video.mp4", "http://a:b@10.0.0.5/x", "",
                  "rtsp://a:b@10.0.0.5:99999/x"):
        assert kesif.rtsp_parcala(adres) is None, adres


def test_kopru_sifreyi_kendi_akis_yolunda_sinar() -> None:
    """
    (A) Köprünün şifre sınaması KENDİ adresinin yolunda ve çözülmüş kimlikle
    yapılır; kimliksiz adreste hiç yapılmaz; sınama patlarsa köprü ölmez
    ("bilinmiyor" = bugünkü gibi bağlanmayı dene).
    """
    _kopru_yuklu()
    import kesif
    import kopru

    cagri: list = []
    eski = kesif.kimlik_dogrula

    def sahte(*a, **k):
        cagri.append((a, k))
        return "yanlis"

    kesif.kimlik_dogrula = sahte
    try:
        url = kesif.rtsp_adresi("10.0.0.5", "admin", "Gizli@Sifre:1", _DAHUA_YOLU)
        assert kopru.kamera_sifresi_kontrol(url) == "yanlis"
        assert cagri == [(("10.0.0.5", 554, "admin", "Gizli@Sifre:1"),
                          {"yol": _DAHUA_YOLU})], cagri
        cagri.clear()
        assert kopru.kamera_sifresi_kontrol("rtsp://10.0.0.5:554/x") == "bilinmiyor"
        assert cagri == [], cagri

        def patla(*a, **k):
            raise OSError("ağ yok")

        kesif.kimlik_dogrula = patla
        assert kopru.kamera_sifresi_kontrol(url) == "bilinmiyor"
    finally:
        kesif.kimlik_dogrula = eski


def test_durum_kamera_sifresi_reddedildi() -> None:
    """
    (A) Köprü kameranın şifreyi reddettiğini yazdıysa `durum` bunu AYRICA ve ne
    yapılacağıyla söyler. "KAMERA YOK — fişi kontrol edin" kişiyi yanlış yere
    gönderirdi; doğrusu programı açıp 'Yeniden kur' demek.
    """
    import gunluk
    bugun = time.strftime("%d.%m")
    bas = f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———"
    var = f"{bugun} 09:00:01  [i] {gunluk.KAMERA_VAR_ISARETI}"
    kopma = f"{bugun} 09:30:00  [!] {gunluk.KARE_YOK_ISARETI}, yeniden bağlanılıyor"
    red = f"{bugun} 09:30:03  [!] {gunluk.SIFRE_RED_ISARETI} — 10 dakika sonra yeniden denenecek"
    ok, cikti = _durum_senaryosu([bas, var, kopma, red])
    assert ok is False, cikti
    assert "KAMERA ŞİFRESİ REDDEDİLDİ" in cikti and "Yeniden kur" in cikti, cikti
    assert "KAMERA YOK" not in cikti, cikti
    # Sonradan kamera döndüyse geçmiş demektir.
    ok, cikti = _durum_senaryosu(
        [bas, red, f"{bugun} 09:40:04  [i] {gunluk.KAMERA_VAR_ISARETI} (yeniden)"])
    assert ok is True, cikti
    # Şifre reddi olmayan kopma hâlâ KAMERA YOK.
    ok, cikti = _durum_senaryosu([bas, var, kopma])
    assert ok is False and "KAMERA YOK" in cikti and "ŞİFRESİ" not in cikti, cikti


def test_baslangic_kamera_sifresi_reddedildi() -> None:
    """(A) Sihirbazın son adımı da aynı cümleyi söyler ve başarı saymaz."""
    import gunluk
    bugun = time.strftime("%d.%m")
    ok, cikti = _baslangic([
        f"{bugun} 09:00:00  [i] ——— köprü başladı (GIRIS) — pid 1 ———",
        f"{bugun} 09:00:01  [!] {gunluk.SIFRE_RED_ISARETI} — 10 dakika sonra yeniden denenecek",
    ])
    assert ok is False and "✓" not in cikti, cikti
    assert "ŞİFRESİ REDDEDİLDİ" in cikti and "Yeniden kur" in cikti, cikti


def _main_eski_kopru(kamera: BaseException | None = None, olustur_ok: bool = True,
                     gorev_var: bool = True):
    """
    kurulum.main()'i ağsız ve görev kurmadan koşar (ORTAK şeridi). schtasks
    komutları ve kamera adımı ("KAMERA") geliş sırasıyla kaydedilir.
    """
    import io as _io
    from contextlib import redirect_stdout
    import kurulum

    olaylar: list = []

    def sahte_calistir(komut):
        olaylar.append(tuple(komut))
        if komut[:2] == ["schtasks", "/query"]:
            return gorev_var, ""
        if komut[:2] == ["schtasks", "/create"]:
            return olustur_ok, "" if olustur_ok else "Erişim engellendi."
        return True, ""

    def kamera_adimi():
        olaylar.append("KAMERA")
        if kamera is not None:
            raise kamera
        return "rtsp://admin:x@10.0.0.5:554/x", (2688, 1520)

    taklit = dict(
        WINDOWS=True,
        bagimliliklar_tamam=lambda: True,
        yonetici_mi=lambda: True,
        mevcut_kimlik_sor=lambda: {"WEBHOOK_URL": "https://p/functions/v1/kamera-webhook",
                                   "KAMERA_SECRET": "x" * 64, "YON": "ORTAK"},
        kimligi_sakla=lambda a: "",
        baglanti_testi=lambda a: True,
        kamera_bilgisi=kamera_adimi,
        kirpma_ve_esikler=lambda r: {"KIRPMA": ""},
        ayari_yaz=lambda a: r"C:\ProgramData\Otopark\kopru-ortak.json",
        guc_ayarlari=lambda: None,
        program_klasorunu_kisitla=lambda: None,
        baslangic_dogrula=lambda yon, **k: True,
        calistir=sahte_calistir,
    )
    eski = {ad: getattr(kurulum, ad) for ad in taklit}
    for ad, deger in taklit.items():
        setattr(kurulum, ad, deger)
    yakala = _io.StringIO()
    try:
        with redirect_stdout(yakala):
            try:
                sonuc = kurulum.main()
            except (SystemExit, KeyboardInterrupt) as e:
                sonuc = type(e).__name__
    finally:
        for ad, deger in eski.items():
            setattr(kurulum, ad, deger)
    return sonuc, olaylar, yakala.getvalue()


def test_yeniden_kurulum_eski_kopruyu_duraklatir() -> None:
    """
    (B) Sihirbaz yeniden çalıştırılınca o şeridin ESKİ köprüsü kamera adımından
    ÖNCE durdurulur; kurulum yeni görevi kurmadan biterse eskisi yeniden
    başlatılır.

    Eski köprü ancak 5. adımda duruyordu. Kameranın şifresi değiştiği için
    sihirbaz açıldıysa, eski köprü 2.-3. adımlar boyunca eski şifreyle girişi
    deniyor ve kamerayı kilitli tutuyordu: sihirbazın şifre sınaması üç kez
    reddediliyor, "30 dakika bekleyin" deniyor, beklemek de işe yaramıyordu —
    schtasks bilmeden çıkışı yoktu. Öte yandan yarıda kalan bir kurulum, şeridi
    karanlıkta bırakmamalı. Başka şeritlere hiç dokunulmaz.
    """
    ad = "Otopark Kamera Koprusu (ORTAK)"
    durdur = ("schtasks", "/end", "/tn", ad)
    baslat = ("schtasks", "/run", "/tn", ad)

    def komut_turu(olaylar, tur):
        return [i for i, o in enumerate(olaylar) if o != "KAMERA" and o[1] == tur]

    def baska_serit(olaylar):
        return [o for o in olaylar if o != "KAMERA" and "/tn" in o
                and o[o.index("/tn") + 1] != ad]

    # Başarılı yeniden kurulum: eski köprü kamera adımından önce durur; sonda
    # yalnızca YENİ görev başlatılır — bir kez, oluşturulduktan sonra.
    sonuc, olaylar, cikti = _main_eski_kopru()
    assert sonuc == 0, cikti
    assert durdur in olaylar[:olaylar.index("KAMERA")], olaylar
    calis = komut_turu(olaylar, "/run")
    assert len(calis) == 1 and calis[0] > komut_turu(olaylar, "/create")[0], olaylar
    assert not baska_serit(olaylar), olaylar

    # Kamera adımında bırakıldı (sys.exit) ya da Ctrl+C: yeni görev yok →
    # eski köprü yeniden başlar.
    for hata in (SystemExit("  Kurulum durduruldu."), KeyboardInterrupt()):
        sonuc, olaylar, cikti = _main_eski_kopru(kamera=hata)
        assert sonuc == type(hata).__name__, (sonuc, cikti)
        assert durdur in olaylar[:olaylar.index("KAMERA")], olaylar
        assert not komut_turu(olaylar, "/create"), olaylar
        assert olaylar[-1] == baslat, olaylar
        assert not baska_serit(olaylar), olaylar

    # Görev oluşturulamadı: eski tanım yerinde → eski köprü yeniden başlar.
    sonuc, olaylar, cikti = _main_eski_kopru(olustur_ok=False)
    assert sonuc == 1, cikti
    assert olaylar[-1] == baslat and len(komut_turu(olaylar, "/run")) == 1, olaylar
    assert komut_turu(olaylar, "/run")[0] > komut_turu(olaylar, "/create")[0], olaylar

    # İlk kurulum (görev yok): hiçbir şey durdurulmaz ya da başlatılmaz.
    sonuc, olaylar, _ = _main_eski_kopru(kamera=SystemExit("x"), gorev_var=False)
    assert durdur not in olaylar and baslat not in olaylar, olaylar


def test_kamera_aramasi_her_agdan_gider() -> None:
    """
    (D) Kamera araması bilgisayarın HER ağından ayrı ayrı gönderilir.

    Tek gönderimde ağı Windows rota ölçüsüne göre seçiyordu: kamera 100 Mbps
    kabloda, internet Wi-Fi'de olunca arama Wi-Fi'den çıkıp kameraya hiç
    ulaşmıyordu. Bir ağın hata vermesi ötekileri durdurmamalı; hiç ağ
    bulunamazsa (ya da hiçbirinden gidemezse) bugünkü tek gönderime düşülür.
    """
    import socket
    import kesif

    if not hasattr(kesif, "_udp_soketi") or not hasattr(kesif, "yerel_ipv4"):
        raise AssertionError("kesif._udp_soketi / yerel_ipv4 yok — arama ağ başına "
                             "gönderilmiyor (test gerçek ağa çıkmasın diye durdu)")

    class SahteSoket:
        def __init__(self, bozuk: set[str], cevap_veren: dict[str, str]):
            self.olaylar: list[tuple] = []
            self.arayuz: str | None = None
            self.bozuk, self.cevap_veren = bozuk, cevap_veren
            self.gelen: list[tuple[str, int]] = []

        def setsockopt(self, seviye, ad, deger):
            if seviye == socket.IPPROTO_IP and ad == socket.IP_MULTICAST_IF:
                self.arayuz = socket.inet_ntoa(deger)
                self.olaylar.append(("arayuz", self.arayuz))

        def settimeout(self, t):
            pass

        def sendto(self, veri, adres):
            if self.arayuz in self.bozuk:
                raise OSError("Ağa ulaşılamıyor")
            self.olaylar.append(("gonder", self.arayuz, adres))
            if self.arayuz in self.cevap_veren:
                self.gelen.append((self.cevap_veren[self.arayuz], 3702))

        def recvfrom(self, n):
            if self.gelen:
                return b"<cevap/>", self.gelen.pop(0)
            time.sleep(0.02)
            raise socket.timeout()

        def close(self):
            pass

    grup = ("239.255.255.250", 3702)
    eski = (kesif._udp_soketi, kesif.yerel_ipv4)
    try:
        # Üç ağ: biri hata veriyor, ikisinden gidiyor; kamera kablodaki ağda.
        s = SahteSoket({"192.168.1.10"}, {"10.77.0.10": "10.77.0.20"})
        kesif._udp_soketi = lambda: s
        kesif.yerel_ipv4 = lambda: ["192.168.1.10", "10.77.0.10", "172.20.0.1"]
        assert kesif.kameralari_ara(saniye=0.3) == ["10.77.0.20"], s.olaylar
        gonderim = [o for o in s.olaylar if o[0] == "gonder"]
        assert gonderim == [("gonder", "10.77.0.10", grup), ("gonder", "172.20.0.1", grup)], s.olaylar

        # Ağ listesi boş: bugünkü gibi tek gönderim, varsayılan ağdan.
        s = SahteSoket(set(), {})
        kesif._udp_soketi = lambda: s
        kesif.yerel_ipv4 = lambda: []
        kesif.kameralari_ara(saniye=0.1)
        assert s.olaylar == [("arayuz", "0.0.0.0"), ("gonder", "0.0.0.0", grup)], s.olaylar

        # Hiçbir ağdan gidemedi: varsayılan ağa geri dönülüp bir kez gönderilir.
        s = SahteSoket({"192.168.1.10"}, {})
        kesif._udp_soketi = lambda: s
        kesif.yerel_ipv4 = lambda: ["192.168.1.10"]
        kesif.kameralari_ara(saniye=0.1)
        assert s.olaylar[-2:] == [("arayuz", "0.0.0.0"), ("gonder", "0.0.0.0", grup)], s.olaylar
    finally:
        kesif._udp_soketi, kesif.yerel_ipv4 = eski


def test_birden_cok_cihaz_cevap_verirse_varsayilan_secilmez() -> None:
    """
    (D) Aramaya birden çok cihaz cevap verirse Enter hiçbirini seçmez.

    Enter = "1" iken site Wi-Fi'sindeki başka bir ONVIF cihazı (kayıt cihazı,
    başka kamera) listenin başına düşerse kameranın şifresi ONA denenirdi.
    Tek cihaz cevap verdiyse Enter onu seçer, bugünkü gibi.
    """
    sorular: list[str] = []
    _, _, cikti, secilen = _kamera_bilgisi(
        ["tamam"], ["", "2", "admin", "s1", "554"],
        bulunan=["192.168.1.30", "192.168.50.20"], sorular=sorular)
    assert secilen == ["192.168.50.20"], (secilen, cikti)
    secim = [s for s in sorular if "Numara" in s]
    assert len(secim) == 2 and not any("[1]" in s for s in secim), sorular

    _, _, cikti, secilen = _kamera_bilgisi(
        ["tamam"], ["", "admin", "s1", "554"], bulunan=["192.168.50.20"])
    assert secilen == ["192.168.50.20"], (secilen, cikti)


# ------------------------------------------- testler makineye dokunmaz ---

def test_alt_surecler_programdata_devralmaz() -> None:
    """
    Bu dosyada alt süreç başlatan her fonksiyon PROGRAMDATA'yı geçici bir
    klasöre çevirir.

    Köprü ayarını da kaydını da %PROGRAMDATA%\\Otopark altında arar. Ortamı
    `os.environ`den kurup PROGRAMDATA'yı devralan bir alt süreç, testi
    çalıştıran makinenin GERÇEK klasörünü görür: `kopru.main()` oradaki kayıt
    dosyasına yazar, ayarsız bir içe aktarma da oradaki `kopru.json`u okur.
    """
    import ast

    with open(os.path.abspath(__file__), encoding="utf-8") as f:
        agac = ast.parse(f.read())
    eksik = []
    for fn in ast.walk(agac):
        if not isinstance(fn, ast.FunctionDef):
            continue
        dugumler = list(ast.walk(fn))
        baslatir = any(
            isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute)
            and d.func.attr == "run" and isinstance(d.func.value, ast.Name)
            and d.func.value.id == "subprocess"
            for d in dugumler)
        cevirir = any(
            isinstance(d, ast.Dict) and any(
                isinstance(k, ast.Constant) and k.value == "PROGRAMDATA"
                for k in d.keys)
            for d in dugumler)
        if baslatir and not cevirir:
            eksik.append(fn.name)
    assert not eksik, f"PROGRAMDATA'yı devralan alt süreç: {eksik}"


def _tuzaktakiler(tuzak: str) -> list[str]:
    return sorted(os.path.relpath(os.path.join(kok, ad), tuzak)
                  for kok, _, dosyalar in os.walk(tuzak) for ad in dosyalar)


if __name__ == "__main__":
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    basarisiz: list[str] = []
    # Bu çalıştırmanın BÜTÜN geçici dosyaları tek klasörde toplanır: testlerin
    # mkdtemp'leri, tuzak, alt süreçlerinkiler (ortamlarını os.environ'dan
    # kurarlar). Eskiden her çalıştırma %TEMP%'e ~20 ayrı klasör bırakıyordu.
    # Klasör SİLİNMEZ; sonunda yolu yazılır, elle temizlenir. Python önce
    # TMPDIR'a bakar (Git Bash onu kurabilir), o yüzden üçü birden atanır.
    kok = tempfile.mkdtemp(prefix="otopark-test-kurulum-")
    tempfile.tempdir = kok
    for _ad in ("TMPDIR", "TEMP", "TMP"):
        os.environ[_ad] = kok
    # Her test PROGRAMDATA olarak BOŞ bir tuzak klasörünü devralır. Kendi
    # geçici klasörünü kurmayı unutan test oraya yazar — makinenin gerçek
    # C:\ProgramData\Otopark klasörüne değil — ve o test FAIL olur. Her testten
    # önce yeniden atanır; yine de değiştirip GERİ KOYMAYAN test FAIL olur:
    # testi tek başına çağıran birinde sonraki kod başka klasöre bakardı.
    tuzak = tempfile.mkdtemp(prefix="otopark-test-")
    for t in testler:
        os.environ["PROGRAMDATA"] = tuzak
        hata = None
        try:
            t()
        except Exception as e:
            hata = str(e)
        ek = []
        if os.environ.get("PROGRAMDATA") != tuzak:
            ek.append("PROGRAMDATA'yı geri koymadı")
        sizan = _tuzaktakiler(tuzak)
        if sizan:
            ek.append("devralınan PROGRAMDATA'ya yazdı: " + ", ".join(sizan))
            tuzak = tempfile.mkdtemp(prefix="otopark-test-")   # sonrakiler temiz başlasın
        if ek:
            hata = " | ".join(([hata] if hata else []) + ek)
        if hata is None:
            print(f"  PASS  {t.__name__}")
        else:
            basarisiz.append(t.__name__)
            print(f"  FAIL  {t.__name__}: {hata}")
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti")
    print(f"Geçici dosyalar: {kok}")
    if basarisiz:
        # Uzun çıktıda tek bir FAIL satırı gözden kaçıyordu (10.10'daki 70/71'in
        # adı bu yüzden bilinmiyor); adlar sonda bir kez daha yazılır.
        print("BAŞARISIZ: " + ", ".join(basarisiz))
    sys.exit(1 if basarisiz else 0)
