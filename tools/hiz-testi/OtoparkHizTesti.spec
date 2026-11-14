# -*- mode: python ; coding: utf-8 -*-
# Hız testi paketi (PyInstaller onedir). Kullanım, bu klasörden:
#   <hiz-venv>\Scripts\pyinstaller --noconfirm OtoparkHizTesti.spec
# OpenVINO'nun tamamı toplanır (GPU / CPU eklentileri onun klasöründe), sonra
# bu araçta GEREKMEYENLER pakete hiç girmez: NPU (sahadaki dizüstünde yok,
# ~103 MB), ONNX / IR dışındaki model okuyucuları, bağlama (.lib) ve debug
# dosyaları, OpenCV'nin video kitaplığı (yalnızca tek bir resim okunur).
from PyInstaller.utils.hooks import collect_all

datas, binaries, hiddenimports = collect_all("openvino")

DISLA = (
    "openvino_intel_npu",
    "_frontend.lib", "openvino_gguf_frontend", "openvino_jax_frontend",
    "openvino_paddle_frontend", "openvino_pytorch_frontend",
    "openvino_tensorflow_frontend", "openvino_tensorflow_lite_frontend",
    "opencv_videoio_ffmpeg",
)


def _gerekli(ad: str) -> bool:
    k = ad.replace("\\", "/").lower()
    if k.endswith(".lib") or "_debug" in k:
        return False
    return not any(d in k for d in DISLA)


a = Analysis(
    ["hiz_testi.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "torch", "tensorflow"],
    noarchive=False,
)
a.binaries = [b for b in a.binaries if _gerekli(b[0])]
a.datas = [d for d in a.datas if _gerekli(d[0])]

pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="OtoparkHizTesti",
    debug=False,
    strip=False,
    upx=False,
    console=True,
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="OtoparkHizTesti")
