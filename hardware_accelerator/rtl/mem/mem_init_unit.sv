`timescale 1ns / 1ps

`include "global_params.vh"

module MemoryInitUnit #(
  // Packet parameters
  parameter INIT_PAYLOAD_WIDTH = INIT_PAYLOAD_WIDTH_G,
  parameter INIT_PACKET_WIDTH  = $bits(pkt_payload_init_s),

  // Init targets parameters
  /// Synapse Weights RAM
  parameter WEIGHT_RAM_ADDR_WIDTH = CORE_WEIGHT_RAM_ADDR_WIDTH_G,
  parameter WEIGHT_RAM_DATA_WIDTH = CORE_WEIGHT_RAM_DATA_WIDTH_G,

  /// Axon Mapping RAM
  parameter AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH = CORE_NEURON_ID_WIDTH_G,
  parameter AXON_MEMORY_MAPPING_RAM_DATA_WIDTH = CORE_MAPPING_RAM_DATA_WIDTH_G,

  /// Axon Routes RAM
  parameter AXON_ROUTES_RAM_ADDR_WIDTH = CORE_ROUTES_RAM_ADDR_WIDTH_G,
  parameter AXON_ROUTES_RAM_DATA_WIDTH = CORE_ROUTES_RAM_DATA_WIDTH_G,

  /// Spike Threshold Register
  parameter SPIKE_THRESHOLD_WIDTH = SPIKE_THRESHOLD_WIDTH_G,

  /// Tau Mem Inv Register
  parameter TAU_MEM_INV_WIDTH = TAU_MEM_INV_WIDTH_G,

  /// Leak Factor LUT RAM
  parameter LEAK_LUT_ADDR_WIDTH = RAM_LEAK_ADDR_WIDTH_G,
  parameter LEAK_LUT_DATA_WIDTH = RAM_LEAK_DATA_WIDTH_G,

  parameter INIT_TARGET_COUNT = INIT_TARGET_COUNT_G,
  parameter pkt_init_type_e    INIT_SYNAPSE_WEIGHTS    = INIT_SYNAPSE_WEIGHTS_G,
  parameter pkt_init_type_e    INIT_AXON_MAPPING       = INIT_AXON_MAPPING_G,
  parameter pkt_init_type_e    INIT_AXON_ROUTES        = INIT_AXON_ROUTES_G,
  parameter pkt_init_type_e    INIT_SPIKE_THRESHOLD    = INIT_SPIKE_THRESHOLD_G,
  parameter pkt_init_type_e    INIT_TAU_MEM_INV        = INIT_TAU_MEM_INV_G,
  parameter pkt_init_type_e    INIT_LEAK_LUT           = INIT_LEAK_LUT_G,
  parameter pkt_init_type_oh_e INIT_SYNAPSE_WEIGHTS_OH = INIT_SYNAPSE_WEIGHTS_OH_G,
  parameter pkt_init_type_oh_e INIT_AXON_MAPPING_OH    = INIT_AXON_MAPPING_OH_G,
  parameter pkt_init_type_oh_e INIT_AXON_ROUTES_OH     = INIT_AXON_ROUTES_OH_G,
  parameter pkt_init_type_oh_e INIT_SPIKE_THRESHOLD_OH = INIT_SPIKE_THRESHOLD_OH_G,
  parameter pkt_init_type_oh_e INIT_TAU_MEM_INV_OH     = INIT_TAU_MEM_INV_OH_G,
  parameter pkt_init_type_oh_e INIT_LEAK_LUT_OH        = INIT_LEAK_LUT_OH_G
) (
  // Control signals
  input logic clk_i,
  input logic rst_i,
  input logic enable_i,  
  output logic done_o,

  // Input data packets
  output logic              packet_ready_o,
  input  logic              packet_valid_i,
  input  pkt_payload_init_s packet_data_i,

  // Connection to init target synapse weight RAM
  output logic                             syn_weight_ram_we_o,
  output logic [WEIGHT_RAM_ADDR_WIDTH-1:0] syn_weight_ram_addr_o,
  output logic [WEIGHT_RAM_DATA_WIDTH-1:0] syn_weight_ram_data_o,

  // Connection to init target axon mapping RAM
  output logic                                          axon_mapping_ram_we_o,
  output logic [AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH-1:0] axon_mapping_ram_addr_o,
  output logic [AXON_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] axon_mapping_ram_data_o,

  // Connection to init target axon routes RAM
  output logic                                  axon_routes_ram_we_o,
  output logic [AXON_ROUTES_RAM_ADDR_WIDTH-1:0] axon_routes_ram_addr_o,
  output logic [AXON_ROUTES_RAM_DATA_WIDTH-1:0] axon_routes_ram_data_o,

  // Connection to init target spike threshold register
  output logic                             spike_threshold_reg_ce_o,
  output logic [SPIKE_THRESHOLD_WIDTH-1:0] spike_threshold_reg_data_o,

  // Connection to init target tau mem inv register
  output logic                         tau_mem_inv_reg_ce_o,
  output logic [TAU_MEM_INV_WIDTH-1:0] tau_mem_inv_reg_data_o,

  // Connection to init target leak factor LUT RAM
  output logic                           leak_lut_we_o,
  output logic [LEAK_LUT_ADDR_WIDTH-1:0] leak_lut_addr_o,
  output logic [LEAK_LUT_DATA_WIDTH-1:0] leak_lut_data_o
);

  //============================================================================
  // FSM State Declarations
  //============================================================================

  typedef enum logic [2:0] {
    IDLE,
    INIT_READY,
    INIT_RUNNING,
    INIT_FINALIZING
  } master_state_e;
    
  master_state_e state_q, state_d;
  
  //============================================================================
  // Signal Declarations
  //============================================================================
  
  pkt_init_type_oh_e init_target_sel_d;
  pkt_init_type_oh_e init_target_sel_q;
  logic clear_in_d;
  logic clear_in_q;
  logic clear_out_d;
  logic clear_out_q;
  logic serial_d;
  logic handshake_in_gate_d;
  logic handshake_in_gate_q;
  logic sram_write_gate_d;
  logic sram_write_gate_q;
  logic                          parallel_in_valid_d;
  logic                          parallel_in_ready_d;
  logic [INIT_PAYLOAD_WIDTH-1:0] parallel_in_data_d;

  localparam WEIGHT_RAM_TOTAL_WIDTH              = WEIGHT_RAM_ADDR_WIDTH + WEIGHT_RAM_DATA_WIDTH;
  localparam AXON_MEMORY_MAPPING_RAM_TOTAL_WIDTH = AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH + AXON_MEMORY_MAPPING_RAM_DATA_WIDTH;
  localparam AXON_ROUTES_RAM_TOTAL_WIDTH         = AXON_ROUTES_RAM_ADDR_WIDTH + AXON_ROUTES_RAM_DATA_WIDTH;
  localparam SPIKE_THRESHOLD_TOTAL_WIDTH         = SPIKE_THRESHOLD_WIDTH;
  localparam TAU_MEM_INV_TOTAL_WIDTH             = TAU_MEM_INV_WIDTH;
  localparam LEAK_LUT_TOTAL_WIDTH                = LEAK_LUT_ADDR_WIDTH + LEAK_LUT_DATA_WIDTH;
  localparam integer ARR_TOTAL_WIDTH [0:255] = '{0: WEIGHT_RAM_TOTAL_WIDTH,
                                                 1: AXON_MEMORY_MAPPING_RAM_TOTAL_WIDTH,
                                                 2: AXON_ROUTES_RAM_TOTAL_WIDTH,
                                                 3: SPIKE_THRESHOLD_TOTAL_WIDTH,
                                                 4: TAU_MEM_INV_TOTAL_WIDTH,
                                                 5: LEAK_LUT_TOTAL_WIDTH,
                                                 default: 0};
  localparam integer MAX_TOTAL_WIDTH = max_in_array(ARR_TOTAL_WIDTH, INIT_TARGET_COUNT);

  logic                       parallel_out_valid_d;
  logic                       parallel_out_ready_d;
  logic [MAX_TOTAL_WIDTH-1:0] parallel_out_data_d;

  localparam integer NUM_PACKETS               = (MAX_TOTAL_WIDTH + INIT_PAYLOAD_WIDTH - 1) / INIT_PAYLOAD_WIDTH;
  localparam integer MAX_COUNT                 = NUM_PACKETS * INIT_PAYLOAD_WIDTH;
  localparam integer ARR_COUNT_BUMP_TO [0:255] = '{0: MAX_COUNT - WEIGHT_RAM_TOTAL_WIDTH,
                                                   1: MAX_COUNT - AXON_MEMORY_MAPPING_RAM_TOTAL_WIDTH,
                                                   2: MAX_COUNT - AXON_ROUTES_RAM_TOTAL_WIDTH,
                                                   3: MAX_COUNT - SPIKE_THRESHOLD_TOTAL_WIDTH,
                                                   4: MAX_COUNT - TAU_MEM_INV_TOTAL_WIDTH,
                                                   5: MAX_COUNT - LEAK_LUT_TOTAL_WIDTH,
                                                   default: 0};
  localparam integer MIN_COUNT_BUMP_TO         = min_in_array(ARR_COUNT_BUMP_TO, INIT_TARGET_COUNT);
  localparam integer COUNT_BUMP_WIDTH          = $clog2(MIN_COUNT_BUMP_TO);

  localparam COUNT_WIDTH   = $clog2(MAX_TOTAL_WIDTH + 1);
  localparam COUNT_ZERO    = {COUNT_WIDTH{1'b0}};
  logic [COUNT_WIDTH-1:0] counter_d;

  logic [INIT_TARGET_COUNT-1:0]                       branch_out_ready_d;
  logic [INIT_TARGET_COUNT-1:0]                       branch_out_valid_d;   
  logic [INIT_TARGET_COUNT-1:0] [MAX_TOTAL_WIDTH-1:0] branch_out_data_d;    

  //============================================================================
  // Signal Assignments
  //============================================================================

  assign done_o = ((state_q == IDLE) || (state_q == INIT_READY)) && (counter_d == COUNT_ZERO);

  assign packet_ready_o      = parallel_in_ready_d &&
                               handshake_in_gate_q;
  assign parallel_in_valid_d = packet_valid_i &&
                               handshake_in_gate_q &&
                               ($unsigned(packet_data_i.init_target) < $unsigned(INIT_TARGET_COUNT));  
  assign parallel_in_data_d  = packet_data_i.data;                                               

  assign branch_out_ready_d = (state_q == INIT_FINALIZING) || (state_q == INIT_RUNNING) ? '1 : '0;
  
  assign syn_weight_ram_we_o   = (init_target_sel_q[0] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign syn_weight_ram_data_o = branch_out_data_d[0][0 +: WEIGHT_RAM_DATA_WIDTH];
  assign syn_weight_ram_addr_o = branch_out_data_d[0][WEIGHT_RAM_DATA_WIDTH +: WEIGHT_RAM_ADDR_WIDTH];

  assign axon_mapping_ram_we_o   = (init_target_sel_q[1] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign axon_mapping_ram_data_o = branch_out_data_d[1][0 +: AXON_MEMORY_MAPPING_RAM_DATA_WIDTH];
  assign axon_mapping_ram_addr_o = branch_out_data_d[1][AXON_MEMORY_MAPPING_RAM_DATA_WIDTH +: AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH];

  assign axon_routes_ram_we_o   = (init_target_sel_q[2] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign axon_routes_ram_data_o = branch_out_data_d[2][0 +: AXON_ROUTES_RAM_DATA_WIDTH];
  assign axon_routes_ram_addr_o = branch_out_data_d[2][AXON_ROUTES_RAM_DATA_WIDTH +: AXON_ROUTES_RAM_ADDR_WIDTH];

  assign spike_threshold_reg_ce_o   = (init_target_sel_q[3] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign spike_threshold_reg_data_o = branch_out_data_d[3][0 +: SPIKE_THRESHOLD_WIDTH];

  assign tau_mem_inv_reg_ce_o   = (init_target_sel_q[4] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign tau_mem_inv_reg_data_o = branch_out_data_d[4][0 +: TAU_MEM_INV_WIDTH];

  assign leak_lut_we_o   = (init_target_sel_q[5] == 1'b1) ? sram_write_gate_q : 1'b0;
  assign leak_lut_data_o = branch_out_data_d[5][0 +: LEAK_LUT_DATA_WIDTH];
  assign leak_lut_addr_o = branch_out_data_d[5][LEAK_LUT_DATA_WIDTH +: LEAK_LUT_ADDR_WIDTH];

  //============================================================================
  // MASTER FSM
  //============================================================================

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q              <= IDLE;
      init_target_sel_q    <= INIT_SYNAPSE_WEIGHTS_OH; 
      clear_in_q           <= 1'b1;
      clear_out_q          <= 1'b1;
      handshake_in_gate_q  <= 1'b0;
      sram_write_gate_q    <= 1'b0;
    end else begin
      state_q              <= state_d;
      init_target_sel_q    <= init_target_sel_d;
      clear_in_q           <= clear_in_d;
      clear_out_q          <= clear_out_d;
      handshake_in_gate_q  <= handshake_in_gate_d;
      sram_write_gate_q    <= sram_write_gate_d;
    end
  end

  always_comb begin
    state_d              = state_q;
    init_target_sel_d    = init_target_sel_q;
    clear_in_d           = 1'b1;
    clear_out_d          = 1'b1;
    handshake_in_gate_d  = 1'b0;
    sram_write_gate_d    = 1'b0;

    case (state_q)
      IDLE: begin
        if (enable_i) begin
          state_d = INIT_READY;
        end
      end

      INIT_READY: begin
        clear_out_d = 1'b0;
        if (!enable_i) begin
          state_d = IDLE;
        end else if (handshake_in_gate_q)  begin
          clear_in_d = 1'b0;
          state_d = INIT_RUNNING;
        end else if (parallel_in_ready_d && packet_valid_i) begin
          case (packet_data_i.init_target)
            INIT_SYNAPSE_WEIGHTS: begin
              init_target_sel_d = INIT_SYNAPSE_WEIGHTS_OH;
            end
            INIT_AXON_MAPPING: begin
              init_target_sel_d = INIT_AXON_MAPPING_OH;
            end
            INIT_AXON_ROUTES: begin
              init_target_sel_d = INIT_AXON_ROUTES_OH;
            end
            INIT_SPIKE_THRESHOLD: begin
              init_target_sel_d = INIT_SPIKE_THRESHOLD_OH;
            end
            INIT_TAU_MEM_INV: begin
              init_target_sel_d = INIT_TAU_MEM_INV_OH;
            end
            INIT_LEAK_LUT: begin
              init_target_sel_d = INIT_LEAK_LUT_OH;
            end
            default: begin 
              init_target_sel_d = INIT_SYNAPSE_WEIGHTS_OH;
            end
          endcase
          clear_in_d = 1'b0;
          handshake_in_gate_d = 1'b1;
        end
      end

      INIT_RUNNING: begin
        clear_in_d = 1'b0;
        clear_out_d = 1'b0;
        if (!enable_i) begin
          state_d = IDLE;
        end else if (parallel_out_valid_d) begin
          sram_write_gate_d = 1'b1;
          state_d = INIT_FINALIZING;
        end else if (parallel_in_ready_d) begin
          clear_in_d = 1'b1;
          state_d = INIT_READY;
        end
      end

      INIT_FINALIZING: begin
        state_d = INIT_READY;
        if (!enable_i) begin
          state_d = IDLE;
        end
      end

      default: begin
        state_d = IDLE;
      end
    endcase
  end

  //============================================================================
  // Module Instantiations
  //============================================================================

  Parallel_Serial #(
    .WORD_WIDTH(INIT_PAYLOAD_WIDTH)
  ) u_parallel_serial (
    .clock            (clk_i),
    .clock_enable     (1'b1),
    .clear            (clear_in_q),
    .parallel_in_ready(parallel_in_ready_d),
    .parallel_in_valid(parallel_in_valid_d),
    .parallel_in      (parallel_in_data_d),
    .serial_out       (serial_d)
  );

  Counter_Binary #(
    .WORD_WIDTH(COUNT_WIDTH),
    .INCREMENT(1),
    .INITIAL_COUNT(COUNT_ZERO)
  ) u_counter (
    .clock(clk_i),
    .clear(clear_out_q),
    .up_down(1'b0), 
    .run(state_q == INIT_RUNNING),
    .load(1'b0),
    .load_count(COUNT_ZERO),
    .carry_in(1'b0),
    .carry_out(),
    .carries(),
    .overflow(),
    .count(counter_d)
  );

  Serial_Parallel #(
    .WORD_WIDTH(MAX_TOTAL_WIDTH)
  ) u_serial_parallel (
    .clock             (clk_i),
    .clock_enable      (($unsigned(counter_d) >= $unsigned(MIN_COUNT_BUMP_TO) && state_q == INIT_RUNNING) || state_q == INIT_FINALIZING),
    .clear             (clear_out_q),
    .serial_in         (serial_d),
    .parallel_out_ready(parallel_out_ready_d),
    .parallel_out_valid(parallel_out_valid_d),
    .parallel_out      (parallel_out_data_d)
  );

  Pipeline_Branch_One_Hot #(
    .WORD_WIDTH    (MAX_TOTAL_WIDTH),
    .OUTPUT_COUNT  (INIT_TARGET_COUNT),
    .IMPLEMENTATION("AND")
  ) u_output_branch (
    .selector    (init_target_sel_q),
    .input_ready (parallel_out_ready_d),
    .input_valid (parallel_out_valid_d),
    .input_data  (parallel_out_data_d),
    .output_ready(branch_out_ready_d),
    .output_valid(branch_out_valid_d),  
    .output_data (branch_out_data_d)
  );

endmodule