`default_nettype none

module Serial_Parallel
#(
    parameter WORD_WIDTH = 0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,
    input   wire                        clear,

    output  reg                         parallel_out_valid,
    input   wire                        parallel_out_ready,
    output  wire    [WORD_WIDTH-1:0]    parallel_out,

    input   wire                        serial_in
);

    `include "clog2_function.vh"

    localparam WORD_ZERO   = {WORD_WIDTH{1'b0}};
    localparam COUNT_WIDTH = clog2(WORD_WIDTH);
    localparam COUNT_ZERO  = {COUNT_WIDTH{1'b0}};

    localparam COUNT_BITS_INITIAL   = WORD_WIDTH - 1;
    localparam COUNT_BITS_NEXT      = WORD_WIDTH - 2;

    initial begin
        parallel_out_valid = 1'b0; // We start empty, so ready to shift-in.
    end

    // Counter for the number of bit shifts remaining.
    reg                     counter_run  = 1'b0;
    reg                     counter_load = 1'b0;
    wire [COUNT_WIDTH-1:0]  count;

    Counter_Binary
    #(
        .WORD_WIDTH     (COUNT_WIDTH),
        .INCREMENT      (1),
        .INITIAL_COUNT  (COUNT_BITS_INITIAL [COUNT_WIDTH-1:0])
    )
    shifts_remaining
    (
        .clock          (clock),
        .clear          (clear),
        .up_down        (1'b1), // 0 up, 1 down
        .run            (counter_run),
        .load           (counter_load),
        .load_count     (COUNT_BITS_NEXT [COUNT_WIDTH-1:0]),
        .carry_in       (1'b0),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      (),
        .carries        (),
        .overflow       (),
        // verilator lint_on  PINCONNECTEMPTY
        .count          (count)
    );

    // Shift register for the serial input bits.
    reg shifter_run  = 1'b0;

    Register_Pipeline
    #(
        .WORD_WIDTH     (1),
        .PIPE_DEPTH     (WORD_WIDTH),
        .RESET_VALUES   (WORD_ZERO)
    )
    shift_register
    (
        .clock          (clock),
        .clock_enable   (shifter_run),
        .clear          (clear),
        .parallel_load  (1'b0),
        .parallel_in    (WORD_ZERO),
        .parallel_out   (parallel_out),
        .pipe_in        (serial_in),
        // verilator lint_off PINCONNECTEMPTY
        .pipe_out       ()
        // verilator lint_on  PINCONNECTEMPTY
    );

    reg handshake_done = 1'b0;

    always @(*) begin
        parallel_out_valid  = (count == COUNT_ZERO) && (clock_enable == 1'b1);
        handshake_done      = (parallel_out_valid == 1'b1) && (parallel_out_ready == 1'b1);

        counter_run         = (count != COUNT_ZERO) && (clock_enable == 1'b1);
        counter_load        = (handshake_done == 1'b1);

        shifter_run         = (counter_run == 1'b1) || (counter_load == 1'b1);
    end

endmodule
