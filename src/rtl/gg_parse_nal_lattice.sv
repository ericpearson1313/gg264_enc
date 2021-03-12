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


// Parse a Nal  
// pre-removed emulation_prevention_three_bytes (0x03)
// Purpose: parse a continuous NAL byte stream (connect start = end)
// Input: rbsp byte stream, nal_start (byte aligned)
// Output: nal_end (byte aligned)
// Function: 
//      seach forward till a NAL startcode. 
//      If nal_unit_type == 1 its a Pintra slice NAL, then 
//          MB start parsing
//          NAL end = MB end
//      else 
//          search forward until nal END and signal
// (operations only take place on byte boundaries)

module gg_parse_nal_lattice
   #(
     parameter int WIDTH             = 32,
     parameter int BYTE_WIDTH        = WIDTH / 8
    )
    (
    // System
    input  logic clk,
    input  logic reset,
    // Input bits
    input  logic [WIDTH-1:0] in_bits, // bitstream, bit endian packed
    input  logic [31:0]      in_pad, // Lookahead of 32 bits
    // Control
    input  logic [BYTE_WIDTH-1:0] nal_start,
    output logic [BYTE_WIDTH-1:0] nal_end,
    
    // Slice lattice interface
    output logic [BYTE_WIDTH-1:0] slice_start, // byte aligned input trigger
    input  logic [BYTE_WIDTH-1:0] slice_end // byte aligned completion
    );
 
    logic [BYTE_WIDTH+3:4]                      s_nal_type;
    logic            [3:0]                      s_nal_type_reg;
    logic [BYTE_WIDTH+3:4]                      s_search_start;
    logic [BYTE_WIDTH+3:4]                      s_search_run;
    logic                                       s_search_run_reg;
    
    logic [BYTE_WIDTH+3:4]              start_code;
    logic [BYTE_WIDTH+3:4]              p_slice;
    
    
    logic [WIDTH+31:0] bits;
    logic [BYTE_WIDTH+3:0] nal_end_flag;
    logic [BYTE_WIDTH+3:0] nal_start_flag;
    logic [BYTE_WIDTH+3:0] slice_end_flag;
    logic [BYTE_WIDTH+3:0] slice_start_flag;
    
    // Set up array inputs
    assign bits = { in_bits, in_pad };
    assign nal_start_flag[BYTE_WIDTH+3:0] = { nal_start, 4'b0000 };
    assign slice_end_flag[BYTE_WIDTH+3:0] = { slice_end, 4'b0000 };

    // Loop Over bitpositions 
    always_comb begin : _lattice_nal_parse

        // Clear state
        s_nal_type       = 0;
        s_search_start   = 0;
        s_search_run     = 0;

        // Clear decode arrays
        start_code       = 0;
        p_slice          = 0;

        // Clear outputs
        nal_end_flag     = 0;
        slice_start_flag = 0;
        
        // Set first bit input
        s_search_run[BYTE_WIDTH-1] = s_search_run_reg;
        
        // Instantiate unqiue hardware for each byte msb bit of the input
        for( int bp = BYTE_WIDTH-1+4; bp >= 4; bp-- ) begin : _slice_lattice_col
        
            // Calculated start code flags
            start_code[bp] = ( bits[bp*8+7-:24] == 24'h00_00_01 ) ? 1'b1 : 1'b0;
            // Determine if this nal is a P-slice. u(5) nal_unit_type==1(non-IDR slice), ue(v) start_mb (skip it), ue(v) slice_type=0 (p-slice)
            p_slice[bp] = ( bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 1] ==  1'b1                && bits[bp*8- 2] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 2] ==  2'b01               && bits[bp*8- 4] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 3] ==  3'b001              && bits[bp*8- 6] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 4] ==  4'b0001             && bits[bp*8- 8] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 5] ==  5'b00001            && bits[bp*8-10] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 6] ==  6'b000001           && bits[bp*8-12] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 7] ==  7'b0000001          && bits[bp*8-14] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 8] ==  8'b00000001         && bits[bp*8-16] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-: 9] ==  9'b000000001        && bits[bp*8-18] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:10] == 10'b0000000001       && bits[bp*8-20] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:11] == 11'b00000000001      && bits[bp*8-22] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:12] == 12'b000000000001     && bits[bp*8-24] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:13] == 13'b0000000000001    && bits[bp*8-26] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:14] == 14'b00000000000001   && bits[bp*8-28] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:15] == 15'b000000000000001  && bits[bp*8-30] == 1'b1 ||
                            bits[bp*8+4-:5] == 5'b00001 && bits[bp*8-1-:16] == 16'b0000000000000001 && bits[bp*8-32] == 1'b1 ) ? 1'b1 : 1'b0;
            
        
            // Start code search
            s_search_start[bp] = slice_end_flag[bp] | nal_start_flag[bp] | (s_nal_type[bp] & !p_slice[bp]);
            
            // If its not a start code here, then keep search running
            s_search_run[bp-1] = ( s_search_start[bp]  | s_search_run[bp] ) & !start_code[bp];
            
            // It it is a startcode then look at the NAL type, slice_type
            s_nal_type[bp-3] = ( ( s_search_start[bp] | s_search_run[bp] ) & start_code[bp] ) | ((bp >= BYTE_WIDTH) ? s_nal_type_reg[bp-BYTE_WIDTH] : 1'b0 );
        
            // Start NAL if nal_unit_type == 1 // P slice
            slice_start_flag[bp-1] = s_nal_type[bp] & p_slice[bp];
            
        end // bp
    end // _lattice

    // Connect up the output bits
    assign nal_end = nal_end_flag[BYTE_WIDTH+3:4];
    assign slice_start = slice_start_flag[BYTE_WIDTH+3:4];

    // Register states from overflow region (if need?) 
    always_ff @(posedge clk) begin // Lower 32 set of states are flopped  
        if( reset ) begin
            // Handle variable length codes   
            s_nal_type_reg <= 0;
            s_search_run_reg <= 0;
        end else begin
            // Handle the variable lenght arcs (up to 31 bits)
            s_search_run_reg <= ( s_search_start[4]  | s_search_run[4] ) & !start_code[4];
            for( int bp = 3; bp >= 0; bp-- ) begin
                s_nal_type_reg[bp] <= ( s_search_start[bp+3] | s_search_run[bp+3] ) & start_code[bp+3];
            end // bp
        end // reset
    end // ff
endmodule

