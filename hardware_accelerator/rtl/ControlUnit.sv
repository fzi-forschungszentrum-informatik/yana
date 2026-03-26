`timescale 1ns / 1ps

`include "global_params.vh"
`include "ControlUnitEnums.vh"


module ControlUnit #(
    // Accelerator configuration
    parameter NUM_CORES_WIDTH         = NUM_CORES_WIDTH_G,
    // Command format
    parameter COMMAND_WIDTH           = COMMAND_WIDTH_G,
    parameter INSTRUCTION_WIDTH       = INSTRUCTION_WIDTH_G,
    parameter PARAM_WIDTH             = PARAM_WIDTH_G,
    parameter STATE_WIDTH             = CONTROL_UNIT_STATE_WIDTH_G,
    parameter RUN_MODE_WIDTH          = CONTROL_UNIT_RUN_MODE_WIDTH_G,
    parameter INT_MODE_WIDTH          = CONTROL_UNIT_INT_MODE_WIDTH_G,
    parameter RST_TYPE_WIDTH          = CONTROL_UNIT_RST_TYPE_WIDTH_G,
    parameter RST_LEN_WIDTH           = CONTROL_UNIT_RST_LEN_WIDTH_G,
    parameter RST_MEM_TARGET_WIDTH    = CONTROL_UNIT_RST_MEM_TARGET_WIDTH_G,
    parameter STATUS_REGISTER_WIDTH   = CONTROL_UNIT_STATUS_REGISTER_WIDTH_G,
    parameter STATUS_CODE_WIDTH       = CONTROL_UNIT_STATUS_CODE_WIDTH_G,
    parameter STATUS_DATA_WIDTH       = CONTROL_UNIT_STATUS_DATA_WIDTH_G,
    parameter MEM_TARGET_WIDTH        = CONTROL_UNIT_MEM_TARGET_WIDTH_G,
    parameter OUT_READ_DATA_WIDTH     = NEURON_STATE_DATA_WIDTH_G,
    parameter OUT_READ_START_WIDTH    = CONTROL_UNIT_OUT_READ_START_WIDTH_G,
    parameter OUT_READ_END_WIDTH      = CONTROL_UNIT_OUT_READ_END_WIDTH_G,
    // Input data format
    parameter PACKET_WIDTH            = INPUT_PACKET_WIDTH_G,
    parameter EVENT_SOURCE_WIDTH      = INPUT_EVENT_SOURCE_WIDTH_G,
    parameter TIMESTEP_WIDTH          = TIMESTEP_WIDTH_G,
    // Command FIFO
    parameter COMMAND_BUFFER_WIDTH    = COMMAND_BUFFER_WIDTH_G,
    parameter COMMAND_BUFFER_DEPTH    = COMMAND_BUFFER_DEPTH_G,
    // Input data FIFO
    parameter INPUT_DATA_BUFFER_WIDTH = INPUT_BUFFER_WIDTH_G,
    parameter INPUT_DATA_BUFFER_DEPTH = INPUT_BUFFER_DEPTH_G,
    // Output data FIFO
    parameter OUTPUT_DATA_BUFFER_WIDTH = OUTPUT_BUFFER_WIDTH_G,
    parameter OUTPUT_DATA_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH_G,
    // Input multicast
    parameter SPIKE_OUT_FIFO_DATA_WIDTH = SPIKE_OUT_FIFO_DATA_WIDTH_G,
    parameter URAM_ROUTES_ADDR_WIDTH    = AXON_ROUTES_RAM_ADDR_WIDTH_G,
    parameter URAM_ROUTES_DATA_WIDTH    = AXON_ROUTES_RAM_DATA_WIDTH_G,
    parameter URAM_ROUTES_ENTRY_WIDTH   = AXON_ROUTES_RAM_ENTRY_WIDTH_G,
    parameter URAM_ROUTES_BYTE_WIDTH    = AXON_ROUTES_RAM_BYTE_WIDTH_G,
    parameter URAM_MAPPING_ADDR_WIDTH   = AXON_MEMORY_MAPPING_RAM_ADDR_WIDTH_G,
    parameter URAM_MAPPING_DATA_WIDTH   = AXON_MEMORY_MAPPING_RAM_DATA_WIDTH_G,
    parameter OUTPUT_FIFO_DATA_WIDTH    = OUTPUT_FIFO_DATA_WIDTH_G,
    parameter IM_URAM_ROUTES_ADDR_WIDTH = AXON_ROUTES_RAM_ADDR_WIDTH_G,
    // Core parameters
    parameter INPUT_DATA_WIDTH           = INPUT_DATA_WIDTH_G,
    parameter OUTPUT_EXTERNAL_DATA_WIDTH = OUTPUT_EXTERNAL_DATA_WIDTH_G,
    parameter WEIGHT_RAM_ADDR_WIDTH      = WEIGHT_RAM_ADDR_WIDTH_G,
    parameter WEIGHT_RAM_DATA_WIDTH      = WEIGHT_RAM_DATA_WIDTH_G,
    // Core top parameters
    parameter CORE_TOP_RAM_LEAK_ADDR_WIDTH    = RAM_LEAK_ADDR_WIDTH_G,
    parameter CORE_TOP_RAM_LEAK_DATA_WIDTH    = RAM_LEAK_DATA_WIDTH_G,
    parameter CORE_TOP_TAU_MEM_INV_DATA_WIDTH = TAU_MEM_INV_DATA_WIDTH_G,
    // Output core parameters
    parameter OUT_CORE_RAM_LEAK_ADDR_WIDTH    = OUT_CORE_RAM_LEAK_ADDR_WIDTH_G,
    parameter OUT_CORE_RAM_LEAK_DATA_WIDTH    = OUT_CORE_RAM_LEAK_DATA_WIDTH_G,
    parameter OUT_CORE_TAU_MEM_INV_DATA_WIDTH = OUT_CORE_TAU_MEM_INV_DATA_WIDTH_G,
    parameter OC_WEIGHT_RAM_ADDR_WIDTH = WEIGHT_RAM_ADDR_WIDTH_G
)(
    input  clk_i,
    input  rstn_i,

    input en_i,

    // Command FIFO Interface
    output                           command_fifo_ready_o,
    input [COMMAND_BUFFER_WIDTH-1:0] command_fifo_data_i,
    input                            command_fifo_valid_i,

    // Input Data FIFO Interface
    output                              input_fifo_ready_o,
    input [INPUT_DATA_BUFFER_WIDTH-1:0] input_fifo_data_i,
    input                               input_fifo_valid_i,

    // Output Data FIFO Interface
    input                                       output_fifo_ready_i,    // Ignored in this module
    output logic [OUTPUT_DATA_BUFFER_WIDTH-1:0] output_fifo_data_o,
    output logic                                output_fifo_valid_o,
    output logic                                output_fifo_last_o,

    // Core Top Configuration
    input                                       core_top_neuron_leak_ram_write_en_i,
    input [CORE_TOP_RAM_LEAK_ADDR_WIDTH-1:0]    core_top_neuron_leak_ram_addr_i,
    input [CORE_TOP_RAM_LEAK_DATA_WIDTH-1:0]    core_top_neuron_leak_ram_data_i,
    input [CORE_TOP_TAU_MEM_INV_DATA_WIDTH-1:0] core_top_neuron_tau_mem_inv_i,

    // Output Core Configuration
    input                                       output_core_neuron_leak_ram_write_en_i,
    input [OUT_CORE_RAM_LEAK_ADDR_WIDTH-1:0]    output_core_neuron_leak_ram_addr_i,
    input [OUT_CORE_RAM_LEAK_DATA_WIDTH-1:0]    output_core_neuron_leak_ram_data_i,
    input [OUT_CORE_TAU_MEM_INV_DATA_WIDTH-1:0] output_core_neuron_tau_mem_inv_i,

    output logic interrupt_o,
    input interrupt_ack_i,
    input interrupt_ack_valid_n_i,

    // Status register
    output [STATUS_REGISTER_WIDTH-1:0] status_reg_o,

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
    input wire [URAM_MAPPING_DATA_WIDTH-1:0] input_multicast_mapping_ram_data_in
);

//
// Derived local parameters
//

localparam integer MAPPING_PACKETS_PER_LINE = URAM_MAPPING_DATA_WIDTH / PARAM_WIDTH + 1;
localparam integer MAPPING_PACKET_SIZE      = $ceil(URAM_MAPPING_DATA_WIDTH / MAPPING_PACKETS_PER_LINE);
localparam integer LAST_MAPPING_PACKET_SIZE = URAM_MAPPING_DATA_WIDTH - (MAPPING_PACKETS_PER_LINE - 1) * MAPPING_PACKET_SIZE;

localparam integer ROUTING_PACKETS_PER_LINE = URAM_ROUTES_DATA_WIDTH / PARAM_WIDTH + 1;
localparam integer ROUTING_PACKET_SIZE      = $ceil(URAM_ROUTES_DATA_WIDTH / ROUTING_PACKETS_PER_LINE);
localparam integer LAST_ROUTING_PACKET_SIZE = URAM_ROUTES_DATA_WIDTH - (ROUTING_PACKETS_PER_LINE - 1) * ROUTING_PACKET_SIZE;

localparam integer ADDRESS_COUNTER_WIDTH    = (URAM_ROUTES_ADDR_WIDTH > URAM_MAPPING_ADDR_WIDTH) ?
                                               URAM_ROUTES_ADDR_WIDTH : URAM_MAPPING_ADDR_WIDTH;
localparam integer PACKET_COUNTER_WIDTH     = ($clog2(MAPPING_PACKETS_PER_LINE) > $clog2(ROUTING_PACKETS_PER_LINE)) ?
                                               $clog2(MAPPING_PACKETS_PER_LINE) : $clog2(ROUTING_PACKETS_PER_LINE);


//
// Internal signals
//

// Status register
StatusCode                    cu_status_code;
logic [STATUS_DATA_WIDTH-1:0] cu_status_data;

// State and configuration
State         cu_state;
RunMode       cu_run_mode;
InterruptMode cu_int_mode;

// Control signals
logic cu_timestep_done;
logic cu_halt_req;
logic cu_interrupt;

logic                      cu_sample_done;
logic [TIMESTEP_WIDTH-1:0] cu_sample_duration;

logic cu_cores_done;
logic cu_accelerator_ready;

// Command signals
Instruction             cu_command_instr;
logic [PARAM_WIDTH-1:0] cu_command_param;
logic                   cu_command_valid;
logic                   cu_command_ack;

// Memory initialization
MemoryTarget                      cu_init_mem_target;
logic [NUM_CORES_WIDTH-1:0]       cu_init_target_core;
logic [ADDRESS_COUNTER_WIDTH-1:0] cu_init_mem_addr_ctr;
logic [PACKET_COUNTER_WIDTH-1:0]  cu_init_mem_pkt_ctr;
logic                             cu_init_mem_full;

// Neuron state read-out
logic [OUT_READ_START_WIDTH-1:0] cu_read_out_start;
logic [OUT_READ_END_WIDTH-1:0]    cu_read_out_end;
logic                             cu_read_out_force_update_req;

// Software reset
logic cu_rstn_cmd;
ResetType cu_rst_type;

logic [RST_LEN_WIDTH-1:0] cu_rst_counter;
// Bitmask with 4 Bits:
//     core_top   |   output_core
// [w_sum | state | w_sum | state]
logic [3:0] cu_rst_mems;
logic       cu_rst_done_core_top, cu_rst_done_output_core;
logic       cu_rst_cores_done;

logic rstn;  // Combined reset signal (external and internal)

//
// Connection signals
//

// InputCore
logic                          input_core_en;
logic [EVENT_SOURCE_WIDTH-1:0] input_core_data;
logic [TIMESTEP_WIDTH-1:0]     input_core_timestep;
logic                          input_core_data_valid;
logic                          input_core_empty;

// TimeSync
logic [TIMESTEP_WIDTH-1:0] time_sync_current_ts;
logic                      time_sync_ts_synced;

// InputMulticast: read_enable to InputCore is registered one cycle (ready/valid vs read_en timing).
logic input_multicast_enable;

logic input_multicast_read_enable;
logic input_multicast_read_enable_d1;
always @(posedge clk_i) input_multicast_read_enable_d1 <= input_multicast_read_enable;

logic input_multicast_idle;
logic input_multicast_output_read_en;
logic input_multicast_output_read_valid;
logic [OUTPUT_FIFO_DATA_WIDTH-1:0] input_multicast_output_data;

// Core Top
logic [1:0]                core_top_rst_mems;
logic [TIMESTEP_WIDTH-1:0] core_top_timestep;
logic                      core_top_enable;
logic core_top_done;

logic                                    core_top_event_valid_input;
logic [INPUT_DATA_WIDTH-1:0]           core_top_event_input;
logic                                    core_top_event_ready;
logic                                    core_top_event_valid_output;
logic [OUTPUT_EXTERNAL_DATA_WIDTH-1:0] core_top_event_output;

// Output Core
logic [1:0]                output_core_rst_mems;
logic [TIMESTEP_WIDTH-1:0] output_core_timestep;
logic                      output_core_enable;
logic output_core_done;
logic output_core_event_ready;

logic                             output_core_neuron_state_read_fu;
logic                             output_core_neuron_state_read_req;
logic [OUT_READ_START_WIDTH-1:0]  output_core_neuron_state_read_start;
logic [OUT_READ_START_WIDTH-1:0]  output_core_neuron_state_read_end;
logic [OUT_READ_END_WIDTH-1:0]    output_core_neuron_state_read_id;
logic [OUT_READ_DATA_WIDTH-1:0]   output_core_neuron_state_read_data;
logic                             output_core_neuron_state_read_valid;
logic                             output_core_neuron_state_read_last;
logic                             output_core_neuron_state_read_done;


//
// Instantiated modules
//

InputCore #(
    .EVENT_SOURCE_WIDTH(EVENT_SOURCE_WIDTH),
    .PACKET_WIDTH(PACKET_WIDTH),
    .FIFO_BUFFER_WIDTH(INPUT_DATA_BUFFER_WIDTH),
    .FIFO_BUFFER_DEPTH(INPUT_DATA_BUFFER_DEPTH),
    .TIMESTEP_WIDTH(TIMESTEP_WIDTH)
) input_core (
    .clk_i(clk_i),
    .rstn_i(rstn),
    .en_i(input_core_en),
    .read_ready_i(input_multicast_read_enable_d1),
    .input_valid_o(input_core_data_valid),
    .input_data_o(input_core_data),
    .next_event_timestep_o(input_core_timestep),
    .empty_o(input_core_empty),
    .fifo_ready_o(input_fifo_ready_o),
    .fifo_data_i(input_fifo_data_i),
    .fifo_valid_i(input_fifo_valid_i)
);

TimeSync #(
    .TIMESTEP_WIDTH(TIMESTEP_WIDTH)
) time_sync (
    .clk_i(clk_i),
    .rstn_i(rstn),
    .acc_idle_i(cu_accelerator_ready),
    .ts_data_in_i(input_core_timestep),
    .ts_data_empty_i(input_core_empty),
    .current_ts_o(time_sync_current_ts),
    .ts_synced_o(time_sync_ts_synced)
);

InputMulticast #(
    .EVENT_SOURCE_WIDTH(EVENT_SOURCE_WIDTH),
    .SPIKE_OUT_FIFO_DATA_WIDTH(SPIKE_OUT_FIFO_DATA_WIDTH),
    .URAM_ROUTES_ADDR_WIDTH(IM_URAM_ROUTES_ADDR_WIDTH),
    .URAM_ROUTES_DATA_WIDTH(URAM_ROUTES_DATA_WIDTH),
    .URAM_ROUTES_ENTRY_WIDTH(URAM_ROUTES_ENTRY_WIDTH),
    .URAM_ROUTES_BYTE_WIDTH(URAM_ROUTES_BYTE_WIDTH),
    .URAM_MAPPING_ADDR_WIDTH(URAM_MAPPING_ADDR_WIDTH),
    .URAM_MAPPING_DATA_WIDTH(URAM_MAPPING_DATA_WIDTH),
    .OUTPUT_FIFO_DATA_WIDTH(OUTPUT_FIFO_DATA_WIDTH)
) input_multicast (
    .clk_i(clk_i),
    .rstn_i(rstn),
    .en_i(input_multicast_enable),
    .idle_o(input_multicast_idle),

    .input_core_read_en_o(input_multicast_read_enable),
    .input_core_read_valid_i(input_core_data_valid),
    .input_core_data_i(input_core_data),
    .output_read_en_i(input_multicast_output_read_en),
    .output_read_valid_o(input_multicast_output_read_valid),
    .output_data_o(input_multicast_output_data),

    .axon_routes_ram_write_enable_i(input_multicast_routes_ram_write_en),
    .axon_routes_ram_write_addr_i(input_multicast_routes_ram_write_addr),
    .axon_routes_ram_data_i(input_multicast_routes_ram_data_in),
    .axon_memory_mapping_ram_write_en_i(input_multicast_mapping_ram_write_en),
    .axon_memory_mapping_ram_write_addr_i(input_multicast_mapping_ram_write_addr),
    .axon_memory_mapping_ram_data_in_i(input_multicast_mapping_ram_data_in)
);

core_top #(
    .CORE_ID(6'b000000)
) core_top (
    // Signals from/to control unit
    .clk_i(clk_i),
    .rst_i(~rstn),
    .rst_mems_i(core_top_rst_mems),
    .rst_done_o(cu_rst_done_core_top),
    .timestep_i(core_top_timestep),
    .enable_i(core_top_enable),
    .router_done_i(~input_multicast_output_read_valid), // As soon as multicast output buffer is empty, it's done.
    .router_buffers_full_i(~output_core_event_ready),
    .neuron_core_done_o(core_top_done),

    // Incoming router signals to RX
    .event_valid_i(core_top_event_valid_input),
    .event_i(core_top_event_input),
    .event_ready_o(core_top_event_ready),

    // Outgoing router signals from TX
    .event_valid_o(core_top_event_valid_output),
    .event_o(core_top_event_output),

    // Expose Weight RAM from Synapse to control for weight updates
    .synapse_weight_ram_we_i(core_top_weight_ram_we),
    .synapse_weight_ram_addr_i(core_top_weight_ram_addr),
    .synapse_weight_ram_data_in(core_top_weight_ram_data),

    // Expose Mapping RAM to control for mapping information updates
    .axon_routes_ram_write_enable_i(core_top_routes_ram_write_enable),
    .axon_routes_ram_write_addr_i(core_top_routes_ram_write_addr),
    .axon_routes_ram_data_i(core_top_routes_ram_data),

    // Expose Routes RAM to control for route updates
    .axon_memory_mapping_ram_write_en_i(core_top_memory_mapping_ram_write_en),
    .axon_memory_mapping_ram_write_addr_i(core_top_memory_mapping_ram_write_addr),
    .axon_memory_mapping_ram_data_in_i(core_top_memory_mapping_ram_data_in),

    .neuron_leak_ram_write_en_i(core_top_neuron_leak_ram_write_en_i),
    .neuron_leak_ram_data_i(core_top_neuron_leak_ram_data_i),
    .neuron_leak_ram_addr_i(core_top_neuron_leak_ram_addr_i),
    .neuron_tau_mem_inv(core_top_neuron_tau_mem_inv_i)
);

output_core #(
    .SYNAPSE_WEIGHT_RAM_ADDR_WIDTH(OC_WEIGHT_RAM_ADDR_WIDTH)
) output_core (
    // Signals from/to control unit
    .clk_i(clk_i),
    .rst_i(~rstn),
    .rst_mems_i(output_core_rst_mems),
    .rst_done_o(cu_rst_done_output_core),
    .timestep_i(output_core_timestep),
    .enable_i(output_core_enable),
    .neuron_core_done_o(output_core_done),

    // Incoming router signals to RX
    .event_valid_i(core_top_event_valid_output),
    .event_i(core_top_event_output[INPUT_DATA_WIDTH-1:0]),    // Cut off core ID
    .event_ready_o(output_core_event_ready),
    .router_done_i(core_top_done),

    // Expose Weight RAM from Synapse to control for weight updates
    .synapse_weight_ram_we_i(output_core_weight_ram_we),
    .synapse_weight_ram_addr_i(output_core_weight_ram_addr),
    .synapse_weight_ram_data_in(output_core_weight_ram_data),

    // Interface for neuron state read-out
    .neuron_state_read_req_i(output_core_neuron_state_read_req),
    .neuron_state_read_fu_i(output_core_neuron_state_read_fu),
    .neuron_state_read_start_i(output_core_neuron_state_read_start),
    .neuron_state_read_end_i(output_core_neuron_state_read_end),
    .neuron_state_read_id_o(output_core_neuron_state_read_id),
    .neuron_state_read_data_o(output_core_neuron_state_read_data),
    .neuron_state_read_valid_o(output_core_neuron_state_read_valid),
    .neuron_state_read_last_o(output_core_neuron_state_read_last),
    .neuron_state_read_done_o(output_core_neuron_state_read_done),

    .neuron_leak_ram_write_en_i(output_core_neuron_leak_ram_write_en_i),
    .neuron_leak_ram_data_i(output_core_neuron_leak_ram_data_i),
    .neuron_leak_ram_addr_i(output_core_neuron_leak_ram_addr_i),
    .neuron_tau_mem_inv(output_core_neuron_tau_mem_inv_i)
);

//
// Wire assignments
//

// Status
assign status_reg_o = {cu_status_data, cu_status_code};

// Control/enable
assign interrupt_o            = cu_interrupt;
assign input_multicast_enable = (cu_state == STATE_RUNNING);
assign input_core_en          = input_multicast_enable & time_sync_ts_synced;
assign cu_sample_done         = !(time_sync_current_ts < cu_sample_duration);
assign cu_accelerator_ready   = cu_cores_done & input_multicast_idle;
assign cu_timestep_done       = (cu_sample_done | !time_sync_ts_synced) & cu_accelerator_ready & (cu_state == STATE_RUNNING);

// Command
assign cu_command_instr = Instruction'(command_fifo_data_i[INSTRUCTION_WIDTH-1:0]);
assign cu_command_param = command_fifo_data_i[COMMAND_WIDTH-1:INSTRUCTION_WIDTH];
assign cu_command_valid = command_fifo_valid_i;
assign command_fifo_ready_o = cu_command_ack;

// Cores (core_top and output_core)
assign cu_cores_done        = core_top_done & output_core_done;

assign core_top_rst_mems    = cu_rst_mems[1:0];
assign output_core_rst_mems = cu_rst_mems[3:2];
assign core_top_timestep    = time_sync_current_ts;
assign output_core_timestep = time_sync_current_ts;

assign core_top_event_input       = input_multicast_output_data[INPUT_DATA_WIDTH-1:0];  // Cut away core ID
assign core_top_event_valid_input = input_multicast_output_read_valid;

assign output_fifo_data_o  = {{(OUTPUT_DATA_BUFFER_WIDTH - OUT_READ_DATA_WIDTH){1'b0}}, output_core_neuron_state_read_data};
assign output_fifo_valid_o = output_core_neuron_state_read_valid;
assign output_fifo_last_o  = output_core_neuron_state_read_last;

assign input_multicast_output_read_en = core_top_event_ready;

// Output core neuron state read
assign output_core_neuron_state_read_fu = cu_read_out_force_update_req;

// Software reset
assign rstn              = rstn_i & cu_rstn_cmd;
assign cu_rst_cores_done = cu_rst_done_core_top & cu_rst_done_output_core;


//
// Control unit logic
//

always @(posedge clk_i) begin
    if (!rstn) begin
        // Control unit signals
        cu_command_ack      <= 0;
        cu_state            <= STATE_HALTED;
        cu_interrupt        <= 0;
        cu_status_code      <= STATUS_NO_ERROR;
        cu_status_data      <= 0;
        cu_sample_duration  <= 0;
        cu_halt_req         <= 0;

        // Input multicast initialization
        cu_init_mem_target   <= TARGET_INPUT_MAPPING;
        cu_init_target_core  <= 0;
        cu_init_mem_pkt_ctr  <= 0;
        cu_init_mem_addr_ctr <= 0;
        cu_init_mem_full     <= 0;

        // Output read-out
        cu_read_out_start            <= 0;
        cu_read_out_end              <= 0;
        cu_read_out_force_update_req <= 0;

        // Core top signals
        core_top_enable                      <= 0;

        // Output core signals
        output_core_enable                   <= 0;
        output_core_neuron_state_read_req    <= 0;
        output_core_neuron_state_read_start  <= 0;
        output_core_neuron_state_read_end    <= 0;

        if (!rstn_i) begin
            // External reset
            // Reset signals used for reset command and configuration registers
            cu_rstn_cmd       <= 1;
            cu_rst_counter    <= 0;
            cu_rst_type       <= RESET_SOFT;
            cu_rst_mems       <= 0;
            // Reset configuration registers
            cu_run_mode <= RUN_MODE_TIMESTEP;
            cu_int_mode <= INT_MODE_DEFAULT;
        end else if (!cu_rstn_cmd) begin
            // Internal reset logic (via command)
            case (cu_rst_type)
                RESET_SOFT: begin   // Only reset control unit configuration for given duration
                    cu_run_mode <= RUN_MODE_TIMESTEP;
                    cu_int_mode <= INT_MODE_DEFAULT;
                    cu_rst_mems <= 0;

                    if (cu_rst_counter <= 1) begin
                        cu_rstn_cmd       <= 1;
                        cu_rst_counter    <= 0;
                        cu_rst_type       <= RESET_SOFT;
                        cu_rst_mems       <= 0;

                        if (cu_int_mode == INT_MODE_DEFAULT) begin
                            cu_interrupt   <= 1;
                            cu_status_code <= STATUS_NO_ERROR;
                        end
                    end else begin
                        cu_rst_counter <= cu_rst_counter-1;
                    end
                end

                RESET_HARD: begin   // Reset control unit configuration and and stateful memories
                    cu_run_mode <= RUN_MODE_TIMESTEP;
                    cu_int_mode <= INT_MODE_DEFAULT;

                    if (cu_rst_cores_done) begin
                        cu_rstn_cmd       <= 1;
                        cu_rst_counter    <= 0;
                        cu_rst_type       <= RESET_SOFT;
                        cu_rst_mems       <= 0;

                        if (cu_int_mode == INT_MODE_DEFAULT) begin
                            cu_interrupt   <= 1;
                            cu_status_code <= STATUS_NO_ERROR;
                        end
                    end
                end

                RESET_STATES: begin // Only reset stateful memories
                    if (cu_rst_cores_done) begin
                        cu_rstn_cmd       <= 1;
                        cu_rst_counter    <= 0;
                        cu_rst_type       <= RESET_SOFT;
                        cu_rst_mems       <= 0;

                        if (cu_int_mode == INT_MODE_DEFAULT) begin
                            cu_interrupt   <= 1;
                            cu_status_code <= STATUS_NO_ERROR;
                        end
                    end
                end

                default: begin
                    cu_rstn_cmd    <= 1;
                    cu_interrupt   <= 1;
                    cu_status_code <= STATUS_PARAM_ERROR;
                end
            endcase
        end
    end else if (en_i) begin
        // Default assignments
        cu_command_ack <= 0;

        // Reset logic
        if ((cu_command_valid && !cu_command_ack) && cu_command_instr == INSTR_RESET) begin
            cu_command_ack    <= 1;
            cu_rstn_cmd       <= 0;
            cu_rst_type       <= ResetType'(cu_command_param[RST_TYPE_WIDTH-1:0]);
            cu_rst_counter    <= cu_command_param[(RST_TYPE_WIDTH+RST_LEN_WIDTH)-1:RST_TYPE_WIDTH];

            // Create reset bitmask
            if (ResetType'(cu_command_param[RST_TYPE_WIDTH-1:0]) == RESET_SOFT) begin
                // No reset of stateful memory
                cu_rst_mems <= 0;
            end else begin
                case (ResetMemTarget'(cu_command_param[(RST_TYPE_WIDTH+RST_LEN_WIDTH+RST_MEM_TARGET_WIDTH)-1 -: RST_MEM_TARGET_WIDTH]))
                    RESET_MEM_ALL: begin
                        cu_rst_mems <= (
                            1 << RESET_MEM_W_SUM_CORE_TOP    |
                            1 << RESET_MEM_STATE_CORE_TOP    |
                            1 << RESET_MEM_W_SUM_OUTPUT_CORE |
                            1 << RESET_MEM_STATE_OUTPUT_CORE
                        );
                    end

                    RESET_MEM_CORE_TOP: begin
                        cu_rst_mems <= (
                            1 << RESET_MEM_W_SUM_CORE_TOP |
                            1 << RESET_MEM_STATE_CORE_TOP
                        );
                    end

                    RESET_MEM_OUTPUT_CORE: begin
                        cu_rst_mems <= (
                            1 << RESET_MEM_W_SUM_OUTPUT_CORE |
                            1 << RESET_MEM_STATE_OUTPUT_CORE
                        );
                    end

                    RESET_MEM_ALL_OH: begin
                        cu_rst_mems <= (
                            1 << RESET_MEM_W_SUM_CORE_TOP    |
                            1 << RESET_MEM_STATE_CORE_TOP    |
                            1 << RESET_MEM_W_SUM_OUTPUT_CORE
                        );
                    end
                endcase
            end
        // Interrupt clear logic
        end else if (cu_interrupt) begin
            if (interrupt_ack_i & !interrupt_ack_valid_n_i) begin
                cu_interrupt   <= 0;
                cu_status_code <= STATUS_NO_ERROR;
                cu_status_data <= 0;
            end
        // State machine logic
        end else begin
            case (cu_state)
                STATE_HALTED: begin
                    if (cu_command_valid && !cu_command_ack) begin
                        cu_command_ack <= 1;
                        case (cu_command_instr)
                            INSTR_START: begin
                                cu_sample_duration <= cu_command_param[TIMESTEP_WIDTH-1:0];
                                cu_state           <= STATE_RUNNING;
                            end

                            INSTR_HALT: begin
                                // Ignore (no effect)
                            end

                            INSTR_SET_RUN_MODE: begin
                                cu_run_mode <= RunMode'(cu_command_param[RUN_MODE_WIDTH-1:0]);
                                if (cu_int_mode == INT_MODE_DEFAULT) begin
                                    cu_interrupt   <= 1;
                                    cu_status_code <= STATUS_NO_ERROR;
                                end
                            end

                            INSTR_SET_INT_MODE: begin
                                cu_int_mode <= InterruptMode'(cu_command_param[INT_MODE_WIDTH-1:0]);
                                if (cu_int_mode == INT_MODE_DEFAULT) begin
                                    cu_interrupt   <= 1;
                                    cu_status_code <= STATUS_NO_ERROR;
                                end
                            end

                            INSTR_INIT_START: begin
                                cu_state            <= STATE_INIT;
                                cu_init_mem_target  <= MemoryTarget'(cu_command_param[MEM_TARGET_WIDTH-1:0]);
                                cu_init_target_core <= cu_command_param[PARAM_WIDTH-1:MEM_TARGET_WIDTH];
                                if (cu_int_mode == INT_MODE_DEFAULT) begin
                                    cu_interrupt   <= 1;
                                    cu_status_code <= STATUS_NO_ERROR;
                                end
                            end

                            INSTR_READ_OUTPUT: begin
                                cu_state                     <= STATE_OUTPUT_READ;
                                cu_read_out_start            <= cu_command_param[OUT_READ_START_WIDTH-1:0];
                                cu_read_out_end              <= cu_command_param[OUT_READ_START_WIDTH+OUT_READ_END_WIDTH-1:OUT_READ_START_WIDTH];
                                cu_read_out_force_update_req <= cu_command_param[OUT_READ_START_WIDTH+OUT_READ_END_WIDTH -: 1];    // Read 1 bit
                            end

                            // Invalid instruction
                            default: begin
                                cu_interrupt   <= 1;
                                cu_status_code <= STATUS_INVALID_INSTR_ERROR;
                            end
                        endcase
                    end
                end


                STATE_RUNNING: begin
                    // Check halting conditions
                    if ((
                        ((cu_run_mode == RUN_MODE_TIMESTEP) & cu_timestep_done) |                               // Halt condition for RUN_MODE_TIMESTEP
                        ((cu_run_mode == RUN_MODE_SAMPLE) & cu_timestep_done & (cu_sample_done | cu_halt_req))  // Halt condition for RUN_MODE_SAMPLE
                    )) begin
                        cu_state    <= STATE_HALTED;
                        cu_halt_req <= 0;
                        // Disable cores
                        core_top_enable    <= 0;
                        output_core_enable <= 0;

                        if (cu_int_mode == INT_MODE_DEFAULT) begin
                            cu_interrupt   <= 1;
                            cu_status_code <= STATUS_NO_ERROR;
                        end
                    end else if ((cu_command_valid && !cu_command_ack) && cu_command_instr == INSTR_HALT) begin
                        cu_command_ack <= 1;
                        cu_halt_req    <= 1;
                    end else begin
                        // Enable cores
                        core_top_enable    <= 1;
                        output_core_enable <= 1;

                        if (cu_run_mode == RUN_MODE_SAMPLE) begin
                            // Disable cores for 1 cycle to start next timestep
                            if (cu_timestep_done) begin
                                core_top_enable    <= 0;
                                output_core_enable <= 0;
                            end
                        end
                    end
                end

                STATE_OUTPUT_READ: begin
                    // Start reading neuron states
                    output_core_neuron_state_read_req   <= 1;
                    output_core_neuron_state_read_start <= cu_read_out_start;
                    output_core_neuron_state_read_end   <= cu_read_out_end;

                    // Read-out of neuron states finished
                    if (output_core_neuron_state_read_done) begin
                        output_core_neuron_state_read_req <= 0;

                        cu_state <= STATE_HALTED;
                        if (cu_int_mode == INT_MODE_DEFAULT) begin
                            cu_interrupt   <= 1;
                            cu_status_code <= STATUS_NO_ERROR;
                        end
                    end
                end

            endcase
        end
    end
end

endmodule
