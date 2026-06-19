`timescale 1ns / 1ps

`include "global_params.vh"

module YanaTop #(
    // Accelerator
    parameter MESH_PACKET_DATA_WIDTH   = MESH_PACKET_DATA_WIDTH_X_G,
    parameter MESH_Y_LENGTH            = NUM_CORES_Y_G,
    parameter TIMESTEP_WIDTH           = TIMESTEP_WIDTH_G,
    parameter SPIKE_SRC_ENCODED_WIDTH  = CORE_NEURON_ID_WIDTH_G,
    // Peripheral widths
    parameter COMMAND_BUFFER_WIDTH     = COMMAND_BUFFER_WIDTH_G,
    parameter INPUT_DATA_BUFFER_WIDTH  = INPUT_BUFFER_WIDTH_G,
    parameter OUTPUT_DATA_BUFFER_WIDTH = OUTPUT_BUFFER_WIDTH_G,
    // Control unit
    parameter CONTROL_UNIT_STATUS_REGISTER_WIDTH = CONTROL_UNIT_STATUS_REGISTER_WIDTH_G
)(
    input  logic clk_i,
    input  logic rstn_i,
    input  logic en_i,

    output logic                            command_ready_o,
    input  logic                            command_valid_i,
    input  logic [COMMAND_BUFFER_WIDTH-1:0] command_data_i,

    output logic                               input_ready_o,
    input  logic                               input_valid_i,
    input  logic [INPUT_DATA_BUFFER_WIDTH-1:0] input_data_i,

    input  logic                                output_ready_i,
    output logic                                output_valid_o,
    output logic [OUTPUT_DATA_BUFFER_WIDTH-1:0] output_data_o,

    output logic                                          interrupt_o,
    input  logic                                          interrupt_ack_i,
    output logic [CONTROL_UNIT_STATUS_REGISTER_WIDTH-1:0] status_out_o
);

    //==========================================================================
    // Declarations
    //==========================================================================

    typedef struct packed {
        logic [TIMESTEP_WIDTH-1:0]           packet_timestep;
        logic [SPIKE_SRC_ENCODED_WIDTH-1:0]  input_neuron_id;
        logic                                ctrl_flag;
        logic [MESH_PACKET_ADDR_WIDTH_G-1:0] packet_addr;
    } yana_top_input_s;

    yana_top_input_s yana_top_input_data;
    assign yana_top_input_data = yana_top_input_s'(input_data_i);

    //==========================================================================
    // Parameter Validation
    //==========================================================================    
    
    ValidateParams u_validate_params ();

    //==========================================================================
    // Reset
    //==========================================================================

    logic rst_i;
    assign rst_i = ~rstn_i;

    //==========================================================================
    // Module Instantiations
    //==========================================================================

    logic [TIMESTEP_WIDTH-1:0]                     cu_in_next_timestep;
    logic                                          cu_in_done;
    logic                                          cu_in_idle;
    logic                                          cu_in_interrupt_ack;
    logic                                          cu_out_core_cmd_ready;
    logic                                          cu_out_core_cmd_valid;
    logic [MESH_PACKET_DATA_WIDTH-1:0]             cu_out_core_cmd_data;
    logic                                          cu_out_rst_gen;
    logic                                          cu_out_mesh_init;
    logic                                          cu_out_mesh_en;
    logic                                          cu_out_input_en;
    logic [TIMESTEP_WIDTH-1:0]                     cu_out_current_timestep;
    logic                                          cu_out_interrupt;
    logic [CONTROL_UNIT_STATUS_REGISTER_WIDTH-1:0] cu_out_status_reg;

    assign cu_in_next_timestep = yana_top_input_data.packet_timestep;
    assign cu_in_interrupt_ack = interrupt_ack_i;
    assign interrupt_o = cu_out_interrupt;
    assign status_out_o = cu_out_status_reg;

    ControlUnit #(
        // No parameter overrides
    ) u_control_unit (
        .clk_i             (clk_i),
        .rst_i             (rst_i),
        .en_i              (en_i),
        .command_data_i    (command_data_i),
        .command_valid_i   (command_valid_i),
        .command_ready_o   (command_ready_o),
        .core_cmd_ready_i  (cu_out_core_cmd_ready),
        .core_cmd_valid_o  (cu_out_core_cmd_valid),
        .core_cmd_data_o   (cu_out_core_cmd_data),
        .next_timestep_i   (cu_in_next_timestep),
        .done_i            (cu_in_done),
        .idle_i            (cu_in_idle),
        .mesh_init_o       (cu_out_mesh_init),
        .rst_o             (cu_out_rst_gen),
        .mesh_en_o         (cu_out_mesh_en),
        .input_en_o        (cu_out_input_en),
        .current_timestep_o(cu_out_current_timestep),
        .interrupt_o       (cu_out_interrupt),
        .interrupt_ack_i   (cu_in_interrupt_ack),
        .status_reg_o      (cu_out_status_reg)
    );

    logic                               input_gate_out_ready;
    logic                               input_gate_out_valid;
    logic [INPUT_DATA_BUFFER_WIDTH-1:0] input_gate_out_data;
    logic                               input_gate_pass_data;

    assign input_gate_pass_data =
        (cu_out_input_en && (cu_out_current_timestep == yana_top_input_data.packet_timestep)) ||
        (cu_out_mesh_init == 1'b1);

    Pipeline_Gate #(
        .WORD_WIDTH(INPUT_DATA_BUFFER_WIDTH)
    ) u_input_gate (
        .enable      (input_gate_pass_data),
        .input_ready (input_ready_o),
        .input_valid (input_valid_i),
        .input_data  (input_data_i),
        .output_ready(input_gate_out_ready),
        .output_valid(input_gate_out_valid),
        .output_data (input_gate_out_data)
    );

    logic                              mesh_input_merge_out_ready;
    logic                              mesh_input_merge_out_valid;
    logic [MESH_PACKET_DATA_WIDTH-1:0] mesh_input_merge_out_data;

    Pipeline_Merge_Interleave #(
        .WORD_WIDTH (MESH_PACKET_DATA_WIDTH),
        .INPUT_COUNT(2)
    ) u_mesh_input_merge (
        .clock       (clk_i),
        .clear       (cu_out_rst_gen),
        .input_ready ({cu_out_core_cmd_ready, input_gate_out_ready}),
        .input_valid ({cu_out_core_cmd_valid, input_gate_out_valid}),
        .input_data  ({cu_out_core_cmd_data, MESH_PACKET_DATA_WIDTH'(input_gate_out_data)}),
        .output_ready(mesh_input_merge_out_ready),
        .output_valid(mesh_input_merge_out_valid),
        .output_data (mesh_input_merge_out_data)
    );

    logic                              mesh_done;
    logic                              mesh_idle;
    logic                              mesh_west_in_ready  [MESH_Y_LENGTH];
    logic                              mesh_west_in_valid  [MESH_Y_LENGTH];
    logic [MESH_PACKET_DATA_WIDTH-1:0] mesh_west_in_data   [MESH_Y_LENGTH]; 
    logic                              mesh_east_out_ready [MESH_Y_LENGTH];
    logic                              mesh_east_out_valid [MESH_Y_LENGTH];
    logic [MESH_PACKET_DATA_WIDTH-1:0] mesh_east_out_data  [MESH_Y_LENGTH];

    assign mesh_input_merge_out_ready = mesh_west_in_ready [0];
    assign mesh_west_in_valid         = '{default: 1'b0, 0: mesh_input_merge_out_valid};
    assign mesh_west_in_data          = '{default: '0,   0: mesh_input_merge_out_data};
    assign cu_in_done = mesh_done;
    assign cu_in_idle = mesh_idle;

    Mesh u_mesh (
        .clk_i           (clk_i),
        .rst_i           (cu_out_rst_gen),
        .enable_i        (cu_out_mesh_en),
        .init_i          (cu_out_mesh_init),
        .timestep_i      (cu_out_current_timestep),
        .done_o          (mesh_done),
        .idle_o          (mesh_idle),
        .west_in_ready_o (mesh_west_in_ready),
        .west_in_valid_i (mesh_west_in_valid),
        .west_in_data_i  (mesh_west_in_data),
        .east_out_ready_i(mesh_east_out_ready),
        .east_out_valid_o(mesh_east_out_valid),
        .east_out_data_o (mesh_east_out_data)
    );

    localparam INDEX = MESH_Y_LENGTH-1; // workaround to make verilator happy
    assign mesh_east_out_ready = '{default: 1'b1, INDEX: output_ready_i};
    assign output_valid_o = mesh_east_out_valid [MESH_Y_LENGTH-1];

    pkt_noc_ro_s readout_packet;
    assign readout_packet = pkt_noc_ro_s'(mesh_east_out_data[MESH_Y_LENGTH-1]);
    assign output_data_o  = OUTPUT_DATA_BUFFER_WIDTH'(readout_packet.core);

endmodule
