`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01/15/2021 09:02:58 AM
// Design Name: 
// Module Name: testbench_lattice
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module testbench_lattice(

    );
    
    //////////////////////
    // Let there be Clock!
    //////////////////////
    
    logic clk;
    initial begin
        clk = 1'b1;
        forever begin
            #(5ns) clk = ~clk;
        end 
    end
    
    logic reset;
    initial begin
        reset = 1'b1;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        reset = 1'b0;
    end

    ////////////////////
    //
    //   D  U  T
    //
    ///////////////////
    
    
    logic [47:0] bits; // bitstream, bit endian packed
    logic [47:0] bend; // a single 1-hot bit indicating block end
    logic [4:0] nc_idx; // coeff_token table index, {0-3} luma, {4} chroma DC
    logic ac_flag; // Set to indicate an AC block (for chroma) with max 15 coeffs

    gg_parse_lattice #( 48 ) _lattice_dut
    (
        .clk( clk ),
        .reset ( reset ),
        .in_bits( bits ),
        .end_bits( bend ),
        .nc_idx ( nc_idx ),
        .ac_flag ( ac_flag )
    );

    logic [0:25][6+9+64-1:0] vlc_mb_vec;
    logic [9:0] len;
    
    assign vlc_mb_vec = {
         { 6'b000001, 9'd30, 64'b00000111_0000000001_00000101_110_0  },
         { 6'b000010, 9'd28, 64'b000111_0000000001_00000101_110_0 },
         { 6'b000010, 9'd32, 64'b001000_000_1_011_0000000000011_000001  },
         { 6'b000100, 9'd24, 64'b01000_1_1_011_010_0000011_0101  },
         { 6'b000010, 9'd43, 64'b0000111_01_10_0000000000000001000000000001_0101  },
         { 6'b000010, 9'd36, 64'b00000111_00001_101_000111_0001001_0101_1_00  },
         { 6'b000100, 9'd28, 64'b01111_1_0000000000000010101_111  },
         { 6'b000010, 9'd29, 64'b000101_00_01_00000000011_110_001_1_0  },
         { 6'b000100, 9'd37, 64'b001010_0_001_11_11_011_00011_000000101_00001_0  },
         { 6'b000100, 9'd28, 64'b0001011_01_011_010_00010_110_0100_0  },
         { 6'b000100, 9'd42, 64'b001000_1_11_0000000000000001000000000111_101_00  },
         { 6'b000100, 9'd23, 64'b01011_11_0001_0011_0101_01_1_0  },
         { 6'b000100, 9'd31, 64'b01111_0_0000000000000010111_011_000  },
         { 6'b000010, 9'd33, 64'b001001_00_0000000000000010001_110_01_0  },
         { 6'b000010, 9'd21, 64'b000111_01_000000011_110_0  },
         { 6'b000010, 9'd43, 64'b00000110_0_01_0010_00000000011_000111_1110_111_01_1_0  },
         { 6'b010000, 9'd9,  64'b001_00_00_00  },
         { 6'b010000, 9'd3,  64'b1_0_1  },
         { 6'b100001, 9'd6,  64'b01_0_011  },
         { 6'b100001, 9'd1,  64'b1  },
         { 6'b100001, 9'd7,  64'b01_1_0010  },
         { 6'b100001, 9'd4,  64'b01_1_1  },
         { 6'b100001, 9'd1,  64'b1  },
         { 6'b100001, 9'd1,  64'b1  },
         { 6'b100001, 9'd1,  64'b1  },
         { 6'b100001, 9'd1,  64'b1  }
        };  






    initial begin
    
        // Clear inputs
        bits = 0;
        nc_idx = 0;
        ac_flag = 0;
        
        // startup delay (for future reset)
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); // 10 cycles

        // Test case
        bits = { 30'b00000111_0000000001_00000101_110_0, 2'b00, 16'b0 };
        nc_idx[0] = 1'b1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

        bits = 0;
        nc_idx = 0;
        ac_flag = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

        // Full MB of blocks
        for( int blk = 0; blk < 26; blk++ ) begin
            bits = 0;
            len = vlc_mb_vec[blk][72:64];
            for( int ii = 0; ii < len; ii++ ) begin
                bits[47-ii] = vlc_mb_vec[blk][len-1-ii];
            end
            { ac_flag, nc_idx } =  vlc_mb_vec[blk][78:73];  
            @(negedge clk);
            if( len > 47 ) 
                $write("TEST ERROR: length [%0d] too long %0d\n", blk, len );
            else if( bend[47-len] != 1'b1 )
                $write("ERROR: lattice mismatch blk[%0d], expected %d, Bend bits %0h\n", blk, len, bend );
            @(posedge clk);
        end // blk            
        // End delay for waveforms
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

        $finish;
    end
        
    
endmodule
