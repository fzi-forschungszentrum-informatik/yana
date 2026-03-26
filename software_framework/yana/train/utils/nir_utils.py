from typing import Optional, Union
from pathlib import Path

import numpy as np
import torch
from torch.nn import ParameterDict, Dropout, ModuleList, Identity

import nir
import norse.torch as nt

from yana.train.neurons.lif_quant import LIFQuantCell
from yana.train.neurons.li_quant import LIQuantCell


def post_map_write(module: torch.nn.Module, dt: float) -> Optional[nir.NIRNode]:
    '''
    This fallback map defines how the mapping from norse and torch
    modules to NIR nodes should be done for classes that are not
    (yet) officially supported by NIR.
    '''
    if isinstance(module, LIFQuantCell):
        return nir.LIF(
            tau=dt/module.p.tau_mem_inv_l,  # Invert time constant
            v_threshold=module.p.v_th,
            v_leak=module.p.v_leak,
            r=np.ones_like(module.p.v_leak),
        )
    if isinstance(module, LIQuantCell):
        return nir.LI(
            tau=dt/module.p.tau_mem_inv_l,  # Invert time constant
            r=np.ones_like(module.p.v_leak),
            v_leak=module.p.v_leak,
        )

    return None


'''
These torch modules should be ignored when tracing the torch graph,
since they only are containers for other modules.
This list can be extended other (container) modules must
not be considered by the graph tracer used by nirtorch.
'''
ignore_types = [ParameterDict, Dropout, ModuleList, Identity]


def extract_graph(model: torch.nn.Module, sample: torch.Tensor, dt: float, broadcast_params: bool = True) -> nir.NIRGraph:
    # Check dimensions of sample: [batch_size, time_steps, width, height]
    assert sample.ndim == 4

    # Do the conversion on the CPU
    #     -> The model must also be on the CPU
    nir_graph: nir.NIRGraph = nt.to_nir(
        model, sample_data=sample,
        dt=dt, ignore_types=ignore_types, post_map=post_map_write
    )
    nir_graph.infer_types()
    nir_graph._check_types()
    if (broadcast_params):
        _broadcast_params(nir_graph)

    return nir_graph


def export_nir(
        model: torch.nn.Module, meta_data: Optional[dict],
        out_file: Union[str, Path], sample: torch.Tensor,
        dt: float, broadcast_params: bool = True
    ) -> None:
    nir_graph = extract_graph(model, sample, dt, broadcast_params)
    if meta_data is not None:
        nir_graph.metadata = meta_data

    _nir_summary(nir_graph)
    print(f"Writing graph to {out_file}")
    if isinstance(out_file, Path):
        out_file = str(out_file)

    nir.write(out_file, nir_graph)


def _nir_summary(graph: nir.NIRGraph):
    print("\n               Graph summary")
    print("--------------------------------------------------")
    for i, node in enumerate(graph.nodes):
        node_type = type(graph.nodes[node]).__name__
        print(f"| Node {i:2} | {node:20}| {node_type:15}|")
    print("--------------------------------------------------")


def _broadcast_params(graph: nir.NIRGraph):
    '''
    Broadcast arguments like tau, r, v_leak and v_threshold of neurons
    to match the input/output size. This is required for the input_types
    and output_types to be reconstructed correctly upon loading the '.nir'
    file.

    NOTE: this code is inspired by the _forward_type_inference method in the
    nir.ir module.
    '''
    ready = [e for e in graph.edges if e[0] in graph.inputs.keys()]
    seen = set([e[0] for e in ready])
    while len(ready) > 0:
        pre_key, post_key = ready.pop()
        pre_node = graph.nodes[pre_key]
        post_node = graph.nodes[post_key]

        if isinstance(post_node, (nir.ir.LI, nir.ir.LIF)):
            post_node.input_type["input"] = pre_node.output_type["output"]
            post_node.output_type["output"] = pre_node.output_type["output"]

            post_node.tau = np.full(pre_node.output_type["output"], post_node.tau)
            post_node.r = np.full(pre_node.output_type["output"], post_node.r)
            post_node.v_leak = np.full(pre_node.output_type["output"], post_node.v_leak)
            if isinstance(post_node, nir.ir.LIF):
                post_node.v_threshold = np.full(pre_node.output_type["output"], post_node.v_threshold)

        seen.add(post_key)
        ready += [e for e in graph.edges if e[0] == post_key and e[1] not in seen]
