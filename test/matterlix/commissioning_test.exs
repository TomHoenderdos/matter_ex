defmodule Matterlix.CommissioningTest do
  use ExUnit.Case, async: true

  alias Matterlix.Commissioning

  setup do
    name = :"commissioning_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Commissioning.start_link(name: name)
    %{name: name}
  end

  describe "initial state" do
    test "not armed and not commissioned", %{name: name} do
      refute Commissioning.armed?(name)
      refute Commissioning.commissioned?(name)
      assert Commissioning.get_keypair(name) == nil
      assert Commissioning.get_credentials(name) == nil
    end
  end

  describe "arm/disarm" do
    test "arm and disarm lifecycle", %{name: name} do
      Commissioning.arm(name)
      assert Commissioning.armed?(name)

      Commissioning.disarm(name)
      refute Commissioning.armed?(name)
    end
  end

  describe "keypair" do
    test "store and retrieve keypair", %{name: name} do
      keypair = {:crypto.strong_rand_bytes(65), :crypto.strong_rand_bytes(32)}
      Commissioning.store_keypair(keypair, name)
      assert Commissioning.get_keypair(name) == keypair
    end
  end

  describe "full credential flow" do
    test "store_root_cert → store_noc → commissioned", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)
      noc = :crypto.strong_rand_bytes(100)
      ipk = :crypto.strong_rand_bytes(16)

      Commissioning.store_keypair({pub, priv}, name)
      Commissioning.store_root_cert(:crypto.strong_rand_bytes(200), name)
      Commissioning.store_noc(1, noc, nil, ipk, 42, 1, name)
      Commissioning.complete(name)

      assert Commissioning.commissioned?(name)
    end

    test "get_credentials returns full credential map", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)
      noc = :crypto.strong_rand_bytes(100)
      ipk = :crypto.strong_rand_bytes(16)

      Commissioning.store_keypair({pub, priv}, name)
      Commissioning.store_noc(1, noc, nil, ipk, 42, 1, name)
      Commissioning.complete(name)

      creds = Commissioning.get_credentials(name)
      assert creds.noc == noc
      assert creds.private_key == priv
      assert creds.ipk == ipk
      assert creds.node_id == 42
      assert creds.fabric_id == 1
      assert creds.fabric_index == 1
    end

    test "get_credentials returns nil when not commissioned", %{name: name} do
      assert Commissioning.get_credentials(name) == nil
    end
  end

  describe "multi-fabric" do
    test "store multiple fabrics with distinct indices", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)

      Commissioning.store_keypair({pub, priv}, name)

      noc1 = :crypto.strong_rand_bytes(100)
      ipk1 = :crypto.strong_rand_bytes(16)
      Commissioning.store_noc(1, noc1, nil, ipk1, 42, 1, name)

      noc2 = :crypto.strong_rand_bytes(100)
      ipk2 = :crypto.strong_rand_bytes(16)
      Commissioning.store_noc(2, noc2, nil, ipk2, 99, 2, name)

      assert Commissioning.commissioned?(name)
      assert Enum.sort(Commissioning.get_fabric_indices(name)) == [1, 2]

      creds1 = Commissioning.get_credentials(1, name)
      assert creds1.node_id == 42
      assert creds1.fabric_id == 1

      creds2 = Commissioning.get_credentials(2, name)
      assert creds2.node_id == 99
      assert creds2.fabric_id == 2
    end

    test "last_added_fabric tracks latest", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)
      Commissioning.store_keypair({pub, priv}, name)

      Commissioning.store_noc(1, <<1>>, nil, <<2>>, 1, 1, name)
      assert Commissioning.last_added_fabric(name) == 1

      Commissioning.store_noc(2, <<3>>, nil, <<4>>, 2, 2, name)
      assert Commissioning.last_added_fabric(name) == 2

      Commissioning.clear_last_added(name)
      assert Commissioning.last_added_fabric(name) == nil
    end

    test "get_all_credentials returns all fabrics", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)
      Commissioning.store_keypair({pub, priv}, name)

      Commissioning.store_noc(1, <<1>>, nil, <<2>>, 10, 1, name)
      Commissioning.store_noc(2, <<3>>, nil, <<4>>, 20, 2, name)

      all = Commissioning.get_all_credentials(name)
      assert length(all) == 2
      node_ids = Enum.map(all, & &1.node_id) |> Enum.sort()
      assert node_ids == [10, 20]
    end
  end

  describe "reset" do
    test "clears all state", %{name: name} do
      Commissioning.arm(name)
      Commissioning.store_keypair({<<1>>, <<2>>}, name)
      Commissioning.store_noc(1, <<3>>, nil, <<4>>, 1, 1, name)
      Commissioning.complete(name)

      Commissioning.reset(name)

      refute Commissioning.armed?(name)
      refute Commissioning.commissioned?(name)
      assert Commissioning.get_keypair(name) == nil
      assert Commissioning.get_credentials(name) == nil
    end
  end
end
