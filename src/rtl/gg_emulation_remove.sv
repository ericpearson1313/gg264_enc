`timescale 1ns / 1ps
//
// MIT License
// 
// Copyright (c) 2021 Eric Pearson
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


// I/O: AXI-S RBSP (bitstream) in parallel words
// Function: remove emulation prevention 0x03's from input stream
// Additional flag on output bytes to flag removals (and prevent start code detection downstream)
// It will maintain word per cycle throughput with 0 or 1 emulations per word, 
// In the case of N emulations per word will take N-1 additional cycles
module gg_emulation_remove
   #(
     parameter int WIDTH             = 128,      
	 parameter int BYTE_WIDTH		 = WIDTH / 8
    )
    (
    input  logic clk,
    input  logic reset,
    input  logic [127:0]     iport, // big endian byte stream
    output logic             iport_ready,
    input  logic             iport_valid,
    output logic [127:0]     oport,   // big endian byte tstream with emulation removed
    output logic [15:0]      flag,    // flag bytes where 0x03 removed 
    input  logic             oport_ready,
    output logic             oport_valid
    );

    // Input Data register
    logic [47:0][7:0] in_reg;
    logic [31:0]      emu_reg;  // Flag all 0x03 emu bytes
    logic [47:0]      emu_flag;  // Flag all 0x03 emu bytes
    
    // Always ready for input data
    assign iport_ready = 1'b1;
        
    // Input Register
    always_ff @(posedge clk) begin // Lower 32 set of states are flopped  
        if( reset ) begin
            in_reg <= ~0;
            emu_reg <= 0;
        end else if( iport_valid ) begin
            in_reg[31:0] <=  in_reg[47:16]; // Shift in reg down by 16 bytes
            for( int ii = 0; ii < 16; ii++ ) begin
                in_reg[47-ii][7:0] <= iport[8*ii+7-:8];  // note: endian swap occurs here
            end
            emu_reg <= { emu_flag[47:32], emu_reg[31:16] };
        end
    end // ff

    // Calc emu bits 
    always_comb begin
        emu_flag = 0;
        for( int ii = 0; ii < 48; ii++ ) begin
            emu_flag[ii] = ( ii < 32 ) ? emu_reg[ii] : ( in_reg[ii]==8'h03 && in_reg[ii-1]==8'h00 && in_reg[ii-2]==8'h00 ) ? 1'b1 : 1'b0; 
        end
    end

    // Position Register
    // Maintain current bytepos, -16 if input is shifted, and +width(16 to 25) when valid.
    // Output is valid when bytepos is in the range 0-15
    
    logic [5:0] cur_pos; // can range from 0 to 40
    logic valid_q; // delayed valid
    logic [5:0] emu_length;
    always_ff @(posedge clk) begin   
        if( reset ) begin
            cur_pos <= 6'd32;
            valid_q <= 0;
        end else begin
            valid_q <= iport_valid;
            if( valid_q ) begin
                if( cur_pos > 15 ) begin
                    cur_pos <= cur_pos - 16;
                end else begin
                    cur_pos <= cur_pos - 16 + emu_length;
                end
            end
        end
    end // ff
   
    // Barrel shift of 39 emu bits by offset cur_pos, will only use 24 bits
    logic  [0:4][38:0] emu_shift;
    logic [23:0] emu; // shifted emu bits
	always_comb begin : _barrel_shift_emu
		for( int ii = 38; ii >= 0; ii-- ) begin
			emu_shift[ 0][ii] = emu_flag[ii]; 
			emu_shift[ 1][ii] = ( cur_pos[3] ) ? ( ( ii < 39 - 8  ) ? emu_shift[0][ii+8] : 1'b0 ) : ( ( ii < 39 - 8  ) ? emu_shift[0][ii] : 1'b0 );
			emu_shift[ 2][ii] = ( cur_pos[2] ) ? ( ( ii < 39 - 12 ) ? emu_shift[1][ii+4] : 1'b0 ) : ( ( ii < 39 - 12 ) ? emu_shift[1][ii] : 1'b0 );
			emu_shift[ 3][ii] = ( cur_pos[1] ) ? ( ( ii < 39 - 14 ) ? emu_shift[2][ii+2] : 1'b0 ) : ( ( ii < 39 - 14 ) ? emu_shift[2][ii] : 1'b0 );
			emu_shift[ 4][ii] = ( cur_pos[0] ) ? ( ( ii < 39 - 15 ) ? emu_shift[3][ii+1] : 1'b0 ) : ( ( ii < 39 - 15 ) ? emu_shift[3][ii] : 1'b0 );
		end
		emu = emu_shift[4][23:0];
	end    

    
    // Tree adders for lengths of 16 byte word (ranges 16 to 24)
    // this offset will be fed back to cur_pos register
    logic [0:7][3:0] emu_sum, u_emu_sum, l_emu_sum;
    logic [0:7][7:0] emu_reduce;
    logic [0:7][23:0] emu_mask;
    
    always_comb begin : _emu_length
        for( int ii = 0; ii < 8; ii++ ) begin
            for( int bb = 0; bb < 24; bb++ ) begin // mask emu bits for length of 16 ... 23
                emu_mask[ii][bb] = ( bb >= 16 + ii ) ? 1'b0 : emu[bb];
            end
            for( int jj = 0; jj < 8; jj++ ) begin // create reduced x3 emu flags
                emu_reduce[ii][jj] = emu_mask[ii][jj*3+0] | emu_mask[ii][jj*3+1] | emu_mask[ii][jj*3+2]; // only 1 in 3 emu bits can be asserted!
            end
            u_emu_sum[ii] = { 3'b000, emu_reduce[ii][4] } + { 3'b000, emu_reduce[ii][5] } + { 3'b000, emu_reduce[ii][6] } + { 3'b000, emu_reduce[ii][7] };
            l_emu_sum[ii] = { 3'b000, emu_reduce[ii][0] } + { 3'b000, emu_reduce[ii][1] } + { 3'b000, emu_reduce[ii][2] } + { 3'b000, emu_reduce[ii][3] };
            emu_sum[ii] = l_emu_sum[ii] + u_emu_sum[ii];
        end
        emu_length = ( emu_sum[0] == 4'd0 ) ? 6'd16 :
                     ( emu_sum[1] == 4'd1 ) ? 6'd17 :
                     ( emu_sum[2] == 4'd2 ) ? 6'd18 :
                     ( emu_sum[3] == 4'd3 ) ? 6'd19 :
                     ( emu_sum[4] == 4'd4 ) ? 6'd20 :
                     ( emu_sum[5] == 4'd5 ) ? 6'd21 :
                     ( emu_sum[6] == 4'd6 ) ? 6'd22 :
                     ( emu_sum[7] == 4'd7 ) ? 6'd23 : 6'd24;
    end
 
    // Barrel shift 39 bytes of data by cur_pos, with 24 bytes of output
    logic  [0:4][38:0][7:0] data_shift;
    logic  [23:0][7:0] data;
	always_comb begin : _barrel_shift_data
		for( int ii = 38; ii >= 0; ii-- ) begin
			data_shift[ 0][ii] = in_reg[ii]; 
			data_shift[ 1][ii] = ( cur_pos[3] ) ? ( ( ii < 39 - 8  ) ? data_shift[0][ii+8] : 8'b0 ) : ( ( ii < 39 - 8  ) ? data_shift[0][ii] : 8'b0 );
			data_shift[ 2][ii] = ( cur_pos[2] ) ? ( ( ii < 39 - 12 ) ? data_shift[1][ii+4] : 8'b0 ) : ( ( ii < 39 - 12 ) ? data_shift[1][ii] : 8'b0 );
			data_shift[ 3][ii] = ( cur_pos[1] ) ? ( ( ii < 39 - 14 ) ? data_shift[2][ii+2] : 8'b0 ) : ( ( ii < 39 - 14 ) ? data_shift[2][ii] : 8'b0 );
			data_shift[ 4][ii] = ( cur_pos[0] ) ? ( ( ii < 39 - 15 ) ? data_shift[3][ii+1] : 8'b0 ) : ( ( ii < 39 - 15 ) ? data_shift[3][ii] : 8'b0 );
		end
		data = data_shift[4][23:0];
	end    
    
    // 8 stages of emulation removal 
    logic [0:8][24:0][8:0] remove_shift; // MSB is emu bit
    logic [0:7][2:0] emu_or;
    int pos;
    
    always_comb begin : _emu_remove
        // wire up 24 input, with both data and emu
            remove_shift = 0;
        for( int bb = 0; bb < 24; bb++ ) begin
            remove_shift[0][bb] = { 1'b0, data[bb] };
        end
        
        // emu removal array
        for( int ii = 0; ii < 8; ii++ ) begin

            pos = 21 - ii*3;
            emu_or[ii][0] = emu[pos];
            emu_or[ii][1] = emu[pos] | emu[pos+1];
            emu_or[ii][2] = emu[pos] | emu[pos+1] | emu[pos+2] ;
            for( int bb = 0; bb < 24; bb++ ) begin
                if( bb < pos ) begin
                    remove_shift[ii+1][bb] = remove_shift[ii][bb];
                end else if( bb > pos+2 ) begin
                    remove_shift[ii+1][bb] = ( emu_or[ii][2] ) ? remove_shift[ii][bb+1] : remove_shift[ii][bb];
                end else begin
                    remove_shift[ii+1][bb][7:0] = ( emu_or[ii][bb-pos] ) ? remove_shift[ii][bb+1][7:0] : remove_shift[ii][bb][7:0];
                    remove_shift[ii+1][bb][8]   = ( emu_or[ii][bb-pos] ) ? emu[bb] /* flag prot byte*/ : remove_shift[ii][bb][8];
                end
            end
        end
        // wire up 16 output, demux flag and data
        for( int bb = 0; bb < 16; bb++ ) begin
            { flag[bb], oport[bb*8+7-:8] } = remove_shift[8][15-bb];
        end
    end
    // Output
    assign oport_valid = valid_q & ((cur_pos < 16) ? 1'b1 : 1'b0 );
endmodule