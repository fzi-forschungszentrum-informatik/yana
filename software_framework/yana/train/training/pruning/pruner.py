from typing import Dict, List, Optional, Union

import torch
import torch.nn as nn


def apply_pruning_masks(model: nn.Module) -> int:
    """Permanently apply any ``weight_mask`` buffers to their weights.

    Multiplies each module's ``weight`` by its ``weight_mask`` in place and
    removes the mask buffer, baking the sparsity into the weights. Returns the
    number of masks applied. Modules without a mask are left untouched.
    """
    num_applied = 0
    for module in model.modules():
        mask = getattr(module, "weight_mask", None)
        if mask is None or not hasattr(module, "weight"):
            continue
        with torch.no_grad():
            module.weight.mul_(mask.to(module.weight.dtype))    # type: ignore
        del module._buffers["weight_mask"]
        num_applied += 1
    return num_applied


class SimplePruner:
    """Magnitude-based pruner for ``torch.nn.Linear`` layers.

    Each managed layer gets a boolean ``weight_mask`` buffer.  At each pruning
    step the smallest-magnitude weights are selected per layer to reach the
    requested target sparsity, the corresponding weights are zeroed, and a
    gradient hook keeps those weights at zero during subsequent fine-tuning by
    masking out their gradients.
    """

    def __init__(self, model: Union[List[nn.Linear], nn.Module]):
        if isinstance(model, nn.Module):
            self.layers: List[nn.Linear] = [
                m for m in model.modules() if isinstance(m, nn.Linear)
            ]
        else:
            self.layers = list(model)

        for layer in self.layers:
            self._prepare_layer(layer)

    @staticmethod
    def _prepare_layer(layer: nn.Linear):
        """Attach a weight mask buffer and a gradient-masking hook."""
        if not hasattr(layer, "weight_mask") or layer.weight_mask is None:
            layer.register_buffer(
                "weight_mask",
                torch.ones_like(layer.weight, dtype=torch.bool),
            )
        if not getattr(layer, "_simple_prune_hook_registered", False):
            # Zero the gradient of pruned weights so the optimizer never revives them.
            layer.weight.register_hook(lambda grad, l=layer: grad * l.weight_mask)
            layer._simple_prune_hook_registered = True  # type: ignore

    def prune_to_sparsity(self, target_sparsity: float,
                          layer_indices: Optional[List[int]] = None) -> Dict:
        """Prune the selected layers to ``target_sparsity`` using weight magnitude.

        Pruning is monotonic: weights already pruned have magnitude zero and are
        therefore re-selected, so calling this with an increasing target sparsity
        progressively removes more connections.
        """
        if layer_indices is None:
            layer_indices = list(range(len(self.layers)))

        for idx in layer_indices:
            layer = self.layers[idx]
            weight_flat = layer.weight.detach().abs().view(-1)
            num_total = weight_flat.numel()
            num_to_prune = int(num_total * target_sparsity)

            mask = torch.ones(num_total, dtype=torch.bool, device=layer.weight.device)
            if num_to_prune > 0:
                prune_idxs = torch.topk(weight_flat, k=num_to_prune, largest=False).indices
                mask[prune_idxs] = False

            layer.weight_mask = mask.view_as(layer.weight)
            with torch.no_grad():
                layer.weight.mul_(layer.weight_mask)

        return self.get_sparsity_stats()

    def get_sparsity_stats(self) -> Dict:
        """Aggregate weight-level sparsity statistics across all managed layers."""
        total_weights = 0
        active_weights = 0
        layer_stats = []

        for layer in self.layers:
            layer_total = layer.weight.numel()
            layer_active = int(layer.weight_mask.sum().item())
            total_weights += layer_total
            active_weights += layer_active
            layer_stats.append({
                "total_weights": layer_total,
                "active_weights": layer_active,
                "weight_sparsity": 1.0 - (layer_active / max(layer_total, 1)),
            })

        return {
            "global_weight_sparsity": 1.0 - (active_weights / max(total_weights, 1)),
            "total_weights": total_weights,
            "active_weights": active_weights,
            "num_layers": len(self.layers),
            "layer_stats": layer_stats,
        }
