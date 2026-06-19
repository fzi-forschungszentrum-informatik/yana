`default_nettype none

module Accumulator_Binary_Saturating
#(
    parameter                   EXTRA_PIPE_STAGES   = -1,
    parameter                   WORD_WIDTH          =  0,
    parameter [WORD_WIDTH-1:0]  INITIAL_VALUE       =  0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,

    input   wire                        clear,
    output  wire                        clear_done,

    input   wire                        increment_carry_in,
    input   wire                        increment_add_sub,  // 0/1 --> +/-
    input   wire    [WORD_WIDTH-1:0]    increment_value,
    input   wire                        increment_valid,
    output  wire                        increment_done,

    input   wire    [WORD_WIDTH-1:0]    load_value,
    input   wire                        load_valid,
    output  wire                        load_done,

    input   wire    [WORD_WIDTH-1:0]    limit_max,
    input   wire    [WORD_WIDTH-1:0]    limit_min,

    output  wire    [WORD_WIDTH-1:0]    accumulated_value,
    output  wire                        accumulated_value_carry_out,
    output  wire    [WORD_WIDTH-1:0]    accumulated_value_carries,
    output  wire                        accumulated_value_at_limit_max,
    output  wire                        accumulated_value_over_limit_max,
    output  wire                        accumulated_value_at_limit_min,
    output  wire                        accumulated_value_under_limit_min
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};

    wire                    clear_pipelined;

    wire                    increment_carry_in_pipelined;
    wire                    increment_add_sub_pipelined;
    wire [WORD_WIDTH-1:0]   increment_value_pipelined;
    wire                    increment_valid_pipelined;

    wire [WORD_WIDTH-1:0]   load_value_pipelined;
    wire                    load_valid_pipelined;

    wire [WORD_WIDTH-1:0]   limit_max_pipelined;
    wire [WORD_WIDTH-1:0]   limit_min_pipelined;

    wire [WORD_WIDTH-1:0]   accumulated_value_pipelined;

    generate
        if (EXTRA_PIPE_STAGES == 0) begin : gen_no_pipe
            assign clear_pipelined              = clear;
            assign increment_carry_in_pipelined = increment_carry_in;
            assign increment_add_sub_pipelined  = increment_add_sub;
            assign increment_value_pipelined    = increment_value;
            assign increment_valid_pipelined    = increment_valid;
            assign load_value_pipelined         = load_value;
            assign load_valid_pipelined         = load_valid;
            assign limit_max_pipelined          = limit_max;
            assign limit_min_pipelined          = limit_min;
            assign increment_carry_in_pipelined = increment_carry_in;
            assign accumulated_value_pipelined  = accumulated_value;
        end
        else if (EXTRA_PIPE_STAGES > 0) begin: gen_extra_pipe

            localparam PIPELINE_WIDTH       = (WORD_WIDTH * 5) + 5;
            localparam PIPELINE_WORD_ZERO   = {PIPELINE_WIDTH{1'b0}};
            localparam PIPELINE_ZERO        = {EXTRA_PIPE_STAGES{PIPELINE_WORD_ZERO}};

            Register_Pipeline
            #(
                .WORD_WIDTH     (PIPELINE_WIDTH),
                .PIPE_DEPTH     (EXTRA_PIPE_STAGES),
                // concatenation of each stage initial/reset value
                .RESET_VALUES   (PIPELINE_ZERO)
            )
            accumulator_pipeline
            (
                .clock          (clock),
                .clock_enable   (clock_enable),
                .clear          (1'b0),
                .parallel_load  (1'b0),
                .parallel_in    (PIPELINE_ZERO),
                // verilator lint_off PINCONNECTEMPTY
                .parallel_out   (),
                // verilator lint_on  PINCONNECTEMPTY
                .pipe_in        ({limit_max,           limit_min,           increment_valid,           increment_value,           load_valid,           load_value,           increment_add_sub,           increment_carry_in,           accumulated_value,           clear}),
                .pipe_out       ({limit_max_pipelined, limit_min_pipelined, increment_valid_pipelined, increment_value_pipelined, load_valid_pipelined, load_value_pipelined, increment_add_sub_pipelined, increment_carry_in_pipelined, accumulated_value_pipelined, clear_pipelined})
            );
        end
    endgenerate

    reg gate_accumulated_value = 1'b0;

    always @(*) begin
        gate_accumulated_value = (load_valid_pipelined == 1'b1) || (clear_pipelined == 1'b1);
    end

    wire [WORD_WIDTH-1:0] accumulated_value_gated;
    wire                  increment_carry_in_gated;

    Annuller
    #(
        .WORD_WIDTH     (WORD_WIDTH + 1),
        .IMPLEMENTATION ("AND")
    )
    gate_accumulated
    (
        .annul          (gate_accumulated_value == 1'b1),
        .data_in        ({accumulated_value_pipelined, increment_carry_in_pipelined}),
        .data_out       ({accumulated_value_gated,     increment_carry_in_gated})
    );

    reg [WORD_WIDTH-1:0] increment_selected = WORD_ZERO;

    always @(*) begin
        increment_selected = (load_valid_pipelined == 1'b1) ? load_value_pipelined : increment_value_pipelined;
        increment_selected = (clear_pipelined      == 1'b1) ? INITIAL_VALUE        : increment_selected;
    end

    wire [WORD_WIDTH-1:0]   incremented_value_internal;
    wire                    accumulated_value_carry_out_internal;
    wire [WORD_WIDTH-1:0]   accumulated_value_carries_internal;
    wire                    accumulated_value_at_limit_max_internal;
    wire                    accumulated_value_over_limit_max_internal;
    wire                    accumulated_value_at_limit_min_internal;
    wire                    accumulated_value_under_limit_min_internal;

    Adder_Subtractor_Binary_Saturating
    #(
        .WORD_WIDTH     (WORD_WIDTH)
    )
    add_increment
    (
        .limit_max      (limit_max_pipelined),
        .limit_min      (limit_min_pipelined),
        .add_sub        (increment_add_sub_pipelined),  // 0/1 -> A+B/A-B
        .carry_in       (increment_carry_in_gated),
        .A              (accumulated_value_gated),
        .B              (increment_selected),
        .sum            (incremented_value_internal),
        .carry_out      (accumulated_value_carry_out_internal),
        .carries        (accumulated_value_carries_internal),
        .at_limit_max    (accumulated_value_at_limit_max_internal),
        .over_limit_max  (accumulated_value_over_limit_max_internal),
        .at_limit_min    (accumulated_value_at_limit_min_internal),
        .under_limit_min (accumulated_value_under_limit_min_internal)
    );

    reg enable_output  = 1'b0;

    always @(*) begin
        enable_output  = (increment_valid_pipelined == 1'b1) || (load_valid_pipelined == 1'b1) || (clear_pipelined == 1'b1);
        enable_output  = (enable_output             == 1'b1) && (clock_enable         == 1'b1);
    end

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (INITIAL_VALUE)
    )
    accumulator
    (
        .clock          (clock),
        .clock_enable   (enable_output),
        .clear          (1'b0),
        .data_in        (incremented_value_internal),
        .data_out       (accumulated_value)
    );

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (WORD_ZERO)
    )
    carries
    (
        .clock          (clock),
        .clock_enable   (enable_output),
        .clear          (1'b0),
        .data_in        (accumulated_value_carries_internal),
        .data_out       (accumulated_value_carries)
    );

    localparam STATUS_BITS_COUNT = 5;
    localparam STATUS_BITS_ZERO  = {STATUS_BITS_COUNT{1'b0}};

    Register
    #(
        .WORD_WIDTH     (STATUS_BITS_COUNT),
        .RESET_VALUE    (STATUS_BITS_ZERO)
    )
    status_bits
    (
        .clock          (clock),
        .clock_enable   (enable_output),
        .clear          (1'b0),
        .data_in        ({accumulated_value_carry_out_internal,  accumulated_value_at_limit_max_internal,  accumulated_value_over_limit_max_internal,  accumulated_value_at_limit_min_internal,  accumulated_value_under_limit_min_internal}),
        .data_out       ({accumulated_value_carry_out,           accumulated_value_at_limit_max,           accumulated_value_over_limit_max,           accumulated_value_at_limit_min,           accumulated_value_under_limit_min})
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_clear
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (clear_pipelined),
        .data_out       (clear_done)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_increment
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (increment_valid_pipelined),
        .data_out       (increment_done)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_load
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (load_valid_pipelined),
        .data_out       (load_done)
    );

endmodule
