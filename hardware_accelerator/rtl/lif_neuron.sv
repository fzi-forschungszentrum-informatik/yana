`timescale 1ns / 1ps

`include "global_params.vh"

module LifNeuron #(
    parameter EMIT_SPIKES = 1,
    parameter LEAK_STATES = 1,
    parameter NEURON_STATE_ADDR_WIDTH  = CORE_NEURON_ID_WIDTH_G,
    parameter NEURON_STATE_DATA_WIDTH  = NEURON_STATE_WIDTH_G,
    parameter NEURON_STATE_FRACTIONALS = NEURON_STATE_WIDTH_FRACTIONALS_G,
    parameter TIMESTEP_COUNTER_DATA_WIDTH = TIMESTEP_WIDTH_G,
    parameter WEIGHT_SUM_DATA_WIDTH  = CORE_WEIGHT_SUM_RAM_DATA_WIDTH_G - 1,
    parameter WEIGHT_SUM_FRACTIONALS = WEIGHT_WIDTH_FRACTIONALS_G,
    parameter TAU_MEM_INV_DATA_WIDTH                   = TAU_MEM_INV_WIDTH_G,
    parameter TAU_MEM_INV_FRACTIONALS                  = TAU_MEM_INV_WIDTH_FRACTIONALS_G,
    parameter SPIKE_THRESHOLD_WIDTH    = SPIKE_THRESHOLD_WIDTH_G,
    parameter SPIKE_THRESHOLD_DECIMALS = SPIKE_THRESHOLD_WIDTH_FRACTIONALS_G,
    parameter RESET_VALUE = RESET_VALUE_G,
    parameter RAM_LEAK_ADDR_WIDTH    = RAM_LEAK_ADDR_WIDTH_G,
    parameter RAM_LEAK_DATA_WIDTH    = RAM_LEAK_DATA_WIDTH_G,
    parameter RAM_LEAK_FRACTIONALS   = RAM_LEAK_WIDTH_FRACTIONALS_G,
    parameter RAM_LEAK_INIT_MEM_FILE = RAM_LEAK_INIT_FILE_G,
    parameter STATE_LOW_CLAMP_MODE = "MIN",
    parameter STATE_ROUND_MODE     = "FLOOR"
) (
    input  logic clk_i,
    input  logic rst_i,
    output logic done_o,

    output logic                                       in_ready_o,
    input  logic                                       in_valid_i,
    input  logic [NEURON_STATE_ADDR_WIDTH -1 : 0]      in_id_i,
    input  logic [NEURON_STATE_DATA_WIDTH -1 : 0]      in_state_i,
    input  logic signed [WEIGHT_SUM_DATA_WIDTH -1 : 0] in_weight_sum_i,
    input  logic [TIMESTEP_COUNTER_DATA_WIDTH -1 : 0]  in_timesteps_i,

    input  logic                                  out_ready_i,
    output logic                                  out_valid_o,
    output logic [NEURON_STATE_ADDR_WIDTH -1 : 0] out_id_o,
    output logic [NEURON_STATE_DATA_WIDTH -1 : 0] out_state_o,
    output logic                                  out_spike_o,

    input logic                               ram_leak_write_en_i,
    input logic [RAM_LEAK_ADDR_WIDTH - 1 : 0] ram_leak_addr_i,
    input logic [RAM_LEAK_DATA_WIDTH - 1 : 0] ram_leak_data_i,

    input logic [SPIKE_THRESHOLD_WIDTH-1:0]  spike_threshold_i,
    input logic [TAU_MEM_INV_DATA_WIDTH-1:0] tau_mem_inv_i
);

  localparam NEURON_STATE_U_WIDTH    = NEURON_STATE_DATA_WIDTH;
  localparam NEURON_STATE_U_DECIMALS = NEURON_STATE_FRACTIONALS;
  localparam STATE_U_LEAKED_WIDTH    = NEURON_STATE_U_WIDTH + RAM_LEAK_DATA_WIDTH;
  localparam STATE_U_LEAKED_DECIMALS = NEURON_STATE_U_DECIMALS + RAM_LEAK_FRACTIONALS;
  localparam INPUT_LEAKED_WIDTH      = WEIGHT_SUM_DATA_WIDTH + TAU_MEM_INV_DATA_WIDTH;
  localparam INPUT_LEAKED_DECIMALS   = WEIGHT_SUM_FRACTIONALS + TAU_MEM_INV_FRACTIONALS;

  localparam STATE_U_SUM_WIDTH = fixed_addition_result_width(
      STATE_U_LEAKED_WIDTH, STATE_U_LEAKED_DECIMALS, INPUT_LEAKED_WIDTH, INPUT_LEAKED_DECIMALS
  );
  localparam STATE_U_SUM_DECIMALS = fixed_addition_result_decimals(
      STATE_U_LEAKED_WIDTH, STATE_U_LEAKED_DECIMALS, INPUT_LEAKED_WIDTH, INPUT_LEAKED_DECIMALS
  );
  localparam STATE_U_SUM_ROUNDED_WIDTH = STATE_U_SUM_WIDTH - (STATE_U_SUM_DECIMALS - NEURON_STATE_U_DECIMALS);

  localparam SPIKE_THRESHOLD_SHIFT_DECIMALS = abs_diff(SPIKE_THRESHOLD_DECIMALS, STATE_U_SUM_DECIMALS);
  localparam SPIKE_THR_U_CMP_W              = STATE_U_SUM_WIDTH - SPIKE_THRESHOLD_SHIFT_DECIMALS;

  localparam signed NEURON_STATE_U_MIN = (STATE_LOW_CLAMP_MODE == "MIN") ? {1'b1, {(NEURON_STATE_U_WIDTH-1){1'b0}}} :  {(NEURON_STATE_U_WIDTH){1'b0}};
  localparam signed NEURON_STATE_U_MAX = {1'b0, {(NEURON_STATE_U_WIDTH - 1) {1'b1}}};

  initial begin
    if (STATE_U_SUM_DECIMALS < SPIKE_THRESHOLD_DECIMALS)
      $error(
          "SPIKE_THRESHOLD_DECIMALS (%0d) has to be > STATE_U_SUM_DECIMALS (%0d)", SPIKE_THRESHOLD_DECIMALS, STATE_U_SUM_DECIMALS
      );
  end

  //============================================================================
  // FSM State Declarations
  //============================================================================

  typedef enum logic [2:0] {
    IDLE,
    PROCESSING
  } master_state_e;

  master_state_e state_q, state_d;

  //============================================================================
  // Signal Declarations
  //============================================================================
  
  logic pipeline_done_d;

  logic input_skid_input_ready;
  logic input_skid_input_valid;
  logic [((NEURON_STATE_ADDR_WIDTH +
          NEURON_STATE_DATA_WIDTH +
          WEIGHT_SUM_DATA_WIDTH +
          TIMESTEP_COUNTER_DATA_WIDTH +
          TAU_MEM_INV_DATA_WIDTH +
          SPIKE_THRESHOLD_WIDTH)
          -1):0] input_skid_input_data;
  logic input_skid_output_ready;
  logic input_skid_output_valid;
  logic [((NEURON_STATE_ADDR_WIDTH +
          NEURON_STATE_DATA_WIDTH +
          WEIGHT_SUM_DATA_WIDTH +
          TIMESTEP_COUNTER_DATA_WIDTH + 
          TAU_MEM_INV_DATA_WIDTH +
          SPIKE_THRESHOLD_WIDTH)
          -1):0] input_skid_output_data;

  logic [TIMESTEP_COUNTER_DATA_WIDTH-1:0]  input_skid_output_timesteps;
  logic signed [WEIGHT_SUM_DATA_WIDTH-1:0] input_skid_output_weight_sum;
  logic [NEURON_STATE_DATA_WIDTH-1:0]      input_skid_output_neuron_state;
  logic [NEURON_STATE_ADDR_WIDTH-1:0]      input_skid_output_neuron_id;
  logic [TAU_MEM_INV_DATA_WIDTH-1:0]       input_skid_output_tau_mem_inv;
  logic [SPIKE_THRESHOLD_WIDTH-1:0]        input_skid_output_spike_threshold;

  logic stage1_output_ready;
  logic stage1_output_valid;
  logic [((NEURON_STATE_ADDR_WIDTH +
          INPUT_LEAKED_WIDTH +
          STATE_U_LEAKED_WIDTH +
          SPIKE_THRESHOLD_WIDTH)
          -1):0] stage1_output_data;

  logic signed [STATE_U_LEAKED_WIDTH - 1 : 0] stage1_leaked_state;
  logic signed [INPUT_LEAKED_WIDTH - 1 : 0]   stage1_leaked_input;

  logic inter_skid1_output_ready;
  logic inter_skid1_output_valid;
  logic [((NEURON_STATE_ADDR_WIDTH +
          INPUT_LEAKED_WIDTH +
          STATE_U_LEAKED_WIDTH +
          SPIKE_THRESHOLD_WIDTH)
          -1):0] inter_skid1_output_data;

  logic signed [STATE_U_LEAKED_WIDTH - 1 : 0] inter_skid1_output_leaked_state;
  logic signed [INPUT_LEAKED_WIDTH - 1 : 0]   inter_skid1_output_leaked_input;
  logic [NEURON_STATE_ADDR_WIDTH-1:0]         inter_skid1_output_neuron_id;
  logic [SPIKE_THRESHOLD_WIDTH-1:0]           inter_skid1_output_spike_threshold;

  logic stage2_output_ready;
  logic stage2_output_valid;
  logic [NEURON_STATE_ADDR_WIDTH +
         STATE_U_SUM_WIDTH +
         SPIKE_THRESHOLD_WIDTH
         -1: 0] stage2_output_data;

  logic signed [STATE_U_SUM_WIDTH - 1 : 0] stage2_state_u_new;

  logic inter_skid2_output_ready;
  logic inter_skid2_output_valid;
  logic [((NEURON_STATE_ADDR_WIDTH +
          STATE_U_SUM_WIDTH +
          SPIKE_THRESHOLD_WIDTH)
          -1):0] inter_skid2_output_data;
  
  logic signed [STATE_U_SUM_WIDTH - 1 : 0] inter_skid2_output_state_u_new;
  logic [NEURON_STATE_ADDR_WIDTH-1:0]      inter_skid2_output_neuron_id;
  logic [SPIKE_THRESHOLD_WIDTH-1:0]        inter_skid2_output_spike_threshold;

  logic stage3_output_ready;
  logic stage3_output_valid;
  logic [(NEURON_STATE_ADDR_WIDTH +
          1                       +
          NEURON_STATE_DATA_WIDTH
         -1): 0] stage3_output_data;

  logic                                  stage3_spike_out;
  logic [NEURON_STATE_DATA_WIDTH -1 : 0] stage3_out_state_out;
  
  logic signed [STATE_U_SUM_ROUNDED_WIDTH - 1 : 0] state_u_new_rounded; 

  logic inter_skid3_output_ready;
  logic inter_skid3_output_valid;
  logic [NEURON_STATE_ADDR_WIDTH +
         1 +
         NEURON_STATE_DATA_WIDTH
         -1: 0] inter_skid3_output_data;
  
  logic [NEURON_STATE_DATA_WIDTH-1:0] inter_skid3_output_neuron_state;
  logic                               inter_skid3_output_spike_out;
  logic [NEURON_STATE_ADDR_WIDTH-1:0] inter_skid3_output_neuron_id;

  logic [RAM_LEAK_ADDR_WIDTH - 1 : 0] lutram_leak_addr;
  logic [RAM_LEAK_DATA_WIDTH - 1 : 0] lutram_leak_factor;

  //============================================================================
  // Done Logic & Idle
  //============================================================================
  assign pipeline_done_d = ~in_valid_i &&
                           ~input_skid_output_valid &&
                           ~stage1_output_valid &&
                           ~inter_skid1_output_valid &&
                           ~stage2_output_valid &&
                           ~inter_skid2_output_valid &&
                           ~stage3_output_valid &&
                           ~inter_skid3_output_valid &&
                           ~out_valid_o;

  assign done_o = ((state_q == IDLE) && pipeline_done_d);

  //============================================================================
  // Data I/O control
  //============================================================================
  assign in_ready_o             = input_skid_input_ready;
  assign input_skid_input_valid = in_valid_i;
  assign input_skid_input_data  = {in_id_i, in_state_i, in_weight_sum_i, in_timesteps_i, tau_mem_inv_i,
                                   (EMIT_SPIKES ? spike_threshold_i : {SPIKE_THRESHOLD_WIDTH{1'b0}})};
  assign inter_skid3_output_ready = out_ready_i;
  assign out_valid_o              = inter_skid3_output_valid;
  assign out_id_o                 = inter_skid3_output_neuron_id;
  assign out_state_o              = inter_skid3_output_neuron_state;
  assign out_spike_o              = inter_skid3_output_spike_out;


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
        if (in_valid_i) begin
          state_d = PROCESSING;
        end
      end
      PROCESSING: begin
        if (pipeline_done_d) begin
          state_d = IDLE;
        end
      end
      default: begin
        state_d = IDLE;
      end
    endcase
  end

  //============================================================================
  // Input Skid Buffer
  //============================================================================
  Pipeline_Skid_Buffer #(
    .WORD_WIDTH((NEURON_STATE_ADDR_WIDTH +
                 NEURON_STATE_DATA_WIDTH +
                 WEIGHT_SUM_DATA_WIDTH +
                 TIMESTEP_COUNTER_DATA_WIDTH + 
                 TAU_MEM_INV_DATA_WIDTH +
                 SPIKE_THRESHOLD_WIDTH)),
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

  localparam INPUT_SKID_OUT_OFFSET_SPIKE_THRESHOLD = 0;
  localparam INPUT_SKID_OUT_OFFSET_TAU_MEM_INV     = INPUT_SKID_OUT_OFFSET_SPIKE_THRESHOLD + SPIKE_THRESHOLD_WIDTH;
  localparam INPUT_SKID_OUT_OFFSET_TS_LAST         = INPUT_SKID_OUT_OFFSET_TAU_MEM_INV + TAU_MEM_INV_DATA_WIDTH;
  localparam INPUT_SKID_OUT_OFFSET_WEIGHT_SUM      = INPUT_SKID_OUT_OFFSET_TS_LAST + TIMESTEP_COUNTER_DATA_WIDTH;
  localparam INPUT_SKID_OUT_OFFSET_NEURON_STATE    = INPUT_SKID_OUT_OFFSET_WEIGHT_SUM + WEIGHT_SUM_DATA_WIDTH;
  localparam INPUT_SKID_OUT_OFFSET_NEURON_ID       = INPUT_SKID_OUT_OFFSET_NEURON_STATE + NEURON_STATE_DATA_WIDTH;

  assign input_skid_output_spike_threshold = input_skid_output_data[INPUT_SKID_OUT_OFFSET_SPIKE_THRESHOLD +: SPIKE_THRESHOLD_WIDTH];
  assign input_skid_output_tau_mem_inv     = input_skid_output_data[INPUT_SKID_OUT_OFFSET_TAU_MEM_INV     +: TAU_MEM_INV_DATA_WIDTH];
  assign input_skid_output_timesteps       = input_skid_output_data[INPUT_SKID_OUT_OFFSET_TS_LAST         +: TIMESTEP_COUNTER_DATA_WIDTH];
  assign input_skid_output_weight_sum      = input_skid_output_data[INPUT_SKID_OUT_OFFSET_WEIGHT_SUM      +: WEIGHT_SUM_DATA_WIDTH];
  assign input_skid_output_neuron_state    = input_skid_output_data[INPUT_SKID_OUT_OFFSET_NEURON_STATE    +: NEURON_STATE_DATA_WIDTH];
  assign input_skid_output_neuron_id       = input_skid_output_data[INPUT_SKID_OUT_OFFSET_NEURON_ID       +: NEURON_STATE_ADDR_WIDTH];

  //============================================================================
  // Stage 1: Leakage Calculations
  //============================================================================
  assign input_skid_output_ready = stage1_output_ready;
  assign stage1_output_valid     = input_skid_output_valid;

  assign lutram_leak_addr = ram_leak_write_en_i ? ram_leak_addr_i : input_skid_output_timesteps;

  generate
    if (LEAK_STATES == 0) begin
      always_comb begin
        stage1_leaked_input = {input_skid_output_weight_sum, {TAU_MEM_INV_FRACTIONALS {1'b0}}}; 
        stage1_leaked_state = {input_skid_output_neuron_state, {RAM_LEAK_FRACTIONALS {1'b0}}}; 
        stage1_output_data  = {input_skid_output_neuron_id, stage1_leaked_input, stage1_leaked_state,
                               input_skid_output_spike_threshold};
      end
    end else begin
      always_comb begin
        stage1_leaked_input = input_skid_output_weight_sum * $signed({1'b0, input_skid_output_tau_mem_inv}); 
        if (input_skid_output_timesteps == 0) begin
          stage1_leaked_state = {input_skid_output_neuron_state, {RAM_LEAK_FRACTIONALS {1'b0}}}; 
        end else if (input_skid_output_timesteps < (2 ** RAM_LEAK_ADDR_WIDTH)) begin
          stage1_leaked_state = $signed(input_skid_output_neuron_state) * $signed({1'b0, lutram_leak_factor}); 
        end else begin
          stage1_leaked_state = 0;
        end
        stage1_output_data  = {input_skid_output_neuron_id, stage1_leaked_input, stage1_leaked_state,
                               input_skid_output_spike_threshold};
      end
    end
  endgenerate

  //============================================================================
  // Inter-stage Skid Buffer 1
  //============================================================================
  Pipeline_Skid_Buffer #(
    .WORD_WIDTH((NEURON_STATE_ADDR_WIDTH +
                 INPUT_LEAKED_WIDTH +
                 STATE_U_LEAKED_WIDTH +
                 SPIKE_THRESHOLD_WIDTH)),
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

  localparam SKID1_OUT_OFFSET_SPIKE_THRESHOLD  = 0;
  localparam SKID1_OUT_OFFSET_LEAKED_STATE     = SKID1_OUT_OFFSET_SPIKE_THRESHOLD + SPIKE_THRESHOLD_WIDTH;
  localparam SKID1_OUT_OFFSET_LEAKED_INPUT     = SKID1_OUT_OFFSET_LEAKED_STATE + STATE_U_LEAKED_WIDTH;
  localparam SKID1_OUT_OFFSET_NEURON_ID        = SKID1_OUT_OFFSET_LEAKED_INPUT + INPUT_LEAKED_WIDTH;

  assign inter_skid1_output_spike_threshold = inter_skid1_output_data[SKID1_OUT_OFFSET_SPIKE_THRESHOLD +: SPIKE_THRESHOLD_WIDTH];
  assign inter_skid1_output_leaked_state    = inter_skid1_output_data[SKID1_OUT_OFFSET_LEAKED_STATE    +: STATE_U_LEAKED_WIDTH];
  assign inter_skid1_output_leaked_input    = inter_skid1_output_data[SKID1_OUT_OFFSET_LEAKED_INPUT    +: INPUT_LEAKED_WIDTH];
  assign inter_skid1_output_neuron_id       = inter_skid1_output_data[SKID1_OUT_OFFSET_NEURON_ID       +: NEURON_STATE_ADDR_WIDTH];

  //============================================================================
  // Stage 2: Addition
  //============================================================================
  assign inter_skid1_output_ready = stage2_output_ready;
  assign stage2_output_valid = inter_skid1_output_valid;

  generate
    if (STATE_U_LEAKED_DECIMALS > INPUT_LEAKED_DECIMALS) begin
      always_comb begin
        stage2_state_u_new = inter_skid1_output_leaked_state +
                             $signed({inter_skid1_output_leaked_input, {(STATE_U_LEAKED_DECIMALS - INPUT_LEAKED_DECIMALS){1'b0}}});
        stage2_output_data = {inter_skid1_output_neuron_id, stage2_state_u_new, inter_skid1_output_spike_threshold};
      end
    end else begin
      always_comb begin
        stage2_state_u_new = inter_skid1_output_leaked_input +
                            $signed({inter_skid1_output_leaked_state, {(INPUT_LEAKED_DECIMALS - STATE_U_LEAKED_DECIMALS){1'b0}}});
        stage2_output_data = {inter_skid1_output_neuron_id, stage2_state_u_new, inter_skid1_output_spike_threshold};
      end
    end
  endgenerate

  //============================================================================
  // Inter-stage Skid Buffer 2
  //============================================================================
  Pipeline_Skid_Buffer #(
    .WORD_WIDTH((NEURON_STATE_ADDR_WIDTH +
                 STATE_U_SUM_WIDTH +
                 SPIKE_THRESHOLD_WIDTH)),
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

  localparam SKID2_OUT_OFFSET_SPIKE_THRESHOLD = 0;
  localparam SKID2_OUT_OFFSET_STATE_U_NEW     = SKID2_OUT_OFFSET_SPIKE_THRESHOLD + SPIKE_THRESHOLD_WIDTH;
  localparam SKID2_OUT_OFFSET_NEURON_ID       = SKID2_OUT_OFFSET_STATE_U_NEW + STATE_U_SUM_WIDTH;

  assign inter_skid2_output_spike_threshold = inter_skid2_output_data[SKID2_OUT_OFFSET_SPIKE_THRESHOLD +: SPIKE_THRESHOLD_WIDTH];
  assign inter_skid2_output_state_u_new     = inter_skid2_output_data[SKID2_OUT_OFFSET_STATE_U_NEW     +: STATE_U_SUM_WIDTH];
  assign inter_skid2_output_neuron_id       = inter_skid2_output_data[SKID2_OUT_OFFSET_NEURON_ID       +: NEURON_STATE_ADDR_WIDTH];

  //============================================================================
  // Stage 3: Spike Threshold Check & Rounding
  //============================================================================
  
  generate
    if (STATE_ROUND_MODE == "CONVERGENT") begin
      RoundConvergent #(
          .INPUT_WIDTH(STATE_U_SUM_WIDTH),
          .OUTPUT_WIDTH(STATE_U_SUM_ROUNDED_WIDTH)
      ) round_convergent_1 (
          .data_i(inter_skid2_output_state_u_new),
          .data_o(state_u_new_rounded)
      );
    end else if (STATE_ROUND_MODE == "FLOOR") begin
      assign state_u_new_rounded = $signed(inter_skid2_output_state_u_new[STATE_U_SUM_WIDTH - 1 : STATE_U_SUM_DECIMALS - NEURON_STATE_U_DECIMALS]); 
    end else begin
      initial $fatal(1, "STATE_ROUND_MODE unsupported mode");
    end
  endgenerate

  assign inter_skid2_output_ready = stage3_output_ready;
  assign stage3_output_valid = inter_skid2_output_valid;

  generate
    if (EMIT_SPIKES) begin
      always_comb begin
        stage3_spike_out = 0;
        stage3_out_state_out = RESET_VALUE;
        if (state_u_new_rounded < NEURON_STATE_U_MIN) begin 
            stage3_out_state_out = NEURON_STATE_U_MIN;
        end else begin
          if ( $signed(
                  inter_skid2_output_state_u_new[STATE_U_SUM_WIDTH-1:SPIKE_THRESHOLD_SHIFT_DECIMALS]
              ) >=
                  $signed(SPIKE_THR_U_CMP_W'($unsigned(inter_skid2_output_spike_threshold)))
              ) begin
            stage3_spike_out     = 1;
            stage3_out_state_out = RESET_VALUE;
          end else begin
            stage3_out_state_out = state_u_new_rounded;
          end
        end
        
        stage3_output_data = {inter_skid2_output_neuron_id, stage3_spike_out, stage3_out_state_out};
      end
    end else begin
      always_comb begin
        stage3_spike_out = 0;
        stage3_out_state_out = RESET_VALUE;
        if (state_u_new_rounded < NEURON_STATE_U_MIN) begin 
            stage3_out_state_out = NEURON_STATE_U_MIN;
        end else begin
          if (state_u_new_rounded > NEURON_STATE_U_MAX) begin
            stage3_out_state_out = NEURON_STATE_U_MAX;
          end else begin
            stage3_out_state_out = state_u_new_rounded;
          end
        end
        
        stage3_output_data  = {inter_skid2_output_neuron_id, stage3_spike_out, stage3_out_state_out};
      end
    end
  endgenerate

  //============================================================================
  // Inter-stage Skid Buffer 3
  //============================================================================
  Pipeline_Skid_Buffer #(
    .WORD_WIDTH((NEURON_STATE_ADDR_WIDTH +
                 1 +
                 NEURON_STATE_DATA_WIDTH)),
    .CIRCULAR_BUFFER(0)
  ) u_inter_skid_buffer_3 (
    .clock       (clk_i),
    .clear       (rst_i),
    .input_ready (stage3_output_ready),
    .input_valid (stage3_output_valid),
    .input_data  (stage3_output_data),
    .output_ready(inter_skid3_output_ready),
    .output_valid(inter_skid3_output_valid),
    .output_data (inter_skid3_output_data)
  );

  localparam SKID3_OUT_OFFSET_NEURON_STATE = 0;
  localparam SKID3_OUT_OFFSET_SPIKE_OUT    = SKID3_OUT_OFFSET_NEURON_STATE + NEURON_STATE_DATA_WIDTH;
  localparam SKID3_OUT_OFFSET_NEURON_ID    = SKID3_OUT_OFFSET_SPIKE_OUT + 1;

  assign inter_skid3_output_neuron_state = inter_skid3_output_data[SKID3_OUT_OFFSET_NEURON_STATE +: NEURON_STATE_DATA_WIDTH];
  assign inter_skid3_output_spike_out    = inter_skid3_output_data[SKID3_OUT_OFFSET_SPIKE_OUT    +: 1];
  assign inter_skid3_output_neuron_id    = inter_skid3_output_data[SKID3_OUT_OFFSET_NEURON_ID    +: NEURON_STATE_ADDR_WIDTH];


  //============================================================================
  // Memory Instantiations
  //============================================================================

  generate
    if (LEAK_STATES) begin
      SinglePortLutram #(
          .RAM_WIDTH(RAM_LEAK_DATA_WIDTH),
          .RAM_ADDR_BITS(RAM_LEAK_ADDR_WIDTH),
          .INIT_MEM_FILE(RAM_LEAK_INIT_MEM_FILE)
      ) RAM_inst (
          .clkw    (clk_i),
          .we_i    (ram_leak_write_en_i),
          .data_in (ram_leak_data_i),
          .addr_i  (lutram_leak_addr),
          .data_out(lutram_leak_factor)
      );
    end else begin
      assign lutram_leak_factor = {RAM_LEAK_DATA_WIDTH{1'b0}};
    end
  endgenerate

endmodule
