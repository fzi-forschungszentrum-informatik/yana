`default_nettype none

module Adder_Subtractor_Binary_Saturating
#(
    parameter       WORD_WIDTH          = 0
)
(
    input   wire    [WORD_WIDTH-1:0]    limit_max,
    input   wire    [WORD_WIDTH-1:0]    limit_min,
    input   wire                        add_sub,    // 0/1 -> A+B/A-B
    input   wire                        carry_in,
    input   wire    [WORD_WIDTH-1:0]    A,
    input   wire    [WORD_WIDTH-1:0]    B,
    output  reg     [WORD_WIDTH-1:0]    sum,
    output  reg                         carry_out,
    output  reg     [WORD_WIDTH-1:0]    carries,
    output  wire                        at_limit_max,
    output  wire                        over_limit_max,
    output  wire                        at_limit_min,
    output  wire                        under_limit_min
);

    localparam WORD_ZERO            = {WORD_WIDTH{1'b0}};
    localparam WORD_WIDTH_EXTENDED  = WORD_WIDTH + 1;
    localparam WORD_ZERO_EXTENDED   = {WORD_WIDTH_EXTENDED{1'b0}};

    initial begin
        sum         = WORD_ZERO;
        carry_out   = 1'b0;
        carries     = WORD_ZERO;
    end

    wire [WORD_WIDTH_EXTENDED-1:0] A_extended;

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (WORD_WIDTH),
        .SIGNED         (1),
        .WORD_WIDTH_OUT (WORD_WIDTH_EXTENDED)
    )
    extend_A
    (
        .original_input     (A),
        .adjusted_output    (A_extended)
    );

    wire [WORD_WIDTH_EXTENDED-1:0] B_extended;

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (WORD_WIDTH),
        .SIGNED         (1),
        .WORD_WIDTH_OUT (WORD_WIDTH_EXTENDED)
    )
    extend_B
    (
        .original_input     (B),
        .adjusted_output    (B_extended)
    );

    wire [WORD_WIDTH_EXTENDED-1:0] limit_max_extended;

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (WORD_WIDTH),
        .SIGNED         (1),
        .WORD_WIDTH_OUT (WORD_WIDTH_EXTENDED)
    )
    extend_limit_max
    (
        .original_input     (limit_max),
        .adjusted_output    (limit_max_extended)
    );

    wire [WORD_WIDTH_EXTENDED-1:0] limit_min_extended;

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (WORD_WIDTH),
        .SIGNED         (1),
        .WORD_WIDTH_OUT (WORD_WIDTH_EXTENDED)
    )
    extend_limit_min
    (
        .original_input     (limit_min),
        .adjusted_output    (limit_min_extended)
    );

    wire [WORD_WIDTH_EXTENDED-1:0] sum_extended;
    wire [WORD_WIDTH_EXTENDED-1:0] carries_extended;

    Adder_Subtractor_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH_EXTENDED)
    )
    extended_add_sub
    (
        .add_sub    (add_sub), // 0/1 -> A+B/A-B
        .carry_in   (carry_in),
        .A          (A_extended),
        .B          (B_extended),
        .sum        (sum_extended),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out  (),
        .carries    (carries_extended),
        .overflow   ()
        // verilator lint_on  PINCONNECTEMPTY
    );

    always @(*) begin
        carry_out = carries_extended [WORD_WIDTH_EXTENDED-1];
        carries   = carries_extended [WORD_WIDTH-1:0];
    end

    Arithmetic_Predicates_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH_EXTENDED)
    )
    limit_max_check
    (
        .A                  (sum_extended),
        .B                  (limit_max_extended),
        
        // verilator lint_off PINCONNECTEMPTY
        .A_eq_B             (at_limit_max),
        
        .A_lt_B_unsigned    (),
        .A_lte_B_unsigned   (),
        .A_gt_B_unsigned    (),
        .A_gte_B_unsigned   (),
        
        .A_lt_B_signed      (),
        .A_lte_B_signed     (),
        .A_gt_B_signed      (over_limit_max),
        .A_gte_B_signed     ()
        // verilator lint_on  PINCONNECTEMPTY
    );

    Arithmetic_Predicates_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH_EXTENDED)
    )
    limit_min_check
    (
        .A                  (sum_extended),
        .B                  (limit_min_extended),
        
        // verilator lint_off PINCONNECTEMPTY
        .A_eq_B             (at_limit_min),
        
        .A_lt_B_unsigned    (),
        .A_lte_B_unsigned   (),
        .A_gt_B_unsigned    (),
        .A_gte_B_unsigned   (),
        
        .A_lt_B_signed      (under_limit_min),
        .A_lte_B_signed     (),
        .A_gt_B_signed      (),
        .A_gte_B_signed     ()
        // verilator lint_on  PINCONNECTEMPTY
    );

    reg [WORD_WIDTH_EXTENDED-1:0] sum_extended_clipped = WORD_ZERO_EXTENDED;

    always @(*) begin
        sum_extended_clipped = (over_limit_max  == 1'b1) ? limit_max_extended : sum_extended;
        sum_extended_clipped = (under_limit_min == 1'b1) ? limit_min_extended : sum_extended_clipped;
        sum                  = sum_extended_clipped [WORD_WIDTH-1:0];
    end

endmodule
