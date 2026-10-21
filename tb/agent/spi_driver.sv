class spi_driver extends uvm_driver #(spi_seq_item);
    `uvm_component_utils(spi_driver)

    spi_agent_cfg            cfg;
    virtual spi_if.driver_mp vif;    // modport handle
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Build phase
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(spi_agent_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "spi_agent_cfg not found")
        vif = cfg.vif;
    endfunction

    // Run phase
    task run_phase(uvm_phase phase);
        // Initialize signals in IDLE 
        drive_idle();
        forever begin
            spi_seq_item item;
            seq_item_port.get_next_item(item);
            drive_transaction(item);
            seq_item_port.item_done();
        end
    endtask

    task drive_idle();
        vif.driver_cb.cs_n  <= 1'b1;
        vif.driver_cb.sclk  <= 1'b0;
        vif.driver_cb.mosi  <= 1'b0;
        
        // Wait until the reset is released, then let the DUT stabilize for a few clocks
        wait (vif.rst_n === 1'b1);
        repeat (4) @(vif.driver_cb);
    endtask

    task drive_transaction(spi_seq_item item);
        bit [15:0] tx = {item.rw, item.addr, item.wdata};
        item.rdata = '0;
        vif.driver_cb.cs_n <= 0;
        vif.driver_cb.mosi <= tx[15];
        // Setup time before the first rising edge
        repeat (item.sclk_half) @(vif.driver_cb);
        for (int i = 0; i < item.num_clks; i++) begin
            vif.driver_cb.sclk <= 1;                            // Rising edge
            if (i >= 8 && i < 16)
                item.rdata[15-i] = vif.driver_cb.miso;          // Sample miso
            repeat (item.sclk_half) @(vif.driver_cb);
            vif.driver_cb.sclk <= 0;                            // Falling edge
            vif.driver_cb.mosi <= (i+1 < 16) ? tx[14-i] : 1'b0; // Next bit, changes on the fall
            repeat (item.sclk_half) @(vif.driver_cb);
        end
        vif.driver_cb.cs_n <= 1;
        vif.driver_cb.mosi <= 0;
        repeat (item.cs_gap) @(vif.driver_cb);  // This is to allow the minimum gap testing
    endtask
endclass