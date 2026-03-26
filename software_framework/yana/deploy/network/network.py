import copy
import os
from typing import List, Dict, Optional, Tuple
from enum import Enum
from tqdm import tqdm

import nir
import numpy as np

from .memory import MemLayout, WeightRam, AxonRam

from yana.deploy.fixed_point import FixedPoint, float_to_fixed_point, max_value, min_value
from yana.core.hardware_config import AcceleratorConfig
from yana.core.quant_options import QuantOptions
from yana.core.neuron_config import (
    TAU_MEM_INV_HIDDEN, LEAK_LUT_HIDDEN,
    TAU_MEM_INV_OUTPUT, LEAK_LUT_OUTPUT
)


class LogLevel(Enum):
    ERROR = 0
    WARNING = 1
    INFO = 2
    VERBOSE = 3
    TRACE = 4

LOG_LEVEL = LogLevel.ERROR

def log(*values: object, log_level: LogLevel):
    if log_level.value <= LOG_LEVEL.value:
        print(*values)

def error(*values: object):
    log(*values, log_level=LogLevel.ERROR)

def warn(*values: object):
    log(*values, log_level=LogLevel.WARNING)

def info(*values: object):
    log(*values, log_level=LogLevel.INFO)

def verbose(*values: object):
    log(*values, log_level=LogLevel.VERBOSE)

def trace(*values: object):
    log(*values, log_level=LogLevel.TRACE)


class Layer:
    def __init__(self, layer_weights: np.ndarray, quant_options: QuantOptions, tau_mem_inv: float, leak_lut: List[int], core_id: int, mem_id_offset: int):
        assert layer_weights.ndim == 2

        self.quant_opt = quant_options
        self.core_id = core_id

        # Layer variables
        self.weights: List[Dict[int, FixedPoint]] = []
        self.num_neurons = layer_weights.shape[0]
        self.input_size = layer_weights.shape[1]
        for weights_neuron in layer_weights:
            neuron_weights = {}
            for idx, weight_value in enumerate(weights_neuron):
                if weight_value != 0.0:
                    neuron_weights[idx] = float_to_fixed_point(weight_value, self.quant_opt.weight_format)
            self.weights.append(neuron_weights)

        self._toggle_ws = True
        self._weight_sums_a = [FixedPoint(0, self.quant_opt.weight_sum_format) for _ in range(self.num_neurons)]
        self._weight_sums_b = [FixedPoint(0, self.quant_opt.weight_sum_format) for _ in range(self.num_neurons)]
        self.states = [FixedPoint(0, self.quant_opt.state_format) for _ in range(self.num_neurons)]
        self.last_ts = [0 for _ in range(self.num_neurons)]
        self.memory_ids = list(range(mem_id_offset, mem_id_offset + self.num_neurons))

        # Constants
        self.tau_mem_inv = float_to_fixed_point(tau_mem_inv, self.quant_opt.tau_mem_inv_format)
        self.leak_lut = leak_lut
        self.neuron_state_max = max_value(self.quant_opt.state_format)
        self.neuron_state_min = min_value(self.quant_opt.state_format)

        verbose(f"tau_mem_inv:      {self.tau_mem_inv}")
        verbose(f"neuron_state_max: {self.neuron_state_max}")
        verbose(f"neuron_state_min: {self.neuron_state_min}")

    def update_mem_ids(self, mem_id_offset: int):
        self.memory_ids = list(range(mem_id_offset, mem_id_offset + self.num_neurons))

    def update_tau(self, tau_mem_inv: float, leak_lut: List[int]):
        self.tau_mem_inv = float_to_fixed_point(tau_mem_inv, self.quant_opt.tau_mem_inv_format)
        self.leak_lut = leak_lut
        verbose(f"tau_mem_inv: (u)  {self.tau_mem_inv}")

    def update_core_id(self, core_id: int):
        self.core_id = core_id

    def apply_input(self, source_id: int):
        trace(f"    Received Spike: source_id [{source_id}]")
        for neuron_id, neuron_weights in enumerate(self.weights):
            if source_id in neuron_weights:
                trace(f"      Applied weight: neuron_id [{neuron_id}], weight [{neuron_weights[source_id]}]")
                self.weight_sums_curr[neuron_id] += neuron_weights[source_id]
                self.weight_sums_curr[neuron_id] = self.weight_sums_curr[neuron_id].compressed(self.quant_opt.weight_sum_format)

    def apply_neuron_update(self, timestep: int, spike_threshold: Optional[FixedPoint], force_update: bool = False) -> Tuple[List[int], List[FixedPoint]]:
        spikes: List[int] = []

        for neuron_id in range(self.size):
            verbose(f"\n    Started neuron update for neuron_id [{neuron_id}]")
            # If no input has been received, skip neuron update
            if not force_update and self.weight_sums_prev[neuron_id].value == 0:
                verbose(f"      Weight sum is 0, skipping neuron update. Keeping previous state: {self.states[neuron_id]}")
                continue

            timestep_diff = timestep - self.last_ts[neuron_id]
            self.last_ts[neuron_id] = timestep

            verbose(f"      State before update:            {self.states[neuron_id]}")

            # Leak calculation
            if timestep_diff > len(self.leak_lut) - 1:
                self.states[neuron_id].value = 0
            else:
                leak_factor = FixedPoint(self.leak_lut[timestep_diff], self.quant_opt.lut_ram_format)
                if leak_factor.value > 0: # First entry in leak LUT (ts_diff = 0) is 0
                    self.states[neuron_id] *= leak_factor

            # Compute leaked input and update state
            verbose(f"      Leaked state:                   {self.states[neuron_id]}")
            verbose(f"      Weight sum:                     {self.weight_sums_prev[neuron_id]}")

            leaked_input = self.weight_sums_prev[neuron_id] * self.tau_mem_inv
            self.states[neuron_id] += leaked_input

            verbose(f"      Leaked input:                   {leaked_input}")
            verbose(f"      State after update:             {self.states[neuron_id]}")

            compressed_state = self.states[neuron_id].compressed(self.quant_opt.state_format)
            verbose(f"      Neuron state after compression: {self.states[neuron_id]}")

            if compressed_state < self.neuron_state_min:
                self.states[neuron_id] = self.neuron_state_min
                verbose(f"      Clipping neuron state to min:   {self.neuron_state_min}")
            else:
                if spike_threshold is not None:
                    if self.states[neuron_id] >= spike_threshold:
                        self.states[neuron_id] = float_to_fixed_point(0.0, self.quant_opt.state_format)
                        spikes.append(neuron_id)
                        verbose(f"      Neuron spiked, state reset to:  {self.states[neuron_id]}")
                    else:
                        self.states[neuron_id] = compressed_state
                else:
                    if compressed_state > self.neuron_state_max:
                        self.states[neuron_id] = self.neuron_state_max
                        verbose(f"      Clipping neuron state to max:   {self.neuron_state_max}")
                    else:
                        self.states[neuron_id] = compressed_state

        self._swap_weight_sums()
        return spikes, copy.deepcopy(self.states)


    def get_weight_mem_ids(self) -> List[List[int]]:
        return [list(neuron_weights.keys()) for neuron_weights in self.weights]


    def add_to_ram(self, axon_ram: AxonRam, weight_ram: WeightRam):
        # Write weights to RAM
        weight_ram.add_layer(self.weights)

        # Write routes to RAM
        for target_neuron_id in self.memory_ids:
            for source_neuron_id in range(self.input_size):
                weight_address = weight_ram.get_weight_address(source_neuron_id, target_neuron_id)
                if weight_address != -1:
                    axon_ram.add_route(source_neuron_id, self.core_id, target_neuron_id, weight_address)

    def _swap_weight_sums(self):
        self._toggle_ws = not self._toggle_ws
        self.weight_sums_curr = [FixedPoint(0, self.quant_opt.weight_sum_format) for _ in range(self.num_neurons)]


    @property
    def weight_sums_curr(self):
        return self._weight_sums_a if self._toggle_ws else self._weight_sums_b

    @weight_sums_curr.setter
    def weight_sums_curr(self, value):
        if self._toggle_ws:
            self._weight_sums_a = value
        else:
            self._weight_sums_b = value

    @property
    def weight_sums_prev(self):
        return self._weight_sums_b if self._toggle_ws else self._weight_sums_a

    @weight_sums_prev.setter
    def weight_sums_prev(self, value):
        if self._toggle_ws:
            self._weight_sums_b = value
        else:
            self._weight_sums_a = value

    @property
    def size(self):
        return self.num_neurons

    @property
    def num_synapses(self):
        num_synapses_sum = 0
        for neuron_weights in self.weights:
            num_synapses_sum += len(neuron_weights)
        return num_synapses_sum

    def __repr__(self):
        return f"Layer(num_neurons={self.num_neurons})"

    def reset(self):
        self._toggle_ws = True
        self._weight_sums_a = [FixedPoint(0, self.quant_opt.weight_sum_format) for _ in range(self.num_neurons)]
        self._weight_sums_b = [FixedPoint(0, self.quant_opt.weight_sum_format) for _ in range(self.num_neurons)]
        self.states = [FixedPoint(0, self.quant_opt.state_format) for _ in range(self.num_neurons)]
        self.last_ts = [0 for _ in range(self.num_neurons)]


class Network:
    def __init__(self, nir_graph: nir.NIRGraph, accelerator_config: AcceleratorConfig, quant_options: QuantOptions, log_level: LogLevel = LogLevel.INFO):
        global LOG_LEVEL
        LOG_LEVEL = log_level

        self.acc_cfg = accelerator_config
        self.quant_opt = quant_options

        # Some assertions checking constraint of the accelerator/toolchain
        assert len(nir_graph.inputs) == 1, "Too many inputs"
        assert len(nir_graph.outputs) == 1, "Too many outputs"

        # Traverse NIR graph
        # - Find all linear/affine layers and create Layer objects
        # - Check constraints
        ready = [edge for edge in nir_graph.edges if edge[0] in nir_graph.inputs.keys()]
        seen = set([edge[0] for edge in ready])

        self.input_size = 0
        self.hidden_layers: List[Layer] = []
        self.output_layer: Layer = None
        self.spike_threshold = None

        mem_id_offset = 0

        while len(ready) > 0:
            pre_key, post_key = ready.pop()
            pre_node = nir_graph.nodes[pre_key]
            post_node = nir_graph.nodes[post_key]

            if isinstance(post_node, (nir.Affine, nir.Linear)):
                # Assign input size from first Affine/Linear layer
                layer_weights = post_node.weight

                if self.input_size == 0:
                    self.input_size = layer_weights.shape[1]

                # Add previous output layer to layer list and reassign tau and ID offsets
                if self.output_layer is not None:
                    self.hidden_layers.append(self.output_layer)
                    mem_id_offset += self.output_layer.size

                self.output_layer = Layer(layer_weights, quant_options, TAU_MEM_INV_HIDDEN, LEAK_LUT_HIDDEN, core_id=0, mem_id_offset=mem_id_offset)

            elif isinstance(post_node, nir.ir.LI):
                assert isinstance(pre_node, (nir.Affine, nir.Linear)), f"Node of type {type(post_node)} must be preceded by Affine or Linear layer"
                assert post_node.r == 1.0
                assert post_node.v_leak == 0.0
                assert abs(post_node.tau - (1 / TAU_MEM_INV_OUTPUT)) < 1e-3, \
                    f"The node's tau ({post_node.tau}) does not match with the preset tau ({1 / TAU_MEM_INV_OUTPUT})"

            elif isinstance(post_node, nir.ir.LIF):
                assert isinstance(pre_node, (nir.Affine, nir.Linear)), f"Node of type {type(post_node)} must be preceded by Affine or Linear layer"
                assert post_node.r == 1.0
                assert post_node.v_leak == 0.0
                assert abs(post_node.tau - (1 / TAU_MEM_INV_HIDDEN)) < 1e-3, \
                    f"The node's tau ({post_node.tau}) does not match with the preset tau ({1 / TAU_MEM_INV_HIDDEN})"

                if self.spike_threshold is None:
                    self.spike_threshold = post_node.v_threshold
                assert self.spike_threshold == post_node.v_threshold, f"All LIF layers must have same threshold! 2 different found: {self.spike_threshold} != {post_node.v_threshold}"

            elif isinstance(post_node, nir.Output):
                assert isinstance(pre_node, nir.LI), f"Last neuron layer must be of type {nir.LI}"

            else:
                assert isinstance(post_node, nir.Flatten), f"Node type not allowed: {type(post_node)}"

            seen.add(post_key)
            ready += [e for e in nir_graph.edges if e[0] == post_key and e[1] not in seen]

        # Update output layer after graph traversal has finished
        self.output_layer.update_mem_ids(mem_id_offset=0)
        self.output_layer.update_tau(TAU_MEM_INV_OUTPUT, LEAK_LUT_OUTPUT)
        self.output_layer.update_core_id(1)

        assert len(self.hidden_layers) > 0, "At least one hidden layer must be present"
        assert self.output_layer is not None, "No output layer found"

        hidden_synapses_sum = 0
        for layer in self.hidden_layers:
            hidden_synapses_sum += layer.num_synapses
        assert hidden_synapses_sum <= self.acc_cfg.synapses_per_core, f"Too many synapses in hidden core. Allowed: [{self.acc_cfg.synapses_per_core}], actual: [{hidden_synapses_sum}]"
        assert self.output_layer.num_synapses <= self.acc_cfg.synapses_per_core, f"Too many synapses in output core. Allowed: [{self.acc_cfg.synapses_per_core}], actual: [{self.output_layer.num_synapses}]"


    def simulate(self, input_events: List[Tuple[int, int]], num_timesteps: int, progressbar: bool = True) -> List[List[FixedPoint]]:
        assert len(input_events) > 0, "No input events given"

        output_states: List[List[FixedPoint]] = []
        spike_threshold = float_to_fixed_point(self.spike_threshold, self.quant_opt.threshold_format)

        info("Simulating network...")

        for timestep in tqdm(range(num_timesteps), disable=(not progressbar)):
            verbose(f"\nStarting Timestep {timestep}")
            # Process input events
            for event_timestep, source_id in input_events:
                if event_timestep == timestep:
                    self.hidden_layers[0].apply_input(source_id)
                elif event_timestep > timestep:
                    break

            # Update neuron states and propagate generated spikes
            all_layers = [*self.hidden_layers, self.output_layer]
            for layer_idx, layer in enumerate(all_layers):
                verbose(f"\n  Starting update for Layer [{layer_idx}]")
                spikes, neuron_states = layer.apply_neuron_update(
                    timestep,
                    spike_threshold if layer is not self.output_layer else None,
                    force_update=(timestep == num_timesteps-1)
                )
                if layer is self.output_layer:
                    output_states.append(neuron_states)
                else:
                    for output_spike in spikes:
                        all_layers[layer_idx+1].apply_input(output_spike)

        info("Simulation done.")

        verbose("\nOutput States:")
        for ts, output_states_ts in enumerate(output_states):
            formatted_states = ", ".join(f"{state.to_float():{15}}" for state in output_states_ts)
            verbose(f"{ts:3}: [{formatted_states}]")

        return output_states


    def generate_mem_files(self, output_directory: str, print_util: bool = False):
        os.makedirs(output_directory, exist_ok=True)

        # Output files
        weights_hidden_file = os.path.join(output_directory, "mem_weights_hidden.txt")
        weights_output_file = os.path.join(output_directory, "mem_weights_output.txt")
        mapping_input_file = os.path.join(output_directory, "mem_mapping_input.txt")
        routing_input_file = os.path.join(output_directory, "mem_routing_input.txt")
        mapping_hidden_file = os.path.join(output_directory, "mem_mapping_hidden.txt")
        routing_hidden_file = os.path.join(output_directory, "mem_routing_hidden.txt")

        axon_input_ram = AxonRam(mapping_input_file, routing_input_file, self.acc_cfg)
        axon_hidden_ram = AxonRam(mapping_hidden_file, routing_hidden_file, self.acc_cfg)
        weights_hidden_ram = WeightRam(weights_hidden_file, self.acc_cfg, mem_layout=MemLayout.WEIGHT_REUSE)
        weights_output_ram = WeightRam(weights_output_file, self.acc_cfg, mem_layout=MemLayout.WEIGHT_REUSE)

        # Write layers to RAM
        self.hidden_layers[0].add_to_ram(axon_input_ram, weights_hidden_ram)
        self.output_layer.add_to_ram(axon_hidden_ram, weights_output_ram)

        axon_input_ram.write()
        axon_hidden_ram.write()
        weights_hidden_ram.write()
        weights_output_ram.write()

        # Close the RAM files
        axon_input_ram.close()
        axon_hidden_ram.close()
        weights_hidden_ram.close()
        weights_output_ram.close()

        # Print out utilization information
        if print_util:
            print(f"------ Utilization report ------")
            print(f"| Hidden weights: {100*weights_hidden_ram.utilization:9.2f}%   |")
            print(f"| Output weights: {100*weights_output_ram.utilization:9.2f}%   |")
            print(f"| Input routing:  {100*axon_input_ram.utilization:9.2f}%   |")
            print(f"| Hidden routing: {100*axon_hidden_ram.utilization:9.2f}%   |")
            print(f"--------------------------------")


    def reset(self):
        for layer in self.hidden_layers:
            layer.reset()
        self.output_layer.reset()
