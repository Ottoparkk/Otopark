# -*- coding: utf-8 -*-
"""
Grafik işlemcisi (1.4.2) — hizlandirici.py birim testleri.

    python test_hizlandirici.py

1.4.2 üç modeli de sahadaki dizüstünün grafik işlemcisinde (Intel UHD 620,
OpenVINO) çalıştırır: sahada 4.5 → ~10 kare/sn. Grafik işlemcisi başlarken
ya da çalışırken bozulursa köprü DÜŞMEZ ve araç KAYBETMEZ: işlemciye (1.4.1'in
ORT-CPU + YOLOX-tiny kümesi) geçer ve bunu kayda yazar.

Sahte nesnelerle sınananlar: küme seçimi, geri dönüş, ayarlar. Gerçek
OpenVINO (paket venv'i) kuruluysa işlemci (CPU) aygıtında sınanır; grafik
işlemcisi olan bilgisayarda gerçek GPU testleri de koşar. Kurulu değilse o
testler AÇIKÇA "atlandı" der — sürüm öncesi hepsi paket venv'inde koşmalı.
"""
from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BURASI)

import numpy as np  # noqa: E402

import arac  # noqa: E402
import gunluk  # noqa: E402
import hizlandirici  # noqa: E402
import plaka  # noqa: E402

ATLANAN: list[str] = []


def _ov_var() -> bool:
    import importlib.util
    return importlib.util.find_spec("openvino") is not None


def _gpu_var() -> bool:
    if not _ov_var():
        return False
    import openvino as ov
    return "GPU" in ov.Core().available_devices


def _ayar(**ek) -> dict:
    eski = {k: os.environ.pop(k, None) for k in plaka.AYAR_ADLARI}
    try:
        a = plaka.calisma_ayarlari()[0]
    finally:
        for k, v in eski.items():
            if v is not None:
                os.environ[k] = v
    a.update(ek)
    return a


def _yakala(f):
    """f()'in ekrana yazdığı (köprünün kaydı) ve dönüşü."""
    tampon = io.StringIO()
    with contextlib.redirect_stdout(tampon):
        sonuc = f()
    return tampon.getvalue(), sonuc


# ------------------------------------------------------------------ ayarlar ---

def test_ayarlar():
    a = _ayar()
    assert a["hizlandirici"] == "GPU", a
    assert a["arac_model"] == "otomatik", a
    # YOLO11s eşikleri ayarlanmadıysa None: profilin kendi değeri kullanılır.
    assert a["arac11_esik"] is None and a["arac11_gecis_esik"] is None, a
    for ad in ("HIZLANDIRICI", "ARAC_MODEL", "ARAC11_BUL_ESIK", "ARAC11_GECIS_ESIK"):
        assert ad in plaka.AYAR_ADLARI, ad
    a, u = plaka.calisma_ayarlari({"HIZLANDIRICI": "cpu", "ARAC_MODEL": "YOLO11s",
                                   "ARAC11_BUL_ESIK": "0.2", "ARAC11_GECIS_ESIK": "0.45"})
    assert u == [] and a["hizlandirici"] == "CPU" and a["arac_model"] == "yolo11s", (a, u)
    assert (a["arac11_esik"], a["arac11_gecis_esik"]) == (0.2, 0.45)
    a, u = plaka.calisma_ayarlari({"HIZLANDIRICI": "npu", "ARAC_MODEL": "yolov8",
                                   "ARAC11_BUL_ESIK": "2"})
    assert a["hizlandirici"] == "GPU" and a["arac_model"] == "otomatik", a
    assert a["arac11_esik"] is None and len(u) == 3, (a, u)


def test_motosiklet_esigi_ayari():
    # 1.4.3 (sahibin kararı 20.11): ARAC11_MOTO_ESIK — boş = profilin değeri
    # (1.4.4: 0.70);
    # sahada geri almak için 0.30 (doğum eşiği) yazılır.
    assert "ARAC11_MOTO_ESIK" in plaka.AYAR_ADLARI
    assert _ayar()["arac11_moto_esik"] is None
    a, u = plaka.calisma_ayarlari({"ARAC11_MOTO_ESIK": "0.3"})
    assert u == [] and a["arac11_moto_esik"] == 0.3, (a, u)
    a, u = plaka.calisma_ayarlari({"ARAC11_MOTO_ESIK": "2"})
    assert a["arac11_moto_esik"] is None and len(u) == 1, (a, u)


def test_kart_esigi_ayari():
    # 1.4.6 B (sahibin kararı 25.11): ARAC11_KART_ESIK — boş = profilin değeri
    # (0.75); sahada geri almak için 0.30 (doğum eşiği) yazılır.
    assert "ARAC11_KART_ESIK" in plaka.AYAR_ADLARI
    assert _ayar()["arac11_kart_esik"] is None
    a, u = plaka.calisma_ayarlari({"ARAC11_KART_ESIK": "0.3"})
    assert u == [] and a["arac11_kart_esik"] == 0.3, (a, u)
    a, u = plaka.calisma_ayarlari({"ARAC11_KART_ESIK": "2"})
    assert a["arac11_kart_esik"] is None and len(u) == 1, (a, u)


def test_ikiz_sn_ayari():
    # 1.4.6 C (sahibin kararı 25.11): IKIZ_SN — varsayılan 25 sn, 0 = kapalı.
    assert "IKIZ_SN" in plaka.AYAR_ADLARI
    assert _ayar()["ikiz_sn"] == 25.0
    a, u = plaka.calisma_ayarlari({"IKIZ_SN": "0"})
    assert u == [] and a["ikiz_sn"] == 0.0, (a, u)
    a, u = plaka.calisma_ayarlari({"IKIZ_SN": "90"})
    assert a["ikiz_sn"] == 25.0 and len(u) == 1, (a, u)


def test_plaka_kirpik_ayari():
    # 1.4.6 L (sahibin kararı 25.11): kartın en iyi plaka kırpığı bu
    # bilgisayarda saklanır — varsayılan AÇIK, 0 = kapalı.
    assert "PLAKA_KIRPIK" in plaka.AYAR_ADLARI
    assert _ayar()["plaka_kirpik"] is True
    a, u = plaka.calisma_ayarlari({"PLAKA_KIRPIK": "0"})
    assert u == [] and a["plaka_kirpik"] is False, (a, u)
    a, u = plaka.calisma_ayarlari({"PLAKA_KIRPIK": "evet"})
    assert a["plaka_kirpik"] is True and len(u) == 1, (a, u)


def test_arac_profili():
    # 2026-11-13: YOLO11s 640 gece fotoğraflarıyla ölçüldü (25/25 araç, boş
    # şerit / insan / el arabasında 0 yanlış alarm) → "otomatik" YOLO11s.
    assert arac.YOLO11S.yer_tutucu is False
    assert hizlandirici.arac_profili(_ayar()) is arac.YOLO11S
    assert hizlandirici.arac_profili(_ayar(arac_model="tiny")) is arac.YOLOX_TINY
    assert hizlandirici.arac_profili(_ayar(arac_model="yolo11s")) is arac.YOLO11S
    # Kural yerinde kalır: ölçülmemiş (yer tutucu) profil "otomatik"te açılmaz.
    eski = arac.YOLO11S
    try:
        arac.YOLO11S = eski._replace(yer_tutucu=True)
        assert hizlandirici.arac_profili(_ayar()) is arac.YOLOX_TINY
        assert hizlandirici.arac_profili(_ayar(arac_model="yolo11s")) is arac.YOLO11S
    finally:
        arac.YOLO11S = eski


# ------------------------------------------------------------ yedekli oturum ---

class _Oturum:
    """
    Sahte oturum. `hata`: her çağrıda; `hatalar`: ilk len(hatalar) çağrıda
    sırayla (None = o çağrı başarılı), sonra başarılı.
    """

    def __init__(self, ad, hata=None, hatalar=None):
        self.ad, self.hata, self.cagri = ad, hata, 0
        self._hatalar = list(hatalar or [])

    def get_inputs(self):
        class G:
            name = "images"
        return [G()]

    def run(self, adlar, girdiler):
        self.cagri += 1
        if self._hatalar:
            h = self._hatalar.pop(0)
            if h is not None:
                raise h
            return [self.ad]
        if self.hata is not None:
            raise self.hata
        return [self.ad]


def test_yedekli_oturum_gpu_hatasinda_isleme_gecer():
    gpu = _Oturum("gpu", plaka.HizlandiriciHatasi("CL_OUT_OF_RESOURCES"))
    acilan = []
    cpu = _Oturum("cpu")

    def yedek():
        acilan.append(1)
        return cpu

    o = hizlandirici.YedekliOturum(gpu, yedek, "plaka okuyucu")
    assert o.get_inputs()[0].name == "images"
    kayit, sonuc = _yakala(lambda: o.run(None, {"images": 0}))
    assert sonuc == ["cpu"], sonuc                   # kare kaybolmaz: aynı çağrı işlemcide
    # 1.4.2: tek hatada bırakılmaz — grafik işlemcisi 3 kez denenir.
    assert gpu.cagri == hizlandirici.DENEME == 3, gpu.cagri
    assert gunluk.GPU_BIRAKILDI_ISARETI in kayit and "plaka okuyucu" in kayit, kayit
    assert "CL_OUT_OF_RESOURCES" in kayit, kayit
    kayit, sonuc = _yakala(lambda: o.run(None, {"images": 0}))
    assert sonuc == ["cpu"] and kayit == "" and gpu.cagri == 3 and len(acilan) == 1
    assert o.yedekte is True


def test_yedekli_oturum_iki_hatadan_sonra_gpu_da_kalir():
    # Geçici aksama (2 hata, 3. deneme başarılı): işlemciye GEÇİLMEZ.
    h = plaka.HizlandiriciHatasi("CL_INVALID_COMMAND_QUEUE")
    gpu = _Oturum("gpu", hatalar=[h, h, None])
    acilan = []
    o = hizlandirici.YedekliOturum(gpu, lambda: acilan.append(1) or _Oturum("cpu"), "plaka bulucu")
    kayit, sonuc = _yakala(lambda: o.run(None, {"images": 0}))
    assert sonuc == ["gpu"] and gpu.cagri == 3 and not acilan and kayit == "", (sonuc, kayit)
    assert o.yedekte is False


def test_kalp_etiketi_birakilan_gpu_yu_soyler():
    # Grafik işlemcisi çalışırken bırakıldıysa kalp satırı artık "GPU" demez:
    # kayda bakan, köprünün işlemcide (yavaş) sürdüğünü görmeli.
    plaka.GPU_BIRAKILANLAR.clear()
    try:
        assert hizlandirici.kalp_etiketi("GPU · YOLO11s") == "GPU · YOLO11s"
        o = hizlandirici.YedekliOturum(_Oturum("gpu", plaka.HizlandiriciHatasi("x")),
                                       lambda: _Oturum("cpu"), "plaka okuyucu")
        _yakala(lambda: o.run(None, {}))
        assert plaka.GPU_BIRAKILANLAR == ["plaka okuyucu"], plaka.GPU_BIRAKILANLAR
        assert hizlandirici.kalp_etiketi("GPU · YOLO11s") == \
            "GPU · YOLO11s (bırakıldı: plaka okuyucu → işlemci)", hizlandirici.kalp_etiketi("GPU")
        assert hizlandirici.kalp_etiketi("CPU · YOLOX-tiny") == "CPU · YOLOX-tiny"
    finally:
        plaka.GPU_BIRAKILANLAR.clear()


def test_yedekli_oturum_baska_hatayi_yutmaz():
    # Grafik işlemcisi hatası olmayan hata (ör. bozuk girdi) işlemcide de
    # olurdu: geçiş yapılmaz, hata işçiye gider (orada sayılır).
    gpu = _Oturum("gpu", ValueError("bozuk girdi"))
    o = hizlandirici.YedekliOturum(gpu, lambda: _Oturum("cpu"), "plaka bulucu")
    try:
        o.run(None, {"images": 0})
        raise AssertionError("hata yutuldu")
    except ValueError:
        pass
    assert o.yedekte is False


# ------------------------------------------------------------ küme seçimi ---

class _SahteHiz:
    """Hizlandirici yerine: oturum istenen dosyaları ve hassasiyeti kaydeder."""

    def __init__(self):
        self.istenen: list[tuple[str, bool]] = []

    def oturum(self, yol, hassas=False, sekiller=None, yedek=None):
        self.istenen.append((os.path.basename(yol), hassas))
        return object()


def _sahte_yukleyiciler(plaka_hata=None, arac_hata=None, gpu_plaka_hata=None,
                        gpu_arac_hata=None):
    cagri = []

    def p_yukle(ayar, dizin=None, hiz=None):
        cagri.append(("plaka", hiz is not None))
        if hiz is not None and gpu_plaka_hata:
            raise plaka.PlakaHatasi(gpu_plaka_hata)
        if hiz is None and plaka_hata:
            raise plaka.PlakaHatasi(plaka_hata)
        return "plakaci-gpu" if hiz is not None else "plakaci-cpu"

    def a_yukle(ayar, dizin=None, profil=None, hiz=None):
        cagri.append(("arac", hiz is not None, (profil or arac.YOLOX_TINY).ad))
        if hiz is not None and gpu_arac_hata:
            raise plaka.PlakaHatasi(gpu_arac_hata)
        if hiz is None and arac_hata:
            raise plaka.PlakaHatasi(arac_hata)
        return f"bulucu-{'gpu' if hiz is not None else 'cpu'}-{(profil or arac.YOLOX_TINY).ad}"

    return cagri, p_yukle, a_yukle


def _yukle(ayar, hiz_ac, **sahte):
    cagri, p_yukle, a_yukle = _sahte_yukleyiciler(**sahte)
    eski = plaka.yukle, arac.yukle
    plaka.yukle, arac.yukle = p_yukle, a_yukle
    try:
        kayit, kume = _yakala(lambda: hizlandirici.modelleri_yukle(ayar, True, hiz_ac=hiz_ac))
    finally:
        plaka.yukle, arac.yukle = eski
    return cagri, kayit, kume


def test_kume_gpu():
    cagri, kayit, k = _yukle(_ayar(arac_model="yolo11s"), lambda: _SahteHiz())
    assert (k.plakaci, k.bulucu) == ("plakaci-gpu", "bulucu-gpu-YOLO11s"), k
    assert k.ad == "GPU · YOLO11s" and k.gpu_hata is None, k
    assert cagri == [("plaka", True), ("arac", True, "YOLO11s")], cagri
    assert f"{gunluk.MODELLER_ISARETI}: GPU · YOLO11s" in kayit, kayit


def test_kume_gpu_yoksa_islemci_tiny():
    def yok():
        raise plaka.HizlandiriciHatasi("grafik işlemcisi bulunamadı")
    cagri, kayit, k = _yukle(_ayar(arac_model="yolo11s"), yok)
    # İşlemci kümesi HER ZAMAN 1.4.1'inki: ORT-CPU + YOLOX-tiny.
    assert (k.plakaci, k.bulucu) == ("plakaci-cpu", "bulucu-cpu-YOLOX-tiny"), k
    assert k.ad == "CPU · YOLOX-tiny (yedek)" and "bulunamadı" in k.gpu_hata, k
    assert cagri == [("plaka", False), ("arac", False, "YOLOX-tiny")], cagri
    assert gunluk.GPU_YOK_ISARETI in kayit and "bulunamadı" in kayit, kayit
    assert f"{gunluk.MODELLER_ISARETI}: CPU · YOLOX-tiny (yedek)" in kayit, kayit


def test_kume_gpu_oz_sinamasi_tutmazsa_hepsi_islemciye():
    # Araç bulucu grafik işlemcisinde öz sınamayı geçemezse (ör. sürücü yanlış
    # hesaplıyor) plaka modelleri de işlemciye döner: tek, sınanmış küme.
    cagri, kayit, k = _yukle(_ayar(arac_model="yolo11s"), lambda: _SahteHiz(),
                             gpu_arac_hata="öz sınama başarısız: puan 0.10")
    assert (k.plakaci, k.bulucu) == ("plakaci-cpu", "bulucu-cpu-YOLOX-tiny"), k
    assert "öz sınama" in k.gpu_hata and k.ad == "CPU · YOLOX-tiny (yedek)", k
    assert cagri[-2:] == [("plaka", False), ("arac", False, "YOLOX-tiny")], cagri
    cagri, kayit, k = _yukle(_ayar(), lambda: _SahteHiz(), gpu_plaka_hata="CL hata")
    assert k.plakaci == "plakaci-cpu" and "CL hata" in k.gpu_hata, k


def test_kume_cpu_istenirse_gpu_denenmez():
    def acilmamali():
        raise AssertionError("HIZLANDIRICI=CPU iken grafik işlemcisi denendi")
    cagri, kayit, k = _yukle(_ayar(hizlandirici="CPU"), acilmamali)
    assert k.ad == "CPU · YOLOX-tiny" and k.gpu_hata is None, k
    assert gunluk.GPU_YOK_ISARETI not in kayit


def test_kume_islemcide_de_bozuksa_bugunku_kural():
    # İşlemci kümesinde de okuyucu açılmazsa köprü 1.4.1 gibi sürer: okuyucu
    # yok → bulucu da yüklenmez; bulucu açılmazsa okuyucu yine çalışır.
    def yok():
        raise plaka.HizlandiriciHatasi("yok")
    _c, _k, k = _yukle(_ayar(), yok, plaka_hata="model dosyası bulunamadı")
    assert k.plakaci is None and k.bulucu is None and "bulunamadı" in k.plaka_hata, k
    _c, _k, k = _yukle(_ayar(), yok, arac_hata="araç modeli açılamadı")
    assert k.plakaci == "plakaci-cpu" and k.bulucu is None and "açılamadı" in k.arac_hata, k


# ------------------------------------------- GPU'ya geri dönüş (1.4.2) ---
#
# Sahibin isteği (2026-11-13): tek hata köprüyü yeniden başlatılana kadar
# tiny'ye düşürmesin. İşlemcideyken her 30 sn'de bir kısa ömürlü iş: yeni
# OpenVINO çekirdeği, üç model, YEDEKSİZ öz sınama → geçerse yayımla (her
# oturum kendi iş parçacığında devralır). 10 dk'da dönmezse sakin anda
# yeniden başlatma (saatte en çok bir).

class _Saat:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class _SahteBulucu:
    """AracBulucu'nun geri dönüşle ilgili yüzü."""

    def __init__(self, gpu_da: bool):
        self._gpu_da = gpu_da
        self.verilen = []

    @property
    def gpu_da(self):
        return self._gpu_da or bool(self.verilen)

    def gpu_ver(self, oturum, profil):
        self.verilen.append((oturum, profil))


class _SahtePlakaci:
    def __init__(self, gpu_da: bool):
        g = _Oturum("gpu") if gpu_da else None
        self._bulucu = hizlandirici.YedekliOturum(g, lambda: _Oturum("cpu-b"), "plaka bulucu")
        self._okuyucu = hizlandirici.YedekliOturum(g, lambda: _Oturum("cpu-o"), "plaka okuyucu")


def _geri(plakaci, bulucu, sonuclar, saat, duvar=None, kayit_dosyasi=None, baslat=None):
    """
    sonuclar: her deneme için ya bir istisna ya da None (başarılı). Başarılı
    deneme (b, o, (v, profil)) yeni GPU oturumları verir.
    """
    deneme = []

    def kume_ac():
        deneme.append(saat())
        s = sonuclar.pop(0) if sonuclar else None
        if s is not None:
            raise s
        return _Oturum("gpu-b2"), _Oturum("gpu-o2"), (_Oturum("gpu-v2"), arac.YOLO11S)

    g = hizlandirici.GpuGeriDonus(
        plakaci, bulucu, kume_ac=kume_ac, saat=saat, duvar=duvar or (lambda: 1_000_000.0),
        kayit_dosyasi=kayit_dosyasi or os.path.join(tempfile.mkdtemp(), "gpu-yeniden.txt"),
        baslat=baslat or (lambda f: f()))
    return g, deneme


def test_geri_donus_30_sn_de_bir_dener_ve_doner():
    plaka.GPU_BIRAKILANLAR[:] = ["plaka okuyucu", "araç bulucu"]
    saat = _Saat()
    p, b = _SahtePlakaci(False), _SahteBulucu(False)
    hata = plaka.HizlandiriciHatasi("grafik işlemcisi bulunamadı (aygıtlar: CPU)")
    g, deneme = _geri(p, b, [hata, hata, None], saat)
    assert g.islemcide() is True
    kayit, _ = _yakala(g.tik)                   # t=0: hemen dener (açılışta GPU yoktu)
    assert deneme == [0.0] and gunluk.GPU_HALA_YOK_ISARETI in kayit, kayit
    saat.t = 29.9
    _yakala(g.tik)
    assert deneme == [0.0], deneme              # 30 sn dolmadan denenmez
    saat.t = 30.0
    _yakala(g.tik)
    assert deneme == [0.0, 30.0], deneme
    saat.t = 60.0
    kayit, _ = _yakala(g.tik)
    assert deneme == [0.0, 30.0, 60.0], deneme
    # Yayımlandı: her oturum yeni GPU'yu KENDİ iş parçacığında devralacak.
    assert p._bulucu._yeni.ad == "gpu-b2" and p._okuyucu._yeni.ad == "gpu-o2"
    assert b.verilen and b.verilen[0][1] is arac.YOLO11S
    assert g.islemcide() is False and gunluk.GPU_GERI_GELDI_ISARETI in kayit, kayit
    assert plaka.GPU_BIRAKILANLAR == [], plaka.GPU_BIRAKILANLAR
    assert p._bulucu.run(None, {})[0] == "gpu-b2" and p._bulucu.yedekte is False
    saat.t = 200.0
    _yakala(g.tik)
    assert len(deneme) == 3                     # GPU'dayken denenmez


def test_geri_donus_ayni_anda_tek_is_ve_cokunce_yeniden():
    saat = _Saat()
    bekleyen = []
    p, b = _SahtePlakaci(False), _SahteBulucu(False)
    g, deneme = _geri(p, b, [RuntimeError("beklenmedik"), None], saat,
                      baslat=lambda f: bekleyen.append(f))
    _yakala(g.tik)
    assert len(bekleyen) == 1
    saat.t = 45.0
    _yakala(g.tik)
    assert len(bekleyen) == 1, "iş sürerken ikinci iş başladı"
    _yakala(bekleyen.pop(0))                    # iş beklenmedik hatayla çöktü
    assert g.islemcide() is True
    saat.t = 80.0
    _yakala(g.tik)                              # çöken iş sonraki tikte yeniden başlar
    assert len(bekleyen) == 1
    kayit, _ = _yakala(bekleyen.pop(0))
    assert g.islemcide() is False and gunluk.GPU_GERI_GELDI_ISARETI in kayit


def test_geri_donus_sebebi_10_dk_da_bir_yazar():
    saat = _Saat()
    hata = plaka.HizlandiriciHatasi("CL_DEVICE_NOT_AVAILABLE")
    g, _ = _geri(_SahtePlakaci(False), _SahteBulucu(False), [hata] * 30, saat)
    satirlar = 0
    for t in range(0, 900, 30):
        saat.t = float(t)
        kayit, _ = _yakala(g.tik)
        satirlar += kayit.count(gunluk.GPU_HALA_YOK_ISARETI)
    assert satirlar == 2, satirlar              # t=0 ve t=600
    assert "CL_DEVICE_NOT_AVAILABLE" in g.son_hata


def test_geri_donus_gpu_dayken_hic_denemez():
    saat = _Saat()
    g, deneme = _geri(_SahtePlakaci(True), _SahteBulucu(True), [], saat)
    for t in (0, 30, 600, 4000):
        saat.t = float(t)
        _yakala(g.tik)
    assert deneme == [] and g.islemcide() is False and g.yeniden_baslat_gerek() is False


def test_geri_donus_yeniden_baslatma_kosulu_saatte_bir():
    saat, duvar = _Saat(), _Saat()
    duvar.t = 1_000_000.0
    dosya = os.path.join(tempfile.mkdtemp(), "gpu-yeniden.txt")
    hata = plaka.HizlandiriciHatasi("CL_DEVICE_NOT_AVAILABLE")
    g, _ = _geri(_SahtePlakaci(False), _SahteBulucu(False), [hata] * 100, saat,
                 duvar=duvar, kayit_dosyasi=dosya)
    _yakala(g.tik)
    saat.t = 599.0
    _yakala(g.tik)
    assert g.yeniden_baslat_gerek() is False    # 10 dk dolmadı
    saat.t = 600.0
    duvar.t += 600
    _yakala(g.tik)
    assert g.yeniden_baslat_gerek() is True
    g.yeniden_baslatiliyor()                    # zamanı diske yazar (yeni süreç de görsün)
    # Yeni süreç (aynı dosya), GPU hâlâ yok: bir saat dolmadan yeniden başlatmaz.
    saat2 = _Saat()
    g2, _ = _geri(_SahtePlakaci(False), _SahteBulucu(False), [hata] * 100, saat2,
                  duvar=duvar, kayit_dosyasi=dosya)
    _yakala(g2.tik)
    saat2.t = 700.0
    duvar.t += 700
    _yakala(g2.tik)
    assert g2.yeniden_baslat_gerek() is False, "saat dolmadan ikinci yeniden başlatma"
    saat2.t = 3700.0
    duvar.t += 3000
    _yakala(g2.tik)
    assert g2.yeniden_baslat_gerek() is True


def test_geri_donus_etiketi():
    saat = _Saat()
    hata = plaka.HizlandiriciHatasi("x")
    g, _ = _geri(_SahtePlakaci(False), _SahteBulucu(False), [hata] * 10, saat)
    _yakala(g.tik)
    saat.t = 23 * 60.0
    assert g.etiket("GPU · YOLO11s") == "CPU · YOLOX-tiny (yedek, 23 dk)", g.etiket("GPU · YOLO11s")
    g2, _ = _geri(_SahtePlakaci(True), _SahteBulucu(True), [], saat)
    assert g2.etiket("GPU · YOLO11s") == "GPU · YOLO11s"


def test_bulucu_islemciden_baslayip_gpu_ya_doner_ve_yine_duser():
    # Açılışta GPU yoktu: işlemci kümesindeki tiny bulucu, yayımlanan YOLO11s
    # GPU oturumunu kendi karesinin başında devralır (eşikler 0.30 / 0.60);
    # GPU yine bozulursa aynı işlemci oturumuna döner (yeniden açmadan).
    import numpy as np
    sinif = None

    class Tiny:
        def get_inputs(self):
            class G:
                name = "images"
            return [G()]

        def run(self, adlar, girdiler):
            nonlocal sinif
            sinif = "tiny"
            return [np.zeros((1, 3549, 85), np.float32)]

    class Y11:
        def __init__(self):
            self.bozuk = False

        def get_inputs(self):
            return Tiny().get_inputs()

        def run(self, adlar, girdiler):
            nonlocal sinif
            assert girdiler["images"].shape == (1, 3, 640, 640)
            if self.bozuk:
                raise plaka.HizlandiriciHatasi("CL_DEVICE_LOST")
            sinif = "y11"
            return [np.zeros((1, 84, 8400), np.float32)]

    b = arac.AracBulucu(Tiny(), _ayar(), plaka.MODEL_DIZINI)          # işlemci kümesi
    assert b.gpu_da is False
    img = np.full((300, 400, 3), 120, np.uint8)
    b.skor(img, None)
    assert sinif == "tiny"
    y = Y11()
    b.gpu_ver(y, arac.YOLO11S)
    assert b.gpu_da is True                     # yayımlandı sayılır (iş tekrar başlamasın)
    b.skor(img, None)
    assert sinif == "y11" and b.profil is arac.YOLO11S and (b.esik, b.gecis_esik) == (0.30, 0.60)
    y.bozuk = True
    _yakala(lambda: b.skor(img, None))
    assert sinif == "tiny" and b.profil is arac.YOLOX_TINY and b.gpu_da is False
    plaka.GPU_BIRAKILANLAR.clear()


def test_geri_donus_gercek_modellerle_acilista_gpu_yoktu():
    # Uçtan uca, gerçek modellerle: açılışta GPU yok → işlemci kümesi (ama
    # sarılmış: geri dönebilsin). Sonra "GPU" geliyor (burada OpenVINO'nun
    # CPU aygıtı onun yerine) → tik → yayım → plaka ve araç yeni oturumla
    # okur: okuyucu altın plakayı, bulucu YOLO11s'in altın puanını verir.
    if not _ov_var():
        ATLANAN.append("geri dönüş, gerçek modeller (openvino kurulu değil)")
        return
    import cv2

    def yok():
        raise plaka.HizlandiriciHatasi("grafik işlemcisi bulunamadı (aygıtlar: CPU)")

    ayar = _ayar(arac_model="yolo11s")
    _, k = _yakala(lambda: hizlandirici.modelleri_yukle(ayar, True, hiz_ac=yok))
    assert k.ad == "CPU · YOLOX-tiny (yedek)"
    assert isinstance(k.plakaci._okuyucu, hizlandirici.YedekliOturum) and k.plakaci._okuyucu.yedekte
    onbellek = _turkce_klasor()
    g = hizlandirici.GpuGeriDonus(
        k.plakaci, k.bulucu, ayar=ayar, baslat=lambda f: f(),
        hiz_ac=lambda: hizlandirici.Hizlandirici.ac(onbellek, cihaz="CPU"),
        kayit_dosyasi=os.path.join(tempfile.mkdtemp(), "gpu-yeniden.txt"))
    assert g.islemcide() is True
    kayit, _ = _yakala(g.tik)
    assert gunluk.GPU_GERI_GELDI_ISARETI in kayit and "GPU · YOLO11s" in kayit, kayit
    metin, enk = plaka.kisitli_coz(k.plakaci.ham_oku(plaka.sabit_okuyucu_girdisi()[None])[0])
    assert metin == plaka.ALTIN_METIN and abs(enk - plaka.ALTIN_ENK) < 1e-3, (metin, enk)
    assert k.plakaci._okuyucu.yedekte is False
    img = cv2.imread(os.path.join(plaka.MODEL_DIZINI, arac.SINAMA.dosya))
    a, _ = k.bulucu.skor(img, None)
    assert k.bulucu.profil is arac.YOLO11S and abs(a - arac.YOLO11S.altin) < 0.01, a
    assert g.islemcide() is False


# ------------------------------------- öz sınama işlemciye kaçamaz (1.4.2) ---

def _ort_var() -> bool:
    import importlib.util
    return importlib.util.find_spec("onnxruntime") is not None


class _BozukGpu:
    """Gerçek gibi: her çağrıda HizlandiriciHatasi (ör. sürücü hatası)."""

    def __init__(self, ad):
        self.ad = ad

    def get_inputs(self):
        class G:
            name = "input" if "cct_s" in self.ad else "images"
        g = G()
        return [g]

    def run(self, adlar, girdiler):
        raise plaka.HizlandiriciHatasi(f"CL_OUT_OF_RESOURCES ({self.ad})")


class _GercekGibiHiz:
    """
    Hizlandirici gibi davranır: `bozuk` adlı dosyaların oturumu her çağrıda
    hata verir, diğerleri işlemcide (ORT) çalışır. yedek verilirse gerçek
    YedekliOturum ile sarılır — sahadaki gibi.
    """

    def __init__(self, *bozuk: str):
        self._bozuk = bozuk

    def oturum(self, yol, hassas=False, sekiller=None):
        ad = os.path.basename(yol)
        return _BozukGpu(ad) if any(b in ad for b in self._bozuk) else plaka.ort_oturumu(yol, 2)

    yedekli = staticmethod(hizlandirici.Hizlandirici.yedekli)


def test_gpu_oz_sinamasi_isleme_kacamaz():
    # 2026-11-13'te bulundu: grafik işlemcisinde öz sınama sırasında bozulan
    # model sessizce işlemciye geçip sınamayı orada GEÇİYORDU; köprü "GPU"
    # diyordu. Öz sınama grafik işlemcisinde, yedeksiz koşmalı: bozuksa
    # bütün küme işlemcide açılır ve öyle söylenir.
    if not _ort_var():
        ATLANAN.append("öz sınama kaçışı (onnxruntime kurulu değil)")
        return
    for bozuk in ("cct_s_v2_global", "yolo11s_640", "license-plates"):
        plaka.GPU_BIRAKILANLAR.clear()
        kayit, k = _yakala(lambda: hizlandirici.modelleri_yukle(
            _ayar(arac_model="yolo11s"), True, hiz_ac=lambda: _GercekGibiHiz(bozuk)))
        assert k.ad == "CPU · YOLOX-tiny (yedek)", (bozuk, k.ad, kayit)
        assert k.gpu_hata and "CL_OUT_OF_RESOURCES" in k.gpu_hata, (bozuk, k.gpu_hata)
        assert k.bulucu is not None and k.bulucu.profil is arac.YOLOX_TINY, bozuk
        assert gunluk.GPU_BIRAKILDI_ISARETI not in kayit, (bozuk, kayit)
    plaka.GPU_BIRAKILANLAR.clear()


def test_gpu_kumesi_sinamadan_sonra_yedekli():
    # Sağlam grafik işlemcisi: öz sınama geçer, SONRA oturumlar işlemci
    # yedeğiyle sarılır (çalışırken bozulursa aynı kare işlemcide).
    if not _ort_var():
        ATLANAN.append("GPU kümesinin yedeği (onnxruntime kurulu değil)")
        return
    kayit, k = _yakala(lambda: hizlandirici.modelleri_yukle(
        _ayar(arac_model="yolo11s"), True, hiz_ac=lambda: _GercekGibiHiz()))
    assert k.ad == "GPU · YOLO11s" and k.gpu_hata is None, (k.ad, kayit)
    assert isinstance(k.plakaci._bulucu, hizlandirici.YedekliOturum)
    assert isinstance(k.plakaci._okuyucu, hizlandirici.YedekliOturum)
    assert (k.plakaci._bulucu.ad, k.plakaci._okuyucu.ad) == ("plaka bulucu", "plaka okuyucu")
    assert k.bulucu._yedek is not None and k.bulucu.profil is arac.YOLO11S


# --------------------------------------------------- gerçek OpenVINO (CPU) ---

def _turkce_klasor() -> str:
    return tempfile.mkdtemp(prefix="hız-ölçüm-ğüşç-")


def test_ov_oturum_ort_ile_ayni_ve_turkce_onbellek():
    if not _ov_var():
        ATLANAN.append("OpenVINO oturumu (openvino kurulu değil)")
        return
    # Önbellek Türkçe harfli klasörde de çalışmalı (sahadaki klasör adı
    # Türkçe olabilir; hız aracı 1.0 tam bu yüzden açılmamıştı).
    onbellek = _turkce_klasor()
    hiz = hizlandirici.Hizlandirici.ac(onbellek, cihaz="CPU")
    yol = os.path.join(plaka.MODEL_DIZINI, plaka.OKUYUCU.dosya)
    o = hiz.oturum(yol, hassas=True, sekiller=[(1, 64, 128, 3), (2, 64, 128, 3)])
    assert [g.name for g in o.get_inputs()] == ["input"]
    g1 = plaka.sabit_okuyucu_girdisi()[None]
    for g in (g1, np.concatenate([g1, g1[:, :, ::-1]])):
        p = o.run(["plate"], {"input": g})
        assert len(p) == 1 and p[0].shape == (len(g), plaka.SLOT, len(plaka.ALFABE)), p[0].shape
        metin, enk = plaka.kisitli_coz(p[0][0])
        assert metin == plaka.ALTIN_METIN and abs(enk - plaka.ALTIN_ENK) < 1e-3, (metin, enk)
    assert os.listdir(onbellek), "önbellek yazılmadı"


def test_ov_oturum_hatasi_hizlandirici_hatasidir():
    if not _ov_var():
        ATLANAN.append("OpenVINO hata sarmalama (openvino kurulu değil)")
        return
    hiz = hizlandirici.Hizlandirici.ac(_turkce_klasor(), cihaz="CPU")
    o = hiz.oturum(os.path.join(plaka.MODEL_DIZINI, plaka.OKUYUCU.dosya), hassas=True)
    try:
        o.run(["plate"], {"yok_boyle_girdi": np.zeros((1, 64, 128, 3), np.uint8)})
        raise AssertionError("OpenVINO hatası sarmalanmadı")
    except plaka.HizlandiriciHatasi as e:
        assert str(e), "sebepsiz hata"


def test_plaka_ve_arac_ov_ile_oz_sinamayi_gecer():
    if not _ov_var():
        ATLANAN.append("OpenVINO ile öz sınama (openvino kurulu değil)")
        return
    hiz = hizlandirici.Hizlandirici.ac(_turkce_klasor(), cihaz="CPU")
    plaka.yukle(_ayar(), hiz=hiz)
    for p in (arac.YOLOX_TINY, arac.YOLO11S):
        b = arac.yukle(_ayar(), profil=p, hiz=hiz)
        assert b.profil is p


# ------------------------------------------------------- gerçek grafik işlemcisi ---

def test_gpu_kumesi_ve_okuyucu_tam_hassas():
    if not _gpu_var():
        ATLANAN.append("grafik işlemcisi (bu bilgisayarda yok ya da openvino kurulu değil)")
        return
    hiz = hizlandirici.Hizlandirici.ac(_turkce_klasor())
    assert hiz.cihaz == "GPU"
    # Okuyucu f32: GPU'nun varsayılanı (f16) olasılığı 0.007'ye kadar kaydırıyor
    # (2026-11-12 ölçümü) — 0.95 / 0.99 eşiklerinin dibinde. Bulucular f16 (fark
    # ≤ 0.003, iki kat hızlı).
    yol = os.path.join(plaka.MODEL_DIZINI, plaka.OKUYUCU.dosya)
    o = hiz.oturum(yol, hassas=True, sekiller=[(1, 64, 128, 3)])
    assert o.hassasiyet() == "f32", o.hassasiyet()
    yol = os.path.join(plaka.MODEL_DIZINI, arac.YOLO11S.model.dosya)
    assert hiz.oturum(yol).hassasiyet() == "f16"
    p = plaka.yukle(_ayar(), hiz=hiz)
    metin, enk = plaka.kisitli_coz(p.ham_oku(plaka.sabit_okuyucu_girdisi()[None])[0])
    assert metin == plaka.ALTIN_METIN and abs(enk - plaka.ALTIN_ENK) < 1e-3, (metin, enk)
    for prof in (arac.YOLOX_TINY, arac.YOLO11S):
        b = arac.yukle(_ayar(), profil=prof, hiz=hiz)
        import cv2
        img = cv2.imread(os.path.join(plaka.MODEL_DIZINI, arac.SINAMA.dosya))
        a, _ = b.skor(img, None)
        assert abs(a - prof.altin) < 0.01, (prof.ad, a)


if __name__ == "__main__":
    import kalinti
    kok = kalinti.klasor("otopark-test-hiz-")         # tek klasörde (kalinti.py)
    testler = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    basarisiz: list[str] = []
    for t in testler:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            basarisiz.append(t.__name__)
            print(f"  FAIL  {t.__name__}: {type(e).__name__}: {e}")
    for a in ATLANAN:
        print(f"  ATLANDI  {a}")
    print(f"\n{len(testler) - len(basarisiz)}/{len(testler)} geçti"
          + (f", {len(ATLANAN)} atlandı" if ATLANAN else ""))
    print(f"Geçici dosyalar (silinmez, elle temizlenir): {kok}")
    sys.exit(1 if basarisiz else 0)
