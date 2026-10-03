// 128×64 双时钟谱面 FIFO，Gray 指针跨域；RAM 不逐项复位，允许推断块 RAM。
// 两个时钟域使用同一个会话复位，必须在读取器整扇区取消完成后才断言。
module rhythm_chart_buffer (
    input wire rst, input wire write_clk, input wire read_clk,
    input wire write_enable, input wire [63:0] write_data,
    output wire reserve_ready, output wire [7:0] write_used,
    output reg overflow,
    input wire note_ready, output reg note_valid, output reg [63:0] note_data
);
    reg [63:0] memory[0:127];
    reg [7:0] write_pointer,write_gray,read_pointer,read_gray;
    reg [7:0] read_gray_meta,read_gray_sync,write_gray_meta,write_gray_sync;
    reg [63:0] read_value;
    reg read_pending;
    function [7:0] from_gray;
        input [7:0] value;
        integer bit_index;
        begin
            from_gray[7]=value[7];
            for(bit_index=6;bit_index>=0;bit_index=bit_index-1)
                from_gray[bit_index]=from_gray[bit_index+1]^value[bit_index];
        end
    endfunction
    wire [7:0] next_write=write_pointer+8'd1;
    wire [7:0] next_read=read_pointer+8'd1;
    assign write_used=write_pointer-from_gray(read_gray_sync);
    assign reserve_ready=write_used<=8'd64;
    wire empty=(read_gray==write_gray_sync);
    wire fetch=!note_valid && !read_pending && !empty;

    // RAM 的读写分别只有一个时钟；控制复位不清 RAM 内容。
    always @(posedge write_clk)if(write_enable && write_used<128)memory[write_pointer[6:0]]<=write_data;
    always @(posedge read_clk)if(fetch)read_value<=memory[read_pointer[6:0]];
    always @(posedge write_clk or posedge rst)begin
        if(rst)begin write_pointer<=0;write_gray<=0;read_gray_meta<=0;read_gray_sync<=0;overflow<=0;end
        else begin
            read_gray_meta<=read_gray;read_gray_sync<=read_gray_meta;
            if(write_enable)begin
                if(write_used==128)overflow<=1;
                else begin write_pointer<=next_write;write_gray<=(next_write>>1)^next_write;end
            end
        end
    end
    always @(posedge read_clk or posedge rst)begin
        if(rst)begin
            read_pointer<=0;read_gray<=0;write_gray_meta<=0;write_gray_sync<=0;
            read_pending<=0;note_valid<=0;note_data<=0;
        end else begin
            write_gray_meta<=write_gray;write_gray_sync<=write_gray_meta;
            read_pending<=fetch;
            if(read_pending)begin note_data<=read_value;note_valid<=1;end
            if(note_valid && note_ready)begin
                note_valid<=0;read_pointer<=next_read;read_gray<=(next_read>>1)^next_read;
            end
        end
    end
endmodule
