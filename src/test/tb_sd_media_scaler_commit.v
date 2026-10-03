`timescale 1ns/1ps
`ifdef MEDIA_STARTUP_MODEL

module tb_sd_media_scaler_commit;
    parameter RHYTHM=0;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg write_finish_toggle = 1'b0;
    wire [3:0] state_code;
    wire display_valid, write_req, write_en;
    wire display_switch_toggle;
    reg display_switch_applied_toggle = 1'b0;
    reg display_switch_seen = 1'b0;
    integer write_pixels = 0;

    always #5 clk = ~clk;

    sd_media_pipeline #(
        .ENABLE_RHYTHM(RHYTHM),.CLK_FREQ_HZ(100_000_000), .SCAN_START_SECTOR(0),
        .SCAN_MAX_SECTOR(0), .SCAN_TARGET_COUNT(3'd1),
        .SCALER_OUT_WIDTH(4), .SCALER_OUT_HEIGHT(4)
    ) dut (
        .game_metadata_address(6'd0),.game_metadata_data(),.game_metadata_valid(),
    .game_clk(clk),.game_reset(1'b0),.game_enable(1'b0),.game_cancel(RHYTHM!=0),.game_mode(RHYTHM!=0),.freeze_media(RHYTHM!=0),.game_note_ready(1'b0),.game_note_valid(),.game_note_data(),.game_ready(),.game_cancelled(),.game_audio_eof(),.game_chart_eof(),.media_quiet(),.game_error(),.game_frames(),.game_audio_level(),.game_notes(),.game_offset(),.game_title(),.game_difficulty(),
    .clk(clk), .rst(rst), .key_next(1'b1), .key_auto(1'b0),
        .uart_command_async(3'd0), .uart_command_toggle_async(1'b0),
        .state_code(state_code), .bmp_width(16'd0), .bmp_height(16'd0),
        .parsed_width(), .parsed_height(), .parsed_top_down(),
        .display_valid(display_valid), .write_finish_toggle(write_finish_toggle),
        .display_switch_applied_toggle_async(display_switch_applied_toggle),
        .display_switch_toggle(display_switch_toggle),
        .auto_play_enabled(), .write_buf_idx(), .disp_buf_idx(),
        .write_req(write_req), .write_req_ack(write_req),
        .write_en(write_en), .write_data(), .write_ready(1'b1),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
        .audio_fifo_we(), .audio_fifo_din(), .audio_fifo_full(1'b0),
        .audio_read_toggle(1'b0), .audio_reader_enable(1'b0),
        .audio_reader_reset(1'b1), .audio_reader_busy(), .audio_reader_done()
    );

    always @(negedge clk) begin
        if (rst) begin
            write_pixels = 0;
            write_finish_toggle = 1'b0;
        end else if (write_en) begin
            write_pixels = write_pixels + 1;
            if (write_pixels == 16)
                write_finish_toggle = ~write_finish_toggle;
        end
    end

    always @(posedge clk) if (!rst && display_switch_toggle != display_switch_seen) begin
        display_switch_seen <= display_switch_toggle;
        display_switch_applied_toggle <= ~display_switch_applied_toggle;
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        wait(display_valid);
        repeat(8)@(negedge clk);
        // 首显提交可先于不可暂停扇区的最后字节，退场必须等待 SD 请求排空。
        if(RHYTHM)begin
            wait(dut.game_cancelled && dut.media_quiet);
            repeat(4)@(negedge clk);
            if(dut.sd_read_mux)$fatal(1,"shared shell started a request after cancellation");
        end
        if (write_pixels != 16)
            $fatal(1, "frame committed with %0d pixels", write_pixels);
        $display("PASS sd_media_pipeline: BMP/FIFO/scaler output reached frame commit");
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "pipeline timeout: status=%0d writes=%0d", state_code, write_pixels);
    end
endmodule

module scaler_linebuf_even_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) if (rstb) dob <= 0; else dob <= mem[addrb];
endmodule

module scaler_linebuf_odd_ip(
    input wire [23:0] dia, input wire [10:0] addra, input wire cea,
    input wire clka, output reg [23:0] dob, input wire [10:0] addrb,
    input wire clkb, input wire rstb
);
    reg [23:0] mem [0:2047];
    always @(posedge clka) if (cea) mem[addra] <= dia;
    always @(posedge clkb) if (rstb) dob <= 0; else dob <= mem[addrb];
endmodule

module media_startup_sector_model(
    input wire clk, rst, SD_MISO,
    output wire SD_nCS, SD_DCLK, SD_MOSI,
    output reg sd_init_done,
    input wire sd_sec_read, input wire [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid, sd_sec_read_end,
    input wire sd_sec_write, input wire [31:0] sd_sec_write_addr,
    input wire [7:0] sd_sec_write_data,
    output wire sd_sec_write_data_req, sd_sec_write_end
);
    reg [1:0] state;
    integer index;
    reg [31:0] sector_addr;
    assign SD_nCS = 1'b1;
    assign SD_DCLK = 1'b0;
    assign SD_MOSI = 1'b1;
    assign sd_sec_write_data_req = 1'b0;
    assign sd_sec_write_end = 1'b0;

    function [7:0] bmp_byte;
        input integer n;
        begin
            bmp_byte = 8'd0;
            case (n)
                0: bmp_byte = "B"; 1: bmp_byte = "M";
                2: bmp_byte = 8'd70;
                10: bmp_byte = 8'd54;
                14: bmp_byte = 8'd40;
                18: bmp_byte = 8'd2;
                22: bmp_byte = 8'd2;
                26: bmp_byte = 8'd1;
                28: bmp_byte = 8'd24;
                // File-order bottom row: blue, white.
                54: bmp_byte = 8'hff; 55: bmp_byte = 8'h00; 56: bmp_byte = 8'h00;
                57: bmp_byte = 8'hff; 58: bmp_byte = 8'hff; 59: bmp_byte = 8'hff;
                // Two padding bytes at 60,61. Top row: red, green.
                62: bmp_byte = 8'h00; 63: bmp_byte = 8'h00; 64: bmp_byte = 8'hff;
                65: bmp_byte = 8'h00; 66: bmp_byte = 8'hff; 67: bmp_byte = 8'h00;
                default: bmp_byte = 8'd0;
            endcase
        end
    endfunction

    // 当前媒体链先扫描 FAT32 目录，不能在 LBA0 只提供旧版裸 BMP。
    // 构造直接卷：BPB=0、FAT=1、根目录=2、2x2 BMP 文件=3。
    function [7:0] sector_byte;
        input [31:0] address;
        input integer byte_index;
        begin
            sector_byte=8'd0;
            case(address)
                0: case(byte_index)
                    12: sector_byte=8'd2;
                    13,14,16,36: sector_byte=8'd1;
                    44: sector_byte=8'd2;
                    default: ;
                endcase
                1: if(byte_index>=8 && byte_index<16)
                    sector_byte=(byte_index%4==3)?8'h0f:8'hff;
                2: case(byte_index)
                    0: sector_byte="I";
                    8: sector_byte="B";
                    9: sector_byte="M";
                    10: sector_byte="P";
                    26: sector_byte=8'd3;
                    28: sector_byte=8'd70;
                    default: ;
                endcase
                3: sector_byte=bmp_byte(byte_index);
                default: ;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state <= 0;
            index <= 0;
            sector_addr <= 0;
            sd_init_done <= 0;
            sd_sec_read_data <= 0;
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
        end else begin
            sd_init_done <= 1;
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
            case (state)
                0: if (sd_sec_read) begin index <= 0; sector_addr <= sd_sec_read_addr; state <= 1; end
                1: begin
                    sd_sec_read_data <= sector_byte(sector_addr,index);
                    sd_sec_read_data_valid <= 1;
                    if (index == 511) state <= 2;
                    else index <= index + 1;
                end
                2: begin sd_sec_read_end <= 1; state <= 3; end
                3: state <= 0;
                default: state <= 0;
            endcase
        end
    end
endmodule

`endif
