package mini

import chisel3.stage.ChiselGeneratorAnnotation
import chisel3.stage.ChiselStage
import firrtl.options.TargetDirAnnotation
import mini.foo._
import mini.core._
import mini.junctions._

object elaborate extends App {
  val dir 	= TargetDirAnnotation("Verilog")
  val config = MiniConfig()
  // Standalone generators use the exact same architectural parameters as Tile.
  // This keeps the VRT test target from drifting away from the deployed IMEM.
  val tileImemBase = BigInt(config.bram.i_offset.stripPrefix("x"), 16)

  args(0) match{
    // case "test_csr" => (new ChiselStage()).emitSystemVerilog(new test_csr(), Array("--target-dir", "Verilog", "--full-stacktrace", "--output-annotation-file", "Foo.sv"))
		case "test_hotloading" => (new ChiselStage()).emitSystemVerilog(new test_hotloading(), Array("--target-dir", "Verilog", "--full-stacktrace"))
    case "chunksim" => (new ChiselStage()).emitSystemVerilog(
          new ChunkLoadSimTop(),
          Array("--target-dir", "Verilog", "--output-file", "chunksim", "--full-stacktrace")
    )
		case "vrt" => (new ChiselStage()).emitSystemVerilog(
      new VersionRemapTable(
        xlen = config.core.xlen,
        imemBase = tileImemBase,
        imemWords = config.bram.inst_entries
      ),
      // postElaborating.py opens Verilog/<command-name>.sv.
      Array("--target-dir", "Verilog", "--output-file", "vrt", "--full-stacktrace")
    )
		case "MiniCoreTop" => (new ChiselStage()).emitSystemVerilog(new MiniCoreTop(), Array("--target-dir", "Verilog", "--full-stacktrace"))
		case "SlicerArbiterTop" | "slicer-arbiter" => (new ChiselStage()).emitSystemVerilog(
        new SlicerArbiterTop(),
        Array("--target-dir", "Verilog", "--full-stacktrace")
      )
		case "mini" => (new ChiselStage()).emitSystemVerilog(
        new Tile(
          enable_hbm = config.enable_hbm,
          coreParams = config.core,
          bramParams = config.bram,
          nastiParams = config.nasti,
          cacheParams = config.cache
        ),
        Array("--target-dir", "Verilog", "--full-stacktrace"),
      )
  }
}
