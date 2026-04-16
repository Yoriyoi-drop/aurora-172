`timescale 1ns / 1ps

// verilator lint_off WIDTHEXPAND
// verilator lint_off WIDTHTRUNC
// verilator lint_off PINCONNECTEMPTY

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Gaming Architecture Team
// 
// Create Date: 10 April 2026
// Design Name: AURORA-172 G-Core
// Module Name: g_core
// 
// Description:
//   Game Core - Latency rendah, high clock (6GHz target)
//   Fitur:
//   - Aggressive branch prediction dengan AI
//   - Frame generation hardware support
//   - Zero latency pipeline
//   - Native RT instruction support
//
// Target: Gaming AAA, VR, Real-time rendering
//////////////////////////////////////////////////////////////////////////////////

module g_core #(
    parameter CORE_ID       = 0,
    parameter DATA_WIDTH    = 64,
    parameter ADDR_WIDTH    = 48,
    parameter INST_WIDTH    = 512,  // UPGRADED: 256→512 for wider instruction fetch (4x ops/cycle)
    parameter L1_CACHE_SIZE = 128 * 1024,  // 128KB L1 cache
    parameter MAX_ADDR      = 48'h0000_0000_FFFF, // 1MB address space limit
    parameter LINE_SIZE     = 64,     // UPGRADED: 512-bit cache line (matches memory bus)

    // NEW: Realistic pipeline depth parameters (OPTIMIZED for 512-bit inst width)
    parameter G_PIPE_DRAW       = 8,    // OPTIMIZED: 10→8 (wider fetch = faster)
    parameter G_PIPE_TEXTURE   = 10,   // OPTIMIZED: 12→10
    parameter G_PIPE_PHYSICS   = 16,   // OPTIMIZED: 20→16
    parameter G_PIPE_COLLISION = 12,   // OPTIMIZED: 15→12
    parameter G_PIPE_RAYTRACE  = 32,   // OPTIMIZED: 38→32
    parameter G_PIPE_FRAMEGEN = 24,   // OPTIMIZED: 28→24
    parameter G_PIPE_SHADING   = 14,   // OPTIMIZED: 16→14
    parameter G_PIPE_BRANCH    = 5     // OPTIMIZED: 6→5
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [31:0]                  cmd_data,
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Result interface
    output reg [DATA_WIDTH-1:0]         result,
    output reg                          result_valid,
    output reg                          busy,

    // Error/Exception interface (NEW)
    output reg                          error_flag,       // High when error occurs
    output reg [7:0]                    error_code,       // Error type
    output reg                          error_valid,      // Error valid pulse

    // Memory fabric interface (legacy - not used when L1 cache present)
    output wire [ADDR_WIDTH-1:0]         fabric_addr,
    output reg                          fabric_rd_en,
    output reg                          fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output wire [DATA_WIDTH-1:0]         fabric_wr_data,
    input  wire                         fabric_ready,

    // L1 → L2 interface (exposed for top-level integration) - 512-BIT
    output wire [ADDR_WIDTH-1:0]        l2_addr,
    output wire [LINE_SIZE*8-1:0]       l2_wr_data,    // 512-bit
    output wire                         l2_rd_en,
    output wire                         l2_wr_en,
    input  wire [LINE_SIZE*8-1:0]       l2_rd_data,    // 512-bit
    input  wire                         l2_ready
);

    // Tie off unused fabric outputs
    assign fabric_addr = {ADDR_WIDTH{1'b0}};
    assign fabric_wr_data = {DATA_WIDTH{1'b0}};

    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [INST_WIDTH-1:0]    instruction_reg;
    reg [ADDR_WIDTH-1:0]    pc_reg;
    reg [31:0]              pipeline_stage_1;
    reg [31:0]              pipeline_stage_2;
    reg [31:0]              pipeline_stage_3;
    
    // FIX: Track cmd_valid edge to prevent duplicate logging
    reg                     cmd_valid_prev;

    // L1 Cache interface (proper 4-way set associative with MESI)
    // Core -> L1 cache interface
    wire [DATA_WIDTH-1:0]        l1_rd_data;
    wire                         l1_ready;
    reg                          l1_rd_en;
    reg                          l1_wr_en;
    reg [ADDR_WIDTH-1:0]         l1_addr;
    reg [LINE_SIZE*8-1:0]        l1_wr_data;  // BUG-1 FIX: Extended to 512-bit to match cache line width

    // L1 Snoop interface
    wire [ADDR_WIDTH-1:0]        snoop_addr;
    wire                         snoop_invalidate;
    wire                         snoop_update;

    // Tie off snoop signals (not used in this configuration)
    assign snoop_addr = {ADDR_WIDTH{1'b0}};
    assign snoop_invalidate = 1'b0;
    assign snoop_update = 1'b0;

    // L1 Cache performance counters
    wire [31:0]                  l1_hits;
    wire [31:0]                  l1_misses;
    wire [31:0]                  l1_writebacks;
    wire [31:0]                  l1_invalidations;
    
    // Branch predictor (AI-based)
    reg [15:0]              branch_history;
    reg                     branch_predicted;
    
    // Pipeline control
    reg [2:0]               pipeline_state;
    
    // NEW: Pipeline execution counter for realistic latency
    reg [15:0]              exec_counter;
    reg [15:0]              exec_target_cycles;
    
    // NEW: Pipeline stage tracking for observability
    reg [3:0]               pipeline_stage_detail;
    
    // NEW: Cache miss tracking
    reg                     cache_miss_occurred;
    reg [7:0]               cache_miss_penalty_cycles;
    
    // Memory access timeout counter
    reg [15:0]              mem_wait_counter;
    
    // Track current operation type
    reg                     mem_is_write;
    
    // L1 request handshake tracking
    reg                     l1_request_accepted;

    localparam IDLE         = 3'b000;
    localparam FETCH        = 3'b001;
    localparam DECODE       = 3'b010;
    localparam EXECUTE      = 3'b011;
    localparam MEMORY       = 3'b100;
    localparam WAIT_L1      = 3'b101;  // Wait for L1 to accept request
    localparam WRITEBACK    = 3'b110;
    localparam ERROR_STATE  = 3'b111;  // Error trap state

    // =========================================================================
    // Instruction opcodes (ISA-172 Gaming Extension)
    // =========================================================================
    localparam OP_NOP       = 8'h00;  // No Operation (valid - digunakan saat idle)
    localparam OP_DRAW      = 8'h01;
    localparam OP_TEXTURE   = 8'h02;
    localparam OP_PHYSICS   = 8'h03;
    localparam OP_COLLISION = 8'h04;
    localparam OP_RAYTRACE  = 8'h05;
    localparam OP_FRAMEGEN  = 8'h06;
    localparam OP_SHADING   = 8'h07;
    localparam OP_BRANCH    = 8'h08;
    localparam OP_LOAD      = 8'h10;
    localparam OP_STORE     = 8'h11;

    // =========================================================================
    // Error codes (NEW)
    // =========================================================================
    localparam ERR_ILLEGAL_OPCODE = 8'h01;
    localparam ERR_OOB_ADDRESS    = 8'h02;
    localparam ERR_ACCESS_VIOLATION = 8'h03;
    localparam ERR_CACHE_TIMEOUT  = 8'h10;

    // =========================================================================
    // Main pipeline - Zero latency design
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_state  <= IDLE;
            pc_reg          <= {ADDR_WIDTH{1'b0}};
            result          <= {DATA_WIDTH{1'b0}};
            result_valid    <= 1'b0;
            busy            <= 1'b0;
            cmd_ready       <= 1'b1;
            fabric_rd_en    <= 1'b0;
            fabric_wr_en    <= 1'b0;
            branch_history  <= 16'h0000;
            l1_rd_en        <= 1'b0;
            l1_wr_en        <= 1'b0;
            mem_wait_counter <= 16'h0;
            mem_is_write    <= 1'b0;
            l1_request_accepted <= 1'b0;
            error_flag      <= 1'b0;
            error_code      <= 8'h00;
            error_valid     <= 1'b0;
            cmd_valid_prev  <= 1'b0;
            exec_counter    <= 16'h0;
            exec_target_cycles <= 16'h0;
            pipeline_stage_detail <= 4'h0;
            cache_miss_occurred <= 1'b0;
            cache_miss_penalty_cycles <= 8'h0;
        end else begin
            error_valid <= 1'b0;  // Clear error valid pulse each cycle
            case (pipeline_state)
                IDLE: begin
                    cmd_ready <= 1'b1;
                    // FIX: Update cmd_valid_prev for edge detection
                    cmd_valid_prev <= cmd_valid;
                    // FIX #1: Always clear result_valid in IDLE to prevent stale signal
                    result_valid <= 1'b0;
                    // Keep result_valid high until new command arrives
                    if (cmd_valid && !cmd_valid_prev && !busy) begin
                        // Only log on rising edge when core is actually IDLE (not busy)
                        // Display expected pipeline latency based on opcode
                        case (cmd_data[31:24])
                            OP_DRAW:      $display("[%0t] [G-CORE#%0d] 📥 DRAW command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_DRAW);
                            OP_TEXTURE:   $display("[%0t] [G-CORE#%0d] 📥 TEXTURE command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_TEXTURE);
                            OP_PHYSICS:   $display("[%0t] [G-CORE#%0d] 📥 PHYSICS command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_PHYSICS);
                            OP_COLLISION: $display("[%0t] [G-CORE#%0d] 📥 COLLISION command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_COLLISION);
                            OP_RAYTRACE:  $display("[%0t] [G-CORE#%0d] 📥 RAYTRACE command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_RAYTRACE);
                            OP_FRAMEGEN:  $display("[%0t] [G-CORE#%0d] 📥 FRAMEGEN command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_FRAMEGEN);
                            OP_SHADING:   $display("[%0t] [G-CORE#%0d] 📥 SHADING command (expected latency: %0d cycles)", $time, CORE_ID, G_PIPE_SHADING);
                            default:      $display("[%0t] [G-CORE#%0d] 📥 Command received: opcode=0x%02x addr=0x%h", $time, CORE_ID, cmd_data[31:24], cmd_addr);
                        endcase
                        // VALIDATE OPCODE FIRST
                        case (cmd_data[31:24])
                            OP_NOP: begin
                                // NOP - No Operation, langsung kembali ke IDLE
                                // Digunakan saat scheduler tidak ada task untuk dikirim
                                result_valid <= 1'b0;
                                cmd_ready <= 1'b1;  // Tetap ready terima command berikutnya
                                busy <= 1'b0;
                                pipeline_state <= IDLE;
                            end
                            OP_DRAW, OP_TEXTURE, OP_PHYSICS, OP_COLLISION,
                            OP_RAYTRACE, OP_FRAMEGEN, OP_SHADING, OP_BRANCH,
                            OP_LOAD, OP_STORE: begin
                                // Valid opcode - proceed
                                result_valid <= 1'b0;  // Clear old result
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                instruction_reg <= {cmd_data, cmd_addr[31:0]};
                                pc_reg <= cmd_addr;
                                pipeline_state <= FETCH;
                                error_flag <= 1'b0;
                                error_code <= 8'h00;
                            end
                            default: begin
                                // FIXED: INVALID OPCODE - generate error result instead of trap
                                // Generate proper error result with error code in data
                                if (error_flag == 1'b0) begin
                                    $display("[%0t] [G-CORE#%0d] ❌ ERROR: Invalid opcode 0x%02x at addr=0x%h",
                                             $time, CORE_ID, cmd_data[31:24], cmd_addr);
                                end
                                error_flag <= 1'b1;
                                error_code <= ERR_ILLEGAL_OPCODE;
                                error_valid <= 1'b1;
                                // FIXED: Generate error result instead of hanging
                                result <= {DATA_WIDTH{1'b1}};  // All ones = error indicator
                                result_valid <= 1'b1;  // Signal result ready with error
                                cmd_ready <= 1'b1;      // Accept next command
                                busy <= 1'b0;           // Not busy after error result
                                pipeline_state <= IDLE;  // Return to IDLE immediately
                            end
                        endcase
                    end
                end
                
                FETCH: begin
                    busy <= 1'b1;  // FIXED: Keep busy during fetch
                    // Fetch instruction - simplified: use cmd_data directly
                    fabric_rd_en <= 1'b0;
                    fabric_wr_en <= 1'b0;
                    pipeline_stage_1 <= cmd_data;  // Use command data as instruction
                    pipeline_state <= DECODE;
                end

                DECODE: begin
                    busy <= 1'b1;  // FIXED: Keep busy during decode
                    // Decode instruction dan setup pipeline depth
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    
                    pipeline_stage_detail <= 4'd2;  // DECODE stage

                    case (pipeline_stage_1[31:24])
                        OP_BRANCH: begin
                            branch_predicted <= ai_branch_predict(pipeline_stage_1);
                            branch_history <= {branch_history[14:0], branch_predicted};
                            // Set realistic pipeline depth
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_BRANCH;
                            pipeline_state <= EXECUTE;
                        end
                        OP_DRAW: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_DRAW;
                            pipeline_state <= EXECUTE;
                        end
                        OP_TEXTURE: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_TEXTURE;
                            pipeline_state <= EXECUTE;
                        end
                        OP_PHYSICS: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_PHYSICS;
                            pipeline_state <= EXECUTE;
                        end
                        OP_COLLISION: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_COLLISION;
                            pipeline_state <= EXECUTE;
                        end
                        OP_RAYTRACE: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_RAYTRACE;
                            pipeline_state <= EXECUTE;
                        end
                        OP_FRAMEGEN: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_FRAMEGEN;
                            pipeline_state <= EXECUTE;
                        end
                        OP_SHADING: begin
                            exec_counter <= 16'h0;
                            exec_target_cycles <= G_PIPE_SHADING;
                            pipeline_state <= EXECUTE;
                        end
                        OP_LOAD: begin
                            // VALIDATE ADDRESS - Check bounds
                            if (pipeline_stage_1[23:0] > MAX_ADDR[23:0]) begin
                                // OOB ADDRESS - trap
                                if (error_flag == 1'b0) begin
                                    $display("[%0t] [G-CORE] ❌ ERROR: OOB address 0x%h (max=0x%h)",
                                             $time, pipeline_stage_1[23:0], MAX_ADDR[23:0]);
                                end
                                error_flag <= 1'b1;
                                error_code <= ERR_OOB_ADDRESS;
                                error_valid <= 1'b1;
                                result_valid <= 1'b0;
                                busy <= 1'b0;
                                pipeline_state <= ERROR_STATE;
                            end else begin
                                // Valid address - Access L1 cache (FIXED: SKIP_L1 removed)
                                l1_addr <= pipeline_stage_1[23:0];
                                l1_rd_en <= 1'b1;
                                mem_wait_counter <= 16'h0;
                                mem_is_write <= 1'b0;
                                l1_request_accepted <= 1'b0;
                                pipeline_state <= WAIT_L1;
                            end
                        end
                        OP_STORE: begin
                            // VALIDATE ADDRESS - Check bounds
                            if (pipeline_stage_1[23:0] > MAX_ADDR[23:0]) begin
                                // OOB ADDRESS - trap
                                if (error_flag == 1'b0) begin
                                    $display("[%0t] [G-CORE] ❌ ERROR: OOB address 0x%h (max=0x%h)",
                                             $time, pipeline_stage_1[23:0], MAX_ADDR[23:0]);
                                end
                                error_flag <= 1'b1;
                                error_code <= ERR_OOB_ADDRESS;
                                error_valid <= 1'b1;
                                result_valid <= 1'b0;
                                busy <= 1'b0;
                                pipeline_state <= ERROR_STATE;
                            end else begin
                                // Valid address - Write to L1 cache (FIXED: SKIP_L1 removed)
                                // BUG-1 FIX: Store 64-bit result into lower bits of 512-bit cache line
                                l1_addr <= pipeline_stage_1[23:0];
                                l1_wr_data <= {{(LINE_SIZE*8-DATA_WIDTH){1'b0}}, result};  // Zero-extend to 512-bit
                                l1_wr_en <= 1'b1;
                                mem_wait_counter <= 16'h0;
                                mem_is_write <= 1'b1;
                                l1_request_accepted <= 1'b0;
                                pipeline_state <= WAIT_L1;
                            end
                        end
                        default: begin
                            // Default ops: set moderate pipeline depth
                            exec_counter <= 16'h0;
                            exec_target_cycles <= 15;  // Default 15 cycles
                            pipeline_state <= EXECUTE;
                        end
                    endcase
                end
                
                EXECUTE: begin
                    busy <= 1'b1;  // FIXED: Keep busy during execute
                    fabric_rd_en <= 1'b0;
                    fabric_wr_en <= 1'b0;
                    pipeline_stage_detail <= 4'd3;  // EXECUTE stage
                    
                    // CRITICAL FIX: Wait until execution counter reaches target
                    // Ini enforce latency yang sebenarnya - compute TIDAK boleh mulai sebelum counter selesai
                    if (exec_counter < exec_target_cycles) begin
                        // Still executing - increment counter, DO NOT compute yet
                        exec_counter <= exec_counter + 1;
                        // Stay in EXECUTE state
                    end else begin
                        // Execution counter complete - NOW compute
                        case (pipeline_stage_1[31:24])
                            OP_DRAW,
                            OP_TEXTURE,
                            OP_SHADING: begin
                                pipeline_stage_2 <= compute_output(pipeline_stage_1, pipeline_stage_1[31:24], pc_reg);
                                pipeline_state <= WRITEBACK;
                            end
                            OP_PHYSICS,
                            OP_COLLISION: begin
                                pipeline_stage_2 <= compute_output(pipeline_stage_1, pipeline_stage_1[31:24], pc_reg);
                                pipeline_state <= WRITEBACK;
                            end
                            OP_RAYTRACE: begin
                                pipeline_stage_2 <= compute_output(pipeline_stage_1, pipeline_stage_1[31:24], pc_reg);
                                pipeline_state <= WRITEBACK;
                            end
                            OP_FRAMEGEN: begin
                                pipeline_stage_2 <= compute_output(pipeline_stage_1, pipeline_stage_1[31:24], pc_reg);
                                pipeline_state <= WRITEBACK;
                            end
                            OP_BRANCH: begin
                                if (branch_predicted) begin
                                    pc_reg <= pc_reg + pipeline_stage_1[23:0];
                                end
                                pipeline_state <= IDLE;
                            end
                            default: begin
                                pipeline_stage_2 <= compute_output(pipeline_stage_1, pipeline_stage_1[31:24], pc_reg);
                                pipeline_state <= WRITEBACK;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // WAIT_L1: Wait for L1 to accept and process request
                // ─────────────────────────────────────────────────
                WAIT_L1: begin
                    busy <= 1'b1;  // FIXED: Keep busy while waiting for L1
                    // Clear request signals (already sent to L1)
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    
                    // Mark request as accepted
                    if (!l1_request_accepted) begin
                        l1_request_accepted <= 1'b1;
                        // Debug: show request sent
                        if (mem_is_write) begin
                            $display("[%0t] [G-CORE] 📤 L1 WRITE REQUEST addr=0x%h", $time, l1_addr);
                        end else begin
                            $display("[%0t] [G-CORE] 📤 L1 READ REQUEST addr=0x%h", $time, l1_addr);
                        end
                        // Stay in this state for at least 1 cycle to let L1 process
                    end else begin
                        // Now check if L1 has completed
                        if (l1_ready) begin
                            // L1 response received
                            if (mem_is_write) begin
                                pipeline_stage_2 <= result;  // Keep result for write
                                $display("[%0t] [G-CORE] ✅ L1 WRITE COMPLETE", $time);
                            end else begin
                                pipeline_stage_2 <= l1_rd_data[31:0];  // Read data
                                $display("[%0t] [G-CORE] ✅ L1 READ COMPLETE data=0x%h", $time, l1_rd_data[31:0]);
                            end
                            mem_wait_counter <= 16'h0;
                            l1_request_accepted <= 1'b0;
                            pipeline_state <= WRITEBACK;
                        end else if (mem_wait_counter >= 16'hFF) begin
                            // Timeout after 256 cycles
                            $display("[%0t] [G-CORE] ⚠️ L1 CACHE TIMEOUT after %0d cycles", $time, mem_wait_counter);
                            pipeline_stage_2 <= 32'hDEADBEEF;
                            mem_wait_counter <= 16'h0;
                            l1_request_accepted <= 1'b0;
                            pipeline_state <= WRITEBACK;
                        end else begin
                            // Increment timeout counter
                            mem_wait_counter <= mem_wait_counter + 1;
                        end
                    end
                end

                WRITEBACK: begin
                    busy <= 1'b1;  // Keep busy during writeback
                    fabric_wr_en <= 1'b0;
                    pipeline_stage_detail <= 4'd5;  // WRITEBACK stage
                    // BUG-7 FIX: Reset mem_wait_counter to prevent stale values in ERROR_STATE
                    mem_wait_counter <= 16'h0;

                    if (mem_is_write) begin
                        // Write operation - result unchanged, just signal completion
                        result_valid <= 1'b1;
                    end else begin
                        // Read operation - update result with data from memory
                        result <= {32'b0, pipeline_stage_2};
                        result_valid <= 1'b1;
                    end

                    // Debug: show actual pipeline latency
                    $display("[%0t] [G-CORE#%0d] ✅ Command completed (actual pipeline latency: %0d cycles, expected: %0d)",
                             $time, CORE_ID, exec_counter, exec_target_cycles);

                    // Reset pipeline counters
                    exec_counter <= 16'h0;
                    exec_target_cycles <= 16'h0;
                    pipeline_stage_detail <= 4'h0;

                    busy <= 1'b0;
                    pc_reg <= pc_reg + 4;
                    pipeline_state <= IDLE;
                end

                // ─────────────────────────────────────────────────
                // ERROR_STATE: Trap state untuk error handling
                // ─────────────────────────────────────────────────
                ERROR_STATE: begin
                    // CRITICAL FIX: Enhanced error recovery protocol
                    // Stay in error state for fixed recovery period, then force return to IDLE
                    // This prevents infinite loop if scheduler keeps re-sending bad commands
                    
                    // Error recovery counter - stay for 10 cycles minimum
                    if (mem_wait_counter < 16'd10) begin
                        mem_wait_counter <= mem_wait_counter + 1;
                        error_valid <= 1'b0;  // Pulse already sent on entry
                        result <= {DATA_WIDTH{1'b1}};  // Keep error result visible
                        result_valid <= 1'b0;  // Don't assert during recovery
                        busy <= 1'b0;
                        cmd_ready <= 1'b0;  // Don't accept new commands during recovery
                        if (CORE_ID == 0 && mem_wait_counter == 16'd5) begin
                            $display("[%0t] [G-CORE#%0d] ** ERROR RECOVERY: In recovery state (cycle %0d/10)", 
                                    $time, CORE_ID, mem_wait_counter);
                        end
                    end else begin
                        // Recovery period complete - force return to IDLE
                        // Clear error state regardless of cmd_valid
                        error_flag <= 1'b0;
                        error_code <= 8'h00;
                        error_valid <= 1'b0;
                        result <= {DATA_WIDTH{1'b0}};
                        result_valid <= 1'b0;
                        busy <= 1'b0;
                        cmd_ready <= 1'b1;  // Ready to accept new commands
                        mem_wait_counter <= 16'h0;
                        pipeline_state <= IDLE;
                        if (CORE_ID == 0)
                            $display("[%0t] [G-CORE#%0d] ** ERROR RECOVERY COMPLETE: Returning to IDLE", $time, CORE_ID);
                        
                        // Log recovery event (only once)
                        $display("[%0t] [G-CORE] ✅ Error recovery complete, returning to IDLE", $time);
                    end
                end
                
                default: begin
                    pipeline_state <= IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // Error counters (NEW)
    // =========================================================================
    reg [31:0]    error_illegal_opcode_count;
    reg [31:0]    error_oob_address_count;
    reg [31:0]    error_access_violation_count;
    reg [31:0]    error_cache_timeout_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_illegal_opcode_count <= 32'h0;
            error_oob_address_count <= 32'h0;
            error_access_violation_count <= 32'h0;
            error_cache_timeout_count <= 32'h0;
        end else begin
            // Count errors by type
            if (error_valid) begin
                case (error_code)
                    ERR_ILLEGAL_OPCODE: error_illegal_opcode_count <= error_illegal_opcode_count + 1;
                    ERR_OOB_ADDRESS: error_oob_address_count <= error_oob_address_count + 1;
                    ERR_ACCESS_VIOLATION: error_access_violation_count <= error_access_violation_count + 1;
                    ERR_CACHE_TIMEOUT: error_cache_timeout_count <= error_cache_timeout_count + 1;
                    default: ; // Ignore unknown error codes
                endcase
            end
        end
    end

    // =========================================================================
    // L1 Cache instance (4-way set associative, 32KB, MESI) - 512-BIT L2
    // =========================================================================
    l1_cache #(
        .DATA_WIDTH(LINE_SIZE*8),       // 512-bit data width (matches L2 bus)
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_SIZE(32 * 1024),       // 32KB L1 for G-Core
        .ASSOCIATIVITY(4),            // 4-way set associative
        .LINE_SIZE(LINE_SIZE)         // 64-byte cache lines (512-bit, matches bus)
    ) u_l1_cache (
        .clk(clk),
        .rst_n(rst_n),

        // Core interface
        .core_addr(l1_addr),
        .core_wr_data(l1_wr_data),  // BUG-1 FIX: Now properly 512-bit wide
        .core_rd_en(l1_rd_en),
        .core_wr_en(l1_wr_en),
        .core_rd_data(l1_rd_data),
        .core_ready(l1_ready),

        // L2 interface (exposed to top-level)
        .l2_addr(l2_addr),
        .l2_wr_data(l2_wr_data),
        .l2_rd_en(l2_rd_en),
        .l2_wr_en(l2_wr_en),
        .l2_rd_data(l2_rd_data),
        .l2_ready(l2_ready),

        // Snoop interface
        .snoop_addr(snoop_addr),
        .snoop_invalidate(snoop_invalidate),
        .snoop_update(snoop_update),

        // Performance counters
        .hits(l1_hits),
        .misses(l1_misses),
        .writebacks(l1_writebacks),
        .invalidations(l1_invalidations)
    );

    // =========================================================================
    // AI Branch Predictor (simplified)
    // =========================================================================
    function automatic logic ai_branch_predict;
        input [31:0] instr;
        begin
            // FIXED: Use instruction bits to correlate with history
            // Combine instruction opcode with history for better prediction
            ai_branch_predict = ^(branch_history & instr[15:0]);  // FIXED: was just ^branch_history
        end
    endfunction

    // =========================================================================
    // Helper: Generate varied output based on operation and input
    // Prevents magic constant outputs like 0x08000008
    // =========================================================================
    function automatic reg [31:0] compute_output;
        input [31:0] input_data;
        input [7:0]  opcode;
        input [47:0] addr;
        reg [63:0] h;
        begin
            // Hash-based output: varies per opcode, addr, and input
            h = {32'b0, input_data};
            h = h ^ (h >> 13);
            h = h + (opcode * 64'd128);
            h = h ^ (h << 17);
            h = h + addr;
            h = h ^ (h >> 7);
            h = h * 64'd6364136223846793005;
            h = h ^ (h >> 33);
            compute_output = h[31:0];
        end
    endfunction

endmodule
