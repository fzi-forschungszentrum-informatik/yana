`default_nettype none

module Pipeline_Crossbar_Interleave #(
    parameter WORD_WIDTH     = 0,
    parameter INPUT_COUNT    = 0,
    parameter OUTPUT_COUNT   = 0,
    parameter IMPLEMENTATION = "AND",

    // Do not set at instantiation, except in IPI
    parameter TOTAL_INPUT_WIDTH    = WORD_WIDTH  * INPUT_COUNT,
    parameter TOTAL_OUTPUT_WIDTH   = WORD_WIDTH  * OUTPUT_COUNT,
    parameter TOTAL_SELECTOR_WIDTH = INPUT_COUNT * OUTPUT_COUNT,
    parameter SKID_WORD_WIDTH      = WORD_WIDTH  + OUTPUT_COUNT
) (
    input  wire clock,
    input  wire clear,

    input  wire [INPUT_COUNT-1:0]          input_valid,
    output wire [INPUT_COUNT-1:0]          input_ready,
    input  wire [TOTAL_INPUT_WIDTH-1:0]    input_data,
    input  wire [TOTAL_SELECTOR_WIDTH-1:0] input_selector,

    output wire [OUTPUT_COUNT-1:0]       output_valid,
    input  wire [OUTPUT_COUNT-1:0]       output_ready,
    output wire [TOTAL_OUTPUT_WIDTH-1:0] output_data,

    output wire done_o
);

    localparam INDEX_WIDTH = (INPUT_COUNT <= 1) ? 1 : $clog2(INPUT_COUNT);
    localparam unsigned [INDEX_WIDTH:0] N = INPUT_COUNT;
    localparam SELECTOR_ZERO = {OUTPUT_COUNT{1'b0}};
    localparam TOTAL_SKID_WIDTH = SKID_WORD_WIDTH * INPUT_COUNT;

    // -------------------------------------------------------------------------
    // Per-input skid ({selector, data}), sink
    // -------------------------------------------------------------------------
    logic [INPUT_COUNT-1:0]      skid_out_valid;
    logic [INPUT_COUNT-1:0]      skid_buf_ready;
    logic [INPUT_COUNT-1:0]      illegal;
    logic [INPUT_COUNT-1:0]      sink_out_valid;
    logic [INPUT_COUNT-1:0]      sink_out_ready;
    logic [TOTAL_SKID_WIDTH-1:0] sink_out_bundle;
    logic [INPUT_COUNT-1:0]      legal_waiting;
    logic [INPUT_COUNT-1:0]      grantable;

    generate
        genvar g;
        for (g = 0; g < INPUT_COUNT; g++) begin : gen_input_path
            logic [OUTPUT_COUNT-1:0]    selector_in;
            logic [SKID_WORD_WIDTH-1:0] skid_in_bundle;
            logic [SKID_WORD_WIDTH-1:0] skid_out_word;
            logic [OUTPUT_COUNT-1:0]    selector_out;

            assign selector_in    = input_selector[g*OUTPUT_COUNT +: OUTPUT_COUNT];
            assign skid_in_bundle = {selector_in, input_data[g*WORD_WIDTH +: WORD_WIDTH]};

            Pipeline_Skid_Buffer #(
                .WORD_WIDTH     (SKID_WORD_WIDTH),
                .CIRCULAR_BUFFER(0)
            ) input_skid (
                .clock       (clock),
                .clear       (clear),
                .input_valid (input_valid[g]),
                .input_ready (input_ready[g]),
                .input_data  (skid_in_bundle),
                .output_valid(skid_out_valid[g]),
                .output_ready(skid_buf_ready[g]),
                .output_data (skid_out_word)
            );

            assign selector_out = skid_out_word[WORD_WIDTH +: OUTPUT_COUNT];
            assign illegal[g]   = ~|selector_out | |(selector_out & (selector_out - 1'b1));

            Pipeline_Sink #(
                .WORD_WIDTH    (SKID_WORD_WIDTH),
                .IMPLEMENTATION(IMPLEMENTATION)
            ) input_sink (
                .sink        (illegal[g]),
                .input_valid (skid_out_valid[g]),
                .input_ready (skid_buf_ready[g]),
                .input_data  (skid_out_word),
                .output_valid(sink_out_valid[g]),
                .output_ready(sink_out_ready[g]),
                .output_data (sink_out_bundle[g*SKID_WORD_WIDTH +: SKID_WORD_WIDTH])
            );

            assign legal_waiting[g] = sink_out_valid[g];
            assign grantable[g]     = sink_out_valid[g] & |(selector_out & output_ready);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Global round-robin grant
    // -------------------------------------------------------------------------
    logic [INDEX_WIDTH-1:0] counter_d, counter_q;
    logic                   selection_valid_d;
    logic was_interleaving_d, was_interleaving_q;

    logic any_legal_waiting;
    assign any_legal_waiting      = |legal_waiting;
    logic multiple_legal_waiting;
    assign multiple_legal_waiting = |(legal_waiting & (legal_waiting - 1'b1));
    logic single_legal_waiting;
    assign single_legal_waiting   = any_legal_waiting & ~multiple_legal_waiting;
    logic any_grantable;
    assign any_grantable          = |grantable;

    logic [INPUT_COUNT-1:0] single_waiting_one_hot;
    Bitmask_Isolate_Rightmost_1_Bit #(.WORD_WIDTH(INPUT_COUNT)) u_single_rhs (
        .word_in  (legal_waiting),
        .word_out (single_waiting_one_hot)
    );

    logic [INDEX_WIDTH-1:0] single_waiting_index;
    always_comb begin
        single_waiting_index = '0;
        for (int i = 0; i < INPUT_COUNT; i++)
            if (single_waiting_one_hot[i]) single_waiting_index = i[INDEX_WIDTH-1:0];
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
            idx = (INDEX_WIDTH+1)'(start_index) + (INDEX_WIDTH+1)'(j);
            slice[j] = (idx >= N) ? valid_mask[idx - N] : valid_mask[idx[INDEX_WIDTH-1:0]];
        end
        rhs_one_hot = slice & (-slice);
        pos_in_slice = '0;
        for (int j = 0; j < INPUT_COUNT; j++)
            if (rhs_one_hot[j]) pos_in_slice = unsigned'(j);
        sum = start_index + pos_in_slice;
        diff = sum - N;
        result = (sum >= N) ? diff[INDEX_WIDTH-1:0] : sum[INDEX_WIDTH-1:0];
        return result;
    endfunction

    logic [INDEX_WIDTH-1:0] grant_index_c;

    always_comb begin
        counter_d          = counter_q;
        selection_valid_d  = 1'b0;
        was_interleaving_d = was_interleaving_q;
        grant_index_c      = '0;

        if (any_grantable) begin
            was_interleaving_d = multiple_legal_waiting | was_interleaving_q;
            selection_valid_d  = 1'b1;
            grant_index_c      = find_next_active_index(
                grantable,
                was_interleaving_q ? (counter_q + 1'b1) : '0
            );
            counter_d = grant_index_c;
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

    // -------------------------------------------------------------------------
    // Granted beat → branch to outputs
    // -------------------------------------------------------------------------
    logic [WORD_WIDTH-1:0]   branch_in_data;
    logic [OUTPUT_COUNT-1:0] branch_selector;
    logic                    branch_in_valid;
    logic                    branch_in_ready;

    always_comb begin
        branch_in_data  = '0;
        branch_selector = SELECTOR_ZERO;
        branch_in_valid = 1'b0;

        if (selection_valid_d) begin
            for (int i = 0; i < INPUT_COUNT; i++) begin
                if (counter_d == i[INDEX_WIDTH-1:0]) begin
                    branch_in_data  = sink_out_bundle[i*SKID_WORD_WIDTH +: WORD_WIDTH];
                    branch_selector = sink_out_bundle[i*SKID_WORD_WIDTH + WORD_WIDTH +: OUTPUT_COUNT];
                    branch_in_valid = sink_out_valid[i];
                end
            end
        end
    end

    logic [OUTPUT_COUNT-1:0]       branch_out_valid;
    logic [OUTPUT_COUNT-1:0]       branch_out_ready;
    logic [TOTAL_OUTPUT_WIDTH-1:0] branch_out_data;

    Pipeline_Branch_One_Hot #(
        .WORD_WIDTH    (WORD_WIDTH),
        .OUTPUT_COUNT  (OUTPUT_COUNT),
        .IMPLEMENTATION(IMPLEMENTATION)
    ) u_route_branch (
        .selector     (branch_selector),
        .input_valid  (branch_in_valid),
        .input_ready  (branch_in_ready),
        .input_data   (branch_in_data),
        .output_ready (branch_out_ready),
        .output_valid (branch_out_valid),
        .output_data  (branch_out_data)
    );

    assign output_valid = branch_out_valid;
    assign output_data  = branch_out_data;
    assign done_o       = ~(|sink_out_valid);

    assign branch_out_ready = output_ready;

    always_ff @(posedge clock) begin
        if (clear) begin
            counter_q          <= '0;
            was_interleaving_q <= 1'b0;
        end else begin
            counter_q          <= counter_d;
            was_interleaving_q <= was_interleaving_d;
        end
    end

    // Legal routes forwarded only when granted; sink handles illegal draining
    always_comb begin
        for (int i = 0; i < INPUT_COUNT; i++) begin
            if (selection_valid_d && (counter_d == i[INDEX_WIDTH-1:0])) begin
                sink_out_ready[i] = branch_in_ready;
            end else begin
                sink_out_ready[i] = 1'b0;
            end
        end
    end

endmodule 
