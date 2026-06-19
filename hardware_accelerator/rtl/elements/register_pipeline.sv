`default_nettype none

module Register_Pipeline
#(
    parameter                   WORD_WIDTH      = 0,
    parameter                   PIPE_DEPTH      = 0,
    // Don't set at instantiation
    parameter                   TOTAL_WIDTH     = WORD_WIDTH * PIPE_DEPTH,

    // concatenation of each stage initial/reset value
    parameter [TOTAL_WIDTH-1:0] RESET_VALUES    = 0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,
    input   wire                        clear,
    input   wire                        parallel_load,
    input   wire    [TOTAL_WIDTH-1:0]   parallel_in,
    output  reg     [TOTAL_WIDTH-1:0]   parallel_out,
    input   wire    [WORD_WIDTH-1:0]    pipe_in,
    output  reg     [WORD_WIDTH-1:0]    pipe_out
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};

    initial begin
        pipe_out = WORD_ZERO;
    end

    wire [WORD_WIDTH-1:0] pipe_stage_in     [PIPE_DEPTH-1:0];
    wire [WORD_WIDTH-1:0] pipe_stage_out    [PIPE_DEPTH-1:0];

    (* multstyle = "logic" *) // Quartus
    (* use_dsp   = "no" *)    // Vivado

    Multiplexer_Binary_Behavioural
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .ADDR_WIDTH     (1),
        .INPUT_COUNT    (2)
    )
    pipe_input_select
    (
        .selector       (parallel_load),    
        .words_in       ({parallel_in[0 +: WORD_WIDTH], pipe_in}),
        .word_out       (pipe_stage_in[0])
    );

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (RESET_VALUES[0 +: WORD_WIDTH])
    )
    pipe_stage
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (clear),
        .data_in        (pipe_stage_in[0]),
        .data_out       (pipe_stage_out[0])
    );

    always @(*) begin
        parallel_out[0 +: WORD_WIDTH] = pipe_stage_out[0];
    end

    generate

        genvar i;

        for(i=1; i < PIPE_DEPTH; i=i+1) begin : pipe_stages

            (* multstyle = "logic" *) // Quartus
            (* use_dsp   = "no" *)    // Vivado

            Multiplexer_Binary_Behavioural
            #(
                .WORD_WIDTH     (WORD_WIDTH),
                .ADDR_WIDTH     (1),
                .INPUT_COUNT    (2)
            )
            pipe_input_select
            (
                .selector       (parallel_load),    
                .words_in       ({parallel_in[WORD_WIDTH*i +: WORD_WIDTH], pipe_stage_out[i-1]}),
                .word_out       (pipe_stage_in[i])
            );


            Register
            #(
                .WORD_WIDTH     (WORD_WIDTH),
                .RESET_VALUE    (RESET_VALUES[WORD_WIDTH*i +: WORD_WIDTH])
            )
            pipe_stage
            (
                .clock          (clock),
                .clock_enable   (clock_enable),
                .clear          (clear),
                .data_in        (pipe_stage_in[i]),
                .data_out       (pipe_stage_out[i])
            );

            always @(*) begin
                parallel_out[WORD_WIDTH*i +: WORD_WIDTH] = pipe_stage_out[i];
            end

        end

    endgenerate

    always @(*) begin
        pipe_out = pipe_stage_out[PIPE_DEPTH-1];
    end

endmodule
