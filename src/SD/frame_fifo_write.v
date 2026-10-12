`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter BURST_COUNT_BITS       = ADDR_BITS,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input                            refresh_hold,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[ADDR_BITS - 1:0]           write_addr_4,               // data write module write request base address 4, used when write_addr_index = 4
	input[2:0]                       write_addr_index,           // select valid base address from write_addr_0 through write_addr_4
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_v_flip,
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      rdusedw                     // from fifo read used words
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_NEXT_ADDR_OFFSET  = (FRAME_HEIGHT - 2) * FRAME_WIDTH;

function integer bits_required;
    input integer value;
    integer remaining;
    begin
        remaining = value - 1;
        bits_required = 0;
        while (remaining > 0) begin
            bits_required = bits_required + 1;
            remaining = remaining >> 1;
        end
        if (bits_required == 0)
            bits_required = 1;
    end
endfunction
localparam integer X_BITS = bits_required(FRAME_WIDTH);

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[BURST_COUNT_BITS - 1:0]         write_burst_cnt;             // 已完成的 burst 数
wire [ADDR_BITS - 1:0]              write_word_count;            // 换算为字数，用于原有长度比较
reg[2:0]                            write_addr_index_d0;
reg[2:0]                            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [ADDR_BITS - 1:0]                next_line_addr;
reg [X_BITS - 1:0]                   wr_x;                       // current x position in one input row
reg                                  wr_line_last;               // 当前写入是否为本行最后一个像素
reg [ADDR_BITS - 1:0]                selected_write_addr;
reg                                  selected_write_addr_valid;
reg                                    write_v_flip_latch;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

wire into_burst;
reg  into_burst_d;
wire [BURST_BITS:0] burst_progress;
assign write_word_count = write_burst_cnt * BURST_SIZE;
assign burst_progress = {1'b0, burst_cnt} + App_wr_en;
assign into_burst = (((write_len_latch <= (rdusedw + write_word_count)) || (rdusedw >= BURST_SIZE)) && ~App_rd_busy);//当rd在突发时不会进入burst

always @* begin
    selected_write_addr = {ADDR_BITS{1'b0}};
    selected_write_addr_valid = 1'b1;
    case (write_addr_index_d1)
        3'd0: selected_write_addr = write_addr_0;
        3'd1: selected_write_addr = write_addr_1;
        3'd2: selected_write_addr = write_addr_2;
        3'd3: selected_write_addr = write_addr_3;
        3'd4: selected_write_addr = write_addr_4;
        default: selected_write_addr_valid = 1'b0;
    endcase
end

// rdusedw crosses from the FIFO read side.  Register the completed burst
// decision before it reaches the write state machine to cut the long
// pointer/comparator/decode timing path.
always @(posedge mem_clk or posedge rst) begin
    if (rst)
        into_burst_d <= 1'b0;
    else
        into_burst_d <= into_burst;
end

assign App_wr_addr = {App_wr_addr_r[ADDR_BITS - 1:0]};
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst_d));//在突发，或者将要突发，则显示busy
assign wr_burst_finish = (burst_cnt >= BURST_SIZE);
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            //write finish at state 'S_END'
assign App_wr_en = App_wr_en_d0;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  3'b000;
		write_addr_index_d1    <=  3'b000;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		next_line_addr <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= {X_BITS{1'b0}};
		wr_line_last <= (FRAME_WIDTH == 1);
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= {X_BITS{1'b0}};
				wr_line_last <= (FRAME_WIDTH == 1);
				if (selected_write_addr_valid)
					begin
						App_wr_addr_r <= selected_write_addr +
						                 (write_v_flip_latch ? VFLIP_FIRST_ADDR_OFFSET : {ADDR_BITS{1'b0}});
						next_line_addr <= selected_write_addr + VFLIP_NEXT_ADDR_OFFSET;
					end
			end
		else if(App_wr_en)
			begin
				if(write_v_flip_latch)
				begin
					if(wr_line_last)
					begin
						wr_x <= {X_BITS{1'b0}};
						wr_line_last <= (FRAME_WIDTH == 1);
						App_wr_addr_r <= next_line_addr;
						next_line_addr <= next_line_addr - FRAME_WIDTH;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						wr_line_last <= (wr_x == FRAME_WIDTH - 2);
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
			else
				App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && burst_progress < BURST_SIZE && (burst_progress + write_word_count < write_len_latch))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		write_v_flip_latch <= WRITE_V_FLIP;
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_burst_cnt <= {BURST_COUNT_BITS{1'b0}};
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
					write_v_flip_latch <= write_v_flip;
				end
				// 帧进度清零
				write_burst_cnt <= {BURST_COUNT_BITS{1'b0}};
			end
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// FIFO 数据就绪且读侧空闲时才可发起写 burst；刷新或控制器忙时必须让出 SDRAM。
			else if(into_burst_d && !Sdr_init_ref_vld && !Sdr_busy && !refresh_hold)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				//burst finish
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					// 一个完整 burst 已写出
					write_burst_cnt <= write_burst_cnt + 1'b1;
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(write_word_count < write_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
