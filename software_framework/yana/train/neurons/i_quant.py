from dataclasses import dataclass
from typing import NamedTuple, Tuple
import torch

from qtorch import FixedPoint
from qtorch.quant import Quantizer

from norse.torch.module.snn import SNNCell


class IQuantFeedForwardState(NamedTuple):
    v_saved: torch.Tensor

@dataclass
class IQuantParameters:
    input_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")
    state_u_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")


def feed_forward_step(
    input_tensor: torch.Tensor,
    state: IQuantFeedForwardState,
    p: IQuantParameters,
    dt: float = 1.0,
) -> Tuple[torch.Tensor, IQuantFeedForwardState]:
    # quantize input
    input_tensor_q = p.input_quantizer(input_tensor)

    # compute voltage updates
    v_updated = input_tensor_q + state.v_saved

    # quantize state
    v_new_q = p.state_u_quantizer(v_updated)

    return v_new_q, IQuantFeedForwardState(v_saved=v_new_q)



class IQuantCell(SNNCell):
    def __init__(self, p: IQuantParameters = IQuantParameters(), **kwargs):
        super().__init__(
            activation=feed_forward_step,
            state_fallback=self.initial_state,
            p=p,
            **kwargs,
        )

    def initial_state(self, input_tensor: torch.Tensor) -> IQuantFeedForwardState:
        state = IQuantFeedForwardState(
            v_saved=torch.full(
                input_tensor.shape,
                0.0,
                device=input_tensor.device,
                dtype=input_tensor.dtype,
            )
        )
        state.v_saved.requires_grad = True
        return state
