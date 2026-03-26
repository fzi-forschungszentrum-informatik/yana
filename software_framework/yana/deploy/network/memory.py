from enum import Enum
from typing import Dict, List, Optional, TextIO, Tuple, NamedTuple
from math import ceil

from yana.deploy.fixed_point import FixedPoint, int_to_binary_str
from yana.core.hardware_config import AcceleratorConfig


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
    values: List[Tuple[int, int]]
    string: str

    def __init__(self, width: Optional[int] = None):
        self.width = width
        self.values = []
        self.string = ""

    def add_value(self, value: int, value_width: int):
        self.values.append((value, value_width))

    def construct(self):
        for value, value_width in self.values:
            value_str = int_to_binary_str(value, value_width)
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


class MemLayout(Enum):
    COMPRESSED = 0
    WEIGHT_REUSE = 1


class WeightRam:
    mem_file: TextIO
    acc_config: AcceleratorConfig
    mem_layout: MemLayout
    weights: List[Dict[int, FixedPoint]]
    weight_address_map: Dict[FixedPoint, int]

    def __init__(self, file_path: str, acc_config: AcceleratorConfig, mem_layout: MemLayout = MemLayout.COMPRESSED):
        self.mem_file = open(file_path, "w")
        self.acc_config = acc_config
        self.mem_layout = mem_layout
        self.weights = []
        self.weight_address_map = {}

    def add_layer(self, layer_weights: List[Dict[int, FixedPoint]]):
        self.weights.extend(layer_weights)

    def get_weight_address(self, source_neuron_id: int, target_neuron_id: int) -> int:
        if self.mem_layout == MemLayout.COMPRESSED:
            # Add up all adresses for neurons before target_neuron_id
            offset: int = 0
            for neuron_weights in self.weights[:target_neuron_id]:
                offset += len(neuron_weights)

            # Find synapse_id in the target_neuron's weights
            for idx, synapse_id in enumerate(self.weights[target_neuron_id]):
                if synapse_id == source_neuron_id:
                    return offset + idx
            return -1

        elif self.mem_layout == MemLayout.WEIGHT_REUSE:
            if source_neuron_id not in self.weights[target_neuron_id]:
                return -1

            weight_value = self.weights[target_neuron_id][source_neuron_id]
            # Check if weight has already been cached
            if weight_value in self.weight_address_map:
                return self.weight_address_map[weight_value]
            # Cache new weight
            weight_address = len(self.weight_address_map)
            self.weight_address_map[weight_value] = weight_address
            return weight_address

        else:
            raise Exception(f"Memory layout {self.mem_layout.name} is not supported (yet).")

    def write(self):
        packet: Packet = Packet(self.acc_config.uram_data_width)

        if self.mem_layout == MemLayout.COMPRESSED:
            addr_counter = 0
            synapse_counter = 0
            # Iterate over all neurons and all weights of a neuron
            for neuron_weights in self.weights:
                for weight_fp in neuron_weights.values():
                    packet.add_value(weight_fp.value, self.acc_config.weight_width)
                    synapse_counter += 1
                    # Write packet (if number of entries per line or last weight has been reached)
                    if len(packet) == self.acc_config.weights_per_line:
                        packet.construct()
                        self.mem_file.write(f"{_int_to_hex_str(addr_counter, self.acc_config.weights_addr_width)}\n")   # Address
                        self.mem_file.write(f"{packet.hex()}\n")                                                        # Data

                        packet.clear()
                        addr_counter += 1

            if len(packet) > 0: # Write last packet if neccessary
                packet.construct()
                self.mem_file.write(f"{_int_to_hex_str(addr_counter, self.acc_config.weights_addr_width)}\n")   # Address
                self.mem_file.write(f"{packet.hex()}\n")                                                        # Data

            assert synapse_counter <= self.acc_config.synapses_per_core, f"Too many synapses: {synapse_counter}. Allowed: {self.acc_config.synapses_per_core}"

        elif self.mem_layout == MemLayout.WEIGHT_REUSE:
            assert len(self.weight_address_map) <= self.acc_config.synapses_per_core, f"Too many weights: {len(self.weight_address_map)}. Allowed: {self.acc_config.synapses_per_core}"

            for weight, weight_address in self.weight_address_map.items():
                packet.add_value(weight.value, self.acc_config.weight_width)
                # Write packet (if number of entries per line or last weight has been reached)
                if len(packet) == self.acc_config.weights_per_line:
                    ram_address = weight_address // self.acc_config.weights_per_line

                    packet.construct()
                    self.mem_file.write(f"{_int_to_hex_str(ram_address, self.acc_config.weights_addr_width)}\n")    # Address
                    self.mem_file.write(f"{packet.hex()}\n")                                                        # Data

                    packet.clear()

            if len(packet) > 0: # Write last packet if neccessary
                ram_address = weight_address // self.acc_config.weights_per_line

                packet.construct()
                self.mem_file.write(f"{_int_to_hex_str(ram_address, self.acc_config.weights_addr_width)}\n")    # Address
                self.mem_file.write(f"{packet.hex()}\n")                                                        # Data

        else:
            raise Exception(f"Memory layout {self.mem_layout.name} is not supported (yet).")

    @property
    def utilization(self) -> float:
        return len(self.weight_address_map) / self.acc_config.synapses_per_core

    def close(self):
        self.mem_file.close()


class RouteEntry(NamedTuple):
    target_core: int
    target_neuron: int
    target_synapse: int


class AxonRam:
    mem_file_mapping: TextIO
    mem_file_routing: TextIO
    acc_config: AcceleratorConfig
    routes: Dict[int, List[RouteEntry]]

    def __init__(self, file_path_mapping: str, file_path_routing: str, acc_config: AcceleratorConfig):
        self.mem_file_mapping = open(file_path_mapping, "w")
        self.mem_file_routing = open(file_path_routing, "w")

        self.acc_config = acc_config
        self.routes = {}

    def add_route(self, source_neuron_id: int, target_core: int, target_neuron_id: int, target_synapse_address: int):
        if source_neuron_id not in self.routes:
            self.routes[source_neuron_id] = []
        self.routes[source_neuron_id].append(RouteEntry(target_core, target_neuron_id, target_synapse_address))

    def write(self):
        addr_counter = 0
        routes_counter = 0
        routing_packet: Packet = Packet(self.acc_config.uram_data_width)
        mapping_packet: Packet = Packet()

        # Sort by ascending source_id
        self.routes = dict(sorted(self.routes.items()))

        # Iterate over all neurons and all routes of a neuron
        for source_neuron_id, neuron_routes in self.routes.items():
            base_address = addr_counter
            num_entries_last_line = 0
            for route_idx, route in enumerate(neuron_routes):
                routing_packet.add_value(route.target_synapse, self.acc_config.synapse_id_bits)
                routing_packet.add_value(route.target_neuron, self.acc_config.neuron_id_bits)
                routing_packet.add_value(route.target_core, self.acc_config.core_id_bits)
                routes_counter += 1
                # Write packet (if number of entries per line or last route has been reached)
                if len(routing_packet) / 3 == self.acc_config.routes_per_line or route_idx == len(neuron_routes) - 1:
                    routing_packet.construct()
                    self.mem_file_routing.write(f"{_int_to_hex_str(addr_counter, self.acc_config.routes_addr_width)}\n")    # Address
                    self.mem_file_routing.write(f"{routing_packet.hex()}\n")                                                # Data

                    num_entries_last_line = int(len(routing_packet) / 3)
                    routing_packet.clear()
                    addr_counter += 1

            # Write mapping packet
            mapping_packet.add_value(base_address, self.acc_config.mapping_base_address_width)
            mapping_packet.add_value((addr_counter-base_address), self.acc_config.mapping_num_lines_width)
            mapping_packet.add_value(num_entries_last_line, self.acc_config.mapping_last_memory_line_width)

            mapping_packet.construct()
            self.mem_file_mapping.write(f"{_int_to_hex_str(source_neuron_id, self.acc_config.neuron_id_bits)}\n")
            self.mem_file_mapping.write(f"{mapping_packet.hex()}\n")
            mapping_packet.clear()

        assert routes_counter <= self.acc_config.routes_per_core, f"Too many routes: {routes_counter}. Allowed: {self.acc_config.routes_per_core}"

    @property
    def utilization(self) -> float:
        return len(self.routes) / self.acc_config.routes_per_core

    def close(self):
        self.mem_file_mapping.close()
        self.mem_file_routing.close()
