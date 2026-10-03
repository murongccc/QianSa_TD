// AUTO 与未来物理输入共用事件握手；TEST 关闭 AUTO 且不送外部事件。
// 输出事件保持到 ready，时间在生成时锁存；暂停时不生成新事件。
module rhythm_auto_input(
    input wire clk,input wire rst_n,input wire run,input wire enable,
    input wire signed [32:0] song_time,input wire [3:0] head_valid,
    input wire [127:0] head_time,input wire [3:0] holding_mask,
    output reg event_valid,input wire event_ready,
    output reg signed [32:0] event_time,output reg [3:0] press_mask,
    output wire [3:0] down_mask
);
    reg [3:0] due;
    integer i;
    always @* begin
        due=0;
        for(i=0;i<4;i=i+1)
            if(head_valid[i] && !holding_mask[i] && song_time>=$signed({1'b0,head_time[i*32 +:32]}))due[i]=1'b1;
    end
    assign down_mask=enable ? (holding_mask | (event_valid ? press_mask : 4'd0)) : 4'd0;
    // 接收后的四拍判定结束前不再生成，防止重复命中同一队头。
    reg [2:0] cooldown;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin event_valid<=0;event_time<=0;press_mask<=0;cooldown<=0;end
        else if(event_valid)begin
            if(event_ready)begin event_valid<=0;cooldown<=3'd5;end
        end else if(cooldown!=0)cooldown<=cooldown-3'd1;
        else if(run && enable && due!=0)begin event_valid<=1'b1;event_time<=song_time;press_mask<=due;end
    end
endmodule
