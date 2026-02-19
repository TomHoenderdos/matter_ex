defmodule Matterlix.Cluster.OperationalCredentials do
  @moduledoc """
  Matter Operational Credentials cluster (0x003E).

  Handles CSR generation and NOC installation during commissioning. Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x003E, name: :operational_credentials

  alias Matterlix.CASE.Messages, as: CASEMessages
  alias Matterlix.Commissioning
  alias Matterlix.Crypto.Certificate
  alias Matterlix.TLV

  attribute 0x0000, :nocs, :list, default: []
  attribute 0x0001, :fabrics, :list, default: []
  attribute 0x0003, :supported_fabrics, :uint8, default: 1
  attribute 0x0004, :commissioned_fabrics, :uint8, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x04, :csr_request, [csr_nonce: :bytes]
  command 0x06, :add_noc, [noc_value: :bytes, ipk_value: :bytes, case_admin_subject: :uint64, admin_vendor_id: :uint16]
  command 0x0B, :add_trusted_root_cert, [root_ca_cert: :bytes]

  @impl Matterlix.Cluster
  def handle_command(:csr_request, params, state) do
    csr_nonce = params[:csr_nonce] || :crypto.strong_rand_bytes(32)
    {pub, priv} = Certificate.generate_keypair()

    # Store keypair in cluster state for AddNOC verification
    state = Map.put(state, :_keypair, {pub, priv})

    # Also store in Commissioning Agent if available
    if Process.whereis(Commissioning) do
      Commissioning.store_keypair({pub, priv})
    end

    # Build NOCSR elements: TLV struct with public key and nonce
    nocsr_elements = TLV.encode(%{1 => {:bytes, pub}, 2 => {:bytes, csr_nonce}})

    # Self-sign the NOCSR elements (simplified attestation)
    attestation_signature = Certificate.sign(nocsr_elements, priv)

    # NOCSRResponse: NOCSRElements, AttestationSignature
    {:ok, %{0 => {:bytes, nocsr_elements}, 1 => {:bytes, attestation_signature}}, state}
  end

  def handle_command(:add_trusted_root_cert, params, state) do
    root_cert = params[:root_ca_cert]

    if root_cert && Process.whereis(Commissioning) do
      Commissioning.store_root_cert(root_cert)
    end

    {:ok, nil, state}
  end

  def handle_command(:add_noc, params, state) do
    noc_value = params[:noc_value]
    ipk_value = params[:ipk_value]

    case CASEMessages.decode_noc(noc_value) do
      {:ok, %{node_id: node_id, fabric_id: fabric_id, public_key: pub_key}} ->
        # Verify public key matches the keypair we generated during CSRRequest
        stored_keypair = Map.get(state, :_keypair)

        if stored_keypair && elem(stored_keypair, 0) == pub_key do
          if Process.whereis(Commissioning) do
            Commissioning.store_noc(noc_value, ipk_value, node_id, fabric_id)

            # Store the admin subject for ACL seeding
            case_admin_subject = params[:case_admin_subject]

            if case_admin_subject do
              Commissioning.store_admin_subject(case_admin_subject)
            end
          end

          state = set_attribute(state, :commissioned_fabrics, 1)

          # NOCResponse: StatusCode=Success(0), FabricIndex=1, DebugText=""
          {:ok, %{0 => {:uint, 0}, 1 => {:uint, 1}, 2 => {:string, ""}}, state}
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
