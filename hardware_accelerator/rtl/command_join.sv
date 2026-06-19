`timescale 1ns / 1ps

`include "global_params.vh"

module CommandJoin #(
  parameter integer WORD_WIDTHS [0:255] = '{default: 0},
  parameter         INPUT_COUNT         = 0,
  parameter TIMESTEP_WIDTH = WORD_WIDTHS[INPUT_COUNT-1],
  parameter TOTAL_WIDTH    = sum_of_array(WORD_WIDTHS, INPUT_COUNT)
) (
  input  logic                      clk_i,
  input  logic                      rst_i,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,
  output logic                      done_o,

  output logic [INPUT_COUNT-1:0]   cmd_input_ready,
  input  logic [INPUT_COUNT-1:0]   cmd_input_valid,
  input  logic [TOTAL_WIDTH-1:0]   cmd_input_data,

  input  logic                     cmd_output_ready,
  output logic                     cmd_output_valid,
  output logic  [TOTAL_WIDTH-1:0]  cmd_output_data
);

  logic [INPUT_COUNT-1:0] half_buffer_ready_out;
  logic [INPUT_COUNT-1:0] half_buffer_valid_out;
  logic [TOTAL_WIDTH-1:0] half_buffer_data_out;

  generate
    genvar j;
    for(j=0; j < INPUT_COUNT; j=j+1) begin: per_input
      localparam WORD_WIDTH  = WORD_WIDTHS[j];
      localparam WORD_OFFSET = (sum_of_array(WORD_WIDTHS, j+1)) - WORD_WIDTH;

      logic                  sink_input;
      logic                  input_sink_ready_out;
      logic                  input_sink_valid_out;
      logic [WORD_WIDTH-1:0] input_sink_data_out;

      Pipeline_Sink #(
          .WORD_WIDTH    (WORD_WIDTH),
          .IMPLEMENTATION("AND")
      )
      input_sink
      (
          .sink        (sink_input),
          .input_ready (cmd_input_ready[j]),
          .input_valid (cmd_input_valid[j]),
          .input_data  (cmd_input_data[WORD_OFFSET+:WORD_WIDTH]),
          .output_ready(input_sink_ready_out),
          .output_valid(input_sink_valid_out),
          .output_data (input_sink_data_out)
      );

      Pipeline_Half_Buffer #(
          .WORD_WIDTH     (WORD_WIDTH),
          .CIRCULAR_BUFFER(0)
      )
      input_buffer
      (
          .clock       (clk_i),
          .clear       (rst_i),
          .input_ready (input_sink_ready_out),
          .input_valid (input_sink_valid_out),
          .input_data  (input_sink_data_out),
          .output_ready(half_buffer_ready_out[j]),
          .output_valid(half_buffer_valid_out[j]),
          .output_data (half_buffer_data_out[WORD_OFFSET+:WORD_WIDTH])
      );

      assign sink_input = half_buffer_valid_out[j];

    end
  endgenerate

  logic                   join_ready_out;
  logic                   join_valid_out;
  logic [TOTAL_WIDTH-1:0] join_data_out;

  Pipeline_Join_Asymm_Words # (
    .WORD_WIDTHS(WORD_WIDTHS),
    .INPUT_COUNT(INPUT_COUNT)
  ) join_inst (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (half_buffer_ready_out),
    .input_valid (half_buffer_valid_out),
    .input_data  (half_buffer_data_out),
    .output_ready(join_ready_out),
    .output_valid(join_valid_out),
    .output_data (join_data_out)
  );

  logic                   too_late;
  logic                   output_sink_ready_out;
  logic                   output_sink_valid_out;
  logic [TOTAL_WIDTH-1:0] output_sink_data_out;

  logic [TIMESTEP_WIDTH-1:0] join_data_timestep;
  assign join_data_timestep = join_data_out[TOTAL_WIDTH-1-:TIMESTEP_WIDTH];
  assign too_late = (join_data_timestep < timestep_i) ? join_valid_out : 0;

  Pipeline_Sink #(
      .WORD_WIDTH    (TOTAL_WIDTH),
      .IMPLEMENTATION("AND")
  )
  input_sink
  (
      .sink        (too_late),
      .input_ready (join_ready_out),
      .input_valid (join_valid_out),
      .input_data  (join_data_out),
      .output_ready(output_sink_ready_out),
      .output_valid(output_sink_valid_out),
      .output_data (output_sink_data_out)
  );

  assign output_sink_ready_out   = cmd_output_ready;
  assign cmd_output_valid        = output_sink_valid_out;
  assign cmd_output_data         = output_sink_data_out;

  assign done_o = ~(|half_buffer_valid_out);

endmodule