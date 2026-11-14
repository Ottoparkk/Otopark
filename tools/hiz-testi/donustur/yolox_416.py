# Official yolox_s.onnx (640) -> same weights at 416 input, by editing only the
# graph's input/output shapes; verified with onnx.checker + ORT on a real image.
import sys

import onnx
from onnx import shape_inference

src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
d = m.graph.input[0].type.tensor_type.shape.dim
print("önce:", [x.dim_value for x in d], [o.name for o in m.graph.output])
d[2].dim_value = 416
d[3].dim_value = 416
for o in m.graph.output:              # let inference recompute the output shape
    o.type.tensor_type.ClearField("shape")
m.graph.ClearField("value_info")      # stale 640-sized intermediate shapes
m = shape_inference.infer_shapes(m)
onnx.checker.check_model(m)
onnx.save(m, dst)
print("sonra:", [x.dim_value for x in m.graph.input[0].type.tensor_type.shape.dim],
      [[x.dim_value for x in o.type.tensor_type.shape.dim] for o in m.graph.output])
