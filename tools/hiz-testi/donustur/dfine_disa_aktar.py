# D-FINE-N -> ONNX, same steps as the official tools/deployment/export_onnx.py
# (commit 956d1709): YAMLConfig, HGNetv2 pretrained=False, load the "ema"
# state, model.deploy() + postprocessor.deploy(), opset 16, onnx checker.
# Differences, both via the config the authors' README names for other sizes:
#   eval_spatial_size = [N, N]  (their example uses 320; we need 416 and 640)
#   remap_mscoco_category = False  (labels 0-79, car = 2, as the bridge counts)
# and batch fixed to 1 (their dummy batch of 32 only matters for dynamic axes).
import os
import sys

import torch
import torch.nn as nn

DEPO, AGIRLIK, BOYUT, CIKTI = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, DEPO)
from src.core import YAMLConfig  # noqa: E402

cfg = YAMLConfig(os.path.join(DEPO, "configs/dfine/dfine_hgnetv2_n_coco.yml"),
                 resume=AGIRLIK, eval_spatial_size=[BOYUT, BOYUT],
                 remap_mscoco_category=False)
if "HGNetv2" in cfg.yaml_cfg:
    cfg.yaml_cfg["HGNetv2"]["pretrained"] = False
durum = torch.load(AGIRLIK, map_location="cpu")
durum = durum["ema"]["module"] if "ema" in durum else durum["model"]
# decoder.anchors / decoder.valid_mask are NOT learned: the decoder computes
# them from eval_spatial_size (_generate_anchors, a grid of start boxes). The
# checkpoint stores the 640 grid; for another size the model's own freshly
# generated grid must stay. Everything learned is loaded and checked.
HESAPLANAN = {"decoder.anchors", "decoder.valid_mask"}
if BOYUT != 640:
    durum = {k: v for k, v in durum.items() if k not in HESAPLANAN}
sonuc = cfg.model.load_state_dict(durum, strict=False)
eksik = set(sonuc.missing_keys) - (HESAPLANAN if BOYUT != 640 else set())
if eksik or sonuc.unexpected_keys:
    raise SystemExit(f"beklenmeyen ağırlık farkı: eksik {eksik}, fazla {sonuc.unexpected_keys}")


class Model(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.model = cfg.model.deploy()
        self.postprocessor = cfg.postprocessor.deploy()

    def forward(self, images, orig_target_sizes):
        return self.postprocessor(self.model(images), orig_target_sizes)


model = Model().eval()
veri = torch.rand(1, 3, BOYUT, BOYUT)
boy = torch.tensor([[BOYUT, BOYUT]])
with torch.no_grad():
    _ = model(veri, boy)
    torch.onnx.export(model, (veri, boy), CIKTI, input_names=["images", "orig_target_sizes"],
                      output_names=["labels", "boxes", "scores"], opset_version=16,
                      do_constant_folding=True, dynamo=False)
import onnx  # noqa: E402

onnx.checker.check_model(onnx.load(CIKTI))
print("tamam", CIKTI, os.path.getsize(CIKTI), "bayt")
