//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel CET)
//
// Create Date: 12 April 2026
// Design Name: Control-flow Enforcement Technology (CET)
// Module Name: cet_anti_cheat
//
// Description:
//   Hardware control-flow enforcement untuk gaming anti-cheat
//   Inspired by Intel CET (Control-flow Enforcement Technology)
//
//   Intel CET Features:
//   - ENDBRANCH: Valid branch target marker
//   - SHSTK: Shadow Stack (return address copy)
//   - Detect ROP: Return address != Shadow stack
//   - Detect JOP: Jump target without ENDBRANCH
//   - Block 99% code reuse attacks
//
//   AURORA Adaptation (Gaming Anti-Cheat):
//   - ENDBRANCH → Valid game instruction marker
//   - SHADOW STACK → Game state integrity check
//   - Detect cheat engines yang inject code
//   - Track unauthorized instruction injection
//   - Game state tamper detection
//
//   CET State Machine:
//   - IDLE: Normal execution
//   - CHECK_BRANCH: Verify ENDBRANCH marker
//   - CHECK_RETURN: Verify return address vs shadow stack
//   - VIOLATION: Cheat detected
//
//   Shadow Stack Structure:
//   - 256 entries deep
//   - Circular buffer
//   - Push on CALL, Pop on RET
//   - Mismatch → violation detected
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module cet_anti_cheat #(
    // Use standardized parameters
    parameter DATA_WIDTH            = AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH            = AURORA_ADDR_WIDTH,
    parameter SHADOW_STACK_DEPTH    = 128,   // OPTIMIZED: 256->128 (smaller shadow stack)
    parameter MAX_GAME_STATES       = 8      // OPTIMIZED: 16->8 (fewer game states)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Instruction stream monitor
    input  wire [ADDR_WIDTH-1:0]        instr_pc,
    input  wire [31:0]                  instr_opcode,
    input  wire                         instr_valid,
    input  wire                         instr_is_branch,
    input  wire                         instr_is_call,
    input  wire                         instr_is_ret,
    input  wire                         instr_is_endbranch,

    // Game state integrity
    input  wire [7:0]                   game_state_id,
    input  wire [31:0]                  game_state_hash,
    input  wire                         game_state_valid,
    input  wire [31:0]                  expected_state_hash,

    // CET control
    input  wire                         cet_enable,
    input  wire                         cet_shadow_enable,
    input  wire                         cet_state_check,

    // Violation output
    output reg                          violation_detected,
    output reg [3:0]                    violation_type,
    output reg [ADDR_WIDTH-1:0]         violation_pc,
    output reg                          violation_latched,

    // Status signals
    output reg                          shadow_stack_active,
    output reg [7:0]                    shadow_stack_depth_cnt,
    output reg                          game_state_integrity_ok,

    // Debug / performance counters
    output reg [31:0]                   cet_branch_checks,
    output reg [31:0]                   cet_return_checks,
    output reg [31:0]                   cet_violations_rop,     // ROP violations
    output reg [31:0]                   cet_violations_jop,     // JOP violations
    output reg [31:0]                   cet_violations_state,   // State tamper violations
    output reg [31:0]                   cet_state_checks,
    output reg [31:0]                   cet_valid_transitions
);

    // ─────────────────────────────────────────────────────────────
    // Shadow Stack
    // ─────────────────────────────────────────────────────────────
    reg [ADDR_WIDTH-1:0]    shadow_stack [0:SHADOW_STACK_DEPTH-1];
    reg [7:0]               shadow_sp;  // Stack pointer

    // ─────────────────────────────────────────────────────────────
    // Game State Registry
    // ─────────────────────────────────────────────────────────────
    reg [31:0]              registered_hashes [0:MAX_GAME_STATES-1];
    reg                     registered_valid [0:MAX_GAME_STATES-1];
    wire [3:0]              game_state_id_4b = game_state_id[3:0];

    // ─────────────────────────────────────────────────────────────
    // Violation types
    // ─────────────────────────────────────────────────────────────
    localparam VIOL_NONE        = 4'h0;
    localparam VIOL_ROP         = 4'h1;  // Return-oriented programming
    localparam VIOL_JOP         = 4'h2;  // Jump-oriented programming
    localparam VIOL_STATE_TAMPER = 4'h3; // Game state tampering
    /* verilator lint_off UNUSED */
    localparam VIOL_UNAUTH_INSTR = 4'h4; // Unauthorized instruction
    /* verilator lint_on UNUSED */

    // ─────────────────────────────────────────────────────────────
    // State machine
    // ─────────────────────────────────────────────────────────────
    typedef enum logic [1:0] {
        CET_IDLE,
        CET_CHECK_BRANCH,
        CET_CHECK_RETURN,
        CET_CHECK_STATE
    } cet_state_t;

    cet_state_t cet_sm;

    // ─────────────────────────────────────────────────────────────
    // Main CET Logic
    // ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cet_sm <= CET_IDLE;
            shadow_sp <= 8'd0;
            violation_detected <= 1'b0;
            violation_latched <= 1'b0;  // FIXED: Initialize latched violation
            violation_type <= VIOL_NONE;
            violation_pc <= {ADDR_WIDTH{1'b0}};
            shadow_stack_active <= 1'b0;
            shadow_stack_depth_cnt <= 8'd0;
            game_state_integrity_ok <= 1'b1;

            cet_branch_checks <= 32'd0;
            cet_return_checks <= 32'd0;
            cet_violations_rop <= 32'd0;
            cet_violations_jop <= 32'd0;
            cet_violations_state <= 32'd0;
            cet_state_checks <= 32'd0;
            cet_valid_transitions <= 32'd0;
        end else if (!cet_enable) begin
            cet_sm <= CET_IDLE;
            violation_detected <= 1'b0;
            violation_latched <= 1'b0;  // FIXED: Clear latch when CET disabled
        end else begin
            // Default: clear violation pulse (still asserted this cycle)
            violation_detected <= 1'b0;
            // FIXED: violation_latched is sticky - only cleared on reset or !cet_enable

            case (cet_sm)
                CET_IDLE: begin
                    if (instr_valid) begin
                        if (instr_is_branch) begin
                            cet_sm <= CET_CHECK_BRANCH;
                        end else if (instr_is_ret) begin
                            cet_sm <= CET_CHECK_RETURN;
                        end else if (cet_state_check) begin
                            cet_sm <= CET_CHECK_STATE;
                        end
                    end
                end

                CET_CHECK_BRANCH: begin
                    cet_branch_checks <= cet_branch_checks + 32'd1;

                    if (cet_shadow_enable) begin
                        if (instr_is_call) begin
                            // CALL: Push return address to shadow stack
                            if (shadow_sp < 8'(SHADOW_STACK_DEPTH - 1)) begin
                                shadow_stack[shadow_sp] <= 48'(instr_pc + 48'd4);  // Next instruction
                                shadow_sp <= shadow_sp + 8'd1;
                                shadow_stack_active <= 1'b1;
                                shadow_stack_depth_cnt <= shadow_sp + 8'd1;
                                cet_valid_transitions <= cet_valid_transitions + 32'd1;
                            end
                        end

                        // Check ENDBRANCH on indirect branches
                        if (instr_is_branch && !instr_is_endbranch) begin
                            // JOP detected: branch without ENDBRANCH marker
                            violation_detected <= 1'b1;
                            violation_latched <= 1'b1;  // FIXED: Latch the violation
                            violation_type <= VIOL_JOP;
                            violation_pc <= instr_pc;
                            cet_violations_jop <= cet_violations_jop + 32'd1;
                        end else begin
                            cet_valid_transitions <= cet_valid_transitions + 32'd1;
                        end
                    end

                    cet_sm <= CET_IDLE;
                end

                CET_CHECK_RETURN: begin
                    cet_return_checks <= cet_return_checks + 32'd1;

                    if (cet_shadow_enable && shadow_sp > 0) begin
                        // FIXED: Read expected return address BEFORE decrementing SP
                        // shadow_sp points to next available slot, so top entry is at shadow_sp-1
                        // With non-blocking assignment, shadow_sp on RHS is the OLD value
                        if (instr_pc != shadow_stack[shadow_sp - 8'd1]) begin
                            // ROP detected: return address mismatch
                            violation_detected <= 1'b1;
                            violation_latched <= 1'b1;  // FIXED: Latch the violation
                            violation_type <= VIOL_ROP;
                            violation_pc <= instr_pc;
                            cet_violations_rop <= cet_violations_rop + 32'd1;
                        end else begin
                            cet_valid_transitions <= cet_valid_transitions + 32'd1;
                        end

                        // FIXED: Pop after comparison (was before, causing off-by-one)
                        shadow_sp <= shadow_sp - 8'd1;
                        shadow_stack_depth_cnt <= shadow_sp - 8'd1;  // Uses old SP = new SP value

                        if (shadow_sp == 8'd1) begin  // FIXED: was 0 (checked before decrement)
                            shadow_stack_active <= 1'b0;
                        end
                    end

                    cet_sm <= CET_IDLE;
                end

                CET_CHECK_STATE: begin
                    cet_state_checks <= cet_state_checks + 32'd1;

                    // Register game state hash
                    if (game_state_valid && game_state_id < MAX_GAME_STATES) begin
                        registered_hashes[game_state_id_4b & 4'h7] <= game_state_hash;
                        registered_valid[game_state_id_4b & 4'h7] <= 1'b1;
                    end

                    // Verify current game state
                    if (game_state_valid && registered_valid[game_state_id_4b & 4'h7]) begin
                        if (game_state_hash != registered_hashes[game_state_id_4b & 4'h7]) begin
                            // State tampering detected!
                            violation_detected <= 1'b1;
                            violation_latched <= 1'b1;  // FIXED: Latch the violation
                            violation_type <= VIOL_STATE_TAMPER;
                            violation_pc <= instr_pc;
                            game_state_integrity_ok <= 1'b0;
                            cet_violations_state <= cet_violations_state + 32'd1;
                        end else begin
                            game_state_integrity_ok <= 1'b1;
                            cet_valid_transitions <= cet_valid_transitions + 32'd1;
                        end
                    end

                    cet_sm <= CET_IDLE;
                end

                default: cet_sm <= CET_IDLE;
            endcase
        end
    end

endmodule
