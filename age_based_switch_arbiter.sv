// Age-Based Crossbar Switch Arbiter
// Each input port can request any output port(s)
// Age-based arbitration resolves conflicts when multiple inputs want the same output
// Target: Basys 3 FPGA

module age_based_switch_arbiter #(
    parameter int NUM_PORTS = 4,           // Number of input/output ports
    parameter int AGE_WIDTH = 8            // Width of age counter (max age = 2^AGE_WIDTH - 1)
) (
    input  logic                        clock,
    input  logic                        reset,
    
    // Request interface: request[input_port][output_port]
    // request[i][j] = 1 means input port i requests output port j
    input  logic [NUM_PORTS-1:0][NUM_PORTS-1:0]   request,
    
    // Grant interface: grant[input_port][output_port]
    // grant[i][j] = 1 means input port i is granted access to output port j
    output logic [NUM_PORTS-1:0][NUM_PORTS-1:0]   grant,
    
    // Optional: ready signal from each output port
    input  logic [NUM_PORTS-1:0]                  ready
);

    // Age counters for each input port
    logic [AGE_WIDTH-1:0] age [NUM_PORTS-1:0];
    
    // Internal signals for arbitration
    logic [NUM_PORTS-1:0] input_has_request;  // Which inputs have any request active
    logic [NUM_PORTS-1:0] input_fully_served; // Which inputs had ALL requests granted and ready
    
    // Debug: track per-input if they're being served this cycle
    logic [NUM_PORTS-1:0] input_has_any_grant;           // Has at least one grant
    logic [NUM_PORTS-1:0] input_has_ungranted_request;   // Has at least one ungranted/unready request
    
    //========================================================================
    // Age Counter Management
    //========================================================================
    // Compute service status for each input (combinational)
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            // Does this input have any request?
            input_has_request[i] = |request[i];
            
            // Does this input have any grant?
            input_has_any_grant[i] = |grant[i];
            
            // Check if this input has any UNGRANTED or NOT-READY request
            input_has_ungranted_request[i] = 1'b0;
            for (int j = 0; j < NUM_PORTS; j++) begin
                // If we requested this output but didn't get it (or it's not ready)
                if (request[i][j] && !(grant[i][j] && ready[j])) begin
                    input_has_ungranted_request[i] = 1'b1;
                end
            end
            
            // Fully served = has requests AND no ungranted requests
            input_fully_served[i] = input_has_request[i] && !input_has_ungranted_request[i];
        end
    end
    
    // Age tracks waiting time for requests not fully serviced
    // Age resets only when grant is given AND output is ready
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                age[i] <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (input_has_ungranted_request[i]) begin
                    // Has at least one ungranted or not-ready request - increment age
                    if (age[i] != {AGE_WIDTH{1'b1}}) begin
                        age[i] <= age[i] + 1'b1;
                    end
                end else begin
                    // No ungranted requests (all granted AND ready) or no requests - reset age
                    age[i] <= '0;
                end
            end
        end
    end
    
    //========================================================================
    // Arbitration Logic - Per Output Port
    //========================================================================
    // For each output port, arbitrate among all inputs requesting it
    always_comb begin
        // Initialize all grants to zero
        grant = '0;
        
        // For each output port
        for (int out_port = 0; out_port < NUM_PORTS; out_port++) begin
            logic grant_valid;
            logic [$clog2(NUM_PORTS)-1:0] winner_input;
            logic [AGE_WIDTH-1:0] max_age_for_output;
            
            grant_valid = 1'b0;
            winner_input = '0;
            max_age_for_output = '0;
            
            // Find the oldest input requesting this output port
            for (int in_port = 0; in_port < NUM_PORTS; in_port++) begin
                if (request[in_port][out_port]) begin
                    // Grant to first requester, or if this requester is strictly older
                    if (!grant_valid || age[in_port] > max_age_for_output) begin
                        max_age_for_output = age[in_port];
                        winner_input = in_port[$clog2(NUM_PORTS)-1:0];
                        grant_valid = 1'b1;
                    end
                end
            end
            
            // Grant this output to the winning input
            if (grant_valid) begin
                grant[winner_input][out_port] = 1'b1;
            end
        end
    end

endmodule
