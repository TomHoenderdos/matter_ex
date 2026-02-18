defmodule Matterlix.PASE do
  @moduledoc """
  PASE (Passcode Authenticated Session Establishment) state machine.

  Pure functional state machine — no GenServer. Caller threads state through.
  Implements both device (verifier) and commissioner (prover) roles.

  ## Device flow

      device = PASE.new_device(passcode: 20202021, salt: salt, iterations: 1000, local_session_id: 1)
      {:reply, :pbkdf_param_response, resp_payload, device} = PASE.handle(device, :pbkdf_param_request, req_payload)
      {:reply, :pase_pake2, pake2_payload, device} = PASE.handle(device, :pase_pake1, pake1_payload)
      {:established, :status_report, sr_payload, session, device} = PASE.handle(device, :pase_pake3, pake3_payload)

  ## Commissioner flow

      comm = PASE.new_commissioner(passcode: 20202021, local_session_id: 2)
      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
      {:send, :pase_pake1, pake1_payload, comm} = PASE.handle(comm, :pbkdf_param_response, resp_payload)
      {:send, :pase_pake3, pake3_payload, comm} = PASE.handle(comm, :pase_pake2, pake2_payload)
      {:established, session, comm} = PASE.handle(comm, :status_report, sr_payload)
  """

  alias Matterlix.Crypto.{SPAKE2Plus, KDF}
  alias Matterlix.PASE.Messages
  alias Matterlix.Protocol.StatusReport
  alias Matterlix.Session

  defstruct [
    :role,
    :state,
    :passcode,
    :salt,
    :iterations,
    :local_session_id,
    :peer_session_id,
    :verifier,
    :prover_context,
    :w0,
    :w1,
    :keys,
    :context_hash
  ]

  @type t :: %__MODULE__{}

  # ── Constructors ──────────────────────────────────────────────────

  @doc """
  Create a new device (verifier) PASE state.

  Required opts: `:passcode`, `:salt`, `:iterations`, `:local_session_id`
  """
  @spec new_device(keyword()) :: t()
  def new_device(opts) do
    passcode = Keyword.fetch!(opts, :passcode)
    salt = Keyword.fetch!(opts, :salt)
    iterations = Keyword.fetch!(opts, :iterations)
    local_session_id = Keyword.fetch!(opts, :local_session_id)

    verifier = SPAKE2Plus.compute_verifier(passcode, salt, iterations)

    %__MODULE__{
      role: :device,
      state: :idle,
      passcode: passcode,
      salt: salt,
      iterations: iterations,
      local_session_id: local_session_id,
      verifier: verifier
    }
  end

  @doc """
  Create a new commissioner (prover) PASE state.

  Required opts: `:passcode`, `:local_session_id`
  """
  @spec new_commissioner(keyword()) :: t()
  def new_commissioner(opts) do
    %__MODULE__{
      role: :commissioner,
      state: :idle,
      passcode: Keyword.fetch!(opts, :passcode),
      local_session_id: Keyword.fetch!(opts, :local_session_id)
    }
  end

  # ── Commissioner: initiate ────────────────────────────────────────

  @doc """
  Commissioner initiates the PASE flow by sending a PBKDFParamRequest.
  """
  @spec initiate(t()) :: {:send, :pbkdf_param_request, binary(), t()}
  def initiate(%__MODULE__{role: :commissioner, state: :idle} = pase) do
    random = :crypto.strong_rand_bytes(32)

    payload = Messages.encode_pbkdf_param_request(random, pase.local_session_id)

    {:send, :pbkdf_param_request, payload,
     %{pase | state: :pbkdf_sent, context_hash: payload}}
  end

  # ── Handle incoming messages ──────────────────────────────────────

  @doc """
  Process an incoming PASE message. Dispatches based on role and state.
  """
  @spec handle(t(), atom(), binary()) ::
    {:reply, atom(), binary(), t()} |
    {:send, atom(), binary(), t()} |
    {:established, atom(), binary(), Session.t(), t()} |
    {:established, Session.t(), t()} |
    {:error, atom()}

  # Device: receive PBKDFParamRequest → reply PBKDFParamResponse
  def handle(%__MODULE__{role: :device, state: :idle} = pase, :pbkdf_param_request, payload) do
    case Messages.decode_pbkdf_param_request(payload) do
      {:ok, msg} ->
        responder_random = :crypto.strong_rand_bytes(32)

        response = Messages.encode_pbkdf_param_response(
          msg.initiator_random,
          responder_random,
          pase.local_session_id,
          pase.iterations,
          pase.salt
        )

        context = hash_context(payload, response)

        {:reply, :pbkdf_param_response, response,
         %{pase |
           state: :pbkdf_sent,
           peer_session_id: msg.initiator_session_id,
           context_hash: context
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Device: receive Pake1 → reply Pake2
  def handle(%__MODULE__{role: :device, state: :pbkdf_sent} = pase, :pase_pake1, payload) do
    case Messages.decode_pake1(payload) do
      {:ok, %{pa: pa}} ->
        {pb, keys} = SPAKE2Plus.verifier_respond(
          pa,
          %{w0: pase.verifier.w0, l: pase.verifier.l},
          context: pase.context_hash
        )

        response = Messages.encode_pake2(pb, keys.cb)

        {:reply, :pase_pake2, response,
         %{pase | state: :pake2_sent, keys: keys}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Device: receive Pake3 → verify cA → reply StatusReport → established
  def handle(%__MODULE__{role: :device, state: :pake2_sent} = pase, :pase_pake3, payload) do
    case Messages.decode_pake3(payload) do
      {:ok, %{ca: ca}} ->
        case SPAKE2Plus.verify_confirmation(pase.keys.ca, ca) do
          :ok ->
            sr = %StatusReport{
              general_code: StatusReport.general_success(),
              protocol_id: 0x0000,
              protocol_code: StatusReport.session_establishment_success()
            }

            sr_payload = StatusReport.encode(sr)

            session = Session.new(
              local_session_id: pase.local_session_id,
              peer_session_id: pase.peer_session_id,
              encryption_key: pase.keys.ke
            )

            {:established, :status_report, sr_payload, session,
             %{pase | state: :established}}

          {:error, :confirmation_failed} ->
            {:error, :confirmation_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Commissioner: receive PBKDFParamResponse → derive keys, send Pake1
  def handle(%__MODULE__{role: :commissioner, state: :pbkdf_sent} = pase, :pbkdf_param_response, payload) do
    case Messages.decode_pbkdf_param_response(payload) do
      {:ok, msg} ->
        %{iterations: iterations, salt: salt} = msg.pbkdf_parameters

        # Derive w0 and w1 from passcode using PBKDF parameters from device
        ws = KDF.pbkdf2_sha256(Integer.to_string(pase.passcode), salt, iterations, 80)
        w0s = binary_part(ws, 0, 40)
        w1s = binary_part(ws, 40, 40)

        w0 = Matterlix.Crypto.P256.scalar_mod_n(w0s)
        w1 = Matterlix.Crypto.P256.scalar_mod_n(w1s)

        w0_binary = <<w0::unsigned-big-256>>
        w1_binary = <<w1::unsigned-big-256>>

        context = hash_context(pase.context_hash, payload)

        {pa, prover_context} = SPAKE2Plus.prover_start(w0_binary)

        pake1_payload = Messages.encode_pake1(pa)

        {:send, :pase_pake1, pake1_payload,
         %{pase |
           state: :pake1_sent,
           peer_session_id: msg.responder_session_id,
           w0: w0_binary,
           w1: w1_binary,
           prover_context: prover_context,
           salt: salt,
           iterations: iterations,
           context_hash: context
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Commissioner: receive Pake2 → prover_finish, verify cB → send Pake3
  def handle(%__MODULE__{role: :commissioner, state: :pake1_sent} = pase, :pase_pake2, payload) do
    case Messages.decode_pake2(payload) do
      {:ok, %{pb: pb, cb: cb}} ->
        {:ok, keys} = SPAKE2Plus.prover_finish(
          pase.prover_context,
          pb,
          pase.w1,
          context: pase.context_hash
        )

        case SPAKE2Plus.verify_confirmation(keys.cb, cb) do
          :ok ->
            pake3_payload = Messages.encode_pake3(keys.ca)

            {:send, :pase_pake3, pake3_payload,
             %{pase | state: :pake3_sent, keys: keys}}

          {:error, :confirmation_failed} ->
            {:error, :confirmation_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Commissioner: receive StatusReport → established
  def handle(%__MODULE__{role: :commissioner, state: :pake3_sent} = pase, :status_report, payload) do
    case StatusReport.decode(payload) do
      {:ok, %StatusReport{general_code: 0, protocol_code: 0}} ->
        session = Session.new(
          local_session_id: pase.local_session_id,
          peer_session_id: pase.peer_session_id,
          encryption_key: pase.keys.ke
        )

        {:established, session, %{pase | state: :established}}

      {:ok, _sr} ->
        {:error, :session_establishment_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Catch-all: wrong state or unexpected message
  def handle(%__MODULE__{}, _opcode, _payload) do
    {:error, :unexpected_message}
  end

  # ── Private ───────────────────────────────────────────────────────

  # Build context hash: SHA-256 of concatenated request + response payloads.
  # For the first call (request only), response is nil.
  # For the second call (commissioner updating context), first arg is the
  # existing hash from the request we sent, second is the response we received.
  defp hash_context(first, nil) do
    :crypto.hash(:sha256, first)
  end

  defp hash_context(first, second) when is_binary(first) and is_binary(second) do
    :crypto.hash(:sha256, first <> second)
  end
end
