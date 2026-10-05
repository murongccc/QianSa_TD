// Clients hold request/address until their done pulse. One complete SD
// transaction owns the return path, regardless of subsequent request changes.
module sd_sector_arbiter #(
    parameter integer ENABLE_CHART=0,
    parameter integer REGISTER_RESPONSE=0
)(
    input wire clk, input wire rst,
    input wire bmp_req, input wire [31:0] bmp_addr,
    input wire audio_req, input wire [31:0] audio_addr,
    input wire audio_urgent,
    output wire sd_req, output reg [31:0] sd_addr,
    input wire sd_valid, input wire sd_done,
    output wire bmp_valid, output wire bmp_done,
    output wire audio_valid, output wire audio_done,
    input wire chart_req, input wire [31:0] chart_addr,
    output wire chart_valid, output wire chart_done,
    input wire [7:0] sd_data, output wire [7:0] response_data,
    output wire response_busy
);
    localparam IDLE=2'd0, ACTIVE=2'd1, GAP=2'd2;
    reg [1:0] state;
    reg owner_bmp, owner_audio, last_audio;
    reg owner_chart,last_chart;
    wire chart_request=ENABLE_CHART && chart_req;
    // A sector already in flight is never interrupted.  Between sectors,
    // protect the PCM reservoir before applying normal fair arbitration.
    wire choose_audio = audio_req && (audio_urgent || (!(bmp_req || chart_request)) || !last_audio);
    // 有 BMP/谱面请求时，音频仅在非紧急且上一扇区也是音频时让出。
    // 两个非音频归属直接并行判断，不串接 choose_audio/choose_chart。
    wire audio_yields = !audio_req || (!audio_urgent && last_audio);
    wire choose_chart = chart_request && (!bmp_req || !last_chart) && audio_yields;
    wire choose_bmp = bmp_req && (!chart_request || last_chart) && audio_yields;
    // 归属独热，地址并行掩码后合并，避免串行优先选择叠加宽寄存器使能。
    wire [31:0] chosen_address=({32{choose_audio}} & audio_addr) |
        ({32{choose_chart}} & chart_addr) | ({32{choose_bmp}} & bmp_addr);
    assign sd_req = (state == ACTIVE);
    // 独热归属只在接收请求时设置；末字节采样后清除，返回无需状态译码。
    wire [5:0] raw_response={sd_done && owner_chart,sd_valid && owner_chart,
        sd_done && owner_audio,sd_valid && owner_audio,sd_done && owner_bmp,sd_valid && owner_bmp};
    wire [5:0] response;
    assign {chart_done,chart_valid,audio_done,audio_valid,bmp_done,bmp_valid}=response;
    assign response_busy=(state!=IDLE) || (|response);
    generate if(REGISTER_RESPONSE)begin: registered_response
        reg [5:0] flags;
        reg [7:0] data;
        always @(posedge clk or posedge rst)begin
            if(rst)begin flags<=6'd0;data<=8'd0;end
            else begin flags<=raw_response;data<=sd_data;end
        end
        assign response=flags;
        assign response_data=data;
    end else begin: direct_response
        assign response=raw_response;
        assign response_data=sd_data;
    end endgenerate
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE; sd_addr<=0; owner_bmp<=0; owner_audio<=0; last_audio<=1;
            owner_chart<=0;last_chart<=1;
        end else case (state)
            IDLE: if (bmp_req || audio_req || chart_request) begin
                owner_audio<=choose_audio;
                owner_chart<=choose_chart;
                owner_bmp<=choose_bmp;
                sd_addr<=chosen_address;
                state<=ACTIVE;
            end
            ACTIVE: if (sd_done) begin
                last_audio<=owner_audio;
                if(!owner_audio)last_chart<=owner_chart;
                owner_bmp<=0;owner_audio<=0;owner_chart<=0;
                state<=GAP;
            end
            // sd_card_sec_read_write returns to WAIT_READ_WRITE at done.
            // Keep request low while clients retire/update their requests.
            GAP: state<=IDLE;
            default: begin state<=IDLE;owner_bmp<=0;owner_audio<=0;owner_chart<=0;end
        endcase
    end
endmodule
