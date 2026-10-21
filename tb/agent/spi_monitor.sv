class spi_monitor extends uvm_monitor;
    `uvm_component_utils(spi_monitor)

    spi_agent_cfg             cfg;
    virtual spi_if.monitor_mp vif;    // modport handle
    
    uvm_analysis_port #(spi_seq_item) spi_mon_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Build phase
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        spi_mon_ap = new("spi_mon_ap", this);
        if(!uvm_config_db #(spi_agent_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "spi_agent_cfg not found")
        vif = cfg.vif;
    endfunction

    // Run phase
    task run_phase(uvm_phase phase);
        // wait for the reset to finish before starting monitoring
        @(posedge vif.clk iff vif.rst_n === 1'b1);

        forever begin
            collect_transaction();
        end
    endtask

    task collect_transaction();
        spi_seq_item item;
        bit [15:0]   tx = '0;
        bit [7:0]    rx = '0;
        int unsigned n  = 0;
        bit          prev_sclk;
        
        @(vif.monitor_cb iff vif.monitor_cb.cs_n === 1'b0);   // Frame start
        prev_sclk = vif.monitor_cb.sclk;

        while (vif.monitor_cb.cs_n === 1'b0) begin
            if (vif.monitor_cb.sclk === 1'b1 && prev_sclk === 1'b0) begin
                if (n < 16)
                    tx = {tx[14:0], vif.monitor_cb.mosi};
                if (n >= 8 && n < 16)
                    rx = {rx[6:0], vif.monitor_cb.miso};
                n++;
            end
            prev_sclk = vif.monitor_cb.sclk;
            @(vif.monitor_cb);
        end

        if (n >= 16) begin
            item = spi_seq_item::type_id::create("spi_mon_item");
            item.rw       = tx[15];
            item.addr     = tx[14:8];
            item.wdata    = tx[7:0];
            item.rdata    = rx;
            item.num_clks = n;

            // Log and publication
            `uvm_info("SPI_MON", item.convert2string(), UVM_HIGH)
            spi_mon_ap.write(item);
        end else 
            `uvm_info("SPI_MON", $sformatf("Aborted frame, %0d SCLK edges", n), UVM_HIGH)
    endtask
endclass