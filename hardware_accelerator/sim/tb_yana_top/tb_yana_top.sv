`include "global_params.vh"
`include "control_unit_enums.vh"
`include "assertions.vh"
`include "path_util.vh"

`timescale 1ns / 1ps

module tb_yana_top ();

    localparam int CLOCK_PERIOD  = 10;
    localparam int RESET_CYCLES  = 200;

    // Global simulation watchdog timeout (in ns). Overridable via +timeout_ns=<value>.
    localparam int TIMEOUT_NS = 1_000_000_000;

    localparam FIFO_DEPTH_LOCAL = 32;

    localparam TIMESTEP_WIDTH_LOCAL          = TIMESTEP_WIDTH_G;
    localparam INPUT_SPIKE_EVENT_WIDTH_LOCAL = CORE_NEURON_ID_WIDTH_G + MESH_PACKET_ADDR_WIDTH_G + 1;

    localparam COMMAND_BUFFER_WIDTH_LOCAL     = COMMAND_BUFFER_WIDTH_G;
    localparam INPUT_DATA_BUFFER_WIDTH_LOCAL  = INPUT_BUFFER_WIDTH_G;
    localparam OUTPUT_DATA_BUFFER_WIDTH_LOCAL = OUTPUT_BUFFER_WIDTH_G;

    localparam CONTROL_UNIT_STATUS_REGISTER_WIDTH_LOCAL = CONTROL_UNIT_STATUS_REGISTER_WIDTH_G;
    localparam CONTROL_UNIT_STATE_WIDTH_LOCAL           = CONTROL_UNIT_STATE_WIDTH_G;
    localparam CONTROL_UNIT_STATUS_CODE_WIDTH_LOCAL     = CONTROL_UNIT_STATUS_CODE_WIDTH_G;
    localparam CONTROL_UNIT_STATUS_DATA_WIDTH_LOCAL     = CONTROL_UNIT_STATUS_DATA_WIDTH_G;
    localparam int STATUS_CODE_LSB_LOCAL = CONTROL_UNIT_STATE_WIDTH_LOCAL;
    localparam int STATUS_CODE_MSB_LOCAL =
        CONTROL_UNIT_STATE_WIDTH_LOCAL + CONTROL_UNIT_STATUS_CODE_WIDTH_LOCAL - 1;
    localparam int STATUS_DATA_LSB_LOCAL =
        CONTROL_UNIT_STATE_WIDTH_LOCAL + CONTROL_UNIT_STATUS_CODE_WIDTH_LOCAL;
    localparam INSTRUCTION_WIDTH_LOCAL = INSTRUCTION_WIDTH_G;
    localparam PARAM_WIDTH_LOCAL       = PARAM_WIDTH_G;

    localparam int DATASET_READOUT_START = 0;
    localparam int DATASET_CORE_X        = 1;
    localparam int DATASET_CORE_Y        = 1;

    localparam PKT_CORE_RO_WIDTH_LOCAL         = $bits(pkt_core_ro_s);
    localparam READOUT_FLIT_IDLE_TIMEOUT_LOCAL = 100;

    typedef logic [INPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] input_word_t;

    typedef struct {
        int ts;
        int nid;
        logic [NEURON_STATE_WIDTH_G-1:0] state;
    } trace_entry_t;

    typedef struct {
        string experiment;
        int    samples;
        int    correct;
        int    cycles;
        int    events;
        int    init_cycles;
        int    weights;
    } dataset_summary_t;

    logic uut_clk_i = 1'b0;

    always #(CLOCK_PERIOD / 2) uut_clk_i = ~uut_clk_i;

    logic [COMMAND_BUFFER_WIDTH_LOCAL-1:0] command_fifo_data = '0;
    logic command_fifo_valid = 1'b0;
    logic command_fifo_ready;

    logic [INPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] input_data_fifo_data = '0;
    logic input_data_fifo_valid = 1'b0;
    logic input_data_fifo_ready;

    logic uut_rstn_i = 1'b1;
    logic uut_en_i   = 1'b1;

    logic [COMMAND_BUFFER_WIDTH_LOCAL-1:0] uut_command_data_i;
    logic uut_command_valid_i;
    logic uut_command_ready_o;

    logic [INPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] uut_input_data_i;
    logic uut_input_valid_i;
    logic uut_input_ready_o;

    logic [OUTPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] uut_output_data_o;
    logic uut_output_valid_o;
    logic uut_output_ready_i = 1'b0;

    logic uut_interrupt_o;
    logic uut_interrupt_ack_i = 1'b0;

    logic [CONTROL_UNIT_STATUS_REGISTER_WIDTH_LOCAL-1:0] uut_status_out_o;

    Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(COMMAND_BUFFER_WIDTH_LOCAL),
        .DEPTH     (FIFO_DEPTH_LOCAL),
        .RAMSTYLE  ("mixed")
    ) command_fifo (
        .clock       (uut_clk_i),
        .clear       (1'b0),
        .input_valid (command_fifo_valid),
        .input_ready (command_fifo_ready),
        .input_data  (command_fifo_data),
        .output_valid(uut_command_valid_i),
        .output_ready(uut_command_ready_o),
        .output_data (uut_command_data_i),
        .empty       ()
    );

    localparam int INPUT_DATA_FIFO_DEPTH = 2**16 + 2**12 + 2**10;
    Pipeline_FIFO_Buffer #(
        .WORD_WIDTH(INPUT_DATA_BUFFER_WIDTH_LOCAL),
        .DEPTH     (INPUT_DATA_FIFO_DEPTH),
        .RAMSTYLE  ("mixed")
    ) input_data_fifo (
        .clock       (uut_clk_i),
        .clear       (1'b0),
        .input_valid (input_data_fifo_valid),
        .input_ready (input_data_fifo_ready),
        .input_data  (input_data_fifo_data),
        .output_valid(uut_input_valid_i),
        .output_ready(uut_input_ready_o),
        .output_data (uut_input_data_i),
        .empty       ()
    );

    YanaTop #(
        .COMMAND_BUFFER_WIDTH              (COMMAND_BUFFER_WIDTH_LOCAL),
        .INPUT_DATA_BUFFER_WIDTH           (INPUT_DATA_BUFFER_WIDTH_LOCAL),
        .OUTPUT_DATA_BUFFER_WIDTH          (OUTPUT_DATA_BUFFER_WIDTH_LOCAL),
        .CONTROL_UNIT_STATUS_REGISTER_WIDTH(CONTROL_UNIT_STATUS_REGISTER_WIDTH_LOCAL)
    ) uut (
        .clk_i          (uut_clk_i),
        .rstn_i         (uut_rstn_i),
        .en_i           (uut_en_i),
        .command_data_i (uut_command_data_i),
        .command_valid_i(uut_command_valid_i),
        .command_ready_o(uut_command_ready_o),
        .input_data_i   (uut_input_data_i),
        .input_valid_i  (uut_input_valid_i),
        .input_ready_o  (uut_input_ready_o),
        .output_data_o  (uut_output_data_o),
        .output_valid_o (uut_output_valid_o),
        .output_ready_i (uut_output_ready_i),
        .interrupt_o    (uut_interrupt_o),
        .interrupt_ack_i(uut_interrupt_ack_i),
        .status_out_o   (uut_status_out_o)
    );

    integer test_case = 0;
    int     last_interrupt_status_data = 0;

    logic [NEURON_STATE_WIDTH_G-1:0] neuron_state_cache[];
    logic neuron_state_received[];

    logic [CORE_NEURON_ID_WIDTH_G-1:0] orphan_neuron_id;
    logic orphan_neuron_id_valid;
    logic [NEURON_STATE_WIDTH_G-1:0] orphan_state;
    logic orphan_state_valid;
    integer bumped_beats;

    input_word_t  input_events[$];
    trace_entry_t trace_entries[$];
    dataset_summary_t dataset_summaries[$];

    function automatic int load_init_words_from_file(input string file_path, ref input_word_t words[$]);
        integer fd;
        integer scan_rc;
        string  line;
        input_word_t word;
        begin
            words.delete();
            fd = fopen_or_fatal(file_path);
            while (!$feof(fd)) begin
                scan_rc = $fgets(line, fd);
                if (scan_rc == 0) break;
                scan_rc = $sscanf(line, "%b", word);
                if (scan_rc != 1) break;
                words.push_back(word);
            end
            $fclose(fd);
            return words.size();
        end
    endfunction

    function automatic logic [COMMAND_BUFFER_WIDTH_LOCAL-1:0] pack_command(
        input logic [INSTRUCTION_WIDTH_LOCAL-1:0] instruction,
        input logic [PARAM_WIDTH_LOCAL-1:0]       params
    );
        return {params, Instruction'(instruction)};
    endfunction

    function automatic string files_dir();
        return get_local_subdir(`__FILE__, "files/");
    endfunction

    function automatic integer fopen_or_fatal(input string file_path);
        integer fd;
        begin
            fd = $fopen(file_path, "r");
            if (fd == 0) begin
                $fatal(1, "Could not open file '%s'.", file_path);
            end
            return fd;
        end
    endfunction

    function automatic string dataset_path(input string dir_name);
        return {files_dir(), dir_name, "/"};
    endfunction

    function automatic string dataset_init_core_path(
        input string  dir_name,
        input integer core_idx,
        input string  prefix
    );
        string core_s;
        begin
            core_s.itoa(core_idx);
            return {dataset_path(dir_name), "init/", prefix, "_core_", core_s, ".txt"};
        end
    endfunction

    function automatic string dataset_sample_path(input string dir_name, input string filename);
        return {dataset_path(dir_name), "dataset/", filename};
    endfunction

    function automatic int split_csv(input string csv, output string items[$]);
        int    i;
        int    start;
        byte   ch;
        string token;
        begin
            items.delete();
            if (csv.len() == 0) return 0;

            start = 0;
            for (i = 0; i <= csv.len(); i++) begin
                ch = (i == csv.len()) ? "," : csv[i];
                if (ch == ",") begin
                    token = csv.substr(start, i - 1);
                    if (token.len() > 0) items.push_back(token);
                    start = i + 1;
                end
            end
            return items.size();
        end
    endfunction

    function automatic string accuracy_string(input int correct, input int samples);
        real accuracy;
        begin
            if (samples == 0) return "N/A";
            accuracy = (100.0 * real'(correct)) / real'(samples);
            return $sformatf("%.1f%%", accuracy);
        end
    endfunction

    task automatic print_dataset_summary_table();
        string accuracy;
        real   avg_cycles;
        real   avg_latency_ms;
        begin
            if (dataset_summaries.size() == 0) begin
                $display("\nNo dataset summaries collected.");
                return;
            end

            $display("\nDataset processing summary:");
            $display("+--------------------+-----------+------------+----------+-------------+--------------+----------+--------------+-----------+");
            $display("|   Experiment       |   Samples |   Accuracy |   Cycles |   AvgCycles |   AvgLat(ms) |   Events |   InitCycles |   Weights |");
            $display("+====================+===========+============+==========+=============+==============+==========+==============+===========+");
            foreach (dataset_summaries[i]) begin
                accuracy = accuracy_string(dataset_summaries[i].correct, dataset_summaries[i].samples);
                if (dataset_summaries[i].samples > 0) begin
                    avg_cycles = real'(dataset_summaries[i].cycles) / real'(dataset_summaries[i].samples);
                end else begin
                    avg_cycles = 0.0;
                end
                // CLOCK_PERIOD is in ns (timescale 1ns); convert avg cycle time to ms (1 ns = 1e-6 ms).
                avg_latency_ms = avg_cycles * real'(CLOCK_PERIOD) * 1.0e-6;
                $display("| %-18s | %9d | %-10s | %8d | %11.1f | %12.4f | %8d | %12d | %9d |",
                         dataset_summaries[i].experiment,
                         dataset_summaries[i].samples,
                         accuracy,
                         dataset_summaries[i].cycles,
                         avg_cycles,
                         avg_latency_ms,
                         dataset_summaries[i].events,
                         dataset_summaries[i].init_cycles,
                         dataset_summaries[i].weights);
                $display("+--------------------+-----------+------------+----------+-------------+--------------+----------+--------------+-----------+");
            end
        end
    endtask

    task automatic run_from_plusargs();
        string datasets_csv;
        string dataset_names[$];
        int    num_samples;
        int    i;
        begin
            dataset_summaries.delete();
            num_samples = 3;
            void'($value$plusargs("num_samples=%d", num_samples));

            if ($value$plusargs("datasets=%s", datasets_csv)) begin
                void'(split_csv(datasets_csv, dataset_names));
            end else if ($value$plusargs("dataset=%s", datasets_csv)) begin
                dataset_names.delete();
                dataset_names.push_back(datasets_csv);
            end else begin
                dataset_names.delete();
                dataset_names.push_back("shd_0");
                $display("No +datasets= or +dataset= plusarg; defaulting to shd_0");
            end

            if (dataset_names.size() == 0) begin
                $fatal(1, "No dataset names parsed from plusargs.");
            end

            foreach (dataset_names[i]) begin
                $display("Running dataset %0d/%0d: %s (up to %0d samples)",
                         i + 1, dataset_names.size(), dataset_names[i], num_samples);
                test_process_dataset(dataset_names[i], num_samples);
            end

            print_dataset_summary_table();
        end
    endtask

    function automatic int count_file_lines(input string file_path);
        integer fd;
        integer c;
        int     line_count;
        bit     line_has_content;
        begin
            fd = $fopen(file_path, "r");
            if (fd == 0) begin
                $fatal(1, "Could not open file '%s'.", file_path);
            end
            line_count       = 0;
            line_has_content = 1'b0;
            forever begin
                c = $fgetc(fd);
                if (c == -1) begin
                    if (line_has_content) line_count++;
                    break;
                end
                if (c == "\n") begin
                    if (line_has_content) line_count++;
                    line_has_content = 1'b0;
                end else if (c != "\r") begin
                    line_has_content = 1'b1;
                end
            end
            $fclose(fd);
            return line_count;
        end
    endfunction

    function automatic void check_input_data_fifo_capacity(
        input string file_kind,
        input string file_path,
        input int    word_count
    );
        if (word_count > INPUT_DATA_FIFO_DEPTH) begin
            $fatal(1,
                   "%s file '%s' has %0d words, but input data FIFO depth is only %0d.",
                   file_kind, file_path, word_count, INPUT_DATA_FIFO_DEPTH);
        end
    endfunction

    function automatic int load_input_trace_file(input string file_path);
        integer fd;
        integer scan_rc;
        integer ts;
        string  line;
        logic [TIMESTEP_WIDTH_LOCAL-1:0]          timestep;
        logic [INPUT_SPIKE_EVENT_WIDTH_LOCAL-1:0] input_data;
        begin
            input_events.delete();
            fd = fopen_or_fatal(file_path);
            while (!$feof(fd)) begin
                scan_rc = $fgets(line, fd);
                if (scan_rc == 0) break;
                scan_rc = $sscanf(line, "%d %b", ts, input_data);
                if (scan_rc != 2) break;
                timestep = TIMESTEP_WIDTH_LOCAL'(ts);
                input_events.push_back({timestep, input_data});
            end
            $fclose(fd);
            return input_events.size();
        end
    endfunction

    function automatic int load_golden_trace_file(
        input  string file_path,
        output int    max_ts,
        output int    num_neurons
    );
        integer fd;
        integer scan_rc;
        integer ts;
        integer nid;
        integer max_nid;
        string  line;
        logic [NEURON_STATE_WIDTH_G-1:0] state;
        begin
            trace_entries.delete();
            fd          = fopen_or_fatal(file_path);
            max_ts      = 0;
            max_nid     = -1;
            num_neurons = 0;
            while (!$feof(fd)) begin
                scan_rc = $fgets(line, fd);
                if (scan_rc == 0) break;
                scan_rc = $sscanf(line, "%d %d %b", ts, nid, state);
                if (scan_rc != 3) break;
                trace_entries.push_back('{ts: ts, nid: nid, state: state});
                if (ts > max_ts) max_ts = ts;
                if (nid > max_nid) max_nid = nid;
            end
            $fclose(fd);
            num_neurons = max_nid + 1;
            return trace_entries.size();
        end
    endfunction

    function automatic logic [PARAM_WIDTH_LOCAL-1:0] pack_read_state_cmd(
        input logic                              force_update,
        input logic [TIMESTEP_WIDTH_LOCAL-1:0]   timestep,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] start_addr,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] end_addr,
        input logic [CORE_ID_X_WIDTH_G-1:0]      core_x,
        input logic [CORE_ID_Y_WIDTH_G-1:0]      core_y
    );
        cu_payload_read_state_s payload;
        begin
            payload               = '0;
            payload.force_update  = force_update;
            payload.timestep      = timestep;
            payload.start_addr    = start_addr;
            payload.end_addr      = end_addr;
            payload.target_core_x = core_x;
            payload.target_core_y = core_y;
            return PARAM_WIDTH_LOCAL'(payload);
        end
    endfunction

    function automatic logic [PARAM_WIDTH_LOCAL-1:0] pack_reset_cmd(
        input ResetType                          rst_type,
        input logic [TIMESTEP_WIDTH_LOCAL-1:0]   timestep,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] start_addr,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] end_addr,
        input logic [CORE_ID_X_WIDTH_G-1:0]      core_x,
        input logic [CORE_ID_Y_WIDTH_G-1:0]      core_y
    );
        cu_payload_reset_s payload;
        begin
            payload               = '0;
            payload.rst_type      = rst_type;
            payload.timestep      = timestep;
            payload.start_addr    = start_addr;
            payload.end_addr      = end_addr;
            payload.target_core_x = core_x;
            payload.target_core_y = core_y;
            return PARAM_WIDTH_LOCAL'(payload);
        end
    endfunction

    function automatic StatusCode get_status_code();
        return StatusCode'(uut_status_out_o[STATUS_CODE_MSB_LOCAL:STATUS_CODE_LSB_LOCAL]);
    endfunction

    function automatic logic [CONTROL_UNIT_STATUS_DATA_WIDTH_LOCAL-1:0] get_status_data();
        return uut_status_out_o[CONTROL_UNIT_STATUS_REGISTER_WIDTH_LOCAL-1:STATUS_DATA_LSB_LOCAL];
    endfunction

    function automatic string status_code_name(input StatusCode code);
        case (code)
            STATUS_NO_ERROR:           return "STATUS_NO_ERROR";
            STATUS_INVALID_INSTR_ERROR: return "STATUS_INVALID_INSTR_ERROR";
            STATUS_PARAM_ERROR:        return "STATUS_PARAM_ERROR";
            STATUS_INIT_MEM_OVERFLOW:  return "STATUS_INIT_MEM_OVERFLOW";
            default:                   return "UNKNOWN";
        endcase
    endfunction

    function automatic pkt_core_ro_s readout_beat_from_host_output(
        input logic [OUTPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] host_word
    );
        return pkt_core_ro_s'(host_word[PKT_CORE_RO_WIDTH_LOCAL-1:0]);
    endfunction

    function automatic logic readout_beat_is_ctrl_packet(input pkt_core_ro_s beat);
        return beat.ctrl_flag == 1'b1;
    endfunction

    function automatic logic readout_beat_is_neuron_id_flit(input pkt_core_ro_s beat);
        if (PKT_RO_FLIT_COUNT_G == 1) begin
            return 1'b1;
        end
        return beat.payload.double_flit0.flit_id == 1'b0;
    endfunction

    function automatic logic [CORE_NEURON_ID_WIDTH_G-1:0] readout_beat_neuron_id(input pkt_core_ro_s beat);
        if (PKT_RO_FLIT_COUNT_G == 1) begin
            return beat.payload.single.neuron_id[CORE_NEURON_ID_WIDTH_G-1:0];
        end
        return beat.payload.double_flit0.neuron_id[CORE_NEURON_ID_WIDTH_G-1:0];
    endfunction

    function automatic logic [NEURON_STATE_WIDTH_G-1:0] readout_beat_state(input pkt_core_ro_s beat);
        if (PKT_RO_FLIT_COUNT_G == 1) begin
            return beat.payload.single.state[NEURON_STATE_WIDTH_G-1:0];
        end
        return beat.payload.double_flit1.state[NEURON_STATE_WIDTH_G-1:0];
    endfunction

    task automatic wait_n(input integer n);
        repeat (n) @(posedge uut_clk_i);
    endtask

    task automatic reset_uut();
        $display("\nResetting UUT for %0d cycles", RESET_CYCLES);
        @(posedge uut_clk_i);
        uut_rstn_i          = 1'b0;
        uut_output_ready_i  = 1'b0;
        uut_interrupt_ack_i = 1'b0;
        repeat (RESET_CYCLES) @(posedge uut_clk_i);
        uut_rstn_i = 1'b1;
        @(posedge uut_clk_i);
    endtask

    task automatic push_input_data_word(input logic [INPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] data);
        input_data_fifo_data  <= data;
        input_data_fifo_valid <= 1'b1;
        @(posedge uut_clk_i);
        while (!input_data_fifo_ready) @(posedge uut_clk_i);
        input_data_fifo_valid <= 1'b0;
        @(posedge uut_clk_i);
    endtask

    task automatic push_command_word(input logic [COMMAND_BUFFER_WIDTH_LOCAL-1:0] data);
        command_fifo_data  <= data;
        command_fifo_valid <= 1'b1;
        @(posedge uut_clk_i);
        while (!command_fifo_ready) @(posedge uut_clk_i);
        command_fifo_valid <= 1'b0;
        @(posedge uut_clk_i);
    endtask

    task automatic write_command_fifo(
        input logic [INSTRUCTION_WIDTH_LOCAL-1:0] instruction,
        input logic [PARAM_WIDTH_LOCAL-1:0]       params
    );
        push_command_word(pack_command(instruction, params));
    endtask

    task automatic write_input_data_fifo(input logic [INPUT_DATA_BUFFER_WIDTH_LOCAL-1:0] data);
        push_input_data_word(data);
    endtask

    task automatic check_status_no_error(input string phase_name);
        StatusCode code;
        code = get_status_code();
        if (code != STATUS_NO_ERROR) begin
            $display("ERROR: control unit reported %s (%0d) during %s",
                     status_code_name(code), code, phase_name);
            $finish;
        end
    endtask

    task automatic clear_interrupt();
        wait_n(1);
        uut_interrupt_ack_i <= 1'b1;
        wait_n(1);
        uut_interrupt_ack_i <= 1'b0;
        wait_n(1);
    endtask

    task automatic process_interrupt(input string phase_name, input bit print_sample_latency = 1'b0);
        wait_n(1);
        check_status_no_error(phase_name);
        last_interrupt_status_data = int'(get_status_data());
        if (print_sample_latency) begin
            $display("  Sample processing latency: %0d cycles", last_interrupt_status_data);
        end
        clear_interrupt();
    endtask

    task automatic resize_readout_cache(input int num_neurons);
        if (num_neurons <= 0) begin
            $fatal(1, "Golden trace did not contain any output neurons.");
        end
        if (num_neurons > NEURONS_PER_CORE_G) begin
            $fatal(1, "Golden trace has %0d output neurons, but the output core only has %0d.",
                   num_neurons, NEURONS_PER_CORE_G);
        end
        neuron_state_cache    = new[num_neurons];
        neuron_state_received = new[num_neurons];
    endtask

    task automatic clear_readout_assembly();
        integer neuron_idx;
        for (neuron_idx = 0; neuron_idx < neuron_state_cache.size(); neuron_idx++) begin
            neuron_state_cache[neuron_idx]    = '0;
            neuron_state_received[neuron_idx] = 1'b0;
        end
        orphan_neuron_id       = '0;
        orphan_neuron_id_valid = 1'b0;
        orphan_state           = '0;
        orphan_state_valid     = 1'b0;
        bumped_beats           = 0;
    endtask

    task automatic commit_readout_entry(
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] neuron_id,
        input logic [NEURON_STATE_WIDTH_G-1:0]   state
    );
        if (int'(neuron_id) >= neuron_state_cache.size()) begin
            $display("  WARNING: readout neuron_id %0d out of cache range [0, %0d)",
                     neuron_id, neuron_state_cache.size());
            return;
        end
        neuron_state_cache[neuron_id]    = state;
        neuron_state_received[neuron_id] = 1'b1;
    endtask

    task automatic absorb_readout_flit(input pkt_core_ro_s beat);
        logic [CORE_NEURON_ID_WIDTH_G-1:0] neuron_id;
        logic [NEURON_STATE_WIDTH_G-1:0]   state;
        if (PKT_RO_FLIT_COUNT_G == 1) begin
            neuron_id = readout_beat_neuron_id(beat);
            state     = readout_beat_state(beat);
            commit_readout_entry(neuron_id, state);
        end else if (readout_beat_is_neuron_id_flit(beat)) begin
            neuron_id = readout_beat_neuron_id(beat);
            if (orphan_state_valid) begin
                commit_readout_entry(neuron_id, orphan_state);
                orphan_state_valid = 1'b0;
            end else begin
                orphan_neuron_id       = neuron_id;
                orphan_neuron_id_valid = 1'b1;
            end
        end else begin
            state = readout_beat_state(beat);
            if (orphan_neuron_id_valid) begin
                commit_readout_entry(orphan_neuron_id, state);
                orphan_neuron_id_valid = 1'b0;
            end else begin
                orphan_state       = state;
                orphan_state_valid = 1'b1;
            end
        end
    endtask

    task automatic write_init_file(
        input  string file_path,
        output int    loaded_count_out,
        output int    init_cycles_out
    );
        input_word_t init_words[$];
        int expected_count;
        int loaded_count;
        int idx;

        $display("Processing initialization file: %s", file_path);

        expected_count = count_file_lines(file_path);
        loaded_count   = load_init_words_from_file(file_path, init_words);
        if (loaded_count != expected_count) begin
            $fatal(1, "Init file '%s': counted %0d lines but loaded %0d words",
                   file_path, expected_count, loaded_count);
        end
        check_input_data_fifo_capacity("Init", file_path, loaded_count);

        foreach (init_words[idx])
            push_input_data_word(init_words[idx]);

        write_command_fifo(INSTR_SET_INIT, '0);

        @(posedge uut_interrupt_o);
        process_interrupt("init file load");
        init_cycles_out = last_interrupt_status_data;
        loaded_count_out = loaded_count;

        $display("  Completed: %0d total entries processed", loaded_count);
    endtask

    task automatic try_write_init_file(
        input  string file_path,
        output int    loaded_count,
        output int    init_cycles
    );
        integer in_file;
        loaded_count = 0;
        init_cycles  = 0;
        in_file = $fopen(file_path, "r");
        if (in_file == 0) begin
            $display("INFO: File not found, skipping: %s", file_path);
            return;
        end
        $fclose(in_file);
        write_init_file(file_path, loaded_count, init_cycles);
    endtask

    task automatic load_sample_metadata(
        input  string dir_name,
        input  int    sample_idx,
        output int    target_out,
        output string input_file_out,
        output string output_file_out,
        output bit    found
    );
        integer fd;
        integer scan_rc;
        integer parsed_idx;
        string  line;
        string  yaml_path;
        bit     in_target_block;
        begin
            target_out      = -1;
            input_file_out  = "";
            output_file_out = "";
            found           = 1'b0;
            in_target_block = 1'b0;
            yaml_path       = dataset_sample_path(dir_name, "sample_info.yaml");

            fd = $fopen(yaml_path, "r");
            if (fd == 0) begin
                $display("INFO: sample_info.yaml not found: %s", yaml_path);
                return;
            end

            while (!$feof(fd)) begin
                scan_rc = $fgets(line, fd);
                if (scan_rc == 0) break;

                if (!in_target_block) begin
                    scan_rc = $sscanf(line, "%d:", parsed_idx);
                    if (scan_rc == 1 && parsed_idx == sample_idx) begin
                        in_target_block = 1'b1;
                    end
                end else begin
                    scan_rc = $sscanf(line, "%d:", parsed_idx);
                    if (scan_rc == 1 && parsed_idx != sample_idx) begin
                        if (target_out >= 0 && input_file_out != "" && output_file_out != "") begin
                            found = 1'b1;
                        end
                        break;
                    end

                    if ($sscanf(line, "  target: %d", target_out) == 1) continue;
                    if ($sscanf(line, "  input_file: %s", input_file_out) == 1) continue;
                    if ($sscanf(line, "  output_file: %s", output_file_out) == 1) begin
                        if (target_out >= 0 && input_file_out != "" && output_file_out != "") begin
                            found = 1'b1;
                        end
                        continue;
                    end
                end
            end

            if (!found && in_target_block &&
                target_out >= 0 && input_file_out != "" && output_file_out != "") begin
                found = 1'b1;
            end

            $fclose(fd);
        end
    endtask

    task automatic write_input_trace_file(
        input  string file_path,
        output int    event_count_out
    );
        int event_count;
        int idx;

        $display("\nProcessing input trace file: %s", file_path);

        event_count = load_input_trace_file(file_path);
        check_input_data_fifo_capacity("Input trace", file_path, event_count);
        foreach (input_events[idx])
            push_input_data_word(input_events[idx]);

        $display("  Completed: %0d input events written", event_count);
        event_count_out = event_count;
    endtask

    task automatic init_dataset_rams(
        input  string dir_name,
        output int    init_cycles,
        output int    weight_count
    );
        integer core_idx;
        int     loaded_count;
        int     file_init_cycles;
        begin
            init_cycles  = 0;
            weight_count = 0;
            reset_uut();
            $display("\n\n--- Dataset %s, initializing RAMs ---\n", dir_name);

            for (core_idx = 0; core_idx < NUM_CORES_G; core_idx++) begin
                $display("\n=== Initializing core %0d ===", core_idx);
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "mem_mapping"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "mem_routing"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "mem_weights"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                weight_count += loaded_count;
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "tau_mem_inv"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "threshold"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                try_write_init_file(dataset_init_core_path(dir_name, core_idx, "leak_ram"), loaded_count, file_init_cycles);
                init_cycles += file_init_cycles;
                $display("Core %0d initialization completed\n", core_idx);
            end

            $display("All cores initialization completed for dataset %s (%0d init cycles, %0d weights)",
                     dir_name, init_cycles, weight_count);
            @(posedge uut_clk_i);
        end
    endtask

    task automatic read_neuron_states_via_cu(
        input logic [TIMESTEP_WIDTH_LOCAL-1:0]   timestep,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] start_addr,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] end_addr,
        input logic [CORE_ID_X_WIDTH_G-1:0]      core_x,
        input logic [CORE_ID_Y_WIDTH_G-1:0]      core_y,
        input integer                            num_neurons
    );
        integer flit_count;
        integer idle_cycles;
        integer expected_flits;
        integer expected_neurons;
        pkt_core_ro_s output_beat;

        $display("\nReading neuron states via INSTR_READ_STATE (t=%0d, core %0d:%0d, start_addr=%0d, end_addr=%0d)",
                 timestep, core_x, core_y, start_addr, end_addr);

        if (OUTPUT_DATA_BUFFER_WIDTH_LOCAL < PKT_CORE_RO_WIDTH_LOCAL) begin
            $display("ERROR: OUTPUT_DATA_BUFFER_WIDTH (%0d) < pkt_core_ro_s width (%0d)",
                     OUTPUT_DATA_BUFFER_WIDTH_LOCAL, PKT_CORE_RO_WIDTH_LOCAL);
            $finish;
        end

        expected_neurons = (start_addr <= end_addr) ? (int'(end_addr) - int'(start_addr) + 1) : 0;
        if (expected_neurons != num_neurons) begin
            $fatal(1, "Readout range covers %0d neurons, but golden trace contains %0d output neurons.",
                   expected_neurons, num_neurons);
        end
        expected_flits   = expected_neurons * PKT_RO_FLIT_COUNT_G;
        flit_count     = 0;
        idle_cycles    = 0;

        resize_readout_cache(num_neurons);
        clear_readout_assembly();
        clear_interrupt();

        uut_output_ready_i <= 1'b1;

        write_command_fifo(
            INSTR_READ_STATE,
            pack_read_state_cmd(1'b0, timestep, start_addr, end_addr, core_x, core_y)
        );

        while (flit_count < expected_flits) begin
            @(posedge uut_clk_i);
            if (uut_output_valid_o) begin
                idle_cycles = 0;
                output_beat = readout_beat_from_host_output(uut_output_data_o);
                if (!readout_beat_is_ctrl_packet(output_beat)) begin
                    bumped_beats++;
                end else begin
                    absorb_readout_flit(output_beat);
                    flit_count++;
                end
            end else begin
                idle_cycles++;
                if (idle_cycles >= READOUT_FLIT_IDLE_TIMEOUT_LOCAL) begin
                    $display("ERROR: readout stalled: received %0d/%0d readout flits (%0d bumped) after %0d idle cycles",
                             flit_count, expected_flits, bumped_beats, idle_cycles);
                    uut_output_ready_i <= 1'b0;
                    $finish;
                end
            end
        end

        uut_output_ready_i <= 1'b0;
        wait_n(1);

        if (!uut_interrupt_o) @(posedge uut_interrupt_o);
        process_interrupt("readout");

        if (orphan_neuron_id_valid || orphan_state_valid) begin
            $display("  WARNING: readout ended with unpaired flit (orphan id=%0b, orphan state=%0b)",
                     orphan_neuron_id_valid, orphan_state_valid);
        end

        $display("  Readout drain complete: %0d/%0d readout flits, %0d non-ctrl beats bumped",
                 flit_count, expected_flits, bumped_beats);
    endtask

    task automatic compare_cached_states_from_mem(
        input string  trace_path,
        input integer expected_timestep,
        input integer num_neurons
    );
        int idx;
        int ts;
        int nid;
        int mismatch_count;
        int match_count;
        int missing_count;
        int neuron_idx;
        logic [NEURON_STATE_WIDTH_G-1:0] expected_value;
        logic [NEURON_STATE_WIDTH_G-1:0] actual_value;

        $display("\nComparing cached neuron states to golden file: %s (timestep %0d)",
                 trace_path, expected_timestep);

        mismatch_count = 0;
        match_count    = 0;
        missing_count  = 0;

        foreach (trace_entries[idx]) begin
            ts  = trace_entries[idx].ts;
            nid = trace_entries[idx].nid;

            if (ts < expected_timestep) continue;
            if (ts > expected_timestep) break;

            expected_value = trace_entries[idx].state;

            if (nid < 0 || nid >= num_neurons) begin
                $display("  WARNING: neuron_id %0d out of range [0, %0d)", nid, num_neurons);
                continue;
            end

            if (!neuron_state_received[nid]) begin
                $display("  MISSING readout for neuron %0d at timestep %0d", nid, ts);
                continue;
            end

            actual_value = neuron_state_cache[nid];
            `assert_eq_fp(actual_value, NEURON_STATE_WIDTH_FRACTIONALS_G, expected_value);

            if (actual_value !== expected_value) begin
                $display("  MISMATCH at timestep %0d, neuron %0d: expected %b, actual %b",
                         ts, nid, expected_value, actual_value);
                mismatch_count++;
            end else begin
                match_count++;
            end
        end

        for (neuron_idx = 0; neuron_idx < num_neurons; neuron_idx++) begin
            if (!neuron_state_received[neuron_idx]) missing_count++;
        end

        if (missing_count != 0) begin
            $display("  FAILURE: %0d neurons never received in readout", missing_count);
        end

        if (mismatch_count == 0 && missing_count == 0 && match_count == num_neurons) begin
            $display("  SUCCESS: All %0d neuron states match at timestep %0d", match_count, expected_timestep);
        end else begin
            $display("  FAILURE: %0d mismatches, %0d missing, %0d matches (expected %0d neurons)",
                     mismatch_count, missing_count, match_count, num_neurons);
        end
    endtask

    task automatic print_classification(
        input int sample_idx,
        input int expected_target,
        input int num_neurons,
        output bit correct
    );
        integer neuron_idx;
        integer predicted;
        logic signed [NEURON_STATE_WIDTH_G-1:0] best_state;
        logic signed [NEURON_STATE_WIDTH_G-1:0] cur_state;
        begin
            predicted  = 0;
            best_state = $signed(neuron_state_cache[0]);
            for (neuron_idx = 1; neuron_idx < num_neurons; neuron_idx++) begin
                cur_state = $signed(neuron_state_cache[neuron_idx]);
                if (cur_state > best_state) begin
                    best_state = cur_state;
                    predicted  = neuron_idx;
                end
            end

            $display("  Classification sample %0d: target=%0d, predicted=%0d (%s)",
                     sample_idx, expected_target, predicted,
                     (predicted == expected_target) ? "MATCH" : "MISMATCH");
            correct = (predicted == expected_target);
        end
    endtask

    task automatic issue_cu_reset(
        input ResetType                          rst_type,
        input string                             phase_name,
        input logic [TIMESTEP_WIDTH_LOCAL-1:0]   timestep,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] start_addr,
        input logic [CORE_NEURON_ID_WIDTH_G-1:0] end_addr,
        input logic [CORE_ID_X_WIDTH_G-1:0]      core_x,
        input logic [CORE_ID_Y_WIDTH_G-1:0]      core_y
    );
        $display("\nIssuing INSTR_RESET: %s", phase_name);
        write_command_fifo(
            INSTR_RESET,
            pack_reset_cmd(rst_type, timestep, start_addr, end_addr, core_x, core_y)
        );
        @(posedge uut_interrupt_o);
        process_interrupt(phase_name);
    endtask

    task automatic run_sample_and_compare_paths(
        input  string input_path,
        input  int    max_timestep,
        input  int    num_neurons,
        output int    event_count,
        output int    sample_cycles
    );
        write_input_trace_file(input_path, event_count);

        write_command_fifo(INSTR_SET_RUN_MODE, RUN_MODE_SAMPLE);
        clear_interrupt();

        write_command_fifo(INSTR_START, TIMESTEP_WIDTH_LOCAL'(max_timestep));

        @(posedge uut_interrupt_o);
        process_interrupt("sample run", 1'b1);
        sample_cycles = last_interrupt_status_data;

        read_neuron_states_via_cu(
            TIMESTEP_WIDTH_LOCAL'(max_timestep),
            CORE_NEURON_ID_WIDTH_G'(DATASET_READOUT_START),
            CORE_NEURON_ID_WIDTH_G'(DATASET_READOUT_START + num_neurons - 1),
            CORE_ID_X_WIDTH_G'(DATASET_CORE_X),
            CORE_ID_Y_WIDTH_G'(DATASET_CORE_Y),
            num_neurons
        );
    endtask

    task automatic reset_between_samples(input int max_timestep);
        issue_cu_reset(
            RESET_STATES,
            "neuron state reset (core 1:0)",
            TIMESTEP_WIDTH_LOCAL'(max_timestep),
            CORE_NEURON_ID_WIDTH_G'(0),
            CORE_NEURON_ID_WIDTH_G'(NEURONS_PER_CORE_G - 1),
            CORE_ID_X_WIDTH_G'(1),
            CORE_ID_Y_WIDTH_G'(0)
        );
        issue_cu_reset(
            RESET_STATES,
            "neuron state reset (core 1:1)",
            TIMESTEP_WIDTH_LOCAL'(max_timestep),
            CORE_NEURON_ID_WIDTH_G'(0),
            CORE_NEURON_ID_WIDTH_G'(NEURONS_PER_CORE_G - 1),
            CORE_ID_X_WIDTH_G'(1),
            CORE_ID_Y_WIDTH_G'(1)
        );
        issue_cu_reset(
            RESET_STATES,
            "neuron state reset (core 0:1)",
            TIMESTEP_WIDTH_LOCAL'(max_timestep),
            CORE_NEURON_ID_WIDTH_G'(0),
            CORE_NEURON_ID_WIDTH_G'(NEURONS_PER_CORE_G - 1),
            CORE_ID_X_WIDTH_G'(0),
            CORE_ID_Y_WIDTH_G'(1)
        );
        reset_uut();
    endtask

    task automatic test_process_dataset(input string dir_name, input int num_samples);
        int    sample_idx;
        int    max_timestep;
        int    trace_entry_count;
        int    output_neurons;
        int    expected_target;
        int    init_cycles;
        int    weight_count;
        int    sample_events;
        int    sample_cycles;
        int    processed_samples;
        int    correct_samples;
        int    total_events;
        int    total_cycles;
        string input_file;
        string output_file;
        string input_path;
        string trace_path;
        bit    metadata_found;
        bit    classification_correct;
        integer input_fd;
        integer trace_fd;
        dataset_summary_t summary;
        begin
            processed_samples = 0;
            correct_samples   = 0;
            total_events      = 0;
            total_cycles      = 0;

            init_dataset_rams(dir_name, init_cycles, weight_count);

            for (sample_idx = 0; sample_idx < num_samples; sample_idx++) begin
                test_case <= sample_idx;
                input_events.delete();
                trace_entries.delete();
                load_sample_metadata(
                    dir_name, sample_idx,
                    expected_target, input_file, output_file, metadata_found
                );
                if (!metadata_found) begin
                    $display("INFO: no metadata for sample %0d, stopping after %0d samples",
                             sample_idx, sample_idx);
                    break;
                end

                input_path = dataset_sample_path(dir_name, input_file);
                trace_path = dataset_sample_path(dir_name, output_file);
                input_fd   = $fopen(input_path, "r");
                trace_fd   = $fopen(trace_path, "r");
                if (input_fd == 0 || trace_fd == 0) begin
                    if (input_fd != 0) $fclose(input_fd);
                    if (trace_fd != 0) $fclose(trace_fd);
                    $display("INFO: sample %0d files missing, stopping after %0d samples",
                             sample_idx, sample_idx);
                    break;
                end
                $fclose(input_fd);
                $fclose(trace_fd);

                $display("\n\n--- Dataset %s, sample %0d (target=%0d) ---\n",
                         dir_name, sample_idx, expected_target);

                trace_entry_count = load_golden_trace_file(trace_path, max_timestep, output_neurons);
                $display("  Max timestep from trace: %0d (%0d entries, %0d output neurons)",
                         max_timestep, trace_entry_count, output_neurons);

                run_sample_and_compare_paths(input_path, max_timestep, output_neurons,
                                             sample_events, sample_cycles);
                compare_cached_states_from_mem(trace_path, max_timestep, output_neurons);
                print_classification(sample_idx, expected_target, output_neurons, classification_correct);
                processed_samples++;
                total_events += sample_events;
                total_cycles += sample_cycles;
                if (classification_correct) correct_samples++;
                reset_between_samples(max_timestep);
            end

            $display("\nDataset %s processing completed", dir_name);
            summary.experiment  = dir_name;
            summary.samples     = processed_samples;
            summary.correct     = correct_samples;
            summary.cycles      = total_cycles;
            summary.events      = total_events;
            summary.init_cycles = init_cycles;
            summary.weights     = weight_count;
            dataset_summaries.push_back(summary);
        end
    endtask

    initial begin
        if ($test$plusargs("trace")) begin
            $display("Tracing enabled: writing waveform.fst");
            $dumpfile("waveform.fst");
            $dumpvars(0, tb_yana_top);
        end
    end

    initial begin
        static int timeout_ns = TIMEOUT_NS;
        void'($value$plusargs("timeout_ns=%d", timeout_ns));
        repeat (timeout_ns) #1;
        $display("\nERROR: simulation watchdog timeout reached after %0d ns", timeout_ns);
        $finish;
    end

    initial begin
        #(CLOCK_PERIOD);
        $display("Testbench started");

        run_from_plusargs();

        #(CLOCK_PERIOD);
        $display("\nTestbench completed");
        $finish;
    end

endmodule
