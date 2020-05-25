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

// DMA Macroblock read, and DC calc
// AXI-L-32bit Slave port - register read/write
// AXI4 128-bit Master Read port - 128-bit video 4x4 pel blocks, in encode order, 24 transfers/macroblock
// AXI Master Stream port - 128 bit video, 4x4 pel blocks, in encode order with added chroma DC blocks,  26 transfers/macroblock

module gg_dma_wr2d
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
    input  logic reset,
    // 32-bit Axi-L register port
    // AR
    input  logic         s_arvalid ,
    output logic         s_arready ,
    input  logic [7:0]   s_araddr  ,
    // R
    output logic         s_rvalid  ,
    input  logic         s_rready  ,
    output logic [31:0]  s_rdata   ,
    output logic  [1:0]  s_rresp    ,
    // AW
    input  logic         s_awvalid ,
    output logic         s_awready ,
    input  logic [7:0]   s_awaddr  ,
    // W
    input  logic         s_wvalid  ,
    output logic         s_wready  ,
    input  logic [31:0]  s_wdata   ,
    // B
    output logic         s_bvalid  ,
    input  logic         s_bready  ,
    output logic  [1:0]  s_bresp   ,
   
    // 128-bit Axi4 dram Write port
    // AW
    output logic         m_awvalid ,
    input  logic         m_awready ,
    output logic [39:0]  m_awaddr  ,
    output logic [ 7:0]  m_awlen   ,
    output logic [ 2:0]  m_awsize  ,
    output logic [ 3:0]  m_awcache ,
    // W
    output logic         m_wvalid  ,
    input  logic         m_wready  ,
    output logic [127:0] m_wdata   ,
    output logic [15:0]  m_wstrb   ,
    output logic         m_wlast   ,   
    // B
    input  logic         m_bvalid  ,
    output logic         m_bready  ,
    input  logic [1:0]   m_bresp   ,
     
    // 128-bit stream slave Input port
	input  logic         s_valid   ,
	output logic         s_ready   ,
	input  logic [127:0] s_data    ,
	input  logic         s_last    
    );

	localparam int S_IDLE           = 0, 
	               S_READ           = 1,
	               S_WRITE          = 2,
	               S_RESP           = 3,
	               S_START          = 4,
                   S_VALID          = 5,
                   S_NEXT           = 6;
	
    logic [63:0] dma_base_addr, dma_limit_addr, dma_read_addr, dma_write_addr;
    logic go_reg, cont_reg;
    logic [7:0] laraddr, lawaddr;
    logic [3:0] rstate; 
    logic [3:0] wstate;
    logic [3:0] astate; 
    logic [3:0] lstate; 
    logic we;
    logic done_flag;
    logic [39:0] curr_addr;
    logic [7:0] curr_len;
    logic go_reg_del;
    logic [7:0] xfer_len;
    logic [7:0] xfer_cnt;
    logic empty, full;

   
    // AXI-L Read State machine
    
    always_ff @(posedge clk) begin 
        case( rstate ) 
        S_IDLE: begin
            if( s_arvalid ) begin
                rstate <= S_READ;
            end
        end
        S_READ: begin
            if( s_rready ) begin
                rstate <= S_IDLE;
            end
        end
        endcase
        
        // Latch read address
        if( s_arvalid & s_arready ) begin
            laraddr <= s_araddr;
        end
    end

    // Connect raddr port
        
    assign s_rresp = 2'b00;
    assign s_arready = ( rstate == S_IDLE ) ? 1'b1 : 1'b0;
    assign s_rvalid  = ( rstate == S_READ ) ? 1'b1 : 1'b0;
    assign s_rdata = ( laraddr == 'h00 ) ? { 29'h0, done_flag, cont_reg, go_reg } :
                     ( laraddr == 'h04 ) ? { 32'h0 } :
                     ( laraddr == 'h08 ) ? dma_base_addr[31:0] :
                     ( laraddr == 'h0C ) ? dma_base_addr[63:32] :
                     ( laraddr == 'h10 ) ? dma_limit_addr[31:0] :
                     ( laraddr == 'h14 ) ? dma_limit_addr[63:32] :
                     ( laraddr == 'h18 ) ? dma_read_addr[31:0] :
                     ( laraddr == 'h1C ) ? dma_read_addr[63:32] :
                     ( laraddr == 'h20 ) ? dma_write_addr[31:0] :
                     ( laraddr == 'h24 ) ? dma_write_addr[63:32] :
                                           32'hdead_beef;
                                                                 
    // AXI-L write state machine
    
    assign done_flag = ( astate == S_IDLE ) ? 1'b1 : 1'b0;
    
    always_ff @(posedge clk) begin
        case( wstate ) 
        S_IDLE: begin
            if( s_awvalid & s_wvalid ) begin
                wstate <= S_WRITE;
            end
        end
        S_WRITE: begin
            wstate <= S_RESP;
        end
        S_RESP: begin
            if( s_bready ) begin
                wstate <= S_IDLE;
            end
        end
        endcase
        
        // Latch read address
        if( s_awvalid & s_awready ) begin
            lawaddr <= s_awaddr;
        end
    end
    
    assign s_awready = ( wstate == S_WRITE ) ? 1'b1 : 1'b0;
    assign s_wready  = ( wstate == S_WRITE ) ? 1'b1 : 1'b0;
    assign s_bvalid  = ( wstate == S_RESP  ) ? 1'b1 : 1'b0;
    assign s_bresp   = 2'b00;
      
    // Registers
    
    assign we = ( wstate == S_WRITE  ) ? 1'b1 : 1'b0;

    always_ff @(posedge clk) begin
        dma_base_addr[31: 0]  <= ( we && lawaddr == 'h08 ) ? s_wdata :  dma_base_addr[31:0];
        dma_base_addr[63:32]  <= ( we && lawaddr == 'h0C ) ? s_wdata :  dma_base_addr[63:32];            
        dma_limit_addr[31: 0] <= ( we && lawaddr == 'h10 ) ? s_wdata :  dma_limit_addr[31:0];
        dma_limit_addr[63:32] <= ( we && lawaddr == 'h14 ) ? s_wdata :  dma_limit_addr[63:32];
        dma_read_addr[31: 0]  <= ( we && lawaddr == 'h18 ) ? s_wdata :  dma_read_addr[31:0];
        dma_read_addr[63:32]  <= ( we && lawaddr == 'h1C ) ? s_wdata :  dma_read_addr[63:32];
        dma_write_addr[31: 0] <= ( we && lawaddr == 'h20 ) ? s_wdata :  dma_write_addr[31:0];
        dma_write_addr[63:32] <= ( we && lawaddr == 'h04 ) ? s_wdata :  dma_write_addr[63:32];
        cont_reg              <= ( we && lawaddr == 'h00 ) ? s_wdata[1] :  cont_reg;
        go_reg                <= ( we && lawaddr == 'h00 ) ? s_wdata[0] :  go_reg;
    end
    
    // DMA Write Address State Machine
    // 
    // Simplifying Assumtions: base addr is 4K aligned. Limit is 128 byte aligned, no read pointer stalling(yet)
    // For Recon, just re-write the same buffer again (ignore read pointer, guranteed valid)
    // Dropping go not supported
 
    always_ff @(posedge clk) begin 
        go_reg_del <= go_reg;
        case( astate ) 
        S_IDLE: begin
            if( go_reg && !go_reg_del) begin
                astate <= S_START;
            end
        end
        
        S_START: begin
            astate <= S_VALID;
        end
        
        S_VALID: begin
            if( m_awvalid & m_awready && curr_addr[39:12] == dma_limit_addr[39:12] ) begin // done last transfer
                astate <= ( cont_reg ) ? S_START : S_IDLE;
            end else begin
                astate <= S_VALID;
            end
        end
        endcase

        if( astate == S_START ) begin
            curr_addr <= { dma_base_addr[39:12], 12'h000 };
            curr_len  <= 'hFF; // 256 beat, 4K burst to start always
        end else if ( m_awvalid & m_awready ) begin
            curr_addr <= curr_addr + 4096;
            curr_len <= ( curr_addr[39:12] == dma_limit_addr[39:9] ) ? { dma_limit_addr[11:7], 3'b111 } : 'hff;
        end
    end
   
    // DMA Write address port
    
    assign  m_awvalid = ( astate == S_VALID && !full ) ? 1'b1 : 1'b0;
    assign  m_awaddr  = curr_addr[39:0];
    assign  m_awlen   = curr_len[7:0];
    assign  m_awsize  = 3'b100; // 128 bit = 16 byte per beat transfers
    assign  m_awcache = 4'b0000; // Determine correct one, Look in Xilinx interconnect IP docs for recommended

    // Write address transaction length fifo
    
    
    gg_sync_fifo #(8, 32, 5) 
    ( 
        .clk  (clk ),
        .reset ( reset ),
        .we    ( m_awvalid & m_awready ),
        .din   ( curr_len[7:0] ),
        .re    ( ( lstate == S_START ) ? 1'b1 : 1'b0 ),
        .qout  ( xfer_len[7:0] ),
        .empty ( empty ),
        .full  ( full ),
        .depth ( )
     );
    
    // Stream interception and write last flag generation, lstate
    
    always_ff @(posedge clk) begin 
        case( lstate ) 
        S_IDLE: begin
            if( !empty ) begin
                lstate <= S_START;
            end
        end
        
        S_START: begin
            lstate <= S_VALID;
        end
           
        S_VALID: begin
            if( m_wvalid && m_wready && xfer_cnt == 0 ) begin
                if( !empty ) begin
                    lstate <= S_START;
                end else begin
                    lstate <= S_IDLE;
                end
            end
        end 
        endcase
        
        // Burst Length Counter
        
        if( lstate == S_START ) begin
            xfer_cnt <= xfer_len;
        end else if( m_wvalid && m_wready && xfer_cnt != 0 ) begin
            xfer_cnt <= xfer_cnt - 1;
        end

    end

    // 128-bit stream slave Input port Connections

    assign s_ready  = ( m_wready && lstate == S_VALID ) ? 1'b1 : 1'b0;;
    assign m_wvalid = ( s_valid  && lstate == S_VALID ) ? 1'b1 : 1'b0;
    assign m_wlast  = ( xfer_cnt == 0 ) ? 1'b1 : 1'b0;
    assign m_wdata[127:0] = s_data[127:0];
    assign m_wstrb[15:0] = 'hffff;
    assign m_bready = 1'b1; // Accept and discard B's
       
endmodule

// Simple sync fifo, full = depth-3
module gg_sync_fifo
   #(
     parameter int WIDTH               = 8 ,
     parameter int DEPTH               = 32,
     parameter int ADDRW               = 5
    )
    (
    input  logic             clk,
    input  logic             reset,
    input  logic             we    ,
    input  logic [WIDTH-1:0] din   ,
    input  logic             re    ,
    output logic [WIDTH-1:0] qout  ,
    output logic [ADDRW:0]   depth ,
    output logic             empty ,
    output logic             full
    );

    logic [ADDRW-1:0]   rcount, wcount;
    logic [1:0]              state; 
    logic [WIDTH-1:0]   oreg, rwreg;
    logic                    rwflag;
    logic [WIDTH-1:0]   ram_q;
    logic [ADDRW-1:0]   rcnt_plus1; 
    logic [ADDRW-1:0]   raddr;
    
    assign empty = (depth == 0) ? 1'b1 : 1'b0;
    assign full  = (depth >= DEPTH-3) ? 1'b1 : 1'b0;
    assign qout  = ( state[0] ) ? oreg : (rwflag) ? rwreg : ram_q; // select oreg if its holding data
    assign raddr = ( |state ) ? ( rcount + 1 ) : rcount;
    
    always @(posedge clk) begin
            // State
            state[1] <= ( state[1] &  state[0] ) |  we | 
                        ( state[1] & !state[0] & (depth > 1) );
            state[0] <= ( state[1] |  state[0] ) & !re;
            // Counters
            wcount  <= wcount + we;
            rcount  <= rcount + re;
            depth   <= depth  + we - re;
            // output register load, when, from where
            if( state == 2'b10 && !re || 
                state == 2'b11 &&  re  ) begin
                oreg <= (rwflag) ? rwreg : ram_q;
            end
            // bypass
            rwflag <= ( (raddr == wcount) && we ) ? 1'b1 : 1'b0;
            rwreg  <= din;
    end
    
	gg_sram_1r1w #( WIDTH, DEPTH, ADDRW ) fifo_data_
    (
	   .dout 	    (ram_q),
	   .clk		    (clk),
	   .wen		    (we),
       .ren         (1'b1),
	   .waddr	    (wcount ),
	   .raddr	    (raddr),
	   .din 		(din)
	);
endmodule

