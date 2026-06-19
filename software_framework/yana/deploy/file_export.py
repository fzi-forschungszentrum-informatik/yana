import math
import os
from typing import Dict, List, Tuple, Union

import numpy as np

from yana.core.config import AcceleratorConfig, CoreConfig
from yana.deploy.core import Route

from .fixed_point import FixedPoint
from .accelerator import Accelerator
from .memory import write_core_memories

def _int_to_binary_str(value: int, value_width: int) -> str:
    if value >= 0:
        return f"{value:0{value_width}b}"
    else:
        return f"{(2**value_width + value):0{value_width}b}"

def write_accelerator_memories(accelerator: Accelerator, output_dir: str, accelerator_config: AcceleratorConfig, as_events: bool = False):
    assert os.path.exists(output_dir), f"Output directory '{output_dir}' does not exist"
    assert os.path.isdir(output_dir), f"'{output_dir}' is not a directory"

    for core in accelerator.cores.values():
        write_weights = core.config.type is not CoreConfig.Type.INPUT
        write_routes  = core.config.type is not CoreConfig.Type.OUTPUT

        write_core_memories(
            core, f"core_{core.id}",
            output_dir, accelerator_config,
            write_weights=write_weights, write_routes=write_routes,
            as_events=as_events
        )

def write_input_events(
    input_events: List[Tuple[int, int]],
    output_dir: str,
    accelerator_config: AcceleratorConfig,
    filename: str = "input_trace.txt",
):
    assert os.path.exists(output_dir), f"Output directory '{output_dir}' does not exist"
    assert os.path.isdir(output_dir), f"'{output_dir}' is not a directory"

    input_trace_file = os.path.join(output_dir, filename)
    with open(input_trace_file, 'w') as f:
        for timestep, pre_neuron_id in input_events:
            # +1 for control flag
            value = pre_neuron_id << (accelerator_config.packet_addr_width + 1)
            f.write(f"{timestep} {value:0{accelerator_config.neuron_id_width + (accelerator_config.packet_addr_width + 1)}b}\n")

def write_input_events_packed(input_sample: np.ndarray, output_dir: str, input_data_width: int):
    assert os.path.exists(output_dir), f"Output directory '{output_dir}' does not exist"
    assert os.path.isdir(output_dir), f"'{output_dir}' is not a directory"

    num_input_channels = input_sample.shape[-1]
    input_trace_file = os.path.join(output_dir, "input_trace.txt")

    with open(input_trace_file, 'w') as f:
        if num_input_channels <= input_data_width:
            timesteps_per_line = input_data_width // num_input_channels
            current_line: List[np.ndarray] = []

            for i, sample_ts in enumerate(input_sample):
                current_line.append(sample_ts)
                if len(current_line) >= timesteps_per_line or i == len(input_sample) - 1:
                    # Create binary string from current line
                    current_line_str = ""
                    for item in current_line:
                        item = item.astype(dtype=np.int32).flatten()    # List of 0 or 1
                        # Reverse for correct ordering of spikes (LSB last)
                        current_line_str = ''.join(str(bit) for bit in reversed(item)) + current_line_str
                    # Pad with 0 if neccessary
                    current_line_str = current_line_str.zfill(input_data_width)
                    # Write to file
                    f.write(f"{current_line_str}\n")
                    current_line.clear()
        else:
            lines_per_timestep = math.ceil(num_input_channels/input_data_width)

            for sample_ts in input_sample:
                data_pointer = 0
                for _ in range(lines_per_timestep):
                    # Slice sample time step
                    end_index = min(data_pointer+input_data_width, sample_ts.size)
                    item = sample_ts.copy()[data_pointer:end_index].astype(dtype=np.int32).flatten()
                    # Create binary string from current line
                    current_line_str = ''.join(str(bit) for bit in reversed(item))
                    # Pad with 0 if neccessary
                    current_line_str = current_line_str.zfill(input_data_width)
                    # Write to file
                    f.write(f"{current_line_str}\n")
                    # Update pointer
                    data_pointer = end_index

def write_output_trace(
    output_states: Dict[int, List[FixedPoint]],
    output_dir: str,
    state_width: int,
    filename: str = "neuron_state_trace.txt",
):
    assert os.path.exists(output_dir), f"Output directory '{output_dir}' does not exist"
    assert os.path.isdir(output_dir), f"'{output_dir}' is not a directory"

    neuron_state_trace_file = os.path.join(output_dir, filename)
    with open(neuron_state_trace_file, 'w') as f:
        for timestep, neuron_states_ts in output_states.items():
            for neuron_idx, neuron_state in enumerate(neuron_states_ts):
                f.write(f"{timestep} {neuron_idx} {_int_to_binary_str(neuron_state.value, state_width)}\n")

def write_test_stimuli(export_trace: Dict[int, Dict], output_dir: str, accelerator_config: AcceleratorConfig):
    assert os.path.exists(output_dir), f"Output directory '{output_dir}' does not exist"
    assert os.path.isdir(output_dir), f"'{output_dir}' is not a directory"

    def format_event(event: Union[int, Route], core_id: int, external: bool, accelerator_config: AcceleratorConfig):
        if isinstance(event, Route):
            target_x, target_y = accelerator_config.core_id_to_xy(event.target_core)
            source_x, source_y = accelerator_config.core_id_to_xy(core_id)
            dx = target_x - source_x
            dy = source_y - target_y  # mesh router: negative = South
            core_dy = f"{dy:0{accelerator_config.packet_dy_width}b}"
            core_dx = f"{dx:0{accelerator_config.packet_dx_width}b}"
            # core_bits = f"{event.target_core:0{accelerator_config.core_id_bits}b}"
            neuron_bits = f"{event.target_neuron:0{accelerator_config.neuron_id_width}b}"
            synapse_bits = f"{event.target_synapse:0{accelerator_config.weight_id_width}b}"
            if external:
                return core_dy + core_dx + neuron_bits + synapse_bits
            else:
                return neuron_bits + synapse_bits
        else:
            output_width = (
                accelerator_config.packet_addr_width if external else 0 +
                accelerator_config.neuron_id_width +
                accelerator_config.weight_id_width
            )
            return f"{event:0{output_width}b}"

    for core_id, core_trace in export_trace.items():
        sim_trace_dir = os.path.join(output_dir, "sim_trace")
        os.makedirs(sim_trace_dir, exist_ok=True)

        core_name = f"core_{core_id}" if core_id > -1 else "core_input"
        trace_file_input = os.path.join(sim_trace_dir, f"{core_name}_in.txt")
        trace_file_output = os.path.join(sim_trace_dir, f"{core_name}_out.txt")

        with open(trace_file_input, 'w') as f_input, open(trace_file_output, 'w') as f_output:
            for timestep, ts_trace in core_trace.items():
                # Write input trace
                for input_event in ts_trace["input"]:
                    event_bits = format_event(input_event, core_id, False, accelerator_config)
                    f_input.write(f"{timestep} {event_bits}\n")
                # Write output trace
                for output_event in ts_trace["output"]:
                    event_bits = format_event(output_event, core_id, True, accelerator_config)
                    f_output.write(f"{timestep} {event_bits}\n")
