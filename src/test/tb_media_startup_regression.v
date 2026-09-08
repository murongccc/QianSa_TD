`timescale 1ns/1ps
// Explicit opt-in, unique model name: this file cannot replace the board SD
// driver even if a GUI accidentally adds test files to its design file set.
`ifdef MEDIA_STARTUP_MODEL
module tb_media_startup_regression;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    wire [3:0] short_status, restored_status;
    wire short_display, restored_display, write_en, write_req;
    reg write_finish=0;
    integer pixels=0;
    sd_media_pipeline #(.SCAN_MAX_SECTOR(2048), .SCAN_TARGET_COUNT(3'd1)) short_window (
        .clk(clk),.rst(rst),.key_next(1'b1),.key_auto(1'b1),
        .uart_command_async(3'd0),.uart_command_toggle_async(1'b0),
        .state_code(short_status),.bmp_width(16'd640),.bmp_height(16'd480),
        .display_valid(short_display),.write_finish_toggle(1'b0),
        .auto_play_enabled(),.write_buf_idx(),.disp_buf_idx(),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1),
        .audio_fifo_we(),.audio_fifo_din(),.audio_fifo_full(1'b0),.audio_read_toggle(1'b0),
        .audio_reader_busy(),.audio_reader_done());
    sd_media_pipeline #(.SCAN_MAX_SECTOR(4096), .SCAN_TARGET_COUNT(3'd1)) restored_window (
        .clk(clk),.rst(rst),.key_next(1'b1),.key_auto(1'b1),
        .uart_command_async(3'd0),.uart_command_toggle_async(1'b0),
        .state_code(restored_status),.bmp_width(16'd640),.bmp_height(16'd480),
        .display_valid(restored_display),.write_finish_toggle(write_finish),
        .auto_play_enabled(),.write_buf_idx(),.disp_buf_idx(),
        .write_req(write_req),.write_req_ack(write_req),.write_en(write_en),.write_data(),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1),
        .audio_fifo_we(),.audio_fifo_din(),.audio_fifo_full(1'b0),.audio_read_toggle(1'b0),
        .audio_reader_busy(),.audio_reader_done());
    // Observe the DUT's NBA-updated write pulse on the following half cycle;
    // sampling it at the same posedge would see the previous value and miss
    // a one-clock pixel write.
    always @(negedge clk) begin
        if(rst) begin pixels<=0; write_finish<=0; end
        else if(write_en) begin pixels<=pixels+1; write_finish<=~write_finish; end
    end
    initial begin
        repeat(4) @(negedge clk); rst=0;
        wait(short_status==8);
        if(short_display!==0 || short_window.media_count!==0)
            $fatal(1,"short window unexpectedly discovered a BMP beyond 2048");
        wait(restored_display);
        if(pixels!==1 || restored_window.media_sector0!==2050)
            $fatal(1,"restored window did not load the discovered BMP");
        // Scan completion must remain high AFTER the discovery pulse.
        if(restored_window.scan_done!==1 || restored_window.scan_found_valid!==0)
            $fatal(1,"scan_done level semantics changed");
        // Fake volume contains no WAV. Lookup must retire cleanly with 9.
        wait(restored_status==9);
        if(!restored_display) $fatal(1,"WAV lookup failure removed image");
        $display("PASS startup: old range misses BMP; expanded range loads sector 2050, commits frame, reports missing WAV");
        $finish;
    end
    initial begin
        #300000000;
        $display("startup timeout: short=%d restored=%d scan=%b/%b count=%d/%d load=%b/%b bmp_state=%d/%d src=%b started=%b pending=%b wc=%b commit=%b disp=%b wrtog=%b sync=%b",
                 short_status, restored_status, short_window.scan_done,
                 restored_window.scan_done, short_window.media_count,
                 restored_window.media_count, short_window.load_inflight,
                 restored_window.load_inflight, short_window.bmp_state_code,
                 restored_window.bmp_state_code, restored_window.source_complete,
                 restored_window.load_started, restored_window.write_complete_pending,
                 restored_window.write_complete, restored_window.frame_commit,
                 restored_window.display_valid, write_finish,
                 restored_window.write_finish_sync);
        $fatal(1,"startup timeout");
    end
endmodule

module media_startup_sector_model (
    input wire clk,rst,SD_MISO,
    output wire SD_nCS,SD_DCLK,SD_MOSI,
    output reg sd_init_done,
    input wire sd_sec_read,input wire [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid,sd_sec_read_end,
    input wire sd_sec_write,input wire [31:0] sd_sec_write_addr,
    input wire [7:0] sd_sec_write_data,
    output wire sd_sec_write_data_req,sd_sec_write_end
);
    assign SD_nCS=1; assign SD_DCLK=0; assign SD_MOSI=1;
    assign sd_sec_write_data_req=0; assign sd_sec_write_end=0;
    reg [1:0] state;
    reg [31:0] addr;
    integer index;
    function [7:0] sector_byte;
        input [31:0] lba; input integer n;
        begin
            sector_byte=0;
            // Minimal MBR/BPB for the independent WAV locator.
            if(lba==0 && n==455) sector_byte=8;
            if(lba==2048) case(n)
                13:sector_byte=1; 14:sector_byte=32;
                16:sector_byte=2; 36:sector_byte=1; 44:sector_byte=2;
            endcase
            // Synthetic short pixel payload keeps the memory mock bounded;
            // its format fields still exercise the real 640x480 matcher.
            if(lba==2050) case(n)
                0:sector_byte="B"; 1:sector_byte="M"; 2:sector_byte=58;
                10:sector_byte=54; 18:sector_byte=8'h80; 19:sector_byte=2;
                22:sector_byte=8'he0; 23:sector_byte=1; 28:sector_byte=24;
                54:sector_byte=8'h12; 55:sector_byte=8'h34; 56:sector_byte=8'h56;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=0; sd_init_done<=0; sd_sec_read_data_valid<=0;
            sd_sec_read_end<=0; sd_sec_read_data<=0; addr<=0; index<=0;
        end else begin
            sd_init_done<=1; sd_sec_read_data_valid<=0; sd_sec_read_end<=0;
            case(state)
                0: if(sd_sec_read) begin addr<=sd_sec_read_addr;index<=0;state<=1;end
                1: begin
                    sd_sec_read_data<=sector_byte(addr,index);sd_sec_read_data_valid<=1;
                    index<=index+1; if(index==511)state<=2;
                end
                2: begin sd_sec_read_end<=1;state<=3;end
                3: state<=0;
            endcase
        end
    end
endmodule
`endif
