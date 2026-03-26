`ifndef _global_params_h
`define _global_params_h

`include "math.vh"


// --------------------------------------------------------
// --------------------------------------------------------
//    General Project Configuration
// --------------------------------------------------------
// --------------------------------------------------------

// --------------------------------------------------------
// --------------------------------------------------------
//    Define Constants dependent on FPGA architecture
// --------------------------------------------------------
// --------------------------------------------------------

// UltraScale+ values
localparam URAM_SIZE_G = 288 * 1024; // 288 size URAM in kb
localparam URAM_BUS_WIDTH_G = 72;
localparam URAM_BYTE_WIDTH_G   = 9;  // 9 for "PARITY_INTERLEAVED" or 8 for "PARITY_INDEPENDENT"

localparam BRAM_SIZE_G = 36 * 1024;
localparam BRAM_BUS_WIDTH_G = 36;

// --------------------------------------------------------
// --------------------------------------------------------
//    General Configuration
// --------------------------------------------------------
// --------------------------------------------------------

localparam NUM_CORES_G = 4;

localparam NEURONS_PER_CORE_G = 1024;
localparam SYNAPSES_PER_CORE_G = NEURONS_PER_CORE_G * 128;

// URAM_BUS_WIDTH_G / WEIGHT_WIDTH_G must be a multiple of two.
localparam WEIGHT_WIDTH_G = 18; // Q8.10
localparam WEIGHT_SUM_WIDTH_G = 31; // Q21.10 with fractionals defined below

// --------------------------------------------------------
// --------------------------------------------------------
//    Input Data Configuration
// --------------------------------------------------------
// --------------------------------------------------------
localparam TIMESTEP_WIDTH_G     = 16;
// Event source index width (e.g. 1024 channels -> 10 bits).
localparam INPUT_EVENT_SOURCE_WIDTH_G = 10;

// --------------------------------------------------------
// --------------------------------------------------------
//    Control Unit Configuration
// --------------------------------------------------------
// --------------------------------------------------------
localparam INSTRUCTION_WIDTH_G                  = 8;
localparam PARAM_WIDTH_G                        = 56;
localparam CONTROL_UNIT_STATE_WIDTH_G           = 4;
localparam CONTROL_UNIT_RUN_MODE_WIDTH_G        = 4;
localparam CONTROL_UNIT_INT_MODE_WIDTH_G        = 1;
localparam CONTROL_UNIT_RST_TYPE_WIDTH_G        = 2;
localparam CONTROL_UNIT_RST_LEN_WIDTH_G         = 8;
localparam CONTROL_UNIT_RST_MEM_TARGET_WIDTH_G  = 4;
localparam CONTROL_UNIT_STATUS_REGISTER_WIDTH_G = 32;
localparam CONTROL_UNIT_STATUS_CODE_WIDTH_G     = 8;
localparam CONTROL_UNIT_STATUS_DATA_WIDTH_G     = 24;
localparam CONTROL_UNIT_MEM_TARGET_WIDTH_G      = 4;

// --------------------------------------------------------
// --------------------------------------------------------
//    Buffers
// --------------------------------------------------------
// --------------------------------------------------------

// Control Unit buffers
localparam COMMAND_BUFFER_WIDTH_G = 64;
localparam COMMAND_BUFFER_DEPTH_G = 64;
localparam INPUT_BUFFER_WIDTH_G   = 32;
localparam INPUT_BUFFER_DEPTH_G   = 2048;
localparam OUTPUT_BUFFER_WIDTH_G  = 32;
localparam OUTPUT_BUFFER_DEPTH_G  = 16;

// Accelerator buffers
localparam ROUTER_BUFFER_DEPTH_G = 8;
localparam INIT_PACKET_MAX_BYTES_G = 4;
localparam AXON_BUFFER_DEPTH_G = 5;

localparam RX_BUFFER_DEPTH_G = 4;

// fixed point format Q21.10
localparam QUAD_PORT_MUX_RAM_DECIMALS_G = 10;

// --------------------------------------------------------
// --------------------------------------------------------
//   Neuron Wrapper and Neuron Configuration
// --------------------------------------------------------
// --------------------------------------------------------
`include "./original.vh"
`include "./default_output.vh"

localparam TIMESTEP_RAM_DATA_WIDTH_G = TIMESTEP_WIDTH_G;

// Flag for making output core a I instead of LI neuron
localparam OUT_CORE_NEURON_LEAK_STATES_G = 1;    // If set to 0, states will not leak

// --------------------------------------------------------
// --------------------------------------------------------
//    Memory init file paths
// --------------------------------------------------------
// --------------------------------------------------------

localparam WEIGHT_RAM_INIT_FILE_G = "";
localparam QUAD_PORT_MUX_RAM_INIT_FILE_G = "";
localparam NEURON_STATE_INIT_FILE_G      = "";
localparam TIMESTEP_RAM_INIT_FILE_G      = "";
localparam AXON_ROUTES_RAM_INIT_FILE_G = "";
localparam AXON_MEMORY_MAPPING_RAM_INIT_FILE_G = "";

// Module-specific init files
localparam WEIGHT_RAM_INIT_FILE_CORE_TOP_G = "";
localparam WEIGHT_RAM_INIT_FILE_OUTPUT_CORE_G = "";
localparam AXON_MAPPING_RAM_INIT_FILE_MULTICAST_G = "";
localparam AXON_MAPPING_RAM_INIT_FILE_CORE_TOP_G = "";
localparam AXON_ROUTES_RAM_INIT_FILE_MULTICAST_G = "";
localparam AXON_ROUTES_RAM_INIT_FILE_CORE_TOP_G = "";

// --------------------------------------------------------
// --------------------------------------------------------
//    Derived constants
// --------------------------------------------------------
// --------------------------------------------------------

// Input data
localparam INPUT_PACKET_WIDTH_G = TIMESTEP_WIDTH_G + INPUT_EVENT_SOURCE_WIDTH_G;

// Addressing/Layout
localparam NUM_CORES_WIDTH_G = $clog2(NUM_CORES_G);
localparam NEURON_WIDTH_G = $clog2(NEURONS_PER_CORE_G);
localparam SYNAPSE_WIDTH_G = $clog2(SYNAPSES_PER_CORE_G);

// NoC
localparam GRID_DIMENSION_X_G = crtoi($sqrt(real'(NUM_CORES_G)));  // crtoi = ceiling real to integer
localparam GRID_DIMENSION_Y_G = NUM_CORES_G / GRID_DIMENSION_X_G;


// RX CONFIGURATION
localparam INPUT_DATA_WIDTH_G = NEURON_WIDTH_G + SYNAPSE_WIDTH_G;


// SYNAPSE CONFIGURATION
// calculate the amount of toal memory lines needed and take log2
// It is important, that URAM_BUS_WIDTH_G / WEIGHT_WIDTH_G is a multiple of two
localparam WEIGHT_RAM_ADDR_WIDTH_G = $clog2(
    SYNAPSES_PER_CORE_G / (URAM_BUS_WIDTH_G / WEIGHT_WIDTH_G)
);
localparam WEIGHT_RAM_DATA_WIDTH_G = URAM_BUS_WIDTH_G;
localparam WEIGHT_RAM_BYTE_WIDTH_G = URAM_BYTE_WIDTH_G;
localparam WEIGHT_RAM_WEIGHT_WIDTH_G = WEIGHT_WIDTH_G;



// QUAD_PORT_MUX_RAM CONFIGURATION
localparam QUAD_PORT_MUX_RAM_ADDR_WIDTH_G = NEURON_WIDTH_G;
localparam QUAD_PORT_MUX_RAM_DATA_WIDTH_G = WEIGHT_SUM_WIDTH_G + 1; // +1 for flag bit if entry is stored in Hot Neuron FIFO or not


// HOT NEURON FIFO CONFIGURATION
// +1 for timestep flag bit
localparam HOT_NEURON_FIFO_DATA_WIDTH_G = NEURON_WIDTH_G + 1;


// NEURON WRAPPER CONFIGURATION
localparam NEURON_STATE_ADDR_WIDTH_G = NEURON_WIDTH_G;
localparam TIMESTEP_RAM_ADDR_WIDTH_G = NEURON_WIDTH_G;


// SPIKE OUT FIFO CONFIGURATION
localparam SPIKE_OUT_FIFO_DATA_WIDTH_G = NEURON_WIDTH_G;


// AXON CONFIGURATION

// Routes RAM Configuration
localparam AXON_ROUTES_RAM_DATA_WIDTH_G = URAM_BUS_WIDTH_G;
localparam AXON_ROUTES_RAM_ENTRY_WIDTH_G = NUM_CORES_WIDTH_G + NEURON_WIDTH_G + SYNAPSE_WIDTH_G;
localparam AXON_ROUTES_RAM_BYTE_WIDTH_G = URAM_BYTE_WIDTH_G;
localparam AXON_ROUTES_PER_CORE_G = NEURONS_PER_CORE_G * 128; // Results in width of 15. Keeps mapping RAM data width within 32 Bits
localparam AXON_ROUTES_RAM_ADDR_WIDTH_G = $clog2(AXON_ROUTES_PER_CORE_G / (AXON_ROUTES_RAM_DATA_WIDTH_G / AXON_ROUTES_RAM_ENTRY_WIDTH_G));

// Memory Mapping RAM Configuration
localparam AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH_G = NEURON_WIDTH_G;

localparam URAM_MEMORY_MAPPING_START_ADDR_WIDTH_G = AXON_ROUTES_RAM_ADDR_WIDTH_G;
// Fan-out is encoded as a line count; maximum routes per neuron is related to these widths.
localparam URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH_G = AXON_ROUTES_RAM_ADDR_WIDTH_G;
localparam URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH_G = $clog2(
    ceil_division(AXON_ROUTES_RAM_DATA_WIDTH_G, AXON_ROUTES_RAM_ENTRY_WIDTH_G)
);

localparam AXON_MEMORY_MAPPING_RAM_DATA_WIDTH_G = URAM_MEMORY_MAPPING_START_ADDR_WIDTH_G + URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH_G + URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH_G;


// OUTPUT FIFO CONFIGURATION
localparam OUTPUT_FIFO_DATA_WIDTH_G = AXON_ROUTES_RAM_ENTRY_WIDTH_G;


// TX CONFIGURATION
localparam OUTPUT_INTERNAL_DATA_WIDTH_G = INPUT_DATA_WIDTH_G;
localparam OUTPUT_EXTERNAL_DATA_WIDTH_G = NUM_CORES_WIDTH_G + INPUT_DATA_WIDTH_G;

// CONTROL UNIT CONFIGURATION
localparam COMMAND_WIDTH_G                     = INSTRUCTION_WIDTH_G + PARAM_WIDTH_G;
localparam CONTROL_UNIT_OUT_READ_START_WIDTH_G = NEURON_WIDTH_G;
localparam CONTROL_UNIT_OUT_READ_END_WIDTH_G   = NEURON_WIDTH_G;

`endif
