from dataclasses import dataclass
from typing import NamedTuple, Tuple
import torch

from qtorch import FixedPoint
from qtorch.quant import Quantizer

from norse.torch.module.snn import SNNCell
from norse.torch.functional.threshold import threshold


class IFQuantFeedForwardState(NamedTuple):
    v_saved: torch.Tensor

@dataclass
class IFQuantParameters:
    v_th: torch.Tensor = torch.as_tensor(1.0, dtype=torch.float32)
    method: str = "super"
    alpha: float = torch.as_tensor(100.0, dtype=torch.float32)
    input_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")
    state_u_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")


def feed_forward_step(
    input_tensor: torch.Tensor,
    state: IFQuantFeedForwardState,
    p: IFQuantParameters,
    dt: float = 1.0,
) -> Tuple[torch.Tensor, IFQuantFeedForwardState]:
    # quantize input
    input_tensor_q = p.input_quantizer(input_tensor)

    # compute voltage updates
    v_updated = input_tensor_q + state.v_saved

    # compute new spikes
    z_new = threshold(v_updated - p.v_th, p.method, p.alpha)
    # compute reset,
    v_new = (1 - z_new) * v_updated

    # quantize state
    v_new_q = p.state_u_quantizer(v_new)

    return z_new, IFQuantFeedForwardState(v_saved=v_new_q)



class IFQuantCell(SNNCell):
    def __init__(self, p: IFQuantParameters = IFQuantParameters(), **kwargs):
        super().__init__(
            activation=feed_forward_step,
            state_fallback=self.initial_state,
            p=p,
            **kwargs,
        )

    def initial_state(self, input_tensor: torch.Tensor) -> IFQuantFeedForwardState:
        state = IFQuantFeedForwardState(
            v_saved=torch.full(
                input_tensor.shape,
                0.0,
                device=input_tensor.device,
                dtype=input_tensor.dtype,
            )
        )
        state.v_saved.requires_grad = True
        return state
