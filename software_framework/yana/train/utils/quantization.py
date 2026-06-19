import torch
from qtorch.quant import Quantizer
from qtorch import FixedPoint

def quantize_weights(model: torch.nn.Module, quant_wl: int, quant_fl: int):
    weight_quantizer = Quantizer(FixedPoint(wl=quant_wl, fl=quant_fl), forward_rounding="floor")

    quantized_weights = model.state_dict()
    for name, param in quantized_weights.items():
        if "weight" in name and param.is_floating_point():
            quantized_weights[name] = weight_quantizer(param)
    model.load_state_dict(quantized_weights)
