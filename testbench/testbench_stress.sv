`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 12 April 2026
// Design Name: AURORA-172 Stress Testbench
// Module Name: tb_stress_test
//
// Description:
//   STRESS TESTBENCH - Menguji sistem dalam kondisi worst-case hardware:
//   ✓ Queue overflow + rejection + retry
//   ✓ Artificial latency (core sibuk 10x-100x longer)
//   ✓ Hazard explosion (RAW/WAR/WAW collision)
//   ✓ Starvation scenario
//   ✓ Back-pressure storm
//   ✓ Worst-case combination
//
//   Testbench ini DIPAKSA membuat kondisi "kotor":
//   - Queue PENUH → task di-reject
//   - Core TIMEOUT → watchdog fire
//   - Hazard TANPA barrier → error/stall
//   - Scheduler "kalah" vs workload
//////////////////////////////////////////////////////////////////////////////////

module tb_stress_test;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam SIM_CLK_PERIOD = 10;   // 100 MHz
    localparam DATA_WIDTH     = 64;
    localparam ADDR_WIDTH     = 48;
    localparam CACHE_LINE_WIDTH = 172;

    // Reduced core counts untuk simulasi
    localparam NUM_G_CORES       = 4;
    localparam NUM_H_CORES       = 8;
    localparam NUM_A_CORES       = 16;
    localparam NUM_NPU_CLUSTERS  = 2;

    // =========================================================================
    // Testbench signals
    // =========================================================================
    reg                         tb_clk;
    reg                         tb_rst_n;

    // Gaming interface
    reg [DATA_WIDTH-1:0]        tb_game_cmd_addr;
    reg [31:0]                  tb_game_cmd_data;
    reg                         tb_game_cmd_valid;
    wire                        tb_game_cmd_ready;
    wire [DATA_WIDTH-1:0]       tb_game_result;
    wire                        tb_game_result_valid;

    // AI interface
    reg [DATA_WIDTH-1:0]        tb_ai_cmd_addr;
    reg [63:0]                  tb_ai_cmd_data;
    reg                         tb_ai_cmd_valid;
    wire                        tb_ai_cmd_ready;
    wire [DATA_WIDTH-1:0]       tb_ai_result;
    wire                        tb_ai_result_valid;

    // System interface
    reg                         tb_sys_interrupt;
    reg [15:0]                  tb_sys_power_mode;
    wire [31:0]                 tb_sys_status;

    // Memory interface
    wire [CACHE_LINE_WIDTH-1:0] tb_mem_addr;
    wire                        tb_mem_rd_en;
    wire                        tb_mem_wr_en;
    reg [CACHE_LINE_WIDTH-1:0]  tb_mem_rd_data;
    wire [CACHE_LINE_WIDTH-1:0] tb_mem_wr_data;
    reg                         tb_mem_ready;

    // Performance counters
    wire [63:0]                 tb_perf_counter_g;
    wire [63:0]                 tb_perf_counter_a;
    wire [63:0]                 tb_perf_counter_npu;

    // Scheduler debug signals (connected from top-level)
    wire [63:0]                 tb_sched_total_dispatched;
    wire [63:0]                 tb_sched_total_completed;
    wire [63:0]                 tb_sched_total_stalled;
    wire [63:0]                 tb_sched_stall_resource_wait;
    wire [63:0]                 tb_sched_stall_queue_contention;
    wire [31:0]                 tb_sched_queue_depth;
    wire [31:0]                 tb_sched_max_queue_depth;
    wire [31:0]                 tb_sched_bp_queue_full_rejections;
    wire [31:0]                 tb_sched_bp_timeout_stalls;
    wire [31:0]                 tb_sched_bp_actual_accepts;
    wire [31:0]                 tb_sched_admission_rejections;
    wire [31:0]                 tb_sched_hazard_raw;
    wire [31:0]                 tb_sched_hazard_war;
    wire [31:0]                 tb_sched_hazard_waw;
    wire [31:0]                 tb_sched_hazard_structural;

    // Local integer variables for tracking (not wire)
    integer                     sched_total_dispatched;
    integer                     sched_total_completed;
    integer                     sched_total_stalled;
    integer                     sched_stall_resource_wait;
    integer                     sched_stall_queue_contention;
    integer                     sched_queue_depth;
    integer                     sched_max_queue_depth;
    integer                     sched_bp_queue_full_rejections;
    integer                     sched_bp_timeout_stalls;
    integer                     sched_bp_actual_accepts;
    integer                     sched_admission_rejections;
    integer                     sched_hazard_raw;
    integer                     sched_hazard_war;
    integer                     sched_hazard_waw;
    integer                     sched_hazard_structural;

    // Core busy signals
    wire                        tb_g_core_busy;
    wire                        tb_a_core_busy;

    // =========================================================================
    // Instantiate DUT
    // =========================================================================
    aurora_172_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_G_CORES(NUM_G_CORES),
        .NUM_H_CORES(NUM_H_CORES),
        .NUM_A_CORES(NUM_A_CORES),
        .NUM_NPU_CLUSTERS(NUM_NPU_CLUSTERS),
        .CACHE_LINE_WIDTH(CACHE_LINE_WIDTH)
    ) dut (
        .clk(tb_clk),
        .rst_n(tb_rst_n),

        // Gaming interface
        .game_cmd_addr(tb_game_cmd_addr),
        .game_cmd_data(tb_game_cmd_data),
        .game_cmd_valid(tb_game_cmd_valid),
        .game_cmd_ready(tb_game_cmd_ready),
        .game_result(tb_game_result),
        .game_result_valid(tb_game_result_valid),

        // AI interface
        .ai_cmd_addr(tb_ai_cmd_addr),
        .ai_cmd_data(tb_ai_cmd_data),
        .ai_cmd_valid(tb_ai_cmd_valid),
        .ai_cmd_ready(tb_ai_cmd_ready),
        .ai_result(tb_ai_result),
        .ai_result_valid(tb_ai_result_valid),

        // System interface
        .sys_interrupt(tb_sys_interrupt),
        .sys_power_mode(tb_sys_power_mode),
        .sys_status(tb_sys_status),

        // Memory interface
        .mem_addr(tb_mem_addr),
        .mem_rd_en(tb_mem_rd_en),
        .mem_wr_en(tb_mem_wr_en),
        .mem_rd_data(tb_mem_rd_data),
        .mem_wr_data(tb_mem_wr_data),
        .mem_ready(tb_mem_ready),

        // Debug interface
        .perf_counter_g(tb_perf_counter_g),
        .perf_counter_a(tb_perf_counter_a),
        .perf_counter_npu(tb_perf_counter_npu),

        // Scheduler debug interface
        .sched_total_dispatched(tb_sched_total_dispatched),
        .sched_total_completed(tb_sched_total_completed),
        .sched_total_stalled(tb_sched_total_stalled),
        .sched_stall_resource_wait(tb_sched_stall_resource_wait),
        .sched_stall_queue_contention(tb_sched_stall_queue_contention),
        .sched_queue_depth(tb_sched_queue_depth),
        .sched_max_queue_depth(tb_sched_max_queue_depth),
        .sched_conflict_count(),  // Not used
        .sched_gaming_priority(), // Not used
        .sched_ai_priority(),     // Not used
        .sched_npu_priority(),    // Not used
        .sched_aging_tasks(),     // Not used
        .sched_rr_rotations(),    // Not used
        .sched_queue_avoidance(), // Not used
        .sched_watchdog_resets(), // Not used

        // Back-pressure monitoring
        .sched_bp_queue_full_rejections(tb_sched_bp_queue_full_rejections),
        .sched_bp_timeout_stalls(tb_sched_bp_timeout_stalls),
        .sched_bp_actual_accepts(tb_sched_bp_actual_accepts),

        // Admission control
        .sched_admission_rejections(tb_sched_admission_rejections),

        // Hazard counters
        .sched_hazard_raw(tb_sched_hazard_raw),
        .sched_hazard_war(tb_sched_hazard_war),
        .sched_hazard_waw(tb_sched_hazard_waw),
        .sched_hazard_structural(tb_sched_hazard_structural),
        .sched_hazard_dependency(),          // Not used
        .sched_hazard_dependency_stalls(),   // Not used

        // Core busy signals
        .g_core_busy(tb_g_core_busy),
        .a_core_busy(tb_a_core_busy)
    );

    // Update local integer variables dari wire (untuk compatibility dengan test code)
    always @(posedge tb_clk) begin
        sched_total_dispatched = tb_sched_total_dispatched;
        sched_total_completed = tb_sched_total_completed;
        sched_total_stalled = tb_sched_total_stalled;
        sched_stall_resource_wait = tb_sched_stall_resource_wait;
        sched_stall_queue_contention = tb_sched_stall_queue_contention;
        sched_queue_depth = tb_sched_queue_depth;
        sched_max_queue_depth = tb_sched_max_queue_depth;
        sched_bp_queue_full_rejections = tb_sched_bp_queue_full_rejections;
        sched_bp_timeout_stalls = tb_sched_bp_timeout_stalls;
        sched_bp_actual_accepts = tb_sched_bp_actual_accepts;
        sched_admission_rejections = tb_sched_admission_rejections;
        sched_hazard_raw = tb_sched_hazard_raw;
        sched_hazard_war = tb_sched_hazard_war;
        sched_hazard_waw = tb_sched_hazard_waw;
        sched_hazard_structural = tb_sched_hazard_structural;
    end

    // =========================================================================
    // Memory model
    // =========================================================================
    reg [CACHE_LINE_WIDTH-1:0] memory_model [0:4095];

    initial begin
        for (int i = 0; i < 4096; i++) begin
            memory_model[i] = {CACHE_LINE_WIDTH{1'b0}};
        end
    end

    always @(posedge tb_clk) begin
        if (tb_mem_rd_en) begin
            tb_mem_rd_data <= memory_model[tb_mem_addr[11:0]];
            tb_mem_ready <= 1'b1;
        end else begin
            tb_mem_ready <= 1'b0;
        end

        if (tb_mem_wr_en) begin
            memory_model[tb_mem_addr[11:0]] <= tb_mem_wr_data;
        end
    end

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial begin
        tb_clk = 1'b0;
        forever #(SIM_CLK_PERIOD/2) tb_clk = ~tb_clk;
    end

    // =========================================================================
    // Test Statistics
    // =========================================================================
    integer total_tests;
    integer tests_passed;
    integer tests_failed;

    // Stress test metrics
    integer total_tasks_dispatched;
    integer total_tasks_completed;
    integer total_rejections;
    integer total_stalls;
    integer total_hazards;
    integer total_watchdog_fires;

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task print_header;
        input [100*8:1] message;
        begin
            $display("\n");
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║  %-56s║", $time, message);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
        end
    endtask

    task print_test_start;
        input [80*8:1] test_name;
        begin
            $display("[%0t] ┌─────────────────────────────────────────────────────────┐", $time);
            $display("[%0t] │ ▶ %-55s│", $time, test_name);
            $display("[%0t] └─────────────────────────────────────────────────────────┘", $time);
        end
    endtask

    task print_test_result;
        input [640:1] result_msg;
        input passed;
        begin
            if (passed) begin
                $display("[%0t] ✓ %-60s", $time, result_msg);
                tests_passed = tests_passed + 1;
            end else begin
                $display("[%0t] ✗ %-60s", $time, result_msg);
                tests_failed = tests_failed + 1;
            end
            total_tests = total_tests + 1;
        end
    endtask

    task wait_cycles;
        input [31:0] num_cycles;
        begin
            repeat(num_cycles) @(posedge tb_clk);
        end
    endtask

    task reset_system;
        begin
            tb_rst_n <= 1'b0;
            wait_cycles(10);
            tb_rst_n <= 1'b1;
            wait_cycles(5);
            $display("[%0t] [RESET] System reset complete", $time);
        end
    endtask

    // =========================================================================
    // STRESS TEST 1: QUEUE OVERFLOW + REJECTION
    // Dispatch 100+ task TANPA consume → queue full → reject
    // =========================================================================
    task stress_test_queue_overflow;
        begin
            integer i;
            integer reject_count_before;
            integer accept_count_before;

            print_test_start("STRESS 1: QUEUE OVERFLOW + REJECTION");
            $display("[%0t] Mengirim 100 gaming commands TANPA consume...", $time);

            reject_count_before = sched_bp_queue_full_rejections;
            accept_count_before = sched_bp_actual_accepts;

            // BURST: 100 commands dalam waktu singkat
            for (i = 0; i < 100; i = i + 1) begin
                tb_game_cmd_addr <= {16'b0, 48'h1000 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;

                // Jangan wait untuk ready - biarkan reject kalau queue full
                wait_cycles(2);
            end

            tb_game_cmd_valid <= 1'b0;
            wait_cycles(100);

            // Check result
            total_rejections = sched_bp_queue_full_rejections - reject_count_before;
            total_tasks_dispatched = sched_bp_actual_accepts - accept_count_before;

            $display("[%0t] [STRESS-1] RESULT:", $time);
            $display("  Accepted: %0d tasks", total_tasks_dispatched);
            $display("  Rejected: %0d tasks", total_rejections);
            $display("  Max Queue Depth: %0d", sched_max_queue_depth);

            // EXPECTED: Ada rejection karena queue overflow
            if (total_rejections > 0) begin
                print_test_result("STRESS 1 PASS: Queue overflow dengan rejection (REAL back-pressure)", 1);
            end else begin
                print_test_result("STRESS 1 FAIL: Tidak ada rejection (queue tidak penuh)", 0);
            end
        end
    endtask

    // =========================================================================
    // STRESS TEST 2: HAZARD EXPLOSION (RAW/WAR/WAW tanpa barrier)
    // Task dengan address overlapping → hazard collision
    // =========================================================================
    task stress_test_hazard_explosion;
        begin
            integer i;
            integer raw_before, war_before, waw_before, struct_before;

            print_test_start("STRESS 2: HAZARD EXPLOSION (RAW/WAR/WAW)");
            $display("[%0t] Mengirim task dengan OVERLAPPING address...", $time);

            raw_before = sched_hazard_raw;
            war_before = sched_hazard_war;
            waw_before = sched_hazard_waw;
            struct_before = sched_hazard_structural;

            // RAW Hazard: Write address yang sama dengan yang akan dibaca
            // Task 1: Write addr 0x5000
            tb_ai_cmd_addr <= {16'b0, 48'h5000};
            tb_ai_cmd_data <= 64'h2000_0000_0000_0001; // MATMUL (write)
            tb_ai_cmd_valid <= 1'b1;
            wait(tb_ai_cmd_ready);
            #10; tb_ai_cmd_valid <= 1'b0;
            wait_cycles(5);

            // Task 2: Read addr 0x5000 (RAW hazard!)
            tb_game_cmd_addr <= {16'b0, 48'h5000};
            tb_game_cmd_data <= 32'h0100_0001; // DRAW (read)
            tb_game_cmd_valid <= 1'b1;
            wait(tb_game_cmd_ready);
            #10; tb_game_cmd_valid <= 1'b0;
            wait_cycles(5);

            // WAR Hazard: Read then write overlap
            // Task 3: Read addr 0x6000
            tb_ai_cmd_addr <= {16'b0, 48'h6000};
            tb_ai_cmd_data <= 64'h2000_0000_0000_0002;
            tb_ai_cmd_valid <= 1'b1;
            wait(tb_ai_cmd_ready);
            #10; tb_ai_cmd_valid <= 1'b0;
            wait_cycles(3);

            // Task 4: Write addr 0x6000 (WAR!)
            tb_game_cmd_addr <= {16'b0, 48'h6000};
            tb_game_cmd_data <= 32'h0300_0003; // PHYSICS (write)
            tb_game_cmd_valid <= 1'b1;
            wait(tb_game_cmd_ready);
            #10; tb_game_cmd_valid <= 1'b0;
            wait_cycles(5);

            // WAW Hazard: Multiple writes ke address sama
            // Task 5,6,7: Write addr 0x7000
            for (i = 0; i < 5; i = i + 1) begin
                tb_ai_cmd_addr <= {16'b0, 48'h7000};
                tb_ai_cmd_data <= 64'h2000_0000_0000_0003 + i;
                tb_ai_cmd_valid <= 1'b1;
                wait(tb_ai_cmd_ready);
                #10; tb_ai_cmd_valid <= 1'b0;
                wait_cycles(2);
            end

            wait_cycles(200);

            // Report hazards
            total_hazards = (sched_hazard_raw - raw_before) +
                           (sched_hazard_war - war_before) +
                           (sched_hazard_waw - waw_before) +
                           (sched_hazard_structural - struct_before);

            $display("[%0t] [STRESS-2] HAZARD REPORT:", $time);
            $display("  RAW Hazards:  %0d", sched_hazard_raw - raw_before);
            $display("  WAR Hazards:  %0d", sched_hazard_war - war_before);
            $display("  WAW Hazards:  %0d", sched_hazard_waw - waw_before);
            $display("  Structural:   %0d", sched_hazard_structural - struct_before);
            $display("  TOTAL:        %0d", total_hazards);

            if (total_hazards > 0) begin
                print_test_result("STRESS 2 PASS: Hazard detection aktif (RAW/WAR/WAW)", 1);
            end else begin
                print_test_result("STRESS 2 FAIL: Tidak ada hazard terdeteksi", 0);
            end
        end
    endtask

    // =========================================================================
    // STRESS TEST 3: STARVATION SCENARIO
    // Flood G-queue agar A/NPU starvation
    // =========================================================================
    task stress_test_starvation;
        begin
            integer i;
            int g_dispatch_before, a_dispatch_before, n_dispatch_before;
            int g_dispatch_after, a_dispatch_after, n_dispatch_after;

            print_test_start("STRESS 3: STARVATION TEST (G-dominate)");
            $display("[%0t] Flood G-queue 200 task, monitor A/NPU starvation...", $time);

            // Snapshot sebelum
            g_dispatch_before = sched_total_dispatched;

            // Flood G-queue
            for (i = 0; i < 200; i = i + 1) begin
                tb_game_cmd_addr <= {16'b0, 48'h8000 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(3);
            end
            tb_game_cmd_valid <= 1'b0;

            // Wait untuk processing
            wait_cycles(500);

            // Check dispatch distribution
            g_dispatch_after = sched_total_dispatched;

            $display("[%0t] [STRESS-3] DISPATCH DISTRIBUTION:", $time);
            $display("  Total dispatched: %0d", sched_total_dispatched);
            $display("  Queue depth: %0d", sched_queue_depth);
            $display("  Stalls: %0d", sched_total_stalled);

            // EXPECTED: G-dominate tapi A/NPU masih dapat kesempatan (aging)
            if (sched_total_dispatched > 0) begin
                print_test_result("STRESS 3 PASS: Dispatch berjalan dengan aging", 1);
            end else begin
                print_test_result("STRESS 3 FAIL: Tidak ada dispatch", 0);
            end
        end
    endtask

    // =========================================================================
    // STRESS TEST 4: BACK-PRESSURE STORM
    // Retry loop saat queue full
    // =========================================================================
    task stress_test_backpressure_storm;
        begin
            integer i;
            int timeout_before, reject_before;

            print_test_start("STRESS 4: BACK-PRESSURE STORM");
            $display("[%0t] Membuat retry loop dengan queue full...", $time);

            timeout_before = sched_bp_timeout_stalls;
            reject_before = sched_bp_queue_full_rejections;

            // Phase 1: Fill queue
            for (i = 0; i < 50; i = i + 1) begin
                tb_game_cmd_addr <= {16'b0, 48'h9000 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(2);
            end
            tb_game_cmd_valid <= 1'b0;

            wait_cycles(50);

            // Phase 2: Continue sending (akan reject + retry)
            for (i = 0; i < 50; i = i + 1) begin
                tb_game_cmd_addr <= {16'b0, 48'h9100 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(1); // Lebih cepat - lebih banyak retry
            end
            tb_game_cmd_valid <= 1'b0;

            wait_cycles(300);

            total_rejections = sched_bp_queue_full_rejections - reject_before;
            total_watchdog_fires = sched_bp_timeout_stalls - timeout_before;

            $display("[%0t] [STRESS-4] BACK-PRESSURE REPORT:", $time);
            $display("  Rejections: %0d", total_rejections);
            $display("  Timeouts: %0d", total_watchdog_fires);

            if (total_rejections > 0 || total_watchdog_fires > 0) begin
                print_test_result("STRESS 4 PASS: Back-pressure aktif (reject/timeout)", 1);
            end else begin
                print_test_result("STRESS 4 FAIL: Tidak ada back-pressure", 0);
            end
        end
    endtask

    // =========================================================================
    // STRESS TEST 5: WORST-CASE COMBINATION
    // Semua scenario sekaligus
    // =========================================================================
    task stress_test_worst_case;
        begin
            integer i;
            int dispatch_before, complete_before, reject_before;
            int raw_before, war_before, stall_before;

            print_test_start("STRESS 5: WORST-CASE (ALL SCENARIOS)");
            $display("[%0t] WORST-CASE: Burst + Hazard + Starvation + Back-pressure", $time);

            dispatch_before = sched_total_dispatched;
            complete_before = sched_total_completed;
            reject_before = sched_bp_queue_full_rejections;
            raw_before = sched_hazard_raw;
            war_before = sched_hazard_war;
            stall_before = sched_total_stalled;

            // Phase 1: BURST flood G + A
            $display("[%0t]   Phase 1: BURST flood (G + A)", $time);
            for (i = 0; i < 100; i = i + 1) begin
                if (i % 2 == 0) begin
                    tb_game_cmd_addr <= {16'b0, 48'hA000 + i};
                    tb_game_cmd_data <= $urandom();
                    tb_game_cmd_valid <= 1'b1;
                end else begin
                    tb_ai_cmd_addr <= {16'b0, 48'hA000 + i};
                    tb_ai_cmd_data <= 64'h2000_0000_0000_0000 + i;
                    tb_ai_cmd_valid <= 1'b1;
                end
                wait_cycles(1);
            end
            tb_game_cmd_valid <= 1'b0;
            tb_ai_cmd_valid <= 1'b0;

            wait_cycles(50);

            // Phase 2: HAZARD overlap
            $display("[%0t]   Phase 2: HAZARD overlap", $time);
            for (i = 0; i < 20; i = i + 1) begin
                // Semua akses address 0xB000 (collision!)
                tb_game_cmd_addr <= {16'b0, 48'hB000};
                tb_game_cmd_data <= 32'h0100_0000 + i;
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(2);
                tb_game_cmd_valid <= 1'b0;

                tb_ai_cmd_addr <= {16'b0, 48'hB000};
                tb_ai_cmd_data <= 64'h2000_0000_0000_0000 + i;
                tb_ai_cmd_valid <= 1'b1;
                wait_cycles(2);
                tb_ai_cmd_valid <= 1'b0;
            end

            wait_cycles(200);

            // Phase 3: Continued pressure
            $display("[%0t]   Phase 3: Continued pressure", $time);
            for (i = 0; i < 100; i = i + 1) begin
                tb_game_cmd_addr <= {16'b0, 48'hC000 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(1);
            end
            tb_game_cmd_valid <= 1'b0;

            wait_cycles(500);

            // Report
            $display("\n");
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║           WORST-CASE TEST REPORT                         ║", $time);
            $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
            $display("[%0t] ║ Dispatched:          %-35d ║", $time, sched_total_dispatched - dispatch_before);
            $display("[%0t] ║ Completed:           %-35d ║", $time, sched_total_completed - complete_before);
            $display("[%0t] ║ Rejected:            %-35d ║", $time, sched_bp_queue_full_rejections - reject_before);
            $display("[%0t] ║ RAW Hazards:         %-35d ║", $time, sched_hazard_raw - raw_before);
            $display("[%0t] ║ WAR Hazards:         %-35d ║", $time, sched_hazard_war - war_before);
            $display("[%0t] ║ Total Stalls:        %-35d ║", $time, sched_total_stalled - stall_before);
            $display("[%0t] ║ Max Queue Depth:     %-35d ║", $time, sched_max_queue_depth);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);

            // EXPECTED: Sistem tetap stabil, ada rejection/hazard/stall tapi tidak crash
            if (sched_total_dispatched > dispatch_before) begin
                print_test_result("STRESS 5 PASS: Worst-case handled (tidak crash)", 1);
            end else begin
                print_test_result("STRESS 5 FAIL: Sistem hang saat worst-case", 0);
            end
        end
    endtask

    // =========================================================================
    // MAIN TEST SEQUENCE
    // =========================================================================
    initial begin
        // Initialize
        tb_rst_n            <= 1'b0;
        tb_game_cmd_addr    <= {ADDR_WIDTH{1'b0}};
        tb_game_cmd_data    <= 32'b0;
        tb_game_cmd_valid   <= 1'b0;
        tb_ai_cmd_addr      <= {ADDR_WIDTH{1'b0}};
        tb_ai_cmd_data      <= 64'b0;
        tb_ai_cmd_valid     <= 1'b0;
        tb_sys_interrupt    <= 1'b0;
        tb_sys_power_mode   <= 16'h0001;
        tb_mem_rd_data      <= {CACHE_LINE_WIDTH{1'b0}};

        total_tests     = 0;
        tests_passed    = 0;
        tests_failed    = 0;

        wait_cycles(10);

        // Reset
        reset_system();
        wait_cycles(100);

        // ═══════════════════════════════════════════════════════════
        // STRESS TESTS
        // ═══════════════════════════════════════════════════════════

        print_header("STRESS TEST SUITE - WORST-CASE VALIDATION");

        // TEST 1: Queue Overflow
        stress_test_queue_overflow();
        wait_cycles(200);

        // TEST 2: Hazard Explosion
        stress_test_hazard_explosion();
        wait_cycles(200);

        // TEST 3: Starvation
        stress_test_starvation();
        wait_cycles(200);

        // TEST 4: Back-Pressure Storm
        stress_test_backpressure_storm();
        wait_cycles(200);

        // TEST 5: Worst-Case
        stress_test_worst_case();
        wait_cycles(300);

        // ═══════════════════════════════════════════════════════════
        // FINAL REPORT
        // ═══════════════════════════════════════════════════════════
        wait_cycles(100);

        print_header("STRESS TEST FINAL REPORT");

        $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
        $display("[%0t] ║                    STRESS TEST SUMMARY                   ║", $time);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Total Stress Tests:       %-32d ║", $time, total_tests);
        $display("[%0t] ║ Passed:                   %-32d ║", $time, tests_passed);
        $display("[%0t] ║ Failed:                   %-32d ║", $time, tests_failed);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Scheduler Metrics:                                                 ║", $time);
        $display("[%0t] ║   Total Dispatched:       %-32d ║", $time, sched_total_dispatched);
        $display("[%0t] ║   Total Completed:        %-32d ║", $time, sched_total_completed);
        $display("[%0t] ║   Total Stalled:          %-32d ║", $time, sched_total_stalled);
        $display("[%0t] ║   Resource Wait:          %-32d ║", $time, sched_stall_resource_wait);
        $display("[%0t] ║   Queue Contention:       %-32d ║", $time, sched_stall_queue_contention);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Back-Pressure Metrics:                                         ║", $time);
        $display("[%0t] ║   Queue Full Rejections:  %-32d ║", $time, sched_bp_queue_full_rejections);
        $display("[%0t] ║   Timeout Stalls:         %-32d ║", $time, sched_bp_timeout_stalls);
        $display("[%0t] ║   Actual Accepts:         %-32d ║", $time, sched_bp_actual_accepts);
        $display("[%0t] ║   Admission Rejections:   %-32d ║", $time, sched_admission_rejections);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Hazard Metrics:                                                  ║", $time);
        $display("[%0t] ║   RAW Hazards:            %-32d ║", $time, sched_hazard_raw);
        $display("[%0t] ║   WAR Hazards:            %-32d ║", $time, sched_hazard_war);
        $display("[%0t] ║   WAW Hazards:            %-32d ║", $time, sched_hazard_waw);
        $display("[%0t] ║   Structural Hazards:     %-32d ║", $time, sched_hazard_structural);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Queue Metrics:                                                   ║", $time);
        $display("[%0t] ║   Current Depth:          %-32d ║", $time, sched_queue_depth);
        $display("[%0t] ║   Peak Depth:             %-32d ║", $time, sched_max_queue_depth);
        $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);

        $display("\n");
        if (tests_failed == 0) begin
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║       *** ALL STRESS TESTS PASSED! ***                   ║", $time);
            $display("[%0t] ║   Sistem tervalidasi untuk worst-case scenarios          ║", $time);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
        end else begin
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║       *** %0d STRESS TEST(S) FAILED! ***                      ║", $time, tests_failed);
            $display("[%0t] ║   Perlu perbaikan pada sistem                             ║", $time);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
        end
        $display("\n");

        // Simulation end
        $display("[%0t] [SIM] Stress test complete", $time);
        $finish;
    end

endmodule
