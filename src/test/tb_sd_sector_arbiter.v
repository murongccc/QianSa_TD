`timescale 1ns/1ps
module tb_sd_sector_arbiter;
    reg clk=0,rst=1,breq=0,areq=0,valid=0,done=0;
    reg [31:0] ba=10,aa=20;
    wire req,bv,bd,av,ad; wire [31:0] addr;
    integer bbytes=0,abytes=0,bends=0,aends=0,j;
    always #5 clk=~clk;
    sd_sector_arbiter dut(.clk(clk),.rst(rst),.bmp_req(breq),.bmp_addr(ba),
        .audio_req(areq),.audio_addr(aa),.sd_req(req),.sd_addr(addr),
        .sd_valid(valid),.sd_done(done),.bmp_valid(bv),.bmp_done(bd),
        .audio_valid(av),.audio_done(ad));
    always @(posedge clk) if(!rst) begin
        if(bv)bbytes=bbytes+1;if(av)abytes=abytes+1;
        if(bd)bends=bends+1;if(ad)aends=aends+1;
        if((bv&&av)||(bd&&ad))$fatal(1,"response broadcast to both readers");
    end
    task transfer;
        input [31:0] expected_addr; input audio_owner;
        begin
            wait(req); @(negedge clk);
            if(addr!==expected_addr)$fatal(1,"wrong arbitration address %d",addr);
            for(j=0;j<512;j=j+1)begin
                valid=1;
                // Even a client withdrawing/changing its request cannot
                // alter the accepted transaction's address/return routing.
                if(j==4 && !audio_owner)begin breq=0;ba=11;end
                if(addr!==expected_addr)$fatal(1,"address changed in flight");
                if(audio_owner ? !av : !bv)begin
                    #1;
                    if(audio_owner ? !av : !bv)$fatal(1,"return owner changed");
                end
                @(negedge clk);
            end
            valid=0;done=1;
            @(negedge clk);done=0;
            if(req)$fatal(1,"request not retired after end");
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;breq=1;areq=1;
        transfer(10,0); breq=1;
        transfer(20,1); aa=21;
        transfer(11,0);
        if(bbytes!=1024||abytes!=512||bends!=2||aends!=1)$fatal(1,"lost bytes or completion");
        $display("PASS arbiter: full sectors, request withdrawal, held requests, fairness, end routing");$finish;
    end
    initial begin #100000; $fatal(1,"arbiter timeout");end
endmodule
