`timescale 1ns / 1ps


module testbench_mb_lattice(

    );
    
    //parameter WID = 128;
    parameter WID = 32;
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
    
    ////////////////////
    //
    //   D  U  T
    //
    ///////////////////
    
    logic reset; // clear flops, leave asserted for async operation    
    logic [WID-1:0] bits; // bitstream, bit endian packed
    logic [WID-1:0] mb_start; // a single 1-hot bit indicating block end
    logic [WID-1:0] mb_end; // a single 1-hot bit indicating block end
    logic [WID-1:0] bend; // a single 1-hot bit indicating block end
    logic [WID-1:0][5:0] nc_idx; // coeff_token table index, {0-3} luma, {4} chroma DC
    logic [31:0] pad;
    
    gg_parse_lattice_macroblock #( WID ) _mb_lattice_dut
    (
        // System
        .clk( clk ),
        .reset ( reset ),
        // Bits
        .in_bits( bits ),
        .in_pad( pad ),
        // Input mb_start trigger
        .mb_start( mb_start ), 
        .mb_end( mb_end ),
        // MB neighborhood info
        .left_oop( 1'b1 ),  
        .above_oop( 1'b1 ),
        .nc_left( 40'b0 ),
        .nc_above( 40'b0 ),
        .nc_right( ), 
        .nc_below( ),
        // transform block lattice interface
        .blk_end    ( bend ),
        .blk_nc_idx ( nc_idx )
    
    );
    
    gg_parse_lattice #( WID ) _lattice_dut
    (
        .clk( clk ),
        .reset ( reset ),
        .in_bits( bits ),
        .in_pad( pad ),
        .end_bits( bend ),
        .nc_idx ( nc_idx )
    );


    logic [127:0] vlc_mb_vec;
    
    assign vlc_mb_vec = 
     128'b_1_0_1_1_000010100_1_001_11_011_001_10_0_1_10_1_011_000101_1_1_01_0_1_01_0_1_000101_1_1_000101_1_1_01_1_011_000101_1_1_01_1_011_01_0_1_000101_1_1_000101_1_1_1_01_0_1_01_001_11_01_0_000000;

   initial begin
    
        // Reset (asserted for combinatorial operation)
        reset = 1;
        // Clear inputs
        bits = 0;
       pad = 0;
        mb_start = 0;
                
        // startup delay (for future reset)
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); // 10 cycles

        // TEST #1 : Coded Macroblock
        reset = 0;
        for( int bc = 0; bc < 128; bc += WID ) begin        
            for( int pos = 0; pos < WID; pos++ ) begin
                bits[WID-1-pos] = vlc_mb_vec[127-(bc)-pos];
            end
            for( int pos = 0; pos < 32; pos++ ) begin
                pad[31-pos] = ( bc+WID+pos < 128 ) ? vlc_mb_vec[127-bc-WID-pos] : 1'b0;
            end
            mb_start[WID-1] = ( bc == 0 ) ? 1'b1 : 1'b0;
            @(posedge clk);
        end
        bits = 0;
        pad = 0;
        mb_start = 0;
        reset = 1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

        // TEST #2 : PCM macroblock
        reset = 0;
        for( int wc = 0; wc < ((3072 / WID) + 1); wc++ ) begin
            mb_start[WID-1] = ( wc == 0 ) ? 1'b1 : 1'b0;
            bits[(WID-1)-:9] = ( wc == 0 ) ? 9'b00001111 : 9'b0;
            @(posedge clk);
        end 
        bits = 0;
        pad = 0;
        mb_start = 0;
        reset = 1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

 
 
        // End delay for waveforms
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);

        $finish;
    end
        
    
endmodule
