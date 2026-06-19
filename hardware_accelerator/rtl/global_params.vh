`ifndef _global_params_h
`define _global_params_h

`include "math.vh"

// --------------------------------------------------------
// --------------------------------------------------------
//    Define Constants dependent on FPGA architecture
// --------------------------------------------------------
// --------------------------------------------------------

`ifndef VENDOR_STRING_G
    `ifdef VERILATOR
        `define VENDOR_STRING_G "GENERIC"
    `else
        `define VENDOR_STRING_G "XILINX"
    `endif
`endif

localparam string VENDOR_G = `VENDOR_STRING_G;

// UltraScale+ values
localparam URAM_WIDTH_G = 72;

// Number of cycles before raising sleep signal on Xilinx Memory Blocks
localparam CYCLES_RAISE_SLEEP_G = 4;

// --------------------------------------------------------
// --------------------------------------------------------
//    General Configuration
// --------------------------------------------------------
// --------------------------------------------------------

localparam NUM_CORES_X_G = 2;
localparam NUM_CORES_Y_G = 2;
localparam NUM_CORES_G   = NUM_CORES_X_G * NUM_CORES_Y_G;

localparam NEURONS_PER_CORE_G = 1024;
// localparam WEIGHTS_PER_CORE_G = 131_072;
// localparam ROUTES_PER_CORE_G  = 131_072;
localparam WEIGHTS_PER_CORE_G = 65_536;
localparam ROUTES_PER_CORE_G  = 65_536;

localparam WEIGHT_WIDTH_G             = 18; // Q8.10
localparam WEIGHT_WIDTH_FRACTIONALS_G = 10;
localparam WEIGHT_SUM_WIDTH_G         = 31; // Q21.10

// --------------------------------------------------------
// --------------------------------------------------------
//    Input Data Configuration
// --------------------------------------------------------
// --------------------------------------------------------
localparam TIMESTEP_WIDTH_G = 16;

// --------------------------------------------------------
// --------------------------------------------------------
//    Control Unit Configuration
// --------------------------------------------------------
// --------------------------------------------------------
localparam INSTRUCTION_WIDTH_G                     = 8;
localparam PARAM_WIDTH_G                           = 56;
localparam CONTROL_UNIT_STATE_WIDTH_G              = 3;
localparam CONTROL_UNIT_CORE_COMMAND_STATE_WIDTH_G = 2;
localparam CONTROL_UNIT_RUN_MODE_WIDTH_G           = 4;
localparam CONTROL_UNIT_INT_MODE_WIDTH_G           = 1;
localparam CONTROL_UNIT_RST_TYPE_WIDTH_G           = 2;
localparam CONTROL_UNIT_RST_LEN_WIDTH_G            = 8;
localparam CONTROL_UNIT_RST_MEM_TARGET_WIDTH_G     = 4;
localparam CONTROL_UNIT_STATUS_REGISTER_WIDTH_G    = 32;
localparam CONTROL_UNIT_STATUS_CODE_WIDTH_G        = 3;
localparam CONTROL_UNIT_STATUS_DATA_WIDTH_G        = 26;
localparam CONTROL_UNIT_RESET_DURATION_G           = 50;

// --------------------------------------------------------
// --------------------------------------------------------
//    Buffers
// --------------------------------------------------------
// --------------------------------------------------------

// Control Unit buffers
localparam COMMAND_BUFFER_WIDTH_G = 64;
localparam INPUT_BUFFER_WIDTH_G   = 32;
localparam OUTPUT_BUFFER_WIDTH_G  = 32;
localparam CORE_FIFOS_DEPTH_G     = 8;

// --------------------------------------------------------
// --------------------------------------------------------
//   Neuron Wrapper and Neuron Configuration
// --------------------------------------------------------
// --------------------------------------------------------

// Hidden Core Neurons
localparam NEURON_STATE_WIDTH_G             = 20; // fixed point format Q10.10
localparam NEURON_STATE_WIDTH_FRACTIONALS_G = 10;

localparam TAU_MEM_INV_WIDTH_G             = 16; // data format UQ0.16
localparam TAU_MEM_INV_WIDTH_FRACTIONALS_G = 16;
localparam TAU_MEM_INV_G                   = 0.1 * 2**TAU_MEM_INV_WIDTH_FRACTIONALS_G; // tau_mem_inv = 1/tau_mem, tau_mem = 10

localparam SPIKE_THRESHOLD_WIDTH_G                                  = 11; // data format UQ1.10
localparam SPIKE_THRESHOLD_WIDTH_FRACTIONALS_G                      = 10;
localparam unsigned [SPIKE_THRESHOLD_WIDTH_G-1:0] SPIKE_THRESHOLD_G = 0.1 * 2**SPIKE_THRESHOLD_WIDTH_FRACTIONALS_G;

localparam RESET_VALUE_G = 0;

localparam RAM_LEAK_DATA_WIDTH_G        = 8; // data format UQ0.8
localparam RAM_LEAK_WIDTH_FRACTIONALS_G = 8;
localparam RAM_LEAK_ADDR_WIDTH_G        = 5;
localparam RAM_LEAK_INIT_FILE_G         = "";

// Output Core Neurons
localparam OUT_CORE_NEURON_STATE_WIDTH_G             = 20; // fixed point format Q12.12
localparam OUT_CORE_NEURON_STATE_WIDTH_FRACTIONALS_G = 10;

localparam OUT_CORE_TAU_MEM_INV_WIDTH_G             = 16; // data format UQ0.16
localparam OUT_CORE_TAU_MEM_INV_WIDTH_FRACTIONALS_G = 16;
localparam OUT_CORE_TAU_MEM_INV_G                   = 0.001 * 2**OUT_CORE_TAU_MEM_INV_WIDTH_FRACTIONALS_G; // tau_mem_inv = 1/tau_mem, tau_mem = 10

localparam OUT_CORE_RAM_LEAK_ADDR_WIDTH_G        = 12; // 4096 entries (neccessary for tau_inv=0.001)
localparam OUT_CORE_RAM_LEAK_DATA_WIDTH_G        = 8;  // data format UQ0.8
localparam OUT_CORE_RAM_LEAK_WIDTH_FRACTIONALS_G = 8;
localparam OUT_CORE_RAM_LEAK_INIT_FILE_G         = "";

// --------------------------------------------------------
// --------------------------------------------------------
//    Init Files for Memories - Should be used only for Simulation if URAMs are used
// --------------------------------------------------------
// --------------------------------------------------------
localparam WEIGHT_RAM_INIT_FILE_INPUT_G  = "";
localparam WEIGHT_RAM_INIT_FILE_HIDDEN_G = "";
localparam WEIGHT_RAM_INIT_FILE_OUTPUT_G = "";

localparam MAPPING_RAM_INIT_FILE_INPUT_G  = "";
localparam MAPPING_RAM_INIT_FILE_HIDDEN_G = "";
localparam MAPPING_RAM_INIT_FILE_OUTPUT_G = "";

localparam ROUTES_RAM_INIT_FILE_INPUT_G  = "";
localparam ROUTES_RAM_INIT_FILE_HIDDEN_G = "";
localparam ROUTES_RAM_INIT_FILE_OUTPUT_G = "";

// --------------------------------------------------------
// --------------------------------------------------------
//    Derived constants - DON'T TOUCH
// --------------------------------------------------------
// --------------------------------------------------------

localparam MESH_PACKET_DX_WIDTH_G = $clog2(NUM_CORES_X_G) + 2; // + 2 for signed directions and off-mesh addressing in X direction
localparam MESH_PACKET_DY_WIDTH_G = $clog2(NUM_CORES_Y_G) + 1; // + 1 for signed directions

localparam CORE_ID_X_WIDTH_G      = $clog2(NUM_CORES_X_G);
localparam CORE_ID_Y_WIDTH_G      = $clog2(NUM_CORES_Y_G);
localparam CORE_NEURON_ID_WIDTH_G = $clog2(NEURONS_PER_CORE_G);
localparam CORE_WEIGHT_ID_WIDTH_G = $clog2(WEIGHTS_PER_CORE_G);
localparam CORE_ROUTE_WIDTH_G     = MESH_PACKET_DY_WIDTH_G + MESH_PACKET_DX_WIDTH_G + CORE_WEIGHT_ID_WIDTH_G + CORE_NEURON_ID_WIDTH_G;
localparam CORE_INPUT_WIDTH_G     = CORE_WEIGHT_ID_WIDTH_G + CORE_NEURON_ID_WIDTH_G + 1;

// Weight RAM Configuration
localparam CORE_WEIGHT_RAM_ADDR_WIDTH_G = $clog2(
    WEIGHTS_PER_CORE_G / (URAM_WIDTH_G / WEIGHT_WIDTH_G)
);
localparam CORE_WEIGHT_RAM_DATA_WIDTH_G = URAM_WIDTH_G;

// Weight Sum RAM Configuration
localparam CORE_WEIGHT_SUM_RAM_ADDR_WIDTH_G = CORE_NEURON_ID_WIDTH_G;
localparam CORE_WEIGHT_SUM_RAM_DATA_WIDTH_G = WEIGHT_SUM_WIDTH_G + 1;

// Routes RAM Configuration
localparam CORE_ROUTES_RAM_DATA_WIDTH_G  = URAM_WIDTH_G;
localparam CORE_ROUTES_RAM_ADDR_WIDTH_G  = $clog2(ROUTES_PER_CORE_G / (CORE_ROUTES_RAM_DATA_WIDTH_G / CORE_ROUTE_WIDTH_G));

//  CORE_MAPPING_RAM_END_ADDR_ENTRY_ID_WIDTH_G
localparam CORE_MAPPING_RAM_LAST_IDX_WIDTH_G = $clog2(
    (CORE_ROUTES_RAM_DATA_WIDTH_G / CORE_ROUTE_WIDTH_G)
);

// Edge case: One neuron uses all routes
localparam CORE_MAPPING_RAM_DATA_WIDTH_G = 2*CORE_ROUTES_RAM_ADDR_WIDTH_G + CORE_MAPPING_RAM_LAST_IDX_WIDTH_G;

localparam CORE_EVENT_WIDTH_G            = CORE_WEIGHT_ID_WIDTH_G + CORE_NEURON_ID_WIDTH_G;

// Control tree upstream
/// The needed values depend on the shape of the control tree at instantiation
/// These presets represent on the defaults of the YANA control tree within a 2D mesh of nodes
localparam NODE_DONE_IN_MAX_CNT_G  = 3;
localparam NODE_IDLE_IN_MAX_CNT_G  = 3;

localparam MESH_PACKET_ADDR_WIDTH_G = MESH_PACKET_DX_WIDTH_G + MESH_PACKET_DY_WIDTH_G;

// Internal Fabric Width (includes ctrl_flag in calculation)
localparam MESH_PACKET_DATA_WIDTH_X_G = max(
    32,
    CORE_ROUTE_WIDTH_G + 1
);
localparam MESH_PACKET_DATA_WIDTH_Y_G = MESH_PACKET_DATA_WIDTH_X_G - MESH_PACKET_DX_WIDTH_G;

// Top level input data
localparam TOP_INPUT_DATA_WIDTH_G    = TIMESTEP_WIDTH_G    + CORE_NEURON_ID_WIDTH_G;
localparam TOP_INPUT_CONTROL_WIDTH_G = INSTRUCTION_WIDTH_G + PARAM_WIDTH_G;

//=========================================================================
//-------------------------------------------------------------------------
// Packet Types
//-------------------------------------------------------------------------
//=========================================================================

//=========================================================================
// Event Data Packet (ctrl_flag=0)
//=========================================================================

localparam PKT_EVENT_DATA_SYN_ID_WIDTH_G = MESH_PACKET_DATA_WIDTH_X_G
                                           -MESH_PACKET_ADDR_WIDTH_G
                                           -CORE_NEURON_ID_WIDTH_G
                                           -1;

typedef struct packed {
  logic [PKT_EVENT_DATA_SYN_ID_WIDTH_G-1:0] synapse_id; //absorbs padding
  logic [CORE_NEURON_ID_WIDTH_G-1:0]        neuron_id;
} pkt_payload_event_data_s;

typedef struct packed {
  pkt_payload_event_data_s payload;
  logic                    ctrl_flag; // = 0 for event data
} pkt_core_event_data_s;

typedef struct packed {
  pkt_core_event_data_s              core;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_noc_event_data_s;

// Route entry format (same as pkt_noc_event_data_s but without ctrl flag)
typedef struct packed {
  pkt_payload_event_data_s payload;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_route_entry_s;

//=========================================================================
// Control Command Packets (ctrl_flag=1)
//=========================================================================

//-------------------------------------
// General Command Parameters
//-------------------------------------

// By convention, all control command packets have to fit into 32 bits
//   If a command needs more than 32 bits, it has to be split into multiple flits
localparam PKT_CMD_MAX_WIDTH_G = 32;

// Command Type Parameters
localparam PKT_CMD_TYPE_COUNT_G = 4;
localparam PKT_CMD_ID_WIDTH_G = $clog2(PKT_CMD_TYPE_COUNT_G);

// Command Type Enumeration
typedef enum logic [PKT_CMD_ID_WIDTH_G-1:0] {
  PKT_CMD_RESET         = 2'b00,
  PKT_CMD_FORCED_UPDATE = 2'b01,
  PKT_CMD_READOUT       = 2'b10,
  PKT_CMD_SET_TIMESTEP  = 2'b11 // SET_TIMESTEP must always be the last command type
} pkt_cmd_type_e;

//-------------------------------------
// Command: Set Timestep
//-------------------------------------

// Field width params and check
localparam PKT_TIMESTEP_SINGLE_PAYLOAD_WIDTH_G = TIMESTEP_WIDTH_G + PKT_CMD_ID_WIDTH_G;
localparam PKT_TIMESTEP_SINGLE_TS_WIDTH_G      = MESH_PACKET_DATA_WIDTH_X_G
                                                 -MESH_PACKET_ADDR_WIDTH_G
                                                 -1
                                                 -PKT_CMD_ID_WIDTH_G
                                                 -PKT_CMD_ID_WIDTH_G;
localparam PKT_TIMESTEP_SINGLE_VALID_G         = (MESH_PACKET_ADDR_WIDTH_G
                                                  +1
                                                  +PKT_CMD_ID_WIDTH_G
                                                  +PKT_TIMESTEP_SINGLE_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G;

// Set Timestep Packet
typedef struct packed {
  logic [PKT_TIMESTEP_SINGLE_TS_WIDTH_G-1:0] timestep;   // absorbs padding
  logic [PKT_CMD_ID_WIDTH_G-1:0]             target_cmd;
} pkt_payload_cmd_timestep_s;

typedef struct packed {
  pkt_payload_cmd_timestep_s     payload;
  logic [PKT_CMD_ID_WIDTH_G-1:0] cmd_id;
  logic                          ctrl_flag; // = 1
} pkt_core_cmd_timestep_s;

typedef struct packed {
  pkt_core_cmd_timestep_s            core;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_noc_cmd_timestep_s;

//-------------------------------------
// Command: Reset/Forced Update/Readout Request ("RQ")
//-------------------------------------

// Field width params and check - single flit version
localparam PKT_RQ_SINGLE_PAYLOAD_WIDTH_G  = 2 * CORE_NEURON_ID_WIDTH_G;
localparam PKT_RQ_SINGLE_END_ADDR_WIDTH_G = MESH_PACKET_DATA_WIDTH_X_G
                                            -MESH_PACKET_ADDR_WIDTH_G
                                            -1
                                            -PKT_CMD_ID_WIDTH_G
                                            -CORE_NEURON_ID_WIDTH_G;
localparam PKT_RQ_SINGLE_VALID_G          = (MESH_PACKET_ADDR_WIDTH_G
                                             +1
                                             +PKT_CMD_ID_WIDTH_G
                                             +PKT_RQ_SINGLE_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G;

// Reset/Forced Update/Readout Request Payload - single flit version
typedef struct packed {
  logic [PKT_RQ_SINGLE_END_ADDR_WIDTH_G-1:0] end_addr;  // absorbs padding
  logic [CORE_NEURON_ID_WIDTH_G-1:0]         start_addr;
} pkt_payload_rq_single_s;

// Field width params and check - double flit version
localparam PKT_RQ_DOUBLE_PAYLOAD_WIDTH_G    = CORE_NEURON_ID_WIDTH_G;
localparam PKT_RQ_DOUBLE_START_END_WIDTH_G  = MESH_PACKET_DATA_WIDTH_X_G
                                              -MESH_PACKET_ADDR_WIDTH_G
                                              -1
                                              -PKT_CMD_ID_WIDTH_G
                                              -1;
localparam PKT_RQ_DOUBLE_VALID_G            = (MESH_PACKET_ADDR_WIDTH_G
                                               +1
                                               +PKT_CMD_ID_WIDTH_G
                                               +1
                                               +PKT_RQ_DOUBLE_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G;

// Reset/Forced Update/Readout Request Payload - double flit version
typedef struct packed {
  logic [PKT_RQ_DOUBLE_START_END_WIDTH_G-1:0] start_end; // start_addr OR end_addr depending on flit_id, absorbs padding
  logic                                       flit_id;   // flit_id=0 for start_addr, flit_id=1 for end_addr
} pkt_payload_rq_double_s;

// Reset/Forced Update/Readout Request Core and NoC level packets
typedef union packed {
    pkt_payload_rq_double_s double;
    pkt_payload_rq_single_s single;
} pkt_payload_rq_u;

typedef struct packed {
    pkt_payload_rq_u               payload;
    logic [PKT_CMD_ID_WIDTH_G-1:0] cmd_id;
    logic                          ctrl_flag;  // = 1
} pkt_core_rq_s;

typedef struct packed {
  pkt_core_rq_s                      core;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_noc_rq_s;

// Reset/Forced Update/Readout Request Widths
localparam PKT_CMD_RQ_FLIT_COUNT_G = PKT_RQ_SINGLE_VALID_G ? 1 : 
                                     PKT_RQ_DOUBLE_VALID_G ? 2 : 
                                     0;
localparam PKT_CMD_RQ_FLIT_ID_WIDTH_G = $clog2(PKT_CMD_RQ_FLIT_COUNT_G);
localparam PKT_CMD_RQ_WORD_COUNT_G    = PKT_CMD_RQ_FLIT_COUNT_G + 1;
localparam PKT_CMD_RQ_PAYLOAD_WIDTH_G = PKT_RQ_SINGLE_VALID_G ? PKT_RQ_SINGLE_PAYLOAD_WIDTH_G :
                                        PKT_RQ_DOUBLE_VALID_G ? PKT_RQ_DOUBLE_PAYLOAD_WIDTH_G :
                                        0;
localparam integer PKT_CMD_RQ_WORD_WIDTHS_G [0:255] = PKT_RQ_SINGLE_VALID_G ? '{0:       PKT_CMD_RQ_PAYLOAD_WIDTH_G,
                                                                                1:       TIMESTEP_WIDTH_G,
                                                                                default: 0} :
                                                      PKT_RQ_DOUBLE_VALID_G ? '{0:       PKT_CMD_RQ_PAYLOAD_WIDTH_G,
                                                                                1:       PKT_CMD_RQ_PAYLOAD_WIDTH_G,
                                                                                2:       TIMESTEP_WIDTH_G,
                                                                                default: 0} :
                                                      '{default: 0};
localparam PKT_CMD_RQ_WORD_WIDTHS_SUM_G = sum_of_array(PKT_CMD_RQ_WORD_WIDTHS_G, PKT_CMD_RQ_WORD_COUNT_G);

//-------------------------------------
// Packet: Neuron State Readout
//-------------------------------------

// Field width params and check - single flit version
localparam PKT_RO_SINGLE_PAYLOAD_WIDTH_G = MESH_PACKET_ADDR_WIDTH_G
                                           +CORE_NEURON_ID_WIDTH_G
                                           +NEURON_STATE_WIDTH_G;
localparam PKT_RO_SINGLE_STATE_WIDTH_G   = MESH_PACKET_DATA_WIDTH_X_G
                                           -MESH_PACKET_ADDR_WIDTH_G
                                           -1
                                           -MESH_PACKET_ADDR_WIDTH_G
                                           -CORE_NEURON_ID_WIDTH_G;
localparam PKT_RO_SINGLE_VALID_G         = (MESH_PACKET_ADDR_WIDTH_G
                                           +1
                                           +PKT_RO_SINGLE_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G;

// Readout Output Payload - single flit version
typedef struct packed {
  logic [PKT_RO_SINGLE_STATE_WIDTH_G-1:0] state;     // absorbs padding
  logic [CORE_NEURON_ID_WIDTH_G-1:0]      neuron_id;
  logic [MESH_PACKET_DY_WIDTH_G-1:0]      source_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0]      source_core_x;
} pkt_payload_ro_single_s;

// Field width params and check - double flit version
localparam PKT_RO_DOUBLE_FLIT0_PAYLOAD_WIDTH_G      = MESH_PACKET_ADDR_WIDTH_G + CORE_NEURON_ID_WIDTH_G;
localparam PKT_RO_DOUBLE_FLIT0_NEURON_ID_WIDTH_G    = MESH_PACKET_DATA_WIDTH_X_G
                                                      -MESH_PACKET_ADDR_WIDTH_G
                                                      -1
                                                      -1
                                                      -MESH_PACKET_ADDR_WIDTH_G;
localparam PKT_RO_DOUBLE_FLIT1_PAYLOAD_WIDTH_G      = MESH_PACKET_ADDR_WIDTH_G + NEURON_STATE_WIDTH_G;
localparam PKT_RO_DOUBLE_FLIT1_NEURON_STATE_WIDTH_G = MESH_PACKET_DATA_WIDTH_X_G
                                                      -MESH_PACKET_ADDR_WIDTH_G
                                                      -1
                                                      -1
                                                      -MESH_PACKET_ADDR_WIDTH_G;
localparam PKT_RO_DOUBLE_VALID_G                    = (MESH_PACKET_ADDR_WIDTH_G
                                                       +1
                                                       +1
                                                       +PKT_RO_DOUBLE_FLIT0_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G &&
                                                      (MESH_PACKET_ADDR_WIDTH_G
                                                       +1
                                                       +1
                                                       +PKT_RO_DOUBLE_FLIT1_PAYLOAD_WIDTH_G) <= PKT_CMD_MAX_WIDTH_G;

// Readout Output Payloads - double flit version
typedef struct packed {
  logic [PKT_RO_DOUBLE_FLIT0_NEURON_ID_WIDTH_G-1:0] neuron_id;      // absorbs padding
  logic [MESH_PACKET_DY_WIDTH_G-1:0]                source_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0]                source_core_x;
  logic                                             flit_id;        // flit_id=0
} pkt_payload_ro_double_flit0_s;

typedef struct packed {
  logic [PKT_RO_DOUBLE_FLIT1_NEURON_STATE_WIDTH_G-1:0] state;          // absorbs padding
  logic [MESH_PACKET_DY_WIDTH_G-1:0]                   source_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0]                   source_core_x;
  logic                                                flit_id;        // flit_id=1
} pkt_payload_ro_double_flit1_s;

// Readout Output Packet Core and NoC level packets
typedef union packed {
    pkt_payload_ro_double_flit1_s double_flit1;
    pkt_payload_ro_double_flit0_s double_flit0;
    pkt_payload_ro_single_s       single;
} pkt_payload_ro_u;

typedef struct packed {
  pkt_payload_ro_u payload;
  logic            ctrl_flag;  // = 1
} pkt_core_ro_s;

typedef struct packed {
  pkt_core_ro_s                      core;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_noc_ro_s;

// Readout Output Packet Widths
localparam PKT_RO_FLIT_COUNT_G = PKT_RO_SINGLE_VALID_G ? 1 :
                                 PKT_RO_DOUBLE_VALID_G ? 2 :
                                 0;

//=========================================================================
// Init-time packet (init = 1)
//=========================================================================

// Init Packet Parameters
localparam INIT_TARGET_COUNT_G  = 6;

typedef enum logic [$clog2(INIT_TARGET_COUNT_G)-1:0] {
  INIT_SYNAPSE_WEIGHTS_G = 3'b000,
  INIT_AXON_MAPPING_G    = 3'b001,
  INIT_AXON_ROUTES_G     = 3'b010,
  INIT_SPIKE_THRESHOLD_G = 3'b011,
  INIT_TAU_MEM_INV_G     = 3'b100,
  INIT_LEAK_LUT_G        = 3'b101
} pkt_init_type_e;

typedef enum logic [INIT_TARGET_COUNT_G-1:0] {
  INIT_SYNAPSE_WEIGHTS_OH_G = 6'b000001,
  INIT_AXON_MAPPING_OH_G    = 6'b000010,
  INIT_AXON_ROUTES_OH_G     = 6'b000100,
  INIT_SPIKE_THRESHOLD_OH_G = 6'b001000,
  INIT_TAU_MEM_INV_OH_G     = 6'b010000,
  INIT_LEAK_LUT_OH_G        = 6'b100000
} pkt_init_type_oh_e;

// Init Packet Parameters (Derived)
localparam INIT_PAYLOAD_WIDTH_G = MESH_PACKET_DATA_WIDTH_X_G - MESH_PACKET_ADDR_WIDTH_G - $bits(pkt_init_type_e);

// Init Packet
typedef struct packed {
  pkt_init_type_e                  init_target;
  logic [INIT_PAYLOAD_WIDTH_G-1:0] data;
} pkt_payload_init_s;

typedef struct packed {
  pkt_payload_init_s                 payload;
  logic [MESH_PACKET_DY_WIDTH_G-1:0] target_core_y;
  logic [MESH_PACKET_DX_WIDTH_G-1:0] target_core_x;
} pkt_noc_init_s;

`endif
