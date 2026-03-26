import math
from typing import Dict, Union
from dataclasses import dataclass

from .quant_options import QuantScheme, scheme_from_config

def _ceiled_width(value: float) -> int:
    return math.ceil(math.log2(value))

@dataclass
class AcceleratorConfig:
    weight_quant_scheme: QuantScheme

    uram_data_width: int
    neurons_per_core: int
    synapses_per_core: int
    cores_per_accelerator: int
    routes_per_core: int

    #
    # General bit-widths
    #

    @property
    def core_id_bits(self):
        return _ceiled_width(self.cores_per_accelerator)

    @property
    def neuron_id_bits(self):
        return _ceiled_width(self.neurons_per_core)

    @property
    def synapse_id_bits(self):
        return _ceiled_width(self.synapses_per_core)

    #
    # Weight RAM bit-widths
    #

    @property
    def weight_width(self):
        return self.weight_quant_scheme.integer_bits + self.weight_quant_scheme.fractional_bits

    @property
    def weights_per_line(self):
        return self.uram_data_width // self.weight_width

    @property
    def weights_addr_width(self):
        return _ceiled_width(self.synapses_per_core / self.weights_per_line)

    #
    # Axon (mapping/routes) RAM bit-widths
    #

    @property
    def routes_entry_width(self):
        return self.core_id_bits + self.neuron_id_bits + self.synapse_id_bits

    @property
    def routes_per_line(self):
        return self.uram_data_width // self.routes_entry_width

    @property
    def routes_addr_width(self):
        return _ceiled_width(self.routes_per_core / self.routes_per_line)

    @property
    def mapping_base_address_width(self):
        return self.routes_addr_width

    @property
    def mapping_num_lines_width(self):
        return self.routes_addr_width

    @property
    def mapping_last_memory_line_width(self):
        return _ceiled_width(self.routes_per_line) + 1 if self.routes_per_line > 1 else 1

    @property
    def mapping_data_width(self):
        return self.routes_addr_width + self.mapping_num_lines_width + self.mapping_last_memory_line_width

    def print_all(self):
        for attr, value in self.__dict__.items():
            print(f"{attr}: {value}")

        for prop in dir(self):
            if isinstance(getattr(type(self), prop, None), property):
                print(f"{prop}: {getattr(self, prop)}")


def from_metadata(hardware_cfg: Dict, quant_scheme_weight: Union[Dict, QuantScheme]) -> AcceleratorConfig:
    return AcceleratorConfig(
        weight_quant_scheme=scheme_from_config(quant_scheme_weight["q_format_weights"]) if isinstance(quant_scheme_weight, Dict) else quant_scheme_weight,
        uram_data_width=hardware_cfg["memory"]["uram_data_width"],
        neurons_per_core=hardware_cfg["num_neurons_core"],
        synapses_per_core=hardware_cfg["num_synapses_core"],
        cores_per_accelerator=hardware_cfg["num_cores"],
        routes_per_core=hardware_cfg["num_routes_core"]
    )
