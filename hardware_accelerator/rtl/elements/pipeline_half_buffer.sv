`default_nettype none

module Pipeline_Half_Buffer
#(
    parameter WORD_WIDTH            = 0,
    parameter CIRCULAR_BUFFER       = 0     // non-zero to enable
)
(
    input  wire                     clock,
    input  wire                     clear,

    input  wire                     input_valid,
    output wire                     input_ready,
    input  wire [WORD_WIDTH-1:0]    input_data,

    output wire                     output_valid,
    input  wire                     output_ready,
    output wire [WORD_WIDTH-1:0]    output_data
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};

    reg half_buffer_load = 1'b0;

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (WORD_ZERO)
    )
    half_buffer
    (
        .clock          (clock),
        .clock_enable   (half_buffer_load),
        .clear          (clear),
        .data_in        (input_data),
        .data_out       (output_data)
    );

    wire buffer_full;
    reg  buffer_full_next = 1'b0;

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    empty_full
    (
        .clock          (clock),
        .clock_enable   (1'b1),
        .clear          (clear),
        .data_in        (buffer_full_next),
        .data_out       (buffer_full)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b1) // EMPTY at start, so accept data
    )
    input_ready_reg
    (
        .clock          (clock),
        .clock_enable   (1'b1),
        .clear          (clear),
        .data_in        ((buffer_full_next == 1'b0) || (CIRCULAR_BUFFER != 0)),
        .data_out       (input_ready)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    output_valid_reg
    (
        .clock          (clock),
        .clock_enable   (1'b1),
        .clear          (clear),
        .data_in        (buffer_full_next == 1'b1),
        .data_out       (output_valid)
    );

    reg insert = 1'b0;
    reg remove = 1'b0;

    always @(*) begin
        insert = (input_valid  == 1'b1) && (input_ready  == 1'b1);
        remove = (output_valid == 1'b1) && (output_ready == 1'b1);
    end

    always @(*) begin
        buffer_full_next = (insert == 1'b1) ? 1'b1 :
                           (remove == 1'b1) ? 1'b0 : buffer_full;
        half_buffer_load = (insert == 1'b1);
    end

endmodule
