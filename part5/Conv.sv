module Conv #(
    parameter INW  = 18,
    parameter R    = 9,
    parameter C    = 8,
    parameter MAXK = 5,
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
    logic signed [INW-1:0]         X_data;
    logic signed [INW-1:0]         W_data;
    logic                          compute_finished;
    logic [X_ADDR_BITS-1:0]        X_read_addr;
    logic [W_ADDR_BITS-1:0]        W_read_addr;

    logic                          mac_init_acc;	//tells the MAC when to store bias value.
    logic                          mac_input_valid;
    logic signed [OUTW-1:0]        mac_out;

    //Delay control signals by 1 cycle to match Memory Read Latency
    logic                          mac_valid_delayed;      
    logic                          mac_init_acc_delayed;   

    logic signed [OUTW-1:0]        fifo_in_tdata;
    logic                          fifo_in_tvalid;
    logic                          fifo_in_tready; //Comes from the FIFO and tells us whether FIFO can accept values.

    //the min num of clk cycles	required to drain the mac pipeline of its contents
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
    logic first_product;

    typedef enum logic [2:0] {
        WAIT_INPUTS,   
        COMPUTE,      
        DRAIN_PIPE,    
        WRITE_RESULT    
    } state_t;

    state_t state, next_state;

    //Input Memories for X and W matrix
    input_mems #( .INW(INW), .R(R), .C(C), .MAXK(MAXK) ) Input_Mems (
		.clk(clk), 
		.reset(reset),
		.AXIS_TDATA(INPUT_TDATA), 
		.AXIS_TVALID(INPUT_TVALID), 
		.AXIS_TUSER(INPUT_TUSER), 
		.AXIS_TREADY(INPUT_TREADY),
		.inputs_loaded(inputs_loaded), 
		.compute_finished(compute_finished),
		.K(K), 
		.B(B),
		.X_read_addr(X_read_addr), 
		.X_data(X_data),
		.W_read_addr(W_read_addr), 
		.W_data(W_data)
    );

    //MAC pipelined between Multiplier and Adder
    mac_pipe #( .INW(INW), .OUTW(OUTW) ) MAC (
		.input0(X_data), 
		.input1(W_data), 
		.init_value(B), 
		.out(mac_out),
		.clk(clk), 
		.reset(reset),
        .init_acc(mac_init_acc_delayed),  //using 1-cycle delay signal
        .input_valid(mac_valid_delayed)   //using 1-cycle delay signal
    );	
	

    
    fifo_out #( .OUTW(OUTW), .DEPTH(C - 1) ) FIFO_OUT (		 //C-1 as prof specified
		.clk(clk), 
		.reset(reset),
		.IN_AXIS_TDATA(fifo_in_tdata), 
		.IN_AXIS_TVALID(fifo_in_tvalid), 
		.IN_AXIS_TREADY(fifo_in_tready),
		.OUT_AXIS_TDATA(OUTPUT_TDATA), 
		.OUT_AXIS_TVALID(OUTPUT_TVALID), 
		.OUT_AXIS_TREADY(OUTPUT_TREADY)
    );
    assign fifo_in_tdata = mac_out;


    //read addr logic for matrices
    always_comb begin
        X_read_addr = (r + i) * C + (c + j);	//we multiply with C to skip the (r+i) rows. Then we add the column offsets c and j.
        W_read_addr = i * K + j; 				//Similarly, we multiply with K to skip 'i' rows and then we add the column offset j
    end
	
	
	//current state logic
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= WAIT_INPUTS;
            r <= '0; c <= '0; i <= '0; j <= '0;
            pipe_cnt <= '0;
            first_product <= 1'b0;
            mac_valid_delayed <= 1'b0;
            mac_init_acc_delayed <= 1'b0;
        end else begin
            state <= next_state;

            //1 cycle delay
            mac_valid_delayed    <= mac_input_valid;
            mac_init_acc_delayed <= mac_init_acc;

            case (state)
                WAIT_INPUTS: begin
                    r <= '0; c <= '0; i <= '0; j <= '0;
                    pipe_cnt <= '0;
                    first_product <= 1'b1;
                end
                COMPUTE: begin			//count till every weight of current window (i.e. r and c) is calculated
                    first_product <= 1'b0;
                    if (j == K-1) begin
                        j <= '0;
                        if (i == K-1) i <= '0; //this happens when we finish the current window, we go to DRAIN_PIPE and Write_result states and come back to the Compute stage with new values of r and c, aka a new window.
                        else i <= i + 1;
                    end else begin
                        j <= j + 1;
                    end
                end
                DRAIN_PIPE: begin		 //creates delay for 3 cycles so that the FIFO is written only the when the mac is ready.
                    pipe_cnt <= pipe_cnt + 1;
                end
                WRITE_RESULT: begin
                    if (fifo_in_tvalid && fifo_in_tready) begin
                        pipe_cnt <= '0;
                        first_product <= 1'b1;		   //resetting the variables for next window
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
	
	
	//next state logic
    always_comb begin
        next_state = state;
        mac_init_acc = 1'b0;
        mac_input_valid = 1'b0;
        fifo_in_tvalid = 1'b0;
        compute_finished = 1'b0;

        case (state)
            WAIT_INPUTS: begin
                if (inputs_loaded) next_state = COMPUTE;
            end
            COMPUTE: begin
                if (first_product) mac_init_acc = 1'b1;	   //for the accumulator to store the bias value
                mac_input_valid = 1'b1;
                if (i == K-1 && j == K-1) next_state = DRAIN_PIPE;
            end
            DRAIN_PIPE: begin
                if (pipe_cnt >= MAC_LAT) next_state = WRITE_RESULT;
            end
            WRITE_RESULT: begin
                fifo_in_tvalid = 1'b1;
                if (fifo_in_tvalid && fifo_in_tready) begin
                    if (r == Rout-1 && c == Cout-1) begin  
						compute_finished = 1'b1;
						next_state = WAIT_INPUTS;   
					end
                    else next_state = COMPUTE;	   //go to next window for convolution.
                end
            end
            default: next_state = WAIT_INPUTS;
        endcase
    end
endmodule