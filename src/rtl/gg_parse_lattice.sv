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


// Decode process a transform block
// Input: bitstream, block predictor, qpy,  and block index
// Output: recon, bitcount
module gg_parse_lattice
   #(
     parameter int WIDTH             = 32
    )
    (
    input  logic clk,
    input  logic reset,
    input  logic [WIDTH-1:0] in_bits, // bitstream, bit endian packed
    input  logic [31:0]      in_pad, // Lookahead of 32 bits
    output logic [WIDTH-1:0] end_bits, // a single 1-hot bit indicating block end
    input  logic [WIDTH-1:0][5:0] nc_idx // coeff_token table index, {0-3} luma, {4} chroma DC, bit 5 = ac_flag
    );


    // State and arc flags (Per Bit)
    logic [WIDTH+31:0][5:0] s_coeff_token; // coeff_token state [nc_idx]
      
    logic [WIDTH+31:0][1:15]          s_total_zeros_y;  // luma total_zeros state [num_coeff]
    logic [WIDTH+31:0][1:3 ]          s_total_zeros_ch; // chroma dc total_zeros state [num_coeff]
    logic       [31:0][1:15]          s_total_zeros_y_reg;  
    logic       [31:0][1:3 ]          s_total_zeros_ch_reg; 
    logic [WIDTH+31:0][1:15][115:0] arc_total_zeros_y;  
    logic [WIDTH+31:0][1:3 ][80:0]  arc_total_zeros_ch; 
    
    logic [WIDTH+31:0][2:15][1:14]         s_run_before; // state s_run_before [num_coeff][zeros_left]
    logic       [31:0][2:15][1:14]         s_run_before_reg; 
    logic [WIDTH+31:0][1:15][0:14][15:0] arc_run_before; 
    logic [WIDTH+31:0][1:14][0:14]           run_before; // decoded run befors
    static logic      [1:14][0:14][3:0]      run_before_len = { // static table of run before lengths 
           { 4'd1, 4'd1, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd1, 4'd2, 4'd2, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd2, 4'd2, 4'd2, 4'd2, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd2, 4'd2, 4'd2, 4'd3, 4'd3, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd2, 4'd2, 4'd3, 4'd3, 4'd3, 4'd3, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd2, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 },
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd0, 4'd0, 4'd0, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd0, 4'd0, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd0, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9, 4'd0, 4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9, 4'd10,4'd0 }, 
           { 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9, 4'd10,4'd11} 
           };

    
    logic [WIDTH+31:0][0:15]                      level_prefix;
    logic [WIDTH+31:0][1:16][1:16][0:6]         s_level_y;  // Luma Level State [num_coeff][coeff_remaining][suflen], num_coeff={16,17} if maxcoeff==num_coeff=={15,16}
    logic [WIDTH+31:0][1:4 ][1:4 ][0:6]         s_level_ch; // chroma dc Level State [num_coeff][coeff_remaining][suffix_len
    logic       [31:0][1:16][1:16][0:6]         s_level_y_reg;  // Luma Level State [num_coeff][coeff_remaining][suflen], num_coeff={16,17} if maxcoeff==num_coeff=={15,16}
    logic       [31:0][1:4 ][1:4 ][0:6]         s_level_ch_reg; // chroma dc Level State [num_coeff][coeff_remaining][suffix_len
    logic [WIDTH+31:0][1:16][1:16][0:6][28:0] arc_level_y;
    logic [WIDTH+31:0][1:4 ][1:4 ][0:6][28:0] arc_level_ch; // [num_coeff][coeff_remaining][arc_id]
    
    logic [WIDTH+31:0][  4:0] arc_coeff_token_last; // [arc_id] 0-4 coeff token
    logic [WIDTH+31:0][111:0]       arc_level_last_y; // arc from coeff is max for 4,15,16 and no zeros.
    logic [WIDTH+31:0][ 79:0]       arc_level_last_ch; // arc from coeff is max for 4,15,16 and no zeros.
    logic [WIDTH+31:0][31:0]  arc_total_zeros_last_y; // arc from total_zeros with num_coeff=1 or total_zeros=0
    logic [WIDTH+31:0][31:0]  arc_total_zeros_last_ch; // arc from total_zeros with num_coeff=1 or total_zeros=0
    logic [WIDTH+31:0][15:0]   arc_run_before_last; // arc from total_zeros with num_coeff=1 or total_zeros=0
    logic [WIDTH+31:0]                      s_last;     
    logic       [31:0]                      s_last_reg;     
    logic [WIDTH+31:0] bits;
    
    assign bits = { in_bits, in_pad };
    
    // Loop Over bitpositions 
    always_comb begin : _lattice_array
        // Clear last arcs
        arc_coeff_token_last = 0;
        arc_level_last_y = 0;
        arc_level_last_ch = 0;
        arc_total_zeros_last_y = 0;
        arc_total_zeros_last_ch = 0;
        arc_run_before_last = 0;
        
        // Clear state arcs
        arc_level_y = 0;
        arc_level_ch = 0;
        arc_total_zeros_y = 0;
        arc_total_zeros_ch = 0;
        arc_run_before = 0;
    
        // Clear state
        s_level_ch = 0;
        s_level_y = 0;
        s_coeff_token = 0;
        s_total_zeros_y = 0;
        s_total_zeros_ch = 0;
        s_run_before = 0;

        // Clear decode arrays
        run_before = 0;
        level_prefix = 0;
        
        // Set state

        for( int bp = WIDTH-1+32; bp >= 32; bp-- ) begin : _lattice_col
            
            // set control inputs
            s_coeff_token[bp] = nc_idx[bp-32];
            
            // Coeff Token + Trailing Ones
            begin : _coeff_token
                // Special End case: num_coeff==0
                if( bits[bp-:1 ]== 1'b1                ) arc_coeff_token_last[bp-1][0]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 0, 1
                if( bits[bp-:2 ]== 2'b11               ) arc_coeff_token_last[bp-2][1]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 0, 11
                if( bits[bp-:4 ]== 4'b1111             ) arc_coeff_token_last[bp-4][2]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 0, 1111
                if( bits[bp-:6 ]== 6'b000011           ) arc_coeff_token_last[bp-6][3]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 0, 000011
                if( bits[bp-:2 ]== 2'b01               ) arc_coeff_token_last[bp-2][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 0, 0, 01
                
                // Special skip direct to Total_Zero if t1s = num coeff >
                if( bits[bp-:2 ]== 2'b01               ) arc_total_zeros_y[bp-3 ][1][0]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 1, 01
                if( bits[bp-:3 ]== 3'b001              ) arc_total_zeros_y[bp-5 ][2][0]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 2, 001
                if( bits[bp-:5 ]== 5'b00011            ) arc_total_zeros_y[bp-8 ][3][0]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 3, 00011
                if( bits[bp-:2 ]== 2'b10               ) arc_total_zeros_y[bp-3 ][1][1]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 1, 10
                if( bits[bp-:3 ]== 3'b011              ) arc_total_zeros_y[bp-5 ][2][1]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 2, 011
                if( bits[bp-:4 ]== 4'b0101             ) arc_total_zeros_y[bp-7 ][3][1]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 3, 0101
                if( bits[bp-:4 ]== 4'b1110             ) arc_total_zeros_y[bp-5 ][1][2]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 1, 1110
                if( bits[bp-:4 ]== 4'b1101             ) arc_total_zeros_y[bp-6 ][2][2]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 2, 1101
                if( bits[bp-:4 ]== 4'b1100             ) arc_total_zeros_y[bp-7 ][3][2]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 3, 1100
                if( bits[bp-:6 ]== 6'b000001           ) arc_total_zeros_y[bp-7 ][1][3]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 1, 000001
                if( bits[bp-:6 ]== 6'b000110           ) arc_total_zeros_y[bp-8 ][2][3]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 2, 000110
                if( bits[bp-:6 ]== 6'b001011           ) arc_total_zeros_y[bp-9 ][3][3]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 3, 001011
                if( bits[bp-:1 ]== 1'b1                ) arc_total_zeros_ch[bp-2][1][0]  =  s_coeff_token[bp][4]; // coeff_token 4, 1, 1, 1
                if( bits[bp-:3 ]== 3'b001              ) arc_total_zeros_ch[bp-5][2][0]  =  s_coeff_token[bp][4]; // coeff_token 4, 2, 2, 001
                if( bits[bp-:6 ]== 6'b000101           ) arc_total_zeros_ch[bp-9][3][0]  =  s_coeff_token[bp][4]; // coeff_token 4, 3, 3, 000101

                // Special case for AC blocks with max nc=15, and no Zero syntax is required.
                // Map cases with ac_flag = s_coeff_token[bp][4] with NC to the NC=16 coeff lattice at 1 step further.
                if( bits[bp-:16]==16'b0000000000000111 ) arc_level_y[bp-16][15][15][1][ 4]  =  s_coeff_token[bp][0] & !s_coeff_token[bp][4]; // coeff_token 0, 0, 15, 0000000000000111
                if( bits[bp-:16]==16'b0000000000001010 ) arc_level_y[bp-17][15][14][1][ 4]  =  s_coeff_token[bp][0] & !s_coeff_token[bp][4]; // coeff_token 0, 1, 15, 0000000000001010
                if( bits[bp-:16]==16'b0000000000001001 ) arc_level_y[bp-18][15][13][1][ 4]  =  s_coeff_token[bp][0] & !s_coeff_token[bp][4]; // coeff_token 0, 2, 15, 0000000000001001
                if( bits[bp-:16]==16'b0000000000001100 ) arc_level_y[bp-19][15][12][0][ 4]  =  s_coeff_token[bp][0] & !s_coeff_token[bp][4]; // coeff_token 0, 3, 15, 0000000000001100
                if( bits[bp-:16]==16'b0000000000000111 ) arc_level_y[bp-16][16][15][1][ 8]  =  s_coeff_token[bp][0] &  s_coeff_token[bp][4]; // coeff_token 0, 0, 15, 0000000000000111
                if( bits[bp-:16]==16'b0000000000001010 ) arc_level_y[bp-17][16][14][1][ 8]  =  s_coeff_token[bp][0] &  s_coeff_token[bp][4]; // coeff_token 0, 1, 15, 0000000000001010
                if( bits[bp-:16]==16'b0000000000001001 ) arc_level_y[bp-18][16][13][1][ 8]  =  s_coeff_token[bp][0] &  s_coeff_token[bp][4]; // coeff_token 0, 2, 15, 0000000000001001
                if( bits[bp-:16]==16'b0000000000001100 ) arc_level_y[bp-19][16][12][0][ 8]  =  s_coeff_token[bp][0] &  s_coeff_token[bp][4]; // coeff_token 0, 3, 15, 0000000000001100
                
                if( bits[bp-:14]==14'b00000000001001   ) arc_level_y[bp-14][15][15][1][ 5]  =  s_coeff_token[bp][1] & !s_coeff_token[bp][4]; // coeff_token 1, 0, 15, 00000000001001
                if( bits[bp-:14]==14'b00000000001000   ) arc_level_y[bp-15][15][14][1][ 5]  =  s_coeff_token[bp][1] & !s_coeff_token[bp][4]; // coeff_token 1, 1, 15, 00000000001000
                if( bits[bp-:14]==14'b00000000001010   ) arc_level_y[bp-16][15][13][1][ 5]  =  s_coeff_token[bp][1] & !s_coeff_token[bp][4]; // coeff_token 1, 2, 15, 00000000001010
                if( bits[bp-:13]==13'b0000000000001    ) arc_level_y[bp-16][15][12][0][ 5]  =  s_coeff_token[bp][1] & !s_coeff_token[bp][4]; // coeff_token 1, 3, 15, 0000000000001
                if( bits[bp-:14]==14'b00000000001001   ) arc_level_y[bp-14][16][15][1][ 9]  =  s_coeff_token[bp][1] &  s_coeff_token[bp][4]; // coeff_token 1, 0, 15, 00000000001001
                if( bits[bp-:14]==14'b00000000001000   ) arc_level_y[bp-15][16][14][1][ 9]  =  s_coeff_token[bp][1] &  s_coeff_token[bp][4]; // coeff_token 1, 1, 15, 00000000001000
                if( bits[bp-:14]==14'b00000000001010   ) arc_level_y[bp-16][16][13][1][ 9]  =  s_coeff_token[bp][1] &  s_coeff_token[bp][4]; // coeff_token 1, 2, 15, 00000000001010
                if( bits[bp-:13]==13'b0000000000001    ) arc_level_y[bp-16][16][12][0][ 9]  =  s_coeff_token[bp][1] &  s_coeff_token[bp][4]; // coeff_token 1, 3, 15, 0000000000001
                
                if( bits[bp-:10]==10'b0000000101       ) arc_level_y[bp-10][15][15][1][ 6]  =  s_coeff_token[bp][2] & !s_coeff_token[bp][4]; // coeff_token 2, 0, 15, 0000000101
                if( bits[bp-:10]==10'b0000001000       ) arc_level_y[bp-11][15][14][1][ 6]  =  s_coeff_token[bp][2] & !s_coeff_token[bp][4]; // coeff_token 2, 1, 15, 0000001000
                if( bits[bp-:10]==10'b0000000111       ) arc_level_y[bp-12][15][13][1][ 6]  =  s_coeff_token[bp][2] & !s_coeff_token[bp][4]; // coeff_token 2, 2, 15, 0000000111
                if( bits[bp-:10]==10'b0000000110       ) arc_level_y[bp-13][15][12][0][ 6]  =  s_coeff_token[bp][2] & !s_coeff_token[bp][4]; // coeff_token 2, 3, 15, 0000000110
                if( bits[bp-:10]==10'b0000000101       ) arc_level_y[bp-10][16][15][1][10]  =  s_coeff_token[bp][2] &  s_coeff_token[bp][4]; // coeff_token 2, 0, 15, 0000000101
                if( bits[bp-:10]==10'b0000001000       ) arc_level_y[bp-11][16][14][1][10]  =  s_coeff_token[bp][2] &  s_coeff_token[bp][4]; // coeff_token 2, 1, 15, 0000001000
                if( bits[bp-:10]==10'b0000000111       ) arc_level_y[bp-12][16][13][1][10]  =  s_coeff_token[bp][2] &  s_coeff_token[bp][4]; // coeff_token 2, 2, 15, 0000000111
                if( bits[bp-:10]==10'b0000000110       ) arc_level_y[bp-13][16][12][0][10]  =  s_coeff_token[bp][2] &  s_coeff_token[bp][4]; // coeff_token 2, 3, 15, 0000000110

                if( bits[bp-:6 ]== 6'b111000           ) arc_level_y[bp-6 ][15][15][1][ 7]  =  s_coeff_token[bp][3] & !s_coeff_token[bp][4]; // coeff_token 3, 0, 15, 111000
                if( bits[bp-:6 ]== 6'b111001           ) arc_level_y[bp-7 ][15][14][1][ 7]  =  s_coeff_token[bp][3] & !s_coeff_token[bp][4]; // coeff_token 3, 1, 15, 111001
                if( bits[bp-:6 ]== 6'b111010           ) arc_level_y[bp-8 ][15][13][1][ 7]  =  s_coeff_token[bp][3] & !s_coeff_token[bp][4]; // coeff_token 3, 2, 15, 111010
                if( bits[bp-:6 ]== 6'b111011           ) arc_level_y[bp-9 ][15][12][0][ 7]  =  s_coeff_token[bp][3] & !s_coeff_token[bp][4]; // coeff_token 3, 3, 15, 111011
                if( bits[bp-:6 ]== 6'b111000           ) arc_level_y[bp-6 ][16][15][1][11]  =  s_coeff_token[bp][3] &  s_coeff_token[bp][4]; // coeff_token 3, 0, 15, 111000
                if( bits[bp-:6 ]== 6'b111001           ) arc_level_y[bp-7 ][16][14][1][11]  =  s_coeff_token[bp][3] &  s_coeff_token[bp][4]; // coeff_token 3, 1, 15, 111001
                if( bits[bp-:6 ]== 6'b111010           ) arc_level_y[bp-8 ][16][13][1][11]  =  s_coeff_token[bp][3] &  s_coeff_token[bp][4]; // coeff_token 3, 2, 15, 111010
                if( bits[bp-:6 ]== 6'b111011           ) arc_level_y[bp-9 ][16][12][0][11]  =  s_coeff_token[bp][3] &  s_coeff_token[bp][4]; // coeff_token 3, 3, 15, 111011
                

                // Bulk array 
                // *** exclude collisions from special cases above ***
                 // coeff_token 0, 0, 0, 1
                if( bits[bp-:6 ]== 6'b000101           ) arc_level_y[bp-6 ][1][1][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 1, 000101
                 // coeff_token 0, 1, 1, 01
                if( bits[bp-:8 ]== 8'b00000111         ) arc_level_y[bp-8 ][2][2][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 2, 00000111
                if( bits[bp-:6 ]== 6'b000100           ) arc_level_y[bp-7 ][2][1][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 2, 000100
                 // coeff_token 0, 2, 2, 001
                if( bits[bp-:9 ]== 9'b000000111        ) arc_level_y[bp-9 ][3][3][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 3, 000000111
                if( bits[bp-:8 ]== 8'b00000110         ) arc_level_y[bp-9 ][3][2][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 3, 00000110
                if( bits[bp-:7 ]== 7'b0000101          ) arc_level_y[bp-9 ][3][1][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 3, 0000101
                 // coeff_token 0, 3, 3, 00011
                if( bits[bp-:10]==10'b0000000111       ) arc_level_y[bp-10][4][4][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 4, 0000000111
                if( bits[bp-:9 ]== 9'b000000110        ) arc_level_y[bp-10][4][3][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 4, 000000110
                if( bits[bp-:8 ]== 8'b00000101         ) arc_level_y[bp-10][4][2][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 4, 00000101
                if( bits[bp-:6 ]== 6'b000011           ) arc_level_y[bp-9 ][4][1][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 4, 000011
                if( bits[bp-:11]==11'b00000000111      ) arc_level_y[bp-11][5][5][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 5, 00000000111
                if( bits[bp-:10]==10'b0000000110       ) arc_level_y[bp-11][5][4][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 5, 0000000110
                if( bits[bp-:9 ]== 9'b000000101        ) arc_level_y[bp-11][5][3][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 5, 000000101
                if( bits[bp-:7 ]== 7'b0000100          ) arc_level_y[bp-10][5][2][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 5, 0000100
                if( bits[bp-:13]==13'b0000000001111    ) arc_level_y[bp-13][6][6][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 6, 0000000001111
                if( bits[bp-:11]==11'b00000000110      ) arc_level_y[bp-12][6][5][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 6, 00000000110
                if( bits[bp-:10]==10'b0000000101       ) arc_level_y[bp-12][6][4][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 6, 0000000101
                if( bits[bp-:8 ]== 8'b00000100         ) arc_level_y[bp-11][6][3][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 6, 00000100
                if( bits[bp-:13]==13'b0000000001011    ) arc_level_y[bp-13][7][7][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 7, 0000000001011
                if( bits[bp-:13]==13'b0000000001110    ) arc_level_y[bp-14][7][6][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 7, 0000000001110
                if( bits[bp-:11]==11'b00000000101      ) arc_level_y[bp-13][7][5][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 7, 00000000101
                if( bits[bp-:9 ]== 9'b000000100        ) arc_level_y[bp-12][7][4][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 7, 000000100
                if( bits[bp-:13]==13'b0000000001000    ) arc_level_y[bp-13][8][8][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 8, 0000000001000
                if( bits[bp-:13]==13'b0000000001010    ) arc_level_y[bp-14][8][7][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 8, 0000000001010
                if( bits[bp-:13]==13'b0000000001101    ) arc_level_y[bp-15][8][6][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 8, 0000000001101
                if( bits[bp-:10]==10'b0000000100       ) arc_level_y[bp-13][8][5][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 8, 0000000100
                if( bits[bp-:14]==14'b00000000001111   ) arc_level_y[bp-14][9][9][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 9, 00000000001111
                if( bits[bp-:14]==14'b00000000001110   ) arc_level_y[bp-15][9][8][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 9, 00000000001110
                if( bits[bp-:13]==13'b0000000001001    ) arc_level_y[bp-15][9][7][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 9, 0000000001001
                if( bits[bp-:11]==11'b00000000100      ) arc_level_y[bp-14][9][6][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 9, 00000000100
                if( bits[bp-:14]==14'b00000000001011   ) arc_level_y[bp-14][10][10][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 10, 00000000001011
                if( bits[bp-:14]==14'b00000000001010   ) arc_level_y[bp-15][10][9][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 10, 00000000001010
                if( bits[bp-:14]==14'b00000000001101   ) arc_level_y[bp-16][10][8][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 10, 00000000001101
                if( bits[bp-:13]==13'b0000000001100    ) arc_level_y[bp-16][10][7][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 10, 0000000001100
                if( bits[bp-:15]==15'b000000000001111  ) arc_level_y[bp-15][11][11][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 11, 000000000001111
                if( bits[bp-:15]==15'b000000000001110  ) arc_level_y[bp-16][11][10][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 11, 000000000001110
                if( bits[bp-:14]==14'b00000000001001   ) arc_level_y[bp-16][11][9][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 11, 00000000001001
                if( bits[bp-:14]==14'b00000000001100   ) arc_level_y[bp-17][11][8][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 11, 00000000001100
                if( bits[bp-:15]==15'b000000000001011  ) arc_level_y[bp-15][12][12][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 12, 000000000001011
                if( bits[bp-:15]==15'b000000000001010  ) arc_level_y[bp-16][12][11][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 12, 000000000001010
                if( bits[bp-:15]==15'b000000000001101  ) arc_level_y[bp-17][12][10][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 12, 000000000001101
                if( bits[bp-:14]==14'b00000000001000   ) arc_level_y[bp-17][12][9][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 12, 00000000001000
                if( bits[bp-:16]==16'b0000000000001111 ) arc_level_y[bp-16][13][13][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 13, 0000000000001111
                if( bits[bp-:15]==15'b000000000000001  ) arc_level_y[bp-16][13][12][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 13, 000000000000001
                if( bits[bp-:15]==15'b000000000001001  ) arc_level_y[bp-17][13][11][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 13, 000000000001001
                if( bits[bp-:15]==15'b000000000001100  ) arc_level_y[bp-18][13][10][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 13, 000000000001100
                if( bits[bp-:16]==16'b0000000000001011 ) arc_level_y[bp-16][14][14][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 14, 0000000000001011
                if( bits[bp-:16]==16'b0000000000001110 ) arc_level_y[bp-17][14][13][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 14, 0000000000001110
                if( bits[bp-:16]==16'b0000000000001101 ) arc_level_y[bp-18][14][12][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 14, 0000000000001101
                if( bits[bp-:15]==15'b000000000001000  ) arc_level_y[bp-18][14][11][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 14, 000000000001000
                 // coeff_token 0, 0, 15, 0000000000000111
                 // coeff_token 0, 1, 15, 0000000000001010
                 // coeff_token 0, 2, 15, 0000000000001001
                 // coeff_token 0, 3, 15, 0000000000001100
                if( bits[bp-:16]==16'b0000000000000100 ) arc_level_y[bp-16][16][16][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 0, 16, 0000000000000100
                if( bits[bp-:16]==16'b0000000000000110 ) arc_level_y[bp-17][16][15][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 1, 16, 0000000000000110
                if( bits[bp-:16]==16'b0000000000000101 ) arc_level_y[bp-18][16][14][1][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 2, 16, 0000000000000101
                if( bits[bp-:16]==16'b0000000000001000 ) arc_level_y[bp-19][16][13][0][4]  =  s_coeff_token[bp][0]; // coeff_token 0, 3, 16, 0000000000001000
                 // coeff_token 1, 0, 0, 11
                if( bits[bp-:6 ]== 6'b001011           ) arc_level_y[bp-6 ][1][1][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 1, 001011
                 // coeff_token 1, 1, 1, 10
                if( bits[bp-:6 ]== 6'b000111           ) arc_level_y[bp-6 ][2][2][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 2, 000111
                if( bits[bp-:5 ]== 5'b00111            ) arc_level_y[bp-6 ][2][1][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 2, 00111
                 // coeff_token 1, 2, 2, 011
                if( bits[bp-:7 ]== 7'b0000111          ) arc_level_y[bp-7 ][3][3][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 3, 0000111
                if( bits[bp-:6 ]== 6'b001010           ) arc_level_y[bp-7 ][3][2][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 3, 001010
                if( bits[bp-:6 ]== 6'b001001           ) arc_level_y[bp-8 ][3][1][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 3, 001001
                 // coeff_token 1, 3, 3, 0101
                if( bits[bp-:8 ]== 8'b00000111         ) arc_level_y[bp-8 ][4][4][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 4, 00000111
                if( bits[bp-:6 ]== 6'b000110           ) arc_level_y[bp-7 ][4][3][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 4, 000110
                if( bits[bp-:6 ]== 6'b000101           ) arc_level_y[bp-8 ][4][2][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 4, 000101
                if( bits[bp-:4 ]== 4'b0100             ) arc_level_y[bp-7 ][4][1][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 4, 0100
                if( bits[bp-:8 ]== 8'b00000100         ) arc_level_y[bp-8 ][5][5][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 5, 00000100
                if( bits[bp-:7 ]== 7'b0000110          ) arc_level_y[bp-8 ][5][4][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 5, 0000110
                if( bits[bp-:7 ]== 7'b0000101          ) arc_level_y[bp-9 ][5][3][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 5, 0000101
                if( bits[bp-:5 ]== 5'b00110            ) arc_level_y[bp-8 ][5][2][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 5, 00110
                if( bits[bp-:9 ]== 9'b000000111        ) arc_level_y[bp-9 ][6][6][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 6, 000000111
                if( bits[bp-:8 ]== 8'b00000110         ) arc_level_y[bp-9 ][6][5][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 6, 00000110
                if( bits[bp-:8 ]== 8'b00000101         ) arc_level_y[bp-10][6][4][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 6, 00000101
                if( bits[bp-:6 ]== 6'b001000           ) arc_level_y[bp-9 ][6][3][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 6, 001000
                if( bits[bp-:11]==11'b00000001111      ) arc_level_y[bp-11][7][7][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 7, 00000001111
                if( bits[bp-:9 ]== 9'b000000110        ) arc_level_y[bp-10][7][6][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 7, 000000110
                if( bits[bp-:9 ]== 9'b000000101        ) arc_level_y[bp-11][7][5][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 7, 000000101
                if( bits[bp-:6 ]== 6'b000100           ) arc_level_y[bp-9 ][7][4][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 7, 000100
                if( bits[bp-:11]==11'b00000001011      ) arc_level_y[bp-11][8][8][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 8, 00000001011
                if( bits[bp-:11]==11'b00000001110      ) arc_level_y[bp-12][8][7][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 8, 00000001110
                if( bits[bp-:11]==11'b00000001101      ) arc_level_y[bp-13][8][6][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 8, 00000001101
                if( bits[bp-:7 ]== 7'b0000100          ) arc_level_y[bp-10][8][5][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 8, 0000100
                if( bits[bp-:12]==12'b000000001111     ) arc_level_y[bp-12][9][9][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 9, 000000001111
                if( bits[bp-:11]==11'b00000001010      ) arc_level_y[bp-12][9][8][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 9, 00000001010
                if( bits[bp-:11]==11'b00000001001      ) arc_level_y[bp-13][9][7][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 9, 00000001001
                if( bits[bp-:9 ]== 9'b000000100        ) arc_level_y[bp-12][9][6][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 9, 000000100
                if( bits[bp-:12]==12'b000000001011     ) arc_level_y[bp-12][10][10][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 10, 000000001011
                if( bits[bp-:12]==12'b000000001110     ) arc_level_y[bp-13][10][9][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 10, 000000001110
                if( bits[bp-:12]==12'b000000001101     ) arc_level_y[bp-14][10][8][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 10, 000000001101
                if( bits[bp-:11]==11'b00000001100      ) arc_level_y[bp-14][10][7][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 10, 00000001100
                if( bits[bp-:12]==12'b000000001000     ) arc_level_y[bp-12][11][11][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 11, 000000001000
                if( bits[bp-:12]==12'b000000001010     ) arc_level_y[bp-13][11][10][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 11, 000000001010
                if( bits[bp-:12]==12'b000000001001     ) arc_level_y[bp-14][11][9][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 11, 000000001001
                if( bits[bp-:11]==11'b00000001000      ) arc_level_y[bp-14][11][8][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 11, 00000001000
                if( bits[bp-:13]==13'b0000000001111    ) arc_level_y[bp-13][12][12][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 12, 0000000001111
                if( bits[bp-:13]==13'b0000000001110    ) arc_level_y[bp-14][12][11][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 12, 0000000001110
                if( bits[bp-:13]==13'b0000000001101    ) arc_level_y[bp-15][12][10][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 12, 0000000001101
                if( bits[bp-:12]==12'b000000001100     ) arc_level_y[bp-15][12][9][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 12, 000000001100
                if( bits[bp-:13]==13'b0000000001011    ) arc_level_y[bp-13][13][13][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 13, 0000000001011
                if( bits[bp-:13]==13'b0000000001010    ) arc_level_y[bp-14][13][12][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 13, 0000000001010
                if( bits[bp-:13]==13'b0000000001001    ) arc_level_y[bp-15][13][11][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 13, 0000000001001
                if( bits[bp-:13]==13'b0000000001100    ) arc_level_y[bp-16][13][10][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 13, 0000000001100
                if( bits[bp-:13]==13'b0000000000111    ) arc_level_y[bp-13][14][14][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 14, 0000000000111
                if( bits[bp-:14]==14'b00000000001011   ) arc_level_y[bp-15][14][13][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 14, 00000000001011
                if( bits[bp-:13]==13'b0000000000110    ) arc_level_y[bp-15][14][12][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 14, 0000000000110
                if( bits[bp-:13]==13'b0000000001000    ) arc_level_y[bp-16][14][11][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 14, 0000000001000
                 // coeff_token 1, 0, 15, 00000000001001
                 // coeff_token 1, 1, 15, 00000000001000
                 // coeff_token 1, 2, 15, 00000000001010
                 // coeff_token 1, 3, 15, 0000000000001
                if( bits[bp-:14]==14'b00000000000111   ) arc_level_y[bp-14][16][16][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 0, 16, 00000000000111
                if( bits[bp-:14]==14'b00000000000110   ) arc_level_y[bp-15][16][15][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 1, 16, 00000000000110
                if( bits[bp-:14]==14'b00000000000101   ) arc_level_y[bp-16][16][14][1][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 2, 16, 00000000000101
                if( bits[bp-:14]==14'b00000000000100   ) arc_level_y[bp-17][16][13][0][5]  =  s_coeff_token[bp][1]; // coeff_token 1, 3, 16, 00000000000100
                 // coeff_token 2, 0, 0, 1111
                if( bits[bp-:6 ]== 6'b001111           ) arc_level_y[bp-6 ][1][1][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 1, 001111
                 // coeff_token 2, 1, 1, 1110
                if( bits[bp-:6 ]== 6'b001011           ) arc_level_y[bp-6 ][2][2][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 2, 001011
                if( bits[bp-:5 ]== 5'b01111            ) arc_level_y[bp-6 ][2][1][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 2, 01111
                 // coeff_token 2, 2, 2, 1101
                if( bits[bp-:6 ]== 6'b001000           ) arc_level_y[bp-6 ][3][3][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 3, 001000
                if( bits[bp-:5 ]== 5'b01100            ) arc_level_y[bp-6 ][3][2][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 3, 01100
                if( bits[bp-:5 ]== 5'b01110            ) arc_level_y[bp-7 ][3][1][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 3, 01110
                 // coeff_token 2, 3, 3, 1100
                if( bits[bp-:7 ]== 7'b0001111          ) arc_level_y[bp-7 ][4][4][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 4, 0001111
                if( bits[bp-:5 ]== 5'b01010            ) arc_level_y[bp-6 ][4][3][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 4, 01010
                if( bits[bp-:5 ]== 5'b01011            ) arc_level_y[bp-7 ][4][2][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 4, 01011
                if( bits[bp-:4 ]== 4'b1011             ) arc_level_y[bp-7 ][4][1][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 4, 1011
                if( bits[bp-:7 ]== 7'b0001011          ) arc_level_y[bp-7 ][5][5][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 5, 0001011
                if( bits[bp-:5 ]== 5'b01000            ) arc_level_y[bp-6 ][5][4][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 5, 01000
                if( bits[bp-:5 ]== 5'b01001            ) arc_level_y[bp-7 ][5][3][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 5, 01001
                if( bits[bp-:4 ]== 4'b1010             ) arc_level_y[bp-7 ][5][2][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 5, 1010
                if( bits[bp-:7 ]== 7'b0001001          ) arc_level_y[bp-7 ][6][6][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 6, 0001001
                if( bits[bp-:6 ]== 6'b001110           ) arc_level_y[bp-7 ][6][5][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 6, 001110
                if( bits[bp-:6 ]== 6'b001101           ) arc_level_y[bp-8 ][6][4][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 6, 001101
                if( bits[bp-:4 ]== 4'b1001             ) arc_level_y[bp-7 ][6][3][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 6, 1001
                if( bits[bp-:7 ]== 7'b0001000          ) arc_level_y[bp-7 ][7][7][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 7, 0001000
                if( bits[bp-:6 ]== 6'b001010           ) arc_level_y[bp-7 ][7][6][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 7, 001010
                if( bits[bp-:6 ]== 6'b001001           ) arc_level_y[bp-8 ][7][5][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 7, 001001
                if( bits[bp-:4 ]== 4'b1000             ) arc_level_y[bp-7 ][7][4][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 7, 1000
                if( bits[bp-:8 ]== 8'b00001111         ) arc_level_y[bp-8 ][8][8][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 8, 00001111
                if( bits[bp-:7 ]== 7'b0001110          ) arc_level_y[bp-8 ][8][7][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 8, 0001110
                if( bits[bp-:7 ]== 7'b0001101          ) arc_level_y[bp-9 ][8][6][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 8, 0001101
                if( bits[bp-:5 ]== 5'b01101            ) arc_level_y[bp-8 ][8][5][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 8, 01101
                if( bits[bp-:8 ]== 8'b00001011         ) arc_level_y[bp-8 ][9][9][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 9, 00001011
                if( bits[bp-:8 ]== 8'b00001110         ) arc_level_y[bp-9 ][9][8][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 9, 00001110
                if( bits[bp-:7 ]== 7'b0001010          ) arc_level_y[bp-9 ][9][7][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 9, 0001010
                if( bits[bp-:6 ]== 6'b001100           ) arc_level_y[bp-9 ][9][6][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 9, 001100
                if( bits[bp-:9 ]== 9'b000001111        ) arc_level_y[bp-9 ][10][10][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 10, 000001111
                if( bits[bp-:8 ]== 8'b00001010         ) arc_level_y[bp-9 ][10][9][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 10, 00001010
                if( bits[bp-:8 ]== 8'b00001101         ) arc_level_y[bp-10][10][8][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 10, 00001101
                if( bits[bp-:7 ]== 7'b0001100          ) arc_level_y[bp-10][10][7][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 10, 0001100
                if( bits[bp-:9 ]== 9'b000001011        ) arc_level_y[bp-9 ][11][11][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 11, 000001011
                if( bits[bp-:9 ]== 9'b000001110        ) arc_level_y[bp-10][11][10][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 11, 000001110
                if( bits[bp-:8 ]== 8'b00001001         ) arc_level_y[bp-10][11][9][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 11, 00001001
                if( bits[bp-:8 ]== 8'b00001100         ) arc_level_y[bp-11][11][8][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 11, 00001100
                if( bits[bp-:9 ]== 9'b000001000        ) arc_level_y[bp-9 ][12][12][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 12, 000001000
                if( bits[bp-:9 ]== 9'b000001010        ) arc_level_y[bp-10][12][11][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 12, 000001010
                if( bits[bp-:9 ]== 9'b000001101        ) arc_level_y[bp-11][12][10][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 12, 000001101
                if( bits[bp-:8 ]== 8'b00001000         ) arc_level_y[bp-11][12][9][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 12, 00001000
                if( bits[bp-:10]==10'b0000001101       ) arc_level_y[bp-10][13][13][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 13, 0000001101
                if( bits[bp-:9 ]== 9'b000000111        ) arc_level_y[bp-10][13][12][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 13, 000000111
                if( bits[bp-:9 ]== 9'b000001001        ) arc_level_y[bp-11][13][11][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 13, 000001001
                if( bits[bp-:9 ]== 9'b000001100        ) arc_level_y[bp-12][13][10][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 13, 000001100
                if( bits[bp-:10]==10'b0000001001       ) arc_level_y[bp-10][14][14][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 14, 0000001001
                if( bits[bp-:10]==10'b0000001100       ) arc_level_y[bp-11][14][13][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 14, 0000001100
                if( bits[bp-:10]==10'b0000001011       ) arc_level_y[bp-12][14][12][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 14, 0000001011
                if( bits[bp-:10]==10'b0000001010       ) arc_level_y[bp-13][14][11][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 14, 0000001010
                 // coeff_token 2, 0, 15, 0000000101
                 // coeff_token 2, 1, 15, 0000001000
                 // coeff_token 2, 2, 15, 0000000111
                 // coeff_token 2, 3, 15, 0000000110
                if( bits[bp-:10]==10'b0000000001       ) arc_level_y[bp-10][16][16][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 0, 16, 0000000001
                if( bits[bp-:10]==10'b0000000100       ) arc_level_y[bp-11][16][15][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 1, 16, 0000000100
                if( bits[bp-:10]==10'b0000000011       ) arc_level_y[bp-12][16][14][1][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 2, 16, 0000000011
                if( bits[bp-:10]==10'b0000000010       ) arc_level_y[bp-13][16][13][0][6]  =  s_coeff_token[bp][2]; // coeff_token 2, 3, 16, 0000000010
                 // coeff_token 3, 0, 0, 000011
                if( bits[bp-:6 ]== 6'b000000           ) arc_level_y[bp-6 ][1][1][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 1, 000000
                 // coeff_token 3, 1, 1, 000001
                if( bits[bp-:6 ]== 6'b000100           ) arc_level_y[bp-6 ][2][2][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 2, 000100
                if( bits[bp-:6 ]== 6'b000101           ) arc_level_y[bp-7 ][2][1][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 2, 000101
                 // coeff_token 3, 2, 2, 000110
                if( bits[bp-:6 ]== 6'b001000           ) arc_level_y[bp-6 ][3][3][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 3, 001000
                if( bits[bp-:6 ]== 6'b001001           ) arc_level_y[bp-7 ][3][2][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 3, 001001
                if( bits[bp-:6 ]== 6'b001010           ) arc_level_y[bp-8 ][3][1][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 3, 001010
                 // coeff_token 3, 3, 3, 001011
                if( bits[bp-:6 ]== 6'b001100           ) arc_level_y[bp-6 ][4][4][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 4, 001100
                if( bits[bp-:6 ]== 6'b001101           ) arc_level_y[bp-7 ][4][3][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 4, 001101
                if( bits[bp-:6 ]== 6'b001110           ) arc_level_y[bp-8 ][4][2][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 4, 001110
                if( bits[bp-:6 ]== 6'b001111           ) arc_level_y[bp-9 ][4][1][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 4, 001111
                if( bits[bp-:6 ]== 6'b010000           ) arc_level_y[bp-6 ][5][5][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 5, 010000
                if( bits[bp-:6 ]== 6'b010001           ) arc_level_y[bp-7 ][5][4][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 5, 010001
                if( bits[bp-:6 ]== 6'b010010           ) arc_level_y[bp-8 ][5][3][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 5, 010010
                if( bits[bp-:6 ]== 6'b010011           ) arc_level_y[bp-9 ][5][2][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 5, 010011
                if( bits[bp-:6 ]== 6'b010100           ) arc_level_y[bp-6 ][6][6][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 6, 010100
                if( bits[bp-:6 ]== 6'b010101           ) arc_level_y[bp-7 ][6][5][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 6, 010101
                if( bits[bp-:6 ]== 6'b010110           ) arc_level_y[bp-8 ][6][4][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 6, 010110
                if( bits[bp-:6 ]== 6'b010111           ) arc_level_y[bp-9 ][6][3][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 6, 010111
                if( bits[bp-:6 ]== 6'b011000           ) arc_level_y[bp-6 ][7][7][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 7, 011000
                if( bits[bp-:6 ]== 6'b011001           ) arc_level_y[bp-7 ][7][6][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 7, 011001
                if( bits[bp-:6 ]== 6'b011010           ) arc_level_y[bp-8 ][7][5][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 7, 011010
                if( bits[bp-:6 ]== 6'b011011           ) arc_level_y[bp-9 ][7][4][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 7, 011011
                if( bits[bp-:6 ]== 6'b011100           ) arc_level_y[bp-6 ][8][8][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 8, 011100
                if( bits[bp-:6 ]== 6'b011101           ) arc_level_y[bp-7 ][8][7][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 8, 011101
                if( bits[bp-:6 ]== 6'b011110           ) arc_level_y[bp-8 ][8][6][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 8, 011110
                if( bits[bp-:6 ]== 6'b011111           ) arc_level_y[bp-9 ][8][5][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 8, 011111
                if( bits[bp-:6 ]== 6'b100000           ) arc_level_y[bp-6 ][9][9][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 9, 100000
                if( bits[bp-:6 ]== 6'b100001           ) arc_level_y[bp-7 ][9][8][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 9, 100001
                if( bits[bp-:6 ]== 6'b100010           ) arc_level_y[bp-8 ][9][7][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 9, 100010
                if( bits[bp-:6 ]== 6'b100011           ) arc_level_y[bp-9 ][9][6][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 9, 100011
                if( bits[bp-:6 ]== 6'b100100           ) arc_level_y[bp-6 ][10][10][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 10, 100100
                if( bits[bp-:6 ]== 6'b100101           ) arc_level_y[bp-7 ][10][9][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 10, 100101
                if( bits[bp-:6 ]== 6'b100110           ) arc_level_y[bp-8 ][10][8][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 10, 100110
                if( bits[bp-:6 ]== 6'b100111           ) arc_level_y[bp-9 ][10][7][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 10, 100111
                if( bits[bp-:6 ]== 6'b101000           ) arc_level_y[bp-6 ][11][11][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 11, 101000
                if( bits[bp-:6 ]== 6'b101001           ) arc_level_y[bp-7 ][11][10][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 11, 101001
                if( bits[bp-:6 ]== 6'b101010           ) arc_level_y[bp-8 ][11][9][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 11, 101010
                if( bits[bp-:6 ]== 6'b101011           ) arc_level_y[bp-9 ][11][8][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 11, 101011
                if( bits[bp-:6 ]== 6'b101100           ) arc_level_y[bp-6 ][12][12][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 12, 101100
                if( bits[bp-:6 ]== 6'b101101           ) arc_level_y[bp-7 ][12][11][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 12, 101101
                if( bits[bp-:6 ]== 6'b101110           ) arc_level_y[bp-8 ][12][10][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 12, 101110
                if( bits[bp-:6 ]== 6'b101111           ) arc_level_y[bp-9 ][12][9][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 12, 101111
                if( bits[bp-:6 ]== 6'b110000           ) arc_level_y[bp-6 ][13][13][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 13, 110000
                if( bits[bp-:6 ]== 6'b110001           ) arc_level_y[bp-7 ][13][12][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 13, 110001
                if( bits[bp-:6 ]== 6'b110010           ) arc_level_y[bp-8 ][13][11][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 13, 110010
                if( bits[bp-:6 ]== 6'b110011           ) arc_level_y[bp-9 ][13][10][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 13, 110011
                if( bits[bp-:6 ]== 6'b110100           ) arc_level_y[bp-6 ][14][14][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 14, 110100
                if( bits[bp-:6 ]== 6'b110101           ) arc_level_y[bp-7 ][14][13][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 14, 110101
                if( bits[bp-:6 ]== 6'b110110           ) arc_level_y[bp-8 ][14][12][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 14, 110110
                if( bits[bp-:6 ]== 6'b110111           ) arc_level_y[bp-9 ][14][11][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 14, 110111
                 // coeff_token 3, 0, 15, 111000
                 // coeff_token 3, 1, 15, 111001
                 // coeff_token 3, 2, 15, 111010
                 // coeff_token 3, 3, 15, 111011
                if( bits[bp-:6 ]== 6'b111100           ) arc_level_y[bp-6 ][16][16][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 0, 16, 111100
                if( bits[bp-:6 ]== 6'b111101           ) arc_level_y[bp-7 ][16][15][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 1, 16, 111101
                if( bits[bp-:6 ]== 6'b111110           ) arc_level_y[bp-8 ][16][14][1][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 2, 16, 111110
                if( bits[bp-:6 ]== 6'b111111           ) arc_level_y[bp-9 ][16][13][0][7]  =  s_coeff_token[bp][3]; // coeff_token 3, 3, 16, 111111
                 // coeff_token 4, 0, 0, 01
                if( bits[bp-:6 ]== 6'b000111           ) arc_level_ch[bp-6 ][1][1][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 0, 1, 000111
                 // coeff_token 4, 1, 1, 1
                if( bits[bp-:6 ]== 6'b000100           ) arc_level_ch[bp-6 ][2][2][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 0, 2, 000100
                if( bits[bp-:6 ]== 6'b000110           ) arc_level_ch[bp-7 ][2][1][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 1, 2, 000110
                 // coeff_token 4, 2, 2, 001
                if( bits[bp-:6 ]== 6'b000011           ) arc_level_ch[bp-6 ][3][3][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 0, 3, 000011
                if( bits[bp-:7 ]== 7'b0000011          ) arc_level_ch[bp-8 ][3][2][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 1, 3, 0000011
                if( bits[bp-:7 ]== 7'b0000010          ) arc_level_ch[bp-9 ][3][1][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 2, 3, 0000010
                 // coeff_token 4, 3, 3, 000101
                if( bits[bp-:6 ]== 6'b000010           ) arc_level_ch[bp-6 ][4][4][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 0, 4, 000010
                if( bits[bp-:8 ]== 8'b00000011         ) arc_level_ch[bp-9 ][4][3][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 1, 4, 00000011
                if( bits[bp-:8 ]== 8'b00000010         ) arc_level_ch[bp-10][4][2][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 2, 4, 00000010
                if( bits[bp-:7 ]== 7'b0000000          ) arc_level_ch[bp-10][4][1][0][4]  =  s_coeff_token[bp][4]; // coeff_token 4, 3, 4, 0000000
            end // coeff_token
             
            // Decode Level Prefix
            
            begin : _level_prefix
                level_prefix[bp] = 0;
                if( bits[bp-:1 ] == 1'b1                 ) level_prefix[bp][0] = 1'b1;
                if( bits[bp-:2 ] == 2'b01                ) level_prefix[bp][1] = 1'b1;
                if( bits[bp-:3 ] == 3'b001               ) level_prefix[bp][2] = 1'b1;
                if( bits[bp-:4 ] == 4'b0001              ) level_prefix[bp][3] = 1'b1;
                if( bits[bp-:5 ] == 5'b00001             ) level_prefix[bp][4] = 1'b1;
                if( bits[bp-:6 ] == 6'b000001            ) level_prefix[bp][5] = 1'b1;
                if( bits[bp-:7 ] == 7'b0000001           ) level_prefix[bp][6] = 1'b1;
                if( bits[bp-:8 ] == 8'b00000001          ) level_prefix[bp][7] = 1'b1;
                if( bits[bp-:9 ] == 9'b000000001         ) level_prefix[bp][8] = 1'b1;
                if( bits[bp-:10] == 10'b0000000001       ) level_prefix[bp][9] = 1'b1;
                if( bits[bp-:11] == 11'b00000000001      ) level_prefix[bp][10] = 1'b1;
                if( bits[bp-:12] == 12'b000000000001     ) level_prefix[bp][11] = 1'b1;
                if( bits[bp-:13] == 13'b0000000000001    ) level_prefix[bp][12] = 1'b1;
                if( bits[bp-:14] == 14'b00000000000001   ) level_prefix[bp][13] = 1'b1;
                if( bits[bp-:15] == 15'b000000000000001  ) level_prefix[bp][14] = 1'b1;
                if( bits[bp-:16] == 16'b0000000000000001 ) level_prefix[bp][15] = 1'b1;
            end // level prefix

            // Level Arcs
            
            begin : _level_arcs
                // Loop Via, Suffix X NumCoeff X CoeffRemain X {Luma,Chroma}
                // With special cases for SL0 with 'b0000/'b00000, and for max==15
                for( int nc = 1; nc <= 16; nc++ ) begin // Num Coeff
                    for( int nr = 1; nr <= nc; nr++ ) begin // Num Remainings
                        for( int sl = 0; sl < 6 && sl <= nc-nr+1 ; sl++ ) begin // Suffix Length
                            for( int lp = 0; lp < 16; lp++ ) begin // Level Prefix
                                int dt;
                                // Luma Merge arcs (reduction OR) 
                                s_level_y[bp][nc][nr][sl] = |arc_level_y[bp][nc][nr][sl] | ((bp >= WIDTH) ? s_level_y_reg[bp-WIDTH][nc][nr][sl] : 1'b0 );
                                // bit offset 
                                dt = lp + 1 + ( ( lp == 15 ) ? 12 : ( lp == 14 && sl == 0 ) ? 4 : sl );
                                // Luma Arc to destination (1:1 fixed mapping)
                                if(      nr == 1 && nc == 16                  ) begin arc_level_last_y[bp-dt][lp+sl*16]         = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // no zeros, Map to last included bit                               
                                else if( nr == 1                              ) begin arc_total_zeros_y[bp-dt][nc][lp+sl*16+4]  = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to total zeros table
                                else if( sl == 0 && (nc - nr) <  3 && lp <  4 ) begin arc_level_y[bp-dt][nc][nr-1][   1][13+lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to SL1
                                else if( sl == 0 && (nc - nr) <  3            ) begin arc_level_y[bp-dt][nc][nr-1][   2][   lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to SL2                                     
                                else if( sl == 0 && (nc - nr) <  5 && lp <  6 ) begin arc_level_y[bp-dt][nc][nr-1][   1][13+lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to SL1
                                else if( sl == 0 && (nc - nr) <  5            ) begin arc_level_y[bp-dt][nc][nr-1][   2][   lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to SL2
                                else if( sl != 0 && sl != 6         && lp < 3 ) begin arc_level_y[bp-dt][nc][nr-1][sl  ][   lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to same SL
                                else if( sl != 0 && sl != 6                   ) begin arc_level_y[bp-dt][nc][nr-1][sl+1][13+lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to SL+1  
                                else if( sl == 6                              ) begin arc_level_y[bp-dt][nc][nr-1][   6][   lp] = level_prefix[bp][lp] & s_level_y[bp][nc][nr][sl]; end // map to sl6       
                            // Chroma
                                if( nc <= 4 ) begin
                                    // Merge arcs (reduction OR) 
                                    s_level_ch[bp][nc][nr][sl] = |arc_level_ch[bp][nc][nr][sl] | ((bp >= WIDTH) ? s_level_ch_reg[bp-WIDTH][nc][nr][sl] : 1'b0 );
                                    // Chroma Arc destinations (1:1 fixed mapping)
                                    if(      nr == 1 && nc == 4                   ) begin arc_level_last_ch[bp-dt][sl*16+lp]         = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // no zeros, Map to last                               
                                    else if( nr == 1                              ) begin arc_total_zeros_ch[bp-dt][nc][lp+sl*16+1]  = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to total zeros table
                                    else if( sl == 0 && (nc - nr) <  3 && lp <  4 ) begin arc_level_ch[bp-dt][nc][nr-1][   1][13+lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to SL1
                                    else if( sl == 0 && (nc - nr) <  3            ) begin arc_level_ch[bp-dt][nc][nr-1][   2][   lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to SL2                                     
                                    else if( sl == 0 && (nc - nr) <  5 && lp <  6 ) begin arc_level_ch[bp-dt][nc][nr-1][   1][13+lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to SL1
                                    else if( sl == 0 && (nc - nr) <  5            ) begin arc_level_ch[bp-dt][nc][nr-1][   2][   lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to SL2
                                    else if( sl != 0 && sl != 6         && lp < 3 ) begin arc_level_ch[bp-dt][nc][nr-1][sl  ][   lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to same SL
                                    else if( sl != 0 && sl != 6                   ) begin arc_level_ch[bp-dt][nc][nr-1][sl+1][13+lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to SL+1                                
                                    else if( sl == 6                              ) begin arc_level_ch[bp-dt][nc][nr-1][   6][   lp] = level_prefix[bp][lp] & s_level_ch[bp][nc][nr][sl]; end // map to sl6       
                                end // chroma
                            end // lp
                        end // sl
                    end // nr
                end // nc
            end // _level_arcs
            
            // Total Zeros 
            begin : _total_zeros
                // s_total_zero merge ( reduction OR )
                for( int nc = 1; nc < 16; nc++ ) begin s_total_zeros_y[bp][nc] =  |arc_total_zeros_y[bp][nc] | ((bp >= WIDTH) ? s_total_zeros_y_reg[bp-WIDTH][nc] : 1'b0 ); end // nc
                for( int nc = 1; nc < 4 ; nc++ ) begin s_total_zeros_ch[bp][nc] = |arc_total_zeros_ch[bp][nc] | ((bp >= WIDTH) ? s_total_zeros_ch_reg[bp-WIDTH][nc] : 1'b0 ); end // nc
                // Decode Logic
                // Last : Transition to arc_last if a transition to total_zeros == 0 
                // Last : End of line arc_last when num_coeff == 1, remaining zeros applied
                // RunBefore[nc][zl] : Transition to run before ladder given num_coeff X total_zeros and run_before (with last upon zero)
                // s_run_before [num_coeff][zeros_left]
                if( bits[bp-:1 ]== 1'b1                ) arc_total_zeros_last_y[bp-1 ][0]  =  s_total_zeros_y[bp][1]; // total zeros 1, 0, Y, 1
                if( bits[bp-:3 ]== 3'b011              ) arc_total_zeros_last_y[bp-3 ][1]  =  s_total_zeros_y[bp][1]; // total zeros 1, 1, Y, 011
                if( bits[bp-:3 ]== 3'b010              ) arc_total_zeros_last_y[bp-3 ][2]  =  s_total_zeros_y[bp][1]; // total zeros 1, 2, Y, 010
                if( bits[bp-:4 ]== 4'b0011             ) arc_total_zeros_last_y[bp-4 ][3]  =  s_total_zeros_y[bp][1]; // total zeros 1, 3, Y, 0011
                if( bits[bp-:4 ]== 4'b0010             ) arc_total_zeros_last_y[bp-4 ][4]  =  s_total_zeros_y[bp][1]; // total zeros 1, 4, Y, 0010
                if( bits[bp-:5 ]== 5'b00011            ) arc_total_zeros_last_y[bp-5 ][5]  =  s_total_zeros_y[bp][1]; // total zeros 1, 5, Y, 00011
                if( bits[bp-:5 ]== 5'b00010            ) arc_total_zeros_last_y[bp-5 ][6]  =  s_total_zeros_y[bp][1]; // total zeros 1, 6, Y, 00010
                if( bits[bp-:6 ]== 6'b000011           ) arc_total_zeros_last_y[bp-6 ][7]  =  s_total_zeros_y[bp][1]; // total zeros 1, 7, Y, 000011
                if( bits[bp-:6 ]== 6'b000010           ) arc_total_zeros_last_y[bp-6 ][8]  =  s_total_zeros_y[bp][1]; // total zeros 1, 8, Y, 000010
                if( bits[bp-:7 ]== 7'b0000011          ) arc_total_zeros_last_y[bp-7 ][9]  =  s_total_zeros_y[bp][1]; // total zeros 1, 9, Y, 0000011
                if( bits[bp-:7 ]== 7'b0000010          ) arc_total_zeros_last_y[bp-7 ][10]  =  s_total_zeros_y[bp][1]; // total zeros 1, 10, Y, 0000010
                if( bits[bp-:8 ]== 8'b00000011         ) arc_total_zeros_last_y[bp-8 ][11]  =  s_total_zeros_y[bp][1]; // total zeros 1, 11, Y, 00000011
                if( bits[bp-:8 ]== 8'b00000010         ) arc_total_zeros_last_y[bp-8 ][12]  =  s_total_zeros_y[bp][1]; // total zeros 1, 12, Y, 00000010
                if( bits[bp-:9 ]== 9'b000000011        ) arc_total_zeros_last_y[bp-9 ][13]  =  s_total_zeros_y[bp][1]; // total zeros 1, 13, Y, 000000011
                if( bits[bp-:9 ]== 9'b000000010        ) arc_total_zeros_last_y[bp-9 ][14]  =  s_total_zeros_y[bp][1]; // total zeros 1, 14, Y, 000000010
                if( bits[bp-:9 ]== 9'b000000001        ) arc_total_zeros_last_y[bp-9 ][15]  =  s_total_zeros_y[bp][1]; // total zeros 1, 15, Y, 000000001
                if( bits[bp-:3 ]== 3'b111              ) arc_total_zeros_last_y[bp-3 ][16]  =  s_total_zeros_y[bp][2]; // total zeros 2, 0, Y, 111
                if( bits[bp-:3 ]== 3'b110              ) arc_run_before[bp-3 ][2][1][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 1, Y, 110
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][2][2][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 2, Y, 101
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][2][3][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 3, Y, 100
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][2][4][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 4, Y, 011
                if( bits[bp-:4 ]== 4'b0101             ) arc_run_before[bp-4 ][2][5][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 5, Y, 0101
                if( bits[bp-:4 ]== 4'b0100             ) arc_run_before[bp-4 ][2][6][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 6, Y, 0100
                if( bits[bp-:4 ]== 4'b0011             ) arc_run_before[bp-4 ][2][7][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 7, Y, 0011
                if( bits[bp-:4 ]== 4'b0010             ) arc_run_before[bp-4 ][2][8][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 8, Y, 0010
                if( bits[bp-:5 ]== 5'b00011            ) arc_run_before[bp-5 ][2][9][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 9, Y, 00011
                if( bits[bp-:5 ]== 5'b00010            ) arc_run_before[bp-5 ][2][10][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 10, Y, 00010
                if( bits[bp-:6 ]== 6'b000011           ) arc_run_before[bp-6 ][2][11][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 11, Y, 000011
                if( bits[bp-:6 ]== 6'b000010           ) arc_run_before[bp-6 ][2][12][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 12, Y, 000010
                if( bits[bp-:6 ]== 6'b000001           ) arc_run_before[bp-6 ][2][13][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 13, Y, 000001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][2][14][0]  =  s_total_zeros_y[bp][2]; // total zeros 2, 14, Y, 000000
                if( bits[bp-:4 ]== 4'b0101             ) arc_total_zeros_last_y[bp-4 ][17]  =  s_total_zeros_y[bp][3]; // total zeros 3, 0, Y, 0101
                if( bits[bp-:3 ]== 3'b111              ) arc_run_before[bp-3 ][3][1][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 1, Y, 111
                if( bits[bp-:3 ]== 3'b110              ) arc_run_before[bp-3 ][3][2][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 2, Y, 110
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][3][3][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 3, Y, 101
                if( bits[bp-:4 ]== 4'b0100             ) arc_run_before[bp-4 ][3][4][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 4, Y, 0100
                if( bits[bp-:4 ]== 4'b0011             ) arc_run_before[bp-4 ][3][5][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 5, Y, 0011
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][3][6][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 6, Y, 100
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][3][7][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 7, Y, 011
                if( bits[bp-:4 ]== 4'b0010             ) arc_run_before[bp-4 ][3][8][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 8, Y, 0010
                if( bits[bp-:5 ]== 5'b00011            ) arc_run_before[bp-5 ][3][9][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 9, Y, 00011
                if( bits[bp-:5 ]== 5'b00010            ) arc_run_before[bp-5 ][3][10][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 10, Y, 00010
                if( bits[bp-:6 ]== 6'b000001           ) arc_run_before[bp-6 ][3][11][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 11, Y, 000001
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][3][12][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 12, Y, 00001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][3][13][0]  =  s_total_zeros_y[bp][3]; // total zeros 3, 13, Y, 000000
                if( bits[bp-:5 ]== 5'b00011            ) arc_total_zeros_last_y[bp-5 ][18]  =  s_total_zeros_y[bp][4]; // total zeros 4, 0, Y, 00011
                if( bits[bp-:3 ]== 3'b111              ) arc_run_before[bp-3 ][4][1][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 1, Y, 111
                if( bits[bp-:4 ]== 4'b0101             ) arc_run_before[bp-4 ][4][2][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 2, Y, 0101
                if( bits[bp-:4 ]== 4'b0100             ) arc_run_before[bp-4 ][4][3][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 3, Y, 0100
                if( bits[bp-:3 ]== 3'b110              ) arc_run_before[bp-3 ][4][4][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 4, Y, 110
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][4][5][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 5, Y, 101
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][4][6][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 6, Y, 100
                if( bits[bp-:4 ]== 4'b0011             ) arc_run_before[bp-4 ][4][7][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 7, Y, 0011
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][4][8][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 8, Y, 011
                if( bits[bp-:4 ]== 4'b0010             ) arc_run_before[bp-4 ][4][9][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 9, Y, 0010
                if( bits[bp-:5 ]== 5'b00010            ) arc_run_before[bp-5 ][4][10][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 10, Y, 00010
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][4][11][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 11, Y, 00001
                if( bits[bp-:5 ]== 5'b00000            ) arc_run_before[bp-5 ][4][12][0]  =  s_total_zeros_y[bp][4]; // total zeros 4, 12, Y, 00000
                if( bits[bp-:4 ]== 4'b0101             ) arc_total_zeros_last_y[bp-4 ][19]  =  s_total_zeros_y[bp][5]; // total zeros 5, 0, Y, 0101
                if( bits[bp-:4 ]== 4'b0100             ) arc_run_before[bp-4 ][5][1][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 1, Y, 0100
                if( bits[bp-:4 ]== 4'b0011             ) arc_run_before[bp-4 ][5][2][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 2, Y, 0011
                if( bits[bp-:3 ]== 3'b111              ) arc_run_before[bp-3 ][5][3][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 3, Y, 111
                if( bits[bp-:3 ]== 3'b110              ) arc_run_before[bp-3 ][5][4][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 4, Y, 110
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][5][5][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 5, Y, 101
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][5][6][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 6, Y, 100
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][5][7][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 7, Y, 011
                if( bits[bp-:4 ]== 4'b0010             ) arc_run_before[bp-4 ][5][8][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 8, Y, 0010
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][5][9][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 9, Y, 00001
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][5][10][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 10, Y, 0001
                if( bits[bp-:5 ]== 5'b00000            ) arc_run_before[bp-5 ][5][11][0]  =  s_total_zeros_y[bp][5]; // total zeros 5, 11, Y, 00000
                if( bits[bp-:6 ]== 6'b000001           ) arc_total_zeros_last_y[bp-6 ][20]  =  s_total_zeros_y[bp][6]; // total zeros 6, 0, Y, 000001
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][6][1][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 1, Y, 00001
                if( bits[bp-:3 ]== 3'b111              ) arc_run_before[bp-3 ][6][2][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 2, Y, 111
                if( bits[bp-:3 ]== 3'b110              ) arc_run_before[bp-3 ][6][3][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 3, Y, 110
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][6][4][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 4, Y, 101
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][6][5][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 5, Y, 100
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][6][6][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 6, Y, 011
                if( bits[bp-:3 ]== 3'b010              ) arc_run_before[bp-3 ][6][7][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 7, Y, 010
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][6][8][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 8, Y, 0001
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][6][9][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 9, Y, 001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][6][10][0]  =  s_total_zeros_y[bp][6]; // total zeros 6, 10, Y, 000000
                if( bits[bp-:6 ]== 6'b000001           ) arc_total_zeros_last_y[bp-6 ][21]  =  s_total_zeros_y[bp][7]; // total zeros 7, 0, Y, 000001
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][7][1][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 1, Y, 00001
                if( bits[bp-:3 ]== 3'b101              ) arc_run_before[bp-3 ][7][2][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 2, Y, 101
                if( bits[bp-:3 ]== 3'b100              ) arc_run_before[bp-3 ][7][3][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 3, Y, 100
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][7][4][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 4, Y, 011
                if( bits[bp-:2 ]== 2'b11               ) arc_run_before[bp-2 ][7][5][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 5, Y, 11
                if( bits[bp-:3 ]== 3'b010              ) arc_run_before[bp-3 ][7][6][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 6, Y, 010
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][7][7][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 7, Y, 0001
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][7][8][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 8, Y, 001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][7][9][0]  =  s_total_zeros_y[bp][7]; // total zeros 7, 9, Y, 000000
                if( bits[bp-:6 ]== 6'b000001           ) arc_total_zeros_last_y[bp-6 ][22]  =  s_total_zeros_y[bp][8]; // total zeros 8, 0, Y, 000001
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][8][1][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 1, Y, 0001
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][8][2][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 2, Y, 00001
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][8][3][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 3, Y, 011
                if( bits[bp-:2 ]== 2'b11               ) arc_run_before[bp-2 ][8][4][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 4, Y, 11
                if( bits[bp-:2 ]== 2'b10               ) arc_run_before[bp-2 ][8][5][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 5, Y, 10
                if( bits[bp-:3 ]== 3'b010              ) arc_run_before[bp-3 ][8][6][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 6, Y, 010
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][8][7][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 7, Y, 001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][8][8][0]  =  s_total_zeros_y[bp][8]; // total zeros 8, 8, Y, 000000
                if( bits[bp-:6 ]== 6'b000001           ) arc_total_zeros_last_y[bp-6 ][23]  =  s_total_zeros_y[bp][9]; // total zeros 9, 0, Y, 000001
                if( bits[bp-:6 ]== 6'b000000           ) arc_run_before[bp-6 ][9][1][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 1, Y, 000000
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][9][2][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 2, Y, 0001
                if( bits[bp-:2 ]== 2'b11               ) arc_run_before[bp-2 ][9][3][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 3, Y, 11
                if( bits[bp-:2 ]== 2'b10               ) arc_run_before[bp-2 ][9][4][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 4, Y, 10
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][9][5][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 5, Y, 001
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][9][6][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 6, Y, 01
                if( bits[bp-:5 ]== 5'b00001            ) arc_run_before[bp-5 ][9][7][0]  =  s_total_zeros_y[bp][9]; // total zeros 9, 7, Y, 00001
                if( bits[bp-:5 ]== 5'b00001            ) arc_total_zeros_last_y[bp-5 ][24]  =  s_total_zeros_y[bp][10]; // total zeros 10, 0, Y, 00001
                if( bits[bp-:5 ]== 5'b00000            ) arc_run_before[bp-5 ][10][1][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 1, Y, 00000
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][10][2][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 2, Y, 001
                if( bits[bp-:2 ]== 2'b11               ) arc_run_before[bp-2 ][10][3][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 3, Y, 11
                if( bits[bp-:2 ]== 2'b10               ) arc_run_before[bp-2 ][10][4][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 4, Y, 10
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][10][5][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 5, Y, 01
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][10][6][0]  =  s_total_zeros_y[bp][10]; // total zeros 10, 6, Y, 0001
                if( bits[bp-:4 ]== 4'b0000             ) arc_total_zeros_last_y[bp-4 ][25]  =  s_total_zeros_y[bp][11]; // total zeros 11, 0, Y, 0000
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][11][1][0]  =  s_total_zeros_y[bp][11]; // total zeros 11, 1, Y, 0001
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][11][2][0]  =  s_total_zeros_y[bp][11]; // total zeros 11, 2, Y, 001
                if( bits[bp-:3 ]== 3'b010              ) arc_run_before[bp-3 ][11][3][0]  =  s_total_zeros_y[bp][11]; // total zeros 11, 3, Y, 010
                if( bits[bp-:1 ]== 1'b1                ) arc_run_before[bp-1 ][11][4][0]  =  s_total_zeros_y[bp][11]; // total zeros 11, 4, Y, 1
                if( bits[bp-:3 ]== 3'b011              ) arc_run_before[bp-3 ][11][5][0]  =  s_total_zeros_y[bp][11]; // total zeros 11, 5, Y, 011
                if( bits[bp-:4 ]== 4'b0000             ) arc_total_zeros_last_y[bp-4 ][26]  =  s_total_zeros_y[bp][12]; // total zeros 12, 0, Y, 0000
                if( bits[bp-:4 ]== 4'b0001             ) arc_run_before[bp-4 ][12][1][0]  =  s_total_zeros_y[bp][12]; // total zeros 12, 1, Y, 0001
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][12][2][0]  =  s_total_zeros_y[bp][12]; // total zeros 12, 2, Y, 01
                if( bits[bp-:1 ]== 1'b1                ) arc_run_before[bp-1 ][12][3][0]  =  s_total_zeros_y[bp][12]; // total zeros 12, 3, Y, 1
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][12][4][0]  =  s_total_zeros_y[bp][12]; // total zeros 12, 4, Y, 001
                if( bits[bp-:3 ]== 3'b000              ) arc_total_zeros_last_y[bp-3 ][27]  =  s_total_zeros_y[bp][13]; // total zeros 13, 0, Y, 000
                if( bits[bp-:3 ]== 3'b001              ) arc_run_before[bp-3 ][13][1][0]  =  s_total_zeros_y[bp][13]; // total zeros 13, 1, Y, 001
                if( bits[bp-:1 ]== 1'b1                ) arc_run_before[bp-1 ][13][2][0]  =  s_total_zeros_y[bp][13]; // total zeros 13, 2, Y, 1
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][13][3][0]  =  s_total_zeros_y[bp][13]; // total zeros 13, 3, Y, 01
                if( bits[bp-:2 ]== 2'b00               ) arc_total_zeros_last_y[bp-2 ][28]  =  s_total_zeros_y[bp][14]; // total zeros 14, 0, Y, 00
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][14][1][0]  =  s_total_zeros_y[bp][14]; // total zeros 14, 1, Y, 01
                if( bits[bp-:1 ]== 1'b1                ) arc_run_before[bp-1 ][14][2][0]  =  s_total_zeros_y[bp][14]; // total zeros 14, 2, Y, 1
                if( bits[bp-:1 ]== 1'b0                ) arc_total_zeros_last_y[bp-1 ][29]  =  s_total_zeros_y[bp][15]; // total zeros 15, 0, Y, 0
                if( bits[bp-:1 ]== 1'b1                ) arc_run_before[bp-1 ][15][1][0]  =  s_total_zeros_y[bp][15]; // total zeros 15, 1, Y, 1
                if( bits[bp-:1 ]== 1'b1                ) arc_total_zeros_last_ch[bp-1 ][0]  =  s_total_zeros_ch[bp][1]; // total zeros 1, 0, C, 1
                if( bits[bp-:2 ]== 2'b01               ) arc_total_zeros_last_ch[bp-2 ][1]  =  s_total_zeros_ch[bp][1]; // total zeros 1, 1, C, 01
                if( bits[bp-:3 ]== 3'b001              ) arc_total_zeros_last_ch[bp-3 ][2]  =  s_total_zeros_ch[bp][1]; // total zeros 1, 2, C, 001
                if( bits[bp-:3 ]== 3'b000              ) arc_total_zeros_last_ch[bp-3 ][3]  =  s_total_zeros_ch[bp][1]; // total zeros 1, 3, C, 000
                if( bits[bp-:1 ]== 1'b1                ) arc_total_zeros_last_ch[bp-1 ][4]  =  s_total_zeros_ch[bp][2]; // total zeros 2, 0, C, 1
                if( bits[bp-:2 ]== 2'b01               ) arc_run_before[bp-2 ][2][1][1]  =  s_total_zeros_ch[bp][2]; // total zeros 2, 1, C, 01
                if( bits[bp-:2 ]== 2'b00               ) arc_run_before[bp-2 ][2][2][1]  =  s_total_zeros_ch[bp][2]; // total zeros 2, 2, C, 00
                if( bits[bp-:1 ]== 1'b1                ) arc_total_zeros_last_ch[bp-1 ][5]  =  s_total_zeros_ch[bp][3]; // total zeros 3, 0, C, 1
                if( bits[bp-:1 ]== 1'b0                ) arc_run_before[bp-1 ][3][1][1]  =  s_total_zeros_ch[bp][3]; // total zeros 3, 1, C, 0
            end // total_zeros
            
            // Decode Run Before
            begin : _run_before_decode
                if( bits[bp-:1 ]== 1'b1                ) run_before[bp][1][0] = 1'b1; // run_before 1, 0, , 1
                if( bits[bp-:1 ]== 1'b0                ) run_before[bp][1][1] = 1'b1; // run_before 1, 1, , 0
                if( bits[bp-:1 ]== 1'b1                ) run_before[bp][2][0] = 1'b1; // run_before 2, 0, , 1
                if( bits[bp-:2 ]== 2'b01               ) run_before[bp][2][1] = 1'b1; // run_before 2, 1, , 01
                if( bits[bp-:2 ]== 2'b00               ) run_before[bp][2][2] = 1'b1; // run_before 2, 2, , 00
                if( bits[bp-:2 ]== 2'b11               ) run_before[bp][3][0] = 1'b1; // run_before 3, 0, , 11
                if( bits[bp-:2 ]== 2'b10               ) run_before[bp][3][1] = 1'b1; // run_before 3, 1, , 10
                if( bits[bp-:2 ]== 2'b01               ) run_before[bp][3][2] = 1'b1; // run_before 3, 2, , 01
                if( bits[bp-:2 ]== 2'b00               ) run_before[bp][3][3] = 1'b1; // run_before 3, 3, , 00
                if( bits[bp-:2 ]== 2'b11               ) run_before[bp][4][0] = 1'b1; // run_before 4, 0, , 11
                if( bits[bp-:2 ]== 2'b10               ) run_before[bp][4][1] = 1'b1; // run_before 4, 1, , 10
                if( bits[bp-:2 ]== 2'b01               ) run_before[bp][4][2] = 1'b1; // run_before 4, 2, , 01
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][4][3] = 1'b1; // run_before 4, 3, , 001
                if( bits[bp-:3 ]== 3'b000              ) run_before[bp][4][4] = 1'b1; // run_before 4, 4, , 000
                if( bits[bp-:2 ]== 2'b11               ) run_before[bp][5][0] = 1'b1; // run_before 5, 0, , 11
                if( bits[bp-:2 ]== 2'b10               ) run_before[bp][5][1] = 1'b1; // run_before 5, 1, , 10
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][5][2] = 1'b1; // run_before 5, 2, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][5][3] = 1'b1; // run_before 5, 3, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][5][4] = 1'b1; // run_before 5, 4, , 001
                if( bits[bp-:3 ]== 3'b000              ) run_before[bp][5][5] = 1'b1; // run_before 5, 5, , 000
                if( bits[bp-:2 ]== 2'b11               ) run_before[bp][6][0] = 1'b1; // run_before 6, 0, , 11
                if( bits[bp-:3 ]== 3'b000              ) run_before[bp][6][1] = 1'b1; // run_before 6, 1, , 000
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][6][2] = 1'b1; // run_before 6, 2, , 001
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][6][3] = 1'b1; // run_before 6, 3, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][6][4] = 1'b1; // run_before 6, 4, , 010
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][6][5] = 1'b1; // run_before 6, 5, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][6][6] = 1'b1; // run_before 6, 6, , 100
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][7][0] = 1'b1; // run_before 7, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][7][1] = 1'b1; // run_before 7, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][7][2] = 1'b1; // run_before 7, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][7][3] = 1'b1; // run_before 7, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][7][4] = 1'b1; // run_before 7, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][7][5] = 1'b1; // run_before 7, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][7][6] = 1'b1; // run_before 7, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][7][7] = 1'b1; // run_before 7, 7, , 0001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][8][0] = 1'b1; // run_before 8, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][8][1] = 1'b1; // run_before 8, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][8][2] = 1'b1; // run_before 8, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][8][3] = 1'b1; // run_before 8, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][8][4] = 1'b1; // run_before 8, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][8][5] = 1'b1; // run_before 8, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][8][6] = 1'b1; // run_before 8, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][8][7] = 1'b1; // run_before 8, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][8][8] = 1'b1; // run_before 8, 8, , 00001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][9][0] = 1'b1; // run_before 9, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][9][1] = 1'b1; // run_before 9, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][9][2] = 1'b1; // run_before 9, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][9][3] = 1'b1; // run_before 9, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][9][4] = 1'b1; // run_before 9, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][9][5] = 1'b1; // run_before 9, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][9][6] = 1'b1; // run_before 9, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][9][7] = 1'b1; // run_before 9, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][9][8] = 1'b1; // run_before 9, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][9][9] = 1'b1; // run_before 9, 9, , 000001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][10][0] = 1'b1; // run_before 10, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][10][1] = 1'b1; // run_before 10, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][10][2] = 1'b1; // run_before 10, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][10][3] = 1'b1; // run_before 10, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][10][4] = 1'b1; // run_before 10, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][10][5] = 1'b1; // run_before 10, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][10][6] = 1'b1; // run_before 10, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][10][7] = 1'b1; // run_before 10, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][10][8] = 1'b1; // run_before 10, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][10][9] = 1'b1; // run_before 10, 9, , 000001
                if( bits[bp-:7 ]== 7'b0000001          ) run_before[bp][10][10] = 1'b1; // run_before 10, 10, , 0000001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][11][0] = 1'b1; // run_before 11, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][11][1] = 1'b1; // run_before 11, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][11][2] = 1'b1; // run_before 11, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][11][3] = 1'b1; // run_before 11, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][11][4] = 1'b1; // run_before 11, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][11][5] = 1'b1; // run_before 11, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][11][6] = 1'b1; // run_before 11, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][11][7] = 1'b1; // run_before 11, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][11][8] = 1'b1; // run_before 11, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][11][9] = 1'b1; // run_before 11, 9, , 000001
                if( bits[bp-:7 ]== 7'b0000001          ) run_before[bp][11][10] = 1'b1; // run_before 11, 10, , 0000001
                if( bits[bp-:8 ]== 8'b00000001         ) run_before[bp][11][11] = 1'b1; // run_before 11, 11, , 00000001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][12][0] = 1'b1; // run_before 12, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][12][1] = 1'b1; // run_before 12, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][12][2] = 1'b1; // run_before 12, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][12][3] = 1'b1; // run_before 12, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][12][4] = 1'b1; // run_before 12, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][12][5] = 1'b1; // run_before 12, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][12][6] = 1'b1; // run_before 12, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][12][7] = 1'b1; // run_before 12, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][12][8] = 1'b1; // run_before 12, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][12][9] = 1'b1; // run_before 12, 9, , 000001
                if( bits[bp-:7 ]== 7'b0000001          ) run_before[bp][12][10] = 1'b1; // run_before 12, 10, , 0000001
                if( bits[bp-:8 ]== 8'b00000001         ) run_before[bp][12][11] = 1'b1; // run_before 12, 11, , 00000001
                if( bits[bp-:9 ]== 9'b000000001        ) run_before[bp][12][12] = 1'b1; // run_before 12, 12, , 000000001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][13][0] = 1'b1; // run_before 13, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][13][1] = 1'b1; // run_before 13, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][13][2] = 1'b1; // run_before 13, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][13][3] = 1'b1; // run_before 13, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][13][4] = 1'b1; // run_before 13, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][13][5] = 1'b1; // run_before 13, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][13][6] = 1'b1; // run_before 13, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][13][7] = 1'b1; // run_before 13, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][13][8] = 1'b1; // run_before 13, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][13][9] = 1'b1; // run_before 13, 9, , 000001
                if( bits[bp-:7 ]== 7'b0000001          ) run_before[bp][13][10] = 1'b1; // run_before 13, 10, , 0000001
                if( bits[bp-:8 ]== 8'b00000001         ) run_before[bp][13][11] = 1'b1; // run_before 13, 11, , 00000001
                if( bits[bp-:9 ]== 9'b000000001        ) run_before[bp][13][12] = 1'b1; // run_before 13, 12, , 000000001
                if( bits[bp-:10]==10'b0000000001       ) run_before[bp][13][13] = 1'b1; // run_before 13, 13, , 0000000001
                if( bits[bp-:3 ]== 3'b111              ) run_before[bp][14][0] = 1'b1; // run_before 14, 0, , 111
                if( bits[bp-:3 ]== 3'b110              ) run_before[bp][14][1] = 1'b1; // run_before 14, 1, , 110
                if( bits[bp-:3 ]== 3'b101              ) run_before[bp][14][2] = 1'b1; // run_before 14, 2, , 101
                if( bits[bp-:3 ]== 3'b100              ) run_before[bp][14][3] = 1'b1; // run_before 14, 3, , 100
                if( bits[bp-:3 ]== 3'b011              ) run_before[bp][14][4] = 1'b1; // run_before 14, 4, , 011
                if( bits[bp-:3 ]== 3'b010              ) run_before[bp][14][5] = 1'b1; // run_before 14, 5, , 010
                if( bits[bp-:3 ]== 3'b001              ) run_before[bp][14][6] = 1'b1; // run_before 14, 6, , 001
                if( bits[bp-:4 ]== 4'b0001             ) run_before[bp][14][7] = 1'b1; // run_before 14, 7, , 0001
                if( bits[bp-:5 ]== 5'b00001            ) run_before[bp][14][8] = 1'b1; // run_before 14, 8, , 00001
                if( bits[bp-:6 ]== 6'b000001           ) run_before[bp][14][9] = 1'b1; // run_before 14, 9, , 000001
                if( bits[bp-:7 ]== 7'b0000001          ) run_before[bp][14][10] = 1'b1; // run_before 14, 10, , 0000001
                if( bits[bp-:8 ]== 8'b00000001         ) run_before[bp][14][11] = 1'b1; // run_before 14, 11, , 00000001
                if( bits[bp-:9 ]== 9'b000000001        ) run_before[bp][14][12] = 1'b1; // run_before 14, 12, , 000000001
                if( bits[bp-:10]==10'b0000000001       ) run_before[bp][14][13] = 1'b1; // run_before 14, 13, , 0000000001
                if( bits[bp-:11]==11'b00000000001      ) run_before[bp][14][14] = 1'b1; // run_before 14, 14, , 00000000001
            end // run before decode
            
            // Process run_before state           
            begin : _run_before_cacl
                 // State arcs 
                for( int nr = 2; nr <= 15; nr++ ) begin // Num coeff remaining Remainings
                    for( int nz = 1; nz < (16-nr); nz++ ) begin // zeros left
                        // Merge run_before arcs (Reduction OR)
                        s_run_before[bp][nr][nz] = |arc_run_before[bp][nr][nz] | ((bp >= WIDTH) ? s_run_before_reg[bp-WIDTH][nr][nz] : 1'b0 );
                        for( int rb = 0; rb <= nz; rb++ ) begin // run before
                        // RunBefore[nr-1][zl-run_before] transition=                        
                            arc_run_before[bp-run_before_len[nz][rb]][nr-1][nz-rb][rb+2] = s_run_before[bp][nr][nz] & run_before[bp][nz][rb];
                        end //rb
                    end //zl
                end // nr

                // Handle Last case with NR=1 (Reduction OR)
                arc_run_before_last[bp][0] = |arc_run_before[bp][1];

                // Handle Last case with ZL=0
                for( int nr = 2; nr < 15; nr++ ) begin
                    arc_run_before_last[bp][nr-1] = |arc_run_before[bp][nr][0];
                end
            end // _run_before

            // handle low run_before arcs
            for( int bp = 31; bp >= 0; bp-- ) begin
                    // Handle Last case with NR=1 (Reduction OR)
                arc_run_before_last[bp][0] = |arc_run_before[bp][1];

                // Handle Last case with ZL=0
                for( int nr = 2; nr < 15; nr++ ) begin
                    arc_run_before_last[bp][nr-1] = |arc_run_before[bp][nr][0];
            end
        end

            // Process last state
            begin : _process_last            
                // Last arc merge (reduction ORs) to flag last bit of a transform block
                s_last[bp]    = ( |arc_coeff_token_last[bp]    ) | 
                                ( |arc_level_last_y[bp]        ) | 
                                ( |arc_level_last_ch[bp]       ) | 
                                ( |arc_total_zeros_last_y[bp]  ) | 
                                ( |arc_total_zeros_last_ch[bp] ) | 
                                ( |arc_run_before_last[bp]     ) |
                                ((bp >= WIDTH) ? s_last_reg[bp-WIDTH] : 1'b0 );
            end // _process_last
        end // bp
    end // lattice array
   
    assign end_bits[WIDTH-1:0] = s_last[WIDTH+32-1:32];
    
    always_ff @(posedge clk) begin // Lower 32 set of states are flopped  
        if( reset ) begin
            for( int bp = 31; bp >= 0; bp-- ) begin
                s_total_zeros_y_reg[bp]  <= 0;
                s_total_zeros_ch_reg[bp] <= 0;
                s_level_y_reg[bp]        <= 0;
                s_level_ch_reg[bp]       <= 0;
                s_run_before_reg[bp]     <= 0;
                s_last_reg[bp]           <= 0;
            end
        end else begin
            for( int bp = 31; bp >= 0; bp-- ) begin
                for( int nc = 1; nc < 16; nc++ ) begin 
                    s_total_zeros_y_reg[bp][nc] <=  |arc_total_zeros_y[bp][nc]; 
                end // nc
                for( int nc = 1; nc < 4 ; nc++ ) begin 
                    s_total_zeros_ch_reg[bp][nc] <= |arc_total_zeros_ch[bp][nc]; 
                end // nc
                for( int nc = 1; nc <= 16; nc++ ) begin // Num Coeff
                    for( int nr = 1; nr <= nc; nr++ ) begin // Num Remainings
                        for( int sl = 0; sl < 6 && sl <= nc-nr+1 ; sl++ ) begin // Suffix Length
                            for( int lp = 0; lp < 16; lp++ ) begin // Level Prefix
                                s_level_y_reg[bp][nc][nr][sl] <= |arc_level_y[bp][nc][nr][sl];
                                if( nc <= 4 ) begin
                                    s_level_ch_reg[bp][nc][nr][sl] <= |arc_level_ch[bp][nc][nr][sl];
                                end
                            end
                        end
                    end
                end
                for( int nr = 2; nr <= 15; nr++ ) begin // Num coeff remaining Remainings
                    for( int nz = 1; nz < (16-nr); nz++ ) begin // zeros left
                        s_run_before_reg[bp][nr][nz] <= |arc_run_before[bp][nr][nz];
                    end
                end
                s_last_reg[bp] <= ( |arc_coeff_token_last[bp]    ) | 
                                  ( |arc_level_last_y[bp]        ) | 
                                  ( |arc_level_last_ch[bp]       ) | 
                                  ( |arc_total_zeros_last_y[bp]  ) | 
                                  ( |arc_total_zeros_last_ch[bp] ) | 
                                  ( |arc_run_before_last[bp]     ) ;
            end
        end
    end // ff
endmodule
 