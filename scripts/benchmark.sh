#!/bin/bash
###############################################################################
# AURORA-172 Benchmark Script
# Mengukur performa dan menghasilkan report
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"  # FIXED: Parent directory is project root
BUILD_DIR="$PROJECT_DIR/build/bin"
REPORT_DIR="$SCRIPT_DIR/benchmarks"

# Create report directory
mkdir -p "$REPORT_DIR"

# Timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$REPORT_DIR/benchmark_$TIMESTAMP.txt"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  AURORA-172 Performance Benchmark${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if binary exists
if [ ! -f "$BUILD_DIR/Vtb_aurora_172" ]; then
    echo -e "${YELLOW}Binary not found. Compiling...${NC}"
    cd "$PROJECT_DIR"  # FIXED: cd to project root where Makefile is
    make compile
    cd "$SCRIPT_DIR"  # Go back to script directory
fi

echo -e "${GREEN}[1/4] Running baseline simulation...${NC}"
START_TIME=$(date +%s%N)
"$BUILD_DIR/Vtb_aurora_172" > "$REPORT_DIR/run_$TIMESTAMP.log" 2>&1
END_TIME=$(date +%s%N)
ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))
echo -e "${GREEN}      Complete in ${ELAPSED}ms${NC}"

echo -e "${GREEN}[2/4] Analyzing results...${NC}"

# Extract metrics from log
GAMING_CMDS=$(grep -c "Gaming CMD" "$REPORT_DIR/run_$TIMESTAMP.log" || echo "0")
AI_CMDS=$(grep -c "AI CMD" "$REPORT_DIR/run_$TIMESTAMP.log" || echo "0")
GAMING_RESULTS=$(grep -c "Gaming Result" "$REPORT_DIR/run_$TIMESTAMP.log" || echo "0")
AI_RESULTS=$(grep -c "AI Result" "$REPORT_DIR/run_$TIMESTAMP.log" || echo "0")
RESET_COMPLETE=$(grep -c "Reset complete" "$REPORT_DIR/run_$TIMESTAMP.log" || echo "0")

echo -e "${GREEN}[3/4] Calculating performance metrics...${NC}"

# Calculate operations per second
if [ "${ELAPSED:-0}" -gt 0 ]; then  # FIXED: Quoted variable with default
    OPS_PER_SEC=$(( (GAMING_CMDS + AI_CMDS) * 1000 / ELAPSED ))
else
    OPS_PER_SEC=0
fi

echo -e "${GREEN}[4/4] Generating report...${NC}"

# Generate report
cat > "$REPORT_FILE" << EOF
================================================================================
  AURORA-172 Performance Benchmark Report
================================================================================
Date: $(date)
Binary: $BUILD_DIR/Vtb_aurora_172
Execution Time: ${ELAPSED}ms

--------------------------------------------------------------------------------
  Test Results
--------------------------------------------------------------------------------
Gaming Commands Sent:     $GAMING_CMDS
AI Commands Sent:         $AI_CMDS
Gaming Results Received:  $GAMING_RESULTS
AI Results Received:      $AI_RESULTS
Reset Sequences:          $RESET_COMPLETE

--------------------------------------------------------------------------------
  Performance Metrics
--------------------------------------------------------------------------------
Total Operations:         $(( GAMING_CMDS + AI_CMDS ))
Operations/Second:        $OPS_PER_SEC
Execution Time:           ${ELAPSED}ms

--------------------------------------------------------------------------------
  Architecture Summary
--------------------------------------------------------------------------------
Total Cores:              112
  - G-Cores (Gaming):     16
  - H-Cores (General):    32
  - A-Cores (AI):         64
NPU Clusters:             8
Memory Bus:               172-bit
Target Clock:             6 GHz
AI Performance:           >5000 TOPS

--------------------------------------------------------------------------------
  Test Status
--------------------------------------------------------------------------------
EOF

if [ $GAMING_RESULTS -gt 0 ] && [ $AI_RESULTS -gt 0 ]; then
    echo "Status:                   ✓ PASSED" >> "$REPORT_FILE"
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
else
    echo "Status:                   ✗ FAILED" >> "$REPORT_FILE"
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
fi

cat >> "$REPORT_FILE" << EOF

================================================================================
  End of Report
================================================================================
EOF

# Display summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Benchmark Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Gaming Commands:    ${GREEN}$GAMING_CMDS${NC}"
echo -e "AI Commands:        ${GREEN}$AI_CMDS${NC}"
echo -e "Results Received:   ${GREEN}$(( GAMING_RESULTS + AI_RESULTS ))${NC}"
echo -e "Execution Time:     ${YELLOW}${ELAPSED}ms${NC}"
echo -e "Ops/Second:         ${YELLOW}$OPS_PER_SEC${NC}"
echo ""
echo -e "Full report: ${BLUE}$REPORT_FILE${NC}"
echo -e "Log file:    ${BLUE}$REPORT_DIR/run_$TIMESTAMP.log${NC}"
echo ""
echo -e "${GREEN}Benchmark complete!${NC}"
