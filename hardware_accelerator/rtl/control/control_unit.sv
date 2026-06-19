`timescale 1ns / 1ps

`include "global_params.vh"
`include "control_unit_enums.vh"

module ControlUnit #(
    parameter COMMAND_WIDTH     = TOP_INPUT_CONTROL_WIDTH_G,
    parameter INSTRUCTION_WIDTH = INSTRUCTION_WIDTH_G,
    parameter PARAM_WIDTH       = PARAM_WIDTH_G,
    parameter RUN_MODE_WIDTH    = CONTROL_UNIT_RUN_MODE_WIDTH_G,
    parameter INT_MODE_WIDTH    = CONTROL_UNIT_INT_MODE_WIDTH_G,
    parameter STATUS_REGISTER_WIDTH = CONTROL_UNIT_STATUS_REGISTER_WIDTH_G,
    parameter STATUS_DATA_WIDTH     = CONTROL_UNIT_STATUS_DATA_WIDTH_G,
    parameter TIMESTEP_WIDTH = TIMESTEP_WIDTH_G,
    parameter COMMAND_BUFFER_WIDTH = COMMAND_BUFFER_WIDTH_G
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic en_i,

    output logic                            command_ready_o,
    input  logic                            command_valid_i,
    input  logic [COMMAND_BUFFER_WIDTH-1:0] command_data_i,

    input  logic                                  core_cmd_ready_i,
    output logic                                  core_cmd_valid_o,
    output logic [MESH_PACKET_DATA_WIDTH_X_G-1:0] core_cmd_data_o,

    input  logic [TIMESTEP_WIDTH-1:0] next_timestep_i,
    input  logic                      done_i,
    input  logic                      idle_i,

    output logic mesh_init_o,
    output logic rst_o,
    output logic mesh_en_o,
    output logic input_en_o,
    output logic [TIMESTEP_WIDTH-1:0] current_timestep_o,
    output logic interrupt_o,
    input  logic interrupt_ack_i,

    output [STATUS_REGISTER_WIDTH-1:0] status_reg_o
);

    // =========================================================================
    // Local Parameters
    // =========================================================================

    localparam RESET_COUNTER_WIDTH = $clog2(CONTROL_UNIT_RESET_DURATION_G);

    // =========================================================================
    // Internal signals
    // =========================================================================

    State         cu_state;
    RunMode       cu_run_mode;
    InterruptMode cu_int_mode;

    StatusCode                    cu_status_code;
    logic [STATUS_DATA_WIDTH-1:0] cu_status_data;
    logic [STATUS_DATA_WIDTH-1:0] cu_running_cycle_counter;
    assign cu_status_data = cu_running_cycle_counter;
    assign status_reg_o   = {cu_status_data, cu_status_code, cu_state};

    logic [TIMESTEP_WIDTH-1:0] cu_timestep;
    logic                      cu_timestep_done;
    logic                      cu_timestep_synced;
    logic                      cu_halt_req;
    logic                      cu_interrupt;

    assign cu_timestep_synced = next_timestep_i == cu_timestep;
    assign input_en_o         = (
        (cu_state == STATE_RUNNING && cu_timestep_synced) ||
        (cu_state == STATE_INIT)
    );
    assign current_timestep_o = cu_timestep;
    assign interrupt_o        = cu_interrupt;

    logic                      cu_sample_done;
    logic [TIMESTEP_WIDTH-1:0] cu_sample_duration;
    assign cu_sample_done = !(cu_timestep < cu_sample_duration);

    logic cu_acc_idle;
    logic cu_acc_idle_posedge;
    assign cu_acc_idle = idle_i;

    logic cu_cores_done;
    logic cu_cores_done_posedge;
    assign cu_cores_done = done_i;

    Instruction             cu_command_instr;
    logic [PARAM_WIDTH-1:0] cu_command_param;
    logic                   cu_command_valid;
    logic                   cu_command_ready;

    assign command_ready_o = cu_command_ready;

    assign cu_command_instr = Instruction'(command_data_i[INSTRUCTION_WIDTH-1:0]);
    assign cu_command_param = command_data_i[COMMAND_WIDTH-1:INSTRUCTION_WIDTH];
    assign cu_command_valid = command_valid_i;

    cu_payload_reset_s cmd_payload;
    assign cmd_payload = cu_payload_reset_s'(cu_command_param);

    logic cu_command_handshake;
    assign cu_command_handshake = cu_command_valid && cu_command_ready;

    logic [PKT_CMD_ID_WIDTH_G-1:0]     core_cmd_gen_type;
    logic [CORE_ID_X_WIDTH_G-1:0]      core_cmd_gen_target_core_x;
    logic [CORE_ID_Y_WIDTH_G-1:0]      core_cmd_gen_target_core_y;
    logic [CORE_NEURON_ID_WIDTH_G-1:0] core_cmd_gen_start_addr;
    logic [CORE_NEURON_ID_WIDTH_G-1:0] core_cmd_gen_end_addr;
    logic [TIMESTEP_WIDTH_G-1:0]       core_cmd_gen_timestep;
    logic                              core_cmd_gen_start;
    logic                              core_cmd_gen_idle;
 
    ReadoutState cu_readout_state;
    ResetState cu_reset_state;
    logic [RESET_COUNTER_WIDTH-1:0] cu_reset_counter;

    // =========================================================================
    // Module instantiation: ControlUnitCoreCmdGen
    // =========================================================================

    ControlUnitCoreCmdGen u_core_cmd_gen (
        .clk_i           (clk_i),
        .rst_i           (rst_i),
        .enable_i        (en_i),
        .start_i         (core_cmd_gen_start),
        .idle_o          (core_cmd_gen_idle),
        .core_cmd_type_i (core_cmd_gen_type),
        .target_core_x_i (core_cmd_gen_target_core_x),
        .target_core_y_i (core_cmd_gen_target_core_y),
        .start_addr_i    (core_cmd_gen_start_addr),
        .end_addr_i      (core_cmd_gen_end_addr),
        .timestep_i      (core_cmd_gen_timestep),
        .core_cmd_ready_i(core_cmd_ready_i),
        .core_cmd_valid_o(core_cmd_valid_o),
        .core_cmd_data_o (core_cmd_data_o)
    );

    // =========================================================================
    // Instruction parsing and main FSM
    // =========================================================================

    always_ff @(posedge clk_i) begin
        rst_o <= rst_i;

        if (rst_i) begin
            cu_status_code            <= STATUS_NO_ERROR;
            cu_running_cycle_counter  <= 0;
            cu_state    <= STATE_HALTED;
            cu_run_mode <= RUN_MODE_TIMESTEP;
            cu_int_mode <= INT_MODE_DEFAULT;
            cu_command_ready   <= 1'b0;
            cu_halt_req        <= 1'b0;
            cu_interrupt       <= 1'b0;
            cu_sample_duration <= 0;
            mesh_init_o <= 1'b0;
            mesh_en_o <= 1'b0;
            cu_readout_state <= READOUT_WAIT_UPDATE;
            cu_reset_state   <= RESET_WAIT_GENERATION;
            core_cmd_gen_start <= 1'b0;
        end else if (en_i) begin
            cu_command_ready <= 1'b0;

            if (cu_interrupt) begin
                if (interrupt_ack_i) begin
                    cu_interrupt   <= 0;
                    cu_status_code <= STATUS_NO_ERROR;
                end
            end else begin
                case (cu_state)
                    STATE_HALTED: begin
                        if (cu_command_handshake) begin
                            case (cu_command_instr)
                                INSTR_START: begin
                                    cu_running_cycle_counter <= 0;
                                    cu_sample_duration       <= cu_command_param[TIMESTEP_WIDTH-1:0];
                                    cu_state                 <= STATE_RUNNING;
                                    mesh_en_o                <= 1'b1;
                                end

                                INSTR_HALT: begin
                                end

                                INSTR_SET_RUN_MODE: begin
                                    cu_run_mode <= RunMode'(cu_command_param[RUN_MODE_WIDTH-1:0]);
                                    if (cu_int_mode == INT_MODE_DEFAULT) begin
                                        cu_interrupt   <= 1;
                                        cu_status_code <= STATUS_NO_ERROR;
                                    end
                                end

                                INSTR_SET_INT_MODE: begin
                                    cu_int_mode <= InterruptMode'(cu_command_param[INT_MODE_WIDTH-1:0]);
                                    if (cu_int_mode == INT_MODE_DEFAULT) begin
                                        cu_interrupt   <= 1;
                                        cu_status_code <= STATUS_NO_ERROR;
                                    end
                                end

                                INSTR_SET_INIT: begin
                                    cu_running_cycle_counter <= 0;
                                    cu_state                 <= STATE_INIT;
                                    mesh_init_o              <= 1'b1;
                                end

                                INSTR_READ_STATE: begin
                                    cu_state  <= STATE_OUTPUT_READ;
                                    mesh_en_o <= 1'b1;
                                    begin
                                        cu_payload_read_state_s cmd_payload;
                                        cmd_payload = cu_payload_read_state_s'(cu_command_param);
                                        core_cmd_gen_target_core_x <= cmd_payload.target_core_x;
                                        core_cmd_gen_target_core_y <= cmd_payload.target_core_y;
                                        core_cmd_gen_start_addr    <= cmd_payload.start_addr;
                                        core_cmd_gen_end_addr      <= cmd_payload.end_addr;
                                        core_cmd_gen_timestep      <= cmd_payload.timestep;
                                        core_cmd_gen_start         <= 1'b1;
                                        if (cmd_payload.force_update) begin
                                            core_cmd_gen_type <= PKT_CMD_FORCED_UPDATE;
                                            cu_readout_state  <= READOUT_WAIT_UPDATE;
                                        end else begin
                                            core_cmd_gen_type <= PKT_CMD_READOUT;
                                            cu_readout_state  <= READOUT_WAIT_READOUT;
                                        end
                                    end
                                end

                                INSTR_RESET: begin
                                    cu_state <= STATE_RESET;
                                    begin
                                        if (cmd_payload.rst_type == RESET_CONTROL) begin
                                            cu_reset_counter   <= CONTROL_UNIT_RESET_DURATION_G - 1;
                                            cu_reset_state     <= RESET_COUNTER_CONTROL;
                                            core_cmd_gen_start <= 1'b0;
                                        end else if (cmd_payload.rst_type == RESET_STATES) begin
                                            mesh_en_o                  <= 1'b1;
                                            core_cmd_gen_type          <= PKT_CMD_RESET;
                                            core_cmd_gen_target_core_x <= cmd_payload.target_core_x;
                                            core_cmd_gen_target_core_y <= cmd_payload.target_core_y;
                                            core_cmd_gen_start_addr    <= cmd_payload.start_addr;
                                            core_cmd_gen_end_addr      <= cmd_payload.end_addr;
                                            core_cmd_gen_timestep      <= cmd_payload.timestep;
                                            core_cmd_gen_start         <= 1'b1;
                                            cu_reset_state             <= RESET_WAIT_GENERATION;
                                        end else begin
                                            cu_reset_counter   <= CONTROL_UNIT_RESET_DURATION_G - 1;
                                            cu_reset_state     <= RESET_COUNTER_CONTROL;
                                            core_cmd_gen_start <= 1'b0;
                                        end
                                    end
                                end

                                default: begin
                                    cu_interrupt   <= 1;
                                    cu_status_code <= STATUS_INVALID_INSTR_ERROR;
                                end
                            endcase
                        end else begin
                            cu_command_ready <= 1'b1;
                        end
                    end

                    STATE_INIT: begin
                        cu_running_cycle_counter <= cu_running_cycle_counter + 1'b1;

                        if (cu_cores_done_posedge || (cu_command_valid && cu_command_instr == INSTR_HALT)) begin
                            cu_state    <= STATE_HALTED;
                            mesh_init_o <= 1'b0;
                            if (cu_int_mode == INT_MODE_DEFAULT) begin
                                cu_interrupt   <= 1;
                                cu_status_code <= STATUS_NO_ERROR;
                            end
                        end
                    end

                    STATE_RUNNING: begin
                        cu_running_cycle_counter <= cu_running_cycle_counter + 1'b1;

                        if (
                            ((cu_run_mode == RUN_MODE_TIMESTEP) & cu_timestep_done) |
                            ((cu_run_mode == RUN_MODE_SAMPLE) & cu_timestep_done & (cu_sample_done | cu_halt_req))
                        ) begin
                            cu_state    <= STATE_HALTED;
                            cu_halt_req <= 0;
                            mesh_en_o   <= 1'b0;

                            if (cu_int_mode == INT_MODE_DEFAULT) begin
                                cu_interrupt   <= 1;
                                cu_status_code <= STATUS_NO_ERROR;
                            end
                        end else if ((cu_command_valid) && cu_command_instr == INSTR_HALT) begin
                            cu_halt_req <= 1;
                        end else begin
                            mesh_en_o <= 1'b1;

                            if (cu_run_mode == RUN_MODE_SAMPLE) begin
                                if (cu_timestep_done) begin
                                    mesh_en_o <= 1'b0;
                                end
                            end
                        end
                    end

                    STATE_OUTPUT_READ: begin
                        mesh_en_o          <= 1'b1;
                        core_cmd_gen_start <= 1'b0;

                        case (cu_readout_state)
                            READOUT_WAIT_UPDATE: begin
                                if (core_cmd_gen_idle && !core_cmd_gen_start) begin
                                    begin
                                        core_cmd_gen_type          <= PKT_CMD_READOUT;
                                        core_cmd_gen_start         <= 1'b1;
                                        cu_readout_state           <= READOUT_WAIT_READOUT;
                                    end
                                end
                            end

                            READOUT_WAIT_READOUT: begin
                                if (core_cmd_gen_idle && cu_acc_idle && !core_cmd_gen_start) begin
                                    mesh_en_o          <= 1'b0;
                                    cu_state           <= STATE_HALTED;
                                    if (cu_int_mode == INT_MODE_DEFAULT) begin
                                        cu_interrupt   <= 1'b1;
                                        cu_status_code <= STATUS_NO_ERROR;
                                    end
                                end
                            end

                            default: begin
                            end
                        endcase

                        if (cu_command_valid && cu_command_instr == INSTR_HALT) begin
                            mesh_en_o          <= 1'b0;
                            core_cmd_gen_start <= 1'b0;
                            cu_state           <= STATE_HALTED;
                            if (cu_int_mode == INT_MODE_DEFAULT) begin
                                cu_interrupt   <= 1'b1;
                                cu_status_code <= STATUS_NO_ERROR;
                            end
                        end
                    end

                    STATE_RESET: begin
                        core_cmd_gen_start <= 1'b0;

                        case (cu_reset_state)
                            RESET_WAIT_GENERATION: begin
                                mesh_en_o <= 1'b1;
                                if (core_cmd_gen_idle && cu_acc_idle && !core_cmd_gen_start) begin
                                    mesh_en_o <= 1'b0;
                                    cu_state  <= STATE_HALTED;
                                    if (cu_int_mode == INT_MODE_DEFAULT) begin
                                        cu_interrupt   <= 1'b1;
                                        cu_status_code <= STATUS_NO_ERROR;
                                    end
                                end
                            end

                            RESET_COUNTER_CONTROL: begin
                                mesh_en_o <= 1'b0;
                                if (cu_reset_counter == '0) begin
                                    cu_state          <= STATE_HALTED;
                                    cu_reset_state    <= RESET_WAIT_GENERATION;
                                    if (cu_int_mode == INT_MODE_DEFAULT) begin
                                        cu_interrupt   <= 1'b1;
                                        cu_status_code <= STATUS_NO_ERROR;
                                    end
                                end else begin
                                    rst_o             <= 1'b1;
                                    cu_reset_counter  <= cu_reset_counter - 1'b1;
                                end
                            end

                            default: begin
                            end
                        endcase

                        if (cu_command_valid && cu_command_instr == INSTR_HALT) begin
                            mesh_en_o           <= 1'b0;
                            cu_reset_counter    <= '0;
                            cu_state            <= STATE_HALTED;
                            cu_reset_state      <= RESET_WAIT_GENERATION;
                            if (cu_int_mode == INT_MODE_DEFAULT) begin
                                cu_interrupt   <= 1'b1;
                                cu_status_code <= STATUS_NO_ERROR;
                            end
                        end
                    end

                    default: begin
                    end

                endcase
            end
        end
    end

    // =========================================================================
    // Edge detections for cores done and cores idle
    // =========================================================================

    Pulse_Generator u_pulse_cores_done (
        .clock            (clk_i),
        .level_in         (cu_cores_done),
        .pulse_posedge_out(cu_cores_done_posedge),
        .pulse_negedge_out(/* unused */),
        .pulse_anyedge_out(/* unused */)
    );

    Pulse_Generator u_pulse_acc_idle (
        .clock            (clk_i),
        .level_in         (cu_acc_idle),
        .pulse_posedge_out(cu_acc_idle_posedge),
        .pulse_negedge_out(/* unused */),
        .pulse_anyedge_out(/* unused */)
    );

    // =========================================================================
    // Timestep synchronization
    // =========================================================================

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            cu_timestep      <= 0;
            cu_timestep_done <= 1'b0;
        end else if (en_i) begin
            cu_timestep_done <= 1'b0;
            if (cu_state == STATE_RUNNING) begin
                if (cu_acc_idle_posedge) begin
                    if (cu_timestep < next_timestep_i) begin
                        cu_timestep_done <= 1'b1;
                        cu_timestep      <= next_timestep_i;
                    end else begin
                        cu_timestep_done <= 1'b1;
                        cu_timestep      <= cu_sample_duration;
                    end
                end else if (cu_cores_done_posedge) begin
                    cu_timestep_done <= 1'b1;
                    cu_timestep      <= cu_timestep + 1;
                end
            end
        end
    end

endmodule
