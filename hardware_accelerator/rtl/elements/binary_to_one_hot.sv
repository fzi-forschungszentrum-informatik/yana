`default_nettype none

module Binary_to_One_Hot
#(
    parameter       BINARY_WIDTH        = 0,
    parameter       OUTPUT_WIDTH        = 0 
)
(
    input   wire    [BINARY_WIDTH-1:0]  binary_in,
    output  wire    [OUTPUT_WIDTH-1:0]  one_hot_out
);

    generate
        genvar i;
        for (i=0; i < OUTPUT_WIDTH; i=i+1) begin : per_output
            Address_Decoder_Behavioural
            #(
                .ADDR_WIDTH (BINARY_WIDTH)
            )
            one_hot_bit
            (
                .base_addr  (i[BINARY_WIDTH-1:0]),
                .bound_addr (i[BINARY_WIDTH-1:0]),
                .addr       (binary_in),
                .hit        (one_hot_out[i])
            );
        end
    endgenerate

endmodule