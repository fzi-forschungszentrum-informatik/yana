`define QUOTE(q) `"q`"

`define assert_eq_b(signal, value) \
        if (signal !== value) begin \
            $display("ASSERT EQUALS FAILED for signal %s: Expected: %b; Received: %b", `QUOTE(signal), value, signal); \
        end else begin \
            $display("ASSERT EQUALS SUCCEEDED for signal %s: Expected: %b; Received: %b", `QUOTE(signal), value, signal); \
        end

`define assert_eq_h(signal, value) \
        if (signal !== value) begin \
            $display("ASSERT EQUALS FAILED for signal %s: Expected: %h; Received: %h", `QUOTE(signal), value, signal); \
        end else begin \
            $display("ASSERT EQUALS SUCCEEDED for signal %s: Expected: %h; Received: %h", `QUOTE(signal), value, signal); \
        end

`define assert_eq_i(signal, value) \
        if (signal !== value) begin \
            $display("ASSERT EQUALS FAILED for signal %s: Expected: %d; Received: %d", `QUOTE(signal), value, signal); \
        end else begin \
            $display("ASSERT EQUALS SUCCEEDED for signal %s: Expected: %d; Received: %d", `QUOTE(signal), value, signal); \
        end

`define assert_eq_fp(signal, decimal_position, value) \
    if (signal !== value) begin \
        $display("ASSERT EQUALS FAILED for signal %s: Expected: %0f; Received: %0f", \
                `QUOTE(signal), \
                $signed(value) / (1.0 * (1 << decimal_position)), \
                $signed(signal) / (1.0 * (1 << decimal_position))); \
    end else begin \
        $display("ASSERT EQUALS SUCCEEDED for signal %s: Expected: %0f; Received: %0f", \
                `QUOTE(signal), \
                $signed(value) / (1.0 * (1 << decimal_position)), \
                $signed(signal) / (1.0 * (1 << decimal_position))); \
    end

`define assert_eq_v(signal, value, size) \
        for (int i = 0; i < size; i++) begin \
            if (signal[i] !== value[i]) begin \
                $display("ASSERT EQUALS VECTOR FAILED at index %0d for signal %s: Expected: %0h; Received: %0h", i, `QUOTE(signal), value[i], signal[i]); \
            end else begin \
                $display("ASSERT EQUALS VECTOR SUCCEEDED at index %0d for signal %s: Expected: %0h; Received: %0h", i, `QUOTE(signal), value[i], signal[i]); \
            end \
        end

`define assert_neq_b(signal, value) \
        if (signal === value) begin \
            $display("ASSERT NOT EQUALS FAILED in %m: Expected: %b; Received: %b", value, signal); \
        end else begin \
            $display("ASSERT NOT EQUALS SUCCEEDED in %m: Expected: %b; Received: %b", value, signal); \
        end
