module mac_pipe #(parameter INW = 16, parameter OUTW = 64)(
    input signed [INW-1:0] input0, input1, init_value,
    output logic signed [OUTW-1:0] out,
    input clk, reset, init_acc, input_valid
);

logic signed [OUTW-1 : 0] accumulator;	
logic signed [2*INW-1 : 0] pipeline_reg;
logic valid_pipelined;

always_ff @(posedge clk) begin	
	if (reset) begin
		pipeline_reg <= 0;	 
		valid_pipelined <= 0;
	end
	else begin		 
		if (input_valid) begin
			pipeline_reg <= (input0 * input1); 
		end
		valid_pipelined <= input_valid;
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
        accumulator <= accumulator + pipeline_reg;
    end
end

assign out = accumulator;

endmodule