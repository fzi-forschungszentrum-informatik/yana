from functools import partial
from typing import List, Union
import numpy as np
import torch
import norse.torch as nt
from torch.nn.init import xavier_uniform_, normal_
from torch.nn.common_types import _size_2_t
from scipy import special

from yana.train.model.networks.base_network import BaseNetwork
from yana.train.config import NetworkCfg, LayerCfg
from yana.train.neurons import create_hidden_cell, create_output_cell
from yana.core.config import AcceleratorConfig

def initialize_weights(module: torch.nn.Module, gain: float):
    if isinstance(module, (torch.nn.Conv2d, torch.nn.Linear)):
        xavier_uniform_(module.weight, gain=gain)


class CustomSequentialState(BaseNetwork):
    def __init__(
        self,
        # General
        input_shape: List[int],
        output_features: int,
        enable_tracking: bool,
        network_cfg: NetworkCfg,
        accelerator_cfg: AcceleratorConfig
    ):
        super().__init__(
            input_shape=input_shape,
            output_features=output_features,
            enable_tracking=enable_tracking,
            network_cfg=network_cfg,
            accelerator_cfg=accelerator_cfg
        )
        self.dt = network_cfg.dt
        assert accelerator_cfg.core_config_hidden is not None, "Hidden core config required."
        self.quant_config_hidden = accelerator_cfg.core_config_hidden.quant_config
        self.quant_config_output = accelerator_cfg.core_config_output.quant_config

        self.layers = nt.SequentialState()

        network_cfg.layers = network_cfg.layers if network_cfg.layers is not None else []
        for layer_cfg in network_cfg.layers:
            layer = self.layer_from_cfg(layer_cfg)
            self.layers.append(layer)
            # norse bugfix: see pull request: https://github.com/norse/norse/pull/431
            if len(self.layers.stateful_layers) < len(self.layers):
                from norse.torch.utils.state import _is_module_stateful
                self.layers.stateful_layers.append(_is_module_stateful(layer))

        self.layers.return_hidden = True

        if network_cfg.weight_init_enable:
            match network_cfg.weight_init_type:
                case "custom":
                    # Scale deeper layer weights
                    if network_cfg.weight_init_gain != 1.0 or network_cfg.weight_init_gain_ramp != 0.0:
                        weight_multiplier = network_cfg.weight_init_gain
                        with torch.no_grad():
                            for layer in self.layers:
                                if hasattr(layer, 'weight') and layer.weight is not None:
                                    layer.weight *= weight_multiplier
                                    weight_multiplier += network_cfg.weight_init_gain_ramp
                case "xavier":
                    self.layers.apply(partial(initialize_weights, gain=network_cfg.weight_init_gain))
                case "micheli":
                    th_list = []
                    for layer in network_cfg.layers:
                        if layer.type == "create_hidden_cell":
                            th_list.append(layer.params["threshold"])
                    th_arr = np.array(th_list)
                    th_mean = float(np.mean(th_arr))
                    for layer in self.layers:
                        if isinstance(layer, (torch.nn.Conv2d, torch.nn.Linear)):
                            with torch.no_grad():
                                num_input_neurons = layer.weight.size(1)    # get number of neurons from previous layer
                             
                                p = 0.5 * special.erfc(th_mean / (np.sqrt(2)))
                                std_est = float(np.sqrt((1 / (p * num_input_neurons))))

                                normal_(layer.weight, mean=0, std=std_est)
                case _:
                    raise ValueError(f"Unknown weight initialization type: {network_cfg.weight_init_type}")

        # Spike Tracking
        if enable_tracking:
            self.register_forward_state_hooks([self.tracker.accumulate_spikes, self.tracker.accumulate_states])

    def layer_from_cfg(self, layer_cfg: LayerCfg) -> torch.nn.Module:
        layer = None
        try:
            match layer_cfg.type:
                case "Linear":
                    if 'in_features' not in layer_cfg.params or layer_cfg.params['in_features'] is None or layer_cfg.params['in_features'] == 'network_input_features':
                        # Compute input features from previous layer output size
                        layer_cfg.params['in_features'] = self.get_next_input_features()
                    if 'out_features' not in layer_cfg.params or layer_cfg.params['out_features'] is None or layer_cfg.params['out_features'] == 'network_output_features':
                        layer_cfg.params['out_features'] = self.output_features
                    layer = torch.nn.Linear(**layer_cfg.params)
                case "Conv2d":
                    if 'in_channels' not in layer_cfg.params or layer_cfg.params['in_channels'] is None or layer_cfg.params['in_channels'] == 'network_input_features':
                        layer_cfg.params['in_channels'] = self.get_next_input_features()
                    layer = torch.nn.Conv2d(**layer_cfg.params)
                case "hidden_cell" | "create_hidden_cell":
                    layer = create_hidden_cell(**layer_cfg.params, dt=self.dt, quant_config=self.quant_config_hidden)
                case "output_cell" | "create_output_cell":
                    layer = create_output_cell(**layer_cfg.params, dt=self.dt, quant_config=self.quant_config_output)
                case _:
                    # search for layer in torch.nn
                    if hasattr(torch.nn, layer_cfg.type):
                        layer_class = getattr(torch.nn, layer_cfg.type)
                        layer = layer_class(**layer_cfg.params if layer_cfg.params is not None else {})
                    elif hasattr(nt, layer_cfg.type):
                        layer_class = getattr(nt, layer_cfg.type)
                        layer = layer_class(**layer_cfg.params if layer_cfg.params is not None else {})
                    else:
                        raise ValueError(f"Unknown layer type: {layer_cfg.type}")
        except Exception as e:
            raise RuntimeError(f"[!] Failed to create Layer:\n\n{e}\n\nModel layers: {self.layers}\n\nLayer config: {layer_cfg}")
        return layer

    def _forward_for_tracing(self, x):
        return_hidden = self.layers.return_hidden
        self.layers.return_hidden = False
        try:
            outputs, self.states = self.layers(x, self.states)
        finally:
            self.layers.return_hidden = return_hidden
        return outputs

    def reset(self):
        super().reset()

    def get_next_input_features(self):
        input_features = None
        if self.layers is not None and len(self.layers) > 0:
            # Compute input channels from previous layer output size
            input_features = self._compute_output_shape(self.input_shape)
            print("input_features from previous layer:", input_features)
            if self.layers[-1].__class__ == torch.nn.Flatten:
                input_features = input_features.numel()
            else:
                input_features = input_features[1]
        else:
            input_features = self.input_shape[-1]
            print("input_features:", input_features)
        return input_features
