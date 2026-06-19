`ifndef _control_unit_enums_h
`define _control_unit_enums_h

`include "global_params.vh"

// ============================================================================
// Control Unit Command Packet
// ============================================================================

typedef struct packed {
    logic [PARAM_WIDTH_G-1:0]       param;
    logic [INSTRUCTION_WIDTH_G-1:0] instr;
} cu_command_packet_s; 

// ============================================================================
// Per-Instruction Payload Structs
// ============================================================================

typedef struct packed {
    logic [PARAM_WIDTH_G-1:0] unused;
} cu_payload_start_s;

typedef struct packed {
    logic [PARAM_WIDTH_G-1:0] unused;
} cu_payload_halt_s;

localparam INSTR_SET_RUN_MODE_UNUSED_BITS = PARAM_WIDTH_G - CONTROL_UNIT_RUN_MODE_WIDTH_G;
typedef struct packed {
    logic [INSTR_SET_RUN_MODE_UNUSED_BITS-1:0] unused;
    logic [CONTROL_UNIT_RUN_MODE_WIDTH_G-1:0]  run_mode;
} cu_payload_set_run_mode_s;

localparam INSTR_SET_INT_MODE_UNUSED_BITS = PARAM_WIDTH_G - CONTROL_UNIT_INT_MODE_WIDTH_G;
typedef struct packed {
    logic [INSTR_SET_INT_MODE_UNUSED_BITS-1:0] unused;
    logic [CONTROL_UNIT_INT_MODE_WIDTH_G-1:0]  int_mode;
} cu_payload_set_int_mode_s;

typedef struct packed {
    logic [PARAM_WIDTH_G-1:0] unused;
} cu_payload_set_init_s;

localparam INSTR_READ_STATE_UNUSED_BITS = PARAM_WIDTH_G - TIMESTEP_WIDTH_G - CORE_NEURON_ID_WIDTH_G*2 - CORE_ID_X_WIDTH_G - CORE_ID_Y_WIDTH_G - 1;
typedef struct packed {
    logic [INSTR_READ_STATE_UNUSED_BITS-1:0] unused;
    logic                                    force_update;
    logic [TIMESTEP_WIDTH_G-1:0]             timestep;
    logic [CORE_NEURON_ID_WIDTH_G-1:0]       end_addr;
    logic [CORE_NEURON_ID_WIDTH_G-1:0]       start_addr;
    logic [CORE_ID_X_WIDTH_G-1:0]            target_core_x;
    logic [CORE_ID_Y_WIDTH_G-1:0]            target_core_y;
} cu_payload_read_state_s;

localparam INSTR_RESET_UNUSED_BITS = PARAM_WIDTH_G - TIMESTEP_WIDTH_G - CONTROL_UNIT_RST_TYPE_WIDTH_G - CORE_NEURON_ID_WIDTH_G*2 - CORE_ID_X_WIDTH_G - CORE_ID_Y_WIDTH_G;
typedef struct packed {
    logic [INSTR_RESET_UNUSED_BITS-1:0]       unused;
    logic [CONTROL_UNIT_RST_TYPE_WIDTH_G-1:0] rst_type;
    logic [TIMESTEP_WIDTH_G-1:0]              timestep;
    logic [CORE_NEURON_ID_WIDTH_G-1:0]        end_addr;
    logic [CORE_NEURON_ID_WIDTH_G-1:0]        start_addr;
    logic [CORE_ID_X_WIDTH_G-1:0]             target_core_x;
    logic [CORE_ID_Y_WIDTH_G-1:0]             target_core_y;
} cu_payload_reset_s;

// ============================================================================
// Payload Union
// ============================================================================

typedef union packed {
    cu_payload_start_s        start;
    cu_payload_halt_s         halt;
    cu_payload_set_run_mode_s set_run_mode;
    cu_payload_set_int_mode_s set_int_mode;
    cu_payload_set_init_s     set_init;
    cu_payload_read_state_s   read_state;
    cu_payload_reset_s        reset;
} cu_payload_u;

// ============================================================================
// Enums
// ============================================================================

typedef enum logic[INSTRUCTION_WIDTH_G-1:0] {
    INSTR_START,
    INSTR_HALT,
    INSTR_SET_RUN_MODE,
    INSTR_SET_INT_MODE,
    INSTR_SET_INIT,
    INSTR_READ_STATE,
    INSTR_RESET
} Instruction;

typedef enum logic[CONTROL_UNIT_STATE_WIDTH_G-1:0] {
    STATE_RESET,
    STATE_HALTED,
    STATE_INIT,
    STATE_RUNNING,
    STATE_OUTPUT_READ
} State;

typedef enum logic {
    READOUT_WAIT_UPDATE,
    READOUT_WAIT_READOUT
} ReadoutState;

typedef enum logic {
    RESET_WAIT_GENERATION,
    RESET_COUNTER_CONTROL
} ResetState;

typedef enum logic[CONTROL_UNIT_RUN_MODE_WIDTH_G-1:0] {
    RUN_MODE_TIMESTEP,
    RUN_MODE_SAMPLE,
    RUN_MODE_BATCH,
    RUN_MODE_CONTINUOUS
} RunMode;

typedef enum logic[CONTROL_UNIT_INT_MODE_WIDTH_G-1:0] {
    INT_MODE_DEFAULT,
    INT_MODE_SILENT
} InterruptMode;

typedef enum logic[CONTROL_UNIT_RST_TYPE_WIDTH_G-1:0] {
    RESET_CONTROL,
    RESET_STATES,
    RESET_ALL
} ResetType;

typedef enum logic[CONTROL_UNIT_STATUS_CODE_WIDTH_G-1:0] {
    STATUS_NO_ERROR,
    STATUS_INVALID_INSTR_ERROR,
    STATUS_PARAM_ERROR,
    STATUS_INIT_MEM_OVERFLOW
} StatusCode;

`endif
