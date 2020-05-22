`timescale 1ns / 1ps
//
// MIT License
// 
// Copyright (c) 2020 Eric Pearson
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
// IN THE SOFTWARE.
//

// DMA Macroblock read, and DC calc
// AXI-L-32bit Slave port - register read/write
// AXI4 128-bit Master Read port - 128-bit video 4x4 pel blocks, in encode order, 24 transfers/macroblock
// AXI Master Stream port - 128 bit video, 4x4 pel blocks, in encode order with added chroma DC blocks,  26 transfers/macroblock

module gg_dma_rdmb
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
    // 32-bit Axi-L register port
    // AR
    input  logic         s_arvalid ,
    output logic         s_arready ,
    input  logic [7:0]   s_araddr  ,
    // R
    output logic         s_rvalid  ,
    input  logic         s_rready  ,
    output logic [31:0]  s_rdata   ,
    output logic  [1:0]  s_rresp    ,
    // AW
    input  logic         s_awvalid ,
    output logic         s_awready ,
    input  logic [7:0]   s_awaddr  ,
    // W
    input  logic         s_wvalid  ,
    output logic         s_wready  ,
    input  logic [31:0]  s_wdata   ,
    // B
    output logic         s_bvalid  ,
    input  logic         s_bready  ,
    output logic  [1:0]  s_bresp   ,
   
    // 128-bit Axi4 dram M read port
    // AR
    output logic         m_arvalid ,
    input  logic         m_arready ,
    output logic [39:0]  m_araddr  ,
    output logic [ 7:0]  m_arlen   ,
    output logic [ 2:0]  m_arsize  ,
    output logic [ 3:0]  m_arcache ,
    // R
    input  logic         m_rvalid  ,
    output logic         m_rready  ,
    input  logic [127:0] m_rdata   ,
    input  logic         m_rlast   ,
    input  logic [1:0]   m_rresp   ,
    
    // 128-bit stream output port
	output logic         m_valid   ,
	input  logic         m_ready   ,
	output logic [127:0] m_data    ,
	output logic         m_last    
    );

	localparam int S_IDLE           = 0, 
	               S_READ           = 1,
	               S_WRITE          = 2,
	               S_RESP           = 3,
                   S_RUN            = 2;
				  
	
    logic [63:0] dma_base_addr, dma_limit_addr, dma_read_addr, dma_write_addr;
    logic go_reg, cont_reg;
    logic [7:0] laraddr, lawaddr;
    logic [3:0] rstate;
    logic [3:0] wstate;
    logic we;

    // AXI-L Read State machine
    
    always_ff @(posedge clk) begin
    
        case( rstate ) 
        S_IDLE: begin
            if( s_arvalid ) begin
                rstate <= S_READ;
            end
        end
        S_READ: begin
            if( s_rready ) begin
                rstate <= S_IDLE;
            end
        end
        endcase
        
        // Latch read address
        if( s_arvalid & s_arready ) begin
            laraddr <= s_araddr;
        end
    end

    // Connect raddr port
        
    assign s_rresp = 2'b00;
    assign s_arready = ( rstate == S_IDLE ) ? 1'b1 : 1'b0;
    assign s_rvalid  = ( rstate == S_READ ) ? 1'b1 : 1'b0;
    assign s_rdata = ( laraddr == 'h00 ) ? { 30'h0, cont_reg, go_reg } :
                     ( laraddr == 'h04 ) ? { 32'h0 } :
                     ( laraddr == 'h08 ) ? dma_base_addr[31:0] :
                     ( laraddr == 'h0C ) ? dma_base_addr[63:32] :
                     ( laraddr == 'h10 ) ? dma_limit_addr[31:0] :
                     ( laraddr == 'h14 ) ? dma_limit_addr[63:32] :
                     ( laraddr == 'h18 ) ? dma_read_addr[31:0] :
                     ( laraddr == 'h1C ) ? dma_read_addr[63:32] :
                     ( laraddr == 'h20 ) ? dma_write_addr[31:0] :
                     ( laraddr == 'h24 ) ? dma_write_addr[63:32] :
                                           32'hdead_beef;
                                                                 
    // AXI-L write state machine
    
    always_ff @(posedge clk) begin
    
        case( wstate ) 
        S_IDLE: begin
            if( s_awvalid & s_wvalid ) begin
                wstate <= S_WRITE;
            end
        end
        S_WRITE: begin
            wstate <= S_RESP;
        end
        S_RESP: begin
            if( s_bready ) begin
                wstate <= S_IDLE;
            end
        end
        endcase
        
        // Latch read address
        if( s_awvalid & s_awready ) begin
            lawaddr <= s_awaddr;
        end
    end
    
    assign s_awready = ( wstate == S_WRITE ) ? 1'b1 : 1'b0;
    assign s_wready  = ( wstate == S_WRITE ) ? 1'b1 : 1'b0;
    assign s_bvalid  = ( wstate == S_RESP  ) ? 1'b1 : 1'b0;
    assign s_bresp   = 2'b00;
      
    // Registers
    
    assign we = ( wstate == S_WRITE  ) ? 1'b1 : 1'b0;

    always_ff @(posedge clk) begin
        dma_base_addr[31: 0]  <= ( we && lawaddr == 'h08 ) ? s_wdata :  dma_base_addr[31:0];
        dma_base_addr[63:32]  <= ( we && lawaddr == 'h0C ) ? s_wdata :  dma_base_addr[63:32];            
        dma_limit_addr[31: 0] <= ( we && lawaddr == 'h10 ) ? s_wdata :  dma_limit_addr[31:0];
        dma_limit_addr[63:32] <= ( we && lawaddr == 'h14 ) ? s_wdata :  dma_limit_addr[63:32];
        dma_read_addr[31: 0]  <= ( we && lawaddr == 'h18 ) ? s_wdata :  dma_read_addr[31:0];
        dma_read_addr[63:32]  <= ( we && lawaddr == 'h1C ) ? s_wdata :  dma_read_addr[63:32];
        dma_write_addr[31: 0] <= ( we && lawaddr == 'h20 ) ? s_wdata :  dma_write_addr[31:0];
        dma_write_addr[63:32] <= ( we && lawaddr == 'h04 ) ? s_wdata :  dma_write_addr[63:32];
        { cont_reg, go_reg }  <= ( we && lawaddr == 'h04 ) ? s_wdata[1:0] : { cont_reg, go_reg };
    end
    
    // DMA Read Address State Machine
    
    // For Recon, just re-read the same buffer again (ignore write pointer, guranteed valid)
    // For orig, watch write pointer, and wait for it when reached. Status should show waiting for write
    // Dropping go means stop generating accesses? (what about data in flight, and clean end)
    
    // << TODO >>
    
    // DMA Read address port
    
    assign  m_arvalid = 1'b0;
    assign  m_araddr  = 40'h0;
    assign  m_arlen   = 8'h0;
    assign  m_arsize  = 3'b100; // 128 bit = 16 byte per beat transfers
    assign  m_arcache = 4'b0000; // Determine correct one, Look in Xilinx interconnect IP docs for recommended


    // Wire in the chroma DC Calc
    // No real reason to have this inside the DMA
    // How to clean up after go is dropped?
	
    chdc_calc   chroma_dc_
    (
        .clk     ( clk ),
        // in from dram read port
        .s_valid ( m_rvalid  ),
        .s_ready ( m_rready  ),
        .s_data  ( m_rdata   ),
        .s_last  ( m_rlast   ),
        // out to module stream out port
        .m_valid ( m_valid   ),
        .m_ready ( m_ready   ),
        .m_data  ( m_data    ),
        .m_last  ( m_last    )
    );
        
endmodule

// Macroblock inline Chroma DC insert
// in 128 bit stream, 24 transfers per MB
// Flow through arch, data will progress to output in 10 cycles
// 
module chdc_calc
 #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
 )
 (
	input  logic  		 clk,
	// Input port (24 cyc/mb)
	output logic         s_ready,
	input  logic         s_valid,
	input  logic [127:0] s_data,
	input  logic         s_last, // asserted occasionally with Cr3, resync with it
	// Output port (26 cyc/mb)
	output logic         m_valid,
	input  logic         m_ready,
	output logic [127:0] m_data,
	output logic         m_last  // asserted always with Cr3.
);

	logic [15:0][7:0] buffer[10]; // input buf, 8 delay buf, output buf
	logic [11:0]  buf_dc[10];
	logic [8:0]   valid, ready, last;
	logic [4:0]   s_count;
	logic         cbdc, crdc;
	

	// Ready logic

    always_comb begin
	    // Connect input
	    s_ready = ready[0];
		// ready 0 to 7 are standard shift
		for( int ii = 0; ii <= 7; ii++ ) begin
			ready[ii] = !valid[ii] | ready[1];
		end
		// ready 8 has to hold off when last
		ready[8] = !valid[8] || ready[9] && !cbdc && !crdc;
		// ready 9 connects to output
		ready[9] = !valid[9] || m_ready;
	end
	
	
	// shift register buffer
    always_ff @(posedge clk) begin
    
		if( s_valid && ready[0] ) begin
			s_count <= ( s_last ) ? 'd23 : ( s_count == 'd23 ) ? 0 : s_count+1;
		end

		// Buffer 0 - register input port
		if( s_valid && ready[0] ) begin // incoming
		    valid[0]  <= 1'b1;
			buffer[0] <= s_data;
			last[0]   <= ( s_count == 'd23 ) ? 1'b1 : 1'b0;
			buf_dc[0] <= 0;
		end else if( valid[0] && ready[1] ) begin // outgoing
			valid[0]  <= 1'b0;
		end
			
		// Buffer 1
		if( valid[0] && ready[1] ) begin // incoming 
			valid[1]  <= 1'b1; 
			buffer[1] <= buffer[0];
			last[1]   <= last[0];
			buf_dc[1] <= ((( { 4'b0000, buffer[0][ 0] } + { 4'b0000, buffer[0][ 1] } ) + ( { 4'b0000, buffer[0][ 2] } + { 4'b0000, buffer[0][ 3] } ))  +
						  (( { 4'b0000, buffer[0][ 4] } + { 4'b0000, buffer[0][ 5] } ) + ( { 4'b0000, buffer[0][ 6] } + { 4'b0000, buffer[0][ 7] } ))) +
						 ((( { 4'b0000, buffer[0][ 8] } + { 4'b0000, buffer[0][ 9] } ) + ( { 4'b0000, buffer[0][10] } + { 4'b0000, buffer[0][11] } ))  +
						  (( { 4'b0000, buffer[0][12] } + { 4'b0000, buffer[0][13] } ) + ( { 4'b0000, buffer[0][14] } + { 4'b0000, buffer[0][15] } ))) ;
		end else if( valid[1] & ready[2] ) begin
			valid[1]  <= 1'b0;
		end
		
		// Buffer 2 to 8
		for( int ii = 2; ii <= 8; ii++ ) begin
			if( valid[ii-1] && ready[ii] ) begin // incoming
				valid[ii]  <= 1'b1;
				buffer[ii] <= buffer[ii-1];
				last[ii]   <= last[ii-1];
				buf_dc[ii] <= buf_dc[ii-1];
			end else if( valid[ii] && ready[ii+1] ) begin // outgoing
				valid[ii]  <= 1'b0;
			end
		end
		
		// Cb/Cr state
		if( valid[7] && ready[8] && last[7] ) begin
			cbdc <= 1'b1;
			crdc <= 1'b1;
		end else if ( |valid[8:5] && last[8] && ready[9] && cbdc ) begin
			cbdc <= 0;
		end else if ( |valid[8:1] && last[8] && ready[9] && crdc ) begin
			crdc <= 0;
		end
		
		// Port 9 - Output port
		if( valid[8] && ready[9] && !cbdc && !crdc ) begin // normal incoming
			valid[9]  <= 1'b1;
			buffer[9] <= buffer[8];
			last[9]   <= last[8];
		end else if( |valid[8:5] && last[8] && ready[9] && cbdc ) begin // CbDc
			valid[9]  <= 1'b1;
			buffer[9] <= { buf_dc[8], 12'd0, buf_dc[7], {5{12'b0}}, buf_dc[6], 12'd0, buf_dc[5], {5{12'd0}} };
			last[9]   <= 1'b0;
		end else if( |valid[8:1] && last[8] && ready[9] && crdc ) begin // CrDc
			valid[9]  <= 1'b1;
			buffer[9] <= { buf_dc[4], 12'd0, buf_dc[3], {5{12'b0}}, buf_dc[2], 12'd0, buf_dc[1], {5{12'd0}} };
			last[9]   <= 1'b0;
		end else if( valid[9] & m_ready ) begin
			valid[9] <= 1'b0;
	    end
	end
    
	// Connect up output port
	
	assign m_valid = valid[9];
	assign m_last = last[9];
	assign m_data = buffer[9];

endmodule
