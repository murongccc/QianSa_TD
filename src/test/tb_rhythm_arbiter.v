`timescale 1ns/1ps
module tb_rhythm_arbiter;
    reg clk=0,rst=1,breq=1,areq=1,creq=1,urgent=0,valid=0,done=0;
    wire req,bv,av,cv,bd,ad,cd;
    wire [31:0] addr;
    integer i,owner;
    always #5 clk=~clk;
    sd_sector_arbiter #(.ENABLE_CHART(1)) dut(
        .clk(clk),.rst(rst),.bmp_req(breq),.bmp_addr(32'd10),.audio_req(areq),.audio_addr(32'd20),
        .chart_req(creq),.chart_addr(32'd30),.audio_urgent(urgent),.sd_req(req),.sd_addr(addr),
        .sd_valid(valid),.sd_done(done),.bmp_valid(bv),.bmp_done(bd),.audio_valid(av),.audio_done(ad),
        .chart_valid(cv),.chart_done(cd));
    task transfer;
        input integer kind;
        begin
            wait(req);@(negedge clk);
            if(addr!==(kind==0?32'd10:kind==1?32'd20:32'd30))$fatal(1,"fairness/priority failed expected %0d got %0d",kind,addr);
            for(i=0;i<512;i=i+1)begin
                valid=1;#1;
                if({cv,av,bv}!==(kind==0?3'b001:kind==1?3'b010:3'b100))$fatal(1,"multiple/wrong response owner");
                @(negedge clk);
            end
            valid=0;done=1;#1;
            if({cd,ad,bd}!==(kind==0?3'b001:kind==1?3'b010:3'b100))$fatal(1,"wrong end routing");
            @(negedge clk);done=0;
            if(req)$fatal(1,"missing transaction gap");
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        transfer(0);transfer(1);transfer(2);transfer(1);transfer(0);
        urgent=1;transfer(1);transfer(1);transfer(1);
        urgent=0;transfer(2);transfer(1);transfer(0);
        breq=0;areq=0;creq=0;repeat(10)@(negedge clk);
        if(req)$fatal(1,"idle not reached");
        $display("PASS three-client fairness, urgent audio, exclusive response ownership and gaps");$finish;
    end
    initial begin #200000;$fatal(1,"arbiter timeout");end
endmodule
