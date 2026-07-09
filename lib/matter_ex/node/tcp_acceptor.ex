defmodule MatterEx.Node.TCPAcceptor do
  @moduledoc """
  Supervised TCP acceptor for a `MatterEx.Node`.

  Owns the TCP listen socket and accepts connections in a self-driven loop,
  handing each accepted socket to the owning node process. Runs in its own
  crash domain: an accept error restarts only this acceptor (via its
  supervisor), never the node, and it can never silently stop accepting.

  Matter TCP is optional. If the listen socket can't be opened the acceptor
  declines to start (`:ignore`) and the node continues on UDP only.

  ## Options

  - `:port` — TCP port to listen on (required; the node passes the port UDP
    was assigned so both transports share it)
  - `:node` — pid of the owning `MatterEx.Node` (required)
  """

  use GenServer

  require Logger

  # Bounded so the accept loop periodically yields — staying responsive to
  # shutdown and noticing a closed listen socket promptly.
  @accept_timeout 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    node = Keyword.fetch!(opts, :node)

    case :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:backlog, 8}]) do
      {:ok, listen} ->
        Logger.info("Matter node TCP listener on port #{port}")
        {:ok, %{listen: listen, node: node}, {:continue, :accept}}

      {:error, reason} ->
        Logger.warning("Failed to start TCP listener on port #{port}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_continue(:accept, %{listen: listen, node: node} = state) do
    case :gen_tcp.accept(listen, @accept_timeout) do
      {:ok, socket} ->
        # Transfer ownership while the socket is still passive, then let the
        # node (the new owner) switch it to active mode. This avoids setting
        # options on a socket we no longer own and prevents any data race
        # during the handoff.
        case :gen_tcp.controlling_process(socket, node) do
          :ok -> send(node, {:tcp_accepted, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        {:noreply, state, {:continue, :accept}}

      {:error, :timeout} ->
        {:noreply, state, {:continue, :accept}}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        # Crash → the supervisor restarts just this acceptor, which re-opens
        # the listen socket. Never silently stops accepting.
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, %{listen: listen}), do: :gen_tcp.close(listen)
  def terminate(_reason, _state), do: :ok
end
