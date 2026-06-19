from typing import Callable, Dict, List, Optional, Tuple, Union, Any

import torch
import nir
import numpy as np
from tqdm import tqdm

from yana.deploy.fixed_point import FixedPoint
from yana.core.logging import info, verbose, trace, error, warn

from yana.core.config import AcceleratorConfig, CoreConfig

from .core import Core, Route
from .mapping import CoreMap
from .operator_graph import OperatorGraph, Operator


def _is_equal(value, other) -> bool:
    def _to_numpy(x):
        if isinstance(x, torch.Tensor):
            return x.detach().numpy()
        return np.asarray(x)
    return bool(np.all(_to_numpy(value) == _to_numpy(other)))

def _is_close(value: Union[torch.Tensor, np.ndarray, float], other: float, eps: float = 1e-3) -> bool:
    if isinstance(value, torch.Tensor):
        return bool(torch.all(torch.abs(value - other) <= eps))
    elif isinstance(value, np.ndarray):
        return bool(np.all(np.abs(value - other) <= eps))
    elif isinstance(value, float):
        return abs(value - other) <= eps
    else:
        raise ValueError("Only torch.Tensor, numpy.ndarray or float allowed.")

def _is_zero(value: Union[torch.Tensor, np.ndarray]) -> bool:
    return _is_equal(value, 0.0)

def _validate_neuron_params(neuron_node: Union[nir.LIF, nir.LI, nir.I], core: Core, fatal: bool):
    def _check(condition: bool, msg: str):
        if not condition:
            if fatal:
                raise ValueError(msg)
            else:
                error(msg)

    _check(_is_equal(neuron_node.r, 1.0), "Resistance must be 1.")

    if isinstance(neuron_node, (nir.LIF, nir.LI)):
        _check(_is_zero(neuron_node.v_leak), "Leak voltage must be 0.")
        _check(
            _is_close((1.0 / neuron_node.tau), core.tau_mem_inv.to_float()),
            f"Inverse tau does not match! Neuron node: "
            f"{1.0 / neuron_node.tau}, core config: {core.tau_mem_inv.to_float()}."
        )

        if isinstance(neuron_node, nir.LIF):
            _check(
                neuron_node.v_reset is not None and _is_zero(neuron_node.v_reset),
                "Reset voltage must be 0."
            )
            _check(
                _is_close(neuron_node.v_threshold, core.threshold.to_float()),
                f"Threshold does not match! Neuron node: "
                f"{neuron_node.v_threshold}, core config: {core.threshold.to_float()}."
            )


OpSequence = List[Union[type, Tuple[type, ...]]]

class Accelerator():
    # The core map is structured like the following:
    # {
        # "layer0": {0: 1, 1: 4, ...},
        # ...
    # }
    # It consists of layers as keys and dictionaries
    # as values. Those dictionaries map neurons to cores:
    #
    # "layer0": {0: 1, 1: 4, ...}
    # --> Neuron 0 of layer 0 is mapped to core 1, neuron
    #     1 in layer 0 is mapped to core 4, and so on.
    #
    # Note that the IDs of the neurons are local to the respective
    # layer, meaning that each layer has its own neuron '0'.
    core_map: CoreMap
    input_core: Core
    output_core: Core
    cores: Dict[int, Core]
    acc_config: AcceleratorConfig

    def __init__(
        self, nir_graph: nir.NIRGraph, acc_config: AcceleratorConfig,
        core_map: Optional[Union[str, Dict[str, Dict[int, int]]]] = None,
        constraints_fatal: bool = True,
        validate_neuron_params: bool = True
    ):
        self.acc_config = acc_config
        if core_map is None:
            # Naively map every layer onto the available cores derived from the
            # accelerator config: non-output layers go onto hidden cores, output
            # layers onto the output core.
            hidden_core_ids = [
                cid for cid, core_config in acc_config.core_configs.items()
                if core_config.type == CoreConfig.Type.HIDDEN
            ]
            output_core_id = next(
                cid for cid, core_config in acc_config.core_configs.items()
                if core_config.type == CoreConfig.Type.OUTPUT
            )
            self.core_map = CoreMap(nir_graph).generate_round_robin(hidden_core_ids, output_core_id)
        elif isinstance(core_map, Dict):
            self.core_map = CoreMap(nir_graph).from_dict(core_map)
        elif isinstance(core_map, str):
            self.core_map = CoreMap(nir_graph).from_json(core_map)
        else:
            raise ValueError(f"Core map must be of type str or Dict[str, Dict[int, int]], but got {type(core_map)} instead")

        self.constraints_fatal = constraints_fatal
        self.validate_neuron_params = validate_neuron_params

        # Validate configs
        self._validate_config_fit(nir_graph, self.acc_config, self.core_map)

        input_core = None
        output_core = None
        self.cores = {}

        for id, core_config in acc_config.core_configs.items():
            self.cores[id] = Core(id, core_config)
            # Populate input/output core
            if core_config.type == CoreConfig.Type.INPUT:
                assert input_core is None, "Only a single input core is allowed"
                input_core = self.cores[id]
            if core_config.type == CoreConfig.Type.OUTPUT:
                assert output_core is None, "Only a single output core is allowed"
                output_core = self.cores[id]

        assert input_core is not None, "Input core is required."
        assert output_core is not None, "Output core is required."
        self.input_core = input_core
        self.output_core = output_core

        # These are the node sequences supported by the accelerator
        self.VALID_SEQUENCES: List[Tuple[OpSequence, Callable[[List[Operator]], None]]] = [
            ([nir.Input], self._add_input),
            ([(nir.Affine, nir.Linear), (nir.LIF, nir.LI, nir.I)], self._add_linear),
            ([nir.Output], self._add_output)
        ]

        # Some assertions checking constraint of the accelerator/toolchain
        assert len(nir_graph.inputs) == 1, "Accelerator only supports single input graphs"
        assert len(nir_graph.outputs) == 1, "Accelerator only supports single output graphs"
        self.input_layer_id = list(nir_graph.inputs.keys())[0]

        # To have a better overview of the graph structure, we parse the
        # NIR graph into our own operator graph. It has a double linked
        # structure to enable structural analysis.
        op_graph = OperatorGraph(nir_graph)
        op_graph.parse_sequences(self._match_valid_sequence)

        # Validate that no core exceeds hardware resource limits
        self._validate_hardware_constraints(fatal=self.constraints_fatal)

    def run(
        self, input_events: List[Tuple[int, int]], num_timesteps: int,
        export_targets: List[int] = [], progressbar: bool = True
    ) -> Optional[Dict[int, Dict]]:
        assert len(input_events) > 0, "No input events given"

        # Trace inputs and outputs for selected export targets
        export_trace = {core_id: {} for core_id in export_targets}

        # Parse input events into map with timesteps as keys
        # and a list of source IDs as values
        input_events_map: Dict[int, List[int]] = {}
        for event_timestep, input_source_id in input_events:
            if event_timestep not in input_events_map:
                input_events_map[event_timestep] = []
            input_events_map[event_timestep].append(input_source_id)

        info("Simulating network...")

        for acc_timestep in tqdm(range(num_timesteps), disable=(not progressbar)):
            verbose(f"\nStarting Timestep {acc_timestep}")

            gen_spikes: Dict[int, List[Route]] = {}

            # Update step
            if acc_timestep in input_events_map:
                # 'input_source_id' is a layer-local ID and must
                # be transformed into a core-local ID 'source_id'.
                # If the source_id is -1, no downstream neuron is
                # connected to that input neuron. They should be ignored.
                source_ids = [
                    source_id
                    for input_source_id in input_events_map[acc_timestep]
                    if (source_id := self.input_core.get_core_local_id((self.input_layer_id, input_source_id))) != -1
                ]

                trace(f"\n  Processing input spikes: {source_ids}")
                gen_spikes_input = self.input_core.apply_update(acc_timestep, injected_spikes=source_ids)
                gen_spikes[self.input_core.id] = gen_spikes_input

                if self.input_core.id in export_trace:
                    export_trace[self.input_core.id][acc_timestep] = {
                        "input": source_ids,
                        "output": gen_spikes_input
                    }

            for id, core in self.cores.items():
                if core.config.type == CoreConfig.Type.INPUT:
                    continue
                verbose(f"\n  Updating core {id}")
                gen_spikes_core = core.apply_update(acc_timestep, force_update=(acc_timestep==num_timesteps-1))
                gen_spikes[id] = gen_spikes_core

            trace("\n  Dispatching spikes\n")
            # Spike dispatch step
            for core_spikes in gen_spikes.values():
                for spike in core_spikes:
                    assert spike.target_core in self.cores, f"Target core {spike.target_core} does not exist."
                    target_core = self.cores[spike.target_core]
                    target_core.apply_input(spike)

            if any(self.cores[core_id].config.type == CoreConfig.Type.HIDDEN for core_id in export_trace):  # Check if any hidden core should be traced
                # Find input spikes for cores
                inbound_spikes: Dict[int, List[Route]] = {}
                for core_spikes in gen_spikes.values():
                    for spike in core_spikes:
                        target_core = self.cores[spike.target_core]
                        if target_core.id not in inbound_spikes:
                            inbound_spikes[target_core.id] = []
                        inbound_spikes[target_core.id].append(spike)

                for core_id in export_trace:
                    # Skip input core, already handeled above
                    if self.cores[core_id].config.type == CoreConfig.Type.INPUT:
                        continue
                    export_trace[core_id][acc_timestep] = {
                        "input": inbound_spikes[core_id] if core_id in inbound_spikes else [],
                        "output": gen_spikes[core_id] if core_id in gen_spikes else []
                    }

        info("Simulation done.")

        if len(export_trace) > 0:
            return export_trace

    def get_output_states(self) ->  Dict[int, List[FixedPoint]]:
        output_states = getattr(self.output_core, "output_states", {})
        return output_states

    def reset(self):
        for core in self.cores.values():
            core.reset()

    def network_depth(self) -> Dict[int, int]:
        """Return the routing depth of each core: the longest non-recurrent path
        (in hops) from the input core.

        The accelerator updates every core in lock-step and dispatches the
        generated spikes afterwards, so a spike emitted by a core at timestep
        ``t`` only influences a downstream core's update at ``t + 1``. The depth
        therefore equals the timestep latency between a reference-model layer
        and the matching accelerator core.

        Recurrent routes (self-loops and feedback edges that close a cycle) do
        not advance the feed-forward propagation, so they must not count toward
        the hop length. This is achieved by only considering *simple* paths
        (paths that never revisit a core): any edge whose target already lies on
        the current path is a recurrent edge and is skipped. The depth of a core
        is the maximum length among all such simple paths reaching it, i.e. the
        longest feed-forward path from the input core.
        """
        # Forward adjacency, de-duplicated. Self-loops are recurrent by
        # definition and are excluded here.
        adjacency: Dict[int, set] = {}
        for core_id, core in self.cores.items():
            adjacency[core_id] = {
                route.target_core
                for routes in core.routes.values()
                for route in routes
                if route.target_core in self.cores and route.target_core != core_id
            }

        depths: Dict[int, int] = {}

        def visit(core_id: int, depth: int, on_path: set) -> None:
            if core_id not in depths or depth > depths[core_id]:
                depths[core_id] = depth
            for target in adjacency[core_id]:
                if target in on_path:
                    continue  # recurrent edge: would revisit a core on this path
                on_path.add(target)
                visit(target, depth + 1, on_path)
                on_path.discard(target)

        start = self.input_core.id
        visit(start, 0, {start})
        return depths

    def print_summary(self):
        print("\n" + "="*40)
        print("Accelerator Network Summary")
        print("="*40)
        print("\nCores:")
        for core_id, core in self.cores.items():
            print(f"  Mesh Core {core_id}:")
            print(f"    Type: {core.config.type.name}")
            print(f"    Neurons: {core.num_neurons()}")
            print(f"    Weights: {len(core.weights)}")
            print(f"    Routes: {sum(len(r) for r in core.routes.values())}")

        nx = self.acc_config.num_cores_x
        ny = self.acc_config.num_cores_y

        # Build per-core info: neuron count and layer names present
        core_info: Dict[int, Dict[str, Any]] = {}
        for core_id, core in self.cores.items():
            layers_present = sorted(set(
                global_id[0] for global_id in core.neuron_id_map.keys()
            ))
            core_info[core_id] = {
                "type": core.config.type.name,
                "neurons": core.num_neurons(),
                "layers": layers_present,
            }

        # Determine cell width based on content
        cell_lines: Dict[int, List[str]] = {}
        for core_id, info_dict in core_info.items():
            lines = [
                f"Core {core_id} ({info_dict['type']})",
                f"Neurons: {info_dict['neurons']}",
            ]
            if info_dict['layers']:
                lines.append("Layers:")
                for layer in info_dict['layers']:
                    lines.append(f"  {layer}")
            cell_lines[core_id] = lines

        # Fill missing cores (if any ID is not instantiated)
        for cid in range(nx * ny):
            if cid not in cell_lines:
                cell_lines[cid] = [f"Core {cid}", "(unused)"]

        cell_width = max(max(len(l) for l in lines) for lines in cell_lines.values()) + 2
        cell_height = max(len(lines) for lines in cell_lines.values())

        # Render grid (y=0 is top row)
        h_border = ("+" + "-" * cell_width) * nx + "+"
        print(f"\nNeuron Mapping ({nx}x{ny} core grid):\n")
        for y in range(ny):
            print(h_border)
            for row_line in range(cell_height):
                row_str = ""
                for x in range(nx):
                    core_id = y * nx + x
                    lines = cell_lines[core_id]
                    content = lines[row_line] if row_line < len(lines) else ""
                    row_str += "|" + f" {content}".ljust(cell_width)
                row_str += "|"
                print(row_str)
        print(h_border)
        print("=" * 40 + "\n")

    def _match_sequence(
        self, op_path: List[Operator],
        sequence_callbacks: List[Tuple[OpSequence, Callable[[List[Operator]], None]]],
        strict: bool = True
    ) -> bool:
        for seq_template, callback in sequence_callbacks:
            if strict:
                if len(op_path) != len(seq_template):
                    continue
                if all(isinstance(op.nir_node, node_type) for op, node_type in zip(op_path, seq_template)):
                    callback(op_path)
                    return True
            else:
                template_len = len(seq_template)
                for start_idx in range(len(op_path) - template_len + 1):
                    subseq = op_path[start_idx:start_idx + template_len]
                    if all(isinstance(op.nir_node, node_type) for op, node_type in zip(subseq, seq_template)):
                        callback(subseq)
                        return True
        return False

    def _match_valid_sequence(self, op_path: List[Operator]) -> bool:
        return self._match_sequence(op_path=op_path, sequence_callbacks=self.VALID_SEQUENCES)

    def _add_input(self, sequence: List[Operator]):
        info(f"Input sequence: {[op.name for op in sequence]}")
        input_op = sequence[0].nir_node
        assert isinstance(input_op, nir.Input)
        assert len(input_op.input_type) == 1, "Only one input tensor allowed."

    def _add_linear(self, sequence: List[Operator]):
        info(f"Linear sequence: {[op.name for op in sequence]}")
        lin_op = sequence[0]
        act_op = sequence[1]
        lin_node = lin_op.nir_node
        act_node = act_op.nir_node

        layer_name = act_op.name

        assert isinstance(lin_node, (nir.Linear, nir.Affine))
        if isinstance(lin_node, nir.Affine):
            assert _is_zero(lin_node.bias), "Bias is not allowed for Affine."
        assert isinstance(act_node, (nir.LIF, nir.LI, nir.I))

        if isinstance(lin_node.weight, torch.Tensor):
            weights = lin_node.weight.numpy()
        else:
            weights: np.ndarray = lin_node.weight

        assert len(lin_op.pre_ops) == 1, f"Only one predecessor allowed for node type {type(lin_node).__name__}"
        pre_op = lin_op.pre_ops[0]
        pre_node = pre_op.nir_node
        assert isinstance(pre_node, (nir.Input, nir.LIF)), (
            f"Only predecessors of type LIF or type Input allowed for node type "
            f"{type(lin_node).__name__}, found {type(pre_node).__name__} instead."
        )
        pre_layer_name = pre_op.name

        n_neurons = weights.shape[0]
        n_inputs = weights.shape[1]

        for i in range(n_neurons):
            global_id = (layer_name, i) # Global ID of neuron inside network graph

            # If there are no weights for entire neuron, skip neuron
            if np.all(weights[i] == 0.0):
                continue

            # Add neuron
            if isinstance(act_node, (nir.LI, nir.I)):
                core_id = self.output_core.id
            else:
                core_id = self.core_map[layer_name][i]
            core = self.cores[core_id]
            if self.validate_neuron_params:
                _validate_neuron_params(act_node, core, self.constraints_fatal)
            core_local_id = core.add_neuron(global_id)

            # Add synapses:
            # - Add weight to this core (or retrieve already present weight index)
            # - Add routes to cores of preceding neurons
            for j in range(n_inputs):
                if isinstance(pre_node, nir.Input):
                    pre_core = self.input_core
                else:
                    pre_core_id = self.core_map[pre_layer_name][j]
                    pre_core = self.cores[pre_core_id]

                # If pre_core is a non-input core and the neuron is not present, skip creation of synapse
                if pre_core.config.type != CoreConfig.Type.INPUT and pre_core.get_core_local_id((pre_layer_name, j)) == -1:
                    continue
                # If the weight would evaluate to 0 with the selected quantization, the returned synapse ID is -1
                synapse_id = core.add_weight(weights[i, j])
                if synapse_id != -1:
                    route = Route(core_id, core_local_id, synapse_id)
                    pre_global_id = (pre_layer_name, j)
                    pre_core.add_route(pre_global_id, route)

    def _add_output(self, sequence: List[Operator]):
        info(f"Output sequence: {[op.name for op in sequence]}")

    def _validate_config_fit(self, nir_graph: nir.NIRGraph, acc_config: AcceleratorConfig,
        core_map: CoreMap, fatal: bool = True) -> bool:
        """
        Verify that all configs fit together.
        1. Checks if the same layers are inside nir_graph and core_map.
        2. Checks if all neurons in one core have the same parameters (as all neurons need to be the same on one core)
        3. Checks if neurons in the nir_graph have the same parameters as specified in the acc_config.
            If not, the nir_graph params overwrite the acc_config.core_configs parameter.
        """
        ERROR_FLAG = False # TODO: unused
        def _check(condition: bool, msg: str):
            nonlocal ERROR_FLAG
            if not condition:
                if fatal:
                    raise ValueError(msg)
                else:
                    error(msg)
                    ERROR_FLAG = True

        VALID_LAYERS = (nir.LIF, nir.LI, nir.I)
        VALID_ATTRIBUTES = ['r', 'tau', 'v_leak', 'v_reset', 'v_threshold']

        nir_stateful_layers = {}
        for layer_name, layer in nir_graph.nodes.items():
            if isinstance(layer, VALID_LAYERS):
                nir_stateful_layers[layer_name] = layer

        # 1.
        _check(_is_equal(
            sorted(list(nir_stateful_layers.keys())), sorted(core_map.keys())
        ), f'Core map layers dont match Nir Graph layers:\n  Core map layers: {core_map.keys()}\n   Nir Graph layers: {list(nir_stateful_layers.keys())}')

        # 2.
        core_configs_from_cm_nir = {}  # {core_id: {param_name: value}}
        for layer_name, nir_layer in nir_stateful_layers.items():
            cm_layer = core_map[layer_name]
            for neuron_id, core_id in cm_layer.items():
                for p_name in dir(nir_layer):
                    if p_name not in VALID_ATTRIBUTES:
                        continue

                    new_val = (getattr(nir_layer, p_name).flatten())[neuron_id]
                    if core_id not in core_configs_from_cm_nir:
                        core_configs_from_cm_nir[core_id] = {}

                    if p_name not in core_configs_from_cm_nir[core_id]:
                        core_configs_from_cm_nir[core_id][p_name] = new_val
                    else:
                        prev_val = core_configs_from_cm_nir[core_id][p_name]
                        _check(_is_equal(prev_val, new_val), f'Not all neurons on core {core_id} are configured correctly. The error is thrown because \'{p_name}\' of neuron \'{neuron_id}\' in layer \'{layer_name}\' has a different value (new_val = {new_val}) than another neuron on the same core: pre_val = {prev_val}')

        # 3.
        def _compare_and_overwrite(obj: Any, attr: str, overwrite_val: Any, core_config_param_name: str):
            compare_val = getattr(obj, attr)
            if not _is_equal(compare_val, overwrite_val):
                warn(f"Warning: Overwriting {core_config_param_name} (= {compare_val}) with: {overwrite_val}")
                if isinstance(overwrite_val, np.generic):
                    overwrite_val = overwrite_val.item()
                setattr(obj, attr, overwrite_val)

        for core_id, config_cm_nir in core_configs_from_cm_nir.items():
            if 'r' in config_cm_nir:
                _check(_is_equal(config_cm_nir['r'], 1.0), f"The membrane resistance value 'r' must be set to 1.0 ('r' has a value of {config_cm_nir['r']}) because other values are not yet supported. Find the stateful Nir nodes in your NirGraph and ensure that they specify the 'r' parameter as 1.0.")
            if 'v_leak' in config_cm_nir:
                _check(_is_equal(config_cm_nir['v_leak'], 0.0), f"The leak potential 'v_leak' must be set to 0.0 ('v_leak' has a value of {config_cm_nir['v_leak']}) because other values are not yet supported. Find the stateful Nir nodes in your NirGraph and ensure that they specify the 'v_leak' parameter as 0.0.")

            tau_mem_inv  = 1/config_cm_nir['tau'] if 'tau' in config_cm_nir else None  # quantize?
            neuron_fires = 'v_reset' in config_cm_nir and 'v_threshold' in config_cm_nir
            reset_value  = config_cm_nir['v_reset']     if neuron_fires else None       # always 0.0?
            threshold    = config_cm_nir['v_threshold'] if neuron_fires else None       # quantize?

            if tau_mem_inv is not None:
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'leak_enabled', True,        f'acc_config.core_configs[{core_id}].neuron_config.leak_enabled')
                assert acc_config.core_configs[core_id].neuron_config.leak_lut_len != 0, f"Leak was enabled, because the layer in the nir graph is leaky. However, the leak lut length in the accelerator config is 0, which means the leak won't be applied. Please change your accelerator config for core {core_id}."
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'tau_mem_inv',  tau_mem_inv, f'acc_config.core_configs[{core_id}].neuron_config.tau_mem_inv')
            else:
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'leak_enabled', False,       f'acc_config.core_configs[{core_id}].neuron_config.leak_enabled')

            if neuron_fires:
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'emit_spikes',  True,        f'acc_config.core_configs[{core_id}].neuron_config.emit_spikes')
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'reset_value',  reset_value, f'acc_config.core_configs[{core_id}].neuron_config.reset_value')
                _compare_and_overwrite(acc_config.core_configs[core_id].neuron_config, 'threshold',    threshold,   f'acc_config.core_configs[{core_id}].neuron_config.threshold')

        # Only cores referenced by the core map were configured from the NIR graph above.
        # All hidden cores must share the same neuron configuration (see
        # AcceleratorConfig.core_config_hidden), so propagate the configuration derived for
        # the used hidden cores onto any unused hidden cores to keep that invariant intact.
        hidden_core_ids = [
            cid for cid, cc in acc_config.core_configs.items()
            if cc.type == CoreConfig.Type.HIDDEN
        ]
        used_hidden_ids = [cid for cid in hidden_core_ids if cid in core_configs_from_cm_nir]
        if used_hidden_ids:
            template_neuron_config = acc_config.core_configs[used_hidden_ids[0]].neuron_config
            for cid in hidden_core_ids:
                if cid not in core_configs_from_cm_nir:
                    acc_config.core_configs[cid].neuron_config = template_neuron_config.model_copy(deep=True)

        return ERROR_FLAG

    def _validate_hardware_constraints(self, fatal):
        """
        Check that no core exceeds the hardware resource limits defined in the
        accelerator config: neurons per core, weights (synapses) per core, and
        routes per core.
        """
        violations: List[str] = []

        for core_id, core in self.cores.items():
            n_neurons = core.num_neurons()
            n_weights = len(core.weights)
            n_routes  = sum(len(r) for r in core.routes.values())

            if n_neurons > self.acc_config.neurons_per_core:
                msg = f"Core {core_id}: neurons {n_neurons} > limit {self.acc_config.neurons_per_core}"
                if fatal:
                    raise ValueError(msg)
                else:
                    violations.append(msg)
            if n_weights > self.acc_config.weights_per_core:
                msg = f"Core {core_id}: weights {n_weights} > limit {self.acc_config.weights_per_core}"
                if fatal:
                    raise ValueError(msg)
                else:
                    violations.append(msg)
            if n_routes > self.acc_config.routes_per_core:
                msg = f"Core {core_id}: routes {n_routes} > limit {self.acc_config.routes_per_core}"
                if fatal:
                    raise ValueError(msg)
                else:
                    violations.append(msg)
        if len(violations) > 0:
            warn("Hardware violations detected.")
            for violation in violations:
                print(violation)
        else:
            info("Hardware constraint validation passed.")
