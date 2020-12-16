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
module gg_deblock_filter
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk, // not used, combinatorial block
    
    input  logic [0:3][0:15][7:0]  blki,  // 512 bit unfiltered or partially deblocked input
    input  logic [0:3][0:15][7:0]  blko, // 512 bit fully or partially deblocked output
    input  logic [0:2][2:0] bs, // deblock edge strength for 3 boundaries 0-cur/lef, 1-lef/ale, 2-cur/abv
    input  logic [0:3][5:0] qpz, // block quantization paramters [0-51], clipped to zero if IPCM
    input  logic [4:0] FilterOffsetA, // -12 to +12
    input  logic [4:0] FilterOffsetB, // -12 to +12
    input  logic ch_flag // chroma block filtering
    );     

    // Intermediate nodes
    logic [0:3][7:0] cur_blk;
    logic [0:3][7:0] lef_blk;
    
    // calc alpha, beta deblock thresholds 
    
    logic [0:2][7:0] alpha;
    logic [0:2][7:0] beta;
    logic [0:2][5:0] tc0;
    logic [0:2][1:0] bsidx;
    
    logic [5:0] qpavg[2:0];
    logic [6:0] qpofsA[2:0];
    logic [6:0] qpofsB[2:0];
    logic [5:0] indexA[2:0];
    logic [5:0] indexB[2:0];
    logic xx0, xx1, xx2; // dummy bits
    
    // Lookup Tables    
    logic [0:51][5:0] qpc_table;
    logic [0:51][7:0] alpha_table;
    logic [0:51][7:0] beta_table;
    logic [0:2][0:51][4:0] tc0_table;
    
    assign qpc_table =  { 6'd0,  6'd1,  6'd2,  6'd3,  6'd4,  6'd5,  6'd6,  6'd7,  6'd8,  6'd9,  6'd10, 6'd11, 
                          6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23, 
                          6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd29, 6'd30, 6'd31, 6'd32, 6'd32, 6'd33, 
                          6'd34, 6'd34, 6'd35, 6'd35, 6'd36, 6'd36, 6'd37, 6'd37, 6'd37, 6'd38, 6'd38, 6'd38, 
                          6'd39, 6'd39, 6'd39, 6'd39 };

    assign alpha_table = { 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 
                           8'd0, 8'd0, 8'd0, 8'd0, 8'd4, 8'd4, 8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 
                           8'd12, 8'd13, 8'd15, 8'd17, 8'd20, 8'd22, 8'd25, 8'd28, 8'd32, 8'd36, 8'd40, 8'd45, 
                           8'd50, 8'd56, 8'd63, 8'd71, 8'd80, 8'd90, 8'd101, 8'd113, 8'd127, 8'd144, 8'd162, 8'd182, 
                           8'd203, 8'd226, 8'd255, 8'd255 };
                           
    assign beta_table  = { 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 
                           8'd0, 8'd0, 8'd0, 8'd0, 8'd2, 8'd2, 8'd2, 8'd3, 8'd3, 8'd3, 8'd3, 8'd4, 
                           8'd4, 8'd4, 8'd6, 8'd6, 8'd7, 8'd7, 8'd8, 8'd8, 8'd9, 8'd9, 8'd10, 8'd10, 
                           8'd11, 8'd11, 8'd12, 8'd12, 8'd13, 8'd13, 8'd14, 8'd14, 8'd15, 8'd15, 8'd16, 8'd16, 
                           8'd17, 8'd17, 8'd18, 8'd18 };

    assign tc0_table =  {{ 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 
                           5'd2, 5'd3, 5'd3, 5'd3, 5'd4, 5'd4, 5'd4, 5'd5, 5'd6, 5'd6, 5'd7, 5'd8, 
                           5'd9, 5'd10, 5'd11, 5'd13  },
                         { 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 5'd2, 5'd3, 
                           5'd3, 5'd3, 5'd4, 5'd4, 5'd5, 5'd5, 5'd6, 5'd7, 5'd8, 5'd8, 5'd10, 5'd11, 
                           5'd12, 5'd13, 5'd15, 5'd17 },
                         { 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 5'd2, 5'd3, 5'd3, 5'd3, 5'd4, 5'd4, 
                           5'd4, 5'd5, 5'd6, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11, 5'd13, 5'd14, 5'd16, 
                           5'd18, 5'd20, 5'd23, 5'd25 } };

    
    always_comb begin
        // calc qp avg for the edges
        { qpavg[0][5:0], xx0 } = ch_flag ? (qpc_table[qpz[2]] + qpc_table[qpz[3]] + 1) : ( qpz[2] + qpz[3] + 1);  
        { qpavg[1][5:0], xx1 } = ch_flag ? (qpc_table[qpz[0]] + qpc_table[qpz[2]] + 1) : ( qpz[0] + qpz[2] + 1);  
        { qpavg[2][5:0], xx2 } = ch_flag ? (qpc_table[qpz[1]] + qpc_table[qpz[3]] + 1) : ( qpz[1] + qpz[3] + 1);  
        // loop thru edges to derive alpha, beta
        for( int ii = 0; ii < 3; ii++ ) begin
            // Deblock offset params
            qpofsA[ii][6:0] = { 1'b0, qpavg[ii][5:0] } + { {2{FilterOffsetA[4]}}, FilterOffsetA[4:0] };
            qpofsB[ii][6:0] = { 1'b0, qpavg[ii][5:0] } + { {2{FilterOffsetB[4]}}, FilterOffsetB[4:0] };
            // Clipped to [0,51] to give indexA, B
            indexA[ii][5:0] = ( qpofsA[ii][6] ) ? 6'd0 : ( qpofsA[ii][5:0] > 6'd51 ) ? 6'd51 : qpofsA[ii][5:0];
            indexB[ii][5:0] = ( qpofsB[ii][6] ) ? 6'd0 : ( qpofsB[ii][5:0] > 6'd51 ) ? 6'd51 : qpofsB[ii][5:0];
            // lookup alpha, beta
            alpha[ii][7:0] = alpha_table[indexA[ii]];
            beta[ii][7:0]  = beta_table[indexB[ii]];
            bsidx[ii][1:0] = (bs==2)?2'd1:(bs==3)?2'd2:2'd0;
            tc0[ii][5:0]   = tc0_table[bsidx[ii]][indexA[ii]];
         end
    end
    
        
    genvar ii;
    generate
        // Vertical edge 0 Filter:  cur | lef = filter ( blki[2] | blki[3] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt0 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( bs[0]    ),
                .alpha      ( alpha[0] ),
                .beta       ( beta[0]  ),
                .tc0        ( tc0[0]   ),
                .qi         ( { blki[3][0+4*ii], blki[3][1+4*ii], blki[3][2+4*ii], blki[3][3+4*ii] } ),
                .pi         ( { blki[2][3+4*ii], blki[2][2+4*ii], blki[2][1+4*ii], blki[2][0+4*ii] } ),
                .qo         ( { cur_blk[0+4*ii], cur_blk[1+4*ii], cur_blk[2+4*ii], cur_blk[3+4*ii] } ),
                .po         ( { lef_blk[3+4*ii], lef_blk[2+4*ii], lef_blk[1+4*ii], lef_blk[0+4*ii] } )
            );
        end
        
        // Horizontal edge 1 filter: blko[2] | blko[0] =  filter ( lef | blki[0] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt1 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( bs[1]    ),
                .alpha      ( alpha[1] ),
                .beta       ( beta[1]  ),
                .tc0        ( tc0[1]   ),
                .qi         ( { lef_blk[0*4+ii], lef_blk[1*4+ii], lef_blk[2*4+ii],lef_blk[3*4+ii] } ),
                .pi         ( { blki[0][3*4+ii], blki[0][2*4+ii], blki[0][1*4+ii], blki[0][0*4+ii] } ),
                .qo         ( { blko[2][0*4+ii], blko[2][1*4+ii], blko[2][2*4+ii], blko[2][3*4+ii] } ),
                .po         ( { blko[0][3*4+ii], blko[0][2*4+ii], blko[0][1*4+ii], blko[0][0*4+ii] } )
            );
        end
    
        // Horizontal edge 2 filter: blko[3] | blko[1] =  filter ( cur | blki[1] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt2 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( bs[2]    ),
                .alpha      ( alpha[2] ),
                .beta       ( beta[2]  ),
                .tc0        ( tc0[2]   ),
                .qi         ( { cur_blk[0*4+ii], cur_blk[1*4+ii], cur_blk[2*4+ii], cur_blk[3*4+ii] } ),
                .pi         ( { blki[1][3*4+ii], blki[1][2*4+ii], blki[1][1*4+ii], blki[1][0*4+ii] } ),
                .qo         ( { blko[3][0*4+ii], blko[3][1*4+ii], blko[3][2*4+ii], blko[3][3*4+ii] } ),
                .po         ( { blko[1][3*4+ii], blko[1][2*4+ii], blko[1][1*4+ii], blko[1][0*4+ii] } )
            );
        end
    endgenerate    
endmodule

module gg_deblock_filter_1x8
(
    input logic clk,
    input logic ch_flag,
    input logic [2:0] bs,
    input logic [7:0] alpha,
    input logic [7:0] beta,
    input logic [4:0] tc0,
    input logic [0:3][7:0] pi,
    input logic [0:3][7:0] qi,
    output logic [0:3][7:0] po,
    output logic [0:3][7:0] qo
 );

    logic filterSamplesFlag;
    logic aq_lt_beta, ap_lt_beta, pq_lt_alpha, pq_lt_alpha_d4;
    logic [4:0]  tc;
    logic [2:0]  dummy1;
    logic [5:0]  delta_clip;
    logic [11:0] delta;
    logic [9:0]  p0pd, q0md;
    logic [7:0]  p0pd_clip, q0md_clip;
    logic [10:0] p1d, q1d;
    logic [5:0]  p1d_clip, q1d_clip;
    logic [7:0]  p1pd, q1pd;
    logic [7:0]  alpha_d4;
    logic [10:0] p0f, p1f, p2f, p0cf;
    logic [10:0] q0f, q1f, q2f, q0cf;

    always_comb begin
        // make filter decision based on thresholds    
        aq_lt_beta =   ( { 1'b0, qi[1] } - { 1'b0, qi[0] } < { 1'b0, beta  } || 
                         { 1'b0, qi[0] } - { 1'b0, qi[1] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;
        ap_lt_beta =   ( { 1'b0, pi[1] } - { 1'b0, pi[0] } < { 1'b0, beta  } || 
                         { 1'b0, pi[0] } - { 1'b0, pi[1] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;
        pq_lt_alpha =  ( { 1'b0, pi[0] } - { 1'b0, qi[0] } < { 1'b0, alpha } || 
                         { 1'b0, qi[0] } - { 1'b0, pi[0] } < { 1'b0, alpha } ) ? 1'b1 : 1'b0 ;
        alpha_d4      = alpha[7:2] + 2;
        pq_lt_alpha_d4 =  ( { 1'b0, pi[0] } - { 1'b0, qi[0] } < { 1'b0, alpha_d4 } || 
                          { 1'b0, qi[0] } - { 1'b0, pi[0] } < { 1'b0, alpha_d4 } ) ? 1'b1 : 1'b0 ;
     
        // Bs < 4 decision flag
        filterSamplesFlag = pq_lt_alpha & ap_lt_beta & aq_lt_beta;

        // Calculate p0, q0 for Bs < 4 
        tc = tc0 + (( ch_flag ) ? 5'd1 : ({ 4'b0, ap_lt_beta } + { 4'b0, aq_lt_beta }));
        delta[11:0] = ( { 2'b00  , qi[0], 2'b00 } - { 2'b00  , pi[0], 2'b00 } ) +
                      ( { 4'b0000, pi[1]        } - { 4'b0000, qi[1]        } ) + 12'd4;
        delta_clip[5:0] = ( !delta[11] && delta[11:3] >  { 4'b0000,  tc[4:0] } ) ? { 1'b0,  tc[4:0] } :
                          (  delta[11] && delta[11:3] <= { 4'b1111, ~tc[4:0] } ) ? { 1'b1, ~tc[4:0] } + 6'd1 : delta[8:3];
        p0pd[9:0] = { 2'b00, pi[0][7:0] } + { {4{delta_clip[5]}}, delta_clip[5:0] } ;
        q0md[9:0] = { 2'b00, qi[0][7:0] } - { {4{delta_clip[5]}}, delta_clip[5:0] } ;
        p0pd_clip[7:0] = ( p0pd[9] ) ? 8'h00 : ( p0pd[8] ) ? 8'hFF : p0pd[7:0];  
        q0md_clip[7:0] = ( q0md[9] ) ? 8'h00 : ( q0md[8] ) ? 8'hFF : q0md[7:0];  
        
        // Calculate p1, q1 for Luma Bs < 4 
        p1d[10:0] = { 2'b00, pi[2], 1'b1 } + { 3'b000, pi[0] } + { 3'b000, qi[0] } - { 1'b0, pi[1], 2'b00 };
        q1d[10:0] = { 2'b00, qi[2], 1'b1 } + { 3'b000, pi[0] } + { 3'b000, qi[0] } - { 1'b0, qi[1], 2'b00 };

        p1d_clip = ( !p1d[10] && p1d[10:1] >  {5'b00000,  tc0[4:0]} ) ? { 1'b0,  tc0[4:0] } :
                   (  p1d[10] && p1d[10:1] <= {5'b11111, ~tc0[4:0]} ) ? { 1'b1, ~tc0[4:0] } + 6'd1 : p1d[6:1];
        q1d_clip = ( !q1d[10] && q1d[10:1] >  {5'b00000,  tc0[4:0]} ) ? { 1'b0,  tc0[4:0] } :
                   (  q1d[10] && q1d[10:1] <= {5'b11111, ~tc0[4:0]} ) ? { 1'b1, ~tc0[4:0] } + 6'd1 : q1d[6:1];
        p1pd = pi[1] + p1d_clip;
        p1pd = qi[1] + q1d_clip;
        
        // Calculate functions for p0, p1, p2, q0, q1, q2
        
        p0f  = (pi[2] + {pi[1], 1'b0}) + ({pi[0],1'b0} + {qi[0],1'b0}) + (qi[1] + 4);
        p1f  = (pi[2] + pi[1]) + (pi[0] + qi[0]) + 2;
        p2f  = (({pi[3],1'b0} + {pi[2],1'b0}) + (pi[2] + pi[1])) + ((pi[0] + qi[0]) + 4);
        p0cf = ({pi[1],1'b0} + pi[0]) + (qi[1] + 2);      

        q0f  = (qi[2] + {qi[1], 1'b0}) + ({qi[0],1'b0} + {pi[0],1'b0}) + (pi[1] + 4);
        q1f  = (qi[2] + qi[1]) + (qi[0] + pi[0]) + 2;
        q2f  = (({qi[3],1'b0} + {qi[2],1'b0}) + (qi[2] + qi[1])) + ((qi[0] + pi[0]) + 4);
        q0cf = ({qi[1],1'b0} + qi[0]) + (pi[1] + 2);      
        
        // Output default and bS decision       
        po = pi;
        qo = qi;
        // Bs == 4
        if( filterSamplesFlag && bs[2:0] == 3'd4 ) begin
            if( ap_lt_beta && pq_lt_alpha_d4 && !ch_flag ) begin
                po[0] = p0f[10:3];
                po[1] = p1f[9:2];
                po[2] = p2f[10:3];
            end else begin
                po[0] = p0cf[9:2];
            end
            if( aq_lt_beta && pq_lt_alpha_d4 && !ch_flag ) begin
                qo[0] = q0f[10:3];
                qo[1] = q1f[9:2];
                qo[2] = q2f[10:3];
            end else begin
                qo[0] = q0cf[9:2]; 
            end       
        end

        // Bs 1-3 - Luma
        else if( filterSamplesFlag && bs[2:0] != 3'd0 ) begin
            po[0] = p0pd;
            qo[0] = q0md;
            if( ap_lt_beta && !ch_flag )
                po[1] = p1pd;
            if( aq_lt_beta && !ch_flag )
                qo[1] = q1pd;
        end
    end   
endmodule