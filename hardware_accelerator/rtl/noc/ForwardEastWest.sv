// Copyright (c) 2026 YANA contributors
// Licensed under CERN-OHL-W Version 2, see LICENSE-hardware
//
// This file contains heavily modified code derived from the RANC project.
// Original work Copyright (c) 2020 - present Joshua Mack, Ruben Purdy, Edward Richter,
// Spencer Valancius, and other contributors
// Licensed under the MIT License, see LICENSE-ranc

`timescale 1ns / 1ps

module ForwardEastWest #(
    parameter integer PACKET_WIDTH = 30,
    parameter integer DX_WIDTH     = 8,
    parameter integer DY_WIDTH     = 8,
    parameter integer EAST         = 1
) (
    input logic clock,
    input logic clear,

    output logic done_o,

    // External input interface
    input  logic                    ext_input_valid,
    output logic                    ext_input_ready,
    input  logic [PACKET_WIDTH-1:0] ext_input_data,

    // Local input interface (from_local)
    input  logic                    local_input_valid,
    output logic                    local_input_ready,
    input  logic [PACKET_WIDTH-1:0] local_input_data,

    // External output interface
    output logic                    ext_output_valid,
    input  logic                    ext_output_ready,
    output logic [PACKET_WIDTH-1:0] ext_output_data,

    // North output interface
    output logic                             north_valid,
    input  logic                             north_ready,
    output logic [PACKET_WIDTH-DX_WIDTH-1:0] north_data,

    // South output interface
    output logic                             south_valid,
    input  logic                             south_ready,
    output logic [PACKET_WIDTH-DX_WIDTH-1:0] south_data
);

  localparam integer COORDINATE_OFFSET = EAST ? -1 : 1;
  localparam integer DEST_Y_LSB        = DX_WIDTH;
  localparam integer DEST_Y_MSB        = DX_WIDTH + DY_WIDTH - 1;
  localparam integer INPUT_COUNT       = 2;
  localparam integer OUTPUT_COUNT      = 3;

  logic [INPUT_COUNT*PACKET_WIDTH-1:0] input_data_concat;
  logic [INPUT_COUNT-1:0]              input_valid_concat;
  logic [INPUT_COUNT-1:0]              input_ready_concat;
  logic [INPUT_COUNT*OUTPUT_COUNT-1:0] input_selector_concat;
  assign input_data_concat  = {local_input_data, ext_input_data};
  assign input_valid_concat = {local_input_valid, ext_input_valid};
  assign ext_input_ready    = input_ready_concat[0];
  assign local_input_ready  = input_ready_concat[1];

  function automatic logic [OUTPUT_COUNT-1:0] few_route_selector(
      input logic [PACKET_WIDTH-1:0] pkt
  );
    logic signed [DX_WIDTH-1:0] dest_x;
    logic signed [DY_WIDTH-1:0] dest_y;
    dest_x = signed'(pkt[DX_WIDTH-1:0]);
    dest_y = signed'(pkt[DEST_Y_MSB:DEST_Y_LSB]);
    if (dest_x != 0)
      few_route_selector = OUTPUT_COUNT'(1) << 0;
    else if (dest_y < 0)
      few_route_selector = OUTPUT_COUNT'(1) << 2;
    else
      few_route_selector = OUTPUT_COUNT'(1) << 1;
  endfunction

  assign input_selector_concat[OUTPUT_COUNT*0 +: OUTPUT_COUNT] = few_route_selector(ext_input_data);
  assign input_selector_concat[OUTPUT_COUNT*1 +: OUTPUT_COUNT] = few_route_selector(local_input_data);

  logic                                 crossbar_done;
  logic [OUTPUT_COUNT-1:0]              xbar_out_valid;
  logic [OUTPUT_COUNT-1:0]              xbar_out_ready;
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

  // Output 0: ext
  logic [PACKET_WIDTH-1:0] xbar_ext_data;
  logic                    ext_xbar_valid;
  logic                    ext_xbar_ready;

  assign xbar_ext_data     = xbar_out_data[0*PACKET_WIDTH +: PACKET_WIDTH];
  assign ext_xbar_valid    = xbar_out_valid[0];
  assign xbar_out_ready[0] = ext_xbar_ready;

  logic signed [DX_WIDTH-1:0] ext_dest_x;
  logic signed [DX_WIDTH-1:0] ext_updated_dest_x;
  logic [PACKET_WIDTH-1:0]    ext_shaped_data;
  logic                       ext_shaped_valid;
  logic                       ext_shaped_ready;

  assign ext_dest_x         = signed'(xbar_ext_data[DX_WIDTH-1:0]);
  assign ext_updated_dest_x = ext_dest_x + signed'(COORDINATE_OFFSET[DX_WIDTH-1:0]);
  assign ext_shaped_data    = {xbar_ext_data[PACKET_WIDTH-1:DX_WIDTH], ext_updated_dest_x};
  assign ext_shaped_valid   = ext_xbar_valid;
  assign ext_xbar_ready     = ext_shaped_ready;

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH)
  ) ext_output_buffer (
      .clock       (clock),
      .clear       (clear),
      .input_valid (ext_shaped_valid),
      .input_ready (ext_shaped_ready),
      .input_data  (ext_shaped_data),
      .output_valid(ext_output_valid),
      .output_ready(ext_output_ready),
      .output_data (ext_output_data)
  );

  logic [PACKET_WIDTH-1:0] xbar_north_data;
  logic                    north_xbar_valid;
  logic                    north_xbar_ready;

  assign xbar_north_data  = xbar_out_data[1*PACKET_WIDTH +: PACKET_WIDTH];
  assign north_xbar_valid = xbar_out_valid[1];
  assign xbar_out_ready[1] = north_xbar_ready;

  logic [PACKET_WIDTH-DX_WIDTH-1:0] north_shaped_data;
  logic                             north_shaped_valid;
  logic                             north_shaped_ready;

  assign north_shaped_data  = xbar_north_data[PACKET_WIDTH-1:DX_WIDTH];
  assign north_shaped_valid = north_xbar_valid;
  assign north_xbar_ready   = north_shaped_ready;

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH - DX_WIDTH)
  ) north_buffer (
      .clock       (clock),
      .clear       (clear),
      .input_valid (north_shaped_valid),
      .input_ready (north_shaped_ready),
      .input_data  (north_shaped_data),
      .output_valid(north_valid),
      .output_ready(north_ready),
      .output_data (north_data)
  );

  logic [PACKET_WIDTH-1:0] xbar_south_data;
  logic                    south_xbar_valid;
  logic                    south_xbar_ready;

  assign xbar_south_data  = xbar_out_data[2*PACKET_WIDTH +: PACKET_WIDTH];
  assign south_xbar_valid = xbar_out_valid[2];
  assign xbar_out_ready[2] = south_xbar_ready;

  logic [PACKET_WIDTH-DX_WIDTH-1:0] south_shaped_data;
  logic                             south_shaped_valid;
  logic                             south_shaped_ready;

  assign south_shaped_data  = xbar_south_data[PACKET_WIDTH-1:DX_WIDTH];
  assign south_shaped_valid = south_xbar_valid;
  assign south_xbar_ready   = south_shaped_ready;

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH(PACKET_WIDTH - DX_WIDTH)
  ) south_buffer (
      .clock       (clock),
      .clear       (clear),
      .input_valid (south_shaped_valid),
      .input_ready (south_shaped_ready),
      .input_data  (south_shaped_data),
      .output_valid(south_valid),
      .output_ready(south_ready),
      .output_data (south_data)
  );

  assign done_o = crossbar_done && ~ext_output_valid && ~north_valid && ~south_valid;

endmodule
