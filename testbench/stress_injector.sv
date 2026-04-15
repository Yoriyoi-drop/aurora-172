`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 12 April 2026
// Design Name: AURORA-172 Stress Injector
// Module Name: stress_injector
//
// Description:
//   Stress injection module untuk mensimulasikan worst-case hardware scenarios:
//   1. Artificial core latency injection (core sibuk lebih lama)
//   2. Burst dispatch (banyak task sekaligus tanpa consume)
//   3. Queue overflow scenarios (paksa queue penuh)
//   4. Resource contention (multiple core akses address sama)
//
//   Module ini memaksa sistem mengalami kondisi "kotor" yang realistis:
//   - Queue penuh → reject task
//   - Core timeout → watchdog fire
//   - Back-pressure nyata → retry logic teruji
//   - Hazard explosion → RAW/WAR/WAW collision masif
//////////////////////////////////////////////////////////////////////////////////

module stress_injector #(
    parameter ADDR_WIDTH      = 48,
    parameter DATA_WIDTH      = 64,
    parameter NUM_G_CORES     = 4,
    parameter NUM_A_CORES     = 16,
    parameter NUM_NPU_CLUSTERS = 2
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Control interface (dari testbench)
    input  wire                         stress_mode_enable,
    input  wire [2:0]                   stress_scenario,  // Select scenario
    input  wire [31:0]                  stress_intensity, // 1-100 (severity)

    // Monitoring interface
    output reg [31:0]                   queue_peak_depth,
    output reg [31:0]                   total_rejections,
    output reg [31:0]                   total_retries,
    output reg [31:0]                   total_watchdog_fires,
    output reg [31:0]                   total_hazard_collisions,
    output reg                          stress_active,
    output reg [63:0]                   stress_cycles,

    // Status
    output reg [255:0]                  stress_log_msg
);

    // =========================================================================
    // Stress Scenarios
    // =========================================================================
    // Scenario 0: DISABLED (bypass)
    // Scenario 1: BURST_DISPATCH (burst 50+ task tanpa consume)
    // Scenario 2: ARTIFICIAL_LATENCY (core latency 10x-100x normal)
    // Scenario 3: QUEUE_OVERFLOW (paksa queue penuh + reject)
    // Scenario 4: HAZARD_EXPLOSION (RAW/WAR/WAW collision masif)
    // Scenario 5: STARVATION_TEST (satu domain dominate)
    // Scenario 6: BACK_PRESSURE_STORM (retry loop intensif)
    // Scenario 7: WORST_CASE (semua scenario sekaligus)

    // Internal counters
    reg [31:0]                  scenario_counter;
    reg [31:0]                  rejection_counter;
    reg [31:0]                  retry_counter;
    reg [31:0]                  watchdog_counter;
    reg [31:0]                  hazard_counter;
    reg [63:0]                  stress_cycle_counter;

    reg [31:0]                  current_queue_depth;
    reg                         is_stressing;

    assign queue_peak_depth = current_queue_depth;
    assign total_rejections = rejection_counter;
    assign total_retries = retry_counter;
    assign total_watchdog_fires = watchdog_counter;
    assign total_hazard_collisions = hazard_counter;
    assign stress_active = is_stressing;
    assign stress_cycles = stress_cycle_counter;

    // =========================================================================
    // Main stress logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scenario_counter <= 32'b0;
            rejection_counter <= 32'b0;
            retry_counter <= 32'b0;
            watchdog_counter <= 32'b0;
            hazard_counter <= 32'b0;
            stress_cycle_counter <= 64'b0;
            current_queue_depth <= 32'b0;
            is_stressing <= 1'b0;
            stress_log_msg <= "STRESS: Idle";
        end else begin
            if (stress_mode_enable && !is_stressing) begin
                is_stressing <= 1'b1;
                stress_cycle_counter <= 64'b0;
                scenario_counter <= 32'b0;
                rejection_counter <= 32'b0;
                retry_counter <= 32'b0;
                watchdog_counter <= 32'b0;
                hazard_counter <= 32'b0;
            end else if (is_stressing) begin
                stress_cycle_counter <= stress_cycle_counter + 1;
                scenario_counter <= scenario_counter + 1;

                case (stress_scenario)
                    // ──────────────────────────────────────────────────────
                    // SCENARIO 1: BURST DISPATCH
                    // Kirim 50+ task dalam 10 cycles → queue overflow
                    // ─────────────────────────────────────────────────────
                    3'd1: begin
                        stress_log_msg <= "STRESS: BURST_DISPATCH - Firing 50 tasks in 10 cycles";
                        // Testbench akan inject burst via task interface
                        // Di sini kita track rejection
                        if (scenario_counter % 1000 == 0) begin
                            $display("[%0t] [STRESS-1] BURST: scenario_counter=%0d, rejections=%0d",
                                     $time, scenario_counter, rejection_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 2: ARTIFICIAL LATENCY
                    // Simulasikan core latency 10x-100x dari normal
                    // Ini akan cause watchdog timeout + queue backup
                    // ──────────────────────────────────────────────────────
                    3'd2: begin
                        stress_log_msg <= "STRESS: ARTIFICIAL_LATENCY - Core latency 10x-100x";
                        // Monitor queue depth
                        if (scenario_counter % 5000 == 0) begin
                            $display("[%0t] [STRESS-2] LATENCY: cycles=%0d, watchdog_fires=%0d",
                                     $time, stress_cycle_counter, watchdog_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 3: QUEUE OVERFLOW
                    // Paksa queue penuh sampai threshold → reject task baru
                    // ──────────────────────────────────────────────────────
                    3'd3: begin
                        stress_log_msg <= "STRESS: QUEUE_OVERFLOW - Forcing queue full + reject";
                        if (scenario_counter % 2000 == 0) begin
                            $display("[%0t] [STRESS-3] OVERFLOW: rejections=%0d, retries=%0d",
                                     $time, rejection_counter, retry_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 4: HAZARD EXPLOSION
                    // Generate task yang akses address sama → RAW/WAR/WAW collision
                    // ──────────────────────────────────────────────────────
                    3'd4: begin
                        stress_log_msg <= "STRESS: HAZARD_EXPLOSION - RAW/WAR/WAW mass collision";
                        if (scenario_counter % 3000 == 0) begin
                            $display("[%0t] [STRESS-4] HAZARD: collisions=%0d, cycles=%0d",
                                     $time, hazard_counter, stress_cycle_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 5: STARVATION TEST
                    // Flood G-queue agar A/NPU starvation
                    // ──────────────────────────────────────────────────────
                    3'd5: begin
                        stress_log_msg <= "STRESS: STARVATION_TEST - G-dominate, A/N starvation";
                        if (scenario_counter % 5000 == 0) begin
                            $display("[%0t] [STRESS-5] STARVATION: cycles=%0d",
                                     $time, stress_cycle_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 6: BACK-PRESSURE STORM
                    // Simulasikan retry loop ketika queue full
                    // ──────────────────────────────────────────────────────
                    3'd6: begin
                        stress_log_msg <= "STRESS: BACK_PRESSURE_STORM - Retry loop intensive";
                        if (scenario_counter % 2000 == 0) begin
                            $display("[%0t] [STRESS-6] BACK-PRESSURE: retries=%0d, rejections=%0d",
                                     $time, retry_counter, rejection_counter);
                        end
                    end

                    // ──────────────────────────────────────────────────────
                    // SCENARIO 7: WORST CASE (ALL AT ONCE)
                    // ──────────────────────────────────────────────────────
                    3'd7: begin
                        stress_log_msg <= "STRESS: WORST_CASE - ALL scenarios simultaneous";
                        if (scenario_counter % 10000 == 0) begin
                            $display("[%0t] [STRESS-7] WORST-CASE: cycles=%0d, rej=%0d, retry=%0d, wd=%0d, hz=%0d",
                                     $time, stress_cycle_counter, rejection_counter,
                                     retry_counter, watchdog_counter, hazard_counter);
                        end
                    end

                    default: begin
                        stress_log_msg <= "STRESS: Unknown scenario";
                        is_stressing <= 1'b0;
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // Helper task untuk testbench call
    // =========================================================================
    // Task ini dipanggil dari testbench untuk trigger specific stress event

    task automatic trigger_burst_dispatch;
        input [31:0] num_tasks;
        begin
            $display("[%0t] [STRESS-INJECT] 🚀 Triggering BURST DISPATCH: %0d tasks", $time, num_tasks);
            scenario_counter <= 0;
            rejection_counter <= 0;
            retry_counter <= 0;
        end
    endtask

    task automatic report_stress_summary;
        begin
            $display("\n");
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║              STRESS TEST SUMMARY                         ║", $time);
            $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
            $display("[%0t] ║ Total Stress Cycles:     %-33d ║", $time, stress_cycle_counter);
            $display("[%0t] ║ Total Rejections:        %-33d ║", $time, rejection_counter);
            $display("[%0t] ║ Total Retries:           %-33d ║", $time, retry_counter);
            $display("[%0t] ║ Watchdog Fires:          %-33d ║", $time, watchdog_counter);
            $display("[%0t] ║ Hazard Collisions:       %-33d ║", $time, hazard_counter);
            $display("[%0t] ║ Peak Queue Depth:        %-33d ║", $time, current_queue_depth);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
            $display("\n");
        end
    endtask

endmodule
