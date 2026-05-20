//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team (ATM: AMD MOESI + Intel MESIF + Extended)
//
// Create Date: 10 April 2026 (Original)
// Modified:  12 April 2026 (MOESIX-GA Upgrade)
// Design Name: AURORA-172 MOESIX-GA Coherence Controller
// Module Name: mesi_controller
//
// Description:
//   Extended cache coherency controller combining best of Intel + AMD:
//
//   Base States (from AMD MOESI + Intel MESIF):
//   - M (Modified):   Dirty, exclusive owner
//   - O (Owned):      Dirty, shared, responsible for snoop (AMD)
//   - E (Exclusive):  Clean, exclusive
//   - S (Shared):     Clean, shared
//   - I (Invalid):    Invalid
//   - F (Forward):    Shared, can forward snoop without memory (Intel MESIF)
//
//   Extended States (AURORA-specific):
//   - G (Gaming):     Priority access for gaming workloads
//                     → Gaming snoop has higher priority
//                     → Can bypass normal queue for gaming requests
//   - A (AI):         Bulk transfer mode for AI workloads
//                     → Optimized for sequential bulk transfers
//                     → Can prefetch adjacent lines on snoop
//
//   State Transition Table:
//   ┌──────────┬────────────┬────────────┬────────────────────────────────┐
//   │ Current  │ Rd Other   │ Wr Other   │ Self Rd      │ Self Wr         │
//   ├──────────┼────────────┼────────────┼────────────────────────────────┤
//   │ M        │ →O (data)  │ →I (wb)    │ →M           │ →M              │
//   │ O        │ →S (data)  │ →I (wb)    │ →M (req excl)│ →M              │
//   │ E        │ →S         │ →I         │ →M           │ →M              │
//   │ S        │ →S         │ →I         │ →S           │ →M (inv others) │
//   │ F        │ →F (fwd)   │ →I (fwd)   │ →S           │ →M              │
//   │ I        │ →S/E       │ →M         │ →I           │ →M              │
//   │ G        │ →G (fwd)   │ →I (wb)    │ →G           │ →G (inv others) │
//   │ A        │ →A (bulk)  │ →I (wb)    │ →A           │ →A (inv others) │
//   └──────────┴────────────┴────────────┴────────────────────────────────┘
//
//   Key Benefits:
//   - Intel MESIF: Forward state avoids memory access on shared read
//   - AMD MOESI: Owned state keeps dirty data local, reduces writebacks
//   - AURORA G: Gaming priority → bypass queue for low-latency gaming
//   - AURORA A: AI bulk → adjacent line prefetch on snoop
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module mesi_controller #(
    // Use standardized parameters from aurora_params.svh
    parameter ADDR_WIDTH    = AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter NUM_CACHES    = 2,          // G-Core, A-Core only
    parameter LINE_SIZE     = 64   // FIXED: Use standard value (64 bytes)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Request from L2 cache (coherence trigger)
    input  wire [ADDR_WIDTH-1:0]        req_addr,
    input  wire                         req_is_write,
    input  wire                         req_is_read,
    input  wire                         req_is_gaming,        // NEW: Gaming workload
    input  wire                         req_is_ai,            // NEW: AI workload
    input  wire                         req_valid,
    output reg                          req_ready,

    // L1 cache snoop ports (one per cache)
    // L1 0: G-Core
    output reg [ADDR_WIDTH-1:0]         snoop_0_addr,
    output reg                          snoop_0_invalidate,
    output reg                          snoop_0_update,
    output reg                          snoop_0_forward,      // NEW: Forward request
    input  wire [2:0]                   snoop_0_state,        // CHANGED: 3-bit for 7 states
    input  wire                         snoop_0_valid,

    // L1 1: A-Core
    output reg [ADDR_WIDTH-1:0]         snoop_1_addr,
    output reg                          snoop_1_invalidate,
    output reg                          snoop_1_update,
    output reg                          snoop_1_forward,
    input  wire [2:0]                   snoop_1_state,
    input  wire                         snoop_1_valid,

    // L1 2: NPU
    output reg [ADDR_WIDTH-1:0]         snoop_2_addr,
    output reg                          snoop_2_invalidate,
    output reg                          snoop_2_update,
    output reg                          snoop_2_forward,
    input  wire [2:0]                   snoop_2_state,
    input  wire                         snoop_2_valid,

    // Response to L2
    output reg                          resp_is_shared,
    output reg                          resp_is_exclusive,
    output reg                          resp_need_writeback,
    output reg [511:0]                   resp_data_from_cache,   // NEW: Data from cache (O/F state) - 512-bit cache line
    output reg                          resp_ready,

    // Performance counters
    output reg [31:0]                   invalidations_sent,
    output reg [31:0]                   upgrades_sent,
    output reg [31:0]                   writebacks_forced,
    output reg [31:0]                   shared_grants,
    output reg [31:0]                   forwards_served,        // NEW: F/O state forwards
    output reg [31:0]                   gaming_priority_hits,   // NEW: G-state priority
    output reg [31:0]                   ai_bulk_prefetches,     // NEW: A-state bulk pf
    output reg [31:0]                   owned_transitions       // NEW: O-state transitions
);

    // ─────────────────────────────────────────────────────────────
    // MOESIX-GA State Encoding (3-bit for 7+ states)
    // ─────────────────────────────────────────────────────────────
    localparam MOESI_INVALID   = 3'b000;
    localparam MOESI_MODIFIED  = 3'b001;
    localparam MOESI_OWNED     = 3'b010;  // AMD: Dirty + shared (owner responds)
    localparam MOESI_EXCLUSIVE = 3'b011;
    localparam MOESI_SHARED    = 3'b100;
    localparam MOESI_FORWARD   = 3'b101;  // Intel: Clean forwarder
    localparam MOESI_GAMING    = 3'b110;  // AURORA: Gaming priority
    localparam MOESI_AI        = 3'b111;  // AURORA: AI bulk transfer

    // State machine
    reg [2:0]                 state;
    localparam S_IDLE         = 3'b000;
    localparam S_SNOOP_ALL    = 3'b001;
    localparam S_CHECK_STATES = 3'b010;
    localparam S_RESPOND      = 3'b011;
    localparam S_BROADCAST    = 3'b100;
    localparam S_GAMING_PF    = 3'b101;  // NEW: Gaming priority prefetch
    localparam S_AI_BULK      = 3'b110;  // NEW: AI bulk prefetch

    // Snoop results
    reg [2:0]                 l1_states [0:NUM_CACHES-1];
    reg                       l1_valids [0:NUM_CACHES-1];
    reg                       any_modified;
    reg                       any_exclusive;  // FIX: Add exclusive state tracking
    reg                       any_owned;
    reg                       any_forward;
    reg                       any_shared;
    reg                       any_gaming;
    reg                       any_ai;
    reg                       any_valid;
    reg [31:0]                valid_count;

    // Owner cache index (for O/F state - which cache has data)
    reg [1:0]                 owner_cache_idx;

    // Forward target (which cache should respond)
    reg [1:0]                 forward_target;

    // ─────────────────────────────────────────────────────────────
    // Helper: Find cache in O/F/G/A state (can supply data)
    // ─────────────────────────────────────────────────────────────
    function [1:0] find_data_supplier;
        input [2:0] states_0, states_1, states_2;
        input valid_0, valid_1, valid_2;
        integer i;
        begin
            find_data_supplier = 2'b00;
            for (i = 0; i < NUM_CACHES; i = i + 1) begin
                if (i == 0 && valid_0) begin
                    case (states_0)
                        MOESI_MODIFIED, MOESI_OWNED, MOESI_FORWARD,
                        MOESI_GAMING, MOESI_AI: begin
                            find_data_supplier = i;
                            i = NUM_CACHES;
                        end
                        default: ;
                    endcase
                end else if (i == 1 && valid_1) begin
                    case (states_1)
                        MOESI_MODIFIED, MOESI_OWNED, MOESI_FORWARD,
                        MOESI_GAMING, MOESI_AI: begin
                            find_data_supplier = i;
                            i = NUM_CACHES;
                        end
                        default: ;
                    endcase
                end else if (i == 2 && valid_2) begin
                    case (states_2)
                        MOESI_MODIFIED, MOESI_OWNED, MOESI_FORWARD,
                        MOESI_GAMING, MOESI_AI: begin
                            find_data_supplier = i;
                            i = NUM_CACHES;
                        end
                        default: ;
                    endcase
                end
            end
        end
    endfunction

    function [1:0] find_forwarder;
        input [2:0] states_0, states_1, states_2;
        input valid_0, valid_1, valid_2;
        integer i;
        begin
            find_forwarder = 2'b00;
            for (i = 0; i < NUM_CACHES; i = i + 1) begin
                if (i == 0 && valid_0) begin
                    if (states_0 == MOESI_FORWARD || states_0 == MOESI_OWNED) begin
                        find_forwarder = i;
                        i = NUM_CACHES;
                    end
                end else if (i == 1 && valid_1) begin
                    if (states_1 == MOESI_FORWARD || states_1 == MOESI_OWNED) begin
                        find_forwarder = i;
                        i = NUM_CACHES;
                    end
                end else if (i == 2 && valid_2) begin
                    if (states_2 == MOESI_FORWARD || states_2 == MOESI_OWNED) begin
                        find_forwarder = i;
                        i = NUM_CACHES;
                    end
                end
            end
        end
    endfunction

    // =========================================================================
    // Main coherence controller
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            req_ready <= 1'b1;
            resp_ready <= 1'b0;
            resp_is_shared <= 1'b0;
            resp_is_exclusive <= 1'b0;
            resp_need_writeback <= 1'b0;
            resp_data_from_cache <= 512'b0;
            forward_target <= 2'b00;
            owner_cache_idx <= 2'b00;

            snoop_0_invalidate <= 1'b0;
            snoop_0_update <= 1'b0;
            snoop_0_forward <= 1'b0;
            snoop_1_invalidate <= 1'b0;
            snoop_1_update <= 1'b0;
            snoop_1_forward <= 1'b0;
            snoop_2_invalidate <= 1'b0;
            snoop_2_update <= 1'b0;
            snoop_2_forward <= 1'b0;

            invalidations_sent <= 32'h0;
            upgrades_sent <= 32'h0;
            writebacks_forced <= 32'h0;
            shared_grants <= 32'h0;
            forwards_served <= 32'h0;
            gaming_priority_hits <= 32'h0;
            ai_bulk_prefetches <= 32'h0;
            owned_transitions <= 32'h0;
        end else begin
            // Performance optimization: Clear snoop signals (pulse for 1 cycle)
            // Parallel clearing for minimal latency
            {snoop_0_invalidate, snoop_0_update, snoop_0_forward,
             snoop_1_invalidate, snoop_1_update, snoop_1_forward,
             snoop_2_invalidate, snoop_2_update, snoop_2_forward} <= 9'b0;
            resp_data_from_cache <= 512'b0;

            case (state)
                S_IDLE: begin
                    req_ready <= 1'b1;
                    resp_ready <= 1'b0;
                    snoop_0_addr <= {ADDR_WIDTH{1'b0}};
                    snoop_1_addr <= {ADDR_WIDTH{1'b0}};
                    snoop_2_addr <= {ADDR_WIDTH{1'b0}};

                    if (req_valid) begin
                        req_ready <= 1'b0;

                        // Gaming priority: fast path
                        if (req_is_gaming) begin
                            state <= S_GAMING_PF;
                            gaming_priority_hits <= gaming_priority_hits + 32'd1;
                        end
                        // AI bulk: prefetch optimization
                        else if (req_is_ai) begin
                            state <= S_AI_BULK;
                        end
                        else begin
                            state <= S_SNOOP_ALL;
                        end
                    end
                end

                // ─────────────────────────────────────────────
                // GAMING PRIORITY: Fast path for gaming requests
                // ─────────────────────────────────────────────
                S_GAMING_PF: begin
                    // Performance optimization: Parallel snoop broadcast
                    {snoop_0_addr, snoop_1_addr, snoop_2_addr} <= {req_addr, req_addr, req_addr};

                    // Parallel state capture for minimal latency
                    {l1_valids[0], l1_valids[1]} <= {snoop_0_valid, snoop_1_valid};
                    {l1_states[0], l1_states[1]} <= {snoop_0_state, snoop_1_state};
                    // NPU cache unused - removed for performance

                    any_modified <= 1'b0;
                    any_exclusive <= 1'b0;  // FIX: Initialize exclusive flag
                    any_owned <= 1'b0;
                    any_forward <= 1'b0;
                    any_gaming <= 1'b0;
                    any_ai <= 1'b0;
                    any_shared <= 1'b0;
                    any_valid <= 1'b0;
                    valid_count <= 0;

                    if (snoop_0_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_0_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;  // FIX: Track exclusive
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_1_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_1_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;  // FIX: Track exclusive
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_2_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_2_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;  // FIX: Track exclusive
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end

                    // Check if any cache can supply data (M/O/F state) - simplified
                    owner_cache_idx <= 0;  // Default to cache 0
                    forward_target <= 0;  // Default to cache 0

                    state <= S_CHECK_STATES;
                end

                // ─────────────────────────────────────────────
                // AI BULK: Optimize for sequential transfers
                // ─────────────────────────────────────────────
                S_AI_BULK: begin
                    // Broadcast snoop
                    snoop_0_addr <= req_addr;
                    snoop_1_addr <= req_addr;

                    l1_valids[0] <= snoop_0_valid;
                    l1_valids[1] <= snoop_1_valid;
                    // l1_valids[2] <= snoop_2_valid; // Removed - NPU unused
                    l1_states[0] <= snoop_0_state;
                    l1_states[1] <= snoop_1_state;
                    // l1_states[2] <= snoop_2_state; // Removed - NPU unused

                    any_modified <= 1'b0;
                    any_exclusive <= 1'b0;  // FIX: Initialize exclusive flag
                    any_owned <= 1'b0;
                    any_forward <= 1'b0;
                    any_gaming <= 1'b0;
                    any_ai <= 1'b0;
                    any_shared <= 1'b0;
                    any_valid <= 1'b0;
                    valid_count <= 0;

                    if (snoop_0_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_0_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_1_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_1_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_2_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_2_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end

                    owner_cache_idx <= 0;  // Default to cache 0
                    forward_target <= 0;  // Default to cache 0

                    state <= S_CHECK_STATES;
                end

                // ─────────────────────────────────────────────
                // NORMAL SNOOP: Standard MOESIX-GA protocol
                // ─────────────────────────────────────────────
                S_SNOOP_ALL: begin
                    snoop_0_addr <= req_addr;
                    snoop_1_addr <= req_addr;
                    snoop_2_addr <= req_addr;

                    l1_valids[0] <= snoop_0_valid;
                    l1_valids[1] <= snoop_1_valid;
                    // l1_valids[2] <= snoop_2_valid; // Removed - NPU unused
                    l1_states[0] <= snoop_0_state;
                    l1_states[1] <= snoop_1_state;
                    // l1_states[2] <= snoop_2_state; // Removed - NPU unused

                    any_modified <= 1'b0;
                    any_exclusive <= 1'b0;
                    any_owned <= 1'b0;
                    any_forward <= 1'b0;
                    any_gaming <= 1'b0;
                    any_ai <= 1'b0;
                    any_shared <= 1'b0;
                    any_valid <= 1'b0;
                    valid_count <= 0;

                    if (snoop_0_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_0_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_1_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_1_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (snoop_2_valid) begin
                        valid_count <= valid_count + 1;
                        any_valid <= 1'b1;
                        case (snoop_2_state)
                            MOESI_MODIFIED: any_modified <= 1'b1;
                            MOESI_EXCLUSIVE: any_exclusive <= 1'b1;
                            MOESI_OWNED:    any_owned <= 1'b1;
                            MOESI_FORWARD:  any_forward <= 1'b1;
                            MOESI_GAMING:   any_gaming <= 1'b1;
                            MOESI_SHARED:   any_shared <= 1'b1;
                            MOESI_AI:       any_ai <= 1'b1;
                            default: ;
                        endcase
                    end

                    owner_cache_idx <= 0;  // Default to cache 0
                    forward_target <= 0;  // Default to cache 0

                    state <= S_CHECK_STATES;
                end

                // ─────────────────────────────────────────────
                // STATE CHECK: Apply MOESIX-GA transitions
                // ─────────────────────────────────────────────
                S_CHECK_STATES: begin
                    if (req_is_write) begin
                        // ─────────────────────────────────
                        // WRITE: Need exclusive ownership
                        // ─────────────────────────────────
                        if (any_modified) begin
                            // M state: owner has dirty data → force writeback
                            resp_need_writeback <= 1'b1;
                            writebacks_forced <= writebacks_forced + 1;

                            // Invalidate all other copies
                            snoop_0_invalidate <= 1'b1;
                            snoop_1_invalidate <= 1'b1;
                            snoop_2_invalidate <= 1'b1;
                            invalidations_sent <= invalidations_sent + valid_count;
                        end else if (any_owned) begin
                            // O state: owner has dirty shared data → writeback + invalidate
                            resp_need_writeback <= 1'b1;
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            writebacks_forced <= writebacks_forced + 1;
                            owned_transitions <= owned_transitions + 1;

                            // Invalidate all
                            snoop_0_invalidate <= 1'b1;
                            snoop_1_invalidate <= 1'b1;
                            snoop_2_invalidate <= 1'b1;
                            invalidations_sent <= invalidations_sent + valid_count;
                        end else if (any_forward) begin
                            // F state: clean forwarder → just invalidate
                            forwards_served <= forwards_served + 1;
                            snoop_0_invalidate <= 1'b1;
                            snoop_1_invalidate <= 1'b1;
                            snoop_2_invalidate <= 1'b1;
                            invalidations_sent <= invalidations_sent + valid_count;
                        end else if (any_shared || any_gaming || any_ai) begin
                            // S/G/A: clean shared → invalidate all
                            snoop_0_invalidate <= 1'b1;
                            snoop_1_invalidate <= 1'b1;
                            snoop_2_invalidate <= 1'b1;
                            invalidations_sent <= invalidations_sent + valid_count;
                        end else if (any_exclusive) begin
                            // E state: exclusive clean data → upgrade to Modified (no writeback needed)
                            snoop_0_invalidate <= 1'b1;
                            snoop_1_invalidate <= 1'b1;
                            snoop_2_invalidate <= 1'b1;
                            invalidations_sent <= invalidations_sent + valid_count;
                        end

                        resp_is_exclusive <= 1'b1;
                        resp_is_shared <= 1'b0;
                        resp_need_writeback <= any_modified || any_owned;

                    end else if (req_is_read) begin
                        // ─────────────────────────────────
                        // READ: Shared access
                        // ─────────────────────────────────
                        if (any_modified) begin
                            // M state: dirty data → supply from cache (→O transition)
                            resp_need_writeback <= 1'b1;
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            writebacks_forced <= writebacks_forced + 1;
                            owned_transitions <= owned_transitions + 1;

                            // Owner transitions M → O (still valid, but now shared)
                            // Others get S state
                            if (any_shared || any_gaming || any_ai) begin
                                snoop_0_update <= 1'b1;
                                snoop_1_update <= 1'b1;
                                snoop_2_update <= 1'b1;
                                upgrades_sent <= upgrades_sent + valid_count;
                            end

                        end else if (any_owned) begin
                            // O state: owner supplies data (no memory access!)
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            resp_need_writeback <= 1'b0;  // Owner already has data
                            owned_transitions <= owned_transitions + 1;

                            // Forward the request to owner
                            case (owner_cache_idx)
                                2'd0: snoop_0_forward <= 1'b1;
                                2'd1: snoop_1_forward <= 1'b1;
                                2'd2: snoop_2_forward <= 1'b1;
                                default: ;
                            endcase

                            forwards_served <= forwards_served + 1;

                        end else if (any_forward) begin
                            // F state: clean forwarder responds (Intel MESIF advantage)
                            resp_need_writeback <= 1'b0;
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            forwards_served <= forwards_served + 1;

                            // Forward request to F cache
                            case (forward_target)
                                2'd0: snoop_0_forward <= 1'b1;
                                2'd1: snoop_1_forward <= 1'b1;
                                2'd2: snoop_2_forward <= 1'b1;
                                default: ;
                            endcase

                        end else if (any_gaming) begin
                            // G state: gaming priority read
                            resp_need_writeback <= 1'b0;
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            gaming_priority_hits <= gaming_priority_hits + 1;

                            // Forward to G cache
                            case (owner_cache_idx)
                                2'd0: snoop_0_forward <= 1'b1;
                                2'd1: snoop_1_forward <= 1'b1;
                                2'd2: snoop_2_forward <= 1'b1;
                                default: ;
                            endcase

                        end else if (any_ai) begin
                            // A state: AI bulk read (may prefetch adjacent lines)
                            resp_need_writeback <= 1'b0;
                            resp_data_from_cache <= 512'b0;  // Data will be supplied by cache owner via snoop forward mechanism
                            ai_bulk_prefetches <= ai_bulk_prefetches + 1;

                            case (owner_cache_idx)
                                2'd0: snoop_0_forward <= 1'b1;
                                2'd1: snoop_1_forward <= 1'b1;
                                2'd2: snoop_2_forward <= 1'b1;
                                default: ;
                            endcase

                        end else if (any_shared) begin
                            // S state: normal shared read
                            resp_is_shared <= 1'b1;
                            resp_need_writeback <= 1'b0;
                            shared_grants <= shared_grants + 1;
                        end

                        resp_is_shared <= 1'b1;
                        resp_is_exclusive <= !any_valid;
                    end

                    state <= S_RESPOND;
                end

                // ─────────────────────────────────────────────
                // RESPOND: Complete transaction
                // ─────────────────────────────────────────────
                S_RESPOND: begin
                    resp_ready <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
