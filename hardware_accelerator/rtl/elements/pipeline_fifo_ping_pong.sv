`default_nettype none

module Pipeline_FIFO_Ping_Pong
#(
    parameter WORD_WIDTH                = 32,
    parameter DEPTH                     = 1024,
    parameter RAMSTYLE                  = "",
    parameter CIRCULAR_BUFFER           = 0         // non-zero to enable
)
(
    input   wire                        clock,
    input   wire                        clear,

    // Control signal to swap the FIFOs
    // 0: Write to FIFO 0, Read from FIFO 1
    // 1: Write to FIFO 1, Read from FIFO 0
    input   wire                        selector,

    // --- Single Write-Side Port ---
    input   wire                        input_valid,
    output  wire                        input_ready,
    input   wire    [WORD_WIDTH-1:0]    input_data,

    // --- Single Read-Side Port ---
    output  wire                        output_valid,
    input   wire                        output_ready,
    output  wire    [WORD_WIDTH-1:0]    output_data,

    output wire                         empty
);

    // Internal wires to connect to the two FIFO instances
    wire    fifo_0_input_valid;
    wire    fifo_0_input_ready;
    wire    fifo_0_output_valid;
    wire    fifo_0_output_ready;
    wire    [WORD_WIDTH-1:0] fifo_0_output_data;
    wire    fifo_0_empty;

    wire    fifo_1_input_valid;
    wire    fifo_1_input_ready;
    wire    fifo_1_output_valid;
    wire    fifo_1_output_ready;
    wire    [WORD_WIDTH-1:0] fifo_1_output_data;
    wire    fifo_1_empty;


    // --- MUX Logic for routing signals based on selector ---

    // The external write port is routed to one of the internal FIFOs.
    // The non-selected FIFO receives a 'valid' of 0 to prevent writes.
    assign fifo_0_input_valid = (selector == 1'b0) ? input_valid : 1'b0;
    assign fifo_1_input_valid = (selector == 1'b1) ? input_valid : 1'b0;

    // The external input_ready is taken from the currently selected write-FIFO.
    assign input_ready = (selector == 1'b0) ? fifo_0_input_ready : fifo_1_input_ready;

    // The external read port is routed from the other internal FIFO.
    assign output_valid = (selector == 1'b0) ? fifo_1_output_valid : fifo_0_output_valid;
    assign output_data  = (selector == 1'b0) ? fifo_1_output_data  : fifo_0_output_data;

    // The external output_ready is routed to the currently selected read-FIFO.
    // The non-selected FIFO receives a 'ready' of 0 to prevent reads.
    assign fifo_0_output_ready = (selector == 1'b1) ? output_ready : 1'b0;
    assign fifo_1_output_ready = (selector == 1'b0) ? output_ready : 1'b0;

    assign empty = fifo_0_empty & fifo_1_empty;

    // --- FIFO Instantiations ---

    // First Pipeline FIFO instance (Ping)
    Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(WORD_WIDTH),
        .DEPTH(DEPTH),
        .RAMSTYLE(RAMSTYLE),
        .CIRCULAR_BUFFER(CIRCULAR_BUFFER)
    )
    fifo_0 (
        .clock          (clock),
        .clear          (clear),

        .input_valid    (fifo_0_input_valid),
        .input_ready    (fifo_0_input_ready),
        .input_data     (input_data),       // Data is broadcast, 'valid' selects

        .output_valid   (fifo_0_output_valid),
        .output_ready   (fifo_0_output_ready),
        .output_data    (fifo_0_output_data),
        .empty          (fifo_0_empty)
    );

    // Second Pipeline FIFO instance (Pong)
    Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(WORD_WIDTH),
        .DEPTH(DEPTH),
        .RAMSTYLE(RAMSTYLE),
        .CIRCULAR_BUFFER(CIRCULAR_BUFFER)
    )
    fifo_1 (
        .clock          (clock),
        .clear          (clear),

        .input_valid    (fifo_1_input_valid),
        .input_ready    (fifo_1_input_ready),
        .input_data     (input_data),       // Data is broadcast, 'valid' selects

        .output_valid   (fifo_1_output_valid),
        .output_ready   (fifo_1_output_ready),
        .output_data    (fifo_1_output_data),
        .empty          (fifo_1_empty)
    );

endmodule
