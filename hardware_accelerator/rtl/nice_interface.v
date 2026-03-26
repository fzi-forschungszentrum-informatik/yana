module nice_interface #(
    // Command format
    parameter COMMAND_BUFFER_WIDTH     = 64,
    parameter COMMAND_WIDTH            = 64,
    parameter INSTRUCTION_WIDTH        = 8,
    parameter PARAM_WIDTH              = 24,
    parameter OUT_READ_START_WIDTH     = 10,
    parameter OUT_READ_END_WIDTH       = 10,
    parameter RST_TYPE_WIDTH           = 2,
    parameter RST_LEN_WIDTH            = 8,
    parameter RST_MEM_TARGET_WIDTH     = 4,
    // Buffer sizes
    parameter INPUT_DATA_BUFFER_WIDTH  = 32,
    parameter OUTPUT_DATA_BUFFER_WIDTH = 32,
    // Core Configs
    parameter CORE_TOP_RAM_LEAK_ADDR_WIDTH = 5,
    parameter CORE_TOP_RAM_LEAK_DATA_WIDTH = 8,
    parameter CORE_TOP_TAU_MEM_INV_DATA_WIDTH = 16,
    parameter OUT_CORE_RAM_LEAK_ADDR_WIDTH = 5,
    parameter OUT_CORE_RAM_LEAK_DATA_WIDTH = 8,
    parameter OUT_CORE_TAU_MEM_INV_DATA_WIDTH = 16,
    // URAM write interfaces
    parameter WEIGHT_RAM_ADDR_WIDTH = 15,
    parameter WEIGHT_RAM_DATA_WIDTH = 72,
    parameter URAM_ROUTES_ADDR_WIDTH = 16,
    parameter URAM_ROUTES_DATA_WIDTH = 72,
    parameter URAM_MAPPING_ADDR_WIDTH = 10,
    parameter URAM_MAPPING_DATA_WIDTH = 34
)(
    input clk_i,
    input rstn_i,
    input en_i,

    // Input Data FIFO Interface
    output                              input_fifo_ready_o,
    input [INPUT_DATA_BUFFER_WIDTH-1:0] input_fifo_data_i,
    input                               input_fifo_valid_i,

    // Output Data FIFO Interface
    input                                 output_fifo_ready_i,
    output [OUTPUT_DATA_BUFFER_WIDTH-1:0] output_fifo_data_o,
    output                                output_fifo_valid_o,
    output                                output_fifo_last_o,

    // Interrupt
    input      interrupt_i,
    output reg interrupt_o,

    // Sample and Network configuration
    input wire [PARAM_WIDTH-1:0] num_sample_timesteps_i,
    
    // Hidden Core Configuration
    input wire                                       core_top_neuron_leak_ram_write_en_i,
    input wire [CORE_TOP_RAM_LEAK_ADDR_WIDTH-1:0]    core_top_neuron_leak_ram_addr_i,
    input wire [CORE_TOP_RAM_LEAK_DATA_WIDTH-1:0]    core_top_neuron_leak_ram_data_i,
    input wire [CORE_TOP_TAU_MEM_INV_DATA_WIDTH-1:0] core_top_neuron_tau_mem_inv_i,
    
    // Output Core Configuration
    input wire                                       output_core_neuron_leak_ram_write_en_i,
    input wire [OUT_CORE_RAM_LEAK_ADDR_WIDTH-1:0]    output_core_neuron_leak_ram_addr_i,
    input wire [OUT_CORE_RAM_LEAK_DATA_WIDTH-1:0]    output_core_neuron_leak_ram_data_i,
    input wire [OUT_CORE_TAU_MEM_INV_DATA_WIDTH-1:0] output_core_neuron_tau_mem_inv_i,
    input wire [OUT_READ_END_WIDTH-1:0]              num_output_neurons_i,
    
    // URAM Write Interfaces
    input wire                             core_top_weight_ram_we,
    input wire [WEIGHT_RAM_ADDR_WIDTH-1:0] core_top_weight_ram_addr,
    input wire [WEIGHT_RAM_DATA_WIDTH-1:0] core_top_weight_ram_data,

    input wire                              core_top_routes_ram_write_enable,
    input wire [URAM_ROUTES_ADDR_WIDTH-1:0] core_top_routes_ram_write_addr,
    input wire [URAM_ROUTES_DATA_WIDTH-1:0] core_top_routes_ram_data,

    input wire                               core_top_memory_mapping_ram_write_en,
    input wire [URAM_MAPPING_ADDR_WIDTH-1:0] core_top_memory_mapping_ram_write_addr,
    input wire [URAM_MAPPING_DATA_WIDTH-1:0] core_top_memory_mapping_ram_data_in,

    input wire                             output_core_weight_ram_we,
    input wire [WEIGHT_RAM_ADDR_WIDTH-1:0] output_core_weight_ram_addr,
    input wire [WEIGHT_RAM_DATA_WIDTH-1:0] output_core_weight_ram_data,

    input wire                              input_multicast_routes_ram_write_en,
    input wire [URAM_ROUTES_ADDR_WIDTH-1:0] input_multicast_routes_ram_write_addr,
    input wire [URAM_ROUTES_DATA_WIDTH-1:0] input_multicast_routes_ram_data_in,

    input wire                               input_multicast_mapping_ram_write_en,
    input wire [URAM_MAPPING_ADDR_WIDTH-1:0] input_multicast_mapping_ram_write_addr,
    input wire [URAM_MAPPING_DATA_WIDTH-1:0] input_multicast_mapping_ram_data_in,

    // Interrupt cycle counter output
    output reg [31:0] interrupt_latency
);

//
// Enum replacement definitions
//

// IF state
localparam NUM_IF_STATES = 6;
localparam IF_STATE_WIDTH = $clog2(NUM_IF_STATES);

localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_IDLE         = 0;
localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_SETUP        = 1;
localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_RUNNING      = 2;
localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_OUTPUT_READ  = 3;
localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_RESET_STATES = 4;
localparam reg [IF_STATE_WIDTH-1:0] IF_STATE_RESET_ALL    = 5;

// Command instruction
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_RESET         = 0;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_START         = 1;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_HALT          = 2;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_SET_RUN_MODE  = 3;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_SET_INT_MODE  = 4;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_INIT_START    = 5;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_INIT_END      = 6;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_INIT_PACKET   = 7;
localparam reg [INSTRUCTION_WIDTH-1:0] INSTR_READ_OUTPUT   = 8;

// Other control units enums (tailored to how they are used in this file)
localparam reg [PARAM_WIDTH-1:0]          RUN_MODE_SAMPLE  = 1;
localparam reg [RST_MEM_TARGET_WIDTH-1:0] RESET_MEM_ALL_OH = 3;
localparam reg [PARAM_WIDTH-1:0]          RESET_HARD       = 1;
localparam reg [RST_TYPE_WIDTH-1:0]       RESET_STATES     = 2;

//
// Internal signals
//

// State machine signals
reg [IF_STATE_WIDTH-1:0] state;
reg init_reset;
reg init_setup;
reg start_req;
reg command_exec;
reg command_done;

// Command signals
reg [INSTRUCTION_WIDTH-1:0] command_instruction;
reg [PARAM_WIDTH-1:0]       command_params;

// Control signals
wire control_unit_enable;
reg  control_unit_busy;
wire control_unit_interrupt;
reg  control_unit_interrupt_ack;
reg  control_unit_interrupt_ack_valid_n;

// External configuration signals
reg [OUT_READ_END_WIDTH-1:0] num_output_neurons;
reg [PARAM_WIDTH-1:0] num_sample_timesteps;

// Cycle counter signals
reg counting;            // Flag to indicate counting state
reg [31:0] counter;      // Internal counter


//
// Instantiated modules
//

// Command FIFO
reg                             command_fifo_s_valid;
wire                            command_fifo_s_ready;
wire [COMMAND_BUFFER_WIDTH-1:0] command_fifo_s_data;

wire                            command_fifo_m_valid;
wire                            command_fifo_m_ready;
wire [COMMAND_BUFFER_WIDTH-1:0] command_fifo_m_data;

control_command_fifo #() command_fifo (
    .s_axis_aclk(clk_i),
    .s_axis_aresetn(rstn_i),
    .s_axis_tvalid(command_fifo_s_valid),
    .s_axis_tready(command_fifo_s_ready),
    .s_axis_tdata(command_fifo_s_data),
    .m_axis_tvalid(command_fifo_m_valid),
    .m_axis_tready(command_fifo_m_ready),
    .m_axis_tdata(command_fifo_m_data)
);

// Control unit


ControlUnit #(
    // No changes to default parameters
) control_unit (
    .clk_i(clk_i),
    .rstn_i(rstn_i),

    .en_i(control_unit_enable),

    .command_fifo_ready_o(command_fifo_m_ready),
    .command_fifo_data_i(command_fifo_m_data),
    .command_fifo_valid_i(command_fifo_m_valid),

    .input_fifo_ready_o(input_fifo_ready_o),
    .input_fifo_data_i(input_fifo_data_i),
    .input_fifo_valid_i(input_fifo_valid_i),

    .output_fifo_ready_i(output_fifo_ready_i),
    .output_fifo_data_o(output_fifo_data_o),
    .output_fifo_valid_o(output_fifo_valid_o),
    .output_fifo_last_o(output_fifo_last_o),

    .core_top_neuron_leak_ram_write_en_i(core_top_neuron_leak_ram_write_en_i),
    .core_top_neuron_leak_ram_addr_i(core_top_neuron_leak_ram_addr_i),
    .core_top_neuron_leak_ram_data_i(core_top_neuron_leak_ram_data_i),
    .core_top_neuron_tau_mem_inv_i(core_top_neuron_tau_mem_inv_i),

    .output_core_neuron_leak_ram_write_en_i(output_core_neuron_leak_ram_write_en_i),
    .output_core_neuron_leak_ram_addr_i(output_core_neuron_leak_ram_addr_i),
    .output_core_neuron_leak_ram_data_i(output_core_neuron_leak_ram_data_i),
    .output_core_neuron_tau_mem_inv_i(output_core_neuron_tau_mem_inv_i),

    .interrupt_o(control_unit_interrupt),
    .interrupt_ack_i(control_unit_interrupt_ack),
    .interrupt_ack_valid_n_i(control_unit_interrupt_ack_valid_n),

    // Memories
    .core_top_weight_ram_we(core_top_weight_ram_we),
    .core_top_weight_ram_addr(core_top_weight_ram_addr),
    .core_top_weight_ram_data(core_top_weight_ram_data),

    .core_top_routes_ram_write_enable(core_top_routes_ram_write_enable),
    .core_top_routes_ram_write_addr(core_top_routes_ram_write_addr),
    .core_top_routes_ram_data(core_top_routes_ram_data),

    .core_top_memory_mapping_ram_write_en(core_top_memory_mapping_ram_write_en),
    .core_top_memory_mapping_ram_write_addr(core_top_memory_mapping_ram_write_addr),
    .core_top_memory_mapping_ram_data_in(core_top_memory_mapping_ram_data_in),

    .output_core_weight_ram_we(output_core_weight_ram_we),
    .output_core_weight_ram_addr(output_core_weight_ram_addr),
    .output_core_weight_ram_data(output_core_weight_ram_data),

    .input_multicast_routes_ram_write_en(input_multicast_routes_ram_write_en),
    .input_multicast_routes_ram_write_addr(input_multicast_routes_ram_write_addr),
    .input_multicast_routes_ram_data_in(input_multicast_routes_ram_data_in),

    .input_multicast_mapping_ram_write_en(input_multicast_mapping_ram_write_en),
    .input_multicast_mapping_ram_write_addr(input_multicast_mapping_ram_write_addr),
    .input_multicast_mapping_ram_data_in(input_multicast_mapping_ram_data_in),

    .status_reg_o() // Ignored in this version
);

//
// Signal assignments
//

assign command_fifo_s_data = {{
    (COMMAND_BUFFER_WIDTH - COMMAND_WIDTH){1'b0}},
    command_params, command_instruction
};

assign control_unit_enable = en_i;

//
// Logic
//

always @(posedge clk_i) begin
    if (!rstn_i) begin
        state                              <= IF_STATE_IDLE;
        start_req                          <= 0;
        command_exec                       <= 0;
        command_done                       <= 0;
        init_reset                         <= 0;
        init_setup                         <= 0;

        command_fifo_s_valid               <= 0;

        control_unit_busy                  <= 0;
        control_unit_interrupt_ack         <= 0;
        control_unit_interrupt_ack_valid_n <= 1;

        interrupt_o                        <= 0;

        // Reset cycle counter signals
        counting <= 1'b0;
        counter <= 32'b0;
        interrupt_latency <= 32'b0;

    end else if (en_i) begin
        // Store external configuration
        num_output_neurons <= num_output_neurons_i;
        num_sample_timesteps <= num_sample_timesteps_i;

        // Store start request
        if (interrupt_i) begin
            start_req <= 1;
        end

        // De-assert interrupt_o after 1 cycle
        if (interrupt_o) begin
            interrupt_o <= 0;
        end

        // De-assert command_done after 1 cycle
        if (command_done) begin
            command_done <= 0;
        end

        if (command_exec) begin
            if (!control_unit_busy) begin
                command_fifo_s_valid <= 1;
                control_unit_busy    <= 1;
            end else begin
                command_fifo_s_valid <= 0;
            end

            if (control_unit_interrupt) begin
                // Clear control unit interrupt
                control_unit_interrupt_ack         <= 1;
                control_unit_interrupt_ack_valid_n <= 0;
            end else if (control_unit_interrupt_ack & ~control_unit_interrupt_ack_valid_n) begin
                // Interrupt cleared, setup finished
                control_unit_interrupt_ack         <= 0;
                control_unit_interrupt_ack_valid_n <= 1;

                control_unit_busy <= 0;
                command_exec      <= 0;
                command_done      <= 1;
            end
        end else begin
            // State machine logic
            case (state)
                IF_STATE_IDLE: begin
                    if (!init_reset) begin
                        init_reset <= 1;
                        state      <= IF_STATE_RESET_ALL;
                    end else if (!init_setup) begin
                        init_setup <= 1;
                        state      <= IF_STATE_SETUP;
                    end else if (start_req) begin
                        start_req <= 0;
                        state     <= IF_STATE_RUNNING;
                    end
                end

                IF_STATE_SETUP: begin
                    if (command_done) begin
                        state <= IF_STATE_IDLE;
                    end else begin
                        command_instruction <= INSTR_SET_RUN_MODE;
                        command_params      <= {1'b1, (RUN_MODE_SAMPLE) & ((1 << PARAM_WIDTH) - 1)};
                        command_exec        <= 1;
                    end
                end

                IF_STATE_RUNNING: begin
                    if (command_done) begin
                        state <= IF_STATE_OUTPUT_READ;
                    end else begin
                        command_instruction <= INSTR_START;
                        command_params      <= num_sample_timesteps & ((1 << PARAM_WIDTH) - 1);
                        command_exec        <= 1;
                    end
                end

                IF_STATE_OUTPUT_READ: begin
                    if (command_done) begin
                        interrupt_o <= 1;
                        state       <= IF_STATE_RESET_STATES;
                    end else begin
                        command_instruction <= INSTR_READ_OUTPUT;
                        command_params      <= {1'b1, (num_output_neurons-1) & ((1 << OUT_READ_END_WIDTH) - 1), {OUT_READ_START_WIDTH{1'b0}}};
                        command_exec        <= 1;
                    end
                end

                IF_STATE_RESET_STATES: begin
                    if (command_done) begin
                        state <= IF_STATE_IDLE;
                    end else begin
                        command_instruction <= INSTR_RESET;
                        command_params      <= {RESET_MEM_ALL_OH & ((1 << RST_MEM_TARGET_WIDTH) - 1), {RST_LEN_WIDTH{1'b0}}, RESET_STATES & ((1 << RST_TYPE_WIDTH) - 1)};
                        command_exec        <= 1;
                    end
                end

                IF_STATE_RESET_ALL: begin
                    if (command_done) begin
                        state <= IF_STATE_IDLE;
                    end else begin
                        command_instruction <= INSTR_RESET;
                        command_params      <= {1'b1, (RESET_HARD) & ((1 << PARAM_WIDTH) - 1)};
                        command_exec        <= 1;
                    end
                end
            endcase
        end

        // Cycle counter logic
        if (interrupt_i) begin
            // When interrupt_i goes high, reset everything
            counting <= 1'b1;    // Start counting
            counter <= 32'b0;    // Reset counter
            interrupt_latency <= 32'b0;      // Reset output
        end
        else if (interrupt_o && counting) begin
            // When interrupt_o goes high while counting
            counting <= 1'b0;    // Stop counting
            interrupt_latency <= counter;    // Output the final count
        end
        else if (counting) begin
            // While counting is active, increment counter
            counter <= counter + 1;
        end
    end
end

endmodule
