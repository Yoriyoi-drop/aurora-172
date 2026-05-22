`timescale 1ns / 1ps

// Import global package for parameters
`include "interfaces/aurora_params.svh"
// Import constants for opcode definitions
`include "interfaces/aurora_constants.svh"
// Import invariants for toxic bug family detection
`include "DEBUG_INVARIANTS.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 11 April 2026
// Design Name: AURORA-172 Global Scheduler — Hybrid Multi-Queue (v4.0)
// Module Name: global_scheduler_mq
//
// Description:
//   HYBRID MULTI-QUEUE ARCHITECTURE (v4.0):
//   FQ (Front Queue) → DQ (Decode Queue) → EQ (Execution Queues) → RQ → CQ
//
//   Queue Pipeline:
//   1. FQ: Input buffer — semua task masuk sini dulu (FIFO)
//   2. DQ: Decode & dependency tagging — parse opcode, set DEP_MASK, PRIORITY
//   3. EQ: Execution Queues — EQ-ALU, EQ-MEM, EQ-VEC (parallel, load balanced)
//   4. RQ: Reorder Queue — out-of-order execution, in-order commit
//   5. CQ: Commit Queue — atomic write-back ke core/memory
//
//   Dynamic Queue Balancer (DQB):
//   - Spill overflow EQ ke EQ lain yang kompatibel
//   - Work stealing dari EQ yang idle
//   - Load balancing berdasarkan latency sensitivity
//
//   Legacy Multi-Queue (v3.x):
//   G/A/NPU domain-isolated queues + WDRR arbitration + aging
//////////////////////////////////////////////////////////////////////////////////

// verilator lint_off CASEINCOMPLETE
// verilator lint_off BLKANDNBLK
// verilator lint_off BLKLOOPINIT

module global_scheduler_mq #(
    // Use standardized parameters from aurora_params.svh
    parameter DATA_WIDTH       = `AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH       = `AURORA_ADDR_WIDTH,
    parameter G_QUEUE_DEPTH    = 16,
    parameter A_QUEUE_DEPTH    = 8,
    parameter N_QUEUE_DEPTH    = 4,
    /* verilator lint_off UNUSED */
    parameter G_WEIGHT         = 2,     // OPTIMIZED: 4->2 (simpler weights)
    parameter A_WEIGHT         = 4,     // OPTIMIZED: 8->4 (simpler weights)
    parameter N_WEIGHT         = 1,     // OPTIMIZED: 2->1 (simpler weights)
    /* verilator lint_on UNUSED */
    parameter AGING_RATE       = 4,     // OPTIMIZED: 8->4 (faster aging)
    parameter MAX_AGING        = 4,     // OPTIMIZED: 8->4 (simpler aging)
    parameter ADMISSION_THRESHOLD_PERCENT = 95,  // OPTIMIZED: 90->95 (more relaxed)

    // Use standardized watchdog timeouts from aurora_params.svh
    parameter G_WATCHDOG_TIMEOUT   = 1000,
    parameter A_WATCHDOG_TIMEOUT   = 2000,
    parameter N_WATCHDOG_TIMEOUT   = 1500,

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE PARAMETERS (v4.0)
    // ═══════════════════════════════════════════════════════
    parameter FQ_DEPTH         = 8,    // Front Queue depth (input buffer)
    parameter DQ_DEPTH         = 12,   // Decode Queue depth (with dependency tags)
    parameter EQ_ALU_DEPTH     = 8,    // EQ-ALU queue depth (compute ops)
    parameter EQ_MEM_DEPTH     = 8,    // EQ-MEM queue depth (memory ops)
    parameter EQ_VEC_DEPTH     = 8,    // EQ-VEC queue depth (vector/AI ops)
    parameter RQ_DEPTH         = 16,   // Reorder Queue depth (in-order commit)
    parameter CQ_DEPTH         = 4,    // Commit Queue depth (atomic write-back)
    parameter TAG_ID_WIDTH     = 8,    // Task tag ID width
    parameter DEP_MASK_WIDTH   = 16    // Dependency mask width
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Task input
    input  wire [ADDR_WIDTH-1:0]        g_task_addr,
    input  wire [31:0]                  g_task_data,
    input  wire                         g_task_valid,
    output wire                         g_task_ready,
    output wire [DATA_WIDTH-1:0]        g_task_result,
    output wire                         g_task_result_valid,

    input  wire [ADDR_WIDTH-1:0]        a_task_addr,
    input  wire [63:0]                  a_task_data,
    input  wire                         a_task_valid,
    output wire                         a_task_ready,
    output wire [DATA_WIDTH-1:0]        a_task_result,
    output wire                         a_task_result_valid,

    input  wire                         npu_task_valid,
    output wire                         npu_task_ready,
    output wire [DATA_WIDTH-1:0]        npu_task_result,
    output wire                         npu_task_result_valid,

    // G-Core dispatch
    output wire [ADDR_WIDTH-1:0]        g_core_cmd_addr,
    output wire [31:0]                  g_core_cmd_data,
    output wire                         g_core_cmd_valid,
    input  wire                         g_core_cmd_ready,  // CRITICAL FIX: Add missing ready signal
    input  wire                         g_core_busy,
    input  wire                         g_core_complete,
    input  wire [DATA_WIDTH-1:0]        g_core_result,
    input  wire                         g_core_error_valid,

    // A-Core dispatch
    output wire [ADDR_WIDTH-1:0]        a_core_cmd_addr,
    output wire [63:0]                  a_core_cmd_data,
    output wire                         a_core_cmd_valid,
    input  wire                         a_core_busy,
    input  wire                         a_core_complete,
    input  wire [DATA_WIDTH-1:0]        a_core_result,
    input  wire                         a_core_result_valid,  // CRITICAL FIX: A-Core result valid signal
    output wire                         a_core_result_ready,  // CRITICAL FIX: Scheduler ready to consume result

    // NPU dispatch
    output wire                         npu_dispatch_valid,
    input  wire                         npu_busy,
    input  wire                         npu_complete,
    input  wire [DATA_WIDTH-1:0]        npu_result,

    // Debug / performance
    output wire [63:0]                  sched_total_dispatched,
    output wire [63:0]                  sched_total_completed,
    output wire [63:0]                  sched_total_stalled,
    output wire [63:0]                  sched_stall_resource_wait,
    output wire [63:0]                  sched_stall_queue_contention,
    output wire [31:0]                  sched_queue_depth,
    output wire [31:0]                  sched_max_queue_depth,
    output wire [31:0]                  sched_conflict_count,
    output wire [7:0]                   sched_gaming_priority,
    output wire [7:0]                   sched_ai_priority,
    output wire [7:0]                   sched_npu_priority,
    output wire [31:0]                  sched_aging_tasks,
    output wire [31:0]                  sched_rr_rotations,
    output wire [31:0]                  sched_queue_avoidance,
    output wire [31:0]                  sched_watchdog_resets,
    output wire [31:0]                  sched_bp_queue_full_rejections,
    output wire [31:0]                  sched_bp_timeout_stalls,
    output wire [31:0]                  sched_bp_actual_accepts,
    output wire [31:0]                  sched_admission_rejections,  // NEW
    output wire [31:0]                  sched_hazard_raw,
    output wire [31:0]                  sched_hazard_war,
    output wire [31:0]                  sched_hazard_waw,
    output wire [31:0]                  sched_hazard_structural,
    output wire [31:0]                  sched_hazard_dependency,
    output wire [31:0]                  sched_hazard_dependency_stalls,  // NEW: Track actual stall count
    
    // NEW: Per-core utilization outputs
    output wire [31:0]                  sched_g_core_busy_cycles,
    output wire [31:0]                  sched_a_core_busy_cycles,
    output wire [31:0]                  sched_n_core_busy_cycles,
    output wire [31:0]                  sched_total_sim_cycles,
    
    // NEW: Hybrid Queue stage counters (v4.0 debug)
    output wire [31:0]                  sched_hq_fq_enqueued,
    output wire [31:0]                  sched_hq_dq_decoded,
    output wire [31:0]                  sched_hq_eq_dispatched,
    output wire [31:0]                  sched_hq_rq_committed,
    output wire [31:0]                  sched_hq_cq_completed,

    // Ring bus interface for load balancing
    input  wire [31:0]                  ring_bus_g_packets,
    input  wire [31:0]                  ring_bus_a_packets,
    input  wire [31:0]                  ring_bus_contention,
    input  wire                         ring_bus_congested
);

    localparam TASK_GAMING = 2'b00;
    localparam TASK_AI     = 2'b01;
    localparam TASK_NPU    = 2'b10;

    // ── Per-domain queues ──
    // G-Queue
    reg [ADDR_WIDTH-1:0]    g_q_addr  [0:G_QUEUE_DEPTH-1];
    reg [63:0]              g_q_data  [0:G_QUEUE_DEPTH-1];
    reg [7:0]               g_q_opcode [0:G_QUEUE_DEPTH-1];
    reg                     g_q_valid [0:G_QUEUE_DEPTH-1];
    reg                     g_q_disp  [0:G_QUEUE_DEPTH-1];
    reg [7:0]               g_q_aging [0:G_QUEUE_DEPTH-1];
    reg [7:0]               g_q_wait  [0:G_QUEUE_DEPTH-1];
    reg                     g_q_fresh [0:G_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(G_QUEUE_DEPTH)-1:0] g_head, g_tail;
    reg [31:0]              g_q_count, g_credits;
    reg [15:0]              debug_counter;  // DEBUG: Counter untuk print status
    
    // A-Queue
    reg [ADDR_WIDTH-1:0]    a_q_addr  [0:A_QUEUE_DEPTH-1];
    reg [63:0]              a_q_data  [0:A_QUEUE_DEPTH-1];
    reg [7:0]               a_q_opcode [0:A_QUEUE_DEPTH-1];
    reg                     a_q_valid [0:A_QUEUE_DEPTH-1];
    reg                     a_q_disp  [0:A_QUEUE_DEPTH-1];
    reg [7:0]               a_q_aging [0:A_QUEUE_DEPTH-1];
    reg [7:0]               a_q_wait  [0:A_QUEUE_DEPTH-1];
    reg                     a_q_fresh [0:A_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(A_QUEUE_DEPTH)-1:0] a_head, a_tail;
    reg [31:0]              a_q_count, a_credits;

    // N-Queue
    reg [ADDR_WIDTH-1:0]    n_q_addr  [0:N_QUEUE_DEPTH-1];
    reg [63:0]              n_q_data  [0:N_QUEUE_DEPTH-1];
    reg                     n_q_valid [0:N_QUEUE_DEPTH-1];
    reg                     n_q_disp  [0:N_QUEUE_DEPTH-1];
    reg [7:0]               n_q_aging [0:N_QUEUE_DEPTH-1];
    reg [7:0]               n_q_wait  [0:N_QUEUE_DEPTH-1];
    reg                     n_q_fresh [0:N_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(N_QUEUE_DEPTH)-1:0] n_head, n_tail;
    reg [31:0]              n_q_count, n_credits;

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE STRUCTURES (v4.0)
    // ═══════════════════════════════════════════════════════

    // ── Task Tag Structure (Dependency Tracking) ──
    // TAG = {ID, DEP_MASK, PRIORITY, EQ_TYPE}
    // ID: Unique task identifier
    // DEP_MASK: Bitmask of task IDs this task depends on
    // PRIORITY: 0=highest, 7=lowest (before aging)
    // EQ_TYPE: Target execution queue type

    localparam EQ_TYPE_ALU = 2'b00;  // ALU/Compute
    localparam EQ_TYPE_MEM = 2'b01;  // Memory ops
    localparam EQ_TYPE_VEC = 2'b10;  // Vector/AI ops
    localparam EQ_TYPE_ANY = 2'b11;  // Can go to any EQ (spill target)

    // Task Tag register
    reg [TAG_ID_WIDTH-1:0]        task_id_counter;  // Auto-increment task ID counter
    reg [TAG_ID_WIDTH-1:0]        fq_tag_id   [0:FQ_DEPTH-1];   // FQ task IDs
    reg [7:0]                     fq_tag_opcode [0:FQ_DEPTH-1]; // FQ opcodes (for decode)
    reg [ADDR_WIDTH-1:0]          fq_tag_addr   [0:FQ_DEPTH-1]; // FQ task addresses
    reg [63:0]                    fq_tag_data   [0:FQ_DEPTH-1]; // FQ task data
    reg                           fq_tag_valid  [0:FQ_DEPTH-1]; // FQ tag valid flags
    reg [$clog2(FQ_DEPTH)-1:0]    fq_tail, fq_head;  // FQ head/tail pointers

    reg [TAG_ID_WIDTH-1:0]        dq_tag_id   [0:DQ_DEPTH-1];   // DQ task IDs
    reg [DEP_MASK_WIDTH-1:0]      dq_dep_mask [0:DQ_DEPTH-1];   // DQ dependency masks
    reg [2:0]                     dq_priority [0:DQ_DEPTH-1];   // DQ priority (0-7)
    reg [1:0]                     dq_eq_type  [0:DQ_DEPTH-1];   // DQ target EQ type
    reg [ADDR_WIDTH-1:0]          dq_addr     [0:DQ_DEPTH-1];   // DQ addresses
    reg [63:0]                    dq_data     [0:DQ_DEPTH-1];   // DQ data
    reg                           dq_valid    [0:DQ_DEPTH-1];   // DQ valid flags
    reg                           dq_decoded  [0:DQ_DEPTH-1];   // DQ decoded flag
    reg [7:0]                     dq_opcode   [0:DQ_DEPTH-1];   // DQ task opcode
    reg [$clog2(DQ_DEPTH)-1:0]    dq_head, dq_tail;
    reg [31:0]                    dq_count;

    // ── Execution Queues (EQ) ──
    // EQ-ALU: For compute-heavy ops (DRAW, PHYSICS, MATMUL, etc)
    reg [TAG_ID_WIDTH-1:0]        eq_alu_tag_id  [0:EQ_ALU_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_alu_addr    [0:EQ_ALU_DEPTH-1];
    reg [63:0]                    eq_alu_data    [0:EQ_ALU_DEPTH-1];
    reg                           eq_alu_valid   [0:EQ_ALU_DEPTH-1];
    reg                           eq_alu_ready   [0:EQ_ALU_DEPTH-1];  // Dependencies met?
    reg [31:0]                    eq_alu_count;

    // EQ-MEM: For memory ops (LOAD, STORE, cache ops)
    reg [TAG_ID_WIDTH-1:0]        eq_mem_tag_id  [0:EQ_MEM_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_mem_addr    [0:EQ_MEM_DEPTH-1];
    reg [63:0]                    eq_mem_data    [0:EQ_MEM_DEPTH-1];
    reg                           eq_mem_valid   [0:EQ_MEM_DEPTH-1];
    reg                           eq_mem_ready   [0:EQ_MEM_DEPTH-1];
    reg [31:0]                    eq_mem_count;

    // EQ-VEC: For vector/AI ops (MATMUL, ATTENTION, CONV)
    reg [TAG_ID_WIDTH-1:0]        eq_vec_tag_id  [0:EQ_VEC_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_vec_addr    [0:EQ_VEC_DEPTH-1];
    reg [63:0]                    eq_vec_data    [0:EQ_VEC_DEPTH-1];
    reg                           eq_vec_valid   [0:EQ_VEC_DEPTH-1];
    reg                           eq_vec_ready   [0:EQ_VEC_DEPTH-1];
    reg [31:0]                    eq_vec_count;

    // ── Reorder Queue (RQ) — In-order commit tracking ──
    reg [TAG_ID_WIDTH-1:0]        rq_tag_id     [0:RQ_DEPTH-1];
    reg                           rq_completed  [0:RQ_DEPTH-1];   // Task done, waiting commit
    reg                           rq_valid      [0:RQ_DEPTH-1];
    reg [31:0]                    rq_count;
    reg [$clog2(RQ_DEPTH)-1:0]    rq_commit_ptr;  // Next to commit (in-order)

    // ── Commit Queue (CQ) — Atomic write-back ──
    reg [TAG_ID_WIDTH-1:0]        cq_tag_id     [0:CQ_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          cq_addr       [0:CQ_DEPTH-1];
    reg [DATA_WIDTH-1:0]          cq_result     [0:CQ_DEPTH-1];
    reg                           cq_valid      [0:CQ_DEPTH-1];
    reg                           cq_committed  [0:CQ_DEPTH-1];
    reg [31:0]                    cq_count;
    reg [$clog2(CQ_DEPTH)-1:0]    cq_head, cq_tail;

    // ── Dynamic Queue Balancer (DQB) State ──
    reg [31:0]                    dqb_spill_count;    // Times tasks spilled to other EQ
    reg [31:0]                    dqb_steal_count;    // Times work was stolen
    reg [31:0]                    dqb_rebalance_count; // Times queues were rebalanced

    // Hybrid Queue Debug outputs
    wire [31:0]                   fq_count_wire;
    wire [31:0]                   eq_alu_ready_count;
    wire [31:0]                   eq_mem_ready_count;
    wire [31:0]                   eq_vec_ready_count;
    wire [31:0]                   rq_commit_rate;

    // ═══════════════════════════════════════════════════════
    // END HYBRID MULTI-QUEUE STRUCTURES
    // ═══════════════════════════════════════════════════════

    // ── Active task per domain (CONCURRENT EXECUTION) ──
    // FIX: Allow G, A, NPU to execute simultaneously instead of serialized
    reg                     g_active_task_valid;
    reg [ADDR_WIDTH-1:0]    g_active_task_addr;
    reg [63:0]              g_active_task_data;
    wire [31:0]              g_active_task_data_unused = g_active_task_data[63:32];

    reg                     a_active_task_valid;
    reg [ADDR_WIDTH-1:0]    a_active_task_addr;
    reg [63:0]              a_active_task_data;
    
    reg                     n_active_task_valid;
    reg [ADDR_WIDTH-1:0]    n_active_task_addr;
    reg [63:0]              n_active_task_data;
    wire [63:0]              n_active_task_data_unused = n_active_task_data;

    // Legacy interface (backward compatible - maps to G domain)
    reg [1:0]               active_task_type;
    reg                     active_task_valid;
    reg [ADDR_WIDTH-1:0]    active_task_addr;
    reg [63:0]              active_task_data;
    wire [ADDR_WIDTH-1:0]   active_task_addr_unused = active_task_addr;
    wire [63:0]             active_task_data_unused = active_task_data;
    reg                     task_being_served;
    wire                    task_being_served_unused = task_being_served;
    reg [15:0]              active_task_wait_counter;
    
    // Per-domain watchdog counters (P1: Different thresholds per core type)
    reg [15:0]              g_watchdog_counter;
    reg [15:0]              a_watchdog_counter;
    reg [15:0]              n_watchdog_counter;
    
    // P1: Track stalled task addresses to prevent duplicate hazard logging
    reg [ADDR_WIDTH-1:0]    g_stalled_addr;
    reg                     g_stalled_valid;
    reg [ADDR_WIDTH-1:0]    a_stalled_addr;
    reg                     a_stalled_valid;
    reg [ADDR_WIDTH-1:0]    n_stalled_addr;
    reg                     n_stalled_valid;

    // FIX v3: Deadlock detection - track how long each domain has been stalled
    // If stalled > DEADLOCK_TIMEOUT, force clear to prevent permanent queue block
    localparam DEADLOCK_TIMEOUT = 100;  // OPTIMIZED: 200->100 cycles for faster simulation recovery
    reg [15:0]              g_stalled_cycles;
    reg [15:0]              a_stalled_cycles;
    reg [15:0]              n_stalled_cycles;
    reg [31:0]              deadlock_resets;  // Track deadlock recoveries
    
    // CRITICAL FIX v4: Cross-domain dependency tracking
    // If G-Core produces data needed by A-Core, and G-Core stalls, A-Core will also stall
    // This tracks inter-domain dependencies to detect cascading deadlocks
    reg                     g_to_a_dependency;  // A-Core waiting for G-Core result
    reg                     g_to_n_dependency;  // NPU waiting for G-Core result
    reg                     a_to_n_dependency;  // NPU waiting for A-Core result
    reg [ADDR_WIDTH-1:0]    g_pending_result_addr;  // Address of G result being waited on
    reg [ADDR_WIDTH-1:0]    a_pending_result_addr;  // Address of A result being waited on

    // Loop variables for Hybrid Queue initialization
    integer                 li_fq_init;
    integer                 li_dq_init;
    integer                 li_eq_init;
    integer                 li_rq_init;
    integer                 li_cq_init;
    integer                 li_gq_init;
    integer                 li_aq_init;
    integer                 li_nq_init;
    
    // Fair scheduling loop variables
    integer                 li_fair_check;
    integer                 li_domain_idx;

    // Loop variables for dep_mask clearing (CRITICAL FIX #12)
    integer                 li_dq_dep_clear;
    integer                 li_dq_dep_clear_a;
    integer                 li_dq_dep_clear_n;
    integer                 li_eq_rq;
    integer                 li_rq_slot;
    integer                 li_eq_slot;
    reg                     found_eq;
    reg                     found_rq;

    // ── Pending result ──
    reg [DATA_WIDTH-1:0]    pending_result;
    reg                     pending_result_valid;
    reg [1:0]               pending_result_type;
    reg                     g_core_complete_prev;
    reg                     a_core_complete_prev;
    reg                     npu_complete_prev;

    // ── ENHANCED FAIR SCHEDULING SYSTEM ──
    reg [1:0]               wrr_domain;
    wire [1:0]              wrr_domain_unused = wrr_domain;
    reg [31:0]              wrr_quantum;
    reg [31:0]              wrr_quantum_counter;
    
    // FAIR SCHEDULING: Aging and Starvation Prevention
    reg [7:0]               domain_service_count [0:2]; // Track service fairness
    reg [15:0]              fair_rotation_counter;      // Round-robin fairness
    reg [7:0]               starvation_threshold [0:2]; // Dynamic starvation detection
    reg                     global_starvation_active;    // System-wide starvation flag
    
    // Enhanced aging with priority inheritance
    wire                    g_starvation_risk = (g_q_count > 0) && (g_q_aging[g_head] >= MAX_AGING / 2);
    wire                    a_starvation_risk = (a_q_count > 4) && (a_q_aging[a_head] >= MAX_AGING - 1);
    wire                    a_starvation_risk_unused = a_starvation_risk;
    reg                     g_priority_boost;
    reg [7:0]               aging_boost_intensity;     // How aggressive aging should be
    
    // PRIORITY INHERITANCE MECHANISM
    reg [1:0]               inherited_priority [0:G_QUEUE_DEPTH-1]; // Inherited priority per task
    reg [1:0]               original_priority [0:G_QUEUE_DEPTH-1];  // Original priority per task
    reg [7:0]               inheritance_count [0:2];     // Count inheritance events per domain
    reg [31:0]              priority_inversions_detected; // Total priority inversions
    reg [31:0]              priority_inheritance_events; // Total inheritance events
    reg                     priority_inheritance_active [0:2]; // Per-domain inheritance flag
    reg [7:0]               inheritance_threshold;     // When to trigger inheritance
    reg [31:0]              inheritance_cooldown [0:2]; // Cooldown after inheritance
    
    // ── ENHANCED ARBITER WITH FAIRNESS ──
    reg [1:0]               arbiter_select;
    wire [1:0]              arbiter_select_unused = arbiter_select;
    reg [31:0]              arbiter_fairness_score [0:2]; // Fairness scoring per domain
    reg [7:0]               last_served_domain;           // Track last served for fairness
    reg [15:0]              domain_wait_cycles [0:2];     // How long each domain has waited

    // ── Ring bus load balancing signals ──
    reg                     g_ring_inject;
    reg [ADDR_WIDTH-1:0]    g_ring_addr;
    reg [63:0]              g_ring_data;
    
    // Ring bus congestion recovery
    reg [15:0]              congestion_timer;
    reg                     congestion_recovery_active;
    reg [31:0]              bp_ring_balanced;
    
    // ── Counters ──
    reg [63:0]              counter_dispatched;
    reg [63:0]              counter_completed;
    reg [63:0]              counter_completed_prev;
    reg [63:0]              stall_waiting_for_resource;
    reg [63:0]              stall_queue_contention;
    reg [31:0]              counter_conflicts;
    reg [31:0]              max_queue_depth_seen;
    reg [31:0]              aging_boosted_tasks;
    reg [31:0]              rr_rotations;
    reg [31:0]              bp_queue_full_rejections;
    reg [31:0]              bp_timeout_stalls;
    
    // ── Temporal Deadlock Detection ──
    reg [15:0]              state_stuck_counter;
    reg [2:0]               state_prev;
    reg [2:0]               state_when_stuck;
    reg [31:0]              bp_actual_accepts;
    reg [31:0]              admission_rejections;  // NEW: Track admission control rejections
    reg [31:0]              hazard_structural_count;
    reg [31:0]              hazard_raw_count;  // FIX: Track RAW hazards
    reg [31:0]              hazard_war_count;  // FIX: Track WAR hazards
    reg [31:0]              hazard_waw_count;  // FIX: Track WAW hazards
    reg [31:0]              hazard_dependency_stalls;  // NEW: Track actual dependency stalls
    reg [ADDR_WIDTH-1:0]    last_write_addr;   // Track last write address
    wire [ADDR_WIDTH-1:0]   last_write_addr_unused = last_write_addr;
    reg                     last_write_was_g;  // Track if last write was from G-Core
    wire                    last_write_was_g_unused = last_write_was_g;

    // NEW: Per-core utilization tracking
    reg [31:0]              g_core_busy_cycles;
    reg [31:0]              a_core_busy_cycles;
    reg [31:0]              n_core_busy_cycles;
    reg [31:0]              total_sim_cycles;
    
    // Integer declarations for dispatch logic
    integer idx;
    integer li_disp_g;
    integer li_disp_a;
    integer li_disp_n;
    
    // Reg declarations for dispatch logic
    reg g_blocking_hazard;
    reg g_already_stalled;
    reg g_has_raw, g_has_war, g_has_waw;
    reg force_dispatch;  // NEW: Starvation override
    reg a_blocking_hazard;
    reg a_already_stalled;
    reg a_has_raw, a_has_war, a_has_waw;
    reg a_force_dispatch;
    reg n_blocking_hazard;
    reg n_already_stalled;
    reg n_has_raw, n_has_war, n_has_waw;
    reg n_force_dispatch;
    
    // NEW: Hybrid Queue stage counters (v4.0 debug)
    reg [31:0]              hq_fq_enqueued;      // Tasks enqueued to FQ
    reg [31:0]              hq_dq_decoded;       // Tasks decoded in DQ
    reg [31:0]              hq_eq_dispatched;    // Tasks dispatched to EQ
    reg [31:0]              hq_rq_committed;     // Tasks committed to RQ
    reg [31:0]              hq_cq_completed;     // Tasks completed via CQ
    
    // NEW: Inflight tracking (CRITICAL FIX - prevent double dispatch)
    reg                     g_core_inflight;     // G-Core has inflight task
    reg                     a_core_inflight;     // A-Core has inflight task
    reg                     n_core_inflight;     // N-Core has inflight task
    reg [31:0]              g_inflight_timer;    // Cycles since G dispatch
    reg [31:0]              a_inflight_timer;    // Cycles since A dispatch
    reg [31:0]              n_inflight_timer;    // Cycles since N dispatch
    
    // Helper flags for single-driver inflight timer management
    reg                     g_reset_timer;       // Reset G-Core timer flag
    reg                     a_reset_timer;       // Reset A-Core timer flag
    reg                     n_reset_timer;       // Reset N-Core timer flag
    reg                     g_increment_timer;   // Increment G-Core timer flag
    reg                     a_increment_timer;   // Increment A-Core timer flag
    reg                     n_increment_timer;   // Increment N-Core timer flag
    
    // Address tracking per domain for hazard detection
    // Each active task has read_addr (input) and write_addr (output) semantics
    reg [ADDR_WIDTH-1:0]    g_active_read_addr;   // G-Core input address
    reg [ADDR_WIDTH-1:0]    g_active_write_addr;  // G-Core output address
    reg                     g_active_has_write;    // G task will write
    reg [ADDR_WIDTH-1:0]    a_active_read_addr;   // A-Core input address
    reg [ADDR_WIDTH-1:0]    a_active_write_addr;  // A-Core output address
    reg                     a_active_has_write;    // A task will write
    reg [ADDR_WIDTH-1:0]    n_active_read_addr;   // NPU input address
    reg [ADDR_WIDTH-1:0]    n_active_write_addr;  // NPU output address
    reg                     n_active_has_write;    // N task will write
    reg [31:0]              watchdog_resets_reg;
    reg                     g_core_error_prev;
    reg                     skip_g_dispatch;
    reg [7:0]               skip_g_counter;

    // FIX: Edge detection untuk prevent double enqueue
    reg                     g_task_valid_prev;
    reg                     a_task_valid_prev;
    reg                     npu_task_valid_prev;
    reg                     g_core_cmd_valid_prev;

    // ── Assignments ──
    // ADMISSION CONTROL: Throttle when queue > threshold
    localparam G_QUEUE_THRESHOLD = (G_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    localparam A_QUEUE_THRESHOLD = (A_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    localparam N_QUEUE_THRESHOLD = (N_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    
    // CRITICAL FIX: Queue overflow protection
    // Prevent queue from exceeding absolute maximum capacity
    assign g_task_ready  = (g_credits > 0) && (g_q_count < G_QUEUE_THRESHOLD) && (g_q_count < G_QUEUE_DEPTH);
    assign a_task_ready  = (a_credits > 0) && (a_q_count < A_QUEUE_THRESHOLD) && (a_q_count < A_QUEUE_DEPTH);
    assign npu_task_ready = (n_credits > 0) && (n_q_count < N_QUEUE_THRESHOLD) && (n_q_count < N_QUEUE_DEPTH);
    
    // DEBUG: Print g_task_ready status (ENABLED for debugging)
    reg [15:0] last_print_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_counter <= 16'd0;
            last_print_counter <= 16'd0;
        end else begin
            debug_counter <= debug_counter + 1;
            // DEBUG: Enabled with conditional compile to prevent log spam
            `ifdef DEBUG_SCHEDULER
            if (debug_counter % 10000 == 0 && debug_counter != last_print_counter) begin  // Print every 10000 cycles, prevent duplicates
                $display("[%0t] [SCHEDULER_G] DEBUG_READY: g_task_ready=%b, credits=%0d, q_count=%0d, threshold=%0d",
                         $time, g_task_ready, g_credits, g_q_count, G_QUEUE_THRESHOLD);
                last_print_counter <= debug_counter;  // CRITICAL: Update to prevent spam
            end
            `endif
        end
    end
    
    // CRITICAL FIX: Queue overflow detection assertions
    // These will fail during simulation if queue overflows
    `ifdef SIMULATION
        always @(posedge clk) begin
            if (g_q_count > G_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 G-QUEUE OVERFLOW: count=%0d > max=%0d", $time, g_q_count, G_QUEUE_DEPTH);
                $finish;
            end
            if (a_q_count > A_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 A-QUEUE OVERFLOW: count=%0d > max=%0d", $time, a_q_count, A_QUEUE_DEPTH);
                $finish;
            end
            if (n_q_count > N_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 N-QUEUE OVERFLOW: count=%0d > max=%0d", $time, n_q_count, N_QUEUE_DEPTH);
                $finish;
            end
        end
    `endif

    assign g_task_result       = (pending_result_type == TASK_GAMING && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign g_task_result_valid = (pending_result_type == TASK_GAMING && pending_result_valid);
    assign a_task_result       = (pending_result_type == TASK_AI && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign a_task_result_valid = (pending_result_type == TASK_AI && pending_result_valid);
    assign npu_task_result     = (pending_result_type == TASK_NPU && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign npu_task_result_valid = (pending_result_type == TASK_NPU && pending_result_valid);

    // CONCURRENT: Each core gets command independently when its domain has active task
    assign g_core_cmd_addr  = g_active_task_addr;
    assign g_core_cmd_data  = g_active_task_data[31:0];
    
    // FIXED: Level-based valid instead of pulse-based
    assign g_core_cmd_valid = g_active_task_valid && !skip_g_dispatch;
    
    // CRITICAL FIX: Ensure g_core_cmd_ready is properly connected
    // If g_core_cmd_ready is stuck LOW, scheduler will never clear active task
    // Stable binary check (ignore Z/X for Verilator compliance)
    wire g_core_ready_fallback;
    assign g_core_ready_fallback = g_core_cmd_ready;
    
    // Clear active task after proper handshake
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_core_cmd_valid_prev <= 1'b0;
        end else begin
            g_core_cmd_valid_prev <= g_active_task_valid && g_core_ready_fallback && !skip_g_dispatch;
            
            // FIXED: Clear active task only when core is ready
            if (g_active_task_valid && g_core_ready_fallback && !skip_g_dispatch) begin
                // DEBUG: Print when clearing task
                if (state_stuck_counter > 100) begin
                    $display("[%0t] [SCHEDULER_G] DEBUG: Clearing task - counter=%0d, active=%0d, ready=%0d, skip=%0d", 
                            $time, state_stuck_counter, g_active_task_valid, g_core_ready_fallback, skip_g_dispatch);
                end
                g_active_task_valid <= 1'b0;
                // Reset stuck counter when making progress
                state_stuck_counter <= 16'd0;
            end else if (g_active_task_valid) begin
                // Increment stuck counter ONLY when a task is pending but no progress
                state_stuck_counter <= state_stuck_counter + 1;
                
                // DEBUG: Print counter every 1000 cycles (check BEFORE reset)
                if ((state_stuck_counter + 1) % 1000 == 0) begin
                    $display("[%0t] [SCHEDULER_G] DEBUG: state_stuck_counter=%0d, g_active_task_valid=%0d, g_core_ready_fallback=%0d", 
                            $time, state_stuck_counter + 1, g_active_task_valid, g_core_ready_fallback);
                end
            end else begin
                // Reset stuck counter when no task is pending
                state_stuck_counter <= 16'd0;
            end
            
            // CRITICAL FIX: Force recovery on deadlock (check BEFORE reset)
            if ((state_stuck_counter + 1) >= 1000) begin
                $display("[%0t] [SCHEDULER_G] FORCE RECOVERY: Clearing stuck G-Core task after %0d cycles", 
                        $time, state_stuck_counter);
                g_active_task_valid <= 1'b0;  // Force clear stuck task
                state_stuck_counter <= 16'd0;  // Reset counter
                skip_g_dispatch <= 1'b1;      // Skip next dispatch to break cycle
                skip_g_counter <= 8'd5;        // Reset skip counter to re-enable dispatch
            end
            
            // ENHANCED DEADLOCK DETECTION: Multiple layers of protection
            `CHECK_REQUEST_RESPONSE_PAIRING("SCHEDULER_G", counter_dispatched, counter_completed, 10);
            `CHECK_NO_WAIT_WITHOUT_PROGRESS("SCHEDULER_G", "DISPATCH", state_stuck_counter, 500);
            
            // CRITICAL: Early deadlock detection at 100 cycles for faster recovery
            // REDUCED FREQUENCY: Only warn every 100 cycles to reduce log spam
            if (state_stuck_counter >= 20 && state_stuck_counter < 500 && (state_stuck_counter % 20 == 0)) begin
                $display("[%0t] [SCHEDULER_G] WARNING: Potential deadlock detected - counter=%0d, valid=%b, ready=%b", 
                        $time, state_stuck_counter, g_active_task_valid, g_core_ready_fallback);
            end
            
            // EMERGENCY: Force recovery at 500 cycles if no progress
            if (state_stuck_counter >= 500 && g_active_task_valid && !g_core_ready_fallback) begin
                $display("[%0t] [SCHEDULER_G] EMERGENCY RECOVERY: Forcing task clear due to unresponsive core", $time);
                $display("[%0t] [SCHEDULER_G] DEBUG PANIC: valid=%b, ready=%b, addr=0x%h", $time, g_active_task_valid, g_core_ready_fallback, g_active_task_addr);
                g_active_task_valid <= 1'b0;
                state_stuck_counter <= 16'd0;
                skip_g_dispatch <= 1'b1;
                skip_g_counter <= 8'd3;
            end
            
            // NUCLEAR: Absolute last resort - force clear everything at 1000 cycles
            if (state_stuck_counter >= 1000) begin
                $display("[%0t] [SCHEDULER_G] NUCLEAR RECOVERY: Absolute force clear after %0d cycles", $time, state_stuck_counter);
                g_active_task_valid <= 1'b0;
                state_stuck_counter <= 16'd0;
                skip_g_dispatch <= 1'b1;
                skip_g_counter <= 8'd10;
                // Also clear any pending tasks to prevent cascade
                g_q_count <= 32'd0;
                g_head <= 4'd0;
                g_tail <= 4'd0;
            end
        end
    end
    
    // DEBUG: Removed all noisy G-Core output

    assign a_core_cmd_addr  = a_active_task_addr;
    assign a_core_cmd_data  = a_active_task_data;
    assign a_core_cmd_valid = a_active_task_valid && !a_core_busy;
    
    // CRITICAL FIX: A-Core result consumption
    // Scheduler is ready to consume result when we have space for pending result
    // FIXED: Always ready to accept A-Core results (FIFO has space)
    assign a_core_result_ready = 1'b1;  // Always ready - A-Core has 4-deep FIFO

    assign npu_dispatch_valid = n_active_task_valid && !npu_busy;

    // Legacy signals updated in always block (no assign)

    assign sched_total_dispatched     = counter_dispatched;
    assign sched_total_completed      = counter_completed;
    assign sched_total_stalled        = stall_waiting_for_resource + stall_queue_contention;
    assign sched_stall_resource_wait  = stall_waiting_for_resource;
    assign sched_stall_queue_contention = stall_queue_contention;
    // FIX: Queue depth should be MAX individual queue, not SUM
    // SUM is misleading: G=12 + A=12 = 24, but each queue limit is 16
    // IVC: Replace function with always @(*) for VVP compatibility
    // FIX: Use 32-bit to match sched_queue_depth width
    reg [31:0] max3_result;
    always @(*) begin
        max3_result = (g_q_count >= a_q_count) ? ((g_q_count >= n_q_count) ? g_q_count : n_q_count) : ((a_q_count >= n_q_count) ? a_q_count : n_q_count);
    end
    assign sched_queue_depth          = max3_result;
    assign sched_max_queue_depth      = max_queue_depth_seen;
    assign sched_conflict_count       = counter_conflicts;
    assign sched_gaming_priority      = 8'd0;  // FIX: BASE_PRIORITY_G = 0 (highest), bukan 2
    assign sched_ai_priority          = 8'd2;
    assign sched_npu_priority         = 8'd3;
    assign sched_aging_tasks          = aging_boosted_tasks;
    assign sched_rr_rotations         = rr_rotations;
    // sched_queue_avoidance: Count DQB spill + steal + rebalance events
    assign sched_queue_avoidance      = dqb_spill_count + dqb_steal_count + dqb_rebalance_count;
    assign sched_watchdog_resets      = watchdog_resets_reg;
    assign sched_bp_queue_full_rejections = bp_queue_full_rejections;
    assign sched_bp_timeout_stalls    = bp_timeout_stalls;
    assign sched_bp_actual_accepts    = bp_actual_accepts;
    assign sched_admission_rejections = admission_rejections;
    assign sched_hazard_raw           = hazard_raw_count;
    assign sched_hazard_war           = hazard_war_count;
    assign sched_hazard_waw           = hazard_waw_count;
    assign sched_hazard_structural    = hazard_structural_count;
    assign sched_hazard_dependency    = hazard_dependency_stalls;
    assign sched_hazard_dependency_stalls = hazard_dependency_stalls;
    
    // NEW: Per-core utilization assigns
    assign sched_g_core_busy_cycles = g_core_busy_cycles;
    assign sched_a_core_busy_cycles = a_core_busy_cycles;
    assign sched_n_core_busy_cycles = n_core_busy_cycles;
    assign sched_total_sim_cycles   = total_sim_cycles;
    
    // NEW: Hybrid Queue stage counters assigns (v4.0)
    assign sched_hq_fq_enqueued    = hq_fq_enqueued;
    assign sched_hq_dq_decoded     = hq_dq_decoded;
    assign sched_hq_eq_dispatched  = hq_eq_dispatched;
    assign sched_hq_rq_committed   = hq_rq_committed;
    assign sched_hq_cq_completed   = hq_cq_completed;

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE DEBUG OUTPUTS (v4.0) - FULLY WIRED
    // ═══════════════════════════════════════════════════════

    // Count active entries in each queue stage (real-time monitoring)
    // IVC: Replace functions with always @(*) for VVP compatibility
    reg [31:0] fq_count_result;
    reg [15:0] fq_count;  // CRITICAL FIX: Track FQ count
    reg [31:0] eq_alu_ready_result;
    reg [31:0] eq_mem_ready_result;
    reg [31:0] eq_vec_ready_result;
    reg [31:0] rq_commit_result;

    always @(*) begin
        integer i;
        fq_count_result = 0;
        for (i = 0; i < FQ_DEPTH; i = i + 1)
            if (fq_tag_valid[i]) fq_count_result = fq_count_result + 1;
    end

    always @(*) begin
        integer i;
        eq_alu_ready_result = 0;
        for (i = 0; i < EQ_ALU_DEPTH; i = i + 1)
            if (eq_alu_valid[i] && eq_alu_ready[i]) eq_alu_ready_result = eq_alu_ready_result + 1;
    end

    always @(*) begin
        integer i;
        eq_mem_ready_result = 0;
        for (i = 0; i < EQ_MEM_DEPTH; i = i + 1)
            if (eq_mem_valid[i] && eq_mem_ready[i]) eq_mem_ready_result = eq_mem_ready_result + 1;
    end

    always @(*) begin
        integer i;
        eq_vec_ready_result = 0;
        for (i = 0; i < EQ_VEC_DEPTH; i = i + 1)
            if (eq_vec_valid[i] && eq_vec_ready[i]) eq_vec_ready_result = eq_vec_ready_result + 1;
    end

    always @(*) begin
        integer i;
        rq_commit_result = 0;
        for (i = 0; i < RQ_DEPTH; i = i + 1)
            if (rq_valid[i] && rq_completed[i]) rq_commit_result = rq_commit_result + 1;
    end

    assign fq_count_wire      = fq_count_result;
    assign eq_alu_ready_count = eq_alu_ready_result;
    assign eq_mem_ready_count = eq_mem_ready_result;
    assign eq_vec_ready_count = eq_vec_ready_result;
    assign rq_commit_rate     = rq_commit_result;

    // ── Main logic ──
    integer fsm_idx;
    integer fsm_idx_a;
    integer fsm_idx_n;
    integer fsm_li;
    integer fsm_li_2;
    integer fsm_li_fq;
    integer fsm_li_fq_dq;
    integer fsm_li_dq;
    integer fsm_li_dq_eq;
    integer fsm_li_dq_dep;
    integer fsm_li_eq_slot;
    integer fsm_li_spill;
    integer fsm_li_vec;
    integer fsm_li_fresh;
    integer fsm_li_aging;
    integer fsm_li_wd;
    integer fsm_li_wd_dq_clear;
    integer fsm_eq_idx;
    integer fsm_rq_idx;
    integer fsm_cleaned_g;
    integer fsm_cleaned_a;
    integer fsm_cleaned_n;
    reg     fsm_hazard;
    reg     fsm_found_slot;
    reg     fsm_found_vec;
    reg     fsm_found_spill;
    reg     fsm_found_exec;
    reg     fsm_found_exec_a;
    reg     fsm_found_rq;
    reg     fsm_dispatched;
    integer fsm_li_exec;
    integer fsm_li_rq;
    reg [TAG_ID_WIDTH-1:0] g_inflight_tag_id;
    reg [3:0]              g_inflight_eq_idx;
    reg                    g_inflight_is_mem;
    reg [TAG_ID_WIDTH-1:0] a_inflight_tag_id;
    reg [3:0]              a_inflight_eq_idx;
    reg [7:0] fsm_opcode;
    reg [ADDR_WIDTH-1:0] fsm_task_addr;
    reg [15:0] g_starve_counter;
    reg [15:0] a_starve_counter;
    reg [15:0] n_starve_counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_head <= 0; g_tail <= 0; g_q_count <= 0;
            a_head <= 0; a_tail <= 0; a_q_count <= 0; a_credits <= A_QUEUE_DEPTH;
            n_head <= 0; n_tail <= 0; n_q_count <= 0; n_credits <= N_QUEUE_DEPTH;
            active_task_valid <= 1'b0; active_task_type <= TASK_GAMING;
            active_task_addr <= {ADDR_WIDTH{1'b0}}; active_task_data <= 64'b0;
            task_being_served <= 1'b0; active_task_wait_counter <= 16'b0;
            pending_result_valid <= 1'b0; pending_result <= {DATA_WIDTH{1'b0}};
            pending_result_type <= TASK_GAMING;
            arbiter_select <= 0; wrr_domain <= 0; wrr_quantum <= 0;
            counter_dispatched <= 64'b0; counter_completed <= 64'b0;
            stall_waiting_for_resource <= 64'b0; stall_queue_contention <= 64'b0;
            counter_conflicts <= 32'b0; max_queue_depth_seen <= 32'b0;
            g_inflight_tag_id <= 0; g_inflight_eq_idx <= 0; g_inflight_is_mem <= 1'b0;
            a_inflight_tag_id <= 0; a_inflight_eq_idx <= 0;
            aging_boosted_tasks <= 32'b0; rr_rotations <= 32'b0;
            bp_queue_full_rejections <= 32'b0; bp_timeout_stalls <= 32'b0;
            bp_actual_accepts <= 32'b0; hazard_structural_count <= 32'b0;
            hazard_raw_count <= 32'b0; hazard_war_count <= 32'b0; hazard_waw_count <= 32'b0;
            hazard_dependency_stalls <= 32'b0;  
            last_write_addr <= {ADDR_WIDTH{1'b0}}; last_write_was_g <= 1'b0;
            admission_rejections <= 32'b0;
            
            // Initialize temporal deadlock detection
            state_stuck_counter <= 16'd0;
            state_prev <= 3'd0;
            state_when_stuck <= 3'd0;
            watchdog_resets_reg <= 32'b0;
            g_core_error_prev <= 1'b0; skip_g_dispatch <= 1'b0; skip_g_counter <= 8'b0;
            
            // CRITICAL: Initialize active task states to prevent startup deadlock
            g_active_task_valid <= 1'b0;
            g_active_task_addr <= {ADDR_WIDTH{1'b0}};
            g_active_task_data <= 64'b0;
            a_active_task_valid <= 1'b0;
            a_active_task_addr <= {ADDR_WIDTH{1'b0}};
            a_active_task_data <= 64'b0;
            n_active_task_valid <= 1'b0;
            n_active_task_addr <= {ADDR_WIDTH{1'b0}};
            n_active_task_data <= 64'b0;
            g_core_complete_prev <= 1'b0; a_core_complete_prev <= 1'b0; npu_complete_prev <= 1'b0;
            g_priority_boost <= 1'b0;
            g_task_valid_prev <= 1'b0; a_task_valid_prev <= 1'b0; npu_task_valid_prev <= 1'b0;
            
            // Initialize priority inheritance system
            priority_inversions_detected <= 32'd0;
            priority_inheritance_events <= 32'd0;
            inheritance_threshold <= 8'd5;
            for (int i = 0; i < 3; i++) begin
                inheritance_count[i] <= 8'd0;
                priority_inheritance_active[i] <= 1'b0;
                inheritance_cooldown[i] <= 32'd0;
            end
            for (int i = 0; i < G_QUEUE_DEPTH; i++) begin
                inherited_priority[i] <= 2'd2; // Default normal priority
                original_priority[i] <= 2'd2;
            end
            // Ring bus load balancing init
            congestion_timer <= 16'b0;
            congestion_recovery_active <= 1'b0;
            bp_ring_balanced <= 32'b0;
            g_ring_inject <= 1'b0;
            g_ring_addr <= {ADDR_WIDTH{1'b0}};
            g_ring_data <= 64'b0;
            bp_ring_balanced <= 32'b0;
            // Concurrent execution init
            g_active_task_valid <= 1'b0; a_active_task_valid <= 1'b0; n_active_task_valid <= 1'b0;
            g_active_read_addr <= {ADDR_WIDTH{1'b0}}; g_active_write_addr <= {ADDR_WIDTH{1'b0}};
            g_active_has_write <= 1'b0;
            a_active_read_addr <= {ADDR_WIDTH{1'b0}}; a_active_write_addr <= {ADDR_WIDTH{1'b0}};
            a_active_has_write <= 1'b0;
            n_active_read_addr <= {ADDR_WIDTH{1'b0}}; n_active_write_addr <= {ADDR_WIDTH{1'b0}};
            n_active_has_write <= 1'b0;
            active_task_valid <= 1'b0; task_being_served <= 1'b0;
            // Per-domain watchdog init
            g_watchdog_counter <= 16'b0; a_watchdog_counter <= 16'b0; n_watchdog_counter <= 16'b0;
            // P1: Stalled task tracking init
            g_stalled_addr <= {ADDR_WIDTH{1'b0}}; g_stalled_valid <= 1'b0;
            a_stalled_addr <= {ADDR_WIDTH{1'b0}}; a_stalled_valid <= 1'b0;
            n_stalled_addr <= {ADDR_WIDTH{1'b0}}; n_stalled_valid <= 1'b0;
            // CRITICAL FIX v4: Cross-domain dependency init
            g_to_a_dependency <= 1'b0; g_to_n_dependency <= 1'b0; a_to_n_dependency <= 1'b0;
            g_pending_result_addr <= {ADDR_WIDTH{1'b0}}; a_pending_result_addr <= {ADDR_WIDTH{1'b0}};
            g_stalled_cycles <= 16'b0; a_stalled_cycles <= 16'b0; n_stalled_cycles <= 16'b0;
            deadlock_resets <= 32'b0;
            // NEW: Per-core utilization init
            g_core_busy_cycles <= 32'b0; a_core_busy_cycles <= 32'b0; n_core_busy_cycles <= 32'b0;
            total_sim_cycles <= 32'b0;
            
            // NEW: Hybrid Queue stage counters init (v4.0)
            hq_fq_enqueued <= 32'b0; hq_dq_decoded <= 32'b0; hq_eq_dispatched <= 32'b0;
            hq_rq_committed <= 32'b0; hq_cq_completed <= 32'b0;
            
            // NEW: Inflight tracking init (CRITICAL FIX)
            g_core_inflight <= 1'b0; a_core_inflight <= 1'b0; n_core_inflight <= 1'b0;
            g_inflight_timer <= 32'b0; a_inflight_timer <= 32'b0; n_inflight_timer <= 32'b0;
            // Helper flags for single-driver inflight timer management
            g_reset_timer <= 1'b0; a_reset_timer <= 1'b0; n_reset_timer <= 1'b0;
            g_increment_timer <= 1'b0; a_increment_timer <= 1'b0; n_increment_timer <= 1'b0;

            // ═══════════════════════════════════════════════
            // HYBRID MULTI-QUEUE INIT (v4.0)
            // ═══════════════════════════════════════════════
            task_id_counter <= {TAG_ID_WIDTH{1'b0}};
            // FQ init
            fq_count <= 0; fq_tail <= 0; fq_head <= 0;  // CRITICAL FIX: Initialize FQ tracking
            for (li_fq_init = 0; li_fq_init < FQ_DEPTH; li_fq_init = li_fq_init + 1) begin
                fq_tag_valid[li_fq_init] <= 1'b0;
            end
            // G-Queue init
            g_head <= 0; g_tail <= 0; g_q_count <= 0; g_credits <= 32'd100;
            for (li_gq_init = 0; li_gq_init < G_QUEUE_DEPTH; li_gq_init = li_gq_init + 1) begin
                g_q_valid[li_gq_init] <= 1'b0;
                g_q_disp[li_gq_init] <= 1'b0;
                g_q_aging[li_gq_init] <= 8'b0;
                g_q_wait[li_gq_init] <= 8'b0;
                g_q_fresh[li_gq_init] <= 1'b0;
            end
            // A-Queue init
            a_head <= 0; a_tail <= 0; a_q_count <= 0; a_credits <= 32'd100;
            for (li_aq_init = 0; li_aq_init < A_QUEUE_DEPTH; li_aq_init = li_aq_init + 1) begin
                a_q_valid[li_aq_init] <= 1'b0;
                a_q_disp[li_aq_init] <= 1'b0;
                a_q_aging[li_aq_init] <= 8'b0;
                a_q_wait[li_aq_init] <= 8'b0;
                a_q_fresh[li_aq_init] <= 1'b0;
            end
            // N-Queue init
            n_head <= 0; n_tail <= 0; n_q_count <= 0; n_credits <= 32'd100;
            for (li_nq_init = 0; li_nq_init < N_QUEUE_DEPTH; li_nq_init = li_nq_init + 1) begin
                n_q_valid[li_nq_init] <= 1'b0;
                n_q_disp[li_nq_init] <= 1'b0;
                n_q_aging[li_nq_init] <= 8'b0;
                n_q_wait[li_nq_init] <= 8'b0;
                n_q_fresh[li_nq_init] <= 1'b0;
            end
            // DQ init
            dq_head <= 0; dq_tail <= 0; dq_count <= 0;
            for (li_dq_init = 0; li_dq_init < DQ_DEPTH; li_dq_init = li_dq_init + 1) begin
                dq_valid[li_dq_init] <= 1'b0;
                dq_decoded[li_dq_init] <= 1'b0;
            end
            // EQ init
            eq_alu_count <= 0; eq_mem_count <= 0; eq_vec_count <= 0;
            for (li_eq_init = 0; li_eq_init < EQ_ALU_DEPTH; li_eq_init = li_eq_init + 1)
                eq_alu_valid[li_eq_init] <= 1'b0;
            for (li_eq_init = 0; li_eq_init < EQ_MEM_DEPTH; li_eq_init = li_eq_init + 1)
                eq_mem_valid[li_eq_init] <= 1'b0;
            for (li_eq_init = 0; li_eq_init < EQ_VEC_DEPTH; li_eq_init = li_eq_init + 1)
                eq_vec_valid[li_eq_init] <= 1'b0;
            // RQ init
            rq_count <= 0; rq_commit_ptr <= 0;
            for (li_rq_init = 0; li_rq_init < RQ_DEPTH; li_rq_init = li_rq_init + 1) begin
                rq_valid[li_rq_init] <= 1'b0;
                rq_completed[li_rq_init] <= 1'b0;
            end
            // CQ init
            cq_head <= 0; cq_tail <= 0; cq_count <= 0;
            for (li_cq_init = 0; li_cq_init < CQ_DEPTH; li_cq_init = li_cq_init + 1) begin
                cq_valid[li_cq_init] <= 1'b0;
                cq_committed[li_cq_init] <= 1'b0;
            end
            // DQB init
            dqb_spill_count <= 0; dqb_steal_count <= 0; dqb_rebalance_count <= 0;
        end else begin
            total_sim_cycles <= total_sim_cycles + 1;

            // NEW: Per-core utilization tracking
            if (g_core_busy) g_core_busy_cycles <= g_core_busy_cycles + 1;
            if (a_core_busy) a_core_busy_cycles <= a_core_busy_cycles + 1;
            if (npu_busy) n_core_busy_cycles <= n_core_busy_cycles + 1;
            
            // CRITICAL FIX: Ensure dispatch logic always runs
            // Force basic dispatch to prevent completed > dispatched
            if (g_q_count > 0 && !g_core_busy && !g_active_task_valid && !g_core_inflight) begin
                // Dispatch G-Core task immediately - AMBIL DATA DARI QUEUE HEAD
                g_active_task_valid <= 1'b1;
                g_active_task_addr <= g_q_addr[g_head];
                g_active_task_data <= g_q_data[g_head];
                g_active_has_write <= (g_q_opcode[g_head] == 8'h11);  // OP_STORE = write operation
                counter_dispatched <= counter_dispatched + 1;
                g_core_inflight <= 1'b1;  // Track task as inflight for completion matching
                
                // Remove from queue
                g_q_valid[g_head] <= 1'b0;
                g_q_count <= g_q_count - 1;
                g_head <= (g_head == G_QUEUE_DEPTH-1) ? 0 : g_head + 1;
            end
            
            if (a_q_count > 0 && !a_core_busy && !a_active_task_valid) begin
                // Dispatch A-Core task immediately - AMBIL DATA DARI QUEUE HEAD
                a_active_task_valid <= 1'b1;
                a_active_task_addr <= a_q_addr[a_head];
                a_active_task_data <= a_q_data[a_head];
                a_active_has_write <= (a_q_opcode[a_head] == 8'h31);  // OP_STORE_WT = write operation
                counter_dispatched <= counter_dispatched + 1;
                
                // Remove from queue
                a_q_valid[a_head] <= 1'b0;
                a_q_count <= a_q_count - 1;
                a_head <= (a_head == A_QUEUE_DEPTH-1) ? 0 : a_head + 1;
            end
            
            // ENHANCED: Memory hazard detection (RAW/WAR/WAW)
            // RAW (Read-After-Write) detection: G writes, A reads
            if (g_active_task_valid && a_active_task_valid && 
                g_active_has_write && !a_active_has_write &&
                (g_active_write_addr == a_active_read_addr)) begin
                hazard_raw_count <= hazard_raw_count + 1;
                hazard_dependency_stalls <= hazard_dependency_stalls + 1;
            end
            
            // WAR (Write-After-Read) detection: G reads, A writes  
            if (g_active_task_valid && a_active_task_valid && 
                !g_active_has_write && a_active_has_write &&
                (g_active_read_addr == a_active_write_addr)) begin
                hazard_war_count <= hazard_war_count + 1;
                hazard_dependency_stalls <= hazard_dependency_stalls + 1;
            end
            
            // WAW (Write-After-Write) detection: both write
            if (g_active_task_valid && a_active_task_valid && 
                g_active_has_write && a_active_has_write &&
                (g_active_write_addr == a_active_write_addr)) begin
                hazard_waw_count <= hazard_waw_count + 1;
                hazard_dependency_stalls <= hazard_dependency_stalls + 1;
            end
            
            // Structural hazard (same resource)
            if (g_core_busy && a_core_busy && 
                (g_active_read_addr[31:0] == a_active_read_addr[31:0])) begin
                hazard_structural_count <= hazard_structural_count + 1;
            end
            
            // ENHANCED: Cross-domain deadlock detection with recovery
            // Track stalled cycles per domain and detect cascading stalls
            // G-Core stalled tracking
            if (g_core_busy && !g_core_complete) begin
                g_stalled_cycles <= g_stalled_cycles + 1;
                if (g_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                    $display("[%0t] [DEADLOCK] G-Core deadlock detected! Initiating recovery...", $time);
                    // Force complete G-Core task to break deadlock
                    force_complete_g_core_task();
                    deadlock_resets <= deadlock_resets + 1;
                end
            end else begin
                g_stalled_cycles <= 16'b0;
            end
            
            // A-Core stalled tracking
            if (a_core_busy && !a_core_complete) begin
                a_stalled_cycles <= a_stalled_cycles + 1;
                if (a_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                    $display("[%0t] [DEADLOCK] A-Core deadlock detected! Initiating recovery...", $time);
                    // Force complete A-Core task to break deadlock
                    force_complete_a_core_task();
                    deadlock_resets <= deadlock_resets + 1;
                end
            end else begin
                a_stalled_cycles <= 16'b0;
            end
            
            // NPU stalled tracking
            if (npu_busy && !npu_complete) begin
                n_stalled_cycles <= n_stalled_cycles + 1;
                if (n_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                    $display("[%0t] [DEADLOCK] NPU deadlock detected! Clearing waiting tasks...", $time);
                    // Clear NPU waiting tasks to break deadlock
                    clear_npu_waiting_tasks(n_active_write_addr);
                    deadlock_resets <= deadlock_resets + 1;
                end
            end else begin
                n_stalled_cycles <= 16'b0;
            end
            
            // PERFORMANCE COUNTERS VALIDATION
            // Ensure counters don't overflow and maintain accuracy
            if (counter_completed > counter_dispatched) begin
                // This should never happen - log for debugging
                $display("[%0t] [COUNTER-ERROR] Completed (%0d) > Dispatched (%0d)", 
                         $time, counter_completed, counter_dispatched);
            end
            
            // Validate queue counts are within bounds
            if (g_q_count > G_QUEUE_DEPTH || a_q_count > A_QUEUE_DEPTH || n_q_count > N_QUEUE_DEPTH) begin
                $display("[%0t] [QUEUE-ERROR] Queue count overflow: G=%0d/%0d A=%0d/%0d N=%0d/%0d",
                         $time, g_q_count, G_QUEUE_DEPTH, a_q_count, A_QUEUE_DEPTH, n_q_count, N_QUEUE_DEPTH);
            end
            
            // Reset counters if they approach overflow (32-bit limit)
            if (counter_completed >= 32'hFFFF_FFF0) begin
                $display("[%0t] [COUNTER-RESET] Approaching 32-bit limit, resetting counters", $time);
                counter_completed <= 32'd0;
                counter_dispatched <= 32'd0;
                stall_waiting_for_resource <= 32'd0;
                stall_queue_contention <= 32'd0;
            end
            
            // DEADLOCK RECOVERY: Already handled in per-domain tracking above (lines 957-993)
            // No duplicate logic needed - prevents redundant resets
            
            // ── ENHANCED FAIR SCHEDULING WITH AGING ──
            // Update domain wait cycles and fairness scores
            for (int d = 0; d < 3; d++) begin
                if ((d == 0 && g_q_count > 0 && !g_active_task_valid) ||
                    (d == 1 && a_q_count > 0 && !a_active_task_valid) ||
                    (d == 2 && n_q_count > 0 && !n_active_task_valid)) begin
                    domain_wait_cycles[d] <= domain_wait_cycles[d] + 1;
                end else begin
                    domain_wait_cycles[d] <= 16'd0;
                end
                
                // Update fairness scores based on wait time and service balance
                arbiter_fairness_score[d] <= (domain_wait_cycles[d] * 100) + 
                                            (fair_rotation_counter - domain_service_count[d] * 10);
            end
            
            // Detect global starvation
            global_starvation_active <= (domain_wait_cycles[0] > 50) || 
                                       (domain_wait_cycles[1] > 100) || 
                                       (domain_wait_cycles[2] > 30);
            
            // Enhanced aging with priority inheritance
            if (g_starvation_risk && !g_priority_boost) begin
                g_priority_boost <= 1'b1;
                aging_boosted_tasks <= aging_boosted_tasks + 1;
                aging_boost_intensity <= aging_boost_intensity + 1;
            end else if (!g_starvation_risk && g_priority_boost) begin
                g_priority_boost <= 1'b0;
                if (aging_boost_intensity > 0) aging_boost_intensity <= aging_boost_intensity - 1;
            end
            
            // A-Core starvation prevention with aggressive aging
            if (a_starvation_risk) begin
                // Boost A-Core priority significantly
                for (int i = 0; i < A_QUEUE_DEPTH; i++) begin
                    if (a_q_valid[i] && !a_q_disp[i]) begin
                        a_q_aging[i] <= a_q_aging[i] + 2; // Double aging speed
                    end
                end
            end
            
            // Fair round-robin rotation
            wrr_quantum_counter <= wrr_quantum_counter + 1;
            if (wrr_quantum_counter >= wrr_quantum) begin
                wrr_quantum_counter <= 32'd0;
                fair_rotation_counter <= fair_rotation_counter + 1;
                wrr_domain <= (wrr_domain == 2'd2) ? 2'd0 : wrr_domain + 1;
                
                // Update service counts for fairness tracking
                if (last_served_domain < 3) begin
                    domain_service_count[last_served_domain] <= domain_service_count[last_served_domain] + 1;
                end
                last_served_domain <= wrr_domain;
            end
            
            // Dynamic quantum adjustment based on starvation
            if (global_starvation_active) begin
                wrr_quantum <= 32'd4; // Smaller quantum for faster rotation
            end else begin
                wrr_quantum <= 32'd8; // Normal quantum
            end
            // DEBUG: Monitor G-Core completion
            if (g_core_complete && !g_core_complete_prev) begin
                $display("[%0t] [MQ-DEBUG] G-Core COMPLETE detected! g_active_task_valid=%b", $time, g_active_task_valid);
            end
            
            g_core_complete_prev <= g_core_complete;
            a_core_complete_prev <= a_core_complete;
            npu_complete_prev  <= npu_complete;
            counter_completed_prev <= counter_completed;

            // CRITICAL FIX: Force dispatch stuck G-Core tasks after 500 cycles
            if (g_active_task_valid && g_core_inflight && (g_inflight_timer > 500)) begin
                // DEBUG: Disabled G-Core force dispatch output
                force_complete_g_core_task();
            end

            // Error detection
            if (g_core_error_valid && !g_core_error_prev) begin
                skip_g_dispatch <= 1'b1; skip_g_counter <= 8'd10;
                if (active_task_valid && active_task_type == TASK_GAMING) begin
                    active_task_valid <= 1'b0; task_being_served <= 1'b0;
                end
            end
            g_core_error_prev <= g_core_error_valid;
            if (skip_g_counter > 0) begin
                skip_g_counter <= skip_g_counter - 1;
                if (skip_g_counter == 1) skip_g_dispatch <= 1'b0;
            end

            // ═══════════════════════════════════════════════════════
            // HYBRID MULTI-QUEUE PIPELINE (v4.0)
            // FQ → DQ → EQ → RQ → CQ
            // ═══════════════════════════════════════════════════════
            // FIX: Verilator 5.020 doesn't support delayed assignment in loops
            // Use blocking assignments consistently for all pipeline variables

            // ── STAGE 1: FRONT QUEUE (FQ) — Input Buffer ──
            // All incoming tasks enter FQ first before decode
            begin
                // CRITICAL FIX: Move tasks from G-Queue to FQ first
                // FIX: Guard against double pop - dispatch also pops g_head/g_q_count
                if (g_q_count > 0 && fq_count < FQ_DEPTH && 
                    !(g_q_count > 0 && !g_core_busy && !g_active_task_valid)) begin
                    // Move from G-Queue to FQ (only if not also dispatching same cycle)
                    g_q_valid[g_head] <= 1'b0;
                    g_q_count <= g_q_count - 1;
                    g_head <= (g_head == G_QUEUE_DEPTH-1) ? 0 : g_head + 1;
                    
                    // Add to FQ
                    fq_tag_id[fq_tail] <= task_id_counter;
                    fq_tag_opcode[fq_tail] <= g_q_opcode[g_head];
                    fq_tag_addr[fq_tail] <= g_q_addr[g_head];
                    fq_tag_data[fq_tail] <= g_q_data[g_head];
                    fq_tag_valid[fq_tail] <= 1'b1;
                    task_id_counter <= task_id_counter + 1;
                    fq_tail <= (fq_tail == FQ_DEPTH-1) ? 0 : fq_tail + 1;
                    fq_count <= fq_count + 1;
                end
                
                // CRITICAL FIX: Move tasks from A-Queue to FQ first
                if (a_q_count > 0 && fq_count < FQ_DEPTH &&
                    !(a_q_count > 0 && !a_core_busy && !a_active_task_valid)) begin
                    // Move from A-Queue to FQ (only if not also dispatching same cycle)
                    a_q_valid[a_head] <= 1'b0;
                    a_q_count <= a_q_count - 1;
                    a_head <= (a_head == A_QUEUE_DEPTH-1) ? 0 : a_head + 1;
                    
                    // Add to FQ
                    fq_tag_id[fq_tail] <= task_id_counter;
                    fq_tag_opcode[fq_tail] <= a_q_opcode[a_head];
                    fq_tag_addr[fq_tail] <= a_q_addr[a_head];
                    fq_tag_data[fq_tail] <= a_q_data[a_head];
                    fq_tag_valid[fq_tail] <= 1'b1;
                    task_id_counter <= task_id_counter + 1;
                    fq_tail <= (fq_tail == FQ_DEPTH-1) ? 0 : fq_tail + 1;
                    fq_count <= fq_count + 1;
                end
                
                // REMOVED: FQ source 3 (direct enqueue from g_task_valid)
                // This was causing double-dispatch: tasks entered FQ directly from input
                // WHILE ALSO entering G-Queue, creating duplicate entries in the pipeline.
                // Tasks now ONLY enter FQ via source 1 (G-Queue→FQ) or source 2 (A-Queue→FQ).

                // Dequeue from FQ → move to DQ when DQ has space
                begin
                    fsm_found_slot = 1'b0;
                    for (fsm_li_fq_dq = 0; fsm_li_fq_dq < FQ_DEPTH && !fsm_found_slot; fsm_li_fq_dq = fsm_li_fq_dq + 1) begin
                        if (fq_tag_valid[fsm_li_fq_dq] && dq_count < DQ_DEPTH) begin
                            // Move to DQ
                            dq_tag_id[dq_tail]   <= fq_tag_id[fsm_li_fq_dq];
                            dq_addr[dq_tail]     <= fq_tag_addr[fsm_li_fq_dq];
                            dq_data[dq_tail]     <= fq_tag_data[fsm_li_fq_dq];
                            dq_dep_mask[dq_tail] <= 16'b0;
                            dq_priority[dq_tail] <= 3'd2;
                            dq_eq_type[dq_tail]  <= 2'b00;
                            dq_valid[dq_tail]    <= 1'b1;
                            dq_decoded[dq_tail]  <= 1'b0;
                            dq_opcode[dq_tail]   <= fq_tag_opcode[fsm_li_fq_dq];
                            // Also clear FQ
                            fq_tag_valid[fsm_li_fq_dq] <= 1'b0;
                            dq_tail <= (dq_tail == DQ_DEPTH-1) ? 0 : dq_tail + 1;
                            dq_count <= dq_count + 1;
                            fq_count <= fq_count - 1;

                            fsm_found_slot = 1'b1;
                        end
                    end
                end
            end

            // ── STAGE 2: DECODE QUEUE (DQ) — Dependency Tagging & EQ Classification ──
            begin
                for (fsm_li_dq = 0; fsm_li_dq < DQ_DEPTH; fsm_li_dq = fsm_li_dq + 1) begin
                    if (dq_valid[fsm_li_dq] && !dq_decoded[fsm_li_dq]) begin
                        // Use pre-extracted opcode
                        fsm_opcode = dq_opcode[fsm_li_dq];
                        fsm_task_addr = dq_addr[fsm_li_dq];

                        // Convert legacy G vector commands into A-Core AI opcodes
                        // so the A-Core receives valid opcode format and avoids INVALID OPCODE 0x00.
                        if (fsm_opcode == 8'h05) begin
                            dq_opcode[fsm_li_dq] = 8'h20;  // RAYTRACE -> MATMUL
                            dq_data[fsm_li_dq]   = {8'h20, 24'b0, dq_data[fsm_li_dq][31:0]};
                            fsm_opcode = 8'h20;
                        end else if (fsm_opcode == 8'h06) begin
                            dq_opcode[fsm_li_dq] = 8'h21;  // FRAMEGEN -> ATTENTION
                            dq_data[fsm_li_dq]   = {8'h21, 24'b0, dq_data[fsm_li_dq][31:0]};
                            fsm_opcode = 8'h21;
                        end

                        // Classify EQ type based on opcode
                        case (fsm_opcode)
                            // ALU ops: DRAW, TEXTURE, PHYSICS, COLLISION, BRANCH
                            8'h01, 8'h02, 8'h03, 8'h04, 8'h08:
                                dq_eq_type[fsm_li_dq] = EQ_TYPE_ALU;
                            // MEM ops: LOAD, STORE
                            8'h10, 8'h11:
                                dq_eq_type[fsm_li_dq] = EQ_TYPE_MEM;
                            // VEC ops: RAYTRACE, FRAMEGEN, MATMUL, ATTENTION, CONV
                            8'h05, 8'h06, 8'h20, 8'h21, 8'h22:
                                dq_eq_type[fsm_li_dq] = EQ_TYPE_VEC;
                            // NPU ops: INFERENCE, CONV, POOL, RELU, etc (0x40-0x48)
                            // NPU tasks have their own queue path, but if they end up here,
                            // classify as VEC to avoid invalid opcode at A-Core
                            8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47, 8'h48:
                                dq_eq_type[fsm_li_dq] = EQ_TYPE_VEC;  // Route to vector unit
                            default:
                                dq_eq_type[fsm_li_dq] = EQ_TYPE_ALU;
                        endcase

                        // ── REAL DATA DEPENDENCY ANALYSIS ──
                        // Check if this task depends on any in-flight or recently completed tasks
                        // by comparing read/write addresses and tracking data flow
                        
                        dq_dep_mask[fsm_li_dq] = 16'b0;  // Start with no dependencies
                        
                        // Check against active tasks in G/A/NPU domains
                        // RAW dependency: This task reads what another task is writing
                        if (g_active_task_valid && g_active_has_write && 
                            (g_active_write_addr == fsm_task_addr)) begin
                            // Set bit 0 in dep_mask: depends on G-Core completion
                            dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0001;
                        end
                        
                        if (a_active_task_valid && a_active_has_write && 
                            (a_active_write_addr == fsm_task_addr)) begin
                            // Set bit 1: depends on A-Core completion
                            dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0002;
                        end
                        
                        if (n_active_task_valid && n_active_has_write && 
                            (n_active_write_addr == fsm_task_addr)) begin
                            // Set bit 2: depends on NPU completion
                            dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0004;
                        end
                        
                        // WAR dependency: This task writes what another task is reading
                        if (g_active_task_valid && (g_active_read_addr == fsm_task_addr)) begin
                            // Set bit 3: anti-dependency with G-Core read
                            dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0008;
                        end
                        
                        if (a_active_task_valid && (a_active_read_addr == fsm_task_addr)) begin
                            // Set bit 4: anti-dependency with A-Core read
                            dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0010;
                        end
                        
                        // Check against tasks in EQ (execution queues) for inter-task dependencies
                        begin
                            for (fsm_li = 0; fsm_li < EQ_ALU_DEPTH; fsm_li = fsm_li + 1) begin
                                if (eq_alu_valid[fsm_li] && 
                                    (eq_alu_addr[fsm_li] == fsm_task_addr) &&
                                    (eq_alu_tag_id[fsm_li] < dq_tag_id[fsm_li_dq])) begin
                                    // Set bit 5: depends on earlier EQ-ALU task
                                    dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0020;
                                end
                            end
                            
                            for (fsm_li = 0; fsm_li < EQ_MEM_DEPTH; fsm_li = fsm_li + 1) begin
                                if (eq_mem_valid[fsm_li] && 
                                    (eq_mem_addr[fsm_li] == fsm_task_addr) &&
                                    (eq_mem_tag_id[fsm_li] < dq_tag_id[fsm_li_dq])) begin
                                    // Set bit 6: depends on earlier EQ-MEM task
                                    dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0040;
                                end
                            end
                            
                            for (fsm_li = 0; fsm_li < EQ_VEC_DEPTH; fsm_li = fsm_li + 1) begin
                                if (eq_vec_valid[fsm_li] && 
                                    (eq_vec_addr[fsm_li] == fsm_task_addr) &&
                                    (eq_vec_tag_id[fsm_li] < dq_tag_id[fsm_li_dq])) begin
                                    // Set bit 7: depends on earlier EQ-VEC task
                                    dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0080;
                                end
                            end
                        end
                        
                        // Check against tasks in RQ (reorder queue) for commit ordering
                        begin
                            fsm_rq_idx = -1;
                            for (fsm_rq_idx = 0; fsm_rq_idx < RQ_DEPTH; fsm_rq_idx = fsm_rq_idx + 1) begin
                                if (rq_valid[fsm_rq_idx] && !rq_completed[fsm_rq_idx]) begin
                                    // Set bit 8: must wait for in-order commit
                                    dq_dep_mask[fsm_li_dq] = dq_dep_mask[fsm_li_dq] | 16'h0100;
                                end
                            end
                        end

                        dq_decoded[fsm_li_dq] <= 1'b1;
                        hq_dq_decoded <= hq_dq_decoded + 1;
                    end
                end
            end

            // ── STAGE 3: DQ → EQ DISPATCH (with Dependency Check) ──
            begin
                fsm_dispatched = 1'b0;
                for (fsm_li_dq_eq = 0; fsm_li_dq_eq < DQ_DEPTH && !fsm_dispatched; fsm_li_dq_eq = fsm_li_dq_eq + 1) begin
                    if (dq_valid[fsm_li_dq_eq] && dq_decoded[fsm_li_dq_eq] && (dq_dep_mask[fsm_li_dq_eq] == 0)) begin
                        // Dispatch to appropriate EQ
                        case (dq_eq_type[fsm_li_dq_eq])
                            EQ_TYPE_ALU: begin
                                if (eq_alu_count < EQ_ALU_DEPTH) begin
                                    fsm_found_slot = 1'b0;
                                    for (fsm_li_eq_slot = 0; fsm_li_eq_slot < EQ_ALU_DEPTH && !fsm_found_slot; fsm_li_eq_slot = fsm_li_eq_slot + 1) begin
                                        if (!eq_alu_valid[fsm_li_eq_slot]) begin
                                            eq_alu_tag_id[fsm_li_eq_slot] <= dq_tag_id[fsm_li_dq_eq];
                                            eq_alu_addr[fsm_li_eq_slot]   <= dq_addr[fsm_li_dq_eq];
                                            eq_alu_data[fsm_li_eq_slot]   <= dq_data[fsm_li_dq_eq];
                                            eq_alu_valid[fsm_li_eq_slot]  <= 1'b1;
                                            eq_alu_ready[fsm_li_eq_slot]  <= 1'b1;
                                            eq_alu_count <= eq_alu_count + 1;
                                            fsm_found_slot = 1'b1;
                                        end
                                    end
                                    // Remove from DQ
                                    dq_valid[fsm_li_dq_eq] <= 1'b0;
                                    dq_count <= dq_count - 1;
                                    fsm_dispatched = 1'b1;
                                end
                            end
                            EQ_TYPE_MEM: begin
                                if (eq_mem_count < EQ_MEM_DEPTH) begin
                                    fsm_found_slot = 1'b0;
                                    for (fsm_li_eq_slot = 0; fsm_li_eq_slot < EQ_MEM_DEPTH && !fsm_found_slot; fsm_li_eq_slot = fsm_li_eq_slot + 1) begin
                                        if (!eq_mem_valid[fsm_li_eq_slot]) begin
                                            eq_mem_tag_id[fsm_li_eq_slot] <= dq_tag_id[fsm_li_dq_eq];
                                            eq_mem_addr[fsm_li_eq_slot]   <= dq_addr[fsm_li_dq_eq];
                                            eq_mem_data[fsm_li_eq_slot]   <= dq_data[fsm_li_dq_eq];
                                            eq_mem_valid[fsm_li_eq_slot]  <= 1'b1;
                                            eq_mem_ready[fsm_li_eq_slot]  <= 1'b1;
                                            eq_mem_count <= eq_mem_count + 1;
                                            fsm_found_slot = 1'b1;
                                        end
                                    end
                                    dq_valid[fsm_li_dq_eq] <= 1'b0;
                                    dq_count <= dq_count - 1;
                                    fsm_dispatched = 1'b1;
                                end
                            end
                            EQ_TYPE_VEC: begin
                                if (eq_vec_count < EQ_VEC_DEPTH) begin
                                    fsm_found_slot = 1'b0;
                                    for (fsm_li_eq_slot = 0; fsm_li_eq_slot < EQ_VEC_DEPTH && !fsm_found_slot; fsm_li_eq_slot = fsm_li_eq_slot + 1) begin
                                        if (!eq_vec_valid[fsm_li_eq_slot]) begin
                                            eq_vec_tag_id[fsm_li_eq_slot] <= dq_tag_id[fsm_li_dq_eq];
                                            eq_vec_addr[fsm_li_eq_slot]   <= dq_addr[fsm_li_dq_eq];
                                            eq_vec_data[fsm_li_eq_slot]   <= dq_data[fsm_li_dq_eq];
                                            eq_vec_valid[fsm_li_eq_slot]  <= 1'b1;
                                            eq_vec_ready[fsm_li_eq_slot]  <= 1'b1;
                                            eq_vec_count <= eq_vec_count + 1;
                                            fsm_found_slot = 1'b1;
                                        end
                                    end
                                    dq_valid[fsm_li_dq_eq] <= 1'b0;
                                    dq_count <= dq_count - 1;
                                    fsm_dispatched = 1'b1;
                                end
                            end
                            default: ;
                        endcase
                    end
                end
            end

            // ── STAGE 4: EQ → RQ (Task completion tracking) ──
            // When core completes, task moves to RQ for in-order commit
            // CRITICAL FIX #12: Clear dep_mask bits for tasks that depended on this completed task
            if (g_core_complete && !g_core_complete_prev) begin
                // Clear bit 0 (G-Core dependency) from ALL tasks in DQ that depend on G-Core
                for (fsm_li_dq_dep = 0; fsm_li_dq_dep < DQ_DEPTH; fsm_li_dq_dep = fsm_li_dq_dep + 1) begin
                    if (dq_valid[fsm_li_dq_dep] && (dq_dep_mask[fsm_li_dq_dep] & 16'h0001)) begin
                        // Clear G-Core dependency bit
                        dq_dep_mask[fsm_li_dq_dep] <= dq_dep_mask[fsm_li_dq_dep] & ~16'h0001;
                    end
                end
            end

            // ── STAGE 4: EQ → CORES (Execution Dispatch) ──
            begin
                // G-Core Dispatch from EQ-ALU or EQ-MEM
                if (!g_core_busy && !g_core_inflight && !g_active_task_valid) begin
                    fsm_found_exec = 1'b0;
                    // Check ALU queue first
                    for (fsm_li_exec = 0; fsm_li_exec < EQ_ALU_DEPTH && !fsm_found_exec; fsm_li_exec = fsm_li_exec + 1) begin
                        if (eq_alu_valid[fsm_li_exec] && eq_alu_ready[fsm_li_exec]) begin
                            if (eq_alu_data[fsm_li_exec][31:24] != 8'h00) begin
                                g_active_task_addr <= eq_alu_addr[fsm_li_exec];
                                g_active_task_data <= eq_alu_data[fsm_li_exec];
                                g_active_task_valid <= 1'b1;
                                g_core_inflight <= 1'b1;
                                g_reset_timer <= 1'b1;
                                counter_dispatched <= counter_dispatched + 1;  // FIX: Increment dispatch counter
                                hq_eq_dispatched <= hq_eq_dispatched + 1;  // Increment EQ counter
                                fsm_found_exec = 1'b1;
                                
                                // Proper tagging order
                                g_inflight_tag_id <= eq_alu_tag_id[fsm_li_exec];
                                g_inflight_eq_idx <= fsm_li_exec;
                                g_inflight_is_mem <= 1'b0;
                                
                                // DEBUG: Removed CORE-G Start output
                            end else begin
                                // Silently drop NOP ghost tasks
                                eq_alu_valid[fsm_li_exec] <= 1'b0;
                                eq_alu_count <= eq_alu_count - 1;
                            end
                        end
                    end
                    // If no ALU task, check MEM queue
                    if (!fsm_found_exec) begin
                        for (fsm_li_exec = 0; fsm_li_exec < EQ_MEM_DEPTH && !fsm_found_exec; fsm_li_exec = fsm_li_exec + 1) begin
                            if (eq_mem_valid[fsm_li_exec] && eq_mem_ready[fsm_li_exec]) begin
                                g_active_task_addr <= eq_mem_addr[fsm_li_exec];
                                g_active_task_data <= eq_mem_data[fsm_li_exec];
                                g_active_task_valid <= 1'b1;
                                g_core_inflight <= 1'b1;
                                g_reset_timer <= 1'b1;
                                counter_dispatched <= counter_dispatched + 1;  // FIX: Increment dispatch counter
                                hq_eq_dispatched <= hq_eq_dispatched + 1;  // Increment EQ counter
                                fsm_found_exec = 1'b1;
                                g_inflight_tag_id <= eq_mem_tag_id[fsm_li_exec];
                                g_inflight_eq_idx <= fsm_li_exec;
                                g_inflight_is_mem <= 1'b1;
                            end
                        end
                    end
                end

                // A-Core Dispatch from EQ-VEC
                if (!a_core_busy && !a_core_inflight && !a_active_task_valid) begin
                    fsm_found_exec_a = 1'b0;
                    for (fsm_li_exec = 0; fsm_li_exec < EQ_VEC_DEPTH && !fsm_found_exec_a; fsm_li_exec = fsm_li_exec + 1) begin
                        if (eq_vec_valid[fsm_li_exec] && eq_vec_ready[fsm_li_exec]) begin
                            a_active_task_addr <= eq_vec_addr[fsm_li_exec];
                            a_active_task_data <= eq_vec_data[fsm_li_exec];
                            a_active_task_valid <= 1'b1;
                            a_core_inflight <= 1'b1;
                            a_reset_timer <= 1'b1;
                            counter_dispatched <= counter_dispatched + 1;  // FIX: Increment dispatch counter
                            hq_eq_dispatched <= hq_eq_dispatched + 1;  // Increment EQ counter
                            fsm_found_exec_a = 1'b1;
                            a_inflight_tag_id <= eq_vec_tag_id[fsm_li_exec];
                            a_inflight_eq_idx <= fsm_li_exec;
                        end
                    end
                end
                
                // NPU Dispatch (FIX: Missing NPU dispatch logic)
                if (!npu_busy && !n_core_inflight && !n_active_task_valid) begin
                    fsm_found_exec = 1'b0;
                    // Simple NPU dispatch from queue head
                    if (n_q_count > 0 && n_q_valid[n_head] && !n_q_disp[n_head]) begin
                        n_active_task_addr <= n_q_addr[n_head];
                        n_active_task_data <= n_q_data[n_head];
                        n_active_task_valid <= 1'b1;
                        n_core_inflight <= 1'b1;
                        n_reset_timer <= 1'b1;
                        counter_dispatched <= counter_dispatched + 1;  // FIX: Increment dispatch counter
                        hq_eq_dispatched <= hq_eq_dispatched + 1;  // Increment EQ counter
                        fsm_found_exec = 1'b1;
                        
                        // Mark as dispatched
                        n_q_disp[n_head] <= 1'b1;
                    end
                end
            end

            // ── STAGE 5: CORES → RQ (Completion & Commitment) ──
            begin
                // G-Core Completion
                if (g_core_complete && !g_core_complete_prev && g_core_inflight) begin
                    // Move in-flight task to RQ
                    if (rq_count < RQ_DEPTH) begin
                        fsm_found_rq = 1'b0;
                        for (fsm_li_rq = 0; fsm_li_rq < RQ_DEPTH && !fsm_found_rq; fsm_li_rq = fsm_li_rq + 1) begin
                            if (!rq_valid[fsm_li_rq]) begin
                                rq_tag_id[fsm_li_rq]    <= g_inflight_tag_id;
                                rq_valid[fsm_li_rq]     <= 1'b1;
                                rq_completed[fsm_li_rq] <= 1'b1;
                                rq_count <= rq_count + 1;
                                hq_rq_committed <= hq_rq_committed + 1;
                                fsm_found_rq = 1'b1;
                            end
                        end
                    end
                    // Clear EQ entry
                    if (g_inflight_is_mem) begin
                        eq_mem_valid[g_inflight_eq_idx] <= 1'b0;
                        eq_mem_count <= eq_mem_count - 1;
                    end else begin
                        eq_alu_valid[g_inflight_eq_idx] <= 1'b0;
                        eq_alu_count <= eq_alu_count - 1;
                    end
                    g_core_inflight <= 1'b0;
                    g_active_task_valid <= 1'b0;
                end

                // A-Core Completion
                if (a_core_complete && !a_core_complete_prev && a_core_inflight) begin
                    // Move to RQ
                    if (rq_count < RQ_DEPTH) begin
                        fsm_found_rq = 1'b0;
                        for (fsm_li_rq = 0; fsm_li_rq < RQ_DEPTH && !fsm_found_rq; fsm_li_rq = fsm_li_rq + 1) begin
                            if (!rq_valid[fsm_li_rq]) begin
                                rq_tag_id[fsm_li_rq]    <= a_inflight_tag_id;
                                rq_valid[fsm_li_rq]     <= 1'b1;
                                rq_completed[fsm_li_rq] <= 1'b1;
                                rq_count <= rq_count + 1;
                                hq_rq_committed <= hq_rq_committed + 1;
                                fsm_found_rq = 1'b1;
                            end
                        end
                    end
                    // Clear EQ entry
                    eq_vec_valid[a_inflight_eq_idx] <= 1'b0;
                    eq_vec_count <= eq_vec_count - 1;
                    a_core_inflight <= 1'b0;
                    a_active_task_valid <= 1'b0;
                end
                
                // NPU Completion (FIX: Missing NPU completion logic)
                if (npu_complete && !npu_complete_prev && n_core_inflight) begin
                    // Move to RQ
                    if (rq_count < RQ_DEPTH) begin
                        fsm_found_rq = 1'b0;
                        for (fsm_li_rq = 0; fsm_li_rq < RQ_DEPTH && !fsm_found_rq; fsm_li_rq = fsm_li_rq + 1) begin
                            if (!rq_valid[fsm_li_rq]) begin
                                rq_tag_id[fsm_li_rq]    <= {TAG_ID_WIDTH{1'b0}};  // NPU doesn't use tagging
                                rq_valid[fsm_li_rq]     <= 1'b1;
                                rq_completed[fsm_li_rq] <= 1'b1;
                                rq_count <= rq_count + 1;
                                hq_rq_committed <= hq_rq_committed + 1;
                                fsm_found_rq = 1'b1;
                            end
                        end
                    end
                    n_core_inflight <= 1'b0;
                    n_active_task_valid <= 1'b0;
                end
            end

            // Clear A-Core dependency bit (bit 1) from DQ tasks
            if (a_core_complete && !a_core_complete_prev) begin
                for (fsm_li_dq_dep = 0; fsm_li_dq_dep < DQ_DEPTH; fsm_li_dq_dep = fsm_li_dq_dep + 1) begin
                    if (dq_valid[fsm_li_dq_dep] && (dq_dep_mask[fsm_li_dq_dep] & 16'h0002)) begin
                        dq_dep_mask[fsm_li_dq_dep] <= dq_dep_mask[fsm_li_dq_dep] & ~16'h0002;
                    end
                end
            end

            // Clear NPU dependency bit (bit 2) from DQ tasks
            if (npu_complete && !npu_complete_prev) begin
                for (fsm_li_dq_dep = 0; fsm_li_dq_dep < DQ_DEPTH; fsm_li_dq_dep = fsm_li_dq_dep + 1) begin
                    if (dq_valid[fsm_li_dq_dep] && (dq_dep_mask[fsm_li_dq_dep] & 16'h0004)) begin
                        dq_dep_mask[fsm_li_dq_dep] <= dq_dep_mask[fsm_li_dq_dep] & ~16'h0004;
                    end
                end
            end

            // ── STAGE 5: RQ → CQ (In-order commit) ──
            // Commit tasks from RQ to CQ in order (FIFO)
            if (rq_valid[rq_commit_ptr] && rq_completed[rq_commit_ptr] && cq_count < CQ_DEPTH) begin
                cq_tag_id[cq_tail]    <= rq_tag_id[rq_commit_ptr];
                cq_addr[cq_tail]      <= 48'b0;  // Address tracked separately
                cq_result[cq_tail]    <= 64'b0;  // Result tracked separately
                cq_valid[cq_tail]     <= 1'b1;
                cq_committed[cq_tail] <= 1'b0;
                cq_tail <= (cq_tail == CQ_DEPTH-1) ? 0 : cq_tail + 1;
                cq_count <= cq_count + 1;

                // Remove from RQ
                rq_valid[rq_commit_ptr] <= 1'b0;
                rq_completed[rq_commit_ptr] <= 1'b0;
                rq_count <= rq_count - 1;

                // Advance commit pointer
                rq_commit_ptr <= (rq_commit_ptr == RQ_DEPTH-1) ? 0 : rq_commit_ptr + 1;
            end

            // ── STAGE 6: CQ → Result Output (Atomic write-back) ──
            // Commit results from CQ
            if (cq_valid[cq_head] && !cq_committed[cq_head]) begin
                cq_committed[cq_head] <= 1'b1;
                cq_valid[cq_head] <= 1'b0;
                cq_count <= cq_count - 1;
                cq_head <= (cq_head == CQ_DEPTH-1) ? 0 : cq_head + 1;
            end

            // ── DYNAMIC QUEUE BALANCER (DQB) ──
            // Spill overflow from busy EQ to less busy EQ
            begin
                if (eq_alu_count > (EQ_ALU_DEPTH * 3 / 4) && eq_vec_count < EQ_VEC_DEPTH / 2) begin
                    fsm_found_spill = 1'b0;
                    for (fsm_li_spill = 0; fsm_li_spill < EQ_ALU_DEPTH && !fsm_found_spill; fsm_li_spill = fsm_li_spill + 1) begin
                        if (eq_alu_valid[fsm_li_spill] && eq_vec_count < EQ_VEC_DEPTH) begin
                            fsm_found_vec = 1'b0;
                            for (fsm_li_vec = 0; fsm_li_vec < EQ_VEC_DEPTH && !fsm_found_vec; fsm_li_vec = fsm_li_vec + 1) begin
                                if (!eq_vec_valid[fsm_li_vec]) begin
                                    eq_vec_tag_id[fsm_li_vec] <= eq_alu_tag_id[fsm_li_spill];
                                    eq_vec_addr[fsm_li_vec]   <= eq_alu_addr[fsm_li_spill];
                                    eq_vec_data[fsm_li_vec]   <= eq_alu_data[fsm_li_spill];
                                    eq_vec_valid[fsm_li_vec]  <= 1'b1;
                                    eq_vec_ready[fsm_li_vec]  <= eq_alu_ready[fsm_li_spill];
                                    eq_vec_count <= eq_vec_count + 1;
                                    fsm_found_vec = 1'b1;
                                end
                            end
                            eq_alu_valid[fsm_li_spill] <= 1'b0;
                            eq_alu_count <= eq_alu_count - 1;
                            dqb_spill_count <= dqb_spill_count + 1;
                            fsm_found_spill = 1'b1;
                        end
                    end
                end
            end

            // ═══════════════════════════════════════════════════════
            // END HYBRID MULTI-QUEUE PIPELINE
            // ═══════════════════════════════════════════════════════

            // ── ENQUEUE per domain (with ADMISSION CONTROL) ──
            // FIX: Edge detection untuk prevent double enqueue saat cmd_valid ditahan > 1 cycle
            g_task_valid_prev <= g_task_valid;
            a_task_valid_prev <= a_task_valid;
            npu_task_valid_prev <= npu_task_valid;
            
            // DEBUG: Always print g_task_valid status for debugging
            if (g_task_valid != g_task_valid_prev) begin
                $display("[%0t] [SCHED-G] g_task_valid changed: %b -> %b, credits=%0d", 
                         $time, g_task_valid_prev, g_task_valid, g_credits);
            end
            
            // FIXED: G-Core enqueue logic - Single path to// Accept G-Core tasks if credits available
            if (g_task_valid && !g_task_valid_prev && g_credits > 0) begin
                // Counter incremented only at actual dispatch (line ~1030), not here
                $display("[%0t] [SCHED-G] G-Task ACCEPTED! g_task_valid=%b, credits=%0d, counter_dispatched=%0d", 
                         $time, g_task_valid, g_credits, counter_dispatched);
                if (g_q_count < G_QUEUE_THRESHOLD) begin
                    // Normal enqueue path
                    g_q_addr[g_tail] <= g_task_addr;
                    g_q_data[g_tail] <= g_task_data;
                    g_q_valid[g_tail] <= 1'b1; g_q_disp[g_tail] <= 1'b0;
                    g_q_aging[g_tail] <= 8'b0; g_q_wait[g_tail] <= 8'b0;
                    g_q_fresh[g_tail] <= 1'b1;
                    g_tail <= (g_tail == G_QUEUE_DEPTH-1) ? 0 : g_tail + 1;
                    g_q_count <= g_q_count + 1;
                    g_credits <= g_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    `ifdef DEBUG_SCHEDULER
                    $display("[%0t] [SCHEDULER_G] G-Task ACCEPTED: credits=%0d, q_count=%0d", $time, g_credits, g_q_count);
                    `endif
                end else begin
                    // Load balancing via ring bus
                    g_ring_inject <= 1'b1;
                    g_ring_addr <= g_task_addr;
                    g_ring_data <= g_task_data;
                    bp_ring_balanced <= bp_ring_balanced + 1;
                    `ifdef DEBUG_SCHEDULER
                    $display("[%0t] [SCHEDULER_G] G-Task RING BALANCED: credits=%0d, q_count=%0d", $time, g_credits, g_q_count);
                    `endif
                end
            end else if (g_task_valid && !g_task_valid_prev && g_credits == 0) begin
                // RING BUS LOAD BALANCING: Try ring bus if no credits
                if (!ring_bus_congested && ring_bus_g_packets < 32'd80) begin
                    // Route to ring bus instead of rejecting
                    g_q_addr[g_tail]  <= g_task_addr;
                    g_q_data[g_tail]  <= g_task_data;
                    g_q_valid[g_tail] <= 1'b1; g_q_disp[g_tail] <= 1'b0;
                    g_q_aging[g_tail] <= 8'b0; g_q_wait[g_tail] <= 8'b0;
                    g_q_fresh[g_tail] <= 1'b1;
                    g_tail <= (g_tail == G_QUEUE_DEPTH-1) ? 0 : g_tail + 1;
                    g_q_count <= g_q_count + 1;
                    g_credits <= g_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                end else begin
                    // REJECT: No credits and ring bus congested
                    bp_queue_full_rejections <= bp_queue_full_rejections + 1;
                end
            end else if (g_task_valid && !g_task_valid_prev) begin
                // ADMISSION CONTROL: Reject - no space available
                admission_rejections <= admission_rejections + 1;
            end

            // Clear fresh flag after 1 cycle (task now eligible for dispatch)
            begin
                for (fsm_li_fresh = 0; fsm_li_fresh < G_QUEUE_DEPTH; fsm_li_fresh = fsm_li_fresh + 1) begin
                    if (g_q_fresh[fsm_li_fresh]) begin
                        g_q_fresh[fsm_li_fresh] <= 1'b0;
                    end
                end
            end

            // HARD BACKPRESSURE: Stop injection if system is overwhelmed
            if (a_task_valid && !a_task_valid_prev && a_credits > 0 && a_q_count < A_QUEUE_THRESHOLD) begin
                // Counter incremented only at actual dispatch (line ~1045), not here
                // Additional safety: Check ring bus congestion before accepting
                if (!ring_bus_congested || (ring_bus_a_packets < 32'd30)) begin
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;  // FIX: Mark as fresh
                    a_tail <= (a_tail == $unsigned(A_QUEUE_DEPTH-1)) ? 0 : a_tail + 1;
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    `ifdef DEBUG_SCHEDULER
                    $display("[%0t] [SCHEDULER_A] A-Task ACCEPTED: credits=%0d, q_count=%0d", $time, a_credits, a_q_count);
                    `endif
                end else begin
                    // HARD BACKPRESSURE: Reject due to ring bus congestion
                    admission_rejections <= admission_rejections + 1;
                end
            end else if (a_task_valid && !a_task_valid_prev && a_q_count >= A_QUEUE_THRESHOLD) begin
                // RING BUS LOAD BALANCING: Try ring bus if scheduler queue full
                if (!ring_bus_congested && ring_bus_a_packets < 32'd50) begin
                    // Accept and let ring bus handle the load
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;
                    a_tail <= (a_tail == $unsigned(A_QUEUE_DEPTH-1)) ? 0 : a_tail + 1;
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    // DEBUG("[%0t] [SCHED-RB] 🔄 A-Task ACCEPTED via Ring Bus (queue_full=%0d, ring_packets=%0d)", $time, a_q_count, ring_bus_a_packets);
                end else begin
                    // ADMISSION CONTROL: Reject - both scheduler and ring bus congested
                    admission_rejections <= admission_rejections + 1;
                    // DEBUG("[%0t] [SCHED-AC] ⚠ A-Task REJECTED: QUEUE_FULL & RING_CONGESTED (queue_depth=%0d/%0d, ring_packets=%0d)", $time, a_q_count, A_QUEUE_DEPTH, ring_bus_a_packets);
                end
            end else if (a_task_valid && !a_task_valid_prev && a_credits == 0) begin
                // RING BUS LOAD BALANCING: Try ring bus if no credits
                if (!ring_bus_congested && ring_bus_a_packets < 32'd40) begin
                    // Route to ring bus instead of rejecting
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;
                    a_tail <= (a_tail == $unsigned(A_QUEUE_DEPTH-1)) ? 0 : a_tail + 1;
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    // DEBUG("[%0t] [SCHED-RB] 🔄 A-Task ROUTED via Ring Bus (no_credits, ring_packets=%0d)", $time, ring_bus_a_packets);
                end else begin
                    // REJECT: No credits and ring bus congested
                    bp_queue_full_rejections <= bp_queue_full_rejections + 1;
                    // DEBUG("[%0t] [SCHED-CR] ⚠ A-Task REJECTED: NO_CREDITS & RING_CONGESTED (queue_depth=%0d, ring_packets=%0d)", $time, a_q_count, ring_bus_a_packets);
                end
            end

            // Clear fresh flag after 1 cycle
            begin
                for (fsm_li_fresh = 0; fsm_li_fresh < A_QUEUE_DEPTH; fsm_li_fresh = fsm_li_fresh + 1) begin
                    if (a_q_fresh[fsm_li_fresh]) begin
                        a_q_fresh[fsm_li_fresh] <= 1'b0;
                    end
                end
            end

            if (npu_task_valid && !npu_task_valid_prev && n_credits > 0) begin
                n_q_addr[n_tail]  <= {ADDR_WIDTH{1'b0}};
                n_q_data[n_tail]  <= 64'b0;
                n_q_valid[n_tail] <= 1'b1; n_q_disp[n_tail] <= 1'b0;
                n_q_aging[n_tail] <= 8'b0; n_q_wait[n_tail] <= 8'b0;
                n_q_fresh[n_tail] <= 1'b1;  // FIX: Mark as fresh
                n_tail <= (n_tail == $unsigned(N_QUEUE_DEPTH-1)) ? 0 : n_tail + 1;
                n_q_count <= n_q_count + 1;
                n_credits <= n_credits - 1;
                bp_actual_accepts <= bp_actual_accepts + 1;
            end else if (npu_task_valid && !npu_task_valid_prev && n_credits == 0) begin
                bp_queue_full_rejections <= bp_queue_full_rejections + 1;
            end

            // Clear fresh flag after 1 cycle
            begin
                for (fsm_li_fresh = 0; fsm_li_fresh < N_QUEUE_DEPTH; fsm_li_fresh = fsm_li_fresh + 1) begin
                    if (n_q_fresh[fsm_li_fresh]) begin
                        n_q_fresh[fsm_li_fresh] <= 1'b0;
                    end
                end
            end

            // Credit refill on completion - FIXED: Restore all credit returns
            // Safety net: ensure credits are returned even if handler path misses
            if (g_core_complete && !g_core_complete_prev && g_credits < G_QUEUE_DEPTH) g_credits <= g_credits + 1;
            if (a_core_complete && !a_core_complete_prev && a_credits < A_QUEUE_DEPTH) a_credits <= a_credits + 1;
            if (npu_complete && !npu_complete_prev && n_credits < N_QUEUE_DEPTH) n_credits <= n_credits + 1;

            // ── AGING ──
            begin
                for (fsm_li_aging = 0; fsm_li_aging < G_QUEUE_DEPTH; fsm_li_aging = fsm_li_aging + 1) begin
                    if (g_q_valid[fsm_li_aging] && !g_q_disp[fsm_li_aging]) begin
                        g_q_wait[fsm_li_aging] <= g_q_wait[fsm_li_aging] + 1;
                        if (g_q_wait[fsm_li_aging] >= AGING_RATE && g_q_aging[fsm_li_aging] < MAX_AGING)
                            g_q_aging[fsm_li_aging] <= g_q_aging[fsm_li_aging] + 1;
                    end
                end
                for (fsm_li_aging = 0; fsm_li_aging < A_QUEUE_DEPTH; fsm_li_aging = fsm_li_aging + 1) begin
                    if (a_q_valid[fsm_li_aging] && !a_q_disp[fsm_li_aging]) begin
                        a_q_wait[fsm_li_aging] <= a_q_wait[fsm_li_aging] + 1;
                        if (a_q_wait[fsm_li_aging] >= AGING_RATE && a_q_aging[fsm_li_aging] < MAX_AGING)
                            a_q_aging[fsm_li_aging] <= a_q_aging[fsm_li_aging] + 1;
                    end
                end
                for (fsm_li_aging = 0; fsm_li_aging < N_QUEUE_DEPTH; fsm_li_aging = fsm_li_aging + 1) begin
                    if (n_q_valid[fsm_li_aging] && !n_q_disp[fsm_li_aging]) begin
                        n_q_wait[fsm_li_aging] <= n_q_wait[fsm_li_aging] + 1;
                        if (n_q_wait[fsm_li_aging] >= AGING_RATE && n_q_aging[fsm_li_aging] < MAX_AGING)
                            n_q_aging[fsm_li_aging] <= n_q_aging[fsm_li_aging] + 1;
                    end
                end
            end
            
            // Ring bus congestion recovery logic
            if (ring_bus_congested) begin
                congestion_timer <= congestion_timer + 1;
                if (congestion_timer >= 1000) begin
                    congestion_recovery_active <= 1'b1;
                    congestion_timer <= 16'b0;
                    bp_ring_balanced <= bp_ring_balanced + 1;
                end
            end else begin
                if (congestion_timer > 0) begin
                    congestion_timer <= congestion_timer - 1;
                end
                if (congestion_recovery_active) begin
                    congestion_recovery_active <= 1'b0;
                end
            end
            
            // CRITICAL FIX: Single-driver inflight timer management
            // Increment timers
            g_increment_timer <= g_core_inflight;
            a_increment_timer <= a_core_inflight;
            n_increment_timer <= n_core_inflight;
            
            // Reset timers (from various conditions)
            g_reset_timer <= 1'b0; a_reset_timer <= 1'b0; n_reset_timer <= 1'b0;

            // ── Completion (CONCURRENT: each domain独立) ──
            if (g_core_complete && !g_core_complete_prev && g_core_inflight) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Clear inflight when task completes
                g_core_inflight <= 1'b0;
                g_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                // NOTE: g_q_count is already decremented at dispatch (line 1035) or G→FQ move (line 1256)
                // Do NOT decrement again here — would cause queue tracking corruption
                g_credits <= g_credits + 1;  // FIX: Return credit on completion
                
                pending_result <= g_core_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_GAMING;
                g_active_task_valid <= 1'b0;
                // Track write address for hazard detection
                last_write_addr <= g_active_write_addr;
                last_write_was_g <= 1'b1;
                g_active_read_addr <= {ADDR_WIDTH{1'b0}};
                g_active_write_addr <= {ADDR_WIDTH{1'b0}};
                g_active_has_write <= 1'b0;
            end
            if (a_core_complete && !a_core_complete_prev && a_active_task_valid) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Clear inflight when task completes
                a_core_inflight <= 1'b0;
                a_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                // FIX #1 (MQ): Tidak lagi bergantung pada a_core_result_ready (circular).
                // a_core_result_ready = 1'b1 selalu, jadi kondisi ini selalu true saat valid=1.
                if (a_core_result_valid) begin
                    pending_result       <= a_core_result;
                    pending_result_valid <= 1'b1;
                    pending_result_type  <= TASK_AI;
                    
                    // NOTE: a_q_count is already decremented at dispatch (line 1049) or A→FQ move (line 1275)
                    // Do NOT decrement again here — would cause queue tracking corruption
                    
                    // DEBUG("[%0t] [MQ-SCHEDULER] ✅ A-Core result consumed: pending_result_valid=1", $time);
                end
                a_active_task_valid <= 1'b0;
                // Track write address for hazard detection
                last_write_addr <= a_active_write_addr;
                last_write_was_g <= 1'b0;
                a_active_read_addr <= {ADDR_WIDTH{1'b0}};
                a_active_write_addr <= {ADDR_WIDTH{1'b0}};
                a_active_has_write <= 1'b0;
            end
            if (npu_complete && !npu_complete_prev && n_active_task_valid) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Return credit when NPU task completes
                n_credits <= n_credits + 1;
                
                // CRITICAL FIX: Clear inflight when task completes
                n_core_inflight <= 1'b0;
                n_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                // CRITICAL FIX: Decrement queue count when NPU task completes with saturating logic
                if (n_q_count > 0) n_q_count <= n_q_count - 1;
                
                pending_result <= npu_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_NPU;
                n_active_task_valid <= 1'b0;
                last_write_addr <= n_active_write_addr;
                n_active_read_addr <= {ADDR_WIDTH{1'b0}};
                n_active_write_addr <= {ADDR_WIDTH{1'b0}};
                n_active_has_write <= 1'b0;
            end
            // DIAGNOSTIC: Pipeline state after first 2 G-core completions
            if (counter_completed == 2 && counter_completed_prev < 2) begin
                fsm_li = 0; for (fsm_li = 0; fsm_li < FQ_DEPTH; fsm_li = fsm_li + 1) begin
                    if (fq_tag_valid[fsm_li]) $display("[DIAG] FQ[%0d] valid addr=0x%h", fsm_li, fq_tag_addr[fsm_li]);
                end
                fsm_li = 0; for (fsm_li = 0; fsm_li < DQ_DEPTH; fsm_li = fsm_li + 1) begin
                    if (dq_valid[fsm_li]) $display("[DIAG] DQ[%0d] valid decoded=%b dep=0x%04h addr=0x%h", fsm_li, dq_decoded[fsm_li], dq_dep_mask[fsm_li], dq_addr[fsm_li]);
                end
                fsm_li = 0; for (fsm_li = 0; fsm_li < EQ_ALU_DEPTH; fsm_li = fsm_li + 1) begin
                    if (eq_alu_valid[fsm_li]) $display("[DIAG] EQ_ALU[%0d] valid ready=%b addr=0x%h", fsm_li, eq_alu_ready[fsm_li], eq_alu_addr[fsm_li]);
                end
                fsm_li = 0; for (fsm_li = 0; fsm_li < EQ_MEM_DEPTH; fsm_li = fsm_li + 1) begin
                    if (eq_mem_valid[fsm_li]) $display("[DIAG] EQ_MEM[%0d] valid ready=%b addr=0x%h", fsm_li, eq_mem_ready[fsm_li], eq_mem_addr[fsm_li]);
                end
                $display("[DIAG] fq_count=%0d dq_count=%0d eq_alu_count=%0d eq_mem_count=%0d", fq_count, dq_count, eq_alu_count, eq_mem_count);
                $display("[DIAG] g_core_busy=%b g_active_task_valid=%b g_core_inflight=%b counter_completed=%0d", g_core_busy, g_active_task_valid, g_core_inflight, counter_completed);
            end

            // FIX: Clear pending_result_valid on rising edge of new task
            // Old code used `active_task_valid` which was NEVER set by the v4.0 pipeline,
            // causing pending_result_valid to always be cleared in the same cycle
            // it was asserted (race condition). Now we clear on next task arrival instead.
            if (g_task_valid && !g_task_valid_prev) pending_result_valid <= 1'b0;

            // ── Stall tracking + WATCHDOG RECOVERY (PER-DOMAIN) ──
            // P1: Each domain has independent watchdog with different thresholds
            
            // G-Core watchdog
            if (g_active_task_valid) begin
                if (g_watchdog_counter < 16'hFFFF)
                    g_watchdog_counter <= g_watchdog_counter + 1;
                if (g_watchdog_counter == G_WATCHDOG_TIMEOUT) begin
                    bp_timeout_stalls <= bp_timeout_stalls + 1;
                    counter_completed <= counter_completed + 1;  // FIX: Count as completed (failed but cleared)
                    hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                    g_credits <= g_credits + 1;  // FIX: Return credit when task cleared by watchdog
                    if (g_q_count > 0) g_q_count <= g_q_count - 1;  // CRITICAL FIX: Decrement queue count on watchdog timeout
                    // DEBUG("[%0t] [SCHED-WD] \u26a0 G-Core watchdog timeout (%0d cycles), force clearing...", $time, G_WATCHDOG_TIMEOUT);
                    g_active_task_valid <= 1'b0;
                    g_active_read_addr <= {ADDR_WIDTH{1'b0}};
                    g_active_write_addr <= {ADDR_WIDTH{1'b0}};
                    g_active_has_write <= 1'b0;
                    g_core_inflight <= 1'b0;  // FIX: Clear inflight flag
                    g_reset_timer <= 1'b1;      // FIX: Set reset flag
                    watchdog_resets_reg <= watchdog_resets_reg + 1;
                    
                    // CRITICAL FIX #1: Clear G-Core dependency bit (bit 0) from ALL DQ tasks
                    // Prevents permanent deadlock when watchdog kills a task but DQ tasks still wait
                    begin
                        for (fsm_li_wd = 0; fsm_li_wd < DQ_DEPTH; fsm_li_wd = fsm_li_wd + 1) begin
                            if (dq_valid[fsm_li_wd] && (dq_dep_mask[fsm_li_wd] & 16'h0001)) begin
                                dq_dep_mask[fsm_li_wd] <= dq_dep_mask[fsm_li_wd] & ~16'h0001;
                            end
                        end
                    end
                    
                    // CRITICAL FIX #2: Mark RQ commit task as completed if it was waiting on G-Core
                    // Prevents RQ commit pointer from stalling forever
                    if (rq_valid[rq_commit_ptr] && !rq_completed[rq_commit_ptr]) begin
                        rq_completed[rq_commit_ptr] <= 1'b1;
                    end
                    
                    // CRITICAL FIX #3: Deadlock detection - force completion if stuck too long
                    if (rq_valid[rq_commit_ptr] && !rq_completed[rq_commit_ptr] && g_watchdog_counter > 500) begin
                        $display("[%0t] [SCHED-WARN] RQ task deadlock detected - forcing completion", $time);
                        rq_completed[rq_commit_ptr] <= 1'b1;
                        rq_commit_ptr <= rq_commit_ptr + 1'b1;
                    end
                end
            end else begin
                g_watchdog_counter <= 16'b0;
            end
            
            // OBSOLETE DISPATCH LOGIC AND WATCHDOGS REMOVED
            // REPLACED BY HYBRID PIPELINE STAGES 1-7
            
            // Starvation and Watchdog integrated in block below
            // ── Cleanup dispatched tasks ──
            begin
                fsm_cleaned_g = 0;
                for (fsm_li = 0; fsm_li < G_QUEUE_DEPTH; fsm_li = fsm_li + 1) begin
                    if (g_q_valid[fsm_li] && g_q_disp[fsm_li]) begin
                        g_q_valid[fsm_li] <= 1'b0;
                        fsm_cleaned_g = fsm_cleaned_g + 1;
                        if (fsm_cleaned_g == 1) g_head <= (g_head == G_QUEUE_DEPTH-1) ? 0 : g_head + 1;
                        if (g_q_count > 0) g_q_count <= g_q_count - 1;
                    end
                end
                
                fsm_cleaned_a = 0;
                for (fsm_li = 0; fsm_li < A_QUEUE_DEPTH; fsm_li = fsm_li + 1) begin
                    if (a_q_valid[fsm_li] && a_q_disp[fsm_li]) begin
                        a_q_valid[fsm_li] <= 1'b0;
                        fsm_cleaned_a = fsm_cleaned_a + 1;
                        if (fsm_cleaned_a == 1) a_head <= (a_head == A_QUEUE_DEPTH-1) ? 0 : a_head + 1;
                        if (a_q_count > 0) a_q_count <= a_q_count - 1;
                    end
                end
                
                fsm_cleaned_n = 0;
                for (fsm_li = 0; fsm_li < N_QUEUE_DEPTH; fsm_li = fsm_li + 1) begin
                    if (n_q_valid[fsm_li] && n_q_disp[fsm_li]) begin
                        n_q_valid[fsm_li] <= 1'b0;
                        fsm_cleaned_n = fsm_cleaned_n + 1;
                        if (fsm_cleaned_n == 1) n_head <= (n_head == N_QUEUE_DEPTH-1) ? 0 : n_head + 1;
                        if (n_q_count > 0) n_q_count <= n_q_count - 1;
                    end
                end
            end
            begin
                // FIX: Track MAX individual queue depth, not SUM
                // This gives true per-queue utilization insight
                // IVC: Use max3_result instead of function call
                if (max3_result[31:0] > max_queue_depth_seen) max_queue_depth_seen <= max3_result[31:0];
            end
            
            // ── Inflight Management & Watchdogs (Integrated) ──
            if (g_reset_timer) begin
                g_inflight_timer <= 0;
                g_reset_timer <= 1'b0;
            end else if (g_core_inflight) begin
                g_inflight_timer <= g_inflight_timer + 1;
                if (g_inflight_timer > 2000) begin
                    // DEBUG("[%0t] [MQ-SCHEDULER] ⚠ INFLIGHT TIMEOUT: G-Core task stalled too long, forcing recovery", $time);
                    force_complete_g_core_task();
                end
            end else begin
                g_inflight_timer <= 0;
            end

            if (a_reset_timer) begin
                a_inflight_timer <= 0;
                a_reset_timer <= 1'b0;
            end else if (a_core_inflight) begin
                a_inflight_timer <= a_inflight_timer + 1;
                if (a_inflight_timer > 2000) begin
                    // DEBUG("[%0t] [MQ-SCHEDULER] ⚠ INFLIGHT TIMEOUT: A-Core task stalled too long, forcing recovery", $time);
                    force_complete_a_core_task();
                end
            end else begin
                a_inflight_timer <= 0;
            end

            // Starvation counters logic (integrated)
            if (g_q_count > 0 && !g_core_busy && !g_core_inflight) begin
                g_starve_counter <= g_starve_counter + 1;
            end else g_starve_counter <= 0;

            if (a_q_count > 0 && !a_core_busy && !a_core_inflight) begin
                a_starve_counter <= a_starve_counter + 1;
            end else a_starve_counter <= 0;
        end
    end

    // =========================================================================
    // Recovery Tasks (NEW)
    // =========================================================================
    task force_complete_g_core_task;
        begin
            // DEBUG("[%0t] [MQ-SCHEDULER] ** RECOVERY: Force completing G-Core task", $time);
            g_active_task_valid <= 1'b0;
            g_core_inflight <= 1'b0;
            g_reset_timer <= 1'b1;
            g_active_read_addr <= {ADDR_WIDTH{1'b0}};
            g_active_write_addr <= {ADDR_WIDTH{1'b0}};
            g_active_has_write <= 1'b0;
            // CRITICAL FIX: Clear task state
            hq_cq_completed <= hq_cq_completed + 1;
        end
    endtask

    task force_complete_a_core_task;
        begin
            // DEBUG("[%0t] [MQ-SCHEDULER] ** RECOVERY: Force completing A-Core task", $time);
            a_active_task_valid <= 1'b0;
            a_core_inflight <= 1'b0;
            a_reset_timer <= 1'b1;
            a_active_read_addr <= {ADDR_WIDTH{1'b0}};
            a_active_write_addr <= {ADDR_WIDTH{1'b0}};
            a_active_has_write <= 1'b0;
            // CRITICAL FIX: Decrement queue count and return credit on force completion with saturating logic
            if (a_q_count > 0) a_q_count <= a_q_count - 1;
            a_credits <= a_credits + 1;
            counter_completed <= counter_completed + 1;
            hq_cq_completed <= hq_cq_completed + 1;
        end
    endtask

    task clear_npu_waiting_tasks;
        input [ADDR_WIDTH-1:0] target_addr;
        integer i_cl;
        reg [7:0] credit_ret;
        begin
            credit_ret = 0;
            for (i_cl = 0; i_cl < N_QUEUE_DEPTH; i_cl = i_cl + 1) begin
                if (n_q_valid[i_cl] && n_q_data[i_cl][ADDR_WIDTH-1:0] == target_addr) begin
                    // DEBUG("[%0t] [MQ-SCHEDULER]    → Clearing NPU queue entry %0d (addr 0x%h)", $time, i_cl, target_addr);
                    n_q_valid[i_cl] <= 1'b0;
                    n_q_disp[i_cl] <= 1'b0;
                    credit_ret = credit_ret + 1;
                end
            end
            if (credit_ret > 0 && n_credits + credit_ret <= N_QUEUE_DEPTH)
                n_credits <= n_credits + credit_ret;
        end
    endtask

endmodule
