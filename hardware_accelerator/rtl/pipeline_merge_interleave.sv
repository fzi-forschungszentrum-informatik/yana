`default_nettype none

module Pipeline_Merge_Interleave
#(
    parameter WORD_WIDTH        = 0,
    parameter INPUT_COUNT       = 0,
    parameter HANDSHAKE_MERGE   = "OR",
    parameter DATA_MERGE        = "OR",
    parameter IMPLEMENTATION    = "AND",

    // Do not set at instantiation, except in IPI
    parameter TOTAL_WIDTH   = WORD_WIDTH * INPUT_COUNT
)
(
    input  wire                   clock,
    input  wire                   clear,

    input  wire [INPUT_COUNT-1:0] input_valid,
    output wire [INPUT_COUNT-1:0] input_ready,
    input  wire [TOTAL_WIDTH-1:0] input_data,

    output wire                   output_valid,
    input  wire                   output_ready,
    output wire [WORD_WIDTH-1:0]  output_data
);

    localparam INDEX_WIDTH = (INPUT_COUNT <= 1) ? 1 : $clog2(INPUT_COUNT);
    localparam unsigned [INDEX_WIDTH:0] N = INPUT_COUNT;

    logic [INPUT_COUNT-1:0] skid_out_valid;
    logic [INPUT_COUNT-1:0] skid_buf_ready;
    logic [TOTAL_WIDTH-1:0] skid_out_data;

    generate
        genvar g;
        for (g = 0; g < INPUT_COUNT; g++) begin : gen_input_skid
            logic [WORD_WIDTH-1:0] skid_out_word;

            Pipeline_Skid_Buffer #(
                .WORD_WIDTH     (WORD_WIDTH),
                .CIRCULAR_BUFFER(0)
            ) input_skid (
                .clock       (clock),
                .clear       (clear),
                .input_valid (input_valid[g]),
                .input_ready (input_ready[g]),
                .input_data  (input_data[g*WORD_WIDTH +: WORD_WIDTH]),
                .output_valid(skid_out_valid[g]),
                .output_ready(skid_buf_ready[g]),
                .output_data (skid_out_word)
            );

            assign skid_out_data[g*WORD_WIDTH +: WORD_WIDTH] = skid_out_word;
        end
    endgenerate

    // Registered round-robin state (grant index is combinatorial)
    logic [INDEX_WIDTH-1:0] counter_d, counter_q;
    logic                   selection_valid_d;
    logic was_interleaving_d, was_interleaving_q;

    // Post-upstream-buffer waiting; grant when downstream can accept
    wire [INPUT_COUNT-1:0] legal_waiting;
    wire [INPUT_COUNT-1:0] grantable;

    assign legal_waiting = skid_out_valid;
    assign grantable     = output_ready ? legal_waiting : '0;

    wire any_legal_waiting;
    assign any_legal_waiting = |legal_waiting;
    wire multiple_legal_waiting;
    assign multiple_legal_waiting = |(legal_waiting & (legal_waiting - 1'b1));
    wire single_legal_waiting;
    assign single_legal_waiting = any_legal_waiting & ~multiple_legal_waiting;
    wire any_grantable;
    assign any_grantable = |grantable;

    wire [INPUT_COUNT-1:0] single_waiting_one_hot;
    Bitmask_Isolate_Rightmost_1_Bit #(.WORD_WIDTH(INPUT_COUNT)) u_single_rhs (
        .word_in  (legal_waiting),
        .word_out (single_waiting_one_hot)
    );

    logic [INDEX_WIDTH-1:0] single_waiting_index;
    always_comb begin
        single_waiting_index = '0;
        for (int i = 0; i < INPUT_COUNT; i++) begin
            if (single_waiting_one_hot[i])
                single_waiting_index = INDEX_WIDTH'(unsigned'(i));
        end
    end

    function automatic logic [INDEX_WIDTH-1:0] find_next_active_index(
        input logic [INPUT_COUNT-1:0] valid_mask,
        input logic [INDEX_WIDTH-1:0] start_index
    );
        logic [INPUT_COUNT-1:0] slice;
        logic [INPUT_COUNT-1:0] rhs_one_hot;
        logic [INDEX_WIDTH-1:0] pos_in_slice;
        logic [INDEX_WIDTH:0] sum;
        logic [INDEX_WIDTH:0] diff;
        logic [INDEX_WIDTH-1:0] result;
        logic [INDEX_WIDTH:0] idx;
        for (int j = 0; j < INPUT_COUNT; j++) begin
            idx = (INDEX_WIDTH+1)'(unsigned'(start_index)) + (INDEX_WIDTH+1)'(unsigned'(j));
            slice[j] = (idx >= N) ? valid_mask[idx - N] : valid_mask[idx[INDEX_WIDTH-1:0]];
        end
        rhs_one_hot = slice & (-slice);
        pos_in_slice = '0;
        for (int j = 0; j < INPUT_COUNT; j++) begin
            if (rhs_one_hot[j])
                pos_in_slice = INDEX_WIDTH'(unsigned'(j));
        end
        sum = (INDEX_WIDTH+1)'(unsigned'(start_index)) + (INDEX_WIDTH+1)'(unsigned'(pos_in_slice));
        diff = sum - N;
        result = (sum >= N) ? diff[INDEX_WIDTH-1:0] : sum[INDEX_WIDTH-1:0];
        return result;
    endfunction

    logic [INPUT_COUNT-1:0] selector;

    always_comb begin
        selector = '0;
        for (int k = 0; k < INPUT_COUNT; k++) begin
            if (selection_valid_d && (counter_d == INDEX_WIDTH'(unsigned'(k))))
                selector[k] = 1'b1;
        end
    end

    Pipeline_Merge_One_Hot #(
        .WORD_WIDTH     (WORD_WIDTH),
        .INPUT_COUNT    (INPUT_COUNT),
        .HANDSHAKE_MERGE(HANDSHAKE_MERGE),
        .DATA_MERGE     (DATA_MERGE),
        .IMPLEMENTATION (IMPLEMENTATION)
    ) u_pipeline_merge_one_hot (
        .clock          (clock),
        .clear          (clear),
        .selector       (selector),
        .input_valid    (skid_out_valid),
        .input_ready    (skid_buf_ready),
        .input_data     (skid_out_data),
        .output_valid   (output_valid),
        .output_ready   (output_ready),
        .output_data    (output_data)
    );

    always_comb begin
        counter_d          = counter_q;
        selection_valid_d  = 1'b0;
        was_interleaving_d = was_interleaving_q;

        if (any_grantable) begin
            was_interleaving_d = multiple_legal_waiting | was_interleaving_q;
            selection_valid_d  = 1'b1;
            counter_d          = find_next_active_index(
                grantable,
                was_interleaving_q ? (counter_q + 1'b1) : '0
            );
        end else if (multiple_legal_waiting) begin
            was_interleaving_d = 1'b1;
            selection_valid_d  = 1'b0;
            counter_d          = find_next_active_index(
                legal_waiting,
                was_interleaving_q ? (counter_q + 1'b1) : '0
            );
        end else if (single_legal_waiting) begin
            was_interleaving_d = 1'b0;
            selection_valid_d  = 1'b0;
            counter_d          = single_waiting_index;
        end else begin
            was_interleaving_d = 1'b0;
            selection_valid_d  = 1'b0;
            counter_d          = '0;
        end
    end

    always_ff @(posedge clock) begin
        if (clear) begin
            counter_q          <= '0;
            was_interleaving_q <= 1'b0;
        end else begin
            counter_q          <= counter_d;
            was_interleaving_q <= was_interleaving_d;
        end
    end

endmodule
