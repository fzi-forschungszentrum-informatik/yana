`timescale 1ns / 1ps

`include "global_params.vh"

module NeuronWrapperStatePacketizer #(
  
  // --- Instantiation-expected ---
  parameter SOURCE_CORE_ID_X = 0,
  parameter SOURCE_CORE_ID_Y = 0,

  // --- From global_params ---
  parameter NEURON_WIDTH               = CORE_NEURON_ID_WIDTH_G,
  parameter NEURON_STATE_WIDTH         = NEURON_STATE_WIDTH_G,
  parameter PKT_RO_FLIT_COUNT          = PKT_RO_FLIT_COUNT_G,
  parameter PKT_RO_TARGET_CORE_X_WIDTH = MESH_PACKET_DX_WIDTH_G,
  parameter PKT_RO_TARGET_CORE_Y_WIDTH = MESH_PACKET_DY_WIDTH_G,

  // Do not set at instantiation, except in IPI
  parameter INPUT_DATA_WIDTH = NEURON_WIDTH + NEURON_STATE_WIDTH
) (
  input  logic clk_i,
  input  logic rst_i,
  output logic done_o,

  output logic                          state_input_ready_o,
  input  logic                          state_input_valid_i,
  input  logic [INPUT_DATA_WIDTH - 1:0] state_input_data_i,

  input  logic        state_packet_out_ready_i,
  output logic        state_packet_out_valid_o,
  output pkt_noc_ro_s state_packet_out_data_o
);

  localparam PAYLOAD_WIDTH = $bits(pkt_payload_ro_u);
  localparam [PKT_RO_TARGET_CORE_X_WIDTH-1:0] TARGET_CORE_X = '1 >> 1;
  localparam [PKT_RO_TARGET_CORE_Y_WIDTH-1:0] TARGET_CORE_Y = '0;

  logic                        in_buf_out_ready;
  logic                        in_buf_out_valid;
  logic [INPUT_DATA_WIDTH-1:0] in_buf_out_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (INPUT_DATA_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_input_buffer (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (state_input_ready_o),
    .input_valid (state_input_valid_i),
    .input_data  (state_input_data_i),
    .output_ready(in_buf_out_ready),
    .output_valid(in_buf_out_valid),
    .output_data (in_buf_out_data)
  );

  logic [NEURON_WIDTH-1:0]       input_neuron_id;
  logic [NEURON_STATE_WIDTH-1:0] input_neuron_state;

  assign input_neuron_state = in_buf_out_data[INPUT_DATA_WIDTH-1 : NEURON_WIDTH];
  assign input_neuron_id    = in_buf_out_data[NEURON_WIDTH-1 : 0];

  generate
    if (PKT_RO_FLIT_COUNT == 1) begin : gen_single_flit_mode
      pkt_payload_ro_single_s composed_payload;

      assign composed_payload.state         = input_neuron_state;
      assign composed_payload.neuron_id     = input_neuron_id;
      assign composed_payload.source_core_x = SOURCE_CORE_ID_X;
      assign composed_payload.source_core_y = SOURCE_CORE_ID_Y;

      assign in_buf_out_ready                       = state_packet_out_ready_i;
      assign state_packet_out_valid_o               = in_buf_out_valid;
      assign state_packet_out_data_o.core.payload   = composed_payload;
      assign state_packet_out_data_o.core.ctrl_flag = 1'b1;
      assign state_packet_out_data_o.target_core_x  = '1;
      assign state_packet_out_data_o.target_core_y  = SOURCE_CORE_ID_Y;

      assign done_o = ~in_buf_out_valid;

    end else begin : gen_double_flit_mode
      pkt_payload_ro_double_flit0_s composed_flit0;
      pkt_payload_ro_double_flit1_s composed_flit1;

      assign composed_flit0.neuron_id     = input_neuron_id;
      assign composed_flit0.source_core_x = SOURCE_CORE_ID_X;
      assign composed_flit0.source_core_y = SOURCE_CORE_ID_Y;
      assign composed_flit0.flit_id       = 1'b0;

      assign composed_flit1.state         = input_neuron_state;
      assign composed_flit1.source_core_x = SOURCE_CORE_ID_X;
      assign composed_flit1.source_core_y = SOURCE_CORE_ID_Y;
      assign composed_flit1.flit_id       = 1'b1;

      logic                           composed_flits_gated_ready;
      logic                           composed_flits_gated_valid;
      logic [1:0] [PAYLOAD_WIDTH-1:0] composed_flits_gated;

      logic                         buf0_input_ready;
      logic                         buf0_output_ready;
      logic                         buf0_output_valid;
      pkt_payload_ro_double_flit0_s buf0_output_data;

      logic                         buf1_input_ready;
      logic                         buf1_output_ready;
      logic                         buf1_output_valid;
      pkt_payload_ro_double_flit1_s buf1_output_data;

      logic                         both_bufs_ready;
      logic                         both_bufs_ready_pulse;

      assign both_bufs_ready = (rst_i) ? 1'b0 : &{buf0_input_ready, buf1_input_ready};

      Pulse_Generator u_pulse_both_bufs_ready (
        .clock            (clk_i),
        .level_in         (both_bufs_ready),
        .pulse_posedge_out(both_bufs_ready_pulse),
        .pulse_negedge_out(/* ignored */),
        .pulse_anyedge_out(/* ignored */)
      );

      Pipeline_Credit_Gate #(
        .WORD_WIDTH      (2*PAYLOAD_WIDTH),
        .MAX_CREDIT_COUNT(1)
      ) u_gate_flits (
        .clock                    (clk_i),
        .clear                    (rst_i),
        .input_data_valid         (in_buf_out_valid),
        .input_data_ready         (in_buf_out_ready),
        .input_data               ({composed_flit1, composed_flit0}),
        .add_credit_pulse         (both_bufs_ready_pulse),
        .add_credit_fail          (/* ignored */),
        .current_credit_count     (/* ignored */),
        .current_credit_count_max (/* ignored */),
        .current_credit_count_zero(/* ignored */),
        .output_data_valid        (composed_flits_gated_valid),
        .output_data_ready        (composed_flits_gated_ready),
        .output_data              ({composed_flits_gated})
      );

      assign composed_flits_gated_ready = buf1_input_ready;

      Pipeline_Half_Buffer #(
        .WORD_WIDTH     (PAYLOAD_WIDTH),
        .CIRCULAR_BUFFER(0)
      ) u_buffer_flit0 (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (buf0_input_ready),
        .input_valid (composed_flits_gated_valid),
        .input_data  (composed_flits_gated[0]),
        .output_ready(buf0_output_ready),
        .output_valid(buf0_output_valid),
        .output_data (buf0_output_data)
      );

      Pipeline_Half_Buffer #(
        .WORD_WIDTH     (PAYLOAD_WIDTH),
        .CIRCULAR_BUFFER(0)
      ) u_buffer_flit1 (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (buf1_input_ready),
        .input_valid (composed_flits_gated_valid),
        .input_data  (composed_flits_gated[1]),
        .output_ready(buf1_output_ready),
        .output_valid(buf1_output_valid),
        .output_data (buf1_output_data)
      );

      logic                     packet_merge_output_ready;
      logic                     packet_merge_output_valid;
      logic [PAYLOAD_WIDTH-1:0] packet_merge_output_data;

      Pipeline_Merge_Interleave #(
        .WORD_WIDTH (PAYLOAD_WIDTH),
        .INPUT_COUNT(2)
      ) u_packet_merge (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready ({buf1_output_ready, buf0_output_ready}),
        .input_valid ({buf1_output_valid, buf0_output_valid}),
        .input_data  ({buf1_output_data,  buf0_output_data}),
        .output_ready(packet_merge_output_ready),
        .output_valid(packet_merge_output_valid),
        .output_data (packet_merge_output_data)
      );

      assign packet_merge_output_ready              = state_packet_out_ready_i;
      assign state_packet_out_valid_o               = packet_merge_output_valid;
      assign state_packet_out_data_o.core.payload   = packet_merge_output_data;
      assign state_packet_out_data_o.core.ctrl_flag = 1'b1;
      assign state_packet_out_data_o.target_core_x  = TARGET_CORE_X;
      assign state_packet_out_data_o.target_core_y  = TARGET_CORE_Y;

      assign done_o = ~|{buf1_output_valid, buf0_output_valid};

    end
  endgenerate
endmodule