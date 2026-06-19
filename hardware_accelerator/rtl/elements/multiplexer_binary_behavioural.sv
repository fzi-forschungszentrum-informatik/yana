`default_nettype none

module Multiplexer_Binary_Behavioural
#(
    parameter       WORD_WIDTH          = 0,
    parameter       ADDR_WIDTH          = 0,
    parameter       INPUT_COUNT         = 0,

    // Do not set at instantiation
    parameter   TOTAL_WIDTH = WORD_WIDTH * INPUT_COUNT
)
(
    input   wire    [ADDR_WIDTH-1:0]    selector,
    input   wire    [TOTAL_WIDTH-1:0]   words_in,
    output  reg     [WORD_WIDTH-1:0]    word_out
);

    initial begin
        word_out = {WORD_WIDTH{1'b0}};
    end

    always @(*) begin
        word_out = words_in[(selector * WORD_WIDTH) +: WORD_WIDTH];
    end

endmodule