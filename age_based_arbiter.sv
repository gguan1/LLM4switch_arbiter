// Age-Based Switch Arbiter
// Grants access to the requester that has been waiting the longest
// Target: Basys 3 FPGA

module age_based_arbiter #(
    parameter int NUM_REQUESTERS = 4,      // Number of requesters
    parameter int AGE_WIDTH = 8            // Width of age counter (max age = 2^AGE_WIDTH - 1)
) (
    input  logic                        clock,
    input  logic                        reset,
    
    // Request interface
    input  logic [NUM_REQUESTERS-1:0]   req,        // Request signals from each requester
    output logic [NUM_REQUESTERS-1:0]   gnt,        // Grant signals to each requester
    
    // Optional: ready signal from shared resource
    input  logic                        ready       // Resource is ready to accept new request
);

    // Age counters for each requester
    logic [AGE_WIDTH-1:0] age [NUM_REQUESTERS-1:0];
    
    // Index of the oldest (highest age) requester
    logic [$clog2(NUM_REQUESTERS)-1:0] oldest_idx;
    logic [AGE_WIDTH-1:0] max_age;
    
    // Grant logic state
    logic grant_valid;
    
    //========================================================================
    // Age Counter Management
    //========================================================================
    // Increment age for active requests that are not being granted
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            for (int i = 0; i < NUM_REQUESTERS; i++) begin
                age[i] <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_REQUESTERS; i++) begin
                if (req[i]) begin
                    // If this requester is granted and resource is ready, reset age
                    if (gnt[i] && ready) begin
                        age[i] <= '0;
                    end 
                    // Otherwise, increment age (with saturation)
                    else if (age[i] != {AGE_WIDTH{1'b1}}) begin
                        age[i] <= age[i] + 1'b1;
                    end
                end else begin
                    // Request is not active, reset age
                    age[i] <= '0;
                end
            end
        end
    end
    
    //========================================================================
    // Find Oldest Requester (Combinational Priority Logic)
    //========================================================================
    // Find the requester with the maximum age among active requests
    always_comb begin
        max_age = '0;
        oldest_idx = '0;
        grant_valid = 1'b0;
        
        // Search for the oldest active request
        // Grant to first valid request found, then only update if strictly older
        for (int i = 0; i < NUM_REQUESTERS; i++) begin
            if (req[i]) begin
                // Grant to first request, or if this request is strictly older
                if (!grant_valid || age[i] > max_age) begin
                    max_age = age[i];
                    oldest_idx = i[$clog2(NUM_REQUESTERS)-1:0];
                    grant_valid = 1'b1;
                end
            end
        end
    end
    
    //========================================================================
    // Grant Generation
    //========================================================================
    // Generate one-hot grant signal
    always_comb begin
        gnt = '0;
        if (grant_valid) begin
            gnt[oldest_idx] = 1'b1;
        end
    end

endmodule
