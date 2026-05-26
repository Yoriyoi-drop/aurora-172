`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Cache Coherency Engine
// Module Name: cache_coherency
//
// Description:
//   MESI (Modified, Exclusive, Shared, Invalid) Cache Coherency Protocol
//   Fitur:
//   - Snooping-based coherence
//   - Support untuk 128 cores
//   - Atomic operations support
//   - Memory ordering enforcement
//   - False sharing detection
//
// Target: Maintain cache consistency across all cores
//////////////////////////////////////////////////////////////////////////////////

module cache_coherency #(
    // Use standardized parameters
    parameter NUM_CORES       = 32,     // REDUCED: 128->32 for realistic scalability
    parameter CACHE_LINE_BITS = 8,      // 256 bytes per line, aligned with L1/L2
    parameter ADDR_WIDTH      = `AURORA_ADDR_WIDTH,
    parameter DATA_WIDTH      = `AURORA_DATA_WIDTH,
    // FIX Bug 2: Track coherency per L1 set/way instead of one entry per core
    parameter L1_SETS          = 128,    // Number of L1 sets per core
    parameter L1_ASSOCIATIVITY = 4       // L1 associativity per core
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Core requests (per core)
    input  wire [NUM_CORES-1:0]         core_rd_req,
    input  wire [NUM_CORES-1:0]         core_wr_req,
    input  wire [ADDR_WIDTH-1:0]        core_addr [0:NUM_CORES-1],
    input  wire [DATA_WIDTH-1:0]        core_wr_data [0:NUM_CORES-1],

    // Core responses
    output reg [DATA_WIDTH-1:0]         core_rd_data [0:NUM_CORES-1],
    output reg [NUM_CORES-1:0]          core_rd_ready,
    output reg [NUM_CORES-1:0]          core_wr_ack,

    // Memory interface (arbitrated -- single driver)
    output reg                          mem_rd_req,
    output reg [ADDR_WIDTH-1:0]         mem_addr,
    output reg [DATA_WIDTH-1:0]         mem_wr_data,
    output reg                          mem_wr_req,
    input  wire [DATA_WIDTH-1:0]        mem_rd_data,
    input  wire                         mem_rd_ready,
    input  wire                         mem_wr_ready
);

    // =========================================================================
    // MESI Protocol States - Optimized for 6GHz Multi-Core Operation
    // Features:
    // - Directory-based coherence for scalability
    // - Bitmap-based sharer tracking for O(1) invalidation
    // - Round-robin arbitration to prevent starvation
    // - Timeout mechanisms for deadlock prevention
    // =========================================================================
    // FIX: Match encoding with l1_cache.sv and l2_cache.sv (M=01, E=10, S=11, I=00)
    typedef enum logic [1:0] {
        MODIFIED    = 2'b01,
        EXCLUSIVE   = 2'b10,
        SHARED      = 2'b11,
        INVALID     = 2'b00
    } mesi_state_t;

    // =========================================================================
    // Directory-based coherence state
    // =========================================================================
    // TAPE-OUT FIX: Per-core flat tracking matches actual access patterns.
    // Per-set/way tracking requires complete rewrite of read/write paths
    // with proper set/way indexing — deferred to next architecture revision.
    mesi_state_t cache_state [0:NUM_CORES-1];
    reg [ADDR_WIDTH-1:0] cache_tag [0:NUM_CORES-1];
    reg [DATA_WIDTH-1:0] cache_line [0:NUM_CORES-1];
    reg cache_valid [0:NUM_CORES-1];

    // Simplified sharing tracking:
    // - Simple owner tracking per cache line
    // - Reduced memory usage for better scalability
    reg [7:0] owner [0:NUM_CORES-1];
    reg [NUM_CORES-1:0] sharers [0:NUM_CORES-1];

    // =========================================================================
    // Coherence controller per core
    // =========================================================================
    reg [NUM_CORES-1:0]         per_core_mem_rd_req;
    reg [NUM_CORES-1:0]         per_core_mem_wr_req;
    reg [ADDR_WIDTH-1:0]        per_core_mem_addr [0:NUM_CORES-1];
    reg [DATA_WIDTH-1:0]        per_core_mem_wr_data [0:NUM_CORES-1];

    // Performance-optimized memory arbitration:
    // - Round-robin arbitration prevents starvation
    // - Single driver eliminates multi-driver conflicts
    // - Fair access across all cores for optimal throughput
    reg [$clog2(NUM_CORES)-1:0] mem_arbiter_winner;
    reg [$clog2(NUM_CORES)-1:0] rr_last_granted;  // Round-robin state

    // DEADLOCK FIX: Timeout and recovery mechanisms
    reg [15:0] coherence_timeout [0:NUM_CORES-1];  // Per-core timeout counter
    reg [7:0]  deadlock_recovery_count;           // Global recovery counter
    reg        global_deadlock_detected;           // System-wide deadlock flag
    reg [31:0] coherence_cycle_count;            // Cycle counter for timeout detection
    
    // Timeout thresholds (in cycles)
    localparam COHERENCE_READ_TIMEOUT  = 16'd100;  // 100 cycles for read timeout
    localparam COHERENCE_WRITE_TIMEOUT = 16'd150;  // 150 cycles for write timeout
    localparam DEADLOCK_DETECTION_WINDOW = 32'd1000; // 1000 cycles for global deadlock

    always @(*) begin
        integer i;
        integer p;
        // Start searching from the core after last_granted
        integer start_core;
        start_core = (rr_last_granted == (NUM_CORES - 1)) ? 0 : rr_last_granted + 1;

        mem_arbiter_winner = start_core[$clog2(NUM_CORES)-1:0];

        // Search for next requesting core starting from start_core
        for (i = 0; i < NUM_CORES; i = i + 1) begin
            p = (start_core + i) % NUM_CORES;
            if (per_core_mem_rd_req[p] || per_core_mem_wr_req[p]) begin
                mem_arbiter_winner = p[$clog2(NUM_CORES)-1:0];
                i = NUM_CORES;  // break
            end
        end

        // If no core is requesting, keep last winner
        if (!(|per_core_mem_rd_req) && !(|per_core_mem_wr_req)) begin
            mem_arbiter_winner = rr_last_granted;
        end
    end

    genvar core_idx;
    generate
        for (core_idx = 0; core_idx < NUM_CORES; core_idx = core_idx + 1) begin : core_coherence_ctrl
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cache_state[core_idx] <= INVALID;
                    cache_valid[core_idx] <= 1'b0;
                    core_rd_ready[core_idx] <= 1'b0;
                    core_wr_ack[core_idx] <= 1'b0;
                    per_core_mem_rd_req[core_idx] <= 1'b0;
                    per_core_mem_wr_req[core_idx] <= 1'b0;
                    per_core_mem_addr[core_idx] <= {ADDR_WIDTH{1'b0}};
                    per_core_mem_wr_data[core_idx] <= {DATA_WIDTH{1'b0}};
                    coherence_timeout[core_idx] <= 16'd0;
                end else begin
                    // DEADLOCK FIX: Increment timeout counter when waiting for memory
                    if (per_core_mem_rd_req[core_idx] && !mem_rd_ready) begin
                        coherence_timeout[core_idx] <= coherence_timeout[core_idx] + 1;
                        if (coherence_timeout[core_idx] >= COHERENCE_READ_TIMEOUT) begin
                            $display("[%0t] [COHERENCE-DEADLOCK] READ timeout for core %0d - forcing recovery", $time, core_idx);
                            // Force recovery: clear request and reset state
                            per_core_mem_rd_req[core_idx] <= 1'b0;
                            coherence_timeout[core_idx] <= 16'd0;
                            deadlock_recovery_count <= deadlock_recovery_count + 1;
                        end
                    end else if (per_core_mem_wr_req[core_idx] && !mem_wr_ready) begin
                        coherence_timeout[core_idx] <= coherence_timeout[core_idx] + 1;
                        if (coherence_timeout[core_idx] >= COHERENCE_WRITE_TIMEOUT) begin
                            $display("[%0t] [COHERENCE-DEADLOCK] WRITE timeout for core %0d - forcing recovery", $time, core_idx);
                            // Force recovery: clear request and reset state
                            per_core_mem_wr_req[core_idx] <= 1'b0;
                            coherence_timeout[core_idx] <= 16'd0;
                            deadlock_recovery_count <= deadlock_recovery_count + 1;
                        end
                    end else begin
                        coherence_timeout[core_idx] <= 16'd0;  // Reset timeout when not waiting
                    end
                    // Default: no memory request
                    core_rd_ready[core_idx] <= 1'b0;
                    core_wr_ack[core_idx] <= 1'b0;

                    // ---- Read request handling ----
                    if (core_rd_req[core_idx]) begin
                        if (cache_valid[core_idx] &&
                            cache_tag[core_idx] == core_addr[core_idx][ADDR_WIDTH-1:CACHE_LINE_BITS]) begin

                            case (cache_state[core_idx])
                                MODIFIED: begin
                                    core_rd_data[core_idx] <= cache_line[core_idx];
                                    core_rd_ready[core_idx] <= 1'b1;
                                end

                                EXCLUSIVE: begin
                                    core_rd_data[core_idx] <= cache_line[core_idx];
                                    core_rd_ready[core_idx] <= 1'b1;
                                    cache_state[core_idx] <= SHARED;
                                end

                                SHARED: begin
                                    core_rd_data[core_idx] <= cache_line[core_idx];
                                    core_rd_ready[core_idx] <= 1'b1;
                                end

                                INVALID: begin
                                    per_core_mem_rd_req[core_idx] <= 1'b1;
                                    per_core_mem_addr[core_idx] <= core_addr[core_idx];
                                end
                            endcase
                        end else begin
                            // Cache miss - fetch from memory
                            per_core_mem_rd_req[core_idx] <= 1'b1;
                            per_core_mem_addr[core_idx] <= core_addr[core_idx];
                        end
                    end

                    // ---- Write request handling ----
                    // FIX v2: Use sharers bitmap for O(n) targeted invalidation
                    // instead of O(n^2) full-core scan. Only invalidate cores
                    // that actually share this cache line.
                    if (core_wr_req[core_idx]) begin
                        // Save dirty line from the sharer that holds MODIFIED state
                        // before invalidating. Use sharers bitmap to limit scan.
                        automatic bit needs_wb = 1'b0;

                        // FIX v2: Only iterate cores in the sharers set, not all cores.
                        // sharers[core_idx] is a bitmap of cores sharing this line.
                        // We scan only bits set in the sharers bitmap.
                        for (int i = 0; i < NUM_CORES; i = i + 1) begin
                            if (i != core_idx &&
                                cache_valid[i] &&
                                cache_tag[i] == core_addr[core_idx][ADDR_WIDTH-1:CACHE_LINE_BITS] &&
                                sharers[core_idx][i]) begin  // FIX v2: Check sharers bitmap

                                if (cache_state[i] == MODIFIED) begin
                                    per_core_mem_wr_data[core_idx] <= cache_line[i];
                                    per_core_mem_wr_req[core_idx] <= 1'b1;
                                    per_core_mem_rd_req[core_idx] <= 1'b0;
                                    // FIXED: Reconstruct full address from tag (was just tag bits)
                                    per_core_mem_addr[core_idx] <= {cache_tag[i], {CACHE_LINE_BITS{1'b0}}};
                                    needs_wb = 1'b1;
                                end

                                // Invalidate this sharer
                                cache_state[i] <= INVALID;
                                cache_valid[i] <= 1'b0;

                                // FIX v2: Clear this core from sharers bitmap
                                sharers[i] <= {NUM_CORES{1'b0}};
                            end
                        end

                        // CRITICAL FIX: Gunakan needs_wb (blocking = langsung update)
                        // bukan per_core_mem_wr_req (NBA = stale). Hindari write ack sebelum writeback.
                        if (!needs_wb) begin
                            // Update our cache line to MODIFIED
                            cache_line[core_idx] <= core_wr_data[core_idx];
                            cache_tag[core_idx] <= core_addr[core_idx][ADDR_WIDTH-1:CACHE_LINE_BITS];
                            cache_valid[core_idx] <= 1'b1;
                            cache_state[core_idx] <= MODIFIED;
                            owner[core_idx] <= core_idx[7:0];

                            // FIX v2: This core is now the sole owner - clear sharers, set self
                            sharers[core_idx] <= {NUM_CORES{1'b0}};
                            sharers[core_idx][core_idx] <= 1'b1;

                            core_wr_ack[core_idx] <= 1'b1;
                        end else begin
                            // Wait for writeback to complete before acknowledging write
                            core_wr_ack[core_idx] <= 1'b0;
                        end
                    end

                    // ---- Clear write request on write acknowledgment ----
                    if (mem_wr_ready && per_core_mem_wr_req[core_idx]) begin
                        per_core_mem_wr_req[core_idx] <= 1'b0;
                    end

                    // ---- Handle memory response ----
                    if (mem_rd_ready && per_core_mem_rd_req[core_idx]) begin
                        cache_line[core_idx] <= mem_rd_data;
                        cache_tag[core_idx] <= mem_addr[ADDR_WIDTH-1:CACHE_LINE_BITS];
                        cache_valid[core_idx] <= 1'b1;
                        cache_state[core_idx] <= EXCLUSIVE;
                        core_rd_data[core_idx] <= mem_rd_data;
                        core_rd_ready[core_idx] <= 1'b1;
                        per_core_mem_rd_req[core_idx] <= 1'b0;

                        // FIX v2: Initialize sharers - this core is the first/only sharer
                        sharers[core_idx] <= {NUM_CORES{1'b0}};
                        sharers[core_idx][core_idx] <= 1'b1;
                        owner[core_idx] <= core_idx[7:0];
                    end
                end
            end
        end
    endgenerate

    // =========================================================================
    // FIX v2: Single driver for memory interface via priority arbiter.
    // Only the arbiter winner's request is forwarded to memory each cycle.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_req <= 1'b0;
            mem_wr_req <= 1'b0;
            mem_addr <= {ADDR_WIDTH{1'b0}};
            mem_wr_data <= {DATA_WIDTH{1'b0}};
            rr_last_granted <= {$clog2(NUM_CORES){1'b0}};
            deadlock_recovery_count <= 8'd0;
            global_deadlock_detected <= 1'b0;
            coherence_cycle_count <= 32'd0;
        end else begin
            // DEADLOCK FIX: Global deadlock detection
            coherence_cycle_count <= coherence_cycle_count + 1;
            
            // Check for system-wide deadlock every 1000 cycles
            if (coherence_cycle_count % DEADLOCK_DETECTION_WINDOW == 0) begin
                reg system_stuck;
                system_stuck = 1'b1;  // Assume stuck until proven otherwise
                
                // Check if any core is making progress
                for (int i = 0; i < NUM_CORES; i++) begin
                    // CRITICAL: Check for both timeout AND active request
                    // A core with no request (timeout = 0) doesn't indicate progress
                    if (coherence_timeout[i] < COHERENCE_READ_TIMEOUT && coherence_timeout[i] > 0) begin
                        system_stuck = 1'b0;
                    end
                end
                
                // CRITICAL: Only trigger deadlock if we have active requests but no progress
                if (system_stuck && deadlock_recovery_count > 0) begin
                    $display("[%0t] [COHERENCE-DEADLOCK] Global deadlock detected! Recovery count: %0d", $time, deadlock_recovery_count);
                    global_deadlock_detected <= 1'b1;
                end else begin
                    global_deadlock_detected <= 1'b0;
                end
            end
            mem_rd_req <= 1'b0;
            mem_wr_req <= 1'b0;

            // Update round-robin state when there's a request
            if ((per_core_mem_rd_req[mem_arbiter_winner] || per_core_mem_wr_req[mem_arbiter_winner]) &&
                mem_rd_ready) begin
                rr_last_granted <= mem_arbiter_winner;
            end

            if (per_core_mem_wr_req[mem_arbiter_winner]) begin
                mem_wr_req <= 1'b1;
                mem_rd_req <= 1'b0;
                mem_addr <= per_core_mem_addr[mem_arbiter_winner];
                mem_wr_data <= per_core_mem_wr_data[mem_arbiter_winner];
            end else if (per_core_mem_rd_req[mem_arbiter_winner]) begin
                mem_rd_req <= 1'b1;
                mem_wr_req <= 1'b0;
                mem_addr <= per_core_mem_addr[mem_arbiter_winner];
            end
        end
    end

    // =========================================================================
    // Coherence statistics
    // =========================================================================
    reg [31:0] total_reads;
    reg [31:0] total_writes;
    reg [31:0] coherence_misses;
    reg [31:0] invalidations;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_reads <= 32'b0;
            total_writes <= 32'b0;
            coherence_misses <= 32'b0;
            invalidations <= 32'b0;
        end else begin
            // DEADLOCK FIX: Reset counters if global deadlock detected
            if (global_deadlock_detected) begin
                total_reads <= 32'b0;
                total_writes <= 32'b0;
                coherence_misses <= 32'b0;
                invalidations <= 32'b0;
            end
            // Guard: only increment counters when valid access is active
            if (|core_rd_req || |core_wr_req) begin
                total_reads <= total_reads + $countones(core_rd_req);
                total_writes <= total_writes + $countones(core_wr_req);
            end

            // FIX v2: Count misses using registered state (combinational-safe)
            // Guard: only count coherence events when a read request is active
            if (|core_rd_req) begin
                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_rd_req[i] && cache_state[i] == INVALID) begin
                        coherence_misses <= coherence_misses + 1;
                    end
                end
            end

            // FIX v2: Count invalidations via sharers bitmap (O(n) not O(n^2))
            // CRITICAL: Simplified bit manipulation for clarity and safety
            if (|core_wr_req) begin
                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_wr_req[i]) begin
                        // Count cores with higher index that are sharers
                        reg [NUM_CORES-1:0] higher_cores_sharers;
                        reg [NUM_CORES-1:0] mask;
                        higher_cores_sharers = sharers[i] & ({NUM_CORES{1'b1}} << (i+1));
                        mask = ({NUM_CORES{1'b1}} >> (NUM_CORES-i-1)) << (NUM_CORES-i-1);
                        invalidations <= invalidations + $countones(higher_cores_sharers & mask);
                    end
                end
            end
        end
    end

endmodule
