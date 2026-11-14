# -*- coding: utf-8 -*-
"""
Grafik işlemcisi (köprü 1.4.2): üç model OpenVINO ile GPU'da.

Neden: sahadaki dizüstü (Dell Latitude 5590, i5-8250U, Intel UHD 620)
modelleri işlemcide saniyede ~4.5 kare çalıştırıyordu; hızlı araç tek
karede görülüyor ya da hiç görülmüyordu. Hız aracı 1.2 sahada ölçtü
(2026-11-11): üç model de GPU'da 96 ms/kare → ~10.5 kare/sn. İşlemcide
OpenVINO bu 8. nesil yongaya bir şey kazandırmıyor; kazanç GPU'da.

Kurallar:
  · Köprü ASLA düşmez, araç KAYBETMEZ. GPU açılamaz ya da öz sınamayı
    geçemezse modeller işlemcideki 1.4.1 kümesiyle (ORT-CPU + YOLOX-tiny)
    açılır; çalışırken bozulursa her oturum işlemciye geçer ve AYNI kare
    orada ölçülür (YedekliOturum; araç bulucuda arac.AracBulucu._yedege_gec).
  · Okuyucu f32: GPU'nun varsayılanı f16 okuyucunun olasılığını 0.007'ye
    kadar kaydırıyor (2026-11-12, bu bilgisayarın UHD'si) — 0.95 / 0.99
    eşiklerinin dibinde. Bulucular f16 (fark ≤ 0.003, iki kat hızlı).
  · Derlenmiş modeller önbelleğe yazılır (ilk açılış 10-20 sn, sonra kısa);
    önbellek yazılamazsa yalnızca açılış yavaşlar.
  · openvino_telemetry pakete girmez (paketle.py); OpenVINO onsuz çalışır
    ve modelleri dönüştürmediğimiz için zaten bir şey göndermez.
"""
from __future__ import annotations

import os
import threading
import time
from types import SimpleNamespace
from typing import Callable, NamedTuple

import arac
import gunluk
import plaka

CIHAZ = "GPU"


def onbellek_dizini() -> str:
    """Derlenmiş modellerin önbelleği — köprünün kayıt klasörünün yanında."""
    return os.path.join(os.environ.get("PROGRAMDATA", os.path.expanduser("~")),
                        "Otopark", "ov-onbellek")


def _ov_yukle():
    import openvino as ov
    return ov


def _hata(e: Exception) -> plaka.HizlandiriciHatasi:
    """OpenVINO'nun çok satırlı hatası → tek satırlık kayıt metni."""
    satirlar = str(e).strip().splitlines()
    return plaka.HizlandiriciHatasi(f"{type(e).__name__}: {satirlar[0] if satirlar else ''}")


class OvOturum:
    """
    onnxruntime oturumu gibi davranır (get_inputs / run): plaka ve arac
    hiçbir şey değiştirmeden kullanır. Her girdi şekli için bir kez derler.
    Her hata HizlandiriciHatasi'dir.
    """

    def __init__(self, core, yol: str, cihaz: str, hassas: bool,
                 sekiller: list[tuple] | None = None):
        self._core, self._yol, self._cihaz = core, yol, cihaz
        self._ayar = {"PERFORMANCE_HINT": "LATENCY"}
        if hassas:
            self._ayar["INFERENCE_PRECISION_HINT"] = "f32"
        try:
            model = core.read_model(yol)
            self._girdiler = [i.get_any_name() for i in model.inputs]
            self._ciktilar = [o.get_any_name() for o in model.outputs]
            self._derli: dict = {}
            if sekiller:
                for s in sekiller:
                    self._derle({self._girdiler[0]: tuple(s)})
            elif not any(i.get_partial_shape().is_dynamic for i in model.inputs):
                self._derle({i.get_any_name(): tuple(i.get_shape()) for i in model.inputs})
        except plaka.HizlandiriciHatasi:
            raise
        except Exception as e:  # noqa: BLE001
            raise _hata(e) from None

    @staticmethod
    def _anahtar(sekil: dict) -> tuple:
        return tuple(sorted((k, tuple(int(x) for x in v)) for k, v in sekil.items()))

    def _derle(self, sekil: dict):
        model = self._core.read_model(self._yol)
        if any(i.get_partial_shape().is_dynamic for i in model.inputs):
            model.reshape({k: list(v) for k, v in sekil.items()})
        derli = self._core.compile_model(model, self._cihaz, self._ayar)
        self._derli[self._anahtar(sekil)] = (derli, derli.create_infer_request())
        return self._derli[self._anahtar(sekil)]

    def get_inputs(self):
        return [SimpleNamespace(name=n) for n in self._girdiler]

    def hassasiyet(self) -> str:
        """Derlenmiş modelin çıkarım hassasiyeti: "f32" | "f16" (test ve kayıt için)."""
        derli = next(iter(self._derli.values()))[0]
        return "f32" if "32" in str(derli.get_property("INFERENCE_PRECISION_HINT")) else "f16"

    def run(self, adlar, girdiler: dict) -> list:
        try:
            anahtar = self._anahtar({k: v.shape for k, v in girdiler.items()})
            _derli, istek = self._derli.get(anahtar) or self._derle(
                {k: v.shape for k, v in girdiler.items()})
            istek.infer(girdiler)
            return [istek.get_tensor(n).data.copy() for n in (adlar or self._ciktilar)]
        except Exception as e:  # noqa: BLE001
            raise _hata(e) from None


DENEME = plaka.GPU_DENEME


class YedekliOturum:
    """
    Grafik işlemcisi oturumu + işlemci yedeği. GPU çağrısı bozulursa
    (HizlandiriciHatasi) DENEME kez denenir; hiçbiri olmazsa yedek açılır,
    kayda yazılır ve AYNI çağrı orada yapılır; sonraki çağrılar işlemcide.
    Başka hata yutulmaz.

    1.4.2: GpuGeriDonus yeni bir GPU oturumunu `gpu_ver` ile YAYIMLAR (kendi
    iş parçacığından); oturum onu kendi iş parçacığında, bir sonraki
    çağrının başında devralır. `birincil` None ise işlemcide başlar.
    """

    def __init__(self, birincil, yedek_ac: Callable, ad: str):
        self._gpu = birincil
        self._yedek_ac = yedek_ac
        self._cpu = None
        self._yeni = None
        self.ad = ad
        if birincil is None:
            self._cpu = yedek_ac()
        self._girdiler = (birincil or self._cpu).get_inputs()

    @property
    def yedekte(self) -> bool:
        """İşlemcide mi? Yayımlanmış ama henüz devralınmamış GPU 'dönmüş' sayılır."""
        return self._gpu is None and self._yeni is None

    def get_inputs(self):
        return self._girdiler

    def gpu_ver(self, oturum) -> None:
        """Öz sınamadan geçmiş yeni GPU oturumu (başka iş parçacığından)."""
        self._yeni = oturum

    def run(self, adlar, girdiler: dict) -> list:
        yeni = self._yeni
        if yeni is not None:
            self._yeni = None
            self._gpu = yeni
        if self._gpu is not None:
            son = None
            for _ in range(DENEME):
                try:
                    return self._gpu.run(adlar, girdiler)
                except plaka.HizlandiriciHatasi as e:
                    son = e
            self._gpu = None
            if self._cpu is None:
                self._cpu = self._yedek_ac()
            plaka.GPU_BIRAKILANLAR.append(self.ad)
            print(f"[!] {gunluk.GPU_BIRAKILDI_ISARETI}: {self.ad} ({son}) — {DENEME} denemede "
                  "olmadı, işlemcide sürüyor", flush=True)
        elif self._cpu is None:
            self._cpu = self._yedek_ac()
        return self._cpu.run(adlar, girdiler)


class GpuGeriDonus:
    """
    1.4.2 (sahibin isteği, 2026-11-13): grafik işlemcisi bir kez bozuldu diye
    köprü yeniden başlatılana kadar işlemcide kalmasın.

    Ana döngü her karede `tik()` çağırır (ucuz). Bir model işlemcideyse en çok
    GERI_DENE_SN'de bir, KISA ÖMÜRLÜ bir iş başlar: yeni OpenVINO çekirdeği,
    üç model, öz sınama YEDEKSİZ (plaka.yukle / arac.yukle). Geçerse yeni GPU
    oturumları YAYIMLANIR; her model onları kendi iş parçacığında, bir
    sonraki çağrısının başında devralır. Aynı anda tek iş; iş çökerse bir
    sonraki tik yenisini başlatır (uzun ömürlü iş parçacığı yok, sessizce
    ölüp denemeyi bitiremez). İlk derleme sahada 8-22 sn sürebilir: bu yüzden
    işçinin 30 sn'lik takılma bekçisinden ayrı bir iş parçacığında.

    YENIDEN_BASLAT_SN boyunca dönemezse (sürücü sıfırlanınca bu süreç GPU'yu
    hiç göremeyebilir) köprü sakin bir anda yeniden başlatılır — en çok
    YENIDEN_ARALIK_SN'de bir; zaman diske yazılır, yeni süreç de bilir.
    """

    def __init__(self, plakaci, bulucu, kume_ac: Callable | None = None,
                 ayar: dict | None = None, dizin: str | None = None,
                 hiz_ac: Callable | None = None, saat: Callable = time.monotonic,
                 duvar: Callable = time.time, kayit_dosyasi: str | None = None,
                 baslat: Callable | None = None):
        self._p = plakaci
        self._b = bulucu
        self._kume_ac = kume_ac or (lambda: _gpu_kumesi_ac(
            ayar or {}, dizin, hiz_ac or Hizlandirici.ac, bulucu is not None))
        self._saat = saat
        self._duvar = duvar
        self._dosya = kayit_dosyasi or os.path.join(
            os.environ.get("PROGRAMDATA", os.path.expanduser("~")), "Otopark",
            "gpu-yeniden-baslatma.txt")
        self._baslat = baslat or (lambda f: threading.Thread(
            target=f, daemon=True, name="gpu-geri").start())
        self.dene_sn = float(os.environ.get("GPU_GERI_DENE_SN", "30"))
        self.yeniden_sn = float(os.environ.get("GPU_YENIDEN_BASLAT_SN", "600"))
        self.aralik_sn = float(os.environ.get("GPU_YENIDEN_ARALIK_SN", "3600"))
        self._is = False
        self._son_deneme = float("-inf")
        self._son_neden = float("-inf")
        self._cpu_baslangic: float | None = None
        self.son_hata: str | None = None

    # -------------------------------------------------------------- durum --
    def _plaka_islemcide(self) -> bool:
        oturumlar = [getattr(self._p, a, None) for a in ("_bulucu", "_okuyucu")]
        return any(getattr(o, "yedekte", False) for o in oturumlar if o is not None)

    def _arac_islemcide(self) -> bool:
        return self._b is not None and not getattr(self._b, "gpu_da", True)

    def islemcide(self) -> bool:
        return self._plaka_islemcide() or self._arac_islemcide()

    def _dk(self) -> int:
        if self._cpu_baslangic is None:
            return 0
        return int((self._saat() - self._cpu_baslangic) // 60)

    def etiket(self, ad: str) -> str:
        """Kalp satırının küme adı: GPU'daysa `ad`, değilse ne kadardır işlemcide."""
        if self._arac_islemcide():
            return f"CPU · YOLOX-tiny (yedek, {self._dk()} dk)"
        if self._plaka_islemcide():
            return f"{ad} (plaka modelleri işlemcide, {self._dk()} dk)"
        return ad

    # ---------------------------------------------------------- deneme --
    def tik(self) -> None:
        """Ana döngüden, her karede. Gerekirse kısa ömürlü bir deneme başlatır."""
        simdi = self._saat()
        if not self.islemcide():
            self._cpu_baslangic = None
            return
        if self._cpu_baslangic is None:
            self._cpu_baslangic = simdi
        if self._is or simdi - self._son_deneme < self.dene_sn:
            return
        self._son_deneme = simdi
        self._is = True
        try:
            self._baslat(self._dene)
        except Exception:  # noqa: BLE001 — iş başlatılamadı: sonraki tik yine dener
            self._is = False

    def _dene(self) -> None:
        try:
            b, o, v = self._kume_ac()
            dk = self._dk()
            if self._p is not None:
                self._p._bulucu.gpu_ver(b)
                self._p._okuyucu.gpu_ver(o)
            if self._b is not None and v is not None:
                self._b.gpu_ver(*v)
            plaka.GPU_BIRAKILANLAR.clear()
            self._cpu_baslangic = None
            self.son_hata = None
            ad = f"GPU · {v[1].ad}" if v is not None else "GPU"
            print(f"[i] {gunluk.GPU_GERI_GELDI_ISARETI}: {ad} — işlemcide {dk} dk kaldı",
                  flush=True)
        except Exception as e:  # noqa: BLE001 — her hata: sonraki tikte yeniden
            self.son_hata = f"{type(e).__name__}: {e}" if not isinstance(
                e, (plaka.HizlandiriciHatasi, plaka.PlakaHatasi)) else str(e)
            simdi = self._saat()
            if simdi - self._son_neden >= NEDEN_KAYIT_SN:
                self._son_neden = simdi
                print(f"[!] {gunluk.GPU_HALA_YOK_ISARETI}: {self.son_hata} — işlemcide "
                      f"{self._dk()} dk; {self.dene_sn:g} sn'de bir deneniyor", flush=True)
        finally:
            self._is = False

    # ------------------------------------------------- yeniden başlatma --
    def _son_yeniden(self) -> float:
        try:
            with open(self._dosya, encoding="utf-8") as f:
                return float(f.read().strip())
        except (OSError, ValueError):
            return float("-inf")

    def yeniden_baslat_gerek(self) -> bool:
        """YENIDEN_BASLAT_SN'dir işlemcide ve son yeniden başlatma ARALIK'tan eski."""
        if not self.islemcide() or self._cpu_baslangic is None:
            return False
        if self._saat() - self._cpu_baslangic < self.yeniden_sn:
            return False
        return self._duvar() - self._son_yeniden() >= self.aralik_sn

    def yeniden_baslatiliyor(self) -> None:
        """Zamanı diske yazar (yeni süreç de bilsin). Hata yutulur."""
        try:
            os.makedirs(os.path.dirname(self._dosya), exist_ok=True)
            gecici = self._dosya + ".tmp"
            with open(gecici, "w", encoding="utf-8") as f:
                f.write(f"{self._duvar():.0f}")
            os.replace(gecici, self._dosya)
        except OSError:
            pass


# Geri dönüş denemesinin sebebi en çok bu sıklıkla kayda yazılır.
NEDEN_KAYIT_SN = 600


def _gpu_kumesi_ac(ayar: dict, dizin: str | None, hiz_ac: Callable, arac_iste: bool):
    """
    Yeni çekirdekle üç modeli GPU'da açar; öz sınamalar YEDEKSİZ (plaka.yukle
    / arac.yukle öyle koşar). (bulucu, okuyucu, (araç oturumu, profil)) —
    çıplak GPU oturumları; hata PlakaHatasi / HizlandiriciHatasi.
    """
    hiz = hiz_ac()
    p = plaka.yukle(ayar, dizin, hiz=hiz)
    v = None
    if arac_iste:
        b = arac.yukle(ayar, dizin, profil=arac_profili(ayar), hiz=hiz)
        v = (b._oturum, b.profil)
    return p._bulucu._gpu, p._okuyucu._gpu, v


def kalp_etiketi(ad: str) -> str:
    """Kalp satırındaki küme adı; çalışırken bırakılan GPU modelleri eklenir."""
    if not plaka.GPU_BIRAKILANLAR or not ad.startswith("GPU"):
        return ad
    return f"{ad} (bırakıldı: {', '.join(plaka.GPU_BIRAKILANLAR)} → işlemci)"


class Hizlandirici:
    """Açılmış OpenVINO çekirdeği; `oturum()` model başına bir OvOturum verir."""

    def __init__(self, core, cihaz: str):
        self._core = core
        self.cihaz = cihaz

    @classmethod
    def ac(cls, onbellek: str | None = None, cihaz: str = CIHAZ) -> "Hizlandirici":
        try:
            ov = _ov_yukle()
        except ImportError as e:
            raise plaka.HizlandiriciHatasi(f"openvino yüklenemedi: {e}") from None
        try:
            core = ov.Core()
            aygitlar = list(core.available_devices)
        except Exception as e:  # noqa: BLE001
            raise _hata(e) from None
        if cihaz not in aygitlar:
            raise plaka.HizlandiriciHatasi(
                f"grafik işlemcisi bulunamadı (aygıtlar: {', '.join(aygitlar) or 'yok'})")
        d = onbellek or onbellek_dizini()
        try:
            os.makedirs(d, exist_ok=True)
            core.set_property({"CACHE_DIR": d})
        except Exception:  # noqa: BLE001 — önbelleksiz yalnızca açılış yavaşlar
            pass
        return cls(core, cihaz)

    def oturum(self, yol: str, hassas: bool = False, sekiller: list[tuple] | None = None):
        """Grafik işlemcisi oturumu, YEDEKSİZ (öz sınama böyle koşar)."""
        return OvOturum(self._core, yol, self.cihaz, hassas, sekiller)

    @staticmethod
    def yedekli(birincil, yedek_ac: Callable, ad: str) -> "YedekliOturum":
        """Öz sınamayı geçmiş oturumu işlemci yedeğiyle sarar."""
        return YedekliOturum(birincil, yedek_ac, ad)


# ------------------------------------------------------------------ küme ---

class Kume(NamedTuple):
    """Yüklenen modeller: hangi kümede, neler çalışmıyor."""
    plakaci: object | None
    plaka_hata: str | None
    bulucu: object | None
    arac_hata: str | None
    ad: str                     # "GPU · YOLO11s" | "CPU · YOLOX-tiny" | "CPU · YOLOX-tiny (yedek)"
    gpu_hata: str | None        # GPU istendiği hâlde neden kullanılmadı


def arac_profili(ayar: dict) -> arac.Profil:
    """Grafik işlemcisindeki araç modeli (işlemci kümesi her zaman tiny)."""
    secim = ayar.get("arac_model", "otomatik")
    if secim == "yolo11s":
        return arac.YOLO11S
    if secim == "tiny":
        return arac.YOLOX_TINY
    return arac.YOLOX_TINY if arac.YOLO11S.yer_tutucu else arac.YOLO11S


def modelleri_yukle(ayar: dict, arac_iste: bool, dizin: str | None = None,
                    hiz_ac: Callable | None = None) -> Kume:
    """
    Önce grafik işlemcisi kümesi; okuyucu ya da bulucu orada açılamaz /
    öz sınamayı geçemezse HEPSİ işlemcide (1.4.1 kümesi). İşlemcide de
    açılmayan model 1.4.1'deki gibi: okuyucu yoksa bulucu da yüklenmez.
    """
    gpu_hata = None
    if ayar.get("hizlandirici", "GPU") == "GPU":
        profil = arac_profili(ayar)
        try:
            hiz = (hiz_ac or Hizlandirici.ac)()
            p = plaka.yukle(ayar, dizin, hiz=hiz)
            b = arac.yukle(ayar, dizin, profil=profil, hiz=hiz) if arac_iste else None
            k = Kume(p, None, b, None, f"GPU · {profil.ad}" if arac_iste else "GPU", None)
            print(f"[i] {gunluk.MODELLER_ISARETI}: {k.ad}", flush=True)
            return k
        except (plaka.HizlandiriciHatasi, plaka.PlakaHatasi) as e:
            gpu_hata = str(e)
            print(f"[!] {gunluk.GPU_YOK_ISARETI}: {gpu_hata} — modeller işlemcide (1.4.1 kümesi)",
                  flush=True)
    p = b = None
    p_hata = a_hata = None
    try:
        p = plaka.yukle(ayar, dizin)
    except plaka.PlakaHatasi as e:
        p_hata = str(e)
    if gpu_hata is not None and isinstance(p, plaka.Plakaci):
        # GPU istendi ama açılamadı: işlemci oturumları sarılır ki GpuGeriDonus
        # GPU'yu sonra getirebilsin (HIZLANDIRICI=CPU ise geri dönülecek yer yok).
        p._bulucu = YedekliOturum(None, lambda s=p._bulucu: s, "plaka bulucu")
        p._okuyucu = YedekliOturum(None, lambda s=p._okuyucu: s, "plaka okuyucu")
    if p is not None and arac_iste:
        try:
            b = arac.yukle(ayar, dizin)
        except plaka.PlakaHatasi as e:
            a_hata = str(e)
    ad = ("CPU · YOLOX-tiny" if arac_iste else "CPU") + (" (yedek)" if gpu_hata else "")
    print(f"[i] {gunluk.MODELLER_ISARETI}: {ad}", flush=True)
    return Kume(p, p_hata, b, a_hata, ad, gpu_hata)
