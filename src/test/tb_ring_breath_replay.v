`timescale 1ns/1ps
// 重放已验证的 FFT 柱序列，记录实际 RTL 的逐帧呼吸半径。
module tb_ring_breath_replay;
reg clk=0,rst=1,frame_start=0;
reg [639:0] bars=0;
wire pixel_on;
wire [23:0] pixel_rgb;
reg [2047:0] input_path,output_path;
integer in_file,out_file,result,frame_count,i,expected_peak;
integer old_radius=90;
always #5 clk=~clk;
ring_spectrum_renderer #(.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.frame_start(frame_start),.pixel_x(10'd417),.pixel_y(10'd240),
    .bars(bars),.bands(256'd0),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));
initial begin
    if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("CSV=%s",output_path))
        $fatal(1,"missing replay paths");
    in_file=$fopen(input_path,"r");out_file=$fopen(output_path,"w");
    if(!in_file || !out_file) $fatal(1,"cannot open replay files");
    $fwrite(out_file,"frame,peak,envelope,radius\n");
    repeat(3) @(negedge clk);rst=0;frame_count=0;
    while(!$feof(in_file)) begin
        result=$fscanf(in_file,"%h\n",bars);
        if(result==1) begin
            expected_peak=0;
            for(i=0;i<80;i=i+1)
                if(bars[i*8 +:8]>expected_peak) expected_peak=bars[i*8 +:8];
            @(negedge clk);frame_start=1;
            @(negedge clk);frame_start=0;old_radius=dut.base_radius;
            repeat(85) begin
                @(negedge clk);
                if(dut.base_radius!=old_radius) $fatal(1,"radius changed during frame");
            end
            if(dut.g_breath.pending_peak!=expected_peak)
                $fatal(1,"music peak scan mismatch frame=%0d",frame_count);
            if(dut.base_radius<90 || dut.base_radius>110)
                $fatal(1,"radius exceeded bounds");
            if(bars==0 && pixel_on) $fatal(1,"silent music frame visible");
            $fwrite(out_file,"%0d,%0d,%0d,%0d\n",frame_count,expected_peak,
                    dut.g_breath.peak_envelope,dut.base_radius);
            frame_count=frame_count+1;
        end
    end
    if(frame_count<100) $fatal(1,"insufficient music frames");
    $fclose(in_file);$fclose(out_file);
    $display("PASS breathing music replay: %0d frames",frame_count);$finish;
end
endmodule
