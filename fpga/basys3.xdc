## ============================================================================
## Basys 3 Constraints for fpga_top
## ============================================================================

## ---- 100 MHz Clock ----
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports {clk_100mhz}];
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports {clk_100mhz}];

## ---- USB-UART ----
set_property -dict { PACKAGE_PIN B18  IOSTANDARD LVCMOS33 } [get_ports {uart_rxd}];
set_property -dict { PACKAGE_PIN A18  IOSTANDARD LVCMOS33 } [get_ports {uart_txd}];

## ---- Centre Push-Button (active-high) ----
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports {btnC}];

## ---- LEDs ----
set_property -dict { PACKAGE_PIN U16  IOSTANDARD LVCMOS33 } [get_ports {led[0]}];
set_property -dict { PACKAGE_PIN E19  IOSTANDARD LVCMOS33 } [get_ports {led[1]}];
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports {led[2]}];
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports {led[3]}];
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports {led[4]}];
set_property -dict { PACKAGE_PIN U15  IOSTANDARD LVCMOS33 } [get_ports {led[5]}];
set_property -dict { PACKAGE_PIN U14  IOSTANDARD LVCMOS33 } [get_ports {led[6]}];
set_property -dict { PACKAGE_PIN V14  IOSTANDARD LVCMOS33 } [get_ports {led[7]}];
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33 } [get_ports {led[8]}];
set_property -dict { PACKAGE_PIN V3   IOSTANDARD LVCMOS33 } [get_ports {led[9]}];
set_property -dict { PACKAGE_PIN W3   IOSTANDARD LVCMOS33 } [get_ports {led[10]}];
set_property -dict { PACKAGE_PIN U3   IOSTANDARD LVCMOS33 } [get_ports {led[11]}];
set_property -dict { PACKAGE_PIN P3   IOSTANDARD LVCMOS33 } [get_ports {led[12]}];
set_property -dict { PACKAGE_PIN N3   IOSTANDARD LVCMOS33 } [get_ports {led[13]}];
set_property -dict { PACKAGE_PIN P1   IOSTANDARD LVCMOS33 } [get_ports {led[14]}];
set_property -dict { PACKAGE_PIN L1   IOSTANDARD LVCMOS33 } [get_ports {led[15]}];

## ---- BUFGCE gated clock: tell Vivado not to worry about the
##      generated clock on the design_clk net ----
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets design_clk];

## ---- Configuration ----
set_property CONFIG_VOLTAGE 3.3 [current_design];
set_property CFGBVS VCCO [current_design];
