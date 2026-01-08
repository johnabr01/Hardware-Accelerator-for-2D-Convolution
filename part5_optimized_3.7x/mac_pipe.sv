module mac_pipe #(parameter INW = 16, parameter OUTW = 48)(
    input signed [INW-1:0] input0, input1, init_value,
    output logic signed [OUTW-1:0] out,
    input clk, reset, init_acc, input_valid
);

logic signed [OUTW-1 : 0] accumulator;	
logic signed [2*INW-1 : 0] pipeline_reg;	//it has 2*INW width because thats the max num of bits possible after multiplying two INW bit numbers
logic valid_pipelined, valid_pipelined2, valid_pipelined3,valid_pipelined4, valid_pipelined5, valid_pipelined6; //for 3 stages of pipelined version		  
	
logic signed [INW-1:0] input0_reg, input1_reg;

//DW02_mult_6_stage #(INW, INW) multinstance(input0_reg, input1_reg, 1'b1, clk, pipeline_reg);		 
//DW02_mult_3_stage #(INW, INW) multinstance(input0, input1, 1'b1, clk, pipeline_reg);
DW02_mult_2_stage #(INW, INW) multinstance(input0, input1, 1'b1, clk, pipeline_reg);

always_ff @(posedge clk) begin	
	if (reset) begin
		//pipeline_reg <= 0;
	//	input0_reg <= 0;
	//	input1_reg <= 0;
		valid_pipelined <= 0;
		//valid_pipelined2 <= 0;
    //  valid_pipelined3 <= 0; 
	//	valid_pipelined4 <= 0;
	//	valid_pipelined5 <= 0;
	//	valid_pipelined6 <= 0;
	end
	else begin		 
	//	if (input_valid) begin
	//	pipeline_reg <= (input0 * input1); 	// every statement in this else block is a D Flip flop, 
											// thats why prof. milder said we have to add another component for the valid signal. 
											// when we write a new signal in the always_ff block, it becomes a new DFF.
	//	end									// every bit of the pipeline_reg is a DFF. 
		//input0_reg <= input0;
		//input1_reg <= input1;
		valid_pipelined <= input_valid;      // Stage 1
        //valid_pipelined2 <= valid_pipelined;  // Stage 2
    //  valid_pipelined3 <= valid_pipelined2; // Stage 3
	//	valid_pipelined4 <= valid_pipelined3; // Stage 4
	//	valid_pipelined5 <= valid_pipelined4; // Stage 5   
	//	valid_pipelined6 <= valid_pipelined5; // Stage 5
	end
end	 

always_ff @(posedge clk) begin
    if(reset) begin
        accumulator <= 0;    
    end
    else if (init_acc) begin
        accumulator <= init_value;
    end
    else if (valid_pipelined) begin
        accumulator <= accumulator + pipeline_reg;	//every bit of the accumulator is a DFF.
    end
end

assign out = accumulator;	//the output is a combinational statement.

endmodule