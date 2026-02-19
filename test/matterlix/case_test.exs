defmodule Matterlix.CASETest do
  use ExUnit.Case, async: true

  alias Matterlix.CASE
  alias Matterlix.CASE.Messages
  alias Matterlix.Crypto.Certificate

  @ipk :crypto.strong_rand_bytes(16)
  @fabric_id 1

  # Helper: generate a keypair and NOC for testing
  defp generate_credentials(node_id) do
    {pub, priv} = Certificate.generate_keypair()
    noc = Messages.encode_noc(node_id, @fabric_id, pub)
    {noc, priv, pub}
  end

  defp new_device(node_id, session_id) do
    {noc, priv, _pub} = generate_credentials(node_id)

    CASE.new_device(
      noc: noc,
      private_key: priv,
      ipk: @ipk,
      node_id: node_id,
      fabric_id: @fabric_id,
      local_session_id: session_id
    )
  end

  defp new_initiator(node_id, session_id, peer_node_id) do
    {noc, priv, _pub} = generate_credentials(node_id)

    CASE.new_initiator(
      noc: noc,
      private_key: priv,
      ipk: @ipk,
      node_id: node_id,
      fabric_id: @fabric_id,
      local_session_id: session_id,
      peer_node_id: peer_node_id,
      peer_fabric_id: @fabric_id
    )
  end

  # ── Constructor tests ──────────────────────────────────────────

  describe "constructors" do
    test "new_device creates idle state" do
      device = new_device(1, 10)
      assert device.role == :device
      assert device.state == :idle
      assert device.node_id == 1
      assert device.local_session_id == 10
    end

    test "new_initiator creates idle state with peer info" do
      init = new_initiator(2, 20, 1)
      assert init.role == :initiator
      assert init.state == :idle
      assert init.node_id == 2
      assert init.peer_node_id == 1
      assert init.peer_fabric_id == @fabric_id
    end
  end

  # ── Initiate tests ─────────────────────────────────────────────

  describe "initiate" do
    test "produces Sigma1 payload" do
      init = new_initiator(2, 20, 1)

      {:send, :case_sigma1, payload, init} = CASE.initiate(init)

      assert init.state == :sigma1_sent
      assert is_binary(payload)
      assert byte_size(init.eph_pub) == 65

      {:ok, sigma1} = Messages.decode_sigma1(payload)
      assert byte_size(sigma1.initiator_random) == 32
      assert sigma1.initiator_session_id == 20
      assert byte_size(sigma1.destination_id) == 32
      assert sigma1.initiator_eph_pub == init.eph_pub
    end
  end

  # ── Full handshake ─────────────────────────────────────────────

  describe "full handshake" do
    test "device and initiator establish matching sessions" do
      device = new_device(1, 10)
      init = new_initiator(2, 20, 1)

      # Initiator sends Sigma1
      {:send, :case_sigma1, sigma1, init} = CASE.initiate(init)

      # Device processes Sigma1 → replies Sigma2
      {:reply, :case_sigma2, sigma2, device} = CASE.handle(device, :case_sigma1, sigma1)
      assert device.state == :sigma2_sent

      # Initiator processes Sigma2 → sends Sigma3
      {:send, :case_sigma3, sigma3, init} = CASE.handle(init, :case_sigma2, sigma2)
      assert init.state == :sigma3_sent

      # Device processes Sigma3 → established
      {:established, :status_report, sr_payload, device_session, device} =
        CASE.handle(device, :case_sigma3, sigma3)
      assert device.state == :established

      # Initiator processes StatusReport → established
      {:established, init_session, init} = CASE.handle(init, :status_report, sr_payload)
      assert init.state == :established

      # Sessions have matching cross-wise keys
      assert device_session.encrypt_key == init_session.decrypt_key
      assert device_session.decrypt_key == init_session.encrypt_key

      # Session IDs are correct
      assert device_session.local_session_id == 10
      assert device_session.peer_session_id == 20
      assert init_session.local_session_id == 20
      assert init_session.peer_session_id == 10
    end

    test "attestation challenges match" do
      device = new_device(1, 10)
      init = new_initiator(2, 20, 1)

      {:send, :case_sigma1, sigma1, init} = CASE.initiate(init)
      {:reply, :case_sigma2, sigma2, device} = CASE.handle(device, :case_sigma1, sigma1)
      {:send, :case_sigma3, sigma3, init} = CASE.handle(init, :case_sigma2, sigma2)
      {:established, :status_report, sr, device_session, _device} =
        CASE.handle(device, :case_sigma3, sigma3)
      {:established, init_session, _init} = CASE.handle(init, :status_report, sr)

      assert device_session.attestation_challenge == init_session.attestation_challenge
      assert byte_size(device_session.attestation_challenge) == 16
    end

    test "node IDs are set on sessions" do
      device = new_device(1, 10)
      init = new_initiator(2, 20, 1)

      {:send, :case_sigma1, sigma1, init} = CASE.initiate(init)
      {:reply, :case_sigma2, sigma2, device} = CASE.handle(device, :case_sigma1, sigma1)
      {:send, :case_sigma3, sigma3, init} = CASE.handle(init, :case_sigma2, sigma2)
      {:established, :status_report, sr, device_session, _device} =
        CASE.handle(device, :case_sigma3, sigma3)
      {:established, init_session, _init} = CASE.handle(init, :status_report, sr)

      assert device_session.local_node_id == 1
      assert device_session.peer_node_id == 2
      assert init_session.local_node_id == 2
      assert init_session.peer_node_id == 1
    end
  end

  # ── Error cases ────────────────────────────────────────────────

  describe "error cases" do
    test "wrong IPK causes destination_id mismatch" do
      device = new_device(1, 10)

      # Initiator uses different IPK
      {noc, priv, _pub} = generate_credentials(2)
      wrong_ipk = :crypto.strong_rand_bytes(16)

      init = CASE.new_initiator(
        noc: noc, private_key: priv, ipk: wrong_ipk,
        node_id: 2, fabric_id: @fabric_id, local_session_id: 20,
        peer_node_id: 1, peer_fabric_id: @fabric_id
      )

      {:send, :case_sigma1, sigma1, _init} = CASE.initiate(init)
      assert {:error, :destination_mismatch} = CASE.handle(device, :case_sigma1, sigma1)
    end

    test "wrong private key causes signature verification failure" do
      device = new_device(1, 10)

      # Initiator has mismatched NOC (public key) and private key
      # NOC contains real_pub, but initiator signs with wrong_priv
      {_wrong_pub, wrong_priv} = Certificate.generate_keypair()
      {real_pub, _real_priv} = Certificate.generate_keypair()
      noc = Messages.encode_noc(2, @fabric_id, real_pub)

      init = CASE.new_initiator(
        noc: noc, private_key: wrong_priv, ipk: @ipk,
        node_id: 2, fabric_id: @fabric_id, local_session_id: 20,
        peer_node_id: 1, peer_fabric_id: @fabric_id
      )

      {:send, :case_sigma1, sigma1, init} = CASE.initiate(init)

      # Use the SAME device object throughout so ephemeral keys (and shared_secret) are consistent
      {:reply, :case_sigma2, sigma2, device} = CASE.handle(device, :case_sigma1, sigma1)
      {:send, :case_sigma3, sigma3, _init} = CASE.handle(init, :case_sigma2, sigma2)

      # Device decrypts successfully (same shared_secret) but signature check fails
      assert {:error, :signature_verification_failed} = CASE.handle(device, :case_sigma3, sigma3)
    end

    test "unexpected message returns error" do
      device = new_device(1, 10)
      assert {:error, :unexpected_message} = CASE.handle(device, :case_sigma3, <<>>)
    end

    test "device in idle rejects sigma3" do
      device = new_device(1, 10)
      assert {:error, :unexpected_message} = CASE.handle(device, :case_sigma3, <<0>>)
    end

    test "initiator in idle rejects sigma2" do
      init = new_initiator(2, 20, 1)
      assert {:error, :unexpected_message} = CASE.handle(init, :case_sigma2, <<0>>)
    end
  end
end
