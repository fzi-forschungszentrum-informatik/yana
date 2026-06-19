// Copyright (c) 2026 YANA contributors
// Licensed under CERN-OHL-W Version 2, see LICENSE-hardware
//
// This file contains heavily modified code derived from the RANC project.
// Original work Copyright (c) 2020 - present Joshua Mack, Ruben Purdy, Edward Richter,
// Spencer Valancius, and other contributors
// Licensed under the MIT License, see LICENSE-ranc

`timescale 1ns / 1ps

module FromLocal #(
    parameter integer PACKET_WIDTH = 30,
    parameter integer DX_WIDTH     = 8
) (
    input wire clock,
    input wire clear,

    output wire done_o,

    input  wire                    input_valid,
    output wire                    input_ready,
    input  wire [PACKET_WIDTH-1:0] input_data,

    output wire                    east_valid,
    input  wire                    east_ready,
    output wire [PACKET_WIDTH-1:0] east_data,

    output wire                    west_valid,
    input  wire                    west_ready,
    output wire [PACKET_WIDTH-1:0] west_data
);

  wire signed [DX_WIDTH-1:0] dx;
  assign dx = signed'(input_data[DX_WIDTH-1:0]);

  wire [1:0] route_selector = (dx < 0) ? 2'b10 : 2'b01;

  wire [1:0]                    branch_out_ready;
  wire [1:0]                    branch_out_valid;
  wire [1:0] [PACKET_WIDTH-1:0] branch_out_data;

  Pipeline_Branch_One_Hot #(
      .WORD_WIDTH    (PACKET_WIDTH),
      .OUTPUT_COUNT  (2),
      .IMPLEMENTATION("AND")
  ) u_route_branch (
      .selector(route_selector),
      .input_valid(input_valid),
      .input_ready(input_ready),
      .input_data(input_data),
      .output_ready(branch_out_ready),
      .output_valid(branch_out_valid),
      .output_data({branch_out_data[1], branch_out_data[0]})
  );

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH)
  ) east_buffer (
      .clock(clock),
      .clear(clear),
      .input_valid(branch_out_valid[0]),
      .input_ready(branch_out_ready[0]),
      .input_data(branch_out_data[0]),
      .output_valid(east_valid),
      .output_ready(east_ready),
      .output_data(east_data)
  );

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH)
  ) west_buffer (
      .clock(clock),
      .clear(clear),
      .input_valid(branch_out_valid[1]),
      .input_ready(branch_out_ready[1]),
      .input_data(branch_out_data[1]),
      .output_valid(west_valid),
      .output_ready(west_ready),
      .output_data(west_data)
  );

  assign done_o = ~east_valid && ~west_valid;

endmodule
