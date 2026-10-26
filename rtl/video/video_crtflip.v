// CRTFLIP-2026-10-25: CRT Flip mechanism (180-degree mirror inside the core, so analog and HDMI both flip).
//
// Vertical: the top feeds the video layers vcnt_v = 254 - vcnt (render the mirrored source row for the NEXT line;
// visible lines 8..247 are symmetric in 0..255, so 255 - v mirrors the visible area exactly).
// Horizontal: this module captures each displayed line (the delayed-hblank window = exactly the 256 pixels shown)
// and plays it back mirrored on the next line. Every DECO layer is a pure function of (hcnt, vcnt), so each axis
// gets exactly one mirror (placement + pixel order) for all layers at once.

module video_crtflip (
    input  wire        clk_sys,
    input  wire        ce_pix,
    input  wire        en,
    input  wire        hblank,        // blank aligned with rgb_in (video_hblank_d)
    input  wire [11:0] rgb_in,
    output wire [11:0] rgb_out
);

reg  [11:0] mem [0:511];             // two 256-pixel lines (ping-pong on sel)
reg  [7:0]  x = 8'd0;
reg         sel = 1'b0, hbl_r = 1'b1;
reg  [11:0] q;

always @(posedge clk_sys) begin
	if (ce_pix) begin
		hbl_r <= hblank;
		if (hblank) x <= 8'd0;
		else begin
			mem[{sel, x}] <= rgb_in;
			x <= x + 8'd1;
		end
		if (hblank && !hbl_r) sel <= ~sel;   // line just ended: play it back next line
	end
	q <= mem[{~sel, ~x}];                    // 255 - x of the previous line; settles long before the next ce_pix
end

assign rgb_out = en ? q : rgb_in;

endmodule
