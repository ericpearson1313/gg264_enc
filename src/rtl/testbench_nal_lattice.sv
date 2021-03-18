`timescale 1ns / 1ps


module testbench_nal_lattice(

    );
    
    //parameter WID = 128;
    parameter WID = 128;
    parameter BYTE_WID = WID / 8;
    parameter FILE_SKIP_BYTES = 2640; // advance to 2nd frame: 2000000121f76039fef4bd8d880e1c07

    
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
    logic [WID-1:0] left_oop;
    logic [WID-1:0] left_skip;
    logic [BYTE_WID-1:0] slice_start; // byte aligned input trigger 
    logic [BYTE_WID-1:0] slice_end; // byte aligned completion      
    logic [BYTE_WID-1:0] nal_start; // byte aligned input trigger 
    logic [BYTE_WID-1:0] nal_end; // byte aligned completion      
    logic [WID-1:0] bend; // a single 1-hot bit indicating block end
    logic [WID-1:0][5:0] nc_idx; // coeff_token table index, {0-3} luma, {4} chroma DC
    logic [31:0] pad;

    gg_parse_nal_lattice #( WID ) _nal_lattice_dut
    (
        // System
        .clk( clk ),
        .reset ( reset ),
        // Bits
        .in_bits( bits ),
        .in_pad( pad ),
        // Control
        .nal_start ( nal_start | nal_end ),
        .nal_end( nal_end ),
        // Slice lattice interface
        .slice_start( slice_start ), 
        .slice_end( slice_end )
    );

    gg_parse_lattice_rowslice #( WID ) _slice_lattice_dut
    (
        // System
        .clk( clk ),
        .reset ( reset ),
        // Bits
        .in_bits( bits ),
        .in_pad( pad ),
        // Input slice trigger
        .slice_start( slice_start ), 
        .slice_end( slice_end ),
        // macroblock lattice interface
        .mb_above_oop( ),
        .mb_left_oop( left_oop ),
        .mb_left_skip( left_skip ),
        .mb_start( mb_start ), 
        .mb_end( mb_end )
    );
    
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
        .left_skip( left_skip ),
        .left_oop( left_oop ),  
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


    parameter TEST_WID = 5 * 128;
    logic [TEST_WID-1:0] vlc_mb_vec;
    int fd;
    int rbsp_byte;
    int tc;
            
    assign vlc_mb_vec = { 
        128'h_00_00_00_01_27_42_e0_2a_f7_16_26_20_00_00_00_00, // sps
        128'h_00_00_00_01_28_ca_8f_20_00_00_00_00_00_00_00_00, // pps
        128'h_00_00_01_0a_00_00_00_00_00_00_00_01_21_e4_40_df, // eos, slice header (includes mbyte = 0 = 1'b1 ue(v)
    // Macroblock 122 bits in length, 6 trailing padding bits (with stop bit)
    // 128'b_1_0_1_1_000010100_1_001_11_011_001_10_0_1_10_1_011_000101_1_1_01_0_1_01_0_1_000101_1_1_000101_1_1_01_1_011_000101_1_1_01_1_011_01_0_1_000101_1_1_000101_1_1_1_01_0_1_01_001_11_01_0_000000;
        128'b_0_1_1_000010100_1_001_11_011_001_10_0_1_10_1_011_000101_1_1_01_0_1_01_0_1_000101_1_1_000101_1_1_01_1_011_000101_1_1_01_1_011_01_0_1_000101_1_1_000101_1_1_1_01_0_1_01_001_11_01_0_1000000,
        128'h_00_00_01_0a_00_00_00_00_00_00_00_00_00_00_00_00 // end of stream nal
    };

    initial begin   
        // Reset (asserted for combinatorial operation)
        reset = 1;
        // Clear inputs
        bits = 0;
        pad  = 0;
        nal_start = 0;
                
        // startup delay (for future reset)
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); // 10 cycles

        // TEST #1 : Coded Macroblock
        reset = 0;
        for( int tc = 0; tc < TEST_WID; tc += WID ) begin  // step through all input data
            for( int pos = 0; pos < WID; pos++ ) begin // bits
                bits[WID-1-pos] = ( tc+pos >= TEST_WID ) ? 1'b0 : vlc_mb_vec[TEST_WID-1-tc-pos];
            end
            for( int pos = 0; pos < 32; pos++ ) begin // padding
                pad[31-pos] = ( tc+WID+pos >= TEST_WID ) ? 1'b0 : vlc_mb_vec[TEST_WID-1-tc-WID-pos];
            end
            nal_start[BYTE_WID-1] = ( tc == 0 ) ? 1'b1 : 1'b0;
            @(posedge clk);
        end
        bits = 0;
        pad = 0;
        nal_start = 0;
        reset = 1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
        

        $write("*****************************************************************\n");
        $write("** \n");
        $write("** F I L E       V E C T O R      T E S T\n");
        $write("** \n");
        $write("*****************************************************************\n");
        $write("\n");
        
        // foreman_qcif_rowslice.264 is 14KB, QCIF 2I+20P frame low quality (qp40) H.264 bitstream
        // It is intended for a low-est latency and employs column refresh P frames, and row slices.
        fd = $fopen( "C:/Users/ecp/Documents/gg264_enc/src/test/foreman_qcif_rowslice.264", "rb"); // verified no emulation bytes 0x03
        
        // skip bytes at beginning of file for debug
        for( int ii = 0; ii < FILE_SKIP_BYTES; ii++ ) begin
            $fgetc(fd);
        end
        
        bits = 0;
        pad = 0;
        nal_start = 0;
        reset = 1;
        tc = 0;


        // Prefil padding
        for( int ii = 0; ii < 4; ii++ ) begin
            pad[31-ii*8-:8] = ( ( rbsp_byte = $fgetc( fd ) ) < 0 ) ? 8'h00 : rbsp_byte ; 
        end
        
        // Loop Until read past the end of the file
        while( !$feof( fd ) ) begin  
            // Move padding to top of bit buffer
            bits[WID-1-:32] = pad;
            // Fill WID-32 of bits
            for( int ii = 4; ii < BYTE_WID; ii++ ) begin
                bits[WID-1-ii*8-:8] = ( ( rbsp_byte = $fgetc( fd ) ) < 0 ) ? 8'h00 : rbsp_byte ;
            end // ii
            // Fill Padding
            for( int ii = 0; ii < 4; ii++ ) begin
                pad[31-ii*8-:8] = ( ( rbsp_byte = $fgetc( fd ) ) < 0 ) ? 8'h00 : rbsp_byte ; 
            end
            nal_start[BYTE_WID-1] = ( tc++ == 0 ) ? 1'b1 : 1'b0;
            reset = 0;
            @(posedge clk);
        end // feof()
        bits = 0;
        pad = 0;
        nal_start = 0;
        reset = 1;
        // End delay for waveforms
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
        $finish;
    end
endmodule
