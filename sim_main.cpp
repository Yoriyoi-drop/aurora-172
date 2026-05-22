// ============================================================================
// AURORA-172 Simulation Main
// Entry point untuk Verilator simulation (support multiple testbenches)
// WITH VCD WAVEFORM TRACING
// ============================================================================

#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"  // VCD tracing (only when compiled with --trace)
#endif
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

// FIXED: Let testbench control clock and reset - no manual control needed

// Global tick counter
static vluint64_t main_time = 0;

int main(int argc, char** argv, char** env) {
    Verilated::commandArgs(argc, argv);
#if VM_TRACE
    Verilated::traceEverOn(true); // REQUIRED by Verilator if --trace is used
#endif

    // Create testbench instance
    std::unique_ptr<TB_CLASS> tb = std::make_unique<TB_CLASS>();

    // OPTIMIZATION 1: Conditional VCD tracing (5-10x speedup when disabled)
    // Only enable tracing if explicitly requested AND compiled with trace support
#if VM_TRACE
    bool enable_trace = false;
    std::unique_ptr<VerilatedVcdC> tfp;

    if (getenv("ENABLE_TRACE") != nullptr) {
        enable_trace = true;
        Verilated::traceEverOn(true);
        tfp = std::make_unique<VerilatedVcdC>();
        const char* vcd_filename = "sim_output.vcd";
        printf("[INFO] VCD tracing ENABLED (debug mode): %s\n", vcd_filename);
        printf("[INFO] For 5-10x faster simulation, unset ENABLE_TRACE\n");
        tb->trace(tfp.get(), 9);  // Reduced from 99 to 9 (top-level only)
        tfp->open(vcd_filename);
    } else {
        printf("[INFO] VCD tracing DISABLED (fast mode)\n");
        printf("[INFO] Set ENABLE_TRACE=1 to enable for debugging\n");
    }
#else
    printf("[INFO] Tracing disabled at compile time (no --trace flag)\n");
    printf("[INFO] For debugging, use: make sim_debug\n");
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

    // Initialize - Let testbench control clock and reset
    printf("[INFO] Letting testbench control clock and reset...\n");

    // OPTIMIZATION 2: Configurable timeout via environment variable
    vluint64_t timeout = getenv("SIM_TIMEOUT") ? atol(getenv("SIM_TIMEOUT")) : 500000000;
    printf("[INFO] Simulation timeout: %" PRIu64 " cycles", timeout);
    if (getenv("SIM_TIMEOUT")) {
        printf(" (custom)");
    }
    printf("\n");

    // Run simulation loop - let testbench control everything
    while (!Verilated::gotFinish() && main_time < timeout) {
        // CRITICAL: Set simulation time before eval for #delay to work
        Verilated::time(main_time);

        // Just eval - testbench controls clock internally
        tb->eval();

        // Flush stdout to ensure $display output is visible in real-time
        fflush(stdout);

#if VM_TRACE
        // Only dump trace if tracing is enabled
        if (enable_trace) {
            tfp->dump(main_time);
        }
#endif
        main_time += 1;  // Increment by 1 time unit

        // Progress print every 10M ticks
        if (main_time % 10000000 == 0) {
            printf("[INFO] tick=%" PRIu64 "\n", main_time);
        }
    }

    printf("\n[INFO] Simulation complete (tick=%" PRIu64 ")\n", main_time);
    printf("========================================\n");

    // Close VCD file only if it was opened
#if VM_TRACE
    if (enable_trace) {
        tfp->close();
        printf("[INFO] VCD trace file closed\n");
    }
#endif

    return 0;
}
