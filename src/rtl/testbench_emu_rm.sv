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


module testbench_emu_rm(

    );
    
    //////////////////////
    // Let there be Clock!
    //////////////////////
    
    logic clk;
    logic reset;
    initial begin
        clk = 1'b1;
        forever begin
            #(5ns) clk = ~clk;
        end 
    end
    


    ///////////////////////
    // End of Time Default
    ///////////////////////
    
    initial begin
        #(60000ns);
        $write("GOBBLE: Sim terminated; hard coded time limit reached.\n");
        $finish;
    end
    
    
    
    //////////////////////
    // Device Under Test
    //////////////////////
    
    logic [127:0] iport;
    logic [127:0] oport;
    logic [15:0] oflag;
    logic valid;
    logic ovalid;
    
    gg_emulation_remove _dut
   (
        .clk ( clk ),  
        .reset ( reset ),
        .iport  ( iport ), // big endian byte stream
        .iport_ready( ),
        .iport_valid( valid ),
        .oport ( oport ),   // big endian byte tstream with emulation removed
        .flag   ( oflag ),    // flag bytes where 0x03 removed 
        .oport_ready( 1'b1 ),
        .oport_valid( ovalid )
    );
        
 ///////////////////////////////////////////
 //
 //              TESTs
 //
 ///////////////////////////////////////////        
    
    
         // testbench decl
         
    logic [0:23][127:0] ref_in;
    

    logic [0:23][127:0] emu_rm;
    logic [0:23][15:0] emu_flag;
    int ptr;
    int err;
    int in_ptr; // Rolling input buffer, so last val avail
    int ww, rr; // emulation output fifo (in bytes)
    int val;
    int pre;
    int bb;
    
    logic [0:2][7:0] byte_in;
    
    initial begin
        err = 0; // error count
       // Set initial data
        ref_in = {
        128'h00_01_02_03_04_05_06_07_08_09_0A_0b_0c_0d_0e_0f ,
        128'h10_11_12_13_14_15_16_17_18_19_1A_1b_1c_1d_1e_1f ,
        128'h20_21_22_23_24_25_26_27_28_29_2A_2b_2c_2d_2e_2f ,
        128'h00_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h01_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h02_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h03_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h04_00_00_00_00_03_00_00_00_00_00_00_00_00_00_00 ,
        128'h05_00_00_03_00_00_03_00_00_00_00_00_00_00_00_00 ,
        128'h06_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h07_00_00_03_00_00_03_00_00_03_00_00_00_00_00_00 ,
        128'h08_00_00_00_00_00_00_03_00_00_00_00_00_00_00_00 ,
        128'h09_00_00_00_00_00_00_00_03_00_00_00_00_00_00_00 ,
        128'h10_00_00_00_00_00_00_00_00_03_00_00_00_03_00_00 ,
        128'h11_00_00_00_00_00_00_00_00_00_00_00_00_00_03_00 ,
        128'h12_00_00_00_00_00_00_00_00_00_00_00_00_00_00_03 ,
        128'h13_03_00_00_00_00_00_00_00_00_00_03_00_00_00_00 ,
        128'h14_00_03_00_00_03_00_00_03_00_00_03_00_00_03_00 ,
        128'h15_00_00_03_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h16_00_00_03_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h17_03_00_00_03_00_00_03_00_00_00_00_00_00_00_00 ,
        128'h18_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h19_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h20_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 
        };
       
        
        // Idle state
        reset = 1;
        valid = 0;
        iport = 128'b0;

        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        ////////////////////////////////////////////////////
        // TEST 0 : 10 words of all zero
        ////////////////////////////////////////////////////

        valid = 1;
        iport = 128'h6;
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); #1;  // 10 cycles
        valid = 0;
        iport = 128'b0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 cycles
        
        ////////////////////////////////////////////////////
        // TEST 1 : 24 words of iport data, no check
        ////////////////////////////////////////////////////

        reset = 1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        valid = 1;
        for( int ii = 0; ii < 24; ii++ ) begin
            iport = ref_in[ii];
            @(posedge clk);
            #1; 
        end
        valid = 0;
        iport = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 cycles
         
        ////////////////////////////////////////////////////
        // TEST 2 : same as test 1 but with checking
        ////////////////////////////////////////////////////
        // Simultaneously feed input, and calculate output,
        // compare output when ovalid strobes asserted

        ptr = 0;
        emu_rm = 0;
        emu_flag = 0;
        for( int ii = 0; ii < 24*16-2; ii++ ) begin
            byte_in[0] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
            byte_in[1] = ref_in[(ii+1)>>4][127-((ii+1)%16)*8-:8];
            byte_in[2] = ref_in[(ii+2)>>4][127-((ii+2)%16)*8-:8];
            if( byte_in == 24'h00_00_03 ) begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_flag[ptr>>4][15-ptr%16] = 1'b1; // mark the protected byte (next)
            end else begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
            end
        end
        // Print orig words
        $write(" Original data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h\n", ref_in[ii] );
        end
        // Print emu removed words
        $write(" Emulation removed data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h,  %4h\n", emu_rm[ii], emu_flag[ii] );
        end
        
        // Reset to clean pipe
        reset = 1;
        valid = 0;
        iport = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        // 25 cycles, 24 with data in, and 1 to flush
        
        ptr = 0; // index into output list
        for( int ii = 0; ii < 26; ii++ ) begin
            if( ii < 24 ) begin
                valid = 1;
                iport = ref_in[ii];
            end else begin
                valid = 0;
                iport = 0;
            end
            @(posedge clk);
            #1;
            @(negedge clk); 
            if( ovalid ) begin
                if( emu_rm[ptr] != oport || emu_flag[ptr] != oflag ) begin
                    $write("ERR found in word %d\n", ptr );
                    $write("Expected = %32h, flag = %4h\n", emu_rm[ptr], emu_flag[ptr] );
                    $write("Actual   = %32h, flag = %4h\n", oport, oflag );
                    err++;
                end 
                ptr++;
            end
        end
                
        ////////////////////////////////////////////////////
       // TEST 3 - Random data
        ////////////////////////////////////////////////////

        ref_in = {
        128'h00_00_00_00_03_00_00_00_00_03_00_00_00_00_00_00,
        128'h03_03_00_00_00_00_00_00_03_00_03_00_00_00_00_00,
        128'h00_03_03_00_00_03_03_00_03_00_00_00_03_03_00_00,
        128'h00_03_00_00_03_00_03_03_03_03_00_00_00_00_00_00,
        128'h00_00_00_03_00_00_00_03_00_03_00_00_00_03_00_03,
        128'h00_00_00_00_00_00_00_03_00_03_00_00_03_00_03_03,
        128'h00_00_00_00_00_03_00_00_03_00_00_00_00_00_00_00,
        128'h00_00_03_00_03_00_00_00_03_03_00_00_00_00_00_00,
        128'h03_00_00_00_00_00_00_03_00_00_03_00_00_00_00_00,
        128'h00_00_00_03_00_00_00_00_00_03_00_00_00_03_00_00,
        128'h00_00_00_00_03_00_00_00_03_00_00_00_00_00_03_00,
        128'h00_00_00_00_03_00_00_00_00_00_00_00_00_00_03_00,
        128'h03_00_00_03_03_03_03_00_00_03_00_00_00_00_00_00,
        128'h00_00_00_00_03_03_00_00_00_03_00_03_03_00_00_00,
        128'h00_00_03_00_00_00_00_00_00_03_00_00_03_00_00_00,
        128'h00_00_00_00_00_03_00_00_00_00_00_00_03_00_00_00,
        128'h00_00_00_00_00_00_00_00_00_00_00_00_03_00_00_00,
        128'h00_00_00_00_00_00_03_00_00_00_00_00_00_00_03_00,
        128'h00_00_00_03_03_00_00_00_00_03_00_03_00_00_03_00,
        128'h00_00_00_00_00_03_00_00_03_00_00_00_03_03_00_00,
        128'h00_03_00_00_00_00_00_00_00_03_00_00_00_00_00_00,
        128'h03_00_03_00_03_00_00_03_00_03_00_00_00_00_00_00,
        128'h19_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 ,
        128'h20_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00 
        };

        ptr = 0;
        emu_rm = 0;
        emu_flag = 0;
        for( int ii = 0; ii < 24*16-2; ii++ ) begin
            byte_in[0] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
            byte_in[1] = ref_in[(ii+1)>>4][127-((ii+1)%16)*8-:8];
            byte_in[2] = ref_in[(ii+2)>>4][127-((ii+2)%16)*8-:8];
            if( byte_in == 24'h00_00_03 ) begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_flag[ptr>>4][15-ptr%16] = 1'b1; // mark the protected byte (next)
           end else begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
            end
        end
        // Print orig words
        $write(" Original data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h\n", ref_in[ii] );
        end
        // Print emu removed words
        $write(" Emulation removed data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h,  %4h\n", emu_rm[ii], emu_flag[ii] );
        end
        
        // Reset to clean pipe
        reset = 1;
        valid = 0;
        iport = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        // 25 cycles, 24 with data in, and 1 to flush
        

        ptr = 0; // index into output list
        for( int ii = 0; ii < 26; ii++ ) begin
            if( ii < 24 ) begin
                valid = 1;
                iport = ref_in[ii];
            end else begin
                valid = 0;
                iport = 0;
            end
            @(posedge clk);
            #1;
            @(negedge clk); 
            if( ovalid ) begin
                if( emu_rm[ptr] != oport || emu_flag[ptr] != oflag ) begin
                    $write("ERR found in word %d\n", ptr );
                    $write("Expected = %32h, flag = %4h\n", emu_rm[ptr], emu_flag[ptr] );
                    $write("Actual   = %32h, flag = %4h\n", oport, oflag );
                    err++;
                end 
                ptr++;
            end
        end
        
        ////////////////////////////////////////////////////
       // TEST 4 - 5 runs of randomized data
        ////////////////////////////////////////////////////

        ptr = $random( 32'hdeadbeef ); // seed

        for( int round = 0; round < 6; round++ ) begin
        $write("random round %d\n", round );
        ref_in = 0;
        for( int ww = 0; ww < 22; ww++ ) begin
            for( int ii = 0; ii < 128; ii+=8 ) begin
                ptr = $random();
                //$write("%8h ", ptr );
                ref_in[ww][ii+7-:8] = ( ptr < 0 ) ? 8'h00 :
                                      ( ptr & (1<<30) ) ? 8'h03 : (ptr & 8'hff);
            end
        end;
                                       
        
        ptr = 0;
        emu_rm = 0;
        emu_flag = 0;
        for( int ii = 0; ii < 24*16-2; ii++ ) begin
            byte_in[0] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
            byte_in[1] = ref_in[(ii+1)>>4][127-((ii+1)%16)*8-:8];
            byte_in[2] = ref_in[(ii+2)>>4][127-((ii+2)%16)*8-:8];
            if( byte_in == 24'h00_00_03 ) begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
                ii++;
                emu_flag[ptr>>4][15-ptr%16] = 1'b1; // mark the protected byte (next)
           end else begin
                emu_rm[ptr>>4][127-((ptr%16)*8)-:8] = ref_in[(ii+0)>>4][127-((ii+0)%16)*8-:8];
                ptr++;
            end
        end
        // Print orig words
        $write(" Original data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h\n", ref_in[ii] );
        end
        // Print emu removed words
        $write(" Emulation removed data\n");
        for( int ii = 0; ii < 24; ii++ ) begin       
            $write("%32h,  %4h\n", emu_rm[ii], emu_flag[ii] );
        end
        
        // Reset to clean pipe
        reset = 1;
        valid = 0;
        iport = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        // 25 cycles, 24 with data in, and 1 to flush
        

        ptr = 0; // index into output list
        for( int ii = 0; ii < 26; ii++ ) begin
            if( ii < 24 ) begin
                valid = 1;
                iport = ref_in[ii];
            end else begin
                valid = 0;
                iport = 0;
            end
            @(posedge clk);
            #1;
            @(negedge clk); 
            if( ovalid ) begin
                if( emu_rm[ptr] != oport || emu_flag[ptr] != oflag ) begin
                    $write("ERR found in word %d\n", ptr );
                    $write("Expected = %32h, flag = %4h\n", emu_rm[ptr], emu_flag[ptr] );
                    $write("Actual   = %32h, flag = %4h\n", oport, oflag );
                    err++;
                end 
                ptr++;
            end
        end
        
        end //round

        //////////////////////////////////////////////////////
       // TEST 5 - infinite length, random data, random valid
        //////////////////////////////////////////////////////
        
        // Setup
        ref_in = ~0;
        emu_rm = 0;
        emu_flag = 0;
        ww = 126;
        rr = 0;
        ptr = 0;
        valid = 0;
        iport = 0;
        pre = -2;
        
        // Reset to clean pipe
        reset = 1;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles
        
        // Operate on -ve edge, far away from +ve edge
        
        for( int cycle = 0; cycle < 5000; cycle++ ) begin
        
            // rand determine if valid cycle
            valid = $urandom() % 2;
            iport = 0;
            
            
            if( valid ) begin // random iport data
            
                // generate random word as input (use rolling buffer) 
                for( int bb = 0; bb < 16; bb++ ) begin
                    val = $random();
                    ref_in[ptr][127-bb*8-:8] = ( val < 0 ) ? 8'h00 :
                                               ( val & (1<<30) ) ? 8'h03 : (val & 8'hff); 
                end
                   
                // assign iport, ovalid
                iport = ref_in[ptr];
                $write("[%d] iport = %32h\n", cycle, iport );
                
                // calc emulation and write to fifo ww++ (will read from prev in port word) (ww is bytes)
                for( bb = pre; bb < 14; bb++ ) begin // step thru 16 bytes
                    byte_in[0] = ref_in[((((ptr+8)<<4)+(bb+0))>>4)%8][127-(((bb+0)+16)%16)*8-:8];
                    byte_in[1] = ref_in[((((ptr+8)<<4)+(bb+1))>>4)%8][127-(((bb+1)+16)%16)*8-:8];
                    byte_in[2] = ref_in[((((ptr+8)<<4)+(bb+2))>>4)%8][127-(((bb+2)+16)%16)*8-:8];
                    if( byte_in == 24'h00_00_03 ) begin
                        emu_rm[ww>>4][127-((ww%16)*8)-:8] = 0;
                        ww = (ww + 1)%128;
                        emu_flag[ww>>4][15-(ww%16)] = 1'b0; 
                       
                        emu_rm[ww>>4][127-((ww%16)*8)-:8] = 0;
                        ww = (ww + 1)%128;
                        emu_flag[ww>>4][15-(ww%16)] = 1'b1; // mark the protected byte (next)
                        
                        bb+=2; // since we processed 3 bytes
                        
                    end else begin
                        emu_rm[ww>>4][127-((ww%16)*8)-:8] = ref_in[((((ptr+8)<<4)+(bb+0))>>4)%8][127-(((bb+0)+16)%16)*8-:8];
                        ww = (ww + 1)%128;
                        emu_flag[ww>>4][15-(ww%16)] = 1'b0; 
                    end
                end // bb  
                pre = bb - 16; // in case we've processed last 1 or 2 already     
               
                ptr = ( ptr + 1 ) % 8; // just keep around 8 rows of input 
            end // valid

            // check ovalid
            // if so, compare against emulation buffer and flags, rr++
            if( ovalid ) begin
                $write("[%d] oport = %32h, oflag = %4h\n", cycle, oport, oflag );
                if( emu_rm[rr] != oport || emu_flag[rr] != oflag ) begin
                    $write("ERR found in cycle %d\n", cycle );
                    $write("Expected = %32h, flag = %4h\n", emu_rm[rr], emu_flag[rr] );
                    $write("Actual   = %32h, flag = %4h\n", oport, oflag );
                    err++;
                    //$finish;
                end 
                rr = ( rr + 1 ) % 8;
            end            
            // rise/fall of clock
     
            @(posedge clk);            
            #1;
        end // cycle
        valid = 0;
        iport = 0;


        //////////////////////////////////////////////////////
        // End Simulation & summary
        //////////////////////////////////////////////////////        

        valid = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; 

        if( err ) begin
            $write("FAILED %d errors found\n", err );
        end else begin
            $write("PASSED\n" );
        end
        $finish;
    end

    

endmodule
