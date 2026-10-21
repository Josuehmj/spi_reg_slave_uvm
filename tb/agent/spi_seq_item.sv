class spi_seq_item extends uvm_sequence_item;
    rand bit       rw;           // 1 = write, 0 = read
    rand bit [6:0] addr;
    rand bit [7:0] wdata;        // Ignored by the DUT on reads

    //Response 
    bit [7:0]      rdata;

    // Frame shape knobs
    rand int unsigned num_clks;    // SCLK cycles in a frame
    rand int unsigned sclk_half;   // SCLK half period, in clk cycles
    rand int unsigned cs_gap;      // cs_n high time after the frame, in clk cycles

    // Constraints
    constraint c_addr {soft addr <= 7'h05;}
    constraint c_len  {soft num_clks == 16;}            // One transaction = one frame
    constraint c_timing {soft sclk_half inside {[5:8]}; 
                         soft cs_gap inside {[4:8]};}  // Spec only mentions minimums, the 8 is arbitrary

    constraint c_bounds {num_clks  inside {[1:32]};
                         sclk_half inside {[1:64]};
                         cs_gap    inside {[1:64]};}

    `uvm_object_utils(spi_seq_item)

    function new(string name = "spi_seq_item");
        super.new(name);
    endfunction

    // Utility methods
    virtual function string convert2string();
        return $sformatf(
            "SPI %s addr=0x%02h wdata=0x%08h rdata=0x%08h num_clks=%0b",
            rw ? "WR" : "RD",
            rw, addr, wdata, rdata, num_clks
        );
    endfunction

    virtual function void do_copy(uvm_object rhs);
        spi_seq_item rhs_;
        if (!$cast(rhs_, rhs))
            `uvm_fatal(get_type_name(), "do_copy: cast failed")
        super.do_copy(rhs);
        rw        = rhs_.rw;
        addr      = rhs_.addr;
        wdata     = rhs_.wdata;
        rdata     = rhs_.rdata;
        num_clks  = rhs_.num_clks;
        sclk_half = rhs_.sclk_half;
        cs_gap    = rhs_.cs_gap;
    endfunction

    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        spi_seq_item rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (super.do_compare(rhs, comparer) &&
                rw       === rhs_.rw              &&
                addr     === rhs_.addr            &&
                wdata    === rhs_.wdata           &&
                rdata    === rhs_.rdata           &&
                num_clks === rhs_.num_clks);
    endfunction
endclass