`timescale 1ns / 1ps

`include "global_params.vh"

module synapse #(
    // Interface parameters (set from project configuration).
    parameter INPUT_DATA_WIDTH = 17,  // 10 Bit Neuron, 7 Bit Synapse
    parameter INPUT_DATA_NEURON_WIDTH = 10,  // 1024 Neurons  
    parameter INPUT_DATA_SYNAPSE_WIDTH = 7,  // 128 Synapses 

    parameter HOT_NEURON_FIFO_DATA_WIDTH = 11,  // 1024 Neurons + Flag Bit

    parameter WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH = 16,
    parameter WEIGHT_SUM_AND_FLAG_RAM_ADDR_WIDTH = 10,  // Should match the amount of neurons

    // Module specific parameters
    parameter WEIGHT_RAM_ADDR_WIDTH = WEIGHT_RAM_ADDR_WIDTH_G,
    parameter WEIGHT_RAM_DATA_WIDTH = WEIGHT_RAM_DATA_WIDTH_G,
    parameter WEIGHT_RAM_WEIGHT_WIDTH = WEIGHT_RAM_WEIGHT_WIDTH_G,
    parameter WEIGHT_RAM_BYTE_WIDTH = WEIGHT_RAM_BYTE_WIDTH_G,
    parameter WEIGHT_RAM_INIT_FILE = WEIGHT_RAM_INIT_FILE_G
) (
    // Control signals
    input  clk_i,
    input  rst_i, // Synchronous reset
    input  rx_done_i,
    input  enable_i,
    input  timestep_i,
    output done_o,

    // Input Buffer
    input [INPUT_DATA_WIDTH -1 : 0] buffer_data_in_i,
    input buffer_read_valid_i, // see FIFO IP, with this signal we can make sure all entries of the input buffer are read only once
    output reg buffer_get_data_o,

    // Hot Neuron FIFO
    output reg [HOT_NEURON_FIFO_DATA_WIDTH -1 : 0] data_hot_neuron_fifo_o,
    output reg we_hot_neuron_fifo_o,
    input hot_neuron_fifo_full_i,

    // Weight Sum and Hot Neuron Flag RAM
    // Write port
    output reg weight_sum_and_flag_ram_we_o,
    output reg [WEIGHT_SUM_AND_FLAG_RAM_ADDR_WIDTH -1 : 0] weight_sum_and_flag_ram_waddr_o,
    output reg [WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH -1 : 0] weight_sum_and_flag_ram_data_o,
    // Read port
    output reg weight_sum_and_flag_ram_re_o,
    output reg [WEIGHT_SUM_AND_FLAG_RAM_ADDR_WIDTH -1 : 0] weight_sum_and_flag_ram_raddr_o,
    input [WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH -1 : 0] weight_sum_and_flag_ram_data_i,

    // Exposes Weight RAM write port to allow weight updates
    input weight_ram_we_i,
    input [WEIGHT_RAM_ADDR_WIDTH-1 : 0] weight_ram_write_addr_i,
    input [WEIGHT_RAM_DATA_WIDTH-1 : 0] weight_ram_data_i
);

  // --------------- Registers -------------------

  // Weight RAM registers
  reg [WEIGHT_RAM_ADDR_WIDTH -1 : 0] weight_ram_addr_r;
  reg weight_ram_re_r;
  reg [$clog2(WEIGHT_RAM_DATA_WIDTH/WEIGHT_RAM_WEIGHT_WIDTH)-1 : 0] weight_ram_weight_sel_r;
  wire [WEIGHT_RAM_WEIGHT_WIDTH -1 : 0] weight_ram_data_in_w;

  // Register for weight summation
  reg [WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH - 2 : 0] weight_sum_r;  // -2 due to flag bit
  reg [WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH - 2 : 0] weight_sum_r_1;
  reg [WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH - 2 : 0] weight_sum_r_2;

  // Pipeline registers
  reg [4:0] exec_r;
  reg [INPUT_DATA_NEURON_WIDTH -1 : 0] neuron_addr_0_r;
  reg [INPUT_DATA_NEURON_WIDTH -1 : 0] neuron_addr_1_r;
  reg [INPUT_DATA_NEURON_WIDTH -1 : 0] neuron_addr_2_r;
  reg [INPUT_DATA_NEURON_WIDTH -1 : 0] neuron_addr_3_r;
  reg [INPUT_DATA_NEURON_WIDTH -1 : 0] neuron_addr_4_r;

  // Marker to add dummy entries to Hot Neuron FIFO to mark a timestep switch
  reg [1:0] marker_set_r;
  reg marker_write_done;
  
  // --------------- Done Logic ------------------- 
  reg rx_done_delay;

  // See core.v for done logic explanation
  // done_o is high if rx is done and the synapse module is idle
  assign done_o = rx_done_delay & ~(|exec_r[2:0]) & ~weight_sum_and_flag_ram_we_o & ~buffer_read_valid_i & marker_write_done;

  // avoids rx_done to be high and buffer_read_valid to be low, but valid data is still in input FIFO
  always @(posedge clk_i) begin
    if (rst_i) begin
      rx_done_delay <= 0;
    end else begin
      if (enable_i) begin
        if (rx_done_i & marker_write_done) begin
          rx_done_delay <= 1;
        end
      end else begin
        rx_done_delay <= 0;
      end
    end
  end

  // --------------- Pipeline Steps -------------------

  always @(posedge clk_i) begin
    if (rst_i) begin
      // Reset all registers
      buffer_get_data_o <= 0;
      we_hot_neuron_fifo_o <= 0;
      weight_sum_and_flag_ram_we_o <= 0;
      weight_sum_and_flag_ram_re_o <= 0;
      neuron_addr_0_r <= 0;
      neuron_addr_1_r <= 0;
      neuron_addr_2_r <= 0;
      neuron_addr_3_r <= 0;
      neuron_addr_4_r <= 0;
      weight_sum_r <= 0;
      weight_sum_r_1 <= 0;
      weight_sum_r_2 <= 0;
      exec_r <= 0;
      marker_set_r <= 0;
      marker_write_done <= 0;
      weight_ram_re_r <= 0;
      weight_ram_weight_sel_r <= 0;
    end else begin
      // Shift pipeline registers each cycle
      neuron_addr_1_r <= neuron_addr_0_r;
      neuron_addr_2_r <= neuron_addr_1_r;
      neuron_addr_3_r <= neuron_addr_2_r;
      neuron_addr_4_r <= neuron_addr_3_r;
      weight_sum_r_1  <= weight_sum_r;
      weight_sum_r_2  <= weight_sum_r_1;

      // Start processing by writing marker entries and process input buffer afterwards
      if (enable_i) begin
        // Two marker entries are written to the Hot Neuron FIFO per timestep
        // They are read by the neuron_wrapper.v to detect the timestep switch and are not processed
        // This step waits in case Hot Neuron FIFO contains max amount of entries from previous timestep
        if (marker_set_r < 2) begin
          if (~hot_neuron_fifo_full_i) begin
            marker_set_r <= marker_set_r + 1;
            data_hot_neuron_fifo_o <= {{(HOT_NEURON_FIFO_DATA_WIDTH - 1) {1'b0}}, timestep_i};
            we_hot_neuron_fifo_o <= 1;
          end else begin
            we_hot_neuron_fifo_o <= 0;
          end
        end else begin
          // To avoid write flag set conflicts with pipeline step 3
          marker_write_done <= 1;
          if (~marker_write_done) begin
            we_hot_neuron_fifo_o <= 0;
          end

          buffer_get_data_o <= 1;
        end
      end else begin
        // Resets after enable signal is low again
        buffer_get_data_o <= 0;
        marker_set_r <= 0;
        marker_write_done <= 0;
      end

      // Pipeline Step 0 wait for FIFO Pop

      // Pipeline Step 1 - process input and trigger RAM reads
      if (buffer_read_valid_i) begin
        // activate execution for this input and store input data to pipeline register
        exec_r <= {exec_r[3:0], 1'b1};
        neuron_addr_0_r <= buffer_data_in_i[INPUT_DATA_WIDTH-1 : INPUT_DATA_SYNAPSE_WIDTH];

        // read weight ram
        weight_ram_addr_r <= buffer_data_in_i[INPUT_DATA_WIDTH - INPUT_DATA_NEURON_WIDTH-1 : INPUT_DATA_WIDTH - INPUT_DATA_NEURON_WIDTH - WEIGHT_RAM_ADDR_WIDTH];
        weight_ram_weight_sel_r <= buffer_data_in_i[INPUT_DATA_WIDTH - INPUT_DATA_NEURON_WIDTH - WEIGHT_RAM_ADDR_WIDTH -1 : 0];
        weight_ram_re_r <= 1'b1;

        // read current weight sum
        weight_sum_and_flag_ram_raddr_o <= buffer_data_in_i[INPUT_DATA_WIDTH-1 : INPUT_DATA_SYNAPSE_WIDTH];
        weight_sum_and_flag_ram_re_o <= 1'b1;
      end else begin
        // deactivate execution for this input
        exec_r <= {exec_r[3:0], 1'b0};
        // address 0 is used for comparisons of invalid data, which is why it is handled in a special case later
        neuron_addr_0_r <= 0;
        // disable reads
        weight_ram_re_r <= 1'b0;
        weight_sum_and_flag_ram_re_o <= 1'b0;
      end
      //end

      // Pipeline Step 2 - wait for RAM reads

      // Pipeline Step 3 - process data
      if (exec_r[1]) begin
        // The intermediate result of weight_sum_r is used if the result is not already written to memory
        // exec register is checked to also write address 0 correctly
        if ((neuron_addr_1_r == neuron_addr_2_r) & (exec_r[2] == 1)) begin
          weight_sum_r <= $signed(weight_sum_r) + $signed(weight_ram_data_in_w);
        end else begin
          if ((neuron_addr_1_r == neuron_addr_3_r) & (exec_r[3] == 1)) begin
            weight_sum_r <= $signed(weight_sum_r_1) + $signed(weight_ram_data_in_w);
          end else begin
            if ((neuron_addr_1_r == neuron_addr_4_r) & (exec_r[4] == 1)) begin
              weight_sum_r <= $signed(weight_sum_r_2) + $signed(weight_ram_data_in_w);
            end else begin
              weight_sum_r <=
                  $signed(weight_sum_and_flag_ram_data_i[WEIGHT_SUM_AND_FLAG_RAM_DATA_WIDTH-1 : 1]) +
                  $signed(weight_ram_data_in_w);
            end
          end
        end
        // Add adresses to Hot Neuron FIFO only one time per timestep. 
        //    The comparison avoids, that an address is added twice before the flag is set in memory, 
        //    exec register is checked to also write address 0 correctly
        if (~weight_sum_and_flag_ram_data_i[0] 
        & ((neuron_addr_1_r != neuron_addr_2_r) | (exec_r[2] == 0))
        & ((neuron_addr_1_r != neuron_addr_3_r) | (exec_r[3] == 0))
        & ((neuron_addr_1_r != neuron_addr_4_r) | (exec_r[4] == 0))) begin
            data_hot_neuron_fifo_o <= {neuron_addr_1_r, timestep_i};
            we_hot_neuron_fifo_o   <= 1;
        end else begin
          we_hot_neuron_fifo_o <= 0;
        end
      end else begin
        // To avoid conflicts writing to Hot Neuron FIFO
        if (marker_write_done) begin
          we_hot_neuron_fifo_o <= 0;
        end
      end

      // Pipeline Step 4 - Write weight sum and flag bit to memory
      if (exec_r[2]) begin
        weight_sum_and_flag_ram_data_o <= {weight_sum_r, 1'b1};
        weight_sum_and_flag_ram_waddr_o <= neuron_addr_2_r;
        weight_sum_and_flag_ram_we_o <= 1'b1;
      end else begin
        weight_sum_and_flag_ram_we_o <= 1'b0;
      end
    end
  end

  // ------------- Memory instantiation -------------------

  URAM #(
      .ADDR_WIDTH(WEIGHT_RAM_ADDR_WIDTH),
      .DATA_WIDTH(WEIGHT_RAM_DATA_WIDTH),
      .ENTRY_WIDTH(WEIGHT_RAM_WEIGHT_WIDTH),
      .BYTE_WIDTH(WEIGHT_RAM_BYTE_WIDTH),
      .INIT_MEM_FILE(WEIGHT_RAM_INIT_FILE)

  ) weight_ram (

      .clk_i(clk_i),

      .we_i(weight_ram_we_i),
      .write_addr_i(weight_ram_write_addr_i),
      .data_i(weight_ram_data_i),

      .re_i(weight_ram_re_r),
      .read_addr_i(weight_ram_addr_r),
      .read_entry_select_i(weight_ram_weight_sel_r),
      .data_o(weight_ram_data_in_w)
  );

endmodule
