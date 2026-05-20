`ifndef DEBUG_INVARIANTS_SVH
`define DEBUG_INVARIANTS_SVH

// Debug invariants - stub implementation (checks disabled)
`define CHECK_NO_WAIT_WITHOUT_PROGRESS(module, state, counter, threshold)
`define CHECK_RESOURCE_CONSERVATION(module, resource, count, max)
`define CHECK_CREDIT_FLOW_BALANCE(module, credits_used, credits_returned, max_credits)
`define CHECK_REQUEST_RESPONSE_PAIRING(module, dispatched, completed, tolerance)

`endif
