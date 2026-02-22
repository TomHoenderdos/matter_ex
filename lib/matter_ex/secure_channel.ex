defmodule MatterEx.SecureChannel do
  @moduledoc """
  Secure message framing for established Matter sessions.

  Pure functional module — caller threads session state through.
  Wraps the message codec, AES-CCM encryption, counter management,
  and replay protection into two operations:

  - `seal/2` — encrypt and frame an outgoing message
  - `open/2` — decrypt and verify an incoming frame
  """

  alias MatterEx.Session
  alias MatterEx.Protocol.{Counter, MessageCodec}
  alias MatterEx.Protocol.MessageCodec.{Header, ProtoHeader}

  @doc """
  Encrypt and frame an outgoing message.

  Builds a message header with the session's local session ID,
  increments the message counter, constructs the nonce, and
  encrypts the protocol header + payload with AES-128-CCM.

  Returns `{frame_binary, updated_session}`.
  """
  @spec seal(Session.t(), ProtoHeader.t()) :: {binary(), Session.t()}
  def seal(%Session{} = session, %ProtoHeader{} = proto) do
    {counter_val, new_counter} = Counter.next(session.counter)

    header = %Header{
      session_id: session.peer_session_id,
      message_counter: counter_val,
      source_node_id: if(session.local_node_id != 0, do: session.local_node_id, else: nil),
      privacy: false,
      session_type: :unicast
    }

    nonce = MessageCodec.build_nonce(
      encode_security_flags(header),
      counter_val,
      session.local_node_id
    )

    frame = IO.iodata_to_binary(
      MessageCodec.encode_encrypted(header, proto, session.encrypt_key, nonce)
    )

    {frame, %{session | counter: new_counter}}
  end

  @doc """
  Decrypt and verify an incoming encrypted frame.

  Parses the plaintext header, verifies the session ID matches,
  decrypts the payload, and checks the message counter for replay.

  Returns `{:ok, message, updated_session}` or `{:error, reason}`.
  """
  @spec open(Session.t(), binary()) :: {:ok, MessageCodec.message(), Session.t()} | {:error, atom()}
  def open(%Session{} = session, frame) when is_binary(frame) do
    with {:ok, header, _rest} <- Header.decode(frame),
         :ok <- verify_session_id(header, session),
         nonce = MessageCodec.build_nonce(
           header.security_flags,
           header.message_counter,
           session.peer_node_id
         ),
         {:ok, message} <- MessageCodec.decode_encrypted(frame, session.decrypt_key, nonce),
         {:ok, new_counter} <- Counter.check_and_update(session.counter, :peer, header.message_counter) do
      {:ok, message, %{session | counter: new_counter}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp verify_session_id(%Header{session_id: frame_session_id}, %Session{local_session_id: local_id}) do
    if frame_session_id == local_id do
      :ok
    else
      {:error, :session_mismatch}
    end
  end

  defp encode_security_flags(%Header{} = h) do
    import Bitwise
    p = if h.privacy, do: 0x80, else: 0
    c = if h.control_message, do: 0x40, else: 0
    st = if h.session_type == :group, do: 1, else: 0
    p ||| c ||| st
  end
end
