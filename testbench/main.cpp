// ============================================================================
// AURORA-172 Main Wrapper
// Verilator C++ wrapper untuk simulasi
// ============================================================================

#include "Vtb_aurora_172.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    // Create testbench
    Vtb_aurora_172* tb = new Vtb_aurora_172;
    
    // Enable trace (VCD)
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    tb->trace(tfp, 99);
    tfp->open("aurora_172_tb.vcd");
    
    // Initialize
    tb->clk = 0;
    tb->rst_n = 0;
    
    // Run simulation
    int tick = 0;
    while (!Verilated::gotFinish() && tick < 100000) {
        tb->clk = !tb->clk;
        tb->eval();
        tfp->dump(tick * 5);
        tick++;
    }
    
    // Cleanup
    tfp->close();
    delete tfp;
    delete tb;
    
    return 0;
}
