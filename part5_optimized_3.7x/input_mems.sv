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


logic [K_BITS-1:0] K_reg, K_reg2;	//to store valid K value.
logic signed [INW-1:0] B_reg, B_reg2; //reg that holds value of B. directly drives output port B.  


//define STATES
typedef enum logic [2:0] {IDLE, LOAD_W, LOAD_B, LOAD_X, LOADED, DONE} state_t;
state_t state, nstate;
	
	
logic [1:0] current_write, current_read; 
logic [1:0] next_write;


logic [X_ADDR_BITS-1 : 0] X_wr_addr;
logic [W_ADDR_BITS-1 : 0] W_wr_addr; 
logic [W_ADDR_BITS:0]   w_limit;   // to tell us how many w-matrix values we have to store before changing states.

logic [X_ADDR_BITS-1:0] x_addr_mux, x_addr_mux2;	  //the output of the mux that decides which addr to use.
logic [W_ADDR_BITS-1:0] w_addr_mux, w_addr_mux2;
logic [INW-1:0] x_mem_out, w_mem_out, x_mem_out2, w_mem_out2; 

logic X_wr_en, W_wr_en, X_wr_en2, W_wr_en2;	

logic inputs_loaded2, first_inputs_loaded;

logic first_data; 

logic saw_compute_finished, first_iteration;

always_comb begin  	 
	if (first_iteration) begin
		inputs_loaded = '0;
	end
	else begin
		if (saw_compute_finished) begin
			if (first_data) inputs_loaded = first_inputs_loaded;
			else inputs_loaded = inputs_loaded2;  
		end	 
		else begin
			if (first_data) inputs_loaded = first_data;
			else inputs_loaded = !first_data;
		end
	end
end


logic prev_new_W;

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

memory #(.WIDTH(INW), .SIZE(R*C)) X_matrix_mem2 (
    .data_in (AXIS_TDATA),
    .data_out(x_mem_out2),
    .addr    (x_addr_mux2),
    .clk     (clk),
    .wr_en   (X_wr_en2)
);

memory #(.WIDTH(INW), .SIZE(MAXK*MAXK)) W_matrix_mem2 (
    .data_in (AXIS_TDATA),
    .data_out(w_mem_out2),
    .addr    (w_addr_mux2),
    .clk     (clk),
    .wr_en   (W_wr_en2)
);

always_comb begin
	if(current_read[1]) begin
		W_data = $signed(w_mem_out2);
		B = B_reg2;
		K = K_reg2;
	end	
	else begin 
		W_data = $signed(w_mem_out);
		B = B_reg;
		K = K_reg;	
	end	 
	if(current_read[0]) X_data = $signed(x_mem_out2);
	else X_data = $signed(x_mem_out);
end


//the addr for the memory modules depend on the inputs_loaded signal

always_comb begin  
	//since the memory module uses one addr port, we can only assign one value and that depends on whether we are reading or writing to the memory module.
	//W1
	if (!current_read[1] && inputs_loaded) w_addr_mux = W_read_addr; 
	else if(state == IDLE) w_addr_mux ='0;
	else w_addr_mux = W_wr_addr; //this addr will be used only when the write_en of that particular memory is asserted.
		
	//X1
	if (!current_read[0] && inputs_loaded) x_addr_mux = X_read_addr;
	else if(state == IDLE) x_addr_mux ='0;
	else x_addr_mux = X_wr_addr; 
		
	//W2
	if (current_read[1] && inputs_loaded) w_addr_mux2 = W_read_addr;
	else if(state == IDLE) w_addr_mux2 ='0;
	else w_addr_mux2 = W_wr_addr;
		
	//X2
	if (current_read[0] && inputs_loaded) x_addr_mux2 = X_read_addr;
	else if(state == IDLE) x_addr_mux2 ='0;
	else x_addr_mux2 = X_wr_addr; 
end






//write enables use next_write for first cycle, current_write for rest
always_comb begin	   
    //for W: use next_write in IDLE->LOAD_W transition, current_write in LOAD_W
    if ((state == IDLE) && (nstate == LOAD_W)) begin
        W_wr_en = !next_write[1] && data_valid && new_W;
        W_wr_en2 = next_write[1] && data_valid && new_W;
    end else begin
        W_wr_en = !current_write[1] && (state == LOAD_W) && data_valid;
        W_wr_en2 = current_write[1] && (state == LOAD_W) && data_valid;
    end
    
    //for X: use next_write in IDLE->LOAD_X transition, current_write in LOAD_X
    if ((state == IDLE) && (nstate == LOAD_X)) begin
        X_wr_en = !next_write[0] && data_valid && !new_W;
        X_wr_en2 = next_write[0] && data_valid && !new_W;
    end else begin
        X_wr_en = !current_write[0] && (state == LOAD_X) && data_valid;
        X_wr_en2 = current_write[0] && (state == LOAD_X) && data_valid;
    end
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
            if ( (W_wr_en && (W_wr_addr == w_limit-1)) || (W_wr_en2 && (W_wr_addr == w_limit-1)))	  //if writing to either W matrix and you reach the last data value, change next state
                nstate = LOAD_B;
        end
        
        LOAD_B: begin
            if (data_valid)
                nstate = LOAD_X;
        end
        
        LOAD_X: begin
            if ( (X_wr_en && (X_wr_addr == (R*C-1))) ||	 (X_wr_en2 && (X_wr_addr == (R*C-1))) )	begin	//if writing to either W matrix and you reach the last data value
				//if (!first_inputs_loaded) begin  
				if (first_iteration) begin 
					nstate = IDLE; //this would execute only after writing the first set of inputs from time=0
				end	
				else nstate = LOADED;
			end
        end
        
        LOADED: begin
            if (saw_compute_finished && inputs_loaded) begin	
                nstate = IDLE; 
			end
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

always_comb begin
	next_write = current_write;  //default: keep same
    //calculate next pointer values based on current_write	  
		if ( (state ==IDLE) && (nstate == LOAD_W ) && new_W) begin	
	    	next_write = {~current_write[1], ~current_write[0]};  
		end
		else if ((state ==IDLE) && (nstate == LOAD_X) && !new_W) begin
			next_write = {current_write[1], ~current_write[0]}; 
		end
end

//Current STATE logic
always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        state         <= IDLE;	 
		first_inputs_loaded <= 1'b0;
        inputs_loaded2 <= 1'b0;
        K_reg         <= '0;
        B_reg         <= '0;
		K_reg2         <= '0;
        B_reg2         <= '0;
        W_wr_addr     <= '0;
        X_wr_addr     <= '0;
        w_limit       <= '0;
		current_write <= 2'b00;  
        current_read  <= 2'b00;  
        prev_new_W    <= 1'b0;
		first_data 	  <= '0; //
		first_iteration <= 1'b1;
		saw_compute_finished <= '0;
    end else begin
        state <= nstate;

        if (state == IDLE && data_valid) begin 
			saw_compute_finished <= '0;
            //inputs_loaded <= 1'b0;	 //inputs_loaded will technically be one always after the first set of inputs
            if (new_W) begin  
				if(!next_write[1]) K_reg <= TUSER_K;   // Use next_write, not current_write!
				else K_reg2 <= TUSER_K;
                w_limit   <= (W_ADDR_BITS+1)'(TUSER_K) * (W_ADDR_BITS+1)'(TUSER_K);	 //extend the bits to accomodate (tuser_K*tuser_K) values
                //first W value already written to addr 0, so next write goes to addr 1
                W_wr_addr <= 1;
                X_wr_addr <= '0;	
            end else begin
                //first X value already written to addr 0, so next write goes to addr 1
                X_wr_addr <= 1;
                W_wr_addr <= '0;  
            end	 
			current_write <= next_write; 
			
			prev_new_W <= new_W; //just for visual purposes during debugging
        end

        else begin
            if (W_wr_en || W_wr_en2) W_wr_addr <= W_wr_addr + 1'b1;	  //this addrs goes to both memory banks but will only be written to one because only one of their wr_en will be asserted.
            if (X_wr_en || X_wr_en2) X_wr_addr <= X_wr_addr + 1'b1;		  
        end


        if (state == LOAD_B && data_valid) begin		//load exactly one data value for B.
			if(!current_write[1]) B_reg <= $signed(AXIS_TDATA);
			if(current_write[1]) B_reg2 <= $signed(AXIS_TDATA);
        end


        if ( (X_wr_en && (X_wr_addr == (R*C-1))) || (X_wr_en2 && (X_wr_addr == (R*C-1)))) begin	//on the last value of x-matrix	
			if (first_inputs_loaded) begin	  //if the first inputs were already loaded, this would be the second inputs.
				first_inputs_loaded <= '0; 
				inputs_loaded2 <= 1'b1;	// after the first set of inputs_loaded, the last data value of the next set of inputs being written will always assert inputs_loaded2 
			end	
			else begin
				first_inputs_loaded <= 1'b1; 
				inputs_loaded2 <= '0;
				first_iteration <= '0; //this we write here because it will update only on the next clk cycle, we know that on the first inputs dataset will enter this block. this is where the first_iteration aka first dataset writing to memory is over
				if (first_iteration) begin
					first_data <= 1'b1;	 //since after reset, the initial value is 0. Only for the first iteration, we need to set this because after that, the compute_finished 'if' block will update the value.
				end
			end	  
			
        end
		
			
        if (compute_finished) begin	 			
			saw_compute_finished <= 1'b1;  	
			first_data <= ~first_data;	  //toggle so that the inputs_loaded signal will be asserted according to the memory bank that just finished computing. 
		 	//when first_data=0, aka data is being stored in the first mem bank
			//when a compute of any memory bank is complete, that means a memory bank is available to load data.
		end	 
		
		if((state==LOADED && nstate==IDLE) || (state==LOAD_X && nstate==IDLE && first_iteration)) current_read <= current_write;	//once inputs loaded, the write ptr becomes the read ptr. only change the read ptrs when the second memory bank is ready. There might be a possibility that the first bank finishes compute but the second bank is still loading because the tvalid and tready probs are low for a given test.
        
    end
end


endmodule