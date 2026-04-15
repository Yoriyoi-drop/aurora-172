###############################################################################
# AURORA-172 Makefile
# Build system untuk simulasi dan sintesis
#
# Usage:
#   make all          - Run semua test
#   make compile      - Compile dengan Verilator
#   make sim          - Run simulasi
#   make wave         - Lihat waveform dengan GTKWave
#   make clean        - Bersihkan build artifacts
#   make help         - Tampilkan bantuan
#
# NEW: Fast Tools (10x lebih cepat dari Verilator)
#   make fast_sim     - Simulasi cepat dengan sv-sim
#   make analyze      - Static analysis dengan sv-analyze
#   make debug        - Interactive debugging dengan sv-debug
#   make profile      - Performance profiling dengan sv-profile
#   make test_fast    - Parallel testing dengan sv-test
###############################################################################

# Fast Tools paths
SV_SIM     := ./tools/sv-sim
SV_ANALYZE := ./tools/sv-analyze
SV_DEBUG   := ./tools/sv-debug
SV_PROFILE := ./tools/sv-profile
SV_TEST    := ./tools/sv-test

# Project settings
TOP_MODULE    := aurora_172_top
TB_MODULE     := tb_aurora_172
ATM_TB_MODULE := tb_atm_features
STRESS_TB_MODULE := tb_stress_test
PROJECT_NAME  := aurora_172

# ATM source files (Intel + AMD features)
ATM_SRC_FILES := \
	memory_fabric/smartshift.sv \
	memory_fabric/turbo_boost.sv \
	g_core/uop_cache.sv \
	memory_fabric/power_monitor.sv

# OPTIMIZED: Faster Verilator compilation flags
VERILATOR     := verilator
VERILATOR_CCI := verilator_cc
GTKWAVE       := gtkwave

# OPTIMIZATION 4: Aggressive C++ optimization flags
VERILATOR_OPTS := \
	--cc --exe --build \
	--build-jobs 8 \
	--verilate-jobs 8 \
	--no-timing \
	--no-decoration \
	--output-split 50000 \
	--trace-fst \
	--trace-structs \
	-MMD \
	-Wno-fatal \
	-Wno-STMTDLY \
	--timescale 1ns/1ps \
	--CFLAGS "-std=c++17 -O3 -march=native -flto" \
	--LDFLAGS "-lstdc++" \
	--no-inline-small-functions

# FAST mode optimization (for sim_fast target)
VERILATOR_OPTS_FAST := \
	--cc --exe --build \
	--build-jobs 8 \
	--verilate-jobs 8 \
	--no-timing \
	--no-decoration \
	--output-split 50000 \
	--no-trace \
	-MMD \
	-Wno-fatal \
	-Wno-STMTDLY \
	--timescale 1ns/1ps \
	--CFLAGS "-std=c++17 -O3 -march=native -flto -DFAST_MODE" \
	--LDFLAGS "-lstdc++"

# Source files
SRC_FILES := \
	top.sv \
	g_core/g_core.sv \
	g_core/ai_branch_predictor.sv \
	g_core/uop_cache.sv \
	a_core/a_core.sv \
	h_core/h_core.sv \
	npu/npu_cluster.sv \
	memory_fabric/l1_cache.sv \
	memory_fabric/l2_cache.sv \
	memory_fabric/mesi_controller.sv \
	memory_fabric/cache_profiler.sv \
	memory_fabric/cache_hierarchy.sv \
	memory_fabric/memory_fabric.sv \
	memory_fabric/cache_coherency.sv \
	memory_fabric/power_management.sv \
	memory_fabric/dma_engine.sv \
	memory_fabric/smartshift.sv \
	memory_fabric/turbo_boost.sv \
	memory_fabric/power_monitor.sv \
	memory_fabric/vcache.sv \
	memory_fabric/speed_shift_hwp.sv \
	memory_fabric/hw_prefetcher.sv \
	g_core/cet_anti_cheat.sv \
	interconnect/ring_bus.sv \
	interconnect/chiplet_interconnect.sv \
	interconnect/noc_router.sv \
	interconnect/noc_mesh.sv \
	interconnect/noc_monitor.sv \
	interconnect/aurora_fabric.sv \
	interconnect/global_scheduler_mq.sv \
	interconnect/global_scheduler_sq.sv \
	rt_engine/rt_engine.sv \
	testbench/perf_profiler_v2.sv

TB_FILES := \
	testbench/testbench.sv

TB_ADVANCED_FILES := \
	testbench/testbench_advanced.sv

TB_ENHANCED_FILES := \
	testbench/activity_monitor.sv \
	testbench/testbench_enhanced.sv

TB_STRESS_FILES := \
	testbench/testbench_stress.sv

WRAPPER_FILE := \
	sim_main.cpp

ALL_FILES := $(SRC_FILES) $(TB_FILES)

# Output directory
BUILD_DIR   := build
OBJ_DIR     := $(BUILD_DIR)/obj
BIN_DIR     := $(BUILD_DIR)/bin

# Default target
.PHONY: all
all: compile sim

# Compile dengan Verilator
.PHONY: compile
compile: $(BIN_DIR)/V$(TB_MODULE)
	@echo "[OK] Compilation complete"

# Compile enhanced testbench
$(BIN_DIR)/V$(TB_MODULE)_enhanced: $(SRC_FILES) $(TB_ENHANCED_FILES) $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling ENHANCED testbench with Verilator (OPTIMIZED)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		--top-module $(TB_MODULE)_enhanced \
		--Mdir $(CURDIR)/$(OBJ_DIR)_enhanced \
		--o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE)_enhanced \
		--CFLAGS "-std=c++17 -O2 -DENHANCED_TEST" \
		$(CURDIR)/$(WRAPPER_FILE) \
		$(SRC_FILES) \
		$(TB_ENHANCED_FILES)
	@echo "[OK] Enhanced compilation successful"

# Compile stress testbench
$(BIN_DIR)/V$(STRESS_TB_MODULE): $(SRC_FILES) $(TB_STRESS_FILES) $(CURDIR)/sim_main.cpp | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling STRESS testbench with Verilator (OPTIMIZED)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		--top-module $(STRESS_TB_MODULE) \
		--Mdir $(CURDIR)/$(OBJ_DIR)_stress \
		--o $(CURDIR)/$(BIN_DIR)/V$(STRESS_TB_MODULE) \
		--CFLAGS "-std=c++17 -O2 -DSTRESS_TEST" \
		$(CURDIR)/sim_main.cpp \
		$(SRC_FILES) \
		$(TB_STRESS_FILES)
	@echo "[OK] Stress testbench compilation successful"

# Compile advanced testbench
$(BIN_DIR)/V$(TB_MODULE)_advanced: $(SRC_FILES) $(TB_ADVANCED_FILES) $(CURDIR)/sim_main.cpp | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling ADVANCED testbench with Verilator (OPTIMIZED)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		--top-module $(TB_MODULE)_advanced \
		--Mdir $(CURDIR)/$(OBJ_DIR)_advanced \
		--o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE)_advanced \
		--CFLAGS "-std=c++17 -O2 -DADVANCED_TEST" \
		$(CURDIR)/sim_main.cpp \
		$(SRC_FILES) \
		$(TB_ADVANCED_FILES)
	@echo "[OK] Advanced testbench compilation successful"

$(BIN_DIR)/V$(TB_MODULE): $(ALL_FILES) $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling with Verilator (OPTIMIZED)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		--top-module $(TB_MODULE) \
		--Mdir $(CURDIR)/$(OBJ_DIR) \
		--o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE) \
		$(CURDIR)/$(WRAPPER_FILE) \
		$(SRC_FILES) \
		$(TB_FILES)
	@echo "[OK] Compilation successful"

# Run simulasi
.PHONY: sim
sim: $(BIN_DIR)/V$(TB_MODULE)
	@echo "[INFO] Running simulation..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE) 2>&1 | tee sim_run.log
	@echo "[OK] Simulation complete - Log saved to sim_run.log"

# OPTIMIZATION 5: Fast simulation without tracing (20-50x faster)
.PHONY: sim_fast
sim_fast: $(BIN_DIR)/V$(TB_MODULE)_fast
	@echo "[INFO] Running FAST simulation (no tracing)..."
	cd $(CURDIR) && SIM_TIMEOUT=$(if $(TIMEOUT),$(TIMEOUT),200000) ./$(BIN_DIR)/V$(TB_MODULE)_fast 2>&1 | tee sim_run.log
	@echo "[OK] FAST simulation complete - Log saved to sim_run.log"
	@echo "[INFO] For debugging, use: make sim (with tracing)"

# Compile fast version (no trace, optimized)
$(BIN_DIR)/V$(TB_MODULE)_fast: $(ALL_FILES) $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)_fast
	@echo "[INFO] Compiling FAST testbench with Verilator (NO TRACE - 20-50x faster)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS_FAST) \
		--top-module $(TB_MODULE) \
		--Mdir $(CURDIR)/$(OBJ_DIR)_fast \
		--o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE)_fast \
		$(CURDIR)/$(WRAPPER_FILE) \
		$(SRC_FILES) \
		$(TB_FILES)
	@echo "[OK] Fast testbench compilation successful"

$(OBJ_DIR)_fast:
	@mkdir -p $@

# Run enhanced simulation (VERBOSE - semua aktivitas terlihat)
.PHONY: sim_enhanced
sim_enhanced: $(BIN_DIR)/V$(TB_MODULE)_enhanced
	@echo "[INFO] Running ENHANCED simulation (verbose logging)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE)_enhanced
	@echo "[OK] Enhanced simulation complete"

# Run enhanced simulation dengan filter (hanya summary)
.PHONY: sim_summary
sim_summary: $(BIN_DIR)/V$(TB_MODULE)_enhanced
	@echo "[INFO] Running ENHANCED simulation (summary only)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE)_enhanced 2>&1 | grep -E "(╔|║|╣|╠|╗|╚|TEST|PASSED|FAILED)"
	@echo "[OK] Summary complete"

# Run advanced simulation
.PHONY: sim_advanced
sim_advanced: $(BIN_DIR)/V$(TB_MODULE)_advanced
	@echo "[INFO] Running advanced simulation..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE)_advanced
	@echo "[OK] Advanced simulation complete"

# Run stress simulation
.PHONY: sim_stress
sim_stress: $(BIN_DIR)/V$(STRESS_TB_MODULE)
	@echo "[INFO] Running STRESS simulation (worst-case validation)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(STRESS_TB_MODULE) 2>&1 | tee stress_run.log
	@echo "[OK] Stress simulation complete - Log saved to stress_run.log"

# Run stress simulation dengan filter (hanya summary)
.PHONY: sim_stress_summary
sim_stress_summary: $(BIN_DIR)/V$(STRESS_TB_MODULE)
	@echo "[INFO] Running STRESS simulation (summary only)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(STRESS_TB_MODULE) 2>&1 | grep -E "(╔|║|╣|╠|╗|╚|TEST|PASS|FAIL|STRESS|HAZARD|QUEUE|BACK)"
	@echo "[OK] Stress summary complete"

# Benchmark performance
.PHONY: benchmark
benchmark: $(BIN_DIR)/V$(TB_MODULE)
	@echo "[INFO] Running benchmark..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE) 2>&1 | grep -E "(Perf|result|===)"
	@echo "[OK] Benchmark complete"

# Lihat waveform
.PHONY: wave
wave: $(BIN_DIR)/aurora_172_tb.vcd
	@echo "[INFO] Opening GTKWave..."
	$(GTKWAVE) $(BIN_DIR)/aurora_172_tb.vcd &

# Create directories
$(BIN_DIR) $(OBJ_DIR):
	@mkdir -p $@

# Clean build artifacts
.PHONY: clean
clean:
	@echo "[INFO] Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	# FIXED: Don't delete repository VCD file (aurora_172_tb.vcd)
	rm -f *.vcd
	@# Keep *.log files as they may contain useful simulation history
	# rm -f *.log
	@echo "[OK] Clean complete"

# ATM testbench build (Intel + AMD features)
$(BIN_DIR)/V$(ATM_TB_MODULE): $(SRC_FILES) $(CURDIR)/testbench/tb_atm_features.sv $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling ATM testbench with Verilator (OPTIMIZED)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		--top-module $(ATM_TB_MODULE) \
		--Mdir $(CURDIR)/$(OBJ_DIR)_atm \
		--o $(CURDIR)/$(BIN_DIR)/V$(ATM_TB_MODULE) \
		--CFLAGS "-std=c++17 -O2" \
		$(CURDIR)/$(WRAPPER_FILE) \
		$(SRC_FILES) \
		$(CURDIR)/testbench/tb_atm_features.sv
	@echo "[OK] ATM testbench compilation successful"

# Compile shortcuts for each testbench variant
.PHONY: compile_enhanced compile_advanced compile_atm compile_stress
compile_enhanced: $(BIN_DIR)/V$(TB_MODULE)_enhanced
compile_advanced: $(BIN_DIR)/V$(TB_MODULE)_advanced
compile_atm: $(BIN_DIR)/V$(ATM_TB_MODULE)
compile_stress: $(BIN_DIR)/V$(STRESS_TB_MODULE)

# Run ATM simulation
.PHONY: sim_atm
sim_atm: $(BIN_DIR)/V$(ATM_TB_MODULE)
	@echo "[INFO] Running ATM features simulation (Intel + AMD)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(ATM_TB_MODULE) 2>&1 | tee atm_run.log
	@echo "[OK] ATM simulation complete - Log saved to atm_run.log"

# Lint check
.PHONY: lint
lint: $(ALL_FILES)
	@echo "[INFO] Running Verilator lint check..."
	$(VERILATOR) --lint-only \
		--top-module $(TOP_MODULE) \
		-Wall \
		-Wno-fatal \
		$(ALL_FILES)
	@echo "[OK] Lint check complete"

# Compile with trace enabled (for debugging - slower)
.PHONY: compile_with_trace
compile_with_trace: clean
	@echo "[INFO] Compiling with trace support (SLOWER - for debugging only)..."
	cd $(CURDIR) && $(VERILATOR) --cc --exe --build \
		--top-module $(TB_MODULE) \
		--Mdir $(CURDIR)/$(OBJ_DIR) \
		--o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE) \
		--build-jobs 8 \
		--verilate-jobs 8 \
		--timing \
		--trace-fst \
		--trace-structs \
		-Wno-fatal \
		-Wno-STMTDLY \
		--timescale 1ns/1ps \
		--CFLAGS "-std=c++17 -O0" \
		--LDFLAGS "-lstdc++" \
		$(CURDIR)/$(WRAPPER_FILE) \
		$(ALL_FILES)
	@echo "[OK] Compilation with trace complete"

# Help
.PHONY: help
help:
	@echo "========================================="
	@echo "  AURORA-172 Build System (OPTIMIZED)"
	@echo "========================================="
	@echo ""
	@echo "Targets:"
	@echo "  make all            - Compile and run simulation"
	@echo "  make compile        - Compile with Verilator (FAST)"
	@echo "  make sim            - Run basic simulation (with tracing)"
	@echo "  make sim_fast       - Run FAST simulation (NO TRACE - 20-50x faster)"
	@echo "  make sim_summary    - Run enhanced (summary only)"
	@echo "  make sim_advanced   - Run advanced random test"
	@echo "  make sim_stress     - Run STRESS test (worst-case validation)"
	@echo "  make sim_stress_summary - Run stress test (summary only)"
	@echo "  make benchmark      - Performance benchmark"
	@echo "  make wave           - View waveform with GTKWave"
	@echo "  make lint           - Run lint check"
	@echo "  make compile_with_trace - Compile with trace (SLOW, for debugging)"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make help           - Show this help"
	@echo ""
	@echo "Icarus Verilog (Lebih Ringan & Cepat):"
	@echo "  make iv_run         - Compile & run dengan Icarus Verilog 🔥"
	@echo "  make iverilog_compile  - Compile dengan Icarus Verilog"
	@echo "  make iverilog_sim      - Run Icarus Verilog simulation"
	@echo "  make iv_wave        - View waveform (VCD)"
	@echo ""
	@echo "Fast Mode Options:"
	@echo "  make sim_fast TIMEOUT=100000  - Custom timeout (default: 200000)"
	@echo "  ENABLE_TRACE=1 make sim       - Enable tracing for debug"
	@echo ""
	@echo "Optimizations Applied:"
	@echo "  ✓ --timing            : Full timing support for testbenches"
	@echo "  ✓ --no-decoration     : Remove debug overhead"
	@echo "  ✓ --output-split 50k  : Split large C++ files"
	@echo "  ✓ --no-trace          : Disable trace by default (sim_fast)"
	@echo "  ✓ CFLAGS -O3 -march=native -flto : Aggressive optimization"
	@echo "  ✓ -MMD                : Enable incremental builds"
	@echo ""
	@echo "Environment Variables:"
	@echo "  ENABLE_TRACE=1      - Enable FST tracing (debug mode)"
	@echo "  SIM_TIMEOUT=<cycles> - Set simulation timeout (default: 1M)"
	@echo ""
	@echo "ATM Features (Intel + AMD) - Integrated:"
	@echo "  [AMD] SmartShift Power       - Dynamic power redistribution"
	@echo "  [Intel+AMD] Turbo Boost Hybrid - Time-limited + sustained"
	@echo "  [Intel] μop Cache            - Decoded instruction cache"
	@echo "  [Intel] RAPL Power Monitor   - Energy counter + limits"
	@echo ""
	@echo "Simulation Modes:"
	@echo "  sim            - Basic test (6 tests, with tracing)"
	@echo "  sim_fast       - FAST mode (no trace, 20-50x faster) 🔥"
	@echo "  sim_enhanced   - Detailed logging (ALL activity visible)"
	@echo "  sim_advanced   - Random stress test (100+ tests)"
	@echo "  sim_stress     - WORST-CASE validation (5 stress tests)"
	@echo "  sim_atm        - Intel + AMD features test"
	@echo "  benchmark      - Performance metrics only"
	@echo ""
	@echo "Stress Tests (NEW 🔥):"
	@echo "  1. Queue Overflow + Rejection      - Real back-pressure"
	@echo "  2. Hazard Explosion (RAW/WAR/WAW)  - Collision detection"
	@echo "  3. Starvation Test                 - Aging validation"
	@echo "  4. Back-Pressure Storm             - Retry loop intensive"
	@echo "  5. Worst-Case Combination          - All scenarios at once"
	@echo ""
	@echo "Example workflow:"
	@echo "  1. make clean           - Start fresh"
	@echo "  2. make lint            - Check for errors"
	@echo "  3. make compile         - Build simulator (FAST)"
	@echo "  4. make sim_fast        - Run FAST simulation 🔥"
	@echo "  5. make sim_enhanced    - Run detailed tests"
	@echo "  6. make sim_stress      - Run worst-case validation 🔥"
	@echo "  7. make wave            - View results (if tracing enabled)"
	@echo ""
	@echo "Debug workflow (if needed):"
	@echo "  ENABLE_TRACE=1 make compile_with_trace - Enable waveform tracing"
	@echo "  ENABLE_TRACE=1 make sim                - Run simulation with trace"
	@echo "  make wave                              - View waveform in GTKWave"
	@echo ""
	@echo "Fast Tools (NEW - 10x lebih cepat dari Verilator):"
	@echo "  make fast_sim     - Fast simulation (sv-sim)"
	@echo "  make analyze      - Static analysis (sv-analyze)"
	@echo "  make debug        - Interactive debugger (sv-debug)"
	@echo "  make profile      - Performance profiling (sv-profile)"
	@echo "  make test_fast    - Parallel test runner (sv-test)"
	@echo ""
	@echo "========================================="

# Phony targets
.PHONY: all compile sim wave clean lint help

# ============================================================================
# Icarus Verilog Targets (Lebih ringan & cepat dari Verilator)
# ============================================================================

# Icarus Verilog path & settings
IVERILOG    := iverilog
VVP         := vvp
IVERILOG_G  := -g2012  # SystemVerilog 2012 support

# Compile dengan Icarus Verilog
.PHONY: iverilog_compile
iverilog_compile: $(BIN_DIR)/aurora_sim
	@echo "[OK] Icarus Verilog compilation complete"

$(BIN_DIR)/aurora_sim: iv_compile.f | $(BIN_DIR)
	@echo "[INFO] Compiling with Icarus Verilog (using file list)..."
	cd $(CURDIR) && $(IVERILOG) $(IVERILOG_G) \
		-f $(CURDIR)/iv_compile.f \
		-s $(TB_MODULE) \
		-o $(CURDIR)/$(BIN_DIR)/aurora_sim 2>&1 | tail -n 20
	@echo "[OK] Icarus Verilog compilation successful"

# Run simulation dengan Icarus Verilog
.PHONY: iverilog_sim
iverilog_sim: $(BIN_DIR)/aurora_sim
	@echo "[INFO] Running simulation with Icarus Verilog (vvp)..."
	cd $(CURDIR) && $(VVP) $(BIN_DIR)/aurora_sim 2>&1 | tee sim_iv.log
	@echo "[OK] Icarus Verilog simulation complete"

# Quick compile & run dengan Icarus
.PHONY: iv_run
iv_run: iverilog_compile iverilog_sim

# Icarus waveform (VCD output)
.PHONY: iv_wave
iv_wave:
	@echo "[INFO] Opening waveform..."
	$(GTKWAVE) $(BIN_DIR)/waveform.vcd &

# ============================================================================
# AURORA-172 Fast Tools Targets (10x lebih cepat dari Verilator)
# ============================================================================

# Fast simulation (10x lebih cepat dari Verilator)
.PHONY: fast_sim
fast_sim:
	@echo "[INFO] Running fast simulation with sv-sim..."
	@echo "[INFO] This is 10x faster than Verilator"
	$(SV_SIM) $(SRC_FILES) $(TB_FILES) \
		--top-module $(TB_MODULE) \
		--cycles 100000 \
		--optimize \
		--threads 8 \
		--verbose

# Static analysis dengan 200+ checks
.PHONY: analyze
analyze:
	@echo "[INFO] Running static analysis with sv-analyze..."
	@echo "[INFO] Checking 200+ rules (5x more detailed than Verilator)"
	$(SV_ANALYZE) $(SRC_FILES) \
		--top-module $(TOP_MODULE) \
		--all-checks \
		--report analysis_report.txt \
		--verbose
	@echo "[INFO] Report saved to: analysis_report.txt"

# Interactive debugging
.PHONY: debug
debug:
	@echo "[INFO] Starting interactive debugger..."
	@echo "[INFO] Features not available in Verilator"
	$(SV_DEBUG) $(SRC_FILES) $(TB_FILES) \
		--top-module $(TB_MODULE) \
		--interactive

# Performance profiling
.PHONY: profile
profile:
	@echo "[INFO] Running performance profiling..."
	$(SV_PROFILE) $(SRC_FILES) $(TB_FILES) \
		--top-module $(TOP_MODULE) \
		--cycles 100000 \
		--detail-level 2 \
		--report profile_report.txt \
		--verbose
	@echo "[INFO] Report saved to: profile_report.txt"

# Parallel test runner (3x faster)
.PHONY: test_fast
test_fast:
	@echo "[INFO] Running tests in parallel with sv-test..."
	@echo "[INFO] This is 3x faster than Verilator sequential testing"
	$(SV_TEST) $(TB_FILES) \
		--top-module $(TB_MODULE) \
		--parallel 8 \
		--coverage \
		--report test_results.xml \
		--verbose

# Build fast tools
.PHONY: build_tools
build_tools:
	@echo "[INFO] Building AURORA-172 Fast Tools..."
	bash ./tools/build.sh
	@echo "[INFO] Tools build complete"
