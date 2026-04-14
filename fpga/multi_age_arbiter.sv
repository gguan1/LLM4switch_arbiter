//============================================================================
// Module:  age_arbiter
//
// Age-Based Network Arbiter — purely combinational
//
// Scans the request table and produces a grant_vector selecting one winner
// per destination per cycle, prioritised by age (oldest first), with ties
// broken by lowest table index.  Source conflicts are NOT enforced — a
// source may be granted multiple times if its packets target different
// destinations, since only the destination port is a contended resource.
//
// Self-request filtering is the responsibility of the top module, which
// rejects them at insertion.  The arbiter treats every valid table entry
// as eligible.
//
// This module is stateless: no clock, no reset, no registers.  The grant
// output is a combinational function of the current table state.  The
// companion request_manager_top is responsible for registering the grant
// internally to break the combinational feedback loop and establish the
// pipeline latency.
//============================================================================

module age_arbiter #(
    parameter int TABLE_SIZE = 8,
    parameter int DST_WIDTH  = 2,
    parameter int DATA_WIDTH = 9,
    parameter int AGE_WIDTH  = 3,
    parameter int MAX_AGE    = 7,

    // Derived — do not override
    parameter int NUM_DSTS   = 1 << DST_WIDTH
) (
    // Request table from request_manager_top
    input  logic [TABLE_SIZE-1:0]       req_valid,
    input  logic [DST_WIDTH-1:0]        req_dest    [TABLE_SIZE-1:0],
    input  logic [DATA_WIDTH-1:0]       req_data    [TABLE_SIZE-1:0],
    input  logic [AGE_WIDTH-1:0]        req_age     [TABLE_SIZE-1:0],

    // Grant vector (combinational output)
    output logic [TABLE_SIZE-1:0]       grant_vector
);

    // ----------------------------------------------------------------
    // Combinational arbitration
    //
    // Greedy scan from highest age down to 0.  Within each age level,
    // entries are visited in index order (lower index = higher tiebreak
    // priority).  An entry is granted if its destination has not already
    // been claimed by a higher-priority entry.
    // ----------------------------------------------------------------
    always_comb begin
        logic [NUM_DSTS-1:0] dst_claimed;

        grant_vector = '0;
        dst_claimed  = '0;

        for (int a = MAX_AGE; a >= 0; a--) begin
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (req_valid[i]
                    && req_age[i] == AGE_WIDTH'(a)
                    && !dst_claimed[req_dest[i]]
                ) begin
                    grant_vector[i]          = 1'b1;
                    dst_claimed[req_dest[i]] = 1'b1;
                end
            end
        end
    end

endmodule
