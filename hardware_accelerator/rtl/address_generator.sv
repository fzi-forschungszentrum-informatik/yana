`timescale 1ns / 1ps

module AddressGenerator #(
    parameter ADDR_WIDTH  = 32
) (
    input  logic                   clk_i,
    input  logic                   rst_i,
    input  logic                   enable_i,
    input  logic                   start_i,
    input  logic [ADDR_WIDTH-1:0]  start_addr_i,
    input  logic [ADDR_WIDTH-1:0]  end_addr_i,
    output logic                   valid_o,
    output logic [ADDR_WIDTH-1:0]  addr_o,
    output logic                   idle_o
);

  localparam ADDR_MAX = {ADDR_WIDTH{1'b1}};

  typedef enum logic {
    IDLE,
    COUNTING
  } addr_gen_state_t;

  addr_gen_state_t        state_q, state_d;
  logic [ADDR_WIDTH-1:0]  addr_q,  addr_d;
  logic [ADDR_WIDTH-1:0]  start_addr_q, start_addr_d;
  logic [ADDR_WIDTH-1:0]  end_addr_q,   end_addr_d;
  logic                   valid_q, valid_d;
  logic [ADDR_WIDTH-1:0]  next_addr;
  logic [ADDR_WIDTH:0]    sum_ext;

  assign addr_o  = addr_q;
  assign idle_o  = (state_q == IDLE);
  assign valid_o = valid_q;

  always_comb begin
    state_d       = state_q;
    addr_d        = addr_q;
    start_addr_d  = start_addr_q;
    end_addr_d    = end_addr_q;
    valid_d       = 1'b0;
    next_addr     = start_addr_q;
    sum_ext       = '0;

    if (enable_i) begin
      case (state_q)
        IDLE: begin
          if (!start_i) begin
          end else if (start_addr_i > end_addr_i) begin
          end else begin
            start_addr_d = start_addr_i;
            end_addr_d   = end_addr_i;
            addr_d       = start_addr_i;
            state_d      = COUNTING;
            valid_d      = 1'b1;
          end
        end
        COUNTING: begin
          if ((addr_q == end_addr_q) || (addr_q == ADDR_MAX)) begin
            addr_d  = start_addr_q;
            state_d = IDLE;
            valid_d = 1'b0;
          end else begin
            sum_ext   = {1'b0, addr_q} + 1'b1;
            next_addr = (sum_ext > ADDR_MAX) ? ADDR_MAX : sum_ext[ADDR_WIDTH-1:0];
            addr_d    = next_addr;
            valid_d   = 1'b1;
          end
        end
        default: begin
          state_d = IDLE;
          addr_d  = start_addr_q;
        end
      endcase
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q      <= IDLE;
      addr_q       <= start_addr_i;
      start_addr_q <= start_addr_i;
      end_addr_q   <= end_addr_i;
      valid_q      <= 1'b0;
    end else begin
      state_q      <= state_d;
      addr_q       <= addr_d;
      start_addr_q <= start_addr_d;
      end_addr_q   <= end_addr_d;
      valid_q      <= valid_d;
    end
  end

endmodule
