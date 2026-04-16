// AURORA-172 File List for Icarus Verilog
// Format: One file per line, in compilation order

// Top level & testbench
testbench/testbench.sv

// Top module
top.sv

// G-Core (Gaming cores)
g_core/g_core.sv
g_core/ai_branch_predictor.sv
g_core/uop_cache.sv
g_core/cet_anti_cheat.sv

// A-Core (AI cores)
a_core/a_core.sv

// H-Core (High-performance cores)
h_core/h_core.sv

// NPU (Neural Processing Unit)
npu/npu_cluster.sv

// Memory Fabric
memory_fabric/l1_cache.sv
memory_fabric/l2_cache.sv
memory_fabric/mesi_controller.sv
memory_fabric/cache_profiler.sv
memory_fabric/cache_hierarchy.sv
memory_fabric/memory_fabric.sv
memory_fabric/cache_coherency.sv
memory_fabric/power_management.sv
memory_fabric/dma_engine.sv
memory_fabric/smartshift.sv
memory_fabric/turbo_boost.sv
memory_fabric/power_monitor.sv
memory_fabric/vcache.sv
memory_fabric/speed_shift_hwp.sv
memory_fabric/hw_prefetcher.sv

//interfaces
interfaces/axi_if.sv
interfaces/memory_if.sv

//assertions
assertions/memory_assertions.sv

// Interconnect
interconnect/ring_bus.sv
interconnect/chiplet_interconnect.sv
interconnect/noc_router.sv
interconnect/noc_mesh.sv
interconnect/noc_monitor.sv
interconnect/aurora_fabric.sv
interconnect/global_scheduler_mq.sv  // ENABLED: Using hybrid MQ scheduler
interconnect/global_scheduler_sq.sv

// RT Engine
rt_engine/rt_engine.sv

// Testbench utilities
testbench/perf_profiler_v2.sv
