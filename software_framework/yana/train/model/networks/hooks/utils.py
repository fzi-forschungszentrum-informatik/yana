import torch
# TODO: add more hooks

def accumulated(accumulation_param, layer_name, value):
    if layer_name in accumulation_param:
        try:
            accumulation_param[layer_name] = torch.cat(
                [accumulation_param[layer_name], value.unsqueeze(0)], dim=0
            )
        except Exception as e:
            raise Exception(f"Failed to accumulate values for layer {layer_name}: {e}")
    else:
        if value is None:
            raise ValueError(f"Value to accumulate for layer {layer_name} is None.")
        accumulation_param[layer_name] = value.unsqueeze(0)
