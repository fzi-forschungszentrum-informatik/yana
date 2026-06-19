from typing import Callable, Dict, Optional, Union
from pathlib import Path
from contextlib import nullcontext

import numpy as np
import torch

import nir
from nir.ir.typing import Edges
from nir.ir.utils import calculate_conv_output, calc_flatten_output
from nirtorch import nir_to_torch

from norse.torch.utils.export_nir import to_nir

from yana.train.neurons import create_hidden_cell, create_output_cell
from yana.train.neurons.lif_quant import LIFQuantCell
from yana.train.neurons.li_quant import LIQuantCell
from yana.train.neurons.i_quant import IQuantCell
from yana.train.neurons.if_quant import IFQuantCell

from yana.train.utils import TraceInterface

from yana.core.config import QuantConfig


##################
### NIR export ###
##################


def _custom_norse_to_nir_mapping_dict(dt=1.0) -> Dict[torch.nn.Module, Callable[[torch.nn.Module], nir.NIRNode]]:
    custom_norse_map = {}

    #
    # Custom export
    #

    def _map_lif_quant(module: LIFQuantCell):
        return nir.LIF(
            tau=dt/module.p.tau_mem_inv_l.detach().numpy(),
            r=np.ones_like(module.p.v_leak.detach().numpy()),
            v_leak=module.p.v_leak.detach().numpy(),
            v_threshold=module.p.v_th.detach().numpy(),
            v_reset=np.zeros_like(module.p.v_leak.detach().numpy()),
            metadata={"type": "lif_quant"}
        )

    custom_norse_map[LIFQuantCell] = _map_lif_quant

    def _map_li_quant(module: LIQuantCell):
        return nir.LI(
            tau=dt/module.p.tau_mem_inv_l.detach().numpy(),
            r=np.ones_like(module.p.v_leak.detach().numpy()),
            v_leak=module.p.v_leak.detach().numpy(),
            metadata={"type": "li_quant"}
        )

    custom_norse_map[LIQuantCell] = _map_li_quant

    def _map_i_quant(_: IQuantCell):
        return nir.I(
            r=np.array(1.0),
            metadata={"type": "i_quant"}
        )

    custom_norse_map[IQuantCell] = _map_i_quant

    def _map_if_quant(module: IFQuantCell):
        return nir.IF(
            r=np.ones_like(module.p.v_th.detach().numpy()),
            v_threshold=module.p.v_th.detach().numpy(),
            v_reset=np.zeros_like(module.p.v_th.detach().numpy()),
            metadata={"type": "if_quant"}
        )

    custom_norse_map[IFQuantCell] = _map_if_quant

    #
    # Custom bypasses
    #

    def _map_none(_):
        return None

    custom_norse_map |= {
        torch.nn.Dropout: _map_none,
        torch.nn.Identity: _map_none
    }

    return custom_norse_map

custom_stateful_modules = {
    LIFQuantCell, LIQuantCell,
    IQuantCell, IFQuantCell
}

# FIXME: make this cleaner (or fix the upstream inference in NIR)
def _infer_types(nir_graph: nir.NIRGraph):
    if not nir_graph.nodes:
        return

    # Ensure all graph inputs flow through an Input node
    all_node_keys = set(nir_graph.nodes.keys())
    destination_nodes = {edge[1] for edge in nir_graph.edges}
    root_nodes = all_node_keys - destination_nodes

    new_nodes: Dict[str, nir.NIRNode] = {}
    new_edges: Edges = []

    for node_key in root_nodes:
        node = nir_graph.nodes[node_key]
        if not isinstance(node, nir.Input):
            # This is a root node that is not an Input node.
            # It must have its input_type defined to create a preceding Input node.
            undef_input_type = node.input_type is None or any(
                v is None or len(v) == 0 for v in node.input_type.values()
            )
            if undef_input_type:
                raise ValueError(
                    f"Root node '{node_key}' of type {type(node).__name__} is not an "
                    f"Input node and has no defined input_type. Cannot infer graph input."
                )

            # Prepend an Input node
            input_node_name = f"input_{node_key}"
            i = 0
            original_name = input_node_name
            while input_node_name in nir_graph.nodes or input_node_name in new_nodes:
                input_node_name = f"{original_name}_{i}"
                i += 1

            new_input_node = nir.Input(input_type=node.input_type)
            new_nodes[input_node_name] = new_input_node
            new_edges.append((input_node_name, node_key))
        else:
            undef_input_type = node.input_type is None or any(
                v is None or len(v) == 0 for v in node.input_type.values()
            )
            if undef_input_type:
                raise ValueError(
                    f"Input node '{node_key}' has no defined input_type. Cannot infer graph without input types."
                )

    if new_nodes:
        nir_graph.nodes.update(new_nodes)
        nir_graph.edges.extend(new_edges)

    # Start type inference from input nodes
    ready = [e for e in nir_graph.edges if e[0] in nir_graph.inputs.keys()]
    if len(ready) == 0:
        raise ValueError(
            "Failed to start type inference: No input nodes found. "
            "This may be due to a cyclic dependency at the graph's input. "
            "Please add an `Input` node manually to define an entry point, "
            "or disable type checking (`type_check=False`)."
        )

    seen = set([e[0] for e in ready])
    while len(ready) > 0:
        pre_key, post_key = ready.pop()
        pre_node = nir_graph.nodes[pre_key]
        post_node = nir_graph.nodes[post_key]

        if isinstance(post_node, nir.NIRGraph):
            post_node.infer_types()

        # check if post input_type needs to be defined
        undef_post_input_type = post_node.input_type is None or any(
            v is None or len(v) == 0 for v in post_node.input_type.values()
        )
        type_mismatch = any(
            [
                len(post_node.input_type) != len(pre_node.output_type),
                not np.array_equal(
                    np.array(list(pre_node.output_type.values())),
                    np.array(list(post_node.input_type.values())),
                ),
            ]
        )
        if undef_post_input_type:
            # define post input_type to be the same as pre output_type
            post_node.input_type = {
                k.replace("output", "input"): v
                for k, v in pre_node.output_type.items()
            }
        elif type_mismatch:
            # set post input_type to be the same as pre output_type
            pre_repr = (
                f"{pre_key}.output: {np.array(list(pre_node.output_type.values()))}"
            )
            post_repr = (
                f"{post_key}.input: {np.array(list(post_node.input_type.values()))}"
            )
            raise ValueError(
                f"Type inference error: type mismatch: {pre_repr} -> {post_repr}"
            )

        # make sure that output nodes have output_type = input_type
        if isinstance(post_node, nir.Output):
            post_node.output_type = {
                k.replace("input", "output"): v
                for k, v in post_node.input_type.items()
            }

        # check if post output_type needs to be defined
        undef_post_output_type = post_node.output_type is None or any(
            v is None or len(v) == 0 for v in post_node.output_type.values()
        )
        if undef_post_output_type:
            # define post output_type
            if isinstance(post_node, nir.Conv1d) or isinstance(post_node, nir.Conv2d):
                if isinstance(post_node, nir.Conv1d):
                    post_node.input_shape = post_node.input_type["input"][1]
                else:
                    post_node.input_shape = tuple(post_node.input_type["input"][1:])
                output_shape = calculate_conv_output(
                    post_node.input_shape,
                    post_node.padding,
                    post_node.dilation,
                    post_node.weight.shape[2],
                    post_node.stride,
                )
                output_type = np.array([post_node.weight.shape[0], *output_shape])
                post_node.output_type = {"output": output_type}

            elif isinstance(post_node, nir.SumPool2d):
                output_shape = calculate_conv_output(
                    pre_node.output_type["output"][1:],
                    post_node.padding,
                    1,
                    post_node.kernel_size,
                    post_node.stride,
                )
                output_type = np.array(
                    [post_node.input_type["input"][0], *output_shape]
                )
                post_node.output_type = {"output": output_type}

            elif isinstance(post_node, nir.AvgPool2d):
                output_shape = calculate_conv_output(
                    pre_node.output_type["output"][1:],
                    post_node.padding,
                    1,
                    post_node.kernel_size,
                    post_node.stride,
                )
                output_type = np.array(
                    [post_node.input_type["input"][0], *output_shape]
                )
                post_node.output_type = {"output": output_type}

            elif isinstance(post_node, nir.Flatten):
                # The Flatten node usually skips one dimension and starts at dimension 1.
                # This is because the batch dimension is not being flattened. However, in
                # this case, the batch dimension is not included in the input/output shapes.
                post_node.output_type = {
                    "output": calc_flatten_output(
                        post_node.input_type["input"],
                        post_node.start_dim - 1 if post_node.start_dim > 0 else 0,
                        post_node.end_dim,
                    )
                }
                n_inputs = np.prod(post_node.input_type["input"])
                n_outputs = np.prod(post_node.output_type["output"])
                assert (
                    n_inputs == n_outputs
                ), "Flatten must not change the number of elements"

            # Any neuron node must be updated (output_type == input_type)
            elif isinstance(post_node, (nir.LIF, nir.LI, nir.CubaLIF, nir.CubaLI, nir.I, nir.IF)):
                post_node.output_type = {"output": v for v in post_node.input_type.values()}

        seen.add(post_key)
        ready += [e for e in nir_graph.edges if e[0] == post_key and e[1] not in seen]

    # Ensure all graph outputs flow through an Output node
    all_node_keys = set(nir_graph.nodes.keys())
    source_nodes = {edge[0] for edge in nir_graph.edges}
    leaf_nodes = all_node_keys - source_nodes

    if not leaf_nodes:
        raise ValueError(
            "Type inference failed: No output nodes found. "
            "This may be due to a cyclic dependency at the graph's output. "
            "Please add an `Output` node manually to define an exit point, "
            "or disable type checking (`type_check=False`)."
        )

    new_nodes: Dict[str, nir.NIRNode] = {}
    new_edges: Edges = []

    for node_key in leaf_nodes:
        node = nir_graph.nodes[node_key]
        if not isinstance(node, nir.Output):
            # This is a leaf node that is not an Output node.
            # It must have its output_type defined to create a succeeding Output
            # node.
            undef_output_type = node.output_type is None or any(
                v is None or len(v) == 0 for v in node.output_type.values()
            )
            if undef_output_type:
                # This should not happen if type inference was successful
                raise ValueError(
                    f"Leaf node '{node_key}' of type {type(node).__name__} "
                    "is not an Output node and has no defined output_type. "
                    "Cannot infer graph output."
                )

            # Append an Output node
            output_node_name = f"output_{node_key}"
            i = 0
            original_name = output_node_name
            while output_node_name in nir_graph.nodes or output_node_name in new_nodes:
                output_node_name = f"{original_name}_{i}"
                i += 1

            new_output_node = nir.Output(output_type=node.output_type)
            new_nodes[output_node_name] = new_output_node
            new_edges.append((node_key, output_node_name))

    if new_nodes:
        nir_graph.nodes.update(new_nodes)
        nir_graph.edges.extend(new_edges)

    nir_graph._update_input_output_types()


#
# NIR export helper functions
#

def _set_input(graph: nir.NIRGraph, input_type: np.ndarray):
    graph_inputs = list(graph.input_type.keys())    # type: ignore
    assert len(graph_inputs) == 1, "For now, only single input graphs are supported."

    graph.input_type[graph_inputs[0]] = input_type  # type: ignore
    graph.inputs[graph_inputs[0]].input_type["input"] = input_type
    graph.inputs[graph_inputs[0]].output_type["output"] = input_type

def _broadcast_neuron_params(graph: nir.NIRGraph):
    def broadcast_param(node, shape: np.ndarray, param: str):
        if hasattr(node, param):
            setattr(node, param, np.full(shape, getattr(node, param)))

    param_names = [
        "tau_syn",
        "tau_mem",
        "tau",
        "r",
        "v_leak",
        "v_threshold",
        "v_reset",
        "w_in"
    ]

    for node in graph.nodes.values():
        if isinstance(node, (nir.LIF, nir.LI, nir.CubaLIF, nir.CubaLI, nir.I, nir.IF)):
            for param in param_names:
                broadcast_param(node, node.input_type["input"], param)

def _nir_summary(graph: nir.NIRGraph):
    print("\n               Graph summary")
    print("--------------------------------------------------")
    for i, node in enumerate(graph.nodes):
        node_type = type(graph.nodes[node]).__name__
        print(f"| Node {i:2} | {node:20}| {node_type:15}|")
    print("--------------------------------------------------")


#
# NIR export user-facing functions
#

def extract_graph(
    model: torch.nn.Module, sample: torch.Tensor, dt: float,
    infer_types: bool = True, broadcast_params: bool = True
) -> nir.NIRGraph:
    # Prepare model for tracing:
    # - Put into evaluation mode
    # - Reset stateful members (if applicable)
    model.eval()
    # Reset the model if possible
    if hasattr(model, "reset") and callable(getattr(model, "reset")):
        model.reset() # type: ignore

    custom_norse_map = _custom_norse_to_nir_mapping_dict(dt=dt)

    trace_context = model if isinstance(model, TraceInterface) else nullcontext()
    with trace_context:
        nir_graph = to_nir(
            model,
            time_scaling_factor=dt,
            custom_stateful_modules=custom_stateful_modules,
            custom_mapping=custom_norse_map,
            type_check=False
        )

    assert isinstance(nir_graph, nir.NIRGraph)

    # Set input type
    input_shape = np.array(sample.shape[1:])
    _set_input(nir_graph, input_shape)

    if infer_types:
        _infer_types(nir_graph)
        # nir_graph.infer_types()   # FIXME: eventually NIR upstream should be fixed and used here
    if broadcast_params:
        _broadcast_neuron_params(nir_graph)

    return nir_graph

def export_nir(
        model: torch.nn.Module, meta_data: Optional[dict],
        out_file: Union[str, Path], sample: torch.Tensor,
        dt: float, broadcast_params: bool = True
    ) -> None:
    nir_graph = extract_graph(model, sample, dt, broadcast_params=broadcast_params)
    if meta_data is not None:
        nir_graph.metadata = meta_data

    _nir_summary(nir_graph)
    print(f"Writing graph to {out_file}")
    if isinstance(out_file, Path):
        out_file = str(out_file)

    nir.write(out_file, nir_graph)


##################
### NIR import ###
##################


def _nir_scalar(arr) -> float:
    """Extract a scalar float from a potentially per-neuron NIR parameter array.

    Raises ValueError if not all values are equal (non-uniform parameters are
    not supported by the YANA hardware).
    """
    a = np.asarray(arr)
    if a.size > 1 and not np.all(a == a.flat[0]):
        raise ValueError(
            f"Non-uniform NIR parameter (all neurons must share the same value): {a}"
        )
    return float(a.flat[0])


def _build_node_map(quant_config: QuantConfig, dt: float) -> dict:
    """Build a NIR node-type → PyTorch module mapping without Norse.

    Maps NIR neuron types directly to YANA quantized cells and structural
    node types (Affine, Conv2d, Flatten, ...) to standard PyTorch modules.
    """

    def _map_lif(node: nir.LIF):
        return create_hidden_cell(
            neuron_type=node.metadata.get("type", "lif_quant"),
            tau_inv_mem=_nir_scalar(1.0 / node.tau),
            threshold=_nir_scalar(node.v_threshold),
            dt=dt,
            quant_config=quant_config,
        )

    def _map_li(node: nir.LI):
        return create_output_cell(
            neuron_type=node.metadata.get("type", "li_quant"),
            tau_inv_mem=_nir_scalar(1.0 / node.tau),
            dt=dt,
            quant_config=quant_config,
        )

    def _map_if(node: nir.IF):
        return create_hidden_cell(
            neuron_type=node.metadata.get("type", "if_quant"),
            tau_inv_mem=0.0,
            threshold=_nir_scalar(node.v_threshold),
            dt=dt,
            quant_config=quant_config,
        )

    def _map_i(node: nir.I):
        return create_output_cell(
            neuron_type=node.metadata.get("type", "i_quant"),
            tau_inv_mem=0.0,
            dt=dt,
            quant_config=quant_config,
        )

    def _map_affine(node: nir.Affine):
        # nir.Affine weight shape: (out_features, in_features) — same as nn.Linear
        linear = torch.nn.Linear(node.weight.shape[1], node.weight.shape[0], bias=True)
        linear.weight.data = torch.from_numpy(node.weight).float()
        linear.bias.data = torch.from_numpy(node.bias).float()
        return linear

    def _map_linear(node: nir.Linear):
        # nir.Linear has no bias
        linear = torch.nn.Linear(node.weight.shape[1], node.weight.shape[0], bias=False)
        linear.weight.data = torch.from_numpy(node.weight).float()
        return linear

    def _map_conv2d(node: nir.Conv2d):
        out_ch, in_ch = node.weight.shape[:2]
        kH, kW = node.weight.shape[2], node.weight.shape[3]
        has_bias = node.bias is not None
        conv = torch.nn.Conv2d(
            in_ch, out_ch, (kH, kW),
            stride=node.stride,
            padding=node.padding,
            dilation=node.dilation,
            groups=node.groups,
            bias=has_bias,
        )
        conv.weight.data = torch.from_numpy(node.weight).float()
        if has_bias and conv.bias is not None:
            conv.bias.data = torch.from_numpy(node.bias).float()
        return conv

    def _map_flatten(node: nir.Flatten):
        # NIR Flatten has no batch dim; add 1 to restore PyTorch convention
        return torch.nn.Flatten(node.start_dim + 1, node.end_dim)

    def _map_identity(_node):
        return torch.nn.Identity()

    return {
        nir.LIF:     _map_lif,
        nir.LI:      _map_li,
        nir.IF:      _map_if,
        nir.I:       _map_i,
        nir.Affine:  _map_affine,
        nir.Linear:  _map_linear,
        nir.Conv2d:  _map_conv2d,
        nir.Flatten: _map_flatten,
        nir.Input:   _map_identity,
        nir.Output:  _map_identity,
    }


def register_hooks(
        graph_module: torch.nn.Module, 
        forward_hooks: Optional[list] = None, 
        forward_pre_hooks: Optional[list] = None
) -> torch.fx.GraphModule:
    if forward_hooks:
        for hook in forward_hooks:
            graph_module.register_forward_hook(hook = hook, with_kwargs=True)

    if forward_pre_hooks:
        for hook in forward_pre_hooks:
            graph_module.register_forward_pre_hook(hook = hook, with_kwargs=True)

    return graph_module


def import_from_nir(
    nir_graph: Union[nir.NIRGraph, str], 
    quant_config: QuantConfig, dt: float,
    forward_hooks: Optional[list] = None,
    forward_pre_hooks: Optional[list] = None,
) -> torch.fx.GraphModule:
    if isinstance(nir_graph, str):
        if not nir_graph.endswith('.nir'):
            nir_graph += '.nir'
        nir_graph = nir.read(nir_graph)

    node_map = _build_node_map(quant_config, dt)

    graph_module = nir_to_torch(nir_graph, node_map=node_map)
    graph_module = register_hooks(graph_module, forward_hooks, forward_pre_hooks)

    return graph_module
