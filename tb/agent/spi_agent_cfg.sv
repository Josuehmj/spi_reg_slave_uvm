class spi_agent_cfg extends uvm_object;
    virtual spi_if          vif;
    uvm_active_passive_enum is_active      = UVM_ACTIVE;
    bit                     has_coverage   = 1;

    `uvm_object_utils(spi_agent_cfg)
    function new(string name = "spi_agent_cfg");
        super.new(name);
    endfunction
endclass