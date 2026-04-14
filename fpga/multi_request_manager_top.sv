//============================================================================
// Request Manager Top Module
//
// Manages a table of active requests and interfaces with a purely
// combinational age-based arbiter.
//
// MULTI-PORT INSERTION
// --------------------
// The module accepts up to NUM_SRCS (= 2^SRC_WIDTH = 4) requests per
// cycle — one per source.  The source ID is implicit: port index s
// corresponds to source s.  A cascaded priority encoder allocates a
// unique free table slot for each valid input.  Requests from all
// sources that have free slots are inserted in the SAME posedge.
//
// Because multiple entries can now appear in the table simultaneously,
// the arbiter can grant them in the same cycle, and they can be cleared
// together — enabling true same-cycle multi-destination grants.
//
// GRANT PIPELINE
// --------------
// The arbiter's grant_vector is combinational.  This module registers it
// internally (grant_reg) to break the feedback loop:
//
//   Cycle N   : Entries inserted.  grant_reg captures 0 (pre-NBA empty).
//   Cycle N+1 : Entries visible.  Arbiter grants.  grant_reg captures.
//   Cycle N+2 : grant_reg applied.  Entries cleared.
//
// Minimum entry lifetime: 2 cycles.
//
// FEATURES
// --------
//   - Multi-port input (one per source, up to NUM_SRCS simultaneous)
//   - Self-request rejection per port (source index == destination)
//   - Auto-expiration at MAX_AGE (prevents starvation deadlock)
//   - Overflow advisory only (does not block insertion)
//   - Granted packet output (registered, captures data before clearing)
//   - Expired entry output (registered, single-cycle pulse)
//============================================================================

module request_manager_top #(
    parameter int TABLE_SIZE = 8,
    parameter int REQ_WIDTH  = 16,
    parameter int SRC_WIDTH  = 2,
    parameter int DST_WIDTH  = 2,
    parameter int DATA_WIDTH = 9,
    parameter int AGE_WIDTH  = 3,
    parameter int MAX_AGE    = 7,

    // Derived — do not override
    parameter int NUM_SRCS   = 1 << SRC_WIDTH
) (
    input  logic                           clock,
    input  logic                           reset,

    // ---- Multi-port request input (one port per source) ----
    // Port index s corresponds to source s (source is implicit).
    input  logic [NUM_SRCS-1:0]            new_req_valid,
    input  logic [DST_WIDTH-1:0]           new_req_dest   [NUM_SRCS-1:0],
    input  logic [DATA_WIDTH-1:0]          new_req_data   [NUM_SRCS-1:0],
    output logic [NUM_SRCS-1:0]            new_req_ready,

    // ---- Request table output to arbiter ----
    output logic [TABLE_SIZE-1:0]          req_table_valid,
    output logic [SRC_WIDTH-1:0]           req_table_source [TABLE_SIZE-1:0],
    output logic [DST_WIDTH-1:0]           req_table_dest   [TABLE_SIZE-1:0],
    output logic [DATA_WIDTH-1:0]          req_table_data   [TABLE_SIZE-1:0],
    output logic [AGE_WIDTH-1:0]           req_table_age    [TABLE_SIZE-1:0],

    // ---- Grant signals from arbiter (combinational) ----
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
    output logic                            age_overflow
);

    // ----------------------------------------------------------------
    // Internal storage
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0]      valid_reg;
    logic [SRC_WIDTH-1:0]       source_reg  [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]       dest_reg    [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]      data_reg    [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]       age_reg     [TABLE_SIZE-1:0];
    logic [TABLE_SIZE-1:0]      grant_reg;

    // ----------------------------------------------------------------
    // Combinational signals
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0]      age_maxed;
    logic [TABLE_SIZE-1:0]      free_slots;
    logic [$clog2(TABLE_SIZE+1)-1:0] active_count;
    logic                       overflow_condition;

    // Per-source insertion signals
    logic [NUM_SRCS-1:0]                    self_request;
    logic [NUM_SRCS-1:0]                    can_insert;
    logic [$clog2(TABLE_SIZE)-1:0]          insert_index [NUM_SRCS-1:0];

    // ---- Table outputs ----
    assign req_table_valid  = valid_reg;
    assign req_table_source = source_reg;
    assign req_table_dest   = dest_reg;
    assign req_table_data   = data_reg;
    assign req_table_age    = age_reg;
    assign num_active_reqs  = active_count;
    assign table_full       = (active_count == TABLE_SIZE[$clog2(TABLE_SIZE+1)-1:0]);

    // ---- Detect overflow (advisory) ----
    always_comb begin
        overflow_condition = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            age_maxed[i] = valid_reg[i] && (age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]);
            if (age_maxed[i])
                overflow_condition = 1'b1;
        end
    end

    assign age_overflow = overflow_condition;

    // ---- Free slots: invalid, granted (prev cycle), or expired ----
    always_comb begin
        for (int i = 0; i < TABLE_SIZE; i++)
            free_slots[i] = ~valid_reg[i] || grant_reg[i] || age_maxed[i];
    end

    // ----------------------------------------------------------------
    // Cascaded multi-slot allocator with inline self-request detection
    //
    // For each source port in order (0, 1, 2, 3), check for self-request,
    // then find the lowest free slot not yet claimed by a lower-numbered
    // source.
    // ----------------------------------------------------------------
    logic [TABLE_SIZE-1:0] available;

    always_comb begin
        available = free_slots;

        for (int s = 0; s < NUM_SRCS; s++) begin
            self_request[s] = (DST_WIDTH'(s) == new_req_dest[s]);
            insert_index[s] = '0;
            can_insert[s]   = 1'b0;

            if (new_req_valid[s] && !self_request[s]) begin
                for (int i = 0; i < TABLE_SIZE; i++) begin
                    if (available[i] && !can_insert[s]) begin
                        insert_index[s] = i[$clog2(TABLE_SIZE)-1:0];
                        can_insert[s]   = 1'b1;
                        available[i]    = 1'b0;
                    end
                end
            end
        end
    end

    // ---- Per-source ready ----
    assign new_req_ready = can_insert;

    // ---- Count active requests ----
    always_comb begin
        active_count = '0;
        for (int i = 0; i < TABLE_SIZE; i++)
            if (valid_reg[i])
                active_count = active_count + 1'b1;
    end

    // ----------------------------------------------------------------
    // Main state update
    // ----------------------------------------------------------------
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            valid_reg     <= '0;
            grant_reg     <= '0;
            granted_valid <= '0;
            expired_valid <= '0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                source_reg[i]     <= '0;
                dest_reg[i]       <= '0;
                data_reg[i]       <= '0;
                age_reg[i]        <= '0;
                granted_source[i] <= '0;
                granted_dest[i]   <= '0;
                granted_data[i]   <= '0;
            end
        end else begin

            // ---- Capture combinational grant for use next cycle ----
            grant_reg <= grant_vector;

            // ---- Clear single-cycle output pulses ----
            granted_valid <= '0;
            expired_valid <= '0;

            for (int i = 0; i < TABLE_SIZE; i++) begin

                // ---- Step 1: Clear granted entries ----
                if (grant_reg[i] && valid_reg[i]) begin
                    valid_reg[i] <= 1'b0;
                    age_reg[i]   <= '0;
                    granted_valid[i]  <= 1'b1;
                    granted_source[i] <= source_reg[i];
                    granted_dest[i]   <= dest_reg[i];
                    granted_data[i]   <= data_reg[i];

                // ---- Step 2: Expire entries at MAX_AGE ----
                end else if (valid_reg[i] && age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]) begin
                    valid_reg[i]     <= 1'b0;
                    age_reg[i]       <= '0;
                    expired_valid[i] <= 1'b1;

                // ---- Step 3: Age active entries ----
                end else if (valid_reg[i]) begin
                    age_reg[i] <= age_reg[i] + 1'b1;
                end

                // ---- Step 4: Insert new requests (all sources) ----
                // Separate 'if' so it can override Step 1/2 (last NBA wins).
                for (int s = 0; s < NUM_SRCS; s++) begin
                    if (can_insert[s] &&
                        (insert_index[s] == i[$clog2(TABLE_SIZE)-1:0])) begin
                        valid_reg[i]  <= 1'b1;
                        source_reg[i] <= s[SRC_WIDTH-1:0];
                        dest_reg[i]   <= new_req_dest[s];
                        data_reg[i]   <= new_req_data[s];
                        age_reg[i]    <= '0;
                    end
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
                    assert (source_reg[i] != dest_reg[i])
                        else $error("Self-request at index %0d (src=%0d)",
                                    i, source_reg[i]);
                end
            end
        end
    end
    // synthesis translate_on

endmodule
