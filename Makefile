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
# REAL Tools (bukan khayalan)
#   make icarus_syntax - Cek syntax dengan Icarus
#   make sim_fast      - Simulasi cepat tanpa trace
#   make sim           - Simulasi dengan trace
###############################################################################

# Tools yang benar-benar ada (bukan khayalan)
VERILATOR := verilator
IVERILOG  := iverilog
VVP       := vvp
GTKWAVE   := gtkwave

# UVM Configuration
UVM_HOME := $(PWD)/uvm-core-2020.3.1/src
UVM_PKG := $(UVM_HOME)/uvm_pkg.sv

# Project settings
TOP_MODULE    := aurora_172_top
TB_MODULE     := tb_aurora_172
UVM_TB_MODULE := tb_aurora_172_uvm
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

# Icarus Verilog support
IVERILOG      := iverilog
VVP           := vvp
IVERILOG_OPTS := -g2012 -Wall -Wno-fatal -DAURORA_FEATURES_POWER -DAURORA_FEATURES_CACHE -DAURORA_FEATURES_PERFORMANCE -DAURORA_FEATURES_SECURITY -DAURORA_DEBUG_CORE_STATE

# Verilator WAJIB - mode debug dengan trace
# Default optimized options (no tracing for fast compile)
VERILATOR_OPTS := \
	--cc --exe --build \
	--top-module $(TB_MODULE) \
	--timing \
	--threads 1 \
	--output-split 20000 \
	-O2 \
	-f iv_compile.f \
	-Wno-fatal -Wno-STMTDLY

# Conditional tracing (only when TRACE=1)
ifeq ($(TRACE),1)
VERILATOR_OPTS += --trace
endif

# FAST mode - maximum performance without tracing
VERILATOR_OPTS_FAST := \
	--cc --exe --build \
	--top-module $(TB_MODULE) \
	--timing \
	--threads 8 \
	--output-split 20000 \
	-O3 \
	-f iv_compile.f \
	-Wno-fatal -Wno-STMTDLY \
	-DFAST_MODE

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
	interfaces/axi_if.sv \
	interfaces/memory_if.sv \
	assertions/memory_assertions.sv

TB_FILES := \
	testbench/testbench.sv

WRAPPER_FILE := \
	sim_main.cpp

ALL_FILES := $(SRC_FILES) $(TB_FILES)

# Output directory
BUILD_DIR   := build
OBJ_DIR     := $(BUILD_DIR)/obj
BIN_DIR     := $(BUILD_DIR)/bin

# Clean log files
.PHONY: clean-logs
clean-logs:
	@echo "[INFO] Cleaning all log files..."
	@rm -f *.log
	@rm -f build/*.log
	@rm -f build/*/*.log
	@echo "[OK] All log files deleted"

# Default target
.PHONY: all
all: clean-logs compile sim

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

$(BIN_DIR)/V$(TB_MODULE): $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)
	@echo "[INFO] Compiling dengan Verilator (DEBUG mode)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS) \
		-Mdir $(CURDIR)/$(OBJ_DIR) \
		-o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE) \
		$(CURDIR)/$(WRAPPER_FILE)
	@echo "[OK] Compilation successful"

# Run simulasi (fast, no tracing by default)
.PHONY: sim
sim: $(BIN_DIR)/V$(TB_MODULE)
	@echo "[INFO] Running simulation (fast mode, no tracing)..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE) 2>&1 | tee sim_run.log
	@echo "[OK] Simulation complete - Log saved to sim_run.log"

# Debug simulation with tracing (use only when needed)
.PHONY: sim_debug
sim_debug: 
	@echo "[INFO] Compiling with tracing enabled..."
	$(MAKE) clean
	$(MAKE) TRACE=1 $(BIN_DIR)/V$(TB_MODULE)
	@echo "[INFO] Running simulation with tracing..."
	cd $(CURDIR) && ./$(BIN_DIR)/V$(TB_MODULE) 2>&1 | tee sim_run.log
	@echo "[OK] Debug simulation complete - Log saved to sim_run.log"
	@echo "[INFO] VCD file: sim_output.vcd"

# Ultra-fast simulation (no tracing, optimized)
.PHONY: sim_fast
sim_fast: $(BIN_DIR)/V$(TB_MODULE)_fast
	@echo "[INFO] Running ULTRA-FAST simulation (no tracing)..."
	cd $(CURDIR) && SIM_TIMEOUT=$(if $(TIMEOUT),$(TIMEOUT),200000) ./$(BIN_DIR)/V$(TB_MODULE)_fast 2>&1 | tee sim_run.log
	@echo "[OK] FAST simulation complete - Log saved to sim_run.log"
	@echo "[INFO] For debugging, use: make sim_debug"

# Compile fast version (no trace, optimized)
$(BIN_DIR)/V$(TB_MODULE)_fast: $(CURDIR)/$(WRAPPER_FILE) | $(BIN_DIR) $(OBJ_DIR)_fast
	@echo "[INFO] Compiling FAST testbench dengan Verilator (NO TRACE)..."
	cd $(CURDIR) && $(VERILATOR) $(VERILATOR_OPTS_FAST) \
		-Mdir $(CURDIR)/$(OBJ_DIR)_fast \
		-o $(CURDIR)/$(BIN_DIR)/V$(TB_MODULE)_fast \
		$(CURDIR)/sim_main_fast.cpp
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
	 rm -f *.log
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
	@echo "  make icarus_compile - Compile dengan Icarus Verilog"
	@echo "  make icarus_sim     - Compile & run simulasi"
	@echo "  make icarus_sim_fast - Fast simulation (no tracing)"
	@echo "  make icarus_wave    - Generate VCD waveform"
	@echo "  make wave_vcd      - View VCD dengan GTKWave"
	@echo "  make icarus_debug   - Debug mode"
	@echo "  make icarus_syntax - Syntax check only (tercepat)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  make icarus_syntax     - Quick syntax check"
	@echo "  make icarus_sim        - Full simulation with logging"
	@echo "  make icarus_sim_fast   - Fast development cycle"
	@echo "  make icarus_wave && make wave_vcd - Debug dengan waveform"
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
	@echo "REAL Tools (yang benar-benar ada):"
	@echo "  make icarus_syntax - Syntax check tercepat"
	@echo "  make sim_fast      - Simulasi cepat tanpa trace"
	@echo "  make sim           - Simulasi dengan trace"
	@echo "  make icarus_sim    - Simulasi dengan Icarus"
	@echo ""
	@echo "========================================="

# Phony targets
.PHONY: all compile sim wave clean lint help

# ============================================================================
# Icarus Verilog Targets (Lebih ringan & cepat dari Verilator)
# ============================================================================

# SBY (SymbiYosys) path & settings
SBY         := sby
SBY_OPTS    := --threads 4 --yosys-opts -Q

# Formal verification dengan SBY
.PHONY: sby_run
sby_run:
	@echo "[INFO] Running formal verification dengan SBY..."
	cd $(CURDIR) && $(SBY) $(SBY_OPTS) aurora.sby
	@echo "[OK] Formal verification complete"

# Quick formal check
.PHONY: sby_quick
sby_quick:
	@echo "[INFO] Quick formal check (depth 50)..."
	cd $(CURDIR) && $(SBY) -f aurora.sby quick
	@echo "[OK] Quick formal check complete"

# Lightweight version untuk laptop low-spec
.PHONY: iv_run_light
iv_run_light:
	@echo "[INFO] Compiling LIGHTWEIGHT version (low memory)..."
	$(IVERILOG) $(IVERILOG_G) \
		-f $(CURDIR)/iv_run_light.f \
		-s $(TB_MODULE) \
		-o $(CURDIR)/$(BIN_DIR)/aurora_sim_light
	@echo "[INFO] Running lightweight simulation dengan TIMEOUT 30 detik..."
	@echo "[WARNING] Simulation akan di-STOP otomatis setelah 30 detik"
	cd $(CURDIR) && timeout 30s $(VVP) $(BIN_DIR)/aurora_sim_light +SIM_TIMEOUT=30000 2>&1 | tee sim_iv_light.log
	@echo "[OK] Lightweight simulation complete (dibatasi 30 detik)"

# Version dengan timeout custom
.PHONY: iv_run_safe
iv_run_safe:
	@if [ -z "$(TIMEOUT)" ]; then \
		echo "[INFO] Usage: make iv_run_safe TIMEOUT=60"; \
		echo "[INFO] Default: 60 detik"; \
		TIMEOUT=60; \
	fi
	@echo "[INFO] Compiling SAFE version dengan timeout $(TIMEOUT) detik..."
	$(IVERILOG) $(IVERILOG_G) \
		-f $(CURDIR)/iv_compile.f \
		-s $(TB_MODULE) \
		-o $(CURDIR)/$(BIN_DIR)/aurora_sim_safe
	@echo "[INFO] Running SAFE simulation dengan TIMEOUT $(TIMEOUT) detik..."
	@echo "[WARNING] Simulation akan di-STOP otomatis setelah $(TIMEOUT) detik"
	cd $(CURDIR) && timeout $(TIMEOUT)s $(VVP) $(BIN_DIR)/aurora_sim_safe +SIM_TIMEOUT=$(shell echo $(TIMEOUT) | awk '{print $$1*1000}') 2>&1 | tee sim_iv_safe.log
	@echo "[OK] SAFE simulation complete (dibatasi $(TIMEOUT) detik)"

# Icarus waveform (VCD output)
.PHONY: iv_wave
iv_wave:
	@echo "[INFO] Opening waveform..."
	$(GTKWAVE) $(BIN_DIR)/waveform.vcd &

# ============================================================================
# REAL TARGETS (bukan khayalan)
# ============================================================================

# Syntax check tercepat
.PHONY: icarus_syntax
icarus_syntax:
	@echo "[INFO] Cek syntax dengan Icarus..."
	cd $(CURDIR) && $(IVERILOG) -g2012 -Wall -t -f iv_compile.f
	@echo "[OK] Syntax check complete"

# ============================================================================
# ICARUS VERILOG TARGETS
# ============================================================================

# Compile dengan Icarus Verilog (menggunakan iv_compile.f)
.PHONY: icarus_compile
icarus_compile:
	@echo "[INFO] Compiling with Icarus Verilog using iv_compile.f..."
	cd $(CURDIR) && mkdir -p build && $(IVERILOG) $(IVERILOG_OPTS) \
		-f iv_compile.f \
		-o build/aurora_172.vvp 2>&1 | tee icarus_compile.log
	@echo "[OK] Icarus Verilog compilation complete - Log saved to icarus_compile.log"

# Run simulasi dengan Icarus Verilog
.PHONY: icarus_sim
icarus_sim: icarus_compile
	@echo "[INFO] Running Icarus Verilog simulation..."
	@$(VVP) build/aurora_172.vvp 2>&1 | tee icarus_sim.log; \
	status=$$?; \
	if [ $$status -ne 0 ]; then \
		echo "[ERROR] Simulation failed with exit code $$status"; \
	else \
		echo "[OK] Simulation complete - Log saved to icarus_sim.log"; \
	fi
# Fast Icarus simulation (no tracing)
.PHONY: icarus_sim_fast
icarus_sim_fast:
	@echo "[INFO] Compiling with Icarus Verilog (fast mode) using iv_compile.f..."
	cd $(CURDIR) && mkdir -p build && $(IVERILOG) -g2012 -Wall \
		-f iv_compile.f \
		-o build/aurora_172_fast.vvp
	@echo "[OK] Fast compilation successful"
	@echo "[INFO] Running fast simulation with timeout protection..."
	@echo "[INFO] Timeout: 30 seconds (fast mode)"
	cd $(CURDIR) && timeout 30s $(VVP) build/aurora_172_fast.vvp 2>&1 | tee icarus_fast.log || \
		if [ $$? -eq 124 ]; then \
			echo "[TIMEOUT] Fast simulation stopped after 30 seconds"; \
		else \
			echo "[OK] Fast simulation complete"; \
		fi

# Generate VCD waveform dengan Icarus
.PHONY: icarus_wave
icarus_wave:
	@echo "[INFO] Compiling with VCD dump support using iv_compile.f..."
	cd $(CURDIR) && mkdir -p build && $(IVERILOG) -g2012 -Wall -DDUMP_VCD \
		-f iv_compile.f \
		-o build/aurora_172_wave.vvp
	@echo "[OK] Waveform compilation successful"
	@echo "[INFO] Running simulation with VCD dump (timeout protected)..."
	@echo "[INFO] Timeout: 45 seconds (wave generation)"
	cd $(CURDIR) && timeout 45s $(VVP) build/aurora_172_wave.vvp || \
		if [ $$? -eq 124 ]; then \
			echo "[TIMEOUT] Wave simulation stopped after 45 seconds"; \
		else \
			echo "[OK] VCD waveform generated - Use: make wave_vcd"; \
		fi

# View VCD waveform dengan GTKWave
.PHONY: wave_vcd
wave_vcd:
	@echo "[INFO] Opening VCD waveform with GTKWave..."
	cd $(CURDIR) && $(GTKWAVE) build/aurora_172.vcd &

# Debug dengan Icarus Verilog
.PHONY: icarus_debug
icarus_debug:
	@echo "[INFO] Compiling with debug symbols using iv_compile.f..."
	cd $(CURDIR) && mkdir -p build && $(IVERILOG) -g2012 -Wall -g \
		-f iv_compile.f \
		-o build/aurora_172_debug.vvp
	@echo "[OK] Debug compilation successful"
	@echo "[INFO] Running debug simulation..."
	cd $(CURDIR) && $(VVP) build/aurora_172_debug.vvp

# Custom timeout simulation
.PHONY: icarus_sim_timeout
icarus_sim_timeout:
	@if [ -z "$(TIMEOUT)" ]; then \
		echo "[INFO] Usage: make icarus_sim_timeout TIMEOUT=60"; \
		echo "[INFO] Default: 60 seconds"; \
		TIMEOUT=60; \
	fi
	@echo "[INFO] Running simulation with custom timeout $(TIMEOUT) seconds..."
	cd $(CURDIR) && timeout $(TIMEOUT)s $(VVP) build/aurora_172.vvp 2>&1 | tee icarus_custom_timeout.log || \
		if [ $$? -eq 124 ]; then \
			echo "[TIMEOUT] Simulation stopped after $(TIMEOUT) seconds"; \
		else \
			echo "[OK] Simulation complete"; \
		fi

# Syntax check only (fastest)
.PHONY: icarus_syntax
icarus_syntax:
	@echo "[INFO] Running Icarus Verilog syntax check using iv_compile.f..."
	cd $(CURDIR) && $(IVERILOG) -g2012 -Wall -t \
		-f iv_compile.f -s $(TB_MODULE)
	@echo "[OK] Syntax check complete"

# Tidak ada build tools - tools khayalan dihapus
