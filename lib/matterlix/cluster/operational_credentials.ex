defmodule Matterlix.Cluster.OperationalCredentials do
  @moduledoc """
  Matter Operational Credentials cluster (0x003E).

  Handles CSR generation and NOC installation during commissioning. Endpoint 0 only.
  Supports multiple fabrics with auto-assigned fabric_index.
  """

  use Matterlix.Cluster, id: 0x003E, name: :operational_credentials

  alias Matterlix.CASE.Messages, as: CASEMessages
  alias Matterlix.Commissioning
  alias Matterlix.Crypto.Certificate
  alias Matterlix.TLV

  attribute 0x0000, :nocs, :list, default: []
  attribute 0x0001, :fabrics, :list, default: []
  attribute 0x0002, :supported_fabrics, :uint8, default: 5
  attribute 0x0003, :commissioned_fabrics, :uint8, default: 0
  attribute 0x0004, :trusted_root_certificates, :list, default: []
  attribute 0x0005, :current_fabric_index, :uint8, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :attestation_request, [attestation_nonce: :bytes], response_id: 0x01
  command 0x02, :certificate_chain_request, [certificate_type: :uint8], response_id: 0x03
  command 0x04, :csr_request, [csr_nonce: :bytes], response_id: 0x05
  command 0x06, :add_noc, [noc_value: :bytes, icac_value: :bytes, ipk_value: :bytes, case_admin_subject: :uint64, admin_vendor_id: :uint16], response_id: 0x08
  command 0x0A, :remove_fabric, [fabric_index: :uint8], response_id: 0x08
  command 0x09, :update_fabric_label, [label: :string], response_id: 0x08
  command 0x0B, :add_trusted_root_cert, [root_ca_cert: :bytes]

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)
    # Generate persistent DAC keypair for attestation signing
    dac_keypair = Certificate.generate_keypair()
    state = state
      |> Map.put(:_next_fabric_index, 1)
      |> Map.put(:_dac_keypair, dac_keypair)
    {:ok, state}
  end

  @impl Matterlix.Cluster
  def handle_command(:attestation_request, params, state) do
    attestation_nonce = params[:attestation_nonce] || :crypto.strong_rand_bytes(32)

    # Build AttestationElements TLV: certification_declaration + attestation_nonce + timestamp
    certification_declaration = <<>>
    attestation_elements = TLV.encode(%{
      1 => {:bytes, certification_declaration},
      2 => {:bytes, attestation_nonce},
      3 => {:uint, System.system_time(:second)}
    })

    # TBS = AttestationElements || AttestationChallenge (from session)
    # chip-tool verifies: ECDSA_verify(SHA256(TBS), signature, dac_pubkey)
    {_pub, priv} = Map.fetch!(state, :_dac_keypair)
    challenge = get_in(params, [:_context, :attestation_challenge]) || <<>>
    tbs = attestation_elements <> challenge
    attestation_signature = Certificate.sign_raw(tbs, priv)

    # AttestationResponse: AttestationElements, AttestationSignature
    {:ok, %{0 => {:bytes, attestation_elements}, 1 => {:bytes, attestation_signature}}, state}
  end

  def handle_command(:certificate_chain_request, params, state) do
    cert_type = params[:certificate_type] || 1

    # Use persistent DAC keypair for both PAI (type 1) and DAC (type 2)
    {pub, priv} = Map.fetch!(state, :_dac_keypair)

    # Build a minimal DER-encoded self-signed X.509 certificate
    cert = Certificate.self_signed_der(pub, priv, "Matterlix #{if cert_type == 1, do: "PAI", else: "DAC"}")

    # CertificateChainResponse: Certificate
    {:ok, %{0 => {:bytes, cert}}, state}
  end

  def handle_command(:csr_request, params, state) do
    csr_nonce = params[:csr_nonce] || :crypto.strong_rand_bytes(32)
    {pub, priv} = Certificate.generate_keypair()

    # Store CSR keypair for AddNOC verification (separate from DAC keypair)
    state = Map.put(state, :_keypair, {pub, priv})

    # Also store in Commissioning Agent if available
    if Process.whereis(Commissioning) do
      Commissioning.store_keypair({pub, priv})
    end

    # Build NOCSR elements: TLV struct with PKCS#10 CSR and nonce
    csr = Certificate.build_csr(pub, priv)
    nocsr_elements = TLV.encode(%{1 => {:bytes, csr}, 2 => {:bytes, csr_nonce}})

    # TBS = NOCSRElements || AttestationChallenge (from session)
    # chip-tool verifies: ECDSA_verify(SHA256(TBS), signature, dac_pubkey)
    {_dac_pub, dac_priv} = Map.fetch!(state, :_dac_keypair)
    challenge = get_in(params, [:_context, :attestation_challenge]) || <<>>
    tbs = nocsr_elements <> challenge
    attestation_signature = Certificate.sign_raw(tbs, dac_priv)

    # NOCSRResponse: NOCSRElements, AttestationSignature
    {:ok, %{0 => {:bytes, nocsr_elements}, 1 => {:bytes, attestation_signature}}, state}
  end

  def handle_command(:add_trusted_root_cert, params, state) do
    root_cert = params[:root_ca_cert]

    if root_cert do
      require Logger
      Logger.debug("AddTrustedRootCert: #{byte_size(root_cert)}B")
    end

    if root_cert && Process.whereis(Commissioning) do
      Commissioning.store_root_cert(root_cert)
    end

    # Store root cert in the trusted_root_certificates attribute
    state =
      if root_cert do
        certs = Map.get(state, :trusted_root_certificates, [])
        Map.put(state, :trusted_root_certificates, certs ++ [root_cert])
      else
        state
      end

    {:ok, nil, state}
  end

  def handle_command(:remove_fabric, params, state) do
    fabric_index = params[:fabric_index] || 0

    nocs = Map.get(state, :nocs, [])
    fabrics = Map.get(state, :fabrics, [])

    get_fi = fn entry -> entry[254] |> elem(1) end

    if Enum.any?(fabrics, &(get_fi.(&1) == fabric_index)) do
      nocs = Enum.reject(nocs, &(get_fi.(&1) == fabric_index))
      fabrics = Enum.reject(fabrics, &(get_fi.(&1) == fabric_index))

      state = state
        |> Map.put(:nocs, nocs)
        |> Map.put(:fabrics, fabrics)
        |> Map.put(:commissioned_fabrics, length(nocs))

      # NOCResponse: StatusCode=Success(0)
      {:ok, %{0 => {:uint, 0}, 1 => {:uint, fabric_index}, 2 => {:string, ""}}, state}
    else
      # NOCResponse: StatusCode=InvalidFabricIndex(11)
      {:ok, %{0 => {:uint, 11}, 1 => {:uint, 0}, 2 => {:string, "unknown fabric"}}, state}
    end
  end

  def handle_command(:update_fabric_label, params, state) do
    # In a real impl, the fabric_index comes from the session context.
    # For simplicity, update the most recently added fabric's label.
    label = params[:label] || ""
    fabrics = Map.get(state, :fabrics, [])

    case fabrics do
      [] ->
        {:ok, %{0 => {:uint, 11}, 1 => {:uint, 0}, 2 => {:string, "no fabrics"}}, state}

      _ ->
        # Update the last fabric's label (in production, derive from session)
        updated = List.update_at(fabrics, -1, &Map.put(&1, 5, {:string, label}))
        state = Map.put(state, :fabrics, updated)
        {:uint, last_fi} = List.last(updated)[254]
        {:ok, %{0 => {:uint, 0}, 1 => {:uint, last_fi}, 2 => {:string, ""}}, state}
    end
  end

  def handle_command(:add_noc, params, state) do
    require Logger
    noc_value = params[:noc_value]
    ipk_value = params[:ipk_value]
    Logger.debug("AddNOC: noc=#{if noc_value, do: byte_size(noc_value)}B ipk=#{if ipk_value, do: "#{Base.encode16(ipk_value)}(#{byte_size(ipk_value)}B)", else: "nil"} all_keys=#{inspect(Map.keys(params) -- [:_context])}")

    case CASEMessages.decode_noc(noc_value) do
      {:ok, %{node_id: node_id, fabric_id: fabric_id, public_key: pub_key}} ->
        Logger.debug("AddNOC decoded: node_id=#{inspect(node_id)}(0x#{Integer.to_string(node_id || 0, 16)}) fabric_id=#{inspect(fabric_id)}(0x#{Integer.to_string(fabric_id || 0, 16)}) pub_key=#{if pub_key, do: byte_size(pub_key), else: "nil"}B")
        # Verify public key matches the keypair we generated during CSRRequest
        stored_keypair = Map.get(state, :_keypair)

        if stored_keypair && elem(stored_keypair, 0) == pub_key do
          # Assign fabric_index
          fabric_index = Map.get(state, :_next_fabric_index, 1)

          if Process.whereis(Commissioning) do
            icac_value = params[:icac_value]
            Commissioning.store_noc(fabric_index, noc_value, icac_value, ipk_value, node_id, fabric_id)

            # Store the admin subject for ACL seeding
            case_admin_subject = params[:case_admin_subject]

            if case_admin_subject do
              Commissioning.store_admin_subject(fabric_index, case_admin_subject)
            end
          end

          # Update nocs list (TLV-tagged: tag 0=NOC, 1=ICAC, 254=FabricIndex)
          nocs = Map.get(state, :nocs, [])
          noc_entry = %{
            0 => {:bytes, noc_value},
            1 => {:bytes, params[:icac_value] || <<>>},
            254 => {:uint, fabric_index}
          }
          nocs = nocs ++ [noc_entry]

          # Update fabrics list (TLV-tagged: 1=RootPubKey, 2=VendorID, 3=FabricID, 4=NodeID, 5=Label, 254=FabricIndex)
          fabrics = Map.get(state, :fabrics, [])
          fabric_entry = %{
            1 => {:bytes, <<>>},
            2 => {:uint, params[:admin_vendor_id] || 0},
            3 => {:uint, fabric_id},
            4 => {:uint, node_id},
            5 => {:string, ""},
            254 => {:uint, fabric_index}
          }
          fabrics = fabrics ++ [fabric_entry]

          state = state
            |> Map.put(:nocs, nocs)
            |> Map.put(:fabrics, fabrics)
            |> Map.put(:commissioned_fabrics, length(nocs))
            |> Map.put(:_next_fabric_index, fabric_index + 1)

          # NOCResponse: StatusCode=Success(0), FabricIndex, DebugText=""
          {:ok, %{0 => {:uint, 0}, 1 => {:uint, fabric_index}, 2 => {:string, ""}}, state}
        else
          # NOCResponse: StatusCode=InvalidPublicKey(1)
          {:ok, %{0 => {:uint, 1}, 1 => {:uint, 0}, 2 => {:string, "public key mismatch"}}, state}
        end

      {:error, _reason} ->
        # NOCResponse: StatusCode=InvalidNOC(3)
        {:ok, %{0 => {:uint, 3}, 1 => {:uint, 0}, 2 => {:string, "invalid NOC"}}, state}
    end
  end
end
