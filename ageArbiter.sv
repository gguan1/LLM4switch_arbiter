module age_arbiter #(
    parameter int TABLE_SIZE = 8,
    parameter int SRC_WIDTH  = 2,
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
    input  logic [SRC_WIDTH-1:0]        req_source  [TABLE_SIZE-1:0],
    input  logic [DST_WIDTH-1:0]        req_dest    [TABLE_SIZE-1:0],
    input  logic [DATA_WIDTH-1:0]       req_data    [TABLE_SIZE-1:0],   // unused — accepted for clean wiring
    input  logic [AGE_WIDTH-1:0]        req_age     [TABLE_SIZE-1:0],

    // Grant vector back to request_manager_top (registered)
    output logic [TABLE_SIZE-1:0]       grant_vector
);

    // ----------------------------------------------------------------
    // Eligibility pre-computation
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0] eligible;

    always_comb begin
        for (int i = 0; i < TABLE_SIZE; i++) begin
            eligible[i] = req_valid[i] && (req_source[i] != req_dest[i]);
        end
    end

    // ----------------------------------------------------------------
    // Combinational arbitration logic
    //
    // Greedy scan from highest age down to 0.  Within each age level,
    // entries are visited in index order (lower index = higher tiebreak
    // priority).  An entry is granted if its destination has not already
    // been claimed by a higher-priority entry.
    //
    // Source conflicts are NOT checked — a source may be granted
    // multiple times in the same cycle if its packets target different
    // destinations, since only the destination port is a contended
    // resource.
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
                    grant_next[i]              = 1'b1;
                    dst_claimed[req_dest[i]]   = 1'b1;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Registered grant output
    // ----------------------------------------------------------------
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            grant_vector <= '0;
        end else begin
            grant_vector <= grant_next;
        end
    end

endmodul