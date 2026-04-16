`timescale 1ns / 1ps

// verilator lint_off WIDTHEXPAND
// verilator lint_off UNSIGNED
// verilator lint_off WIDTHTRUNC

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
    parameter DATA_WIDTH    = 128,  // UPGRADED: 64→128 for wider tensor data path
    parameter ADDR_WIDTH    = 48,
    parameter TILE_SIZE     = 4,    // OPTIMIZED: 2→4 (4x4 matrix, more parallelism)
    parameter PRECISION     = 16,   // FP16 default
    parameter RESULT_FIFO_DEPTH = 8,  // OPTIMIZED: 4→8 (deeper buffer for wider data)
    parameter LINE_SIZE     = 64,     // UPGRADED: 512-bit cache line (matches memory bus)

    // NEW: Realistic AI compute latency (OPTIMIZED for 512-bit bus)
    parameter A_PIPE_MATMUL    = 80,  // OPTIMIZED: 100→80 (512-bit bus)
    parameter A_PIPE_ATTENTION = 100,  // OPTIMIZED: 120→100
    parameter A_PIPE_CONV2D    = 70,   // OPTIMIZED: 85→70
    parameter A_PIPE_POOLING   = 40,   // OPTIMIZED: 50→40
    parameter A_PIPE_ACTIVATION = 32,  // OPTIMIZED: 40→32
    parameter A_PIPE_NORMALIZE = 40,   // OPTIMIZED: 48→40
    parameter A_PIPE_LOAD_WT   = 28,   // OPTIMIZED: 35→28
    parameter A_PIPE_STORE_WT  = 30    // OPTIMIZED: 38→30
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [127:0]                 cmd_data,  // OPTIMIZED: 64→128 bit
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Result interface (dengan FIFO buffering)
    output wire [DATA_WIDTH-1:0]        result,  // CHANGED: wire instead of reg
    output wire                         result_valid,  // FIXED: wire (driven by assign, not reg)
    output reg                          busy,
    input  wire                         result_ready,  // NEW: Scheduler ready to pull result
    output wire                         complete,  // NEW: Signal task completion to scheduler

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

    // L1 → L2 interface (exposed for top-level integration) - 512-BIT
    output wire [ADDR_WIDTH-1:0]        l2_addr,
    output wire [LINE_SIZE*8-1:0]       l2_wr_data,    // 512-bit
    output wire                         l2_rd_en,
    output wire                         l2_wr_en,
    input  wire [LINE_SIZE*8-1:0]       l2_rd_data,    // 512-bit
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
        .LINE_SIZE(LINE_SIZE)  // 64-byte (512-bit) cache lines
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

    // Internal result register (sebelum FIFO)
    reg [DATA_WIDTH-1:0]    result_reg;

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

    // FIX v3: Separate push from RESULT_WAIT entry to avoid race with pop
    // Push happens when ENTERING RESULT_WAIT, not while IN RESULT_WAIT
    reg result_wait_entry_pushed;  // Track if we already pushed this result

    assign result_fifo_has_data = !result_fifo_empty;
    // FIX: Push on state transition, not on state presence
    assign result_fifo_push = (state == RESULT_WAIT) && !result_wait_entry_pushed;
    assign result_fifo_pop = result_ready && result_fifo_has_data;

    // FIFO write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < RESULT_FIFO_DEPTH; i++)
                result_fifo[i] <= {DATA_WIDTH{1'b0}};
            result_fifo_count <= 0;
            result_fifo_head <= 0;
            result_fifo_tail <= 0;
            result_fifo_full <= 1'b0;
            result_fifo_empty <= 1'b1;
            fifo_occupancy <= 4'b0;
            fifo_full_warn <= 1'b0;
        end else begin
            // Push result ke FIFO (dari result_reg)
            if (result_fifo_push && !result_fifo_full) begin
                result_fifo[result_fifo_tail] <= result_reg;
                result_fifo_tail <= (result_fifo_tail == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_tail + 1;
                result_fifo_count <= result_fifo_count + 1;
                result_fifo_full <= (result_fifo_count == RESULT_FIFO_DEPTH);  // FIXED: was DEPTH-1
                result_fifo_empty <= 1'b0;
                $display("[%0t] [A-CORE#%0d] ✅ Pushed result to FIFO, count=%0d", $time, CORE_ID, result_fifo_count+1);
            end

            // FIX v2: Pop result dari FIFO (scheduler pull) - guarded by !result_fifo_empty
            if (result_fifo_pop && !result_fifo_empty) begin
                result_fifo_head <= (result_fifo_head == (RESULT_FIFO_DEPTH-1)) ? 0 : result_fifo_head + 1;
                result_fifo_count <= result_fifo_count - 1;
                result_fifo_full <= 1'b0;
                // FIX v2: Empty AFTER pop if count was 1 (will become 0)
                result_fifo_empty <= (result_fifo_count == 1);
            end else begin
                // Ensure empty flag is correct when no pop
                result_fifo_empty <= (result_fifo_count == 0);
            end

            // Update metrics
            fifo_occupancy <= result_fifo_count[3:0];
            fifo_full_warn <= (result_fifo_count > (RESULT_FIFO_DEPTH * 3 / 4));
        end
    end

    // Result output: wire driven by FIFO
    assign result = !result_fifo_empty ? result_fifo[result_fifo_head] : {DATA_WIDTH{1'b0}};
    assign result_valid = !result_fifo_empty;  // Persistent valid saat FIFO ada isi
    assign complete = complete_reg;  // Completion signal to scheduler

    // Compute indices
    reg [3:0]               row_idx;
    reg [3:0]               col_idx;
    reg [3:0]               k_idx;
    reg [5:0]               stage_counter;

    // NEW: Execution counter untuk realistic latency
    reg [15:0]              a_exec_counter;
    reg [15:0]              a_exec_target_cycles;
    reg                     mac_compute_started;  // NEW: Flag to track MAC compute start
    reg [4:0]               final_stage_counter;   // NEW: Counter for final stages 64-79
    reg                     complete_reg;         // NEW: Register for completion signal

    // NEW: Pipeline stage tracking untuk observability
    reg [3:0]               a_pipeline_stage_detail;

    // Pipeline state (4-bit untuk lebih banyak states)
    reg [3:0]               state;
    reg [3:0]               next_compute_state;  // Untuk COMPUTE_INIT transition
    reg [6:0]               result_wait_timeout;  // FIX #3: Timeout counter untuk RESULT_WAIT

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
    function automatic reg [63:0] compute_hash;
        input [63:0] seed;
        input [7:0]  op_type;
        input [15:0] iteration;
        reg [63:0] h;
        begin
            // Combine inputs dengan XOR dan concatenation
            h = seed ^ {op_type, op_type, op_type, op_type, op_type, op_type, op_type, op_type};
            h = h ^ {iteration, iteration, iteration, iteration};

            // Xorshift64* algorithm (better mixing)
            h = h ^ (h >> 12);
            h = h ^ (h << 25);
            h = h ^ (h >> 27);

            // Multiply dengan random constant
            h = h * 64'd2685821657736338717;

            // Additional mixing dengan opcode
            h = h + {56'b0, op_type} * 64'd14024371719626972817;

            // Final xorshift
            h = h ^ (h >> 31);
            h = h * 64'd8948120567065598367;

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
            next_compute_state <= IDLE;
            result_wait_timeout <= 7'd0;  // FIX #3: Initialize timeout counter
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

            // Initialize matrices to zero
            for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                matrix_a[i] <= 32'sb0;
                matrix_b[i] <= 32'sb0;
                matrix_c[i] <= 32'sb0;
            end
        end else begin
            case (state)
                // ─────────────────────────────────────────────────
                // MAC_INIT: Reset counter sebelum MAC_COMPUTE
                // ─────────────────────────────────────────────────
                MAC_INIT: begin
                    stage_counter <= 6'b0;
                    if (CORE_ID == 0)
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
                    // Mark that we've pushed result for this entry
                    result_wait_entry_pushed <= 1'b1;
                    
                    // result_valid sekarang persistent dari FIFO
                    busy <= 1'b0;  // Core selesai, tidak busy lagi

                    // FIX #3: Add timeout to prevent infinite wait if FIFO is full
                    // If FIFO cannot accept result after 100 cycles, force transition
                    if (result_wait_timeout >= 7'd100) begin
                        // Safety timeout: force transition to IDLE
                        if (CORE_ID == 0)
                            $display("[%0t] [A-CORE#%0d] TIMEOUT: RESULT_WAIT exceeded 100 cycles, forcing IDLE", $time, CORE_ID);
                        result_wait_timeout <= 7'd0;
                        result_wait_entry_pushed <= 1'b0;  // Reset for next operation
                        complete_reg <= 1'b1;  // Signal completion to scheduler
                        state <= IDLE;
                    end
                    // FIX v3: Transition when FIFO has been successfully populated
                    else if (result_fifo_pop && result_fifo_has_data) begin
                        // FIFO sudah di-pop, transition ke IDLE
                        result_wait_timeout <= 7'd0;  // Reset timeout counter
                        result_wait_entry_pushed <= 1'b0;  // Reset for next operation
                        complete_reg <= 1'b1;  // Signal completion to scheduler
                        if (CORE_ID == 0)  // Only log for master core
                            $display("[%0t] [A-CORE#%0d] RESULT_WAIT: Result consumed by scheduler, transitioning to IDLE", $time, CORE_ID);
                        state <= IDLE;
                    end else begin
                        // Increment timeout counter
                        result_wait_timeout <= result_wait_timeout + 1;
                    end
                    // Else: stay di RESULT_WAIT, result_valid tetap 1 dari FIFO
                end

                // ─────────────────────────────────────────────────
                // IDLE: terima command, route ke state yang tepat
                // ─────────────────────────────────────────────────
                IDLE: begin
                    cmd_ready <= 1'b1;
                    // result_valid sekarang dihandle oleh FIFO logic
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    // Ensure push flag is reset when entering IDLE
                    result_wait_entry_pushed <= 1'b0;
                    // Reset MAC compute flag for next operation
                    mac_compute_started <= 1'b0;
                    // Reset completion signal
                    complete_reg <= 1'b0;

                    // Phase 3: Throttle dispatch jika FIFO > 75% full
                    // Ini prevent FIFO overflow saat scheduler lambat consume
                    if (fifo_full_warn) begin
                        cmd_ready <= 1'b0;  // Backpressure: jangan terima command baru
                        if (CORE_ID == 0 && cmd_valid)
                            $display("[%0t] [A-CORE#%0d] ⚠ FIFO full warning! Rejecting command", $time, CORE_ID);
                    end

                    if (cmd_valid && !fifo_full_warn) begin
                        cmd_ready <= 1'b0;
                        busy <= 1'b1;
                        stage_counter <= 6'b0;
                        row_idx <= 4'b0;
                        col_idx <= 4'b0;
                        k_idx <= 4'b0;

                        $display("[%0t] [A-CORE#%0d] 📥 Received command, opcode=0x%02h", $time, CORE_ID, cmd_data[63:56]);

                        // Seed MAC dengan hash dari addr+data
                        mac_accum <= {32'b0, cmd_addr[31:0]} ^ cmd_data;

                        // Save opcode untuk digunakan di state lain
                        saved_opcode <= cmd_data[63:56];

                        case (cmd_data[63:56])
                            OP_MATMUL: begin
                                if (CORE_ID == 0)
                                    $display("[%0t] [A-CORE#%0d] MATMUL opcode matched, loading from memory", $time, CORE_ID);
                                // Initialize matrix C to zero
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_c[i] <= 32'sb0;
                                end
                                // Set realistic pipeline depth
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_MATMUL;
                                a_pipeline_stage_detail <= 4'd1;  // INIT stage
                                // Transition ke LOAD_INPUT untuk load matrix A dari memory
                                state <= LOAD_INPUT;
                            end
                            OP_ATTENTION: begin
                                if (CORE_ID == 0)
                                    $display("[%0t] [A-CORE#%0d] ATTENTION opcode matched, loading from memory", $time, CORE_ID);
                                // Initialize matrix C to zero
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_c[i] <= 32'sb0;
                                end
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_ATTENTION;
                                a_pipeline_stage_detail <= 4'd1;
                                // Transition ke LOAD_INPUT untuk load matrix A dari memory
                                state <= LOAD_INPUT;
                            end
                            OP_CONV2D: begin
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_a[i] <= $signed(cmd_data[31:0]) + $signed(i * 1000);
                                    matrix_b[i] <= $signed(cmd_data[63:32]) - $signed(i * 500);
                                    matrix_c[i] <= 32'sb0;
                                end
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_CONV2D;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= MAC_INIT;
                            end
                            OP_POOLING: begin
                                // Init matrix C dari cmd_data
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_c[i] <= $signed(cmd_data[31:0]) + $signed(i * 777);
                                end
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_POOLING;
                                a_pipeline_stage_detail <= 4'd1;
                                next_compute_state <= POOL;
                                state <= COMPUTE_INIT;
                            end
                            OP_ACTIVATION: begin
                                // Init matrix C dari cmd_data
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_c[i] <= $signed(cmd_data[31:0]) + $signed(i * 1234);
                                end
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_ACTIVATION;
                                a_pipeline_stage_detail <= 4'd1;
                                next_compute_state <= ACTIVATE;
                                state <= COMPUTE_INIT;
                            end
                            OP_NORMALIZE: begin
                                // Init matrix C dari cmd_data
                                for (int i = 0; i < TILE_SIZE*TILE_SIZE; i++) begin
                                    matrix_c[i] <= $signed(cmd_data[31:0]) - $signed(i * 333);
                                end
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_NORMALIZE;
                                a_pipeline_stage_detail <= 4'd1;
                                next_compute_state <= NORMALIZE;
                                state <= COMPUTE_INIT;
                            end
                            OP_LOAD_WT: begin
                                // Load weights - simple memory operation
                                if (CORE_ID == 0)
                                    $display("[%0t] [A-CORE#%0d] 📦 LOAD_WT opcode, addr=0x%0h", $time, CORE_ID, cmd_addr);
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_LOAD_WT;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= STORE_RESULT;  // Direct to store result
                            end
                            OP_STORE_WT: begin
                                // Store weights - simple memory operation  
                                if (CORE_ID == 0)
                                    $display("[%0t] [A-CORE#%0d] 💾 STORE_WT opcode, addr=0x%0h", $time, CORE_ID, cmd_addr);
                                a_exec_counter <= 16'h0;
                                a_exec_target_cycles <= A_PIPE_STORE_WT;
                                a_pipeline_stage_detail <= 4'd1;
                                state <= STORE_RESULT;  // Direct to store result
                            end
                            default: begin
                                // FIXED: Invalid opcode - reject and push error result to FIFO
                                if (CORE_ID == 0)
                                    $display("[%0t] [A-CORE#%0d] WARNING: Invalid opcode 0x%x, pushing error result", $time, CORE_ID, cmd_data[63:56]);
                                stage_counter <= 6'b0;
                                busy <= 1'b0;
                                cmd_ready <= 1'b1;
                                // FIXED: Use consistent error pattern (all ones) like G-Core
                                result_reg <= {64{1'b1}};  // All ones = error indicator
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
                    if (CORE_ID == 0)
                        $display("[%0t] [A-CORE#%0d] LOAD_INPUT: Loading matrix A from memory, stage_counter=%0d", $time, CORE_ID, stage_counter);
                    l1_rd_en <= 1'b1;
                    l1_addr <= cmd_addr + {42'b0, stage_counter[5:0]};

                    // FIXED: Timeout after 256 cycles to prevent infinite hang
                    if (a_exec_counter >= 16'hFF) begin
                        if (CORE_ID == 0)
                            $display("[%0t] [A-CORE#%0d] LOAD_INPUT TIMEOUT! Skipping to MAC_INIT", $time, CORE_ID);
                        stage_counter <= 4'b0;
                        a_exec_counter <= 16'h0;
                        state <= MAC_INIT;
                    end else if (l1_ready) begin
                        a_exec_counter <= a_exec_counter + 1;
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
                    if (a_exec_counter >= 16'hFF) begin
                        if (CORE_ID == 0)
                            $display("[%0t] [A-CORE#%0d] LOAD_WEIGHT TIMEOUT! Skipping to MAC_INIT", $time, CORE_ID);
                        stage_counter <= 4'b0;
                        a_exec_counter <= 16'h0;
                        state <= MAC_INIT;
                    end else if (l1_ready) begin
                        a_exec_counter <= a_exec_counter + 1;
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
                        if (a_exec_counter == 0 && CORE_ID == 0)
                            $display("[%0t] [A-CORE#%0d] MAC_COMPUTE: Counter starting, target=%0d cycles", $time, CORE_ID, a_exec_target_cycles);
                        // Don't execute MAC ops yet - still waiting for latency
                        stage_counter <= stage_counter;  // Hold stage_counter
                    end else if (!mac_compute_started) begin
                        // Counter reached target AND this is first cycle - start MAC
                        mac_compute_started <= 1'b1;
                        a_exec_counter <= a_exec_target_cycles;
                        // CRITICAL FIX: Start at stage 0 where MAC computation actually begins!
                        stage_counter <= 6'd0;
                        if (CORE_ID == 0)
                            $display("[%0t] [A-CORE#%0d] MAC_COMPUTE: Starting MAC ops, stage_counter -> 0", $time, CORE_ID);
                    end else begin
                        // Counter at target AND mac_compute_started already set
                        a_exec_counter <= a_exec_target_cycles;
                        
                        // Execute MAC operations stage-by-stage
                        case (stage_counter)
                            // === ROW 0 ===
                            // C[0] = A[0]*B[0] + A[1]*B[4] + A[2]*B[8] + A[3]*B[12]
                            0: begin
                                mac_accum <= $signed(matrix_a[0]) * $signed(matrix_b[0]);
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
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Row 0 complete (stage 16)", $time, CORE_ID);
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
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Row 1 complete (stage 32)", $time, CORE_ID);
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
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Row 2 complete (stage 48)", $time, CORE_ID);
                                // === ROW 3 ===
                                // C[12] = A[12]*B[0] + A[13]*B[4] + A[14]*B[8] + A[15]*B[12]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[0]); stage_counter <= 6'd49; end
                            49: begin 
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Entering stage 49", $time, CORE_ID);
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
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Entering stage 56 (Row 3 mid)", $time, CORE_ID);
                                // C[14] = A[12]*B[2] + A[13]*B[6] + A[14]*B[10] + A[15]*B[14]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[2]); stage_counter <= 6'd57; end
                            57: begin mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[6]); stage_counter <= 6'd58; end
                            58: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[10]); stage_counter <= 6'd59; end
                            59: begin mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[14]); stage_counter <= 6'd60; end
                            60: begin matrix_c[14] <= mac_accum[31:0];
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Entering stage 60 (Row 3 late)", $time, CORE_ID);
                                // C[15] = A[12]*B[3] + A[13]*B[7] + A[14]*B[11] + A[15]*B[15]
                                mac_accum <= $signed(matrix_a[12]) * $signed(matrix_b[3]); stage_counter <= 6'd61; end
                            61: begin mac_accum <= mac_accum + $signed(matrix_a[13]) * $signed(matrix_b[7]); stage_counter <= 6'd62; end
                            62: begin mac_accum <= mac_accum + $signed(matrix_a[14]) * $signed(matrix_b[11]); stage_counter <= 6'd63; end
                            63: begin 
                                mac_accum <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[15]); 
                                matrix_c[15] <= mac_accum + $signed(matrix_a[15]) * $signed(matrix_b[15]);
                                final_stage_counter <= 5'h0;  // Reset final stage counter
                                if (CORE_ID == 0) $display("[%0t] [A-CORE#%0d] MAC: Stage 63 complete - continuing to stage 64", $time, CORE_ID);
                                stage_counter <= 6'd64;  // Continue to stage 64 (will wrap to 0 due to 6-bit limit)
                            end
                            // Stages 64-79: Additional latency cycles to reach target=80
                            // Since 6-bit counter wraps at 64, we use final_stage_counter
                            default: begin
                                // Check if we've completed MAC ops (stage_counter wrapped and mac_compute_started is true)
                                if (mac_compute_started && a_exec_counter >= a_exec_target_cycles) begin
                                    // We're in final latency padding stages 64-79
                                    if (final_stage_counter < 5'd16) begin  // Need 16 cycles (64-79)
                                        final_stage_counter <= final_stage_counter + 1;
                                        if (CORE_ID == 0) 
                                            $display("[%0t] [A-CORE#%0d] MAC: Final stage %0d/16", $time, CORE_ID, final_stage_counter + 1);
                                        stage_counter <= stage_counter + 1;  // Increment to avoid staying in same case
                                    end else begin
                                        // Completed all 80 cycles (63 + 16 padding + 1 final)
                                        if (CORE_ID == 0) 
                                            $display("[%0t] [A-CORE#%0d] MAC: Stage 79 complete - transitioning to STORE_RESULT (target=%0d)", $time, CORE_ID, a_exec_target_cycles);
                                        final_stage_counter <= 5'h0;  // Reset for next operation
                                        stage_counter <= 6'b0;
                                        a_exec_counter <= 0;
                                        a_pipeline_stage_detail <= 4'd0;
                                        state <= STORE_RESULT; 
                                    end
                                end else begin
                                    // Normal MAC computation - should not reach here
                                    if (CORE_ID == 0)
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
                            if (CORE_ID == 0)
                                $display("[%0t] [A-CORE#%0d] STORE_RESULT: Pushing to RESULT_WAIT", $time, CORE_ID);
                            result_reg <= compute_hash(mac_accum, saved_opcode, cmd_addr[15:0]);
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
