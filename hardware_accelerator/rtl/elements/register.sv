`default_nettype none

module Register
#(
    parameter WORD_WIDTH  = 0,
    parameter RESET_VALUE = 0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,
    input   wire                        clear,
    input   wire    [WORD_WIDTH-1:0]    data_in,
    output  reg     [WORD_WIDTH-1:0]    data_out
);

    initial begin
        data_out = RESET_VALUE;
    end

    always @(posedge clock) begin
        if (clock_enable == 1'b1) begin
            data_out <= data_in;
        end

        if (clear == 1'b1) begin
            data_out <= RESET_VALUE;
        end
    end

endmodule