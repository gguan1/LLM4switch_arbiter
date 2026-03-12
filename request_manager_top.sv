// Request Manager Top Module
// Manages a table of active requests and interfaces with an arbiter

module request_manager_top #(
    parameter int TABLE_SIZE = 8,      // Number of request table entries
    parameter int REQ_WIDTH = 16,      // Request width (source:2, dest:3)
    parameter int SRC_WIDTH = 2,       // Source field width
    parameter int DST_WIDTH = 2,       // Destination field width
    parameter int DATA_WIDTH = 9,      // Data field width
    parameter int AGE_WIDTH = 3,       // Age field width
    parameter int MAX_AGE = 7          // Maximum age threshold (congestion indicator)
) (
    input  logic                           clock,
    input  logic                           reset,
    
    // New request input interface
    input  logic                           new_req_valid,
    input  logic [SRC_WIDTH-1:0]           new_req_source,
    input  logic [DST_WIDTH-1:0]           new_req_dest,
    input  logic [DATA_WIDTH-1:0]          new_req_data,
    output logic                           new_req_ready,
    
    // Request table output to arbiter
    output logic [TABLE_SIZE-1:0]          req_table_valid,
    output logic [SRC_WIDTH-1:0]           req_table_source [TABLE_SIZE-1:0],
    output logic [DST_WIDTH-1:0]           req_table_dest   [TABLE_SIZE-1:0],
    output logic [DATA_WIDTH-1:0]          req_table_data   [TABLE_SIZE-1:0],
    output logic [AGE_WIDTH-1:0]           req_table_age    [TABLE_SIZE-1:0],
    
    // Grant signals from arbiter
    input  logic [TABLE_SIZE-1:0]          grant_vector,
    
    // Status outputs
    output logic [$clog2(TABLE_SIZE+1)-1:0] num_active_reqs,
    output logic                            table_full,
    output logic                            age_overflow    // Congestion flag: any request reached MAX_AGE
);

    // Internal request table storage
    logic [TABLE_SIZE-1:0]      valid_reg;
    logic [SRC_WIDTH-1:0]       source_reg [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]       dest_reg   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]      data_reg   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]       age_reg    [TABLE_SIZE-1:0];
    
    // Internal signals
    logic [TABLE_SIZE-1:0]      age_maxed;
    logic [TABLE_SIZE-1:0]      free_slots;
    logic [$clog2(TABLE_SIZE)-1:0] insert_index;
    logic                       can_insert;
    logic [$clog2(TABLE_SIZE+1)-1:0] active_count;
    logic                       overflow_condition;
    
    // Assign outputs
    assign req_table_valid  = valid_reg;
    assign req_table_source = source_reg;
    assign req_table_dest   = dest_reg;
    assign req_table_data   = data_reg;
    assign req_table_age    = age_reg;
    assign num_active_reqs  = active_count;
    assign table_full       = (active_count == TABLE_SIZE);
    
    // Detect age overflow condition (any request at MAX_AGE)
    always_comb begin
        overflow_condition = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            age_maxed[i] = valid_reg[i] && (age_reg[i] == MAX_AGE);
            if (age_maxed[i]) begin
                overflow_condition = 1'b1;
            end
        end
    end
    
    assign age_overflow = overflow_condition;
    
    // Find free slots (only from invalid entries or grants - NO expiration)
    always_comb begin
        for (int i = 0; i < TABLE_SIZE; i++) begin
            free_slots[i] = ~valid_reg[i] || grant_vector[i];
        end
    end
    
    // Priority encoder to find first free slot
    always_comb begin
        insert_index = '0;
        can_insert = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (free_slots[i] && !can_insert) begin
                insert_index = i[$clog2(TABLE_SIZE)-1:0];
                can_insert = 1'b1;
            end
        end
    end
    
    // Ready signal - can accept new request if there's a free slot AND no overflow
    assign new_req_ready = can_insert && !overflow_condition;
    
    // Count active requests
    always_comb begin
        active_count = '0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (valid_reg[i]) begin
                active_count = active_count + 1'b1;
            end
        end
    end
    
    // Main state update logic
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            valid_reg <= '0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                source_reg[i] <= '0;
                dest_reg[i]   <= '0;
                data_reg[i]   <= '0;
                age_reg[i]    <= '0;
            end
        end else begin
            // Process each table entry
            for (int i = 0; i < TABLE_SIZE; i++) begin
                // Step 1: Remove granted requests
                if (grant_vector[i]) begin
                    valid_reg[i] <= 1'b0;
                    age_reg[i]   <= '0;
                // Step 2: Update age for active, non-granted requests (saturate at MAX_AGE)
                end else if (valid_reg[i] && (age_reg[i] < MAX_AGE)) begin
                    age_reg[i] <= age_reg[i] + 1'b1;
                end
                // Age saturates at MAX_AGE - no further increment
                
                // Step 3: Insert new request if this is the selected slot
                if ((grant_vector[i] || ~valid_reg[i]) && 
                    new_req_valid && can_insert && !overflow_condition && (i == insert_index)) begin
                    valid_reg[i]  <= 1'b1;
                    source_reg[i] <= new_req_source;
                    dest_reg[i]   <= new_req_dest;
                    data_reg[i]   <= new_req_data;
                    age_reg[i]    <= '0;
                end
            end
        end
    end

    // Assertions for verification
    // synthesis translate_off
    always_ff @(posedge clock) begin
        if (!reset) begin
            // Check age doesn't exceed maximum
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (valid_reg[i]) begin
                    assert (age_reg[i] <= MAX_AGE) 
                        else $error("Age exceeded maximum at index %0d", i);
                end
            end
        end
    end
    // synthesis translate_on

endmodule
