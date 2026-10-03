`timescale 1ns/1ps
// 真实 GAME.BIN 七个数据扇区，碎片 FAT 链，异步消费与逐条比较。
module tb_rhythm_real_chart;
    reg clk=0,nclk=0,rst=1,valid=0,done=0,nready=0,cancel=0;
    reg [7:0] data=0;
    wire req,we,hvalid,eof,cancelled,reserve,nvalid,overflow;
    wire [31:0] addr,frames;
    wire [63:0] record,note;
    wire [15:0] count,holds;
    wire [3:0] error;
    wire signed [31:0] offset;
    integer i,j,cluster,sector_index,position,consumed=0,cycles=0;
    reg [31:0] active_addr,next_cluster;
    reg [63:0] expected;
    reg [7:0] image[0:3367];
    always #5 clk=~clk;
    always #17 nclk=~nclk;
    fat32_chart_reader dut(
        .metadata_we(),.metadata_address(),.metadata_data(),
    .clk(clk),.rst(rst),.enable(1'b1),.cancel(cancel),.volume_valid(1'b1),
        .volume_fat_start(32'd100),.volume_data_start(32'd200),
        .volume_root_cluster(32'd2),.volume_sectors_per_cluster(8'd1),
        .reserve_ready(reserve),.sd_req(req),.sd_addr(addr),.sd_data(data),.sd_valid(valid),.sd_done(done),
        .note_we(we),.note_data(record),.header_valid(hvalid),.song_frames(frames),.note_count(count),
        .hold_count(holds),.offset_samples(offset),.title(),.difficulty(),.busy(),.eof(eof),
        .cancelled(cancelled),.error_code(error));
    rhythm_chart_buffer buffer(
        .rst(rst),.write_clk(clk),.read_clk(nclk),.write_enable(we),.write_data(record),
        .reserve_ready(reserve),.write_used(),.overflow(overflow),
        .note_ready(nready),.note_valid(nvalid),.note_data(note));
    always @(posedge nclk)if(!rst && nvalid && nready)begin
        if(consumed>=413)$fatal(1,"extra chart record");
        for(j=0;j<8;j=j+1)expected[j*8 +:8]=image[64+consumed*8+j];
        if(note!==expected)$fatal(1,"real chart mismatch %0d",consumed);
        consumed=consumed+1;
    end
    always @(negedge nclk)if(!rst)begin cycles=cycles+1;nready=(cycles%23)<9;end
    initial forever begin
        wait(req && !rst);@(negedge clk);active_addr=addr;
        for(i=0;i<512;i=i+1)begin
            data=0;
            if(active_addr==200)begin
                case(i)
                    0:data="G";1:data="A";2:data="M";3:data="E";4,5,6,7:data=" ";
                    8:data="B";9:data="I";10:data="N";26:data=3;28:data=8'h28;29:data=8'h0d;
                    default:;
                endcase
            end else if(active_addr==100)begin
                cluster=i/4;
                // 3→5→7→9→11→13→15；高四位无关，必须屏蔽。
                next_cluster=(cluster>=3 && cluster<15 && cluster%2==1)?32'hf0000000+cluster+2:32'hffffffff;
                data=next_cluster>>((i%4)*8);
            end else begin
                sector_index=(active_addr-201)/2;
                if(active_addr<201 || active_addr>213 || active_addr%2==0)$fatal(1,"bad fragment request %0d",active_addr);
                position=sector_index*512+i;
                if(position<3368)data=image[position];
            end
            valid=1;@(negedge clk);valid=0;repeat(i%4)@(negedge clk);
        end
        done=1;@(negedge clk);done=0;wait(!req);@(negedge clk);
    end
    initial begin
        $readmemh("prj/log/rhythm_stage2_regression/real_chart.hex",image);
        repeat(5)@(negedge clk);rst=0;
        wait(eof && consumed==413);repeat(20)@(negedge clk);
        if(!hvalid || count!=413 || holds!=49 || frames!=4323421 || offset!=0 || error!=0 || overflow)
            $fatal(1,"real chart metadata/error mismatch");
        cancel=1;wait(cancelled);
        $display("PASS real Dell's Normal: 413 records/49 holds, seven fragmented sectors, dual-clock FIFO");$finish;
    end
    initial begin #5000000;$fatal(1,"real chart timeout");end
endmodule
