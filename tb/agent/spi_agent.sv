class spi_agent extends uvm_agent;
    `uvm_component_utils(spi_agent)

    spi_agent_cfg cfg;

    // Components
    spi_sequencer sequencer;
    spi_driver    driver;
    spi_monitor   monitor;

    // Analysis port - exposed for connections to the scoreboard and coverage collector
    uvm_analysis_port #(spi_seq_item) spi_mon_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Build phase
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(spi_agent_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "spi_agent_cfg not found")
        is_active = cfg.is_active;
        spi_mon_ap = new("spi_mon_ap", this);
        if (get_is_active() == UVM_ACTIVE) begin
            sequencer = spi_sequencer::type_id::create("sequencer", this);
            driver    = spi_driver::type_id::create("driver", this);
        end
        monitor = spi_monitor::type_id::create("monitor", this);
    endfunction

    // Connect phase - connect the driver to the sequencer and expose spi_mon_ap
    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
        monitor.spi_mon_ap.connect(spi_mon_ap);
    endfunction
endclass