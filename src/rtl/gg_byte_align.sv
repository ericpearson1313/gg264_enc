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
    input  logic          byte_align_flag, // Indicates byte alignment after the vlc is emitted
    input  logic [3:0]    startcode_flag, // indicates that up to the first 4 first bytes are a startcode
	
	// Output 512 bit memory words
	output logic [511:0]  mem_word,
	output logic [63:0]   mem_startcode, // indicates associated byte is part of a startcode
	output logic          mem_valid 
	);
	
    
    //////////
    // DONE
    //////////
   
    assign mem_word 		= 0;
    assign mem_startcode 	= 0;
    assign mem_valid 		= 0;

endmodule




