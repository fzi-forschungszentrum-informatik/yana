`default_nettype none

module Register_Toggle
#(
    parameter WORD_WIDTH  = 0,
    parameter RESET_VALUE = 0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,
    input   wire                        clear,
    input   wire                        toggle,
    input   wire    [WORD_WIDTH-1:0]    data_in,
    output  wire    [WORD_WIDTH-1:0]    data_out
);

    reg [WORD_WIDTH-1:0] new_value = {WORD_WIDTH{1'b0}};

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (RESET_VALUE)
    )
    Register
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (clear),
        .data_in        (new_value),
        .data_out       (data_out)
    );

    always @(*) begin
        new_value = (toggle == 1'b1) ? ~data_out : data_in;
    end

endmodule