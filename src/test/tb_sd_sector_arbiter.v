`timescale 1ns/1ps
module tb_sd_sector_arbiter;
    reg clk=0,rst=1,breq=0,areq=0,urgent=0,valid=0,done=0;
    reg [31:0] ba=10,aa=20;
    wire req,bv,bd,av,ad; wire [31:0] addr;
    integer bbytes=0,abytes=0,bends=0,aends=0,j;
    always #5 clk=~clk;
    sd_sector_arbiter dut(.clk(clk),.rst(rst),.bmp_req(breq),.bmp_addr(ba),
        .audio_req(areq),.audio_addr(aa),.audio_urgent(urgent),.sd_req(req),.sd_addr(addr),
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
        // Make audio the previous owner.  With both clients requesting, the
        // ordinary fairness rule would choose BMP; an urgent PCM reservoir
        // must override that choice for the next complete sector.
        breq=0; areq=1; urgent=0;
        transfer(21,1);
        breq=1; ba=22; areq=1; aa=23; urgent=1;
        transfer(23,1);
        if(bbytes!=1024||abytes!=1536||bends!=2||aends!=3)$fatal(1,"lost bytes, completion, or urgent-audio priority");
        $display("PASS arbiter: full sectors, fairness, urgent audio priority, and end routing");$finish;
    end
    initial begin #100000; $fatal(1,"arbiter timeout");end
endmodule
