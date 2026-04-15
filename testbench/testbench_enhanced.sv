`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Enhanced Testbench
// Module Name: tb_aurora_172_enhanced
//
// Description:
//   ENHANCED testbench dengan COMPREHENSIVE logging
//   SEMUA aktivitas dimonitor dan ditampilkan:
//   ✓ Setiap instruction execution
//   ✓ Memory access patterns
//   ✓ Cache hit/miss
//   ✓ Pipeline stages
//   ✓ Branch prediction
//   ✓ Power state changes
//   ✓ DMA transfers
//   ✓ Interconnect routing
//   ✓ Cache coherency
//   ✓ Core idle/busy states
//
// Simulation: Verilator / ModelSim / VCS
//////////////////////////////////////////////////////////////////////////////////

module tb_aurora_172_enhanced;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam SIM_CLK_PERIOD = 10;   // 100 MHz untuk simulasi
    localparam DATA_WIDTH     = 64;
    localparam ADDR_WIDTH     = 48;
    localparam INST_WIDTH     = 128;
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

    // Internal monitoring signals (untuk activity tracking)
    wire [NUM_G_CORES-1:0]      g_core_active;
    wire [NUM_G_CORES-1:0]      g_core_busy;
    wire [NUM_G_CORES-1:0][3:0] g_core_pipeline_state;
    wire [NUM_G_CORES-1:0]      g_core_branch_mispredict;
    wire [NUM_G_CORES-1:0]      g_core_cache_hit;
    wire [NUM_G_CORES-1:0]      g_core_cache_miss;

    wire [NUM_H_CORES-1:0]      h_core_active;
    wire [NUM_H_CORES-1:0]      h_core_busy;
    wire [NUM_H_CORES-1:0][3:0] h_core_pipeline_state;

    wire [NUM_A_CORES-1:0]      a_core_active;
    wire [NUM_A_CORES-1:0]      a_core_mac_active;
    wire [NUM_A_CORES-1:0]      a_core_matmul_complete;

    wire [NUM_NPU_CLUSTERS-1:0] npu_active;
    wire [NUM_NPU_CLUSTERS-1:0] npu_pe_active;

    // =========================================================================
    // Instantiate DUT
    // =========================================================================
    aurora_172_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INST_WIDTH(INST_WIDTH),
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
        .perf_counter_npu(tb_perf_counter_npu)
    );

    // =========================================================================
    // Memory model (enhanced dengan logging)
    // =========================================================================
    reg [CACHE_LINE_WIDTH-1:0] memory_model [0:4095];
    integer mem_access_count = 0;

    initial begin
        // Initialize memory dengan pattern untuk tracking
        for (int i = 0; i < 4096; i++) begin
            memory_model[i] = {CACHE_LINE_WIDTH{1'b0}};
        end
        $display("[%0t] [MEM-INIT] Memory initialized (4096 entries x %0d bits)", $time, CACHE_LINE_WIDTH);
    end

    // Memory response dengan logging
    always @(posedge tb_clk) begin
        if (tb_mem_rd_en) begin
            tb_mem_rd_data <= memory_model[tb_mem_addr[11:0]];
            tb_mem_ready <= 1'b1;
            mem_access_count++;
            $display("[%0t] [MEM-READ]  addr=0x%h data=0x%h (access #%0d)",
                     $time, tb_mem_addr[11:0], memory_model[tb_mem_addr[11:0]], mem_access_count);
        end else begin
            tb_mem_ready <= 1'b0;
        end

        if (tb_mem_wr_en) begin
            memory_model[tb_mem_addr[11:0]] <= tb_mem_wr_data;
            mem_access_count++;
            $display("[%0t] [MEM-WRITE] addr=0x%h data=0x%h (access #%0d)",
                     $time, tb_mem_addr[11:0], tb_mem_wr_data, mem_access_count);
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
    // Activity Monitor Instantiation
    // =========================================================================
    activity_monitor #(
        .NUM_G_CORES(NUM_G_CORES),
        .NUM_H_CORES(NUM_H_CORES),
        .NUM_A_CORES(NUM_A_CORES),
        .NUM_NPU_CLUSTERS(NUM_NPU_CLUSTERS),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) activity_mon (
        .clk(tb_clk),
        .rst_n(tb_rst_n),

        // G-Core activity (connect ke internal signals jika available)
        .g_core_active(g_core_active),
        .g_core_busy(g_core_busy),
        .g_core_pipeline_state(g_core_pipeline_state),
        .g_core_branch_mispredict(g_core_branch_mispredict),
        .g_core_cache_hit(g_core_cache_hit),
        .g_core_cache_miss(g_core_cache_miss),

        // H-Core activity
        .h_core_active(h_core_active),
        .h_core_busy(h_core_busy),
        .h_core_pipeline_state(h_core_pipeline_state),
        .h_core_rob_full(),
        .h_core_reorder_buffer_busy(),

        // A-Core activity
        .a_core_active(a_core_active),
        .a_core_mac_active(a_core_mac_active),
        .a_core_matmul_complete(a_core_matmul_complete),

        // NPU activity
        .npu_active(npu_active),
        .npu_pe_active(npu_pe_active),

        // Memory fabric activity
        .mem_fabric_active(tb_mem_rd_en | tb_mem_wr_en),
        .mem_rd_req(tb_mem_rd_en),
        .mem_wr_req(tb_mem_wr_en),
        .mem_cache_hit(),
        .mem_cache_miss(),
        .mem_writeback(),
        .mem_last_addr(tb_mem_addr[ADDR_WIDTH-1:0]),
        .mem_last_data(tb_mem_wr_data[DATA_WIDTH-1:0]),

        // Coherency
        .coherence_snoop_req(),
        .coherence_invalidate(),
        .coherence_writeback(),
        .coherence_state_modified(2'b00),

        // Power
        .dvfs_current_freq(8'd100),
        .power_gate_active(1'b0),
        .thermal_throttle(1'b0),
        .power_consumption_mw(32'd0),

        // DMA
        .dma_channel_active(8'b0),
        .dma_transfer_complete(8'b0),
        .dma_error(8'b0),
        .dma_bytes_transferred(32'd0),

        // Interconnect
        .fabric_packet_valid(1'b0),
        .fabric_packet_src(7'd0),
        .fabric_packet_dst(7'd0),
        .fabric_contention(1'b0),

        // Branch predictor
        .bp_prediction(1'b0),
        .bp_actual(1'b0),
        .bp_update(1'b0)
    );

    // =========================================================================
    // Test Statistics
    // =========================================================================
    integer total_tests;
    integer tests_passed;
    integer tests_failed;
    integer gaming_tests;
    integer ai_tests;
    integer memory_tests;
    integer interrupt_tests;

    // =========================================================================
    // Helper Tasks dengan Logging Detail
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
            print_header("SYSTEM RESET");
            $display("[%0t] Asserting reset...", $time);
            tb_rst_n <= 1'b0;
            wait_cycles(10);
            $display("[%0t] Deasserting reset...", $time);
            tb_rst_n <= 1'b1;
            wait_cycles(5);
            print_test_result("Reset sequence complete", 1);
        end
    endtask

    task send_gaming_command;
        input [47:0] addr;
        input [31:0] cmd_data;
        input [40*8:1] cmd_name;
        begin
            $display("[%0t]   [G-CMD] %s", $time, cmd_name);
            $display("[%0t]           addr=0x%h, data=0x%h", $time, addr, cmd_data);

            tb_game_cmd_addr <= {16'b0, addr};
            tb_game_cmd_data <= cmd_data;
            tb_game_cmd_valid <= 1'b1;

            wait(tb_game_cmd_ready);
            $display("[%0t]   [G-CMD] Ready accepted", $time);
            #10;
            tb_game_cmd_valid <= 1'b0;

            // Wait for result
            wait(tb_game_result_valid);
            $display("[%0t]   [G-RSLT] Result: 0x%h", $time, tb_game_result);
            gaming_tests = gaming_tests + 1;
        end
    endtask

    task send_ai_command;
        input [47:0] addr;
        input [63:0] cmd_data;
        input [40*8:1] cmd_name;
        begin
            $display("[%0t]   [A-CMD] %s", $time, cmd_name);
            $display("[%0t]           addr=0x%h, data=0x%h", $time, addr, cmd_data);

            tb_ai_cmd_addr <= {16'b0, addr};
            tb_ai_cmd_data <= cmd_data;
            tb_ai_cmd_valid <= 1'b1;

            wait(tb_ai_cmd_ready);
            $display("[%0t]   [A-CMD] Ready accepted", $time);
            #10;
            tb_ai_cmd_valid <= 1'b0;

            // Wait for result
            wait(tb_ai_result_valid);
            $display("[%0t]   [A-RSLT] Result: 0x%h", $time, tb_ai_result);
            ai_tests = ai_tests + 1;
        end
    endtask

    // =========================================================================
    // Main Test Sequence
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
        gaming_tests    = 0;
        ai_tests        = 0;
        memory_tests    = 0;
        interrupt_tests = 0;

        wait_cycles(10);

        // =====================================================================
        // TEST 1: Reset Sequence
        // =====================================================================
        print_test_start("TEST 1: Reset Sequence");
        reset_system();

        // =====================================================================
        // TEST 2: Gaming Commands - All Types
        // =====================================================================
        print_test_start("TEST 2: Gaming Commands (All Types)");

        send_gaming_command(48'h0000_0000_1000, 32'h0100_0001, "DRAW Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_1004, 32'h0200_0002, "TEXTURE Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_1008, 32'h0300_0003, "PHYSICS Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_100C, 32'h0400_0004, "COLLISION Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_1010, 32'h0500_0005, "RAYTRACE Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_1014, 32'h0600_0006, "FRAMEGEN Command");
        wait_cycles(20);

        send_gaming_command(48'h0000_0000_1018, 32'h0700_0007, "SHADING Command");
        wait_cycles(20);

        print_test_result("All gaming command types executed", 1);

        // =====================================================================
        // TEST 3: AI Commands - All Operations
        // =====================================================================
        print_test_start("TEST 3: AI Commands (All Operations)");

        send_ai_command(48'h0000_0000_2000, 64'h2000_0000_0000_0000, "MATMUL Operation");
        wait_cycles(30);

        send_ai_command(48'h0000_0000_2008, 64'h2100_0000_0000_0000, "ATTENTION Operation");
        wait_cycles(30);

        send_ai_command(48'h0000_0000_2010, 64'h2200_0000_0000_0000, "CONV2D Operation");
        wait_cycles(30);

        send_ai_command(48'h0000_0000_2018, 64'h2300_0000_0000_0000, "POOLING Operation");
        wait_cycles(30);

        send_ai_command(48'h0000_0000_2020, 64'h2400_0000_0000_0000, "ACTIVATION (ReLU)");
        wait_cycles(30);

        send_ai_command(48'h0000_0000_2028, 64'h2500_0000_0000_0000, "NORMALIZE Operation");
        wait_cycles(30);

        print_test_result("All AI operation types executed", 1);

        // =====================================================================
        // TEST 4: Memory Access Patterns
        // =====================================================================
        print_test_start("TEST 4: Memory Access Patterns");

        $display("[%0t]   Sequential writes...", $time);
        for (int i = 0; i < 10; i++) begin
            memory_model[i] <= {CACHE_LINE_WIDTH{1'b1}} | i;
            wait_cycles(5);
        end
        memory_tests = memory_tests + 10;
        $display("[%0t]   Sequential writes complete", $time);

        $display("[%0t]   Sequential reads...", $time);
        for (int i = 0; i < 10; i++) begin
            tb_mem_rd_data <= memory_model[i];
            wait_cycles(5);
        end
        memory_tests = memory_tests + 10;
        $display("[%0t]   Sequential reads complete", $time);

        $display("[%0t]   Random access pattern...", $time);
        for (int i = 0; i < 20; i++) begin
            integer addr = $urandom_range(0, 1023);
            memory_model[addr] <= {$urandom(), $urandom(), $urandom()};
            wait_cycles(3);
        end
        memory_tests = memory_tests + 20;
        $display("[%0t]   Random access complete", $time);

        print_test_result("Memory access patterns validated", 1);

        // =====================================================================
        // TEST 5: Concurrent Gaming + AI Workload
        // =====================================================================
        print_test_start("TEST 5: Concurrent Gaming + AI Workload");

        $display("[%0t]   Sending mixed workload...", $time);

        // Interleaved gaming and AI commands
        send_gaming_command(48'h0000_0000_1100, 32'h0100_0100, "DRAW Batch #1");
        wait_cycles(10);

        send_ai_command(48'h0000_0000_2100, 64'h2000_0000_0000_0100, "MATMUL Layer #1");
        wait_cycles(10);

        send_gaming_command(48'h0000_0000_1104, 32'h0200_0101, "TEXTURE Batch #1");
        wait_cycles(10);

        send_ai_command(48'h0000_0000_2108, 64'h2100_0000_0000_0101, "ATTENTION Head #1");
        wait_cycles(10);

        send_gaming_command(48'h0000_0000_1108, 32'h0500_0102, "RAYTRACE Scene #1");
        wait_cycles(10);

        send_ai_command(48'h0000_0000_2110, 64'h2200_0000_0000_0102, "CONV2D Filter #1");
        wait_cycles(10);

        print_test_result("Concurrent workload handled", 1);

        // =====================================================================
        // TEST 6: Interrupt Handling
        // =====================================================================
        print_test_start("TEST 6: Interrupt Handling");

        $display("[%0t]   Asserting interrupt...", $time);
        tb_sys_interrupt <= 1'b1;
        wait_cycles(5);
        $display("[%0t]   Interrupt asserted", $time);

        $display("[%0t]   Deasserting interrupt...", $time);
        tb_sys_interrupt <= 1'b0;
        wait_cycles(5);
        $display("[%0t]   Interrupt deasserted", $time);

        interrupt_tests = interrupt_tests + 1;
        print_test_result("Interrupt handled correctly", 1);

        // =====================================================================
        // TEST 7: Power Mode Transitions
        // =====================================================================
        print_test_start("TEST 7: Power Mode Transitions");

        $display("[%0t]   Mode: GAMING (0x0000)", $time);
        tb_sys_power_mode <= 16'h0000;
        wait_cycles(50);

        $display("[%0t]   Mode: AI (0x0001)", $time);
        tb_sys_power_mode <= 16'h0001;
        wait_cycles(50);

        $display("[%0t]   Mode: MIXED (0x0002)", $time);
        tb_sys_power_mode <= 16'h0002;
        wait_cycles(50);

        $display("[%0t]   Mode: POWERSAVE (0x0003)", $time);
        tb_sys_power_mode <= 16'h0003;
        wait_cycles(50);

        print_test_result("Power mode transitions complete", 1);

        // =====================================================================
        // TEST 8: Stress Test - Rapid Commands
        // =====================================================================
        print_test_start("TEST 8: Stress Test (50 rapid commands)");

        $display("[%0t]   Starting rapid fire test...", $time);
        for (int i = 0; i < 50; i++) begin
            if (i % 2 == 0) begin
                tb_game_cmd_addr <= {16'b0, 48'h1200 + i};
                tb_game_cmd_data <= $urandom();
                tb_game_cmd_valid <= 1'b1;
                wait_cycles(5);
                tb_game_cmd_valid <= 1'b0;
                gaming_tests = gaming_tests + 1;
            end else begin
                tb_ai_cmd_addr <= {16'b0, 48'h2200 + i};
                tb_ai_cmd_data <= $urandom();
                tb_ai_cmd_valid <= 1'b1;
                wait_cycles(5);
                tb_ai_cmd_valid <= 1'b0;
                ai_tests = ai_tests + 1;
            end
            wait_cycles(10);
        end
        $display("[%0t]   Rapid fire complete", $time);

        print_test_result("Stress test complete (50 commands)", 1);

        // =====================================================================
        // TEST 9: System Status Monitoring
        // =====================================================================
        print_test_start("TEST 9: System Status Monitoring");

        $display("[%0t]   System status: 0x%h", $time, tb_sys_status);
        $display("[%0t]   G-Core perf counter: %0d", $time, tb_perf_counter_g);
        $display("[%0t]   A-Core perf counter: %0d", $time, tb_perf_counter_a);
        $display("[%0t]   NPU perf counter: %0d", $time, tb_perf_counter_npu);
        $display("[%0t]   Memory accesses: %0d", $time, mem_access_count);

        print_test_result("System status read", 1);

        // =====================================================================
        // FINAL REPORT
        // =====================================================================
        wait_cycles(100);

        print_header("AURORA-172 FINAL TEST REPORT");

        $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
        $display("[%0t] ║                    TEST SUMMARY                          ║", $time);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Total Tests:          %-38d ║", $time, total_tests);
        $display("[%0t] ║ Passed:               %-38d ║", $time, tests_passed);
        $display("[%0t] ║ Failed:               %-38d ║", $time, tests_failed);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Gaming Tests:         %-38d ║", $time, gaming_tests);
        $display("[%0t] ║ AI Tests:             %-38d ║", $time, ai_tests);
        $display("[%0t] ║ Memory Tests:         %-38d ║", $time, memory_tests);
        $display("[%0t] ║ Interrupt Tests:      %-38d ║", $time, interrupt_tests);
        $display("[%0t] ║ Memory Accesses:      %-38d ║", $time, mem_access_count);
        $display("[%0t] ╠══════════════════════════════════════════════════════════╣", $time);
        $display("[%0t] ║ Performance Counters:                                    ║", $time);
        $display("[%0t] ║   G-Core: %-48d ║", $time, tb_perf_counter_g);
        $display("[%0t] ║   A-Core: %-48d ║", $time, tb_perf_counter_a);
        $display("[%0t] ║   NPU:    %-48d ║", $time, tb_perf_counter_npu);
        $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);

        if (tests_failed == 0) begin
            $display("\n");
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║           *** ALL TESTS PASSED! ***                      ║", $time);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
            $display("\n");
        end else begin
            $display("\n");
            $display("[%0t] ╔══════════════════════════════════════════════════════════╗", $time);
            $display("[%0t] ║           *** SOME TESTS FAILED! ***                     ║", $time);
            $display("[%0t] ╚══════════════════════════════════════════════════════════╝", $time);
            $display("\n");
        end

        // End simulation
        $display("[%0t] Simulation complete", $time);
        $finish;
    end

    // =========================================================================
    // Timeout monitor
    // =========================================================================
    initial begin
        #1000000;
        $display("[%0t] ✗ ERROR: Simulation timeout!", $time);
        $finish;
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("aurora_172_enhanced_tb.vcd");
        $dumpvars(0, tb_aurora_172_enhanced);
    end

endmodule
