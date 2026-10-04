`timescale 1ns/1ps
// 两种返回模式逐拍计分；请求中途撤回、地址变动不能改变扇区归属。
module tb_sd_registered_response;
    parameter integer REGISTER_RESPONSE=0;
    reg clk=0,rst=1,breq=1,areq=1,creq=1,urgent=0,valid=0,done=0;
    reg [31:0] ba=10,aa=20,ca=30;
    reg [7:0] data=0;
    wire req,bv,av,cv,bd,ad,cd,busy;
    wire [7:0] returned;
    wire [31:0] addr;
    integer owner=0,count=0,ends=0,i;
    reg [2:0] expected_flags;
    always #5 clk=~clk;
    sd_sector_arbiter #(.ENABLE_CHART(1),.REGISTER_RESPONSE(REGISTER_RESPONSE)) dut(
        .clk(clk),.rst(rst),.bmp_req(breq),.bmp_addr(ba),.audio_req(areq),.audio_addr(aa),
        .chart_req(creq),.chart_addr(ca),.audio_urgent(urgent),.sd_req(req),.sd_addr(addr),
        .sd_data(data),.response_data(returned),.response_busy(busy),
        .sd_valid(valid),.sd_done(done),.bmp_valid(bv),.bmp_done(bd),
        .audio_valid(av),.audio_done(ad),.chart_valid(cv),.chart_done(cd));
    always @(posedge clk)if(!rst)begin
        expected_flags=owner==0 ? 3'b001 : owner==1 ? 3'b010 : 3'b100;
        if(|{cv,av,bv})begin
            if({cv,av,bv}!==expected_flags || returned!==(count[7:0]^8'ha5))
                $fatal(1,"wrong response owner or byte at %0d",count);
            count=count+1;
        end
        if(|{cd,ad,bd})begin
            if({cd,ad,bd}!==expected_flags || count!=512 || !busy)
                $fatal(1,"end before complete sector/drain");
            ends=ends+1;
        end
    end
    task transfer;
        input integer kind;
        input withdraw;
        input together;
        reg [31:0] expected_address;
        begin
            owner=kind;count=0;ends=0;
            expected_address=kind==0 ? ba : kind==1 ? aa : ca;
            wait(req);@(negedge clk);
            if(addr!==expected_address)$fatal(1,"fairness or stale address %d",addr);
            for(i=0;i<512;i=i+1)begin
                valid=1;data=i[7:0]^8'ha5;done=together && i==511;
                if(withdraw && i==1)begin breq=0;areq=0;creq=0;ba=ba+1;aa=aa+1;ca=ca+1;end
                if(addr!==expected_address)$fatal(1,"in flight address changed");
                @(negedge clk);
            end
            valid=0;done=!together;
            @(negedge clk);done=0;
            // 注册返回的尾拍必须在下一请求之前被客户端消费。
            if(!together)@(negedge clk);
            if(count!=512 || ends!=1)$fatal(1,"sector bytes/end count %d %d",count,ends);
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        transfer(0,0,1);transfer(1,0,0);transfer(2,0,1);transfer(1,0,1);
        urgent=1;transfer(1,0,1);transfer(1,0,0);
        urgent=0;transfer(0,1,1);
        repeat(5)@(negedge clk);if(busy || req)$fatal(1,"cancel did not drain");
        creq=1;transfer(2,1,0);
        repeat(5)@(negedge clk);if(busy || req)$fatal(1,"restart did not drain");
        $display("PASS SD response mode %d: full sectors, exclusive owner, changed requests, priority, drain",REGISTER_RESPONSE);
        $finish;
    end
    initial begin #100000;$fatal(1,"registered SD timeout");end
endmodule
