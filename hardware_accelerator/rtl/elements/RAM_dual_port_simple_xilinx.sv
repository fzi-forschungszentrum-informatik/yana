`default_nettype none

module RAM_Simple_Dual_Port 
#(
    parameter                       WORD_WIDTH          = 0,
    parameter                       ADDR_WIDTH          = 0,
    parameter                       DEPTH               = 0,
    // Used as attributes, not values
    // verilator lint_off UNUSED
    parameter                       RAMSTYLE            = "",
    parameter                       RW_ADDR_COLLISION   = "",
    // verilator lint_on  UNUSED
    parameter                       READ_NEW_DATA       = 0,
    parameter                       USE_INIT_FILE       = 0,
    parameter                       INIT_FILE           = "",
    parameter   [WORD_WIDTH-1:0]    INIT_VALUE          = 0
)
(
    input  wire                         clock,
    input  wire                         wren,
    input  wire     [ADDR_WIDTH-1:0]    write_addr,
    input  wire     [WORD_WIDTH-1:0]    write_data,
    input  wire                         rden,
    input  wire     [ADDR_WIDTH-1:0]    read_addr, 
    output reg      [WORD_WIDTH-1:0]    read_data
);

    initial begin
        read_data = {WORD_WIDTH{1'b0}};
    end

    (* ram_style            = RAMSTYLE *)
    (* rw_addr_collision    = RW_ADDR_COLLISION *)
    reg [WORD_WIDTH-1:0] ram [DEPTH-1:0];

    generate
        // Returns OLD data
        if (READ_NEW_DATA == 0) begin : gen_read_old_data
            always @(posedge clock) begin
                if(wren == 1'b1) begin
                    ram[write_addr] <= write_data;
                end
                if(rden == 1'b1) begin
                    read_data <= ram[read_addr];
                end
            end
        end
        // Returns NEW data
        // This isn't proper, but that's what the CAD tool expects for inference.
        // verilator lint_off BLKSEQ
        else begin : gen_read_new_data
            always @(posedge clock) begin
                if(wren == 1'b1) begin
                    ram[write_addr] = write_data;
                end
                if(rden == 1'b1) begin
                    read_data = ram[read_addr];
                end
            end
        end
        // verilator lint_on BLKSEQ
    endgenerate

    generate
        if (USE_INIT_FILE == 0) begin : gen_init_value
            integer i;
            initial begin
                for (i = 0; i < DEPTH; i = i + 1) begin
                    ram[i] = INIT_VALUE;
                end
            end
        end
        else begin : gen_init_file
            initial begin
                $readmemh(INIT_FILE, ram);
            end
        end
    endgenerate

endmodule