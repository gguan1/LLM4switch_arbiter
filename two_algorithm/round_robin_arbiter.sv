//============================================================================
// Module:  round_robin_arbiter (Vivado-safe: packed ports)
//
// Round-Robin Network Arbiter
//
// Grants one winner per destination per cycle, rotating priority among
// table slots so that no slot is permanently starved.  A per-destination
// pointer tracks the last slot that was granted for each destination.
// On each cycle the scan starts from (last_granted + 1) and wraps
// around, giving the next valid requester the highest priority.
//
// INTERFACE
// ---------
// Same data ports as age_arbiter, plus clock and reset (needed to
// maintain the rotating pointer state).
//
// req_age_flat is accepted for port compatibility but is NOT used
// for arbitration -- priority comes purely from the round-robin pointer.
//============================================================================

module round_robin_arbiter #(
    parameter TABLE_SIZE = 8,
    parameter DST_WIDTH  = 2,
    parameter DATA_WIDTH = 9,
    parameter AGE_WIDTH  = 3,
    parameter MAX_AGE    = 7,
    parameter NUM_DSTS   = 1 << DST_WIDTH,
    parameter IDX_WIDTH  = $clog2(TABLE_SIZE)
) (
    input  wire                                 clock,
    input  wire                                 reset,

    // Request table from request_manager_top (packed) -- same as age_arbiter
    input  wire [TABLE_SIZE-1:0]                req_valid,
    input  wire [TABLE_SIZE*DST_WIDTH-1:0]      req_dest_flat,
    input  wire [TABLE_SIZE*DATA_WIDTH-1:0]     req_data_flat,   // unused, kept for compatibility
    input  wire [TABLE_SIZE*AGE_WIDTH-1:0]      req_age_flat,    // unused, kept for compatibility

    // Grant vector
    output reg  [TABLE_SIZE-1:0]                grant_vector
);

    // ---- Unpack destination array ----
    reg [DST_WIDTH-1:0] req_dest [0:TABLE_SIZE-1];

    genvar gi;
    generate
        for (gi = 0; gi < TABLE_SIZE; gi = gi + 1) begin : unpack
            always @(*) begin
                req_dest[gi] = req_dest_flat[gi*DST_WIDTH +: DST_WIDTH];
            end
        end
    endgenerate

    // ================================================================
    // Per-destination round-robin pointer
    //
    // last_grant_idx[d] holds the table index that was most recently
    // granted for destination d.  The next scan for destination d
    // starts at (last_grant_idx[d] + 1) mod TABLE_SIZE.
    // ================================================================
    reg [IDX_WIDTH-1:0] last_grant_idx [0:NUM_DSTS-1];

    // ---- Destination-claimed mask ----
    reg [NUM_DSTS-1:0] dst_claimed;

    // ---- Temporary: which slot wins for each destination this cycle ----
    reg [TABLE_SIZE-1:0] next_grant;
    reg [IDX_WIDTH-1:0]  next_grant_idx [0:NUM_DSTS-1];
    reg [NUM_DSTS-1:0]   dst_granted;

    // ================================================================
    // Combinational arbitration
    //
    // For each destination, scan TABLE_SIZE slots starting from
    // (last_grant_idx[d] + 1).  The first valid requester for that
    // destination wins.  Each destination is independent, so multiple
    // destinations can each grant one winner simultaneously.
    // ================================================================
    always @(*) begin : blk_arb
        integer d, s, idx;
        next_grant  = {TABLE_SIZE{1'b0}};
        dst_claimed = {NUM_DSTS{1'b0}};
        dst_granted = {NUM_DSTS{1'b0}};

        for (d = 0; d < NUM_DSTS; d = d + 1) begin
            next_grant_idx[d] = last_grant_idx[d];
        end

        // Scan for each destination independently
        for (d = 0; d < NUM_DSTS; d = d + 1) begin
            for (s = 1; s <= TABLE_SIZE; s = s + 1) begin
                // Compute wrapped index: (last_grant_idx[d] + s) mod TABLE_SIZE
                idx = (last_grant_idx[d] + s);
                // Manual modulo for synthesis friendliness
                if (idx >= TABLE_SIZE)
                    idx = idx - TABLE_SIZE;
                // Second wrap check (needed if last_grant_idx + s >= 2*TABLE_SIZE,
                // which can't happen since s <= TABLE_SIZE, but defensive)
                if (idx >= TABLE_SIZE)
                    idx = idx - TABLE_SIZE;

                if (req_valid[idx]
                    && req_dest[idx] == d[DST_WIDTH-1:0]
                    && !dst_granted[d]
                ) begin
                    next_grant[idx]    = 1'b1;
                    dst_granted[d]     = 1'b1;
                    next_grant_idx[d]  = idx[IDX_WIDTH-1:0];
                end
            end
        end

        grant_vector = next_grant;
    end

    // ================================================================
    // Update round-robin pointers on clock edge
    // ================================================================
    integer di;
    always @(posedge clock or posedge reset) begin
        if (reset) begin
            for (di = 0; di < NUM_DSTS; di = di + 1)
                last_grant_idx[di] <= {IDX_WIDTH{1'b0}};
        end else begin
            for (di = 0; di < NUM_DSTS; di = di + 1) begin
                if (dst_granted[di])
                    last_grant_idx[di] <= next_grant_idx[di];
            end
        end
    end

endmodule
