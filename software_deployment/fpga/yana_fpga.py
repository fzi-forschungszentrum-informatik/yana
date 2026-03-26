"""High-level PYNQ driver for the YANA SNN FPGA prototype on AMD Kria.

Loads a bitstream overlay, programs weight/mapping/routes memories via AXI stream
FIFOs, streams spike events over DMA, and optionally runs batch experiments.
IP block names passed to the constructor must match the overlay (e.g. Vivado export).
"""

from typing import List, Dict, Tuple
from pynq import Overlay, DefaultIP, allocate
from pynq.lib import DMA
from pynq.buffer import PynqBuffer
import numpy as np
from time import sleep
from fixed_point import QuantScheme, FixedPoint
import os
from experiment_tracker import ExperimentTracker


class YanaFpga:
    """YANA accelerator control: CSR shadow registers, memory programming, DMA I/O, experiment stats."""

    # Chunk size parameter for FIFO transfers (in bytes)
    #   This corresponds to the data width of an AXI-Lite transfer
    CHUNK_SIZE = 4
    # Assumed programmable logic clock frequency (MHz) for rough latency estimates in verbose logs.
    PL_CLOCK_MHZ = 100
    # Address and data width parameters for SNN memories
    HIDDEN_LEAK_LUT_ADDR_WIDTH = 5
    OUTPUT_LEAK_LUT_DATA_WIDTH = 8
    WEIGHT_ADDR_WIDTH = 15
    WEIGHT_DATA_WIDTH = 72
    ROUTES_ADDR_WIDTH = 16
    ROUTES_DATA_WIDTH = 72
    MAPPING_ADDR_WIDTH = 10
    MAPPING_DATA_WIDTH = 34
    # Input path parameters
    IN_SAMPLE_MAX_EVENTS = 32768
    # Source event parameters
    IN_EVENT_NEURON_WIDTH = 10
    IN_EVENT_TIMESTEP_WIDTH = 22
    # Membrane readout parameters
    OUT_POT_WORD_WIDTH = 24
    OUT_POT_FRAC_WIDTH = 12
    OUT_POT_SIGN = True

    def __init__(
        self,
        bitstream: str,
        output_buffer_size: int = 1024,
        stream_fifo_routes: str = "axi_fifo_mm_s_routes",
        stream_fifo_mapping: str = "axi_fifo_mm_s_mapping",
        stream_fifo_weights: str = "axi_fifo_mm_s_weights",
        dma_event_io: str = "axi_dma_0",
        axi_intc: str = "axi_intc_0",
        ctrl_0: str = "axi_ctrl_0",
        ctrl_1: str = "axi_ctrl_1",
        stat_cycles: str = "axi_stat_cyc_cnt"
    ):
        """
        Args:
            bitstream: Path to the bitstream file.
            output_buffer_size: Size of the output buffer for DMA transfers.
            stream_fifo_routes: Name of the routes stream FIFO IP.
            stream_fifo_mapping: Name of the mapping stream FIFO IP.
            stream_fifo_weights: Name of the weights stream FIFO IP.
            dma_event_io: Name of the DMA IP for event input/output.
            axi_intc: Name of the AXI interrupt controller IP.
            ctrl_0: Name of the control register 0 IP.
            ctrl_1: Name of the control register 1 IP.
            stat_cycles: Name of the cycle counter IP.

        """
        # Load the overlay
        self.overlay = Overlay(bitstream)

        # Store IP references
        ## AXI IP
        self.stream_fifo_routes: DefaultIP = self.overlay.__getattr__(stream_fifo_routes)
        self.stream_fifo_mapping: DefaultIP = self.overlay.__getattr__(stream_fifo_mapping)
        self.stream_fifo_weights: DefaultIP = self.overlay.__getattr__(stream_fifo_weights)
        self.axi_intc: DefaultIP = self.overlay.__getattr__(axi_intc)
        self.dma_event_io: DMA = self.overlay.__getattr__(dma_event_io)
        ## CSRs
        self.ctrl_0: DefaultIP = self.overlay.__getattr__(ctrl_0)
        self.ctrl_1: DefaultIP = self.overlay.__getattr__(ctrl_1)
        self.stat_cycles: DefaultIP = self.overlay.__getattr__(stat_cycles)
        # Init DMA receive buffer
        self.output_buffer: PynqBuffer = allocate(shape=(output_buffer_size,), dtype=np.uint32)

        # Stream FIFO registers
        self._sf_registers = {
            'ISR': 0x0,  # Interrupt Status Register
            'IER': 0x4,  # Interrupt Enable Register
            'TDFR': 0x8,  # Transmit Data FIFO Reset
            'TDFV': 0xC,  # Transmit Data FIFO Vacancy
            'TDFD': 0x10,  # Transmit Data FIFO Data
            'TLR': 0x14,  # Transmit Length Register
            'RDFR': 0x18,  # Receive Data FIFO Reset
            'RDFO': 0x1C,  # Receive Data FIFO Occupancy
            'RDFD': 0x20,  # Receive Data FIFO Data
            'RLR': 0x24,  # Receive Length Register
            'SRR': 0x28,  # AXI4 Stream Reset
            'TDR': 0x2C,  # Transmit Destination Register
            'RDR': 0x30,  # Receive Destination Register
            'TID': 0x34,  # Transmit ID Register
            'TUSER': 0x38,  # Transmit USER Register
            'RID': 0x3C,  # Receive ID Register
            'RUSER': 0x40,  # Receive USER Register
            'TEOCC': 0x44,  # Transmit FIFO ECC Configuration Register
            'TCOCC': 0x48,  # Transmit FIFO Counter Configuration Register
            'REOCC': 0x4C,  # Receive FIFO ECC Configuration Register
            'RCOCC': 0x50  # Receive FIFO Counter Configuration Register
        }

        # Initialize experiment tracker
        self.experiment_tracker = ExperimentTracker()

        #
        # Reset sequence for all FIFOs
        #
        for fifo in [self.stream_fifo_routes, self.stream_fifo_mapping, self.stream_fifo_weights]:
            # Read ISR
            isr_value = fifo.mmio.read(self._sf_registers['ISR'])
            if isr_value != 0x1400000:
                raise RuntimeError(f"Expected ISR to be 0x1400000, but got {hex(isr_value)}")
            # Clear ISR
            fifo.mmio.write(self._sf_registers['ISR'], 0xFFFFFFFF)  # Clear reset
            # Read ISR (verifies clear)
            isr_value = fifo.mmio.read(self._sf_registers['ISR'])
            if isr_value != 0x0:
                raise RuntimeError(f"Expected ISR to be 0x0, but got {hex(isr_value)}")
            # Read IER
            ier_value = fifo.mmio.read(self._sf_registers['IER'])
            if ier_value != 0x0:
                raise RuntimeError(f"Expected IER to be 0x0, but got {hex(ier_value)}")
            # Read TDFV
            tdfv_value = fifo.mmio.read(self._sf_registers['TDFV'])
            if tdfv_value != 0x1FC:
                raise RuntimeError(f"Expected TDFV to be 0x1FC, but got {hex(tdfv_value)}")
            # Read RDFO
            rdfo_value = fifo.mmio.read(self._sf_registers['RDFO'])
            if rdfo_value != 0x0:
                raise RuntimeError(f"Expected RDFO to be 0x0, but got {hex(rdfo_value)}")

        #
        # Set CSRs
        #
        self._ctrl_0_shadow_lo = 0
        self._ctrl_0_shadow_hi = 0
        # Default tau_mem_inv for hidden and output cores (packed 32-bit control register 1 value).
        self._ctrl_1_shadow = 0x0042028f
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)
        self.ctrl_0.mmio.write(8, self._ctrl_0_shadow_hi)
        self.ctrl_1.mmio.write(0, self._ctrl_1_shadow)

    # Control Register Map:
    # Control 0 Lo Register (Offset 0):
    #   Bit 0:      Enable bit - Enables the accelerator
    #   Bit 1:      Reset bit
    #   Bit 2:      Start processing bit - Toggled to start processing
    #   Bits 3-12:  Number of output neurons (10 bits, max 1024)
    #   Bits 13-14: Weight memory select (01 for hidden, 10 for output)
    #   Bits 15-16: Mapping memory select (01 for input, 10 for hidden)
    #   Bits 17-18: Routes memory select (01 for hidden, 10 for output)
    #   Bits 19-20: Leak LUT memory select (01 for hidden, 10 for output)
    #
    # Control 0 Hi Register (Offset 8):
    #   Bits 0-23:  Sample length - Number of timestamps in a sample
    #
    # Control 1 Register (Offset 0):
    #   Bits 0-15:  Hidden core tau_mem_inv
    #   Bits 16-31: Output core tau_mem_inv

    @property
    def ctrl_enable(self) -> bool:
        """Get the enable bit from the control register."""
        return bool(self._ctrl_0_shadow_lo & 0x1)

    @ctrl_enable.setter
    def ctrl_enable(self, enable: bool) -> None:
        """Set the enable bit in the control register."""
        if not isinstance(enable, bool):
            raise TypeError("Enable must be a boolean value.")
        if enable:
            self._ctrl_0_shadow_lo |= 0x1
        else:
            self._ctrl_0_shadow_lo &= ~0x1
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def ctrl_reset(self) -> bool:
        """Get the reset bit from the control register."""
        return not bool(self._ctrl_0_shadow_lo & 0x2)

    @ctrl_reset.setter
    def ctrl_reset(self, reset: bool) -> None:
        """Set the reset bit in the control register."""
        if not isinstance(reset, bool):
            raise TypeError("Reset must be a boolean value.")
        if reset:
            self._ctrl_0_shadow_lo &= ~0x2
        else:
            self._ctrl_0_shadow_lo |= 0x2
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def num_output_neurons(self) -> int:
        """Get the number of output neurons from the control register."""
        return (self._ctrl_0_shadow_lo >> 3) & 0x3FF

    @num_output_neurons.setter
    def num_output_neurons(self, num_neurons: int) -> None:
        """Set the number of output neurons in the control register."""
        if not isinstance(num_neurons, int):
            raise TypeError("Number of neurons must be an integer.")
        if not 0 <= num_neurons <= 1024:
            raise ValueError("Number of neurons must be between 0 and 1024.")
        self._ctrl_0_shadow_lo &= ~(0x3FF << 3)  # Clear existing bits
        self._ctrl_0_shadow_lo |= (num_neurons << 3)
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def weight_memory_select(self) -> int:
        """Get the weight memory select bits from the control register."""
        val = (self._ctrl_0_shadow_lo >> 13) & 0x3
        if val == 0x2:
            return 1
        elif val == 0x1:
            return 0
        else:
            return 0  # Default to hidden layer

    @weight_memory_select.setter
    def weight_memory_select(self, select: int) -> None:
        """Set the weight memory select bits in the control register."""
        if not isinstance(select, int):
            raise TypeError("Weight memory select must be an integer.")
        if select not in [0, 1]:
            raise ValueError("Weight memory select must be 0 or 1.")

        # Map 0 and 1 to the actual memory select values (1 and 2)
        encoded_select = select + 1

        self._ctrl_0_shadow_lo &= ~(0x3 << 13)  # Clear existing bits
        self._ctrl_0_shadow_lo |= (encoded_select << 13)
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def mapping_memory_select(self) -> int:
        """Get the mapping memory select bits from the control register."""
        val = (self._ctrl_0_shadow_lo >> 15) & 0x3
        if val == 0x2:
            return 1
        elif val == 0x1:
            return 0
        else:
            return 0  # Default to input layer

    @mapping_memory_select.setter
    def mapping_memory_select(self, select: int) -> None:
        """Set the mapping memory select bits in the control register."""
        if not isinstance(select, int):
            raise TypeError("Mapping memory select must be an integer.")
        if select not in [0, 1]:
            raise ValueError("Mapping memory select must be 0 or 1.")

        # Map 0 and 1 to the actual memory select values (1 and 2)
        encoded_select = select + 1

        self._ctrl_0_shadow_lo &= ~(0x3 << 15)  # Clear existing bits
        self._ctrl_0_shadow_lo |= (encoded_select << 15)
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def routes_memory_select(self) -> int:
        """Get the routes memory select bits from the control register."""
        val = (self._ctrl_0_shadow_lo >> 17) & 0x3
        if val == 0x2:
            return 1
        elif val == 0x1:
            return 0
        else:
            return 0  # Default to hidden layer

    @routes_memory_select.setter
    def routes_memory_select(self, select: int) -> None:
        """Set the routes memory select bits in the control register."""
        if not isinstance(select, int):
            raise TypeError("Routes memory select must be an integer.")
        if select not in [0, 1]:
            raise ValueError("Routes memory select must be 0 or 1.")

        # Map 0 and 1 to the actual memory select values (1 and 2)
        encoded_select = select + 1

        self._ctrl_0_shadow_lo &= ~(0x3 << 17)  # Clear existing bits
        self._ctrl_0_shadow_lo |= (encoded_select << 17)
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def leak_lut_memory_select(self) -> int:
        """Get the leak LUT memory select bits from the control register."""
        val = (self._ctrl_0_shadow_lo >> 19) & 0x3
        if val == 0x2:
            return 1
        elif val == 0x1:
            return 0
        else:
            return 0  # Default to hidden

    @leak_lut_memory_select.setter
    def leak_lut_memory_select(self, select: int) -> None:
        """Set the leak LUT memory select bits in the control register."""
        if not isinstance(select, int):
            raise TypeError("Leak LUT memory select must be an integer.")
        if select not in [0, 1]:
            raise ValueError("Leak LUT memory select must be 0 or 1.")

        # Map 0 and 1 to the actual memory select values (1 and 2)
        encoded_select = select + 1

        self._ctrl_0_shadow_lo &= ~(0x3 << 19)  # Clear existing bits
        self._ctrl_0_shadow_lo |= (encoded_select << 19)
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)

    @property
    def sample_ts_length(self) -> int:
        """Get the sample length from the upper control register."""
        return self._ctrl_0_shadow_hi & 0xFFFFFF

    @sample_ts_length.setter
    def sample_ts_length(self, num_ts: int) -> None:
        """Set the sample length in the upper control register."""
        if not isinstance(num_ts, int):
            raise TypeError("Number of timestamps must be an integer.")
        if not 0 <= num_ts <= 0xFFFFFF:
            raise ValueError("Number of timestamps must be between 0 and 16777215.")
        self._ctrl_0_shadow_hi &= ~0xFFFFFF  # Clear existing bits
        self._ctrl_0_shadow_hi |= num_ts
        self.ctrl_0.mmio.write(8, self._ctrl_0_shadow_hi)

    @property
    def hidden_tau_mem_inv(self) -> int:
        """Get the hidden core tau_mem_inv value from control register 1."""
        return self._ctrl_1_shadow & 0xFFFF

    @hidden_tau_mem_inv.setter
    def hidden_tau_mem_inv(self, tau: int) -> None:
        """Set the hidden core tau_mem_inv value in control register 1."""
        if not isinstance(tau, int):
            raise TypeError("Hidden core tau_mem_inv must be an integer.")
        if not 0 <= tau <= 0xFFFF:
            raise ValueError("Hidden core tau_mem_inv must be between 0 and 65535.")
        self._ctrl_1_shadow &= ~0xFFFF  # Clear existing bits
        self._ctrl_1_shadow |= tau
        self.ctrl_1.mmio.write(0, self._ctrl_1_shadow)

    @property
    def output_tau_mem_inv(self) -> int:
        """Get the output core tau_mem_inv value from control register 1."""
        return (self._ctrl_1_shadow >> 16) & 0xFFFF

    @output_tau_mem_inv.setter
    def output_tau_mem_inv(self, tau: int) -> None:
        """Set the output core tau_mem_inv value in control register 1."""
        if not isinstance(tau, int):
            raise TypeError("Output core tau_mem_inv must be an integer.")
        if not 0 <= tau <= 0xFFFF:
            raise ValueError("Output core tau_mem_inv must be between 0 and 65535.")
        self._ctrl_1_shadow &= ~(0xFFFF << 16)  # Clear existing bits
        self._ctrl_1_shadow |= (tau << 16)
        self.ctrl_1.mmio.write(0, self._ctrl_1_shadow)

    #
    # Core Control Methods
    #
    
    def _start_processing(self) -> None:
        """Start processing by toggling bit 2 of the lower control register."""
        self._ctrl_0_shadow_lo |= (0x1 << 2)  # Set bit 2
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)
        self._ctrl_0_shadow_lo &= ~(0x1 << 2)  # Unset bit 2
        self.ctrl_0.mmio.write(0, self._ctrl_0_shadow_lo)
    
    def report_cycles(self) -> int:
        """Report the number of clock cycles taken to process the last sample."""
        return self.stat_cycles.mmio.read(0)
    
    #
    # Memory Configuration Methods
    #
    
    def weights_write(self, address: int, data: int, select: int) -> None:
        """Transmit weight data to the stream FIFO.

        Args:
            address: {self.WEIGHT_ADDR_WIDTH}-bit address value
            data: {self.WEIGHT_DATA_WIDTH}-bit data value
            select: Select memory bank 0 or 1.
                - 0: hidden weights memory
                - 1: output weights memory
        """
        self.weight_memory_select = select

        # Validate input sizes
        if address >= (1 << self.WEIGHT_ADDR_WIDTH):
            raise ValueError(f"Address must be a {self.WEIGHT_ADDR_WIDTH}-bit value")
        if data >= (1 << self.WEIGHT_DATA_WIDTH):
            raise ValueError(f"Data must be a {self.WEIGHT_DATA_WIDTH}-bit value")

        # Combine address and data into 86-bit value
        combined = (address << self.WEIGHT_DATA_WIDTH) | data

        self._transmit_fifo(self.stream_fifo_weights, combined, self.WEIGHT_ADDR_WIDTH + self.WEIGHT_DATA_WIDTH)

    def weights_write_array(self, addresses: list[int], data: list[int], select: int) -> None:
        """Transmit an array of weight data to the stream FIFO.

        Args:
            data: List of {self.WEIGHT_DATA_WIDTH}-bit data values
            addresses: List of {self.WEIGHT_ADDR_WIDTH}-bit address values
            select: Select memory bank 0 or 1.
                - 0: hidden weights memory
                - 1: output weights memory
        """
        self.weight_memory_select = select

        if len(data) != len(addresses):
            raise ValueError("Data and addresses lists must have the same length.")

        combined_data = []
        for address, d in zip(addresses, data):
            # Validate input sizes
            if address >= (1 << self.WEIGHT_ADDR_WIDTH):
                raise ValueError(f"Address must be a {self.WEIGHT_ADDR_WIDTH}-bit value")
            if d >= (1 << self.WEIGHT_DATA_WIDTH):
                raise ValueError(f"Data must be a {self.WEIGHT_DATA_WIDTH}-bit value")

            # Combine address and data into 86-bit value
            combined = (address << self.WEIGHT_DATA_WIDTH) | d
            combined_data.append(combined)

        self._transmit_fifo_array(self.stream_fifo_weights, combined_data, self.WEIGHT_ADDR_WIDTH + self.WEIGHT_DATA_WIDTH)

    def weights_write_file(self, file_path: str, select: int) -> int:
        """Transmit weight data to the stream FIFO from a memory file.

        Args:
            file_path: Path to the memory file.
            select: Select memory bank 0 or 1.
                - 0: hidden weights memory
                - 1: output weights memory

        Returns:
            Number of weights loaded
        """
        addresses, data = self._read_mem_file(file_path)
        self.weights_write_array(addresses, data, select=select)
        return len(addresses)

    def mapping_write(self, address: int, data: int, select: int) -> None:
        """Transmit neuron mapping data to the mapping stream FIFO.

        Args:
            address: {self.MAPPING_ADDR_WIDTH}-bit address value
            data: {self.MAPPING_DATA_WIDTH}-bit data value
            select: Select memory bank 0 or 1.
                - 0: input mapping memory
                - 1: hidden mapping memory
        """
        self.mapping_memory_select = select
        # Validate input sizes
        if address >= (1 << self.MAPPING_ADDR_WIDTH):
            raise ValueError(f"Address must be a {self.MAPPING_ADDR_WIDTH}-bit value")
        if data >= (1 << self.MAPPING_DATA_WIDTH):
            raise ValueError(f"Data must be a {self.MAPPING_DATA_WIDTH}-bit value")

        # Combine address and data into 44-bit value
        combined = (address << self.MAPPING_DATA_WIDTH) | data

        self._transmit_fifo(self.stream_fifo_mapping, combined, self.MAPPING_ADDR_WIDTH + self.MAPPING_DATA_WIDTH)

    def mapping_write_array(self, addresses: list[int], data: list[int], select: int) -> None:
        """Transmit an array of mapping entries to the mapping stream FIFO.

        Args:
            data: List of {self.MAPPING_DATA_WIDTH}-bit data values
            addresses: List of {self.MAPPING_ADDR_WIDTH}-bit address values
            select: Select memory bank 0 or 1.
                - 0: input mapping memory
                - 1: hidden mapping memory
        """
        self.mapping_memory_select = select

        if len(data) != len(addresses):
            raise ValueError("Data and addresses lists must have the same length.")

        combined_data = []
        for address, d in zip(addresses, data):
            # Validate input sizes
            if address >= (1 << self.MAPPING_ADDR_WIDTH):
                raise ValueError(f"Address must be a {self.MAPPING_ADDR_WIDTH}-bit value")
            if d >= (1 << self.MAPPING_DATA_WIDTH):
                raise ValueError(f"Data must be a {self.MAPPING_DATA_WIDTH}-bit value")

            # Combine address and data into 44-bit value
            combined = (address << self.MAPPING_DATA_WIDTH) | d
            combined_data.append(combined)

        self._transmit_fifo_array(self.stream_fifo_mapping, combined_data, self.MAPPING_ADDR_WIDTH + self.MAPPING_DATA_WIDTH)

    def mapping_write_file(self, file_path: str, select: int) -> int:
        """Transmit routes map data to the stream FIFO from a memory file.

        Args:
            file_path: Path to the memory file.
            select: Select memory bank 0 or 1.
                - 0: input mapping memory
                - 1: hidden mapping memory

        Returns:
            Number of mappings loaded
        """
        addresses, data = self._read_mem_file(file_path, pad_zeros=True)
        self.mapping_write_array(addresses, data, select=select)
        return len(addresses)

    def routes_write(self, address: int, data: int, select: int) -> None:
        """Transmit routing data to the routes stream FIFO.

        Args:
            address: {self.ROUTES_ADDR_WIDTH}-bit address value
            data: {self.ROUTES_DATA_WIDTH}-bit data value
            select: Select memory bank 0 or 1.
                - 0: input routes memory
                - 1: hidden routes memory
        """
        self.routes_memory_select = select

        # Validate input sizes
        if address >= (1 << self.ROUTES_ADDR_WIDTH):
            raise ValueError(f"Address must be a {self.ROUTES_ADDR_WIDTH}-bit value")
        if data >= (1 << self.ROUTES_DATA_WIDTH):
            raise ValueError(f"Data must be a {self.ROUTES_DATA_WIDTH}-bit value")

        # Combine address and data into 88-bit value
        combined = (address << self.ROUTES_DATA_WIDTH) | data

        self._transmit_fifo(self.stream_fifo_routes, combined, self.ROUTES_ADDR_WIDTH + self.ROUTES_DATA_WIDTH)

    def routes_write_array(self, addresses: list[int], data: list[int], select: int) -> None:
        """Transmit an array of routing entries to the routes stream FIFO.

        Args:
            data: List of {self.ROUTES_DATA_WIDTH}-bit data values
            addresses: List of {self.ROUTES_ADDR_WIDTH}-bit address values
            select: Select memory bank 0 or 1.
                - 0: input routes memory
                - 1: hidden routes memory
        """
        self.routes_memory_select = select

        if len(data) != len(addresses):
            raise ValueError("Data and addresses lists must have the same length.")

        combined_data = []
        for address, d in zip(addresses, data):
            # Validate input sizes
            if address >= (1 << self.ROUTES_ADDR_WIDTH):
                raise ValueError(f"Address must be a {self.ROUTES_ADDR_WIDTH}-bit value")
            if d >= (1 << self.ROUTES_DATA_WIDTH):
                raise ValueError(f"Data must be a {self.ROUTES_DATA_WIDTH}-bit value")

            # Combine address and data into 88-bit value
            combined = (address << self.ROUTES_DATA_WIDTH) | d
            combined_data.append(combined)

        self._transmit_fifo_array(self.stream_fifo_routes, combined_data, self.ROUTES_ADDR_WIDTH + self.ROUTES_DATA_WIDTH)

    def routes_write_file(self, file_path: str, select: int) -> int:
        """Transmit routes data to the stream FIFO from a memory file.

        Args:
            file_path: Path to the memory file.
            select: Select memory bank 0 or 1.
                - 0: input routes memory
                - 1: hidden routes memory

        Returns:
            Number of routes loaded
        """
        addresses, data = self._read_mem_file(file_path)
        self.routes_write_array(addresses, data, select=select)
        return len(addresses)

    #
    # Network Loading and Configuration
    #
    
    def load_network(self, dataset_name: str, network_name: str) -> int:
        """Load a network from the experiments directory.

        Args:
            dataset_name: Name of the dataset (e.g., 'SHD', 'NMNIST')
            network_name: Name of the network (e.g., 'network_0')

        Returns:
            Total number of weights loaded
        """
        base_path = f"experiments/{dataset_name}/networks/{network_name}"

        if not os.path.exists(base_path):
            raise FileNotFoundError(f"Network directory not found: {base_path}")

        # Define file paths
        mem_mapping_input_path = os.path.join(base_path, "mem_mapping_input.txt")
        mem_mapping_hidden_path = os.path.join(base_path, "mem_mapping_hidden.txt")
        mem_routing_input_path = os.path.join(base_path, "mem_routing_input.txt")
        mem_routing_hidden_path = os.path.join(base_path, "mem_routing_hidden.txt")
        mem_weights_hidden_path = os.path.join(base_path, "mem_weights_hidden.txt")
        mem_weights_output_path = os.path.join(base_path, "mem_weights_output.txt")

        # Load and write mapping files
        print(f"Loading network {network_name} for dataset {dataset_name}...")
        print("Loading mapping files...")
        mapping_input_count = self.mapping_write_file(mem_mapping_input_path, 0)  # Input layer mapping (select=0)
        mapping_hidden_count = self.mapping_write_file(mem_mapping_hidden_path, 1)  # Hidden layer mapping (select=1)
        total_mapping_lines = mapping_input_count + mapping_hidden_count
        mapping_kb_transferred = (total_mapping_lines * self.MAPPING_DATA_WIDTH) / (8 * 1024)
        print(f"  Mapping files loaded successfully ({total_mapping_lines} lines, {mapping_kb_transferred:.2f} KB transferred)")

        # Load and write routing files
        print("Loading routing files...")
        routing_input_count = self.routes_write_file(mem_routing_input_path, 0)  # Input layer routing (select=0)
        routing_hidden_count = self.routes_write_file(mem_routing_hidden_path, 1)  # Hidden layer routing (select=1)
        total_routing_lines = routing_input_count + routing_hidden_count
        routing_kb_transferred = (total_routing_lines * self.ROUTES_DATA_WIDTH) / (8 * 1024)
        print(f"  Routing files loaded successfully ({total_routing_lines} lines, {routing_kb_transferred:.2f} KB transferred)")

        # Load and write weight files
        print("Loading weight files...")
        weights_hidden_count = self.weights_write_file(mem_weights_hidden_path, 0)  # Hidden layer weights (select=0)
        weights_output_count = self.weights_write_file(mem_weights_output_path, 1)  # Output layer weights (select=1)
        total_weight_lines = weights_hidden_count + weights_output_count
        weights_kb_transferred = (total_weight_lines * self.WEIGHT_DATA_WIDTH) / (8 * 1024)
        total_logical_weights = total_weight_lines * 4
        print(f"  Weight files loaded successfully ({total_logical_weights} weights, {weights_kb_transferred:.2f} KB transferred)")

        print("Network configuration complete!")

        return total_logical_weights

    def _get_num_output_neurons(self, dataset_name: str, network_name: str) -> int:
        """Determine the number of output neurons from the output trace file.
        
        Args:
            dataset_name: Name of the dataset
            network_name: Name of the network
            
        Returns:
            Number of output neurons
        """
        try:
            trace_file_path = f"experiments/{dataset_name}/networks/{network_name}/output_traces/neuron_state_trace_0.txt"
            
            if not os.path.exists(trace_file_path):
                print(f"Warning: Output trace file not found: {trace_file_path}")
                return 10
                
            with open(trace_file_path, "r") as file:
                lines = file.readlines()
                
            if not lines:
                print(f"Warning: Output trace file is empty: {trace_file_path}")
                return 10
                
            last_line = lines[-1].strip()
            parts = last_line.split()
            
            if len(parts) < 2:
                print(f"Warning: Invalid format in output trace file: {trace_file_path}")
                return 10
                
            num_neurons = int(parts[1]) + 1
            return num_neurons
                
        except Exception as e:
            print(f"Warning: Error determining number of output neurons: {e}")
            return 10

    #
    # Sample Evaluation Methods
    #
    
    def evaluate_sample_array(self, timesteps: np.ndarray, source_neuron_ids: np.ndarray, expected_class: int = None,
                              verbose: bool = True, sample_index: int = None,
                              dataset_name: str = None, network_name: str = None, sample_ts_length: int = 103) -> Tuple[int, int, int, int, float]:
        """Run inference on a spike sample given as timestep and source-neuron arrays.

        Args:
            timesteps: Per-event timestep indices.
            source_neuron_ids: Per-event source neuron IDs (same length as ``timesteps``).
            expected_class: Optional label for accuracy bookkeeping.
            verbose: If True, print diagnostics and comparison to golden traces when available.
            sample_index: Sample index for loading ``output_traces/neuron_state_trace_{i}.txt``.
            dataset_name: Dataset folder under ``experiments/`` for golden traces.
            network_name: Network folder for golden traces.
            sample_ts_length: Sample length (timesteps) written to the control register. Must match
                the deployed network and timing assumptions; it is not derived from ``timesteps`` yet.

        Returns:
            ``(output_class, total_events, total_timesteps, cycles, mse)``. ``mse`` is -1 if not computed.
        """
        # Check if arrays are not greater than IN_SAMPLE_MAX_EVENTS
        if len(timesteps) > self.IN_SAMPLE_MAX_EVENTS or len(source_neuron_ids) > self.IN_SAMPLE_MAX_EVENTS:
            raise ValueError(f"Number of events exceeds maximum allowed: {self.IN_SAMPLE_MAX_EVENTS}")
        if len(timesteps) != len(source_neuron_ids):
            raise ValueError("Timesteps and source neuron IDs arrays must have the same length.")

        # Calculate total timesteps (from the last timestep in the array)
        total_timesteps = int(timesteps[-1]) + 1  # +1 because timesteps are 0-indexed
        self.sample_ts_length = sample_ts_length

        # Reformat the input arrays to a single array of uint32
        combined_arrays = self._combine_arrays(timesteps, source_neuron_ids)

        self._dma_write(combined_arrays)
        self._start_processing()

        # Get sample stats
        total_events = len(timesteps)
        if verbose:
            self._print_sample_array_stats(timesteps, source_neuron_ids)
        sleep(0.25)

        output_potentials = self._dma_read()
        output_potentials_parsed = output_potentials[:self.num_output_neurons]
        output_potentials_fixed = self._states_to_fixed(output_potentials_parsed)
        output_potentials_softmax = self._log_softmax(output_potentials_fixed)
        output_class = np.argmax(output_potentials_softmax)

        cycles = self.report_cycles()

        if verbose:
            print("Output Potentials (float):\n ",
                  ["{:.4f}".format(x.to_float()) for x in output_potentials_fixed])
            print("Output Probabilities:\n ",
                  ["{:.4f}".format(np.exp(x)) for x in output_potentials_softmax])
            print("Output Class:\n ",
                  output_class)
            _clock_hz = self.PL_CLOCK_MHZ * 1e6
            _ms = cycles / (_clock_hz / 1000.0)
            print("Amount of clock cycles to process the sample:\n ",
                  cycles, f"(~{_ms:.3f} ms at {self.PL_CLOCK_MHZ} MHz)")

        # Calculate MSE if sample_index, dataset_name, and network_name are provided
        mse = -1
        expected_class_internal = None
        if sample_index is not None and dataset_name is not None and network_name is not None:
            try:
                trace_file_path = f"experiments/{dataset_name}/networks/{network_name}/output_traces/neuron_state_trace_{sample_index}.txt"
                expected_outputs_raw = self._read_output_trace_file(trace_file_path, self.num_output_neurons)
                expected_outputs_fixed = self._states_to_fixed(expected_outputs_raw)
                expected_class_softmax = self._log_softmax(expected_outputs_fixed)
                expected_class_internal = int(np.argmax(expected_class_softmax))
                mse = self.calculate_mse(output_potentials_fixed, expected_outputs_fixed)

                if verbose:
                    print("Expected Output Potentials (float):\n ",
                          ["{:.4f}".format(x.to_float()) for x in expected_outputs_fixed])
                    print("MSE:\n ",
                          f"{mse:.6f}")
            except Exception as e:
                if verbose:
                    print(f"Warning: Could not calculate MSE: {e}")

            if expected_class_internal is not None:
                print("Expected Class:\n ",
                      f"{expected_class_internal}")
                print(f"Classification {'Correct' if output_class == expected_class_internal else 'Incorrect'}")

        return output_class, total_events, total_timesteps, cycles, mse

    def evaluate_sample_trace_file(self, file_path: str, expected_class: int = None, verbose: bool = True,
                                  sample_index: int = None, dataset_name: str = None, 
                                  network_name: str = None, sample_ts_length: int = 103) -> Tuple[int, int, int, int, float]:
        """Evaluates a sample from a trace file.

        Args:
            file_path: Path to the trace file.
            expected_class: Expected class for the sample (for accuracy tracking)
            verbose: Whether to print detailed output
            sample_index: Index of the sample (for finding expected output trace)
            dataset_name: Name of the dataset (for finding expected output trace)
            network_name: Name of the network (for finding expected output trace)

        Returns:
            Tuple containing (output_class, total_events, total_timesteps, cycles, mse)
        """
        # Get timesteps and neuron_ids as numpy arrays directly
        timesteps, neuron_ids = self._read_in_trace_file(file_path)
        return self.evaluate_sample_array(timesteps, neuron_ids, expected_class, verbose, 
                                         sample_index, dataset_name, network_name, sample_ts_length)

    #
    # Experiment Management Methods
    #
    
    def run_experiment(self, dataset_name: str, network_name: str, sample_ts_length: int = 103, verbose: bool = False) -> Dict:
        """Run an experiment with a specific network on a dataset.

        Args:
            dataset_name: Name of the dataset (e.g., 'SHD', 'NMNIST')
            network_name: Name of the network (e.g., 'network_0')
            verbose: Whether to print detailed output for each sample

        Returns:
            Dictionary with experiment results
        """
        # Reset the accelerator
        self.ctrl_enable = False
        self.ctrl_reset = True
        sleep(0.1)
        self.ctrl_reset = False
        
        # Determine the number of output neurons from the output trace file
        self.num_output_neurons = self._get_num_output_neurons(dataset_name, network_name)
        print(f"Using {self.num_output_neurons} output neurons for this network")
        
        self.ctrl_enable = True

        # Load the network
        weight_count = self.load_network(dataset_name, network_name)

        # Update experiment with weight count
        self.experiment_tracker.update_experiment(
            dataset_name,
            network_name,
            weight_count=weight_count
        )

        # Get samples from YAML file
        samples_yaml_path = f"experiments/{dataset_name}/test_samples/sample_info.yaml"
        samples = self.experiment_tracker.parse_samples_yaml(samples_yaml_path)

        print(f"\nRunning experiment: {dataset_name}/{network_name}")
        print(f"Processing {len(samples)} samples...")

        total_events = 0
        total_cycles = 0
        total_timesteps = 0
        correct_classifications = 0
        total_mse = 0.0
        total_mse_samples = 0

        # Process each sample
        for i, (sample_path, expected_class) in enumerate(samples):
            print(f"\nSample {i + 1}/{len(samples)}: {os.path.basename(sample_path)}")
            
            # Extract sample index from filename
            sample_filename = os.path.basename(sample_path)
            sample_index = int(sample_filename.split('_')[1].split('.')[0])

            # Evaluate the sample
            output_class, events, timesteps, cycles, mse = self.evaluate_sample_trace_file(
                sample_path,
                expected_class=expected_class,
                verbose=verbose,
                sample_index=sample_index,
                dataset_name=dataset_name,
                network_name=network_name,
                sample_ts_length=sample_ts_length
            )

            # Update statistics
            total_events += events
            total_cycles += cycles
            total_timesteps += timesteps
            if output_class == expected_class:
                correct_classifications += 1
                
            # Update MSE statistics if valid
            if mse > -1:
                total_mse += mse
                total_mse_samples += 1

            # Print brief result if not verbose
            if not verbose:
                print(f"  Output Class: {output_class}, Expected: {expected_class}, " +
                      f"{'Correct' if output_class == expected_class else 'Incorrect'}")
                print(f"  Events: {events}, Timesteps: {timesteps}, Cycles: {cycles}, MSE: {mse:.6f}")

        # Update experiment tracker
        self.experiment_tracker.update_experiment(
            dataset_name,
            network_name,
            events=total_events,
            cycles=total_cycles,
            timesteps=total_timesteps,
            correct=correct_classifications,
            total=len(samples),
            mse=total_mse,
            mse_samples=total_mse_samples
        )

        # Get updated experiment data
        experiment_data = self.experiment_tracker.get_experiment(dataset_name, network_name)

        print("\nExperiment complete!")
        print(f"Accuracy: {correct_classifications}/{len(samples)} " +
              f"({(correct_classifications / len(samples)) * 100:.2f}%)")
        if total_mse_samples > 0:
            print(f"MSE: {total_mse/total_mse_samples:.6f}")
        print("\n")

        return experiment_data

    def print_experiment_results(self):
        """Print the results of all experiments."""
        self.experiment_tracker.print_results()

    def export_experiment_results(self, output_file: str):
        """Export the experiment results to a .csv file."""
        self.experiment_tracker.export_all_to_csv(output_file)

    def reset_experiment_tracker(self):
        """Reset the experiment tracker."""
        self.experiment_tracker.reset()

    #
    # Data Processing Utilities
    #
    
    def _read_in_trace_file(self, file_path: str) -> tuple[np.ndarray, np.ndarray]:
        """Read a trace file and return arrays of timesteps and neuron IDs.

        Args:
            file_path: Path to the trace file.

        Returns:
            tuple[np.ndarray, np.ndarray]: Arrays of timesteps and neuron IDs.
        """
        try:
            with open(file_path, "r") as file:
                lines = file.readlines()
        except FileNotFoundError:
            raise FileNotFoundError(f"Trace file not found: {file_path}")

        # Remove whitespace and empty lines
        lines = [line.strip() for line in lines if line.strip()]

        # Split lines into timesteps and neuron_ids
        split_lines = [line.split() for line in lines]

        # Validate line format
        for line in split_lines:
            if len(line) != 2:
                raise ValueError(
                    f"Invalid line format in trace file: {line}. Expected 'timestep neuron_id'.")

        # Convert to numpy arrays
        try:
            timesteps = np.array([int(line[0]) for line in split_lines], dtype=np.uint32)
            neuron_ids = np.array([int(line[1], 2) for line in split_lines], dtype=np.uint32)
        except ValueError:
            raise ValueError(
                "Invalid data in trace file. Timesteps must be integers and neuron IDs must be binary strings.")

        # Validate neuron_id length
        for neuron_id in split_lines:
            if len(neuron_id[1]) != self.IN_EVENT_NEURON_WIDTH:
                raise ValueError(
                    f"Data in trace file must be a {self.IN_EVENT_NEURON_WIDTH}-bit binary string, got {len(neuron_id[1])} bits.")

        return timesteps, neuron_ids

    def _combine_arrays(self, timesteps: np.ndarray, source_neuron_ids: np.ndarray) -> np.ndarray:
        """Combines timesteps and source neuron IDs into a single array of uint32.

        Args:
            timesteps: Array of timesteps.
            source_neuron_ids: Array of source neuron IDs.

        Returns:
            A combined numpy array of uint32 values.
        """
        combined_arrays = np.zeros(len(timesteps), dtype=np.uint32)
        for i in range(len(timesteps)):
            combined_arrays[i] = (timesteps[i] << self.IN_EVENT_NEURON_WIDTH) | source_neuron_ids[i]
        return combined_arrays

    def _print_sample_array_stats(self, timesteps: np.ndarray, source_neuron_ids: np.ndarray) -> None:
        """Print statistics about the sample array.

        Args:
            timesteps: Array of timesteps.
            source_neuron_ids: Array of source neuron IDs.
        """
        # Total timesteps (from the last timestep in the array)
        total_timesteps = int(timesteps[-1]) + 1  # +1 because timesteps are 0-indexed

        # Total number of events
        total_events = len(timesteps)

        # Count events per timestep
        events_per_timestep = {}
        for ts in timesteps:
            ts_int = int(ts)
            if ts_int in events_per_timestep:
                events_per_timestep[ts_int] += 1
            else:
                events_per_timestep[ts_int] = 1

        # Timesteps without any event
        timesteps_without_events = total_timesteps - len(events_per_timestep)

        # Calculate statistics (for all timesteps with events)
        if events_per_timestep:
            avg_events = total_events / len(events_per_timestep)
            max_events = max(events_per_timestep.values())
            min_events = min(events_per_timestep.values())
        else:
            avg_events = max_events = min_events = 0

        # Print statistics
        print(f"Sample Statistics:")
        print(f"  Total timesteps: {total_timesteps}")
        print(f"  Total events: {total_events}")
        print(f"  Timesteps without events: {timesteps_without_events}")
        print(f"  Avg events per timestep: {avg_events:.2f}")
        print(f"  Max events per timestep: {max_events}")
        print(f"  Min events per timestep: {min_events}")

    #
    # DMA and Data Transfer Methods
    #
    
    def _dma_write(self, data: np.ndarray):
        """Writes data to the DMA input buffer.

        Args:
            data: Data to write.
        """
        temp_buffer: PynqBuffer = allocate(shape=data.shape, dtype=np.uint32)
        np.copyto(temp_buffer, data)
        self.dma_event_io.sendchannel.transfer(temp_buffer)
        self.dma_event_io.sendchannel.wait()
        temp_buffer.freebuffer()
        del temp_buffer

    def _dma_read(self) -> np.ndarray:
        """Reads data from the DMA output buffer.

        Returns:
            Output data.
        """
        self.dma_event_io.recvchannel.transfer(self.output_buffer)
        # self.dma_event_io.recvchannel.wait() is not used here; a short sleep allows the transfer to complete before copy.
        sleep(0.01)
        output_data = np.copy(self.output_buffer)
        return output_data

    def _transmit_fifo(self, fifo: DefaultIP, data: int, total_bits: int) -> None:
        """Transmit data to the specified FIFO.

        Args:
            fifo: The FIFO object to transmit to.
            data: The combined data to transmit.
            total_bits: The total number of bits in the combined data.
        """
        packet_size = ((total_bits + 31) // 32) * 32

        while fifo.register_map.TDFV.Vacancy <= 16:
            sleep(0.01)

        remaining_bits = total_bits
        while remaining_bits > 0:
            bits_to_take = min(32, remaining_bits)
            chunk = (data >> (total_bits - remaining_bits)) & ((1 << bits_to_take) - 1)
            fifo.register_map.TDFD = chunk
            remaining_bits -= bits_to_take
        fifo.register_map.TLR = packet_size // 8

    def _transmit_fifo_array(self, fifo: DefaultIP, data: list[int], total_bits: int) -> None:
        """Transmit an array of data to the specified FIFO.

        Args:
            fifo: The FIFO object to transmit to.
            data: The list of combined data to transmit.
            total_bits: The total number of bits in each combined data element.
        """

        for d in data:
            self._transmit_fifo(fifo, d, total_bits)

    #
    # Numerical Processing Methods
    #
    
    def _states_to_fixed(self, states: np.ndarray) -> List[FixedPoint]:
        """Convert raw uint32 words to ``FixedPoint`` using ``OUT_POT_*`` format constants."""
        # Mask to extract valid bits
        bitmask = (1 << self.OUT_POT_WORD_WIDTH) - 1
        masked = states.astype(np.uint64) & bitmask

        # Handle signed/unsigned conversion
        if self.OUT_POT_SIGN:
            threshold = 1 << (self.OUT_POT_WORD_WIDTH - 1)
            is_negative = masked >= threshold
            integer_values = np.where(
                is_negative,
                masked - (1 << self.OUT_POT_WORD_WIDTH),
                masked
            ).astype(np.int64)
        else:
            integer_values = masked.astype(np.uint64)

        states_fixed_point = []
        for integer in integer_values:
            states_fixed_point.append(
                FixedPoint(
                    int(integer),
                    QuantScheme(
                        self.OUT_POT_WORD_WIDTH - self.OUT_POT_FRAC_WIDTH,
                        self.OUT_POT_FRAC_WIDTH,
                        self.OUT_POT_SIGN
                    )
                )
            )

        return states_fixed_point

    def _log_softmax(self, x: List[FixedPoint]) -> np.ndarray:
        """Compute log-softmax over one vector of scores (as ``FixedPoint``)."""
        x_np = np.array([value.to_float() for value in x])

        e_x = np.exp(x_np - np.max(x_np))
        return np.log(e_x / e_x.sum(axis=0))

    def calculate_mse(self, actual_fixed: List[FixedPoint], expected_fixed: List[FixedPoint]) -> float:
        """Calculate Mean Squared Error between actual and expected outputs.
        
        Args:
            actual_fixed: Actual output values as FixedPoint objects
            expected_fixed: Expected output values as FixedPoint objects
            
        Returns:
            Mean Squared Error
        """
        if len(actual_fixed) != len(expected_fixed):
            raise ValueError("Actual and expected arrays must have the same length")
            
        # Convert to float values
        actual_float = np.array([x.to_float() for x in actual_fixed])
        expected_float = np.array([x.to_float() for x in expected_fixed])
        
        # Calculate MSE
        squared_diff = (actual_float - expected_float)**2
        return np.mean(squared_diff)

    def _read_output_trace_file(self, file_path: str, num_output_neurons: int) -> np.ndarray:
        """Read an output trace file and return the final state values.
        
        Args:
            file_path: Path to the output trace file
            num_output_neurons: Number of output neurons to read
            
        Returns:
            Array of final output neuron states
        """
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"Output trace file not found: {file_path}")
            
        try:
            with open(file_path, "r") as file:
                lines = file.readlines()
                
            # Get only the last num_output_neurons lines
            last_lines = lines[-num_output_neurons:]
            
            # Parse the values (format: timestep neuron_id value)
            output_values = np.zeros(num_output_neurons, dtype=np.uint32)
            for i, line in enumerate(last_lines):
                parts = line.strip().split()
                if len(parts) != 3:
                    raise ValueError(f"Invalid line format in trace file: {line}")
                    
                # The third value is the neuron state in binary format
                output_values[i] = int(parts[2], 2)
                
            return output_values
                
        except Exception as e:
            raise ValueError(f"Error reading output trace file: {e}")
    
    def _read_mem_file(self, file_path: str, pad_zeros: bool = False) -> tuple[list[int], list[int]]:
        """Reads a memory file containing addresses and data.

        Args:
            file_path: Path to the memory file.
            pad_zeros: Flag to pad the file with zero entries for all addresses that are not listed.

        Returns:
            A tuple containing two lists: addresses and data.

        Raises:
            FileNotFoundError: If the specified file does not exist.
            ValueError: If the file format is invalid or if the number of addresses and data entries do not match.
        """
        addresses = []
        data = []

        try:
            with open(file_path, "r") as file:
                addr = True
                for line in file:
                    line = line.strip()
                    if line == "":
                        continue
                    if addr:
                        addr = False
                        addresses.append(int(line, 16))
                    else:
                        addr = True
                        data.append(int(line, 16))
        except FileNotFoundError:
            raise FileNotFoundError(f"Memory file not found: {file_path}")
        except ValueError as e:
            raise ValueError(f"Invalid data in memory file: {e}")

        if len(addresses) != len(data):
            raise ValueError("Address and data entries not matching.")

        if pad_zeros:
            for addr_idx in range(1 << self.MAPPING_ADDR_WIDTH):
                if addr_idx not in addresses:
                    addresses.append(addr_idx)
                    data.append(0)

        return addresses, data

    def __del__(self):
        """Destructor to clean up resources when the object is destroyed."""
        try:
            if hasattr(self, 'output_buffer') and self.output_buffer is not None:
                self.output_buffer.freebuffer()
                del self.output_buffer
        except Exception as e:
            print(f"Warning: Error during cleanup: {e}")

if __name__ == "__main__":
    raise SystemExit(
        "yana_fpga is a library module; import YanaFpga from application or notebook code."
    )