`timescale 1ns / 1ps

`include "global_params.vh"


module lif_neuron #(
    parameter EMIT_SPIKES = 1,  // If 0, no spikes are created
    parameter LEAK_STATES = 1,  // If 0, no leak is applied to the neuron state

    parameter NEURON_STATE_ADDR_WIDTH = 10,
    parameter NEURON_STATE_DATA_WIDTH = 24,
    parameter NEURON_STATE_DECIMALS   = 16,

    parameter TIMESTEP_COUNTER_DATA_WIDTH = 8,

    parameter WEIGHT_SUM_DATA_WIDTH = 15,
    parameter WEIGHT_SUM_DECIMALS   = 8,

    parameter TAU_MEM_INV_DATA_WIDTH = TAU_MEM_INV_DATA_WIDTH_G,
    parameter TAU_MEM_INV_DECIMALS   = TAU_MEM_INV_DECIMALS_G,
    parameter [TAU_MEM_INV_DATA_WIDTH-1:0] TAU_MEM_INV = TAU_MEM_INV_G,

    parameter SPIKE_THRESHOLD_DECIMALS = SPIKE_THRESHOLD_DECIMALS_G,
    parameter integer SPIKE_THRESHOLD  = SPIKE_THRESHOLD_G,

    parameter RESET_VALUE = RESET_VALUE_G,

    parameter RAM_LEAK_ADDR_WIDTH    = RAM_LEAK_ADDR_WIDTH_G,
    parameter RAM_LEAK_DATA_WIDTH    = RAM_LEAK_DATA_WIDTH_G,
    parameter RAM_LEAK_DECIMALS      = RAM_LEAK_DECIMALS_G,
    parameter RAM_LEAK_INIT_MEM_FILE = RAM_LEAK_INIT_MEM_FILE_G,

    parameter STATE_LOW_CLAMP_MODE = "MIN",   //"MIN", "ZERO"
    parameter STATE_ROUND_MODE     = "FLOOR", //"CONVERGENT", "FLOOR"

    parameter MULT_USE_DSP = "auto"
) (
    input  clk_i,
    input  rst_i,
    output idle_o,

    input                                       input_valid_i,
    input [NEURON_STATE_ADDR_WIDTH -1 : 0]      neuron_id_i,
    input [NEURON_STATE_DATA_WIDTH -1 : 0]      neuron_state_i, // represents u(t)
    input signed [WEIGHT_SUM_DATA_WIDTH -1 : 0] weight_sum_i,   // represents I(t)
    input [TIMESTEP_COUNTER_DATA_WIDTH -1 : 0]  timesteps_since_last_activation_i,  // represents n

    output reg                                  output_valid_o,
    output reg [NEURON_STATE_ADDR_WIDTH -1 : 0] neuron_id_o,
    output reg [NEURON_STATE_DATA_WIDTH -1 : 0] neuron_state_o, // represents u(t+n)
    output reg                                  spike_out_o,    // represents u(t+n) > SPIKE_THRESHOLD

    input                                       ram_leak_write_en_i,
    input [RAM_LEAK_ADDR_WIDTH - 1 : 0]         ram_leak_addr_i,
    input [RAM_LEAK_DATA_WIDTH - 1 : 0]         ram_leak_data_i,

    input [TAU_MEM_INV_DATA_WIDTH-1:0]          tau_mem_inv
);
  // Naming Conventions
  // - state_u means the voltage part of the state

  // Define voltage part of neuron state. For LIF this equals the whole state but for other neurons it can differ
  localparam NEURON_STATE_U_WIDTH    = NEURON_STATE_DATA_WIDTH;
  localparam NEURON_STATE_U_DECIMALS = NEURON_STATE_DECIMALS;

  // Parameter calculations to handle fixed point numbers with different amounts of decimals
  localparam STATE_U_LEAKED_WIDTH    = NEURON_STATE_U_WIDTH + RAM_LEAK_DATA_WIDTH;
  localparam STATE_U_LEAKED_DECIMALS = NEURON_STATE_U_DECIMALS + RAM_LEAK_DECIMALS;
  localparam INPUT_LEAKED_WIDTH      = WEIGHT_SUM_DATA_WIDTH + TAU_MEM_INV_DATA_WIDTH;
  localparam INPUT_LEAKED_DECIMALS   = WEIGHT_SUM_DECIMALS + TAU_MEM_INV_DECIMALS;

  localparam STATE_U_SUM_WIDTH = fixed_addition_result_width(
      STATE_U_LEAKED_WIDTH, STATE_U_LEAKED_DECIMALS, INPUT_LEAKED_WIDTH, INPUT_LEAKED_DECIMALS
  );
  localparam STATE_U_SUM_DECIMALS = fixed_addition_result_decimals(
      STATE_U_LEAKED_WIDTH, STATE_U_LEAKED_DECIMALS, INPUT_LEAKED_WIDTH, INPUT_LEAKED_DECIMALS
  );
  localparam STATE_U_SUM_ROUNDED_WIDTH = STATE_U_SUM_WIDTH - (STATE_U_SUM_DECIMALS - NEURON_STATE_U_DECIMALS); // Size is NEURON_STATE_U_WIDTH + 1 to catch overflows

  localparam SPIKE_THRESHOLD_SHIFT_DECIMALS = abs_diff(SPIKE_THRESHOLD_DECIMALS, STATE_U_SUM_DECIMALS);

  localparam signed NEURON_STATE_U_MIN = (STATE_LOW_CLAMP_MODE == "MIN") ? {1'b1, {(NEURON_STATE_U_WIDTH-1){1'b0}}} :  {(NEURON_STATE_U_WIDTH){1'b0}};
  localparam signed NEURON_STATE_U_MAX = {1'b0, {(NEURON_STATE_U_WIDTH - 1) {1'b1}}};


  initial begin
    if (STATE_U_SUM_DECIMALS < SPIKE_THRESHOLD_DECIMALS)
      $error(
          "SPIKE_THRESHOLD_DECIMALS (%0d) has to be > STATE_U_SUM_DECIMALS (%0d)", SPIKE_THRESHOLD_DECIMALS, STATE_U_SUM_DECIMALS
      );

    if (SPIKE_THRESHOLD / (2.0 ** SPIKE_THRESHOLD_DECIMALS) > NEURON_STATE_U_MAX / (2.0 ** NEURON_STATE_U_DECIMALS))
      $error(
          "SPIKE_THRESHOLD (%f) has to be <= NEURON_STATE_U_MAX (%f)",
          SPIKE_THRESHOLD / (2.0 ** SPIKE_THRESHOLD_DECIMALS),
          NEURON_STATE_U_MAX / (2.0 ** NEURON_STATE_U_DECIMALS)
      );
  end


  // Unpack input state and pack output state (extract/combine all state signals from/to a single state vector).
  // LIF only has a single state signal (voltage), but for other neurons it can differ
  wire signed [NEURON_STATE_U_WIDTH - 1 : 0] neuron_state_u_in;
  reg  signed [NEURON_STATE_U_WIDTH - 1 : 0] neuron_state_u_out;
  assign neuron_state_u_in = $signed(neuron_state_i);
  assign neuron_state_o    = neuron_state_u_out;

  // LUTRAM registers
  wire [RAM_LEAK_DATA_WIDTH - 1 : 0] leak_factor;

  // Pipeline registers
  reg [1:0] pipeline_exec;
  reg [NEURON_STATE_ADDR_WIDTH - 1 : 0] neuron_id_q, neuron_id_q2;

  (* use_dsp=MULT_USE_DSP *) reg signed [STATE_U_LEAKED_WIDTH - 1 : 0] state_u_leaked;
  (* use_dsp=MULT_USE_DSP *) reg signed [INPUT_LEAKED_WIDTH - 1 : 0]   input_leaked;

  reg  signed [STATE_U_SUM_WIDTH - 1 : 0]         state_u_new;
  wire signed [STATE_U_SUM_ROUNDED_WIDTH - 1 : 0] state_u_new_rounded; // Rounded state_u matching our Norse implementation

  // Module is idle if pipeline is not executed and in and outport are not busy
  assign idle_o = ~(input_valid_i | (|pipeline_exec) | output_valid_o);


  // Pipeline Step 1: Trigger pipeline if input is valid and calculate leak
  always @(posedge clk_i) begin
    if (rst_i) begin
      pipeline_exec <= 2'b00;
    end else if (input_valid_i) begin
      input_leaked <= weight_sum_i * $signed({1'b0, tau_mem_inv});

      if (
        timesteps_since_last_activation_i == 0 // During the very first timestep, no time has passed yet -> no leak
        | LEAK_STATES != 1                     // If leak is disabled for this neuron
      ) begin
        // No leak, just shift to match fixed point format
        state_u_leaked <= {neuron_state_u_in, {RAM_LEAK_DECIMALS {1'b0}}};
      end else if (timesteps_since_last_activation_i < (2 ** RAM_LEAK_ADDR_WIDTH)) begin
        // Normal operation
        state_u_leaked <= neuron_state_u_in * $signed({1'b0, leak_factor});
      end else begin
        // Passed time is greater than LUTRAM size -> state is 0
        state_u_leaked <= 0;
      end

      neuron_id_q <= neuron_id_i;
      pipeline_exec   <= {pipeline_exec[0], 1'b1};
    end else begin
      pipeline_exec   <= {pipeline_exec[0], 1'b0};
    end
  end

  // Pipeline Step 2: Add the two multiplication results based on fixed point logic
  always @(posedge clk_i) begin
    if (rst_i) begin
      neuron_id_q2 <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
    end else if (pipeline_exec[0]) begin
      neuron_id_q2 <= neuron_id_q;

      // Shifts need to be done because of fixed point arithmetic
      if (STATE_U_LEAKED_DECIMALS > INPUT_LEAKED_DECIMALS) begin
        state_u_new <= state_u_leaked +
            $signed({input_leaked, {(STATE_U_LEAKED_DECIMALS - INPUT_LEAKED_DECIMALS) {1'b0}}});
      end else begin
        state_u_new <= input_leaked +
            $signed({state_u_leaked, {(INPUT_LEAKED_DECIMALS - STATE_U_LEAKED_DECIMALS) {1'b0}}});
      end
    end
  end

  // Pipeline Step 3: Check spike threshold and set outputs
  always @(posedge clk_i) begin
    if (rst_i) begin
      output_valid_o     <= 0;
      neuron_id_o        <= 0;
      neuron_state_u_out <= RESET_VALUE_G;
      spike_out_o        <= 0;
    end else if (pipeline_exec[1]) begin
      output_valid_o     <= 1;
      neuron_id_o        <= neuron_id_q2;
      spike_out_o        <= 0;

      // Check if rounded state is below minimal state. We use the rounded state as rounding might result in a smaller value.
      if (state_u_new_rounded < NEURON_STATE_U_MIN) begin
        neuron_state_u_out <= NEURON_STATE_U_MIN;
      end else begin
        if (EMIT_SPIKES) begin
          // Compare with non-rounded state_u to match our Norse neuron, can be changed but then in both places
          if ($signed(state_u_new[STATE_U_SUM_WIDTH-1:SPIKE_THRESHOLD_SHIFT_DECIMALS]) >= SPIKE_THRESHOLD) begin
            spike_out_o        <= 1;
            neuron_state_u_out <= RESET_VALUE_G;
          end else begin
            neuron_state_u_out <= state_u_new_rounded;
          end
        end else begin
          if (state_u_new_rounded > NEURON_STATE_U_MAX) begin // Saturate positive
            neuron_state_u_out <= NEURON_STATE_U_MAX;
          end else begin
            neuron_state_u_out <= state_u_new_rounded;
          end
        end
      end
    end else begin
      output_valid_o <= 0;
    end
  end


  generate
    if (STATE_ROUND_MODE == "CONVERGENT") begin
      round_convergent #(
          .INPUT_WIDTH(STATE_U_SUM_WIDTH),
          .OUTPUT_WIDTH(STATE_U_SUM_ROUNDED_WIDTH)
      ) round_convergent_1 (
          .data_i(state_u_new),
          .data_o(state_u_new_rounded)
      );
    end else if (STATE_ROUND_MODE == "FLOOR") begin
      // Slice off decimal places, to match output decimal places.
      // We do not need to resize the integer part as the MSBs are automatically cut when assigning to output in Pipeline Step 3,
      // thus effectively removing overflow bits; minimum clamping in pipeline step 3 keeps this safe.
      assign state_u_new_rounded = $signed(state_u_new[STATE_U_SUM_WIDTH - 1 : STATE_U_SUM_DECIMALS - NEURON_STATE_U_DECIMALS]); // Cast to sign required after slicing in Verilog!
    end else begin
      initial $fatal(1, "STATE_ROUND_MODE unsupported mode");
    end
  endgenerate


  // Leak LUTRAM: indexed by timesteps since last spike; contents are (1 - 1/tau)^n in fixed point.
  wire [RAM_LEAK_DATA_WIDTH - 1 : 0] lutram_leak_output;
  wire [RAM_LEAK_ADDR_WIDTH - 1 : 0] lutram_leak_addr;
  assign lutram_leak_addr = ram_leak_write_en_i ? ram_leak_addr_i : timesteps_since_last_activation_i;
  assign leak_factor = timesteps_since_last_activation_i < (2 ** RAM_LEAK_ADDR_WIDTH) ? lutram_leak_output : 0;

  SINGLE_PORT_LUTRAM #(
      .RAM_WIDTH(RAM_LEAK_DATA_WIDTH),
      .RAM_ADDR_BITS(RAM_LEAK_ADDR_WIDTH),
      .INIT_MEM_FILE(RAM_LEAK_INIT_MEM_FILE)
  ) RAM_inst (
      .clkw(clk_i),                  // Write clock input
      .we_i(ram_leak_write_en_i),
      .data_in(ram_leak_data_i),
      .addr_i(lutram_leak_addr),
      .data_out(lutram_leak_output)
  );

endmodule