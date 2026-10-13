package mini.foo

import chisel3._
import chisel3.util._
import qdma._
import hbm._
import cmac._
import common._
import common.storage._
import common.axi._
import qdma.examples._
import common.partialReconfig.AlveoStaticIO
import mini.foo._
import mini.core._
import mini.junctions._


class Foo extends Module{
	override val desiredName = "AlveoDynamicTop"
    val io = IO(Flipped(new AlveoStaticIO(
        VIVADO_VERSION = "202501",
		QDMA_PCIE_WIDTH = 16, 
		QDMA_SLAVE_BRIDGE = false, 
		QDMA_AXI_BRIDGE = true,
		ENABLE_CMAC_1 = true,
		ENABLE_CMAC_2 = true
    )))

	val sys_156M_0_p = IO(Input(Clock()))
    val sys_156M_0_n = IO(Input(Clock()))


	dontTouch(io)
	val cmac = Module(new CMACTop())
    cmac.cmac0_pin <> io.cmacPin.get
	cmac.cmac1_pin <> io.cmacPin2.get

	val sys_156M_clk = IBUFDS(
        sys_156M_0_p,
        sys_156M_0_n
    )
	cmac.sys_clk := sys_156M_clk

	val userClk  	= Wire(Clock())
	val userRstn 	= Wire(Bool())
    
	userClk		:= clock		// 这个就是 MMC 分频之后的
	userRstn	:= ~reset.asBool


	// HBM 已移除（去掉 HBM_DRIVER/HBMBlackBox 依赖）
	

	// 实例化 QDMA 模块
	val qdma = Module(new QDMADynamic(
		VIVADO_VERSION		= "202501",
		PCIE_WIDTH			= 16,
		SLAVE_BRIDGE		= false,
		BRIDGE_BAR_SCALE	= "Megabytes",
		BRIDGE_BAR_SIZE 	= 4
	))

	ToZero(qdma.io.reg_status)

	qdma.io.qdma_port	<> io.qdma
	qdma.io.user_clk	:= userClk
	qdma.io.user_arstn	:= ((~reset.asBool & ~qdma.io.reg_control(0)(0)).asClock).asBool

	//C2H默认驱动，H2C则由hotloading驱动
	// qdma.io.h2c_data.ready	:= 0.U
	qdma.io.c2h_data.valid	:= 0.U
	qdma.io.c2h_data.bits	:= 0.U.asTypeOf(new C2H_DATA)

	// qdma.io.h2c_cmd.valid	:= 0.U
	// qdma.io.h2c_cmd.bits	:= 0.U.asTypeOf(new H2C_CMD)
	qdma.io.c2h_cmd.valid	:= 0.U
	qdma.io.c2h_cmd.bits	:= 0.U.asTypeOf(new C2H_CMD)
	
	qdma.io.axib := DontCare

	val reg_control = qdma.io.reg_control
	val reg_status = qdma.io.reg_status
	val qdma_h2c_cmd = qdma.io.h2c_cmd
	val qdma_h2c_data = qdma.io.h2c_data
	val qdma_c2h_cmd = qdma.io.c2h_cmd
	val qdma_c2h_data = qdma.io.c2h_data

	val h2c = withClockAndReset(userClk, !qdma.io.user_arstn){ Module(new H2CWithAXI()) }
	// h2c.io.h2c_cmd		<> qdma_h2c_cmd
	// h2c.io.h2c_data		<> qdma_h2c_data

	val c2h = withClockAndReset(userClk, !qdma.io.user_arstn){ Module(new C2HWithAXI()) }
	// c2h.io.c2h_cmd		<> qdma_c2h_cmd
	// c2h.io.c2h_data		<> qdma_c2h_data
	// h2c/c2h 的 QDMA 命令通道已改由 hotloading/直连，未用 ready 置 DontCare
	h2c.io.h2c_cmd.ready := DontCare
	c2h.io.c2h_cmd.ready := DontCare


	h2c.io.hbmCtrlAw.ready := DontCare
	c2h.io.hbmCtrlAr.ready := DontCare
	//c2h_data is generaued by QDMADynamic
	// qdma_c2h_data.ready := DontCare
	val count_send_word_h2c	= RegInit(UInt(32.W),0.U)
	val count_send_word_c2h	= RegInit(UInt(32.W),0.U)
	when(qdma_h2c_data.fire){
		count_send_word_h2c			:= count_send_word_h2c + 1.U
	}
	when(qdma_c2h_data.fire){
		count_send_word_c2h			:= count_send_word_c2h + 1.U
	}
	h2c.io.cur_word 	 := count_send_word_h2c
	c2h.io.cur_word 	 := count_send_word_c2h
	

	h2c.io.start_addr	:= Cat(reg_control(100), reg_control(101))
	h2c.io.length		:= reg_control(102)
	h2c.io.offset		:= reg_control(103)
	h2c.io.sop			:= reg_control(104)
	h2c.io.eop			:= reg_control(105)
	h2c.io.start		:= reg_control(106)
	h2c.io.total_words	:= reg_control(107)
	h2c.io.total_qs		:= reg_control(108)
	h2c.io.total_cmds	:= reg_control(109)
	h2c.io.range		:= reg_control(110)
	h2c.io.range_words	:= reg_control(111)
	h2c.io.is_seq		:= reg_control(112)
	h2c.io.target_addr	:= reg_control(114)

	for(i <- 0 until 16){
		h2c.io.count_word(i*32+31,i*32)	<> reg_status(102+i)
	}
	h2c.io.count_err	<> reg_status(100)
	h2c.io.count_time	<> reg_status(101)

	c2h.io.start_addr		:= Cat(reg_control(200), reg_control(201))
	c2h.io.length			:= reg_control(202)
	c2h.io.offset			:= reg_control(203)
	c2h.io.start			:= reg_control(204)
	c2h.io.total_words		:= reg_control(205)
	c2h.io.total_qs			:= reg_control(206)
	c2h.io.total_cmds		:= reg_control(207)
	c2h.io.pfch_tag			:= reg_control(209)
	c2h.io.tag_index		:= reg_control(210)
	c2h.io.target_addr		:= reg_control(214)
	
	c2h.io.count_cmd		<> reg_status(200)
	c2h.io.count_word		<> reg_status(201)
	c2h.io.count_time		<> reg_status(202)

	Collector.connect_to_status_reg(reg_status, 400)

	val loading_start_reg = RegNext(reg_control(215)(0))//取bit0位
    val loading_start_pulse = reg_control(215)(0) && !loading_start_reg

	val hotloading = Module(new hotloading())
	hotloading.io.h2c_cmd <> qdma_h2c_cmd
	hotloading.io.h2c_data <> qdma_h2c_data
	hotloading.io.loading_start := loading_start_pulse
	// 216/217: 64-bit host source address; 219: CPU IMEM destination base.
	hotloading.io.host_mem_addr := Cat(reg_control(216),reg_control(217)).asUInt
	hotloading.io.imem_base_addr := reg_control(219)
	hotloading.io.mem_length  := reg_control(218)
	hotloading.io.version := reg_control(220)(23, 0)
	hotloading.io.page_idx := reg_control(221)(15, 0)
	hotloading.io.shadow_slot := reg_control(222)(15, 0)
	hotloading.io.vrt_update_enable := reg_control(223)(0)

	// riscv-mini
	val config = MiniConfig()
	val sys_rst = !qdma.io.user_arstn
	val mini_core = withClockAndReset(userClk, sys_rst) {
		Module(new Tile(
		enable_hbm = config.enable_hbm,
		coreParams = config.core, 
		bramParams = config.bram,
		nastiParams = config.nasti, 
		cacheParams = config.cache
		))
	}
	//hotloading写入imem ?由testhotloading完成
	mini_core.io.cpu_reset := hotloading.io.core_started
	mini_core.io.imem_addr    := hotloading.io.imem_addr
    mini_core.io.imem_wr_en   := hotloading.io.imem_wr_en
    mini_core.io.imem_data_in := hotloading.io.imem_data_in
    mini_core.io.imem_musk    := hotloading.io.imem_musk
    mini_core.io.vrt_update <> hotloading.io.vrt_update

	reg_status(300) := mini_core.io.rdma_print_addr
	reg_status(301) := mini_core.io.rdma_print_string_num
	reg_status(302) := mini_core.io.rdma_print_string_len
	reg_status(303) := mini_core.io.rdma_trap
	mini_core.io.pkg_type_to_cc  := DontCare
	mini_core.io.user_header_len := DontCare
	mini_core.io.user_table_size := DontCare
	mini_core.io.has_event_wr := false.B
    mini_core.io.has_event_rd := DontCare
    mini_core.io.event_recv_cnt := DontCare
    mini_core.io.event_processed_cnt := DontCare
    mini_core.io.event_type := DontCare
    mini_core.io.user_csr_wr := VecInit(Seq.fill(32)(0.U(32.W)))
    mini_core.io.user_csr_rd := DontCare


	// HBM 已移除，mini-core 走 BRAM（enable_hbm=false），nasti 置 DontCare
	mini_core.io.nasti := DontCare



	mini_core.io.host := DontCare

}
