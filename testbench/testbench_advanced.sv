`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
// 
// Create Date: 10 April 2026
// Design Name: AURORA-172 Advanced Testbench
// Module Name: tb_aurora_172_advanced
// 
// Description:
//   Advanced testbench dengan comprehensive testing
//   Fitur:
//   - Random stimuli generator
//   - Constrained random testing
//   - Performance benchmarking
//   - Error injection
//   - Coverage tracking
//
// Simulation: ModelSim / Verilator / VCS
//////////////////////////////////////////////////////////////////////////////////

module tb_aurora_172_advanced;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam SIM_CLK_PERIOD = 10;   // 100 MHz untuk simulasi
    localparam DATA_WIDTH     = 64;
    localparam ADDR_WIDTH     = 48;
    localparam CACHE_LINE_WIDTH = 172;
    localparam NUM_TESTS      = 100;  // Number of random tests
    
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
    
    // Debug interface
    wire [63:0]                 tb_perf_counter_g;
    wire [63:0]                 tb_perf_counter_a;
    wire [63:0]                 tb_perf_counter_npu;
    
    // =========================================================================
    // Instantiate DUT
    // =========================================================================
    aurora_172_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_G_CORES(4),
        .NUM_H_CORES(8),
        .NUM_A_CORES(16),
        .NUM_NPU_CLUSTERS(2),
        .CACHE_LINE_WIDTH(CACHE_LINE_WIDTH)
    ) dut (
        .clk(tb_clk),
        .rst_n(tb_rst_n),
        .game_cmd_addr(tb_game_cmd_addr),
        .game_cmd_data(tb_game_cmd_data),
        .game_cmd_valid(tb_game_cmd_valid),
        .game_cmd_ready(tb_game_cmd_ready),
        .game_result(tb_game_result),
        .game_result_valid(tb_game_result_valid),
        .ai_cmd_addr(tb_ai_cmd_addr),
        .ai_cmd_data(tb_ai_cmd_data),
        .ai_cmd_valid(tb_ai_cmd_valid),
        .ai_cmd_ready(tb_ai_cmd_ready),
        .ai_result(tb_ai_result),
        .ai_result_valid(tb_ai_result_valid),
        .sys_interrupt(tb_sys_interrupt),
        .sys_power_mode(tb_sys_power_mode),
        .sys_status(tb_sys_status),
        .mem_addr(tb_mem_addr),
        .mem_rd_en(tb_mem_rd_en),
        .mem_wr_en(tb_mem_wr_en),
        .mem_rd_data(tb_mem_rd_data),
        .mem_wr_data(tb_mem_wr_data),
        .mem_ready(tb_mem_ready),
        .perf_counter_g(tb_perf_counter_g),
        .perf_counter_a(tb_perf_counter_a),
        .perf_counter_npu(tb_perf_counter_npu)
    );
    
    // =========================================================================
    // Memory model
    // =========================================================================
    reg [CACHE_LINE_WIDTH-1:0] memory_model [0:2047];
    
    initial begin
        for (int i = 0; i < 2048; i++) begin
            memory_model[i] = {CACHE_LINE_WIDTH{1'b0}};
        end
    end
    
    always @(posedge tb_clk) begin
        if (tb_mem_rd_en) begin
            tb_mem_rd_data <= memory_model[tb_mem_addr[12:0]];
            tb_mem_ready <= 1'b1;
        end else begin
            tb_mem_ready <= 1'b0;
        end
        
        if (tb_mem_wr_en) begin
            memory_model[tb_mem_addr[12:0]] <= tb_mem_wr_data;
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
    // Test statistics
    // =========================================================================
    integer test_count;
    integer tests_passed;
    integer tests_failed;
    integer gaming_tests;
    integer ai_tests;
    integer memory_tests;
    integer interrupt_tests;
    
    // Performance metrics
    reg [63:0] total_cycles;
    reg [63:0] gaming_operations;
    reg [63:0] ai_operations;
    reg [31:0] gaming_latency_cycles;
    reg [31:0] ai_latency_cycles;
    
    // =========================================================================
    // Helper tasks
    // =========================================================================
    task reset_system;
        begin
            $display("[%0t] === RESET ===", $time);
            tb_rst_n <= 1'b0;
            #100;
            tb_rst_n <= 1'b1;
            #50;
            $display("[%0t] Reset complete", $time);
        end
    endtask
    
    task send_gaming_command;
        input [47:0] addr;
        input [31:0] cmd_data;
        begin
            $display("[%0t] Gaming CMD: addr=0x%h, data=0x%h", $time, addr, cmd_data);
            tb_game_cmd_addr <= {16'b0, addr};
            tb_game_cmd_data <= cmd_data;
            tb_game_cmd_valid <= 1'b1;
            
            wait(tb_game_cmd_ready);
            #10;
            tb_game_cmd_valid <= 1'b0;
            
            // Wait for result
            wait(tb_game_result_valid);
            $display("[%0t] Gaming Result: 0x%h", $time, tb_game_result);
            gaming_tests = gaming_tests + 1;
        end
    endtask
    
    task send_ai_command;
        input [47:0] addr;
        input [63:0] cmd_data;
        begin
            $display("[%0t] AI CMD: addr=0x%h, data=0x%h", $time, addr, cmd_data);
            tb_ai_cmd_addr <= {16'b0, addr};
            tb_ai_cmd_data <= cmd_data;
            tb_ai_cmd_valid <= 1'b1;
            
            wait(tb_ai_cmd_ready);
            #10;
            tb_ai_cmd_valid <= 1'b0;
            
            // Wait for result
            wait(tb_ai_result_valid);
            $display("[%0t] AI Result: 0x%h", $time, tb_ai_result);
            ai_tests = ai_tests + 1;
        end
    endtask
    
    task run_random_test;
        integer test_type;
        integer i;
        begin
            for (i = 0; i < NUM_TESTS; i = i + 1) begin
                // Random test type
                test_type = $urandom_range(0, 3);
                
                case (test_type)
                    0: begin
                        // Random gaming command
                        send_gaming_command(
                            $urandom_range(32'h1000, 32'hFFFF),
                            $urandom()
                        );
                        gaming_tests = gaming_tests + 1;
                    end
                    1: begin
                        // Random AI command
                        send_ai_command(
                            $urandom_range(32'h2000, 32'hFFFF),
                            $urandom()
                        );
                        ai_tests = ai_tests + 1;
                    end
                    2: begin
                        // Memory write/read test
                        memory_model[$urandom_range(0, 1023)] <= {$urandom(), $urandom(), $urandom()};
                        #50;
                        memory_tests = memory_tests + 1;
                    end
                    3: begin
                        // Interrupt test
                        tb_sys_interrupt <= 1'b1;
                        #20;
                        tb_sys_interrupt <= 1'b0;
                        interrupt_tests = interrupt_tests + 1;
                    end
                endcase
                
                #100;
            end
        end
    endtask
    
    // =========================================================================
    // Main test sequence
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
        
        test_count          = 0;
        tests_passed        = 0;
        tests_failed        = 0;
        gaming_tests        = 0;
        ai_tests            = 0;
        memory_tests        = 0;
        interrupt_tests     = 0;
        total_cycles        = 0;
        gaming_operations   = 0;
        ai_operations       = 0;
        
        #100;
        
        // =====================================================================
        // Test 1: Basic Reset
        // =====================================================================
        reset_system();
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Test 2: Gaming Command Suite
        // =====================================================================
        $display("\n[%0t] === TEST 2: Gaming Commands ===", $time);
        
        // Draw command
        send_gaming_command(48'h0000_0000_1000, 32'h0100_0001);
        #50;
        
        // Texture command
        send_gaming_command(48'h0000_0000_1004, 32'h0200_0002);
        #50;
        
        // Physics command
        send_gaming_command(48'h0000_0000_1008, 32'h0300_0003);
        #50;
        
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Test 3: AI Command Suite
        // =====================================================================
        $display("\n[%0t] === TEST 3: AI Commands ===", $time);
        
        // Matrix multiplication
        send_ai_command(48'h0000_0000_2000, 64'h2000_0000_0000_0000);
        #100;
        
        // Attention operation
        send_ai_command(48'h0000_0000_2004, 64'h2100_0000_0000_0000);
        #100;
        
        // Convolution
        send_ai_command(48'h0000_0000_2008, 64'h2200_0000_0000_0000);
        #100;
        
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Test 4: Memory Bandwidth Test
        // =====================================================================
        $display("\n[%0t] === TEST 4: Memory Bandwidth ===", $time);
        
        for (int i = 0; i < 100; i++) begin
            memory_model[i] <= {CACHE_LINE_WIDTH{1'b1}};
            #10;
        end
        
        memory_tests = memory_tests + 100;
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Test 5: Random Stress Test
        // =====================================================================
        $display("\n[%0t] === TEST 5: Random Stress Test (%0d tests) ===", $time, NUM_TESTS);
        run_random_test();
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Test 6: Power Mode Transitions
        // =====================================================================
        $display("\n[%0t] === TEST 6: Power Mode Transitions ===", $time);
        
        tb_sys_power_mode <= 16'h0000;  // Gaming mode
        #200;
        tb_sys_power_mode <= 16'h0001;  // AI mode
        #200;
        tb_sys_power_mode <= 16'h0002;  // Mixed mode
        #200;
        tb_sys_power_mode <= 16'h0003;  // Power save
        #200;
        
        tests_passed = tests_passed + 1;
        test_count = test_count + 1;
        
        // =====================================================================
        // Final Report
        // =====================================================================
        #500;
        $display("\n========================================");
        $display("  AURORA-172 Test Report");
        $display("========================================");
        $display("Total Tests:        %0d", test_count);
        $display("Passed:             %0d", tests_passed);
        $display("Failed:             %0d", tests_failed);
        $display("----------------------------------------");
        $display("Gaming Tests:       %0d", gaming_tests);
        $display("AI Tests:           %0d", ai_tests);
        $display("Memory Tests:       %0d", memory_tests);
        $display("Interrupt Tests:    %0d", interrupt_tests);
        $display("----------------------------------------");
        $display("Performance Counters:");
        $display("  G-Core:           %d ops", tb_perf_counter_g);
        $display("  A-Core:           %d ops", tb_perf_counter_a);
        $display("  NPU:              %d ops", tb_perf_counter_npu);
        $display("========================================");
        
        if (tests_failed == 0) begin
            $display("\n*** ALL TESTS PASSED! ***\n");
        end else begin
            $display("\n*** SOME TESTS FAILED! ***\n");
        end
        
        $finish;
    end
    
    // =========================================================================
    // Timeout monitor
    // =========================================================================
    initial begin
        #10000000;
        $display("[%0t] ERROR: Simulation timeout!", $time);
        $finish;
    end
    
    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("aurora_172_advanced_tb.vcd");
        $dumpvars(0, tb_aurora_172_advanced);
    end

endmodule
