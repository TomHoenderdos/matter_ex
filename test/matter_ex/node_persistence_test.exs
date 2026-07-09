defmodule MatterEx.NodePersistenceTest do
  # async: false — exercises the singleton MatterEx.Commissioning agent.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias MatterEx.{Commissioning, FabricStore, Storage}

  @passcode 20_202_021

  defmodule Device do
    use MatterEx.Device,
      vendor_name: "TestCo",
      product_name: "Persist",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster(MatterEx.Cluster.OnOff)
    end
  end

  @fabric %{
    fabric_index: 1,
    fabric_id: 0x1234,
    node_id: 0x2A,
    noc: "NOC",
    icac: nil,
    root_cert: nil,
    private_key: "PRIV",
    ipk: :binary.copy(<<7>>, 16),
    case_admin_subject: 112_233
  }

  @acl_entry %{privilege: 5, auth_mode: 2, subjects: [112_233], targets: nil, fabric_index: 1}

  setup %{tmp_dir: dir} do
    # Own the singleton commissioning agent for the test so its lifecycle is
    # deterministic; the Node reuses it rather than starting (and linking) its own.
    if pid = Process.whereis(Commissioning), do: Agent.stop(pid)
    start_supervised!({Commissioning, []})
    start_supervised!(Device)

    %{storage: {Storage.FileSystem, [dir: Path.join(dir, "store")]}}
  end

  defp acl_name, do: Device.__process_name__(0, :access_control)

  defp write_acl, do: :ok = GenServer.call(acl_name(), {:write_attribute, :acl, [@acl_entry]})

  defp start_node(storage) do
    start_supervised!(
      {MatterEx.Node,
       device: Device,
       passcode: @passcode,
       salt: :crypto.strong_rand_bytes(32),
       iterations: 1000,
       port: 0,
       tcp: false,
       storage: storage},
      restart: :temporary
    )
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  test "persists fabric state when a fabric-scoped cluster changes", %{storage: storage} do
    start_node(storage)

    Commissioning.restore_fabric(@fabric)
    write_acl()

    # The Node persists in response to the reporting-bus notification.
    wait_until(fn -> match?({:ok, _}, Storage.get(storage, "matter/fabric/1")) end)
    assert {:ok, _} = Storage.get(storage, "matter/acl")
  end

  test "restores fabrics from storage on start", %{storage: storage} do
    # Pre-populate storage as a previous run would have.
    Commissioning.restore_fabric(@fabric)
    write_acl()
    :ok = FabricStore.persist(Device, storage)

    # Wipe live state, as a restart would.
    Commissioning.reset()
    :ok = GenServer.call(acl_name(), {:write_attribute, :acl, []})
    refute Commissioning.commissioned?()

    # A node started with the same storage brings the fabric back.
    start_node(storage)
    wait_until(fn -> Commissioning.commissioned?() end)

    assert Commissioning.get_credentials(1).node_id == 0x2A
    assert {:ok, [%{fabric_index: 1}]} = GenServer.call(acl_name(), {:read_attribute, :acl})
  end

  test "no storage configured leaves the node in-memory only", %{storage: _storage} do
    start_node(nil)
    Commissioning.restore_fabric(@fabric)
    write_acl()
    Process.sleep(30)
    # Nothing to assert about files — just that the Node runs fine without storage.
    assert Commissioning.commissioned?()
  end
end
