`timescale 1ns/1ps
`ifdef MEDIA_STARTUP_MODEL

module tb_sd_media_scaler_commit;
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
        .CLK_FREQ_HZ(100_000_000), .SCAN_START_SECTOR(0),
        .SCAN_MAX_SECTOR(0), .SCAN_TARGET_COUNT(3'd1),
        .SCALER_OUT_WIDTH(4), .SCALER_OUT_HEIGHT(4)
    ) dut (
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

    always @(posedge clk) begin
        if (rst) begin
            state <= 0;
            index <= 0;
            sd_init_done <= 0;
            sd_sec_read_data <= 0;
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
        end else begin
            sd_init_done <= 1;
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
            case (state)
                0: if (sd_sec_read) begin index <= 0; state <= 1; end
                1: begin
                    sd_sec_read_data <= bmp_byte(index);
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
