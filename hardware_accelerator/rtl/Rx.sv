`timescale 1ns / 1ps

`include "global_params.vh"

module Rx #(
    parameter INPUT_DATA_WIDTH = 17,
    parameter BUFFER_DEPTH = RX_BUFFER_DEPTH_G
) (
    input clk_i,
    input rst_i,
    input enable_i,

    // Input from NoC
    input [INPUT_DATA_WIDTH -1 : 0] evt_i,
    input evt_valid_i,

    // Input from Tx
    input [INPUT_DATA_WIDTH -1 : 0] evt_internal_i,
    input evt_internal_valid_i,

    // Input FIFO
    output reg input_fifo_we_o,
    output reg [INPUT_DATA_WIDTH -1 : 0] input_fifo_data_out_o,
    input input_fifo_buffer_full_i,

    // Done logic
    input tx_done_i,
    input router_done_i,

    // Full flag
    output buffer_full_o,
    output buffer_empty_o,

    output rx_done_o
);
  reg buffer_full;
  reg buffer_empty;

  reg [$clog2(BUFFER_DEPTH)-1:0] buffer_pointer;
  reg [INPUT_DATA_WIDTH-1:0] evt_internal_buffer[BUFFER_DEPTH-1:0];

  assign rx_done_o = tx_done_i & router_done_i & ~evt_valid_i & ~evt_internal_valid_i 
                      & ~buffer_full & buffer_empty & ~input_fifo_we_o;
  assign buffer_full_o = buffer_full;
  assign buffer_empty_o = buffer_empty;

  always @(posedge clk_i) begin
    if (rst_i) begin
        buffer_pointer <= 0;
        buffer_full    <= 0;
        buffer_empty   <= 1;
    end else if (enable_i) begin
       case ({
        evt_valid_i, evt_internal_valid_i
      })

        2'b00: begin  // no input at all
          if (!buffer_empty) begin
            input_fifo_we_o <= 1;

            if (buffer_full) begin
              input_fifo_data_out_o <= evt_internal_buffer[BUFFER_DEPTH-1];
              buffer_full <= 0;
              buffer_pointer <= buffer_pointer - 1;
            end else begin
              if (buffer_pointer == 0) begin
                buffer_empty <= 1;
                input_fifo_we_o <= 0; // No data left in buffer, clear write enable
              end else begin
                input_fifo_data_out_o <= evt_internal_buffer[buffer_pointer-1];
                buffer_pointer <= buffer_pointer - 1;
              end
            end
          end else begin
            input_fifo_we_o <= 0;
          end
        end

        2'b01: begin  // only internal data
          input_fifo_data_out_o <= evt_internal_i;
          input_fifo_we_o <= 1;
        end

        2'b10: begin  // only external data
          input_fifo_we_o <= 1;

          if (!buffer_empty) begin
            if (buffer_full) begin
              input_fifo_data_out_o <= evt_internal_buffer[BUFFER_DEPTH-1];
              buffer_full <= 0;
              buffer_pointer <= buffer_pointer - 1;
            end else begin
              if (buffer_pointer == 0) begin
                buffer_empty <= 1;
                input_fifo_data_out_o <= evt_i; // No data left in buffer, send fresh data
              end else begin
                input_fifo_data_out_o <= evt_internal_buffer[buffer_pointer-1];
                buffer_pointer <= buffer_pointer - 1;
              end
            end
          end else begin
            input_fifo_data_out_o <= evt_i;
          end
        end

        2'b11: begin  // both internal and external data
          input_fifo_data_out_o <= evt_internal_i;
          input_fifo_we_o <= 1;

          if (!buffer_full) begin
            evt_internal_buffer[buffer_pointer] <= evt_i;

            if (buffer_pointer == (BUFFER_DEPTH - 1)) begin
              buffer_full <= 1;
            end

            buffer_pointer <= buffer_pointer + 1;
            buffer_empty <= 0;
          end
        end
      endcase
    end
  end

endmodule