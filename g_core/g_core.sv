`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"
`include "interfaces/aurora_error_codes.svh"

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
    // Use standardized parameters from aurora_global_pkg
    parameter DATA_WIDTH    = `AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH    = `AURORA_ADDR_WIDTH,
    parameter INST_WIDTH    = `AURORA_INST_WIDTH,
    parameter L1_CACHE_SIZE = `AURORA_L1_CACHE_SIZE,
    parameter MAX_ADDR      = 48'h0000_0000_FFFF, // 1MB address space limit
    parameter LINE_SIZE     = `AURORA_LINE_SIZE,

    // Use standardized pipeline latencies from params
    parameter G_PIPE_DRAW       = `AURORA_G_PIPE_DRAW,       // From params
    parameter G_PIPE_TEXTURE   = `AURORA_G_PIPE_TEXTURE,   // From params
    parameter G_PIPE_PHYSICS   = `AURORA_G_PIPE_PHYSICS,   // From params
    parameter G_PIPE_COLLISION = `AURORA_G_PIPE_COLLISION, // From params
    parameter G_PIPE_RAYTRACE  = `AURORA_G_PIPE_RAYTRACE,  // From params
    parameter G_PIPE_FRAMEGEN = `AURORA_G_PIPE_FRAMEGEN, // From params
    parameter G_PIPE_SHADING   = `AURORA_G_PIPE_SHADING,   // From params
    parameter G_PIPE_BRANCH    = `AURORA_G_PIPE_BRANCH    // From params
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

    // FIXED: Proper fabric interface handling
    // Registered fabric_addr to break potential combinational loops
    reg [ADDR_WIDTH-1:0]    fabric_addr_reg;
    assign fabric_addr = fabric_addr_reg;
    assign fabric_wr_data = fabric_wr_en ? result : {DATA_WIDTH{1'b0}};

    // Register fabric_addr from cmd_addr on command capture
    // Bug 6: Hold last valid address instead of defaulting to zero
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fabric_addr_reg <= {ADDR_WIDTH{1'b0}};
        else if (cmd_valid && cmd_ready && !busy)
            fabric_addr_reg <= cmd_addr;
        else if (fabric_rd_en)
            fabric_addr_reg <= cmd_addr;
    end

    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [INST_WIDTH-1:0]    instruction_reg;
    reg [ADDR_WIDTH-1:0]    pc_reg;
    reg [31:0]              pipeline_stage_2;
    
    // FIX: Track cmd_valid edge to prevent duplicate logging
    reg                     cmd_valid_prev;

    // L1 Cache interface (proper 4-way set associative with MESI)
    // Core -> L1 cache interface
    wire [DATA_WIDTH-1:0]        l1_rd_data;
    wire                         l1_ready;
    reg                          l1_rd_en;
    reg                          l1_wr_en;
    reg [ADDR_WIDTH-1:0]         l1_addr;
    reg [LINE_SIZE*8-1:0]        l1_wr_data;  // Extended to 512-bit to match cache line width

    // L1 Snoop interface
    wire [ADDR_WIDTH-1:0]        snoop_addr;
    wire                         snoop_invalidate;
    wire                         snoop_update;

    // FIXED: Proper snoop interface handling
    // Implement basic snoop protocol for cache coherency
    assign snoop_addr = (l1_rd_en || l1_wr_en) ? l1_addr : {ADDR_WIDTH{1'b0}};
    
    // Basic snoop logic: invalidate on write operations, update on read-modify-write
    assign snoop_invalidate = l1_wr_en && (pipeline_state == OP_STORE);
    assign snoop_update = l1_wr_en && (pipeline_state == OP_LOAD && l1_request_accepted);

    // L1 Cache performance counters
    wire [31:0]                  l1_hits;
    wire [31:0]                  l1_misses;
    wire [31:0]                  l1_writebacks;
    wire [31:0]                  l1_invalidations;
    
    // Branch predictor (AI-based)
    reg [15:0]              branch_history;
    reg                     branch_predicted;
    
    // Pipeline control
    reg [3:0]               pipeline_state;
    
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
    
    // Bug 4: L1 handshake - separate accept and complete tracking
    reg                     l1_rd_data_valid;
    reg                     l1_accept_phase;  // 0=wait accept, 1=wait complete
    
    // Bug 3: Resource contention management
    reg                     resource_locked;
    reg [31:0]              global_cycle_count;

    // Bug 2: 3-stage pipeline with valid/ready handshake
    reg                     stage1_valid;  // FETCH output valid
    reg                     stage2_valid;  // DECODE output valid
    reg                     stage2_ready;  // EXECUTE ready for new input
    reg [31:0]              stage1_data;   // FETCH → DECODE data
    reg [31:0]              stage2_data;   // DECODE → EXECUTE data (opcode+payload)
    reg [47:0]              stage1_addr;   // FETCH → DECODE address
    reg [47:0]              stage2_addr;   // DECODE → EXECUTE address
    reg [7:0]               stage1_opcode; // Opcode being fetched
    reg [7:0]               stage2_opcode; // Opcode being decoded
    reg                     stage2_branch; // DECODE output for branch
    
    // Bug 3: Resource lock timeout counter
    reg [15:0]              lock_timeout_counter;

    localparam IDLE         = 4'b0000;
    localparam FETCH        = 4'b0001;
    localparam DECODE       = 4'b0010;
    localparam EXECUTE      = 4'b0011;
    localparam MEMORY       = 4'b0100;
    localparam WAIT_ACCEPT  = 4'b0101;  // Bug 4: Wait for L1 to accept request
    localparam WAIT_COMPLETE= 4'b0110;  // Bug 4: Wait for L1 completion
    localparam WRITEBACK    = 4'b0111;
    localparam CLEANUP      = 4'b1000;  // One-cycle cleanup before IDLE
    localparam ERROR_STATE  = 4'b1001;  // Error trap state

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
    // NEW: Fallback opcodes for compatibility
    localparam OP_RESERVED  = 8'h42;  // Reserved opcode - treat as NOP

    // =========================================================================
    // Error codes (FIXED: Using standardized codes)
    // =========================================================================
    // All error codes are now defined in aurora_error_codes.svh

    // REMOVED: Debug counter untuk mengurangi debug output
    // reg [31:0] debug_counter;
    
    // =========================================================================
    // 3-Stage Pipeline with Valid/Ready Handshake - Bug 2
    // Stage 1 (FETCH): accept new cmd while stage 2 decodes
    // Stage 2 (DECODE): decode while stage 3 executes
    // Stage 3 (EXECUTE): execute while writing back
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_state  <= IDLE;
            pc_reg          <= {ADDR_WIDTH{1'b0}};
            result          <= {DATA_WIDTH{1'b0}};
            result_valid    <= 1'b0;
            busy            <= 1'b0;
            mem_wait_counter <= 16'd0;
            resource_locked <= 1'b0;
            lock_timeout_counter <= 16'd0;
            global_cycle_count <= 32'd0;
            cmd_ready       <= 1'b1;
            fabric_rd_en    <= 1'b0;
            fabric_wr_en    <= 1'b0;
            branch_history  <= 16'h0000;
            l1_rd_en        <= 1'b0;
            l1_wr_en        <= 1'b0;
            mem_is_write    <= 1'b0;
            l1_request_accepted <= 1'b0;
            l1_rd_data_valid <= 1'b0;
            l1_accept_phase <= 1'b0;
            error_flag      <= 1'b0;
            error_code      <= 8'h00;
            error_valid     <= 1'b0;
            exec_counter    <= 16'h0;
            exec_target_cycles <= 16'h0;
            pipeline_stage_detail <= 4'h0;
            cmd_valid_prev <= 1'b0;
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
            stage2_ready <= 1'b0;
        end else begin
            global_cycle_count <= global_cycle_count + 1;
            cmd_valid_prev <= cmd_valid;
            error_valid <= 1'b0;
            l1_rd_data_valid <= 1'b0;

            // Bug 3: Resource lock timeout - 1000 cycles max
            if (resource_locked) begin
                if (lock_timeout_counter >= 16'd1000) begin
                    resource_locked <= 1'b0;
                    lock_timeout_counter <= 16'd0;
                    error_flag <= 1'b1;
                    error_code <= `AURORA_ERR_TIMEOUT;
                    error_valid <= 1'b1;
                    pipeline_state <= ERROR_STATE;
                end else begin
                    lock_timeout_counter <= lock_timeout_counter + 1;
                end
            end

            case (pipeline_state)
                IDLE: begin
                    cmd_ready <= 1'b1;
                    result_valid <= 1'b0;
                    busy <= 1'b0;

                    // Bug 2: Accept new cmd into stage 1 (FETCH)
                    if (cmd_valid && cmd_ready && !busy) begin
                        case (cmd_data[31:24])
                            OP_NOP, OP_RESERVED: begin
                                // Bug 7: NOP does NOT assert result_valid
                                result_valid <= 1'b0;
                                busy <= 1'b0;
                                pipeline_state <= IDLE;
                            end
                            OP_DRAW, OP_TEXTURE, OP_PHYSICS, OP_COLLISION,
                            OP_RAYTRACE, OP_FRAMEGEN, OP_SHADING, OP_BRANCH,
                            OP_LOAD, OP_STORE: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                instruction_reg <= cmd_data;
                                pc_reg <= cmd_addr;
                                // Stage 1 (FETCH) captures the instruction
                                stage1_data <= cmd_data;
                                stage1_addr <= cmd_addr;
                                stage1_opcode <= cmd_data[31:24];
                                stage1_valid <= 1'b1;
                                pipeline_state <= DECODE;
                            end
                            default: begin
                                error_flag <= 1'b1;
                                error_code <= `AURORA_ERR_ILLEGAL_OPCODE;
                                error_valid <= 1'b1;
                                result <= {DATA_WIDTH{1'b1}};
                                result_valid <= 1'b1;
                                cmd_ready <= 1'b1;
                                busy <= 1'b0;
                                pipeline_state <= IDLE;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // DECODE (Stage 2): Decode while stage 3 executes
                // ─────────────────────────────────────────────────
                DECODE: begin
                    busy <= 1'b1;
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;
                    pipeline_stage_detail <= 4'd2;

                    // Forward stage1 → stage2 (DECODE → EXECUTE data)
                    if (stage1_valid) begin
                            stage2_data <= stage1_data;
                            stage2_addr <= stage1_addr;
                            stage2_opcode <= stage1_opcode;
                            stage2_valid <= 1'b1;
                            stage1_valid <= 1'b0;
                            // Stage 2 decoded opcode for EXECUTE
                            case (stage1_opcode)
                                OP_BRANCH: begin
                                    stage2_branch <= branch_predicted;
                                    branch_history <= {branch_history[14:0], branch_predicted};
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_BRANCH;
                                end
                                OP_DRAW: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_DRAW;
                                end
                                OP_TEXTURE: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_TEXTURE;
                                end
                                OP_PHYSICS: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_PHYSICS;
                                end
                                OP_COLLISION: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_COLLISION;
                                end
                                OP_RAYTRACE: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_RAYTRACE;
                                end
                                OP_FRAMEGEN: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_FRAMEGEN;
                                end
                                OP_SHADING: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= G_PIPE_SHADING;
                                end
                                OP_LOAD: begin
                                    if (stage1_data[23:0] > MAX_ADDR[23:0]) begin
                                        error_flag <= 1'b1;
                                        error_code <= `AURORA_ERR_OOB_ADDRESS;
                                        error_valid <= 1'b1;
                                        pipeline_state <= ERROR_STATE;
                                    end else begin
                                        l1_addr <= stage1_data[23:0];
                                        l1_rd_en <= 1'b1;
                                        mem_wait_counter <= 16'h0;
                                        mem_is_write <= 1'b0;
                                        l1_request_accepted <= 1'b0;
                                        l1_accept_phase <= 1'b0;
                                        pipeline_state <= WAIT_ACCEPT;
                                    end
                                end
                                OP_STORE: begin
                                    if (stage1_data[23:0] > MAX_ADDR[23:0]) begin
                                        error_flag <= 1'b1;
                                        error_code <= `AURORA_ERR_OOB_ADDRESS;
                                        error_valid <= 1'b1;
                                        pipeline_state <= ERROR_STATE;
                                    end else begin
                                        l1_addr <= stage1_data[23:0];
                                        l1_wr_data <= { {(LINE_SIZE*8-32){1'b0}}, stage1_data[31:0] };
                                        l1_wr_en <= 1'b1;
                                        mem_wait_counter <= 16'h0;
                                        mem_is_write <= 1'b1;
                                        l1_request_accepted <= 1'b0;
                                        l1_accept_phase <= 1'b0;
                                        pipeline_state <= WAIT_ACCEPT;
                                    end
                                end
                                default: begin
                                    exec_counter <= 16'h0;
                                    exec_target_cycles <= 15;
                                end
                            endcase
                            pipeline_state <= EXECUTE;
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // EXECUTE (Stage 3): Execute while writing back.
                // Bug 2: 3-stage pipeline overlap — while counting,
                // cmd_ready=1 to fetch next instruction into stage1.
                // When counter expires, if stage1 has data, auto-reload
                // stage2 with new instruction (skip IDLE round-trip).
                // Bug 3: resource_locked set on entry, cleared in WRITEBACK
                // ─────────────────────────────────────────────────
                EXECUTE: begin
                    busy <= 1'b1;
                    fabric_rd_en <= 1'b0;
                    fabric_wr_en <= 1'b0;
                    pipeline_stage_detail <= 4'd3;

                    // Bug 3: Set resource lock on entry to EXECUTE
                    if (!resource_locked) begin
                        resource_locked <= 1'b1;
                        lock_timeout_counter <= 16'd0;
                    end

                    // ── 3-stage pipeline overlap (Bug 2) ──
                    // While counting, accept next cmd into stage1
                    cmd_ready <= !stage1_valid;

                    // Stage 1 (FETCH): accept new command while stage3 executes
                    if (cmd_valid && cmd_ready && !stage1_valid) begin
                        stage1_data <= cmd_data;
                        stage1_addr <= cmd_addr;
                        stage1_opcode <= cmd_data[31:24];
                        stage1_valid <= 1'b1;
                    end

                    // ── Stage 3 execution ──
                    if (exec_counter < exec_target_cycles) begin
                        exec_counter <= exec_counter + 1;
                    end else begin
                        mem_is_write <= 1'b0;

                        // Bug 1: Real compute per opcode
                        case (stage2_opcode)
                            OP_DRAW: begin
                                reg signed [31:0] ax, ay, bx, by, cx, cy;
                                reg signed [31:0] area2, u, v, w;
                                reg signed [63:0] mul;
                                ax = stage2_data[7:0];
                                ay = stage2_data[15:8];
                                bx = stage2_data[23:16];
                                by = stage2_data[31:24];
                                cx = (pc_reg[7:0] + 8'd10);
                                cy = (pc_reg[15:8] + 8'd5);
                                mul = ax * (by - cy) + bx * (cy - ay) + cx * (ay - by);
                                area2 = mul[31:0];
                                u = (bx * (cy - ay) + cx * (ay - by) + ax * (by - cy)) / (area2 | 1);
                                v = (cx * (ay - by) + ax * (by - cy) + bx * (cy - ay)) / (area2 | 1);
                                w = 16'sd1 - u - v;
                                pipeline_stage_2 <= {w[15:0], v[15:0], u[15:0], area2[15:0]};
                                pipeline_state <= WRITEBACK;
                            end
                            OP_TEXTURE: begin
                                reg [7:0] tex00, tex01, tex10, tex11;
                                reg [15:0] frac_x, frac_y;
                                reg signed [31:0] top, bot, result_val;
                                tex00 = stage2_data[7:0];
                                tex01 = stage2_data[15:8];
                                tex10 = stage2_data[23:16];
                                tex11 = stage2_data[31:24];
                                frac_x = {pc_reg[7:0], 8'h80};
                                frac_y = {pc_reg[15:8], 8'h80};
                                top = tex00 * (256 - frac_x[7:0]) + tex01 * frac_x[7:0];
                                bot = tex10 * (256 - frac_x[7:0]) + tex11 * frac_x[7:0];
                                result_val = top * (256 - frac_y[7:0]) + bot * frac_y[7:0];
                                pipeline_stage_2 <= result_val[31:0];
                                pipeline_state <= WRITEBACK;
                            end
                            OP_PHYSICS: begin
                                reg signed [31:0] pos, prev_pos, accel;
                                reg signed [63:0] verlet;
                                pos = stage2_data[15:0];
                                prev_pos = stage2_data[31:16];
                                accel = {stage2_data[31], stage2_data[31:16]};
                                verlet = 2 * pos - prev_pos + (accel * 16'sd100) / 16'sd100;
                                pipeline_stage_2 <= verlet[31:0];
                                pipeline_state <= WRITEBACK;
                            end
                            OP_COLLISION: begin
                                reg [15:0] a_min_x, a_min_y, a_max_x, a_max_y;
                                reg [15:0] b_min_x, b_min_y, b_max_x, b_max_y;
                                reg overlap;
                                a_min_x = stage2_data[7:0];
                                a_max_x = stage2_data[15:8];
                                a_min_y = stage2_data[23:16];
                                a_max_y = stage2_data[31:24];
                                b_min_x = pc_reg[7:0];
                                b_max_x = pc_reg[15:8];
                                b_min_y = pc_reg[23:16];
                                b_max_y = pc_reg[31:24];
                                overlap = (a_min_x <= b_max_x) && (a_max_x >= b_min_x) &&
                                          (a_min_y <= b_max_y) && (a_max_y >= b_min_y);
                                pipeline_stage_2 <= {31'b0, overlap};
                                pipeline_state <= WRITEBACK;
                            end
                            OP_RAYTRACE: begin
                                reg signed [31:0] ox, oy, oz, dx, dy, dz;
                                reg signed [31:0] cx_s, cy_s, cz_s, r_s;
                                reg signed [63:0] ocx, ocy, ocz;
                                reg signed [63:0] a, b, c, disc, sqrt_disc;
                                reg signed [63:0] t0, t1;
                                reg hit;
                                ox = stage2_data[7:0];
                                oy = stage2_data[15:8];
                                oz = stage2_data[23:16];
                                dx = stage2_data[31:24];
                                cx_s = pc_reg[7:0];
                                cy_s = pc_reg[15:8];
                                cz_s = pc_reg[23:16];
                                r_s = 16'sd50;
                                ocx = ox - cx_s;
                                ocy = oy - cy_s;
                                ocz = oz - cz_s;
                                a = dx * dx + dy * dy + dz * dz;
                                b = 2 * (ocx * dx + ocy * dy + ocz * dz);
                                c = ocx * ocx + ocy * ocy + ocz * ocz - r_s * r_s;
                                disc = b * b - 4 * a * c;
                                hit = (disc >= 0);
                                if (hit) begin
                                    sqrt_disc = 0;
                                    for (int bit = 30; bit >= 0; bit--) begin
                                        if ((sqrt_disc + (1 << bit)) * (sqrt_disc + (1 << bit)) <= disc) begin
                                            sqrt_disc = sqrt_disc + (1 << bit);
                                        end
                                    end
                                    t0 = (-b - sqrt_disc) / (2 * a | 1);
                                    t1 = (-b + sqrt_disc) / (2 * a | 1);
                                    pipeline_stage_2 <= {t1[15:0], t0[15:0], 15'b0, hit};
                                end else begin
                                    pipeline_stage_2 <= 32'h0;
                                end
                                pipeline_state <= WRITEBACK;
                            end
                            OP_FRAMEGEN: begin
                                reg signed [31:0] mv_x, mv_y, t, interp_x, interp_y;
                                mv_x = stage2_data[15:0];
                                mv_y = stage2_data[31:16];
                                t = pc_reg[7:0];
                                interp_x = mv_x * t / 256;
                                interp_y = mv_y * t / 256;
                                pipeline_stage_2 <= {interp_y[15:0], interp_x[15:0]};
                                pipeline_state <= WRITEBACK;
                            end
                            OP_SHADING: begin
                                reg signed [31:0] nx, ny, nz, lx, ly, lz;
                                reg signed [31:0] vx, vy, vz;
                                reg signed [63:0] dot_nl, dot_nv;
                                reg signed [63:0] diffuse, specular;
                                reg [31:0] color;
                                nx = stage2_data[7:0];
                                ny = stage2_data[15:8];
                                nz = stage2_data[23:16];
                                lx = 16'sd50;
                                ly = 16'sd100;
                                lz = 16'sd75;
                                vx = pc_reg[7:0];
                                vy = pc_reg[15:8];
                                vz = pc_reg[23:16];
                                dot_nl = nx * lx + ny * ly + nz * lz;
                                dot_nv = nx * vx + ny * vy + nz * vz;
                                diffuse = (dot_nl > 0) ? dot_nl : 0;
                                specular = (dot_nv > 0) ? (dot_nv * dot_nv) / 256 : 0;
                                color = {8'd50, diffuse[7:0] + 8'd100, specular[7:0] + 8'd50, 8'd255};
                                pipeline_stage_2 <= color;
                                pipeline_state <= WRITEBACK;
                            end
                            OP_BRANCH: begin
                                if (stage2_branch) begin
                                    pc_reg <= stage2_addr + stage2_data[23:0];
                                end
                                pipeline_state <= IDLE;
                            end
                            default: begin
                                pipeline_stage_2 <= stage2_data;
                                pipeline_state <= WRITEBACK;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // Bug 4: Proper L1 handshake FSM
                // WAIT_ACCEPT: wait for l1_ready to assert request accepted
                // WAIT_COMPLETE: wait for l1_valid/l1_rd_data valid
                // ─────────────────────────────────────────────────
                WAIT_ACCEPT: begin
                    busy <= 1'b1;
                    if (!l1_request_accepted && l1_ready) begin
                        l1_request_accepted <= 1'b1;
                        l1_accept_phase <= 1'b1;
                        l1_rd_en <= 1'b0;
                        l1_wr_en <= 1'b0;
                        pipeline_state <= WAIT_COMPLETE;
                    end else if (mem_wait_counter >= 16'hFF) begin
                        error_flag <= 1'b1;
                        error_code <= `AURORA_ERR_CACHE_TIMEOUT;
                        error_valid <= 1'b1;
                        l1_rd_en <= 1'b0;
                        l1_wr_en <= 1'b0;
                        mem_wait_counter <= 16'h0;
                        pipeline_state <= ERROR_STATE;
                    end else begin
                        mem_wait_counter <= mem_wait_counter + 1;
                    end
                end

                WAIT_COMPLETE: begin
                    busy <= 1'b1;
                    l1_rd_en <= 1'b0;
                    l1_wr_en <= 1'b0;

                    if (l1_ready) begin
                        // L1 completed — capture data
                        l1_rd_data_valid <= 1'b1;
                        if (mem_is_write) begin
                            pipeline_stage_2 <= result[31:0];
                        end else begin
                            pipeline_stage_2 <= l1_rd_data[31:0];
                        end
                        mem_wait_counter <= 16'h0;
                        l1_request_accepted <= 1'b0;
                        l1_accept_phase <= 1'b0;
                        pipeline_state <= WRITEBACK;
                    end else if (mem_wait_counter >= 16'h3FF) begin
                        // 1024-cycle timeout
                        error_flag <= 1'b1;
                        error_code <= `AURORA_ERR_CACHE_TIMEOUT;
                        error_valid <= 1'b1;
                        pipeline_stage_2 <= {DATA_WIDTH{1'b1}};
                        mem_wait_counter <= 16'h0;
                        l1_request_accepted <= 1'b0;
                        l1_accept_phase <= 1'b0;
                        pipeline_state <= WRITEBACK;
                    end else begin
                        mem_wait_counter <= mem_wait_counter + 1;
                    end
                end

                // ─────────────────────────────────────────────────
                // WRITEBACK: Write result, clear resource lock.
                // Bug 2: If stage1 already has next instruction (pipeline
                // overlap), reload stage2 and go directly to EXECUTE.
                // ─────────────────────────────────────────────────
                WRITEBACK: begin
                    busy <= 1'b1;
                    fabric_wr_en <= 1'b0;
                    pipeline_stage_detail <= 4'd5;
                    mem_wait_counter <= 16'h0;

                    if (mem_is_write) begin
                        result_valid <= 1'b1;
                    end else begin
                        result <= {{(DATA_WIDTH-32){1'b0}}, pipeline_stage_2};
                        result_valid <= 1'b1;
                    end

                    // Bug 3: Clear resource lock on leaving EXECUTE
                    resource_locked <= 1'b0;
                    lock_timeout_counter <= 16'd0;

                    exec_counter <= 16'h0;
                    exec_target_cycles <= 16'h0;
                    pipeline_stage_detail <= 4'h0;
                    busy <= 1'b0;
                    pc_reg <= pc_reg + 4;

                    // Bug 2: Pipeline overlap — reload stage2 from stage1 if available
                    if (stage1_valid) begin
                        stage2_data <= stage1_data;
                        stage2_addr <= stage1_addr;
                        stage2_opcode <= stage1_opcode;
                        stage2_valid <= 1'b1;
                        stage1_valid <= 1'b0;
                        case (stage1_opcode)
                            OP_DRAW:         exec_target_cycles <= G_PIPE_DRAW;
                            OP_TEXTURE:      exec_target_cycles <= G_PIPE_TEXTURE;
                            OP_PHYSICS:      exec_target_cycles <= G_PIPE_PHYSICS;
                            OP_COLLISION:    exec_target_cycles <= G_PIPE_COLLISION;
                            OP_RAYTRACE:     exec_target_cycles <= G_PIPE_RAYTRACE;
                            OP_FRAMEGEN:     exec_target_cycles <= G_PIPE_FRAMEGEN;
                            OP_SHADING:      exec_target_cycles <= G_PIPE_SHADING;
                            OP_BRANCH: begin
                                exec_target_cycles <= G_PIPE_BRANCH;
                                stage2_branch <= branch_predicted;
                                branch_history <= {branch_history[14:0], branch_predicted};
                            end
                            default:         exec_target_cycles <= 15;
                        endcase
                        pipeline_state <= EXECUTE;
                    end else begin
                        pipeline_state <= CLEANUP;
                    end
                end

                CLEANUP: begin
                    busy <= 1'b0;
                    resource_locked <= 1'b0;
                    lock_timeout_counter <= 16'd0;
                    // Bug 2: Check again (stage1 might have been loaded this cycle)
                    if (stage1_valid) begin
                        stage2_data <= stage1_data;
                        stage2_addr <= stage1_addr;
                        stage2_opcode <= stage1_opcode;
                        stage2_valid <= 1'b1;
                        stage1_valid <= 1'b0;
                        case (stage1_opcode)
                            OP_DRAW:         exec_target_cycles <= G_PIPE_DRAW;
                            OP_TEXTURE:      exec_target_cycles <= G_PIPE_TEXTURE;
                            OP_PHYSICS:      exec_target_cycles <= G_PIPE_PHYSICS;
                            OP_COLLISION:    exec_target_cycles <= G_PIPE_COLLISION;
                            OP_RAYTRACE:     exec_target_cycles <= G_PIPE_RAYTRACE;
                            OP_FRAMEGEN:     exec_target_cycles <= G_PIPE_FRAMEGEN;
                            OP_SHADING:      exec_target_cycles <= G_PIPE_SHADING;
                            OP_BRANCH: begin
                                exec_target_cycles <= G_PIPE_BRANCH;
                                stage2_branch <= branch_predicted;
                                branch_history <= {branch_history[14:0], branch_predicted};
                            end
                            default:         exec_target_cycles <= 15;
                        endcase
                        pipeline_state <= EXECUTE;
                    end else begin
                        pipeline_state <= IDLE;
                    end
                end

                ERROR_STATE: begin
                    if (mem_wait_counter < 16'd10) begin
                        mem_wait_counter <= mem_wait_counter + 1;
                        error_valid <= 1'b0;
                        result <= {DATA_WIDTH{1'b1}};
                        result_valid <= 1'b0;
                        busy <= 1'b0;
                        cmd_ready <= 1'b0;
                    end else begin
                        pipeline_state <= IDLE;
                        busy <= 1'b0;
                        cmd_ready <= 1'b1;
                        error_flag <= 1'b0;
                        error_code <= 8'h00;
                        error_valid <= 1'b0;
                        result <= {DATA_WIDTH{1'b0}};
                        result_valid <= 1'b0;
                        busy <= 1'b0;
                        cmd_ready <= 1'b1;
                        mem_wait_counter <= 16'h0;
                        resource_locked <= 1'b0;
                        lock_timeout_counter <= 16'd0;
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
                    `AURORA_ERR_ILLEGAL_OPCODE: error_illegal_opcode_count <= error_illegal_opcode_count + 1;
                    `AURORA_ERR_OOB_ADDRESS: error_oob_address_count <= error_oob_address_count + 1;
                    `AURORA_ERR_ACCESS_VIOLATION: error_access_violation_count <= error_access_violation_count + 1;
                    `AURORA_ERR_CACHE_TIMEOUT: error_cache_timeout_count <= error_cache_timeout_count + 1;
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
        .LINE_SIZE(LINE_SIZE),        // 64-byte cache lines (512-bit, matches bus)
        .CORE_ID(CORE_ID)
    ) u_l1_cache (
        .clk(clk),
        .rst_n(rst_n),

        // Core interface
        .core_addr(l1_addr),
        .core_wr_data(l1_wr_data),  // Now properly 512-bit wide
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
    // Bug 5: AI Branch Predictor instantiation
    // =========================================================================
    wire ai_prediction_taken;
    wire [47:0] ai_prediction_target;
    wire [31:0] ai_total_branches;
    wire [31:0] ai_correct_predictions;
    wire [7:0]  ai_prediction_accuracy;

    ai_branch_predictor #(
        .PHT_BITS(10),
        .HISTORY_LEN(16),
        .BTB_SIZE(256),
        .RAS_SIZE(16),
        .WEIGHT_BITS(8)
    ) u_ai_branch_predictor (
        .clk(clk),
        .rst_n(rst_n),
        .branch_pc(pc_reg),
        .branch_is_call(1'b0),
        .branch_is_return(1'b0),
        .branch_is_indirect(1'b0),
        .branch_taken_actual(stage2_branch),
        .branch_target_actual(pc_reg + stage2_data[23:0]),
        .prediction_taken(ai_prediction_taken),
        .prediction_target(ai_prediction_target),
        .train_enable(stage2_opcode == OP_BRANCH),
        .total_branches(ai_total_branches),
        .correct_predictions(ai_correct_predictions),
        .prediction_accuracy(ai_prediction_accuracy)
    );

    // Bug 5: Use ai_branch_predictor prediction for branch opcode
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            branch_predicted <= 1'b0;
        end else if (stage1_opcode == OP_BRANCH && stage1_valid) begin
            branch_predicted <= ai_prediction_taken;
            branch_history <= {branch_history[14:0], ai_prediction_taken};
        end
    end

endmodule
