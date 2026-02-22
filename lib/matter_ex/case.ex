defmodule MatterEx.CASE do
  @moduledoc """
  CASE (Certificate Authenticated Session Establishment) state machine.

  Pure functional state machine — no GenServer. Caller threads state through.
  Implements both device (responder) and initiator roles using the Sigma protocol.

  ## Device flow

      device = CASE.new_device(noc: noc, private_key: priv, ipk: ipk,
                               node_id: 1, fabric_id: 1, local_session_id: 1)
      {:reply, :case_sigma2, sigma2, device} = CASE.handle(device, :case_sigma1, sigma1)
      {:established, :status_report, sr, session, device} = CASE.handle(device, :case_sigma3, sigma3)

  ## Initiator flow

      init = CASE.new_initiator(noc: noc, private_key: priv, ipk: ipk,
                                node_id: 2, fabric_id: 1, local_session_id: 2,
                                peer_node_id: 1, peer_fabric_id: 1)
      {:send, :case_sigma1, sigma1, init} = CASE.initiate(init)
      {:send, :case_sigma3, sigma3, init} = CASE.handle(init, :case_sigma2, sigma2)
      {:established, session, init} = CASE.handle(init, :status_report, sr)
  """

  require Logger

  alias MatterEx.CASE.Messages
  alias MatterEx.Crypto.Certificate
  alias MatterEx.Protocol.StatusReport
  alias MatterEx.Session

  defstruct [
    :role,
    :state,
    :noc,
    :icac,
    :private_key,
    :ipk,
    :root_public_key,
    :node_id,
    :fabric_id,
    :fabric_index,
    :local_session_id,
    :peer_session_id,
    :peer_node_id,
    :peer_fabric_id,
    :eph_priv,
    :eph_pub,
    :peer_eph_pub,
    :shared_secret,
    :transcript,
    skip_dest_check: false
  ]

  @type t :: %__MODULE__{}

  # ── Constructors ──────────────────────────────────────────────────

  @doc """
  Create a new device (responder) CASE state.

  Required opts: `:noc`, `:private_key`, `:ipk`, `:node_id`, `:fabric_id`, `:local_session_id`
  Optional: `:icac`, `:fabric_index`, `:root_public_key`
  """
  @spec new_device(keyword()) :: t()
  def new_device(opts) do
    %__MODULE__{
      role: :device,
      state: :idle,
      noc: Keyword.fetch!(opts, :noc),
      icac: Keyword.get(opts, :icac),
      private_key: Keyword.fetch!(opts, :private_key),
      ipk: Keyword.fetch!(opts, :ipk),
      root_public_key: Keyword.get(opts, :root_public_key),
      node_id: Keyword.fetch!(opts, :node_id),
      fabric_id: Keyword.fetch!(opts, :fabric_id),
      fabric_index: Keyword.get(opts, :fabric_index, 1),
      local_session_id: Keyword.fetch!(opts, :local_session_id)
    }
  end

  @doc """
  Create a new initiator CASE state.

  Required opts: `:noc`, `:private_key`, `:ipk`, `:node_id`, `:fabric_id`,
                 `:local_session_id`, `:peer_node_id`, `:peer_fabric_id`
  Optional: `:icac`, `:root_public_key`
  """
  @spec new_initiator(keyword()) :: t()
  def new_initiator(opts) do
    %__MODULE__{
      role: :initiator,
      state: :idle,
      noc: Keyword.fetch!(opts, :noc),
      icac: Keyword.get(opts, :icac),
      private_key: Keyword.fetch!(opts, :private_key),
      ipk: Keyword.fetch!(opts, :ipk),
      root_public_key: Keyword.get(opts, :root_public_key),
      node_id: Keyword.fetch!(opts, :node_id),
      fabric_id: Keyword.fetch!(opts, :fabric_id),
      fabric_index: Keyword.get(opts, :fabric_index, 1),
      local_session_id: Keyword.fetch!(opts, :local_session_id),
      peer_node_id: Keyword.fetch!(opts, :peer_node_id),
      peer_fabric_id: Keyword.fetch!(opts, :peer_fabric_id)
    }
  end

  # ── Initiator: initiate ───────────────────────────────────────────

  @doc """
  Initiator starts the CASE flow by sending Sigma1.
  """
  @spec initiate(t()) :: {:send, :case_sigma1, binary(), t()}
  def initiate(%__MODULE__{role: :initiator, state: :idle} = cs) do
    random = :crypto.strong_rand_bytes(32)
    {eph_pub, eph_priv} = Certificate.generate_keypair()

    dest_id = Messages.compute_destination_id(
      cs.ipk, random, cs.root_public_key || <<>>, cs.peer_fabric_id, cs.peer_node_id
    )

    payload = Messages.encode_sigma1(random, cs.local_session_id, dest_id, eph_pub)

    {:send, :case_sigma1, payload,
     %{cs |
       state: :sigma1_sent,
       eph_priv: eph_priv,
       eph_pub: eph_pub,
       transcript: payload
     }}
  end

  # ── Handle incoming messages ──────────────────────────────────────

  @spec handle(t(), atom(), binary()) ::
    {:reply, atom(), binary(), t()}
    | {:send, atom(), binary(), t()}
    | {:established, atom(), binary(), Session.t(), t()}
    | {:established, Session.t(), t()}
    | {:error, atom()}

  # Device: receive Sigma1 → reply Sigma2
  def handle(%__MODULE__{role: :device, state: :idle} = cs, :case_sigma1, payload) do
    case Messages.decode_sigma1(payload) do
      {:ok, msg} ->
        if msg.resumption_id do
          Logger.debug("CASE: resumption requested, falling back to full CASE")
        end

        # Verify destination_id
        rpk = cs.root_public_key || <<>>

        Logger.debug("CASE dest_id inputs: ipk=#{Base.encode16(cs.ipk)}(#{byte_size(cs.ipk)}B) " <>
          "random=#{Base.encode16(msg.initiator_random)}(#{byte_size(msg.initiator_random)}B) " <>
          "rpk=#{Base.encode16(rpk)}(#{byte_size(rpk)}B) " <>
          "fabric_id=#{cs.fabric_id} node_id=#{cs.node_id}")

        expected_dest = Messages.compute_destination_id(
          cs.ipk, msg.initiator_random, rpk, cs.fabric_id, cs.node_id
        )

        if expected_dest == msg.destination_id or cs.skip_dest_check do
          process_sigma1(cs, msg, payload)
        else
          Logger.debug("CASE dest_id mismatch: expected=#{Base.encode16(expected_dest)} got=#{Base.encode16(msg.destination_id)}")
          {:error, :destination_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Device: receive Sigma3 → verify → established
  def handle(%__MODULE__{role: :device, state: :sigma2_sent} = cs, :case_sigma3, payload) do
    case Messages.decode_sigma3(payload) do
      {:ok, msg} ->
        process_sigma3(cs, msg, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Initiator: receive Sigma2 → verify → send Sigma3
  def handle(%__MODULE__{role: :initiator, state: :sigma1_sent} = cs, :case_sigma2, payload) do
    case Messages.decode_sigma2(payload) do
      {:ok, msg} ->
        process_sigma2(cs, msg, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Initiator: receive StatusReport → established
  def handle(%__MODULE__{role: :initiator, state: :sigma3_sent} = cs, :status_report, payload) do
    case StatusReport.decode(payload) do
      {:ok, %StatusReport{general_code: 0, protocol_code: 0}} ->
        # Session salt = IPK || SHA256(full transcript)
        session_salt = cs.ipk <> :crypto.hash(:sha256, cs.transcript)

        session = Session.new(
          local_session_id: cs.local_session_id,
          peer_session_id: cs.peer_session_id,
          encryption_key: cs.shared_secret,
          salt: session_salt,
          role: :initiator,
          local_node_id: cs.node_id,
          peer_node_id: cs.peer_node_id,
          auth_mode: :case,
          fabric_index: cs.fabric_index
        )

        {:established, session, %{cs | state: :established}}

      {:ok, _sr} ->
        {:error, :session_establishment_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Catch-all: unexpected message
  def handle(%__MODULE__{}, _opcode, _payload) do
    {:error, :unexpected_message}
  end

  # ── Device: process Sigma1 ────────────────────────────────────────

  defp process_sigma1(cs, msg, sigma1_bytes) do
    # Generate ephemeral keypair
    {eph_pub, eph_priv} = Certificate.generate_keypair()

    # Compute ECDH shared secret
    shared_secret = Certificate.ecdh(msg.initiator_eph_pub, eph_priv)

    # Generate responder random (used in both S2K salt and Sigma2 message)
    responder_random = :crypto.strong_rand_bytes(32)

    # Transcript hash at this point = SHA256(sigma1 only)
    transcript_hash = :crypto.hash(:sha256, sigma1_bytes)

    # Derive S2K with proper salt: IPK || random || eph_pub || transcript_hash
    s2k = Messages.derive_sigma2_key(cs.ipk, shared_secret, responder_random, eph_pub, transcript_hash)

    # Build TBS as TLV structure: {1:NOC, 2:ICAC, 3:sender_eph, 4:receiver_eph}
    tbs2 = Messages.build_tbs(cs.noc, cs.icac, eph_pub, msg.initiator_eph_pub)

    # Sign with device's operational key (raw P1363 format for Matter)
    signature = Certificate.sign_raw(tbs2, cs.private_key)

    # Build and encrypt TBEData2
    resumption_id = :crypto.strong_rand_bytes(16)
    tbe_plaintext = Messages.encode_tbe_data2(cs.noc, cs.icac, signature, resumption_id)
    encrypted2 = Messages.encrypt_tbe(:sigma2, s2k, tbe_plaintext)

    # Build Sigma2 response (same responder_random used in salt)
    sigma2_payload = Messages.encode_sigma2(
      responder_random,
      cs.local_session_id,
      eph_pub,
      encrypted2
    )

    {:reply, :case_sigma2, sigma2_payload,
     %{cs |
       state: :sigma2_sent,
       eph_priv: eph_priv,
       eph_pub: eph_pub,
       peer_eph_pub: msg.initiator_eph_pub,
       peer_session_id: msg.initiator_session_id,
       shared_secret: shared_secret,
       transcript: sigma1_bytes <> sigma2_payload
     }}
  end

  # ── Initiator: process Sigma2 ─────────────────────────────────────

  defp process_sigma2(cs, msg, sigma2_bytes) do
    # Compute ECDH shared secret
    shared_secret = Certificate.ecdh(msg.responder_eph_pub, cs.eph_priv)

    # Transcript hash = SHA256(sigma1 only)
    transcript_hash = :crypto.hash(:sha256, cs.transcript)

    # Derive S2K with proper salt: IPK || random || eph_pub || transcript_hash
    s2k = Messages.derive_sigma2_key(cs.ipk, shared_secret, msg.responder_random, msg.responder_eph_pub, transcript_hash)

    case Messages.decrypt_tbe(:sigma2, s2k, msg.encrypted2) do
      {:ok, tbe_plaintext} ->
        case Messages.decode_tbe_data2(tbe_plaintext) do
          {:ok, tbe} ->
            verify_and_send_sigma3(cs, msg, sigma2_bytes, shared_secret, tbe)

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :decryption_failed}
    end
  end

  defp verify_and_send_sigma3(cs, msg, sigma2_bytes, shared_secret, tbe) do
    # Extract responder's public key from NOC
    case Messages.decode_noc(tbe.noc) do
      {:ok, %{public_key: responder_pub}} ->
        # Build TBS as TLV structure for verification
        tbs2 = Messages.build_tbs(tbe.noc, tbe.icac, msg.responder_eph_pub, cs.eph_pub)

        if Certificate.verify_raw(tbs2, tbe.signature, responder_pub) do
          build_sigma3(cs, msg, sigma2_bytes, shared_secret)
        else
          {:error, :signature_verification_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_sigma3(cs, msg, sigma2_bytes, shared_secret) do
    transcript = cs.transcript <> sigma2_bytes

    # Transcript hash = SHA256(sigma1 || sigma2)
    transcript_hash = :crypto.hash(:sha256, transcript)

    # Derive S3K with proper salt: IPK || transcript_hash
    s3k = Messages.derive_sigma3_key(cs.ipk, shared_secret, transcript_hash)

    # Build TBS as TLV structure
    tbs3 = Messages.build_tbs(cs.noc, cs.icac, cs.eph_pub, msg.responder_eph_pub)

    # Sign with initiator's operational key (raw P1363 format)
    signature = Certificate.sign_raw(tbs3, cs.private_key)

    # Build and encrypt TBEData3
    tbe_plaintext = Messages.encode_tbe_data3(cs.noc, cs.icac, signature)
    encrypted3 = Messages.encrypt_tbe(:sigma3, s3k, tbe_plaintext)

    sigma3_payload = Messages.encode_sigma3(encrypted3)

    {:send, :case_sigma3, sigma3_payload,
     %{cs |
       state: :sigma3_sent,
       peer_session_id: msg.responder_session_id,
       peer_eph_pub: msg.responder_eph_pub,
       shared_secret: shared_secret,
       transcript: transcript <> sigma3_payload
     }}
  end

  # ── Device: process Sigma3 ────────────────────────────────────────

  defp process_sigma3(cs, msg, sigma3_bytes) do
    # Transcript hash = SHA256(sigma1 || sigma2)
    transcript_hash = :crypto.hash(:sha256, cs.transcript)

    # Derive S3K with proper salt: IPK || transcript_hash
    s3k = Messages.derive_sigma3_key(cs.ipk, cs.shared_secret, transcript_hash)

    case Messages.decrypt_tbe(:sigma3, s3k, msg.encrypted3) do
      {:ok, tbe_plaintext} ->
        case Messages.decode_tbe_data3(tbe_plaintext) do
          {:ok, tbe} ->
            verify_sigma3_and_establish(cs, tbe, sigma3_bytes)

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :decryption_failed}
    end
  end

  defp verify_sigma3_and_establish(cs, tbe, sigma3_bytes) do
    # Extract initiator's public key from NOC
    case Messages.decode_noc(tbe.noc) do
      {:ok, %{public_key: initiator_pub, node_id: peer_node_id}} ->
        # Build TBS as TLV structure for verification
        tbs3 = Messages.build_tbs(tbe.noc, tbe.icac, cs.peer_eph_pub, cs.eph_pub)

        if Certificate.verify_raw(tbs3, tbe.signature, initiator_pub) do
          # Full transcript = sigma1 || sigma2 || sigma3
          full_transcript = cs.transcript <> sigma3_bytes
          session_salt = cs.ipk <> :crypto.hash(:sha256, full_transcript)

          # Build status report and session
          sr = %StatusReport{
            general_code: StatusReport.general_success(),
            protocol_id: 0x0000,
            protocol_code: StatusReport.session_establishment_success()
          }

          sr_payload = StatusReport.encode(sr)

          session = Session.new(
            local_session_id: cs.local_session_id,
            peer_session_id: cs.peer_session_id,
            encryption_key: cs.shared_secret,
            salt: session_salt,
            role: :responder,
            local_node_id: cs.node_id,
            peer_node_id: peer_node_id,
            auth_mode: :case,
            fabric_index: cs.fabric_index
          )

          {:established, :status_report, sr_payload, session,
           %{cs | state: :established, peer_node_id: peer_node_id}}
        else
          {:error, :signature_verification_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
