
`timescale 1ns / 1ps

`include "global_params.vh"

module Synapse #(
    parameter VENDOR = VENDOR_G,

    parameter INPUT_DATA_NEURON_WIDTH  = CORE_NEURON_ID_WIDTH_G,
    parameter INPUT_DATA_SYNAPSE_WIDTH = CORE_WEIGHT_ID_WIDTH_G,
    parameter INPUT_DATA_WIDTH         = INPUT_DATA_SYNAPSE_WIDTH + INPUT_DATA_NEURON_WIDTH,

    parameter HOT_NEURON_FIFO_DATA_WIDTH = INPUT_DATA_NEURON_WIDTH,

    parameter WEIGHT_SUM_RAM_DATA_WIDTH = CORE_WEIGHT_SUM_RAM_DATA_WIDTH_G,
    parameter WEIGHT_SUM_RAM_ADDR_WIDTH = CORE_WEIGHT_SUM_RAM_ADDR_WIDTH_G,

    parameter WEIGHT_RAM_ADDR_WIDTH   = CORE_WEIGHT_RAM_ADDR_WIDTH_G,
    parameter WEIGHT_RAM_DATA_WIDTH   = CORE_WEIGHT_RAM_DATA_WIDTH_G,
    parameter WEIGHT_RAM_WEIGHT_WIDTH = WEIGHT_WIDTH_G,
    parameter WEIGHT_RAM_INIT_FILE    = WEIGHT_RAM_INIT_FILE_HIDDEN_G,

    parameter CYCLES_RAISE_SLEEP = CYCLES_RAISE_SLEEP_G
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic enable_i,
    input  logic init_i,
    output logic done_o,

    output logic                        spike_in_ready_o,
    input  logic                        spike_in_valid_i,
    input  logic [INPUT_DATA_WIDTH-1:0] spike_in_data_i,

    input  logic                                  hot_neuron_out_ready_i,
    output logic                                  hot_neuron_out_valid_o,
    output logic [HOT_NEURON_FIFO_DATA_WIDTH-1:0] hot_neuron_out_data_o,

    output logic                                 weight_sum_ram_we_o,
    output logic [WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_ram_waddr_o,
    output logic [WEIGHT_SUM_RAM_DATA_WIDTH-1:0] weight_sum_ram_data_o,

    output logic                                 weight_sum_ram_re_o,
    output logic [WEIGHT_SUM_RAM_ADDR_WIDTH-1:0] weight_sum_ram_raddr_o,
    input  logic [WEIGHT_SUM_RAM_DATA_WIDTH-1:0] weight_sum_ram_data_i,

    input logic                             weight_ram_we_i,
    input logic [WEIGHT_RAM_ADDR_WIDTH-1:0] weight_ram_addr_i,
    input logic [WEIGHT_RAM_DATA_WIDTH-1:0] weight_ram_data_i
);

  //============================================================================
  // FSM State Declarations
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

  //============================================================================
  // Signal Declarations
  //============================================================================

  logic weight_ram_sleep;
  logic weight_ram_awake;
  logic all_memories_awake;
  logic [$clog2(CYCLES_RAISE_SLEEP+1)-1:0] sleep_counter_q, sleep_counter_d;

  localparam WEIGHT_RAM_ENTRY_SELECT_WIDTH = $clog2(WEIGHT_RAM_DATA_WIDTH/WEIGHT_RAM_WEIGHT_WIDTH);
  logic                                     weight_ram_read_enable_q;
  logic [WEIGHT_RAM_ADDR_WIDTH-1:0]         weight_ram_read_addr_q;
  logic [WEIGHT_RAM_ENTRY_SELECT_WIDTH-1:0] weight_ram_read_sel_q;
  logic [WEIGHT_RAM_WEIGHT_WIDTH-1:0]       weight_ram_read_data_q;

  logic                                     weight_ram_init_write_enable_d;
  logic [WEIGHT_RAM_ADDR_WIDTH-1:0]         weight_ram_init_write_addr_d;
  logic [WEIGHT_RAM_DATA_WIDTH-1:0]         weight_ram_init_write_data_d;

  logic [WEIGHT_SUM_RAM_DATA_WIDTH-2:0] weight_sum_q_0;
  logic [WEIGHT_SUM_RAM_DATA_WIDTH-2:0] weight_sum_q_1;
  logic [WEIGHT_SUM_RAM_DATA_WIDTH-2:0] weight_sum_q_2;

  logic [4:0] pipeline_exec_q;
  logic [INPUT_DATA_NEURON_WIDTH-1:0] neuron_addr_0_q;
  logic [INPUT_DATA_NEURON_WIDTH-1:0] neuron_addr_1_q;
  logic [INPUT_DATA_NEURON_WIDTH-1:0] neuron_addr_2_q;
  logic [INPUT_DATA_NEURON_WIDTH-1:0] neuron_addr_3_q;
  logic [INPUT_DATA_NEURON_WIDTH-1:0] neuron_addr_4_q;

  logic pipeline_done_d;

  //============================================================================
  // Signal Assignments
  //============================================================================

  assign all_memories_awake = weight_ram_awake;

  assign pipeline_done_d =  ~spike_in_valid_i && ~|pipeline_exec_q[2:0] && ~weight_sum_ram_we_o;
  // assign done_o = ((state_q == IDLE)         && pipeline_done_d) ||
  //                 ((state_q == INITIALIZING) && weight_ram_init_done_d);
  assign done_o = ((state_q == IDLE) && pipeline_done_d);

  assign spike_in_ready_o = (state_q == PROCESSING);

  assign weight_ram_init_write_enable_d = (init_i == 1'b1) ? weight_ram_we_i : 1'b0;
  assign weight_ram_init_write_addr_d   = weight_ram_addr_i;
  assign weight_ram_init_write_data_d   = weight_ram_data_i;

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
    weight_ram_sleep = 1'b0;

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
            weight_ram_sleep = 1'b1;
            sleep_state_d = SLEEPING;
          end else begin
            sleep_counter_d = sleep_counter_q - 1;
          end
        end
        SLEEPING: begin
          weight_ram_sleep = 1'b1;
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
  // Main Datapath Logic
  //============================================================================

  pkt_payload_event_data_s spike_in_data;
  assign spike_in_data = pkt_payload_event_data_s'(spike_in_data_i);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      pipeline_exec_q          <= '0;
      hot_neuron_out_valid_o   <= 1'b0;
      weight_sum_ram_we_o      <= 1'b0;
      weight_sum_ram_re_o      <= 1'b0;
      weight_ram_read_enable_q <= 1'b0;
      weight_ram_read_sel_q    <= '0;
    end else begin
      weight_ram_read_enable_q <= 1'b0;
      weight_sum_ram_re_o      <= 1'b0;
      weight_sum_ram_we_o      <= 1'b0;
      hot_neuron_out_valid_o   <= 1'b0;
      
      case (state_q)
        PROCESSING: begin
          neuron_addr_1_q <= neuron_addr_0_q;
          neuron_addr_2_q <= neuron_addr_1_q;
          neuron_addr_3_q <= neuron_addr_2_q;
          neuron_addr_4_q <= neuron_addr_3_q;
          weight_sum_q_1  <= weight_sum_q_0;
          weight_sum_q_2  <= weight_sum_q_1;

          if (spike_in_valid_i) begin
            pipeline_exec_q <= {pipeline_exec_q[3:0], 1'b1};
            neuron_addr_0_q <= spike_in_data.neuron_id;

            weight_ram_read_addr_q   <= spike_in_data.synapse_id[INPUT_DATA_SYNAPSE_WIDTH-1:WEIGHT_RAM_ENTRY_SELECT_WIDTH];
            weight_ram_read_sel_q    <= spike_in_data.synapse_id[WEIGHT_RAM_ENTRY_SELECT_WIDTH-1:0];
            weight_ram_read_enable_q <= 1'b1;

            weight_sum_ram_raddr_o <= spike_in_data.neuron_id;
            if ((spike_in_data.neuron_id == neuron_addr_2_q) && (pipeline_exec_q[2] == 1'b1)) begin
            end else begin
              weight_sum_ram_re_o <= 1'b1;
            end
          end else begin
            pipeline_exec_q <= {pipeline_exec_q[3:0], 1'b0};
            neuron_addr_0_q <= '0;
          end

          if (pipeline_exec_q[1]) begin
            if ((neuron_addr_1_q == neuron_addr_2_q) && (pipeline_exec_q[2] == 1'b1)) begin
              weight_sum_q_0 <= $signed(weight_sum_q_0) + $signed(weight_ram_read_data_q);
            end else if ((neuron_addr_1_q == neuron_addr_3_q) && (pipeline_exec_q[3] == 1'b1)) begin
              weight_sum_q_0 <= $signed(weight_sum_q_1) + $signed(weight_ram_read_data_q);
            end else if ((neuron_addr_1_q == neuron_addr_4_q) && (pipeline_exec_q[4] == 1'b1)) begin
              weight_sum_q_0 <= $signed(weight_sum_q_2) + $signed(weight_ram_read_data_q);
            end else begin
              weight_sum_q_0 <= $signed(weight_sum_ram_data_i[WEIGHT_SUM_RAM_DATA_WIDTH-1 : 1]) +
                              $signed(weight_ram_read_data_q);
            end
            if (
              ~weight_sum_ram_data_i[0] 
              && ((neuron_addr_1_q != neuron_addr_2_q) || (pipeline_exec_q[2] == 0))
              && ((neuron_addr_1_q != neuron_addr_3_q) || (pipeline_exec_q[3] == 0))
              && ((neuron_addr_1_q != neuron_addr_4_q) || (pipeline_exec_q[4] == 0))
            ) begin
                hot_neuron_out_data_o  <= neuron_addr_1_q;
                hot_neuron_out_valid_o <= 1'b1;
            end
          end

          if (pipeline_exec_q[2]) begin
            weight_sum_ram_data_o <= {weight_sum_q_0, 1'b1};
            weight_sum_ram_waddr_o <= neuron_addr_2_q;
            // FIXME: should this really be checking spike_in_data_i instead of one of the weight_sum_q_*?
            if (spike_in_valid_i && spike_in_data.neuron_id == neuron_addr_2_q) begin
            end else begin
              weight_sum_ram_we_o <= 1'b1;
            end
          end
        end

        INITIALIZING: begin
        end

        IDLE: begin
        end

        default: begin
        end
      endcase
    end
  end

  //============================================================================
  // Memory instantiations
  //============================================================================

  Uram #(
      .VENDOR       (VENDOR),
      .ADDR_WIDTH   (WEIGHT_RAM_ADDR_WIDTH),
      .DATA_WIDTH   (WEIGHT_RAM_DATA_WIDTH),
      .ENTRY_WIDTH  (WEIGHT_RAM_WEIGHT_WIDTH),
      .BYTE_WIDTH   (),
      .INIT_MEM_FILE(WEIGHT_RAM_INIT_FILE)
  ) u_weight_ram (
      .clk_i              (clk_i),
      .we_i               (weight_ram_init_write_enable_d),
      .write_addr_i       (weight_ram_init_write_addr_d),
      .data_i             (weight_ram_init_write_data_d),
      .re_i               (weight_ram_read_enable_q),
      .read_addr_i        (weight_ram_read_addr_q),
      .read_entry_select_i(weight_ram_read_sel_q),
      .data_o             (weight_ram_read_data_q),
      .sleep_i            (weight_ram_sleep),
      .awake_o            (weight_ram_awake)
  );

endmodule
