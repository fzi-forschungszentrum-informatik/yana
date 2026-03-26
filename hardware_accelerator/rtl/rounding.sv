module round_convergent #(
    parameter INPUT_WIDTH  = 12,
    parameter OUTPUT_WIDTH = 8
)(
    input  [INPUT_WIDTH-1:0]  data_i,
    output [OUTPUT_WIDTH-1:0] data_o
);
    wire [INPUT_WIDTH-1:0] w_convergent = data_i[(INPUT_WIDTH-1):0]
                                          + { {(OUTPUT_WIDTH){1'b0}}, data_i[(INPUT_WIDTH-OUTPUT_WIDTH)],
                                              {(INPUT_WIDTH-OUTPUT_WIDTH-1){!data_i[(INPUT_WIDTH-OUTPUT_WIDTH)]}} };

    assign data_o = w_convergent[(INPUT_WIDTH-1):(INPUT_WIDTH-OUTPUT_WIDTH)];
endmodule