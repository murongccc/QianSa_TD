`timescale 1ns/1ps
module tb_sd_speed_parameter;
    parameter integer HIGH_SPEED_DIV=2;
    reg clk=0,rst=1,read_request=0;always #5 clk=~clk;
    wire init_done,cmd_req,block_req;wire [15:0] divider;wire [47:0] cmd;
    reg cmd_ack=0,block_ack=0;
    sd_card_sec_read_write #(.SPI_HIGH_SPEED_DIV(HIGH_SPEED_DIV)) dut(
        .clk(clk),.rst(rst),.sd_init_done(init_done),.sd_sec_read(read_request),.sd_sec_read_addr(32'd23912),
        .sd_sec_read_data(),.sd_sec_read_data_valid(),.sd_sec_read_end(),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end(),
        .spi_clk_div(divider),.cmd_req(cmd_req),.cmd_req_ack(cmd_ack),.cmd_req_error(1'b0),.cmd(cmd),.cmd_r1(),.cmd_data_len(),
        .block_read_req(block_req),.block_read_valid(1'b0),.block_read_data(8'd0),.block_read_req_ack(block_ack),
        .block_write_req(),.block_write_data(),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0));
    always @(negedge clk)begin cmd_ack=cmd_req && !cmd_ack;block_ack=block_req && !block_ack;end
    initial begin
        repeat(3)@(negedge clk);rst=0;wait(init_done);repeat(12)@(negedge clk);
        if(divider!==HIGH_SPEED_DIV)$fatal(1,"idle overrides divider %0d",divider);
        read_request=1;wait(cmd_req && cmd[47:40]==17);@(negedge clk);
        if(cmd[39:8]!=23912 || divider!==HIGH_SPEED_DIV)$fatal(1,"CMD17 divider/address");
        read_request=0;wait(block_req);repeat(10)@(negedge clk);
        if(divider!==HIGH_SPEED_DIV)$fatal(1,"read completion overrides divider");
        $display("PASS SPI high-speed divider %0d preserved across init/idle/CMD17/read/return",HIGH_SPEED_DIV);$finish;
    end
    initial begin #10000;$fatal(1,"divider timeout");end
endmodule
