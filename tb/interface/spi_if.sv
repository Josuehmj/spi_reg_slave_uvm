`timescale 1ns/1ps

interface spi_if (input logic clk, input logic rst_n);
    logic sclk;
    logic cs_n;
    logic mosi;
    logic miso;
    logic irq_o;

    // Driver clocking block
    // irq_o is not included because the driver never needs it
    clocking driver_cb @(posedge clk);
        input miso;

        output sclk;
        output cs_n;
        output mosi;
    endclocking

    // Monitor clocking block
    clocking monitor_cb @(posedge clk);
        input sclk;
        input cs_n;
        input mosi;
        input miso;
        input irq_o;
    endclocking

    // Modports
    modport driver_mp  (clocking driver_cb, input clk, input rst_n);
    modport monitor_mp (clocking monitor_cb, input clk, input rst_n);
endinterface