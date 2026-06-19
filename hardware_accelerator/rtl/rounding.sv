module RoundConvergent #(
    parameter INPUT_WIDTH  = 12,
    parameter OUTPUT_WIDTH = 8
)(
    input  logic [INPUT_WIDTH-1:0]  data_i,
    output logic [OUTPUT_WIDTH-1:0] data_o
);
    logic [INPUT_WIDTH-1:0] convergent_val = data_i[(INPUT_WIDTH-1):0]
                                          + { {(OUTPUT_WIDTH){1'b0}}, data_i[(INPUT_WIDTH-OUTPUT_WIDTH)],
                                              {(INPUT_WIDTH-OUTPUT_WIDTH-1){!data_i[(INPUT_WIDTH-OUTPUT_WIDTH)]}} };

    assign data_o = convergent_val[(INPUT_WIDTH-1):(INPUT_WIDTH-OUTPUT_WIDTH)];
endmodule