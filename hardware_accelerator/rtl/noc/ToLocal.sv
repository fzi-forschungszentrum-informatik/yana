// Copyright (c) 2026 YANA contributors
// Licensed under CERN-OHL-W Version 2, see LICENSE-hardware
//
// This file contains heavily modified code derived from the RANC project.
// Original work Copyright (c) 2020 - present Joshua Mack, Ruben Purdy, Edward Richter,
// Spencer Valancius, and other contributors
// Licensed under the MIT License, see LICENSE-ranc

`timescale 1ns / 1ps

module ToLocal #(
    parameter integer PACKET_WIDTH = 12
) (
    input wire clock,
    input wire clear,

    output wire done_o,

    input  wire                    north_valid,
    output wire                    north_ready,
    input  wire [PACKET_WIDTH-1:0] north_data,

    input  wire                    south_valid,
    output wire                    south_ready,
    input  wire [PACKET_WIDTH-1:0] south_data,

    output wire                    output_valid,
    input  wire                    output_ready,
    output wire [PACKET_WIDTH-1:0] output_data
);

  wire merge_output_valid;
  wire merge_output_ready;
  wire [PACKET_WIDTH-1:0] merge_output_data;

  wire [2*PACKET_WIDTH-1:0] input_data_concat = {south_data, north_data};
  wire [1:0] input_valid_concat = {south_valid, north_valid};
  wire [1:0] input_ready_concat;

  assign north_ready = input_ready_concat[0];
  assign south_ready = input_ready_concat[1];

  Pipeline_Merge_Interleave #(
      .WORD_WIDTH(PACKET_WIDTH),
      .INPUT_COUNT(2),
      .HANDSHAKE_MERGE("OR"),
      .DATA_MERGE("OR"),
      .IMPLEMENTATION("AND")
  ) merge_module (
      .clock(clock),
      .clear(clear),
      .input_valid(input_valid_concat),
      .input_ready(input_ready_concat),
      .input_data(input_data_concat),
      .output_valid(merge_output_valid),
      .output_ready(merge_output_ready),
      .output_data(merge_output_data)
  );

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH),
      .CIRCULAR_BUFFER(0)
  ) output_buffer (
      .clock(clock),
      .clear(clear),
      .input_valid(merge_output_valid),
      .input_ready(merge_output_ready),
      .input_data(merge_output_data),
      .output_valid(output_valid),
      .output_ready(output_ready),
      .output_data(output_data)
  );

  assign done_o = ~merge_output_valid && ~output_valid;

endmodule
