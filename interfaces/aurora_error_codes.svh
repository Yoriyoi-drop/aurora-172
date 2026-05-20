`ifndef AURORA_ERROR_CODES_SVH
`define AURORA_ERROR_CODES_SVH

// Error codes
`define ERR_NONE                 8'h00
`define ERR_ILLEGAL_OPCODE       8'h01
`define ERR_MEMORY_FAULT         8'h02
`define ERR_BUS_ERROR            8'h03
`define ERR_TIMEOUT              8'h04
`define ERR_OVERFLOW             8'h05
`define ERR_UNDERFLOW            8'h06
`define ERR_DIVIDE_BY_ZERO       8'h07
`define ERR_PRIVILEGE_VIOLATION  8'h08
`define ERR_PAGE_FAULT           8'h09
`define ERR_ALIGNMENT_FAULT      8'h0A
`define ERR_DEBUG_TRAP           8'h0B
`define ERR_SYSTEM_CALL          8'h0C
`define ERR_HARDWARE_FAULT       8'h0D
`define ERR_POWER_FAULT          8'h0E
`define ERR_THERMAL_FAULT        8'h0F
`define ERR_OOB_ADDRESS          8'h10
`define ERR_ACCESS_VIOLATION     8'h11
`define ERR_CACHE_TIMEOUT        8'h12

`endif
