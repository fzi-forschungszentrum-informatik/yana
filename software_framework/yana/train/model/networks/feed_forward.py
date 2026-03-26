from typing import Dict, List
import numpy as np
import torch
import pytorch_lightning as pl

from yana.train.neurons import create_neuron_cells
from yana.core.quant_options import options_from_config

class FeedForward(pl.LightningModule):
    def __init__(
        self,
        # General
        input_shape: List[int],
        output_features: int,
        enable_spikerate_tracking: bool,
        # Network architecture
        hidden_features: int,
        dropout_low: float,
        dropout_high: float,
        bias: bool,
        # Neuron config
        neuron_type_hidden: str,
        neuron_type_out: str,
        tau_inv_mem_hidden: float,
        tau_inv_mem_output: float,
        threshold: float,
        dt: float,
        quant_cfg: Dict
    ):
        super().__init__()

        # General setup
        self.input_shape = input_shape
        self.flattened_size = np.prod(self.input_shape).item()

        self.low_dropout = torch.nn.Dropout(p=dropout_low)
        self.high_dropout = torch.nn.Dropout(p=dropout_high)
        self.flatten = torch.nn.Flatten()

        quant_options = options_from_config(quant_cfg)

        self.layer_h_cell, self.layer_o_cell = create_neuron_cells(
            neuron_type_hidden,
            neuron_type_out,
            tau_inv_mem_hidden,
            tau_inv_mem_output,
            threshold,
            dt,
            quant_options
        )

        self.layer_h_fc = torch.nn.Linear(self.flattened_size, hidden_features, bias=bias)
        self.layer_o_fc = torch.nn.Linear(hidden_features, output_features, bias=bias)

        # Neuron states
        self.layer_h_cell_state = self.layer_o_cell_state = None

        # Accumulated spikes
        self.enable_spikerate_tracking = enable_spikerate_tracking
        self.accumulated_spikes = {}

    def accumulate_spikes(self, z, layer_name):
        if not self.enable_spikerate_tracking:
            return

        if layer_name in self.accumulated_spikes:
            self.accumulated_spikes[layer_name] += z
        else:
            self.accumulated_spikes[layer_name] = torch.clone(z)

    def forward(self, x):
        z = self.flatten(x)
        z = self.layer_h_fc(z)
        z, self.layer_h_cell_state = self.layer_h_cell(z, self.layer_h_cell_state)

        # Accumulate spikes of hidden layer
        self.accumulate_spikes(z, "layer_h_cell")

        # layer o
        z = self.low_dropout(z)
        z = self.layer_o_fc(z)
        z = self.high_dropout(z)
        z, self.layer_o_cell_state = self.layer_o_cell(z, self.layer_o_cell_state)
        return z

    def reset(self):
        self.layer_h_cell_state = self.layer_o_cell_state = None
        self.accumulated_spikes = {}
