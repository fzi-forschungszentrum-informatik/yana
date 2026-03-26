`timescale 1ns / 1ps

`include "global_params.vh"

module axon #(
    // Set parameters from the project configuration (defaults are not valid alone).
    parameter SPIKE_OUT_FIFO_DATA_WIDTH = 10,
    parameter OUTPUT_BUFFER_DATA_WIDTH  = 24,

    parameter URAM_ROUTES_ADDR_WIDTH  = 16,
    parameter URAM_ROUTES_DATA_WIDTH  = 72,
    parameter URAM_ROUTES_ENTRY_WIDTH = 24,
    parameter URAM_ROUTES_BYTE_WIDTH  = 9,
    parameter URAM_ROUTES_INIT_FILE   = "",

    parameter URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH = 10,
    parameter URAM_MEMORY_MAPPING_RAM_DATA_WIDTH = 32,
    parameter URAM_MEMORY_MAPPING_RAM_INIT_FILE  = "",

    parameter URAM_MEMORY_MAPPING_START_ADDR_WIDTH = URAM_MEMORY_MAPPING_START_ADDR_WIDTH_G,
    parameter URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH = URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH_G,
    parameter URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH = URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH_G

) (
    // Control signals
    input clk_i,
    input rst_i,
    input enable_i,

    // Connection to Spike Out FIFO
    output reg spike_out_fifo_read_enable_o,
    input spike_out_fifo_read_valid_i,
    input [SPIKE_OUT_FIFO_DATA_WIDTH -1 : 0] spike_out_fifo_data_i,

    // Connection to Output Buffer
    input reg output_buffer_full_i,
    output reg output_buffer_write_enable_o,
    output reg [OUTPUT_BUFFER_DATA_WIDTH -1 : 0] output_buffer_data_o,

    // Done logic
    input neuron_done_i,
    output reg axon_done_o,

    // Expose Route URAM Write Port
    input ram_routes_write_enable_i,
    input [URAM_ROUTES_ADDR_WIDTH -1 :0] ram_routes_write_addr_i,
    input [URAM_ROUTES_DATA_WIDTH -1 :0] ram_routes_data_i,

    // Expose URAM Memory mapping RAM Write Port
    input uram_memory_mapping_ram_write_en_i,
    input [URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH -1 : 0] uram_memory_mapping_ram_write_addr_i,
    input [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH -1 : 0] uram_memory_mapping_ram_data_in_i
);

  // Connection to Routes URAM read port
  wire ram_routes_read_en_w;
  reg ram_routes_read_en_internal;
  // Disable reading from routes RAM when module is not enabled
  assign ram_routes_read_en_w = ram_routes_read_en_internal & enable_i;
  
  reg [URAM_ROUTES_ADDR_WIDTH -1 : 0] ram_routes_read_addr_r;
  reg [$clog2(URAM_ROUTES_DATA_WIDTH/URAM_ROUTES_ENTRY_WIDTH) -1 : 0] ram_routes_read_entry_select;
  wire [URAM_ROUTES_ENTRY_WIDTH -1 : 0] ram_routes_data_o;

  // Connection to URAM memory mapping read port
  reg uram_memory_mapping_ram_read_en_r;
  reg [URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH -1 : 0] uram_memory_mapping_ram_read_addr_r;
  wire [URAM_MEMORY_MAPPING_RAM_DATA_WIDTH -1 : 0] uram_memory_mapping_ram_data_out_w;

  // Registers for routes memory region of a neuron
  reg [URAM_MEMORY_MAPPING_START_ADDR_WIDTH -1 : 0] neuron_routes_start_address;
  reg [URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH -1 : 0] neuron_routes_amount_of_mem_lines;
  reg [URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH -1 : 0] neuron_routes_amount_entries_last_line;

  // Registers to process a neuron
  reg process_neuron;
  reg [1:0] exec;
  reg [URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH -1 : 0] counter_mem_lines;
  reg [URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH -1 : 0] counter_entries;

  // Registers for done logic
  reg spike_out_fifo_empty;

  // Local params 
  localparam ENTRIES_PER_LINE = URAM_ROUTES_DATA_WIDTH / URAM_ROUTES_ENTRY_WIDTH;


  // DONE LOGIC

  assign axon_done_o = neuron_done_i & spike_out_fifo_empty & ~process_neuron & ~(|exec) & ~output_buffer_write_enable_o;


  // FSM: pop spike-out FIFO, fetch mapping RAM entry, then drive route URAM reads until the neuron is done.

  typedef enum reg [2:0] {
    STATE_READ_FIFO,
    STATE_WAIT_FIFO_POP,
    STATE_FIFO_RESULT,
    STATE_WAIT_MEM_COMP_READ,
    STATE_PROCESS_MEM_COMP_READ
  } axon_state_e;


  axon_state_e state;


  always @(posedge clk_i) begin
    if (rst_i) begin
      // spike_out_fifo_read_enable_o <= 0;
      // output_buffer_write_enable_o <= 0;
      // output_buffer_data_o <= 0;
      state <= STATE_READ_FIFO;
      ram_routes_read_en_internal <= 0;
      uram_memory_mapping_ram_read_en_r <= 0;
      neuron_routes_start_address <= 0;
      neuron_routes_amount_of_mem_lines <= 0;
      neuron_routes_amount_entries_last_line <= 0;
      process_neuron <= 0;
      exec <= 0;
      counter_mem_lines <= 0;
      counter_entries <= 0;
      spike_out_fifo_empty <= 0;
    end else if (enable_i) begin
      case (state)

        STATE_READ_FIFO: begin
          if (~process_neuron) begin
            spike_out_fifo_read_enable_o <= 1;
            state <= STATE_WAIT_FIFO_POP;
          end
        end

        STATE_WAIT_FIFO_POP: begin
          spike_out_fifo_read_enable_o <= 0;
          state <= STATE_FIFO_RESULT;
        end

        STATE_FIFO_RESULT: begin
          spike_out_fifo_read_enable_o <= 0;
          if (spike_out_fifo_read_valid_i) begin
            spike_out_fifo_empty <= 0;
            uram_memory_mapping_ram_read_addr_r <= spike_out_fifo_data_i;
            uram_memory_mapping_ram_read_en_r <= 1;
            state <= STATE_WAIT_MEM_COMP_READ;
          end else begin
            spike_out_fifo_empty <= 1;
            state <= STATE_READ_FIFO;
          end
        end

        STATE_WAIT_MEM_COMP_READ: begin
          uram_memory_mapping_ram_read_en_r <= 0;
          state <= STATE_PROCESS_MEM_COMP_READ;
        end

        STATE_PROCESS_MEM_COMP_READ: begin
          neuron_routes_start_address <= uram_memory_mapping_ram_data_out_w[0 +: URAM_MEMORY_MAPPING_START_ADDR_WIDTH];
          neuron_routes_amount_of_mem_lines <= uram_memory_mapping_ram_data_out_w[URAM_MEMORY_MAPPING_START_ADDR_WIDTH +: URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH];
          neuron_routes_amount_entries_last_line <= uram_memory_mapping_ram_data_out_w[(URAM_MEMORY_MAPPING_START_ADDR_WIDTH + URAM_MEMORY_MAPPING_AMOUNT_MEM_LINES_WIDTH) +: URAM_MEMORY_MAPPING_ENTRIES_LAST_MEM_LINE_WIDTH];
          process_neuron <= 1;
          state <= STATE_READ_FIFO;
        end
        default: begin
          spike_out_fifo_read_enable_o <= 0;
          uram_memory_mapping_ram_read_en_r <= 0;
        end

      endcase
    end else begin
      state <= STATE_READ_FIFO;
      spike_out_fifo_read_enable_o <= 0;
    end



    // Route URAM read pipeline: one route per cycle while process_neuron is set.

    if (enable_i) begin
      if (process_neuron) begin
        // Pause execution if output buffer signals full
        if (~output_buffer_full_i) begin

          // Stop processing immediately if there is no data for neuron (shouldn't be the case otherwise network has dead end)
          if (~(neuron_routes_amount_of_mem_lines > 0)) begin
            process_neuron <= 0;
          end else begin

            ram_routes_read_addr_r <= neuron_routes_start_address + counter_mem_lines;
            ram_routes_read_entry_select <= counter_entries;
            ram_routes_read_en_internal <= 1;
            exec <= {exec[0], 1'b1};

            // Special case for last memory line, because it is not guaranteed that this line is fully populated with entries
            if (counter_mem_lines == (neuron_routes_amount_of_mem_lines - 1)) begin
              if (counter_entries < (neuron_routes_amount_entries_last_line - 1)) begin // -1 because indexing of a line starts with 0
                counter_entries <= counter_entries + 1;
              end else begin
                counter_entries <= 0;
                counter_mem_lines <= 0;
                process_neuron <= 0;
              end
            end else begin
              // Count up read position
              if (counter_entries < (ENTRIES_PER_LINE - 1)) begin // -1 because indexing of a line starts with 0
                counter_entries <= counter_entries + 1;
              end else begin
                counter_entries   <= 0;
                counter_mem_lines <= counter_mem_lines + 1;
              end
            end
          end

        end else begin
          exec <= {exec[0], 1'b0};
        end

      end else begin
        exec <= {exec[0], 1'b0};
        counter_mem_lines <= 0;
        counter_entries <= 0;
        ram_routes_read_en_internal <= 0;
      end
    end
  end

  // Avoids wait cycle with direct assignment
  assign output_buffer_data_o = ram_routes_data_o;

  // Enables write to output buffer
  always_comb begin
    if (enable_i & exec[1]) begin
      output_buffer_write_enable_o <= 1;
    end else begin
      output_buffer_write_enable_o <= 0;
    end
  end


  // ------------- Memory instantiation -------------------

  // This memory allows a flexible addressation of the routes URAM
  // If the maximum amount of total routes is not exceeded the amount of routes per neuron is flexible
  //
  // It contains the information of a start address of a neuron, the amount of mem lines, 
  // and the amount of entries in the last mem lines. See also the comments at the beginning of this file.
  DUAL_PORT_RAM #(
      .ADDR_WIDTH(URAM_MEMORY_MAPPING_RAM_ADDR_WIDTH),
      .DATA_WIDTH(URAM_MEMORY_MAPPING_RAM_DATA_WIDTH),
      .INIT_MEM_FILE(URAM_MEMORY_MAPPING_RAM_INIT_FILE)

  ) uram_memory_mapping_ram (

      .clk_i(clk_i),

      .read_en_i(uram_memory_mapping_ram_read_en_r),
      .read_addr_i(uram_memory_mapping_ram_read_addr_r),
      .data_out(uram_memory_mapping_ram_data_out_w),

      .write_en_i(uram_memory_mapping_ram_write_en_i),
      .write_addr_i(uram_memory_mapping_ram_write_addr_i),
      .data_in(uram_memory_mapping_ram_data_in_i)
  );


  // This memory contains the routing information for all neurons of the core
  URAM #(
      .DATA_WIDTH(URAM_ROUTES_DATA_WIDTH),
      .ADDR_WIDTH(URAM_ROUTES_ADDR_WIDTH),
      .ENTRY_WIDTH(URAM_ROUTES_ENTRY_WIDTH),
      .BYTE_WIDTH(URAM_ROUTES_BYTE_WIDTH),
      .INIT_MEM_FILE(URAM_ROUTES_INIT_FILE)

  ) axon_uram (

      .clk_i(clk_i),

      .we_i(ram_routes_write_enable_i),
      .write_addr_i(ram_routes_write_addr_i),
      .data_i(ram_routes_data_i),

      .re_i(ram_routes_read_en_w),
      .read_addr_i(ram_routes_read_addr_r),
      .read_entry_select_i(ram_routes_read_entry_select),
      .data_o(ram_routes_data_o)
  );

endmodule
