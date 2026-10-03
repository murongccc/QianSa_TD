// 四轨判定，所有接口在 clk 域；时间单位为 48 kHz PCM 帧。
// event_valid/ready 为保持式握手，时间及掩码接收后锁存，和弦逐轨处理不改时间。
module rhythm_judge_core #(parameter integer BLOCK_QUEUE=0,parameter integer SCORE_DSP=0)(
    input wire clk, input wire rst_n, input wire run,
    input wire signed [32:0] song_time, input wire signed [31:0] chart_offset,
    input wire [15:0] total_notes, input wire chart_eof,
    input wire note_valid, input wire [63:0] note_data, output wire note_ready,
    input wire event_valid, output wire event_ready,
    input wire signed [32:0] event_time,
    input wire [3:0] press_mask, input wire [3:0] release_mask, input wire [3:0] down_mask,
    output wire [3:0] head_valid, output wire [127:0] head_time,
    output wire [3:0] holding_mask,
    input wire [4:0] view_index, output wire view_valid,
    output wire [31:0] view_start, output wire [31:0] view_end,
    output reg result_valid, output reg [1:0] result_lane, output reg [1:0] result_grade,
    output reg [15:0] perfect_count, output reg [15:0] good_count,
    output reg [15:0] bad_count, output reg [15:0] miss_count,
    output reg [15:0] combo, output reg [15:0] max_combo,
    output reg [19:0] score, output wire done, output reg queue_overflow
);
    // grade: 0 Miss、1 Bad、2 Good、3 Perfect；每个 Hold 只在最终成功/失败时结算。
    reg [2:0] read_ptr [0:3], write_ptr [0:3];
    reg [3:0] used [0:3];
    reg [3:0] holding;
    reg [1:0] hold_grade [0:3];
    reg processing_event;
    reg [1:0] lane;
    reg signed [32:0] captured_time;
    reg [3:0] captured_press, captured_release;
    wire [4:0] address = {lane,read_ptr[lane]};
    wire [31:0] current_start,current_end;
    reg memory_wait;
    wire signed [33:0] now_time = processing_event ? {captured_time[32],captured_time} : {song_time[32],song_time};
    wire signed [33:0] delta = now_time - $signed({2'b00,current_start});
    // 判定窗不超过 7200 帧，只对可表示的 ±8192 区间取 14 位绝对值。
    wire delta_near=(delta[33:13]==21'd0) || (delta[33:13]==21'h1fffff);
    wire [13:0] distance=delta[13] ? -delta[13:0] : delta[13:0];
    wire signed [33:0] tail_time = $signed({2'b00,current_end});
    reg retire, begin_hold;
    reg [1:0] grade;
    always @* begin
        retire=1'b0; begin_hold=1'b0; grade=2'd0;
        if(run && used[lane]!=0 && (!BLOCK_QUEUE || !memory_wait)) begin
            if(holding[lane]) begin
                if(processing_event && captured_release[lane]) begin
                    retire=1'b1;
                    if(now_time>=tail_time-34'sd2400) grade=hold_grade[lane];
                end else if(!processing_event) begin
                    if(now_time>=tail_time) begin retire=1'b1;grade=hold_grade[lane];end
                    else if(!down_mask[lane]) begin
                        retire=1'b1;
                        if(now_time>=tail_time-34'sd2400)grade=hold_grade[lane];
                    end
                end
            end else if(processing_event && captured_press[lane] && delta_near && distance<=14'd7200) begin
                grade=distance<=14'd2400 ? 2'd3 : (distance<=14'd4800 ? 2'd2 : 2'd1);
                if(current_end!=current_start)begin_hold=1'b1;
                else retire=1'b1;
            end else if(!processing_event && delta>34'sd7200) retire=1'b1;
        end
    end
    wire signed [33:0] incoming_start = $signed({2'b00,note_data[31:0]}) + $signed({{2{chart_offset[31]}},chart_offset});
    wire signed [33:0] horizon = $signed({song_time[32],song_time}) + 34'sd96000;
    wire [1:0] incoming_lane = note_data[57:56];
    wire incoming_due = incoming_start<=horizon;
    wire actual_retire;
    assign note_ready = !done && incoming_due && (used[incoming_lane]<4'd8 || (actual_retire && lane==incoming_lane));
    wire enqueue = note_valid && note_ready;
    assign event_ready = run && !processing_event && !done && (!BLOCK_QUEUE || !memory_wait);
    wire accept_event = event_valid && event_ready;
    // 新事件优先于后台扫描，避免松开电平先触发失败而丢失该事件的原始时间。
    assign actual_retire = retire && !accept_event;
    assign holding_mask=holding;
    wire [1:0] view_lane=view_index[4:3];
    wire [2:0] view_slot=read_ptr[view_lane]+view_index[2:0];
    wire view_is_valid={1'b0,view_index[2:0]}<used[view_lane];
    genvar g;
    generate for(g=0;g<4;g=g+1)begin: heads
        assign head_valid[g]=used[g]!=0;
    end endgenerate
    wire [31:0] incoming_end=incoming_start[31:0]+{8'd0,note_data[55:32]};
    generate if(BLOCK_QUEUE)begin: block_queue
        wire [63:0] current_word,view_word;
        reg delayed_view_valid;
        rhythm_block_ram #(.WIDTH(64),.ADDRESS_BITS(5),.DEPTH(32)) judge_ram(
            .write_clk(clk),.write_enable(enqueue && rst_n),.write_address({incoming_lane,write_ptr[incoming_lane]}),.write_data({incoming_end,incoming_start[31:0]}),
            .read_clk(clk),.read_address(address),.read_data(current_word));
        rhythm_block_ram #(.WIDTH(64),.ADDRESS_BITS(5),.DEPTH(32)) view_ram(
            .write_clk(clk),.write_enable(enqueue && rst_n),.write_address({incoming_lane,write_ptr[incoming_lane]}),.write_data({incoming_end,incoming_start[31:0]}),
            .read_clk(clk),.read_address({view_lane,view_slot}),.read_data(view_word));
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)delayed_view_valid<=0;else delayed_view_valid<=view_is_valid;
        end
        assign current_start=current_word[31:0];assign current_end=current_word[63:32];
        assign view_start=view_word[31:0];assign view_end=view_word[63:32];assign view_valid=delayed_view_valid;
        // 同步存储模式必须与引擎 SHARED_VIEW 搭配，AUTO 通过串行查询口读取队头。
        assign head_time=128'd0;
    end else begin: distributed_queue
        reg [31:0] starts[0:31],ends[0:31];
        always @(posedge clk)if(enqueue && rst_n)begin
            starts[{incoming_lane,write_ptr[incoming_lane]}]<=incoming_start[31:0];
            ends[{incoming_lane,write_ptr[incoming_lane]}]<=incoming_end;
        end
        assign current_start=starts[address];assign current_end=ends[address];
        assign view_start=starts[{view_lane,view_slot}];assign view_end=ends[{view_lane,view_slot}];assign view_valid=view_is_valid;
        for(g=0;g<4;g=g+1)begin: times
            assign head_time[g*32 +:32]=starts[{g[1:0],read_ptr[g]}];
        end
    end endgenerate
    reg [15:0] resolved;
    reg [19:0] weight;
    // 精确百万分归一化；移位长除法，板级可选 DSP 计算分子，不使用组合除法器。
    // 判定可继续发生，分数按快照计算，若有新结果则自动再算最新快照。
    reg dividing;
    reg [5:0] divide_left;
    reg [35:0] dividend, quotient;
    reg [16:0] remainder;
    reg [19:0] scored_weight, target_weight;
    reg [15:0] divisor;
    wire [17:0] trial={remainder,dividend[35]};
    wire subtract_ok=trial>={2'b00,divisor};
    wire [35:0] next_quotient={quotient[34:0],subtract_ok};
    wire [35:0] numerator;
    generate if(SCORE_DSP)begin: dsp_score
        wire [35:0] low_product;
        reg [18:0] high_product;
        // 一颗 18x18 DSP 处理低位，高两位是四选一常数；覆盖 65535*10 权重。
        EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
            .INPUTFORMAT("UNSIGNED"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
            .OUTPUTREG("DISABLE"),.IMPLEMENT("DSP"),.SRMODE("ASYNC")) multiplier(
            .p(low_product),.a(weight[17:0]),.b(18'd100000),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
            .clk(clk),.rstan(rst_n),.rstbn(rst_n),.rstpdn(rst_n));
        always @*case(weight[19:18])
            0:high_product=19'd0;1:high_product=19'd100000;
            2:high_product=19'd200000;default:high_product=19'd300000;
        endcase
        assign numerator=low_product+{high_product[17:0],18'd0};
    end else begin: lut_score
        wire [35:0] expanded_weight={16'd0,weight};
        assign numerator=(expanded_weight<<16)+(expanded_weight<<15)+(expanded_weight<<10)+(expanded_weight<<9)+(expanded_weight<<7)+(expanded_weight<<5);
    end endgenerate
    assign done=chart_eof && total_notes!=0 && resolved==total_notes && !dividing && scored_weight==weight;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(i=0;i<4;i=i+1)begin read_ptr[i]<=0;write_ptr[i]<=0;used[i]<=0;hold_grade[i]<=0;end
            holding<=0;memory_wait<=1;processing_event<=0;lane<=0;captured_time<=0;captured_press<=0;captured_release<=0;
            result_valid<=0;result_lane<=0;result_grade<=0;perfect_count<=0;good_count<=0;bad_count<=0;miss_count<=0;
            combo<=0;max_combo<=0;resolved<=0;weight<=0;queue_overflow<=0;
            score<=0;dividing<=0;divide_left<=0;dividend<=0;quotient<=0;remainder<=0;scored_weight<=0;target_weight<=0;divisor<=0;
        end else begin
            result_valid<=1'b0;
            if(note_valid && incoming_due && used[incoming_lane]==4'd8 && !(actual_retire && lane==incoming_lane))queue_overflow<=1'b1;
            if(enqueue)write_ptr[incoming_lane]<=write_ptr[incoming_lane]+3'd1;
            for(i=0;i<4;i=i+1)begin
                case({enqueue && incoming_lane==i[1:0],actual_retire && lane==i[1:0]})
                    2'b10:used[i]<=used[i]+4'd1;
                    2'b01:used[i]<=used[i]-4'd1;
                    default:begin end
                endcase
            end
            if(run && !done)begin
                if(accept_event)begin
                    captured_time<=event_time;captured_press<=press_mask;captured_release<=release_mask;
                    lane<=0;memory_wait<=1;processing_event<=1'b1;
                end else if(BLOCK_QUEUE && memory_wait)memory_wait<=0;
                else begin
                    memory_wait<=BLOCK_QUEUE;lane<=lane+2'd1;
                    if(processing_event && lane==2'd3)processing_event<=1'b0;
                    if(begin_hold)begin holding[lane]<=1'b1;hold_grade[lane]<=grade;end
                    if(actual_retire)begin
                        read_ptr[lane]<=read_ptr[lane]+3'd1;holding[lane]<=1'b0;
                        resolved<=resolved+16'd1;result_valid<=1'b1;result_lane<=lane;result_grade<=grade;
                        case(grade)
                            2'd3:begin perfect_count<=perfect_count+16'd1;weight<=weight+20'd10;end
                            2'd2:begin good_count<=good_count+16'd1;weight<=weight+20'd7;end
                            2'd1:begin bad_count<=bad_count+16'd1;weight<=weight+20'd3;end
                            default:miss_count<=miss_count+16'd1;
                        endcase
                        if(grade>=2'd2)begin
                            combo<=combo+16'd1;
                            if(combo>=max_combo)max_combo<=combo+16'd1;
                        end else combo<=0;
                    end
                end
            end
            if(!dividing && weight!=scored_weight && total_notes!=0)begin
                dividing<=1'b1;divide_left<=6'd36;dividend<=numerator;quotient<=0;remainder<=0;
                divisor<=total_notes;target_weight<=weight;
            end else if(dividing)begin
                dividend<={dividend[34:0],1'b0};quotient<=next_quotient;
                if(subtract_ok)remainder<=trial-{2'b00,divisor};else remainder<=trial[16:0];
                divide_left<=divide_left-6'd1;
                if(divide_left==6'd1)begin score<=next_quotient[19:0];scored_weight<=target_weight;dividing<=1'b0;end
            end
        end
    end
endmodule
