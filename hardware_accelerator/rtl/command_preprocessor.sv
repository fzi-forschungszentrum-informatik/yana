`timescale 1ns / 1ps

`include "global_params.vh"

module CommandPreprocessor #(
  parameter TIMESTEP_WIDTH = TIMESTEP_WIDTH_G,

  // General control packet parameters
  parameter PKT_CTRL_WIDTH              = CORE_INPUT_WIDTH_G - 1,
  parameter PKT_CTRL_TYPE_WIDTH         = PKT_CMD_ID_WIDTH_G,
  parameter PKT_CTRL_TYPE_WIDTH_OH      = PKT_CMD_TYPE_COUNT_G,
  parameter PKT_CTRL_PAYLOAD_MAX_WIDTH  = PKT_CTRL_WIDTH - PKT_CTRL_TYPE_WIDTH, // don't set at instantiation

  // Command type parameters
  parameter PKT_CTRL_CMD_TYPE_COUNT     = PKT_CMD_TYPE_COUNT_G,
  parameter PKT_CTRL_CMD_ID_WIDTH       = PKT_CMD_ID_WIDTH_G,

  // Set Timestep parameters
  parameter PKT_CTRL_TS_TIMESTEP_WIDTH = TIMESTEP_WIDTH_G,

  // Reset/Forced Update/Readout Request parameters
  parameter         PKT_CTRL_RQ_FLIT_COUNT          = PKT_CMD_RQ_FLIT_COUNT_G,
  parameter         PKT_CTRL_RQ_FLIT_ID_WIDTH       = PKT_CMD_RQ_FLIT_ID_WIDTH_G,
  parameter         PKT_CTRL_RQ_WORD_COUNT          = PKT_CMD_RQ_WORD_COUNT_G,
  parameter         PKT_CTRL_RQ_PAYLOAD_WIDTH       = PKT_CMD_RQ_PAYLOAD_WIDTH_G,
  parameter integer PKT_CTRL_RQ_WORD_WIDTHS [0:255] = PKT_CMD_RQ_WORD_WIDTHS_G,
  parameter         PKT_CTRL_RQ_WORD_WIDTHS_SUM     = PKT_CMD_RQ_WORD_WIDTHS_SUM_G
) (
  // Control signals
  input  logic                      clk_i,
  input  logic                      rst_i,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,
  output logic                      done_o,

  // Input data packets
  output logic                      packet_in_ready_o,
  input  logic                      packet_in_valid_i,
  input  logic [PKT_CTRL_WIDTH-1:0] packet_in_data_i,

  // Output commands
  input  logic                                   state_reset_out_ready_i,
  output logic                                   state_reset_out_valid_o,
  output logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] state_reset_out_data_o,

  input  logic                                   forced_update_out_ready_i,
  output logic                                   forced_update_out_valid_o,
  output logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] forced_update_out_data_o,

  input  logic                                   state_read_out_ready_i,
  output logic                                   state_read_out_valid_o,
  output logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] state_read_out_data_o
);

  //============================================================================
  // Part 1: Branching the different command types
  //============================================================================

  logic                      input_buffer_out_ready;
  logic                      input_buffer_out_valid;
  logic [PKT_CTRL_WIDTH-1:0] input_buffer_out_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (PKT_CTRL_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_input_skid_buffer (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (packet_in_ready_o),
    .input_valid (packet_in_valid_i),
    .input_data  (packet_in_data_i),
    .output_ready(input_buffer_out_ready),
    .output_valid(input_buffer_out_valid),
    .output_data (input_buffer_out_data)
  );

  logic [PKT_CTRL_TYPE_WIDTH_OH-1:0] input_buffer_out_selector;

  Binary_to_One_Hot #(
    .BINARY_WIDTH(PKT_CTRL_TYPE_WIDTH),
    .OUTPUT_WIDTH(PKT_CTRL_TYPE_WIDTH_OH)
  ) u_bin_to_oh (
    .binary_in  (input_buffer_out_data[PKT_CTRL_TYPE_WIDTH-1:0]),
    .one_hot_out(input_buffer_out_selector)
  );

  logic [PKT_CTRL_PAYLOAD_MAX_WIDTH-1:0] input_buffer_out_data_payload; 
  assign input_buffer_out_data_payload = input_buffer_out_data[PKT_CTRL_TYPE_WIDTH+:PKT_CTRL_PAYLOAD_MAX_WIDTH];

  localparam SWITCH_OUTPUT_COUNT = PKT_CTRL_TYPE_WIDTH_OH;
  logic [SWITCH_OUTPUT_COUNT-1:0]                                  pipeline_branch_out_ready;
  logic [SWITCH_OUTPUT_COUNT-1:0]                                  pipeline_branch_out_valid;
  logic [SWITCH_OUTPUT_COUNT-1:0] [PKT_CTRL_PAYLOAD_MAX_WIDTH-1:0] pipeline_branch_out_data;

  Pipeline_Branch_One_Hot #(
    .WORD_WIDTH    (PKT_CTRL_PAYLOAD_MAX_WIDTH),
    .OUTPUT_COUNT  (SWITCH_OUTPUT_COUNT),
    .IMPLEMENTATION("AND")
  ) u_pipeline_branch (
    .selector    (input_buffer_out_selector),
    .input_ready (input_buffer_out_ready),
    .input_valid (input_buffer_out_valid),
    .input_data  (input_buffer_out_data_payload),
    .output_ready(pipeline_branch_out_ready),
    .output_valid(pipeline_branch_out_valid),
    .output_data (pipeline_branch_out_data)
  );

  //============================================================================
  // Part 2: Assembling commands for execution in downstream modules
  //============================================================================

  //============================================================================
  // Set Timestep Branch
  //============================================================================

  localparam PKT_CTRL_TS_TARGET_COUNT = PKT_CTRL_CMD_TYPE_COUNT - 1; // -1 to exclude SET_TIMESTEP command itself
  localparam CMD_RECEIVER_COUNT       = PKT_CTRL_TS_TARGET_COUNT;

  logic [PKT_CTRL_TS_TARGET_COUNT-1:0] ctrl_ts_target_selector;
  pkt_payload_cmd_timestep_s pipeline_branch_out_data_3; // Intermediate signal to make Vivado happy
  assign pipeline_branch_out_data_3 = pipeline_branch_out_data[3];

  Binary_to_One_Hot #(
    .BINARY_WIDTH(PKT_CTRL_CMD_ID_WIDTH),
    .OUTPUT_WIDTH(PKT_CTRL_TS_TARGET_COUNT)
  ) u_ctrl_ts_bin_to_oh (
    .binary_in  (pipeline_branch_out_data_3.target_cmd),
    .one_hot_out(ctrl_ts_target_selector)
  );

  logic [PKT_CTRL_TS_TARGET_COUNT-1:0]                                  ctrl_ts_branch_out_ready;
  logic [PKT_CTRL_TS_TARGET_COUNT-1:0]                                  ctrl_ts_branch_out_valid;
  logic [PKT_CTRL_TS_TARGET_COUNT-1:0] [PKT_CTRL_TS_TIMESTEP_WIDTH-1:0] ctrl_ts_branch_out_data;

  logic [PKT_CTRL_TS_TIMESTEP_WIDTH-1:0] ctrl_ts_payload;
  assign ctrl_ts_payload = pipeline_branch_out_data_3.timestep[PKT_CTRL_TS_TIMESTEP_WIDTH-1:0];

  Pipeline_Branch_One_Hot #(
    .WORD_WIDTH    (PKT_CTRL_TS_TIMESTEP_WIDTH),
    .OUTPUT_COUNT  (PKT_CTRL_TS_TARGET_COUNT),
    .IMPLEMENTATION("AND")
  ) u_ctrl_ts_branch (
    .selector    (ctrl_ts_target_selector),
    .input_ready (pipeline_branch_out_ready[3]),
    .input_valid (pipeline_branch_out_valid[3]),
    .input_data  (ctrl_ts_payload),
    .output_ready(ctrl_ts_branch_out_ready),
    .output_valid(ctrl_ts_branch_out_valid),
    .output_data (ctrl_ts_branch_out_data)
  );

  //============================================================================
  // Command Receivers (State Reset, Forced Update, State Readout)
  //============================================================================

  logic [CMD_RECEIVER_COUNT-1:0]                                   rcv_done;
  logic [CMD_RECEIVER_COUNT-1:0] [PKT_CTRL_RQ_WORD_COUNT-1:0]      rcv_join_in_ready;
  logic [CMD_RECEIVER_COUNT-1:0] [PKT_CTRL_RQ_WORD_COUNT-1:0]      rcv_join_in_valid;
  logic [CMD_RECEIVER_COUNT-1:0] [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] rcv_join_in_data;
  logic [CMD_RECEIVER_COUNT-1:0]                                   rcv_join_out_valid;
  logic [CMD_RECEIVER_COUNT-1:0] [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] rcv_join_out_data;

  logic [CMD_RECEIVER_COUNT-1:0] rcv_out_ready_i;
  assign rcv_out_ready_i[0] = state_reset_out_ready_i;
  assign rcv_out_ready_i[1] = forced_update_out_ready_i;
  assign rcv_out_ready_i[2] = state_read_out_ready_i;

  generate
    genvar i;
    for (i = 0; i < CMD_RECEIVER_COUNT; i = i + 1) begin : gen_cmd_receivers
      if (PKT_CTRL_RQ_FLIT_COUNT > 1) begin : gen_flit_branch
        logic [PKT_CTRL_RQ_FLIT_COUNT-1:0]    flit_selector;
        logic [PKT_CTRL_RQ_FLIT_ID_WIDTH-1:0] data_flit;
        pkt_payload_rq_double_s pipeline_branch_out_data_i; // Intermediate signal to make Vivado happy
        assign pipeline_branch_out_data_i = pipeline_branch_out_data[i];
        assign data_flit = pipeline_branch_out_data_i.flit_id;

        Binary_to_One_Hot #(
          .BINARY_WIDTH(PKT_CTRL_RQ_FLIT_ID_WIDTH),
          .OUTPUT_WIDTH(PKT_CTRL_RQ_FLIT_COUNT)
        ) u_bin_to_oh (
          .binary_in  (data_flit),
          .one_hot_out(flit_selector)
        );

        logic [PKT_CTRL_RQ_PAYLOAD_WIDTH-1:0] data_payload;
        assign data_payload = pipeline_branch_out_data_i.start_end[PKT_CTRL_RQ_PAYLOAD_WIDTH-1:0];

        logic [PKT_CTRL_RQ_FLIT_COUNT-1:0]                                 branch_out_ready;
        logic [PKT_CTRL_RQ_FLIT_COUNT-1:0]                                 branch_out_valid;
        logic [PKT_CTRL_RQ_FLIT_COUNT-1:0] [PKT_CTRL_RQ_PAYLOAD_WIDTH-1:0] branch_out_data;

        Pipeline_Branch_One_Hot #(
          .WORD_WIDTH    (PKT_CTRL_RQ_PAYLOAD_WIDTH),
          .OUTPUT_COUNT  (PKT_CTRL_RQ_FLIT_COUNT),
          .IMPLEMENTATION("AND")
        ) u_branch (
          .selector    (flit_selector),
          .input_ready (pipeline_branch_out_ready[i]),
          .input_valid (pipeline_branch_out_valid[i]),
          .input_data  (data_payload),
          .output_ready(branch_out_ready),
          .output_valid(branch_out_valid),
          .output_data (branch_out_data)
        );

        assign branch_out_ready = rcv_join_in_ready[i][PKT_CTRL_RQ_FLIT_COUNT-1:0];
        assign rcv_join_in_valid[i] = {branch_out_valid, ctrl_ts_branch_out_valid[i]};
        assign rcv_join_in_data[i]  = {branch_out_data, ctrl_ts_branch_out_data[i]};

      end else begin : gen_single_flit
        assign pipeline_branch_out_ready[i] = rcv_join_in_ready[i][0];
        assign rcv_join_in_valid[i] = {pipeline_branch_out_valid[i], ctrl_ts_branch_out_valid[i]};
        assign rcv_join_in_data[i]  = {pipeline_branch_out_data[i][PKT_CTRL_RQ_PAYLOAD_WIDTH-1:0], ctrl_ts_branch_out_data[i]};
      end

      assign ctrl_ts_branch_out_ready[i] = rcv_join_in_ready[i][PKT_CTRL_RQ_WORD_COUNT-1];

      CommandJoin #(
        .WORD_WIDTHS(PKT_CTRL_RQ_WORD_WIDTHS),
        .INPUT_COUNT(PKT_CTRL_RQ_WORD_COUNT)
      ) u_join (
        .clk_i           (clk_i),
        .rst_i           (rst_i),
        .timestep_i      (timestep_i),
        .done_o          (rcv_done[i]),
        .cmd_input_ready (rcv_join_in_ready[i]),
        .cmd_input_valid (rcv_join_in_valid[i]),
        .cmd_input_data  (rcv_join_in_data[i]),
        .cmd_output_ready(rcv_out_ready_i[i]),
        .cmd_output_valid(rcv_join_out_valid[i]),
        .cmd_output_data (rcv_join_out_data[i])
      );
    end
  endgenerate

  assign state_reset_out_valid_o    = rcv_join_out_valid[0];
  assign state_reset_out_data_o     = rcv_join_out_data[0];
  assign forced_update_out_valid_o  = rcv_join_out_valid[1];
  assign forced_update_out_data_o   = rcv_join_out_data[1];
  assign state_read_out_valid_o     = rcv_join_out_valid[2];
  assign state_read_out_data_o      = rcv_join_out_data[2];

  //============================================================================
  // Part 3: Other Logic
  //============================================================================

  //============================================================================
  // Done Logic
  //============================================================================

  assign done_o = ~input_buffer_out_valid && &rcv_done;

endmodule