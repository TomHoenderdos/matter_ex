defmodule MatterEx.Node.TCPAcceptor do
  @moduledoc """
  Supervised TCP acceptor for a `MatterEx.Node`.

  Owns the TCP listen socket and accepts connections in a self-driven loop,
  handing each accepted socket to the owning node process. Runs in its own
  crash domain: an accept error restarts only this acceptor, via its supervisor,
  and it can never silently stop accepting.

  That isolation has a deliberate limit. The supervisor is *linked* to the node,
  which does not trap exits, so exhausting its restart intensity (10 restarts in
  5 seconds) brings the node down too. A wire failing that persistently is not
  something to keep restarting through — the escalation is the point — but it
  does mean "an acceptor crash never touches the node" holds for isolated
  failures, not for a sustained one.

  Matter TCP is optional. An occupied listen port is retried with backoff, since
  a crashed acceptor's socket may still be closing when its replacement starts.
  Other listen errors disable TCP and the node continues on UDP only.

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

    start_listening(port, node, 25)
  end

  @impl true
  def handle_info(:retry_listen, %{port: port, node: node, retry_delay: delay} = state) do
    case start_listening(port, node, delay) do
      {:ok, listening, continuation} -> {:noreply, listening, continuation}
      {:ok, waiting} -> {:noreply, waiting}
      :ignore -> {:noreply, state}
    end
  end

  defp start_listening(port, node, delay) do
    case :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:backlog, 8}]) do
      {:ok, listen} ->
        Logger.info("Matter node TCP listener on port #{port}")
        {:ok, %{listen: listen, node: node}, {:continue, :accept}}

      {:error, :eaddrinuse} ->
        Process.send_after(self(), :retry_listen, delay)
        {:ok, %{port: port, node: node, retry_delay: min(delay * 2, 1_000)}}

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

  # No terminate/2: without trap_exit it wouldn't run on the paths that matter,
  # and the listen socket is a port owned by this process — it closes when the
  # process dies, however it dies.
end
