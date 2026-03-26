import math

import torch

from qtorch.quant import Quantizer
from qtorch import FixedPoint

from yana.train.neurons.lif_quant import LIFQuantParameters, LIFQuantCell
from yana.train.neurons.li_quant import LIQuantParameters, LIQuantCell
from yana.core.quant_options import QuantOptions, QuantScheme

from norse.torch.functional.lif import LIFParameters
from norse.torch.functional.leaky_integrator import LIParameters
from norse.torch import LIFCell, LICell

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
    if value < 0:
        q = 0
    else:
        q = quant_constants(value, quant_scheme.wl + 1, quant_scheme.fl)

    return q


#
# Create neurons
#

def create_neuron_cells(
    # Neuron config
    neuron_type_hidden: str,
    neuron_type_out: str,
    tau_inv_mem_hidden: float,
    tau_inv_mem_output: float,
    threshold: float,
    dt: float,
    # Quantization
    quant_options: QuantOptions
):
    q_lut_length_leak_hidden = next_power_of_2(1 / tau_inv_mem_hidden)
    q_lut_length_leak_output = next_power_of_2(1 / tau_inv_mem_output)

    input_quantizer = Quantizer(
        FixedPoint(wl=quant_options.weight_sum_format.wl, fl=quant_options.weight_sum_format.fl),
        forward_rounding="floor",
        backward_rounding="floor",
    )
    state_quantizer = Quantizer(
        FixedPoint(wl=quant_options.state_format.wl, fl=quant_options.state_format.fl),
        forward_rounding="floor",
        backward_rounding="floor",
    )

    # lutsim specific
    leak_factor_lut_quantizer = Quantizer(
        FixedPoint(wl=quant_options.lut_ram_format.wl + 1, fl=quant_options.lut_ram_format.fl),
        forward_rounding="nearest",
    )

    if neuron_type_hidden == "lif_quant":
        p = LIFQuantParameters(
            tau_mem_inv_j=torch.as_tensor(quant_const_unsigned(tau_inv_mem_hidden, quant_options.tau_mem_inv_format)),
            tau_mem_inv_l=torch.as_tensor(tau_inv_mem_hidden),
            v_th=torch.as_tensor(quant_const_unsigned(threshold, quant_options.threshold_format)),
            state_u_quantizer=state_quantizer,
            input_quantizer=input_quantizer,
            leak_factor_lut_quantizer=leak_factor_lut_quantizer,
            leak_factor_lut_length=torch.as_tensor(q_lut_length_leak_hidden),
        )
        hidden_cell = LIFQuantCell(p=p, dt=dt)
    elif neuron_type_hidden == "lif":
        p = LIFParameters(
            tau_syn_inv=torch.as_tensor(tau_inv_mem_hidden),
            tau_mem_inv=torch.as_tensor(tau_inv_mem_hidden),
            v_th=torch.as_tensor(threshold),
        )
        hidden_cell = LIFCell(p=p, dt=dt)
    else:
        raise Exception("Neuron type not recognized: {}".format(neuron_type_hidden))

    if neuron_type_out == "li_quant":
        p = LIQuantParameters(
            tau_mem_inv_j=torch.as_tensor(quant_const_unsigned(tau_inv_mem_output, quant_options.tau_mem_inv_format)),
            tau_mem_inv_l=torch.as_tensor(tau_inv_mem_output),
            state_u_quantizer=state_quantizer,
            input_quantizer=input_quantizer,
            leak_factor_lut_quantizer=leak_factor_lut_quantizer,
            leak_factor_lut_length=torch.as_tensor(q_lut_length_leak_output),
        )
        output_cell = LIQuantCell(p=p, dt=dt)
    elif neuron_type_out == "li":
        p = LIParameters(
            tau_syn_inv=torch.as_tensor(tau_inv_mem_output),
            tau_mem_inv=torch.as_tensor(tau_inv_mem_output),
        )
        output_cell = LICell(p=p, dt=dt)
    else:
        raise Exception("Neuron type not recognized: {}".format(neuron_type_out))

    return hidden_cell, output_cell
