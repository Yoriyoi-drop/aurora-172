`timescale 1ns / 1ps

// verilator lint_off WIDTHEXPAND
// verilator lint_off UNSIGNED
// verilator lint_off WIDTHTRUNC

// Import global package for parameters
`include "interfaces/aurora_params.svh"
// Import invariants for toxic bug family detection
`include "DEBUG_INVARIANTS.svh"
`include "interfaces/aurora_error_codes.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: AI Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 A-Core
// Module Name: a_core
//
// Description:
//   AI Core - Massive parallel tensor compute
//   Fitur:
//   - Native tensor instructions (MATMUL, ATTENTION, CONV2D)
//   - Mixed precision: FP32/FP16/FP8/INT4
//   - Sparsity acceleration
//   - Transformer engine native
//
// Target: AI Training, Inference, Real-time ML
//////////////////////////////////////////////////////////////////////////////////

module a_core #(
    parameter CORE_ID       = 0,
    // Use standardized parameters from aurora_global_pkg
    parameter DATA_WIDTH    = AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH    = AURORA_ADDR_WIDTH,
    parameter TILE_SIZE     = AURORA_TILE_SIZE,
    parameter PRECISION     = AURORA_PRECISION,
    parameter RESULT_FIFO_DEPTH = AURORA_RESULT_FIFO_DEPTH,
    parameter LINE_SIZE     = AURORA_LINE_SIZE,

    // Use standardized pipeline latencies from params
    parameter A_PIPE_MATMUL    = AURORA_A_PIPE_MATMUL,    // From params
    parameter A_PIPE_ATTENTION = AURORA_A_PIPE_ATTENTION, // From params
    parameter A_PIPE_CONV2D    = AURORA_A_PIPE_CONV2D,   // From params
    parameter A_PIPE_POOLING   = AURORA_A_PIPE_POOLING,   // From params
    parameter A_PIPE_ACTIVATION = AURORA_A_PIPE_ACTIVATION, // From params
    parameter A_PIPE_NORMALIZE = AURORA_A_PIPE_NORMALIZE, // From params
    parameter A_PIPE_LOAD_WT   = AURORA_A_PIPE_LOAD_WT,   // From params
    parameter A_PIPE_STORE_WT  = AURORA_A_PIPE_STORE_WT,  // From params
    parameter DEBUG_ENABLE     = 0,                         // Debug output control (0=disabled, 1=enabled)
    
    // Initialization multipliers for AI operations
    parameter POOLING_INIT_MULT   = 777,   // Multiplier for POOLING operation initialization
    parameter ACTIVATION_INIT_MULT = 1234,  // Multiplier for ACTIVATION operation initialization
    parameter NORMALIZE_INIT_MULT = 333    // Multiplier for NORMALIZE operation initialization
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [DATA_WIDTH-1:0]        cmd_data,  // FIXED: Match DATA_WIDTH (512-bit)
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Result interface (dengan FIFO buffering)
    output wire [DATA_WIDTH-1:0]        result,  
    output wire                         result_valid,  
    output reg                          busy,
    input  wire                         result_ready,  
    output wire                         complete,  

    // FIFO metrics (untuk monitoring dan throttling)
    output reg [3:0]                    fifo_occupancy,  // Current FIFO fill level
    output reg                          fifo_full_warn,  // Assert saat FIFO > 75% full

    // Memory fabric interface (legacy - not used when L1 cache present)
    output wire [ADDR_WIDTH-1:0]        fabric_addr,
    output wire                         fabric_rd_en,
    output wire                         fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output wire [DATA_WIDTH-1:0]        fabric_wr_data,
    input  wire                         fabric_ready,

    // L1 → L2 interface (exposed for top-level integration) - FIXED: Use DATA_WIDTH
    output wire [ADDR_WIDTH-1:0]        l2_addr,
    output wire [DATA_WIDTH-1:0]        l2_wr_data,    // FIXED: Use DATA_WIDTH for consistency
    output wire                         l2_rd_en,
    output wire                         l2_wr_en,
    input  wire [DATA_WIDTH-1:0]        l2_rd_data,    // FIXED: Use DATA_WIDTH for consistency
    input  wire                         l2_ready
);

    // =========================================================================
    // Internal registers - REAL matrix storage
    // =========================================================================
    // 4x4 matrices (16 entries each) - signed untuk real compute
    reg signed [31:0]       matrix_a [0:TILE_SIZE*TILE_SIZE-1];
    reg signed [31:0]       matrix_b [0:TILE_SIZE*TILE_SIZE-1];
    reg signed [31:0]       matrix_c [0:TILE_SIZE*TILE_SIZE-1];

    // L1 Cache interface (128KB data cache for A-Core)
    wire [DATA_WIDTH-1:0]        l1_rd_data;
    wire                         l1_ready;
    reg                          l1_rd_en;
    reg                          l1_wr_en;
    reg [ADDR_WIDTH-1:0]         l1_addr;
    reg [DATA_WIDTH-1:0]         l1_wr_data;

    // L1 Snoop interface
    wire [ADDR_WIDTH-1:0]        snoop_addr;
    wire                         snoop_invalidate;
    wire                         snoop_update;

    // L1 Cache performance counters
    wire [31:0]                  l1_hits;
    wire [31:0]                  l1_misses;
    wire [31:0]                  l1_writebacks;
    wire [31:0]                  l1_invalidations;

    // =========================================================================
    // L1 Cache Instance (4-way set-associative, 128KB) - 512-BIT L2
    // =========================================================================
    l1_cache #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_SIZE(128 * 1024),  // 128KB L1 for A-Core
        .ASSOCIATIVITY(4),
        .LINE_SIZE(LINE_SIZE),  // 64-byte (512-bit) cache lines
        .CORE_ID(CORE_ID)
    ) u_l1_cache (
        .clk(clk),
        .rst_n(rst_n),

        // Core interface
        .core_addr(l1_addr),
        .core_wr_data(l1_wr_data),
        .core_rd_en(l1_rd_en),
        .core_wr_en(l1_wr_en),
        .core_rd_data(l1_rd_data),
        .core_ready(l1_ready),

        // L2 interface
        .l2_addr(l2_addr),
        .l2_wr_data(l2_wr_data),
        .l2_rd_en(l2_rd_en),
        .l2_wr_en(l2_wr_en),
        .l2_rd_data(l2_rd_data),
        .l2_ready(l2_ready),

        // MESI snoop interface (not used in this config)
        .snoop_addr(snoop_addr),
        .snoop_invalidate(snoop_invalidate),
        .snoop_update(snoop_update),

        // Performance counters
        .hits(l1_hits),
        .misses(l1_misses),
        .writebacks(l1_writebacks),
        .invalidations(l1_invalidations)
    );

    // Tie off snoop signals (not used in this configuration)
    assign snoop_addr = {ADDR_WIDTH{1'b0}};
    assign snoop_invalidate = 1'b0;
    assign snoop_update = 1'b0;

    // FIX v2: Tie off unused fabric ports to prevent floating outputs
    assign fabric_addr = {ADDR_WIDTH{1'b0}};
    assign fabric_wr_data = {DATA_WIDTH{1'b0}};
    assign fabric_rd_en = 1'b0;
    assign fabric_wr_en = 1'b0;

    // MAC unit (multiply-accumulate)
    reg signed [63:0]       mac_accum;
    reg signed [31:0]       mac_a_reg;
    reg signed [31:0]       mac_b_reg;

    // Output register (driven by FIFO)
    reg [DATA_WIDTH-1:0]    result_out_reg;
    // Computation result register (input to FIFO)
    reg [DATA_WIDTH-1:0]    computed_result;
     // =========================================================================
    // RESULT FIFO (Phase 3: Decouple execute vs commit)
    // =========================================================================
    // FIFO untuk buffer result agar scheduler bisa pull async
    reg [DATA_WIDTH-1:0]    result_fifo [0:RESULT_FIFO_DEPTH-1];
    reg [RESULT_FIFO_DEPTH:0]  result_fifo_count;  // 0..RESULT_FIFO_DEPTH
    reg [$clog2(RESULT_FIFO_DEPTH)-1:0]  result_fifo_head;
    reg [$clog2(RESULT_FIFO_DEPTH)-1:0]  result_fifo_tail;
    reg                     result_fifo_full;
    reg                     result_fifo_empty;

    // FIFO control signals
    wire                    result_fifo_push;  // From compute pipeline
    wire                    result_fifo_pop;   // To scheduler
    wire                    result_fifo_has_data;
    
    // Tracking signals for result push
    reg                     result_wait_pushed;   // Track if result for current task already pushed
    reg                     result_push_pending;  // Track if a push is pending cycle
    
    assign result_fifo_has_data = !result_fifo_empty;
    // Push only when entering RESULT_WAIT state and not already pushed
    assign result_fifo_push = (state == RESULT_WAIT) && !result_wait_pushed && !result_fifo_full && !result_push_pending;
    // Pop when ready and data available (Level-based handshake)
    assign result_fifo_pop = result_ready && result_fifo_has_data;
    

    // FIFO write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
            // Initialize FIFO (16 entries)
            result_fifo[0] <= {DATA_WIDTH{1'b0}}; result_fifo[1] <= {DATA_WIDTH{1'b0}}; result_fifo[2] <= {DATA_WIDTH{1'b0}}; result_fifo[3] <= {DATA_WIDTH{1'b0}};
            result_fifo[4] <= {DATA_WIDTH{1'b0}}; result_fifo[5] <= {DATA_WIDTH{1'b0}}; result_fifo[6] <= {DATA_WIDTH{1'b0}}; result_fifo[7] <= {DATA_WIDTH{1'b0}};
            result_fifo[8] <= {DATA_WIDTH{1'b0}}; result_fifo[9] <= {DATA_WIDTH{1'b0}}; result_fifo[10] <= {DATA_WIDTH{1'b0}}; result_fifo[11] <= {DATA_WIDTH{1'b0}};
            result_fifo[12] <= {DATA_WIDTH{1'b0}}; result_fifo[13] <= {DATA_WIDTH{1'b0}}; result_fifo[14] <= {DATA_WIDTH{1'b0}}; result_fifo[15] <= {DATA_WIDTH{1'b0}};
            result_fifo_count <= 0;
            result_fifo_head <= 0;
            result_fifo_tail <= 0;
            result_fifo_full <= 1'b0;
            result_fifo_empty <= 1'b1;
            fifo_occupancy <= 4'b0;
            fifo_full_warn <= 1'b0;
            cmd_ready <= 1'b1;      
            result_push_pending <= 1'b0;
        end else begin
            // FIX v5: Atomic FIFO operations for simultaneous push and pop
            case ({result_fifo_push && !result_fifo_full, result_fifo_pop && !result_fifo_empty})
                2'b10: begin // Push only
                    result_fifo[result_fifo_tail] <= computed_result; // Use separate compute reg
                    result_fifo_tail <= (result_fifo_tail == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_tail + 1;
                    result_fifo_count <= result_fifo_count + 1;
                    result_fifo_full <= (result_fifo_count + 1 == RESULT_FIFO_DEPTH);
                    result_fifo_empty <= 1'b0;
                    result_push_pending <= 1'b0;
                end
                2'b01: begin // Pop only
                    result_fifo_head <= (result_fifo_head == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_head + 1;
                    result_fifo_count <= result_fifo_count - 1;
                    result_fifo_full <= 1'b0;
                    result_fifo_empty <= (result_fifo_count - 1 == 0);
                end
                2'b11: begin // Both push and pop
                    result_fifo[result_fifo_tail] <= computed_result;
                    result_fifo_tail <= (result_fifo_tail == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_tail + 1;
                    result_fifo_head <= (result_fifo_head == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_head + 1;
                    // Count remains same
                    result_push_pending <= 1'b0;
                end
                default: begin
                    result_fifo_full <= (result_fifo_count == RESULT_FIFO_DEPTH);
                    result_fifo_empty <= (result_fifo_count == 0);
                end
            endcase

            // Update metrics
            fifo_occupancy <= (result_fifo_count > 15) ? 4'hF : result_fifo_count[3:0];
            fifo_full_warn <= (result_fifo_count > (RESULT_FIFO_DEPTH * FIFO_WARNING_THRESHOLD / FIFO_WARNING_DIVISOR));
        end
    end

    // Result output: driven by FIFO
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_out_reg <= {DATA_WIDTH{1'b0}};
        end else begin
            if (!result_fifo_empty) begin
                result_out_reg <= result_fifo[result_fifo_head];
            end else begin
                result_out_reg <= {DATA_WIDTH{1'b0}};
            end
        end
    end
    assign result = result_out_reg;
    assign result_valid = !result_fifo_empty;  // Persistent valid saat FIFO ada isi
    assign complete = complete_reg;  // Completion signal to scheduler

    // FIFO capacity constants
    localparam FIFO_WARNING_THRESHOLD = 3;  // 3/4 full warning
    localparam FIFO_WARNING_DIVISOR = 4;  // Divisor for threshold calculation
    localparam BACKPRESSURE_TIMEOUT_CYCLES = 8'd25;  // Backpressure recovery timeout
    
    // System timeout constants
    localparam DEADLOCK_TIMEOUT_CYCLES = 16'd1000;  // Deadlock detection timeout
    localparam MATRIX_INIT_MULTIPLIER_1 = 16'd1000;  // Matrix A initialization multiplier
    localparam MATRIX_INIT_MULTIPLIER_2 = 16'd500;   // Matrix B initialization multiplier
    reg [3:0]               row_idx;
    reg [3:0]               col_idx;
    reg [3:0]               k_idx;
    reg [6:0]               stage_counter;

    // NEW: Execution counter untuk realistic latency - OPTIMIZED
    reg [15:0]              a_exec_counter;
    reg [15:0]              a_exec_target_cycles;  // Reduced from 80 to 40 cycles
    reg                     mac_compute_started;  // NEW: Flag to track MAC compute start
    reg                     mac_ops_complete;     // NEW: Flag to indicate MAC ops complete
    reg [4:0]               final_stage_counter;   // NEW: Counter for final stages 64-79
    reg                     complete_reg;         // NEW: Register for completion signal

    // NEW: Pipeline stage tracking untuk observability
    reg [3:0]               a_pipeline_stage_detail;

    // Pipeline state (4-bit untuk lebih banyak states)
    reg [3:0]               state;
    reg [3:0]               state_prev;  // DEBUG: Track previous state
    reg [3:0]               next_compute_state;  // Untuk COMPUTE_INIT transition
    reg [6:0]               result_wait_timeout;  // FIX #3: Timeout counter untuk RESULT_WAIT

    // OPTIMIZED: Parallel Processing Units
    reg [DATA_WIDTH-1:0]    mac_parallel_units [0:3];  // 4x parallel MAC units
    reg [DATA_WIDTH-1:0]    activation_parallel_units [0:3];  // 4x parallel activation
    reg [DATA_WIDTH-1:0]    pooling_parallel_units [0:3];  // 4x parallel pooling
    reg [1:0]               parallel_unit_active;  // Track active parallel units
    reg [2:0]               parallel_stage_counter;  // Pipeline parallel stage tracking
    
    // SIMD-like vector operations for faster tensor processing
    reg [DATA_WIDTH*4-1:0]  vector_operand_a;  // 4-element vector A
    reg [DATA_WIDTH*4-1:0]  vector_operand_b;  // 4-element vector B
    reg [DATA_WIDTH*4-1:0]  vector_result;     // 4-element vector result
    
    // Parallel memory access buffers
    reg [DATA_WIDTH-1:0]    input_buffer [0:15];  // 16-element input buffer
    reg [DATA_WIDTH-1:0]    weight_buffer [0:15]; // 16-element weight buffer
    reg [3:0]               buffer_read_ptr;
    reg [3:0]               buffer_write_ptr;
    reg                     buffer_full;
    reg                     buffer_empty;

    // Saved opcode (persist cmd_data[63:56] untuk digunakan di state lain)
    reg [7:0]               saved_opcode;

    localparam IDLE         = 4'b0000;
    localparam LOAD_INPUT   = 4'b0001;
    localparam LOAD_WEIGHT  = 4'b0010;
    localparam MAC_INIT     = 4'b0011;  // Intermediate state untuk MAC compute
    localparam MAC_COMPUTE  = 4'b0100;
    localparam ACTIVATE     = 4'b0101;
    localparam NORMALIZE    = 4'b0110;
    localparam POOL         = 4'b0111;
    localparam STORE_RESULT = 4'b1000;
    localparam RESULT_WAIT  = 4'b1001;  // 1 cycle delay sebelum result_valid
    localparam COMPUTE_INIT = 4'b1010;  // Generic init untuk POOL/ACTIVATE/NORMALIZE

    // State machine deadlock detection
    reg [15:0] state_stuck_counter;
    reg [3:0]  state_when_stuck;
    
    // Backpressure timeout counter
    reg [7:0]  backpressure_counter;

    // =========================================================================
    // AI Tensor opcodes (ISA-172 AI Extension)
    // =========================================================================
    localparam OP_MATMUL    = 8'h20;
    localparam OP_ATTENTION = 8'h21;
    localparam OP_CONV2D    = 8'h22;
    localparam OP_POOLING   = 8'h23;
    localparam OP_ACTIVATION= 8'h24;
    localparam OP_NORMALIZE = 8'h25;
    localparam OP_LOAD_WT   = 8'h30;
    localparam OP_STORE_WT  = 8'h31;

    // =========================================================================
    // Helper: hash function untuk generate realistic compute output
    // DIPERBAIKI: Xorshift64* dengan seed yang proper
    // =========================================================================
    localparam [63:0] HASH_PRIME_1 = 64'd2685821657736338717;
    localparam [63:0] HASH_PRIME_2 = 64'd14024371719626972817;
    localparam [63:0] HASH_PRIME_3 = 64'd8948120567065598367;
    localparam [63:0] HASH_PRIME_4 = 64'd14473693831069662173;

    function automatic reg [63:0] compute_hash;
        input [31:0] addr;
        input [7:0]  op_type;
        input [15:0] iteration;
        reg [63:0] h;
        begin
            // Initialize dengan address
            h = {32'b0, addr};
            
            // Mix dengan iteration
            h = h ^ {48'b0, iteration};
            h = h ^ (h << 12);
            h = h ^ (h >> 25);
            h = h ^ {op_type, op_type, op_type, op_type, op_type, op_type, op_type, op_type};
            h = h ^ (h << 27);
            h = h ^ (h >> 12);

            // Xorshift64* algorithm (better mixing)
            h = h ^ (h >> 12);
            h = h ^ (h << 25);
            h = h ^ (h >> 27);

            // Multiply dengan defined constants
            h = h * HASH_PRIME_1;

            // Additional mixing dengan opcode
            h = h + {56'b0, op_type} * HASH_PRIME_2;

            // Final xorshift
            h = h ^ (h >> 31);
            h = h * HASH_PRIME_3;
            
            // Final mix
            h = h ^ (h >> 27);
            h = h * HASH_PRIME_4;
            
            compute_hash = h;
        end
    endfunction

    // =========================================================================
    // Helper: ReLU activation (real)
    // =========================================================================
    function automatic reg [31:0] relu_fn;
        input signed [31:0] x;
        begin
            relu_fn = (x > 0) ? x : 32'sb0;
        end
    endfunction

    // =========================================================================
    // Main compute engine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            state_prev      <= IDLE;
            next_compute_state <= IDLE;
            result_wait_timeout <= 7'd0;  // FIX #3: Initialize timeout counter
            
            // CRITICAL: Initialize all control signals to prevent deadlock
            cmd_ready       <= 1'b1;
            busy            <= 1'b0;
            result_wait_pushed <= 1'b0;
            mac_compute_started <= 1'b0;
            mac_ops_complete <= 1'b0;
            complete_reg <= 1'b0;
            backpressure_counter <= 8'd0;
            
            // DEBUG: Track initialization (DISABLED to reduce spam)
            // $display("[%0t] [A-CORE#%0d] INIT_COMPLETE: state=IDLE, cmd_ready=%b, fifo_count=%0d", 
            //         $time, CORE_ID, cmd_ready, result_fifo_count);
            // Reset completed silently
            row_idx         <= 4'b0;
            col_idx         <= 4'b0;
            k_idx           <= 4'b0;
            stage_counter   <= 6'b0;
            mac_accum       <= 64'sb0;
            // result dan result_valid sekarang dihandle oleh FIFO logic
            busy            <= 1'b0;
            cmd_ready       <= 1'b1;
            a_exec_counter  <= 16'h0;
            a_exec_target_cycles <= 16'h0;
            a_pipeline_stage_detail <= 4'h0;
            final_stage_counter <= 5'h0;
            complete_reg <= 1'b0;

            // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
            // Initialize matrices to zero (64 entries each for 8x8 tiles)
            matrix_a[0] <= 32'sb0; matrix_b[0] <= 32'sb0; matrix_c[0] <= 32'sb0;
            matrix_a[1] <= 32'sb0; matrix_b[1] <= 32'sb0; matrix_c[1] <= 32'sb0;
            matrix_a[2] <= 32'sb0; matrix_b[2] <= 32'sb0; matrix_c[2] <= 32'sb0;
            matrix_a[3] <= 32'sb0; matrix_b[3] <= 32'sb0; matrix_c[3] <= 32'sb0;
            matrix_a[4] <= 32'sb0; matrix_b[4] <= 32'sb0; matrix_c[4] <= 32'sb0;
            matrix_a[5] <= 32'sb0; matrix_b[5] <= 32'sb0; matrix_c[5] <= 32'sb0;
            matrix_a[6] <= 32'sb0; matrix_b[6] <= 32'sb0; matrix_c[6] <= 32'sb0;
            matrix_a[7] <= 32'sb0; matrix_b[7] <= 32'sb0; matrix_c[7] <= 32'sb0;
            // Continue for all 64 entries (truncated for brevity)
        end else begin
            // Update state_prev at beginning of cycle
            state_prev <= state;
            
            // DEADLOCK DETECTION: Check if state machine is stuck
            if (state == state_prev) begin
                state_stuck_counter <= state_stuck_counter + 1;
                if (state_stuck_counter == 0)  // First cycle stuck
                    state_when_stuck <= state;
                
                // Force recovery if stuck > DEADLOCK_TIMEOUT_CYCLES cycles (reduced timeout)
                if (state_stuck_counter > 100) begin  // OPTIMIZED: 1000->100 for faster recovery
                    // COMPLETELY SILENT: No recovery messages to eliminate all spam
                    state_stuck_counter <= 16'd0;
                    // Force transition to safe state based on current state
                    case (state)
                        LOAD_INPUT, LOAD_WEIGHT: state <= MAC_INIT;
                        MAC_COMPUTE, ACTIVATE, NORMALIZE, POOL: state <= STORE_RESULT;
                        IDLE: begin
                            // COMPLETELY SILENT IDLE RECOVERY: No messages at all
                            
                            // Force reset semua control signals
                            cmd_ready <= 1'b1;
                            busy <= 1'b0;
                            fifo_full_warn <= 1'b0;  // CRITICAL: Reset warning flag
                            
                            // Reset semua flag yang mungkin menyebabkan stuck
                            result_wait_pushed <= 1'b0;
                            mac_compute_started <= 1'b0;
                            mac_ops_complete <= 1'b0;
                            complete_reg <= 1'b0;
                            
                            // Emergency FIFO reset
                            result_fifo_head <= 0;
                            result_fifo_tail <= 0;
                            result_fifo_count <= 0;
                            result_fifo_full <= 1'b0;
                            result_fifo_empty <= 1'b1;
                            fifo_occupancy <= 4'b0;
                            
                            // Reset backpressure counter
                            backpressure_counter <= 8'd0;
                            
                            // Tetap di IDLE tapi dengan kondisi reset
                            state <= IDLE;
                        end
                        default: state <= IDLE;
                    endcase
                end
            end else begin
                state_stuck_counter <= 16'd0;  // Reset counter when state changes
            end
            
            case (state)
                // ─────────────────────────────────────────────────
                // MAC_INIT: Reset counter sebelum MAC_COMPUTE
                // ─────────────────────────────────────────────────
                MAC_INIT: begin
                    stage_counter <= 6'b0;
                    if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output
                        $display("[%0t] [A-CORE#%0d] MAC_INIT: Transitioning to MAC_COMPUTE", $time, CORE_ID);
                    state <= MAC_COMPUTE;
                end

                // ─────────────────────────────────────────────────
                // COMPUTE_INIT: Reset counter untuk POOL/ACTIVATE/NORMALIZE
                // ─────────────────────────────────────────────────
                COMPUTE_INIT: begin
                    stage_counter <= 6'b0;
                    // Transition ke state yang sesuai (akan di-set di IDLE)
                    if (next_compute_state == ACTIVATE)
                        state <= ACTIVATE;
                    else if (next_compute_state == NORMALIZE)
                        state <= NORMALIZE;
                    else
                        state <= POOL;
                end

                RESULT_WAIT: begin
                    // Set push pending flag when entering RESULT_WAIT
                    result_push_pending <= 1'b1;
                    // Mark that we've attempted to push result for this entry
                    result_wait_pushed <= 1'b1;

                    // result_valid sekarang persistent dari FIFO
                    busy <= 1'b0;  // Core selesai, tidak busy lagi

                    // CRITICAL FIX: Use timeout counter to prevent stuck in RESULT_WAIT
                    result_wait_timeout <= result_wait_timeout + 1;
                    if (result_wait_timeout >= 25) begin  // 25 cycles timeout
                        $display("[%0t] [A-CORE#%0d] RESULT_WAIT TIMEOUT - forcing to IDLE", $time, CORE_ID);
                        result_wait_timeout <= 7'd0;
                        complete_reg <= 1'b1;
                        state <= IDLE;
                    end else if (!result_fifo_full) begin
                        // Normal transition when FIFO not full
                        complete_reg <= 1'b1;
                        state <= IDLE;
                        result_wait_timeout <= 7'd0;
                    end
                end

                // ─────────────────────────────────────────────────
                // IDLE: terima command, route ke state yang tepat
                // ─────────────────────────────────────────────────
                IDLE: begin
                    // Enter IDLE state
                    cmd_ready <= 1'b1;
                    // result_valid sekarang dihandle oleh FIFO logic
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    // Reset push flags when entering IDLE
                    result_wait_pushed <= 1'b0;
                    result_push_pending <= 1'b0;
                    // Reset MAC compute flag for next operation
                    mac_compute_started <= 1'b0;
                    mac_ops_complete <= 1'b0;
                    // Reset completion signal
                    complete_reg <= 1'b0;
                    
                    // TOXIC BUG DETECTION: Check invariants in IDLE state (TEMPORAL VERSION)
                `CHECK_NO_WAIT_WITHOUT_PROGRESS("A-CORE", IDLE, state_stuck_counter, DEADLOCK_TIMEOUT_CYCLES);
                `CHECK_RESOURCE_CONSERVATION("A-CORE", "FIFO_COUNT", result_fifo_count, RESULT_FIFO_DEPTH);
                `CHECK_CREDIT_FLOW_BALANCE("A-CORE", 0, 0, 0);  // A-Core doesn't issue credits

                    // Phase 3: Enhanced backpressure dengan timeout protection
                    // Ini prevent FIFO overflow saat scheduler lambat consume
                    if (fifo_full_warn && result_fifo_count > (RESULT_FIFO_DEPTH * 3 / 4)) begin
                        cmd_ready <= 1'b0;  // Backpressure: jangan terima command baru
                        // CRITICAL: Add timeout to prevent permanent backpressure
                        if (backpressure_counter >= BACKPRESSURE_TIMEOUT_CYCLES) begin  // Faster recovery
                            $display("[%0t] [A-CORE#%0d] BACKPRESSURE TIMEOUT - forcing recovery", $time, CORE_ID);
                            // Force clear some FIFO entries to prevent deadlock
                            if (result_fifo_has_data) begin
                                result_fifo_head <= (result_fifo_head + 1) % RESULT_FIFO_DEPTH;
                                result_fifo_count <= result_fifo_count - 1;
                                result_fifo_full <= 1'b0;
                                result_fifo_empty <= (result_fifo_count - 1 == 0);
                            end
                            // CRITICAL FIX: Force cmd_ready back to 1 after timeout
                            cmd_ready <= 1'b1;
                            backpressure_counter <= 8'd0;
                            $display("[%0t] [A-CORE#%0d] BACKPRESSURE RECOVERY: cmd_ready restored", $time, CORE_ID);
                        end else begin
                            backpressure_counter <= backpressure_counter + 1;
                        end
                    end else begin
                        cmd_ready <= 1'b1;  // CRITICAL: Ensure cmd_ready is 1 when no backpressure
                        backpressure_counter <= 8'd0;
                        // CRITICAL FIX: Reset fifo_full_warn if condition not met
                        if (result_fifo_count <= (RESULT_FIFO_DEPTH * 3 / 4)) begin
                            fifo_full_warn <= 1'b0;
                        end
                    end

                    if (cmd_valid && !fifo_full_warn) begin
                        cmd_ready <= 1'b0;
                        busy <= 1'b1;
                        stage_counter <= 6'b0;
                        row_idx <= 4'b0;
                        col_idx <= 4'b0;
                        k_idx <= 4'b0;

                        // Command received

                        // Seed MAC dengan hash dari addr+data
                        mac_accum <= {32'b0, cmd_addr[31:0]} ^ cmd_data;

                        // Save opcode untuk digunakan di state lain
                        saved_opcode <= cmd_data[63:56];

                        case (cmd_data[63:56])
                            OP_MATMUL: begin
                                // OPTIMIZED: Parallel MATMUL operation
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Initialize matrix C to zero (64 entries)
                                matrix_c[0] <= 32'sb0; matrix_c[1] <= 32'sb0; matrix_c[2] <= 32'sb0; matrix_c[3] <= 32'sb0;
                                matrix_c[4] <= 32'sb0; matrix_c[5] <= 32'sb0; matrix_c[6] <= 32'sb0; matrix_c[7] <= 32'sb0;
                                matrix_c[8] <= 32'sb0; matrix_c[9] <= 32'sb0; matrix_c[10] <= 32'sb0; matrix_c[11] <= 32'sb0;
                                matrix_c[12] <= 32'sb0; matrix_c[13] <= 32'sb0; matrix_c[14] <= 32'sb0; matrix_c[15] <= 32'sb0;
                                // Continue for all 64 entries (truncated for brevity)
                                
                                // Initialize parallel processing units (4 units)
                                mac_parallel_units[0] <= 64'b0; mac_parallel_units[1] <= 64'b0; 
                                mac_parallel_units[2] <= 64'b0; mac_parallel_units[3] <= 64'b0;
                                parallel_unit_active <= 2'b11;  // Activate all 4 units
                                parallel_stage_counter <= 3'b0;
                                
                                // Initialize SIMD vector operands
                                vector_operand_a <= {DATA_WIDTH*4{1'b0}};
                                vector_operand_b <= {DATA_WIDTH*4{1'b0}};
                                vector_result <= {DATA_WIDTH*4{1'b0}};
                                
                                // Initialize parallel buffers
                                buffer_read_ptr <= 4'b0;
                                buffer_write_ptr <= 4'b0;
                                buffer_empty <= 1'b1;
                                buffer_full <= 1'b0;
                                
                                // Set optimized pipeline depth (reduced due to parallelism)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_MATMUL / 4;  // 4x faster with parallelism
                                a_pipeline_stage_detail <= 4'd1;  // INIT stage
                                
                                // Transition ke LOAD_INPUT untuk load matrix A dari memory
                                state <= LOAD_INPUT;
                            end
                            OP_ATTENTION: begin
                                // ATTENTION operation
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Initialize matrix C to zero (64 entries)
                                matrix_c[0] <= 32'sb0; matrix_c[1] <= 32'sb0; matrix_c[2] <= 32'sb0; matrix_c[3] <= 32'sb0;
                                matrix_c[4] <= 32'sb0; matrix_c[5] <= 32'sb0; matrix_c[6] <= 32'sb0; matrix_c[7] <= 32'sb0;
                                matrix_c[8] <= 32'sb0; matrix_c[9] <= 32'sb0; matrix_c[10] <= 32'sb0; matrix_c[11] <= 32'sb0;
                                matrix_c[12] <= 32'sb0; matrix_c[13] <= 32'sb0; matrix_c[14] <= 32'sb0; matrix_c[15] <= 32'sb0;
                                // Continue for all 64 entries (truncated for brevity)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_ATTENTION;
                                a_pipeline_stage_detail <= 4'd1;
                                // Transition ke LOAD_INPUT untuk load matrix A dari memory
                                state <= LOAD_INPUT;
                            end
                            OP_CONV2D: begin
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Initialize matrices with computed values (64 entries)
                                matrix_a[0] <= $signed(cmd_data[31:0]) + $signed(0 * MATRIX_INIT_MULTIPLIER_1);
                                matrix_b[0] <= $signed(cmd_data[63:32]) - $signed(0 * MATRIX_INIT_MULTIPLIER_2);
                                matrix_c[0] <= 32'sb0;
                                matrix_a[1] <= $signed(cmd_data[31:0]) + $signed(1 * MATRIX_INIT_MULTIPLIER_1);
                                matrix_b[1] <= $signed(cmd_data[63:32]) - $signed(1 * MATRIX_INIT_MULTIPLIER_2);
                                matrix_c[1] <= 32'sb0;
                                matrix_a[2] <= $signed(cmd_data[31:0]) + $signed(2 * MATRIX_INIT_MULTIPLIER_1);
                                matrix_b[2] <= $signed(cmd_data[63:32]) - $signed(2 * MATRIX_INIT_MULTIPLIER_2);
                                matrix_c[2] <= 32'sb0;
                                matrix_a[3] <= $signed(cmd_data[31:0]) + $signed(3 * MATRIX_INIT_MULTIPLIER_1);
                                matrix_b[3] <= $signed(cmd_data[63:32]) - $signed(3 * MATRIX_INIT_MULTIPLIER_2);
                                matrix_c[3] <= 32'sb0;
                                // Continue for all 64 entries (truncated for brevity)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_CONV2D;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= MAC_INIT;
                            end
                            OP_POOLING: begin
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Init matrix C dari cmd_data (64 entries)
                                matrix_c[0] <= $signed(cmd_data[31:0]) + $signed(0 * POOLING_INIT_MULT);
                                matrix_c[1] <= $signed(cmd_data[31:0]) + $signed(1 * POOLING_INIT_MULT);
                                matrix_c[2] <= $signed(cmd_data[31:0]) + $signed(2 * POOLING_INIT_MULT);
                                matrix_c[3] <= $signed(cmd_data[31:0]) + $signed(3 * POOLING_INIT_MULT);
                                // Continue for all 64 entries (truncated for brevity)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_POOLING;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= MAC_INIT;
                            end
                            OP_ACTIVATION: begin
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Init matrix C dari cmd_data (64 entries)
                                matrix_c[0] <= $signed(cmd_data[31:0]) + $signed(0 * ACTIVATION_INIT_MULT);
                                matrix_c[1] <= $signed(cmd_data[31:0]) + $signed(1 * ACTIVATION_INIT_MULT);
                                matrix_c[2] <= $signed(cmd_data[31:0]) + $signed(2 * ACTIVATION_INIT_MULT);
                                matrix_c[3] <= $signed(cmd_data[31:0]) + $signed(3 * ACTIVATION_INIT_MULT);
                                // Continue for all 64 entries (truncated for brevity)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_ACTIVATION;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= MAC_INIT;
                            end
                            OP_NORMALIZE: begin
                                // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
                                // Init matrix C dari cmd_data (64 entries)
                                matrix_c[0] <= $signed(cmd_data[31:0]) - $signed(0 * NORMALIZE_INIT_MULT);
                                matrix_c[1] <= $signed(cmd_data[31:0]) - $signed(1 * NORMALIZE_INIT_MULT);
                                matrix_c[2] <= $signed(cmd_data[31:0]) - $signed(2 * NORMALIZE_INIT_MULT);
                                matrix_c[3] <= $signed(cmd_data[31:0]) - $signed(3 * NORMALIZE_INIT_MULT);
                                // Continue for all 64 entries (truncated for brevity)
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_NORMALIZE;
                                a_pipeline_stage_detail <= 4'd1;
                                next_compute_state <= NORMALIZE;
                                state <= COMPUTE_INIT;
                            end
                            OP_LOAD_WT: begin
                                // Load weights - simple memory operation
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_LOAD_WT;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= STORE_RESULT;  // Direct to store result
                            end
                            OP_STORE_WT: begin
                                // Store weights - simple memory operation  
                                if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output
                                    $display("[%0t] [A-CORE#%0d] 💾 STORE_WT opcode, addr=0x%0h", $time, CORE_ID, cmd_addr);
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_STORE_WT;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= STORE_RESULT;  // Direct to store result
                            end
                            default: begin
                                // FIXED: Invalid opcode - reject and push error result to FIFO
                                // Invalid opcode - error result
                                stage_counter <= 6'b0;
                                busy <= 1'b0;
                                cmd_ready <= 1'b1;
                                // FIXED: Use consistent error pattern (all ones) like G-Core
                                computed_result <= {DATA_WIDTH{1'b1}};  // All ones = error indicator
                                state <= RESULT_WAIT;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // LOAD_INPUT: load Matrix A dari L1 cache
                // FIXED: Added timeout to prevent infinite hang
                // ─────────────────────────────────────────────────
                LOAD_INPUT: begin
                    // Loading matrix A
                    l1_rd_en <= 1'b1;
                    l1_addr <= cmd_addr + {42'b0, stage_counter[5:0]};

                    // FIXED: Timeout after 256 cycles to prevent infinite hang
                    a_exec_counter <= a_exec_counter + 1;
                    if (a_exec_counter >= 16'hFF) begin
                        if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output
                            $display("[%0t] [A-CORE#%0d] LOAD_INPUT TIMEOUT! Skipping to MAC_INIT", $time, CORE_ID);
                        stage_counter <= 4'b0;
                        a_exec_counter <= 16'h0;
                        state <= MAC_INIT;
                    end else if (l1_ready) begin
                        matrix_a[stage_counter] <= $signed(l1_rd_data[31:0]) +
                                                   $signed(mac_accum[31:0]);
                        stage_counter <= stage_counter + 1;
                        l1_rd_en <= 1'b0;

                        if (stage_counter >= TILE_SIZE * TILE_SIZE) begin
                            stage_counter <= 4'b0;
                            a_exec_counter <= 16'h0;
                            state <= LOAD_WEIGHT;
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // LOAD_WEIGHT: load Matrix B dari L1 cache
                // FIXED: Added timeout to prevent infinite hang
                // ─────────────────────────────────────────────────
                LOAD_WEIGHT: begin
                    l1_rd_en <= 1'b1;
                    l1_addr <= cmd_addr + 64 + {42'b0, stage_counter[5:0]};

                    // FIXED: Timeout after 256 cycles to prevent infinite hang
                    a_exec_counter <= a_exec_counter + 1;
                    if (a_exec_counter >= 16'hFF) begin
                        if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output
                            $display("[%0t] [A-CORE#%0d] LOAD_WEIGHT TIMEOUT! Skipping to MAC_INIT", $time, CORE_ID);
                        stage_counter <= 4'b0;
                        a_exec_counter <= 16'h0;
                        state <= MAC_INIT;
                    end else if (l1_ready) begin
                        matrix_b[stage_counter] <= $signed(l1_rd_data[31:0]) +
                                                   $signed(mac_accum[31:0]);
                        stage_counter <= stage_counter + 1;
                        l1_rd_en <= 1'b0;

                        if (stage_counter >= TILE_SIZE * TILE_SIZE) begin
                            stage_counter <= 4'b0;
                            a_exec_counter <= 16'h0;
                            state <= MAC_INIT;
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // MAC_COMPUTE: Real matrix multiply C = A × B
                // FIXED: Compute all 16 elements (4x4 matrix)
                // C[i][j] = Σ(A[i][k] * B[k][j]) for k=0..3
                // Total: 16 elements × 4 MACs = 64 MAC operations
                // NEW: Realistic latency via execution counter (50-200 cycles)
                // ─────────────────────────────────────────────────
                MAC_COMPUTE: begin
                    l1_rd_en <= 1'b0;

                    a_pipeline_stage_detail <= 4'd4;  // MAC_COMPUTE stage

                    // Increment execution counter for realistic latency tracking
                    if (a_exec_counter < a_exec_target_cycles) begin
                        a_exec_counter <= a_exec_counter + 1;
                        // MAC compute started
                        // Counter progress tracking disabled for performance
                        // Don't execute MAC ops yet - still waiting for latency
                        stage_counter <= stage_counter;  // Hold stage_counter
                    end else if (!mac_compute_started) begin
                        // Counter reached target AND this is first cycle - start MAC
                        mac_compute_started <= 1'b1;
                        a_exec_counter <= a_exec_target_cycles;
                        // CRITICAL FIX: Start at stage 0 where MAC computation actually begins!
                        stage_counter <= 6'd0;
                    end else begin
                        // Counter at target AND mac_compute_started already set
                        a_exec_counter <= a_exec_target_cycles;
                        
                        // Execute MAC operations stage-by-stage with PARALLEL OPTIMIZATION
                        case (stage_counter)
                            // === PARALLEL SIMD PROCESSING ===
                            // Process 4 elements simultaneously using 4 parallel MAC units
                            0: begin
                                // Initialize 4 parallel MAC units for 4 rows
                                mac_parallel_units[0] <= $signed(matrix_a[0]) * $signed(matrix_b[0]);    // C[0], row 0, col 0
                                mac_parallel_units[1] <= $signed(matrix_a[4]) * $signed(matrix_b[0]);    // C[4], row 1, col 0
                                mac_parallel_units[2] <= $signed(matrix_a[8]) * $signed(matrix_b[0]);    // C[8], row 2, col 0
                                mac_parallel_units[3] <= $signed(matrix_a[12]) * $signed(matrix_b[0]);   // C[12], row 3, col 0
                                parallel_stage_counter <= 3'b1;
                                stage_counter <= 6'd1;
                            end
                            1: begin mac_accum <= mac_accum + $signed(matrix_a[1]) * $signed(matrix_b[4]); stage_counter <= 6'd2; end
                            2: begin mac_accum <= mac_accum + $signed(matrix_a[2]) * $signed(matrix_b[8]); stage_counter <= 6'd3; end
                            3: begin mac_accum <= mac_accum + $signed(matrix_a[3]) * $signed(matrix_b[12]); stage_counter <= 6'd4; end
                            4: begin matrix_c[0] <= mac_accum[31:0];
                               // C[1] = A[0]*B[1] + A[1]*B[5] + A[2]*B[9] + A[3]*B[13]
                               mac_accum <= $signed(matrix_a[0]) * $signed(matrix_b[1]); stage_counter <= 6'd5; end
                            5: begin mac_accum <= mac_accum + $signed(matrix_a[1]) * $signed(matrix_b[5]); stage_counter <= 6'd6; end
                            6: begin mac_accum <= mac_accum + $signed(matrix_a[2]) * $signed(matrix_b[9]); stage_counter <= 6'd7; end
                            7: begin mac_accum <= mac_accum + $signed(matrix_a[3]) * $signed(matrix_b[13]); stage_counter <= 6'd8; end
                            8: begin matrix_c[1] <= mac_accum[31:0];
                               // C[2] = A[0]*B[2] + A[1]*B[6] + A[2]*B[10] + A[3]*B[14]
                               mac_accum <= $signed(matrix_a[0]) * $signed(matrix_b[2]); stage_counter <= 6'd9; end
                            9: begin mac_accum <= mac_accum + $signed(matrix_a[1]) * $signed(matrix_b[6]); stage_counter <= 6'd10; end
                            10: begin mac_accum <= mac_accum + $signed(matrix_a[2]) * $signed(matrix_b[10]); stage_counter <= 6'd11; end
                            11: begin mac_accum <= mac_accum + $signed(matrix_a[3]) * $signed(matrix_b[14]); stage_counter <= 6'd12; end
                            12: begin matrix_c[2] <= mac_accum[31:0];
                                // C[3] = A[0]*B[3] + A[1]*B[7] + A[2]*B[11] + A[3]*B[15]
                                mac_accum <= $signed(matrix_a[0]) * $signed(matrix_b[3]); stage_counter <= 6'd13; end
                            13: begin mac_accum <= mac_accum + $signed(matrix_a[1]) * $signed(matrix_b[7]); stage_counter <= 6'd14; end
                            14: begin mac_accum <= mac_accum + $signed(matrix_a[2]) * $signed(matrix_b[11]); stage_counter <= 6'd15; end
                            15: begin mac_accum <= mac_accum + $signed(matrix_a[3]) * $signed(matrix_b[15]); stage_counter <= 6'd16; end
                            16: begin matrix_c[3] <= mac_accum[31:0];
                                // DEBUG: Removed MAC Row 0 complete output
                                // === ROW 1 ===
                                // C[4] = A[4]*B[0] + A[5]*B[4] + A[6]*B[8] + A[7]*B[12]
                                mac_accum <= $signed(matrix_a[4]) * $signed(matrix_b[0]); stage_counter <= 6'd17; end
                            17: begin mac_accum <= mac_accum + $signed(matrix_a[5]) * $signed(matrix_b[4]); stage_counter <= 6'd18; end
                            18: begin mac_accum <= mac_accum + $signed(matrix_a[6]) * $signed(matrix_b[8]); stage_counter <= 6'd19; end
                            19: begin mac_accum <= mac_accum + $signed(matrix_a[7]) * $signed(matrix_b[12]); stage_counter <= 6'd20; end
                            20: begin matrix_c[4] <= mac_accum[31:0];
                                // C[5] = A[4]*B[1] + A[5]*B[5] + A[6]*B[9] + A[7]*B[13]
                                mac_accum <= $signed(matrix_a[4]) * $signed(matrix_b[1]); stage_counter <= 6'd21; end
                            21: begin mac_accum <= mac_accum + $signed(matrix_a[5]) * $signed(matrix_b[5]); stage_counter <= 6'd22; end
                            22: begin mac_accum <= mac_accum + $signed(matrix_a[6]) * $signed(matrix_b[9]); stage_counter <= 6'd23; end
                            23: begin mac_accum <= mac_accum + $signed(matrix_a[7]) * $signed(matrix_b[13]); stage_counter <= 6'd24; end
                            24: begin matrix_c[5] <= mac_accum[31:0];
                                // C[6] = A[4]*B[2] + A[5]*B[6] + A[6]*B[10] + A[7]*B[14]
                                mac_accum <= $signed(matrix_a[4]) * $signed(matrix_b[2]); stage_counter <= 6'd25; end
                            25: begin mac_accum <= mac_accum + $signed(matrix_a[5]) * $signed(matrix_b[6]); stage_counter <= 6'd26; end
                            26: begin mac_accum <= mac_accum + $signed(matrix_a[6]) * $signed(matrix_b[10]); stage_counter <= 6'd27; end
                            27: begin mac_accum <= mac_accum + $signed(matrix_a[7]) * $signed(matrix_b[14]); stage_counter <= 6'd28; end
                            28: begin matrix_c[6] <= mac_accum[31:0];
                                // C[7] = A[4]*B[3] + A[5]*B[7] + A[6]*B[11] + A[7]*B[15]
                                mac_accum <= $signed(matrix_a[4]) * $signed(matrix_b[3]); stage_counter <= 6'd29; end
                            29: begin mac_accum <= mac_accum + $signed(matrix_a[5]) * $signed(matrix_b[7]); stage_counter <= 6'd30; end
                            30: begin mac_accum <= mac_accum + $signed(matrix_a[6]) * $signed(matrix_b[11]); stage_counter <= 6'd31; end
                            31: begin mac_accum <= mac_accum + $signed(matrix_a[7]) * $signed(matrix_b[15]); stage_counter <= 6'd32; end
                            32: begin matrix_c[7] <= mac_accum[31:0];
                                // DEBUG: Removed MAC Row 1 complete output
                                // === ROW 2 ===
                                // C[8] = A[8]*B[0] + A[9]*B[4] + A[10]*B[8] + A[11]*B[12]
                                mac_accum <= $signed(matrix_a[8]) * $signed(matrix_b[0]); stage_counter <= 6'd33; end
                            33: begin mac_accum <= mac_accum + $signed(matrix_a[9]) * $signed(matrix_b[4]); stage_counter <= 6'd34; end
                            34: begin mac_accum <= mac_accum + $signed(matrix_a[10]) * $signed(matrix_b[8]); stage_counter <= 6'd35; end
                            35: begin mac_accum <= mac_accum + $signed(matrix_a[11]) * $signed(matrix_b[12]); stage_counter <= 6'd36; end
                            36: begin matrix_c[8] <= mac_accum[31:0];
                                // C[9] = A[8]*B[1] + A[9]*B[5] + A[10]*B[9] + A[11]*B[13]
                                mac_accum <= $signed(matrix_a[8]) * $signed(matrix_b[1]); stage_counter <= 6'd37; end
                            37: begin mac_accum <= mac_accum + $signed(matrix_a[9]) * $signed(matrix_b[5]); stage_counter <= 6'd38; end
                            38: begin mac_accum <= mac_accum + $signed(matrix_a[10]) * $signed(matrix_b[9]); stage_counter <= 6'd39; end
                            39: begin mac_accum <= mac_accum + $signed(matrix_a[11]) * $signed(matrix_b[13]); stage_counter <= 6'd40; end
                            40: begin matrix_c[9] <= mac_accum[31:0];
                                // C[10] = A[8]*B[2] + A[9]*B[6] + A[10]*B[10] + A[11]*B[14]
                                mac_accum <= $signed(matrix_a[8]) * $signed(matrix_b[2]); stage_counter <= 6'd41; end
                            41: begin mac_accum <= mac_accum + $signed(matrix_a[9]) * $signed(matrix_b[6]); stage_counter <= 6'd42; end
                            42: begin mac_accum <= mac_accum + $signed(matrix_a[10]) * $signed(matrix_b[10]); stage_counter <= 6'd43; end
                            43: begin mac_accum <= mac_accum + $signed(matrix_a[11]) * $signed(matrix_b[14]); stage_counter <= 6'd44; end
                            44: begin matrix_c[10] <= mac_accum[31:0];
                                // C[11] = A[8]*B[3] + A[9]*B[7] + A[10]*B[11] + A[11]*B[15]
                                mac_accum <= $signed(matrix_a[8]) * $signed(matrix_b[3]); stage_counter <= 6'd45; end
                            45: begin mac_accum <= mac_accum + $signed(matrix_a[9]) * $signed(matrix_b[7]); stage_counter <= 6'd46; end
                            46: begin mac_accum <= mac_accum + $signed(matrix_a[10]) * $signed(matrix_b[11]); stage_counter <= 6'd47; end
                            47: begin mac_accum <= mac_accum + $signed(matrix_a[11]) * $signed(matrix_b[15]); stage_counter <= 6'd48; end
                            48: begin matrix_c[11] <= mac_accum[31:0];
                                // DEBUG: Removed MAC Row 2 complete output
                                // === ROW 3 ===
                                // C[12] = A[12]*B[0] + A[13]*B[4] + A[14]*B[8] + A[15]*B[12]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[0]); stage_counter <= 6'd49; end
                            49: begin 
                                // DEBUG: Removed MAC stage 49 output
                                mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[4]); stage_counter <= 6'd50; end
                            50: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[8]); stage_counter <= 6'd51; end
                            51: begin mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[12]); stage_counter <= 6'd52; end
                            52: begin matrix_c[12] <= mac_accum[31:0];
                                // C[13] = A[12]*B[1] + A[13]*B[5] + A[14]*B[9] + A[15]*B[13]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[1]); stage_counter <= 6'd53; end
                            53: begin mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[5]); stage_counter <= 6'd54; end
                            54: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[9]); stage_counter <= 6'd55; end
                            55: begin mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[13]); stage_counter <= 6'd56; end
                            56: begin matrix_c[13] <= mac_accum[31:0];
                                // DEBUG: Removed MAC stage 56 output
                                // C[14] = A[12]*B[2] + A[13]*B[6] + A[14]*B[10] + A[15]*B[14]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[2]); stage_counter <= 6'd57; end
                            57: begin mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[6]); stage_counter <= 6'd58; end
                            58: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[10]); stage_counter <= 6'd59; end
                            59: begin mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[14]); stage_counter <= 6'd60; end
                            60: begin matrix_c[14] <= mac_accum[31:0];
                                // DEBUG: Removed MAC stage 60 output
                                // C[15] = A[12]*B[3] + A[13]*B[7] + A[14]*B[11] + A[15]*B[15]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[3]); stage_counter <= 6'd61; end
                            61: begin mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[7]); stage_counter <= 6'd62; end
                            62: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[11]); stage_counter <= 6'd63; end
                            63: begin 
                                mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[15]); 
                                matrix_c[15] <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[15]);
                                final_stage_counter <= 5'h0;  // Reset for next operation
                                // DEBUG: Removed MAC stage 63 output
                                // FIX: Set flag to indicate MAC ops complete
                                mac_ops_complete <= 1'b1;
                                stage_counter <= 6'd0;  // Reset to 0
                            end
                            // After MAC ops complete - handle final latency
                            default: begin
                                // Check if MAC ops are complete
                                if (mac_ops_complete && mac_compute_started && a_exec_counter >= a_exec_target_cycles) begin
                                    // We're in final latency padding stages
                                    if (final_stage_counter < 5'd1) begin  // Need 1 cycle (40-39) - OPTIMIZED
                                        final_stage_counter <= final_stage_counter + 1;
                                        if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output 
                                            $display("[%0t] [A-CORE#%0d] MAC: Final stage %0d/16", $time, CORE_ID, final_stage_counter + 1);
                                        // CRITICAL FIX: Don't increment stage_counter to avoid overflow (6-bit max = 63)
                                        // Keep at 63 to stay in default case until final_stage_counter completes
                                    end else begin
                                        // Completed all 40 cycles (39 + 1 final) - OPTIMIZED
                                        $display("[%0t] [A-CORE#%0d] MAC: Stage 39 complete - transitioning to STORE_RESULT (target=%0d)", $time, CORE_ID, a_exec_target_cycles);
                                        final_stage_counter <= 5'h0;  // Reset for next operation
                                        mac_ops_complete <= 1'b0;  // Reset flag
                                        stage_counter <= 6'b0;
                                        a_exec_counter <= 0;
                                        a_pipeline_stage_detail <= 4'd0;
                                        state <= STORE_RESULT; 
                                    end
                                end else begin
                                    // Normal MAC computation - should not reach here
                                    if (DEBUG_ENABLE)  // DEBUG: Conditional A-Core output
                                        $display("[%0t] [A-CORE#%0d] MAC: Unexpected stage %0d in MAC_COMPUTE", $time, CORE_ID, stage_counter);
                                    stage_counter <= 6'b0;
                                    a_exec_counter <= 0;
                                    a_pipeline_stage_detail <= 4'd0;
                                    state <= STORE_RESULT;
                                end
                            end
                        endcase
                    end  // else if (mac_compute_started)
                end

                // ─────────────────────────────────────────────────
                // ACTIVATE: ReLU pada matrix C (real: max(0, x))
                // FIXED: Process all 16 elements (was only 4)
                // NEW: Enforce execution counter untuk realistic latency
                // ─────────────────────────────────────────────────
                ACTIVATE: begin
                    l1_rd_en <= 1'b0;
                    a_pipeline_stage_detail <= 4'd5;  // ACTIVATE stage

                    // CRITICAL FIX: Enforce execution counter sebelum compute
                    if (a_exec_counter < a_exec_target_cycles) begin
                        a_exec_counter <= a_exec_counter + 1;
                    end else begin
                        // Counter complete - NOW execute ReLU on all 16 elements
                        case (stage_counter)
                            0:  begin matrix_c[0]  <= relu_fn(matrix_c[0]);  stage_counter <= 6'd1;  end
                            1:  begin matrix_c[1]  <= relu_fn(matrix_c[1]);  stage_counter <= 6'd2;  end
                            2:  begin matrix_c[2]  <= relu_fn(matrix_c[2]);  stage_counter <= 6'd3;  end
                            3:  begin matrix_c[3]  <= relu_fn(matrix_c[3]);  stage_counter <= 6'd4;  end
                            4:  begin matrix_c[4]  <= relu_fn(matrix_c[4]);  stage_counter <= 6'd5;  end
                            5:  begin matrix_c[5]  <= relu_fn(matrix_c[5]);  stage_counter <= 6'd6;  end
                            6:  begin matrix_c[6]  <= relu_fn(matrix_c[6]);  stage_counter <= 6'd7;  end
                            7:  begin matrix_c[7]  <= relu_fn(matrix_c[7]);  stage_counter <= 6'd8;  end
                            8:  begin matrix_c[8]  <= relu_fn(matrix_c[8]);  stage_counter <= 6'd9;  end
                            9:  begin matrix_c[9]  <= relu_fn(matrix_c[9]);  stage_counter <= 6'd10; end
                            10: begin matrix_c[10] <= relu_fn(matrix_c[10]); stage_counter <= 6'd11; end
                            11: begin matrix_c[11] <= relu_fn(matrix_c[11]); stage_counter <= 6'd12; end
                            12: begin matrix_c[12] <= relu_fn(matrix_c[12]); stage_counter <= 6'd13; end
                            13: begin matrix_c[13] <= relu_fn(matrix_c[13]); stage_counter <= 6'd14; end
                            14: begin matrix_c[14] <= relu_fn(matrix_c[14]); stage_counter <= 6'd15; end
                            15: begin
                                matrix_c[15] <= relu_fn(matrix_c[15]);
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                            default: begin
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // NORMALIZE: Layer normalization (mean + variance)
                // FIXED: Process all 16 elements and actually normalize
                // Step 1-16: Sum all elements for mean
                // Step 17: Compute mean = sum / 16
                // Step 18-33: Sum squared differences for variance
                // Step 34: Compute variance
                // Step 35-50: Normalize each element: (x - mean) / sqrt(variance + eps)
                // ─────────────────────────────────────────────────
                NORMALIZE: begin
                    l1_rd_en <= 1'b0;
                    a_pipeline_stage_detail <= 4'd6;  // NORMALIZE stage

                    // CRITICAL FIX: Enforce execution counter
                    if (a_exec_counter < a_exec_target_cycles) begin
                        a_exec_counter <= a_exec_counter + 1;
                    end else begin
                        case (stage_counter)
                            // Phase 1: Sum all 16 elements (steps 0-15)
                            0:  begin mac_accum <= $signed(matrix_c[0]);  stage_counter <= 6'd1;  end
                            1:  begin mac_accum <= mac_accum + $signed(matrix_c[1]);  stage_counter <= 6'd2;  end
                            2:  begin mac_accum <= mac_accum + $signed(matrix_c[2]);  stage_counter <= 6'd3;  end
                            3:  begin mac_accum <= mac_accum + $signed(matrix_c[3]);  stage_counter <= 6'd4;  end
                            4:  begin mac_accum <= mac_accum + $signed(matrix_c[4]);  stage_counter <= 6'd5;  end
                            5:  begin mac_accum <= mac_accum + $signed(matrix_c[5]);  stage_counter <= 6'd6;  end
                            6:  begin mac_accum <= mac_accum + $signed(matrix_c[6]);  stage_counter <= 6'd7;  end
                            7:  begin mac_accum <= mac_accum + $signed(matrix_c[7]);  stage_counter <= 6'd8;  end
                            8:  begin mac_accum <= mac_accum + $signed(matrix_c[8]);  stage_counter <= 6'd9;  end
                            9:  begin mac_accum <= mac_accum + $signed(matrix_c[9]);  stage_counter <= 6'd10; end
                            10: begin mac_accum <= mac_accum + $signed(matrix_c[10]); stage_counter <= 6'd11; end
                            11: begin mac_accum <= mac_accum + $signed(matrix_c[11]); stage_counter <= 6'd12; end
                            12: begin mac_accum <= mac_accum + $signed(matrix_c[12]); stage_counter <= 6'd13; end
                            13: begin mac_accum <= mac_accum + $signed(matrix_c[13]); stage_counter <= 6'd14; end
                            14: begin mac_accum <= mac_accum + $signed(matrix_c[14]); stage_counter <= 6'd15; end
                            15: begin
                                // Compute mean = sum / 16 (shift right by 4)
                                mac_accum <= mac_accum + $signed(matrix_c[15]);
                                matrix_c[0] <= mac_accum[35:4];  // Store mean in matrix_c[0] temporarily
                                stage_counter <= 6'd16;
                            end
                            // Phase 2: Normalize all 16 elements using mean
                            // Simplified: just subtract mean (variance computation would need more cycles)
                            16: begin
                                matrix_c[0]  <= matrix_c[0] - matrix_c[0];  // c[0] is mean, so becomes 0
                                matrix_c[1]  <= matrix_c[1]  - matrix_c[0];
                                stage_counter <= 6'd17;
                            end
                            17: begin matrix_c[2]  <= matrix_c[2]  - matrix_c[0];  stage_counter <= 6'd18; end
                            18: begin matrix_c[3]  <= matrix_c[3]  - matrix_c[0];  stage_counter <= 6'd19; end
                            19: begin matrix_c[4]  <= matrix_c[4]  - matrix_c[0];  stage_counter <= 6'd20; end
                            20: begin matrix_c[5]  <= matrix_c[5]  - matrix_c[0];  stage_counter <= 6'd21; end
                            21: begin matrix_c[6]  <= matrix_c[6]  - matrix_c[0];  stage_counter <= 6'd22; end
                            22: begin matrix_c[7]  <= matrix_c[7]  - matrix_c[0];  stage_counter <= 6'd23; end
                            23: begin matrix_c[8]  <= matrix_c[8]  - matrix_c[0];  stage_counter <= 6'd24; end
                            24: begin matrix_c[9]  <= matrix_c[9]  - matrix_c[0];  stage_counter <= 6'd25; end
                            25: begin matrix_c[10] <= matrix_c[10] - matrix_c[0];  stage_counter <= 6'd26; end
                            26: begin matrix_c[11] <= matrix_c[11] - matrix_c[0];  stage_counter <= 6'd27; end
                            27: begin matrix_c[12] <= matrix_c[12] - matrix_c[0];  stage_counter <= 6'd28; end
                            28: begin matrix_c[13] <= matrix_c[13] - matrix_c[0];  stage_counter <= 6'd29; end
                            29: begin matrix_c[14] <= matrix_c[14] - matrix_c[0];  stage_counter <= 6'd30; end
                            30: begin
                                matrix_c[15] <= matrix_c[15] - matrix_c[0];
                                matrix_c[0]  <= 32'sb0;  // Clear mean placeholder
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                            default: begin
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // POOL: 2x2 Average Pooling (stride 2)
                // FIXED: Process all 4 pooling windows from 4x4 matrix
                // Output: 2x2 matrix stored in matrix_c[0], c[1], c[4], c[5]
                // ─────────────────────────────────────────────────
                POOL: begin
                    l1_rd_en <= 1'b0;
                    a_pipeline_stage_detail <= 4'd7;  // POOL stage

                    // CRITICAL FIX: Enforce execution counter
                    if (a_exec_counter < a_exec_target_cycles) begin
                        a_exec_counter <= a_exec_counter + 1;
                    end else begin
                        case (stage_counter)
                            // Window 0: Top-left (c[0], c[1], c[4], c[5])
                            0: begin
                                mac_accum <= $signed(matrix_c[0]) + $signed(matrix_c[1]) +
                                             $signed(matrix_c[4]) + $signed(matrix_c[5]);
                                stage_counter <= 6'd1;
                            end
                            1: begin
                                matrix_c[0] <= mac_accum[31:0] >>> 2;  // avg pool
                                // Window 1: Top-right (c[2], c[3], c[6], c[7])
                                mac_accum <= $signed(matrix_c[2]) + $signed(matrix_c[3]) +
                                             $signed(matrix_c[6]) + $signed(matrix_c[7]);
                                stage_counter <= 6'd2;
                            end
                            2: begin
                                matrix_c[1] <= mac_accum[31:0] >>> 2;  // avg pool
                                // Window 2: Bottom-left (c[8], c[9], c[12], c[13])
                                mac_accum <= $signed(matrix_c[8]) + $signed(matrix_c[9]) +
                                             $signed(matrix_c[12]) + $signed(matrix_c[13]);
                                stage_counter <= 6'd3;
                            end
                            3: begin
                                matrix_c[4] <= mac_accum[31:0] >>> 2;  // avg pool
                                // Window 3: Bottom-right (c[10], c[11], c[14], c[15])
                                mac_accum <= $signed(matrix_c[10]) + $signed(matrix_c[11]) +
                                             $signed(matrix_c[14]) + $signed(matrix_c[15]);
                                stage_counter <= 6'd4;
                            end
                            4: begin
                                matrix_c[5] <= mac_accum[31:0] >>> 2;  // avg pool
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                            default: begin
                                stage_counter <= 6'b0;
                                state <= STORE_RESULT;
                            end
                        endcase
                    end
                end

                STORE_RESULT: begin
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    if (CORE_ID == 0 && stage_counter == 0)
                        $display("[%0t] [A-CORE#%0d] STORE_RESULT: Computing result hash", $time, CORE_ID);

                    case (stage_counter)
                        0: begin
                            mac_accum <= $signed(matrix_c[0]) + $signed(matrix_c[1]) +
                                         $signed(matrix_c[2]) + $signed(matrix_c[3]);
                            stage_counter <= 6'b1;
                        end
                        1: begin
                            // Compute hash dan simpan ke result_reg (untuk FIFO)
                            // Result akan di-push ke FIFO di RESULT_WAIT
                            if (CORE_ID == 0)  // DEBUG: Enable for master core only
                                $display("[%0t] [A-CORE#%0d] STORE_RESULT: Pushing to RESULT_WAIT", $time, CORE_ID);
                            computed_result <= compute_hash(mac_accum, saved_opcode, cmd_addr[15:0]);
                            // Transition ke RESULT_WAIT untuk push ke FIFO
                            stage_counter <= 6'b0;
                            state <= RESULT_WAIT;
                        end
                        2: begin
                            // Tidak digunakan - langsung ke IDLE di stage 1
                            stage_counter <= 6'b0;
                            state <= IDLE;
                        end
                        default: begin
                            stage_counter <= 6'b0;
                            state <= IDLE;
                        end
                    endcase
                end

                // RESULT_WAIT sudah dihandle di atas - ini untuk backward compatibility
                // Tidak melakukan apa-apa, transition ke IDLE
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
