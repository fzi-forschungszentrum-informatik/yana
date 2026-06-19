`default_nettype none

module CarryIn_Binary
#(
    parameter WORD_WIDTH = 0
)
(
    input   wire    [WORD_WIDTH-1:0]    A,
    input   wire    [WORD_WIDTH-1:0]    B,
    input   wire    [WORD_WIDTH-1:0]    sum,
    output  reg     [WORD_WIDTH-1:0]    carryin
);

    initial begin
        carryin = {WORD_WIDTH{1'b0}};
    end

    always @(*) begin
        carryin = A ^ B ^ sum;
    end

endmodule