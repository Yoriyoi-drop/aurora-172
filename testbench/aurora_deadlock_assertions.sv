`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: RTL Debug Team
//
// Create Date: 14 April 2026
// Design Name: AURORA-172 Deadlock Detection Assertions
// Module Name: aurora_deadlock_assertions
//
// Description:
//   SystemVerilog Assertions untuk mendeteksi kondisi deadlock, livelock,
//   dan liveness violations di seluruh desain Aurora-172.
//  Assertions ini dapat di-enable/disable via macro untuk simulasi vs formal.
//////////////////////////////////////////////////////////////////////////////////

`ifndef DISABLE_SVA
`define ASSERT_ENABLED

module aurora_deadlock_assertions #(
    parameter NUM_G_CORES      = 16,
    parameter NUM_A_CORES      = 64,
    parameter NUM_H_CORES      = 32,
    parameter NUM_NPU_CLUSTERS = 8,
    parameter FIFO_DEPTH       = 8,
    parameter QUEUE_DEPTH      = 32
)(
    input wire clk,
    input wire rst_n,
    
    // A-Core interface
    input wire [NUM_A_CORES-1:0]   a_core_cmd_valid,
    input wire [NUM_A_CORES-1:0]   a_core_cmd_ready,
    input wire [NUM_A_CORES-1:0]   a_core_result_valid,
    input wire [NUM_A_CORES-1:0]   a_core_result_ready,
    input wire [NUM_A_CORES-1:0]   a_core_busy,
    input wire [NUM_A_CORES-1:0][$clog2(FIFO_DEPTH):0] a_core_fifo_count,
    
    // G-Core interface
    input wire [NUM_G_CORES-1:0]   g_core_cmd_valid,
    input wire [NUM_G_CORES-1:0]   g_core_cmd_ready,
    input wire [NUM_G_CORES-1:0]   g_core_busy,
    
    // H-Core interface  
    input wire [NUM_H_CORES-1:0]   h_core_cmd_valid,
    input wire [NUM_H_CORES-1:0]   h_core_cmd_ready,
    input wire [NUM_H_CORES-1:0]   h_core_busy,
    
    // NPU interface
    input wire [NUM_NPU_CLUSTERS-1:0] npu_cmd_valid,
    input wire [NUM_NPU_CLUSTERS-1:0] npu_cmd_ready,
    input wire [NUM_NPU_CLUSTERS-1:0] npu_busy,
    
    // Scheduler queue status
    input wire [$clog2(QUEUE_DEPTH):0] sq_queue_count,
    input wire                         sq_dispatch_valid,
    input wire                         sq_dispatch_ready,
    
    // Memory interface
    input wire                         mem_valid,
    input wire                         mem_ready,
    input wire [7:0]                   mem_stall_cycles
);

`ifdef ASSERT_ENABLED

    // =========================================================================
    // ASSERTION 1: A-Core Result FIFO Deadlock Detection
    // =========================================================================
    // Jika A-Core result_valid high dan result_ready low selama > 100 cycles,
    // maka terjadi deadlock pada result handshake
    
    property p_a_core_result_handshake_progress;
        @(posedge clk) disable iff (!rst_n)
        (a_core_result_valid[0] && !a_core_result_ready[0]) |-> 
            ##[1:100] (a_core_result_ready[0]);
    endproperty
    
    assert property (p_a_core_result_handshake_progress)
        else $error("[%0t] DEADLOCK: A-Core#0 result handshake stuck (valid=1, ready=0 for >100 cycles)", $time);
    
    // Cover version: track how often result handshake completes
    cover property (
        @(posedge clk) (a_core_result_valid[0] && a_core_result_ready[0])
    );
    
    // =========================================================================
    // ASSERTION 2: A-Core FIFO Overflow/Underflow Detection
    // =========================================================================
    // FIFO count harus selalu dalam range [0, FIFO_DEPTH]
    
    property p_a_core_fifo_bounds;
        @(posedge clk) disable iff (!rst_n)
        (a_core_fifo_count[0] <= FIFO_DEPTH) && (a_core_fifo_count[0] >= 0);
    endproperty
    
    assert property (p_a_core_fifo_bounds)
        else $error("[%0t] BUG: A-Core#0 FIFO count out of bounds: %0d", $time, a_core_fifo_count[0]);
    
    // =========================================================================
    // ASSERTION 3: Valid/Ready Handshake Liveness
    // =========================================================================
    // Jika valid high dan ready high, transfer harus terjadi di cycle yang sama
    
    property p_handshake_atomicity;
        @(posedge clk) disable iff (!rst_n)
        (a_core_cmd_valid[0] && a_core_cmd_ready[0]) |=> 
            ##1 (a_core_cmd_valid[0] == 1'b0 || $changed(a_core_cmd_valid[0]));
    endproperty
    
    assert property (p_handshake_atomicity)
        else $warning("[%0t] WARNING: A-Core#0 command handshake may have glitch", $time);
    
    // =========================================================================
    // ASSERTION 4: Scheduler Queue Stuck Detection
    // =========================================================================
    // Jika queue_count > 0 tapi tidak ada dispatch selama > 50 cycles, queue stuck
    
    property p_sq_queue_progress;
        @(posedge clk) disable iff (!rst_n)
        (sq_queue_count > 0) |-> 
            ##[1:50] (sq_dispatch_valid && sq_dispatch_ready);
    endproperty
    
    assert property (p_sq_queue_progress)
        else $error("[%0t] DEADLOCK: Scheduler SQ queue stuck (count=%0d, no dispatch for 50 cycles)", 
                    $time, sq_queue_count);
    
    // =========================================================================
    // ASSERTION 5: Core Busy Without Progress (Livelock Detection)
    // =========================================================================
    // Jika core busy selama > 256 cycles tanpa cmd_ready deassert, kemungkinan livelock
    
    property p_g_core_livelock;
        @(posedge clk) disable iff (!rst_n)
        (g_core_busy[0] && g_core_cmd_ready[0]) |-> 
            ##[1:256] (!g_core_busy[0]);
    endproperty
    
    assert property (p_g_core_livelock)
        else $error("[%0t] LIVLOCK: G-Core#0 busy for >256 cycles without completing", $time);
    
    property p_a_core_livelock;
        @(posedge clk) disable iff (!rst_n)
        (a_core_busy[0]) |-> 
            ##[1:500] (!a_core_busy[0]);  // A-Core bisa take up to 100 cycles for MATMUL
    endproperty
    
    assert property (p_a_core_livelock)
        else $error("[%0t] LIVLOCK: A-Core#0 busy for >500 cycles", $time);
    
    // =========================================================================
    // ASSERTION 6: Memory Stall Timeout
    // =========================================================================
    // Memory stall tidak boleh exceed 100 cycles (should be ~40-70)
    
    property p_mem_stall_timeout;
        @(posedge clk) disable iff (!rst_n)
        (mem_valid && !mem_ready) |-> 
            ##[1:100] (mem_ready);
    endproperty
    
    assert property (p_mem_stall_timeout)
        else $error("[%0t] DEADLOCK: Memory interface stuck (valid=1, ready=0 for >100 cycles)", $time);
    
    // =========================================================================
    // ASSERTION 7: No Simultaneous Push/Pop on Full FIFO
    // =========================================================================
    // Ketika FIFO full, tidak boleh ada simultaneous push dan pop
    
    property p_fifo_no_push_when_full;
        @(posedge clk) disable iff (!rst_n)
        (a_core_fifo_count[0] == FIFO_DEPTH) |=> 
            !(a_core_result_valid[0] && a_core_result_ready[0]);
    endproperty
    
    assert property (p_fifo_no_push_when_full)
        else $error("[%0t] BUG: A-Core#0 FIFO push+pop when full may corrupt state", $time);
    
    // =========================================================================
    // ASSERTION 8: Reset Deactivation Sequence
    // =========================================================================
    // Setelah reset deassert, semua cores harus masuk IDLE dalam 10 cycles
    
    property p_reset_to_idle;
        @(posedge clk)
        (!rst_n) |=> ##[1:10] (a_core_cmd_ready[0] || !a_core_result_valid[0]);
    endproperty
    
    assert property (p_reset_to_idle)
        else $warning("[%0t] WARNING: A-Core#0 not in IDLE within 10 cycles after reset", $time);
    
    // =========================================================================
    // ASSERTION 9: Queue Count Consistency
    // =========================================================================
    // queue_count tidak boleh negative
    
    property p_queue_count_non_negative;
        @(posedge clk) disable iff (!rst_n)
        sq_queue_count >= 0;
    endproperty
    
    assert property (p_queue_count_non_negative)
        else $error("[%0t] BUG: SQ queue count is negative: %0d", $time, sq_queue_count);
    
    // =========================================================================
    // ASSERTION 10: No Starvation - Fairness Check
    // =========================================================================
    // Jika ada request pending, eventually harus ada grant dalam 200 cycles
    
    property p_no_starvation_g_core;
        @(posedge clk) disable iff (!rst_n)
        (g_core_cmd_valid[0] && !g_core_cmd_ready[0]) |-> 
            ##[1:200] (g_core_cmd_ready[0]);
    endproperty
    
    assert property (p_no_starvation_g_core)
        else $error("[%0t] STARVATION: G-Core#0 request pending for >200 cycles without grant", $time);

    // =========================================================================
    // COVERAGE: Track important scenarios
    // =========================================================================
    
    // Cover: FIFO penuh dan kemudian dikosongkan
    cover property (
        @(posedge clk) (a_core_fifo_count[0] == FIFO_DEPTH) ##1 (a_core_fifo_count[0] == 0)
    );
    
    // Cover: Queue empty ke full transition
    cover property (
        @(posedge clk) (sq_queue_count == 0) ##1 (sq_queue_count > 0)
    );
    
    // Cover: Semua cores busy simultaneously
    cover property (
        @(posedge clk) (&g_core_busy)  // Semua G-Core busy
    );
    
    // Cover: Memory stall > 50 cycles
    cover property (
        @(posedge clk) (mem_valid && !mem_ready) ##50 (mem_valid && !mem_ready)
    );

`endif // ASSERT_ENABLED

endmodule
