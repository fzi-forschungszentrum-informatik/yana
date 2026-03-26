`timescale 1ns / 1ps

`include "global_params.vh"

module Tx #(
    parameter CORE_ID = 6'b000000,
    parameter OUTPUT_BUFFER_WIDTH = 24,
    parameter EVENT_WIDTH_INTERNAL = 17,
    parameter EVENT_WIDTH_EXTERNAL = 24
) (
    // Control Signals
    input clk_i,
    input enable_i,
    input rst_i,

    // Connection to Output Buffer
    output reg output_buffer_read_en_o,
    input output_buffer_read_valid_i,
    input [OUTPUT_BUFFER_WIDTH-1:0] output_buffer_data_in,

    // Connection to Rx
    output reg event_internal_valid_o,
    output reg [EVENT_WIDTH_INTERNAL -1 : 0] event_internal_o,

    // Connection to Router
    output reg event_external_valid_o,
    output reg [EVENT_WIDTH_EXTERNAL -1 : 0] event_external_o,

    // Done Logic
    input  axon_done_i,
    output tx_done_o,

    // Router signals overload
    input router_buffers_full_i

);

  // Done logic
  assign tx_done_o = axon_done_i & ~event_external_valid_o & ~event_internal_valid_o & ~output_buffer_read_valid_i & ~router_buffers_full_i;

  // Tx pipeline
  always @(posedge clk_i) begin

    if (rst_i) begin
      event_internal_valid_o  <= 0;
      event_external_valid_o  <= 0;
      output_buffer_read_en_o <= 0;
    end else if (enable_i) begin

      if (router_buffers_full_i) begin
        output_buffer_read_en_o <= 0;
      end else begin
        output_buffer_read_en_o <= 1;
      end

      if (output_buffer_read_valid_i) begin
        if (output_buffer_data_in[OUTPUT_BUFFER_WIDTH-1:EVENT_WIDTH_INTERNAL] == CORE_ID) begin
          event_internal_o <= output_buffer_data_in[EVENT_WIDTH_INTERNAL-1 : 0];
          event_internal_valid_o <= 1;
          event_external_valid_o <= 0;
          output_buffer_read_en_o <= 1;
        end else begin
          event_external_o <= output_buffer_data_in[EVENT_WIDTH_EXTERNAL-1 : 0];
          event_internal_valid_o <= 0;
          event_external_valid_o <= 1;
        end

      end else begin
        event_internal_valid_o <= 0;
        event_external_valid_o <= 0;
      end

    end else begin
      event_internal_valid_o  <= 0;
      event_external_valid_o  <= 0;
      output_buffer_read_en_o <= 0;
    end

  end

endmodule
