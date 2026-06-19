`default_nettype none

module Word_Reducer
#(
    parameter OPERATION  = "",
    parameter WORD_WIDTH = 0,
    parameter WORD_COUNT = 0,

    // Don't change at instantiation
    parameter TOTAL_WIDTH = WORD_WIDTH * WORD_COUNT
)
(
    input   wire    [TOTAL_WIDTH-1:0]   words_in,
    output  wire    [WORD_WIDTH-1:0]    word_out
);

    localparam BIT_ZERO  = {WORD_COUNT{1'b0}};

    generate

        genvar i, j;

        for (j=0; j < WORD_WIDTH; j=j+1) begin : per_bit

            reg [WORD_COUNT-1:0] bit_word = BIT_ZERO;

            for (i=0; i < WORD_COUNT; i=i+1) begin : per_word
                always @(*) begin
                    bit_word[i] = words_in[(WORD_WIDTH*i)+j];
                end
            end

            Bit_Reducer
            #(
                .OPERATION      (OPERATION),
                .INPUT_COUNT    (WORD_COUNT)
            )
            bit_position
            (
                .bits_in        (bit_word),
                .bit_out        (word_out[j])
            );
        end

    endgenerate

endmodule