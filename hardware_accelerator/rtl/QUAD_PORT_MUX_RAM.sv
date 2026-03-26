`timescale 1ns / 1ps

module QUAD_PORT_MUX_RAM #(
    parameter RAM_WIDTH = 8,
    parameter RAM_ADDR_BITS = 4,
    parameter INIT_MEM_FILE = ""
)(
    input clk_i,
    input port_switch_i,

    input port_a_we_i,
    input [RAM_ADDR_BITS-1:0] port_a_waddr_i,
    input [RAM_WIDTH-1:0]     port_a_data_in,

    input port_a_re_i,
    input [RAM_ADDR_BITS-1:0] port_a_raddr_i,
    output [RAM_WIDTH-1:0]    port_a_data_out,

    input port_b_we_i,
    input [RAM_ADDR_BITS-1:0] port_b_waddr_i,
    input [RAM_WIDTH-1:0]     port_b_data_in,

    input port_b_re_i,
    input [RAM_ADDR_BITS-1:0] port_b_raddr_i,
    output [RAM_WIDTH-1:0]    port_b_data_out
);

    // Internal signals for RAM selection
    wire ram0_read_en, ram0_write_en;
    wire ram1_read_en, ram1_write_en;
    wire [RAM_WIDTH-1:0] ram0_data_out, ram1_data_out;

    // RAM selection logic based on port_switch_i
    assign ram0_write_en = (port_switch_i) ? port_a_we_i : port_b_we_i;
    assign ram0_read_en  = (port_switch_i) ? port_a_re_i : port_b_re_i;

    assign ram1_write_en = (port_switch_i) ? port_b_we_i : port_a_we_i;
    assign ram1_read_en  = (port_switch_i) ? port_b_re_i : port_a_re_i;

    assign port_a_data_out = (port_switch_i) ? ram0_data_out : ram1_data_out;
    assign port_b_data_out = (port_switch_i) ? ram1_data_out : ram0_data_out;

    // First dual-port RAM instance
    DUAL_PORT_RAM #(
        .DATA_WIDTH(RAM_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_BITS),
        .INIT_MEM_FILE(INIT_MEM_FILE)
    ) ram_0 (
        .clk_i(clk_i),
        .read_en_i(ram0_read_en),
        .read_addr_i((port_switch_i) ? port_a_raddr_i : port_b_raddr_i),
        .data_out(ram0_data_out),
        .write_en_i(ram0_write_en),
        .write_addr_i((port_switch_i) ? port_a_waddr_i : port_b_waddr_i),
        .data_in((port_switch_i) ? port_a_data_in : port_b_data_in)
    );

    // Second dual-port RAM instance
    DUAL_PORT_RAM #(
        .DATA_WIDTH(RAM_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_BITS),
        .INIT_MEM_FILE(INIT_MEM_FILE)
    ) ram_1 (
        .clk_i(clk_i),
        .read_en_i(ram1_read_en),
        .read_addr_i((port_switch_i) ? port_b_raddr_i : port_a_raddr_i),
        .data_out(ram1_data_out),
        .write_en_i(ram1_write_en),
        .write_addr_i((port_switch_i) ? port_b_waddr_i : port_a_waddr_i),
        .data_in((port_switch_i) ? port_b_data_in : port_a_data_in)
    );

endmodule
