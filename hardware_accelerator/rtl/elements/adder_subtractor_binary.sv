`default_nettype none

module Adder_Subtractor_Binary
#(
    parameter       WORD_WIDTH = 0
)
(
    input   wire                        add_sub,    // 0/1 -> A+B/A-B
    input   wire                        carry_in,
    input   wire    [WORD_WIDTH-1:0]    A,
    input   wire    [WORD_WIDTH-1:0]    B,
    output  reg     [WORD_WIDTH-1:0]    sum,
    output  reg                         carry_out,
    output  wire    [WORD_WIDTH-1:0]    carries,
    output  reg                         overflow
);

    localparam ZERO = {WORD_WIDTH{1'b0}};
    localparam ONE  = {{WORD_WIDTH-1{1'b0}},1'b1};

    initial begin
        sum         = ZERO;
        carry_out   = 1'b0;
        overflow    = 1'b0;
    end

    wire [WORD_WIDTH-1:0] carry_in_extended_unsigned;
    wire [WORD_WIDTH-1:0] carry_in_extended_signed;

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (1),
        .SIGNED         (0),
        .WORD_WIDTH_OUT (WORD_WIDTH)
    )
    extend_carry_in_unsigned
    (
        .original_input     (carry_in),
        .adjusted_output    (carry_in_extended_unsigned)
    );

    Width_Adjuster
    #(
        .WORD_WIDTH_IN  (1),
        .SIGNED         (1),
        .WORD_WIDTH_OUT (WORD_WIDTH)
    )
    extend_carry_in_signed
    (
        .original_input     (carry_in),
        .adjusted_output    (carry_in_extended_signed)
    );

    reg [WORD_WIDTH-1:0] B_selected         = ZERO;
    reg [WORD_WIDTH-1:0] negation_offset    = ZERO;
    reg [WORD_WIDTH-1:0] carry_in_selected  = ZERO;

    always @(*) begin
        B_selected          = (add_sub == 1'b0) ? B    : ~B;
        negation_offset     = (add_sub == 1'b0) ? ZERO : ONE;
        carry_in_selected   = (add_sub == 1'b0) ? carry_in_extended_unsigned : carry_in_extended_signed;
    end

    always @(*) begin
        {carry_out, sum} = {1'b0, A} + {1'b0, B_selected} + {1'b0, negation_offset} + {1'b0, carry_in_selected};
    end

    CarryIn_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH)
    )
    per_bit
    (
        .A          (A),
        .B          (B_selected),
        .sum        (sum),
        .carryin    (carries)
    );

    always @(*) begin
        overflow = (carries [WORD_WIDTH-1] != carry_out);
    end

endmodule