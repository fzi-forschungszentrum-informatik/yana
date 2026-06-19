`default_nettype none

module Arithmetic_Predicates_Binary
#(
    parameter WORD_WIDTH = 0
)
(
    input   wire    [WORD_WIDTH-1:0]    A,
    input   wire    [WORD_WIDTH-1:0]    B,

    output  reg                         A_eq_B,

    output  reg                         A_lt_B_unsigned,
    output  reg                         A_lte_B_unsigned,
    output  reg                         A_gt_B_unsigned,
    output  reg                         A_gte_B_unsigned,

    output  reg                         A_lt_B_signed,
    output  reg                         A_lte_B_signed,
    output  reg                         A_gt_B_signed,
    output  reg                         A_gte_B_signed
);

    localparam ZERO = {WORD_WIDTH{1'b0}};

    initial begin
        A_eq_B              = 1'b0;
        A_lt_B_unsigned     = 1'b0;
        A_lte_B_unsigned    = 1'b0;
        A_gt_B_unsigned     = 1'b0;
        A_gte_B_unsigned    = 1'b0;
        A_lt_B_signed       = 1'b0;
        A_lte_B_signed      = 1'b0;
        A_gt_B_signed       = 1'b0;
        A_gte_B_signed      = 1'b0;
    end

    wire [WORD_WIDTH-1:0]   difference;
    wire                    carry_out;
    wire                    overflow_signed;

    Adder_Subtractor_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH)
    )
    subtraction
    (
        .add_sub    (1'b1),    // 0/1 -> A+B/A-B
        .carry_in   (1'b0),
        .A          (A),
        .B          (B),
        .sum        (difference),
        .carry_out  (carry_out),
        // verilator lint_off PINCONNECTEMPTY
        .carries    (),
        // verilator lint_on  PINCONNECTEMPTY
        .overflow   (overflow_signed)
    );

    reg negative = 1'b0;

    always @(*) begin
        negative            = (difference[WORD_WIDTH-1] == 1'b1);
        A_eq_B              = (difference == ZERO);

        A_lt_B_unsigned     = (carry_out == 1'b0);
        A_lte_B_unsigned    = (A_lt_B_unsigned == 1'b1) || (A_eq_B == 1'b1);
        A_gte_B_unsigned    = (carry_out == 1'b1);
        A_gt_B_unsigned     = (A_gte_B_unsigned == 1'b1) && (A_eq_B == 1'b0);

        A_lt_B_signed       = (negative != overflow_signed);
        A_lte_B_signed      = (A_lt_B_signed == 1'b1) || (A_eq_B == 1'b1);
        A_gte_B_signed      = (negative == overflow_signed);
        A_gt_B_signed       = (A_gte_B_signed == 1'b1) && (A_eq_B == 1'b0);
    end

endmodule
