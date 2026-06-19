`timescale 1ns / 1ps

`include "global_params.vh"

module ControlUnitCoreCmdGen #(
    parameter TIMESTEP_WIDTH                    = TIMESTEP_WIDTH_G,
    parameter CORE_COMMAND_TYPE_WIDTH           = PKT_CMD_ID_WIDTH_G,
    parameter CORE_COMMAND_NEURON_ID_WIDTH      = CORE_NEURON_ID_WIDTH_G,
    parameter CORE_COMMAND_TARGET_CORE_X_WIDTH  = CORE_ID_X_WIDTH_G,
    parameter CORE_COMMAND_TARGET_CORE_Y_WIDTH  = CORE_ID_Y_WIDTH_G,
    parameter PKT_CMD_RQ_FLIT_COUNT             = PKT_CMD_RQ_FLIT_COUNT_G,
    parameter MESH_PACKET_DX_WIDTH              = MESH_PACKET_DX_WIDTH_G,
    parameter MESH_PACKET_DY_WIDTH              = MESH_PACKET_DY_WIDTH_G,
    parameter MESH_PACKET_DATA_WIDTH            = MESH_PACKET_DATA_WIDTH_X_G
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic enable_i,
    input  logic start_i,
    output logic idle_o,

    input  logic [CORE_COMMAND_TYPE_WIDTH-1:0]          core_cmd_type_i,
    input  logic [CORE_COMMAND_TARGET_CORE_X_WIDTH-1:0] target_core_x_i,
    input  logic [CORE_COMMAND_TARGET_CORE_Y_WIDTH-1:0] target_core_y_i,
    input  logic [CORE_COMMAND_NEURON_ID_WIDTH-1:0]     start_addr_i,
    input  logic [CORE_COMMAND_NEURON_ID_WIDTH-1:0]     end_addr_i,
    input  logic [TIMESTEP_WIDTH-1:0]                   timestep_i,

    input  logic                              core_cmd_ready_i,
    output logic                              core_cmd_valid_o,
    output logic [MESH_PACKET_DATA_WIDTH-1:0] core_cmd_data_o
);

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  typedef enum logic {
    IDLE,
    SEND_RQ
  } state_t;

  state_t state_q, state_d;

  logic [CORE_COMMAND_NEURON_ID_WIDTH-1:0]     start_addr_q,    start_addr_d;
  logic [CORE_COMMAND_NEURON_ID_WIDTH-1:0]     end_addr_q,      end_addr_d;
  logic [CORE_COMMAND_TARGET_CORE_X_WIDTH-1:0] target_core_x_q, target_core_x_d;
  logic [CORE_COMMAND_TARGET_CORE_Y_WIDTH-1:0] target_core_y_q, target_core_y_d;
  logic [TIMESTEP_WIDTH-1:0]                   timestep_q,      timestep_d;
  logic [CORE_COMMAND_TYPE_WIDTH-1:0]          cmd_type_q,      cmd_type_d;

  localparam int unsigned FLIT_CNT_MAX   = PKT_CMD_RQ_FLIT_COUNT;
  localparam int unsigned FLIT_CNT_WIDTH = (FLIT_CNT_MAX == 2) ? 2 : 1;
  localparam logic [FLIT_CNT_WIDTH-1:0] FLIT_IDX_SET_TIMESTEP = {FLIT_CNT_WIDTH{1'b0}};
  localparam logic [FLIT_CNT_WIDTH-1:0] FLIT_IDX_LAST_RQ      = (FLIT_CNT_MAX == 2) ? FLIT_CNT_WIDTH'(2'b10) :
                                                                                      FLIT_CNT_WIDTH'(2'b01);
  logic [FLIT_CNT_WIDTH-1:0] flit_cnt_q, flit_cnt_d;

  logic                              out_sb_input_valid;
  logic                              out_sb_input_ready;
  logic [MESH_PACKET_DATA_WIDTH-1:0] out_sb_input_data;

  pkt_noc_rq_s           rq_pkt;
  pkt_noc_cmd_timestep_s set_timestep_pkt;

  logic signed [MESH_PACKET_DY_WIDTH-1:0] mesh_routing_dy;
  assign mesh_routing_dy = -$signed({1'b0, target_core_y_q});

  // ===========================================================================
  // Output Skid Buffer
  // ===========================================================================

  Pipeline_Skid_Buffer #(
      .WORD_WIDTH     (MESH_PACKET_DATA_WIDTH),
      .CIRCULAR_BUFFER(0)
  ) u_output_skid_buffer (
      .clock       (clk_i),
      .clear       (rst_i),
      .input_valid (out_sb_input_valid),
      .input_ready (out_sb_input_ready),
      .input_data  (out_sb_input_data),
      .output_valid(core_cmd_valid_o),
      .output_ready(core_cmd_ready_i),
      .output_data (core_cmd_data_o)
  );

  // ===========================================================================
  // Packet Assembly: SET_TIMESTEP
  // ===========================================================================

  always_comb begin
    set_timestep_pkt = '0;
    set_timestep_pkt.target_core_y           = mesh_routing_dy[$bits(mesh_routing_dy)-1:0];
    set_timestep_pkt.target_core_x           = MESH_PACKET_DX_WIDTH'(target_core_x_q);
    set_timestep_pkt.core.cmd_id             = PKT_CMD_SET_TIMESTEP;
    set_timestep_pkt.core.ctrl_flag          = 1'b1;
    set_timestep_pkt.core.payload.target_cmd = pkt_cmd_type_e'(cmd_type_q);
    set_timestep_pkt.core.payload.timestep   =
        {{(PKT_TIMESTEP_SINGLE_TS_WIDTH_G-TIMESTEP_WIDTH){1'b0}}, timestep_q};
  end

  // ===========================================================================
  // Packet Assembly: RQ (one or two flits)
  // ===========================================================================

  generate
    if (PKT_CMD_RQ_FLIT_COUNT == 2) begin : gen_rq_double
      always_comb begin
        rq_pkt = '0;
        rq_pkt.target_core_y  = mesh_routing_dy[$bits(mesh_routing_dy)-1:0];
        rq_pkt.target_core_x  = MESH_PACKET_DX_WIDTH'(target_core_x_q);
        rq_pkt.core.cmd_id    = pkt_cmd_type_e'(cmd_type_q);
        rq_pkt.core.ctrl_flag = 1'b1;
        rq_pkt.core.payload.double.flit_id = (flit_cnt_q == FLIT_IDX_LAST_RQ) ? 1'b1 : 1'b0;
        rq_pkt.core.payload.double.start_end = (flit_cnt_q == FLIT_IDX_LAST_RQ) ?
            {{(PKT_RQ_DOUBLE_START_END_WIDTH_G-CORE_COMMAND_NEURON_ID_WIDTH){1'b0}}, end_addr_q} :
            {{(PKT_RQ_DOUBLE_START_END_WIDTH_G-CORE_COMMAND_NEURON_ID_WIDTH){1'b0}}, start_addr_q};
      end
    end else begin : gen_rq_single
      always_comb begin
        rq_pkt = '0;
        rq_pkt.target_core_y  = mesh_routing_dy[$bits(mesh_routing_dy)-1:0];
        rq_pkt.target_core_x  = MESH_PACKET_DX_WIDTH'(target_core_x_q);
        rq_pkt.core.cmd_id    = pkt_cmd_type_e'(cmd_type_q);
        rq_pkt.core.ctrl_flag = 1'b1;
        rq_pkt.core.payload.single.end_addr =
            {{(PKT_RQ_SINGLE_END_ADDR_WIDTH_G-CORE_COMMAND_NEURON_ID_WIDTH){1'b0}}, end_addr_q};
        rq_pkt.core.payload.single.start_addr = start_addr_q;
      end
    end
  endgenerate

  // ===========================================================================
  // Output Multiplexer
  // ===========================================================================

  always_comb begin
    if (state_q == SEND_RQ && flit_cnt_q == FLIT_IDX_SET_TIMESTEP) begin
      out_sb_input_data = set_timestep_pkt;
    end else begin
      out_sb_input_data = rq_pkt;
    end
  end

  // ===========================================================================
  // Combinational Logic
  // ===========================================================================

  always_comb begin
    state_d         = state_q;
    start_addr_d    = start_addr_q;
    end_addr_d      = end_addr_q;
    target_core_x_d = target_core_x_q;
    target_core_y_d = target_core_y_q;
    timestep_d      = timestep_q;
    cmd_type_d      = cmd_type_q;
    flit_cnt_d      = flit_cnt_q;

    out_sb_input_valid = 1'b0;

    case (state_q)
      IDLE: begin
        if (enable_i && start_i) begin
          start_addr_d    = start_addr_i;
          end_addr_d      = end_addr_i;
          target_core_x_d = target_core_x_i;
          target_core_y_d = target_core_y_i;
          timestep_d      = timestep_i;
          cmd_type_d      = core_cmd_type_i;
          flit_cnt_d      = '0;
          state_d         = SEND_RQ;
        end
      end

      SEND_RQ: begin
        if (out_sb_input_ready) begin
          if (flit_cnt_q == FLIT_IDX_SET_TIMESTEP) begin
            out_sb_input_valid = 1'b1;
            flit_cnt_d         = flit_cnt_q + 1'b1;
          end else begin
            out_sb_input_valid = 1'b1;
            if (flit_cnt_q == FLIT_IDX_LAST_RQ) begin
              state_d    = IDLE;
              flit_cnt_d = '0;
            end else begin
              flit_cnt_d = flit_cnt_q + 1'b1;
            end
          end
        end
      end

      default: begin
        state_d = IDLE;
      end
    endcase
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q         <= IDLE;
      start_addr_q    <= '0;
      end_addr_q      <= '0;
      target_core_x_q <= '0;
      target_core_y_q <= '0;
      timestep_q      <= '0;
      cmd_type_q      <= '0;
      flit_cnt_q      <= '0;
    end else begin
      state_q         <= state_d;
      start_addr_q    <= start_addr_d;
      end_addr_q      <= end_addr_d;
      target_core_x_q <= target_core_x_d;
      target_core_y_q <= target_core_y_d;
      timestep_q      <= timestep_d;
      cmd_type_q      <= cmd_type_d;
      flit_cnt_q      <= flit_cnt_d;
    end
  end

  // ===========================================================================
  // Output Assignments
  // ===========================================================================

  assign idle_o = (state_q == IDLE) && ~core_cmd_valid_o;

endmodule