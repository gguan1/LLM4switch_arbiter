//============================================================================
// Module:  age_arbiter
//
// Age-Based Network Arbiter
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
// PIPELINE LATENCY
// ----------------
// The grant output is REGISTERED.  Because both the arbiter and the top
// module sample registers on the same posedge, the effective pipeline is:
//
//   Cycle N          : Entry visible in table (age 0).  Arbiter
//                      combinationally computes grant_next.
//   Cycle N+1 posedge: Arbiter registers grant_vector <= grant_next.
//                      Top module's always_ff reads the OLD grant_vector
//                      (from cycle N-1) — so this grant is NOT yet visible
//                      to the top module.  Entry ages to 1.
//   Cycle N+2 posedge: Top module reads the grant_vector registered at
//                      cycle N+1.  Entry is cleared.
//
// Minimum entry lifetime is therefore 2 cycles.  Entries are always
// granted at age >= 1, never at age 0.
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
    input  logic                        clock,
    input  logic                        reset,

    // Request table from request_manager_top
    input  logic [TABLE_SIZE-1:0]       req_valid,
    input  logic [DST_WIDTH-1:0]        req_dest    [TABLE_SIZE-1:0],
    input  logic [DATA_WIDTH-1:0]       req_data    [TABLE_SIZE-1:0],
    input  logic [AGE_WIDTH-1:0]        req_age     [TABLE_SIZE-1:0],

    // Grant vector back to request_manager_top (registered)
    output logic [TABLE_SIZE-1:0]       grant_vector
);

    // ----------------------------------------------------------------
    // Eligibility: valid entries are eligible.
    //
    // Self-request filtering is handled at insertion by the top module
    // (and enforced by assertion), so the arbiter does not need to
    // check source vs destination.
    // ----------------------------------------------------------------
    wire [TABLE_SIZE-1:0] eligible = req_valid;

    // ----------------------------------------------------------------
    // Combinational arbitration
    //
    // Greedy scan from highest age down to 0.  Within each age level,
    // entries are visited in index order (lower index = higher tiebreak
    // priority).  An entry is granted if its destination has not already
    // been claimed by a higher-priority entry.
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0] grant_next;

    always_comb begin
        logic [NUM_DSTS-1:0] dst_claimed;

        grant_next  = '0;
        dst_claimed = '0;

        for (int a = MAX_AGE; a >= 0; a--) begin
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (eligible[i]
                    && req_age[i] == AGE_WIDTH'(a)
                    && !dst_claimed[req_dest[i]]
                ) begin
                    grant_next[i]            = 1'b1;
                    dst_claimed[req_dest[i]] = 1'b1;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Registered grant output
    //
    // Breaking the combinational path (table regs → arbiter → grant →
    // table always_ff) is essential: without the register, Verilator
    // (and other simulators) resolve the arbiter within the same delta
    // cycle as the insertion NBA, causing entries to be born and killed
    // in a single posedge evaluation.
    // ----------------------------------------------------------------
    always_ff @(posedge clock or posedge reset) begin
        if (reset)
            grant_vector <= '0;
        else
            grant_vector <= grant_next;
    end

endmodule
