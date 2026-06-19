`default_nettype none

module Pipeline_Sink
#(
    parameter WORD_WIDTH        = 0,
    parameter IMPLEMENTATION    = "AND"
)
(
    input   wire                        sink,

    input   wire                        input_valid,
    output  reg                         input_ready,
    input   wire    [WORD_WIDTH-1:0]    input_data,

    output  wire                        output_valid,
    input   wire                        output_ready,
    output  wire    [WORD_WIDTH-1:0]    output_data
);

    initial begin
        input_ready = 1'b0;
    end

    localparam FORWARD_WIDTH = WORD_WIDTH + 1;

    Annuller
    #(
        .WORD_WIDTH     (FORWARD_WIDTH),
        .IMPLEMENTATION (IMPLEMENTATION)
    )
    forward_sink
    (
        .annul          (sink),
        .data_in        ({input_data,  input_valid}),
        .data_out       ({output_data, output_valid})
    );

    always @(*) begin
        input_ready = (sink == 1'b1) ? 1'b1 : output_ready;
    end

endmodule
