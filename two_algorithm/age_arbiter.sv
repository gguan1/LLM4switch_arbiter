//============================================================================
// Module:  age_arbiter (Vivado-safe: packed ports, no block-local variables)
//
// Age-Based Network Arbiter -- purely combinational
//
// Scans the request table and produces a grant_vector selecting one winner
// per destination per cycle, prioritised by age (oldest first), with ties
// broken by lowest table index.
//============================================================================

module age_arbiter #(
    parameter TABLE_SIZE = 8,
    parameter DST_WIDTH  = 2,
    parameter DATA_WIDTH = 9,
    parameter AGE_WIDTH  = 3,
    parameter MAX_AGE    = 7,
    parameter NUM_DSTS   = 1 << DST_WIDTH
) (
    // Request table from request_manager_top (packed)
    input  wire [TABLE_SIZE-1:0]                req_valid,
    input  wire [TABLE_SIZE*DST_WIDTH-1:0]      req_dest_flat,
    input  wire [TABLE_SIZE*DATA_WIDTH-1:0]     req_data_flat,
    input  wire [TABLE_SIZE*AGE_WIDTH-1:0]      req_age_flat,

    // Grant vector (combinational output)
    output reg  [TABLE_SIZE-1:0]                grant_vector
);

    // ---- Unpack flat inputs into local arrays ----
    reg [DST_WIDTH-1:0]  req_dest [0:TABLE_SIZE-1];
    reg [AGE_WIDTH-1:0]  req_age  [0:TABLE_SIZE-1];

    genvar gi;
    generate
        for (gi = 0; gi < TABLE_SIZE; gi = gi + 1) begin : unpack
            always @(*) begin
                req_dest[gi] = req_dest_flat[gi*DST_WIDTH +: DST_WIDTH];
                req_age[gi]  = req_age_flat [gi*AGE_WIDTH +: AGE_WIDTH];
            end
        end
    endgenerate

    // ---- Destination-claimed mask (module scope, not block-local) ----
    reg [NUM_DSTS-1:0] dst_claimed;

    // ================================================================
    // Combinational arbitration
    //
    // Greedy scan from highest age down to 0.  Within each age level,
    // entries are visited in index order (lower index = higher tiebreak
    // priority).  An entry is granted if its destination has not already
    // been claimed by a higher-priority entry.
    // ================================================================
    always @(*) begin : blk_arb
        integer a, i;
        grant_vector = {TABLE_SIZE{1'b0}};
        dst_claimed  = {NUM_DSTS{1'b0}};

        for (a = MAX_AGE; a >= 0; a = a - 1) begin
            for (i = 0; i < TABLE_SIZE; i = i + 1) begin
                if (req_valid[i]
                    && req_age[i] == a[AGE_WIDTH-1:0]
                    && !dst_claimed[req_dest[i]]
                ) begin
                    grant_vector[i]          = 1'b1;
                    dst_claimed[req_dest[i]] = 1'b1;
                end
            end
        end
    end

endmodule
