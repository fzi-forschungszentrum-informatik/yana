`timescale 1ns / 1ps

`include "global_params.vh"

module Node #(
  parameter string  CORE_TYPE    = "FULL",  // "FULL", "INPUT", "OUTPUT"
  parameter integer GRID_X_ID    = 0,
  parameter integer GRID_Y_ID    = 0,
  parameter integer DEEPEST_NODE = 0,

  parameter integer TIMESTEP_WIDTH = TIMESTEP_WIDTH_G,

  parameter integer DATA_FABRIC_WIDTH_X   = MESH_PACKET_DATA_WIDTH_X_G,
  parameter integer DATA_FABRIC_WIDTH_Y   = MESH_PACKET_DATA_WIDTH_Y_G,
  parameter integer FIELD_ROUTING_X_WIDTH = MESH_PACKET_DX_WIDTH_G,
  parameter integer FIELD_ROUTING_Y_WIDTH = MESH_PACKET_DY_WIDTH_G,
  parameter integer FIELD_ROUTING_X_LSB   = 0,                      // TODO: Right now X_LSB is fixed as the packets
  parameter integer FIELD_ROUTING_Y_LSB   = MESH_PACKET_DX_WIDTH_G, //   most-LSB field, should be a localparam per
                                                                    //   our convention, but seeing it here makes it
                                                                    //   easier to read 

  parameter integer NUM_CORES_X        = NUM_CORES_X_G,
  parameter integer NUM_CORES_Y        = NUM_CORES_Y_G,
  parameter integer CORE_IN_DATA_WIDTH = CORE_INPUT_WIDTH_G,

  parameter integer DONE_IN_MAX_CNT = NODE_DONE_IN_MAX_CNT_G,
  parameter integer IDLE_IN_MAX_CNT = NODE_IDLE_IN_MAX_CNT_G
) (
  input  logic clk_i,
  input  logic                      rst_i,
  output logic                      rst_o,
  input  logic                      enable_i,
  output logic                      enable_o,
  input  logic                      init_i,
  output logic                      init_o,
  input  logic [TIMESTEP_WIDTH-1:0] timestep_i,
  output logic [TIMESTEP_WIDTH-1:0] timestep_o,

  input  logic [DONE_IN_MAX_CNT - 1 : 0] done_i,
  output logic                           done_o,
  input  logic [IDLE_IN_MAX_CNT - 1 : 0] idle_i,
  output logic                           idle_o,

  output logic                           west_input_ready_o,
  input  logic                           west_input_valid_i,
  input  logic [DATA_FABRIC_WIDTH_X-1:0] west_input_data_i,
  input  logic                           west_output_ready_i,
  output logic                           west_output_valid_o,
  output logic [DATA_FABRIC_WIDTH_X-1:0] west_output_data_o,
  output logic                           east_input_ready_o,
  input  logic                           east_input_valid_i,
  input  logic [DATA_FABRIC_WIDTH_X-1:0] east_input_data_i,
  input  logic                           east_output_ready_i,
  output logic                           east_output_valid_o,
  output logic [DATA_FABRIC_WIDTH_X-1:0] east_output_data_o,
  output logic                           north_input_ready_o,
  input  logic                           north_input_valid_i,
  input  logic [DATA_FABRIC_WIDTH_Y-1:0] north_input_data_i,
  input  logic                           north_output_ready_i,
  output logic                           north_output_valid_o,
  output logic [DATA_FABRIC_WIDTH_Y-1:0] north_output_data_o,
  output logic                           south_input_ready_o,
  input  logic                           south_input_valid_i,
  input  logic [DATA_FABRIC_WIDTH_Y-1:0] south_input_data_i,
  input  logic                           south_output_ready_i,
  output logic                           south_output_valid_o,
  output logic [DATA_FABRIC_WIDTH_Y-1:0] south_output_data_o
);

  //============================================================================
  // Local parameters
  //============================================================================
  localparam int MANHATTAN_DEEPEST       = abs_diff(GRID_X_ID, NUM_CORES_X - 1) +
                                           abs_diff(GRID_Y_ID, NUM_CORES_Y - 1);
  localparam int MANHATTAN_DEEPEST_WIDTH = (MANHATTAN_DEEPEST + 1 > 1) ? $clog2(MANHATTAN_DEEPEST + 1) : 1;

  //============================================================================
  // Node Reset Logic
  //============================================================================
  logic rst_q;
  always_ff @(posedge clk_i) begin
    rst_q <= rst_i;
  end
  assign rst_o = rst_q;

  logic rst_local_q;
  generate
    if (DEEPEST_NODE == 0) begin : gen_reset_fsm
      logic rst_local_d;

      typedef enum logic [2:0] {
        RESET_IDLE,
        RESET_ACTIVE,
        RESET_DELAY
      } reset_state_e;

      reset_state_e state_reset_q, state_reset_d;

      logic                               delay_cnt_rst_run;
      logic                               delay_cnt_rst_clear;
      logic [MANHATTAN_DEEPEST_WIDTH-1:0] delay_cnt_rst_count;

      Counter_Binary #(
        .WORD_WIDTH   (MANHATTAN_DEEPEST_WIDTH),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_delay_cnt_rst (
        .clock     (clk_i),
        .clear     (delay_cnt_rst_clear),
        .up_down   (1'b0), // count up
        .run       (delay_cnt_rst_run),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/*ignored*/),
        .carries   (/*ignored*/),
        .overflow  (/*ignored*/),
        .count     (delay_cnt_rst_count)
      );

      always_ff @(posedge clk_i) begin
        state_reset_q <= state_reset_d;
        rst_local_q   <= rst_local_d;
      end

      always_comb begin
        state_reset_d       = state_reset_q;
        rst_local_d         = 1'b0;
        delay_cnt_rst_run   = 1'b0;
        delay_cnt_rst_clear = 1'b1;

        case (state_reset_q)
          RESET_IDLE: begin
            if (rst_i) begin
              rst_local_d   = 1'b1;
              state_reset_d = RESET_ACTIVE;
            end
          end

          RESET_ACTIVE: begin
            rst_local_d = 1'b1;
            if (!rst_i) begin
              delay_cnt_rst_run   = 1'b1;
              delay_cnt_rst_clear = 1'b0;
              state_reset_d       = RESET_DELAY;
            end
          end

          RESET_DELAY: begin
            localparam count_threshold = (MANHATTAN_DEEPEST_WIDTH)'({MANHATTAN_DEEPEST});
            if (rst_i) begin
              rst_local_d   = 1'b1;
              state_reset_d = RESET_ACTIVE;
            end else if (delay_cnt_rst_count < count_threshold) begin
              rst_local_d         = 1'b1;
              delay_cnt_rst_run   = 1'b1;
              delay_cnt_rst_clear = 1'b0;
            end else begin
              state_reset_d = RESET_IDLE;
            end
          end

          default: begin
            state_reset_d = RESET_IDLE;
          end
        endcase
      end
    end else begin : gen_reset_deepest
      assign rst_local_q = rst_q;
    end
  endgenerate

  //============================================================================
  // Node Initialization Logic
  //============================================================================
  logic init_q;
  always_ff @(posedge clk_i) begin
    init_q <= init_i;
  end
  assign init_o = init_q;

  logic init_local_q;
  generate
    if (DEEPEST_NODE == 0) begin : gen_init_fsm
      logic init_local_d;

      typedef enum logic [2:0] {
        INIT_IDLE,
        INIT_ACTIVE,
        INIT_DELAY
      } init_state_e;

      init_state_e state_init_q, state_init_d;

      logic                               delay_cnt_init_run;
      logic                               delay_cnt_init_clear;
      logic [MANHATTAN_DEEPEST_WIDTH-1:0] delay_cnt_init_count;

      Counter_Binary #(
        .WORD_WIDTH   (MANHATTAN_DEEPEST_WIDTH),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_delay_cnt_init (
        .clock     (clk_i),
        .clear     (delay_cnt_init_clear),
        .up_down   (1'b0), // count up
        .run       (delay_cnt_init_run),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/*ignored*/),
        .carries   (/*ignored*/),
        .overflow  (/*ignored*/),
        .count     (delay_cnt_init_count)
      );

      always_ff @(posedge clk_i) begin
        state_init_q <= state_init_d;
        init_local_q <= init_local_d;
      end

      always_comb begin
        state_init_d         = state_init_q;
        init_local_d         = 1'b0;
        delay_cnt_init_run   = 1'b0;
        delay_cnt_init_clear = 1'b1;

        case (state_init_q)
          INIT_IDLE: begin
            if (init_i) begin
              init_local_d = 1'b1;
              state_init_d = INIT_ACTIVE;
            end
          end

          INIT_ACTIVE: begin
            init_local_d = 1'b1;
            if (!init_i) begin
              delay_cnt_init_run   = 1'b1;
              delay_cnt_init_clear = 1'b0;
              state_init_d         = INIT_DELAY;
            end
          end

          INIT_DELAY: begin
            localparam count_threshold = (MANHATTAN_DEEPEST_WIDTH)'({MANHATTAN_DEEPEST});
            if (init_i) begin
              init_local_d = 1'b1;
              state_init_d = INIT_ACTIVE;
            end else if (delay_cnt_init_count < count_threshold) begin
              init_local_d         = 1'b1;
              delay_cnt_init_run   = 1'b1;
              delay_cnt_init_clear = 1'b0;
            end else begin
              state_init_d = INIT_IDLE;
            end
          end

          default: begin
            state_init_d = INIT_IDLE;
          end
        endcase
      end
    end else begin : gen_init_deepest
      assign init_local_q = init_q;
    end
  endgenerate

  //============================================================================
  // Node Enable Logic
  //============================================================================
  logic enable_q;
  always_ff @(posedge clk_i) begin
    enable_q <= enable_i;
  end
  assign enable_o = enable_q;

  logic enable_local_q;
  generate
    if (DEEPEST_NODE == 0) begin : gen_enable_fsm
      logic enable_local_d;

      typedef enum logic [2:0] {
        ENABLE_IDLE,
        ENABLE_ACTIVE,
        ENABLE_DELAY
      } enable_state_e;

      enable_state_e state_enable_q, state_enable_d;

      logic                               delay_cnt_enable_run;
      logic                               delay_cnt_enable_clear;
      logic [MANHATTAN_DEEPEST_WIDTH-1:0] delay_cnt_enable_count;

      Counter_Binary #(
        .WORD_WIDTH   (MANHATTAN_DEEPEST_WIDTH),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_delay_cnt_enable (
        .clock     (clk_i),
        .clear     (delay_cnt_enable_clear),
        .up_down   (1'b0), // count up
        .run       (delay_cnt_enable_run),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/*ignored*/),
        .carries   (/*ignored*/),
        .overflow  (/*ignored*/),
        .count     (delay_cnt_enable_count)
      );

      always_ff @(posedge clk_i) begin
        state_enable_q <= state_enable_d;
        enable_local_q <= enable_local_d;
      end

      always_comb begin
        state_enable_d         = state_enable_q;
        enable_local_d         = 1'b0;
        delay_cnt_enable_run   = 1'b0;
        delay_cnt_enable_clear = 1'b1;

        case (state_enable_q)
          ENABLE_IDLE: begin
            if (enable_i) begin
              delay_cnt_enable_run   = 1'b1;
              delay_cnt_enable_clear = 1'b0;
              state_enable_d         = ENABLE_DELAY;
            end
          end

          ENABLE_DELAY: begin
            localparam count_threshold = (MANHATTAN_DEEPEST_WIDTH)'({MANHATTAN_DEEPEST});
            if (!enable_i) begin
              state_enable_d = ENABLE_IDLE;
            end else if (delay_cnt_enable_count < count_threshold) begin
              delay_cnt_enable_run   = 1'b1;
              delay_cnt_enable_clear = 1'b0;
            end else begin
              enable_local_d = 1'b1;
              state_enable_d = ENABLE_ACTIVE;
            end
          end

          ENABLE_ACTIVE: begin
            enable_local_d = 1'b1;
            if (!enable_i) begin
              enable_local_d = 1'b0;
              state_enable_d = ENABLE_IDLE;
            end
          end

          default: begin
            state_enable_d = ENABLE_IDLE;
          end
        endcase
      end
    end else begin : gen_enable_deepest
      assign enable_local_q = enable_q;
    end
  endgenerate

  //============================================================================
  // Node Timestep Logic
  //============================================================================
  logic [TIMESTEP_WIDTH-1:0] timestep_q;
  always_ff @(posedge clk_i) begin
    timestep_q <= timestep_i;
  end
  assign timestep_o = timestep_q;

  logic [TIMESTEP_WIDTH-1:0] timestep_local_q;
  generate
    if (DEEPEST_NODE == 0) begin : gen_timestep_fsm
      logic [TIMESTEP_WIDTH-1:0] timestep_local_d;

      typedef enum logic [2:0] {
        TIMESTEP_MATCHES,
        TIMESTEP_DELAY
      } timestep_state_e;

      timestep_state_e state_timestep_q, state_timestep_d;

      logic                               delay_cnt_timestep_run;
      logic                               delay_cnt_timestep_clear;
      logic [MANHATTAN_DEEPEST_WIDTH-1:0] delay_cnt_timestep_count;

      Counter_Binary #(
        .WORD_WIDTH   (MANHATTAN_DEEPEST_WIDTH),
        .INCREMENT    (1),
        .INITIAL_COUNT(0)
      ) u_delay_cnt_timestep (
        .clock     (clk_i),
        .clear     (delay_cnt_timestep_clear),
        .up_down   (1'b0), // count up
        .run       (delay_cnt_timestep_run),
        .load      (1'b0),
        .load_count('0),
        .carry_in  (1'b0),
        .carry_out (/*ignored*/),
        .carries   (/*ignored*/),
        .overflow  (/*ignored*/),
        .count     (delay_cnt_timestep_count)
      );

      always_ff @(posedge clk_i) begin
        state_timestep_q <= state_timestep_d;
        timestep_local_q <= timestep_local_d;
      end

      always_comb begin
        state_timestep_d         = state_timestep_q;
        timestep_local_d         = timestep_local_q;
        delay_cnt_timestep_run   = 1'b0;
        delay_cnt_timestep_clear = 1'b1;

        case (state_timestep_q)
          TIMESTEP_MATCHES: begin
            if (timestep_local_q != timestep_i) begin
              delay_cnt_timestep_run   = 1'b1;
              delay_cnt_timestep_clear = 1'b0;
              state_timestep_d         = TIMESTEP_DELAY;
            end
          end

          TIMESTEP_DELAY: begin
            localparam count_threshold = (MANHATTAN_DEEPEST_WIDTH)'({MANHATTAN_DEEPEST});
            if (timestep_local_q == timestep_i) begin
              state_timestep_d = TIMESTEP_MATCHES;
            end else if (delay_cnt_timestep_count < count_threshold) begin
              delay_cnt_timestep_run   = 1'b1;
              delay_cnt_timestep_clear = 1'b0;
            end else begin
              timestep_local_d = timestep_i;
              state_timestep_d = TIMESTEP_MATCHES;
            end
          end

          default: begin
            timestep_local_d = '0;
            state_timestep_d = TIMESTEP_MATCHES;
          end
        endcase
      end
    end else begin : gen_timestep_deepest
      assign timestep_local_q = timestep_q;
    end
  endgenerate

  //============================================================================
  // Node Done and Idle Logic
  //============================================================================
  logic router_done_d;
  logic core_done_d;
  logic core_idle_d;
  logic node_done_d;
  logic node_idle_d;
  logic node_done_q;
  logic node_idle_q;

  assign node_done_d = core_done_d && router_done_d && (&done_i);
  assign node_idle_d = core_idle_d && router_done_d && (&idle_i);

  always_ff @(posedge clk_i) begin
    if (rst_local_q) begin
      node_done_q <= 1'b0;
      node_idle_q <= 1'b0;
    end else begin
      node_done_q <= node_done_d;
      node_idle_q <= node_idle_d;
    end
  end

  assign done_o = node_done_q;
  assign idle_o = node_idle_q;

  //============================================================================
  // Core and Router Instantiation
  //============================================================================

  logic                          router_to_core_ready;
  logic                          router_to_core_valid;
  logic [CORE_IN_DATA_WIDTH-1:0] router_to_core_data;

  logic                           core_to_router_ready;
  logic                           core_to_router_valid;
  logic [DATA_FABRIC_WIDTH_X-1:0] core_to_router_data;

  Core #(
    .CORE_TYPE(CORE_TYPE),
    .CORE_ID_X(GRID_X_ID),
    .CORE_ID_Y(GRID_Y_ID)
  ) u_core (
    .clk_i      (clk_i),
    .rst_i      (rst_local_q),
    .enable_i   (enable_local_q),
    .timestep_i (timestep_local_q),
    .init_i     (init_local_q),
    .core_done_o(core_done_d),
    .core_idle_o(core_idle_d),
    .packet_in_ready_o(router_to_core_ready),
    .packet_in_valid_i(router_to_core_valid),
    .packet_in_data_i (router_to_core_data),
    .packet_out_ready_i(core_to_router_ready),
    .packet_out_valid_o(core_to_router_valid),
    .packet_out_data_o (core_to_router_data)
  );

  Router #(
    .PACKET_WIDTH(DATA_FABRIC_WIDTH_X),
    .DX_WIDTH    (FIELD_ROUTING_X_WIDTH),
    .DY_WIDTH    (FIELD_ROUTING_Y_WIDTH)
  ) u_router (
    .clk_i (clk_i),
    .rst_i (rst_local_q),
    .done_o(router_done_d),
    .local_input_valid_i(core_to_router_valid),
    .local_input_ready_o(core_to_router_ready),
    .local_input_data_i (core_to_router_data),
    .local_output_valid_o(router_to_core_valid),
    .local_output_ready_i(router_to_core_ready),
    .local_output_data_o (router_to_core_data),
    .west_input_valid_i(west_input_valid_i),
    .west_input_ready_o(west_input_ready_o),
    .west_input_data_i (west_input_data_i),
    .east_input_valid_i(east_input_valid_i),
    .east_input_ready_o(east_input_ready_o),
    .east_input_data_i (east_input_data_i),
    .north_input_valid_i(north_input_valid_i),
    .north_input_ready_o(north_input_ready_o),
    .north_input_data_i (north_input_data_i),
    .south_input_valid_i(south_input_valid_i),
    .south_input_ready_o(south_input_ready_o),
    .south_input_data_i (south_input_data_i),
    .west_output_valid_o(west_output_valid_o),
    .west_output_ready_i(west_output_ready_i),
    .west_output_data_o (west_output_data_o),
    .east_output_valid_o(east_output_valid_o),
    .east_output_ready_i(east_output_ready_i),
    .east_output_data_o (east_output_data_o),
    .north_output_valid_o(north_output_valid_o),
    .north_output_ready_i(north_output_ready_i),
    .north_output_data_o (north_output_data_o),
    .south_output_valid_o(south_output_valid_o),
    .south_output_ready_i(south_output_ready_i),
    .south_output_data_o (south_output_data_o)
  );

endmodule