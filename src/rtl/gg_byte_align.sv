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

// Non Blocking Byte align, word pack module: 
// Input: 511 bit VLC code, post byte align, and start code flagging.
// Output: 512 bit memory interface word, organized as 64 byte output (512 bits), 
//         with bits  packed    big endian into bytes (Mpeg ), and
//         with bytes packed little endian into words (intel), 
module gg_byte_align
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
	input  logic flush,
	
	// Input 512 bit VLC port
	input  logic          valid,
    input  logic [1039:0] vlc512_phrase,
    input  logic          byte_align_flag, // Indicates byte alignment required, post/after the vlc is emitted, used for PCM
    input  logic          dont_touch_flag, // don't touch or consider for emulation insertion. 
	                                       // This phrase may contain startcode(s), but guarateed not to require emulation bits.
	
	// Output 512 bit memory words
	output logic [511:0]  mem_word,
	output logic [63:0]   mem_startcode, // indicates associated byte is part of a startcode
	output logic          mem_valid 
	);
	
    // Input VLC, big endian, lsb aligned
	logic [  8:0] len  = vlc512_phrase[8:0];
	logic [511:0] bits = vlc512_phrase[527:15];
	logic [511:0] mask = vlc512_phrase[1039:526];
	
	// Word buffer
	logic [9:0] count;
	logic [9:0] shift;
	logic [1023:0][1:0] word_reg;
	logic [1023:0][1:0] barrel[11];
	
	always_comb begin : barrel_shift_1024x2bit
		shift = 11'd1024 - ( { 2'b00, count[8:0] } + { 2'b00, len[8:0] } );
		for( int ii = 0; ii < 1024; ii ++ ) begin
			barrel[ 0][ii] = ( ii >= 512 ) ? 2'b00 : { mask[ii], bits[ii] }; 
			barrel[ 1][ii] = ( shift[0] ) ? ( ( ii >=   1 && ii <= 511 +   1 ) ? barrel[0][ii-  1] : 2'b00 ) : ( ( ii < 511 +   1 ) ? barrel[0][ii] : 2'b00 );
			barrel[ 2][ii] = ( shift[1] ) ? ( ( ii >=   2 && ii <= 511 +   3 ) ? barrel[1][ii-  2] : 2'b00 ) : ( ( ii < 511 +   3 ) ? barrel[1][ii] : 2'b00 );
			barrel[ 3][ii] = ( shift[2] ) ? ( ( ii >=   4 && ii <= 511 +   7 ) ? barrel[2][ii-  4] : 2'b00 ) : ( ( ii < 511 +   7 ) ? barrel[2][ii] : 2'b00 );
			barrel[ 4][ii] = ( shift[3] ) ? ( ( ii >=   8 && ii <= 511 +  15 ) ? barrel[3][ii-  8] : 2'b00 ) : ( ( ii < 511 +  15 ) ? barrel[3][ii] : 2'b00 );
			barrel[ 5][ii] = ( shift[4] ) ? ( ( ii >=  16 && ii <= 511 +  31 ) ? barrel[4][ii- 16] : 2'b00 ) : ( ( ii < 511 +  31 ) ? barrel[4][ii] : 2'b00 );
			barrel[ 6][ii] = ( shift[5] ) ? ( ( ii >=  32 && ii <= 511 +  63 ) ? barrel[5][ii- 32] : 2'b00 ) : ( ( ii < 511 +  63 ) ? barrel[5][ii] : 2'b00 );
			barrel[ 7][ii] = ( shift[6] ) ? ( ( ii >=  64 && ii <= 511 + 127 ) ? barrel[6][ii- 64] : 2'b00 ) : ( ( ii < 511 + 127 ) ? barrel[6][ii] : 2'b00 );
			barrel[ 8][ii] = ( shift[7] ) ? ( ( ii >= 128 && ii <= 511 + 255 ) ? barrel[7][ii-128] : 2'b00 ) : ( ( ii < 511 + 255 ) ? barrel[7][ii] : 2'b00 );
			barrel[ 9][ii] = ( shift[8] ) ? ( ( ii >= 256 && ii <= 511 + 511 ) ? barrel[8][ii-256] : 2'b00 ) : ( ( ii < 511 + 511 ) ? barrel[8][ii] : 2'b00 );
			barrel[10][ii] = ( shift[9] ) ? ( ( ii >= 512 && ii <= 511 +1023 ) ? barrel[9][ii-512] : 2'b00 ) : ( ( ii < 511 +1023 ) ? barrel[9][ii] : 2'b00 );
		end
	end
	
	always_ff @(posedge clk) begin 
		if( valid ) begin // Update only on valid input.
			count[9:0] <= { 1'b0, count[8:0] } + { 1'b0, len[8:0] }; // count wraps
			for( int ii =0; ii < 511; ii++ ) begin
				if( ii < 512 ) begin // save any overflow for next words
					word_reg[ii] <= barrel[10][ii];
				end else begin // output word
					word_reg[ii] <= ( barrel[10][ii][1]   ) ? barrel[10][ii] :  // take output of barrel
									( word_reg[ii-512][1] ) ? word_reg[ii-512] : // take overflow
															  word_reg[ii];		// else hold value					   
				end
			end
		end
    end
	
    //////////
    // DONE
    //////////
   
	// output with do endian swap
	always_comb begin
		for( int ii = 0; ii < 64; ii++ ) begin // byte packing - litle endian
			for( int jj = 0; jj < 8; jj++ ) begin // bit packing - big endian
				mem_word[ii*8+7-jj] = word_reg[1023-(ii*8+jj)][0];
		    end
		end
	end
	
    assign mem_startcode 	= 0;
    assign mem_valid 		= count[9];

endmodule




