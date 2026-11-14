# -*- coding: utf-8 -*-
"""
Otopark — hız testi (kamera bilgisayarı için, salt ölçüm).

Köprünün modellerini ve aday araç bulucuları bu bilgisayarda üç yoldan
çalıştırıp süre ölçer:
  · ORT-CPU — köprünün bugün kullandığı onnxruntime, işlemcide;
  · OV-CPU  — Intel OpenVINO, işlemcide;
  · OV-GPU  — Intel OpenVINO, yerleşik grafik işlemcisinde (UHD 620 vb.).
Sonra köprünün GERÇEK işini taklit eden birleşik senaryoları ölçer: aynı
anda araç bulucu (bir iş parçacığı) + plaka bulucu ve okuyucu (öteki).

Hiçbir şey göndermez, köprüye ve ayarlara dokunmaz. Sonuç ekrana ve bu
programın yanındaki `hiz-sonuc.txt` dosyasına yazılır. Köprü çalışırken de
koşabilir (sayılar o zaman biraz düşük çıkar — ikisi aynı işlemciyi paylaşır).

Her bulucu, ölçülmeden önce köprünün öz sınama resmindeki ARACI bulmalı:
bozuk bir model hızlı ama anlamsız ölçülürdü (puan satırda yazar).
"""
from __future__ import annotations

import os
import platform
import statistics
import sys
import threading
import time
from datetime import datetime
from typing import Callable, NamedTuple

os.environ.setdefault("ORT_DISABLE_TELEMETRY", "1")   # köprüdeki gibi (plaka._ort_yukle)

import cv2  # noqa: E402
import numpy as np  # noqa: E402

for _a in (sys.stdout, sys.stderr):
    if _a is not None and hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

SINAMA_RESMI = "arac_sinama.jpg"
IPLIK = 3                    # sahadaki PLAKA_IPLIK
ARKALAR = ("ORT-CPU", "OV-CPU", "OV-GPU")
ARAC_SINIFLARI = (2, 3, 5, 7)   # COCO: araba, motosiklet, otobüs, kamyon (köprüyle aynı)
DOLGU = 114


class Model(NamedTuple):
    ad: str
    dosya: str
    tur: str          # yolox | yolo11 | dfine | plaka_bul | plaka_oku
    boyut: int


MODELLER = (
    Model("YOLOX-tiny 416", "yolox_tiny.onnx", "yolox", 416),        # bugünkü
    Model("YOLOX-s 416", "yolox_s_416.onnx", "yolox", 416),
    Model("YOLOX-s 640", "yolox_s_640.onnx", "yolox", 640),
    Model("YOLO11s 416", "yolo11s_416.onnx", "yolo11", 416),
    Model("YOLO11s 640", "yolo11s_640.onnx", "yolo11", 640),
    Model("D-FINE-N 416", "dfine_n_416.onnx", "dfine", 416),
    Model("D-FINE-N 640", "dfine_n_640.onnx", "dfine", 640),
    Model("Plaka bulucu 640", "yolo-v9-t-640-license-plates-end2end.onnx", "plaka_bul", 640),
    Model("Plaka okuyucu x2", "cct_s_v2_global.onnx", "plaka_oku", 0),
)
_MODEL = {m.ad: m for m in MODELLER}


class Senaryo(NamedTuple):
    ad: str
    arac: str          # model adı
    arac_arka: str
    bul_arka: str      # plaka bulucu
    oku_arka: str      # plaka okuyucu


# Kare süresini PLAKA işi belirler (bulucu + okuyucu sırayla); araç bulucu
# onunla aynı anda koşar. Bu yüzden büyük araç modelleri plaka işi en hızlı
# CPU yolundayken (OV-CPU) karşılaştırılır.
SENARYOLAR = (
    Senaryo("1) Bugünkü köprü (hepsi ORT-CPU)", "YOLOX-tiny 416", "ORT-CPU", "ORT-CPU", "ORT-CPU"),
    Senaryo("2) Hepsi OpenVINO-CPU (GPU'suz)", "YOLOX-tiny 416", "OV-CPU", "OV-CPU", "OV-CPU"),
    Senaryo("3) Araç GPU, plaka ORT-CPU", "YOLOX-tiny 416", "OV-GPU", "ORT-CPU", "ORT-CPU"),
    Senaryo("4) Araç GPU, plaka OV-CPU", "YOLOX-tiny 416", "OV-GPU", "OV-CPU", "OV-CPU"),
    Senaryo("5) Araç + plaka bulucu GPU, okuyucu OV-CPU", "YOLOX-tiny 416", "OV-GPU", "OV-GPU",
            "OV-CPU"),
    Senaryo("6) YOLOX-s 416 GPU, plaka OV-CPU", "YOLOX-s 416", "OV-GPU", "OV-CPU", "OV-CPU"),
    Senaryo("7) YOLO11s 416 GPU, plaka OV-CPU", "YOLO11s 416", "OV-GPU", "OV-CPU", "OV-CPU"),
    Senaryo("8) D-FINE-N 416 GPU, plaka OV-CPU", "D-FINE-N 416", "OV-GPU", "OV-CPU", "OV-CPU"),
    Senaryo("9) YOLOX-s 416, hepsi OV-CPU (GPU'suz)", "YOLOX-s 416", "OV-CPU", "OV-CPU", "OV-CPU"),
    # Büyük araç modeli + plaka bulucu İKİSİ BİRDEN GPU'da (GPU'yu paylaşırlar).
    Senaryo("10) YOLOX-s 416 + plaka bulucu GPU", "YOLOX-s 416", "OV-GPU", "OV-GPU", "OV-CPU"),
    Senaryo("11) YOLO11s 416 + plaka bulucu GPU", "YOLO11s 416", "OV-GPU", "OV-GPU", "OV-CPU"),
    Senaryo("12) D-FINE-N 416 + plaka bulucu GPU", "D-FINE-N 416", "OV-GPU", "OV-GPU", "OV-CPU"),
    # 1.2 (sahadaki ilk sonuçtan sonra, Latitude 5590): okuyucu CPU'da en yavaş
    # parça kaldı. İşi BÖLMEK: plaka işinin tamamı GPU'da, araç bulucu CPU'da.
    Senaryo("13) Araç ORT-CPU, plaka işi tümüyle GPU", "YOLOX-tiny 416", "ORT-CPU", "OV-GPU",
            "OV-GPU"),
    Senaryo("14) Hepsi GPU", "YOLOX-tiny 416", "OV-GPU", "OV-GPU", "OV-GPU"),
    Senaryo("15) D-FINE-N 416 OV-CPU, plaka işi GPU", "D-FINE-N 416", "OV-CPU", "OV-GPU",
            "OV-GPU"),
    Senaryo("16) YOLOX-s 416, hepsi GPU", "YOLOX-s 416", "OV-GPU", "OV-GPU", "OV-GPU"),
    Senaryo("17) D-FINE-N 416, hepsi GPU", "D-FINE-N 416", "OV-GPU", "OV-GPU", "OV-GPU"),
)


# OpenVINO önbellek klasörü; None = programın yanında "ov-onbellek" (testler
# Türkçe harfli bir klasör verir: sahadaki program da öyle bir yerde olabilir).
ONBELLEK: str | None = None


class Yok(Exception):
    """Çalıştırıcı ya da dosya yok — satır bunu yazar, araç sürer."""


# ------------------------------------------------------------ ön işleme ----

def yolox_hazirla(img: np.ndarray, n: int) -> tuple[np.ndarray, float]:
    """Köprünün arac.on_isle'si BİREBİR: BGR, 0-255, sol üste dolgulu."""
    h, w = img.shape[:2]
    r = min(n / h, n / w)
    yeni = cv2.resize(img, (int(w * r), int(h * r)), interpolation=cv2.INTER_LINEAR)
    tuval = np.full((n, n, 3), DOLGU, np.uint8)
    tuval[: yeni.shape[0], : yeni.shape[1]] = yeni
    return np.ascontiguousarray(tuval.transpose(2, 0, 1)[None], dtype=np.float32), r


def _rgb01(img: np.ndarray, n: int) -> tuple[np.ndarray, float]:
    """Ultralytics / plaka bulucu biçimi: RGB, 0-1, sol üste dolgulu (süre için yeter)."""
    x, r = yolox_hazirla(img, n)
    return np.ascontiguousarray(x[:, ::-1] / 255.0, dtype=np.float32), r


def girdiler(m: Model, img: np.ndarray, adlar: list[str]) -> dict:
    if m.tur == "yolox":
        return {adlar[0]: yolox_hazirla(img, m.boyut)[0]}
    if m.tur in ("yolo11", "plaka_bul"):
        return {adlar[0]: _rgb01(img, m.boyut)[0]}
    if m.tur == "dfine":
        # D-FINE'ın kendi onnx_inf.py'si: oranı koruyarak küçült + dolgu, RGB,
        # 0-1 (ToTensor), ek normalleştirme yok; ikinci girdi (yükseklik, en).
        boy = np.array([[m.boyut, m.boyut]], dtype=np.int64)
        return {adlar[0]: _rgb01(img, m.boyut)[0], adlar[1]: boy}
    if m.tur == "plaka_oku":
        h, w = img.shape[:2]
        parca = cv2.resize(img[h // 3: 2 * h // 3, w // 4: 3 * w // 4], (128, 64))[:, :, ::-1]
        return {adlar[0]: np.ascontiguousarray(np.stack([parca, parca]), dtype=np.uint8)}
    raise ValueError(m.tur)


# ------------------------------------------------------------- araç puanı --

def _yolox_puan(ham: np.ndarray, n: int) -> float:
    p = np.asarray(ham, dtype=np.float32).reshape(-1, 85)
    beklenen = sum((n // s) ** 2 for s in (8, 16, 32))
    if p.shape[0] != beklenen:
        raise ValueError(f"beklenmedik YOLOX çıktısı {np.shape(ham)}")
    return float((p[:, 4] * p[:, [5 + s for s in ARAC_SINIFLARI]].max(axis=1)).max())


def _yolo11_puan(ham: np.ndarray) -> float:
    p = np.asarray(ham, dtype=np.float32)[0]          # (84, N)
    return float(p[[4 + s for s in ARAC_SINIFLARI]].max())


def _dfine_puan(ciktilar: list) -> float:
    etiket, _kutu, puan = (np.asarray(c) for c in ciktilar[:3])
    araclar = np.isin(etiket.reshape(-1), ARAC_SINIFLARI)
    return float(puan.reshape(-1)[araclar].max()) if araclar.any() else 0.0


def puan_hesapla(m: Model, ciktilar: list) -> float | None:
    if m.tur == "yolox":
        return _yolox_puan(ciktilar[0], m.boyut)
    if m.tur == "yolo11":
        return _yolo11_puan(ciktilar[0])
    if m.tur == "dfine":
        return _dfine_puan(ciktilar)
    return None


# ----------------------------------------------------------- çalıştırıcı --

_OV = None


def _ov():
    global _OV
    if _OV is None:
        import openvino as ov
        _OV = ov.Core()
    return _OV


def ov_cihazlari() -> list[str]:
    try:
        return list(_ov().available_devices)
    except Exception:  # noqa: BLE001
        return []


def kullanilabilir_arkalar(cihazlar: list[str]) -> list[str]:
    out = ["ORT-CPU"]
    if "CPU" in cihazlar:
        out.append("OV-CPU")
    if "GPU" in cihazlar:
        out.append("OV-GPU")
    return out


class Calistirici:
    """Bir modeli bir yoldan çalıştırır: .adlar (girdi adları), .__call__(girdi) → çıktılar."""

    def __init__(self, yol: str, arka: str, cihazlar: list[str], ornek: Callable[[list], dict]):
        if not os.path.isfile(yol):
            raise Yok("dosya yok")
        self.arka = arka
        t0 = time.perf_counter()
        if arka == "ORT-CPU":
            import onnxruntime as ort
            try:
                ort.disable_telemetry_events()
            except Exception:  # noqa: BLE001
                pass
            so = ort.SessionOptions()           # köprünün oturum_ayarlari'sı
            so.intra_op_num_threads = IPLIK
            so.inter_op_num_threads = 1
            so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
            so.log_severity_level = 3
            so.add_session_config_entry("session.intra_op.allow_spinning", "0")
            self._s = ort.InferenceSession(yol, so, providers=["CPUExecutionProvider"])
            self.adlar = [i.name for i in self._s.get_inputs()]
            self._f = lambda g: self._s.run(None, g)
        else:
            cihaz = "CPU" if arka == "OV-CPU" else "GPU"
            if cihaz not in cihazlar:
                raise Yok(f"{cihaz} yok")
            core = _ov()
            model = core.read_model(yol)
            self.adlar = [i.get_any_name() for i in model.inputs]
            g = ornek(self.adlar)
            if any(i.get_partial_shape().is_dynamic for i in model.inputs):
                model.reshape({ad: list(v.shape) for ad, v in g.items()})
            ayar = {"PERFORMANCE_HINT": "LATENCY"}
            if cihaz == "CPU":
                ayar["INFERENCE_NUM_THREADS"] = IPLIK
            onbellek = ONBELLEK or os.path.join(_program_klasoru(), "ov-onbellek")
            os.makedirs(onbellek, exist_ok=True)
            core.set_property({"CACHE_DIR": onbellek})
            derli = core.compile_model(model, cihaz, ayar)
            istek = derli.create_infer_request()
            ciktilar = derli.outputs

            def _f(gir):
                istek.infer(gir)
                return [istek.get_tensor(o).data.copy() for o in ciktilar]
            self._f = _f
        self.yukleme_ms = (time.perf_counter() - t0) * 1000

    def __call__(self, girdi: dict) -> list:
        return self._f(girdi)


def _program_klasoru() -> str:
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def _resim(dizin: str) -> np.ndarray:
    # cv2.imread Windows'ta ASCII dışı yolu açamaz (sahada: C:\OtoparkKameraHız\…
    # → "bulunamadı"). Dosya Python ile okunur, OpenCV yalnızca çözer.
    yol = os.path.join(dizin, SINAMA_RESMI)
    try:
        img = cv2.imdecode(np.fromfile(yol, dtype=np.uint8), cv2.IMREAD_COLOR)
    except OSError:
        img = None
    if img is None:
        raise SystemExit(f"Öz sınama resmi bulunamadı: {os.path.join(dizin, SINAMA_RESMI)}")
    return img


def arac_puani(dizin: str, m: Model, arka: str, cihazlar: list[str] | None = None) -> float:
    """Testler için: modelin öz sınama resmindeki en yüksek araç puanı."""
    img = _resim(dizin)
    c = Calistirici(os.path.join(dizin, m.dosya), arka, cihazlar or ov_cihazlari(),
                    lambda adlar: girdiler(m, img, adlar))
    return puan_hesapla(m, c(girdiler(m, img, c.adlar)))


# ---------------------------------------------------------------- ölçüm --

def olc(f: Callable[[], object], n: int, isinma: int) -> list[float]:
    for _ in range(isinma):
        f()
    sureler = []
    for _ in range(n):
        t0 = time.perf_counter()
        f()
        sureler.append((time.perf_counter() - t0) * 1000)
    return sureler


def _p90(x: list[float]) -> float:
    s = sorted(x)
    return s[min(len(s) - 1, int(round(0.9 * (len(s) - 1))))]


def _senaryo(dizin: str, s: Senaryo, img, cihazlar, sure_sn: float) -> str:
    try:
        am = _MODEL[s.arac]
        bm, om = _MODEL["Plaka bulucu 640"], _MODEL["Plaka okuyucu x2"]
        a = Calistirici(os.path.join(dizin, am.dosya), s.arac_arka, cihazlar,
                        lambda ad: girdiler(am, img, ad))
        b = Calistirici(os.path.join(dizin, bm.dosya), s.bul_arka, cihazlar,
                        lambda ad: girdiler(bm, img, ad))
        o = Calistirici(os.path.join(dizin, om.dosya), s.oku_arka, cihazlar,
                        lambda ad: girdiler(om, img, ad))
    except Yok as e:
        return f"  {s.ad:46s} atlandı ({e})"
    ga, gb, go = girdiler(am, img, a.adlar), girdiler(bm, img, b.adlar), girdiler(om, img, o.adlar)
    # Isınma süreye göre: işlemci hızlanıp yavaşlarken ilk saniyeler yanıltır
    # (ilk ölçümde 4 sn'lik ortalamalar iki kat sapmıştı — ortanca kullanılır).
    isinma_bitis = time.perf_counter() + min(3.0, sure_sn / 4)
    while time.perf_counter() < isinma_bitis:
        a(ga), b(gb), o(go)
    kareler: list[float] = []
    ta: list[float] = []
    tb: list[float] = []
    to: list[float] = []
    bitis = time.perf_counter() + sure_sn
    while time.perf_counter() < bitis or not kareler:
        sonuc: dict = {}

        def is_a() -> None:
            t = time.perf_counter()
            a(ga)                                          # araç bulucu ...
            sonuc["a"] = (time.perf_counter() - t) * 1000

        t0 = time.perf_counter()
        th = threading.Thread(target=is_a)
        th.start()
        t = time.perf_counter()
        b(gb)                                              # ... ile aynı anda plaka işi
        tb.append((time.perf_counter() - t) * 1000)
        t = time.perf_counter()
        o(go)
        to.append((time.perf_counter() - t) * 1000)
        th.join()
        kareler.append((time.perf_counter() - t0) * 1000)
        ta.append(sonuc["a"])
    orta = statistics.median(kareler)
    m = statistics.median
    return (f"  {s.ad:44s} kare {orta:5.0f} ms  p90 {_p90(kareler):5.0f}  "
            f"→ {1000 / orta:4.1f} kare/sn   (araç {m(ta):4.0f} · bulucu {m(tb):4.0f} · "
            f"okuyucu {m(to):4.0f} ms; {len(kareler)} kare)")


def _islemci_adi() -> str:
    try:
        import winreg
        k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                           r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
        return str(winreg.QueryValueEx(k, "ProcessorNameString")[0]).strip()
    except Exception:  # noqa: BLE001
        return platform.processor() or "?"


def calistir(dizin: str, cihazlar: list[str] | None = None, n: int = 40, isinma: int = 5,
             senaryo_sn: float = 20.0, yaz: Callable[[str], None] = lambda s: None) -> str:
    cihazlar = ov_cihazlari() if cihazlar is None else list(cihazlar)
    img = _resim(dizin)
    satirlar: list[str] = []

    def ekle(s: str) -> None:
        satirlar.append(s)
        yaz(s)

    import onnxruntime as ort
    try:
        import openvino as ov
        ov_surum = ov.__version__
    except Exception:  # noqa: BLE001
        ov_surum = "yok"
    gpu = "yok"
    if "GPU" in cihazlar:
        try:
            gpu = str(_ov().get_property("GPU", "FULL_DEVICE_NAME"))
        except Exception:  # noqa: BLE001
            gpu = "var (adı okunamadı)"
    ekle(f"OTOPARK HIZ TESTİ — {datetime.now():%d.%m.%Y %H:%M}")
    ekle(f"İşlemci: {_islemci_adi()} · {os.cpu_count()} iş parçacığı · GPU: {gpu}")
    ekle(f"Sürümler: onnxruntime {ort.__version__} · openvino {ov_surum} · "
         f"iş parçacığı (CPU) {IPLIK} · tekrar {n}")
    ekle("")
    ekle("Tek tek modeller (ortanca süre; araç puanı = öz sınama resmindeki araç):")
    for m in MODELLER:
        for arka in ARKALAR:
            etiket = f"  {m.ad:18s} {arka:8s}"
            try:
                c = Calistirici(os.path.join(dizin, m.dosya), arka, cihazlar,
                                lambda adlar, m=m: girdiler(m, img, adlar))
            except Yok as e:
                ekle(f"{etiket} {e}" if str(e) == "dosya yok" else f"{etiket} {e} — atlandı")
                continue
            except Exception as e:  # noqa: BLE001
                ekle(f"{etiket} açılamadı: {type(e).__name__}: {str(e)[:120]}")
                continue
            g = girdiler(m, img, c.adlar)
            try:
                puan = puan_hesapla(m, c(g))
                sureler = olc(lambda: c(g), n, isinma)
            except Exception as e:  # noqa: BLE001
                ekle(f"{etiket} çalışmadı: {type(e).__name__}: {str(e)[:120]}")
                continue
            p = "" if puan is None else f"  araç {puan:.2f}"
            uyari = "  ← ARACI BULAMADI, sayı geçersiz" if puan is not None and puan < 0.5 else ""
            ekle(f"{etiket} {statistics.median(sureler):7.1f} ms  p90 {_p90(sureler):7.1f} ms  "
                 f"yükleme {c.yukleme_ms / 1000:5.1f} sn{p}{uyari}")
    ekle("")
    ekle(f"Birleşik senaryolar (köprünün gerçek işi: araç bulucu ile plaka işi AYNI ANDA, "
         f"her biri {senaryo_sn:.0f} sn):")
    for s in SENARYOLAR:
        ekle(_senaryo(dizin, s, img, cihazlar, senaryo_sn))
    return "\n".join(satirlar)


def main() -> int:
    klasor = _program_klasoru()
    dizin = os.path.join(klasor, "modeller")
    print("\n  Otopark hız testi — yaklaşık 12-15 dakika sürer. Bilgisayarı kullanmayın,")
    print("  prize takılı olsun. Hiçbir şey gönderilmez, köprüye dokunulmaz.\n")
    try:
        rapor = calistir(dizin, yaz=print)
    except SystemExit as e:
        print(f"\n  ✗ {e}")
        return 1
    yol = os.path.join(klasor, "hiz-sonuc.txt")
    with open(yol, "w", encoding="utf-8") as f:
        f.write(rapor + "\n")
    print(f"\n  ✓ Bitti. Sonuç: {yol}")
    print("    Bu dosyanın içeriğini Claude'a iletin.")
    return 0


if __name__ == "__main__":
    kod = main()
    if getattr(sys, "frozen", False):
        try:
            input("\n  Kapatmak için Enter'a basın… ")
        except Exception:  # noqa: BLE001
            pass
    sys.exit(kod)
