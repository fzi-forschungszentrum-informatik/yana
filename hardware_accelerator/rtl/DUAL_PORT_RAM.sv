`timescale 1ns / 1ps

(* dont_touch = "yes" *)
module DUAL_PORT_RAM #(
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 32,
    parameter INIT_MEM_FILE = ""
)(
    input clk_i,

    input read_en_i,
    input [ADDR_WIDTH-1:0] read_addr_i,
    output reg [DATA_WIDTH-1:0] data_out,

    input write_en_i,
    input [ADDR_WIDTH-1:0] write_addr_i,
    input [DATA_WIDTH-1:0] data_in
);

    (* ram_style="block" *)
    reg [DATA_WIDTH-1:0] ram [(2**ADDR_WIDTH)-1:0];

    // If given, the RAM will be initialzied using a mem file.
    // This only works during simulation or on SRAM-based FPGAs (e.g. Xilinx).
    initial begin
        if (INIT_MEM_FILE != "") begin
            $display("Writing Memory (DUAL_PORT_RAM.sv)");
            $readmemh(INIT_MEM_FILE, ram);
        end
    end

    always@(posedge clk_i) begin
        // read port
        if(read_en_i) begin
            data_out <= ram[read_addr_i];
        end

         // write port
        if(write_en_i) begin
            ram[write_addr_i] <= data_in;
        end
    end
endmodule
