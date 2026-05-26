`ifndef DEBUG_INVARIANTS_SVH
`define DEBUG_INVARIANTS_SVH

// Debug invariants - full implementation
// All checks are gated by AURORA_SIMULATION to allow silicon to exclude them.

`ifdef AURORA_SIMULATION

// Check that a state machine doesn't stay in a waiting state without making
// progress. Asserts if (counter >= threshold) while still in the wait state.
`define CHECK_NO_WAIT_WITHOUT_PROGRESS(module, state, counter, threshold) \
    always @(posedge clk) begin \
        if (rst_n && state && (counter >= threshold)) begin \
            $error("[%0t] [INVARIANT] %s: stalled %0d cycles without progress (threshold=%0d)", \
                   $time, module, counter, threshold); \
        end \
    end

// Check that a resource usage count never exceeds the specified maximum.
`define CHECK_RESOURCE_CONSERVATION(module, resource, count, max) \
    always @(posedge clk) begin \
        if (rst_n && (count > max)) begin \
            $error("[%0t] [INVARIANT] %s: resource %0d exceeds max %0d", \
                   $time, module, count, max); \
        end \
    end

// Check that credit counting stays balanced: credits_used - credits_returned <= max_credits.
`define CHECK_CREDIT_FLOW_BALANCE(module, credits_used, credits_returned, max_credits) \
    always @(posedge clk) begin \
        if (rst_n) begin \
            if ((credits_used - credits_returned) > max_credits) begin \
                $error("[%0t] [INVARIANT] %s: credit balance %0d exceeds max %0d", \
                       $time, module, (credits_used - credits_returned), max_credits); \
            end \
        end \
    end

// Check that request-response pairing stays balanced: dispatched - completed <= tolerance.
`define CHECK_REQUEST_RESPONSE_PAIRING(module, dispatched, completed, tolerance) \
    always @(posedge clk) begin \
        if (rst_n) begin \
            if ((dispatched - completed) > tolerance) begin \
                $error("[%0t] [INVARIANT] %s: outstanding requests %0d exceeds tolerance %0d", \
                       $time, module, (dispatched - completed), tolerance); \
            end \
        end \
    end

`else

// Silicon stubs — compile to nothing
`define CHECK_NO_WAIT_WITHOUT_PROGRESS(module, state, counter, threshold)
`define CHECK_RESOURCE_CONSERVATION(module, resource, count, max)
`define CHECK_CREDIT_FLOW_BALANCE(module, credits_used, credits_returned, max_credits)
`define CHECK_REQUEST_RESPONSE_PAIRING(module, dispatched, completed, tolerance)

`endif

`endif
