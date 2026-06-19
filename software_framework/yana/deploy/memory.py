import os
from typing import List, Optional, TextIO, Tuple, Union
from math import ceil

import numpy as np

from yana.deploy.fixed_point import int_to_binary_str
from yana.core.config import AcceleratorConfig

from .core import Core


def _int_to_hex_str(value: int, value_width: int) -> str:
    """
    Converts a signed integer value to its hexadecimal representation.
    """
    if value >= 0:
        return f"{value:0{ceil(value_width / 4)}x}"
    else:
        return f"{(2**value_width + value):0{ceil(value_width / 4)}x}"

def _binary_str_to_hex_str(bin_str: str) -> str:
    return f"{int(bin_str, 2):0{ceil(len(bin_str) / 4)}x}"


class Packet:
    width: Optional[int]
    values: List[Tuple[Union[int, str], int]]
    string: str

    def __init__(self, width: Optional[int] = None):
        self.width = width
        self.values = []
        self.string = ""

    def add_value(self, value: Union[int, str], value_width: int):
        self.values.append((value, value_width))

    def construct(self):
        for value, value_width in self.values:
            value_str = int_to_binary_str(value, value_width) if isinstance(value, (int, np.integer)) else value.zfill(value_width)
            self.string = value_str + self.string
        if self.width is not None:
            if len(self.string) < self.width:
                self.string = self.string.zfill(self.width)
            elif len(self.string) > self.width:
                raise Exception(f"Actual packet size [{len(self.string)}] is larger than required packet size [{self.width}]")

    def bin(self) -> str:
        return self.string
    
    def hex(self) -> str:
        return _binary_str_to_hex_str(self.string)

    def clear(self):
        self.values.clear()
        self.string = ""

    def __len__(self):
        return len(self.values)


def write_core_memories(
    core: Core, suffix: str,
    output_dir: str,
    acc_config: AcceleratorConfig,
    write_weights: bool = True,
    write_routes: bool = True,
    write_threshold: bool = True,
    write_tau_mem_inv: bool = True,
    write_leak_lut: bool = True,
    as_events: bool = False,
):
    if write_weights:
        weights_file_path = os.path.join(output_dir, f"mem_weights_{suffix}.txt")
        write_core_weights(core, acc_config, weights_file_path, as_events)
    if write_routes:
        mapping_file_path = os.path.join(output_dir, f"mem_mapping_{suffix}.txt")
        routing_file_path = os.path.join(output_dir, f"mem_routing_{suffix}.txt")
        write_core_routes(core, acc_config, mapping_file_path, routing_file_path, as_events)
    if write_threshold:
        threshold_file_path = os.path.join(output_dir, f"threshold_{suffix}.txt")
        write_core_threshold(core, acc_config, threshold_file_path, as_events)
    if write_tau_mem_inv:
        tau_mem_inv_file_path = os.path.join(output_dir, f"tau_mem_inv_{suffix}.txt")
        write_core_tau_mem_inv(core, acc_config, tau_mem_inv_file_path, as_events)
    if write_leak_lut:
        leak_lut_file_path = os.path.join(output_dir, f"leak_ram_{suffix}.txt")
        write_core_leak_lut(core, acc_config, leak_lut_file_path, as_events)

def write_to_events(file: TextIO, address: int, packet: Packet, acc_config: AcceleratorConfig, target_core: int, memory_target: str):
    assert packet.width is not None, "No 'None' packet widths allowed."

    match memory_target:
        case "synapse_weights":
            addr_width = acc_config.weight_ram_addr_width
        case "axon_mapping":
            addr_width = acc_config.neuron_id_width
        case "axon_routes":
            addr_width = acc_config.routes_ram_addr_width
        case "spike_threshold":
            addr_width = 0
        case "tau_mem_inv":
            addr_width = 0
        case "leak_lut":
            addr_width = acc_config.core_configs[target_core].neuron_config.leak_lut_addr_width
        case _:
            raise ValueError(f"Unknown memory_target: {memory_target}")

    # Construct combined packet (addr|data) in binary
    combined_packet_str = f"{address:0{addr_width}b}" + packet.bin()
    # Pad with zeros at MSBs
    combined_packet_str = combined_packet_str.zfill(acc_config.init_burst_num_events * acc_config.init_event_payload_width)

    init_event = Packet(acc_config.init_packet_width)  # Maximum data width of mesh packet
    for i in range(acc_config.init_burst_num_events):
        init_event.clear()
        # Add packet address
        target_x, target_y = acc_config.core_id_to_xy(target_core)
        inject_x, inject_y = 0, 0  # We inject fixed at (0, 0) for now
        dx = target_x - inject_x
        dy = inject_y - target_y  # mesh router: negative = South
        init_event.add_value(dx, acc_config.packet_dx_width)
        init_event.add_value(dy, acc_config.packet_dy_width)
        # Add payload
        init_event.add_value(
            combined_packet_str[i*acc_config.init_event_payload_width:(i+1)*acc_config.init_event_payload_width],
            acc_config.init_event_payload_width
        )
        # Add init target
        init_event.add_value(acc_config.mem_init_targets[memory_target], acc_config.init_event_target_width)

        init_event.construct()
        file.write(f"{init_event.bin()}\n")

def write_core_weights(core: Core, acc_config: AcceleratorConfig, weights_file_path: str, as_events: bool = False):
    with open(weights_file_path, "w") as mem_file_weights:
        packet: Packet = Packet(acc_config.platform_config.uram_width)
        core_config = acc_config.core_configs[core.id]

        assert len(core.weights) <= acc_config.weights_per_core, f"Too many weights: {len(core.weights)}. Allowed: {acc_config.weights_per_core}"

        for weight_address, weight in enumerate(core.weights):
            packet.add_value(weight.value, core_config.quant_config.format_weights.word_length)
            # Write packet (if number of entries per line or last weight has been reached)
            if len(packet) == acc_config.weights_per_line or weight_address == len(core.weights) - 1:
                ram_address = weight_address // acc_config.weights_per_line

                packet.construct()

                if as_events:
                    write_to_events(mem_file_weights, ram_address, packet, acc_config, core.id, "synapse_weights")
                else:
                    mem_file_weights.write(f"{_int_to_hex_str(ram_address, acc_config.weight_ram_addr_width)}\n") # Address
                    mem_file_weights.write(f"{packet.hex()}\n")                                                   # Data

                packet.clear()

def write_core_routes(core: Core, acc_config: AcceleratorConfig, mapping_file_path: str, routing_file_path: str, as_events: bool = False):
    with open(mapping_file_path, "w") as mem_file_mapping, open(routing_file_path, "w") as mem_file_routing:
        addr_counter = 0
        routes_counter = 0
        routing_packet: Packet = Packet(acc_config.platform_config.uram_width)
        mapping_packet: Packet = Packet(acc_config.mapping_ram_data_width)

        assert routes_counter <= acc_config.routes_per_core, f"Too many routes: {routes_counter}. Allowed: {acc_config.routes_per_core}"
        # Sort by ascending source_id
        core.routes = dict(sorted(core.routes.items()))

        # Iterate over all neurons and all routes of a neuron
        for source_neuron_id, neuron_routes in core.routes.items():
            base_address = addr_counter
            num_entries_last_line = 0
            for route_idx, route in enumerate(neuron_routes):
                # Add packet address
                target_x, target_y = acc_config.core_id_to_xy(route.target_core)
                source_x, source_y = acc_config.core_id_to_xy(core.id)
                dx = target_x - source_x
                dy = source_y - target_y  # mesh router: negative = South
                routing_packet.add_value(dx, acc_config.packet_dx_width)
                routing_packet.add_value(dy, acc_config.packet_dy_width)
                # Add target neuron
                routing_packet.add_value(route.target_neuron, acc_config.neuron_id_width)
                # Add target synapse
                routing_packet.add_value(route.target_synapse, acc_config.weight_id_width)
                routes_counter += 1
                # Write packet (if number of entries per line or last route has been reached)
                # The 4 refers to the 4 calls to 'add_value' above, forming one single complete routing packet.
                if len(routing_packet) / 4 == acc_config.routes_ram_entries_per_line or route_idx == len(neuron_routes) - 1:
                    routing_packet.construct()

                    if as_events:
                        write_to_events(mem_file_routing, addr_counter, routing_packet, acc_config, core.id, "axon_routes")
                    else:
                        mem_file_routing.write(f"{_int_to_hex_str(addr_counter, acc_config.routes_ram_addr_width)}\n") # Address
                        mem_file_routing.write(f"{routing_packet.hex()}\n")                                            # Data

                    num_entries_last_line = int(len(routing_packet) / 4)
                    routing_packet.clear()
                    addr_counter += 1

            # Write mapping packet
            mapping_packet.add_value(base_address, acc_config.routes_ram_addr_width)
            mapping_packet.add_value((addr_counter - 1), acc_config.routes_ram_addr_width)
            mapping_packet.add_value(num_entries_last_line-1, acc_config.mapping_ram_last_idx_width)

            mapping_packet.construct()

            if as_events:
                write_to_events(mem_file_mapping, source_neuron_id, mapping_packet, acc_config, core.id, "axon_mapping")
            else:
                mem_file_mapping.write(f"{_int_to_hex_str(source_neuron_id, acc_config.neuron_id_width)}\n")
                mem_file_mapping.write(f"{mapping_packet.hex()}\n")

            mapping_packet.clear()

def write_core_threshold(core: Core, acc_config: AcceleratorConfig, threshold_file_path: str, as_events: bool = False):
    value_width = acc_config.core_configs[core.id].quant_config.format_threshold.word_length
    packet = Packet(value_width)
    packet.add_value(core.threshold.value, value_width)
    packet.construct()

    with open(threshold_file_path, "w") as f:
        if as_events:
            write_to_events(f, 0, packet, acc_config, core.id, "spike_threshold")
        else:
            f.write(f"{packet.hex()}\n")

def write_core_tau_mem_inv(core: Core, acc_config: AcceleratorConfig, tau_mem_inv_file_path: str, as_events: bool = False):
    value_width = acc_config.core_configs[core.id].quant_config.format_tau_inv_j.word_length
    packet = Packet(value_width)
    packet.add_value(core.tau_mem_inv.value, value_width)
    packet.construct()

    with open(tau_mem_inv_file_path, "w") as f:
        if as_events:
            write_to_events(f, 0, packet, acc_config, core.id, "tau_mem_inv")
        else:
            f.write(f"{packet.hex()}\n")

def write_core_leak_lut(core: Core, acc_config: AcceleratorConfig, leak_lut_file_path: str, as_events: bool = False):
    if not core.leak_lut:
        return

    quant_opts_lut = core.config.quant_config.format_tau_inv_l
    value_width = quant_opts_lut.integer_length + quant_opts_lut.fraction_length
    addr_width = core.config.neuron_config.leak_lut_addr_width
    packet = Packet(value_width)

    with open(leak_lut_file_path, "w") as lut_file:
        for addr, entry in enumerate(core.leak_lut):
            packet.add_value(entry.value, value_width)
            packet.construct()

            if as_events:
                write_to_events(lut_file, addr, packet, acc_config, core.id, "leak_lut")
            else:
                lut_file.write(f"{_int_to_hex_str(addr, addr_width)}\n")
                lut_file.write(f"{packet.hex()}\n")

            packet.clear()
