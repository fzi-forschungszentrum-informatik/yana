`timescale 1ns / 1ps

`include "global_params.vh"

module Axon #(
  parameter VENDOR = VENDOR_G,
  parameter SPIKE_OUT_FIFO_DATA_WIDTH = CORE_NEURON_ID_WIDTH_G,
  parameter OUTPUT_BUFFER_DATA_WIDTH  = CORE_ROUTE_WIDTH_G,

  parameter URAM_ROUTES_ADDR_WIDTH  = CORE_ROUTES_RAM_ADDR_WIDTH_G,
  parameter URAM_ROUTES_DATA_WIDTH  = CORE_ROUTES_RAM_DATA_WIDTH_G,
  parameter URAM_ROUTES_ENTRY_WIDTH = CORE_ROUTE_WIDTH_G,
  parameter URAM_ROUTES_BYTE_WIDTH  = 9,
  parameter URAM_ROUTES_INIT_FILE   = ROUTES_RAM_INIT_FILE_HIDDEN_G,

  parameter URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH = CORE_NEURON_ID_WIDTH_G,
  parameter URAM_MEMORY_MAPPING_RAM_DATA_WIDTH = CORE_MAPPING_RAM_DATA_WIDTH_G,
  parameter URAM_MEMORY_MAPPING_RAM_INIT_FILE  = MAPPING_RAM_INIT_FILE_HIDDEN_G,

  parameter URAM_MEMORY_MAPPING_ADDR_WIDTH     = CORE_ROUTES_RAM_ADDR_WIDTH_G,
  parameter URAM_MEMORY_MAPPING_LAST_IDX_WIDTH = CORE_MAPPING_RAM_LAST_IDX_WIDTH_G,

  parameter CYCLES_RAISE_SLEEP = CYCLES_RAISE_SLEEP_G
) (
  input  logic clk_i,
  input  logic rst_i,
  input  logic enable_i,
  input  logic init_i,
  output logic done_o,

  output logic                                 spiking_neuron_in_ready_o,
  input  logic                                 spiking_neuron_in_valid_i,
  input  logic [SPIKE_OUT_FIFO_DATA_WIDTH-1:0] spiking_neuron_in_data_i,

  input  logic                                spike_out_ready_i,
  output logic                                spike_out_valid_o,
  output logic [OUTPUT_BUFFER_DATA_WIDTH-1:0] spike_out_data_o,

  input logic                                          memory_mapping_ram_we_i,
  input logic [URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH-1:0] memory_mapping_ram_addr_i,
  input logic [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] memory_mapping_ram_data_i,
  
  input logic                              routes_ram_we_i,
  input logic [URAM_ROUTES_ADDR_WIDTH-1:0] routes_ram_addr_i,
  input logic [URAM_ROUTES_DATA_WIDTH-1:0] routes_ram_data_i

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
    PROCESSING
  } master_state_e;

  typedef enum logic [1:0] {
    AWAKE,
    COUNTING_TO_SLEEP,
    SLEEPING
  } sleep_state_e;

  master_state_e state_q, state_d;
  sleep_state_e sleep_state_q, sleep_state_d;

  typedef struct packed {
    logic [URAM_MEMORY_MAPPING_LAST_IDX_WIDTH-1:0] last_idx;
    logic [URAM_MEMORY_MAPPING_ADDR_WIDTH-1:0]     end_addr;
    logic [URAM_MEMORY_MAPPING_ADDR_WIDTH-1:0]     start_addr;
  } mapping_ram_data_s;

  //============================================================================
  // Signal Declarations
  //============================================================================
  
  // Uncomment to see these signals in simulation
  //  and comment their local declarations in stage 2
  // logic is_last_line;
  // logic is_last_entry_in_line;
  // logic is_last_entry_in_last_line;

  logic                                          mapping_ram_read_en_q;
  logic [URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH-1:0] mapping_ram_read_addr_q;
  logic [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] mapping_ram_data_out;

  logic                                          mapping_ram_init_write_en_d;
  logic [URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH-1:0] mapping_ram_init_write_addr_d;
  logic [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] mapping_ram_init_data_in_d;

  localparam URAM_ROUTES_ENTRY_SELECT_WIDTH = URAM_MEMORY_MAPPING_LAST_IDX_WIDTH;
  logic                                      routes_ram_read_en_q;
  logic [URAM_ROUTES_ADDR_WIDTH-1:0]         routes_ram_read_addr_q;
  logic [URAM_ROUTES_ENTRY_SELECT_WIDTH-1:0] routes_ram_read_entry_select_q;
  logic [URAM_ROUTES_ENTRY_WIDTH-1:0]        routes_ram_data_out;

  logic                                      routes_ram_init_write_en_d;
  logic [URAM_ROUTES_ADDR_WIDTH-1:0]         routes_ram_init_write_addr_d;
  logic [URAM_ROUTES_DATA_WIDTH-1:0]         routes_ram_init_write_data_d;

  logic routes_uram_sleep;
  logic routes_uram_awake;
  logic memory_mapping_ram_sleep;
  logic memory_mapping_ram_awake;
  logic all_memories_awake;
  logic [$clog2(CYCLES_RAISE_SLEEP+1)-1:0] sleep_counter_q, sleep_counter_d;

  logic pipeline_done_d;

  //============================================================================
  // MASTER FSM
  //============================================================================

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= IDLE;
    end else begin
      state_q <= state_d;
    end
  end

  always_comb begin
    state_d = state_q;
    case (state_q)
      IDLE: begin
        if (init_i) begin
          state_d = INITIALIZING;
        end else if (enable_i && !pipeline_done_d && all_memories_awake) begin
          state_d = PROCESSING;
        end
      end
      PROCESSING: begin
        if (pipeline_done_d) begin
          state_d = IDLE;
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
      sleep_state_q <= AWAKE;
      sleep_counter_q <= '0;
    end else begin
      sleep_state_q <= sleep_state_d;
      sleep_counter_q <= sleep_counter_d;
    end
  end

  always_comb begin
    sleep_state_d = sleep_state_q;
    sleep_counter_d = sleep_counter_q;
    memory_mapping_ram_sleep = 1'b0;
    routes_uram_sleep = 1'b0;

    if (state_q == INITIALIZING) begin
      sleep_state_d = AWAKE;
      sleep_counter_d = '0;
    end else begin
      case (sleep_state_q)
        AWAKE: begin
          if (pipeline_done_d) begin
            sleep_counter_d = CYCLES_RAISE_SLEEP;
            sleep_state_d = COUNTING_TO_SLEEP;
          end
        end
        COUNTING_TO_SLEEP: begin
          if (!pipeline_done_d) begin
            sleep_counter_d = '0;
            sleep_state_d = AWAKE;
          end else if (sleep_counter_q == 0) begin
            memory_mapping_ram_sleep = 1'b1;
            routes_uram_sleep = 1'b1;
            sleep_state_d = SLEEPING;
          end else begin
            sleep_counter_d = sleep_counter_q - 1;
          end
        end
        SLEEPING: begin
          memory_mapping_ram_sleep = 1'b1;
          routes_uram_sleep = 1'b1;
          if (!pipeline_done_d) begin
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
  // Input Skid Buffer
  //============================================================================

  logic                                 input_skid_input_ready;
  logic                                 input_skid_input_valid;
  logic [SPIKE_OUT_FIFO_DATA_WIDTH-1:0] input_skid_input_data;
  logic                                 input_skid_output_ready;
  logic                                 input_skid_output_valid;
  logic [SPIKE_OUT_FIFO_DATA_WIDTH-1:0] input_skid_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (SPIKE_OUT_FIFO_DATA_WIDTH),
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
  // Stage 1: Memory Mapping Lookup
  //============================================================================

  logic stage1_busy_q;
  logic stage1_output_ready, stage1_output_ready_q;
  logic stage1_output_valid, stage1_output_valid_q, stage1_output_valid_qq;
  logic [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] stage1_output_data, stage1_output_data_qq;

  assign input_skid_output_ready = stage1_output_ready && ~stage1_busy_q;

  logic              stage1_config_valid;
  mapping_ram_data_s stage1_mapping_ram_data;
  assign mapping_ram_read_en_q   = input_skid_output_valid;
  assign mapping_ram_read_addr_q = input_skid_output_data;
  assign stage1_mapping_ram_data = mapping_ram_data_out;
  assign stage1_config_valid = (stage1_mapping_ram_data.end_addr >= stage1_mapping_ram_data.start_addr);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      stage1_busy_q           <= 1'b0;
      stage1_output_ready_q   <= 1'b0;
      stage1_output_valid_q   <= 1'b0;
      stage1_output_valid_qq  <= 1'b0;
    end else begin
      stage1_output_ready_q  <= stage1_output_ready;
      if (!stage1_output_ready && stage1_output_ready_q) begin
        stage1_output_valid_q  <= 1'b0;
        stage1_output_valid_qq <= stage1_output_valid_q;
        stage1_output_data_qq  <= mapping_ram_data_out;
        stage1_busy_q <= 1'b1;
      end else if (stage1_output_ready && stage1_busy_q) begin
        stage1_busy_q <= 1'b0;
      end else if (stage1_output_ready) begin
        stage1_output_valid_q  <= input_skid_output_valid;
        stage1_output_valid_qq <= stage1_output_valid_q && stage1_config_valid;
        stage1_output_data_qq  <= mapping_ram_data_out;
      end
    end
  end

  assign stage1_output_valid = (stage1_busy_q) ? stage1_output_valid_qq : stage1_output_valid_q && stage1_config_valid;
  assign stage1_output_data  = (stage1_busy_q) ? stage1_output_data_qq  : mapping_ram_data_out;

  //============================================================================
  // Inter-stage Skid Buffer 1
  //============================================================================

  logic inter_skid1_output_ready;
  logic inter_skid1_output_valid;
  logic [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH-1:0] inter_skid1_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (URAM_MEMORY_MAPPING_RAM_DATA_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_inter_skid_buffer_1 (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (stage1_output_ready),
    .input_valid (stage1_output_valid),
    .input_data  (stage1_output_data),
    .output_ready(inter_skid1_output_ready),
    .output_valid(inter_skid1_output_valid),
    .output_data (inter_skid1_output_data)
  );

  mapping_ram_data_s stage2_mapping_ram_data;
  assign stage2_mapping_ram_data = inter_skid1_output_data;

  //============================================================================
  // Stage 2: Route Processing Pipeline
  //============================================================================

  logic route_proc_output_ready, route_proc_output_ready_q;
  logic route_proc_output_valid, route_proc_output_valid_q, route_proc_output_valid_qq;
  logic [URAM_ROUTES_ENTRY_WIDTH-1:0] route_proc_output_data, route_proc_output_data_qq;

  logic [URAM_MEMORY_MAPPING_ADDR_WIDTH-1:0]     current_end_addr_q;
  logic [URAM_MEMORY_MAPPING_LAST_IDX_WIDTH-1:0] current_last_idx_q;
  
  logic route_proc_busy_q;
  logic route_proc_active_q;
  logic [URAM_MEMORY_MAPPING_LAST_IDX_WIDTH-1:0] route_proc_entry_idx_q;
  logic [URAM_MEMORY_MAPPING_ADDR_WIDTH-1:0]     route_proc_line_idx_q;

  assign inter_skid1_output_ready = route_proc_output_ready && ~route_proc_active_q && ~route_proc_busy_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      route_proc_busy_q          <= 1'b0;
      route_proc_active_q        <= 1'b0;
      route_proc_output_valid_q  <= 1'b0;
      route_proc_output_valid_qq <= 1'b0;
      route_proc_entry_idx_q     <= '0;
      route_proc_line_idx_q      <= '0;
      current_end_addr_q         <= '0;
      current_last_idx_q         <= '0;
    end else begin
      route_proc_output_ready_q <= route_proc_output_ready;
      if (!route_proc_output_ready && route_proc_output_ready_q) begin
        route_proc_output_valid_q  <= 1'b0;
        route_proc_output_valid_qq <= route_proc_output_valid_q;
        route_proc_output_data_qq  <= routes_ram_data_out;
        route_proc_busy_q <= 1'b1;
      end else if (route_proc_output_ready && route_proc_busy_q) begin
        route_proc_busy_q <= 1'b0;
      end else if (route_proc_output_ready) begin
        route_proc_output_valid_q  <= inter_skid1_output_valid;
        route_proc_output_valid_qq <= route_proc_output_valid_q;
        route_proc_output_data_qq  <= routes_ram_data_out;

        if (route_proc_active_q) begin
          automatic logic is_last_line;
          automatic logic is_last_entry_in_line;
          automatic logic is_last_entry_in_last_line;

          localparam int ENTRIES_PER_LINE = URAM_ROUTES_DATA_WIDTH / URAM_ROUTES_ENTRY_WIDTH;
          localparam [URAM_MEMORY_MAPPING_LAST_IDX_WIDTH-1:0] ENTRY_IDX_HI = ENTRIES_PER_LINE - 1;

          is_last_entry_in_line       = (route_proc_entry_idx_q == ENTRY_IDX_HI);
          is_last_line                = (route_proc_line_idx_q  == current_end_addr_q);
          is_last_entry_in_last_line  = (is_last_line && (route_proc_entry_idx_q == current_last_idx_q));
          
          route_proc_output_valid_q  <= 1'b1;

          if (is_last_entry_in_last_line) begin
            route_proc_active_q <= 1'b0;
          end else begin
            if (is_last_line) begin
              if (route_proc_entry_idx_q < current_last_idx_q) begin 
                route_proc_entry_idx_q <= route_proc_entry_idx_q + 1;
              end
            end else begin
              if (is_last_entry_in_line) begin
                route_proc_entry_idx_q <= '0;
                route_proc_line_idx_q  <= route_proc_line_idx_q + 1;
              end else begin
                route_proc_entry_idx_q <= route_proc_entry_idx_q + 1;
              end
            end
          end

        end else begin // ~route_proc_active_q
          if (inter_skid1_output_valid && !((stage2_mapping_ram_data.start_addr == stage2_mapping_ram_data.end_addr) && (stage2_mapping_ram_data.last_idx == 0))) begin
            current_end_addr_q   <= stage2_mapping_ram_data.end_addr;
            current_last_idx_q   <= stage2_mapping_ram_data.last_idx;
            route_proc_active_q    <= 1'b1;
            route_proc_line_idx_q  <= stage2_mapping_ram_data.start_addr;
            route_proc_entry_idx_q <= '0 + 1;
          end
        end
      end
    end
  end

  assign routes_ram_read_en_q           = (!route_proc_active_q) ? inter_skid1_output_valid           : 1'b1;
  assign routes_ram_read_addr_q         = (!route_proc_active_q) ? stage2_mapping_ram_data.start_addr : route_proc_line_idx_q;
  assign routes_ram_read_entry_select_q = (!route_proc_active_q) ? '0                                 : route_proc_entry_idx_q;

  assign route_proc_output_valid = (route_proc_busy_q) ? route_proc_output_valid_qq : route_proc_output_valid_q;
  assign route_proc_output_data  = (route_proc_busy_q) ? route_proc_output_data_qq  : routes_ram_data_out;

  //============================================================================
  // Inter-stage Skid Buffer 2
  //============================================================================

  logic inter_skid2_output_ready;
  logic inter_skid2_output_valid;
  logic [URAM_ROUTES_ENTRY_WIDTH-1:0] inter_skid2_output_data;

  Pipeline_Skid_Buffer #(
    .WORD_WIDTH     (URAM_ROUTES_ENTRY_WIDTH),
    .CIRCULAR_BUFFER(0)
  ) u_inter_skid_buffer_2 (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (route_proc_output_ready),
    .input_valid (route_proc_output_valid),
    .input_data  (route_proc_output_data),
    .output_ready(inter_skid2_output_ready),
    .output_valid(inter_skid2_output_valid),
    .output_data (inter_skid2_output_data)
  );

  //============================================================================
  // Memory Instantiations
  //============================================================================

  DualPortRamSimple #(
    .VENDOR       (VENDOR),
    .ADDR_WIDTH   (URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH),
    .DATA_WIDTH   (URAM_MEMORY_MAPPING_RAM_DATA_WIDTH),
    .INIT_MEM_FILE(URAM_MEMORY_MAPPING_RAM_INIT_FILE)
  ) u_memory_mapping_ram (
    .clk_i       (clk_i),
    .read_en_i   (mapping_ram_read_en_q),
    .read_addr_i (mapping_ram_read_addr_q),
    .data_o      (mapping_ram_data_out),
    .write_en_i  (mapping_ram_init_write_en_d),
    .write_addr_i(mapping_ram_init_write_addr_d),
    .data_i      (mapping_ram_init_data_in_d),
    .sleep_i     (memory_mapping_ram_sleep),
    .awake_o     (memory_mapping_ram_awake)
  );

  Uram #(
    .VENDOR       (VENDOR),
    .DATA_WIDTH   (URAM_ROUTES_DATA_WIDTH),
    .ADDR_WIDTH   (URAM_ROUTES_ADDR_WIDTH),
    .ENTRY_WIDTH  (URAM_ROUTES_ENTRY_WIDTH),
    .BYTE_WIDTH   (URAM_ROUTES_BYTE_WIDTH),
    .INIT_MEM_FILE(URAM_ROUTES_INIT_FILE)
  ) u_routes_uram (
    .clk_i              (clk_i),
    .re_i               (routes_ram_read_en_q),
    .read_addr_i        (routes_ram_read_addr_q),
    .read_entry_select_i(routes_ram_read_entry_select_q),
    .data_o             (routes_ram_data_out),
    .we_i               (routes_ram_init_write_en_d),
    .write_addr_i       (routes_ram_init_write_addr_d),
    .data_i             (routes_ram_init_write_data_d),
    .sleep_i            (routes_uram_sleep),
    .awake_o            (routes_uram_awake)
  );

  //============================================================================
  // Signal Assignments
  //============================================================================

  assign all_memories_awake = memory_mapping_ram_awake && routes_uram_awake;

  assign pipeline_done_d = ~spiking_neuron_in_valid_i &&
                           ~input_skid_output_valid &&
                           ~stage1_output_valid &&
                           ~inter_skid1_output_valid &&
                           ~inter_skid2_output_valid &&
                           ~route_proc_output_valid_q &&
                           ~route_proc_output_valid_qq;
                          //  ~route_proc_active_q &&;
  assign done_o = ((state_q == IDLE) && pipeline_done_d);

  assign spiking_neuron_in_ready_o = (state_q == PROCESSING) && input_skid_input_ready;
  assign input_skid_input_valid    = (state_q == PROCESSING) && spiking_neuron_in_valid_i;
  assign input_skid_input_data     = spiking_neuron_in_data_i;
  assign inter_skid2_output_ready  = (state_q == PROCESSING) && spike_out_ready_i;
  assign spike_out_valid_o         = (state_q == PROCESSING) && inter_skid2_output_valid;
  assign spike_out_data_o          = inter_skid2_output_data;

  assign routes_ram_init_write_en_d   = (init_i == 1'b1) ? routes_ram_we_i : 1'b0;
  assign routes_ram_init_write_addr_d = routes_ram_addr_i;
  assign routes_ram_init_write_data_d = routes_ram_data_i;

  assign mapping_ram_init_write_en_d   = (init_i == 1'b1) ? memory_mapping_ram_we_i : 1'b0;
  assign mapping_ram_init_write_addr_d = memory_mapping_ram_addr_i;
  assign mapping_ram_init_data_in_d    = memory_mapping_ram_data_i;

endmodule
