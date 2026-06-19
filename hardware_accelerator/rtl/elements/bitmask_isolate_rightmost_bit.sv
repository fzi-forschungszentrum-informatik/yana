`default_nettype none

module Bitmask_Isolate_Rightmost_1_Bit
#(
    parameter WORD_WIDTH = 0
)
(
    input   wire    [WORD_WIDTH-1:0]    word_in,
    output  reg     [WORD_WIDTH-1:0]    word_out
);

    initial begin
        word_out = {WORD_WIDTH{1'b0}};
    end

    always @(*) begin
        word_out = word_in & (-word_in);
    end

endmodule