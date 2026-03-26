`include "global_params.vh"

module InputCore #(
    EVENT_SOURCE_WIDTH = INPUT_EVENT_SOURCE_WIDTH_G,
    PACKET_WIDTH       = INPUT_PACKET_WIDTH_G,
    FIFO_BUFFER_WIDTH  = INPUT_BUFFER_WIDTH_G,
    FIFO_BUFFER_DEPTH  = INPUT_BUFFER_DEPTH_G,
    TIMESTEP_WIDTH     = TIMESTEP_WIDTH_G
)(
    input clk_i,
    input rstn_i,
    input en_i,

    // The module reading from the input core is ready to consume data.
    // Must only be high if it is able to consume data in the current cycle.
    // If both read_ready and input_valid are high, the FIFO gets popped and
    // the next data item will be available.
    input read_ready_i,

    output                          input_valid_o,
    output [EVENT_SOURCE_WIDTH-1:0] input_data_o,
    output                          empty_o,

    output [TIMESTEP_WIDTH-1:0]     next_event_timestep_o,

    // FIFO Interface
    output                          fifo_ready_o,
    input [FIFO_BUFFER_WIDTH-1:0]   fifo_data_i,
    input                           fifo_valid_i
);

// Helper wires
wire read_ack;
assign read_ack = input_valid_o & read_ready_i;

// Module outputs
assign input_valid_o         = en_i & fifo_valid_i;
assign input_data_o          = fifo_data_i[EVENT_SOURCE_WIDTH-1:0];
assign empty_o               = !fifo_valid_i;
assign next_event_timestep_o = fifo_data_i[PACKET_WIDTH-1:EVENT_SOURCE_WIDTH];

// FIFO read control
assign fifo_ready_o = en_i & read_ack;

endmodule
