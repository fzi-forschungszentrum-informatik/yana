// Copyright (c) 2026 YANA contributors
// Licensed under CERN-OHL-W Version 2, see LICENSE-hardware
//
// This file contains heavily modified code derived from the RANC project.
// Original work Copyright (c) 2020 - present Joshua Mack, Ruben Purdy, Edward Richter,
// Spencer Valancius, and other contributors
// Licensed under the MIT License, see LICENSE-ranc

`timescale 1ns / 1ps

module Router #(
    parameter integer PACKET_WIDTH = 30,
    parameter integer DX_WIDTH     = 8,
    parameter integer DY_WIDTH     = 8
) (
    input wire clk_i,
    input wire rst_i,

    output wire done_o,

    input  wire                    local_input_valid_i,
    output wire                    local_input_ready_o,
    input  wire [PACKET_WIDTH-1:0] local_input_data_i,

    input  wire                    west_input_valid_i,
    output wire                    west_input_ready_o,
    input  wire [PACKET_WIDTH-1:0] west_input_data_i,

    input  wire                    east_input_valid_i,
    output wire                    east_input_ready_o,
    input  wire [PACKET_WIDTH-1:0] east_input_data_i,

    input  wire                             north_input_valid_i,
    output wire                             north_input_ready_o,
    input  wire [PACKET_WIDTH-DX_WIDTH-1:0] north_input_data_i,

    input  wire                             south_input_valid_i,
    output wire                             south_input_ready_o,
    input  wire [PACKET_WIDTH-DX_WIDTH-1:0] south_input_data_i,

    output wire                    west_output_valid_o,
    input  wire                    west_output_ready_i,
    output wire [PACKET_WIDTH-1:0] west_output_data_o,

    output wire                    east_output_valid_o,
    input  wire                    east_output_ready_i,
    output wire [PACKET_WIDTH-1:0] east_output_data_o,

    output wire                             north_output_valid_o,
    input  wire                             north_output_ready_i,
    output wire [PACKET_WIDTH-DX_WIDTH-1:0] north_output_data_o,

    output wire                             south_output_valid_o,
    input  wire                             south_output_ready_i,
    output wire [PACKET_WIDTH-DX_WIDTH-1:0] south_output_data_o,

    output wire                                      local_output_valid_o,
    input  wire                                      local_output_ready_i,
    output wire [PACKET_WIDTH-DX_WIDTH-DY_WIDTH-1:0] local_output_data_o
);

  wire east_from_local_valid_o, west_from_local_valid_o;
  wire east_from_local_ready_i, west_from_local_ready_i;
  wire [PACKET_WIDTH-1:0] east_from_local_data_o, west_from_local_data_o;

  wire east_to_north_valid_o, east_to_south_valid_o;
  wire east_to_north_ready_i, east_to_south_ready_i;
  wire [PACKET_WIDTH-DX_WIDTH-1:0] east_to_north_data_o, east_to_south_data_o;

  wire west_to_north_valid_o, west_to_south_valid_o;
  wire west_to_north_ready_i, west_to_south_ready_i;
  wire [PACKET_WIDTH-DX_WIDTH-1:0] west_to_north_data_o, west_to_south_data_o;

  wire north_to_local_valid_o, south_to_local_valid_o;
  wire north_to_local_ready_i, south_to_local_ready_i;
  wire [PACKET_WIDTH-DX_WIDTH-DY_WIDTH-1:0] north_to_local_data_o, south_to_local_data_o;

  wire from_local_done, forward_east_done, forward_west_done, forward_north_done, forward_south_done, to_local_done;

  FromLocal #(
      .PACKET_WIDTH(PACKET_WIDTH),
      .DX_WIDTH(DX_WIDTH)
  ) from_local (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(from_local_done),
      .input_valid(local_input_valid_i),
      .input_ready(local_input_ready_o),
      .input_data(local_input_data_i),
      .east_valid(east_from_local_valid_o),
      .east_ready(east_from_local_ready_i),
      .east_data(east_from_local_data_o),
      .west_valid(west_from_local_valid_o),
      .west_ready(west_from_local_ready_i),
      .west_data(west_from_local_data_o)
  );

  ForwardEastWest #(
      .PACKET_WIDTH(PACKET_WIDTH),
      .DX_WIDTH(DX_WIDTH),
      .DY_WIDTH(DY_WIDTH),
      .EAST(1)
  ) forward_east (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(forward_east_done),
      .ext_input_valid(west_input_valid_i),
      .ext_input_ready(west_input_ready_o),
      .ext_input_data(west_input_data_i),
      .local_input_valid(east_from_local_valid_o),
      .local_input_ready(east_from_local_ready_i),
      .local_input_data(east_from_local_data_o),
      .ext_output_valid(east_output_valid_o),
      .ext_output_ready(east_output_ready_i),
      .ext_output_data(east_output_data_o),
      .north_valid(east_to_north_valid_o),
      .north_ready(east_to_north_ready_i),
      .north_data(east_to_north_data_o),
      .south_valid(east_to_south_valid_o),
      .south_ready(east_to_south_ready_i),
      .south_data(east_to_south_data_o)
  );

  ForwardEastWest #(
      .PACKET_WIDTH(PACKET_WIDTH),
      .DX_WIDTH(DX_WIDTH),
      .DY_WIDTH(DY_WIDTH),
      .EAST(0)
  ) forward_west (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(forward_west_done),
      .ext_input_valid(east_input_valid_i),
      .ext_input_ready(east_input_ready_o),
      .ext_input_data(east_input_data_i),
      .local_input_valid(west_from_local_valid_o),
      .local_input_ready(west_from_local_ready_i),
      .local_input_data(west_from_local_data_o),
      .ext_output_valid(west_output_valid_o),
      .ext_output_ready(west_output_ready_i),
      .ext_output_data(west_output_data_o),
      .north_valid(west_to_north_valid_o),
      .north_ready(west_to_north_ready_i),
      .north_data(west_to_north_data_o),
      .south_valid(west_to_south_valid_o),
      .south_ready(west_to_south_ready_i),
      .south_data(west_to_south_data_o)
  );

  ForwardNorthSouth #(
      .PACKET_WIDTH(PACKET_WIDTH - DX_WIDTH),
      .DY_WIDTH(DY_WIDTH),
      .NORTH(1)
  ) forward_north (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(forward_north_done),
      .routing_valid(south_input_valid_i),
      .routing_ready(south_input_ready_o),
      .routing_data(south_input_data_i),
      .east_valid(east_to_north_valid_o),
      .east_ready(east_to_north_ready_i),
      .east_data(east_to_north_data_o),
      .west_valid(west_to_north_valid_o),
      .west_ready(west_to_north_ready_i),
      .west_data(west_to_north_data_o),
      .routing_output_valid(north_output_valid_o),
      .routing_output_ready(north_output_ready_i),
      .routing_output_data(north_output_data_o),
      .local_valid(north_to_local_valid_o),
      .local_ready(north_to_local_ready_i),
      .local_data(north_to_local_data_o)
  );

  ForwardNorthSouth #(
      .PACKET_WIDTH(PACKET_WIDTH - DX_WIDTH),
      .DY_WIDTH(DY_WIDTH),
      .NORTH(0)
  ) forward_south (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(forward_south_done),
      .routing_valid(north_input_valid_i),
      .routing_ready(north_input_ready_o),
      .routing_data(north_input_data_i),
      .east_valid(east_to_south_valid_o),
      .east_ready(east_to_south_ready_i),
      .east_data(east_to_south_data_o),
      .west_valid(west_to_south_valid_o),
      .west_ready(west_to_south_ready_i),
      .west_data(west_to_south_data_o),
      .routing_output_valid(south_output_valid_o),
      .routing_output_ready(south_output_ready_i),
      .routing_output_data(south_output_data_o),
      .local_valid(south_to_local_valid_o),
      .local_ready(south_to_local_ready_i),
      .local_data(south_to_local_data_o)
  );

  ToLocal #(
      .PACKET_WIDTH(PACKET_WIDTH - DX_WIDTH - DY_WIDTH)
  ) to_local (
      .clock(clk_i),
      .clear(rst_i),
      .done_o(to_local_done),
      .north_valid(north_to_local_valid_o),
      .north_ready(north_to_local_ready_i),
      .north_data(north_to_local_data_o),
      .south_valid(south_to_local_valid_o),
      .south_ready(south_to_local_ready_i),
      .south_data(south_to_local_data_o),
      .output_valid(local_output_valid_o),
      .output_ready(local_output_ready_i),
      .output_data(local_output_data_o)
  );

  assign done_o = from_local_done &&
                  forward_east_done &&
                  forward_west_done &&
                  forward_north_done &&
                  forward_south_done &&
                  to_local_done;

endmodule
