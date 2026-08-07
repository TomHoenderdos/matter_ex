defmodule MatterEx.FabricStoreTest do
  use ExUnit.Case, async: true

  alias MatterEx.{Commissioning, FabricStore, Storage}
  alias MatterEx.Storage.FileSystem

  @moduletag :tmp_dir

  defmodule Device do
    use MatterEx.Device,
      vendor_name: "TestCo",
      product_name: "FabricStore",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster(MatterEx.Cluster.OnOff)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    start_supervised!(Device)
    comm = :"comm_#{:erlang.unique_integer([:positive])}"
    start_supervised!(%{id: comm, start: {Commissioning, :start_link, [[name: comm]]}})

    backend = {FileSystem, [dir: Path.join(tmp_dir, "store")]}
    %{backend: backend, comm: comm}
  end

  @fabric %{
    fabric_index: 1,
    fabric_id: 0x1234,
    node_id: 0x2A,
    noc: "NOC-BYTES",
    icac: nil,
    root_cert: "ROOT-CERT",
    private_key: "PRIVATE-KEY",
    ipk: "IPK-BYTES",
    case_admin_subject: 112_233
  }

  defp acl_name, do: Device.__process_name__(0, :access_control)
  defp opcreds_name, do: Device.__process_name__(0, :operational_credentials)
  defp gkm_name, do: Device.__process_name__(0, :group_key_management)

  defp seed_state(comm) do
    Commissioning.restore_fabric(@fabric, comm)

    :ok =
      GenServer.call(
        acl_name(),
        {:write_attribute, :acl,
         [%{privilege: 5, auth_mode: 2, subjects: [112_233], targets: nil, fabric_index: 1}]}
      )

    :ok =
      GenServer.call(
        opcreds_name(),
        {:update_attribute, :nocs, [%{0 => {:bytes, "NOC-BYTES"}, 254 => {:uint8, 1}}]}
      )

    :ok =
      GenServer.call(
        gkm_name(),
        {:restore_state,
         %{
           group_key_map: [%{group_id: 1, group_key_set_id: 1}],
           _key_sets: %{1 => %{group_key_set_id: 1, epoch_key0: "EPOCH0", epoch_start_time0: 0}}
         }}
      )
  end

  # Wipe agent + clusters back to empty, as if the BEAM had restarted.
  defp wipe(comm) do
    Commissioning.reset(comm)
    :ok = GenServer.call(acl_name(), {:write_attribute, :acl, []})
    :ok = GenServer.call(opcreds_name(), {:update_attribute, :nocs, []})
    :ok = GenServer.call(gkm_name(), {:restore_state, %{group_key_map: [], _key_sets: %{}}})
  end

  test "persist then load restores fabric identity, opcreds, acl, and group state", %{
    backend: backend,
    comm: comm
  } do
    seed_state(comm)

    assert :ok = FabricStore.persist(Device, backend, commissioning: comm)

    wipe(comm)
    # Confirm the wipe really cleared things.
    assert Commissioning.get_credentials(1, comm) == nil
    assert {:ok, []} = GenServer.call(acl_name(), {:read_attribute, :acl})

    loaded = FabricStore.load(Device, backend, commissioning: comm)

    # Return value carries the fabric credentials for CASE re-enablement.
    assert [%{fabric_index: 1, node_id: 0x2A, private_key: "PRIVATE-KEY"}] = loaded

    # Commissioning agent repopulated.
    creds = Commissioning.get_credentials(1, comm)
    assert creds.fabric_id == 0x1234
    assert creds.ipk == "IPK-BYTES"
    assert creds.case_admin_subject == 112_233

    # Cluster state restored.
    assert {:ok, [%{fabric_index: 1}]} = GenServer.call(acl_name(), {:read_attribute, :acl})

    assert {:ok, [%{0 => {:bytes, "NOC-BYTES"}}]} =
             GenServer.call(opcreds_name(), {:read_attribute, :nocs})

    gkm_state = GenServer.call(gkm_name(), :get_state)

    assert gkm_state._key_sets == %{
             1 => %{group_key_set_id: 1, epoch_key0: "EPOCH0", epoch_start_time0: 0}
           }
  end

  test "load returns [] when nothing is stored", %{backend: backend, comm: comm} do
    assert FabricStore.load(Device, backend, commissioning: comm) == []
  end

  test "a removed fabric is gone from the next snapshot", %{backend: backend, comm: comm} do
    # The snapshot is the fabric set, so removal needs no reconciliation — the
    # next write simply doesn't contain it.
    Commissioning.restore_fabric(@fabric, comm)
    Commissioning.restore_fabric(%{@fabric | fabric_index: 2, node_id: 0x63}, comm)
    :ok = FabricStore.persist(Device, backend, commissioning: comm)

    assert [1, 2] = loaded_indices(backend, comm)

    Commissioning.remove_fabric(2, comm)
    :ok = FabricStore.persist(Device, backend, commissioning: comm)

    assert [1] = loaded_indices(backend, comm)
  end

  defp loaded_indices(backend, comm) do
    Device
    |> FabricStore.load(backend, commissioning: comm)
    |> Enum.map(& &1.fabric_index)
    |> Enum.sort()
  end

  test "persist reports a storage failure instead of swallowing it", %{comm: comm} do
    # A read-only or full /data must not no-op in silence: the device would look
    # commissioned right up until it rebooted uncommissioned.
    Commissioning.restore_fabric(@fabric, comm)
    unwritable = {MatterEx.Storage.FileSystem, dir: "/proc/matter_ex_should_not_be_writable"}

    assert {:error, _reason} = FabricStore.persist(Device, unwritable, commissioning: comm)
  end

  test "load warns rather than silently returning nothing when state is unreadable",
       %{backend: backend, comm: comm} do
    Commissioning.restore_fabric(@fabric, comm)
    :ok = FabricStore.persist(Device, backend, commissioning: comm)

    # Corrupt the stored snapshot the way a truncated write would.
    :ok = MatterEx.Storage.put(backend, "matter/state", <<0, 1, 2, 3>>)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [] = FabricStore.load(Device, backend, commissioning: comm)
      end)

    assert log =~ "could not be read"
  end

  test "clear resets clusters to defaults and wipes storage", %{backend: backend, comm: comm} do
    seed_state(comm)
    FabricStore.persist(Device, backend, commissioning: comm)
    assert Storage.keys(backend, "matter/") != []

    assert :ok = FabricStore.clear(Device, backend)

    # Every persisted key is gone.
    assert Storage.keys(backend, "matter/") == []

    # Fabric-scoped clusters are back to their initial defaults.
    assert {:ok, []} = GenServer.call(acl_name(), {:read_attribute, :acl})
    assert {:ok, []} = GenServer.call(opcreds_name(), {:read_attribute, :nocs})
    assert {:ok, []} = GenServer.call(opcreds_name(), {:read_attribute, :fabrics})
    assert {:ok, 0} = GenServer.call(opcreds_name(), {:read_attribute, :commissioned_fabrics})

    gkm_state = GenServer.call(gkm_name(), :get_state)
    assert gkm_state.group_key_map == []
    assert gkm_state._key_sets == %{}
  end

  test "clear with a nil backend still resets clusters", %{comm: comm} do
    seed_state(comm)

    assert :ok = FabricStore.clear(Device, nil)

    assert {:ok, []} = GenServer.call(acl_name(), {:read_attribute, :acl})
    assert {:ok, []} = GenServer.call(opcreds_name(), {:read_attribute, :nocs})
  end
end
