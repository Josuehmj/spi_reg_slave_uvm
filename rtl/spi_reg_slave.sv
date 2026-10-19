// -----------------------------------------------------------------------------
// spi_reg_slave
// SPI slave (mode 0) exposing a small register file over SPI.
// Frame = 16 SCLK cycles: {RW, ADDR[6:0], DATA[7:0]}, MSB first.
// See docs/spi_reg_slave_spec.md for the full specification.
// -----------------------------------------------------------------------------
module spi_reg_slave (
  input  logic clk,     // system clock
  input  logic rst_n,   // asynchronous, active-low reset
  // SPI pins (asynchronous to clk, mode 0: CPOL=0, CPHA=0)
  input  logic sclk,
  input  logic cs_n,
  input  logic mosi,
  output logic miso,
  // Interrupt
  output logic irq_o
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam logic [6:0] ADDR_ID        = 7'h00;
  localparam logic [6:0] ADDR_CTRL      = 7'h01;
  localparam logic [6:0] ADDR_THRESH    = 7'h02;
  localparam logic [6:0] ADDR_STATUS    = 7'h03;
  localparam logic [6:0] ADDR_FRAME_CNT = 7'h04;
  localparam logic [6:0] ADDR_SCRATCH   = 7'h05;

  localparam logic [7:0] ID_VALUE       = 8'hA5;
  localparam logic [7:0] THRESH_RESET   = 8'h10;

  // ---------------------------------------------------------------------------
  // Register state (names are the backdoor HDL paths used by the spec)
  // ---------------------------------------------------------------------------
  logic       r_ctrl_en;
  logic       r_ctrl_irq_en;
  logic [7:0] r_thresh;
  logic       r_st_thresh_hit;
  logic       r_st_err;
  logic [7:0] r_frame_cnt;
  logic [7:0] r_scratch;

  // ---------------------------------------------------------------------------
  // Input synchronizers (2 FF) + 1 extra stage for edge detection
  // ---------------------------------------------------------------------------
  logic [2:0] sclk_sr;
  logic [2:0] cs_n_sr;
  logic [1:0] mosi_sr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_sr <= 3'b000;
      cs_n_sr <= 3'b111;
      mosi_sr <= 2'b00;
    end else begin
      sclk_sr <= {sclk_sr[1:0], sclk};
      cs_n_sr <= {cs_n_sr[1:0], cs_n};
      mosi_sr <= {mosi_sr[0],   mosi};
    end
  end

  wire sclk_s    = sclk_sr[1];
  wire cs_n_s    = cs_n_sr[1];
  wire mosi_s    = mosi_sr[1];
  wire sclk_rise =  sclk_sr[1] & ~sclk_sr[2];
  wire sclk_fall = ~sclk_sr[1] &  sclk_sr[2];
  wire cs_rise   =  cs_n_sr[1] & ~cs_n_sr[2];

  // ---------------------------------------------------------------------------
  // Register read mux (explicit always_comb: sensitive to every register)
  // ---------------------------------------------------------------------------
  logic [6:0] cmd_addr;
  logic [7:0] rd_data;

  always_comb begin
    case (cmd_addr)
      ADDR_ID:        rd_data = ID_VALUE;
      ADDR_CTRL:      rd_data = {5'b0, r_ctrl_irq_en, 1'b0, r_ctrl_en};
      ADDR_THRESH:    rd_data = r_thresh;
      ADDR_STATUS:    rd_data = {6'b0, r_st_err, r_st_thresh_hit};
      ADDR_FRAME_CNT: rd_data = r_frame_cnt;
      ADDR_SCRATCH:   rd_data = r_scratch;
      default:        rd_data = 8'h00;
    endcase
  end

  // ---------------------------------------------------------------------------
  // SPI frame shifting
  // ---------------------------------------------------------------------------
  logic [15:0] shift_in;
  logic [4:0]  bit_cnt;     // number of SCLK rising edges seen in this frame (saturates at 16)
  logic        cmd_rw;      // 1 = write
  logic        miso_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_in <= 16'h0000;
      bit_cnt  <= 5'd0;
      cmd_rw   <= 1'b0;
      cmd_addr <= 7'h00;
      miso_r   <= 1'b0;
    end else if (cs_n_s) begin
      // Idle: CS_N deasserted. Frame state is cleared. The frame-end commit
      // below uses the pre-edge value of bit_cnt, so it still sees 16.
      bit_cnt <= 5'd0;
      miso_r  <= 1'b0;
    end else begin
      // Sample MOSI on the rising edge
      if (sclk_rise && bit_cnt < 5'd16) begin
        shift_in <= {shift_in[14:0], mosi_s};
        bit_cnt  <= bit_cnt + 5'd1;
        if (bit_cnt == 5'd7) begin       // 8th bit: command phase complete
          cmd_rw   <= shift_in[6];
          cmd_addr <= {shift_in[5:0], mosi_s};
        end
      end
      // Update MISO on the falling edge (data phase of read frames only)
      if (sclk_fall) begin
        if (bit_cnt >= 5'd8 && bit_cnt < 5'd16 && !cmd_rw)
          miso_r <= rd_data[3'd7 - bit_cnt[2:0]];
        else
          miso_r <= 1'b0;
      end
    end
  end

  assign miso = miso_r;

  // ---------------------------------------------------------------------------
  // Frame-end decode (a frame is valid only if exactly 16 SCLK rising edges
  // were seen while CS_N was low; it commits when CS_N rises)
  // ---------------------------------------------------------------------------
  wire [7:0] wdata      = shift_in[7:0];
  wire       frame_done = cs_rise && (bit_cnt == 5'd16);
  wire       wr_en      = frame_done &&  cmd_rw;
  wire       addr_valid = (cmd_addr <= ADDR_SCRATCH);
  wire       ro_write   = wr_en && (cmd_addr == ADDR_ID || cmd_addr == ADDR_FRAME_CNT);
  wire       bad_access = frame_done && (!addr_valid || ro_write);

  wire       cnt_clr    = wr_en && (cmd_addr == ADDR_CTRL)   && wdata[1];
  wire       hit_clr    = wr_en && (cmd_addr == ADDR_STATUS) && wdata[0];
  wire       err_clr    = wr_en && (cmd_addr == ADDR_STATUS) && wdata[1];

  // Counter uses CTRL.EN as it was BEFORE this frame's write
  wire       cnt_inc    = frame_done && r_ctrl_en && !cnt_clr && (r_frame_cnt != 8'hFF);
  wire       hit_set    = cnt_inc && ((r_frame_cnt + 8'd1) == r_thresh);

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_ctrl_en       <= 1'b0;
      r_ctrl_irq_en   <= 1'b0;
      r_thresh        <= THRESH_RESET;
      r_st_thresh_hit <= 1'b0;
      r_st_err        <= 1'b0;
      r_frame_cnt     <= 8'h00;
      r_scratch       <= 8'h00;
    end else begin
      if (wr_en && cmd_addr == ADDR_CTRL) begin
        r_ctrl_en     <= wdata[0];
        r_ctrl_irq_en <= wdata[2];
      end
      if (wr_en && cmd_addr == ADDR_THRESH)  r_thresh  <= wdata;
      if (wr_en && cmd_addr == ADDR_SCRATCH) r_scratch <= wdata;

      // Frame counter (clear wins over increment)
      if (cnt_clr)      r_frame_cnt <= 8'h00;
      else if (cnt_inc) r_frame_cnt <= r_frame_cnt + 8'd1;

      // Sticky status bits (set wins over W1C clear)
      if (hit_set)      r_st_thresh_hit <= 1'b1;
      else if (hit_clr) r_st_thresh_hit <= 1'b0;

      if (bad_access)   r_st_err <= 1'b1;
      else if (err_clr) r_st_err <= 1'b0;
    end
  end

  assign irq_o = r_ctrl_irq_en & r_st_thresh_hit;

endmodule
