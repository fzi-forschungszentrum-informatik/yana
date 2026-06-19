import math

import torch

from qtorch.quant import Quantizer
from qtorch import FixedPoint

from norse.torch.functional.lif_box import LIFBoxParameters
from norse.torch.functional.leaky_integrator_box import LIBoxParameters
from norse.torch import LIFBoxCell, LIBoxCell

from .lif_quant import LIFQuantParameters, LIFQuantCell
from .li_quant import LIQuantParameters, LIQuantCell
from .if_quant import IFQuantParameters, IFQuantCell
from .i_quant import IQuantParameters, IQuantCell
from yana.core.config import QuantConfig, QuantScheme
from norse.torch.module.snn import SNNCell

#
# Utility functions
#

def next_power_of_2(x):
    x = int(x)
    return 1 if x == 0 else 2 ** (x - 1).bit_length()

def round_half_away_from_zero(n, decimals=0):
    def round_half_up(n, decimals=0):
        multiplier = 10**decimals
        return math.floor(n * multiplier + 0.5) / multiplier

    rounded_abs = round_half_up(abs(n), decimals)
    return math.copysign(rounded_abs, n)

# Round constants the same way as Verilog: "half away from zero"
def quant_constants(val, wl, fl):
    val = val * 2 ** (wl - 1)
    val = round_half_away_from_zero(val)

    val_min = (-(2 ** (wl - 1))) * 2 ** (wl - fl - 1)
    val_max = (2 ** (wl - 1) - 1) * 2 ** (wl - fl - 1)

    return max(min(val, val_max), val_min) / 2 ** (wl - 1)

def quant_const_unsigned(value, quant_scheme: QuantScheme):
    """Quantize a non-negative float to the given unsigned fixed-point scheme.

    Scales by 2**fl (the declared fractional-bit count), rounds half-away-from-zero,
    then clamps to [0, 2**wl - 1] raw integer space before converting back to float.
    """
    if value < 0:
        return 0.0

    scale = 2 ** quant_scheme.fraction_length
    raw = round_half_away_from_zero(value * scale)
    raw = max(0, min(raw, (1 << quant_scheme.word_length) - 1))
    return raw / scale

#
# Helper functions for neuron creation
#

def _create_quantizers(quant_config: QuantConfig) -> dict:
    """Create common quantizers for input and state.
    
    Args:
        quant_config: Quantization configuration
        
    Returns:
        Dictionary with 'input' and 'state' quantizers
    """
    input_quantizer = Quantizer(
        FixedPoint(wl=quant_config.format_weight_sum.word_length, fl=quant_config.format_weight_sum.fraction_length),
        forward_rounding="floor",
        backward_rounding="floor",
    )
    state_quantizer = Quantizer(
        FixedPoint(wl=quant_config.format_state.word_length, fl=quant_config.format_state.fraction_length),
        forward_rounding="floor",
        backward_rounding="floor",
    )
    return {'input': input_quantizer, 'state': state_quantizer}


def _create_leak_quantizer(quant_config: QuantConfig) -> Quantizer:
    """Create leak factor LUT quantizer for LIF/LI neurons.
    
    Args:
        quantconfig: Quantization configuration
        
    Returns:
        Quantizer configured for leak factor LUT
    """
    return Quantizer(
        FixedPoint(wl=quant_config.format_tau_inv_l.word_length + 1, fl=quant_config.format_tau_inv_l.fraction_length),
        forward_rounding="nearest",
    )


def _compute_lut_length(tau_inv_mem: float) -> int:
    """Compute LUT length for leak factor lookup table. It may vary compared to the accelerator's LUT length, but this shouldn't be a problem.
    
    Args:
        tau_inv_mem: Inverse membrane time constant
        
    Returns:
        LUT length as next power of 2
    """
    return next_power_of_2(1 / tau_inv_mem)

#
# Create neurons
#

def create_hidden_cell(
    neuron_type: str,
    tau_inv_mem: float,
    threshold: float,
    dt: float,
    quant_config: QuantConfig
) -> SNNCell:
    """Create a hidden (spiking) neuron cell.
    
    Args:
        neuron_type: Type of neuron ("lif_quant", "if_quant", "lif")
        tau_inv_mem: Inverse membrane time constant
        threshold: Spike threshold voltage
        dt: Timestep duration
        quant_options: Quantization configuration
        
    Returns:
        Configured neuron cell (LIF, IF, or variants)
        
    Raises:
        Exception: If neuron_type is not recognized
    """
    quantizers = _create_quantizers(quant_config)

    if neuron_type == "lif_quant":
        lut_length = _compute_lut_length(tau_inv_mem)
        leak_quantizer = _create_leak_quantizer(quant_config)

        p = LIFQuantParameters(
            tau_mem_inv_j=torch.as_tensor(quant_const_unsigned(tau_inv_mem, quant_config.format_tau_inv_j)),
            tau_mem_inv_l=torch.as_tensor(tau_inv_mem),
            v_th=torch.as_tensor(quant_const_unsigned(threshold, quant_config.format_threshold)),
            state_u_quantizer=quantizers["state"],
            input_quantizer=quantizers["input"],
            leak_factor_lut_quantizer=leak_quantizer,
            leak_factor_lut_length=torch.as_tensor(lut_length)
        )
        return LIFQuantCell(p=p, dt=dt)

    elif neuron_type == "if_quant":
        p = IFQuantParameters(
            v_th=torch.as_tensor(quant_const_unsigned(threshold, quant_config.format_threshold)),
            state_u_quantizer=quantizers["state"],
            input_quantizer=quantizers["input"]
        )
        return IFQuantCell(p=p, dt=dt)

    elif neuron_type == "lif":
        p = LIFBoxParameters(
            tau_mem_inv=torch.as_tensor(tau_inv_mem),
            v_th=torch.as_tensor(threshold),
        )
        return LIFBoxCell(p=p, dt=dt)
    else:
        raise Exception("Neuron type not recognized: {}".format(neuron_type))

def create_output_cell(
    neuron_type: str,
    tau_inv_mem: float,
    dt: float,
    quant_config: QuantConfig
) -> SNNCell:
    """Create an output (non-spiking integrator) neuron cell.
    
    Args:
        neuron_type: Type of neuron ("li_quant", "i_quant", "li")
        tau_inv_mem: Inverse membrane time constant
        dt: Timestep duration
        quant_options: Quantization configuration
        
    Returns:
        Configured neuron cell (LI, I, or variants)
        
    Raises:
        Exception: If neuron_type is not recognized
    """
    quantizers = _create_quantizers(quant_config)

    if neuron_type == "li_quant":
        lut_length = _compute_lut_length(tau_inv_mem)
        leak_quantizer = _create_leak_quantizer(quant_config)

        p = LIQuantParameters(
            tau_mem_inv_j=torch.as_tensor(quant_const_unsigned(tau_inv_mem, quant_config.format_tau_inv_j)),
            tau_mem_inv_l=torch.as_tensor(tau_inv_mem),
            state_u_quantizer=quantizers["state"],
            input_quantizer=quantizers["input"],
            leak_factor_lut_quantizer=leak_quantizer,
            leak_factor_lut_length=torch.as_tensor(lut_length)
        )
        return LIQuantCell(p=p, dt=dt)
    elif neuron_type == "i_quant":
        p = IQuantParameters(
            state_u_quantizer=quantizers["state"],
            input_quantizer=quantizers["input"]
        )
        return IQuantCell(p=p, dt=dt)
    elif neuron_type == "li":
        p = LIBoxParameters(
            tau_mem_inv=torch.as_tensor(tau_inv_mem),
        )
        return LIBoxCell(p=p, dt=dt)
    else:
        raise Exception("Neuron type not recognized: {}".format(neuron_type))
