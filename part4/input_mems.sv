module input_mems #(
	parameter INW = 24,	  //the num of bits for each data word
	parameter R = 9,	 // the num of rows in the X matrix
	parameter C = 8,     // the num of columns in the X matrix
	parameter MAXK = 4,	 // max value of K that the hardware can support, where K represents num of rows and columns of weight matrix.
	localparam K_BITS = $clog2(MAXK+1),	  //num of bits necessary for K
	localparam X_ADDR_BITS = $clog2(R*C), //row major order receiving data
	localparam W_ADDR_BITS = $clog2(MAXK*MAXK)	 //similarly like above
)(
	input clk, reset,
	input [INW-1:0] AXIS_TDATA,
	input AXIS_TVALID,
	input [K_BITS:0] AXIS_TUSER,
	output logic AXIS_TREADY,  
	
	output logic inputs_loaded,	//this is asserted when the module's internal memories hold complete X and W matrices and values of K and B.
	input compute_finished,	  //when asserted on pos clk edge, inputs_loaded is set to 0
	
	output logic [K_BITS-1:0] K,  //K val of weight matrix currently stored in memory, When inputs_loaded is 1, K should be a valid value within 2<=K<=MaxK
	output logic signed [INW-1:0] B,   //holds bias value. we need to check its correct and valid when inputs_loaded is 1.
	
	input [X_ADDR_BITS-1:0] X_read_addr,  //only when the module is in inputs_loaded state, then X_data = mem[X_read_addr].
	output logic signed [INW-1:0] X_data,
	input [W_ADDR_BITS-1:0] W_read_addr,  //only when the module is in inputs_loaded state, then W_data = mem[W_read_addr].
	output logic signed [INW-1:0] W_data
);	  

  	logic [K_BITS-1:0] TUSER_K;	  //directly drives K_reg.
	logic new_W;
	assign new_W   = AXIS_TUSER[0];
    assign TUSER_K = AXIS_TUSER[K_BITS:1];
	
	logic data_valid;
    assign data_valid = AXIS_TVALID & AXIS_TREADY;
	
	
	logic [K_BITS-1:0] K_reg;	//to store valid K value.
	logic signed [INW-1:0] B_reg; //reg that holds value of B. directly drives output port B.  
	
	assign K = K_reg; 
	assign B = B_reg;	
	
	
	//define STATES
	typedef enum logic [2:0] {IDLE, LOAD_W, LOAD_B, LOAD_X, LOADED} state_t;
    state_t state, nstate;
		
		
	
	
	
	logic [X_ADDR_BITS-1 : 0] X_wr_addr;
	logic [W_ADDR_BITS-1 : 0] W_wr_addr; 
	logic [W_ADDR_BITS:0]   w_limit;   // to tell us how many w-matrix values we have to store before changing states.
	
	logic [X_ADDR_BITS-1:0] x_addr_mux;	  //the output of the mux that decides which addr to use.
    logic [W_ADDR_BITS-1:0] w_addr_mux;
    logic [INW-1:0] x_mem_out, w_mem_out; 
	
	logic X_wr_en, W_wr_en;	  

    memory #(.WIDTH(INW), .SIZE(R*C)) X_matrix_mem (
        .data_in (AXIS_TDATA),
        .data_out(x_mem_out),
        .addr    (x_addr_mux),
        .clk     (clk),
        .wr_en   (X_wr_en)
    );

    memory #(.WIDTH(INW), .SIZE(MAXK*MAXK)) W_matrix_mem (
        .data_in (AXIS_TDATA),
        .data_out(w_mem_out),
        .addr    (w_addr_mux),
        .clk     (clk),
        .wr_en   (W_wr_en)
    );

    always_comb begin
        X_data = $signed(x_mem_out);
        W_data = $signed(w_mem_out);
    end
	
	
	
	
	//the addr for the memory modules depend on the inputs_loaded signal
	
    always_comb begin
        if (inputs_loaded) begin
            x_addr_mux = X_read_addr;	   	 //this is for the reading the stored memory
            w_addr_mux = W_read_addr;
        end else begin
            //if its the first valid data (aka S_IDLE) then use address 0
            if (state == IDLE) begin
			    x_addr_mux = '0;
			    w_addr_mux = '0;
			end else begin
			    x_addr_mux = X_wr_addr;
			    w_addr_mux = W_wr_addr;
			end
        end
    end
	
	
	
	//logic to enable the write signals for memory.
	always_comb begin	   
		W_wr_en = ((state == LOAD_W) && data_valid) || ((state == IDLE) && data_valid && new_W); 
		X_wr_en = ((state == LOAD_X) && data_valid) || ((state == IDLE) && data_valid && !new_W);
    end
	
	
	
	
	
	//next-state logic
	always_comb begin
	    nstate = state;  // dafault, stay in current state
	    
	    case (state)
	        IDLE: begin
	            if (data_valid) begin
	                if (new_W)
	                    nstate = LOAD_W;
	                else
	                    nstate = LOAD_X;
	            end
	        end
	        
	        LOAD_W: begin	
	            if ( (W_wr_en && (W_wr_addr == w_limit-1)))
	                nstate = LOAD_B;
	        end
	        
	        LOAD_B: begin
	            if (data_valid)
	                nstate = LOAD_X;
	        end
	        
	        LOAD_X: begin
	            if (X_wr_en && (X_wr_addr == (R*C-1)))
	                nstate = LOADED;
	        end
	        
	        LOADED: begin
	            if (compute_finished)
	                nstate = IDLE;
	        end
	        
	        default: begin
	            nstate = IDLE;
	        end
	    endcase
	end


	
	
		 

	
	always_comb begin
	    if (state == LOADED)
	        AXIS_TREADY = 1'b0;
	    else
	        AXIS_TREADY = 1'b1;
	end

	
	//Current STATE logic
	always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= IDLE;
            inputs_loaded <= 1'b0;
            K_reg         <= '0;
            B_reg         <= '0;
            W_wr_addr     <= '0;
            X_wr_addr     <= '0;
            w_limit       <= '0;
        end else begin
            state <= nstate;

            if (state == IDLE && data_valid) begin
                inputs_loaded <= 1'b0;

                if (new_W) begin
                    K_reg     <= TUSER_K;
                    w_limit   <= (W_ADDR_BITS+1)'(TUSER_K) * (W_ADDR_BITS+1)'(TUSER_K);	 //extend the bits to accomodate (tuser_K*tuser_K) values
                    //first W value already written to addr 0, so next write goes to addr 1
                    W_wr_addr <= 1;
                    X_wr_addr <= '0;
                end else begin

                    //first X value already written to addr 0, so next write goes to addr 1
                    X_wr_addr <= 1;
                    W_wr_addr <= '0;
                end
            end

            else begin
                if (W_wr_en) W_wr_addr <= W_wr_addr + 1'b1;	  //this is the increment for the next write addr
                if (X_wr_en) X_wr_addr <= X_wr_addr + 1'b1;
            end


            if (state == LOAD_B && data_valid) begin		//load exactly one data value for B.
                B_reg <= $signed(AXIS_TDATA);
            end


            if (X_wr_en && (X_wr_addr == (R*C-1))) begin	//on the last value of x-matrix
                inputs_loaded <= 1'b1;
            end
            

            if (compute_finished) begin
                inputs_loaded <= 1'b0;
            end
        end
    end
	
endmodule