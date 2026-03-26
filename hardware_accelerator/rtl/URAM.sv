`timescale 1ns / 1ps

(* dont_touch = "yes" *)
module URAM #(
    // Set ADDR_WIDTH, DATA_WIDTH, ENTRY_WIDTH from the project; defaults are placeholders.
    // Addresses larger than default will result in auto cascade mode
    parameter ADDR_WIDTH = 12,  // one URAM Block 
    // Data width larger than default will result in auto bank striping
    parameter DATA_WIDTH = 72,  // If parity bits are used a URAM can store up to 72 Bits
    parameter ENTRY_WIDTH = 8,  // Defines how many entries can be stored in one data line
    parameter BYTE_WIDTH = 9, // BYTE width of URAM memory
    parameter INIT_MEM_FILE = ""
) (
    input clk_i, 

    // write
    input we_i,
    input [ADDR_WIDTH-1:0] write_addr_i,
    input [DATA_WIDTH-1:0] data_i,

    // read
    input re_i,
    input [ADDR_WIDTH-1:0] read_addr_i,
    input [$clog2(DATA_WIDTH/ENTRY_WIDTH)-1 : 0] read_entry_select_i,
    output reg [ENTRY_WIDTH-1:0] data_o
);

  (* ram_style = "ultra" *)
  reg [DATA_WIDTH-1:0] ram[(2**ADDR_WIDTH)-1:0];
  
  reg [DATA_WIDTH-1:0] ram_out;
  reg [$clog2(DATA_WIDTH/ENTRY_WIDTH)-1 : 0] read_select;

  // Optional simulation preload via $readmemh (disabled for synthesis).
 `ifndef SYNTHESIS
    initial begin
      if (INIT_MEM_FILE != "") begin
        $display("Writing Memory (URAM.sv)");
        $readmemh(INIT_MEM_FILE, ram);
      end
    end
  `endif
  
  /*
  * DATA_WIDTH should be a multiple of ENTRY_WIDTH, otherwise memory is wasted.
  * Storing entries over multiple memory lines is not supported.
  */
  localparam ENTRIES_PER_LINE = DATA_WIDTH / BYTE_WIDTH;
  integer i;


  always @(posedge clk_i) begin : write_uram
    if (we_i) begin
      for (i = 0; i < ENTRIES_PER_LINE; i = i + 1) begin
        ram[write_addr_i][i*BYTE_WIDTH+:BYTE_WIDTH] <= data_i[i*BYTE_WIDTH+:BYTE_WIDTH];
      end
    end
  end


  always @(posedge clk_i) begin : read_uram
    if (re_i) begin
      ram_out <= ram[read_addr_i];
      read_select <= read_entry_select_i;
    end
  end

  assign data_o = ram_out[read_select*ENTRY_WIDTH+:ENTRY_WIDTH];

endmodule