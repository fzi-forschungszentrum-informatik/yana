`include "global_params.vh"

module InputMulticast #(
    parameter EVENT_SOURCE_WIDTH = INPUT_EVENT_SOURCE_WIDTH_G,

    // Input core related
    parameter SPIKE_OUT_FIFO_DATA_WIDTH = SPIKE_OUT_FIFO_DATA_WIDTH_G,
    // Axon
    parameter URAM_ROUTES_ADDR_WIDTH  = AXON_ROUTES_RAM_ADDR_WIDTH_G,
    parameter URAM_ROUTES_DATA_WIDTH  = AXON_ROUTES_RAM_DATA_WIDTH_G,
    parameter URAM_ROUTES_ENTRY_WIDTH = AXON_ROUTES_RAM_ENTRY_WIDTH_G,
    parameter URAM_ROUTES_BYTE_WIDTH  = AXON_ROUTES_RAM_BYTE_WIDTH_G,
    parameter URAM_ROUTES_INIT_FILE   = AXON_ROUTES_RAM_INIT_FILE_MULTICAST_G,
    parameter URAM_MAPPING_ADDR_WIDTH = AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH_G,
    parameter URAM_MAPPING_DATA_WIDTH = AXON_MEMORY_MAPPING_RAM_DATA_WIDTH_G,
    parameter URAM_MAPPING_INIT_FILE  = AXON_MAPPING_RAM_INIT_FILE_MULTICAST_G,
    // Output Fifo
    parameter OUTPUT_FIFO_DATA_WIDTH = OUTPUT_FIFO_DATA_WIDTH_G
)(
    input clk_i,
    input rstn_i,
    input en_i,

    output idle_o,

    // Interface to input core
    output                         input_core_read_en_o,
    input                          input_core_read_valid_i,
    input [EVENT_SOURCE_WIDTH-1:0] input_core_data_i,

    // Output interface
    input                               output_read_en_i,
    output                              output_read_valid_o,
    output [OUTPUT_FIFO_DATA_WIDTH-1:0] output_data_o,

    // Expose routes and mapping URAMs
    input                              axon_routes_ram_write_enable_i,
    input [URAM_ROUTES_ADDR_WIDTH-1:0] axon_routes_ram_write_addr_i,
    input [URAM_ROUTES_DATA_WIDTH-1:0] axon_routes_ram_data_i,
    input                               axon_memory_mapping_ram_write_en_i,
    input [URAM_MAPPING_ADDR_WIDTH-1:0] axon_memory_mapping_ram_write_addr_i,
    input [URAM_MAPPING_DATA_WIDTH-1:0] axon_memory_mapping_ram_data_in_i
);

// Output FIFO
wire [OUTPUT_FIFO_DATA_WIDTH-1:0] output_fifo_data_in_w;
wire output_fifo_write_enable_w;
wire output_fifo_full_w;

core_output_fifo output_FIFO (
    .clk      (clk_i),
    .srst     (~rstn_i),
    .din      (output_fifo_data_in_w),
    .wr_en    (output_fifo_write_enable_w),
    .rd_en    (output_read_en_i),
    .dout     (output_data_o),
    .prog_full(output_fifo_full_w),
    .valid    (output_read_valid_o)
);

// Axon
wire axon_done_w;
assign idle_o = axon_done_w;

axon #(
    .SPIKE_OUT_FIFO_DATA_WIDTH(SPIKE_OUT_FIFO_DATA_WIDTH),
    .OUTPUT_BUFFER_DATA_WIDTH (OUTPUT_FIFO_DATA_WIDTH),

    .URAM_ROUTES_ADDR_WIDTH (URAM_ROUTES_ADDR_WIDTH),
    .URAM_ROUTES_DATA_WIDTH (URAM_ROUTES_DATA_WIDTH),
    .URAM_ROUTES_ENTRY_WIDTH(URAM_ROUTES_ENTRY_WIDTH),
    .URAM_ROUTES_BYTE_WIDTH (URAM_ROUTES_BYTE_WIDTH),
    .URAM_ROUTES_INIT_FILE  (URAM_ROUTES_INIT_FILE),

    .URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH(URAM_MAPPING_ADDR_WIDTH),
    .URAM_MEMORY_MAPPING_RAM_DATA_WIDTH(URAM_MAPPING_DATA_WIDTH),
    .URAM_MEMORY_MAPPING_RAM_INIT_FILE (URAM_MAPPING_INIT_FILE)
) inst_axon (
    // Control signals
    .clk_i(clk_i),
    .rst_i(~rstn_i),
    .enable_i(en_i),

    // Connection to input core
    .spike_out_fifo_read_enable_o(input_core_read_en_o),
    .spike_out_fifo_read_valid_i(input_core_read_valid_i),
    .spike_out_fifo_data_i(input_core_data_i),

    // Connection to Output Buffer
    .output_buffer_full_i(output_fifo_full_w),
    .output_buffer_write_enable_o(output_fifo_write_enable_w),
    .output_buffer_data_o(output_fifo_data_in_w),

    // Done logic
    .neuron_done_i(1'b1),
    .axon_done_o  (axon_done_w),

    // Expose Route URAM Write Port
    .ram_routes_write_enable_i(axon_routes_ram_write_enable_i),
    .ram_routes_write_addr_i(axon_routes_ram_write_addr_i),
    .ram_routes_data_i(axon_routes_ram_data_i),

    // Expose URAM Memory mapping RAM Write Port
    .uram_memory_mapping_ram_write_en_i(axon_memory_mapping_ram_write_en_i),
    .uram_memory_mapping_ram_write_addr_i(axon_memory_mapping_ram_write_addr_i),
    .uram_memory_mapping_ram_data_in_i(axon_memory_mapping_ram_data_in_i)
);

endmodule
