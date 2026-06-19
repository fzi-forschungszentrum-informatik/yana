`default_nettype none

module Pipeline_FIFO_Buffer
#(
    parameter WORD_WIDTH                = 0,
    parameter DEPTH                     = 0,
    parameter RAMSTYLE                  = "",
    parameter CIRCULAR_BUFFER           = 0         // non-zero to enable
)
(
    input   wire                        clock,
    input   wire                        clear,

    input   wire                        input_valid,
    output  reg                         input_ready,
    input   wire    [WORD_WIDTH-1:0]    input_data,

    output  wire                        output_valid,
    input   wire                        output_ready,
    output  wire    [WORD_WIDTH-1:0]    output_data,

    output  wire                        empty
);

    initial begin
        input_ready = 1'b1; // Empty at start, so accept data
    end

    `include "clog2_function.vh"

    localparam WORD_ZERO    = {WORD_WIDTH{1'b0}};

    localparam ADDR_WIDTH   = clog2(DEPTH);
    localparam ADDR_ONE     = {{ADDR_WIDTH-1{1'b0}},1'b1};
    localparam ADDR_ZERO    = {ADDR_WIDTH{1'b0}};
    localparam ADDR_LAST    = DEPTH-1;

    reg                     buffer_wren = 1'b0;
    wire [ADDR_WIDTH-1:0]   buffer_write_addr;

    reg                     buffer_rden = 1'b0;
    wire [ADDR_WIDTH-1:0]   buffer_read_addr;

    RAM_Simple_Dual_Port
    #(
        .WORD_WIDTH         (WORD_WIDTH),
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DEPTH              (DEPTH),
        .RAMSTYLE           (RAMSTYLE),
        .READ_NEW_DATA      (0),
        .RW_ADDR_COLLISION  ("no"),
        .USE_INIT_FILE      (0),
        .INIT_FILE          (),
        .INIT_VALUE         (WORD_ZERO)
    )
    buffer
    (
        .clock          (clock),
        .wren           (buffer_wren),
        .write_addr     (buffer_write_addr),
        .write_data     (input_data),

        .rden           (buffer_rden),
        .read_addr      (buffer_read_addr),
        .read_data      (output_data)
    );

    reg increment_buffer_write_addr = 1'b0;
    reg load_buffer_write_addr      = 1'b0;

    Counter_Binary
    #(
        .WORD_WIDTH     (ADDR_WIDTH),
        .INCREMENT      (ADDR_ONE),
        .INITIAL_COUNT  (ADDR_ZERO)
    )
    write_address
    (
        .clock          (clock),
        .clear          (clear),
        .up_down        (1'b0), // 0/1 --> up/down
        .run            (increment_buffer_write_addr),
        .load           (load_buffer_write_addr),
        .load_count     (ADDR_ZERO),
        .carry_in       (1'b0),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      (),
        .carries        (),
        .overflow       (),
        // verilator lint_on  PINCONNECTEMPTY
        .count          (buffer_write_addr)
    );

    reg increment_buffer_read_addr = 1'b0;
    reg load_buffer_read_addr      = 1'b0;

    Counter_Binary
    #(
        .WORD_WIDTH     (ADDR_WIDTH),
        .INCREMENT      (ADDR_ONE),
        .INITIAL_COUNT  (ADDR_ZERO)
    )
    read_address
    (
        .clock          (clock),
        .clear          (clear),
        .up_down        (1'b0), // 0/1 --> up/down
        .run            (increment_buffer_read_addr),
        .load           (load_buffer_read_addr),
        .load_count     (ADDR_ZERO),
        .carry_in       (1'b0),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      (),
        .carries        (),
        .overflow       (),
        // verilator lint_on  PINCONNECTEMPTY
        .count          (buffer_read_addr)
    );

    reg  toggle_buffer_write_addr_wrap_around = 1'b0;
    wire buffer_write_addr_wrap_around;

    Register_Toggle
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    write_wrap_around_bit
    (
        .clock          (clock),
        .clock_enable   (1'b1),
        .clear          (clear),
        .toggle         (toggle_buffer_write_addr_wrap_around),
        .data_in        (buffer_write_addr_wrap_around),
        .data_out       (buffer_write_addr_wrap_around)
    );

    reg  toggle_buffer_read_addr_wrap_around = 1'b0;
    wire buffer_read_addr_wrap_around;

    Register_Toggle
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    read_wrap_around_bit
    (
        .clock          (clock),
        .clock_enable   (1'b1),
        .clear          (clear),
        .toggle         (toggle_buffer_read_addr_wrap_around),
        .data_in        (buffer_read_addr_wrap_around),
        .data_out       (buffer_read_addr_wrap_around)
    );

    reg stored_items_zero = 1'b0;
    reg stored_items_max  = 1'b0;

    always @(*) begin
        stored_items_zero = (buffer_read_addr == buffer_write_addr) && (buffer_read_addr_wrap_around == buffer_write_addr_wrap_around);
        stored_items_max  = (buffer_read_addr == buffer_write_addr) && (buffer_read_addr_wrap_around != buffer_write_addr_wrap_around);
    end

    reg insert = 1'b0;

    always @(*) begin
        input_ready                             = (stored_items_max == 1'b0) || (CIRCULAR_BUFFER != 0);
        insert                                  = (input_valid      == 1'b1) && (input_ready  == 1'b1);

        buffer_wren                             = (insert == 1'b1);
        increment_buffer_write_addr             = (insert == 1'b1);
        load_buffer_write_addr                  = (increment_buffer_write_addr == 1'b1) && (buffer_write_addr == ADDR_LAST [ADDR_WIDTH-1:0]);
        toggle_buffer_write_addr_wrap_around    = (load_buffer_write_addr      == 1'b1);
    end

    reg remove_normal           = 1'b0;
    reg remove_circular         = 1'b0;
    reg remove                  = 1'b0;
    reg output_leaving_idle     = 1'b0;
    reg load_output_register    = 1'b0;

    always @(*) begin
        remove_normal                       = (output_valid    == 1'b1) && (output_ready        == 1'b1);
        remove_circular                     = (CIRCULAR_BUFFER !=    0) && (stored_items_max    == 1'b1) && (insert == 1'b1);
        remove                              = (remove_normal   == 1'b1) || (remove_circular     == 1'b1);
        output_leaving_idle                 = (output_valid    == 1'b0) && (stored_items_zero   == 1'b0);
        load_output_register                = (remove          == 1'b1) || (output_leaving_idle == 1'b1);

        buffer_rden                         = (load_output_register       == 1'b1) && (stored_items_zero == 1'b0);
        increment_buffer_read_addr          = (load_output_register       == 1'b1) && (stored_items_zero == 1'b0);
        load_buffer_read_addr               = (increment_buffer_read_addr == 1'b1) && (buffer_read_addr  == ADDR_LAST [ADDR_WIDTH-1:0]);
        toggle_buffer_read_addr_wrap_around = (load_buffer_read_addr      == 1'b1);
    end

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    output_data_valid
    (
        .clock          (clock),
        .clock_enable   (load_output_register == 1'b1),
        .clear          (clear),
        .data_in        (stored_items_zero == 1'b0),
        .data_out       (output_valid)
    );

    assign empty = (stored_items_zero == 1'b1) && (output_valid == 1'b0);

endmodule