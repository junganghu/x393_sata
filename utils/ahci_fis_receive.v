/*******************************************************************************
 * Module: ahci_fis_receive
 * Date:2016-01-06  
 * Author: Andrey Filippov      
 * Description: Receives incoming FIS-es, forwards DMA ones to DMA engine
 * Stores received FIS-es if requested
 *
 * 'fis_first_vld' is asserted when the FIFO output contains first DWORD
 * of the received FIS (low byte - FIS type). FIS type is decoded
 * outside of this module, and the caller pulses one of the get_* inputs
 * to initiate incoming FIS processing (or ignoring it).
 * 'get_fis_busy' is high until the fis is being received/stored,
 * one of the 3 states (fis_ok, fis_err and fis_ferr) are raised 
 * This module also receives/updates device signature and PxTFD ERR and STS.
 *
 * Copyright (c) 2016 Elphel, Inc .
 * ahci_fis_receive.v is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 *  ahci_fis_receive.v is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/> .
 *******************************************************************************/
`timescale 1ns/1ps

module  ahci_fis_receive#(
    parameter ADDRESS_BITS = 10 // number of memory address bits - now fixed. Low half - RO/RW/RWC,RW1 (2-cycle write), 2-nd just RW (single-cycle)
)(
    input                         hba_rst, // @posedge mclk - sync reset
    input                         mclk, // for command/status
    // Control Interface
    // Receiving FIS
    input                         get_sig,        // update signature
    input                         get_dsfis,
    input                         get_psfis,
    input                         get_rfis,
    input                         get_sdbfis,
    input                         get_ufis,
    input                         get_data_fis,
    input                         get_ignore,    // ignore whatever FIS data in the
    output reg                    get_fis_busy,  // busy processing FIS 
    output reg                    fis_first_vld, // fis_first contains valid FIS header, reset by get_*
    output reg                    fis_ok,        // FIS done,  checksum OK reset by starting a new get FIS
    output reg                    fis_err,       // FIS done, checksum ERROR reset by starting a new get FIS
    output                        fis_ferr,      // FIS done, fatal error - FIS too long
    input                         update_err_sts,// update PxTFD.STS and PxTFD.ERR from the last received regs d2h
    output                  [7:0] tfd_sts,       // Current PxTFD status field (updated after regFIS and SDB - certain fields)
    output                  [7:0] tfd_err,       // Current PxTFD error field (updated after regFIS and SDB)
    output reg                    fis_i,         // value of "I" field in received regsD2H or SDB FIS
    output reg                    sdb_n,         // value of "N" field in received SDB FIS 
    output reg                    dma_a,         // value of "A" field in received DMA Setup FIS 
    output reg                    dma_d,         // value of "D" field in received DMA Setup FIS
    output reg                    pio_i,         // value of "I" field in received PIO Setup FIS
    output reg                    pio_d,         // value of "D" field in received PIO Setup FIS
    output reg              [7:0] pio_es,        // value of PIO E_Status
    output reg             [31:1] xfer_cntr,     // transfer counter in words for both DMA (31 bit) and PIO (lower 15 bits)

// Registers interface
// 2. HBA R/W registers, may be added external register layer
    output reg [ADDRESS_BITS-1:0] reg_addr,      
    output reg                    reg_we,
    output reg             [31:0] reg_data,        
    
    input                  [31:0] hda_data_in,         // FIFO output data
    input                  [ 1:0] hda_data_in_type,    // 0 - data, 1 - FIS head, 2 - R_OK, 3 - R_ERR
    input                         hba_data_in_avalid,  // Data available from the transport layer in FIFO                
    input                         hba_data_in_many,    // Multiple DWORDs available from the transport layer in FIFO           
    output                        hba_data_in_ready,   // This module or DMA consumes DWORD

    // Forwarding data to the DMA engine
    input                         dma_in_ready,        // DMA engine ready to accept data
    output                        dma_in_valid         // Write data to DMA dev->memory channel

);
//localparam FA_BITS =        6; // number of bits in received FIS address
//localparam CLB_OFFS32 = 'h200; // # In the second half of the register space (0x800..0xbff - 1KB)
/*
HBA_OFFS = 0x0 # All offsets are in bytes
CLB_OFFS = 0x800 # In the second half of the register space (0x800..0xbff - 1KB)
FB_OFFS =  0xc00 # Needs 0x100 bytes 
#HBA_PORT0 = 0x100 Not needed, always HBA_OFFS + 0x100

*/
localparam HBA_OFFS32 =         0;
localparam HBA_PORT0_OFFS32  = 'h40;
localparam PXSIG_OFFS32 = HBA_OFFS32 + HBA_PORT0_OFFS32 + 'h9; 
localparam PXTFD_OFFS32 = HBA_OFFS32 + HBA_PORT0_OFFS32 + 'h8; 
localparam FB_OFFS32 =         'h300; // # Needs 0x100 bytes 
localparam DSFIS32 =           'h0;   // DMA Setup FIS
localparam PSFIS32 =           'h8;   // PIO Setup FIS
localparam RFIS32 =            'h10;  // D2H Register FIS
localparam SDBFIS32 =          'h16;  // Set device bits FIS
localparam UFIS32 =            'h18;  // Unknown FIS
localparam DSFIS32_LENM1 =     'h6;   // DMA Setup FIS
localparam PSFIS32_LENM1 =     'h4;   // PIO Setup FIS
localparam RFIS32_LENM1 =      'h4;   // D2H Register FIS
localparam SDBFIS32_LENM1 =    'h1;
localparam UFIS32_LENM1 =      'hf;
localparam DMAH_LENM1 =        'h0; // just one word
localparam IGNORE_LENM1 =      'hf;

localparam DATA_TYPE_DMA =      0;
localparam DATA_TYPE_FIS_HEAD = 1;
localparam DATA_TYPE_OK =       2;
localparam DATA_TYPE_ERR =      3;



    wire                dma_in_start;
    wire                dma_in_stop;
    reg                 dma_in;
    reg           [1:0] was_data_in;
    reg          [12:0] data_in_words;
    reg                 dwords_over;
    reg                 too_long_err;
    
    reg [ADDRESS_BITS-1:0] reg_addr_r;
    reg           [3:0] fis_dcount; // number of DWORDS left to be written to the "memory"
    reg                 fis_save;   // save FIS data
    wire                fis_end = (hda_data_in_type == DATA_TYPE_OK) || (hda_data_in_type == DATA_TYPE_ERR);
    wire                fis_end_w = data_in_ready && fis_end & ~(|fis_end_r);
    reg           [1:0] fis_end_r;
     
    reg                 fis_rec_run; // running received FIS
    reg                 is_data_fis;
    
    wire                is_FIS_HEAD = data_in_ready && (hda_data_in_type == DATA_TYPE_FIS_HEAD);
    
    wire                data_in_ready =  hba_data_in_avalid && (hba_data_in_many || !(|was_data_in || hba_data_in_ready) );
    
    wire                get_fis = get_dsfis || get_psfis || get_rfis || get_sdbfis || get_ufis || get_data_fis ||  get_ignore;
    reg                 wreg_we_r; 
    
    wire                reg_we_w;

    reg           [3:0] update_sig;
    reg           [5:0] reg_ds;
    reg           [4:0] reg_ps;
    reg                 reg_d2h;    
    reg                 reg_sdb;    
    

    reg          [15:0] tf_err_sts;
    
    // Forward data to DMA (dev->mem) engine
    assign              dma_in_valid = dma_in_ready && (hda_data_in_type == DATA_TYPE_DMA) && data_in_ready && !too_long_err;
    assign              dma_in_stop = dma_in && data_in_ready && (hda_data_in_type != DATA_TYPE_DMA); // ||
    
    
    assign reg_we_w = wreg_we_r && !dwords_over && fis_save;
    assign dma_in_start = is_data_fis && wreg_we_r;
    
    assign hba_data_in_ready = dma_in_valid || wreg_we_r || fis_end_r[0];
    assign fis_ferr = too_long_err;
    
    
    assign tfd_sts = tf_err_sts[ 7:0];
    assign tfd_err = tf_err_sts[15:8];
    
    
     
    always @ (posedge mclk) begin
        if (hba_rst || dma_in_stop) dma_in <= 0;
        else if (dma_in_start)      dma_in <= 1;
        
        if   (hba_rst) was_data_in <= 0;
        else           was_data_in <= {was_data_in[0], hba_data_in_ready};
        
        if      (dma_in_start) data_in_words <= 0;
        else if (dma_in_valid) data_in_words <=  data_in_words + 1;
        
        if      (hba_rst)                                 too_long_err <= 0; // it is a fatal error, only reset
        else if ((dma_in_valid && data_in_words[12]) ||
                  (wreg_we_r && dwords_over))             too_long_err <= 1;
        
        if (get_fis) begin
           reg_addr_r <= ({ADDRESS_BITS{get_sig}}    & (PXSIG_OFFS32))  |
                         ({ADDRESS_BITS{get_dsfis}}  & (FB_OFFS32 + DSFIS32))  |
                         ({ADDRESS_BITS{get_psfis}}  & (FB_OFFS32 + PSFIS32))  |
                         ({ADDRESS_BITS{get_rfis}}   & (FB_OFFS32 + RFIS32))   |
                         ({ADDRESS_BITS{get_sdbfis}} & (FB_OFFS32 + SDBFIS32)) |
                         ({ADDRESS_BITS{get_ufis}}   & (FB_OFFS32 + UFIS32));
           fis_dcount <= ({4{get_sig}}    & RFIS32_LENM1)  |
                         ({4{get_dsfis}}    & DSFIS32_LENM1)  |
                         ({4{get_psfis}}    & PSFIS32_LENM1)  |
                         ({4{get_rfis}}     & RFIS32_LENM1)   |
                         ({4{get_sdbfis}}   & SDBFIS32_LENM1) |
                         ({4{get_ufis}}     & UFIS32_LENM1 )  |
                         ({4{get_data_fis}} & DMAH_LENM1)     |
                         ({4{get_ignore}}   & IGNORE_LENM1 );
           fis_save <=    !get_data_fis && !get_ignore && !get_sig;
           is_data_fis <= get_data_fis;
           update_sig <=  get_sig?    1 : 0;
           reg_ds <=      get_dsfis ? 1 : 0;
           reg_ps <=      get_psfis ? 1 : 0;
           reg_d2h <=     get_rfis ?  1 : 0;    
           reg_sdb <=     get_rfis ?  1 : 0;    
        end else if (wreg_we_r && !dwords_over) begin
           fis_dcount <= fis_dcount - 1;               // update even if not writing to registers
           if (fis_save) reg_addr_r <= reg_addr_r + 1; // update only when writing to registers
           update_sig <=  update_sig << 1;
           reg_ds <=      reg_ds << 1;
           reg_ps <=      reg_ps << 1;
           reg_d2h <=     0;    
           reg_sdb <=     0;    
           
        end
        
        if      (hba_rst)                  fis_rec_run <= 0;
        else if (get_fis)                  fis_rec_run <= 1;
        else if (fis_end && data_in_ready) fis_rec_run <= 0;
        
        if      (hba_rst)                     dwords_over <= 0;
        else if (wreg_we_r && !(|fis_dcount)) dwords_over <= 1;
        
        if (hba_rst) wreg_we_r <= 0;
        else         wreg_we_r <= fis_rec_run && data_in_ready && !fis_end && !dwords_over && (|fis_dcount || !wreg_we_r);

        fis_end_r <= {fis_end_r[0], fis_end_w};
        
        if      (hba_rst)                     get_fis_busy <= 0;
        else if (get_fis)                     get_fis_busy <= 1;
        else if (too_long_err || fis_end_w)   get_fis_busy <= 0; 
        
        if      (hba_rst || get_fis)          fis_first_vld <= 0;
        else if (is_FIS_HEAD)                 fis_first_vld <= 1;
        
        if      (hba_rst || get_fis)          fis_ok <= 0;
        else if (fis_end_w)                   fis_ok <= hda_data_in_type == DATA_TYPE_OK;
        
        if      (hba_rst || get_fis)          fis_err <= 0;
        else if (fis_end_w)                   fis_err <= hda_data_in_type != DATA_TYPE_OK;
        
        if (reg_we_w)            reg_data[31:8] <= hda_data_in[31:8];
        else if (update_sig[1])  reg_data[31:8] <= hda_data_in[23:0];
        else if (update_err_sts) reg_data[31:8] <= {16'b0,tf_err_sts[15:8]};

        if (reg_we_w)            reg_data[ 7:0] <=  hda_data_in[ 7:0];
        else if (update_sig[3])  reg_data[ 7:0] <=  hda_data_in[ 7:0];
        else if (update_err_sts) reg_data[ 7:0] <=  tf_err_sts [ 7:0];
        
        if (reg_d2h || update_sig[0]) tf_err_sts  <= hda_data_in[15:0];
        else if (reg_sdb)             tf_err_sts  <= {hda_data_in[15:8], tf_err_sts[7], hda_data_in[6:4], tf_err_sts[3],hda_data_in[2:0]};
        
        reg_we <= reg_we_w || update_sig[3] || update_err_sts;
        if (reg_we_w || update_sig[3]) reg_addr <=  reg_addr_r;
        else if (update_err_sts)     reg_addr <=  PXTFD_OFFS32;

        if (reg_d2h || reg_sdb || reg_ds[0]) fis_i <=           hda_data_in[14];
        if (reg_sdb)                         sdb_n <=           hda_data_in[15];
        if (reg_ds[0])                       {dma_a,dma_d}  <=  {hda_data_in[15],hda_data_in[13]};

        if (reg_ps[0])                       {pio_i,pio_d}  <=  {hda_data_in[14],hda_data_in[13]};
        if (reg_ps[3])                       pio_es  <=         hda_data_in[31:24];
        
        if (reg_ps[4] || reg_ds[5])          xfer_cntr[31:1] <= {reg_ds[5]?hda_data_in[31:16]:16'b0,hda_data_in[15:1]};
        
    end

endmodule
