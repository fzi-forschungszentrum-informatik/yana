`default_nettype none

module Pulse_Latch
#(
    parameter RESET_VALUE = 1'b0
)
(
    input   wire    clock,
    input   wire    clear,
    input   wire    pulse_in,
    output  wire    level_out
);

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (RESET_VALUE)
    )
    latch
    (
        .clock          (clock),
        .clock_enable   (pulse_in),
        .clear          (clear),
        .data_in        (1'b1),
        .data_out       (level_out)
    );

endmodule
