`default_nettype none

module Pipeline_Branch_One_Hot
#(
    parameter WORD_WIDTH        = 0,
    parameter OUTPUT_COUNT      = 0,
    parameter IMPLEMENTATION    = "AND",

    // Do not set at instantiation, except in IPI
    parameter TOTAL_WIDTH = WORD_WIDTH * OUTPUT_COUNT
)
(
    input  wire [OUTPUT_COUNT-1:0]  selector,

    input  wire                     input_valid,
    output wire                     input_ready,
    input  wire [WORD_WIDTH-1:0]    input_data,

    output wire [OUTPUT_COUNT-1:0]  output_valid,
    input  wire [OUTPUT_COUNT-1:0]  output_ready,
    output wire [TOTAL_WIDTH-1:0]   output_data
);

    Multiplexer_One_Hot
    #(
        .WORD_WIDTH     (1),
        .WORD_COUNT     (OUTPUT_COUNT),
        .OPERATION      ("OR"),         // Other operations aren't meaningful here.
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    ready_mux
    (
        .selectors      (selector),
        .words_in       (output_ready),
        .word_out       (input_ready)
    );

    Demultiplexer_One_Hot
    #(
        .BROADCAST      (0),
        .WORD_WIDTH     (1),
        .OUTPUT_COUNT   (OUTPUT_COUNT),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    valid_demux
    (
        .selectors      (selector),
        .word_in        (input_valid),
        .words_out      (output_valid),
        // verilator lint_off PINCONNECTEMPTY
        .valids_out     ()
        // verilator lint_on  PINCONNECTEMPTY
    );

    Demultiplexer_One_Hot
    #(
        .BROADCAST      (0),
        .WORD_WIDTH     (WORD_WIDTH),
        .OUTPUT_COUNT   (OUTPUT_COUNT),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    data_demux
    (
        .selectors      (selector),
        .word_in        (input_data),
        .words_out      (output_data),
        // verilator lint_off PINCONNECTEMPTY
        .valids_out     ()
        // verilator lint_on  PINCONNECTEMPTY
    );

endmodule