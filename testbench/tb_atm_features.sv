`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: ATM Intel + AMD Features
// 
// Tests:
//   1. SmartShift Power (AMD)
//   2. Turbo Boost Hybrid (Intel + AMD)
//   3. μop Cache (Intel)
//   4. Power Monitor RAPL (Intel)
//
//////////////////////////////////////////////////////////////////////////////////

module tb_atm_features;

    parameter DATA_WIDTH    = 64;
    parameter ADDR_WIDTH    = 48;
    parameter INST_WIDTH    = 128;
    
    reg  tb_clk;
    reg  tb_rst_n;
    
    // Clock generation
    initial begin
        tb_clk = 0;
        forever #5 tb_clk = ~tb_clk;  // 100MHz clock
    end
    
    // =========================================================================
    // TEST 1: SmartShift Power (AMD)
    // =========================================================================
    wire [DATA_WIDTH-1:0]   ss_g_budget, ss_a_budget, ss_h_budget, ss_npu_budget;
    wire                    ss_active;
    wire [DATA_WIDTH-1:0]   ss_total, ss_surplus, ss_deficit;
    wire [31:0]             ss_redist_count, ss_g_boost, ss_a_boost, ss_tdp_hits;
    
    reg  [DATA_WIDTH-1:0]   g_demand, a_demand, h_demand, npu_demand;
    reg                     gaming_mode, ai_mode, mixed_mode, gpu_bound;
    reg  [DATA_WIDTH-1:0]   tdp_limit;
    
    smartshift #(
        .DATA_WIDTH(DATA_WIDTH),
        .G_CORE_BASE_W(80),
        .A_CORE_BASE_W(100),
        .H_CORE_BASE_W(50),
        .NPU_BASE_W(20)
    ) u_smartshift (
        .clk(tb_clk),
        .rst_n(tb_rst_n),
        .g_core_demand_mw(g_demand),
        .a_core_demand_mw(a_demand),
        .h_core_demand_mw(h_demand),
        .npu_demand_mw(npu_demand),
        .gaming_mode(gaming_mode),
        .ai_mode(ai_mode),
        .mixed_mode(mixed_mode),
        .gpu_bound(gpu_bound),
        .tdp_limit_mw(tdp_limit),
        .g_core_budget_mw(ss_g_budget),
        .a_core_budget_mw(ss_a_budget),
        .h_core_budget_mw(ss_h_budget),
        .npu_budget_mw(ss_npu_budget),
        .redistribution_active(ss_active),
        .total_allocated_mw(ss_total),
        .power_surplus_mw(ss_surplus),
        .power_deficit_mw(ss_deficit),
        .redistribution_count(ss_redist_count),
        .g_core_boost_count(ss_g_boost),
        .a_core_boost_count(ss_a_boost),
        .tdp_limit_hit_count(ss_tdp_hits)
    );
    
    // =========================================================================
    // TEST 2: Turbo Boost Hybrid (Intel + AMD)
    // =========================================================================
    wire [DATA_WIDTH-1:0]   tb_g_freq, tb_a_freq, tb_h_freq, tb_npu_freq;
    wire                    tb_active, tb_gaming, tb_ai, tb_throttle, tb_tdp_lim;
    wire [31:0]             tb_entry, tb_timeout, tb_throttle_cnt, tb_cooldown;
    
    reg  [7:0]              temp_c;
    reg  [DATA_WIDTH-1:0]   power_mw;
    reg                     turbo_en, turbo_override;
    
    turbo_boost #(
        .DATA_WIDTH(DATA_WIDTH),
        .G_BASE_CLOCK_MHZ(6000),
        .G_TURBO_CLOCK_MHZ(6500),
        .A_BASE_CLOCK_MHZ(4000),
        .A_TURBO_CLOCK_MHZ(4500)
    ) u_turbo_boost (
        .clk(tb_clk),
        .rst_n(tb_rst_n),
        .gaming_mode(gaming_mode),
        .ai_mode(ai_mode),
        .mixed_mode(mixed_mode),
        .gpu_bound(gpu_bound),
        .current_temp_c(temp_c),
        .current_power_mw(power_mw),
        .tdp_limit_mw(tdp_limit),
        .turbo_enable(turbo_en),
        .turbo_override(turbo_override),
        .g_core_freq_mhz(tb_g_freq),
        .a_core_freq_mhz(tb_a_freq),
        .h_core_freq_mhz(tb_h_freq),
        .npu_freq_mhz(tb_npu_freq),
        .turbo_active(tb_active),
        .turbo_gaming(tb_gaming),
        .turbo_ai(tb_ai),
        .thermal_throttle(tb_throttle),
        .tdp_limited(tb_tdp_lim),
        .turbo_entry_count(tb_entry),
        .turbo_timeout_count(tb_timeout),
        .thermal_throttle_count(tb_throttle_cnt),
        .cooldown_count(tb_cooldown)
    );
    
    // =========================================================================
    // TEST 3: μop Cache (Intel)
    // =========================================================================
    wire                    uop_hit, uop_ready, uop_valid, decode_req;
    wire [63:0]             uop_micro_ops;
    wire [7:0]              uop_count;
    wire [31:0]             uop_hits, uop_misses, uop_evictions;
    wire [7:0]              uop_hit_rate;
    
    reg  [ADDR_WIDTH-1:0]   fetch_pc;
    reg  [INST_WIDTH-1:0]   fetch_inst;
    reg                     fetch_valid;
    reg                     decode_complete;
    reg  [63:0]             decode_uops;
    reg  [7:0]              decode_uop_cnt;
    
    uop_cache #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INST_WIDTH(INST_WIDTH),
        .NUM_ENTRIES(512),
        .ASSOCIATIVITY(8)
    ) u_uop_cache (
        .clk(tb_clk),
        .rst_n(tb_rst_n),
        .fetch_pc(fetch_pc),
        .fetch_instruction(fetch_inst),
        .fetch_valid(fetch_valid),
        .uop_cache_hit(uop_hit),
        .uop_cache_ready(uop_ready),
        .uop_micro_ops(uop_micro_ops),
        .uop_count(uop_count),
        .uop_valid(uop_valid),
        .decode_request(decode_req),
        .decode_complete(decode_complete),
        .decode_micro_ops(decode_uops),
        .decode_uop_count(decode_uop_cnt),
        .uop_hits(uop_hits),
        .uop_misses(uop_misses),
        .uop_evictions(uop_evictions),
        .uop_hit_rate_percent(uop_hit_rate)
    );
    
    // =========================================================================
    // TEST 4: Power Monitor RAPL (Intel)
    // =========================================================================
    wire [63:0]             pm_energy_g, pm_energy_a, pm_energy_h, pm_energy_total;
    wire [DATA_WIDTH-1:0]   pm_avg_g, pm_avg_a, pm_avg_total;
    wire                    pm_pl1_exceeded, pm_pl2_exceeded, pm_throttle_req;
    wire [4:0]              pm_domain_pl1, pm_domain_pl2;
    wire [3:0]              pm_throttle_domain;
    wire [31:0]             pm_pl1_violations, pm_pl2_violations, pm_throttle_events;
    
    reg  [DATA_WIDTH-1:0]   pm_g_power, pm_a_power, pm_h_power, pm_npu_power, pm_mem_power;
    reg  [DATA_WIDTH-1:0]   pm_pl1_g, pm_pl1_a, pm_pl1_h, pm_pl1_npu, pm_pl1_total;
    reg  [DATA_WIDTH-1:0]   pm_pl2_g, pm_pl2_a, pm_pl2_total;
    reg  [31:0]             pm_pl2_window;
    reg                     pm_enable, pm_enforce;
    
    power_monitor #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_DOMAINS(5),
        .ENERGY_UNIT_uJ(1),
        .POWER_AVG_WINDOW(100)
    ) u_power_monitor (
        .clk(tb_clk),
        .rst_n(tb_rst_n),
        .g_core_power_mw(pm_g_power),
        .a_core_power_mw(pm_a_power),
        .h_core_power_mw(pm_h_power),
        .npu_power_mw(pm_npu_power),
        .memory_power_mw(pm_mem_power),
        .pl1_g_core_mw(pm_pl1_g),
        .pl1_a_core_mw(pm_pl1_a),
        .pl1_h_core_mw(pm_pl1_h),
        .pl1_npu_mw(pm_pl1_npu),
        .pl1_total_mw(pm_pl1_total),
        .pl2_g_core_mw(pm_pl2_g),
        .pl2_a_core_mw(pm_pl2_a),
        .pl2_total_mw(pm_pl2_total),
        .pl2_time_window_cycles(pm_pl2_window),
        .enable_monitor(pm_enable),
        .enable_limit_enforce(pm_enforce),
        .energy_g_core_uj(pm_energy_g),
        .energy_a_core_uj(pm_energy_a),
        .energy_h_core_uj(pm_energy_h),
        .energy_npu_uj(),  // Not connected
        .energy_total_uj(pm_energy_total),
        .avg_g_core_power_mw(pm_avg_g),
        .avg_a_core_power_mw(pm_avg_a),
        .avg_total_power_mw(pm_avg_total),
        .pl1_exceeded(pm_pl1_exceeded),
        .pl2_exceeded(pm_pl2_exceeded),
        .domain_pl1_exceeded(pm_domain_pl1),
        .domain_pl2_exceeded(pm_domain_pl2),
        .throttle_request(pm_throttle_req),
        .throttle_domain(pm_throttle_domain),
        .pl1_violation_count(pm_pl1_violations),
        .pl2_violation_count(pm_pl2_violations),
        .throttle_event_count(pm_throttle_events)
    );
    
    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    integer i;
    
    initial begin
        // Initialize
        tb_rst_n = 0;
        gaming_mode = 0;
        ai_mode = 0;
        mixed_mode = 0;
        gpu_bound = 0;
        g_demand = 80000;
        a_demand = 100000;
        h_demand = 50000;
        npu_demand = 20000;
        tdp_limit = 250000;
        temp_c = 65;
        power_mw = 200000;
        turbo_en = 0;
        turbo_override = 0;
        fetch_valid = 0;
        fetch_pc = 0;
        decode_complete = 0;
        decode_uops = 0;
        decode_uop_cnt = 0;
        pm_g_power = 80000;
        pm_a_power = 100000;
        pm_h_power = 50000;
        pm_npu_power = 20000;
        pm_mem_power = 30000;
        pm_pl1_g = 80000;
        pm_pl1_a = 100000;
        pm_pl1_h = 50000;
        pm_pl1_npu = 20000;
        pm_pl1_total = 250000;
        pm_pl2_g = 120000;
        pm_pl2_a = 150000;
        pm_pl2_total = 300000;
        pm_pl2_window = 28000;
        pm_enable = 0;
        pm_enforce = 0;
        
        // Reset
        #20;
        tb_rst_n = 1;
        #10;
        
        $display("========================================");
        $display("  ATM Intel + AMD Features Test");
        $display("========================================\n");
        
        // ─────────────────────────────────────────────
        // TEST 1: SmartShift Power (AMD)
        // ─────────────────────────────────────────────
        $display("[TEST 1] SmartShift Power (AMD)");
        $display("----------------------------------------");
        
        // Gaming mode - G-Core should get boost
        gaming_mode = 1;
        gpu_bound = 1;
        g_demand = 120000;  // High demand
        a_demand = 60000;   // Low demand
        #100;
        
        $display("Gaming Mode: G=%0dmW, A=%0dmW, H=%0dmW, NPU=%0dmW", 
                 ss_g_budget, ss_a_budget, ss_h_budget, ss_npu_budget);
        $display("Total: %0dmW, Redistrib: %0d", ss_total, ss_redist_count);
        
        // AI mode - A-Core should get boost
        gaming_mode = 0;
        ai_mode = 1;
        g_demand = 40000;   // Low demand
        a_demand = 150000;  // High demand
        #100;
        
        $display("AI Mode: G=%0dmW, A=%0dmW, H=%0dmW, NPU=%0dmW", 
                 ss_g_budget, ss_a_budget, ss_h_budget, ss_npu_budget);
        $display("Total: %0dmW, Redistrib: %0d", ss_total, ss_redist_count);
        
        // TDP limit hit
        g_demand = 100000;
        a_demand = 120000;
        h_demand = 60000;
        tdp_limit = 250000;  // Less than total demand
        #100;
        
        $display("TDP Limit: Total=%0dmW, TDP=%0dmW, Hits=%0d", 
                 ss_total, tdp_limit, ss_tdp_hits);
        
        gaming_mode = 0;
        ai_mode = 0;
        #50;
        
        $display("SmartShift G-Boost: %0d, A-Boost: %0d\n", ss_g_boost, ss_a_boost);
        
        // ─────────────────────────────────────────────
        // TEST 2: Turbo Boost Hybrid (Intel + AMD)
        // ─────────────────────────────────────────────
        $display("[TEST 2] Turbo Boost Hybrid (Intel + AMD)");
        $display("----------------------------------------");
        
        // Gaming turbo (Intel-style time-limited)
        gaming_mode = 1;
        gpu_bound = 1;
        turbo_en = 1;
        temp_c = 70;
        power_mw = 220000;
        #200;
        
        $display("Gaming Turbo: G=%0dMHz, A=%0dMHz, Active=%b, Gaming=%b", 
                 tb_g_freq, tb_a_freq, tb_active, tb_gaming);
        
        // AI turbo (AMD-style unlimited)
        gaming_mode = 0;
        ai_mode = 1;
        temp_c = 75;
        #200;
        
        $display("AI Turbo: G=%0dMHz, A=%0dMHz, Active=%b, AI=%b", 
                 tb_g_freq, tb_a_freq, tb_active, tb_ai);
        
        // Thermal throttle
        temp_c = 96;  // Above throttle temp
        #100;
        
        $display("Thermal Throttle: G=%0dMHz, A=%0dMHz, Throttle=%b, Count=%0d", 
                 tb_g_freq, tb_a_freq, tb_throttle, tb_throttle_cnt);
        
        // Cool down
        temp_c = 70;
        #200;
        
        $display("After Cooldown: G=%0dMHz, A=%0dMHz, Cooldown=%0d\n", 
                 tb_g_freq, tb_a_freq, tb_cooldown);
        
        turbo_en = 0;
        gaming_mode = 0;
        ai_mode = 0;
        
        // ─────────────────────────────────────────────
        // TEST 3: μop Cache (Intel)
        // ─────────────────────────────────────────────
        $display("[TEST 3] μop Cache (Intel)");
        $display("----------------------------------------");
        
        // First access (miss)
        fetch_pc = 48'h1000;
        fetch_inst = 128'hDEADBEEF;
        fetch_valid = 1;
        #10;
        fetch_valid = 0;
        
        // Simulate decode complete
        #10;
        decode_complete = 1;
        decode_uops = 64'hCAFEBABE;
        decode_uop_cnt = 4;
        #10;
        decode_complete = 0;
        
        $display("First Access: Hit=%b, Miss expected", uop_hit);
        
        // Second access (should hit)
        fetch_pc = 48'h1000;
        fetch_valid = 1;
        #10;
        fetch_valid = 0;
        
        $display("Second Access: Hit=%b, Rate=%0d%%", uop_hit, uop_hit_rate);
        
        // Multiple accesses
        for (i = 0; i < 10; i = i + 1) begin
            fetch_pc = 48'h1000 + i;
            fetch_valid = 1;
            #10;
            fetch_valid = 0;
            #10;
            decode_complete = 1;
            decode_uops = 64'hCAFEBABE + i;
            decode_uop_cnt = 3 + (i % 4);
            #10;
            decode_complete = 0;
            #10;
        end
        
        // Repeat some (should hit)
        for (i = 0; i < 5; i = i + 1) begin
            fetch_pc = 48'h1000 + i;
            fetch_valid = 1;
            #10;
            fetch_valid = 0;
            #10;
        end
        
        $display("μop Cache: Hits=%0d, Misses=%0d, Hit Rate=%0d%%", 
                 uop_hits, uop_misses, uop_hit_rate);
        $display("Evictions: %0d\n", uop_evictions);
        
        // ─────────────────────────────────────────────
        // TEST 4: Power Monitor RAPL (Intel)
        // ─────────────────────────────────────────────
        $display("[TEST 4] Power Monitor RAPL (Intel)");
        $display("----------------------------------------");
        
        pm_enable = 1;
        #100;
        
        // Normal operation
        $display("Energy: G=%0dμJ, A=%0dμJ, Total=%0dμJ", 
                 pm_energy_g, pm_energy_a, pm_energy_total);
        
        // PL1 limit test
        pm_pl1_g = 60000;  // Lower limit
        pm_pl1_total = 200000;
        pm_g_power = 80000;  // Exceeds PL1
        #500;
        
        $display("PL1 Test: Exceeded=%b, Violations=%0d, Throttle=%b", 
                 pm_pl1_exceeded, pm_pl1_violations, pm_throttle_req);
        
        // PL2 limit test
        pm_enforce = 1;
        pm_pl2_g = 70000;  // Very low PL2
        pm_g_power = 100000;  // Exceeds PL2
        #200;
        
        $display("PL2 Test: Exceeded=%b, Violations=%0d, Throttle=%b, Domain=%0d", 
                 pm_pl2_exceeded, pm_pl2_violations, pm_throttle_req, pm_throttle_domain);
        
        $display("\nFinal Energy: G=%0dμJ, A=%0dμJ, H=%0dμJ, Total=%0dμJ", 
                 pm_energy_g, pm_energy_a, pm_energy_h, pm_energy_total);
        
        pm_enable = 0;
        
        // ─────────────────────────────────────────────
        // FINAL REPORT
        // ─────────────────────────────────────────────
        #100;
        $display("\n========================================");
        $display("  FINAL REPORT - ATM Features");
        $display("========================================");
        $display("[SmartShift] Redist: %0d, G-Boost: %0d, A-Boost: %0d, TDP Hits: %0d", 
                 ss_redist_count, ss_g_boost, ss_a_boost, ss_tdp_hits);
        $display("[TurboBoost] Entry: %0d, Timeout: %0d, Throttle: %0d, Cooldown: %0d", 
                 tb_entry, tb_timeout, tb_throttle_cnt, tb_cooldown);
        $display("[uOp Cache]  Hits: %0d, Misses: %0d, Hit Rate: %0d%%, Evict: %0d", 
                 uop_hits, uop_misses, uop_hit_rate, uop_evictions);
        $display("[PowerMon]   PL1 Viol: %0d, PL2 Viol: %0d, Throttle: %0d", 
                 pm_pl1_violations, pm_pl2_violations, pm_throttle_events);
        $display("========================================");
        $display("ALL TESTS COMPLETE\n");
        
        // End simulation
        #100;
        $finish;
    end
    
endmodule
