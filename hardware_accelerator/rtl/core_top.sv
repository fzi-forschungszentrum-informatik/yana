`timescale 1ns / 1ps

`include "global_params.vh"

// Enable sequencing for the host / wrapping module: set timestep and router_done, assert enable, wait for done, then deassert enable.

module core_top #(
    // General
    parameter CORE_ID = 6'b000000,
    parameter TIMESTEP_WIDTH = TIMESTEP_WIDTH_G,

    // Rx
    parameter INPUT_DATA_WIDTH = INPUT_DATA_WIDTH_G,

    // Input FIFO
    parameter INPUT_FIFO_DATA_WIDTH = INPUT_DATA_WIDTH_G,
    parameter INPUT_FIFO_DATA_NEURON_WIDTH = NEURON_WIDTH_G,
    parameter INPUT_FIFO_DATA_SYNAPSE_WIDTH = SYNAPSE_WIDTH_G,

    // Synapse
    parameter SYNAPSE_WEIGHT_RAM_ADDR_WIDTH = WEIGHT_RAM_ADDR_WIDTH_G,
    parameter SYNAPSE_WEIGHT_RAM_DATA_WIDTH = WEIGHT_RAM_DATA_WIDTH_G,
    parameter SYNAPSE_WEIGHT_RAM_WEIGHT_WIDTH = WEIGHT_RAM_WEIGHT_WIDTH_G,
    parameter SYNAPSE_WEIGHT_RAM_INIT_FILE = WEIGHT_RAM_INIT_FILE_G,

    // Hot Neuron FIFO
    parameter HOT_NEURON_FIFO_DATA_WIDTH = HOT_NEURON_FIFO_DATA_WIDTH_G,

    // QUAD Port Mux RAM
    parameter QUAD_PORT_MUX_RAM_ADDR_WIDTH = QUAD_PORT_MUX_RAM_ADDR_WIDTH_G,
    parameter QUAD_PORT_MUX_RAM_DATA_WIDTH = QUAD_PORT_MUX_RAM_DATA_WIDTH_G,
    parameter QUAD_PORT_MUX_RAM_DECIMALS   = QUAD_PORT_MUX_RAM_DECIMALS_G,
    parameter QUAD_PORT_MUX_RAM_INIT_FILE  = QUAD_PORT_MUX_RAM_INIT_FILE_G,

    // Leak RAM
    parameter RAM_LEAK_ADDR_WIDTH    = RAM_LEAK_ADDR_WIDTH_G,
    parameter RAM_LEAK_DATA_WIDTH    = RAM_LEAK_DATA_WIDTH_G,
    parameter RAM_LEAK_DECIMALS      = RAM_LEAK_DECIMALS_G,
    parameter RAM_LEAK_INIT_MEM_FILE = RAM_LEAK_INIT_MEM_FILE_G,

    // Neuron config
    parameter NEURON_TAU_MEM_INV_DATA_WIDTH = TAU_MEM_INV_DATA_WIDTH_G,
    parameter NEURON_TAU_MEM_INV_DECIMALS   = TAU_MEM_INV_DECIMALS_G,
    parameter NEURON_TAU_MEM_INV            = TAU_MEM_INV_G,

    // Neuron state RAM
    parameter NEURON_STATE_DATA_WIDTH = NEURON_STATE_DATA_WIDTH_G,
    parameter NEURON_STATE_DECIMALS = NEURON_STATE_DECIMALS_G,

    // Spike Out Fifo
    parameter SPIKE_OUT_FIFO_DATA_WIDTH = SPIKE_OUT_FIFO_DATA_WIDTH_G,

    // Axon
    parameter AXON_ROUTES_RAM_ADDR_WIDTH  = AXON_ROUTES_RAM_ADDR_WIDTH_G,
    parameter AXON_ROUTES_RAM_DATA_WIDTH  = AXON_ROUTES_RAM_DATA_WIDTH_G,
    parameter AXON_ROUTES_RAM_ENTRY_WIDTH = AXON_ROUTES_RAM_ENTRY_WIDTH_G,
    parameter AXON_ROUTES_RAM_BYTE_WIDTH  = AXON_ROUTES_RAM_BYTE_WIDTH_G,
    parameter AXON_ROUTES_RAM_INIT_FILE   = AXON_ROUTES_RAM_INIT_FILE_CORE_TOP_G,

    parameter AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH = AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH_G,
    parameter AXON_MEMORY_MAPPING_RAM_DATA_WIDTH = AXON_MEMORY_MAPPING_RAM_DATA_WIDTH_G,
    parameter AXON_MEMORY_MAPPING_RAM_INIT_FILE  = AXON_MAPPING_RAM_INIT_FILE_CORE_TOP_G,

    parameter URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH = URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH_G,
    parameter URAM_MEMORY_MAPPING_START_ADDR_WIDTH = URAM_MEMORY_MAPPING_START_ADDR_WIDTH_G,

    // Output Fifo
    parameter OUTPUT_FIFO_DATA_WIDTH = OUTPUT_FIFO_DATA_WIDTH_G,

    // Tx
    parameter OUTPUT_INTERNAL_DATA_WIDTH = OUTPUT_INTERNAL_DATA_WIDTH_G,
    parameter OUTPUT_EXTERNAL_DATA_WIDTH = OUTPUT_EXTERNAL_DATA_WIDTH_G

) (
    // Signals from/to control unit
    input clk_i,
    input rst_i,
    input [1:0] rst_mems_i, // 2 bit: first bit weight sum, second bit neuron states
    output rst_done_o,
    input [TIMESTEP_WIDTH-1:0] timestep_i,
    input enable_i,
    output reg neuron_core_done_o,

    // Incoming router signals to RX
    input event_valid_i,
    input [INPUT_DATA_WIDTH - 1 : 0] event_i,
    output event_ready_o,
    input router_done_i,

    // Router signals from TX
    input router_buffers_full_i,
    output event_valid_o,
    output [OUTPUT_EXTERNAL_DATA_WIDTH - 1 : 0] event_o,

    // Expose Weight RAM from Synapse to control for weight updates
    input synapse_weight_ram_we_i,
    input [SYNAPSE_WEIGHT_RAM_ADDR_WIDTH -1 :0] synapse_weight_ram_addr_i,
    input [SYNAPSE_WEIGHT_RAM_DATA_WIDTH -1 :0] synapse_weight_ram_data_in,

    // Expose Routes RAM to control for route updates
    input axon_routes_ram_write_enable_i,
    input [AXON_ROUTES_RAM_ADDR_WIDTH-1:0] axon_routes_ram_write_addr_i,
    input [AXON_ROUTES_RAM_DATA_WIDTH-1:0] axon_routes_ram_data_i,

    // Expose Mapping RAM to control for mapping information updates
    input axon_memory_mapping_ram_write_en_i,
    input [AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH -1 : 0] axon_memory_mapping_ram_write_addr_i,
    input [AXON_MEMORY_MAPPING_RAM_DATA_WIDTH -1 : 0] axon_memory_mapping_ram_data_in_i,

    // Expose Leak RAM of neuron for leak term updates
    input                                      neuron_leak_ram_write_en_i,
    input [RAM_LEAK_ADDR_WIDTH - 1 : 0]        neuron_leak_ram_addr_i,
    input [RAM_LEAK_DATA_WIDTH - 1 : 0]        neuron_leak_ram_data_i,

    // Expose neuron configuration
    input [NEURON_TAU_MEM_INV_DATA_WIDTH-1:0] neuron_tau_mem_inv
);

  // ---------- INTERNAL SIGNALS ----------

  // Done signals
  wire fifos_in_done_w;
  wire fifos_out_done_w;
  wire fifos_done_w;
  reg [1:0] fifos_done_r;

  // Reset signals
  wire neuron_wrapper_rst_done_w;
  reg qpmr_rst_done_r;

  reg                                    rst_qpmr_port_a_we_r;
  reg [QUAD_PORT_MUX_RAM_ADDR_WIDTH-1:0] rst_qpmr_port_a_waddr_r = {QUAD_PORT_MUX_RAM_ADDR_WIDTH{1'b0}};
  reg                                    rst_qpmr_port_b_we_r;
  reg [QUAD_PORT_MUX_RAM_ADDR_WIDTH-1:0] rst_qpmr_port_b_waddr_r = {QUAD_PORT_MUX_RAM_ADDR_WIDTH{1'b0}};

  // ---------- INSTANTIATE MEMORIES ----------

  // QUAD_PORT_MUX_RAM

  // Multiplexed write signals
  reg                                       mux_qpmr_port_a_we_w;
  reg [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] mux_qpmr_port_a_waddr_w;
  reg [QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 0] mux_qpmr_port_a_data_in_w;
  reg                                       mux_qpmr_port_b_we_w;
  reg [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] mux_qpmr_port_b_waddr_w;
  reg [QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 0] mux_qpmr_port_b_data_in_w;

  // Signals connected to other modules
  wire qpmr_port_a_we_w;
  wire [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] qpmr_port_a_waddr_w;
  wire [QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 0] qpmr_port_a_data_in_w;

  wire qpmr_port_a_re_w;
  wire [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] qpmr_port_a_raddr_w;
  wire [QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 0] qpmr_port_a_data_out_w;

  wire qpmr_port_b_we_w;
  wire [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] qpmr_port_b_waddr_w;
  wire [QUAD_PORT_MUX_RAM_DATA_WIDTH -2 : 0] qpmr_port_b_data_in_w; // -2 because flag bit is cleared by appending

  wire qpmr_port_b_re_w;
  wire [QUAD_PORT_MUX_RAM_ADDR_WIDTH -1 : 0] qpmr_port_b_raddr_w;
  wire [QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 0] qpmr_port_b_data_out_w;


  QUAD_PORT_MUX_RAM #(
      .RAM_ADDR_BITS(QUAD_PORT_MUX_RAM_ADDR_WIDTH),
      .RAM_WIDTH(QUAD_PORT_MUX_RAM_DATA_WIDTH),
      .INIT_MEM_FILE(QUAD_PORT_MUX_RAM_INIT_FILE)

  ) inst_qpmr (

      .clk_i(clk_i),
      .port_switch_i(timestep_i[0]),

      .port_a_we_i(mux_qpmr_port_a_we_w),
      .port_a_waddr_i(mux_qpmr_port_a_waddr_w),
      .port_a_data_in(mux_qpmr_port_a_data_in_w),

      .port_a_re_i(qpmr_port_a_re_w),
      .port_a_raddr_i(qpmr_port_a_raddr_w),
      .port_a_data_out(qpmr_port_a_data_out_w),

      .port_b_we_i(mux_qpmr_port_b_we_w),
      .port_b_waddr_i(mux_qpmr_port_b_waddr_w),
      .port_b_data_in(mux_qpmr_port_b_data_in_w),

      .port_b_re_i(qpmr_port_b_re_w),
      .port_b_raddr_i(qpmr_port_b_raddr_w),
      .port_b_data_out(qpmr_port_b_data_out_w)
  );

  // ---------- INSTANTIATE FIFOS ----------

  // Input FIFO
  wire [INPUT_FIFO_DATA_WIDTH -1 : 0] input_fifo_data_in_w;
  wire input_fifo_write_enable_w;
  wire input_fifo_buffer_full_w;
  wire input_fifo_read_enable_w;
  wire [INPUT_FIFO_DATA_WIDTH -1 : 0] input_fifo_data_out_w;
  wire input_fifo_read_valid_w;

  core_input_fifo input_FIFO (
      .clk  (clk_i),
      .srst (rst_i),
      .din  (input_fifo_data_in_w),
      .wr_en(input_fifo_write_enable_w),
      .full(input_fifo_buffer_full_w),
      .rd_en(input_fifo_read_enable_w),
      .dout (input_fifo_data_out_w),
      .valid(input_fifo_read_valid_w)
  );


  // Hot Neuron FIFO
  wire [HOT_NEURON_FIFO_DATA_WIDTH -1 : 0] hot_neuron_fifo_data_in_w;
  wire hot_neuron_fifo_write_enable_w;
  wire hot_neuron_fifo_read_enable_w;
  wire [HOT_NEURON_FIFO_DATA_WIDTH -1 : 0] hot_neuron_fifo_data_out_w;
  wire hot_neuron_fifo_full_w;
  wire hot_neuron_fifo_read_valid_w;

  core_hot_neuron_fifo hot_neuron_FIFO (
      .clk  (clk_i),
      .srst (rst_i),
      .din  (hot_neuron_fifo_data_in_w),
      .wr_en(hot_neuron_fifo_write_enable_w),
      .rd_en(hot_neuron_fifo_read_enable_w),
      .dout (hot_neuron_fifo_data_out_w),
      .full (hot_neuron_fifo_full_w),
      .valid(hot_neuron_fifo_read_valid_w)
  );


  // Spike Out FIFO
  wire [SPIKE_OUT_FIFO_DATA_WIDTH -1 : 0] spike_out_fifo_data_in_w;
  wire spike_out_fifo_write_enable_w;
  wire spike_out_fifo_read_enable_w;
  wire [SPIKE_OUT_FIFO_DATA_WIDTH -1 : 0] spike_out_fifo_data_out_w;
  wire spike_out_fifo_read_valid_w;

  core_spike_out_fifo spike_out_FIFO (
      .clk  (clk_i),
      .srst (rst_i),
      .din  (spike_out_fifo_data_in_w),
      .wr_en(spike_out_fifo_write_enable_w),
      .rd_en(spike_out_fifo_read_enable_w),
      .dout (spike_out_fifo_data_out_w),
      .valid(spike_out_fifo_read_valid_w)
  );


  // Output FIFO
  wire [OUTPUT_FIFO_DATA_WIDTH -1 : 0] output_fifo_data_in_w;
  wire output_fifo_write_enable_w;
  wire output_fifo_read_enable_w;
  wire [OUTPUT_FIFO_DATA_WIDTH -1 : 0] output_fifo_data_out_w;
  wire output_fifo_read_valid_w;
  wire output_fifo_full_w;

  core_output_fifo output_FIFO (
      .clk      (clk_i),
      .srst     (rst_i),
      .din      (output_fifo_data_in_w),
      .wr_en    (output_fifo_write_enable_w),
      .rd_en    (output_fifo_read_enable_w),
      .dout     (output_fifo_data_out_w),
      .prog_full(output_fifo_full_w),
      .valid    (output_fifo_read_valid_w)
  );



  // ---------- INSTANTIATE PIPELINES ----------

  // Rx

  // Connection signals to Tx
  wire [OUTPUT_INTERNAL_DATA_WIDTH -1 : 0] event_internal_w;
  wire event_internal_valid_w;
  wire tx_done_w;
  wire rx_buffer_full_w;
  wire rx_buffer_empty_w;
  assign event_ready_o = rx_buffer_empty_w;

  // Connection signals to synapse
  wire rx_done_w;

  Rx #(
      .INPUT_DATA_WIDTH(INPUT_DATA_WIDTH)

  ) inst_rx (

      // Control signals
      .clk_i(clk_i),
      .rst_i(rst_i),
      .enable_i(enable_i),

      // Input from NoC
      .evt_i(event_i),
      .evt_valid_i(event_valid_i),

      // Input from Tx
      .evt_internal_i(event_internal_w),
      .evt_internal_valid_i(event_internal_valid_w),

      // Input FIFO
      .input_fifo_we_o(input_fifo_write_enable_w),
      .input_fifo_data_out_o(input_fifo_data_in_w),
      .input_fifo_buffer_full_i(input_fifo_buffer_full_w),

      // Done logic
      .tx_done_i(tx_done_w),
      .router_done_i(router_done_i),

      .buffer_full_o(rx_buffer_full_w),
      .buffer_empty_o(rx_buffer_empty_w),

      .rx_done_o(rx_done_w)
  );


  // Synapse Pipeline

  wire synapse_done_w;

  synapse #(

      .INPUT_DATA_WIDTH(INPUT_FIFO_DATA_WIDTH),
      .INPUT_DATA_NEURON_WIDTH(INPUT_FIFO_DATA_NEURON_WIDTH),
      .INPUT_DATA_SYNAPSE_WIDTH(INPUT_FIFO_DATA_SYNAPSE_WIDTH),

      .HOT_NEURON_FIFO_DATA_WIDTH(HOT_NEURON_FIFO_DATA_WIDTH),

      .WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH(QUAD_PORT_MUX_RAM_DATA_WIDTH),
      .WEIGHT_SUM_AND_FLAG_RAM_ADDR_WIDTH(QUAD_PORT_MUX_RAM_ADDR_WIDTH),

      .WEIGHT_RAM_ADDR_WIDTH(SYNAPSE_WEIGHT_RAM_ADDR_WIDTH),
      .WEIGHT_RAM_WEIGHT_WIDTH(SYNAPSE_WEIGHT_RAM_WEIGHT_WIDTH),
      .WEIGHT_RAM_INIT_FILE(SYNAPSE_WEIGHT_RAM_INIT_FILE)

  ) inst_synapse (

      .clk_i(clk_i),
      .rst_i(rst_i),
      .rx_done_i(rx_done_w),
      .enable_i(enable_i),
      .timestep_i(timestep_i[0]),
      .done_o(synapse_done_w),

      .buffer_data_in_i(input_fifo_data_out_w),
      .buffer_read_valid_i(input_fifo_read_valid_w),
      .buffer_get_data_o(input_fifo_read_enable_w),

      .data_hot_neuron_fifo_o(hot_neuron_fifo_data_in_w),
      .we_hot_neuron_fifo_o  (hot_neuron_fifo_write_enable_w),
      .hot_neuron_fifo_full_i(hot_neuron_fifo_full_w),

      // connect to QUAD Port Mux RAM Port A
      .weight_sum_and_flag_ram_we_o(qpmr_port_a_we_w),
      .weight_sum_and_flag_ram_waddr_o(qpmr_port_a_waddr_w),
      .weight_sum_and_flag_ram_data_o(qpmr_port_a_data_in_w),

      .weight_sum_and_flag_ram_re_o(qpmr_port_a_re_w),
      .weight_sum_and_flag_ram_raddr_o(qpmr_port_a_raddr_w),
      .weight_sum_and_flag_ram_data_i(qpmr_port_a_data_out_w),

      // Weight RAM Write Port
      .weight_ram_we_i(synapse_weight_ram_we_i),
      .weight_ram_write_addr_i(synapse_weight_ram_addr_i),
      .weight_ram_data_i(synapse_weight_ram_data_in)
  );


  // Neuron Pipeline

  wire neuron_pipeline_done_w;

  neuron_wrapper #(
      .HOT_NEURON_FIFO_DATA_WIDTH(HOT_NEURON_FIFO_DATA_WIDTH),

      .WEIGHT_SUM_ADDR_WIDTH(QUAD_PORT_MUX_RAM_ADDR_WIDTH),
      .WEIGHT_SUM_DATA_WIDTH(QUAD_PORT_MUX_RAM_DATA_WIDTH - 1),  // no flag bit
      .WEIGHT_SUM_DECIMALS  (QUAD_PORT_MUX_RAM_DECIMALS),

      .SPIKE_OUT_FIFO_DATA_WIDTH(SPIKE_OUT_FIFO_DATA_WIDTH),

      .TAU_MEM_INV_DATA_WIDTH(NEURON_TAU_MEM_INV_DATA_WIDTH),
      .TAU_MEM_INV_DECIMALS(NEURON_TAU_MEM_INV_DECIMALS),
      .TAU_MEM_INV(NEURON_TAU_MEM_INV),

      .NEURON_STATE_DATA_WIDTH(NEURON_STATE_DATA_WIDTH),
      .NEURON_STATE_DECIMALS(NEURON_STATE_DECIMALS),

      .RAM_LEAK_ADDR_WIDTH(RAM_LEAK_ADDR_WIDTH),
      .RAM_LEAK_DATA_WIDTH(RAM_LEAK_DATA_WIDTH),
      .RAM_LEAK_DECIMALS(RAM_LEAK_DECIMALS),
      .RAM_LEAK_INIT_MEM_FILE(RAM_LEAK_INIT_MEM_FILE)
  ) inst_neuron_wrapper_lif (

      // Control
      .clk_i(clk_i),
      .rst_i(rst_i),
      .rst_mems_i(rst_mems_i[1]),
      .rst_done_o(neuron_wrapper_rst_done_w),
      .timestep_i(timestep_i),
      .enable_i(enable_i),
      .done_o(neuron_pipeline_done_w),

      // Connection to Hot Neuron FIFO
      .hot_neuron_fifo_re_o(hot_neuron_fifo_read_enable_w),
      .hot_neuron_fifo_data_i(hot_neuron_fifo_data_out_w),
      .hot_neuron_fifo_read_valid_i(hot_neuron_fifo_read_valid_w),

      // Connection to Spike Out FIFO
      .spike_out_fifo_we_o  (spike_out_fifo_write_enable_w),
      .spike_out_fifo_data_o(spike_out_fifo_data_in_w),

      // Connection to Quad Port MUX RAM
      .weight_sum_ram_we_o(qpmr_port_b_we_w),
      .weight_sum_ram_waddr_o(qpmr_port_b_waddr_w),
      .weight_sum_ram_data_o(qpmr_port_b_data_in_w),

      .weight_sum_ram_re_o(qpmr_port_b_re_w),
      .weight_sum_ram_raddr_o(qpmr_port_b_raddr_w),
      .weight_sum_ram_data_i(qpmr_port_b_data_out_w[QUAD_PORT_MUX_RAM_DATA_WIDTH -1 : 1]), // ignore flag bit

      // Write connection to neuron leak RAM
      .neuron_leak_ram_write_en_i(neuron_leak_ram_write_en_i),
      .neuron_leak_ram_addr_i(neuron_leak_ram_addr_i),
      .neuron_leak_ram_data_i(neuron_leak_ram_data_i),

      .neuron_tau_mem_inv(neuron_tau_mem_inv)
  );


  // Axon semi-pipelined

  wire axon_done_w;

  axon #(
      .SPIKE_OUT_FIFO_DATA_WIDTH(SPIKE_OUT_FIFO_DATA_WIDTH),
      .OUTPUT_BUFFER_DATA_WIDTH (OUTPUT_FIFO_DATA_WIDTH),

      .URAM_ROUTES_ADDR_WIDTH (AXON_ROUTES_RAM_ADDR_WIDTH),
      .URAM_ROUTES_DATA_WIDTH (AXON_ROUTES_RAM_DATA_WIDTH),
      .URAM_ROUTES_ENTRY_WIDTH(AXON_ROUTES_RAM_ENTRY_WIDTH),
      .URAM_ROUTES_BYTE_WIDTH (AXON_ROUTES_RAM_BYTE_WIDTH),
      .URAM_ROUTES_INIT_FILE  (AXON_ROUTES_RAM_INIT_FILE),

      .URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH(AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH),
      .URAM_MEMORY_MAPPING_RAM_DATA_WIDTH(AXON_MEMORY_MAPPING_RAM_DATA_WIDTH),
      .URAM_MEMORY_MAPPING_RAM_INIT_FILE (AXON_MEMORY_MAPPING_RAM_INIT_FILE),

      .URAM_MEMORY_MAPPING_START_ADDR_WIDTH(URAM_MEMORY_MAPPING_START_ADDR_WIDTH),
      .URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH(URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH)

  ) inst_axon (

      // Control signals
      .clk_i(clk_i),
      .rst_i(rst_i),
      .enable_i(enable_i),

      // Connection to Spike Out FIFO
      .spike_out_fifo_read_enable_o(spike_out_fifo_read_enable_w),
      .spike_out_fifo_read_valid_i(spike_out_fifo_read_valid_w),
      .spike_out_fifo_data_i(spike_out_fifo_data_out_w),

      // Connection to Output Buffer
      .output_buffer_full_i(output_fifo_full_w),
      .output_buffer_write_enable_o(output_fifo_write_enable_w),
      .output_buffer_data_o(output_fifo_data_in_w),

      // Done logic
      .neuron_done_i(neuron_pipeline_done_w),
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



  // Tx pipeline
  Tx #(
      .CORE_ID(CORE_ID),
      .OUTPUT_BUFFER_WIDTH(OUTPUT_FIFO_DATA_WIDTH),
      .EVENT_WIDTH_INTERNAL(OUTPUT_INTERNAL_DATA_WIDTH),
      .EVENT_WIDTH_EXTERNAL(OUTPUT_EXTERNAL_DATA_WIDTH)

  ) inst_tx (

      // Control Signals
      .clk_i(clk_i),
      .rst_i(rst_i),
      .enable_i(enable_i),

      // Connection to Output Buffer
      .output_buffer_read_en_o(output_fifo_read_enable_w),
      .output_buffer_read_valid_i(output_fifo_read_valid_w),
      .output_buffer_data_in(output_fifo_data_out_w),

      // Connection to Rx
      .event_internal_valid_o(event_internal_valid_w),
      .event_internal_o(event_internal_w),

      // Connection to Router
      .event_external_valid_o(event_valid_o),
      .event_external_o(event_o),

      // Done Logic
      .axon_done_i(axon_done_w),
      .tx_done_o  (tx_done_w),

      // Router signals overload
      .router_buffers_full_i(router_buffers_full_i)
  );

  // ---------- ASSIGNMENTS ----------

  // Done logic
  assign fifos_in_done_w = ~input_fifo_write_enable_w & ~hot_neuron_fifo_write_enable_w & ~spike_out_fifo_write_enable_w & ~output_fifo_write_enable_w;
  assign fifos_out_done_w = ~input_fifo_read_valid_w & ~spike_out_fifo_read_valid_w & ~output_fifo_read_valid_w;
  assign fifos_done_w = fifos_out_done_w & fifos_in_done_w;

  // Reset done logic
  assign rst_done_o = rst_i & (!rst_mems_i[0] | qpmr_rst_done_r) & (!rst_mems_i[1] | neuron_wrapper_rst_done_w);

  // ---------- LOGIC ----------

  //
  // Done logic
  //
  always @(posedge clk_i) begin
    if (rst_i) begin
        fifos_done_r <= 2'b00;
        neuron_core_done_o <= 1'b0;
    end else begin
        fifos_done_r <= {fifos_done_r[0], fifos_done_w};
        neuron_core_done_o <= rx_done_w & synapse_done_w & neuron_pipeline_done_w & axon_done_w & tx_done_w & (&fifos_done_r) & fifos_done_w;
    end
  end

  //
  // Reset logic
  //

  // Multiplex the signals connected to the QPMR
  // to enable clearing it when resetting.
  always_comb begin
    if (rst_i & rst_mems_i[0]) begin
      mux_qpmr_port_a_we_w      = rst_qpmr_port_a_we_r;
      mux_qpmr_port_a_waddr_w   = rst_qpmr_port_a_waddr_r;
      mux_qpmr_port_a_data_in_w = {QUAD_PORT_MUX_RAM_DATA_WIDTH{1'b0}};
      mux_qpmr_port_b_we_w      = rst_qpmr_port_b_we_r;
      mux_qpmr_port_b_waddr_w   = rst_qpmr_port_b_waddr_r;
      mux_qpmr_port_b_data_in_w = {QUAD_PORT_MUX_RAM_DATA_WIDTH{1'b0}};
    end else begin
      mux_qpmr_port_a_we_w      = qpmr_port_a_we_w;
      mux_qpmr_port_a_waddr_w   = qpmr_port_a_waddr_w;
      mux_qpmr_port_a_data_in_w = qpmr_port_a_data_in_w;
      mux_qpmr_port_b_we_w      = qpmr_port_b_we_w;
      mux_qpmr_port_b_waddr_w   = qpmr_port_b_waddr_w;
      mux_qpmr_port_b_data_in_w = {qpmr_port_b_data_in_w, 1'b0};  // reset flag bit
    end
  end

  always @(posedge clk_i) begin
    if (rst_i & rst_mems_i[0]) begin
      if (rst_qpmr_port_a_waddr_r < ((1 << QUAD_PORT_MUX_RAM_ADDR_WIDTH) - 1)) begin
        rst_qpmr_port_a_we_r <= 1;
        rst_qpmr_port_b_we_r <= 1;
        qpmr_rst_done_r <= 0;

        if (rst_qpmr_port_a_we_r && rst_qpmr_port_b_we_r) begin // After writing started, begin incrementing
          rst_qpmr_port_a_waddr_r <= rst_qpmr_port_a_waddr_r + 1;
          rst_qpmr_port_b_waddr_r <= rst_qpmr_port_b_waddr_r + 1;
        end
      end else begin
        qpmr_rst_done_r <= 1;
        rst_qpmr_port_a_we_r <= 0;
        rst_qpmr_port_b_we_r <= 0;
      end
    end else begin
      qpmr_rst_done_r <= 0;
      rst_qpmr_port_a_we_r <= 0;
      rst_qpmr_port_b_we_r <= 0;
      rst_qpmr_port_a_waddr_r <= {QUAD_PORT_MUX_RAM_ADDR_WIDTH{1'b0}};
      rst_qpmr_port_b_waddr_r <= {QUAD_PORT_MUX_RAM_ADDR_WIDTH{1'b0}};
    end
  end

endmodule
