module mac_pipe #(parameter INW = 16, parameter OUTW = 48)(
    input signed [INW-1:0] input0, input1, init_value,
    output logic signed [OUTW-1:0] out,
    input clk, reset, init_acc, input_valid
);

logic signed [OUTW-1 : 0] accumulator;	
logic signed [2*INW-1 : 0] pipeline_reg;	//it has 2*INW width because thats the max num of bits possible after multiplying two INW bit numbers
logic valid_pipelined;

always_ff @(posedge clk) begin	
	if (reset) begin
		pipeline_reg <= 0;	 
		valid_pipelined <= 0;
	end
	else begin		 
		if (input_valid) begin
		pipeline_reg <= (input0 * input1); 	// every statement in this else block is a D Flip flop, 
											// thats why prof. milder said we have to add another component for the valid signal. 
											// when we write a new signal in the always_ff block, it becomes a new DFF.
		end									// every bit of the pipeline_reg is a DFF. 
		valid_pipelined <= input_valid;	    // pipeline the input_valid signal.
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