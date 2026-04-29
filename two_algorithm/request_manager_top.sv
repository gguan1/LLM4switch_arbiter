//============================================================================
// Request Manager Top Module (Vivado-safe: all ports are packed vectors)
//
// Manages a table of active requests and interfaces with a purely
// combinational age-based arbiter.
//
// CHANGES FROM ORIGINAL
// ---------------------
// All unpacked-array ports have been flattened into packed vectors to
// avoid Vivado elaboration crashes.  Internal logic is unchanged.
//
// Packing convention:
//   Element i of width W occupies flat_vector[i*W +: W]
//============================================================================

module request_manager_top #(
    parameter TABLE_SIZE = 8,
    parameter REQ_WIDTH  = 16,
    parameter SRC_WIDTH  = 2,
    parameter DST_WIDTH  = 2,
    parameter DATA_WIDTH = 9,
    parameter AGE_WIDTH  = 3,
    parameter MAX_AGE    = 7,
    parameter NUM_SRCS   = 1 << SRC_WIDTH
) (
    input  wire                                    clock,
    input  wire                                    reset,

    // ---- Multi-port request input (one port per source) ----
    input  wire  [NUM_SRCS-1:0]                    new_req_valid,
    input  wire  [NUM_SRCS*DST_WIDTH-1:0]          new_req_dest_flat,
    input  wire  [NUM_SRCS*DATA_WIDTH-1:0]         new_req_data_flat,
    output wire  [NUM_SRCS-1:0]                    new_req_ready,

    // ---- Request table output to arbiter ----
    output wire  [TABLE_SIZE-1:0]                  req_table_valid,
    output wire  [TABLE_SIZE*SRC_WIDTH-1:0]        req_table_source_flat,
    output wire  [TABLE_SIZE*DST_WIDTH-1:0]        req_table_dest_flat,
    output wire  [TABLE_SIZE*DATA_WIDTH-1:0]       req_table_data_flat,
    output wire  [TABLE_SIZE*AGE_WIDTH-1:0]        req_table_age_flat,

    // ---- Grant signals from arbiter (combinational) ----
    input  wire  [TABLE_SIZE-1:0]                  grant_vector,

    // ---- Granted packet outputs (registered) ----
    output wire  [TABLE_SIZE-1:0]                  granted_valid,
    output wire  [TABLE_SIZE*SRC_WIDTH-1:0]        granted_source_flat,
    output wire  [TABLE_SIZE*DST_WIDTH-1:0]        granted_dest_flat,
    output wire  [TABLE_SIZE*DATA_WIDTH-1:0]       granted_data_flat,

    // ---- Expired entry outputs (registered) ----
    output wire  [TABLE_SIZE-1:0]                  expired_valid,

    // ---- Status outputs ----
    output wire  [$clog2(TABLE_SIZE+1)-1:0]        num_active_reqs,
    output wire                                    table_full,
    output wire                                    age_overflow
);

    // ================================================================
    // Unpack flat input ports into local arrays
    // ================================================================
    reg [DST_WIDTH-1:0]   new_req_dest  [0:NUM_SRCS-1];
    reg [DATA_WIDTH-1:0]  new_req_data  [0:NUM_SRCS-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_SRCS; gi = gi + 1) begin : unpack_inputs
            always @(*) begin
                new_req_dest[gi] = new_req_dest_flat[gi*DST_WIDTH  +: DST_WIDTH];
                new_req_data[gi] = new_req_data_flat[gi*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate

    // ================================================================
    // Internal storage
    // ================================================================
    reg [TABLE_SIZE-1:0]      valid_reg;
    reg [SRC_WIDTH-1:0]       source_reg  [0:TABLE_SIZE-1];
    reg [DST_WIDTH-1:0]       dest_reg    [0:TABLE_SIZE-1];
    reg [DATA_WIDTH-1:0]      data_reg    [0:TABLE_SIZE-1];
    reg [AGE_WIDTH-1:0]       age_reg     [0:TABLE_SIZE-1];
    reg [TABLE_SIZE-1:0]      grant_reg;

    reg [TABLE_SIZE-1:0]      granted_valid_reg;
    reg [SRC_WIDTH-1:0]       granted_source_reg [0:TABLE_SIZE-1];
    reg [DST_WIDTH-1:0]       granted_dest_reg   [0:TABLE_SIZE-1];
    reg [DATA_WIDTH-1:0]      granted_data_reg   [0:TABLE_SIZE-1];
    reg [TABLE_SIZE-1:0]      expired_valid_reg;

    // ================================================================
    // Pack internal arrays into flat output ports
    // ================================================================
    assign req_table_valid = valid_reg;
    assign granted_valid   = granted_valid_reg;
    assign expired_valid   = expired_valid_reg;

    generate
        for (gi = 0; gi < TABLE_SIZE; gi = gi + 1) begin : pack_outputs
            assign req_table_source_flat[gi*SRC_WIDTH  +: SRC_WIDTH]  = source_reg[gi];
            assign req_table_dest_flat  [gi*DST_WIDTH  +: DST_WIDTH]  = dest_reg[gi];
            assign req_table_data_flat  [gi*DATA_WIDTH +: DATA_WIDTH] = data_reg[gi];
            assign req_table_age_flat   [gi*AGE_WIDTH  +: AGE_WIDTH]  = age_reg[gi];
            assign granted_source_flat  [gi*SRC_WIDTH  +: SRC_WIDTH]  = granted_source_reg[gi];
            assign granted_dest_flat    [gi*DST_WIDTH  +: DST_WIDTH]  = granted_dest_reg[gi];
            assign granted_data_flat    [gi*DATA_WIDTH +: DATA_WIDTH] = granted_data_reg[gi];
        end
    endgenerate

    // ================================================================
    // Combinational signals
    // ================================================================
    reg [TABLE_SIZE-1:0]              age_maxed;
    reg [TABLE_SIZE-1:0]              free_slots;
    reg [$clog2(TABLE_SIZE+1)-1:0]    active_count;
    reg                               overflow_condition;

    // Per-source insertion signals
    reg [NUM_SRCS-1:0]                self_request;
    reg [NUM_SRCS-1:0]                can_insert;
    reg [$clog2(TABLE_SIZE)-1:0]      insert_index [0:NUM_SRCS-1];

    assign num_active_reqs = active_count;
    assign table_full      = (active_count == TABLE_SIZE[$clog2(TABLE_SIZE+1)-1:0]);

    // ---- Detect overflow (advisory) ----
    always @(*) begin : blk_overflow
        integer i;
        overflow_condition = 1'b0;
        for (i = 0; i < TABLE_SIZE; i = i + 1) begin
            age_maxed[i] = valid_reg[i] && (age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]);
            if (age_maxed[i])
                overflow_condition = 1'b1;
        end
    end

    assign age_overflow = overflow_condition;

    // ---- Free slots: invalid, granted (prev cycle), or expired ----
    always @(*) begin : blk_free
        integer i;
        for (i = 0; i < TABLE_SIZE; i = i + 1)
            free_slots[i] = ~valid_reg[i] | grant_reg[i] | age_maxed[i];
    end

    // ================================================================
    // Cascaded multi-slot allocator with inline self-request detection
    // ================================================================
    reg [TABLE_SIZE-1:0] available;

    always @(*) begin : blk_alloc
        integer s, i;
        available = free_slots;

        for (s = 0; s < NUM_SRCS; s = s + 1) begin
            self_request[s] = (new_req_dest[s] == s[DST_WIDTH-1:0]);
            insert_index[s] = {$clog2(TABLE_SIZE){1'b0}};
            can_insert[s]   = 1'b0;

            if (new_req_valid[s] && !self_request[s]) begin
                for (i = 0; i < TABLE_SIZE; i = i + 1) begin
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
    always @(*) begin : blk_count
        integer i;
        active_count = {($clog2(TABLE_SIZE+1)){1'b0}};
        for (i = 0; i < TABLE_SIZE; i = i + 1)
            if (valid_reg[i])
                active_count = active_count + 1'b1;
    end

    // ================================================================
    // Main state update
    // ================================================================
    always @(posedge clock or posedge reset) begin : blk_update
        integer i, s;
        if (reset) begin
            valid_reg         <= {TABLE_SIZE{1'b0}};
            grant_reg         <= {TABLE_SIZE{1'b0}};
            granted_valid_reg <= {TABLE_SIZE{1'b0}};
            expired_valid_reg <= {TABLE_SIZE{1'b0}};
            for (i = 0; i < TABLE_SIZE; i = i + 1) begin
                source_reg[i]         <= {SRC_WIDTH{1'b0}};
                dest_reg[i]           <= {DST_WIDTH{1'b0}};
                data_reg[i]           <= {DATA_WIDTH{1'b0}};
                age_reg[i]            <= {AGE_WIDTH{1'b0}};
                granted_source_reg[i] <= {SRC_WIDTH{1'b0}};
                granted_dest_reg[i]   <= {DST_WIDTH{1'b0}};
                granted_data_reg[i]   <= {DATA_WIDTH{1'b0}};
            end
        end else begin

            // ---- Capture combinational grant for use next cycle ----
            grant_reg <= grant_vector;

            // ---- Clear single-cycle output pulses ----
            granted_valid_reg <= {TABLE_SIZE{1'b0}};
            expired_valid_reg <= {TABLE_SIZE{1'b0}};

            for (i = 0; i < TABLE_SIZE; i = i + 1) begin

                // ---- Step 1: Clear granted entries ----
                if (grant_reg[i] && valid_reg[i]) begin
                    valid_reg[i] <= 1'b0;
                    age_reg[i]   <= {AGE_WIDTH{1'b0}};
                    granted_valid_reg[i]  <= 1'b1;
                    granted_source_reg[i] <= source_reg[i];
                    granted_dest_reg[i]   <= dest_reg[i];
                    granted_data_reg[i]   <= data_reg[i];

                // ---- Step 2: Expire entries at MAX_AGE ----
                end else if (valid_reg[i] && age_reg[i] == MAX_AGE[AGE_WIDTH-1:0]) begin
                    valid_reg[i]         <= 1'b0;
                    age_reg[i]           <= {AGE_WIDTH{1'b0}};
                    expired_valid_reg[i] <= 1'b1;

                // ---- Step 3: Age active entries ----
                end else if (valid_reg[i]) begin
                    age_reg[i] <= age_reg[i] + 1'b1;
                end

                // ---- Step 4: Insert new requests (all sources) ----
                // Also clear grant_reg for this slot so a stale grant
                // from the previous occupant cannot clear the new entry.
                for (s = 0; s < NUM_SRCS; s = s + 1) begin
                    if (can_insert[s] &&
                        (insert_index[s] == i[$clog2(TABLE_SIZE)-1:0])) begin
                        valid_reg[i]  <= 1'b1;
                        source_reg[i] <= s[SRC_WIDTH-1:0];
                        dest_reg[i]   <= new_req_dest[s];
                        data_reg[i]   <= new_req_data[s];
                        age_reg[i]    <= {AGE_WIDTH{1'b0}};
                        grant_reg[i]  <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
