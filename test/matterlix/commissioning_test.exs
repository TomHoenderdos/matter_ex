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
      Commissioning.store_noc(noc, ipk, 42, 1, name)
      Commissioning.complete(name)

      assert Commissioning.commissioned?(name)
    end

    test "get_credentials returns full credential map", %{name: name} do
      pub = :crypto.strong_rand_bytes(65)
      priv = :crypto.strong_rand_bytes(32)
      noc = :crypto.strong_rand_bytes(100)
      ipk = :crypto.strong_rand_bytes(16)

      Commissioning.store_keypair({pub, priv}, name)
      Commissioning.store_noc(noc, ipk, 42, 1, name)
      Commissioning.complete(name)

      creds = Commissioning.get_credentials(name)
      assert creds.noc == noc
      assert creds.private_key == priv
      assert creds.ipk == ipk
      assert creds.node_id == 42
      assert creds.fabric_id == 1
    end

    test "get_credentials returns nil when not commissioned", %{name: name} do
      assert Commissioning.get_credentials(name) == nil
    end
  end

  describe "reset" do
    test "clears all state", %{name: name} do
      Commissioning.arm(name)
      Commissioning.store_keypair({<<1>>, <<2>>}, name)
      Commissioning.store_noc(<<3>>, <<4>>, 1, 1, name)
      Commissioning.complete(name)

      Commissioning.reset(name)

      refute Commissioning.armed?(name)
      refute Commissioning.commissioned?(name)
      assert Commissioning.get_keypair(name) == nil
      assert Commissioning.get_credentials(name) == nil
    end
  end
end
