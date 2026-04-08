//============================================================================
// Request Manager Top Module (Fixed)
//
// Manages a table of active requests and interfaces with an age-based
// arbiter.  Changes from the original:
//
//   FIX 1 — Self-request rejection at input
//     new_req_ready is deasserted and Step 3 will not insert if
//     new_req_source == new_req_dest.  This prevents ungrantable entries
//     from consuming table slots.
//
//   FIX 2 — Auto-expiration at MAX_AGE
//     Entries that saturate at MAX_AGE without being granted are
//     automatically cleared.  This prevents permanent deadlock in cases
//     where a request can never win arbitration (starvation).  An
//     expired_vector output reports which entries were expired so the
//     sender can retry.
//
//   FIX 3 — Overflow decoupled from insertion
//     age_overflow is now purely advisory (congestion indicator).  It no
//     longer blocks new_req_ready.  The deadlock risk is eliminated by
//     FIX 1 + FIX 2, so there is no safety reason to gate insertions.
//
//   FIX 4 — Granted packet output
//     Registered outputs (granted_valid, granted_source, granted_dest,
//     granted_data) capture the packet fields on the cycle a grant is
//     applied, BEFORE the entry is cleared.  Downstream logic can read
//     these to forward packets to their destinations.
//============================================================================

module request_manager_top #(
    parameter int TABLE_SIZE = 8,
    parameter int REQ_WIDTH  = 16,
    parameter int SRC_WIDTH  = 2,
    parameter int DST_WIDTH  = 2,
    parameter int DATA_WIDTH = 9,
    parameter int AGE_WIDTH  = 3,
    parameter int MAX_AGE    = 7
) (
    input  logic                           clock,
    input  logic                           reset,

    // ---- New request input interface ----
    input  logic                           new_req_valid,
    input  logic [SRC_WIDTH-1:0]           new_req_source,
    input  logic [DST_WIDTH-1:0]           new_req_dest,
    input  logic [DATA_WIDTH-1:0]          new_req_data,
    output logic                           new_req_ready,

    // ---- Request table output to arbiter ----
    output logic [TABLE_SIZE-1:0]          req_table_valid,
    output logic [SRC_WIDTH-1:0]           req_table_source [TABLE_SIZE-1:0],
    output logic [DST_WIDTH-1:0]           req_table_dest   [TABLE_SIZE-1:0],
    output logic [DATA_WIDTH-1:0]          req_table_data   [TABLE_SIZE-1:0],
    output logic [AGE_WIDTH-1:0]           req_table_age    [TABLE_SIZE-1:0],

    // ---- Grant signals from arbiter ----
    input  logic [TABLE_SIZE-1:0]          grant_vector,

    // ---- Granted packet outputs (registered) ----
    output logic [TABLE_SIZE-1:0]          granted_valid,
    output logic [SRC_WIDTH-1:0]           granted_source   [TABLE_SIZE-1:0],
    output logic [DST_WIDTH-1:0]           granted_dest     [TABLE_SIZE-1:0],
    output logic [DATA_WIDTH-1:0]          granted_data     [TABLE_SIZE-1:0],

    // ---- Expired entry outputs (registered) ----
    output logic [TABLE_SIZE-1:0]          expired_valid,

    // ---- Status outputs ----
    output logic [$clog2(TABLE_SIZE+1)-1:0] num_active_reqs,
    output logic                            table_full,
    output logic                            age_overflow     // Advisory: any request reached MAX_AGE
);

    // ----------------------------------------------------------------
    // Internal storage
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0]      valid_reg;
    logic [SRC_WIDTH-1:0]       source_reg [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]       dest_reg   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]      data_reg   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]       age_reg    [TABLE_SIZE-1:0];

    // ----------------------------------------------------------------
    // Combinational signals
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0]      age_maxed;
    logic [TABLE_SIZE-1:0]      free_slots;
    logic [$clog2(TABLE_SIZE)-1:0] insert_index;
    logic                       can_insert;
    logic [$clog2(TABLE_SIZE+1)-1:0] active_count;
    logic                       overflow_condition;
    logic                       self_request;       // FIX 1

    // ---- FIX 1: detect self-request on input ----
    assign self_request = (new_req_source == new_req_dest);

    // ---- Table outputs ----
    assign req_table_valid  = valid_reg;
    assign req_table_source = source_reg;
    assign req_table_dest   = dest_reg;
    assign req_table_data   = data_reg;
    assign req_table_age    = age_reg;
    assign num_active_reqs  = active_count;
    assign table_full       = (active_count == TABLE_SIZE[$clog2(TABLE_SIZE+1)-1:0]);

    // ---- Detect overflow condition (advisory) ----
    always_comb begin
        overflow_condition = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            age_maxed[i] = valid_reg[i] && (age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]);
            if (age_maxed[i])
                overflow_condition = 1'b1;
        end
    end

    assign age_overflow = overflow_condition;

    // ---- Free slots: invalid entries, granted entries, or expired entries ----
    always_comb begin
        for (int i = 0; i < TABLE_SIZE; i++) begin
            free_slots[i] = ~valid_reg[i] || grant_vector[i] || age_maxed[i];  // FIX 2
        end
    end

    // ---- Priority encoder: first free slot ----
    always_comb begin
        insert_index = '0;
        can_insert   = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (free_slots[i] && !can_insert) begin
                insert_index = i[$clog2(TABLE_SIZE)-1:0];
                can_insert   = 1'b1;
            end
        end
    end

    // ---- FIX 1 + FIX 3: ready = free slot exists AND not a self-request ----
    // (overflow no longer blocks insertion)
    assign new_req_ready = can_insert && !self_request;

    // ---- Count active requests ----
    always_comb begin
        active_count = '0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (valid_reg[i])
                active_count = active_count + 1'b1;
        end
    end

    // ----------------------------------------------------------------
    // Main state update
    //
    // Within the same always_ff, later NBA assignments to the same
    // register win over earlier ones (last-write-wins).  The ordering
    // below ensures that Step 4 (insert) can override Step 1/2/3
    // when inserting into a slot that is simultaneously being cleared.
    // ----------------------------------------------------------------
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            valid_reg     <= '0;
            granted_valid <= '0;
            expired_valid <= '0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                source_reg[i]  <= '0;
                dest_reg[i]    <= '0;
                data_reg[i]    <= '0;
                age_reg[i]     <= '0;
                granted_source[i] <= '0;
                granted_dest[i]   <= '0;
                granted_data[i]   <= '0;
            end
        end else begin

            // Default: clear single-cycle output pulses
            granted_valid <= '0;
            expired_valid <= '0;

            for (int i = 0; i < TABLE_SIZE; i++) begin

                // ---- Step 1: Remove granted requests (FIX 4: capture output) ----
                if (grant_vector[i] && valid_reg[i]) begin
                    valid_reg[i] <= 1'b0;
                    age_reg[i]   <= '0;
                    // FIX 4: latch granted packet data for downstream use
                    granted_valid[i]  <= 1'b1;
                    granted_source[i] <= source_reg[i];
                    granted_dest[i]   <= dest_reg[i];
                    granted_data[i]   <= data_reg[i];

                // ---- Step 2: Expire entries at MAX_AGE (FIX 2) ----
                end else if (valid_reg[i] && age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]) begin
                    valid_reg[i]     <= 1'b0;
                    age_reg[i]       <= '0;
                    expired_valid[i] <= 1'b1;

                // ---- Step 3: Age active entries ----
                end else if (valid_reg[i]) begin
                    age_reg[i] <= age_reg[i] + 1'b1;
                end

                // ---- Step 4: Insert new request (FIX 1: reject self-requests) ----
                // This is a separate 'if', not 'else if', so it can override
                // Step 1/2 for the same slot (last NBA wins).
                if ((grant_vector[i] || age_maxed[i] || ~valid_reg[i]) &&
                    new_req_valid && can_insert && !self_request &&
                    (i[$clog2(TABLE_SIZE)-1:0] == insert_index)) begin
                    valid_reg[i]  <= 1'b1;
                    source_reg[i] <= new_req_source;
                    dest_reg[i]   <= new_req_dest;
                    data_reg[i]   <= new_req_data;
                    age_reg[i]    <= '0;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Assertions
    // ----------------------------------------------------------------
    // synthesis translate_off
    always_ff @(posedge clock) begin
        if (!reset) begin
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (valid_reg[i]) begin
                    assert (age_reg[i] <= MAX_AGE)
                        else $error("Age exceeded MAX_AGE at index %0d", i);
                    // FIX 1: self-requests should never be in the table
                    assert (source_reg[i] != dest_reg[i])
                        else $error("Self-request found at index %0d (src=%0d)",
                                    i, source_reg[i]);
                end
            end
        end
    end
    // synthesis translate_on

endmodule
