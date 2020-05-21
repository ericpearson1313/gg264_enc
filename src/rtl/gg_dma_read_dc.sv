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

module gg_dma_read_dc
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
	// Input AXI stream of 4x4 transform blocks 24/MB
	input  logic [127:0] s_data,
	input  logic         s_last,
	input  logic         s_valid,
	output logic         s_ready,
	// Output AXI stream of PCM pels, 24/MB
	output logic [127:0] m_data,
	output logic         m_last,
	output logic         m_valid,
	input  logic         m_ready
    );

	localparam int S_IDLE           = 0,
                   S_WAIT           = 1,
                   S_RUN            = 2;
				  
	
	logic [1:0] ishift;
	logic [2:0] oshift;
    logic bank;
	
endmodule

// Macroblock inline Chroma DC insert
// in 128 bit stream, 24 transfers per MB
// Flow through arch, data will progress to output in 10 cycles
// 
module chroma_dc_insert
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
	
	// Connect input
	assign s_ready = ready[0];
	
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
			buf_dc[1] <= ((( { 4'b0000, buf[0][ 0] } + { 4'b0000, buf[0][ 1] } ) + ( { 4'b0000, buf[0][ 2] } + { 4'b0000, buf[0][ 3] } ))  +
						  (( { 4'b0000, buf[0][ 4] } + { 4'b0000, buf[0][ 5] } ) + ( { 4'b0000, buf[0][ 6] } + { 4'b0000, buf[0][ 7] } ))) +
						 ((( { 4'b0000, buf[0][ 8] } + { 4'b0000, buf[0][ 9] } ) + ( { 4'b0000, buf[0][10] } + { 4'b0000, buf[0][11] } ))  +
						  (( { 4'b0000, buf[0][12] } + { 4'b0000, buf[0][13] } ) + ( { 4'b0000, buf[0][14] } + { 4'b0000, buf[0][15] } ))) ;
		end else if( valid[1] & ready[2] ) begin
			valid[2]  <= 1'b0:
		end
		
		// Buffer 2 to 8
		for( int ii = 2; ii <= 8; ii++ ) begin
			if( valid[ii-1] && ready[ii] ) begin // incoming
				valid[ii]  <= 1'b1;
				buffer[ii] <= buffer[ii-1];
				last[ii]   <= last[ii-1];
				buf_dc[ii] <= buf_dc[ii-1];
			end else if( s_valid[ii] && ready[ii+1] ) begin // outgoing
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
		end else begin if( |valid[8:5] && last[8] && ready[9] && cbdc ) begin // CbDc
			valid[9]  <= 1'b1;
			buffer[9] <= { buf_dc[8], 12'd0, buf_dc[7], {5{12'b0}}, buf_dc[6], 12'd0, buf_dc[5], {5{12'd0}} };
			last[9]   <= 1'b0;
		end else begin if( |valid[8:1] && last[8] && ready[9] && crdc ) begin // CrDc
			valid[9]  <= 1'b1;
			buffer[9] <= { buf_dc[4], 12'd0, buf_dc[3], {5{12'b0}}, buf_dc[2], 12'd0, buf_dc[1], {5{12'd0}} };
			last[9]   <= 1'b0;
		end else if( valid[9] & m_ready ) begin
			valid[9] <= 1'b0;
		end
	end
	
	// Ready logic
	
    always_comb begin
		// ready 0 to 7 are standard shift
		for( int ii = 0; ii <= 7; ii++ ) begin
			ready[ii] = !valid[ii] | ready[1];
		end
		// ready 8 has to hold off when last
		ready[8] = !valid[8] || ready[9] && !cbdc && !crdc;
		// ready 9 connects to output
		ready[9] = !valid[9] || m_ready;
	end
	
	// Connect up output port
	
	assign m_valid = valid[9];
	assign m_last = last[9];
	assign m_data = buffer[9];
	
endmodule
