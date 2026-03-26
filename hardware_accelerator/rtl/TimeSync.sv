module TimeSync #(
    TIMESTEP_WIDTH = 28
)(
    input clk_i,
    input rstn_i,

    input acc_idle_i,
    input [TIMESTEP_WIDTH-1:0] ts_data_in_i,
    input ts_data_empty_i,

    output logic [TIMESTEP_WIDTH-1:0] current_ts_o,
    output ts_synced_o
);

logic prev_acc_idle;
assign ts_synced_o = (ts_data_in_i == current_ts_o);

always @(posedge clk_i) begin
    if (!rstn_i) begin
        current_ts_o <= 0;
    end else begin
        prev_acc_idle <= acc_idle_i;

        // Detect rising edge of acc_idle_i
        if (!prev_acc_idle && acc_idle_i) begin
            if (!ts_data_empty_i && !ts_synced_o) begin // Input data available, sync with input
                current_ts_o <= current_ts_o + 1;
            end else if (ts_data_empty_i) begin         // Input empty, increment timestep
                current_ts_o <= current_ts_o + 1;
            end
        end
    end
end

endmodule
