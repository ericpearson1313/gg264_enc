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

// PCM Buffer: 1 macrblock Delay
// Input: 128-bit original 4x4 pel blocks, in encode order 
// Output: 128-bit raster 16 pixel of PCM data in bitstream order, 24 transfers.

module gg_pcm_buf
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
	logic [0:3][4:0] raddr;
	logic [4:0] waddr;
	logic [0:3][31:0] wdata, rdata;
	logic [1:0] wstate;
	logic [1:0] rstate;
	logic [4:0] wcnt, rcnt;

	// State Machines
	
    always_ff @(posedge clk) begin

		case(wstate)
			S_IDLE : begin if( s_valid ) wstate <= S_RUN ; end
			S_RUN: begin if( s_ready && s_valid && s_last ) wstate <= S_WAIT; end
			S_WAIT: begin if( rstate == S_WAIT ) wstate <= S_RUN; end
		endcase
		
		case(rstate)
			S_IDLE: begin if( wstate != S_IDLE ) rstate <= S_WAIT; end
			S_WAIT: begin if( wstate == S_WAIT ) rstate <= S_RUN; end
			S_RUN: begin if( m_ready && m_valid && m_last ) rstate <= S_WAIT; end
		endcase

		wcnt <= ( wstate == S_IDLE || (s_ready && s_valid && s_last)) ? 0 : (s_ready && s_valid) ? (wcnt + 1) : wcnt; 
		rcnt <= ( rstate == S_IDLE || (m_ready && m_valid && m_last)) ? 0 : (m_ready && m_valid) ? (rcnt + 1) : rcnt;
		bank <= ( rstate == S_WAIT && wstate == S_WAIT ) ? ~bank : bank; // Toggle banks at rendevous
	end
	
	// Port interfaces

	assign s_ready = ( wstate == S_WAIT || wstate == S_IDLE ) ? 1'b0 : 1'b1;
	assign m_valid = ( rstate == S_RUN ) ? 1'b1 : 1'b0;
	assign m_last  = ( rstate == S_RUN && rcnt == 'd24 ) ? 1'b1 : 1'b0;

	// Control Decoder
	
	assign raddr[0] = ( rcnt[4] ) ? { rcnt[4:1],  rcnt[0] } : { rcnt[4:2], 2'b00 };
	assign raddr[1] = ( rcnt[4] ) ? { rcnt[4:1],  rcnt[0] } : { rcnt[4:2], 2'b01 };
	assign raddr[2] = ( rcnt[4] ) ? { rcnt[4:1], ~rcnt[0] } : { rcnt[4:2], 2'b10 };
	assign raddr[3] = ( rcnt[4] ) ? { rcnt[4:1], ~rcnt[0] } : { rcnt[4:2], 2'b11 };

	assign waddr = ( wcnt[4] ) ? { wcnt[4:0] } : { wcnt[4:3], wcnt[1], wcnt[2], wcnt[0] };
	assign ishift = { wcnt[2], wcnt[0] };
	assign oshift = { rcnt[4] } ? { 2'b10, rcnt[0] } : { 1'b0, rcnt[1:0] };
	
	// Data Path
	
	assign wdata = (ishift == 0) ? { s_data[ 31: 0], s_data[ 63:32], s_data[ 95:64], s_data[127:96] } :
	               (ishift == 1) ? { s_data[127:96], s_data[ 31: 0], s_data[ 63:32], s_data[ 95:64] } :
	               (ishift == 2) ? { s_data[ 95:64], s_data[127:96], s_data[ 31: 0], s_data[ 63:32] } :
	             /*(ishift == 1)*/ { s_data[ 63:32], s_data[ 95:64], s_data[127:96], s_data[ 31: 0] } ;

	assign m_data = (oshift == 0) ? { rdata[0], rdata[1], rdata[2], rdata[3] } : // luma
	                (oshift == 1) ? { rdata[1], rdata[2], rdata[3], rdata[0] } :
	                (oshift == 2) ? { rdata[2], rdata[3], rdata[0], rdata[1] } :
	                (oshift == 3) ? { rdata[3], rdata[0], rdata[1], rdata[2] } :
	                (oshift == 4) ? { rdata[0], rdata[2], rdata[1], rdata[3] } : // chroma
	              /*(oshift == 5)*/ { rdata[2], rdata[0], rdata[3], rdata[1] } ;
		
    // Srams
	
	gg_sram_1r1w #( 32, 64, 6 ) sram_0 
		(
			.clk	( clk ),
			.raddr	( {  bank, raddr[0][4:0] } ),
			.waddr	( { ~bank, waddr[0][4:0] } ),
			.we		( s_valid & s_ready ),
			.din	( wdata[0][31:0] ),
			.qout	( rdata[0][31:0] )
		);
		
	gg_sram_1r1w #( 32, 64, 6 ) sram_1 
		(
			.clk	( clk ),
			.raddr	( {  bank, raddr[1][4:0] } ),
			.waddr	( { ~bank, waddr[1][4:0] } ),
			.we		( s_valid & s_ready ), 
			.din	( wdata[1][31:0] ),
			.qout	( rdata[1][31:0] )
		);

	gg_sram_1r1w #( 32, 64, 6 ) sram_2 
		(
			.clk	( clk ),
			.raddr	( {  bank, raddr[2][4:0] } ),
			.waddr	( { ~bank, waddr[2][4:0] } ),
			.we		( s_valid & s_ready ), 
			.din	( wdata[2][31:0] ),
			.qout	( rdata[2][31:0] )
		);

	gg_sram_1r1w #( 32, 64, 6 ) sram_3 
		(
			.clk	( clk ),
			.raddr	( {  bank, raddr[3][4:0] } ),
			.waddr	( { ~bank, waddr[3][4:0] } ),
			.we		( s_valid & s_ready ), 
			.din	( wdata[3][31:0] ),
			.qout	( rdata[3][31:0] )
		);

endmodule

// synchronous Sram with separate read and write ports
module gg_sram_1r1w
 #(
	parameter int WIDTH = 32,
	parameter int WORDS = 64,
	parameter int ADDR  = 6
 )
 (
	input  logic  			clk,
	input  logic [ADDR-1:0] raddr,
	input  logic [ADDR-1:0] waddr,
	input  logic  			we,
	input  logic			re,
	input  logic [WIDTH-1:0] din,
	output logic [WIDTH-1:0] qout
 );

	logic [WIDTH-1:0] mem[WORDS];
	
    always_ff @(posedge clk) begin
		if( we ) begin	
			mem[ waddr ] <= din;
		end
		qout <= mem[ raddr ];
	end
	
endmodule
