// AUTO 与未来物理输入共用事件握手；TEST 关闭 AUTO 且不送外部事件。
// 输出事件保持到 ready，时间在生成时锁存；暂停时不生成新事件。
module rhythm_auto_input #(parameter integer SERIAL_HEAD=0,parameter integer SERIAL_LATENCY=0)(
    input wire clk,input wire rst_n,input wire run,input wire enable,
    input wire signed [32:0] song_time,input wire [3:0] head_valid,
    input wire [127:0] head_time,input wire [3:0] holding_mask,
    input wire serial_valid,input wire [31:0] serial_time,output reg [1:0] serial_lane,
    output reg event_valid,input wire event_ready,
    output reg signed [32:0] event_time,output reg [3:0] press_mask,
    output wire [3:0] down_mask
);
    reg [3:0] scan_wait;
    reg in_flight;
    reg [3:0] due;
    integer i;
    always @* begin
        due=0;
        if(SERIAL_HEAD)begin
            if((!SERIAL_LATENCY || scan_wait==0) && serial_valid && !holding_mask[serial_lane] && song_time>=$signed({1'b0,serial_time}))due[serial_lane]=1;
        end else for(i=0;i<4;i=i+1)
            if(head_valid[i] && !holding_mask[i] && song_time>=$signed({1'b0,head_time[i*32 +:32]}))due[i]=1'b1;
    end
    assign down_mask=enable ? (holding_mask | (event_valid ? press_mask : 4'd0)) : 4'd0;
    // 新 AUTO 事件还须等待判定器空闲，取数延迟或在途写入不会重复命中队头。
    reg [2:0] cooldown;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin event_valid<=0;event_time<=0;press_mask<=0;cooldown<=0;serial_lane<=0;scan_wait<=SERIAL_LATENCY[3:0];in_flight<=0;end
        else begin
        if(event_valid && event_ready)in_flight<=1;else if(event_ready)in_flight<=0;
        if(run && enable && !event_valid)begin
            if(SERIAL_LATENCY && scan_wait!=4'd0)scan_wait<=scan_wait-4'd1;else begin serial_lane<=serial_lane+2'd1;scan_wait<=SERIAL_LATENCY[3:0];end
        end
        if(event_valid)begin
            if(event_ready)begin event_valid<=0;cooldown<=3'd5;end
        end else if(cooldown!=0)cooldown<=cooldown-3'd1;
        else if(run && enable && due!=0 && !in_flight)begin event_valid<=1'b1;event_time<=song_time;press_mask<=due;end
        end
    end
endmodule
