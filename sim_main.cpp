// ============================================================================
// AURORA-172 Simulation Main
// Entry point untuk Verilator simulation (support multiple testbenches)
// WITH VCD WAVEFORM TRACING
// ============================================================================

#include "verilated.h"
#include "verilated_fst_c.h"  // FST tracing
#include <cinttypes>
#include <cstdio>
#include <memory>

// ============================================================================
// Conditional include berdasarkan testbench type
// ============================================================================
#if defined(ENHANCED_TEST)
#include "Vtb_aurora_172_enhanced.h"
#include "Vtb_aurora_172_enhanced___024root.h"
#define TB_CLASS Vtb_aurora_172_enhanced
#define TB_NAME "tb_aurora_172_enhanced"
#elif defined(ADVANCED_TEST)
#include "Vtb_aurora_172_advanced.h"
#include "Vtb_aurora_172_advanced___024root.h"
#define TB_CLASS Vtb_aurora_172_advanced
#define TB_NAME "tb_aurora_172_advanced"
#elif defined(ATM_TEST)
#include "Vtb_atm_features.h"
#include "Vtb_atm_features___024root.h"
#define TB_CLASS Vtb_atm_features
#define TB_NAME "tb_atm_features"
#elif defined(STRESS_TEST)
#include "Vtb_stress_test.h"
#include "Vtb_stress_test___024root.h"
#define TB_CLASS Vtb_stress_test
#define TB_NAME "tb_stress_test"
#else
#include "Vtb_aurora_172.h"
#include "Vtb_aurora_172___024root.h"
#define TB_CLASS Vtb_aurora_172
#define TB_NAME "tb_aurora_172"
#endif

// FIXED: Make hierarchy paths configurable (less fragile approach)
#if defined(STRESS_TEST)
#define TB_CLK_PATH tb_stress_test__DOT__tb_clk
#define TB_RST_PATH tb_stress_test__DOT__tb_rst_n
#else
#define TB_CLK_PATH tb_aurora_172__DOT__tb_clk
#define TB_RST_PATH tb_aurora_172__DOT__tb_rst_n
#endif

// Global tick counter
static vluint64_t main_time = 0;

int main(int argc, char** argv, char** env) {
    Verilated::commandArgs(argc, argv);

    // Create testbench instance
    std::unique_ptr<TB_CLASS> tb = std::make_unique<TB_CLASS>();

    // OPTIMIZATION 1: Conditional FST tracing (5-10x speedup when disabled)
    // Only enable tracing if explicitly requested AND compiled with trace support
    bool enable_trace = false;
    std::unique_ptr<VerilatedFstC> tfp;
    
    // Check if compiled with trace support (not FAST_MODE)
#ifndef FAST_MODE
    if (getenv("ENABLE_TRACE") != nullptr) {
        enable_trace = true;
        Verilated::traceEverOn(true);
        tfp = std::make_unique<VerilatedFstC>();
        const char* fst_filename = "sim_output.fst";
        printf("[INFO] FST tracing ENABLED (debug mode): %s\n", fst_filename);
        printf("[INFO] For 5-10x faster simulation, unset ENABLE_TRACE\n");
        tb->trace(tfp.get(), 9);  // Reduced from 99 to 9 (top-level only)
        tfp->open(fst_filename);
    } else {
        printf("[INFO] FST tracing DISABLED (fast mode)\n");
        printf("[INFO] Set ENABLE_TRACE=1 to enable for debugging\n");
    }
#else
    printf("[INFO] FAST MODE: Tracing disabled at compile time\n");
    printf("[INFO] For debugging, use: make sim (with tracing support)\n");
#endif

    // Print startup message
#if defined(ENHANCED_TEST)
    printf("========================================\n");
    printf("  AURORA-172 Enhanced Test Starting\n");
    printf("========================================\n\n");
#elif defined(ADVANCED_TEST)
    printf("========================================\n");
    printf("  AURORA-172 Advanced Test Starting\n");
    printf("========================================\n\n");
#elif defined(ATM_TEST)
    printf("========================================\n");
    printf("  AURORA-172 ATM Features Test (Intel + AMD)\n");
    printf("========================================\n\n");
#elif defined(STRESS_TEST)
    printf("========================================\n");
    printf("  AURORA-172 Stress Test Starting\n");
    printf("========================================\n\n");
#else
    printf("========================================\n");
    printf("  AURORA-172 Basic Simulation Starting\n");
    printf("========================================\n\n");
#endif

    // Initialize
    tb->rootp->TB_CLK_PATH = 0;
    tb->rootp->TB_RST_PATH = 0;

    // Reset sequence (10 ticks)
    for (int i = 0; i < 10; i++) {
        tb->rootp->TB_CLK_PATH = !tb->rootp->TB_CLK_PATH;
        tb->eval();
        tfp->dump(main_time);  // Dump VCD
        main_time += 5;
    }

    tb->rootp->TB_RST_PATH = 1;
    printf("[INFO] Reset complete\n");

    // OPTIMIZATION 2: Configurable timeout via environment variable
    vluint64_t timeout = getenv("SIM_TIMEOUT") ? atol(getenv("SIM_TIMEOUT")) : 1000000;
    printf("[INFO] Simulation timeout: %" PRIu64 " cycles", timeout);
    if (getenv("SIM_TIMEOUT")) {
        printf(" (custom)");
    }
    printf("\n");

    // Run simulation loop
    while (!Verilated::gotFinish() && main_time < timeout) {
        tb->rootp->TB_CLK_PATH = !tb->rootp->TB_CLK_PATH;
        tb->eval();
        
        // Only dump trace if tracing is enabled
        if (enable_trace) {
            tfp->dump(main_time);
        }
        main_time += 5;

        // OPTIMIZATION 3: Reduce progress print frequency (500K -> 1M)
        if (main_time % 1000000 == 0) {
            printf("[INFO] Simulation progress: tick=%" PRIu64 "\n", main_time);
        }
    }

    printf("\n[INFO] Simulation complete (tick=%" PRIu64 ")\n", main_time);
    printf("========================================\n");

    // Close FST file only if it was opened
    if (enable_trace) {
        tfp->close();
        printf("[INFO] FST trace file closed\n");
    }

    return 0;
}
