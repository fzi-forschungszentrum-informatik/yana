`default_nettype none

module Counter_Binary
#(
    parameter                   WORD_WIDTH      = 0,
    parameter [WORD_WIDTH-1:0]  INCREMENT       = 0,
    parameter [WORD_WIDTH-1:0]  INITIAL_COUNT   = 0
)
(
    input   wire                        clock,
    input   wire                        clear,

    input   wire                        up_down, // 0/1 --> up/down
    input   wire                        run,

    input   wire                        load,
    input   wire    [WORD_WIDTH-1:0]    load_count,

    input   wire                        carry_in,
    output  wire                        carry_out,
    output  wire    [WORD_WIDTH-1:0]    carries,
    output  wire                        overflow,

    output  wire    [WORD_WIDTH-1:0]    count
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};

    wire [WORD_WIDTH-1:0] incremented_count;
    wire                  carry_out_internal;
    wire [WORD_WIDTH-1:0] carries_internal;
    wire                  overflow_internal;

    Adder_Subtractor_Binary
    #(
        .WORD_WIDTH (WORD_WIDTH)
    )
    calc_next_count
    (
        .add_sub    (up_down), // 0/1 -> A+B/A-B
        .carry_in   (carry_in),
        .A          (count),
        .B          (INCREMENT),
        .sum        (incremented_count),
        .carry_out  (carry_out_internal),
        .carries    (carries_internal),
        .overflow   (overflow_internal)
    );

    reg [WORD_WIDTH-1:0]    next_count      = WORD_ZERO;
    reg                     load_counter    = 0;
    reg                     clear_counter   = 0;
    reg                     load_flags      = 0;
    reg                     clear_flags     = 0;

    always @(*) begin
        next_count      = (load  == 1'b1) ? load_count : incremented_count;
        load_counter    = (run   == 1'b1) || (load == 1'b1);
        clear_counter   = (clear == 1'b1);
        load_flags      = (run   == 1'b1);
        clear_flags     = (load  == 1'b1) || (clear == 1'b1);
    end

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (INITIAL_COUNT)
    )
    count_storage
    (
        .clock          (clock),
        .clock_enable   (load_counter),
        .clear          (clear_counter),
        .data_in        (next_count),
        .data_out       (count)
    );

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (WORD_ZERO)
    )
    carries_storage
    (
        .clock          (clock),
        .clock_enable   (load_flags),
        .clear          (clear_flags),
        .data_in        (carries_internal),
        .data_out       (carries)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    carry_out_storage
    (
        .clock          (clock),
        .clock_enable   (load_flags),
        .clear          (clear_flags),
        .data_in        (carry_out_internal),
        .data_out       (carry_out)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    overflow_storage
    (
        .clock          (clock),
        .clock_enable   (load_flags),
        .clear          (clear_flags),
        .data_in        (overflow_internal),
        .data_out       (overflow)
    );

endmodule