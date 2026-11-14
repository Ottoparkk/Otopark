# Hız testi (kamera bilgisayarı)

Salt ölçüm aracı: köprünün modellerini ve aday araç bulucuları **ORT-CPU**
(bugünkü köprü), **OpenVINO-CPU** ve **OpenVINO-GPU** (Intel yerleşik grafik)
ile ölçer, sonra köprünün gerçek işini (araç bulucu ile plaka işi aynı anda)
senaryolarla ölçer. Sahibe giden kullanım: `OKU-BENI.txt`. İçerik ve
lisanslar: `LISANS.txt`. Köprünün parçası değildir.

## Test

```
C:\Users\Lrx\otopark-hiz-venv\Scripts\python test_hiz_testi.py
```

Modeller `HIZ_MODELLER` klasöründen (varsayılan `C:\Users\Lrx\hiz-modeller\hazir`).
Testler: YOLOX ön işlemesi köprüyle birebir; her bulucu öz sınama resmindeki
aracı her yolda buluyor (≥ 0.50); GPU / dosya yoksa durmuyor; rapor tam.

## Ortam (depo dışında)

- `otopark-hiz-venv` (Python 3.14): `openvino==2026.4.1 onnxruntime==1.31.0
  numpy==2.3.4 opencv-python-headless==4.13.0.92 pyinstaller==6.22.3`.
- `otopark-donustur-venv`: yalnızca model çevirisi (torch 2.15 CPU,
  ultralytics 8.4.210 — analitik kapalı: `yolo settings sync=False`, onnx 1.23.2).

## Modeller (`hiz-modeller\hazir`, depoya girmez)

| Dosya | Nasıl |
|---|---|
| `yolox_tiny.onnx`, plaka modelleri, `arac_sinama.jpg` | köprünün `modeller\` klasöründen |
| `yolox_s_640.onnx` | YOLOX 0.1.1rc0 resmî sürümü, değiştirilmeden |
| `yolox_s_416.onnx` | aynı dosya; yalnızca girdi boyutu 416 (onnx shape_inference + checker) |
| `yolo11s_416/640.onnx` | resmî `yolo11s.pt` (assets v8.3.0) → ultralytics `export(format="onnx", imgsz=…, simplify=False)` |
| `dfine_n_416/640.onnx` | resmî `dfine_n_coco.pth` + D-FINE deposu (commit `956d170`), `export_onnx.py` adımları; `eval_spatial_size` 416/640, `remap_mscoco_category: False` (sınıf 0-79); 416'da hesaplanan `decoder.anchors/valid_mask` yeniden üretilir, öğrenilmiş ağırlıkların tamamı denetlenerek yüklenir |

SHA-256 değerleri `LISANS.txt`'de.

## Paket

```
cd tools\hiz-testi
C:\Users\Lrx\otopark-hiz-venv\Scripts\pyinstaller --noconfirm --distpath <çıktı>\dist --workpath <çıktı>\build OtoparkHizTesti.spec
```

Sonra `dist\OtoparkHizTesti\` içine `modeller\` (yukarıdaki dosyalar),
`OKU-BENI.txt`, `LISANS.txt`; ZIP'lenir. Spec, NPU eklentisini, ONNX / IR
dışındaki model okuyucularını, `.lib` / debug dosyalarını ve OpenCV video
kitaplığını dışarıda bırakır (436 → 285 MB).
