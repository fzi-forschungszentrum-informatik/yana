`default_nettype none

module Demultiplexer_One_Hot
#(
    parameter       BROADCAST           = 0,
    parameter       WORD_WIDTH          = 0,
    parameter       OUTPUT_COUNT        = 0,
    parameter       IMPLEMENTATION      = "AND",

    // Do not set at instantiation
    parameter   TOTAL_WIDTH = WORD_WIDTH * OUTPUT_COUNT
)
(
    input   wire    [OUTPUT_COUNT-1:0]  selectors,
    input   wire    [WORD_WIDTH-1:0]    word_in,
    output  reg     [TOTAL_WIDTH-1:0]   words_out,
    output  reg     [OUTPUT_COUNT-1:0]  valids_out
);

    localparam OUTPUT_ZERO = {OUTPUT_COUNT{1'b0}};
    localparam TOTAL_ZERO  = {TOTAL_WIDTH{1'b0}};

    initial begin
        words_out  = TOTAL_ZERO;
        valids_out = OUTPUT_ZERO;
    end

    always @(*) begin
        valids_out = selectors;
    end

    generate
        if (BROADCAST == 0) begin : gen_no_broadcast
            wire [TOTAL_WIDTH-1:0] words_out_internal;

            genvar i;
            for (i=0; i < OUTPUT_COUNT; i=i+1) begin: per_output
                Annuller
                #(
                    .WORD_WIDTH     (WORD_WIDTH),
                    .IMPLEMENTATION (IMPLEMENTATION)
                )
                output_gate
                (
                    .annul          (selectors[i] == 1'b0),
                    .data_in        (word_in),
                    .data_out       (words_out_internal[WORD_WIDTH*i +: WORD_WIDTH])
                );
            end

            always @(*) begin
                words_out = words_out_internal;
            end
        end
        else
        if (BROADCAST == 1) begin : gen_broadcast
            always @(*) begin
                words_out = {OUTPUT_COUNT{word_in}};
            end
        end
    endgenerate

endmodule