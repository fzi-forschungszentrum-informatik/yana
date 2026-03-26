`ifndef _control_unit_enums_h
`define _control_unit_enums_h

`include "global_params.vh"

typedef enum logic[INSTRUCTION_WIDTH_G-1:0] {
    INSTR_RESET,
    INSTR_START,
    INSTR_HALT,
    INSTR_SET_RUN_MODE,
    INSTR_SET_INT_MODE,
    INSTR_INIT_START,
    INSTR_INIT_END,
    INSTR_INIT_PACKET,
    INSTR_READ_OUTPUT
} Instruction;

typedef enum logic[CONTROL_UNIT_STATE_WIDTH_G-1:0] {
    STATE_HALTED,
    STATE_INIT,
    STATE_RUNNING,
    STATE_OUTPUT_READ
} State;

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
    RESET_SOFT,     // Only reset configuration (no deep reset of memories)
    RESET_HARD,     // Reset configuration and stateful memories
    RESET_STATES    // Only reset stateful memories
} ResetType;

typedef enum logic[CONTROL_UNIT_RST_MEM_TARGET_WIDTH_G-1:0] {
    RESET_MEM_ALL,  // Default behavior (e.g., for RESET_HARD type)
    RESET_MEM_CORE_TOP,
    RESET_MEM_OUTPUT_CORE,
    RESET_MEM_ALL_OH    // Like RESET_MEM_ALL but skips output-core neuron state RAM
} ResetMemTarget;

typedef enum logic[1:0] {
    RESET_MEM_W_SUM_CORE_TOP,
    RESET_MEM_STATE_CORE_TOP,
    RESET_MEM_W_SUM_OUTPUT_CORE,
    RESET_MEM_STATE_OUTPUT_CORE
} ResetMemTargetBit;

typedef enum logic[CONTROL_UNIT_STATUS_CODE_WIDTH_G-1:0] {
    STATUS_NO_ERROR,
    STATUS_INVALID_INSTR_ERROR,
    STATUS_PARAM_ERROR,
    STATUS_INIT_MEM_OVERFLOW
} StatusCode;

typedef enum logic[CONTROL_UNIT_MEM_TARGET_WIDTH_G-1:0] {
    TARGET_INPUT_MAPPING,
    TARGET_INPUT_ROUTING,
    TARGET_CORE_SYNAPSE,
    TARGET_CORE_AXON_MAPPING,
    TARGET_CORE_AXON_ROUTING
} MemoryTarget;

`endif
