`timescale 1ns / 1ps

`include "global_params.vh"

module neuron_wrapper #(
    parameter EMIT_SPIKES = 1,
    parameter LEAK_STATES = 1,
    parameter HOT_NEURON_FIFO_DATA_WIDTH = 11,  // 1024 Neurons + Flag Bit

    parameter WEIGHT_SUM_ADDR_WIDTH = HOT_NEURON_FIFO_DATA_WIDTH - 1,
    parameter WEIGHT_SUM_DATA_WIDTH = 15,
    parameter WEIGHT_SUM_DECIMALS   = 7,

    parameter SPIKE_OUT_FIFO_DATA_WIDTH = HOT_NEURON_FIFO_DATA_WIDTH - 1,  // 1024 Neurons

    parameter TAU_MEM_INV_DATA_WIDTH = TAU_MEM_INV_DATA_WIDTH_G,
    parameter TAU_MEM_INV_DECIMALS   = TAU_MEM_INV_DECIMALS_G,
    parameter TAU_MEM_INV            = TAU_MEM_INV_G,

    parameter NEURON_STATE_ADDR_WIDTH = NEURON_STATE_ADDR_WIDTH_G,
    parameter NEURON_STATE_DATA_WIDTH = NEURON_STATE_DATA_WIDTH_G,
    parameter NEURON_STATE_DECIMALS   = NEURON_STATE_DECIMALS_G,
    parameter NEURON_STATE_INIT_FILE  = NEURON_STATE_INIT_FILE_G,

    parameter TIMESTEP_WIDTH          = TIMESTEP_WIDTH_G,
    parameter TIMESTEP_RAM_ADDR_WIDTH = TIMESTEP_RAM_ADDR_WIDTH_G,
    parameter TIMESTEP_RAM_DATA_WIDTH = TIMESTEP_RAM_DATA_WIDTH_G,
    parameter TIMESTEP_RAM_INIT_FILE  = TIMESTEP_RAM_INIT_FILE_G,

    parameter RAM_LEAK_ADDR_WIDTH     = RAM_LEAK_ADDR_WIDTH_G,
    parameter RAM_LEAK_DATA_WIDTH     = RAM_LEAK_DATA_WIDTH_G,
    parameter RAM_LEAK_DECIMALS       = RAM_LEAK_DECIMALS_G,
    parameter RAM_LEAK_INIT_MEM_FILE  = RAM_LEAK_INIT_MEM_FILE_G
) (
    input  clk_i,
    input  rst_i,
    input  rst_mems_i,
    output rst_done_o,
    input  [TIMESTEP_WIDTH-1:0] timestep_i,
    input  enable_i,
    output done_o,

    // Connection to Hot Neuron FIFO
    output reg hot_neuron_fifo_re_o,
    input [HOT_NEURON_FIFO_DATA_WIDTH  -1 : 0] hot_neuron_fifo_data_i,
    input hot_neuron_fifo_read_valid_i,

    // Connection to Spike Out FIFO
    output reg spike_out_fifo_we_o,
    output reg [SPIKE_OUT_FIFO_DATA_WIDTH  -1 : 0] spike_out_fifo_data_o,

    // Connection to Quad Port MUX RAM
    output reg weight_sum_ram_we_o,
    output reg [WEIGHT_SUM_ADDR_WIDTH -1 : 0] weight_sum_ram_waddr_o,
    output reg [WEIGHT_SUM_DATA_WIDTH -1 : 0] weight_sum_ram_data_o,

    output reg weight_sum_ram_re_o,
    output reg [WEIGHT_SUM_ADDR_WIDTH -1 : 0] weight_sum_ram_raddr_o,
    input      [WEIGHT_SUM_DATA_WIDTH -1 : 0] weight_sum_ram_data_i,

    // Read out connection for neuron state RAM
    input                                    neuron_state_read_req_i,
    input                                    neuron_state_read_fu_i,    // Force update of neuron states
    input [NEURON_STATE_ADDR_WIDTH-1:0]      neuron_state_read_start_i,
    input [NEURON_STATE_ADDR_WIDTH-1:0]      neuron_state_read_end_i,
    output reg [NEURON_STATE_ADDR_WIDTH-1:0] neuron_state_read_id_o,
    output reg [NEURON_STATE_DATA_WIDTH-1:0] neuron_state_read_data_o,
    output reg                               neuron_state_read_valid_o,
    output reg                               neuron_state_read_last_o,
    output reg                               neuron_state_read_done_o,

    // Write connection to neuron leak RAM
    input                                    neuron_leak_ram_write_en_i,
    input      [RAM_LEAK_ADDR_WIDTH-1:0]     neuron_leak_ram_addr_i,
    input      [RAM_LEAK_DATA_WIDTH-1:0]     neuron_leak_ram_data_i,

    // Write connection for neuron tau_mem
    input [TAU_MEM_INV_DATA_WIDTH-1:0]       neuron_tau_mem_inv
);

  // ------------- DEFINE SIGNALS -------------

  // Reset signals
  reg rst_states_done_r;
  reg rst_timesteps_done_r;

  reg rst_state_ram_write_en_r;
  reg [NEURON_STATE_ADDR_WIDTH -1 : 0] rst_state_ram_write_addr_r;

  reg rst_timestep_ram_write_en_r;
  reg [TIMESTEP_RAM_ADDR_WIDTH -1 : 0] rst_timestep_ram_write_addr_r;

  // Multiplexed RAM write signals
  reg mux_state_ram_write_en_r;
  reg [NEURON_STATE_ADDR_WIDTH -1 : 0] mux_state_ram_write_addr_r;
  reg [NEURON_STATE_DATA_WIDTH -1 : 0] mux_state_ram_data_in_r;

  reg mux_timestep_ram_write_en_r;
  reg [TIMESTEP_RAM_ADDR_WIDTH -1 : 0] mux_timestep_ram_write_addr_r;
  reg [TIMESTEP_RAM_DATA_WIDTH -1 : 0] mux_timestep_ram_data_in_r;

  // Signals to connect with state RAM
  reg state_ram_read_en_r;
  reg [NEURON_STATE_ADDR_WIDTH -1 : 0] state_ram_read_addr_r;
  wire [NEURON_STATE_DATA_WIDTH -1 : 0] state_ram_data_out_w;

  reg state_ram_write_en_r;
  reg [NEURON_STATE_ADDR_WIDTH -1 : 0] state_ram_write_addr_r;
  reg [NEURON_STATE_DATA_WIDTH -1 : 0] state_ram_data_in_r;

  // Signals to connect with timesteps RAM
  reg timestep_ram_read_en_r;
  reg [TIMESTEP_RAM_ADDR_WIDTH -1 : 0] timestep_ram_read_addr_r;
  wire [TIMESTEP_RAM_DATA_WIDTH -1 : 0] timestep_ram_data_out_w;

  reg timestep_ram_write_en_r;
  reg [TIMESTEP_RAM_ADDR_WIDTH -1 : 0] timestep_ram_write_addr_r;
  reg [TIMESTEP_RAM_DATA_WIDTH -1 : 0] timestep_ram_data_in_r;

  // Signals to connect to neuron logic implementation
  wire inst_neuron_idle_w;

  reg inst_neuron_valid_in_r;
  reg [NEURON_STATE_ADDR_WIDTH -1 : 0] inst_neuron_id_in_r;
  reg [NEURON_STATE_DATA_WIDTH -1 : 0] inst_neuron_state_in_r;
  reg [TIMESTEP_RAM_DATA_WIDTH -1 : 0] inst_neuron_timesteps_in_r;
  reg [WEIGHT_SUM_DATA_WIDTH -1 : 0] inst_neuron_weight_sum_in_r;

  wire inst_neuron_output_valid_w;
  wire [NEURON_STATE_ADDR_WIDTH -1 : 0] inst_neuron_neuron_id_out_w;
  wire [NEURON_STATE_DATA_WIDTH -1 : 0] inst_neuron_neuron_state_out_w;
  wire inst_neuron_spike_out_w;


  // Pipeline registers
  reg [HOT_NEURON_FIFO_DATA_WIDTH -2 :0] neuron_addr_pipeline_reg_0; // -2 due to timestep bit of Hot Neuron FIFO
  reg [HOT_NEURON_FIFO_DATA_WIDTH -2 :0] neuron_addr_pipeline_reg_1; // -2 due to timestep bit of Hot Neuron FIFO
  reg [1:0] pipeline_exec;

  // Forced update registers
  reg [1:0] fu_pipeline_exec;
  reg [NEURON_STATE_ADDR_WIDTH-1:0] fu_neuron_id_counter;

  reg [NEURON_STATE_ADDR_WIDTH-1:0] fu_neuron_addr_pipeline_reg_0;
  reg [NEURON_STATE_ADDR_WIDTH-1:0] fu_neuron_addr_pipeline_reg_1;
  reg fu_processing_done;
  reg fu_processing_active;

  // Neuron state read-out registers
  reg neuron_state_read_active;
  reg neuron_state_read_done;
  assign neuron_state_read_data_o = state_ram_data_out_w;

  // ------------- DONE Signals -------------

  wire calculation_done_w;
  reg timestep_done;

  // Is high if all inputs of the Hot Neuron FIFO are processed and results are written to memory
  assign calculation_done_w = timestep_done & ~|pipeline_exec & inst_neuron_idle_w & ~state_ram_write_en_r;

  assign done_o = calculation_done_w;

  // Force update done
  wire fu_calculation_done_w;

  assign fu_calculation_done_w    = fu_processing_done & ~|fu_pipeline_exec & inst_neuron_idle_w & ~state_ram_write_en_r;
  assign neuron_state_read_done_o = (fu_calculation_done_w | !neuron_state_read_fu_i) & neuron_state_read_done;

  // Reset done
  assign rst_done_o = rst_states_done_r & rst_timesteps_done_r;

  // ------------- LOGIC -------------

  //
  // Functional logic
  //
  always @(posedge clk_i) begin
    if (rst_i) begin
      hot_neuron_fifo_re_o <= 1'b0;
      spike_out_fifo_we_o <= 1'b0;
      //spike_out_fifo_data_o <= 0;
      //weight_sum_ram_we_o <= 1'b0;
      //weight_sum_ram_waddr_o <= 0;
      //weight_sum_ram_data_o <= 0;
      //weight_sum_ram_re_o <= 1'b0;
      //weight_sum_ram_raddr_o <= 0;
      neuron_state_read_id_o <= 0;
      //neuron_state_read_data_o <= 0;
      neuron_state_read_valid_o <= 0;
      neuron_state_read_last_o <= 0;
      state_ram_read_en_r <= 1'b0;
      state_ram_read_addr_r <= 0;
      state_ram_write_en_r <= 1'b0;
      state_ram_write_addr_r <= 0;
      state_ram_data_in_r <= 0;
      timestep_ram_read_en_r <= 1'b0;
      timestep_ram_read_addr_r <= 0;
      timestep_ram_write_en_r <= 1'b0;
      timestep_ram_write_addr_r <= 0;
      timestep_ram_data_in_r <= 0;
      inst_neuron_valid_in_r <= 1'b0;
      inst_neuron_id_in_r <= 0;
      inst_neuron_state_in_r <= 0;
      inst_neuron_timesteps_in_r <= 0;
      inst_neuron_weight_sum_in_r <= 0;
      neuron_addr_pipeline_reg_0 <= 0;
      neuron_addr_pipeline_reg_1 <= 0;
      pipeline_exec <= 0;
      timestep_done <= 1'b0;
      fu_pipeline_exec <= 2'b0;
      fu_neuron_id_counter <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
      fu_neuron_addr_pipeline_reg_0 <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
      fu_neuron_addr_pipeline_reg_1 <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
      fu_processing_active <= 1'b0;
      fu_processing_done <= 1'b0;
      neuron_state_read_active <= 1'b0;
      neuron_state_read_done <= 1'b0;
    end else begin

      if (enable_i) begin

        // Pipeline Step 1: Fetch Data from Hot Neuron FIFO and trigger memory reads
        if (!timestep_done) begin

          hot_neuron_fifo_re_o <= 1'b1;

          if (hot_neuron_fifo_read_valid_i) begin
            if (hot_neuron_fifo_data_i[0] == timestep_i[0]) begin // indicates that all neurons of the current timesteps are processed
              // No processing here, since this is a marker entry from the synapse module
              timestep_done <= 1;
              hot_neuron_fifo_re_o <= 1'b0;

              pipeline_exec <= {pipeline_exec[0], 1'b0};
              weight_sum_ram_re_o <= 1'b0;
              state_ram_read_en_r <= 1'b0;
              timestep_ram_read_addr_r <= 0;
              timestep_ram_read_en_r <= 1'b0;

            end else begin
              // Process neuron
              pipeline_exec <= {pipeline_exec[0], 1'b1};
              neuron_addr_pipeline_reg_0 <= hot_neuron_fifo_data_i[HOT_NEURON_FIFO_DATA_WIDTH-1 : 1];

              weight_sum_ram_raddr_o <= hot_neuron_fifo_data_i[HOT_NEURON_FIFO_DATA_WIDTH-1 : 1];
              weight_sum_ram_re_o <= 1'b1;

              state_ram_read_addr_r <= hot_neuron_fifo_data_i[HOT_NEURON_FIFO_DATA_WIDTH-1 : 1];
              state_ram_read_en_r <= 1'b1;

              timestep_ram_read_addr_r <= hot_neuron_fifo_data_i[HOT_NEURON_FIFO_DATA_WIDTH-1 : 1];
              timestep_ram_read_en_r <= 1'b1;
            end

          end else begin
            pipeline_exec <= {pipeline_exec[0], 1'b0};
            weight_sum_ram_re_o <= 1'b0;
            state_ram_read_en_r <= 1'b0;
            timestep_ram_read_addr_r <= 0;
            timestep_ram_read_en_r <= 1'b0;
          end

        end else begin
          pipeline_exec <= {pipeline_exec[0], 1'b0};
        end

        // Pipeline step 2: Wait for memory reads
        if (pipeline_exec[0]) begin
          neuron_addr_pipeline_reg_1 <= neuron_addr_pipeline_reg_0;
        end

        // Pipeline step 3: Put memory output in neuron instance to do calculations and reset weight sum
        if (pipeline_exec[1]) begin
          inst_neuron_id_in_r <= neuron_addr_pipeline_reg_1;
          inst_neuron_state_in_r <= state_ram_data_out_w;
          inst_neuron_weight_sum_in_r <= weight_sum_ram_data_i;
          inst_neuron_timesteps_in_r <= timestep_i - timestep_ram_data_out_w;
          inst_neuron_valid_in_r <= 1;

          // reset weight sum
          weight_sum_ram_waddr_o <= neuron_addr_pipeline_reg_1;
          weight_sum_ram_data_o <= 0;
          weight_sum_ram_we_o <= 1;
        end else begin
          inst_neuron_valid_in_r <= 0;
          weight_sum_ram_we_o <= 0;
        end

        // Neuron Pipeline is processing input ...

        // Write results to memories and Spike Out FIFO
        if (inst_neuron_output_valid_w) begin
          // Put spiking neuron address to Spike Out FIFO
          if (inst_neuron_spike_out_w == 1'b1) begin
            spike_out_fifo_data_o <= inst_neuron_neuron_id_out_w;
            spike_out_fifo_we_o   <= 1'b1;
          end else begin
            spike_out_fifo_we_o <= 1'b0;
          end

          state_ram_write_addr_r <= inst_neuron_neuron_id_out_w;
          state_ram_data_in_r <= inst_neuron_neuron_state_out_w;
          state_ram_write_en_r <= 1'b1;

          timestep_ram_write_addr_r <= inst_neuron_neuron_id_out_w;
          timestep_ram_data_in_r <= timestep_i;
          timestep_ram_write_en_r <= 1'b1;
        end else begin
          spike_out_fifo_we_o <= 1'b0;
          state_ram_write_en_r <= 1'b0;
          timestep_ram_write_addr_r <= 0;
          timestep_ram_write_en_r <= 1'b0;
        end

      end else begin  // !enable_i

        // Reset normal operation variables
        timestep_done   <= 0;

        // Disable all read/write enables by default
        inst_neuron_valid_in_r  <= 1'b0;
        state_ram_read_en_r     <= 1'b0;
        state_ram_write_en_r    <= 1'b0;
        timestep_ram_read_en_r  <= 1'b0;
        timestep_ram_write_en_r <= 1'b0;

        // Neuron state output logic

        if (neuron_state_read_req_i) begin

          // Forced neuron state update required
          if (neuron_state_read_fu_i) begin

            if (!fu_processing_done) begin
              if (!fu_processing_active) begin
                fu_processing_active  <= 1;
                fu_neuron_id_counter  <= neuron_state_read_start_i;
                state_ram_read_addr_r <= 0;
              end else begin
                // Pipeline Step 1: Read data from state and timestep RAM
                fu_pipeline_exec <= {fu_pipeline_exec[0], 1'b1};
                fu_neuron_addr_pipeline_reg_0 <= fu_neuron_id_counter;

                state_ram_read_addr_r      <= fu_neuron_id_counter;
                state_ram_read_en_r        <= 1'b1;
                timestep_ram_read_addr_r   <= fu_neuron_id_counter;
                timestep_ram_read_en_r     <= 1'b1;

                if (state_ram_read_addr_r < neuron_state_read_end_i) begin
                  fu_neuron_id_counter <= fu_neuron_id_counter + 1;
                end else begin
                  fu_processing_active   <= 0;
                  fu_processing_done     <= 1;
                  fu_pipeline_exec       <= {fu_pipeline_exec[0], 1'b0};

                  state_ram_read_en_r    <= 1'b0;
                  timestep_ram_read_en_r <= 1'b0;
                end
              end
            end else begin
              fu_processing_active <= 0;
              fu_pipeline_exec     <= {fu_pipeline_exec[0], 1'b0};
            end

            // Pipeline step 2: Wait for memory reads
            if (fu_pipeline_exec[0]) begin
              fu_neuron_addr_pipeline_reg_1 <= fu_neuron_addr_pipeline_reg_0;
            end

            // Pipeline step 3: Put memory output in neuron instance to do calculations
            if (fu_pipeline_exec[1]) begin
              inst_neuron_id_in_r         <= fu_neuron_addr_pipeline_reg_1;
              inst_neuron_state_in_r      <= state_ram_data_out_w;
              inst_neuron_weight_sum_in_r <= {WEIGHT_SUM_DATA_WIDTH{1'b0}}; // No inputs
              // Forced update uses previous timestep (timestep advances when execution completes).
              inst_neuron_timesteps_in_r  <= (timestep_i - timestep_ram_data_out_w) - 1;
              inst_neuron_valid_in_r      <= 1;
            end else begin
              inst_neuron_valid_in_r      <= 0;
            end

            // Neuron Pipeline is processing input ...

            // Pipeline step 4: Write results to memories (no need to check for spikes, as no input is given)
            if (inst_neuron_output_valid_w) begin
              state_ram_write_addr_r <= inst_neuron_neuron_id_out_w;
              state_ram_data_in_r    <= inst_neuron_neuron_state_out_w;
              state_ram_write_en_r   <= 1'b1;

              timestep_ram_write_addr_r <= inst_neuron_neuron_id_out_w;
              timestep_ram_data_in_r    <= timestep_i - 1;
              timestep_ram_write_en_r   <= 1'b1;
            end else begin
              state_ram_write_en_r    <= 1'b0;
              timestep_ram_write_en_r <= 1'b0;
            end
          end

          // Neuron state read-out (if forced update is done or not requested)
          if ((fu_calculation_done_w | !neuron_state_read_fu_i) && !neuron_state_read_done) begin
            state_ram_read_en_r <= 1;

            if (!neuron_state_read_active) begin
              neuron_state_read_active <= 1;
              state_ram_read_addr_r    <= neuron_state_read_start_i;
              neuron_state_read_id_o   <= 0;
            end else begin
              neuron_state_read_id_o    <= state_ram_read_addr_r;
              neuron_state_read_valid_o <= 1;

              if (neuron_state_read_id_o < neuron_state_read_end_i) begin
                state_ram_read_addr_r <= state_ram_read_addr_r + 1;
                if (neuron_state_read_id_o == neuron_state_read_end_i - 1) begin
                  neuron_state_read_last_o <= 1;
                end
              end else begin
                neuron_state_read_done    <= 1;
                neuron_state_read_active  <= 0;
                neuron_state_read_valid_o <= 0;
                neuron_state_read_last_o  <= 0;
                state_ram_read_en_r       <= 0;
              end
            end

          end else begin
            neuron_state_read_active  <= 0;
            neuron_state_read_valid_o <= 0;
            neuron_state_read_last_o  <= 0;
          end

        end else begin
          // Reset forced neuron update variables
          fu_processing_active  <= 0;
          fu_processing_done    <= 0;
          fu_pipeline_exec      <= 2'b0;
          fu_neuron_id_counter  <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
          // Reset neuron state readout variables
          neuron_state_read_active  <= 0;
          neuron_state_read_done    <= 0;
          neuron_state_read_valid_o <= 0;
          neuron_state_read_last_o  <= 0;
          neuron_state_read_id_o    <= 0;
        end
      end
    end
  end

  //
  // Reset logic
  //

  // Multiplex the signals connected to the DP RAM
  // to enable clearing it when resetting.
  always_comb begin
    if (rst_i & rst_mems_i) begin
      mux_state_ram_write_en_r      = rst_state_ram_write_en_r;
      mux_state_ram_write_addr_r    = rst_state_ram_write_addr_r;
      mux_state_ram_data_in_r       = {NEURON_STATE_DATA_WIDTH{1'b0}};

      mux_timestep_ram_write_en_r   = rst_timestep_ram_write_en_r;
      mux_timestep_ram_write_addr_r = rst_timestep_ram_write_addr_r;
      mux_timestep_ram_data_in_r    = {TIMESTEP_RAM_DATA_WIDTH{1'b0}};
    end else begin
      mux_state_ram_write_en_r      = state_ram_write_en_r;
      mux_state_ram_write_addr_r    = state_ram_write_addr_r;
      mux_state_ram_data_in_r       = state_ram_data_in_r;

      mux_timestep_ram_write_en_r   = timestep_ram_write_en_r;
      mux_timestep_ram_write_addr_r = timestep_ram_write_addr_r;
      mux_timestep_ram_data_in_r    = timestep_ram_data_in_r;
    end
  end

  // Reset states RAM
  always @(posedge clk_i) begin
    if (rst_i & rst_mems_i) begin
      if (rst_state_ram_write_addr_r < ((1 << NEURON_STATE_ADDR_WIDTH) - 1)) begin
        rst_state_ram_write_en_r <= 1;
        rst_states_done_r <= 0;

        if (rst_state_ram_write_en_r) begin // After writing started, begin incrementing
          rst_state_ram_write_addr_r <= rst_state_ram_write_addr_r + 1;
        end
      end else begin
        rst_states_done_r <= 1;
        rst_state_ram_write_en_r <= 0;
      end
    end else begin
      rst_states_done_r <= 0;
      rst_state_ram_write_en_r <= 0;
      rst_state_ram_write_addr_r <= {NEURON_STATE_ADDR_WIDTH{1'b0}};
    end
  end

  // Reset timesteps RAM
  always @(posedge clk_i) begin
    if (rst_i & rst_mems_i) begin
      if (rst_timestep_ram_write_addr_r < ((1 << TIMESTEP_RAM_ADDR_WIDTH) - 1)) begin
        rst_timestep_ram_write_en_r <= 1;
        rst_timesteps_done_r <= 0;

        if (rst_timestep_ram_write_en_r) begin // After writing started, begin incrementing
          rst_timestep_ram_write_addr_r <= rst_timestep_ram_write_addr_r + 1;
        end
      end else begin
        rst_timesteps_done_r <= 1;
        rst_timestep_ram_write_en_r <= 0;
      end
    end else begin
      rst_timesteps_done_r <= 0;
      rst_timestep_ram_write_en_r <= 0;
      rst_timestep_ram_write_addr_r <= {TIMESTEP_RAM_ADDR_WIDTH{1'b0}};
    end
  end


  // ------------- NEURON -------------

  lif_neuron #(
      .EMIT_SPIKES(EMIT_SPIKES),
      .LEAK_STATES(LEAK_STATES),
      .NEURON_STATE_ADDR_WIDTH(NEURON_STATE_ADDR_WIDTH),
      .NEURON_STATE_DATA_WIDTH(NEURON_STATE_DATA_WIDTH),
      .NEURON_STATE_DECIMALS  (NEURON_STATE_DECIMALS),

      .TIMESTEP_COUNTER_DATA_WIDTH(TIMESTEP_RAM_DATA_WIDTH),

      .WEIGHT_SUM_DATA_WIDTH(WEIGHT_SUM_DATA_WIDTH),
      .WEIGHT_SUM_DECIMALS  (WEIGHT_SUM_DECIMALS),

      .TAU_MEM_INV_DATA_WIDTH(TAU_MEM_INV_DATA_WIDTH),
      .TAU_MEM_INV_DECIMALS(TAU_MEM_INV_DECIMALS),
      .TAU_MEM_INV(TAU_MEM_INV),

      .RAM_LEAK_ADDR_WIDTH(RAM_LEAK_ADDR_WIDTH),
      .RAM_LEAK_DATA_WIDTH(RAM_LEAK_DATA_WIDTH),
      .RAM_LEAK_DECIMALS(RAM_LEAK_DECIMALS),
      .RAM_LEAK_INIT_MEM_FILE(RAM_LEAK_INIT_MEM_FILE)
  ) inst_neuron_lif (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .idle_o(inst_neuron_idle_w),

      .input_valid_i(inst_neuron_valid_in_r),
      .neuron_id_i(inst_neuron_id_in_r),
      .neuron_state_i(inst_neuron_state_in_r),
      .weight_sum_i(inst_neuron_weight_sum_in_r),
      .timesteps_since_last_activation_i(inst_neuron_timesteps_in_r),

      .output_valid_o(inst_neuron_output_valid_w),
      .neuron_id_o(inst_neuron_neuron_id_out_w),
      .neuron_state_o(inst_neuron_neuron_state_out_w),
      .spike_out_o(inst_neuron_spike_out_w),

      .ram_leak_write_en_i(neuron_leak_ram_write_en_i),
      .ram_leak_addr_i(neuron_leak_ram_addr_i),
      .ram_leak_data_i(neuron_leak_ram_data_i),

      .tau_mem_inv(neuron_tau_mem_inv)
  );


  // ------------- MEMORIES -------------

  DUAL_PORT_RAM #(
      .DATA_WIDTH(NEURON_STATE_DATA_WIDTH),
      .ADDR_WIDTH(NEURON_STATE_ADDR_WIDTH),
      .INIT_MEM_FILE(NEURON_STATE_INIT_FILE)
  ) state_RAM (
      .clk_i(clk_i),

      .read_en_i(state_ram_read_en_r),
      .read_addr_i(state_ram_read_addr_r),
      .data_out(state_ram_data_out_w),

      .write_en_i(mux_state_ram_write_en_r),
      .write_addr_i(mux_state_ram_write_addr_r),
      .data_in(mux_state_ram_data_in_r)
  );


  DUAL_PORT_RAM #(
      .DATA_WIDTH(TIMESTEP_RAM_DATA_WIDTH),
      .ADDR_WIDTH(TIMESTEP_RAM_ADDR_WIDTH),
      .INIT_MEM_FILE(TIMESTEP_RAM_INIT_FILE)
  ) timestep_RAM (
      .clk_i(clk_i),

      .read_en_i(timestep_ram_read_en_r),
      .read_addr_i(timestep_ram_read_addr_r),
      .data_out(timestep_ram_data_out_w),

      .write_en_i(mux_timestep_ram_write_en_r),
      .write_addr_i(mux_timestep_ram_write_addr_r),
      .data_in(mux_timestep_ram_data_in_r)
  );

endmodule
