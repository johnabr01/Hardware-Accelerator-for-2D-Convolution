// ESE 507 Stony Brook University
// Peter Milder
// You may not redistribute this code.
// Dual-port Memory to use for output FIFO

module memory_dual_port #(
        parameter                WIDTH=16, SIZE=64,
        localparam               LOGSIZE=$clog2(SIZE)
    )(
        input [WIDTH-1:0]        data_in,
        output logic [WIDTH-1:0] data_out,
        input [LOGSIZE-1:0]      write_addr, read_addr,
        input                    clk, wr_en
    );

    logic [SIZE-1:0][WIDTH-1:0] mem;

    always_ff @(posedge clk) begin
        // if we are reading and writing to same address concurrently, 
        // then output the new data
        if (wr_en && (read_addr == write_addr))
            data_out <= data_in;
        else
            data_out <= mem[read_addr];

        if (wr_en)
            mem[write_addr] <= data_in;            
    end
endmodule