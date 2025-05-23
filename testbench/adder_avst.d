import esdl;
import esdl.intf.verilator.verilated;
import esdl.intf.verilator.trace;
import uvm;
import std.stdio;
import std.string: format;

class avst_item: uvm_sequence_item
{
  mixin uvm_object_utils;

  @UVM_DEFAULT {
    @rand ubyte data;
    @rand ubyte delay;
    ubvec!1 end;
  }
   
  this(string name = "avst_item") {
    super(name);
  }

  constraint! q{
    delay dist [0 := 99, 1:9 :/ 1];
  } cst_delay;

  constraint! q{
    data >= 0x30;
    data <= 0x7a;
  } cst_ascii;

}

class avst_phrase_seq: uvm_sequence!avst_item
{

  mixin uvm_object_utils;

  @UVM_DEFAULT {
    ubyte[] phrase;
  }

  this(string name="") {
    super(name);
  }

  void set_phrase(string phrase) {
    this.phrase = cast(ubyte[]) phrase;
  }

  bool _is_final;

  bool is_finalized() {
    return _is_final;
  }

  void opOpAssign(string op)(avst_item item) if(op == "~")
    {
      assert(item !is null);
      phrase ~= item.data;
      if (item.end) _is_final = true;
    }
  // task
  override void body() {
    // uvm_info("avst_seq", "Starting sequence", UVM_MEDIUM);

    for (size_t i=0; i!=phrase.length; ++i) {
      wait_for_grant();
      req.data = cast(ubyte) phrase[i];
      if (i == phrase.length - 1) req.end = true;
      else req.end = false;
      avst_item cloned = cast(avst_item) req.clone;
      send_request(cloned);
    }
    
    // uvm_info("avst_item", "Finishing sequence", UVM_MEDIUM);
  } // body

  ubyte[] transform() {
    ubyte[] retval;
    uint value;
    foreach (c; phrase) {
      value += c;
    }
    for (int i=4; i!=0; --i) {
      retval ~= cast (ubyte) (value >> (i-1)*8);
    }
    return retval;
  }
}

class avst_seq: uvm_sequence!avst_item
{
  @UVM_DEFAULT {
    @rand uint seq_size;
  }

  mixin uvm_object_utils;


  this(string name="") {
    super(name);
    req = avst_item.type_id.create(name ~ ".req");
  }

  constraint!q{
    seq_size < 64;
    seq_size > 16;
  } seq_size_cst;

  // task
  override void body() {
      for (size_t i=0; i!=seq_size; ++i) {
	wait_for_grant();
	req.randomize();
	if (i == seq_size - 1) req.end = true;
	else req.end = false;
	avst_item cloned = cast(avst_item) req.clone;
	// uvm_info("avst_item", cloned.sprint, UVM_DEBUG);
	send_request(cloned);
      }
      // uvm_info("avst_item", "Finishing sequence", UVM_DEBUG);
    }

}

class avst_driver: uvm_driver!(avst_item)
{

  mixin uvm_component_utils;
  
  AvstIntf avst_in;

  this(string name, uvm_component parent = null) {
    super(name, parent);
    uvm_config_db!AvstIntf.get(this, "", "avst_in", avst_in);
    assert (avst_in !is null);
  }


  override void run_phase(uvm_phase phase) {
    super.run_phase(phase);
    while (true) {
      // uvm_info("AVL TRANSACTION", req.sprint(), UVM_DEBUG);
      seq_item_port.try_next_item(req);

      if (req !is null) {

	for (int i = 0; i != req.delay; ++i) {
	  wait (avst_in.clock.negedge());

	  avst_in.end = false;
	  avst_in.valid = false;
	}
	
	while (avst_in.ready == 0 || avst_in.reset == 1) {
	  wait (avst_in.clock.negedge());

	  avst_in.end = false;
	  avst_in.valid = false;
	}
	  

	wait (avst_in.clock.negedge());

	avst_in.data = req.data;
	avst_in.end = req.end;
	avst_in.valid = true;

	// req_analysis.write(req);
	seq_item_port.item_done();
      }
      else {
	wait (avst_in.clock.negedge());

	avst_in.end = false;
	avst_in.valid = false;
      }
    }
  }

  // protected void trans_received(avst_item tr) {}
  // protected void trans_executed(avst_item tr) {}

}

class avst_out_driver: uvm_component
{

  mixin uvm_component_utils;
  
  AvstIntf avst_out;

  this(string name, uvm_component parent = null) {
    super(name, parent);
    uvm_config_db!AvstIntf.get(this, "", "avst_out", avst_out);
    assert (avst_out !is null);
  }


  override void run_phase(uvm_phase phase) {
    super.run_phase(phase);
    while (true) {
      uint delay;
      uint flag;
      delay = urandom(0, 10);
      flag = urandom(0, 10);
      if (flag == 0) {
	for (size_t i=0; i!=delay; ++i) {
	  avst_out.ready = false;
	  wait (avst_out.clock.negedge());
	}
      }
      else {
	avst_out.ready = true;
	wait (avst_out.clock.negedge());
      }
    }
  }

  // protected void trans_received(avst_item tr) {}
  // protected void trans_executed(avst_item tr) {}

}

class avst_snooper: uvm_monitor
{
  mixin uvm_component_utils;

  AvstIntf avst;

  int _ready_latency = 0;

  void set_read_latency(int latency) {
    assert (latency == 0 || latency == 1);
    _ready_latency = latency;
  }

  bool prev_ready;

  this (string name, uvm_component parent = null) {
    super(name,parent);
    uvm_config_db!AvstIntf.get(this, "", "avst", avst);
    assert (avst !is null);
  }

  @UVM_BUILD {
    uvm_analysis_port!avst_item egress;
  }
  
  override void run_phase(uvm_phase phase) {
    super.run_phase(phase);

    while (true) {
      wait (avst.clock.posedge());
      if (_ready_latency == 0) prev_ready = avst.ready;
      if (avst.reset == 1 ||
	  prev_ready == 0 || avst.valid == 0) {
	if (_ready_latency == 1) prev_ready = avst.ready;
	continue;
      }
      else {
	avst_item item = avst_item.type_id.create(get_full_name() ~ ".avst_item");
	item.data = avst.data;
	item.end = cast(bool) avst.end;
	egress.write(item);
	uvm_info("AVL Monitored Req", item.sprint(), UVM_DEBUG);
	// writeln("valid input");
      }
      if (_ready_latency == 1) prev_ready = avst.ready;
    }
  }

}


class avst_scoreboard: uvm_scoreboard
{
  this(string name, uvm_component parent = null) {
    super(name, parent);
  }

  mixin uvm_component_utils;

  uvm_phase phase_run;

  uint matched;

  avst_phrase_seq[] req_queue;
  avst_phrase_seq[] rsp_queue;

  @UVM_BUILD {
    uvm_analysis_imp!(avst_scoreboard, write_req) req_analysis;
    uvm_analysis_imp!(avst_scoreboard, write_rsp) rsp_analysis;
  }

  override void run_phase(uvm_phase phase) {
    phase_run = phase;
    auto imp = phase.get_imp();
    assert(imp !is null);
    uvm_wait_for_ever();
  }

  void write_req(avst_phrase_seq seq) {
      uvm_info("Monitor", "Got req item", UVM_DEBUG);
      req_queue ~= seq;
      assert(phase_run !is null);
      phase_run.raise_objection(this);
      // writeln("Received request: ", matched + 1);
  }

  void write_rsp(avst_phrase_seq seq) {
      uvm_info("Monitor", "Got rsp item", UVM_DEBUG);
      // seq.print();
      rsp_queue ~= seq;
      assert(phase_run !is null);
      check_matched();
      phase_run.drop_objection(this);
  }

  void check_matched() {
    auto expected = req_queue[matched].transform();
    // writeln("Ecpected: ", expected[0..64]);
    if (expected == rsp_queue[matched].phrase) {
      uvm_info("MATCHED",
	       format("Scoreboard received expected response #%d", matched),
	       UVM_LOW);
      uvm_info("REQUEST", format("%s", req_queue[$-1].phrase), UVM_LOW);
      uvm_info("RESPONSE", format("%s", rsp_queue[$-1].phrase), UVM_LOW);
    }
    else {
      uvm_error("MISMATCHED", "Scoreboard received unmatched response");
      writeln(expected, " != ", rsp_queue[matched].phrase);
    }
    matched += 1;
  }

}

class avst_monitor: uvm_monitor
{

  mixin uvm_component_utils;
  
  @UVM_BUILD {
    uvm_analysis_port!avst_phrase_seq egress;
    uvm_analysis_imp!(avst_monitor, write) ingress;
  }


  this(string name, uvm_component parent = null) {
    super(name, parent);
  }

  avst_phrase_seq seq;

  void write(avst_item item) {
    if (seq is null) {
      seq = avst_phrase_seq.type_id.create("avst_seq");
    }
    seq ~= item;
    if (seq.is_finalized()) {
      uvm_info("Monitor", "Got Seq " ~ seq.sprint(), UVM_DEBUG);
      egress.write(seq);
      seq = null;
    }
  }
  
}


class avst_sequencer: uvm_sequencer!avst_item
{
  mixin uvm_component_utils;

  this(string name, uvm_component parent=null) {
    super(name, parent);
  }
}

class avst_agent: uvm_agent
{

  @UVM_BUILD {
    avst_sequencer sequencer;
    avst_driver    driver;
    avst_out_driver driver_out;

    avst_monitor   req_monitor;
    avst_monitor   rsp_monitor;

    avst_snooper   req_snooper;
    avst_snooper   rsp_snooper;

    avst_scoreboard   scoreboard;
  }
  
  mixin uvm_component_utils;
   
  this(string name, uvm_component parent = null) {
    super(name, parent);
  }

  override void connect_phase(uvm_phase phase) {
    driver.seq_item_port.connect(sequencer.seq_item_export);
    req_snooper.egress.connect(req_monitor.ingress);
    req_monitor.egress.connect(scoreboard.req_analysis);
    rsp_snooper.egress.connect(rsp_monitor.ingress);
    rsp_monitor.egress.connect(scoreboard.rsp_analysis);
  }

  override void end_of_elaboration_phase(uvm_phase phase) {
    rsp_snooper.set_read_latency(1);
  }
}

class random_test: uvm_test
{
  mixin uvm_component_utils;

  this(string name, uvm_component parent) {
    super(name, parent);
  }

  @UVM_BUILD {
    avst_env env;
  }
  
  override void run_phase(uvm_phase phase) {
    phase.get_objection().set_drain_time(this, 100.nsec);
    phase.raise_objection(this);
    avst_seq rand_sequence = avst_seq.type_id.create("avst_seq");

    for (size_t i=0; i!=100; ++i) {
      rand_sequence.randomize();
      auto sequence = cast(avst_seq) rand_sequence.clone();
      sequence.start(env.agent.sequencer, null);
    }
    phase.drop_objection(this);
  }
}

// class QuickFoxTest: uvm_test
// {
//   mixin uvm_component_utils;

//   this(string name, uvm_component parent) {
//     super(name, parent);
//   }

//   @UVM_BUILD avst_env env;
  
//   override void run_phase(uvm_phase phase) {
//     phase.raise_objection(this);
//     auto sequence = new avst_phrase_seq("QuickFoxSeq");
//     sequence.set_phrase("The quick brown fox jumps over the lazy dog");

//     sequence.start(env.agent.sequencer, null);
//     phase.drop_objection(this);
//   }
// }

class avst_env: uvm_env
{
  mixin uvm_component_utils;

  @UVM_BUILD private avst_agent agent;

  this(string name, uvm_component parent) {
    super(name, parent);
  }

}

class AvstIntf: VlInterface
{
  Port!(Signal!(ubvec!1)) clock;
  Port!(Signal!(ubvec!1)) reset;
  
  VlPort!8 data;
  VlPort!1 end;
  VlPort!1 valid;
  VlPort!1 ready;
}

class Top: Entity
{
  import Vadder_avst_euvm;
  import esdl.intf.verilator.verilated;

  VerilatedVcdD _trace;

  Signal!(ubvec!1) reset;
  Signal!(ubvec!1) clock;

  DVadder_avst dut;

  AvstIntf avstIn;
  AvstIntf avstOut;
  
  void opentrace(string vcdname) {
    if (_trace is null) {
      _trace = new VerilatedVcdD();
      dut.trace(_trace, 99);
      _trace.open(vcdname);
    }
  }

  void closetrace() {
    if (_trace !is null) {
      _trace.close();
      _trace = null;
    }
  }

  override void doConnect() {
    import std.stdio;

    //
    avstIn.clock(clock);
    avstIn.reset(reset);

    avstIn.data(dut.data_in);
    avstIn.end(dut.end_in);
    avstIn.valid(dut.valid_in);
    avstIn.ready(dut.ready_in);

    // 
    avstOut.clock(clock);
    avstOut.reset(reset);

    avstOut.data(dut.data_out);
    avstOut.end(dut.end_out);
    avstOut.valid(dut.valid_out);
    avstOut.ready(dut.ready_out);
  }

  override void doBuild() {
    dut = new DVadder_avst();
    traceEverOn(true);
    opentrace("avst_adder.vcd");
  }
  
  Task!stimulateClock stimulateClockTask;
  Task!stimulateReset stimulateResetTask;
  Task!stimulateReadyOut stimulateReadyOutTask;

  void stimulateReadyOut() {
    dut.reset = true;
  }
  
  void stimulateClock() {
    import std.stdio;
    clock = false;
    for (size_t i=0; i!=1000000; ++i)
      {
	
      // writeln("clock is: ", clock);
      clock = false;
      dut.clk = false;
      wait (2.nsec);
      dut.eval();
      if (_trace !is null)
	_trace.dump(getSimTime().getVal());
      wait (8.nsec);
      clock = true;
      dut.clk = true;
      wait (2.nsec);
      dut.eval();
      if (_trace !is null) {
	_trace.dump(getSimTime().getVal());
	_trace.flush();
      }
      wait (8.nsec);
    }
  }

  void stimulateReset() {
    reset = true;
    dut.reset = true;
    wait (100.nsec);
    reset = false;
    dut.reset = false;
  }
  
}

class uvm_sha3_tb: uvm_tb
{
  Top top;
  override void initial() {
    uvm_config_db!(AvstIntf).set(null, "uvm_test_top.env.agent.driver", "avst_in", top.avstIn);
    uvm_config_db!(AvstIntf).set(null, "uvm_test_top.env.agent.driver_out", "avst_out", top.avstOut);
    uvm_config_db!(AvstIntf).set(null, "uvm_test_top.env.agent.req_snooper", "avst", top.avstIn);
    uvm_config_db!(AvstIntf).set(null, "uvm_test_top.env.agent.rsp_snooper", "avst", top.avstOut);
  }
}

void main(string[] args) {
  import std.stdio;
  uint random_seed;

  CommandLine cmdl = new CommandLine(args);

  if (cmdl.plusArgs("random_seed=" ~ "%d", random_seed))
    writeln("Using random_seed: ", random_seed);
  else random_seed = 1;

  auto tb = new uvm_sha3_tb;
  tb.multicore(0, 1);
  tb.elaborate("tb", args);
  tb.set_seed(random_seed);
  tb.start();
  
}
