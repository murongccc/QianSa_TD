`timescale 1ns/1ps
// 与参考浮点递推比较，覆盖速度上限、小幅度减 1、立即上升与原始峰值呼吸。
module tb_reference_dynamics;
reg clk=0,rst=1;
wire [639:0] bars;
wire [7:0] breath_radius;
integer n,speed,expected_speed,expected_m_q8,expected_offset,argument_q8;
real magnitude,expected_m;
always #5 clk=~clk;
reference_fft_spectrum dut(.bars_read_address(7'd0),.bars_read_data(),.bars_read_valid(),.bars_active(),
    .clk(clk),.rst(rst),.sample_valid(1'b0),.sample_pcm(24'd0),
    .frame_start(1'b0),.bars(bars),.breath_radius(breath_radius));
initial begin
    repeat(3) @(negedge clk);rst=0;wait(dut.state==0);
    // 仅驱动闲置时的算术操作数；没有伪造 FFT 结果或跳过频率测试。
    magnitude=109.375;speed=0;
    for(n=0;n<60;n=n+1) begin
        @(negedge clk);dut.history_q={speed[4:0],19'd0};
        dut.history_q[18:0]=$rtoi(magnitude*256);dut.sqrt_root=0;
        if(magnitude-speed>0) expected_m=magnitude-speed;
        else expected_m=magnitude-1;
        if(expected_m<0) expected_m=0;
        expected_m_q8=$rtoi(expected_m*256);
        expected_speed=(speed<20)?speed+1:20;
        #1;
        if(dut.smooth_magnitude!==expected_m_q8[18:0] || dut.next_fall_speed!==expected_speed[4:0])
            $fatal(1,"gravity recurrence mismatch update=%0d",n);
        magnitude=expected_m;speed=expected_speed;
    end
    if(magnitude!=0) $fatal(1,"gravity tail failed to reach zero");
    @(negedge clk);dut.history_q={5'd20,19'd2560};dut.sqrt_root=0;
    #1;if(dut.smooth_magnitude!==19'd2304) $fatal(1,"reference subtract-one branch lost");
    @(negedge clk);dut.history_q={5'd20,19'd256};dut.sqrt_root=16'd2000;
    #1;if(dut.smooth_magnitude!==19'd14000 || dut.next_fall_speed!==5'd0)
        $fatal(1,"rise did not immediately follow raw FFT/reset speed");
    for(n=0;n<=458745;n=n+7) begin
        expected_offset=$rtoi(3.0*$ln(1.0+n/256.0)/$ln(2.0)+1.0e-9);
        if(expected_offset>20) expected_offset=20;
        if(dut.radius_offset(n[18:0])!==expected_offset[4:0])
            $fatal(1,"raw amplitude breathing curve mismatch q8=%0d",n);
    end
    @(negedge clk);dut.raw_peak=19'd12345;dut.peak_envelope=19'd54321;
    #1;
    if(dut.next_envelope!==19'd20740) $fatal(1,"exact 0.8/0.2 mix mismatch");
    @(negedge clk);dut.raw_peak=19'd458745;dut.peak_envelope=19'd458745;
    #1;if(dut.next_envelope!==19'd458745) $fatal(1,"raw peak mix overflow");
    $display("PASS reference dynamics: floating gravity recurrence, zero clamp, immediate rise, raw log radius and exact 4/5 mix");
    $finish;
end
endmodule
