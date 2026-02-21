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
  attribute 0x0003, :supported_fabrics, :uint8, default: 5
  attribute 0x0004, :commissioned_fabrics, :uint8, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x04, :csr_request, [csr_nonce: :bytes]
  command 0x06, :add_noc, [noc_value: :bytes, ipk_value: :bytes, case_admin_subject: :uint64, admin_vendor_id: :uint16]
  command 0x0A, :remove_fabric, [fabric_index: :uint8]
  command 0x09, :update_fabric_label, [label: :string]
  command 0x0B, :add_trusted_root_cert, [root_ca_cert: :bytes]

  def init(opts) do
    {:ok, state} = super(opts)
    # Track next available fabric index (internal, not an attribute)
    {:ok, Map.put(state, :_next_fabric_index, 1)}
  end

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

  def handle_command(:remove_fabric, params, state) do
    fabric_index = params[:fabric_index] || 0

    nocs = Map.get(state, :nocs, [])
    fabrics = Map.get(state, :fabrics, [])

    if Enum.any?(fabrics, &(&1.fabric_index == fabric_index)) do
      nocs = Enum.reject(nocs, &(&1.fabric_index == fabric_index))
      fabrics = Enum.reject(fabrics, &(&1.fabric_index == fabric_index))

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
        updated = List.update_at(fabrics, -1, &Map.put(&1, :label, label))
        state = Map.put(state, :fabrics, updated)
        last_fi = List.last(updated).fabric_index
        {:ok, %{0 => {:uint, 0}, 1 => {:uint, last_fi}, 2 => {:string, ""}}, state}
    end
  end

  def handle_command(:add_noc, params, state) do
    noc_value = params[:noc_value]
    ipk_value = params[:ipk_value]

    case CASEMessages.decode_noc(noc_value) do
      {:ok, %{node_id: node_id, fabric_id: fabric_id, public_key: pub_key}} ->
        # Verify public key matches the keypair we generated during CSRRequest
        stored_keypair = Map.get(state, :_keypair)

        if stored_keypair && elem(stored_keypair, 0) == pub_key do
          # Assign fabric_index
          fabric_index = Map.get(state, :_next_fabric_index, 1)

          if Process.whereis(Commissioning) do
            Commissioning.store_noc(fabric_index, noc_value, ipk_value, node_id, fabric_id)

            # Store the admin subject for ACL seeding
            case_admin_subject = params[:case_admin_subject]

            if case_admin_subject do
              Commissioning.store_admin_subject(fabric_index, case_admin_subject)
            end
          end

          # Update nocs list
          nocs = Map.get(state, :nocs, [])
          noc_entry = %{fabric_index: fabric_index, noc: noc_value, icac: nil}
          nocs = nocs ++ [noc_entry]

          # Update fabrics list
          fabrics = Map.get(state, :fabrics, [])
          fabric_entry = %{
            fabric_index: fabric_index,
            root_public_key: <<>>,
            vendor_id: params[:admin_vendor_id] || 0,
            fabric_id: fabric_id,
            node_id: node_id,
            label: ""
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
