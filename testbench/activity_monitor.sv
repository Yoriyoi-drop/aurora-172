`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Activity Monitor
// Module Name: activity_monitor
//
// Description:
//   Comprehensive activity monitor untuk expose SEMUA aktivitas internal
//   yang sebelumnya silent/hidden. Monitor ini akan logging:
//   - Setiap instruction execution di semua core types
//   - Memory access patterns (reads/writes/hits/misses)
//   - Cache coherency state transitions (MESI)
//   - Interconnect packet routing
//   - Power state changes (DVFS)
//   - DMA transfers
//   - Branch predictor behavior
//   - Pipeline stalls & bubbles
//
// Usage: Instantiate di testbench atau di top-level untuk monitoring
//////////////////////////////////////////////////////////////////////////////////

module activity_monitor #(
    parameter NUM_G_CORES       = 16,
    parameter NUM_H_CORES       = 32,
    parameter NUM_A_CORES       = 64,
    parameter NUM_NPU_CLUSTERS  = 8,
    parameter DATA_WIDTH        = 64,
    parameter ADDR_WIDTH        = 48
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // =========================================================================
    // G-Core Activity
    // =========================================================================
    input  wire [NUM_G_CORES-1:0]       g_core_active,
    input  wire [NUM_G_CORES-1:0]       g_core_busy,
    input  wire [NUM_G_CORES-1:0][3:0]  g_core_pipeline_state,
    input  wire [NUM_G_CORES-1:0]       g_core_branch_mispredict,
    input  wire [NUM_G_CORES-1:0]       g_core_cache_hit,
    input  wire [NUM_G_CORES-1:0]       g_core_cache_miss,

    // =========================================================================
    // H-Core Activity
    // =========================================================================
    input  wire [NUM_H_CORES-1:0]       h_core_active,
    input  wire [NUM_H_CORES-1:0]       h_core_busy,
    input  wire [NUM_H_CORES-1:0][3:0]  h_core_pipeline_state,
    input  wire [NUM_H_CORES-1:0]       h_core_rob_full,
    input  wire [NUM_H_CORES-1:0]       h_core_reorder_buffer_busy,

    // =========================================================================
    // A-Core Activity
    // =========================================================================
    input  wire [NUM_A_CORES-1:0]       a_core_active,
    input  wire [NUM_A_CORES-1:0]       a_core_mac_active,
    input  wire [NUM_A_CORES-1:0]       a_core_matmul_complete,

    // =========================================================================
    // NPU Activity
    // =========================================================================
    input  wire [NUM_NPU_CLUSTERS-1:0]  npu_active,
    input  wire [NUM_NPU_CLUSTERS-1:0]  npu_pe_active,

    // =========================================================================
    // Memory Fabric Activity
    // =========================================================================
    input  wire                         mem_fabric_active,
    input  wire                         mem_rd_req,
    input  wire                         mem_wr_req,
    input  wire                         mem_cache_hit,
    input  wire                         mem_cache_miss,
    input  wire                         mem_writeback,
    input  wire [ADDR_WIDTH-1:0]        mem_last_addr,
    input  wire [DATA_WIDTH-1:0]        mem_last_data,

    // =========================================================================
    // Cache Coherency Activity
    // =========================================================================
    input  wire                         coherence_snoop_req,
    input  wire                         coherence_invalidate,
    input  wire                         coherence_writeback,
    input  wire [1:0]                   coherence_state_modified,  // MESI state

    // =========================================================================
    // Power Management Activity
    // =========================================================================
    input  wire [7:0]                   dvfs_current_freq,
    input  wire                         power_gate_active,
    input  wire                         thermal_throttle,
    input  wire [31:0]                  power_consumption_mw,

    // =========================================================================
    // DMA Activity
    // =========================================================================
    input  wire [7:0]                   dma_channel_active,
    input  wire [7:0]                   dma_transfer_complete,
    input  wire [7:0]                   dma_error,
    input  wire [31:0]                  dma_bytes_transferred,

    // =========================================================================
    // Interconnect Activity
    // =========================================================================
    input  wire                         fabric_packet_valid,
    input  wire [6:0]                   fabric_packet_src,
    input  wire [6:0]                   fabric_packet_dst,
    input  wire                         fabric_contention,

    // =========================================================================
    // Branch Predictor Activity
    // =========================================================================
    input  wire                         bp_prediction,
    input  wire                         bp_actual,
    input  wire                         bp_update,

    // =========================================================================
    // Debug Output Interface
    // =========================================================================
    output reg                          monitor_event_detected,
    output reg [63:0]                   total_events,
    output reg [63:0]                   g_core_instructions_executed,
    output reg [63:0]                   h_core_instructions_executed,
    output reg [63:0]                   a_core_operations,
    output reg [63:0]                   npu_operations,
    output reg [63:0]                   mem_reads,
    output reg [63:0]                   mem_writes,
    output reg [63:0]                   cache_hits,
    output reg [63:0]                   cache_misses,
    output reg [63:0]                   bp_correct,
    output reg [63:0]                   bp_mispredicts,
    output reg [63:0]                   coherence_events,
    output reg [63:0]                   dma_transfers,
    output reg [63:0]                   power_state_changes,
    output reg [63:0]                   fabric_packets
);

    // =========================================================================
    // Internal counters & registers
    // =========================================================================
    reg [63:0] event_counter = 0;
    reg [63:0] g_core_inst_counter = 0;
    reg [63:0] h_core_inst_counter = 0;
    reg [63:0] a_core_op_counter = 0;
    reg [63:0] npu_op_counter = 0;
    reg [63:0] mem_rd_counter = 0;
    reg [63:0] mem_wr_counter = 0;
    reg [63:0] cache_hit_counter = 0;
    reg [63:0] cache_miss_counter = 0;
    reg [63:0] bp_correct_counter = 0;
    reg [63:0] bp_mispredict_counter = 0;
    reg [63:0] coherence_counter = 0;
    reg [63:0] dma_counter = 0;
    reg [63:0] power_change_counter = 0;
    reg [63:0] fabric_counter = 0;

    reg [7:0] prev_dvfs_freq = 0;
    reg prev_bp_prediction = 0;
    reg prev_bp_actual = 0;

    // =========================================================================
    // Event detection logic - detect EVERYTHING
    // =========================================================================
    wire any_g_core_active = |g_core_active;
    wire any_g_core_branched = |g_core_branch_mispredict;
    wire any_g_core_cache_access = |g_core_cache_hit | |g_core_cache_miss;

    wire any_h_core_active = |h_core_active;
    wire any_h_core_rob_event = |h_core_rob_full;

    wire any_a_core_active = |a_core_active;
    wire any_a_core_matmul = |a_core_matmul_complete;

    wire any_npu_active = |npu_active;

    wire any_mem_access = mem_rd_req | mem_wr_req;
    wire any_cache_event = mem_cache_hit | mem_cache_miss | mem_writeback;

    wire any_coherence_event = coherence_snoop_req | coherence_invalidate | coherence_writeback;

    wire any_dma_event = |dma_transfer_complete;
    wire any_dma_error = |dma_error;

    wire bp_correct_event = (bp_prediction == bp_actual) && bp_update;
    wire bp_mispredict_event = (bp_prediction != bp_actual) && bp_update;

    wire power_state_change = (dvfs_current_freq != prev_dvfs_freq);

    // =========================================================================
    // Main monitoring logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_counter <= 0;
            g_core_inst_counter <= 0;
            h_core_inst_counter <= 0;
            a_core_op_counter <= 0;
            npu_op_counter <= 0;
            mem_rd_counter <= 0;
            mem_wr_counter <= 0;
            cache_hit_counter <= 0;
            cache_miss_counter <= 0;
            bp_correct_counter <= 0;
            bp_mispredict_counter <= 0;
            coherence_counter <= 0;
            dma_counter <= 0;
            power_change_counter <= 0;
            fabric_counter <= 0;
            prev_dvfs_freq <= 0;
            prev_bp_prediction <= 0;
            prev_bp_actual <= 0;
        end else begin
            // =================================================================
            // Global event counter
            // =================================================================
            if (any_g_core_active | any_h_core_active | any_a_core_active |
                any_npu_active | any_mem_access | any_coherence_event |
                any_dma_event | fabric_packet_valid) begin
                event_counter <= event_counter + 1;
            end

            // =================================================================
            // G-Core instruction tracking
            // =================================================================
            if (any_g_core_active) begin
                // Count active cores
                for (int i = 0; i < NUM_G_CORES; i++) begin
                    if (g_core_active[i]) begin
                        g_core_inst_counter <= g_core_inst_counter + 1;

                        // Detailed logging per core
                        case (g_core_pipeline_state[i])
                            4'b0001: $display("[%0t] [G-CORE-%0d] >> FETCH", $time, i);
                            4'b0010: $display("[%0t] [G-CORE-%0d]    DECODE", $time, i);
                            4'b0011: $display("[%0t] [G-CORE-%0d]       EXECUTE", $time, i);
                            4'b0100: $display("[%0t] [G-CORE-%0d]          MEMORY", $time, i);
                            4'b0101: $display("[%0t] [G-CORE-%0d]             WRITEBACK", $time, i);
                            default: ;
                        endcase
                    end
                end
            end

            // Cache activity
            for (int i = 0; i < NUM_G_CORES; i++) begin
                if (g_core_cache_hit[i]) begin
                    cache_hit_counter <= cache_hit_counter + 1;
                    $display("[%0t] [G-CORE-%0d] [L1-HIT] ✓", $time, i);
                end
                if (g_core_cache_miss[i]) begin
                    cache_miss_counter <= cache_miss_counter + 1;
                    $display("[%0t] [G-CORE-%0d] [L1-MISS] ✗ → Fetching from L2", $time, i);
                end
            end

            // Branch mispredictions
            for (int i = 0; i < NUM_G_CORES; i++) begin
                if (g_core_branch_mispredict[i]) begin
                    bp_mispredict_counter <= bp_mispredict_counter + 1;
                    $display("[%0t] [G-CORE-%0d] [BRANCH] ✗ MISPREDICT → Pipeline flush!", $time, i);
                end
            end

            // =================================================================
            // H-Core instruction tracking
            // =================================================================
            if (any_h_core_active) begin
                for (int i = 0; i < NUM_H_CORES; i++) begin
                    if (h_core_active[i]) begin
                        h_core_inst_counter <= h_core_inst_counter + 1;

                        if (h_core_rob_full[i]) begin
                            $display("[%0t] [H-CORE-%0d] [ROB] FULL → Stalling fetch", $time, i);
                        end
                    end
                end
            end

            // =================================================================
            // A-Core operation tracking
            // =================================================================
            if (any_a_core_active) begin
                for (int i = 0; i < NUM_A_CORES; i++) begin
                    if (a_core_active[i]) begin
                        a_core_op_counter <= a_core_op_counter + 1;

                        if (a_core_mac_active[i]) begin
                            $display("[%0t] [A-CORE-%0d] [MAC] Active", $time, i);
                        end
                    end
                end
            end

            // Matmul completions
            if (any_a_core_matmul) begin
                for (int i = 0; i < NUM_A_CORES; i++) begin
                    if (a_core_matmul_complete[i]) begin
                        $display("[%0t] [A-CORE-%0d] [MATMUL] ✓ Complete", $time, i);
                    end
                end
            end

            // =================================================================
            // NPU tracking
            // =================================================================
            if (any_npu_active) begin
                for (int i = 0; i < NUM_NPU_CLUSTERS; i++) begin
                    if (npu_active[i]) begin
                        npu_op_counter <= npu_op_counter + 1;

                        if (npu_pe_active[i]) begin
                            $display("[%0t] [NPU-%0d] [PE] Processing Elements Active", $time, i);
                        end
                    end
                end
            end

            // =================================================================
            // Memory fabric tracking
            // =================================================================
            if (mem_rd_req) begin
                mem_rd_counter <= mem_rd_counter + 1;
                $display("[%0t] [MEM] >>> READ req addr=0x%h", $time, mem_last_addr);
            end

            if (mem_wr_req) begin
                mem_wr_counter <= mem_wr_counter + 1;
                $display("[%0t] [MEM] <<< WRITE req addr=0x%h data=0x%h", $time, mem_last_addr, mem_last_data);
            end

            if (mem_cache_hit) begin
                cache_hit_counter <= cache_hit_counter + 1;
                $display("[%0t] [MEM] [L2-HIT] ✓", $time);
            end

            if (mem_cache_miss) begin
                cache_miss_counter <= cache_miss_counter + 1;
                $display("[%0t] [MEM] [L2-MISS] ✗ → Fetching from L3/HBM", $time);
            end

            if (mem_writeback) begin
                $display("[%0t] [MEM] [WRITEBACK] Dirty line → Memory", $time);
            end

            // =================================================================
            // Cache coherency tracking
            // =================================================================
            if (any_coherence_event) begin
                coherence_counter <= coherence_counter + 1;

                if (coherence_snoop_req) begin
                    $display("[%0t] [COHERENCE] Snoop request broadcast", $time);
                end

                if (coherence_invalidate) begin
                    $display("[%0t] [COHERENCE] Invalidate → Cache line invalidated", $time);
                end

                if (coherence_writeback) begin
                    $display("[%0t] [COHERENCE] Writeback → Modified data written", $time);
                end

                case (coherence_state_modified)
                    2'b00: $display("[%0t] [COHERENCE] State → Modified (M)", $time);
                    2'b01: $display("[%0t] [COHERENCE] State → Exclusive (E)", $time);
                    2'b10: $display("[%0t] [COHERENCE] State → Shared (S)", $time);
                    2'b11: $display("[%0t] [COHERENCE] State → Invalid (I)", $time);
                endcase
            end

            // =================================================================
            // Power management tracking
            // =================================================================
            if (power_state_change) begin
                power_change_counter <= power_change_counter + 1;
                $display("[%0t] [POWER] DVFS freq change: %0d → %0d MHz", $time, prev_dvfs_freq, dvfs_current_freq);
                prev_dvfs_freq <= dvfs_current_freq;
            end

            if (power_gate_active) begin
                $display("[%0t] [POWER] Power gating active", $time);
            end

            if (thermal_throttle) begin
                $display("[%0t] [POWER] ⚠ THERMAL THROTTLING ENGAGED", $time);
            end

            // =================================================================
            // DMA tracking
            // =================================================================
            if (any_dma_event) begin
                for (int i = 0; i < 8; i++) begin
                    if (dma_transfer_complete[i]) begin
                        dma_counter <= dma_counter + 1;
                        $display("[%0t] [DMA] Channel %0d transfer complete", $time, i);
                    end
                end
            end

            if (any_dma_error) begin
                for (int i = 0; i < 8; i++) begin
                    if (dma_error[i]) begin
                        $display("[%0t] [DMA] ⚠ Channel %0d ERROR", $time, i);
                    end
                end
            end

            // =================================================================
            // Interconnect tracking
            // =================================================================
            if (fabric_packet_valid) begin
                fabric_counter <= fabric_counter + 1;
                $display("[%0t] [FABRIC] Packet: src=%0d → dst=%0d", $time, fabric_packet_src, fabric_packet_dst);

                if (fabric_contention) begin
                    $display("[%0t] [FABRIC] ⚠ Contention detected", $time);
                end
            end

            // =================================================================
            // Branch predictor tracking
            // =================================================================
            if (bp_update) begin
                prev_bp_prediction <= bp_prediction;
                prev_bp_actual <= bp_actual;

                if (bp_correct_event) begin
                    bp_correct_counter <= bp_correct_counter + 1;
                end

                if (bp_mispredict_event) begin
                    bp_mispredict_counter <= bp_mispredict_counter + 1;
                end
            end
        end
    end

    // =========================================================================
    // Output assignments
    // =========================================================================
    assign monitor_event_detected = (event_counter > 0);
    assign total_events = event_counter;
    assign g_core_instructions_executed = g_core_inst_counter;
    assign h_core_instructions_executed = h_core_inst_counter;
    assign a_core_operations = a_core_op_counter;
    assign npu_operations = npu_op_counter;
    assign mem_reads = mem_rd_counter;
    assign mem_writes = mem_wr_counter;
    assign cache_hits = cache_hit_counter;
    assign cache_misses = cache_miss_counter;
    assign bp_correct = bp_correct_counter;
    assign bp_mispredicts = bp_mispredict_counter;
    assign coherence_events = coherence_counter;
    assign dma_transfers = dma_counter;
    assign power_state_changes = power_change_counter;
    assign fabric_packets = fabric_counter;

    // =========================================================================
    // Periodic summary (every 10000 cycles)
    // =========================================================================
    reg [31:0] summary_counter = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            summary_counter <= 0;
        end else begin
            summary_counter <= summary_counter + 1;

            if (summary_counter == 32'd10000) begin
                summary_counter <= 0;

                $display("\n");
                $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
                $display("[%0t] ║         AURORA-172 ACTIVITY SUMMARY (10K cycles)        ║", $time);
                $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
                $display("[%0t] ║ G-Core Instructions:  %-40d ║", $time, g_core_inst_counter);
                $display("[%0t] ║ H-Core Instructions:  %-40d ║", $time, h_core_inst_counter);
                $display("[%0t] ║ A-Core Operations:    %-40d ║", $time, a_core_op_counter);
                $display("[%0t] ║ NPU Operations:       %-40d ║", $time, npu_op_counter);
                $display("[%0t] ║----------------------------------------------------------║", $time);
                $display("[%0t] ║ Memory Reads:         %-40d ║", $time, mem_rd_counter);
                $display("[%0t] ║ Memory Writes:        %-40d ║", $time, mem_wr_counter);
                $display("[%0t] ║ Cache Hits:           %-40d ║", $time, cache_hit_counter);
                $display("[%0t] ║ Cache Misses:         %-40d ║", $time, cache_miss_counter);
                $display("[%0t] ║----------------------------------------------------------║", $time);
                $display("[%0t] ║ Branch Predict:       %-40d ║", $time, bp_correct_counter);
                $display("[%0t] ║ Branch Mispredicts:   %-40d ║", $time, bp_mispredict_counter);
                $display("[%0t] ║----------------------------------------------------------║", $time);
                $display("[%0t] ║ Coherence Events:     %-40d ║", $time, coherence_counter);
                $display("[%0t] ║ DMA Transfers:        %-40d ║", $time, dma_counter);
                $display("[%0t] ║ Power State Changes:  %-40d ║", $time, power_change_counter);
                $display("[%0t] ║ Fabric Packets:       %-40d ║", $time, fabric_counter);
                $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
                $display("\n");
            end
        end
    end

endmodule
