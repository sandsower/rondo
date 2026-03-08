pub type Port

pub type PortMessage {
  Line(BitArray)
  Partial(BitArray)
  ExitStatus(Int)
}

@external(erlang, "rondo_port_ffi", "open_port")
pub fn open(command: String, args: List(String)) -> Result(Port, String)

@external(erlang, "rondo_port_ffi", "close_port")
pub fn close(port: Port) -> Nil

@external(erlang, "rondo_port_ffi", "receive_port_message")
pub fn receive_message(port: Port, timeout_ms: Int) -> Result(PortMessage, Nil)

@external(erlang, "rondo_port_ffi", "run_shell_command")
pub fn run_shell(command: String, working_dir: String, timeout_ms: Int) -> Result(Int, Nil)
