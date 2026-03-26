`timescale 1ns / 1ps

module SINGLE_PORT_LUTRAM #(
    parameter RAM_WIDTH     = 8,
    parameter RAM_ADDR_BITS = 4,
    parameter INIT_MEM_FILE = ""
)(
    input clkw,                         // Write clock
    input we_i,                         // Write enable
    input [RAM_WIDTH-1:0]     data_in,
    input [RAM_ADDR_BITS-1:0] addr_i,

    output [RAM_WIDTH-1:0] data_out
);

    (* ram_style="distributed" *)
    reg [RAM_WIDTH-1:0] ram [0:(2**RAM_ADDR_BITS)-1];

    // If given, the RAM will be initialzied using a mem file.
    // This only works during simulation or on SRAM-based FPGAs (e.g. Xilinx).
    initial begin
        if (INIT_MEM_FILE != "") begin
            $info("SINGLE_PORT_LUTRAM using mem file '%s'", INIT_MEM_FILE);
            $readmemh(INIT_MEM_FILE, ram);
            if (ram[0][0] === 1'bx) begin
                $fatal(1, "SINGLE_PORT_LUTRAM readmemh error");
            end
        end else begin
            $info("SINGLE_PORT_LUTRAM no memory file specified");
        end
    end

    always @(posedge clkw) begin
        if (we_i) begin
            ram[addr_i] <= data_in;
        end
    end

    assign data_out = ram[addr_i];

endmodule