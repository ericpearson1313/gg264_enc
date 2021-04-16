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
        #(2000ns);
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
    
    assign ref_in = {
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


    initial begin
        
        // Idle state
        reset = 1;
        valid = 0;
        iport = 128'b0;

        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 reset cycles
        reset = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 !reset cycles

        // TEST 0 : 10 words of all zero
        valid = 1;
        iport = 128'h6;
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); #1;  // 10 cycles
        valid = 0;
        iport = 128'b0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; // 5 cycles
        
        // TEST 1 : 24 words of iport data, no check
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
         
        // End Simulation        
        valid = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk); #1; 
        $finish;
    end

    

endmodule
