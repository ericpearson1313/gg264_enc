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


// Decode a macroblock layer
// Runs in parallel with gg_parse_lattice
// Input: bitstream, nc_left/above_y/cb/cr[16], mb_start
// Output: mb_end, nc_right/below_y/cb/cr[16]
module gg_parse_lattice_macroblock
   #(
     parameter int WIDTH             = 32
    )
    (
    // System
    input  logic clk,
    input  logic reset,
    // Input bits
    input  logic [WIDTH-1:0] in_bits, // bitstream, bit endian packed
    input  logic [31:0]      in_pad, // Lookahead of 32 bits
    // Input mb_start trigger
    input  logic [WIDTH-1:0] mb_start, // Input trigger
    output logic [WIDTH-1:0] mb_end, // a single 1-hot bit indicating block end
    // MB neighborhood info
    input  logic left_oop,  
    input  logic above_oop,
    input  logic [0:7][4:0] nc_left , // Y: 0-3 Cb: 4-5 Cr: 6-7
    input  logic [0:7][4:0] nc_above,
    output logic [0:7][4:0] nc_right, 
    output logic [0:7][4:0] nc_below,
    // transform block lattice interface
    input  logic [WIDTH-1:0] blk_end, // a single 1-hot bit indicating block end
    output logic [WIDTH-1:0][5:0] blk_nc_idx // block trigger one hot coeff_token table index, {0-3} luma, {4} chroma DC, and bit 5 = ac_flag
    );

    parameter MB_SYNTAX_MBTYPE    = 0;

    parameter MB_SYNTAX_PCM_ALIGN = 1;
   
    parameter MB_SYNTAX_P16x16_REF = 2;
    parameter MB_SYNTAX_P16x16_MVX = 3;
    parameter MB_SYNTAX_P16x16_MVY = 4;
    
    parameter MB_SYNTAX_P16x8_REF0 = 5;
    parameter MB_SYNTAX_P16x8_REF1 = 6;
    parameter MB_SYNTAX_P16x8_MVX0 = 7;
    parameter MB_SYNTAX_P16x8_MVY0 = 8;
    parameter MB_SYNTAX_P16x8_MVX1=  9;
    parameter MB_SYNTAX_P16x8_MVY1 = 10;
    
    parameter MB_SYNTAX_CBP        = 11;
    parameter MB_SYNTAX_DELTA_QP   = 12;

    parameter MB_SYNTAX_RESIDUAL   = 13;    

 

    logic [WIDTH+31:0][0:13]           s_mb_syntax; // macroblock syntax elements 
    logic [WIDTH+31:0][0:13][0:31]   arc_mb_syntax; // [syntax element][ue/se prefix length] 
   
    logic [WIDTH+31:0][5:0]          coded_block_pattern;
    logic [WIDTH+31:0][0:7][4:0]     num_coeff_left;
    logic [WIDTH+31:0][0:7][4:0]     num_coeff_above;
    logic [WIDTH+31:0][5:0]          num_coeff_idx;
    
    logic [WIDTH+31:0][0:4]            s_blk_zero;  // Skip State to bypass a set of states
    logic [WIDTH+31:0][0:25]           s_blk_start;    
    logic [WIDTH+31:0][0:25]           s_blk_run;
 
    logic [WIDTH+31:0][0:7][4:0]        local_left;
    logic [WIDTH+31:0][0:7][4:0]        local_above;
    logic [WIDTH+31:0][0:25][7:0]       arc_nc_x2;  // { ac_flag, nc_idx[4], nc[4:0], ignore[0] }
    logic [WIDTH+31:0][7:0]             nc_x2;  // { ac_flag, nc_idx[4], nc[4:0], ignore[0] }
    logic [WIDTH+31:0][4:0]             num_coeff;
    logic [WIDTH+31:0][0:3][0:16][4:0]  nc;

    logic [WIDTH+31:0]                  s_last;
    
    logic [WIDTH+31:0][0:15]            ue_prefix;
    
    logic [WIDTH+31:0] bits;
    logic [WIDTH+31:0] blk_end_flag;
    
    assign blk_end_flag = { blk_end, 32'b0 };
    assign bits = { in_bits, in_pad };

    // Loop Over bitpositions 
    always_comb begin : _lattice_mb_parse
        // Clear last arcs
        
        // Clear state arcs
        arc_mb_syntax = 0;
    
        // Clear state
        s_mb_syntax = 0;
        s_blk_run = 0;
        s_blk_start = 0;
        s_blk_zero = 0;
        s_last = 0;

        // Clear decode arrays
        coded_block_pattern = 0;
        ue_prefix = 0;
        num_coeff_idx = 0;
        num_coeff_left = 0;             
        num_coeff_above = 0;     
        
        // Clear Local Variables
        local_left = 0;
        local_above = 0;
        arc_nc_x2 = 0; 
        nc_x2 = 0;  // { ac_flag, nc_idx[4], nc[4:0], ignore[0] }
        num_coeff = 0;
        nc = 0;;
       
        
        // Set starting neighbourhood state ( _HACK_ _
        num_coeff_left[ WIDTH-1+31] = nc_left;
        num_coeff_above[WIDTH-1+31] = nc_above; 

        // Loop through all bits
        for( int bp = WIDTH-1+32; bp >= 32; bp-- ) begin : _lattice_col

            begin : _mbtype // Just decode the few used: 0, 1, 2, 30 
                 if( bits[bp-:1 ]== 1'b1                ) arc_mb_syntax[bp-1][MB_SYNTAX_P16x16_REF][0]  =  mb_start[bp-32]; // 0 - P16x16
                 if( bits[bp-:2 ]== 2'b01                ) arc_mb_syntax[bp-3][MB_SYNTAX_P16x8_REF0][0]  =  mb_start[bp-32]; // 1 - P16x8 and 2 - P8x16
                 if( bits[bp-:9 ]== 9'b00001111         ) arc_mb_syntax[((bp-9)/8)*8][MB_SYNTAX_PCM_ALIGN][(bp-9)%8] = mb_start[bp-32]; // 30 - PCM
            end // mb_type
           
            begin : _pcm_mb // TODO: handle PCM MBs 384 byte step, wrap registers
                 s_mb_syntax[bp][MB_SYNTAX_PCM_ALIGN] = |arc_mb_syntax[bp][MB_SYNTAX_PCM_ALIGN]; // Reduction OR
            //    arc_pcm_last[bp-3072] = s_mb_syntax[bp][MB_SYNTAX_PCM_ALIGN];
            end // pcm
            
            begin : _refidx // assume num_refidx_minus_1 == 0, so single bit only
                 s_mb_syntax[bp][MB_SYNTAX_P16x16_REF] = |arc_mb_syntax[bp][MB_SYNTAX_P16x16_REF]; // Reduction OR
                 arc_mb_syntax[bp-1][MB_SYNTAX_P16x16_MVX][0] = s_mb_syntax[bp][MB_SYNTAX_P16x16_REF];   
                 
                 s_mb_syntax[bp][MB_SYNTAX_P16x8_REF0] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_REF0]; // Reduction OR
                 arc_mb_syntax[bp-1][MB_SYNTAX_P16x8_REF1][0] = s_mb_syntax[bp][MB_SYNTAX_P16x8_REF0];   
                 
                 s_mb_syntax[bp][MB_SYNTAX_P16x8_REF1] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_REF1]; // Reduction OR
                 arc_mb_syntax[bp-1][MB_SYNTAX_P16x8_MVX0][0] = s_mb_syntax[bp][MB_SYNTAX_P16x8_REF1];
            end
            
            begin : _ue_prefix
                if( bits[bp-:1 ] == 1'b1                 ) ue_prefix[bp][0] = 1'b1;
                if( bits[bp-:2 ] == 2'b01                ) ue_prefix[bp][1] = 1'b1;
                if( bits[bp-:3 ] == 3'b001               ) ue_prefix[bp][2] = 1'b1;
                if( bits[bp-:4 ] == 4'b0001              ) ue_prefix[bp][3] = 1'b1;
                if( bits[bp-:5 ] == 5'b00001             ) ue_prefix[bp][4] = 1'b1;
                if( bits[bp-:6 ] == 6'b000001            ) ue_prefix[bp][5] = 1'b1;
                if( bits[bp-:7 ] == 7'b0000001           ) ue_prefix[bp][6] = 1'b1;
                if( bits[bp-:8 ] == 8'b00000001          ) ue_prefix[bp][7] = 1'b1;
                if( bits[bp-:9 ] == 9'b000000001         ) ue_prefix[bp][8] = 1'b1;
                if( bits[bp-:10] == 10'b0000000001       ) ue_prefix[bp][9] = 1'b1;
                if( bits[bp-:11] == 11'b00000000001      ) ue_prefix[bp][10] = 1'b1;
                if( bits[bp-:12] == 12'b000000000001     ) ue_prefix[bp][11] = 1'b1;
                if( bits[bp-:13] == 13'b0000000000001    ) ue_prefix[bp][12] = 1'b1;
                if( bits[bp-:14] == 14'b00000000000001   ) ue_prefix[bp][13] = 1'b1;
                if( bits[bp-:15] == 15'b000000000000001  ) ue_prefix[bp][14] = 1'b1;
                if( bits[bp-:16] == 16'b0000000000000001 ) ue_prefix[bp][15] = 1'b1;
            end // ue prefix

            begin : _mb_syntax // All are UE/SE (assume max 15 prefix length
                s_mb_syntax[bp][MB_SYNTAX_P16x16_MVX] = |arc_mb_syntax[bp][MB_SYNTAX_P16x16_MVX]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_P16x16_MVY][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x16_MVX];   

                s_mb_syntax[bp][MB_SYNTAX_P16x16_MVY] = |arc_mb_syntax[bp][MB_SYNTAX_P16x16_MVY]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_CBP       ][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x16_MVY];
                    
                s_mb_syntax[bp][MB_SYNTAX_P16x8_MVX0] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_MVX0]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_P16x8_MVY0][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x8_MVX0];   

                s_mb_syntax[bp][MB_SYNTAX_P16x8_MVY0] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_MVY0]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_P16x8_MVX1][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x8_MVY0];   
                    
                s_mb_syntax[bp][MB_SYNTAX_P16x8_MVX1] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_MVX1]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_P16x8_MVY1][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x8_MVX1];  
                    
                s_mb_syntax[bp][MB_SYNTAX_P16x8_MVY1] = |arc_mb_syntax[bp][MB_SYNTAX_P16x8_MVY1]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_CBP    ][pl+16] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_P16x8_MVY1];    
                                    
                s_mb_syntax[bp][MB_SYNTAX_CBP] = |arc_mb_syntax[bp][MB_SYNTAX_CBP]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_DELTA_QP  ][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_CBP];   
                    
                s_mb_syntax[bp][MB_SYNTAX_DELTA_QP] = |arc_mb_syntax[bp][MB_SYNTAX_DELTA_QP]; // Reduction OR
                for( int pl=0; pl < 16; pl++ ) 
                    arc_mb_syntax[bp-(pl*2+1)][MB_SYNTAX_RESIDUAL  ][pl] = ue_prefix[bp][pl] & s_mb_syntax[bp][MB_SYNTAX_DELTA_QP];   
                    
                s_mb_syntax[bp][MB_SYNTAX_RESIDUAL] = |arc_mb_syntax[bp][MB_SYNTAX_RESIDUAL]; // Reduction OR
            end // mv

            begin : _codec_block_pattern // if this is start of a CBP then decode it, otherwise forward CBP 
                unique0 casez( { bits[bp-:11], s_mb_syntax[bp][MB_SYNTAX_CBP] } )
                    // Special case to just copy along previous CBP 
                    { 11'b??????????? , 1'b0 } : begin coded_block_pattern[bp-1] = coded_block_pattern[bp]; end
                    // Otherwise decode CBP to forward along 
                    // (TODO fix the table below, something looks wrong!!!)
                    { 11'b1?????????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd0  ; end // coded_block_pattern 0, 0, 0, 1
                    { 11'b010???????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd16 ; end // coded_block_pattern 16, 0, 1, 010
                    { 11'b011???????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd1  ; end // coded_block_pattern 1, 1, 0, 011
                    { 11'b00100?????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd2  ; end // coded_block_pattern 2, 2, 0, 00100
                    { 11'b00101?????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd4  ; end // coded_block_pattern 4, 4, 0, 00101
                    { 11'b00110?????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd8  ; end // coded_block_pattern 8, 8, 0, 00110
                    { 11'b00111?????? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd32 ; end // coded_block_pattern 32, 0, 2, 00111
                    { 11'b0001000???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd3  ; end // coded_block_pattern 3, 3, 0, 0001000
                    { 11'b0001001???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd5  ; end // coded_block_pattern 5, 5, 0, 0001001
                    { 11'b0001010???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd10 ; end // coded_block_pattern 10, A, 0, 0001010
                    { 11'b0001011???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd12 ; end // coded_block_pattern 12, C, 0, 0001011
                    { 11'b0001100???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd15 ; end // coded_block_pattern 15, F, 0, 0001100
                    { 11'b0001101???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd47 ; end // coded_block_pattern 47, F, 2, 0001101
                    { 11'b0001110???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd7  ; end // coded_block_pattern 7, 7, 0, 0001110
                    { 11'b0001111???? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd11 ; end // coded_block_pattern 11, B, 0, 0001111
                    { 11'b000010000?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd13 ; end // coded_block_pattern 13, D, 0, 000010000
                    { 11'b000010001?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd14 ; end // coded_block_pattern 14, E, 0, 000010001
                    { 11'b000010010?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd6  ; end // coded_block_pattern 6, 6, 0, 000010010
                    { 11'b000010011?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd9  ; end // coded_block_pattern 9, 9, 0, 000010011
                    { 11'b000010100?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd31 ; end // coded_block_pattern 31, F, 1, 000010100
                    { 11'b000010101?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd35 ; end // coded_block_pattern 35, 3, 2, 000010101
                    { 11'b000010110?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd37 ; end // coded_block_pattern 37, 5, 2, 000010110
                    { 11'b000010111?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd42 ; end // coded_block_pattern 42, A, 2, 000010111
                    { 11'b000011000?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd44 ; end // coded_block_pattern 44, C, 2, 000011000
                    { 11'b000011001?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd33 ; end // coded_block_pattern 33, 1, 2, 000011001
                    { 11'b000011010?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd34 ; end // coded_block_pattern 34, 2, 2, 000011010
                    { 11'b000011011?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd36 ; end // coded_block_pattern 36, 4, 2, 000011011
                    { 11'b000011100?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd40 ; end // coded_block_pattern 40, 8, 2, 000011100
                    { 11'b000011101?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd39 ; end // coded_block_pattern 39, 7, 2, 000011101
                    { 11'b000011110?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd43 ; end // coded_block_pattern 43, B, 2, 000011110
                    { 11'b000011111?? , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd45 ; end // coded_block_pattern 45, D, 2, 000011111
                    { 11'b00000100000 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd46 ; end // coded_block_pattern 46, E, 2, 00000100000
                    { 11'b00000100001 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd17 ; end // coded_block_pattern 17, 1, 1, 00000100001
                    { 11'b00000100010 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd18 ; end // coded_block_pattern 18, 2, 1, 00000100010
                    { 11'b00000100011 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd20 ; end // coded_block_pattern 20, 4, 1, 00000100011
                    { 11'b00000100100 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd24 ; end // coded_block_pattern 24, 8, 1, 00000100100
                    { 11'b00000100101 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd19 ; end // coded_block_pattern 19, 3, 1, 00000100101
                    { 11'b00000100110 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd21 ; end // coded_block_pattern 21, 5, 1, 00000100110
                    { 11'b00000100111 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd26 ; end // coded_block_pattern 26, A, 1, 00000100111
                    { 11'b00000101000 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd28 ; end // coded_block_pattern 28, C, 1, 00000101000
                    { 11'b00000101001 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd23 ; end // coded_block_pattern 23, 7, 1, 00000101001
                    { 11'b00000101010 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd27 ; end // coded_block_pattern 27, B, 1, 00000101010
                    { 11'b00000101011 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd29 ; end // coded_block_pattern 29, D, 1, 00000101011
                    { 11'b00000101100 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd30 ; end // coded_block_pattern 30, E, 1, 00000101100
                    { 11'b00000101101 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd22 ; end // coded_block_pattern 22, 6, 1, 00000101101
                    { 11'b00000101110 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd25 ; end // coded_block_pattern 25, 9, 1, 00000101110
                    { 11'b00000101111 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd38 ; end // coded_block_pattern 38, 6, 2, 00000101111
                    { 11'b00000110000 , 1'b1 } : begin coded_block_pattern[bp-1] = 6'd41 ; end // coded_block_pattern 41, 9, 2, 00000110000
                endcase 
            end // CBP

            begin : _residual // Handle the blocks of the transform
                // Current block starts and zero skip states 
                // 8x8 : 0
                s_blk_zero[ bp][0] = !coded_block_pattern[bp][0] & s_mb_syntax[bp][MB_SYNTAX_RESIDUAL];
                s_blk_start[bp][0] =  coded_block_pattern[bp][0] & s_mb_syntax[bp][MB_SYNTAX_RESIDUAL];
                s_blk_start[bp][1] =  s_blk_run[bp][0] & blk_end_flag[bp];
                s_blk_start[bp][2] =  s_blk_run[bp][1] & blk_end_flag[bp];
                s_blk_start[bp][3] =  s_blk_run[bp][2] & blk_end_flag[bp];
                
                // 8x8 : 1
                s_blk_zero[ bp][1] = !coded_block_pattern[bp][1] & s_blk_zero[bp][0]  |
                                     !coded_block_pattern[bp][1] & s_blk_run[bp][3] & blk_end_flag[bp];
                s_blk_start[bp][4] =  coded_block_pattern[bp][1] & s_blk_zero[bp][0]  |
                                      coded_block_pattern[bp][1] & s_blk_run[bp][3] & blk_end_flag[bp];
                s_blk_start[bp][5] =  s_blk_run[bp][4] & blk_end_flag[bp];
                s_blk_start[bp][6] =  s_blk_run[bp][5] & blk_end_flag[bp];
                s_blk_start[bp][7] =  s_blk_run[bp][6] & blk_end_flag[bp];
                
                // 8x8 : 2
                s_blk_zero[ bp][2] = !coded_block_pattern[bp][2] & s_blk_zero[bp][1]  |
                                     !coded_block_pattern[bp][2] & s_blk_run[bp][7] & blk_end_flag[bp];
                s_blk_start[bp][8] =  coded_block_pattern[bp][2] & s_blk_zero[bp][1]  |
                                      coded_block_pattern[bp][2] & s_blk_run[bp][7] & blk_end_flag[bp];
                s_blk_start[bp][9] =  s_blk_run[bp][8] & blk_end_flag[bp];
                s_blk_start[bp][10] =  s_blk_run[bp][9] & blk_end_flag[bp];
                s_blk_start[bp][11] =  s_blk_run[bp][10] & blk_end_flag[bp];
                
                // 8x8 : 3
                s_blk_zero[ bp][ 3] = !coded_block_pattern[bp][3] & s_blk_zero[bp][2]  |
                                      !coded_block_pattern[bp][3] & s_blk_run[bp][11] & blk_end_flag[bp];
                s_blk_start[bp][12] =  coded_block_pattern[bp][3] & s_blk_zero[bp][2]  |
                                       coded_block_pattern[bp][3] & s_blk_run[bp][11] & blk_end_flag[bp];
                s_blk_start[bp][13] =  s_blk_run[bp][12] & blk_end_flag[bp];
                s_blk_start[bp][14] =  s_blk_run[bp][13] & blk_end_flag[bp];
                s_blk_start[bp][15] =  s_blk_run[bp][14] & blk_end_flag[bp];
              
                // Chroma DC        
                s_blk_start[bp][16] =  ( coded_block_pattern[bp][4] | coded_block_pattern[bp][5] ) & s_blk_zero[bp][3]  |
                                       ( coded_block_pattern[bp][4] | coded_block_pattern[bp][5] ) & s_blk_run[bp][15] & blk_end_flag[bp] ;
                s_blk_start[bp][17] =  s_blk_run[bp][16] & blk_end_flag[bp];

                // Chroma AC
                s_blk_zero[ bp][ 4] = !coded_block_pattern[bp][4] & !coded_block_pattern[bp][5] & s_blk_zero[bp][3]  |
                                      !coded_block_pattern[bp][4] & !coded_block_pattern[bp][5] & s_blk_run[bp][15] & blk_end_flag[bp] |
                                                                    !coded_block_pattern[bp][5] & s_blk_run[bp][17] & blk_end_flag[bp] ;
                s_blk_start[bp][18] =  coded_block_pattern[bp][5] & s_blk_run[bp][17] & blk_end_flag[bp] ;
                s_blk_start[bp][19] =  s_blk_run[bp][18] & blk_end_flag[bp];
                s_blk_start[bp][20] =  s_blk_run[bp][19] & blk_end_flag[bp];
                s_blk_start[bp][21] =  s_blk_run[bp][20] & blk_end_flag[bp];
                s_blk_start[bp][22] =  s_blk_run[bp][21] & blk_end_flag[bp];
                s_blk_start[bp][23] =  s_blk_run[bp][22] & blk_end_flag[bp];
                s_blk_start[bp][24] =  s_blk_run[bp][23] & blk_end_flag[bp];
                s_blk_start[bp][25] =  s_blk_run[bp][24] & blk_end_flag[bp];

                // Current s_mb_end
                s_last[bp] = s_blk_zero[ bp][ 4] | s_blk_run[bp][25] & blk_end_flag[bp] ;

                // Next run state which latches until blk_end_flag
                for( int ii = 0; ii < 26; ii++ ) begin
                    s_blk_run[bp-1][ii] = s_blk_start[bp][ii] | ( s_blk_run[bp][ii] & !blk_end_flag[bp] );
                end
            end // residual

     
            // nC above and left maintenance
            
            begin : _num_coeff_neighborhood 
                // Zero out nc given block skip states
                local_left[bp][0:1]  = ( s_blk_zero[bp][0] | s_blk_zero[bp][1] ) ? 10'b0 : num_coeff_left[bp][0:1];
                local_left[bp][2:3]  = ( s_blk_zero[bp][2] | s_blk_zero[bp][3] ) ? 10'b0 : num_coeff_left[bp][2:3];
                local_above[bp][0:1] = ( s_blk_zero[bp][0] | s_blk_zero[bp][2] ) ? 10'b0 : num_coeff_above[bp][0:1];
                local_above[bp][2:3] = ( s_blk_zero[bp][1] | s_blk_zero[bp][3] ) ? 10'b0 : num_coeff_above[bp][2:3];
                local_left[bp][4:7]  = ( s_blk_zero[bp][4] ) ? 20'b0 : num_coeff_left[bp][4:7];
                local_above[bp][4:7] = ( s_blk_zero[bp][4] ) ? 20'b0 : num_coeff_above[bp][4:7];
                    
                // Calculate nC and nc_idx from nc data for given block
                if( s_blk_start[bp][ 0] ) arc_nc_x2[bp][ 0] = ( left_oop & above_oop ) ? 0 : ( left_oop ) ? { local_above[bp][0], 1'b0 } : ( above_oop ) ? { local_left[bp][0], 1'b0 } : local_left[bp][0] + local_above[bp][0] + 1;
                if( s_blk_start[bp][ 1] ) arc_nc_x2[bp][ 1] = ( above_oop ) ? { local_left[bp][0], 1'b0 } : local_left[bp][0] + local_above[bp][1] + 1;
                if( s_blk_start[bp][ 2] ) arc_nc_x2[bp][ 2] = ( left_oop  ) ? { local_above[bp][0], 1'b0 } : local_left[bp][1] + local_above[bp][0] + 1;
                if( s_blk_start[bp][ 3] ) arc_nc_x2[bp][ 3] = local_left[bp][1] + local_above[bp][1] + 1;
                if( s_blk_start[bp][ 4] ) arc_nc_x2[bp][ 4] = ( above_oop ) ? { local_left[bp][0], 1'b0 } : local_left[bp][0] + local_above[bp][2] + 1;
                if( s_blk_start[bp][ 5] ) arc_nc_x2[bp][ 5] = ( above_oop ) ? { local_left[bp][0], 1'b0 } : local_left[bp][0] + local_above[bp][3] + 1;
                if( s_blk_start[bp][ 6] ) arc_nc_x2[bp][ 6] = local_left[bp][1] + local_above[bp][2] + 1;
                if( s_blk_start[bp][ 7] ) arc_nc_x2[bp][ 7] = local_left[bp][1] + local_above[bp][3] + 1;
                if( s_blk_start[bp][ 8] ) arc_nc_x2[bp][ 8] = ( left_oop ) ? { local_above[bp][0], 1'b0 } : local_left[bp][2] + local_above[bp][0] + 1;
                if( s_blk_start[bp][ 9] ) arc_nc_x2[bp][ 9] = local_left[bp][2] + local_above[bp][1] + 1;
                if( s_blk_start[bp][10] ) arc_nc_x2[bp][10] = ( left_oop ) ? { local_above[bp][0], 1'b0 } : local_left[bp][3] + local_above[bp][0] + 1;
                if( s_blk_start[bp][11] ) arc_nc_x2[bp][11] = local_left[bp][3] + local_above[bp][1] + 1;
                if( s_blk_start[bp][12] ) arc_nc_x2[bp][12] = local_left[bp][2] + local_above[bp][2] + 1;
                if( s_blk_start[bp][13] ) arc_nc_x2[bp][13] = local_left[bp][2] + local_above[bp][3] + 1;
                if( s_blk_start[bp][14] ) arc_nc_x2[bp][14] = local_left[bp][3] + local_above[bp][2] + 1;
                if( s_blk_start[bp][15] ) arc_nc_x2[bp][15] = local_left[bp][3] + local_above[bp][3] + 1;
                if( s_blk_start[bp][16] ) arc_nc_x2[bp][16] = 8'h40;
                if( s_blk_start[bp][17] ) arc_nc_x2[bp][17] = 8'h40;
                if( s_blk_start[bp][18] ) arc_nc_x2[bp][18] = 8'h80 | (( left_oop & above_oop ) ? 0 : ( left_oop ) ? { local_above[bp][4], 1'b0 } : ( above_oop ) ? { local_left[bp][4], 1'b0 } : local_left[bp][4] + local_above[bp][4] + 1);
                if( s_blk_start[bp][19] ) arc_nc_x2[bp][19] = 8'h80 | (( above_oop ) ? { local_left[bp][4], 1'b0 } : local_left[bp][4] + local_above[bp][5] + 1);
                if( s_blk_start[bp][20] ) arc_nc_x2[bp][20] = 8'h80 | (( left_oop  ) ? { local_above[bp][4], 1'b0 } : local_left[bp][5] + local_above[bp][4] + 1);
                if( s_blk_start[bp][21] ) arc_nc_x2[bp][21] = 8'h80 | (local_left[bp][5] + local_above[bp][5] + 1);
                if( s_blk_start[bp][22] ) arc_nc_x2[bp][22] = 8'h80 | (( left_oop & above_oop ) ? 0 : ( left_oop ) ? { local_above[bp][6], 1'b0 } : ( above_oop ) ? { local_left[bp][6], 1'b0 } : local_left[bp][6] + local_above[bp][6] + 1);
                if( s_blk_start[bp][23] ) arc_nc_x2[bp][23] = 8'h80 | (( above_oop ) ? { local_left[bp][6], 1'b0 } : local_left[bp][6] + local_above[bp][7] + 1);
                if( s_blk_start[bp][24] ) arc_nc_x2[bp][24] = 8'h80 | (( left_oop  ) ? { local_above[bp][6], 1'b0 } : local_left[bp][7] + local_above[bp][6] + 1);
                if( s_blk_start[bp][25] ) arc_nc_x2[bp][25] = 8'h80 | (local_left[bp][7] + local_above[bp][7] + 1);
                
                nc_x2[bp] = arc_nc_x2[bp][ 0] | arc_nc_x2[bp][ 1] | arc_nc_x2[bp][ 2] | arc_nc_x2[bp][ 3] | arc_nc_x2[bp][ 4] |
                            arc_nc_x2[bp][ 5] | arc_nc_x2[bp][ 6] | arc_nc_x2[bp][ 7] | arc_nc_x2[bp][ 8] | arc_nc_x2[bp][ 9] |
                            arc_nc_x2[bp][10] | arc_nc_x2[bp][11] | arc_nc_x2[bp][12] | arc_nc_x2[bp][13] | arc_nc_x2[bp][14] |
                            arc_nc_x2[bp][15] | arc_nc_x2[bp][16] | arc_nc_x2[bp][17] | arc_nc_x2[bp][18] | arc_nc_x2[bp][19] |
                            arc_nc_x2[bp][20] | arc_nc_x2[bp][21] | arc_nc_x2[bp][22] | arc_nc_x2[bp][23] | arc_nc_x2[bp][24] |
                            arc_nc_x2[bp][25] ;
                
                // Reduction of blk_starts and mapping to nc_idx
                num_coeff_idx[bp][5:0] = (!(|s_blk_start[bp])) ? 6'b00_0000 : ( nc_x2[bp][6] ) ? 6'b01_0000 : { nc_x2[bp][7], 1'b0, ( |nc_x2[bp][5:4] ) ? 4'b1000 : ( nc_x2[bp][3] ) ? 4'b0100 : ( nc_x2[bp][2] ) ? 4'b0010 : 4'b0001 } ;
                                         
                // coeff_token decoded here nc = coeff_token_decode( nc_idx )
                begin : _coeff_token
                    if( bits[bp-:1 ]== 1'b1                ) nc[bp][0][0] = 0;
                    if( bits[bp-:6 ]== 6'b000101           |
                        bits[bp-:2 ]== 2'b01               ) nc[bp][0][1] = 1;
                    if( bits[bp-:8 ]== 8'b00000111         |
                        bits[bp-:6 ]== 6'b000100           |
                        bits[bp-:3 ]== 3'b001              ) nc[bp][0][2] = 2;
                    if( bits[bp-:9 ]== 9'b000000111        |
                        bits[bp-:8 ]== 8'b00000110         |
                        bits[bp-:7 ]== 7'b0000101          |
                        bits[bp-:5 ]== 5'b00011            ) nc[bp][0][3] = 3;
                    if( bits[bp-:10]==10'b0000000111       |
                        bits[bp-:9 ]== 9'b000000110        |
                        bits[bp-:8 ]== 8'b00000101         |
                        bits[bp-:6 ]== 6'b000011           ) nc[bp][0][4] = 4;
                    if( bits[bp-:11]==11'b00000000111      |
                        bits[bp-:10]==10'b0000000110       |
                        bits[bp-:9 ]== 9'b000000101        |
                        bits[bp-:7 ]== 7'b0000100          ) nc[bp][0][5] = 5;
                    if( bits[bp-:13]==13'b0000000001111    |
                        bits[bp-:11]==11'b00000000110      |
                        bits[bp-:10]==10'b0000000101       |
                        bits[bp-:8 ]== 8'b00000100         ) nc[bp][0][6] = 6;
                    if( bits[bp-:13]==13'b0000000001011    |
                        bits[bp-:13]==13'b0000000001110    |
                        bits[bp-:11]==11'b00000000101      |
                        bits[bp-:9 ]== 9'b000000100        ) nc[bp][0][7] = 7;
                    if( bits[bp-:13]==13'b0000000001000    |
                        bits[bp-:13]==13'b0000000001010    |
                        bits[bp-:13]==13'b0000000001101    |
                        bits[bp-:10]==10'b0000000100       ) nc[bp][0][8] = 8;
                    if( bits[bp-:14]==14'b00000000001111   |
                        bits[bp-:14]==14'b00000000001110   |
                        bits[bp-:13]==13'b0000000001001    |
                        bits[bp-:11]==11'b00000000100      ) nc[bp][0][9] = 9;
                    if( bits[bp-:14]==14'b00000000001011   |
                        bits[bp-:14]==14'b00000000001010   |
                        bits[bp-:14]==14'b00000000001101   |
                        bits[bp-:13]==13'b0000000001100    ) nc[bp][0][10] = 10;
                    if( bits[bp-:15]==15'b000000000001111  |
                        bits[bp-:15]==15'b000000000001110  |
                        bits[bp-:14]==14'b00000000001001   |
                        bits[bp-:14]==14'b00000000001100   ) nc[bp][0][11] = 11;
                    if( bits[bp-:15]==15'b000000000001011  |
                        bits[bp-:15]==15'b000000000001010  |
                        bits[bp-:15]==15'b000000000001101  |
                        bits[bp-:14]==14'b00000000001000   ) nc[bp][0][12] = 12;
                    if( bits[bp-:16]==16'b0000000000001111 |
                        bits[bp-:15]==15'b000000000000001  |
                        bits[bp-:15]==15'b000000000001001  |
                        bits[bp-:15]==15'b000000000001100  ) nc[bp][0][13] = 13;
                    if( bits[bp-:16]==16'b0000000000001011 |
                        bits[bp-:16]==16'b0000000000001110 |
                        bits[bp-:16]==16'b0000000000001101 |
                        bits[bp-:15]==15'b000000000001000  ) nc[bp][0][14] = 14;
                    if( bits[bp-:16]==16'b0000000000000111 |
                        bits[bp-:16]==16'b0000000000001010 |
                        bits[bp-:16]==16'b0000000000001001 |
                        bits[bp-:16]==16'b0000000000001100 ) nc[bp][0][15] = 15;
                    if( bits[bp-:16]==16'b0000000000000100 |
                        bits[bp-:16]==16'b0000000000000110 |
                        bits[bp-:16]==16'b0000000000000101 |
                        bits[bp-:16]==16'b0000000000001000 ) nc[bp][0][16] = 16;
                    if( bits[bp-:2 ]== 2'b11               ) nc[bp][1][0] = 0;  
                    if( bits[bp-:6 ]== 6'b001011           |                    
                        bits[bp-:2 ]== 2'b10               ) nc[bp][1][1] = 1;  
                    if( bits[bp-:6 ]== 6'b000111           |                    
                        bits[bp-:5 ]== 5'b00111            |                    
                        bits[bp-:3 ]== 3'b011              ) nc[bp][1][2] = 2;  
                    if( bits[bp-:7 ]== 7'b0000111          |                    
                        bits[bp-:6 ]== 6'b001010           |                    
                        bits[bp-:6 ]== 6'b001001           |                    
                        bits[bp-:4 ]== 4'b0101             ) nc[bp][1][3] = 3;  
                    if( bits[bp-:8 ]== 8'b00000111         |                    
                        bits[bp-:6 ]== 6'b000110           |                    
                        bits[bp-:6 ]== 6'b000101           |                    
                        bits[bp-:4 ]== 4'b0100             ) nc[bp][1][4] = 4;  
                    if( bits[bp-:8 ]== 8'b00000100         |                    
                        bits[bp-:7 ]== 7'b0000110          |                    
                        bits[bp-:7 ]== 7'b0000101          |                    
                        bits[bp-:5 ]== 5'b00110            ) nc[bp][1][5] = 5;  
                    if( bits[bp-:9 ]== 9'b000000111        |                    
                        bits[bp-:8 ]== 8'b00000110         |                    
                        bits[bp-:8 ]== 8'b00000101         |                    
                        bits[bp-:6 ]== 6'b001000           ) nc[bp][1][6] = 6;  
                    if( bits[bp-:11]==11'b00000001111      |                    
                        bits[bp-:9 ]== 9'b000000110        |                    
                        bits[bp-:9 ]== 9'b000000101        |                    
                        bits[bp-:6 ]== 6'b000100           ) nc[bp][1][7] = 7;  
                    if( bits[bp-:11]==11'b00000001011      |                    
                        bits[bp-:11]==11'b00000001110      |                    
                        bits[bp-:11]==11'b00000001101      |                    
                        bits[bp-:7 ]== 7'b0000100          ) nc[bp][1][8] = 8;  
                    if( bits[bp-:12]==12'b000000001111     |                    
                        bits[bp-:11]==11'b00000001010      |                    
                        bits[bp-:11]==11'b00000001001      |                    
                        bits[bp-:9 ]== 9'b000000100        ) nc[bp][1][9] = 9;  
                    if( bits[bp-:12]==12'b000000001011     |                    
                        bits[bp-:12]==12'b000000001110     |                    
                        bits[bp-:12]==12'b000000001101     |                    
                        bits[bp-:11]==11'b00000001100      ) nc[bp][1][10] = 10;
                    if( bits[bp-:12]==12'b000000001000     |                    
                        bits[bp-:12]==12'b000000001010     |                    
                        bits[bp-:12]==12'b000000001001     |                    
                        bits[bp-:11]==11'b00000001000      ) nc[bp][1][11] = 11;
                    if( bits[bp-:13]==13'b0000000001111    |                    
                        bits[bp-:13]==13'b0000000001110    |                    
                        bits[bp-:13]==13'b0000000001101    |                    
                        bits[bp-:12]==12'b000000001100     ) nc[bp][1][12] = 12;
                    if( bits[bp-:13]==13'b0000000001011    |                    
                        bits[bp-:13]==13'b0000000001010    |                    
                        bits[bp-:13]==13'b0000000001001    |                    
                        bits[bp-:13]==13'b0000000001100    ) nc[bp][1][13] = 13;
                    if( bits[bp-:13]==13'b0000000000111    |                    
                        bits[bp-:14]==14'b00000000001011   |                    
                        bits[bp-:13]==13'b0000000000110    |                    
                        bits[bp-:13]==13'b0000000001000    ) nc[bp][1][14] = 14;
                    if( bits[bp-:14]==14'b00000000001001   |                    
                        bits[bp-:14]==14'b00000000001000   |                    
                        bits[bp-:14]==14'b00000000001010   |                    
                        bits[bp-:13]==13'b0000000000001    ) nc[bp][1][15] = 15;
                    if( bits[bp-:14]==14'b00000000000111   |                    
                        bits[bp-:14]==14'b00000000000110   |                    
                        bits[bp-:14]==14'b00000000000101   |                    
                        bits[bp-:14]==14'b00000000000100   ) nc[bp][1][16] = 16;
                    if( bits[bp-:4 ]== 4'b1111             ) nc[bp][2][0] = 0;  
                    if( bits[bp-:6 ]== 6'b001111           |                    
                        bits[bp-:4 ]== 4'b1110             ) nc[bp][2][1] = 1;  
                    if( bits[bp-:6 ]== 6'b001011           |                    
                        bits[bp-:5 ]== 5'b01111            |                    
                        bits[bp-:4 ]== 4'b1101             ) nc[bp][2][2] = 2;  
                    if( bits[bp-:6 ]== 6'b001000           |                    
                        bits[bp-:5 ]== 5'b01100            |                    
                        bits[bp-:5 ]== 5'b01110            |                    
                        bits[bp-:4 ]== 4'b1100             ) nc[bp][2][3] = 3;  
                    if( bits[bp-:7 ]== 7'b0001111          |                    
                        bits[bp-:5 ]== 5'b01010            |                    
                        bits[bp-:5 ]== 5'b01011            |                    
                        bits[bp-:4 ]== 4'b1011             ) nc[bp][2][4] = 4;  
                    if( bits[bp-:7 ]== 7'b0001011          |                    
                        bits[bp-:5 ]== 5'b01000            |                    
                        bits[bp-:5 ]== 5'b01001            |                    
                        bits[bp-:4 ]== 4'b1010             ) nc[bp][2][5] = 5;  
                    if( bits[bp-:7 ]== 7'b0001001          |                    
                        bits[bp-:6 ]== 6'b001110           |                    
                        bits[bp-:6 ]== 6'b001101           |                    
                        bits[bp-:4 ]== 4'b1001             ) nc[bp][2][6] = 6;  
                    if( bits[bp-:7 ]== 7'b0001000          |                    
                        bits[bp-:6 ]== 6'b001010           |                    
                        bits[bp-:6 ]== 6'b001001           |                    
                        bits[bp-:4 ]== 4'b1000             ) nc[bp][2][7] = 7;  
                    if( bits[bp-:8 ]== 8'b00001111         |                    
                        bits[bp-:7 ]== 7'b0001110          |                    
                        bits[bp-:7 ]== 7'b0001101          |                    
                        bits[bp-:5 ]== 5'b01101            ) nc[bp][2][8] = 8;  
                    if( bits[bp-:8 ]== 8'b00001011         |                    
                        bits[bp-:8 ]== 8'b00001110         |                    
                        bits[bp-:7 ]== 7'b0001010          |                    
                        bits[bp-:6 ]== 6'b001100           ) nc[bp][2][9] = 9;  
                    if( bits[bp-:9 ]== 9'b000001111        |                    
                        bits[bp-:8 ]== 8'b00001010         |                    
                        bits[bp-:8 ]== 8'b00001101         |                    
                        bits[bp-:7 ]== 7'b0001100          ) nc[bp][2][10] = 10;
                    if( bits[bp-:9 ]== 9'b000001011        |                    
                        bits[bp-:9 ]== 9'b000001110        |                    
                        bits[bp-:8 ]== 8'b00001001         |                    
                        bits[bp-:8 ]== 8'b00001100         ) nc[bp][2][11] = 11;
                    if( bits[bp-:9 ]== 9'b000001000        |                    
                        bits[bp-:9 ]== 9'b000001010        |                    
                        bits[bp-:9 ]== 9'b000001101        |                    
                        bits[bp-:8 ]== 8'b00001000         ) nc[bp][2][12] = 12;
                    if( bits[bp-:10]==10'b0000001101       |                    
                        bits[bp-:9 ]== 9'b000000111        |                    
                        bits[bp-:9 ]== 9'b000001001        |                    
                        bits[bp-:9 ]== 9'b000001100        ) nc[bp][2][13] = 13;
                    if( bits[bp-:10]==10'b0000001001       |                    
                        bits[bp-:10]==10'b0000001100       |                    
                        bits[bp-:10]==10'b0000001011       |                    
                        bits[bp-:10]==10'b0000001010       ) nc[bp][2][14] = 14;
                    if( bits[bp-:10]==10'b0000000101       |                    
                        bits[bp-:10]==10'b0000001000       |                    
                        bits[bp-:10]==10'b0000000111       |                    
                        bits[bp-:10]==10'b0000000110       ) nc[bp][2][15] = 15;
                    if( bits[bp-:10]==10'b0000000001       |                    
                        bits[bp-:10]==10'b0000000100       |                    
                        bits[bp-:10]==10'b0000000011       |                    
                        bits[bp-:10]==10'b0000000010       ) nc[bp][2][16] = 16;
                    if( bits[bp-:6 ]== 6'b000011           ) nc[bp][3][0] = 0;  
                    if( bits[bp-:6 ]== 6'b000000           |                    
                        bits[bp-:6 ]== 6'b000001           ) nc[bp][3][1] = 1;  
                    if( bits[bp-:6 ]== 6'b000100           |                    
                        bits[bp-:6 ]== 6'b000101           |                    
                        bits[bp-:6 ]== 6'b000110           ) nc[bp][3][2] = 2;  
                    if( bits[bp-:6 ]== 6'b001000           |                    
                        bits[bp-:6 ]== 6'b001001           |                    
                        bits[bp-:6 ]== 6'b001010           |                    
                        bits[bp-:6 ]== 6'b001011           ) nc[bp][3][3] = 3;  
                    if( bits[bp-:6 ]== 6'b001100           |                    
                        bits[bp-:6 ]== 6'b001101           |                    
                        bits[bp-:6 ]== 6'b001110           |                    
                        bits[bp-:6 ]== 6'b001111           ) nc[bp][3][4] = 4;  
                    if( bits[bp-:6 ]== 6'b010000           |                    
                        bits[bp-:6 ]== 6'b010001           |                    
                        bits[bp-:6 ]== 6'b010010           |                    
                        bits[bp-:6 ]== 6'b010011           ) nc[bp][3][5] = 5;  
                    if( bits[bp-:6 ]== 6'b010100           |                    
                        bits[bp-:6 ]== 6'b010101           |                    
                        bits[bp-:6 ]== 6'b010110           |                    
                        bits[bp-:6 ]== 6'b010111           ) nc[bp][3][6] = 6;  
                    if( bits[bp-:6 ]== 6'b011000           |                    
                        bits[bp-:6 ]== 6'b011001           |                    
                        bits[bp-:6 ]== 6'b011010           |                    
                        bits[bp-:6 ]== 6'b011011           ) nc[bp][3][7] = 7;  
                    if( bits[bp-:6 ]== 6'b011100           |                    
                        bits[bp-:6 ]== 6'b011101           |                    
                        bits[bp-:6 ]== 6'b011110           |                    
                        bits[bp-:6 ]== 6'b011111           ) nc[bp][3][8] = 8;  
                    if( bits[bp-:6 ]== 6'b100000           |                    
                        bits[bp-:6 ]== 6'b100001           |                    
                        bits[bp-:6 ]== 6'b100010           |                    
                        bits[bp-:6 ]== 6'b100011           ) nc[bp][3][9] = 9;  
                    if( bits[bp-:6 ]== 6'b100100           |                    
                        bits[bp-:6 ]== 6'b100101           |                    
                        bits[bp-:6 ]== 6'b100110           |                    
                        bits[bp-:6 ]== 6'b100111           ) nc[bp][3][10] = 10;
                    if( bits[bp-:6 ]== 6'b101000           |                    
                        bits[bp-:6 ]== 6'b101001           |                    
                        bits[bp-:6 ]== 6'b101010           |                    
                        bits[bp-:6 ]== 6'b101011           ) nc[bp][3][11] = 11;
                    if( bits[bp-:6 ]== 6'b101100           |                    
                        bits[bp-:6 ]== 6'b101101           |                    
                        bits[bp-:6 ]== 6'b101110           |                    
                        bits[bp-:6 ]== 6'b101111           ) nc[bp][3][12] = 12;
                    if( bits[bp-:6 ]== 6'b110000           |                    
                        bits[bp-:6 ]== 6'b110001           |                    
                        bits[bp-:6 ]== 6'b110010           |                    
                        bits[bp-:6 ]== 6'b110011           ) nc[bp][3][13] = 13;
                    if( bits[bp-:6 ]== 6'b110100           |                    
                        bits[bp-:6 ]== 6'b110101           |                    
                        bits[bp-:6 ]== 6'b110110           |                    
                        bits[bp-:6 ]== 6'b110111           ) nc[bp][3][14] = 14;
                    if( bits[bp-:6 ]== 6'b111000           |                    
                        bits[bp-:6 ]== 6'b111001           |                    
                        bits[bp-:6 ]== 6'b111010           |                    
                        bits[bp-:6 ]== 6'b111011           ) nc[bp][3][15] = 15;
                    if( bits[bp-:6 ]== 6'b111100           |                    
                        bits[bp-:6 ]== 6'b111101           |                    
                        bits[bp-:6 ]== 6'b111110           |                    
                        bits[bp-:6 ]== 6'b111111           ) nc[bp][3][16] = 16;
                end // coeff token

                // select applicable NC. AndOr Mux                
                num_coeff[bp][4:0] = {5{num_coeff_idx[bp][0]}} & ( nc[bp][0][0] | nc[bp][0][1] |nc[bp][0][2] |nc[bp][0][3] |nc[bp][0][4] |nc[bp][0][5] |nc[bp][0][6] |nc[bp][0][7] |nc[bp][0][8] |nc[bp][0][9] |nc[bp][0][10] |nc[bp][0][11] |nc[bp][0][12] |nc[bp][0][13] |nc[bp][0][14] |nc[bp][0][15] |nc[bp][0][16] ) |
                                     {5{num_coeff_idx[bp][1]}} & ( nc[bp][1][0] | nc[bp][1][1] |nc[bp][1][2] |nc[bp][1][3] |nc[bp][1][4] |nc[bp][1][5] |nc[bp][1][6] |nc[bp][1][7] |nc[bp][1][8] |nc[bp][1][9] |nc[bp][1][10] |nc[bp][1][11] |nc[bp][1][12] |nc[bp][1][13] |nc[bp][1][14] |nc[bp][1][15] |nc[bp][1][16] ) |
                                     {5{num_coeff_idx[bp][2]}} & ( nc[bp][2][0] | nc[bp][2][1] |nc[bp][2][2] |nc[bp][2][3] |nc[bp][2][4] |nc[bp][2][5] |nc[bp][2][6] |nc[bp][2][7] |nc[bp][2][8] |nc[bp][2][9] |nc[bp][2][10] |nc[bp][2][11] |nc[bp][2][12] |nc[bp][2][13] |nc[bp][2][14] |nc[bp][2][15] |nc[bp][2][16] ) |
                                     {5{num_coeff_idx[bp][3]}} & ( nc[bp][3][0] | nc[bp][3][1] |nc[bp][3][2] |nc[bp][3][3] |nc[bp][3][4] |nc[bp][3][5] |nc[bp][3][6] |nc[bp][3][7] |nc[bp][3][8] |nc[bp][3][9] |nc[bp][3][10] |nc[bp][3][11] |nc[bp][3][12] |nc[bp][3][13] |nc[bp][3][14] |nc[bp][3][15] |nc[bp][3][16] ) ;

                // Update NEXT neighbourhood based on immediate coeff token decode if start of a new blocks               
                num_coeff_left[bp-1][0] = ( s_blk_start[bp][ 0] | s_blk_start[bp][ 1] | s_blk_start[bp][ 4] | s_blk_start[bp][ 5] ) ? num_coeff[bp] : local_left[bp][0];
                num_coeff_left[bp-1][1] = ( s_blk_start[bp][ 2] | s_blk_start[bp][ 3] | s_blk_start[bp][ 6] | s_blk_start[bp][ 7] ) ? num_coeff[bp] : local_left[bp][1];
                num_coeff_left[bp-1][2] = ( s_blk_start[bp][ 8] | s_blk_start[bp][ 9] | s_blk_start[bp][12] | s_blk_start[bp][13] ) ? num_coeff[bp] : local_left[bp][2];
                num_coeff_left[bp-1][3] = ( s_blk_start[bp][10] | s_blk_start[bp][11] | s_blk_start[bp][14] | s_blk_start[bp][15] ) ? num_coeff[bp] : local_left[bp][3];
                num_coeff_left[bp-1][4] = ( s_blk_start[bp][18] | s_blk_start[bp][19] ) ? num_coeff[bp] : local_left[bp][4];
                num_coeff_left[bp-1][5] = ( s_blk_start[bp][20] | s_blk_start[bp][21] ) ? num_coeff[bp] : local_left[bp][5];
                num_coeff_left[bp-1][6] = ( s_blk_start[bp][22] | s_blk_start[bp][23] ) ? num_coeff[bp] : local_left[bp][6];
                num_coeff_left[bp-1][7] = ( s_blk_start[bp][24] | s_blk_start[bp][25] ) ? num_coeff[bp] : local_left[bp][7];

                num_coeff_above[bp-1][0] = ( s_blk_start[bp][ 0] | s_blk_start[bp][ 2] | s_blk_start[bp][ 8] | s_blk_start[bp][10] ) ? num_coeff[bp] : local_above[bp][0];
                num_coeff_above[bp-1][1] = ( s_blk_start[bp][ 1] | s_blk_start[bp][ 3] | s_blk_start[bp][ 9] | s_blk_start[bp][11] ) ? num_coeff[bp] : local_above[bp][1];
                num_coeff_above[bp-1][2] = ( s_blk_start[bp][ 4] | s_blk_start[bp][ 6] | s_blk_start[bp][12] | s_blk_start[bp][14] ) ? num_coeff[bp] : local_above[bp][2];
                num_coeff_above[bp-1][3] = ( s_blk_start[bp][ 5] | s_blk_start[bp][ 5] | s_blk_start[bp][13] | s_blk_start[bp][15] ) ? num_coeff[bp] : local_above[bp][3];
                num_coeff_above[bp-1][4] = ( s_blk_start[bp][18] | s_blk_start[bp][20] ) ? num_coeff[bp] : local_above[bp][4];
                num_coeff_above[bp-1][5] = ( s_blk_start[bp][19] | s_blk_start[bp][21] ) ? num_coeff[bp] : local_above[bp][5];
                num_coeff_above[bp-1][6] = ( s_blk_start[bp][22] | s_blk_start[bp][24] ) ? num_coeff[bp] : local_above[bp][6];
                num_coeff_above[bp-1][7] = ( s_blk_start[bp][23] | s_blk_start[bp][25] ) ? num_coeff[bp] : local_above[bp][7];
                
            end // num_coeff
        end // bp
    end // _lattice

    // Connect up MB END bits
    assign mb_end[WIDTH-1:0]        = s_last[WIDTH+32-1:32];
    assign nc_right                 = num_coeff_left[31];
    assign nc_below                 = num_coeff_above[31];
    assign blk_nc_idx[WIDTH-1:0]    = num_coeff_idx[WIDTH+32-1:32];
endmodule

