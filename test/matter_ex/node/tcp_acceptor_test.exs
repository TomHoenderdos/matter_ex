defmodule MatterEx.Node.TCPAcceptorTest do
  use ExUnit.Case, async: true

  alias MatterEx.Node.TCPAcceptor

  test "recovers when a previously occupied listen port becomes available" do
    {:ok, occupied} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(occupied)
    on_exit(fn -> :gen_tcp.close(occupied) end)

    acceptor = start_supervised!({TCPAcceptor, port: port, node: self()})
    assert is_pid(acceptor)
    assert Process.alive?(acceptor)

    :gen_tcp.close(occupied)

    assert {:ok, client} = connect_when_ready(port, 100)
    on_exit(fn -> :gen_tcp.close(client) end)
    assert_receive {:tcp_accepted, accepted}, 1_000
    :gen_tcp.close(accepted)
    assert Process.alive?(acceptor)
  end

  defp connect_when_ready(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:error, :econnrefused} when attempts > 0 ->
        Process.sleep(10)
        connect_when_ready(port, attempts - 1)

      result ->
        result
    end
  end
end
