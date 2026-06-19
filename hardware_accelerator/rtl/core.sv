`timescale 1ns / 1ps

`include "global_params.vh"

module Core #(
  parameter CORE_TYPE = "FULL",
  parameter CORE_ID_X = 0,
  parameter CORE_ID_Y = 0,

  parameter VENDOR                         = VENDOR_G,
  parameter TIMESTEP_WIDTH                 = TIMESTEP_WIDTH_G,
  parameter CORE_FEEDBACK_DATA_WIDTH       = CORE_EVENT_WIDTH_G,
  parameter CORE_NEURON_ID_WIDTH           = CORE_NEURON_ID_WIDTH_G,
  parameter CORE_WEIGHT_ID_WIDTH           = CORE_WEIGHT_ID_WIDTH_G,
  parameter CORE_INPUT_WIDTH               = CORE_INPUT_WIDTH_G,
  parameter CORE_ROUTE_WIDTH               = CORE_ROUTE_WIDTH_G,
  parameter CORE_FIFOS_DEPTH               = CORE_FIFOS_DEPTH_G,
  parameter CORE_WEIGHT_SUM_RAM_ADDR_WIDTH = CORE_WEIGHT_SUM_RAM_ADDR_WIDTH_G,
  parameter CORE_WEIGHT_SUM_RAM_DATA_WIDTH = CORE_WEIGHT_SUM_RAM_DATA_WIDTH_G,
  parameter CORE_WEIGHT_RAM_ADDR_WIDTH     = CORE_WEIGHT_RAM_ADDR_WIDTH_G,
  parameter CORE_WEIGHT_RAM_DATA_WIDTH     = CORE_WEIGHT_RAM_DATA_WIDTH_G,
  parameter CORE_MAPPING_RAM_DATA_WIDTH    = CORE_MAPPING_RAM_DATA_WIDTH_G,
  parameter CORE_ROUTES_RAM_ADDR_WIDTH     = CORE_ROUTES_RAM_ADDR_WIDTH_G,
  parameter CORE_ROUTES_RAM_DATA_WIDTH     = CORE_ROUTES_RAM_DATA_WIDTH_G,
  parameter CORE_SPIKE_THRESHOLD_WIDTH     = SPIKE_THRESHOLD_WIDTH_G,
  parameter CORE_TAU_MEM_INV_WIDTH         = TAU_MEM_INV_WIDTH_G,
  parameter PKT_CMD_RQ_WORD_WIDTHS_SUM     = PKT_CMD_RQ_WORD_WIDTHS_SUM_G,
  parameter CYCLES_RAISE_SLEEP             = CYCLES_RAISE_SLEEP_G,
  parameter MESH_PACKET_ADDR_WIDTH         = MESH_PACKET_ADDR_WIDTH_G,
  parameter MESH_PACKET_DX_WIDTH           = MESH_PACKET_DX_WIDTH_G,
  parameter MESH_PACKET_DY_WIDTH           = MESH_PACKET_DY_WIDTH_G,
  parameter MESH_PACKET_DATA_WIDTH_X       = MESH_PACKET_DATA_WIDTH_X_G
) (
  input  logic                      clk_i,
  input  logic                      rst_i,
  input  logic                      enable_i,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,
  input  logic                      init_i,
  output logic                      core_done_o,
  output logic                      core_idle_o,

  output logic                 packet_in_ready_o,
  input  logic                 packet_in_valid_i,
  input  pkt_core_event_data_s packet_in_data_i,

  input  logic                packet_out_ready_i,
  output logic                packet_out_valid_o,
  output pkt_noc_event_data_s packet_out_data_o
);

  //============================================================================
  // Signal Declarations
  //============================================================================

  logic core_done_d;
  logic core_idle_d;

  logic rx_done;

  logic                                rx_merge_out_ready;
  logic                                rx_merge_out_valid;
  logic [CORE_FEEDBACK_DATA_WIDTH-1:0] rx_merge_out_data;

  logic                            spiking_neurons_fifo_output_ready;
  logic                            spiking_neurons_fifo_output_valid;
  logic [CORE_NEURON_ID_WIDTH-1:0] spiking_neurons_fifo_output_data;
  logic                            spiking_neurons_fifo_empty;

  logic init_d;

  //============================================================================
  // Conditional Signal Declarations based on CORE_TYPE
  //============================================================================

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_synapse_neuron_signals
      logic synapse_done;
      logic neuron_done;
      logic                                syn_input_fifo_out_ready;
      logic                                syn_input_fifo_out_valid;
      logic [CORE_FEEDBACK_DATA_WIDTH-1:0] syn_input_fifo_out_data;
      logic                                syn_input_fifo_empty;
      logic                            hot_neurons_fifo_input_ready;
      logic                            hot_neurons_fifo_input_valid;
      logic [CORE_NEURON_ID_WIDTH-1:0] hot_neurons_fifo_input_data;
      logic                            hot_neurons_fifo_output_ready;
      logic                            hot_neurons_fifo_output_valid;
      logic [CORE_NEURON_ID_WIDTH-1:0] hot_neurons_fifo_output_data;
      logic                            hot_neurons_fifo_empty;
      logic                            spiking_neurons_fifo_input_ready;
      logic                            spiking_neurons_fifo_input_valid;
      logic [CORE_NEURON_ID_WIDTH-1:0] spiking_neurons_fifo_input_data;
      logic        state_readout_out_ready;
      logic        state_readout_out_valid;
      pkt_noc_ro_s state_readout_out_data;
      logic                                      weight_sum_port_a_we;
      logic [CORE_WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_port_a_waddr;
      logic [CORE_WEIGHT_SUM_RAM_DATA_WIDTH-1:0] weight_sum_port_a_data_in;
      logic                                      weight_sum_port_a_re;
      logic [CORE_WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_port_a_raddr;
      logic [CORE_WEIGHT_SUM_RAM_DATA_WIDTH-1:0] weight_sum_port_a_data_out;
      logic                                      weight_sum_port_b_we;
      logic [CORE_WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_port_b_waddr;
      logic [CORE_WEIGHT_SUM_RAM_DATA_WIDTH-2:0] weight_sum_port_b_data_in;
      logic                                      weight_sum_port_b_re;
      logic [CORE_WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_port_b_raddr;
      logic [CORE_WEIGHT_SUM_RAM_DATA_WIDTH-1:0] weight_sum_port_b_data_out;
      logic                                    weight_sum_sleep;
      logic                                    weight_sum_awake;
      logic [$clog2(CYCLES_RAISE_SLEEP+1)-1:0] sleep_counter_q, sleep_counter_d;
    end
    if (CORE_TYPE == "FULL") begin : gen_full_core_signals
      logic tx_done;
      logic                                feedback_fifo_output_ready;
      logic                                feedback_fifo_output_valid;
      logic [CORE_FEEDBACK_DATA_WIDTH-1:0] feedback_fifo_output_data;
      logic                                feedback_fifo_empty;
      logic [1:0]                          output_branch_ready;
      logic [1:0]                          output_branch_valid;
      logic [1:0] [CORE_ROUTE_WIDTH-1:0]   output_branch_data;
      logic                                event_internal_ready;
      logic                                event_internal_valid;
      logic [CORE_FEEDBACK_DATA_WIDTH-1:0] event_internal_data;
    end
    if (CORE_TYPE == "FULL" || CORE_TYPE == "INPUT") begin : gen_axon_signals
      logic axon_done;
      logic                        spike_output_fifo_input_ready;
      logic                        spike_output_fifo_input_valid;
      logic [CORE_ROUTE_WIDTH-1:0] spike_output_fifo_input_data;
      logic                        spike_output_fifo_output_ready;
      logic                        spike_output_fifo_output_valid;
      logic [CORE_ROUTE_WIDTH-1:0] spike_output_fifo_output_data;
      logic                        spike_output_fifo_empty;
    end
    if (CORE_TYPE == "INPUT") begin : gen_input_core_signals
      logic tx_done;
    end
  endgenerate

  //============================================================================
  // FSM State Declarations (conditional based on CORE_TYPE)
  //============================================================================

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_sleep_fsm
      typedef enum logic [1:0] {
        AWAKE,
        COUNTING_TO_SLEEP,
        SLEEPING
      } sleep_state_e;

      sleep_state_e sleep_state_q, sleep_state_d;

      always_ff @(posedge clk_i) begin
        if (rst_i) begin
          sleep_state_q <= AWAKE;
          gen_synapse_neuron_signals.sleep_counter_q <= '0;
        end else begin
          sleep_state_q <= sleep_state_d;
          gen_synapse_neuron_signals.sleep_counter_q <= gen_synapse_neuron_signals.sleep_counter_d;
        end
      end

      always_comb begin
        sleep_state_d = sleep_state_q;
        gen_synapse_neuron_signals.sleep_counter_d = gen_synapse_neuron_signals.sleep_counter_q;
        gen_synapse_neuron_signals.weight_sum_sleep = 1'b0;

        case (sleep_state_q)
          AWAKE: begin
            if (core_done_d) begin
              gen_synapse_neuron_signals.sleep_counter_d = CYCLES_RAISE_SLEEP;
              sleep_state_d = COUNTING_TO_SLEEP;
            end
          end
          COUNTING_TO_SLEEP: begin
            if (!core_done_d) begin
              gen_synapse_neuron_signals.sleep_counter_d = '0;
              sleep_state_d = AWAKE;
            end else if (gen_synapse_neuron_signals.sleep_counter_q == 0) begin
              gen_synapse_neuron_signals.weight_sum_sleep = 1'b1;
              sleep_state_d = SLEEPING;
            end else begin
              gen_synapse_neuron_signals.sleep_counter_d = gen_synapse_neuron_signals.sleep_counter_q - 1;
            end
          end
          SLEEPING: begin
            gen_synapse_neuron_signals.weight_sum_sleep = 1'b1;
            if (!core_done_d) begin
              gen_synapse_neuron_signals.sleep_counter_d = '0;
              sleep_state_d = AWAKE;
            end
          end
          default: begin
            gen_synapse_neuron_signals.sleep_counter_d = '0;
            sleep_state_d = AWAKE;
          end
        endcase
      end
    end
  endgenerate

  //============================================================================
  // Memories
  //============================================================================

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_weight_sum_ram
      DualPortRamSimplePingPong #(
        .VENDOR       (VENDOR),
        .RAM_ADDR_BITS(CORE_WEIGHT_SUM_RAM_ADDR_WIDTH),
        .RAM_WIDTH    (CORE_WEIGHT_SUM_RAM_DATA_WIDTH),
        .INIT_MEM_FILE("")
      ) u_weight_sum_ram (
        .clk_i          (clk_i),
        .select_i       (gen_ts_det_toggle.ts_det_toggle_d),
        .port_a_we_i    (gen_synapse_neuron_signals.weight_sum_port_a_we),
        .port_a_waddr_i (gen_synapse_neuron_signals.weight_sum_port_a_waddr),
        .port_a_data_in (gen_synapse_neuron_signals.weight_sum_port_a_data_in),
        .port_a_re_i    (gen_synapse_neuron_signals.weight_sum_port_a_re),
        .port_a_raddr_i (gen_synapse_neuron_signals.weight_sum_port_a_raddr),
        .port_a_data_out(gen_synapse_neuron_signals.weight_sum_port_a_data_out),
        .port_b_we_i    (gen_synapse_neuron_signals.weight_sum_port_b_we),
        .port_b_waddr_i (gen_synapse_neuron_signals.weight_sum_port_b_waddr),
        .port_b_data_in ({gen_synapse_neuron_signals.weight_sum_port_b_data_in, 1'b0}),
        .port_b_re_i    (gen_synapse_neuron_signals.weight_sum_port_b_re),
        .port_b_raddr_i (gen_synapse_neuron_signals.weight_sum_port_b_raddr),
        .port_b_data_out(gen_synapse_neuron_signals.weight_sum_port_b_data_out),
        .sleep_i        (gen_synapse_neuron_signals.weight_sum_sleep),
        .awake_o        (gen_synapse_neuron_signals.weight_sum_awake)
      );
    end
  endgenerate

  //============================================================================
  // FIFOs
  //============================================================================

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_syn_input_fifo
      Pipeline_FIFO_Buffer #(
        .WORD_WIDTH     (CORE_FEEDBACK_DATA_WIDTH),
        .DEPTH          (CORE_FIFOS_DEPTH),
        .RAMSTYLE       ("mixed"),
        .CIRCULAR_BUFFER(0)
      ) u_syn_input_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (rx_merge_out_ready),
        .input_valid (rx_merge_out_valid),
        .input_data  (rx_merge_out_data),
        .output_ready(gen_synapse_neuron_signals.syn_input_fifo_out_ready),
        .output_valid(gen_synapse_neuron_signals.syn_input_fifo_out_valid),
        .output_data (gen_synapse_neuron_signals.syn_input_fifo_out_data),
        .empty       (gen_synapse_neuron_signals.syn_input_fifo_empty)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_hot_neurons_fifo
      Pipeline_FIFO_Ping_Pong #(
        .WORD_WIDTH     (CORE_NEURON_ID_WIDTH),
        .DEPTH          (1024),
        .RAMSTYLE       ("block"),
        .CIRCULAR_BUFFER(0)
      ) u_hot_neurons_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .selector    (gen_ts_det_toggle.ts_det_toggle_d),
        .input_ready (gen_synapse_neuron_signals.hot_neurons_fifo_input_ready),
        .input_valid (gen_synapse_neuron_signals.hot_neurons_fifo_input_valid),
        .input_data  (gen_synapse_neuron_signals.hot_neurons_fifo_input_data),
        .output_ready(gen_synapse_neuron_signals.hot_neurons_fifo_output_ready),
        .output_valid(gen_synapse_neuron_signals.hot_neurons_fifo_output_valid),
        .output_data (gen_synapse_neuron_signals.hot_neurons_fifo_output_data),
        .empty       (gen_synapse_neuron_signals.hot_neurons_fifo_empty)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL") begin : gen_spiking_neurons_fifo
      Pipeline_FIFO_Buffer #(
        .WORD_WIDTH     (CORE_NEURON_ID_WIDTH),
        .DEPTH          (CORE_FIFOS_DEPTH),
        .RAMSTYLE       ("mixed"),
        .CIRCULAR_BUFFER(0)
      ) u_spiking_neurons_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (gen_synapse_neuron_signals.spiking_neurons_fifo_input_ready),
        .input_valid (gen_synapse_neuron_signals.spiking_neurons_fifo_input_valid),
        .input_data  (gen_synapse_neuron_signals.spiking_neurons_fifo_input_data),
        .output_ready(spiking_neurons_fifo_output_ready),
        .output_valid(spiking_neurons_fifo_output_valid),
        .output_data (spiking_neurons_fifo_output_data),
        .empty       (spiking_neurons_fifo_empty)
      );
    end else if (CORE_TYPE == "INPUT") begin : gen_input_core_spiking_fifo
      Pipeline_FIFO_Buffer #(
        .WORD_WIDTH     (CORE_NEURON_ID_WIDTH),
        .DEPTH          (CORE_FIFOS_DEPTH),
        .RAMSTYLE       ("mixed"),
        .CIRCULAR_BUFFER(0)
      ) u_spiking_neurons_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (rx_merge_out_ready),
        .input_valid (rx_merge_out_valid),
        .input_data  (rx_merge_out_data[CORE_NEURON_ID_WIDTH-1:0]),
        .output_ready(spiking_neurons_fifo_output_ready),
        .output_valid(spiking_neurons_fifo_output_valid),
        .output_data (spiking_neurons_fifo_output_data),
        .empty       (spiking_neurons_fifo_empty)
      );
    end else begin : gen_no_spiking_neurons_fifo
      assign spiking_neurons_fifo_output_valid = 1'b0;
      assign spiking_neurons_fifo_output_data = '0;
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL") begin : gen_feedback_fifo
      Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(CORE_FEEDBACK_DATA_WIDTH),
        .DEPTH     (CORE_FIFOS_DEPTH),
        .RAMSTYLE  ("mixed"),
        .CIRCULAR_BUFFER(0)
      ) u_feedback_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (gen_full_core_signals.event_internal_ready),
        .input_valid (gen_full_core_signals.event_internal_valid),
        .input_data  (gen_full_core_signals.event_internal_data),
        .output_ready(gen_full_core_signals.feedback_fifo_output_ready),
        .output_valid(gen_full_core_signals.feedback_fifo_output_valid),
        .output_data (gen_full_core_signals.feedback_fifo_output_data),
        .empty       (gen_full_core_signals.feedback_fifo_empty)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "INPUT") begin : gen_spike_output_fifo
      Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(CORE_ROUTE_WIDTH),
        .DEPTH     (CORE_FIFOS_DEPTH),
        .RAMSTYLE  ("mixed"),
        .CIRCULAR_BUFFER(0)
      ) u_spike_output_fifo (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready (gen_axon_signals.spike_output_fifo_input_ready),
        .input_valid (gen_axon_signals.spike_output_fifo_input_valid),
        .input_data  (gen_axon_signals.spike_output_fifo_input_data),
        .output_ready(gen_axon_signals.spike_output_fifo_output_ready),
        .output_valid(gen_axon_signals.spike_output_fifo_output_valid),
        .output_data (gen_axon_signals.spike_output_fifo_output_data),
        .empty       (gen_axon_signals.spike_output_fifo_empty)
      );
    end
  endgenerate

  //============================================================================
  // Pipeline Modules
  //============================================================================

  logic [2:0]                        rx_branch_out_ready;
  logic [2:0]                        rx_branch_out_valid;
  logic [2:0] [CORE_INPUT_WIDTH-1:0] rx_branch_out_data;
  Pipeline_Branch_One_Hot #(
    .WORD_WIDTH    (CORE_INPUT_WIDTH),
    .OUTPUT_COUNT  (3),
    .IMPLEMENTATION("AND")
  ) u_rx_branch (
    .selector    ((init_d) ? 3'b100 : (packet_in_data_i.ctrl_flag) ? 3'b010 : 3'b001),
    .input_ready (packet_in_ready_o),
    .input_valid (packet_in_valid_i),
    .input_data  (packet_in_data_i),
    .output_ready(rx_branch_out_ready),
    .output_valid(rx_branch_out_valid),
    .output_data ({rx_branch_out_data})
  );

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_cmd_preprocess
      localparam RX_BRANCH_TO_CMD_PROC_WIDTH = CORE_INPUT_WIDTH - 1;
      logic [RX_BRANCH_TO_CMD_PROC_WIDTH-1:0] rx_branch_to_cmd_proc;
      assign rx_branch_to_cmd_proc = rx_branch_out_data[1][1+:RX_BRANCH_TO_CMD_PROC_WIDTH];

      logic                                  cmd_proc_done_d;
      logic                                  cmd_proc_out_state_reset_ready;
      logic                                  cmd_proc_out_state_reset_valid;
      logic [PKT_CMD_RQ_WORD_WIDTHS_SUM-1:0] cmd_proc_out_state_reset_data;
      logic                                  cmd_proc_out_forced_update_ready;
      logic                                  cmd_proc_out_forced_update_valid;
      logic [PKT_CMD_RQ_WORD_WIDTHS_SUM-1:0] cmd_proc_out_forced_update_data;
      logic                                  cmd_proc_out_state_read_ready;
      logic                                  cmd_proc_out_state_read_valid;
      logic [PKT_CMD_RQ_WORD_WIDTHS_SUM-1:0] cmd_proc_out_state_read_data;
      CommandPreprocessor u_command_preprocessor (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i),
        .timestep_i               (timestep_i),
        .done_o                   (cmd_proc_done_d),
        .packet_in_ready_o        (rx_branch_out_ready[1]),
        .packet_in_valid_i        (rx_branch_out_valid[1]),
        .packet_in_data_i         (rx_branch_to_cmd_proc),
        .state_reset_out_ready_i  (cmd_proc_out_state_reset_ready),
        .state_reset_out_valid_o  (cmd_proc_out_state_reset_valid),
        .state_reset_out_data_o   (cmd_proc_out_state_reset_data),
        .forced_update_out_ready_i(cmd_proc_out_forced_update_ready),
        .forced_update_out_valid_o(cmd_proc_out_forced_update_valid),
        .forced_update_out_data_o (cmd_proc_out_forced_update_data),
        .state_read_out_ready_i   (cmd_proc_out_state_read_ready),
        .state_read_out_valid_o   (cmd_proc_out_state_read_valid),
        .state_read_out_data_o    (cmd_proc_out_state_read_data)
      );
    end else begin : gen_no_cmd_preprocess
      assign rx_branch_out_ready[1] = 1'b1;
    end
  endgenerate

  logic [CORE_INPUT_WIDTH-1:0] rx_branch_to_init;
  assign rx_branch_to_init = rx_branch_out_data[2];

  logic                        rx_branch_buffer_out_ready;
  logic                        rx_branch_buffer_out_valid;
  logic [CORE_INPUT_WIDTH-1:0] rx_branch_buffer_out_data;
  Pipeline_Skid_Buffer #(
    .WORD_WIDTH(CORE_INPUT_WIDTH)
  ) u_rx_init_skid_buffer (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (rx_branch_out_ready[2]),
    .input_valid (rx_branch_out_valid[2]),
    .input_data  (rx_branch_to_init),
    .output_ready(rx_branch_buffer_out_ready),
    .output_valid(rx_branch_buffer_out_valid),
    .output_data (rx_branch_buffer_out_data)
  );

  logic                                   rx_init_done_d;
  logic                                   rx_init_syn_weight_ram_we_d;
  logic [CORE_WEIGHT_RAM_ADDR_WIDTH-1:0]  rx_init_syn_weight_ram_addr_d;
  logic [CORE_WEIGHT_RAM_DATA_WIDTH-1:0]  rx_init_syn_weight_ram_data_d;
  logic                                   rx_init_axon_mapping_ram_we_d;
  logic [CORE_NEURON_ID_WIDTH-1:0]        rx_init_axon_mapping_ram_addr_d;
  logic [CORE_MAPPING_RAM_DATA_WIDTH-1:0] rx_init_axon_mapping_ram_data_d;
  logic                                   rx_init_axon_routes_ram_we_d;
  logic [CORE_ROUTES_RAM_ADDR_WIDTH-1:0]  rx_init_axon_routes_ram_addr_d;
  logic [CORE_ROUTES_RAM_DATA_WIDTH-1:0]  rx_init_axon_routes_ram_data_d;
  logic                                   rx_init_spike_threshold_reg_ce_d;
  logic [CORE_SPIKE_THRESHOLD_WIDTH-1:0]  rx_init_spike_threshold_reg_data_d;
  logic                                   rx_init_tau_mem_inv_reg_ce_d;
  logic [CORE_TAU_MEM_INV_WIDTH-1:0]      rx_init_tau_mem_inv_reg_data_d;
  logic                                   rx_init_leak_lut_we_d;
  logic [RAM_LEAK_ADDR_WIDTH_G-1:0]       rx_init_leak_lut_addr_d;
  logic [RAM_LEAK_DATA_WIDTH_G-1:0]       rx_init_leak_lut_data_d;
  MemoryInitUnit u_rx_mem_init_unit (
    .clk_i                     (clk_i),
    .rst_i                     (rst_i),
    .enable_i                  (init_d),
    .done_o                    (rx_init_done_d),
    .packet_ready_o            (rx_branch_buffer_out_ready),
    .packet_valid_i            (rx_branch_buffer_out_valid),
    .packet_data_i             (rx_branch_buffer_out_data),
    .syn_weight_ram_we_o       (rx_init_syn_weight_ram_we_d),
    .syn_weight_ram_addr_o     (rx_init_syn_weight_ram_addr_d),
    .syn_weight_ram_data_o     (rx_init_syn_weight_ram_data_d),
    .axon_mapping_ram_we_o     (rx_init_axon_mapping_ram_we_d),
    .axon_mapping_ram_addr_o   (rx_init_axon_mapping_ram_addr_d),
    .axon_mapping_ram_data_o   (rx_init_axon_mapping_ram_data_d),
    .axon_routes_ram_we_o      (rx_init_axon_routes_ram_we_d),
    .axon_routes_ram_addr_o    (rx_init_axon_routes_ram_addr_d),
    .axon_routes_ram_data_o    (rx_init_axon_routes_ram_data_d),
    .spike_threshold_reg_ce_o  (rx_init_spike_threshold_reg_ce_d),
    .spike_threshold_reg_data_o(rx_init_spike_threshold_reg_data_d),
    .tau_mem_inv_reg_ce_o      (rx_init_tau_mem_inv_reg_ce_d),
    .tau_mem_inv_reg_data_o    (rx_init_tau_mem_inv_reg_data_d),
    .leak_lut_we_o             (rx_init_leak_lut_we_d),
    .leak_lut_addr_o           (rx_init_leak_lut_addr_d),
    .leak_lut_data_o           (rx_init_leak_lut_data_d)
  );

  localparam RX_BRANCH_TO_MAIN_WIDTH = CORE_FEEDBACK_DATA_WIDTH;
  logic [RX_BRANCH_TO_MAIN_WIDTH-1:0] rx_branch_to_main;
  assign rx_branch_to_main = rx_branch_out_data[0][1+:RX_BRANCH_TO_MAIN_WIDTH];

  generate
    if (CORE_TYPE == "FULL") begin : gen_rx_merge
      Pipeline_Merge_Interleave #(
        .WORD_WIDTH (RX_BRANCH_TO_MAIN_WIDTH),
        .INPUT_COUNT(2)
      ) u_rx_merge (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready ({gen_full_core_signals.feedback_fifo_output_ready, rx_branch_out_ready[0]}),
        .input_valid ({gen_full_core_signals.feedback_fifo_output_valid, rx_branch_out_valid[0]}),
        .input_data  ({gen_full_core_signals.feedback_fifo_output_data,  rx_branch_to_main}),
        .output_ready(rx_merge_out_ready),
        .output_valid(rx_merge_out_valid),
        .output_data (rx_merge_out_data)
      );
    end else begin : gen_no_rx_merge
      assign rx_branch_out_ready[0] = rx_merge_out_ready;
      assign rx_merge_out_valid     = rx_branch_out_valid[0];
      assign rx_merge_out_data      = rx_branch_to_main;
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_synapse
      Synapse u_synapse (
        .clk_i                 (clk_i),
        .rst_i                 (rst_i),
        .enable_i              (enable_i),
        .done_o                (gen_synapse_neuron_signals.synapse_done),
        .init_i                (init_d),
        .spike_in_ready_o      (gen_synapse_neuron_signals.syn_input_fifo_out_ready),
        .spike_in_valid_i      (gen_synapse_neuron_signals.syn_input_fifo_out_valid),
        .spike_in_data_i       (gen_synapse_neuron_signals.syn_input_fifo_out_data),
        .hot_neuron_out_ready_i(gen_synapse_neuron_signals.hot_neurons_fifo_input_ready),
        .hot_neuron_out_valid_o(gen_synapse_neuron_signals.hot_neurons_fifo_input_valid),
        .hot_neuron_out_data_o (gen_synapse_neuron_signals.hot_neurons_fifo_input_data),
        .weight_sum_ram_we_o   (gen_synapse_neuron_signals.weight_sum_port_a_we),
        .weight_sum_ram_waddr_o(gen_synapse_neuron_signals.weight_sum_port_a_waddr),
        .weight_sum_ram_data_o (gen_synapse_neuron_signals.weight_sum_port_a_data_in),
        .weight_sum_ram_re_o   (gen_synapse_neuron_signals.weight_sum_port_a_re),
        .weight_sum_ram_raddr_o(gen_synapse_neuron_signals.weight_sum_port_a_raddr),
        .weight_sum_ram_data_i (gen_synapse_neuron_signals.weight_sum_port_a_data_out),
        .weight_ram_we_i       (rx_init_syn_weight_ram_we_d),
        .weight_ram_addr_i     (rx_init_syn_weight_ram_addr_d),
        .weight_ram_data_i     (rx_init_syn_weight_ram_data_d)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_neuron
      NeuronWrapper #(
        .CORE_ID_X  (CORE_ID_X),
        .CORE_ID_Y  (CORE_ID_Y),
        .EMIT_SPIKES(CORE_TYPE == "FULL" ? 1 : 0),
        .LEAK_STATES(CORE_TYPE == "FULL" ? 1 : 0)
      ) u_neuron_wrapper (
        .clk_i                     (clk_i),
        .rst_i                     (rst_i),
        .enable_i                  (enable_i),
        .init_i                    (init_d),
        .timestep_i                (timestep_i),
        .core_came_out_of_reset_i  (gen_ts_det_toggle.core_came_out_of_reset_q),
        .done_o                    (gen_synapse_neuron_signals.neuron_done),
        .hot_neuron_in_ready_o     (gen_synapse_neuron_signals.hot_neurons_fifo_output_ready),
        .hot_neuron_in_valid_i     (gen_synapse_neuron_signals.hot_neurons_fifo_output_valid),
        .hot_neuron_in_data_i      (gen_synapse_neuron_signals.hot_neurons_fifo_output_data),
        .spiking_neuron_out_ready_i(gen_synapse_neuron_signals.spiking_neurons_fifo_input_ready),
        .spiking_neuron_out_valid_o(gen_synapse_neuron_signals.spiking_neurons_fifo_input_valid),
        .spiking_neuron_out_data_o (gen_synapse_neuron_signals.spiking_neurons_fifo_input_data),
        .weight_sum_ram_we_o       (gen_synapse_neuron_signals.weight_sum_port_b_we),
        .weight_sum_ram_waddr_o    (gen_synapse_neuron_signals.weight_sum_port_b_waddr),
        .weight_sum_ram_data_o     (gen_synapse_neuron_signals.weight_sum_port_b_data_in),
        .weight_sum_ram_re_o       (gen_synapse_neuron_signals.weight_sum_port_b_re),
        .weight_sum_ram_raddr_o    (gen_synapse_neuron_signals.weight_sum_port_b_raddr),
        .weight_sum_ram_data_i     (gen_synapse_neuron_signals.weight_sum_port_b_data_out[CORE_WEIGHT_SUM_RAM_DATA_WIDTH -1 : 1]),
        .spike_threshold_reg_ce_i  (rx_init_spike_threshold_reg_ce_d),
        .spike_threshold_reg_data_i(rx_init_spike_threshold_reg_data_d),
        .tau_mem_inv_reg_ce_i      (rx_init_tau_mem_inv_reg_ce_d),
        .tau_mem_inv_reg_data_i    (rx_init_tau_mem_inv_reg_data_d),
        .leak_lut_we_i             (rx_init_leak_lut_we_d),
        .leak_lut_addr_i           (rx_init_leak_lut_addr_d),
        .leak_lut_data_i           (rx_init_leak_lut_data_d),
        .forced_update_in_ready_o  (gen_cmd_preprocess.cmd_proc_out_forced_update_ready),
        .forced_update_in_valid_i  (gen_cmd_preprocess.cmd_proc_out_forced_update_valid),
        .forced_update_in_data_i   (gen_cmd_preprocess.cmd_proc_out_forced_update_data),
        .state_readout_in_ready_o  (gen_cmd_preprocess.cmd_proc_out_state_read_ready),
        .state_readout_in_valid_i  (gen_cmd_preprocess.cmd_proc_out_state_read_valid),
        .state_readout_in_data_i   (gen_cmd_preprocess.cmd_proc_out_state_read_data),
        .state_reset_in_ready_o    (gen_cmd_preprocess.cmd_proc_out_state_reset_ready),
        .state_reset_in_valid_i    (gen_cmd_preprocess.cmd_proc_out_state_reset_valid),
        .state_reset_in_data_i     (gen_cmd_preprocess.cmd_proc_out_state_reset_data),
        .state_readout_out_ready_i (gen_synapse_neuron_signals.state_readout_out_ready),
        .state_readout_out_valid_o (gen_synapse_neuron_signals.state_readout_out_valid),
        .state_readout_out_data_o  (gen_synapse_neuron_signals.state_readout_out_data)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "INPUT") begin : gen_axon
      Axon u_axon (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i),
        .enable_i                 (enable_i),
        .init_i                   (init_d),
        .done_o                   (gen_axon_signals.axon_done),
        .spiking_neuron_in_ready_o(spiking_neurons_fifo_output_ready),
        .spiking_neuron_in_valid_i(spiking_neurons_fifo_output_valid), 
        .spiking_neuron_in_data_i (spiking_neurons_fifo_output_data),
        .spike_out_ready_i        (gen_axon_signals.spike_output_fifo_input_ready),
        .spike_out_valid_o        (gen_axon_signals.spike_output_fifo_input_valid),
        .spike_out_data_o         (gen_axon_signals.spike_output_fifo_input_data),
        .memory_mapping_ram_we_i  (rx_init_axon_mapping_ram_we_d),
        .memory_mapping_ram_addr_i(rx_init_axon_mapping_ram_addr_d),
        .memory_mapping_ram_data_i(rx_init_axon_mapping_ram_data_d),
        .routes_ram_we_i          (rx_init_axon_routes_ram_we_d),
        .routes_ram_addr_i        (rx_init_axon_routes_ram_addr_d),
        .routes_ram_data_i        (rx_init_axon_routes_ram_data_d)
      );
    end
  endgenerate

  generate
    if (CORE_TYPE == "FULL") begin : gen_tx_full_core
      pkt_route_entry_s packet_from_spike_output_fifo;
      assign packet_from_spike_output_fifo = gen_axon_signals.spike_output_fifo_output_data;
      Pipeline_Branch_One_Hot #(
        .WORD_WIDTH    (CORE_ROUTE_WIDTH),
        .OUTPUT_COUNT  (2),
        .IMPLEMENTATION("AND")
      ) u_branch_tx (
        .selector    (|{packet_from_spike_output_fifo.target_core_x, packet_from_spike_output_fifo.target_core_y} ? 2'b10 : 2'b01),
        .input_ready (gen_axon_signals.spike_output_fifo_output_ready),
        .input_valid (gen_axon_signals.spike_output_fifo_output_valid),
        .input_data  (gen_axon_signals.spike_output_fifo_output_data),
        .output_ready(gen_full_core_signals.output_branch_ready),
        .output_valid(gen_full_core_signals.output_branch_valid),
        .output_data ({gen_full_core_signals.output_branch_data})
      );

      assign gen_full_core_signals.output_branch_ready[0] = gen_full_core_signals.event_internal_ready;
      assign gen_full_core_signals.event_internal_valid   = gen_full_core_signals.output_branch_valid[0];
      assign gen_full_core_signals.event_internal_data    = gen_full_core_signals.output_branch_data[0][CORE_FEEDBACK_DATA_WIDTH-1:0];

      pkt_route_entry_s axon_out_data;
      assign axon_out_data = gen_full_core_signals.output_branch_data[1];
      pkt_noc_event_data_s axon_noc_packet;
      assign axon_noc_packet.core.payload   = axon_out_data.payload;
      assign axon_noc_packet.core.ctrl_flag = 1'b0;
      assign axon_noc_packet.target_core_y  = axon_out_data.target_core_y;
      assign axon_noc_packet.target_core_x  = axon_out_data.target_core_x;

      logic                                tx_merge_out_ready;
      logic                                tx_merge_out_valid;
      logic [MESH_PACKET_DATA_WIDTH_X-1:0] tx_merge_out_data;
      Pipeline_Merge_Interleave #(
        .WORD_WIDTH (MESH_PACKET_DATA_WIDTH_X),
        .INPUT_COUNT(2)
      ) u_tx_merge (
        .clock       (clk_i),
        .clear       (rst_i),
        .input_ready ({gen_synapse_neuron_signals.state_readout_out_ready, gen_full_core_signals.output_branch_ready[1]}),
        .input_valid ({gen_synapse_neuron_signals.state_readout_out_valid, gen_full_core_signals.output_branch_valid[1]}),
        .input_data  ({gen_synapse_neuron_signals.state_readout_out_data,  axon_noc_packet}),
        .output_ready(tx_merge_out_ready),
        .output_valid(tx_merge_out_valid),
        .output_data (tx_merge_out_data)
      );

      assign tx_merge_out_ready = packet_out_ready_i;
      assign packet_out_valid_o = tx_merge_out_valid;
      assign packet_out_data_o  = tx_merge_out_data;

    end else if (CORE_TYPE == "OUTPUT") begin : gen_tx_output_core
      assign gen_synapse_neuron_signals.state_readout_out_ready = packet_out_ready_i;
      assign packet_out_valid_o                                 = gen_synapse_neuron_signals.state_readout_out_valid;
      assign packet_out_data_o                                  = pkt_noc_event_data_s'(gen_synapse_neuron_signals.state_readout_out_data);

    end else if (CORE_TYPE == "INPUT") begin : gen_tx_input_core
      pkt_route_entry_s axon_out_data;
      assign axon_out_data = gen_axon_signals.spike_output_fifo_output_data;
      pkt_noc_event_data_s axon_noc_packet;
      assign axon_noc_packet.core.payload   = axon_out_data.payload;
      assign axon_noc_packet.core.ctrl_flag = 1'b0;
      assign axon_noc_packet.target_core_y  = axon_out_data.target_core_y;
      assign axon_noc_packet.target_core_x  = axon_out_data.target_core_x;

      assign gen_axon_signals.spike_output_fifo_output_ready = packet_out_ready_i;
      assign packet_out_valid_o                              = gen_axon_signals.spike_output_fifo_output_valid;
      assign packet_out_data_o                               = axon_noc_packet;
    end else begin : gen_no_tx_branch
      assign packet_out_valid_o             = 1'b0;
    end
  endgenerate

  //============================================================================
  // Processes
  //============================================================================

  generate
    if (CORE_TYPE == "FULL" || CORE_TYPE == "OUTPUT") begin : gen_ts_det_toggle

      logic                      ts_det_toggle_prev_q;
      logic [TIMESTEP_WIDTH-1:0] ts_det_id_prev_q;
      logic                      ts_det_toggle_d;

      always_ff @(posedge clk_i) begin
        if (rst_i) begin
          ts_det_id_prev_q     <= '0;
          ts_det_toggle_prev_q <= 1'b1;
        end else if (!enable_i) begin
          if (timestep_i != ts_det_id_prev_q) begin
            ts_det_id_prev_q     <= timestep_i;
            ts_det_toggle_prev_q <= ts_det_toggle_d;
          end
        end
      end

      assign ts_det_toggle_d = ~ts_det_toggle_prev_q;

      logic ts_det_toggle_posedge_d;
      Pulse_Generator u_pulse_ts_toggle (
          .clock            (clk_i),
          .level_in         (ts_det_toggle_d),
          .pulse_posedge_out(ts_det_toggle_posedge_d),
          .pulse_negedge_out(/* ignored */),
          .pulse_anyedge_out(/* ignored */)
      );

      logic core_came_out_of_reset_q;
      always_ff @(posedge clk_i) begin
        if (rst_i) begin
          core_came_out_of_reset_q <= 1'b1;
        end else if (ts_det_toggle_posedge_d) begin
          core_came_out_of_reset_q <= 1'b0;
        end
      end

    end
  endgenerate

  //============================================================================
  // Assignments
  //============================================================================

  assign init_d = ~enable_i && init_i;

  generate
    if (CORE_TYPE == "FULL") begin : gen_ready_full
      assign rx_done                        = gen_full_core_signals.feedback_fifo_empty && ~packet_in_valid_i && gen_synapse_neuron_signals.syn_input_fifo_empty && gen_cmd_preprocess.cmd_proc_done_d;
      assign gen_full_core_signals.tx_done  = ~gen_full_core_signals.event_internal_valid && ~packet_out_valid_o;
      assign core_done_d                    = rx_done && gen_synapse_neuron_signals.synapse_done && gen_synapse_neuron_signals.neuron_done && gen_axon_signals.axon_done && gen_full_core_signals.tx_done;
      assign core_idle_d                    = core_done_d && gen_synapse_neuron_signals.hot_neurons_fifo_empty;
    end else if (CORE_TYPE == "OUTPUT") begin : gen_ready_output
      assign rx_done                        = ~packet_in_valid_i && gen_synapse_neuron_signals.syn_input_fifo_empty;
      assign core_done_d                    = rx_done && gen_synapse_neuron_signals.synapse_done && gen_synapse_neuron_signals.neuron_done;
      assign core_idle_d                    = core_done_d && gen_synapse_neuron_signals.hot_neurons_fifo_empty;
    end else begin : gen_ready_input
      assign rx_done                        = ~packet_in_valid_i && spiking_neurons_fifo_empty;
      assign gen_input_core_signals.tx_done = ~packet_out_valid_o;
      assign core_done_d                    = rx_done && gen_axon_signals.axon_done && gen_input_core_signals.tx_done;
      assign core_idle_d                    = core_done_d;
    end
  endgenerate

  assign core_done_o = core_done_d || (init_d && rx_init_done_d);
  assign core_idle_o = core_idle_d || (init_d && rx_init_done_d);

endmodule
