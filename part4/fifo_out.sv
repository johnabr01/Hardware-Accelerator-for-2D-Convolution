module fifo_out #(
    parameter  OUTW     = 24,	// num of bits of Fifo's input and output values
    parameter  DEPTH    = 38, //num of entries in fifo
    localparam LOGDEPTH = $clog2(DEPTH)	 //num of bits necessary for max values of read and write addr
)(
    input                   clk,
    input                   reset,
    input  [OUTW-1:0]       IN_AXIS_TDATA,
    input                   IN_AXIS_TVALID,
    output logic            IN_AXIS_TREADY,
    output logic [OUTW-1:0] OUT_AXIS_TDATA,
    output logic            OUT_AXIS_TVALID,
    input                   OUT_AXIS_TREADY
);

    localparam CNTW = $clog2(DEPTH + 1); //the +1 is the extra bit u need to represent the last num. eg: if DEPTH is 8, u need 4 bits to represent the num 8. 

    logic [LOGDEPTH-1:0] tail, head;
    logic [CNTW-1:0] count;	  //capacity signal for telling us when to write and read enable signals

    logic [OUTW-1:0] mem_dout;
	
	logic empty, full, read_en, write_en;
	
    assign empty = (count == 0);
    assign full  = (count == DEPTH);
	
	//below assignments were specified in proj description
    assign OUT_AXIS_TVALID = !empty;   //if fifo's not empty then output is valid. 
    assign read_en  = OUT_AXIS_TVALID && OUT_AXIS_TREADY;   //pop 
    assign IN_AXIS_TREADY = (!full) || (full && read_en);//accept while full if popping
    assign write_en = IN_AXIS_TVALID && IN_AXIS_TREADY;     //push

    //if reading now, use tail+1 to output on data_out in the next cycle.
    
    logic [LOGDEPTH-1:0] lookahead_read_addr;
	
    always_comb begin
        lookahead_read_addr = tail;
        if (read_en) begin
            if (tail == DEPTH-1)
                lookahead_read_addr = '0;
            else
                lookahead_read_addr = tail + 1'b1;	//looking ahead for the possibility of reading
        end
    end
	
	//counters to tell us where we should store and read 
    always_ff @(posedge clk) begin
        if (reset) begin
            tail <= '0;
            head <= '0;
            count  <= '0;
        end else begin
            //counter for write pointer, aka, the next memory location where we can store data
            if (write_en) begin
                if (head == DEPTH-1) 	   //from slides
                    head <= '0;			   //reset the pointer to first mem addr
                else                    
                    head <= head + 1'b1;
            end

            //counter for read pointer, aka, the next memory location where we can read data from. 
            if (read_en) begin
                if (tail == DEPTH-1) 	  //from slides
                    tail <= '0;			  //reset the pointer to first mem addr
                else                    
                    tail <= tail + 1'b1;
            end

            //count
            case ({write_en, read_en})
                2'b10: count <= count + 1'b1; //push only
                2'b01: count <= count - 1'b1; //pop only
                default: count <= count;      //both or none so then the count remains the same.
            endcase
        end
    end
    // memory
    memory_dual_port #(.WIDTH(OUTW),.SIZE (DEPTH)) mem_inst (
        .clk        (clk),
        .data_in    (IN_AXIS_TDATA),
        .data_out   (mem_dout),
        .write_addr (head),
        .read_addr  (lookahead_read_addr),  //use look-ahead address here
        .wr_en      (write_en)
    );

    assign OUT_AXIS_TDATA = mem_dout;

    

endmodule