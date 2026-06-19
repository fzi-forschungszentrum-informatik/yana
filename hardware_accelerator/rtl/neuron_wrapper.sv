`timescale 1ns / 1ps

`include "global_params.vh"

module NeuronWrapper #(
  parameter CORE_ID_X   = 0,
  parameter CORE_ID_Y   = 0,
  parameter EMIT_SPIKES = 1,
  parameter LEAK_STATES = 1,
  parameter NEURON_STATE_INIT_FILE = "",
  parameter TIMESTEP_RAM_INIT_FILE = "",

  parameter VENDOR = VENDOR_G,
  parameter HOT_NEURON_FIFO_DATA_WIDTH = CORE_NEURON_ID_WIDTH_G,

  parameter WEIGHT_SUM_ADDR_WIDTH  = CORE_WEIGHT_SUM_RAM_ADDR_WIDTH_G,
  parameter WEIGHT_SUM_DATA_WIDTH  = CORE_WEIGHT_SUM_RAM_DATA_WIDTH_G - 1,

  parameter SPIKE_OUT_FIFO_DATA_WIDTH = CORE_NEURON_ID_WIDTH_G,

  parameter SPIKE_THRESHOLD_WIDTH = SPIKE_THRESHOLD_WIDTH_G,
  parameter TAU_MEM_INV_WIDTH     = TAU_MEM_INV_WIDTH_G,

  parameter NEURON_STATE_ADDR_WIDTH  = CORE_NEURON_ID_WIDTH_G,
  parameter NEURON_STATE_DATA_WIDTH  = NEURON_STATE_WIDTH_G,

  parameter TIMESTEP_WIDTH          = TIMESTEP_WIDTH_G,
  parameter TIMESTEP_RAM_ADDR_WIDTH = CORE_NEURON_ID_WIDTH_G,
  parameter TIMESTEP_RAM_DATA_WIDTH = TIMESTEP_WIDTH_G,

  parameter RAM_LEAK_ADDR_WIDTH    = RAM_LEAK_ADDR_WIDTH_G,
  parameter RAM_LEAK_DATA_WIDTH    = RAM_LEAK_DATA_WIDTH_G,
  parameter RAM_LEAK_INIT_MEM_FILE = RAM_LEAK_INIT_FILE_G,

  parameter CYCLES_RAISE_SLEEP = CYCLES_RAISE_SLEEP_G,

  parameter PKT_CTRL_RQ_WORD_WIDTHS_SUM = PKT_CMD_RQ_WORD_WIDTHS_SUM_G
) (     
  input  logic                      clk_i,
  input  logic                      rst_i,
  input  logic                      enable_i,
  input  logic                      init_i,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,
  input  logic                      core_came_out_of_reset_i,
  output logic                      done_o,

  output logic                                  hot_neuron_in_ready_o,
  input  logic                                  hot_neuron_in_valid_i,
  input  logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] hot_neuron_in_data_i,

  input  logic                                 spiking_neuron_out_ready_i,
  output logic                                 spiking_neuron_out_valid_o,
  output logic [SPIKE_OUT_FIFO_DATA_WIDTH-1:0] spiking_neuron_out_data_o,

  output logic                             weight_sum_ram_we_o,
  output logic [WEIGHT_SUM_ADDR_WIDTH-1:0] weight_sum_ram_waddr_o,
  output logic [WEIGHT_SUM_DATA_WIDTH-1:0] weight_sum_ram_data_o,
  output logic                             weight_sum_ram_re_o,
  output logic [WEIGHT_SUM_ADDR_WIDTH-1:0] weight_sum_ram_raddr_o,
  input  logic [WEIGHT_SUM_DATA_WIDTH-1:0] weight_sum_ram_data_i,

  input logic                             spike_threshold_reg_ce_i,
  input logic [SPIKE_THRESHOLD_WIDTH-1:0] spike_threshold_reg_data_i,

  input logic                         tau_mem_inv_reg_ce_i,
  input logic [TAU_MEM_INV_WIDTH-1:0] tau_mem_inv_reg_data_i,

  input logic                           leak_lut_we_i,
  input logic [RAM_LEAK_ADDR_WIDTH-1:0] leak_lut_addr_i,
  input logic [RAM_LEAK_DATA_WIDTH-1:0] leak_lut_data_i,

  output logic                                   forced_update_in_ready_o,
  input  logic                                   forced_update_in_valid_i,
  input  logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] forced_update_in_data_i,
  output logic                                   state_readout_in_ready_o,
  input  logic                                   state_readout_in_valid_i,
  input  logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] state_readout_in_data_i,
  output logic                                   state_reset_in_ready_o,
  input  logic                                   state_reset_in_valid_i,
  input  logic [PKT_CTRL_RQ_WORD_WIDTHS_SUM-1:0] state_reset_in_data_i,

  input  logic        state_readout_out_ready_i,
  output logic        state_readout_out_valid_o,
  output pkt_noc_ro_s state_readout_out_data_o
);

  //============================================================================
  // Declarations
  //============================================================================

  //============================================================================
  // Type Declarations
  //============================================================================

  typedef enum logic [2:0] {
    IDLE,
    INITIALIZING,
    PROCESSING,
    CTRL_FORCED_UPDATE,
    CTRL_STATE_READOUT,
    CTRL_STATE_RESET
  } master_state_e;

  typedef enum logic [1:0] {
    AWAKE,
    COUNTING_TO_SLEEP,
    SLEEPING
  } sleep_state_e;

  master_state_e state_q, state_d;
  sleep_state_e sleep_state_q, sleep_state_d;

  typedef struct packed {
    logic [NEURON_STATE_ADDR_WIDTH-1:0] end_addr;
    logic [NEURON_STATE_ADDR_WIDTH-1:0] start_addr;
    logic [TIMESTEP_WIDTH-1:0]          timestep;
  } ctrl_rq_data_s;

  //============================================================================
  // Signal Declarations
  //============================================================================
  
  logic state_ram_sleep;
  logic state_ram_awake;
  logic timestep_ram_sleep;
  logic timestep_ram_awake;
  logic all_memories_awake;
  logic [$clog2(CYCLES_RAISE_SLEEP+1)-1:0] sleep_counter_q, sleep_counter_d;

  logic                               ram_addr_gen_enable;
  logic                               ram_addr_gen_start;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] ram_addr_gen_start_addr;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] ram_addr_gen_end_addr;
  logic                               ram_addr_gen_valid;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] ram_addr_gen_addr;
  logic                               ram_addr_gen_idle;

  localparam STATE_PACKETIZER_INPUT_WIDTH = HOT_NEURON_FIFO_DATA_WIDTH + NEURON_STATE_DATA_WIDTH;
  logic                                    state_packetizer_done;
  logic                                    state_packetizer_input_ready; 
  logic                                    state_packetizer_input_valid;
  logic [STATE_PACKETIZER_INPUT_WIDTH-1:0] state_packetizer_input_data;
  logic                                    state_packetizer_output_ready;
  logic                                    state_packetizer_output_valid;
  pkt_noc_ro_s                             state_packetizer_output_data;

  logic                               addr_decoder_hit;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] addr_decoder_base_d;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] addr_decoder_base_q;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] addr_decoder_bound_d;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] addr_decoder_bound_q;

  logic                               state_ram_read_en_q;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] state_ram_read_addr_q;
  logic [NEURON_STATE_DATA_WIDTH-1:0] state_ram_data_out;
  logic                               state_ram_write_en_q;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] state_ram_write_addr_q;
  logic [NEURON_STATE_DATA_WIDTH-1:0] state_ram_data_in_q;
  
  logic                               timestep_ram_read_en_q;
  logic [TIMESTEP_RAM_ADDR_WIDTH-1:0] timestep_ram_read_addr_q;
  logic [TIMESTEP_RAM_DATA_WIDTH-1:0] timestep_ram_data_out;
  logic                               timestep_ram_write_en_q;
  logic [TIMESTEP_RAM_ADDR_WIDTH-1:0] timestep_ram_write_addr_q;
  logic [TIMESTEP_RAM_DATA_WIDTH-1:0] timestep_ram_data_in_q;

  logic [SPIKE_THRESHOLD_WIDTH-1:0] threshold_reg_data_out;
  logic [TAU_MEM_INV_WIDTH-1:0] tau_mem_inv_reg_data_out;

  logic                               inst_neuron_done;
  logic                               inst_neuron_in_valid_d;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] inst_neuron_in_id_d;
  logic [NEURON_STATE_DATA_WIDTH-1:0] inst_neuron_in_state_d;
  logic [TIMESTEP_RAM_DATA_WIDTH-1:0] inst_neuron_in_timesteps_d;
  logic [WEIGHT_SUM_DATA_WIDTH-1:0]   inst_neuron_in_weight_sum_d;
  logic                               inst_neuron_in_ready_d;
  logic                               inst_neuron_out_ready_d;
  logic                               inst_neuron_out_valid_d;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] inst_neuron_out_id_d;
  logic [NEURON_STATE_DATA_WIDTH-1:0] inst_neuron_out_state_d;
  logic                               inst_neuron_out_spike_d;
  
  logic data_pipeline_done_d;
  logic ctrl_pipeline_pending_now_d;
  logic ctrl_pipeline_pending_past_d;
  logic ctrl_pipeline_pending_d;
  logic ctrl_cmd_started_q, ctrl_cmd_started_d;
  logic pipelines_done_d;
  logic [TIMESTEP_WIDTH-1:0] last_reset_timestep_d;
  logic [TIMESTEP_WIDTH-1:0] last_reset_timestep_q;

  ctrl_rq_data_s forced_update_in_data;
  ctrl_rq_data_s state_readout_in_data;
  ctrl_rq_data_s state_reset_in_data;
  assign forced_update_in_data = ctrl_rq_data_s'(forced_update_in_data_i);
  assign state_readout_in_data = ctrl_rq_data_s'(state_readout_in_data_i);
  assign state_reset_in_data   = ctrl_rq_data_s'(state_reset_in_data_i);

  //============================================================================
  // Main Processing Pipeline
  //============================================================================

  //============================================================================
  // Input Skid Buffer
  //============================================================================

  logic input_skid_input_ready;
  logic input_skid_input_valid;
  logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] input_skid_input_data;
  logic input_skid_output_ready;
  logic input_skid_output_valid;
  logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] input_skid_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (HOT_NEURON_FIFO_DATA_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_input_skid_buffer (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (input_skid_input_ready),
    .input_valid (input_skid_input_valid),
    .input_data  (input_skid_input_data),
    .output_ready(input_skid_output_ready),
    .output_valid(input_skid_output_valid),
    .output_data (input_skid_output_data)
  );

  //============================================================================
  // Stage 1: Neuron State Lookup
  //============================================================================

  logic stage1_busy_q;
  logic stage1_output_ready, stage1_output_ready_q;
  logic stage1_output_valid, stage1_output_valid_q, stage1_output_valid_qq;
  logic [((HOT_NEURON_FIFO_DATA_WIDTH +
           WEIGHT_SUM_DATA_WIDTH +
           NEURON_STATE_DATA_WIDTH +
           TIMESTEP_RAM_DATA_WIDTH)
           -1):0] stage1_output_data, stage1_output_data_qq;
  
  logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] stage1_neuron_addr_q;

  assign input_skid_output_ready = stage1_output_ready && ~stage1_busy_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      stage1_busy_q          <= 1'b0;
      stage1_output_ready_q  <= 1'b0;
      stage1_output_valid_q  <= 1'b0;
      stage1_output_valid_qq <= 1'b0;
    end else begin
      stage1_output_ready_q  <= stage1_output_ready;
      if (!stage1_output_ready && stage1_output_ready_q) begin
        stage1_output_valid_q  <= 1'b0;
        stage1_output_valid_qq <= stage1_output_valid_q;
        stage1_output_data_qq  <= {stage1_neuron_addr_q,
                                   weight_sum_ram_data_i,
                                   state_ram_data_out,
                                   timestep_ram_data_out};
        stage1_busy_q <= 1'b1;
      end else if (stage1_output_ready && stage1_busy_q) begin
        stage1_busy_q <= 1'b0;
      end else if (stage1_output_ready) begin
        stage1_output_valid_q  <= input_skid_output_valid;
        stage1_output_valid_qq <= stage1_output_valid_q;
        stage1_neuron_addr_q   <= input_skid_output_data;
        stage1_output_data_qq  <= {stage1_neuron_addr_q,
                                   weight_sum_ram_data_i,
                                   state_ram_data_out,
                                   timestep_ram_data_out};
      end
    end
  end

  logic inter_skid1_input_ready;
  assign stage1_output_ready = (state_q == CTRL_STATE_READOUT) ? state_packetizer_input_ready :
                               /*default*/                       inter_skid1_input_ready;

  assign weight_sum_ram_re_o      = input_skid_output_valid;
  assign state_ram_read_en_q      = input_skid_output_valid;
  assign timestep_ram_read_en_q   = input_skid_output_valid;
  assign weight_sum_ram_raddr_o   = input_skid_output_data;
  assign state_ram_read_addr_q    = input_skid_output_data;
  assign timestep_ram_read_addr_q = input_skid_output_data;

  assign stage1_output_valid = (stage1_busy_q) ? stage1_output_valid_qq :
                                /*default*/      stage1_output_valid_q;
  assign stage1_output_data  = (stage1_busy_q) ? stage1_output_data_qq  : {stage1_neuron_addr_q,
                                                                          weight_sum_ram_data_i,
                                                                          state_ram_data_out,
                                                                          timestep_ram_data_out};

  localparam OFFSET_NEURON_STATE = TIMESTEP_RAM_DATA_WIDTH;
  localparam OFFSET_NEURON_ID    = TIMESTEP_RAM_DATA_WIDTH + NEURON_STATE_DATA_WIDTH + WEIGHT_SUM_DATA_WIDTH;
  assign state_packetizer_input_valid = (state_q == CTRL_STATE_READOUT) ? stage1_output_valid : 1'b0;
  assign state_packetizer_input_data  = (stage1_busy_q) ? {stage1_output_data_qq[OFFSET_NEURON_STATE +: NEURON_STATE_DATA_WIDTH],
                                                           stage1_output_data_qq[OFFSET_NEURON_ID    +: HOT_NEURON_FIFO_DATA_WIDTH]} :
                                        /*default*/       {state_ram_data_out, stage1_neuron_addr_q};

  //============================================================================
  // Inter-stage Skid Buffer 1
  //============================================================================

  logic inter_skid1_output_ready;
  logic inter_skid1_output_valid;
  logic [((HOT_NEURON_FIFO_DATA_WIDTH +
           WEIGHT_SUM_DATA_WIDTH +
           NEURON_STATE_DATA_WIDTH +
           TIMESTEP_RAM_DATA_WIDTH)
           -1):0] inter_skid1_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH(HOT_NEURON_FIFO_DATA_WIDTH +
                WEIGHT_SUM_DATA_WIDTH +
                NEURON_STATE_DATA_WIDTH +
                TIMESTEP_RAM_DATA_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_inter_skid_buffer_1 (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (inter_skid1_input_ready),
    .input_valid ((state_q == CTRL_STATE_READOUT) ? 1'b0 : stage1_output_valid),
    .input_data  (stage1_output_data),
    .output_ready(inter_skid1_output_ready),
    .output_valid(inter_skid1_output_valid),
    .output_data (inter_skid1_output_data)
  );

  logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] inter_skid1_output_data_neuron_id;
  logic [NEURON_STATE_DATA_WIDTH-1:0]    inter_skid1_output_data_neuron_state;
  logic [WEIGHT_SUM_DATA_WIDTH-1:0]      inter_skid1_output_data_weight_sum;
  logic [TIMESTEP_RAM_DATA_WIDTH-1:0]    inter_skid1_output_data_timestep;

  localparam OFFSET_TIMESTEP     = 0;
  localparam OFFSET_WEIGHT_SUM   = TIMESTEP_RAM_DATA_WIDTH + NEURON_STATE_DATA_WIDTH;
  
  assign inter_skid1_output_data_timestep     = inter_skid1_output_data[OFFSET_TIMESTEP     +: TIMESTEP_RAM_DATA_WIDTH];
  assign inter_skid1_output_data_neuron_state = inter_skid1_output_data[OFFSET_NEURON_STATE +: NEURON_STATE_DATA_WIDTH];
  assign inter_skid1_output_data_weight_sum   = inter_skid1_output_data[OFFSET_WEIGHT_SUM   +: WEIGHT_SUM_DATA_WIDTH];
  assign inter_skid1_output_data_neuron_id    = inter_skid1_output_data[OFFSET_NEURON_ID    +: HOT_NEURON_FIFO_DATA_WIDTH];

  //============================================================================
  // Stage 2: Feed LIF Neuron
  //============================================================================

  logic                               stage2_output_ready;
  logic                               stage2_output_valid;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] stage2_output_data;

  assign inter_skid1_output_ready    = inst_neuron_in_ready_d;
  assign inst_neuron_in_valid_d      = (core_came_out_of_reset_i)                ? 1'b0 :
                                       (timestep_i == last_reset_timestep_q - 1) ? inter_skid1_output_valid && ~addr_decoder_hit :
                                       /*default*/                                 inter_skid1_output_valid;
  assign inst_neuron_in_id_d         = inter_skid1_output_data_neuron_id;
  assign inst_neuron_in_state_d      = inter_skid1_output_data_neuron_state;
  assign inst_neuron_in_weight_sum_d = inter_skid1_output_data_weight_sum;
  assign inst_neuron_in_timesteps_d  = (ctrl_pipeline_pending_past_d) ? forced_update_in_data.timestep - inter_skid1_output_data_timestep :
                                       /*default*/                      timestep_i - inter_skid1_output_data_timestep;

  assign weight_sum_ram_we_o    = inter_skid1_output_valid;
  assign weight_sum_ram_waddr_o = inter_skid1_output_data_neuron_id;
  assign weight_sum_ram_data_o  = '0;

  assign inst_neuron_out_ready_d = stage2_output_ready;
  assign stage2_output_valid     = inst_neuron_out_valid_d && inst_neuron_out_spike_d;
  assign stage2_output_data      = inst_neuron_out_id_d;

  assign state_ram_write_en_q      = (state_q == CTRL_STATE_RESET) ? ram_addr_gen_valid : inst_neuron_out_valid_d;
  assign state_ram_write_addr_q    = (state_q == CTRL_STATE_RESET) ? ram_addr_gen_addr  : inst_neuron_out_id_d;
  assign state_ram_data_in_q       = (state_q == CTRL_STATE_RESET) ? '0                 : inst_neuron_out_state_d;
  assign timestep_ram_write_en_q   = (state_q == CTRL_STATE_RESET) ? ram_addr_gen_valid : inst_neuron_out_valid_d;
  assign timestep_ram_write_addr_q = (state_q == CTRL_STATE_RESET) ? ram_addr_gen_addr  : inst_neuron_out_id_d;
  assign timestep_ram_data_in_q    = (state_q == CTRL_STATE_RESET) ? '0                 : timestep_i;

  //============================================================================
  // Inter-stage Skid Buffer 2
  //============================================================================

  logic inter_skid2_output_ready;
  logic inter_skid2_output_valid;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] inter_skid2_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (NEURON_STATE_ADDR_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_inter_skid_buffer_2 (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (stage2_output_ready),
    .input_valid (stage2_output_valid),
    .input_data  (stage2_output_data),
    .output_ready(inter_skid2_output_ready),
    .output_valid(inter_skid2_output_valid),
    .output_data (inter_skid2_output_data)
  );

  //============================================================================
  // Module Instantiations
  //============================================================================

  //============================================================================
  // Neuron Instantiation
  //============================================================================

  LifNeuron #(
      .EMIT_SPIKES(EMIT_SPIKES),
      .LEAK_STATES(LEAK_STATES)
  ) u_lif_neuron (
      .clk_i (clk_i),
      .rst_i (rst_i),
      .done_o(inst_neuron_done),

      .in_ready_o     (inst_neuron_in_ready_d),
      .in_valid_i     (inst_neuron_in_valid_d),
      .in_id_i        (inst_neuron_in_id_d),
      .in_state_i     (inst_neuron_in_state_d),
      .in_weight_sum_i(inst_neuron_in_weight_sum_d),
      .in_timesteps_i (inst_neuron_in_timesteps_d),

      .out_ready_i(inst_neuron_out_ready_d),
      .out_valid_o(inst_neuron_out_valid_d),
      .out_id_o   (inst_neuron_out_id_d),
      .out_state_o(inst_neuron_out_state_d),
      .out_spike_o(inst_neuron_out_spike_d),

      .ram_leak_write_en_i(leak_lut_we_i),
      .ram_leak_addr_i    (leak_lut_addr_i),
      .ram_leak_data_i    (leak_lut_data_i),

      .spike_threshold_i(threshold_reg_data_out),
      .tau_mem_inv_i    (tau_mem_inv_reg_data_out)
  );

  //============================================================================
  // Memory Instantiations
  //============================================================================

  DualPortRamSimple #(
      .VENDOR       (VENDOR),
      .DATA_WIDTH   (NEURON_STATE_DATA_WIDTH),
      .ADDR_WIDTH   (NEURON_STATE_ADDR_WIDTH),
      .INIT_MEM_FILE(NEURON_STATE_INIT_FILE)
  ) u_state_ram (
      .clk_i       (clk_i),
      .read_en_i   (state_ram_read_en_q),
      .read_addr_i (state_ram_read_addr_q),
      .data_o      (state_ram_data_out),
      .write_en_i  (state_ram_write_en_q),
      .write_addr_i(state_ram_write_addr_q),
      .data_i      (state_ram_data_in_q),
      .sleep_i     (state_ram_sleep),
      .awake_o     (state_ram_awake)
  );

  DualPortRamSimple #(
      .VENDOR       (VENDOR),
      .DATA_WIDTH   (TIMESTEP_RAM_DATA_WIDTH),
      .ADDR_WIDTH   (TIMESTEP_RAM_ADDR_WIDTH),
      .INIT_MEM_FILE(TIMESTEP_RAM_INIT_FILE)
  ) u_timestep_ram (
      .clk_i       (clk_i),
      .read_en_i   (timestep_ram_read_en_q),
      .read_addr_i (timestep_ram_read_addr_q),
      .data_o      (timestep_ram_data_out),
      .write_en_i  (timestep_ram_write_en_q),
      .write_addr_i(timestep_ram_write_addr_q),
      .data_i      (timestep_ram_data_in_q),
      .sleep_i     (timestep_ram_sleep),
      .awake_o     (timestep_ram_awake)
  );

  Register #(
      .WORD_WIDTH(SPIKE_THRESHOLD_WIDTH_G),
      .RESET_VALUE('1)
  ) u_neuron_threshold_register (
      .clock       (clk_i),
      .clock_enable(spike_threshold_reg_ce_i),
      .clear       (/* ignored */),
      .data_in     (spike_threshold_reg_data_i),
      .data_out    (threshold_reg_data_out)
  );

  Register #(
      .WORD_WIDTH(TAU_MEM_INV_WIDTH),
      .RESET_VALUE('1)
  ) u_neuron_tau_mem_inv_register (
      .clock       (clk_i),
      .clock_enable(tau_mem_inv_reg_ce_i),
      .clear       (/* ignored */),
      .data_in     (tau_mem_inv_reg_data_i),
      .data_out    (tau_mem_inv_reg_data_out)
  );

  //============================================================================
  // State Readout Module Instantiations
  //============================================================================

  AddressGenerator #(
    .ADDR_WIDTH (NEURON_STATE_ADDR_WIDTH)
  ) u_ram_addr_gen (
    .clk_i       (clk_i),
    .rst_i       (rst_i),
    .enable_i    (ram_addr_gen_enable),
    .start_i     (ram_addr_gen_start),
    .start_addr_i(ram_addr_gen_start_addr),
    .end_addr_i  (ram_addr_gen_end_addr),
    .valid_o     (ram_addr_gen_valid),
    .addr_o      (ram_addr_gen_addr),
    .idle_o      (ram_addr_gen_idle)
  );

  NeuronWrapperStatePacketizer #(
    .SOURCE_CORE_ID_X(CORE_ID_X),
    .SOURCE_CORE_ID_Y(CORE_ID_Y)
  ) u_state_packetizer (
    .clk_i                   (clk_i),
    .rst_i                   (rst_i),
    .done_o                  (state_packetizer_done),
    .state_input_ready_o     (state_packetizer_input_ready),
    .state_input_valid_i     (state_packetizer_input_valid),
    .state_input_data_i      (state_packetizer_input_data),
    .state_packet_out_ready_i(state_packetizer_output_ready),
    .state_packet_out_valid_o(state_packetizer_output_valid),
    .state_packet_out_data_o (state_packetizer_output_data)
  );

  //============================================================================
  // State Reset Module Instantiations
  //============================================================================

  Address_Decoder_Behavioural #(
    .ADDR_WIDTH (NEURON_STATE_ADDR_WIDTH)
  ) u_addr_decoder (
    .base_addr (addr_decoder_base_q),
    .bound_addr(addr_decoder_bound_q),
    .addr      (inter_skid1_output_data_neuron_id),
    .hit       (addr_decoder_hit)
  );

  //============================================================================
  // FSMs
  //============================================================================
  
  //============================================================================
  // MASTER FSM
  //============================================================================

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q               <= IDLE;
      ctrl_cmd_started_q    <= 1'b0;
      last_reset_timestep_q <= '0;
      addr_decoder_base_q   <= '0;    
      addr_decoder_bound_q  <= '0;    
    end else begin
      state_q               <= state_d;
      ctrl_cmd_started_q    <= ctrl_cmd_started_d;
      last_reset_timestep_q <= last_reset_timestep_d;
      addr_decoder_base_q   <= addr_decoder_base_d;
      addr_decoder_bound_q  <= addr_decoder_bound_d;
    end
  end

  always_comb begin
    state_d                  = state_q;
    ram_addr_gen_enable      = 1'b0;
    ram_addr_gen_start       = 1'b0;
    ram_addr_gen_start_addr  = '0;
    ram_addr_gen_end_addr    = '0;
    forced_update_in_ready_o = 1'b0;
    state_readout_in_ready_o = 1'b0;
    state_reset_in_ready_o   = 1'b0;
    last_reset_timestep_d    = last_reset_timestep_q;
    addr_decoder_base_d      = addr_decoder_base_q;
    addr_decoder_bound_d     = addr_decoder_bound_q;
    ctrl_cmd_started_d       = ctrl_cmd_started_q;

    case (state_q)
      IDLE: begin
        if (init_i) begin
          state_d = INITIALIZING;
        end else if (enable_i && all_memories_awake) begin
          if (ctrl_pipeline_pending_past_d) begin
            state_d = CTRL_FORCED_UPDATE;
          end else if (!data_pipeline_done_d) begin
            state_d = PROCESSING;
          end else if (ctrl_pipeline_pending_now_d) begin
            state_d = CTRL_FORCED_UPDATE;
          end
        end
      end

      PROCESSING: begin
        if (data_pipeline_done_d) begin
          state_d = IDLE;
        end
      end

      CTRL_FORCED_UPDATE: begin
        ram_addr_gen_enable = 1'b1;
        if (!ctrl_cmd_started_q &&
            forced_update_in_valid_i && forced_update_in_data.timestep <= timestep_i) begin
          ram_addr_gen_start       = 1'b1;
          ram_addr_gen_start_addr  = forced_update_in_data.start_addr;
          ram_addr_gen_end_addr    = forced_update_in_data.end_addr;
          forced_update_in_ready_o = 1'b1;
          ctrl_cmd_started_d       = 1'b1;
        end else if (ram_addr_gen_idle && data_pipeline_done_d) begin
          ram_addr_gen_enable      = 1'b0;
          state_d                  = CTRL_STATE_READOUT;
          ctrl_cmd_started_d       = 1'b0;
        end
      end

      CTRL_STATE_READOUT: begin
        ram_addr_gen_enable = 1'b1;
        if (!ctrl_cmd_started_q &&
            state_readout_in_valid_i && state_readout_in_data.timestep <= timestep_i) begin
          ram_addr_gen_start       = 1'b1;
          ram_addr_gen_start_addr  = state_readout_in_data.start_addr;
          ram_addr_gen_end_addr    = state_readout_in_data.end_addr;
          state_readout_in_ready_o = 1'b1;
          ctrl_cmd_started_d       = 1'b1;
        end else if (!input_skid_output_ready) begin
          ram_addr_gen_enable = 1'b0;
        end else if (ram_addr_gen_idle && data_pipeline_done_d && state_packetizer_done) begin
          ram_addr_gen_enable      = 1'b0;
          state_d                  = CTRL_STATE_RESET;
          ctrl_cmd_started_d       = 1'b0;
        end
      end

      CTRL_STATE_RESET: begin
        ram_addr_gen_enable = 1'b1;
        if (!ctrl_cmd_started_q &&
            state_reset_in_valid_i && state_reset_in_data.timestep <= timestep_i) begin
          ram_addr_gen_start      = 1'b1;
          ram_addr_gen_start_addr = state_reset_in_data.start_addr;
          ram_addr_gen_end_addr   = state_reset_in_data.end_addr;
          state_reset_in_ready_o  = 1'b1;
          ctrl_cmd_started_d      = 1'b1;
          last_reset_timestep_d   = state_reset_in_data.timestep;
          addr_decoder_base_d     = state_reset_in_data.start_addr;
          addr_decoder_bound_d    = state_reset_in_data.end_addr;
        end else if (ram_addr_gen_idle) begin
          ram_addr_gen_enable    = 1'b0;
          state_d                = IDLE;
          ctrl_cmd_started_d     = 1'b0;
        end
      end

      INITIALIZING: begin
        if (!init_i) begin
          state_d = IDLE;
        end
      end

      default: begin
        state_d = IDLE;
      end
    endcase
  end

  //============================================================================
  // MEMORY SLEEP FSM
  //============================================================================

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      sleep_counter_q <= '0;
      sleep_state_q <= AWAKE;
    end else begin
      sleep_state_q <= sleep_state_d;
      sleep_counter_q <= sleep_counter_d;
    end
  end

  always_comb begin
    sleep_state_d = sleep_state_q;
    sleep_counter_d = sleep_counter_q;
    state_ram_sleep = 1'b0;
    timestep_ram_sleep = 1'b0;

    if (state_q == INITIALIZING) begin
      sleep_counter_d = '0;
      sleep_state_d = AWAKE;
    end else begin
      case (sleep_state_q)
        AWAKE: begin
          if (pipelines_done_d) begin
            sleep_counter_d = CYCLES_RAISE_SLEEP;
            sleep_state_d = COUNTING_TO_SLEEP;
          end
        end
        COUNTING_TO_SLEEP: begin
          if (!pipelines_done_d) begin
            sleep_counter_d = '0;
            sleep_state_d = AWAKE;
          end else if (sleep_counter_q == 0) begin
            state_ram_sleep = 1'b1;
            timestep_ram_sleep = 1'b1;
            sleep_state_d = SLEEPING;
          end else begin
            sleep_counter_d = sleep_counter_q - 1;
          end
        end
        SLEEPING: begin
          state_ram_sleep = 1'b1;
          timestep_ram_sleep = 1'b1;
          if (!pipelines_done_d) begin
            sleep_counter_d = '0;
            sleep_state_d = AWAKE;
          end
        end
        default: begin
          sleep_counter_d = '0;
          sleep_state_d = AWAKE;
        end
      endcase
    end
  end

  //============================================================================
  // Signal Assignments
  //============================================================================
  
  assign all_memories_awake = state_ram_awake && timestep_ram_awake;
  
  assign data_pipeline_done_d         = ~hot_neuron_in_valid_i &&
                                        ~input_skid_output_valid &&
                                        ~stage1_output_valid &&
                                        ~inter_skid1_output_valid &&
                                        ~stage2_output_valid &&
                                        ~inter_skid2_output_valid &&
                                        inst_neuron_done;
  assign ctrl_pipeline_pending_past_d = ((state_reset_in_data.timestep   < timestep_i) && state_reset_in_valid_i)   ||
                                        ((forced_update_in_data.timestep < timestep_i) && forced_update_in_valid_i) ||
                                        ((state_readout_in_data.timestep < timestep_i) && state_readout_in_valid_i);

  assign ctrl_pipeline_pending_now_d  = (state_reset_in_data.timestep   == timestep_i && state_reset_in_valid_i)   ||
                                        (forced_update_in_data.timestep == timestep_i && forced_update_in_valid_i) ||
                                        (state_readout_in_data.timestep == timestep_i && state_readout_in_valid_i);
  assign ctrl_pipeline_pending_d      = ctrl_pipeline_pending_now_d || ctrl_pipeline_pending_past_d;
  assign pipelines_done_d             = (state_q == IDLE) &&
                                        data_pipeline_done_d &&
                                        ~ctrl_pipeline_pending_d;
  assign done_o                       = pipelines_done_d ||
                                        (state_q == INITIALIZING);

  assign hot_neuron_in_ready_o  = (state_q == PROCESSING)         ? input_skid_input_ready : 1'b0;
  assign input_skid_input_valid = (state_q == CTRL_FORCED_UPDATE) ? ram_addr_gen_valid    :
                                  (state_q == CTRL_STATE_READOUT) ? ram_addr_gen_valid    :
                                  (state_q == PROCESSING)         ? hot_neuron_in_valid_i :
                                  /*default*/                       1'b0;
  assign input_skid_input_data  = (state_q == CTRL_FORCED_UPDATE) ? ram_addr_gen_addr :
                                  (state_q == CTRL_STATE_READOUT) ? ram_addr_gen_addr :
                                  /*default*/                       hot_neuron_in_data_i;
  assign inter_skid2_output_ready   = (state_q == PROCESSING) && spiking_neuron_out_ready_i;
  assign spiking_neuron_out_valid_o = (state_q == PROCESSING) && inter_skid2_output_valid;
  assign spiking_neuron_out_data_o  = inter_skid2_output_data;
  assign state_packetizer_output_ready = state_readout_out_ready_i;
  assign state_readout_out_valid_o     = state_packetizer_output_valid;
  assign state_readout_out_data_o      = state_packetizer_output_data;

endmodule