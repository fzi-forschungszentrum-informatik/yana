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

    reg [INPUT_COUNT-1:0] partial_reduction;
    integer i;

    generate

        // verilator lint_off WIDTH
        if (OPERATION == "AND") begin : gen_and
        // verilator lint_on  WIDTH
            always @(*) begin
                // Initialize defaults to prevent latches
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                // Perform reduction
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] & bits_in[i];
                end
                
                // Assign output
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "NAND") begin : gen_nand
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] & bits_in[i]);
                end
                
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "OR") begin : gen_or
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] | bits_in[i];
                end
                
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "NOR") begin : gen_nor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] | bits_in[i]);
                end
                
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "XOR") begin : gen_xor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = partial_reduction[i-1] ^ bits_in[i];
                end
                
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else
        // verilator lint_off WIDTH
        if (OPERATION == "XNOR") begin : gen_xnor
        // verilator lint_on  WIDTH
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                partial_reduction[0] = bits_in[0];
                
                for(i=1; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = ~(partial_reduction[i-1] ^ bits_in[i]);
                end
                
                bit_out = partial_reduction[INPUT_COUNT-1];
            end
        end
        else begin : gen_unknown
            always @(*) begin
                for(i=0; i < INPUT_COUNT; i=i+1) begin
                    partial_reduction[i] = 1'b0;
                end
                bit_out = 1'b0;
            end
        end

    endgenerate
endmodule