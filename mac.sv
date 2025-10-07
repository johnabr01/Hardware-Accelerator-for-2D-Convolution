module mac #(parameter INW = 16, parameter OUTW = 64)(
    input signed [INW-1:0] input0, input1, init_value,
    output logic signed [OUTW-1:0] out,
    input clk, reset, init_acc, input_valid
);
	logic signed [OUTW-1 : 0] accumulator;
	always_ff @(posedge clk) begin
	    if(reset) begin
	        accumulator <= 0;    
	    end
	    else if (init_acc) begin
	        accumulator <= init_value;
	    end
	    else if (input_valid) begin
	        accumulator <= accumulator + (input0 * input1);		//basic MAC unit.
	    end
	end
	assign out = accumulator; //the output is a combinational statement.
endmodule