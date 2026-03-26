import argparse
import os

import nir
import numpy as np

from yana.deploy.network import Network, generate_input_events
from yana.core.hardware_config import from_metadata
from yana.core.quant_options import options_from_config


# This accounts for the delay in computation on the hardware
# due to pipelining. Depends on network depth.
PIPELINE_DEPTH = 3

def _int_to_binary_str(value: int, value_width: int) -> str:
    """
    Converts a signed integer value to its 2's complement binary representation.
    """
    if value >= 0:
        return f"{value:0{value_width}b}"
    else:
        return f"{(2**value_width + value):0{value_width}b}"

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input-path", type=str, help="Path to training artifacts.", required=True)
    parser.add_argument("-o", "--output-path", type=str, help="Path where deployment files should be saved to (default: {input-path}/deploy).", default=None)
    args = parser.parse_args()

    input_folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.input_path)
    output_folder = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), args.output_path
        if args.output_path is not None
        else os.path.join(args.input_path, "deploy")
    )

    os.makedirs(output_folder, exist_ok=True)

    # Load NIR graph, configuration and metadata
    nir_graph = nir.read(os.path.join(input_folder, "nir_file.nir"))
    metadata = nir_graph.metadata
    quant_options = options_from_config(metadata["quant_cfg"])
    accelerator_config = from_metadata(metadata["hardware_cfg"], quant_options.weight_format)

    # Create simulator and input events
    network = Network(nir_graph, accelerator_config, quant_options)
    input_sample = np.load(os.path.join(input_folder, "sample_data.npy"))
    input_events = generate_input_events(input_sample)

    # Simulate network execution
    simulation_duration = len(input_sample) + 3
    output_neuron_states = network.simulate(input_events, simulation_duration)
    sim_output = np.array([state.to_float() for state in output_neuron_states[simulation_duration-1]])

    # Compare against torch output
    ref_neuron_states = np.load(os.path.join(input_folder, "sample_output.npy"))
    ref_output = ref_neuron_states[-1][0]

    print("\nSimulator States:")
    formatted_states = ", ".join(f"{state.item():{15}}" for state in sim_output)
    print(f"[{formatted_states}]")
    print("\nReference States:")
    formatted_states = ", ".join(f"{state.item():{15}}" for state in ref_output)
    print(f"[{formatted_states}]\n")

    max_difference = np.max(np.abs(sim_output - ref_output))
    print(f"Maximum difference: {max_difference}\n")

    # Generate deployment files
    network.generate_mem_files(output_folder, print_util=True)

    # Write input events to file
    input_trace_file = os.path.join(output_folder, "input_trace.txt")
    with open(input_trace_file, 'w') as f:
        for timestep, pre_neuron_id in input_events:
            f.write(f"{timestep - 1} {pre_neuron_id:0{accelerator_config.neuron_id_bits}b}\n") # ts -1 because pipelined ts processing in HW

    # Write neuron states so file
    neuron_state_trace_file = os.path.join(output_folder, "neuron_state_trace.txt")
    with open(neuron_state_trace_file, 'w') as f:
        for timestep, neuron_states_ts in enumerate(output_neuron_states[1:]):
            for neuron_idx, neuron_state in enumerate(neuron_states_ts):
                total_bits = neuron_state.integer_bits + neuron_state.fractional_bits
                f.write(f"{timestep} {neuron_idx} {_int_to_binary_str(neuron_state.value, quant_options.state_format.wl)}\n")

    print("Deployment files written.")
