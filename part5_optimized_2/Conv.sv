module Conv #(
    parameter INW  = 24,
    parameter R    = 16,
    parameter C    = 17,
    parameter MAXK = 9,
    localparam OUTW = $clog2(MAXK*MAXK*(128'd1 << 2*INW-2) + (1<<(INW-1)))+1,
    localparam K_BITS = $clog2(MAXK+1)
)(
    input  logic                 clk,
    input  logic                 reset,

    //AXI-Stream input interface
    input  logic signed [INW-1:0] INPUT_TDATA,
    input  logic                  INPUT_TVALID,
    input  logic [K_BITS:0]       INPUT_TUSER,
    output logic                  INPUT_TREADY,

    //AXI-Stream output interface
    output logic signed [OUTW-1:0] OUTPUT_TDATA,
    output logic                   OUTPUT_TVALID,
    input  logic                   OUTPUT_TREADY
);
    localparam X_ADDR_BITS = $clog2(R*C);
    localparam W_ADDR_BITS = $clog2(MAXK*MAXK);

    //Internal signals
    logic                          inputs_loaded;
    logic [K_BITS-1:0]             K;
    logic signed [INW-1:0]         B;
    logic                          compute_finished;

    //Memory signals for 3 parallel banks
    logic                          tready_0, tready_1, tready_2;
    logic signed [INW-1:0]         X_data_0, X_data_1, X_data_2;
    logic signed [INW-1:0]         W_data_0, W_data_1, W_data_2;
    logic [X_ADDR_BITS-1:0]        X_addr_0, X_addr_1, X_addr_2;
    logic [W_ADDR_BITS-1:0]        W_addr_0, W_addr_1, W_addr_2;

    //All 3 memory banks must be ready to accept input
    assign INPUT_TREADY = tready_0 & tready_1 & tready_2;

    //MAC control signals
    logic                          mac_valid;
    logic [2:0]                    current_mask;
    logic                          first_product;
    
    //Delayed control signals to match pipeline
    logic                          mac_valid_delayed;
    logic                          first_product_delayed;
    logic [2:0]                    mask_delayed;

    logic signed [OUTW-1:0]        fifo_in_tdata;
    logic                          fifo_in_tvalid;
    logic                          fifo_in_tready;

    //Pipeline latency: memory read (1) + multiply (1) = 2 cycles
    localparam int MAC_LAT = 2;

    logic [$clog2(R):0] Rout;
    logic [$clog2(C):0] Cout;
    assign Rout = R - K + 1;
    assign Cout = C - K + 1;

    logic [$clog2(MAXK):0] i;  
    logic [$clog2(MAXK):0] j;  
    logic [$clog2(R):0]    r;  
    logic [$clog2(C):0]    c;
    logic [$clog2(MAC_LAT):0] pipe_cnt;

    //Pipeline registers
    logic signed [2*INW-1:0] mult_0, mult_1, mult_2;
    logic signed [OUTW-1:0]  accumulator;

    typedef enum logic [2:0] {
        WAIT_INPUTS,   
        COMPUTE,      
        DRAIN_PIPE,    
        WRITE_RESULT,  
        DONE_PULSE     
    } state_t;

    state_t state, next_state;
    
    logic inputs_dummy_1, inputs_dummy_2;
    logic ignore_wire;
    assign ignore_wire = inputs_dummy_1 ^ inputs_dummy_2;	//So the fake signals don't get optimized away

    //Input Memories - 3 instances for parallel access
    input_mems #( .INW(INW), .R(R), .C(C), .MAXK(MAXK) ) Mem0 (
        .clk(clk), 
        .reset(reset),
        .AXIS_TDATA(INPUT_TDATA), 
        .AXIS_TVALID(INPUT_TVALID), 
        .AXIS_TUSER(INPUT_TUSER), 
        .AXIS_TREADY(tready_0),
        .inputs_loaded(inputs_loaded), 
        .compute_finished(compute_finished),
        .K(K), 
        .B(B),
        .X_read_addr(X_addr_0), 
        .X_data(X_data_0),
        .W_read_addr(W_addr_0), 
        .W_data(W_data_0)
    );

    input_mems #( .INW(INW), .R(R), .C(C), .MAXK(MAXK) ) Mem1 (
        .clk(clk), 
        .reset(reset),
        .AXIS_TDATA(INPUT_TDATA), 
        .AXIS_TVALID(INPUT_TVALID), 
        .AXIS_TUSER(INPUT_TUSER), 
        .AXIS_TREADY(tready_1),
        .inputs_loaded(inputs_dummy_1), 
        .compute_finished(compute_finished),
        .K(), 
        .B(),
        .X_read_addr(X_addr_1), 
        .X_data(X_data_1),
        .W_read_addr(W_addr_1), 
        .W_data(W_data_1)
    );

    input_mems #( .INW(INW), .R(R), .C(C), .MAXK(MAXK) ) Mem2 (
        .clk(clk), 
        .reset(reset),
        .AXIS_TDATA(INPUT_TDATA), 
        .AXIS_TVALID(INPUT_TVALID), 
        .AXIS_TUSER(INPUT_TUSER), 
        .AXIS_TREADY(tready_2),
        .inputs_loaded(inputs_dummy_2), 
        .compute_finished(compute_finished),
        .K(), 
        .B(),
        .X_read_addr(X_addr_2), 
        .X_data(X_data_2),
        .W_read_addr(W_addr_2), 
        .W_data(W_data_2)
    );

    fifo_out #( .OUTW(OUTW), .DEPTH(C - 1) ) FIFO_OUT (
        .clk(clk), 
        .reset(reset),
        .IN_AXIS_TDATA(fifo_in_tdata), 
        .IN_AXIS_TVALID(fifo_in_tvalid), 
        .IN_AXIS_TREADY(fifo_in_tready),
        .OUT_AXIS_TDATA(OUTPUT_TDATA), 
        .OUT_AXIS_TVALID(OUTPUT_TVALID), 
        .OUT_AXIS_TREADY(OUTPUT_TREADY)
    );
    assign fifo_in_tdata = accumulator;

    //Address generation for 3 parallel memory accesses
    always_comb begin
        //Bank 0: position (r+i, c+j)
        X_addr_0 = (r + i) * C + (c + j);
        W_addr_0 = i * K + j;
        
        //Bank 1: position (r+i, c+j+1)
        X_addr_1 = (r + i) * C + (c + j + 1);
        W_addr_1 = i * K + (j + 1);
        
        //Bank 2: position (r+i, c+j+2)
        X_addr_2 = (r + i) * C + (c + j + 2);
        W_addr_2 = i * K + (j + 2);

        //Mask determines which of the 3 MACs are valid
        current_mask = 3'b000;
        if (mac_valid) begin
            current_mask[0] = 1;
            if (j + 1 < K) current_mask[1] = 1;
            if (j + 2 < K) current_mask[2] = 1;
        end
    end

    //Multipliers - pipelined stage
    always_ff @(posedge clk) begin
        if (reset) begin
            mult_0 <= 0;
            mult_1 <= 0;
            mult_2 <= 0;
        end else begin
            mult_0 <= X_data_0 * W_data_0;
            mult_1 <= X_data_1 * W_data_1;
            mult_2 <= X_data_2 * W_data_2;
        end
    end

    //Control signal delay pipeline
    logic [MAC_LAT-1:0] mac_valid_pipe;
    logic [MAC_LAT-1:0] first_product_pipe;
    logic [MAC_LAT-1:0][2:0] mask_pipe;

    always_ff @(posedge clk) begin
        if (reset) begin
            mac_valid_pipe <= 0;
            first_product_pipe <= 0;
            for (int k = 0; k < MAC_LAT; k++) mask_pipe[k] <= 0;
        end else begin
            mac_valid_pipe <= {mac_valid_pipe[MAC_LAT-2:0], mac_valid};
            first_product_pipe <= {first_product_pipe[MAC_LAT-2:0], first_product};
            mask_pipe <= {mask_pipe[MAC_LAT-2:0], current_mask};
        end
    end

    assign mac_valid_delayed = mac_valid_pipe[MAC_LAT-1];
    assign first_product_delayed = first_product_pipe[MAC_LAT-1];
    assign mask_delayed = mask_pipe[MAC_LAT-1];

    //Accumulator
    always_ff @(posedge clk) begin
        if (reset) begin
            accumulator <= 0;
        end else begin
            if (first_product_delayed) begin
                logic signed [2*INW-1:0] p0, p1, p2;
                p0 = mask_delayed[0] ? mult_0 : '0;
                p1 = mask_delayed[1] ? mult_1 : '0;
                p2 = mask_delayed[2] ? mult_2 : '0;
                accumulator <= B + p0 + p1 + p2;
            end else if (mac_valid_delayed) begin
                logic signed [2*INW-1:0] p0, p1, p2;
                p0 = mask_delayed[0] ? mult_0 : '0;
                p1 = mask_delayed[1] ? mult_1 : '0;
                p2 = mask_delayed[2] ? mult_2 : '0;
                accumulator <= accumulator + p0 + p1 + p2;
            end
        end
    end

    //Current state logic
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= WAIT_INPUTS;
            r <= '0; c <= '0; i <= '0; j <= '0;
            pipe_cnt <= '0;
        end else begin
            state <= next_state;

            case (state)
                WAIT_INPUTS: begin
                    r <= '0; c <= '0; i <= '0; j <= '0;
                    pipe_cnt <= '0;
                end
                
                COMPUTE: begin
                    //Increment by 3 each cycle for parallel processing
                    if (j + 3 >= K) begin
                        j <= '0;
                        if (i == K-1) i <= '0;
                        else i <= i + 1;
                    end else begin
                        j <= j + 3;
                    end
                end
                
                DRAIN_PIPE: begin
                    pipe_cnt <= pipe_cnt + 1;
                end
                
                WRITE_RESULT: begin
                    if (fifo_in_tvalid && fifo_in_tready) begin
                        pipe_cnt <= '0;
                        if (c == Cout-1) begin
                            c <= '0;
                            if (r == Rout-1) r <= '0;
                            else r <= r + 1;
                        end else begin
                            c <= c + 1;
                        end
                    end
                end
                
                default: ;
            endcase
        end
    end

    //Next state logic
    always_comb begin
        next_state = state;
        mac_valid = 1'b0;
        first_product = 1'b0;
        fifo_in_tvalid = 1'b0;
        compute_finished = 1'b0;

        case (state)
            WAIT_INPUTS: begin
                if (inputs_loaded) next_state = COMPUTE;
            end
            
            COMPUTE: begin
                mac_valid = 1'b1;
                first_product = (i == 0 && j == 0);
                if ((j + 3 >= K) && (i == K-1)) next_state = DRAIN_PIPE;
            end
            
            DRAIN_PIPE: begin
                if (pipe_cnt >= MAC_LAT) next_state = WRITE_RESULT;
            end
            
            WRITE_RESULT: begin
                fifo_in_tvalid = 1'b1;
                if (fifo_in_tvalid && fifo_in_tready) begin
                    if (r == Rout-1 && c == Cout-1) next_state = DONE_PULSE;
                    else next_state = COMPUTE;
                end
            end
            
            DONE_PULSE: begin
                compute_finished = 1'b1;
                next_state = WAIT_INPUTS;
            end
            
            default: next_state = WAIT_INPUTS;
        endcase
    end
endmodule