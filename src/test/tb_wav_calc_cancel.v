`timescale 1ns/1ps
// 分拍计算期间取消不得发请求；已接受扇区保持地址直至done。
module tb_wav_calc_cancel;
    reg clk=0,rst=1,cancel=0,done=0;always #5 clk=~clk;
    wire req,cancelled;wire [31:0] addr;wire [4:0] observed_state=dut.state;
    fat32_wav_reader #(.USE_SHARED_VOLUME(1),.ENABLE_GAME(1)) dut(
        .clk(clk),.rst(rst),.sd_init_done(1'b1),.enable(1'b1),.game_mode(1'b1),.cancel(cancel),
        .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_data(8'd0),.sd_data_valid(1'b0),.sd_sec_read_end(done),
        .fifo_we(),.fifo_din(),.fifo_full(1'b0),.audio_read_toggle(1'b0),.audio_fifo_level(),
        .busy(),.done(),.file_found(),.format_ok(),.format_error(),.format_error_detail(),
        .song_frames(),.song_frames_valid(),.stream_eof(),.cancelled(cancelled),
        .volume_valid(1'b1),.volume_fat_start(32'd2086),.volume_data_start(32'd9640),
        .volume_root_cluster(32'd225),.volume_sectors_per_cluster(8'd64));
    task reset_reader;
        begin @(negedge clk);rst=1;cancel=0;done=0;repeat(3)@(negedge clk);rst=0;end
    endtask
    integer phase;
    initial begin
        for(phase=15;phase<=22;phase=phase+7)begin
            reset_reader;wait(observed_state==phase);@(negedge clk);cancel=1;
            repeat(3)@(negedge clk);if(req || !cancelled)$fatal(1,"cancel during calculation phase %0d",phase);
        end
        reset_reader;wait(req);@(negedge clk);cancel=1;
        repeat(8)@(negedge clk);if(!req || cancelled || addr!=23912)$fatal(1,"request was not held during cancel");
        done=1;@(negedge clk);done=0;repeat(3)@(negedge clk);
        if(req || !cancelled)$fatal(1,"cancel did not retire at done");
        $display("PASS WAV calculation cancel, restart and stable accepted address LBA23912");$finish;
    end
    initial begin #10000;$fatal(1,"calculation cancel timeout");end
endmodule
