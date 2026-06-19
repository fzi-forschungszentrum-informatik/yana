`timescale 1ns / 1ps

`include "global_params.vh"


module ValidateParams #();

  // Validation
  initial begin
    if (!PKT_TIMESTEP_SINGLE_VALID_G) begin
      $error("Error: Timestep command packet does not fit into a single flit.");
      $finish;
    end
    if (!(PKT_RQ_SINGLE_VALID_G || PKT_RQ_DOUBLE_VALID_G)) begin
      $error("Error: Reset/Forced Update/Readout Request packet does not fit into single or double flit.");
      $finish;
    end
    if (!(PKT_RO_SINGLE_VALID_G || PKT_RO_DOUBLE_VALID_G)) begin
      $error("Error: Readout packet does not fit into single or double flit.");
      $finish;
    end
    if (INPUT_BUFFER_WIDTH_G < TOP_INPUT_DATA_WIDTH_G) begin
      $error("Error: INPUT_BUFFER_WIDTH_G (%0d) must be >= TOP_INPUT_DATA_WIDTH_G (%0d).", INPUT_BUFFER_WIDTH_G, TOP_INPUT_DATA_WIDTH_G);
      $finish;
    end
  end

  // Printing Info
  initial begin
    // Event Data Packet
    $display("Event Data Packet: Length=%0d bits", $bits(pkt_noc_event_data_s));
    $display($sformatf("  Layout: [%0d-bit synapse_id | %0d-bit neuron_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
      PKT_EVENT_DATA_SYN_ID_WIDTH_G, CORE_NEURON_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
    if (PKT_EVENT_DATA_SYN_ID_WIDTH_G > CORE_WEIGHT_ID_WIDTH_G) begin
      $display($sformatf("    synapse_id: [%0d-bit padding | %0d-bit data]", PKT_EVENT_DATA_SYN_ID_WIDTH_G - CORE_WEIGHT_ID_WIDTH_G, CORE_WEIGHT_ID_WIDTH_G));
    end

    // Timestep Command
    $display("Timestep Command: Always uses single flit.");
    $display("Timestep Command: Length=%0d bits", $bits(pkt_noc_cmd_timestep_s));
    $display($sformatf("  Layout: [%0d-bit timestep | %0d-bit target_cmd | %0d-bit cmd_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
      PKT_TIMESTEP_SINGLE_TS_WIDTH_G, PKT_CMD_ID_WIDTH_G, PKT_CMD_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
    if (PKT_TIMESTEP_SINGLE_TS_WIDTH_G > TIMESTEP_WIDTH_G) begin
      $display($sformatf("    timestep: [%0d-bit padding | %0d-bit data]", PKT_TIMESTEP_SINGLE_TS_WIDTH_G - TIMESTEP_WIDTH_G, TIMESTEP_WIDTH_G));
    end

    // Reset/Forced Update/Readout Request
    if (PKT_RQ_SINGLE_VALID_G) begin
      $display("Reset/Forced Update/Readout Request: Uses SINGLE flit version.");
      $display("Reset/Forced Update/Readout Request: Length=%0d bits", $bits(pkt_noc_rq_s));
      $display($sformatf("  Layout: [%0d-bit end_addr | %0d-bit start_addr | %0d-bit cmd_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RQ_SINGLE_END_ADDR_WIDTH_G, CORE_NEURON_ID_WIDTH_G, PKT_CMD_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RQ_SINGLE_END_ADDR_WIDTH_G > CORE_NEURON_ID_WIDTH_G) begin
        $display($sformatf("    end_addr: [%0d-bit padding | %0d-bit data]", PKT_RQ_SINGLE_END_ADDR_WIDTH_G - CORE_NEURON_ID_WIDTH_G, CORE_NEURON_ID_WIDTH_G));
      end
    end else begin
      $display("Reset/Forced Update/Readout Request: Uses DOUBLE flit version.");
      $display("Reset/Forced Update/Readout Request: Flit 0 Length=%0d bits", $bits(pkt_noc_rq_s));
      $display($sformatf("  Flit 0 Layout: [%0d-bit start_addr | 1-bit flit_id | %0d-bit cmd_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RQ_DOUBLE_START_END_WIDTH_G, PKT_CMD_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RQ_DOUBLE_START_END_WIDTH_G > CORE_NEURON_ID_WIDTH_G) begin
        $display($sformatf("    start_addr: [%0d-bit padding | %0d-bit data]", PKT_RQ_DOUBLE_START_END_WIDTH_G - CORE_NEURON_ID_WIDTH_G, CORE_NEURON_ID_WIDTH_G));
      end

      $display("Reset/Forced Update/Readout Request: Flit 1 Length=%0d bits", $bits(pkt_noc_rq_s));
      $display($sformatf("  Flit 1 Layout: [%0d-bit end_addr | 1-bit flit_id | %0d-bit cmd_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RQ_DOUBLE_START_END_WIDTH_G, PKT_CMD_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RQ_DOUBLE_START_END_WIDTH_G > CORE_NEURON_ID_WIDTH_G) begin
        $display($sformatf("    end_addr: [%0d-bit padding | %0d-bit data]", PKT_RQ_DOUBLE_START_END_WIDTH_G - CORE_NEURON_ID_WIDTH_G, CORE_NEURON_ID_WIDTH_G));
      end
    end

    // Neuron State Readout
    if (PKT_RO_SINGLE_VALID_G) begin
      $display("Neuron State Readout: Uses SINGLE flit version.");
      $display("Neuron State Readout: Length=%0d bits", $bits(pkt_noc_ro_s));
      $display($sformatf("  Layout: [%0d-bit state | %0d-bit neuron_id | %0d-bit source_core_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RO_SINGLE_STATE_WIDTH_G, CORE_NEURON_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RO_SINGLE_STATE_WIDTH_G > NEURON_STATE_WIDTH_G) begin
        $display($sformatf("    state: [%0d-bit padding | %0d-bit data]", PKT_RO_SINGLE_STATE_WIDTH_G - NEURON_STATE_WIDTH_G, NEURON_STATE_WIDTH_G));
      end
    end else begin
      $display("Neuron State Readout: Uses DOUBLE flit version.");
      $display("Neuron State Readout: Flit 0 Length=%0d bits", $bits(pkt_noc_ro_s));
      $display($sformatf("  Flit 0 Layout: [%0d-bit neuron_id | %0d-bit source_core_id | 1-bit flit_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RO_DOUBLE_FLIT0_NEURON_ID_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RO_DOUBLE_FLIT0_NEURON_ID_WIDTH_G > CORE_NEURON_ID_WIDTH_G) begin
        $display($sformatf("    neuron_id: [%0d-bit padding | %0d-bit data]", PKT_RO_DOUBLE_FLIT0_NEURON_ID_WIDTH_G - CORE_NEURON_ID_WIDTH_G, CORE_NEURON_ID_WIDTH_G));
      end

      $display("Neuron State Readout: Flit 1 Length=%0d bits", $bits(pkt_noc_ro_s));
      $display($sformatf("  Flit 1 Layout: [%0d-bit state | %0d-bit source_core_id | 1-bit flit_id | 1-bit ctrl_flag | %0d-bit target_core_id]",
        PKT_RO_DOUBLE_FLIT1_NEURON_STATE_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G, MESH_PACKET_ADDR_WIDTH_G));
      if (PKT_RO_DOUBLE_FLIT1_NEURON_STATE_WIDTH_G > NEURON_STATE_WIDTH_G) begin
        $display($sformatf("    state: [%0d-bit padding | %0d-bit data]", PKT_RO_DOUBLE_FLIT1_NEURON_STATE_WIDTH_G - NEURON_STATE_WIDTH_G, NEURON_STATE_WIDTH_G));
      end
    end
  end

endmodule