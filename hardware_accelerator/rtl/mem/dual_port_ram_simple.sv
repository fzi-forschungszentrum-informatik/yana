`timescale 1ns / 1ps

`include "global_params.vh"

(* dont_touch = "yes" *)
module DualPortRamSimple #(
  parameter VENDOR = VENDOR_G,
  parameter ADDR_WIDTH = 10,
  parameter DATA_WIDTH = 32,
  parameter INIT_MEM_FILE = ""
)(
  input  logic clk_i,

  input  logic read_en_i,
  input  logic [ADDR_WIDTH-1:0] read_addr_i,
  output logic [DATA_WIDTH-1:0] data_o,

  input  logic write_en_i,
  input  logic [ADDR_WIDTH-1:0] write_addr_i,
  input  logic [DATA_WIDTH-1:0] data_i,

  input  logic sleep_i,
  output logic awake_o
);

  logic sleep_q;
  logic [1:0] wake_counter_q, wake_counter_d;
  logic awake_d;

  // Sleep/Awake Control
  always_comb begin
    wake_counter_d = wake_counter_q;
    awake_d = 1'b1;
    
    if (sleep_i && !sleep_q) begin
      awake_d = 1'b0;
      wake_counter_d = 2'b00;
    end
    else if (!sleep_i && sleep_q) begin
      awake_d = 1'b0;
      wake_counter_d = 2'b01;
    end
    else if (!sleep_i && wake_counter_q > 2'b00 && wake_counter_q < 2'b11) begin
      awake_d = 1'b0;
      wake_counter_d = wake_counter_q + 1'b1;
    end
    else if (!sleep_i && wake_counter_q == 2'b11) begin
      awake_d = 1'b1;
      wake_counter_d = 2'b00;
    end
    else if (!sleep_i && wake_counter_q == 2'b00) begin
      awake_d = 1'b1;
    end
    else if (sleep_i) begin
      awake_d = 1'b0;
      wake_counter_d = 2'b00;
    end
  end

  always_ff @(posedge clk_i) begin
    sleep_q <= sleep_i;
    wake_counter_q <= wake_counter_d;
    awake_o <= awake_d;
  end

  // Memory
  generate
    if (VENDOR != "XILINX") begin : gen_generic_ram
      (* ram_style="block" *)
      logic [DATA_WIDTH-1:0] ram [(2**ADDR_WIDTH)-1:0];

      initial begin
        if (INIT_MEM_FILE != "") begin
          $display("Writing Memory (DualPortRamSimple.sv - Generic)");
          $readmemh(INIT_MEM_FILE, ram);
        end
      end

      always_ff @(posedge clk_i) begin
        if (read_en_i) begin
          data_o <= ram[read_addr_i];
        end

        if (write_en_i) begin
          ram[write_addr_i] <= data_i;
        end
      end

    end else begin : gen_xilinx_xpm

      xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(DATA_WIDTH),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_BIT_RANGE("7:0"),
        .ECC_MODE("no_ecc"),
        .ECC_TYPE("none"),
        .IGNORE_INIT_SYNTH(0),
        .MEMORY_INIT_FILE(INIT_MEM_FILE == "" ? "none" : INIT_MEM_FILE),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE((2**ADDR_WIDTH) * DATA_WIDTH),
        .MESSAGE_CONTROL(0),
        .RAM_DECOMP("auto"),
        .READ_DATA_WIDTH_B(DATA_WIDTH),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(1),
        .USE_MEM_INIT_MMI(0),
        .WAKEUP_TIME("use_sleep_pin"),
        .WRITE_DATA_WIDTH_A(DATA_WIDTH),
        .WRITE_MODE_B("no_change"),
        .WRITE_PROTECT(1)
      ) xpm_memory_sdpram_inst (
        .dbiterrb(),
        .doutb(data_o),
        .sbiterrb(),
        .addra(write_addr_i),
        .addrb(read_addr_i),
        .clka(clk_i),
        .clkb(clk_i),
        .dina(data_i),
        .ena(write_en_i),
        .enb(read_en_i),
        .injectdbiterra(1'b0),
        .injectsbiterra(1'b0),
        .regceb(1'b1),
        .rstb(1'b0),
        .sleep(sleep_i),
        .wea(write_en_i)
      );

    end
  endgenerate

endmodule
