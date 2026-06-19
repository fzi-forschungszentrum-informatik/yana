// Copyright (c) 2026 YANA contributors
// Licensed under CERN-OHL-W Version 2, see LICENSE-hardware
//
// This file contains heavily modified code derived from the RANC project.
// Original work Copyright (c) 2020 - present Joshua Mack, Ruben Purdy, Edward Richter,
// Spencer Valancius, and other contributors
// Licensed under the MIT License, see LICENSE-ranc

`timescale 1ns / 1ps

module ForwardNorthSouth #(
    parameter integer PACKET_WIDTH = 21,
    parameter integer DY_WIDTH     = 8,
    parameter integer NORTH        = 1
) (
    input logic clock,
    input logic clear,

    output logic done_o,

    input  logic                    routing_valid,
    output logic                    routing_ready,
    input  logic [PACKET_WIDTH-1:0] routing_data,

    input  logic                    east_valid,
    output logic                    east_ready,
    input  logic [PACKET_WIDTH-1:0] east_data,

    input  logic                    west_valid,
    output logic                    west_ready,
    input  logic [PACKET_WIDTH-1:0] west_data,

    output logic                    routing_output_valid,
    input  logic                    routing_output_ready,
    output logic [PACKET_WIDTH-1:0] routing_output_data,

    output logic                             local_valid,
    input  logic                             local_ready,
    output logic [PACKET_WIDTH-DY_WIDTH-1:0] local_data
);

  localparam integer COORDINATE_OFFSET = NORTH ? -1 : 1;
  localparam integer INPUT_COUNT       = 3;
  localparam integer OUTPUT_COUNT      = 2;

  logic [INPUT_COUNT*PACKET_WIDTH-1:0] input_data_concat;
  logic [INPUT_COUNT-1:0]              input_valid_concat;
  logic [INPUT_COUNT-1:0]              input_ready_concat;
  logic [INPUT_COUNT*OUTPUT_COUNT-1:0] input_selector_concat;

  assign input_data_concat  = {west_data, east_data, routing_data};
  assign input_valid_concat = {west_valid, east_valid, routing_valid};
  assign routing_ready      = input_ready_concat[0];
  assign east_ready         = input_ready_concat[1];
  assign west_ready         = input_ready_concat[2];

  function automatic logic [OUTPUT_COUNT-1:0] fns_route_selector(
      input logic [PACKET_WIDTH-1:0] pkt
  );
    logic signed [DY_WIDTH-1:0] dest_y;
    dest_y = signed'(pkt[DY_WIDTH-1:0]);
    if (dest_y == 0)
      fns_route_selector = OUTPUT_COUNT'(1) << 1;
    else
      fns_route_selector = OUTPUT_COUNT'(1) << 0;
  endfunction

  assign input_selector_concat[OUTPUT_COUNT*0 +: OUTPUT_COUNT] = fns_route_selector(routing_data);
  assign input_selector_concat[OUTPUT_COUNT*1 +: OUTPUT_COUNT] = fns_route_selector(east_data);
  assign input_selector_concat[OUTPUT_COUNT*2 +: OUTPUT_COUNT] = fns_route_selector(west_data);

  logic crossbar_done;
  logic [OUTPUT_COUNT-1:0] xbar_out_valid;
  logic [OUTPUT_COUNT-1:0] xbar_out_ready;
  logic [OUTPUT_COUNT*PACKET_WIDTH-1:0] xbar_out_data;

  Pipeline_Crossbar_Interleave #(
      .WORD_WIDTH    (PACKET_WIDTH),
      .INPUT_COUNT   (INPUT_COUNT),
      .OUTPUT_COUNT  (OUTPUT_COUNT),
      .IMPLEMENTATION("AND")
  ) crossbar (
      .clock         (clock),
      .clear         (clear),
      .input_valid   (input_valid_concat),
      .input_ready   (input_ready_concat),
      .input_data    (input_data_concat),
      .input_selector(input_selector_concat),
      .output_valid  (xbar_out_valid),
      .output_ready  (xbar_out_ready),
      .output_data   (xbar_out_data),
      .done_o        (crossbar_done)
  );

  logic [PACKET_WIDTH-1:0] xbar_routing_data;
  logic                    routing_xbar_valid;
  logic                    routing_xbar_ready;

  assign xbar_routing_data  = xbar_out_data[0*PACKET_WIDTH +: PACKET_WIDTH];
  assign routing_xbar_valid = xbar_out_valid[0];
  assign xbar_out_ready[0]  = routing_xbar_ready;

  logic signed [DY_WIDTH-1:0] routing_dest_y;
  logic signed [DY_WIDTH-1:0] routing_updated_dest_y;
  logic [PACKET_WIDTH-1:0]    routing_shaped_data;
  logic                       routing_shaped_valid;
  logic                       routing_shaped_ready;

  assign routing_dest_y         = signed'(xbar_routing_data[DY_WIDTH-1:0]);
  assign routing_updated_dest_y = routing_dest_y + signed'(COORDINATE_OFFSET[DY_WIDTH-1:0]);
  assign routing_shaped_data    = {xbar_routing_data[PACKET_WIDTH-1:DY_WIDTH], routing_updated_dest_y};
  assign routing_shaped_valid   = routing_xbar_valid;
  assign routing_xbar_ready     = routing_shaped_ready;

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH)
  ) routing_buffer (
      .clock       (clock),
      .clear       (clear),
      .input_valid (routing_shaped_valid),
      .input_ready (routing_shaped_ready),
      .input_data  (routing_shaped_data),
      .output_valid(routing_output_valid),
      .output_ready(routing_output_ready),
      .output_data (routing_output_data)
  );

  logic [PACKET_WIDTH-1:0] xbar_local_data;
  logic                    local_xbar_valid;
  logic                    local_xbar_ready;

  assign xbar_local_data  = xbar_out_data[1*PACKET_WIDTH +: PACKET_WIDTH];
  assign local_xbar_valid = xbar_out_valid[1];
  assign xbar_out_ready[1] = local_xbar_ready;

  logic [PACKET_WIDTH-DY_WIDTH-1:0] local_shaped_data;
  logic                             local_shaped_valid;
  logic                             local_shaped_ready;

  assign local_shaped_data  = xbar_local_data[PACKET_WIDTH-1:DY_WIDTH];
  assign local_shaped_valid = local_xbar_valid;
  assign local_xbar_ready   = local_shaped_ready;

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH - DY_WIDTH)
  ) local_buffer (
      .clock       (clock),
      .clear       (clear),
      .input_valid (local_shaped_valid),
      .input_ready (local_shaped_ready),
      .input_data  (local_shaped_data),
      .output_valid(local_valid),
      .output_ready(local_ready),
      .output_data (local_data)
  );

  assign done_o = crossbar_done && ~routing_output_valid && ~local_valid;

endmodule
