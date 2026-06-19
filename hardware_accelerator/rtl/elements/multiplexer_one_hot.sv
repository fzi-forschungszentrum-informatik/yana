`default_nettype none

module Multiplexer_One_Hot
#(
    parameter       WORD_WIDTH          = 0,
    parameter       WORD_COUNT          = 0,
    parameter       OPERATION           = "OR",
    parameter       IMPLEMENTATION      = "AND",

    // Do not set at instantiation
    parameter   TOTAL_WIDTH = WORD_COUNT * WORD_WIDTH
)
(
    input   wire    [WORD_COUNT-1:0]    selectors,
    input   wire    [TOTAL_WIDTH-1:0]   words_in,
    output  wire    [WORD_WIDTH-1:0]    word_out
);

wire [TOTAL_WIDTH-1:0] words_in_selected;

generate

    genvar i;

    for (i=0; i < WORD_COUNT; i=i+1) begin : per_word

        Annuller
        #(
            .WORD_WIDTH     (WORD_WIDTH),
            .IMPLEMENTATION (IMPLEMENTATION)
        )
        select_input
        (
            .annul       (selectors[i] == 1'b0),
            .data_in     (words_in          [WORD_WIDTH*i +: WORD_WIDTH]),
            .data_out    (words_in_selected [WORD_WIDTH*i +: WORD_WIDTH])
        );

    end

endgenerate

Word_Reducer
#(
    .OPERATION  (OPERATION),
    .WORD_WIDTH (WORD_WIDTH),
    .WORD_COUNT (WORD_COUNT)
)
combine_words
(
    .words_in   (words_in_selected),
    .word_out   (word_out)
);

endmodule