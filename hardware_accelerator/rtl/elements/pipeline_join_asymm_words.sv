`default_nettype none

`ifndef _math_h
function integer sum_of_array;

    input integer arr [0:255];
    input integer size;  // array size (1 to 256)
    
    integer i;
    integer sum_val;
    
    begin
        sum_val = 0;
        for (i = 0; i < size; i = i + 1) begin
            sum_val = sum_val + arr[i];
        end
        sum_of_array = sum_val;
    end
endfunction
`endif

module Pipeline_Join_Asymm_Words
#(
    parameter integer WORD_WIDTHS [0:255] = '{default: 0},
    parameter         INPUT_COUNT         = 0,

    // Do not set at instantiation, except in IPI
    parameter TOTAL_WIDTH = sum_of_array(WORD_WIDTHS, INPUT_COUNT)
)
(
    input  wire                    clock,
    input  wire                    clear,

    input  wire [INPUT_COUNT-1:0] input_valid,
    output wire [INPUT_COUNT-1:0] input_ready,
    input  wire [TOTAL_WIDTH-1:0] input_data,

    output reg                    output_valid,
    input  wire                   output_ready,
    output reg  [TOTAL_WIDTH-1:0] output_data
);

    localparam INPUT_ZERO = {INPUT_COUNT{1'b0}};
    localparam INPUT_ONES = {INPUT_COUNT{1'b1}};
    localparam TOTAL_ZERO = {TOTAL_WIDTH{1'b0}};

    initial begin
        output_valid = 1'b0;
        output_data  = TOTAL_ZERO;
    end

    wire [INPUT_COUNT-1:0] input_valid_buffered;
    reg  [INPUT_COUNT-1:0] input_ready_buffered = INPUT_ZERO;
    wire [TOTAL_WIDTH-1:0] input_data_buffered;

    generate
        genvar j;
        for(j=0; j < INPUT_COUNT; j=j+1) begin: per_input
            localparam WORD_WIDTH  = WORD_WIDTHS[j];
            localparam WORD_OFFSET = (sum_of_array(WORD_WIDTHS, j+1)) - WORD_WIDTH;
            Pipeline_Half_Buffer
            #(
                .WORD_WIDTH         (WORD_WIDTH),
                .CIRCULAR_BUFFER    (0)             // Not meaningful here
            )
            input_buffer
            (
                .clock          (clock),
                .clear          (clear),
                
                .input_valid    (input_valid[j]),
                .input_ready    (input_ready[j]),
                .input_data     (input_data [WORD_OFFSET +: WORD_WIDTH]),
                
                .output_valid   (input_valid_buffered[j]),
                .output_ready   (input_ready_buffered[j]),
                .output_data    (input_data_buffered [WORD_OFFSET +: WORD_WIDTH])
            );
        end
    endgenerate

    always @(*) begin
        output_valid            = (input_valid_buffered == INPUT_ONES);
        output_data             = input_data_buffered;
    end

    always @(*) begin
        input_ready_buffered    = (output_valid == 1'b1) ? {INPUT_COUNT{output_ready}} : INPUT_ZERO;
    end

endmodule
