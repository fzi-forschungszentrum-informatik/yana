`default_nettype none

module Bit_Reducer
#(
    parameter OPERATION     = "",
    parameter INPUT_COUNT   = 0
)
(
    input   wire    [INPUT_COUNT-1:0]   bits_in,
    output  reg                         bit_out
);

    initial begin
        bit_out = 1'b0;
    end

        // verilator lint_off UNOPTFLAT
    reg [INPUT_COUNT-1:0] partial_reduction;
    // verilator lint_on  UNOPTFLAT

    integer i;

    initial begin
        for(i=0; i < INPUT_COUNT; i=i+1) begin
            partial_reduction[i] = 1'b0;
        end
    end

    always @(*) begin
        partial_reduction[0]    = bits_in[0];
        bit_out                 = partial_reduction[INPUT_COUNT-1];
    end

    generate

        // verilator lint_off WIDTH
        if (OPERATION == "AND") begin : gen_and
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] & bits_in[i];
                end
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "NAND") begin : gen_nand
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] & bits_in[i]);
                end
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "OR") begin : gen_or
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] | bits_in[i];
                end
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "NOR") begin : gen_nor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] | bits_in[i]);
                end
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "XOR") begin : gen_xor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] ^ bits_in[i];
                end
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "XNOR") begin : gen_xnor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] ^ bits_in[i]);
                end
            end
        end

    endgenerate
endmodule