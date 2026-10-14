// 预加载时共享串行除法/BCD转换器；成功提交后才发布对应SDRAM槽的信息。
// info布局：[87:72]宽BCD，[71:56]高BCD，[55:28]水平百分比BCD，[27:0]垂直百分比BCD。
module image_info_metadata #(
    parameter integer OUT_WIDTH=640, parameter integer OUT_HEIGHT=480
)(
    input wire clk,rst,start,abort,commit,
    input wire [2:0] write_slot,
    input wire [15:0] source_width,source_height,
    output wire ready,
    input wire video_clk,video_rst,frame_start,input wire [2:0] display_slot,
    output reg [88:0] display_info
);
reg [4:0] slot_valid;
reg [2:0] pending_slot;
reg [10:0] width_q,height_q,divisor;
reg [87:0] prepared;
reg prepared_valid,commit_pending;
reg write_active;
reg [3:0] write_index;
localparam IDLE=2'd0,BCD=2'd1,DIV_INIT=2'd2,DIV_RUN=2'd3;
localparam [23:0] X_PERCENT_NUMERATOR=OUT_WIDTH*10000;
localparam [23:0] Y_PERCENT_NUMERATOR=OUT_HEIGHT*10000;
reg [1:0] state,field;
reg [4:0] bit_count;
reg [23:0] binary_shift,quotient;
reg [27:0] bcd;
reg [11:0] remainder;
reg [27:0] bcd_adjust;
integer digit;
wire [27:0] bcd_next={bcd_adjust[26:0],binary_shift[23]};
wire [11:0] trial={remainder[10:0],binary_shift[23]};
wire subtract=trial>={1'b0,divisor};
wire [11:0] remainder_next=subtract ? trial-{1'b0,divisor} : trial;
wire [23:0] quotient_next={quotient[22:0],subtract};
// 每槽16字节，其中前11字节为88位显示数据；双时钟BRAM不复位内容。
// 发布需11拍；ready限定下一个scaler_start，防止发布期间覆写prepared。
assign ready=state==IDLE && !prepared_valid && !write_active;
wire [7:0] cache_data;
reg [2:0] read_slot;
reg [3:0] read_index;
reg read_active,read_primed;
reg [4:0] valid_meta,valid_sync;
rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(8),.ADDRESS_BITS(7),.DEPTH(128)) u_slots(
    .write_clk(clk),.write_enable(write_active && !abort && !rst),
    .write_address({pending_slot,write_index}),.write_data(prepared[87:80]),
    .read_clk(video_clk),.read_address({read_slot,read_index}),.read_data(cache_data));
// VS起点开始读取，12拍内完成，早于当前640x480时序的有效画面。
// 组包期间valid=0，避免首帧/复位/无效槽泄露未初始化RAM数据。
always @(posedge video_clk or posedge video_rst)begin
    if(video_rst)begin
        valid_meta<=0;valid_sync<=0;read_slot<=0;read_index<=0;
        read_active<=0;read_primed<=0;display_info<=0;
    end else begin
        valid_meta<=slot_valid;valid_sync<=valid_meta;
        if(frame_start)begin
            display_info[88]<=0;read_slot<=display_slot;read_index<=0;read_primed<=0;
            read_active<=display_slot<3'd5 && valid_sync[display_slot];
        end else if(read_active)begin
            read_primed<=1;read_index<=read_index+1'b1;
            if(read_primed)display_info[87:0]<={display_info[79:0],cache_data};
            if(read_index==4'd11)begin read_active<=0;display_info[88]<=1;end
        end
    end
end
always @* begin
    bcd_adjust=bcd;
    for(digit=0;digit<7;digit=digit+1)
        if(bcd[digit*4 +: 4]>=4'd5) bcd_adjust[digit*4 +: 4]=bcd[digit*4 +: 4]+4'd3;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        slot_valid<=0;pending_slot<=0;width_q<=0;height_q<=0;divisor<=0;
        prepared_valid<=0;commit_pending<=0;state<=IDLE;field<=0;write_active<=0;write_index<=0;
        bit_count<=0;binary_shift<=0;quotient<=0;bcd<=0;remainder<=0;
    end else if(abort) begin
        state<=IDLE;prepared_valid<=0;commit_pending<=0;write_active<=0;
    end else if(start) begin
        pending_slot<=write_slot;width_q<=source_width[10:0];height_q<=source_height[10:0];
        if(write_slot<3'd5)slot_valid[write_slot]<=0;
        prepared_valid<=0;commit_pending<=0;
        field<=0;bit_count<=0;bcd<=0;binary_shift<={8'd0,source_width};
        state<=(source_width!=0 && source_height!=0 && source_width<=16'd1920 && source_height<=16'd1080) ? BCD : IDLE;
    end else begin
        if(commit)commit_pending<=1;
        if(prepared_valid && (commit_pending || commit)) begin
            if(pending_slot<3'd5)begin write_active<=1;write_index<=0;end
            prepared_valid<=0;commit_pending<=0;
        end
        if(write_active)begin
            prepared<={prepared[79:0],8'd0};write_index<=write_index+1'b1;
            if(write_index==4'd10)begin write_active<=0;slot_valid[pending_slot]<=1;end
        end
        case(state)
            BCD:begin
                bcd<=bcd_next;binary_shift<=binary_shift<<1;bit_count<=bit_count+1'b1;
                if(bit_count==5'd23)begin
                    bit_count<=0;bcd<=0;
                    case(field)
                        0:begin prepared[87:72]<=bcd_next[15:0];field<=1;binary_shift<={13'd0,height_q};end
                        1:begin prepared[71:56]<=bcd_next[15:0];field<=2;state<=DIV_INIT;end
                        2:begin prepared[55:28]<=bcd_next;field<=3;state<=DIV_INIT;end
                        3:begin prepared[27:0]<=bcd_next;prepared_valid<=1;state<=IDLE;end
                    endcase
                end
            end
            DIV_INIT:begin
                // 单位0.01%，加除数的一半使整数除法实现四舍五入。
                binary_shift<=(field==2 ? X_PERCENT_NUMERATOR : Y_PERCENT_NUMERATOR)+
                    (field==2 ? {1'b0,width_q[10:1]} : {1'b0,height_q[10:1]});
                divisor<=field==2 ? width_q : height_q;
                remainder<=0;quotient<=0;bit_count<=0;state<=DIV_RUN;
            end
            DIV_RUN:begin
                remainder<=remainder_next;quotient<=quotient_next;binary_shift<=binary_shift<<1;
                bit_count<=bit_count+1'b1;
                if(bit_count==5'd23)begin binary_shift<=quotient_next;bit_count<=0;bcd<=0;state<=BCD;end
            end
            default:state<=IDLE;
        endcase
    end
end
endmodule
