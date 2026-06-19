`default_nettype none

module Pipeline_Merge_One_Hot
#(
    parameter WORD_WIDTH        = 0,
    parameter INPUT_COUNT       = 0,
    parameter HANDSHAKE_MERGE   = "",
    parameter DATA_MERGE        = "",
    parameter IMPLEMENTATION    = "AND",

    // Do not set at instantiation, except in IPI
    parameter TOTAL_WIDTH   = WORD_WIDTH * INPUT_COUNT
)
(
    input  wire                     clock,
    input  wire                     clear,

    input  wire [INPUT_COUNT-1:0]   selector,

    input  wire [INPUT_COUNT-1:0]   input_valid,
    output wire [INPUT_COUNT-1:0]   input_ready,
    input  wire [TOTAL_WIDTH-1:0]   input_data,

    output wire                     output_valid,
    input  wire                     output_ready,
    output wire [WORD_WIDTH-1:0]    output_data
);


    wire input_valid_selected;

    Multiplexer_One_Hot
    #(
        .WORD_WIDTH     (1),
        .WORD_COUNT     (INPUT_COUNT),
        .OPERATION      (HANDSHAKE_MERGE),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    valid_mux
    (
        .selectors  (selector),
        .words_in   (input_valid),
        .word_out   (input_valid_selected)
    );


    wire [WORD_WIDTH-1:0] input_data_selected;

    Multiplexer_One_Hot
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .WORD_COUNT     (INPUT_COUNT),
        .OPERATION      (DATA_MERGE),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    data_out_mux
    (
        .selectors      (selector),
        .words_in       (input_data),
        .word_out       (input_data_selected)
    );

    wire input_ready_buffered;

    Demultiplexer_One_Hot
    #(
        .BROADCAST      (0),
        .WORD_WIDTH     (1),
        .OUTPUT_COUNT   (INPUT_COUNT),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    ready_in_demux
    (
        .selectors      (selector),
        .word_in        (input_ready_buffered),
        .words_out      (input_ready),
        // verilator lint_off PINCONNECTEMPTY
        .valids_out     ()
        // verilator lint_on  PINCONNECTEMPTY
    );


    Pipeline_Skid_Buffer
    #(
        .WORD_WIDTH      (WORD_WIDTH),
        .CIRCULAR_BUFFER (0)            // Not meaningful here
    )
    output_buffer
    (
        .clock          (clock),
        .clear          (clear),
        
        .input_valid    (input_valid_selected),
        .input_ready    (input_ready_buffered),
        .input_data     (input_data_selected),
        
        .output_valid   (output_valid),
        .output_ready   (output_ready),
        .output_data    (output_data)
    );

endmodule
