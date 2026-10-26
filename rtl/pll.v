`timescale 1 ps / 1 ps

//============================================================================
//  DECO Cassette PLL wrapper.
//  outclk_0 = 96.000 MHz (clk_sys) — drives rtl/clock_div.v.
//
//  PLL config:
//    refclk    = 50 MHz  (DE10-Nano)
//    VCO       = 768 MHz  (M_int=15, M_frac=0.36, N=1)
//    outclk_0  = VCO / 8  = 96 MHz  (clk_sys)
//    outclk_1  = VCO / 32 = 24 MHz  (spare)
//    outclk_2  = VCO / 64 = 12 MHz  (spare)
//============================================================================

module pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    // outclk_1 = SDRAM clock; reconfig ports go to sys/pll_cfg (DPS)
    output wire outclk_1,
    output wire locked,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);

    pll_0002 pll_inst (
        .refclk            (refclk),
        .rst               (rst),
        .outclk_0          (outclk_0),
        .outclk_1          (outclk_1),
        .outclk_2          (),
        .locked            (locked),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

endmodule
