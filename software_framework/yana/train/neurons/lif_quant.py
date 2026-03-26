from dataclasses import dataclass
from typing import NamedTuple, Tuple
import torch

from qtorch import FixedPoint
from qtorch.quant import Quantizer

from norse.torch.module.snn import SNNCell
from norse.torch.functional.threshold import threshold


class LIFQuantFeedForwardState(NamedTuple):
    v: torch.Tensor
    v_saved: torch.Tensor
    t_since_activation: torch.Tensor


@dataclass
class LIFQuantParameters:
    tau_mem_inv_j: torch.Tensor = torch.as_tensor(0.0625, dtype=torch.float32)
    tau_mem_inv_l: torch.Tensor = torch.as_tensor(0.0625, dtype=torch.float32)
    v_leak: torch.Tensor = torch.as_tensor(0.0, dtype=torch.float32)  # should be 0
    v_th: torch.Tensor = torch.as_tensor(1.0, dtype=torch.float32)
    method: str = "super"
    alpha: float = torch.as_tensor(100.0, dtype=torch.float32)
    state_u_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")
    input_quantizer: Quantizer = Quantizer(FixedPoint(wl=16, fl=10), forward_rounding="floor", backward_rounding="floor")
    leak_factor_lut_quantizer: Quantizer = Quantizer(FixedPoint(wl=8 + 1, fl=8), forward_rounding="nearest", backward_rounding="nearest")  # lut is roundend using python round
    leak_factor_lut_length: torch.Tensor = torch.as_tensor(32)


def feed_forward_step(
    input_tensor: torch.Tensor,
    state: LIFQuantFeedForwardState,
    p: LIFQuantParameters,
    dt: float = 1.0,
) -> Tuple[torch.Tensor, LIFQuantFeedForwardState]:
    # quantize input
    input_tensor_q = p.input_quantizer(input_tensor)

    # use explicit decay formula instead of recursive formula
    t_since_activation = state.t_since_activation + dt

    leak_factor = torch.pow(1.0 - dt * p.tau_mem_inv_l, t_since_activation)
    leak_factor_q = p.leak_factor_lut_quantizer(leak_factor)

    # lut contains value for t_since_activation < leak_factor_lut_length else zero
    leak_factor_q = leak_factor_q * torch.lt(t_since_activation, p.leak_factor_lut_length).to(t_since_activation.dtype)

    # compute voltage updates (v_leak not supported)
    v_decayed = dt * p.tau_mem_inv_j * input_tensor_q + state.v_saved * leak_factor_q

    # alternative rounding here instead of at the end. would result in smaller threshold comparison logic
    # v_decayed = p.state_u_quantizer(v_decayed)

    # compute new spikes
    z_new = threshold(v_decayed - p.v_th, p.method, p.alpha)
    # compute reset,
    v_new = (1 - z_new) * v_decayed

    # quantize state
    v_new_q = p.state_u_quantizer(v_new)

    # input_tensor_q != 0 -> 1.0 else 0.0
    active_neurons = torch.ne(input_tensor_q, 0).to(input_tensor_q.dtype)

    # update state for active neurons
    v_saved_new = v_new_q * active_neurons + state.v_saved * (1 - active_neurons)

    # reset t_since_activation for active neurons
    t_since_activation_new = t_since_activation * (1 - active_neurons)

    return z_new, LIFQuantFeedForwardState(v=v_new_q, t_since_activation=t_since_activation_new, v_saved=v_saved_new)


class LIFQuantCell(SNNCell):
    def __init__(self, p: LIFQuantParameters = LIFQuantParameters(), **kwargs):
        super().__init__(
            activation=feed_forward_step,
            state_fallback=self.initial_state,
            p=p,
            **kwargs,
        )

    def initial_state(self, input_tensor: torch.Tensor) -> LIFQuantFeedForwardState:
        state = LIFQuantFeedForwardState(
            v=torch.full(
                input_tensor.shape,
                self.p.v_leak.detach(),
                device=input_tensor.device,
                dtype=input_tensor.dtype,
            ),
            v_saved=torch.full(
                input_tensor.shape,
                self.p.v_leak.detach(),
                device=input_tensor.device,
                dtype=input_tensor.dtype,
            ),
            t_since_activation=torch.zeros_like(input_tensor),
        )
        state.v_saved.requires_grad = True
        return state

    # make parameters movable between devices (dataclass)
    def _apply(self, fn):
        super()._apply(fn)
        for attr, value in self.p.__dict__.items():
            if torch.is_tensor(value):
                self.p.__dict__[attr] = fn(value)
        return self
