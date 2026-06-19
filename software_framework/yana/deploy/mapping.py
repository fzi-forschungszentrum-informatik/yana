
import json
from typing import Dict, List, Tuple, Union

import nir
import numpy as np

from .operator_graph import OperatorGraph

class CoreMap():
    def __init__(self, nir_graph: Union[nir.NIRGraph, str]):
        self.value = {}
        self.layer_cfg = {}

        # Parse NIR graph into layer configurations
        if isinstance(nir_graph, str):
            try:
                nir_graph = nir.read(nir_graph)
            except Exception as e:
                raise ValueError(f"Failed to read NIR graph from file: {e}")
        self.op_graph = OperatorGraph(nir_graph)
        self.neuron_layers, self.output_layers = self._extract_neuron_layers()

        for layer_name in self.neuron_layers:
            num_neurons = np.prod(next(iter(nir_graph.nodes[layer_name].output_type.values()))) # type: ignore
            layer_type = "output" if layer_name in self.output_layers else "hidden"
            self.layer_cfg[layer_name] = {
                "num_neurons": num_neurons, 
                "layer_type": layer_type
            }

    def from_dict(self, cm_dict: Dict[str, Dict[int, int]]) -> "CoreMap":
        for layer_name, layer in cm_dict.items():
            self.value[layer_name] = {int(neuron_id): core_id for neuron_id, core_id in layer.items()}
        return self

    def from_json(self, file: str) -> "CoreMap":
        with open(file, "r") as f:
            content = json.load(f)
        self.from_dict(content)
        return self

    def generate_round_robin(self, hidden_core_ids: List[int], output_core_id: int) -> "CoreMap":
        """
        Greedily map every layer onto the available cores using the layer
        information extracted from the NIR graph.

        Each non-output layer is assigned to a hidden core in round-robin order
        (cycling through `hidden_core_ids`), with all of its neurons placed on
        that single core. When there are more layers than hidden cores, multiple
        layers share a core. Output layers are mapped onto `output_core_id`.
        """
        if not hidden_core_ids:
            raise ValueError("No hidden cores available to map layers onto.")
        next_hidden = 0
        for layer_name, cfg in self.layer_cfg.items():
            if cfg["layer_type"] == "output":
                core_id = output_core_id
            else:
                core_id = hidden_core_ids[next_hidden % len(hidden_core_ids)]
                next_hidden += 1
            num_neurons = int(cfg["num_neurons"])
            self.value[layer_name] = {neuron_id: core_id for neuron_id in range(num_neurons)}
        return self

    def keys(self):
        return list(self.value.keys())

    def values(self):
        return list(self.value.values())

    def items(self):
        return list(self.value.items())

    def __iter__(self):
        return iter(self.value.items())
    
    def __getitem__(self, key):
        return self.value[key]
    
    def __call__(self):
        return self.value
    
    def __len__(self):
        return len(self.value)

    def _extract_neuron_layers(self) -> Tuple[List[str], List[str]]:
        NEURON_LAYERS = (nir.LIF, nir.IF, nir.LI, nir.I)

        neuron_layers = []
        output_layers = []

        for op in reversed(self.op_graph):
            if isinstance(op.nir_node, NEURON_LAYERS):
                neuron_layers.append(op.name)
                # If there are no downstream neuron nodes, add to output_layers
                has_downstream_neurons = any(
                    isinstance(downstream_op.nir_node, NEURON_LAYERS)
                    for downstream_op in self.op_graph.iter_from(op.post_ops)
                )
                if not has_downstream_neurons:
                    output_layers.append(op.name)

        return neuron_layers, output_layers
