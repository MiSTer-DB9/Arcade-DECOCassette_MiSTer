// PLAID-2026-10-25: "Fast Load: PLAID" — instant cassette load.
//
// While the load window is open (from reset until the BIOS hands over to the game = first opcode fetch below $F000,
// the same `game_run` the hiscore gate uses), this module answers the BIOS's $E5xx host-port protocol in place of
// the real 8041 + tape, serving 256-byte blocks straight from the cassette BRAM (block N byte k = cas[N*256+k],
// MAME decocass_tape.cpp), and supplies 16x clock enables for the main 6502 (/8) and the audio 6502 (/12).
// The top keeps the real 8041 off the host bus during the window and hands the port back to it at game entry
// (cflyball keeps talking to the 8041 during play). The dongle path is untouched: our DBBOUT/DBBSTS feed
// dongle_mux exactly where the 8041's would, so every dongle type still transforms the data.
//
// Protocol (MAME host transcript, cflyball, 2026-10-25): boot $33,$29 (rewind, wait $E502 BOT/EOT), $33,$2F
// (search EOT); per block $33, $28 -> REQ/ low -> param byte (FF) to $E500 -> 256x (OBF -> read $E500); end $29.
// $E502 = {present/=0, 1, 1, BOT/EOT, ERR/, EOT/, FNO/(1 = busy), REQ/}; DBBSTS = {F1=0, F0, IBF, OBF}.
//
// The mode is latched at reset: switching PLAID on/off during a load restarts the core (`restart`), because the
// real 8041 / BIOS cannot be taken over (or handed back) mid-command. After game entry a change waits for the next
// reset.

module plaid_load (
    input  wire        clk_sys,
    input  wire        reset,           // core reset (incl. ioctl_download); also clears game_run upstream
    input  wire        sel,             // OSD Fast Load == PLAID (and not a tapeless multigame)
    input  wire        game_run,        // 1 once the BIOS has jumped into the game
    output reg         restart = 1'b0,  // OR into the core reset: PLAID toggled during a load
    output wire        active,          // load window with PLAID latched

    output wire        ce_main_fast,    // 16x main 6502 enable (750 kHz -> 12 MHz)
    output wire        ce_audio_fast,   // 16x audio 6502 enable (500 kHz -> 8 MHz)

    // 6502 host port ($E5xx strobes from decocass.v, one clk_sys pulse per access)
    input  wire        cpu_re,
    input  wire        cpu_we,
    input  wire [7:0]  cpu_addr_lo,
    input  wire [7:0]  cpu_dout,

    // cassette BRAM read port (top muxes it onto the tape_streamer's port while active)
    output wire [15:0] cas_addr,
    input  wire [7:0]  cas_q,

    // replacements for the 8041's host-side outputs
    output reg  [7:0]  dbb_dout = 8'h00,
    output wire [7:0]  dbb_sts,
    output wire [7:0]  e502
);

localparam [15:0] CMD_DLY    = 16'd16384;  // ~170 us "8041 busy" per command (first BIOS poll still sees busy)
localparam [15:0] PARAM_DLY  = 16'd64;
localparam [15:0] SETTLE_DLY = 16'd128;    // type-1 dongle PROM address follows DBBOUT -> let the SDRAM fetch land
localparam [15:0] BLKEND_DLY = 16'd1024;

localparam [2:0] S_IDLE = 3'd0, S_CMD = 3'd1, S_WAITPARAM = 3'd2, S_PARAM = 3'd3,
                 S_FETCH = 3'd4, S_SETTLE = 3'd5, S_READY = 3'd6, S_BLKEND = 3'd7;

// ---- mode latch + restart -------------------------------------------------------------------------------------
reg        mode = 1'b0;
reg [15:0] restart_cnt = 16'd0;
always @(posedge clk_sys) begin
	if (reset) mode <= sel;
	if (restart_cnt != 16'd0) begin
		restart_cnt <= restart_cnt - 16'd1;
		restart     <= (restart_cnt != 16'd1);
	end else if (!reset && !game_run && sel != mode) begin
		restart_cnt <= 16'hFFFF;              // ~0.7 ms reset pulse
		restart     <= 1'b1;
	end
end
assign active = mode & ~game_run;

// ---- 16x clock enables ----------------------------------------------------------------------------------------
reg [2:0] div8  = 3'd0;
reg [3:0] div12 = 4'd0;
always @(posedge clk_sys) begin
	div8  <= div8 + 3'd1;
	div12 <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
end
assign ce_main_fast  = (div8 == 3'd7);
assign ce_audio_fast = (div12 == 4'd11);

// ---- host-port model ------------------------------------------------------------------------------------------
reg  [2:0]  st = S_IDLE;
reg  [7:0]  cmd = 8'h00;
reg  [7:0]  blk = 8'h00;
reg  [8:0]  k = 9'd0;
reg  [15:0] dly = 16'd0;
reg         obf = 1'b0, ibf = 1'b0, f0 = 1'b0, busy = 1'b0, req_n = 1'b1, at_bot = 1'b1;

wire wr_cmd  = cpu_we && !cpu_addr_lo[1] &&  cpu_addr_lo[0];   // $E5x1 write
wire wr_data = cpu_we && !cpu_addr_lo[1] && !cpu_addr_lo[0];   // $E5x0 write
wire rd_data = cpu_re && !cpu_addr_lo[1] && !cpu_addr_lo[0];   // $E5x0 read

assign cas_addr = {blk, k[7:0]};
assign dbb_sts  = {4'b0000, 1'b0, f0, ibf, obf};
assign e502     = {1'b0, 1'b1, 1'b1, at_bot, 1'b1, 1'b1, busy, req_n};

always @(posedge clk_sys) begin
	if (reset) begin
		st <= S_IDLE; blk <= 8'h00; k <= 9'd0; dly <= 16'd0; dbb_dout <= 8'h00;
		obf <= 1'b0; ibf <= 1'b0; f0 <= 1'b0; busy <= 1'b0; req_n <= 1'b1; at_bot <= 1'b1;
	end else begin
		if (dly != 16'd0) dly <= dly - 16'd1;

		if (wr_cmd) begin                     // a new command always wins (the BIOS only sends one when idle)
			cmd <= cpu_dout; ibf <= 1'b1; busy <= 1'b1; obf <= 1'b0; dly <= CMD_DLY; st <= S_CMD;
		end else begin
			case (st)
			S_CMD: if (dly == 16'd0) begin
				ibf <= 1'b0;
				case (cmd)
				8'h28:   begin f0 <= 1'b1; req_n <= 1'b0; st <= S_WAITPARAM; end   // read_block_b: ask for the param
				8'h29:   begin blk <= 8'h00; at_bot <= 1'b1; busy <= 1'b0; st <= S_IDLE; end   // rewind_fast
				8'h2F:   begin at_bot <= 1'b0; busy <= 1'b0; st <= S_IDLE; end   // search_eot (ends off BOT, like MAME)
				default: begin busy <= 1'b0; st <= S_IDLE; end                    // $33 flag_status_report etc.
				endcase
			end
			S_WAITPARAM: if (wr_data) begin ibf <= 1'b1; dly <= PARAM_DLY; st <= S_PARAM; end
			S_PARAM: if (dly == 16'd0) begin
				ibf <= 1'b0; req_n <= 1'b1; at_bot <= 1'b0; k <= 9'd0; dly <= 16'd3; st <= S_FETCH;
			end
			S_FETCH: if (dly == 16'd0) begin  // cas_addr has been stable >= 2 clocks: BRAM q is valid
				dbb_dout <= cas_q; dly <= SETTLE_DLY; st <= S_SETTLE;
			end
			S_SETTLE: if (dly == 16'd0) begin obf <= 1'b1; st <= S_READY; end
			S_READY: if (rd_data) begin
				obf <= 1'b0;
				if (k == 9'd255) begin dly <= BLKEND_DLY; st <= S_BLKEND; end
				else begin k <= k + 9'd1; dly <= 16'd3; st <= S_FETCH; end
			end
			S_BLKEND: if (dly == 16'd0) begin
				f0 <= 1'b0; busy <= 1'b0; blk <= blk + 8'h01; k <= 9'd0; st <= S_IDLE;
			end
			default: ;
			endcase
		end
	end
end

endmodule
