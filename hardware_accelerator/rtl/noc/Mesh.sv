`timescale 1ns / 1ps

`include "global_params.vh"

module Mesh #(
  parameter integer X                    = NUM_CORES_X_G,
  parameter integer Y                    = NUM_CORES_Y_G,
  parameter integer TIMESTEP_WIDTH       = TIMESTEP_WIDTH_G,
  parameter integer DATA_FABRIC_WIDTH_X  = MESH_PACKET_DATA_WIDTH_X_G,
  parameter integer DATA_FABRIC_WIDTH_Y  = MESH_PACKET_DATA_WIDTH_Y_G,
  parameter integer NODE_DONE_IN_MAX_CNT = NODE_DONE_IN_MAX_CNT_G,
  parameter integer NODE_IDLE_IN_MAX_CNT = NODE_IDLE_IN_MAX_CNT_G
) (
  input  logic clk_i,

  input  logic                      rst_i,
  input  logic                      enable_i,
  input  logic                      init_i,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,

  output logic done_o,
  output logic idle_o,

  output logic                           west_in_ready_o [Y],
  input  logic                           west_in_valid_i [Y],
  input  logic [DATA_FABRIC_WIDTH_X-1:0] west_in_data_i  [Y],

  input  logic                           east_out_ready_i [Y],
  output logic                           east_out_valid_o [Y],
  output logic [DATA_FABRIC_WIDTH_X-1:0] east_out_data_o  [Y]
);

  //============================================================================
  // Local parameters
  //============================================================================
  localparam int UPSTREAM_CTRL_CNT_THRESH = abs_diff(0, X - 1) + abs_diff(0, Y - 1);
  localparam int DONE_IDLE_WINDUP_CNT     = 2 * (UPSTREAM_CTRL_CNT_THRESH + 3);

  //============================================================================
  // CTRL_TREE downstream signal arrays
  //============================================================================
  logic                      rst_ctrl_i      [Y][X];
  logic                      rst_ctrl_o      [Y][X];
  logic                      enable_ctrl_i   [Y][X];
  logic                      enable_ctrl_o   [Y][X];
  logic                      init_ctrl_i     [Y][X];
  logic                      init_ctrl_o     [Y][X];
  logic [TIMESTEP_WIDTH-1:0] timestep_ctrl_i [Y][X];
  logic [TIMESTEP_WIDTH-1:0] timestep_ctrl_o [Y][X];

  //============================================================================
  // CTRL_TREE upstream signal arrays
  //============================================================================
  logic                                done_node   [Y][X];
  logic                                idle_node   [Y][X];
  logic [NODE_DONE_IN_MAX_CNT - 1 : 0] done_in     [Y][X];
  logic [NODE_IDLE_IN_MAX_CNT - 1 : 0] idle_in     [Y][X];
  logic                                done_skid_d [Y][Y+1];
  logic                                done_skid_q [Y][Y+1];

  //============================================================================
  // DATA_FABRIC internal signal arrays
  //============================================================================
  logic                           west_input_valid  [Y][X];
  logic                           west_input_ready  [Y][X];
  logic [DATA_FABRIC_WIDTH_X-1:0] west_input_data   [Y][X];

  logic                           west_output_valid [Y][X];
  logic                           west_output_ready [Y][X];
  logic [DATA_FABRIC_WIDTH_X-1:0] west_output_data  [Y][X];

  logic                           east_input_valid  [Y][X];
  logic                           east_input_ready  [Y][X];
  logic [DATA_FABRIC_WIDTH_X-1:0] east_input_data   [Y][X];

  logic                           east_output_valid [Y][X];
  logic                           east_output_ready [Y][X];
  logic [DATA_FABRIC_WIDTH_X-1:0] east_output_data  [Y][X];

  logic                           north_input_valid  [Y][X];
  logic                           north_input_ready  [Y][X];
  logic [DATA_FABRIC_WIDTH_Y-1:0] north_input_data   [Y][X];

  logic                           north_output_valid [Y][X];
  logic                           north_output_ready [Y][X];
  logic [DATA_FABRIC_WIDTH_Y-1:0] north_output_data  [Y][X];

  logic                           south_input_valid  [Y][X];
  logic                           south_input_ready  [Y][X];
  logic [DATA_FABRIC_WIDTH_Y-1:0] south_input_data   [Y][X];

  logic                           south_output_valid [Y][X];
  logic                           south_output_ready [Y][X];
  logic [DATA_FABRIC_WIDTH_Y-1:0] south_output_data  [Y][X];

  logic                           west_chain_valid [Y][Y+1];
  logic                           west_chain_ready [Y][Y+1];
  logic [DATA_FABRIC_WIDTH_X-1:0] west_chain_data  [Y][Y+1];

  //============================================================================
  // CTRL_TREE downstream wiring
  //============================================================================
  genvar gj, gi, gb;
  generate
    for (gj = 0; gj < Y; gj++) begin : ctrl_rows

      if (gj == 0) begin : ctrl_col0_root
        assign rst_ctrl_i     [0][0] = rst_i;
        assign enable_ctrl_i  [0][0] = enable_i;
        assign init_ctrl_i    [0][0] = init_i;
        assign timestep_ctrl_i[0][0] = timestep_i;
      end else begin : ctrl_col0_chain
        assign rst_ctrl_i     [gj][0] = rst_ctrl_o     [gj-1][0];
        assign enable_ctrl_i  [gj][0] = enable_ctrl_o  [gj-1][0];
        assign init_ctrl_i    [gj][0] = init_ctrl_o    [gj-1][0];
        assign timestep_ctrl_i[gj][0] = timestep_ctrl_o[gj-1][0];
      end

      if (X > 1) begin : ctrl_row_chains
        genvar gx;
        for (gx = 1; gx < X; gx++) begin : ctrl_cols
          assign rst_ctrl_i     [gj][gx] = rst_ctrl_o     [gj][gx-1];
          assign enable_ctrl_i  [gj][gx] = enable_ctrl_o  [gj][gx-1];
          assign init_ctrl_i    [gj][gx] = init_ctrl_o    [gj][gx-1];
          assign timestep_ctrl_i[gj][gx] = timestep_ctrl_o[gj][gx-1];
        end
      end

    end
  endgenerate

  //============================================================================
  // CTRL_TREE upstream wiring (done / idle aggregation)
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : done_rows
      for (gi = 0; gi < X; gi++) begin : done_cols

        if (gi == X-1) begin : node_leaf
          assign done_in[gj][gi][0] = 1'b1;
          assign done_in[gj][gi][1] = 1'b1;
          assign done_in[gj][gi][2] = 1'b1;
          assign idle_in[gj][gi][0] = 1'b1;
          assign idle_in[gj][gi][1] = 1'b1;
          assign idle_in[gj][gi][2] = 1'b1;
        end else if (gi == 0 && gj < Y-1) begin : node_branch_nonbottom
          assign done_in[gj][0][0] = done_node[gj][1];
          assign done_in[gj][0][1] = done_node[gj+1][0];
          assign done_in[gj][0][2] = done_skid_q[gj][gj+1];
          assign idle_in[gj][0][0] = idle_node[gj][1];
          assign idle_in[gj][0][1] = idle_node[gj+1][0];
          assign idle_in[gj][0][2] = done_skid_q[gj][gj+1];               // The boundary skid bufs are never "idle",
        end else if (gi == 0 && gj == Y-1) begin : node_branch_bottom     //   so we use their "done" signals
          assign done_in[Y-1][0][0] = done_node[Y-1][1];
          assign done_in[Y-1][0][1] = 1'b1;
          assign done_in[Y-1][0][2] = done_skid_q[Y-1][Y];
          assign idle_in[Y-1][0][0] = idle_node[Y-1][1];
          assign idle_in[Y-1][0][1] = 1'b1;
          assign idle_in[Y-1][0][2] = done_skid_q[Y-1][Y];
        end else begin : node_middle
          assign done_in[gj][gi][0] = done_node[gj][gi+1];
          assign done_in[gj][gi][1] = 1'b1;
          assign done_in[gj][gi][2] = 1'b1;
          assign idle_in[gj][gi][0] = idle_node[gj][gi+1];
          assign idle_in[gj][gi][1] = 1'b1;
          assign idle_in[gj][gi][2] = 1'b1;
        end

      end

      for (gb = 0; gb <= gj; gb++) begin : done_skid_chains
        if (gb == 0) begin : first_stage_done
          assign done_skid_d[gj][1] = ~west_chain_valid[gj][1];
        end else begin : chain_stage_done
          assign done_skid_d[gj][gb+1] = ~west_chain_valid[gj][gb+1] && done_skid_q[gj][gb];
        end

        always_ff @(posedge clk_i) begin
          if (rst_ctrl_i[gj][0]) begin
            done_skid_q[gj][gb+1] <= 1'b0;
          end else begin
            done_skid_q[gj][gb+1] <= done_skid_d[gj][gb+1];
          end
        end
      end

    end
  endgenerate

  generate
    if (UPSTREAM_CTRL_CNT_THRESH == 0) begin : gen_direct
      assign done_o = done_node[0][0];
      assign idle_o = idle_node[0][0];

    end else begin : gen_thresh

      localparam WINDUP_CNT_W = ($clog2(DONE_IDLE_WINDUP_CNT + 1) > 0) ? $clog2(DONE_IDLE_WINDUP_CNT + 1) : 1;
      logic                    enable_in_posedge;
      logic                    enable_in_negedge;
      logic                    enable_out_level;
      logic [WINDUP_CNT_W-1:0] windup_count;
      logic                    windup_thresh;

      Pulse_Generator u_pulse_enable (
        .clock            (clk_i),
        .level_in         (enable_i || init_i),
        .pulse_posedge_out(enable_in_posedge),
        .pulse_negedge_out(enable_in_negedge),
        .pulse_anyedge_out(/* ignored */)
      );

      Pulse_Latch #(
        .RESET_VALUE(1'b0)
      ) u_latch_enable (
        .clock     (clk_i),
        .clear     (enable_in_negedge | rst_i),
        .pulse_in  (enable_in_posedge),
        .level_out (enable_out_level)
      );

      Counter_Binary #(
        .WORD_WIDTH   (WINDUP_CNT_W),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_cnt_enable (
        .clock     (clk_i),
        .clear     (enable_in_negedge | rst_i),
        .up_down   (1'b0),
        .run       (enable_out_level && ~windup_thresh),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/* ignored */),
        .carries   (/* ignored */),
        .overflow  (/* ignored */),
        .count     (windup_count)
      );

      assign windup_thresh = (windup_count >= WINDUP_CNT_W'(unsigned'(DONE_IDLE_WINDUP_CNT)));

      localparam DONE_IDLE_CNT_W = ($clog2(UPSTREAM_CTRL_CNT_THRESH + 1) > 0) ? $clog2(UPSTREAM_CTRL_CNT_THRESH + 1) : 1;

      logic [DONE_IDLE_CNT_W-1:0] done_count;
      logic                       done_thresh;

      Counter_Binary #(
        .WORD_WIDTH   (DONE_IDLE_CNT_W),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_cnt_done (
        .clock     (clk_i),
        .clear     (~done_node[0][0] || enable_in_negedge || rst_i),
        .up_down   (1'b0),
        .run       (done_node[0][0] && ~done_thresh && windup_thresh),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/* ignored */),
        .carries   (/* ignored */),
        .overflow  (/* ignored */),
        .count     (done_count)
      );

      assign done_thresh = (done_count >= DONE_IDLE_CNT_W'(unsigned'(UPSTREAM_CTRL_CNT_THRESH)));
      assign done_o      = done_thresh;

      logic [DONE_IDLE_CNT_W-1:0] idle_count;
      logic                       idle_thresh;

      Counter_Binary #(
        .WORD_WIDTH   (DONE_IDLE_CNT_W),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_cnt_idle (
        .clock     (clk_i),
        .clear     (~idle_node[0][0] || enable_in_negedge || rst_i),
        .up_down   (1'b0),
        .run       (idle_node[0][0] && ~idle_thresh && windup_thresh),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/* ignored */),
        .carries   (/* ignored */),
        .overflow  (/* ignored */),
        .count     (idle_count)
      );

      assign idle_thresh = (idle_count >= DONE_IDLE_CNT_W'(unsigned'(UPSTREAM_CTRL_CNT_THRESH)));
      assign idle_o      = idle_thresh;

    end
  endgenerate

  //============================================================================
  // DATA_FABRIC: west boundary (col 0) input
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : west_boundary
      assign west_chain_valid[gj][0] = west_in_valid_i[gj];
      assign west_chain_data [gj][0] = west_in_data_i [gj];
      assign west_in_ready_o [gj]    = west_chain_ready[gj][0];

      for (gb = 0; gb <= gj; gb++) begin : skid_buf
        Pipeline_Skid_Buffer #(
          .WORD_WIDTH     (DATA_FABRIC_WIDTH_X),
          .CIRCULAR_BUFFER(0)
        ) u_west_skid (
          .clock       (clk_i),
          .clear       (rst_ctrl_i[gj][0]),
          .input_valid (west_chain_valid[gj][gb]),
          .input_ready (west_chain_ready[gj][gb]),
          .input_data  (west_chain_data [gj][gb]),
          .output_valid(west_chain_valid[gj][gb+1]),
          .output_ready(west_chain_ready[gj][gb+1]),
          .output_data (west_chain_data [gj][gb+1])
        );
      end

      assign west_input_valid[gj][0]     = west_chain_valid[gj][gj+1];
      assign west_input_data [gj][0]     = west_chain_data [gj][gj+1];
      assign west_chain_ready[gj][gj+1]  = west_input_ready[gj][0];
    end
  endgenerate

  //============================================================================
  // DATA_FABRIC: east boundary (col X-1) output
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : east_boundary
      assign east_out_valid_o [gj]      = east_output_valid[gj][X-1];
      assign east_out_data_o  [gj]      = east_output_data [gj][X-1];
      assign east_output_ready[gj][X-1] = east_out_ready_i [gj];
    end
  endgenerate

  //============================================================================
  // DATA_FABRIC: horizontal inter-node connections
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : horiz_rows
      for (gi = 0; gi < X-1; gi++) begin : horiz_cols
        assign west_input_valid [gj][gi+1] = east_output_valid[gj][gi];
        assign west_input_data  [gj][gi+1] = east_output_data [gj][gi];
        assign east_output_ready[gj][gi]   = west_input_ready [gj][gi+1];

        assign east_input_valid [gj][gi]   = west_output_valid[gj][gi+1];
        assign east_input_data  [gj][gi]   = west_output_data [gj][gi+1];
        assign west_output_ready[gj][gi+1] = east_input_ready [gj][gi];
      end
    end
  endgenerate

  //============================================================================
  // DATA_FABRIC: vertical inter-node connections
  //============================================================================
  generate
    for (gj = 0; gj < Y-1; gj++) begin : vert_rows
      for (gi = 0; gi < X; gi++) begin : vert_cols
        assign north_input_valid [gj+1][gi] = south_output_valid[gj][gi];
        assign north_input_data  [gj+1][gi] = south_output_data [gj][gi];
        assign south_output_ready[gj][gi]   = north_input_ready [gj+1][gi];

        assign south_input_valid [gj][gi]   = north_output_valid[gj+1][gi];
        assign south_input_data  [gj][gi]   = north_output_data [gj+1][gi];
        assign north_output_ready[gj+1][gi] = south_input_ready [gj][gi];
      end
    end
  endgenerate

  //============================================================================
  // DATA_FABRIC: open boundary tie-offs
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : east_input_tie
      assign east_input_valid[gj][X-1] = 1'b0;
      assign east_input_data [gj][X-1] = '0;
    end
  endgenerate

  generate
    for (gj = 0; gj < Y; gj++) begin : west_output_sink
      assign west_output_ready[gj][0] = 1'b1;
    end
  endgenerate

  generate
    for (gi = 0; gi < X; gi++) begin : north_boundary
      assign north_input_valid [0][gi] = 1'b0;
      assign north_input_data  [0][gi] = '0;
      assign north_output_ready[0][gi] = 1'b1;
    end
  endgenerate

  generate
    for (gi = 0; gi < X; gi++) begin : south_boundary
      assign south_input_valid [Y-1][gi] = 1'b0;
      assign south_input_data  [Y-1][gi] = '0;
      assign south_output_ready[Y-1][gi] = 1'b1;
    end
  endgenerate

  //============================================================================
  // Node instantiation
  //============================================================================
  generate
    for (gj = 0; gj < Y; gj++) begin : rows
      for (gi = 0; gi < X; gi++) begin : cols

        Node #(
          .CORE_TYPE (
            (gi == 0 && gj == 0)         ? "INPUT"  :
            (gi == X-1 && gj == Y-1)     ? "OUTPUT" :
                                           "FULL"),
          .GRID_X_ID             (gi),
          .GRID_Y_ID             (gj),
          .DEEPEST_NODE          ((gi == X - 1 && gj == Y - 1) ? 1 : 0)
        ) u_node (
          .clk_i(clk_i),

          .rst_i     (rst_ctrl_i     [gj][gi]),
          .rst_o     (rst_ctrl_o     [gj][gi]),
          .enable_i  (enable_ctrl_i  [gj][gi]),
          .enable_o  (enable_ctrl_o  [gj][gi]),
          .init_i    (init_ctrl_i    [gj][gi]),
          .init_o    (init_ctrl_o    [gj][gi]),
          .timestep_i(timestep_ctrl_i[gj][gi]),
          .timestep_o(timestep_ctrl_o[gj][gi]),

          .done_i(done_in  [gj][gi]),
          .done_o(done_node[gj][gi]),
          .idle_i(idle_in  [gj][gi]),
          .idle_o(idle_node[gj][gi]),

          .west_input_ready_o (west_input_ready [gj][gi]),
          .west_input_valid_i (west_input_valid [gj][gi]),
          .west_input_data_i  (west_input_data  [gj][gi]),
          .west_output_ready_i(west_output_ready[gj][gi]),
          .west_output_valid_o(west_output_valid[gj][gi]),
          .west_output_data_o (west_output_data [gj][gi]),

          .east_input_ready_o (east_input_ready [gj][gi]),
          .east_input_valid_i (east_input_valid [gj][gi]),
          .east_input_data_i  (east_input_data  [gj][gi]),
          .east_output_ready_i(east_output_ready[gj][gi]),
          .east_output_valid_o(east_output_valid[gj][gi]),
          .east_output_data_o (east_output_data [gj][gi]),

          .north_input_ready_o (north_input_ready [gj][gi]),
          .north_input_valid_i (north_input_valid [gj][gi]),
          .north_input_data_i  (north_input_data  [gj][gi]),
          .north_output_ready_i(north_output_ready[gj][gi]),
          .north_output_valid_o(north_output_valid[gj][gi]),
          .north_output_data_o (north_output_data [gj][gi]),

          .south_input_ready_o (south_input_ready [gj][gi]),
          .south_input_valid_i (south_input_valid [gj][gi]),
          .south_input_data_i  (south_input_data  [gj][gi]),
          .south_output_ready_i(south_output_ready[gj][gi]),
          .south_output_valid_o(south_output_valid[gj][gi]),
          .south_output_data_o (south_output_data [gj][gi])
        );

      end
    end
  endgenerate

endmodule
