defmodule Matterlix.Protocol.ProtocolID do
  @moduledoc """
  Matter protocol ID constants and opcode lookup.
  """

  # Protocol IDs (wire format, uint16)
  @secure_channel 0x0000
  @interaction_model 0x0001
  @bdx 0x0002
  @user_directed_commissioning 0x0003

  @type protocol :: :secure_channel | :interaction_model | :bdx | :user_directed_commissioning | {:unknown, non_neg_integer()}
  @type opcode :: atom() | {:unknown, non_neg_integer()}

  # ── Protocol name lookup ──────────────────────────────────────────

  @spec protocol_name(non_neg_integer()) :: protocol()
  def protocol_name(@secure_channel), do: :secure_channel
  def protocol_name(@interaction_model), do: :interaction_model
  def protocol_name(@bdx), do: :bdx
  def protocol_name(@user_directed_commissioning), do: :user_directed_commissioning
  def protocol_name(n), do: {:unknown, n}

  # ── Reverse: protocol atom to ID ──────────────────────────────────

  @spec protocol_id(atom()) :: non_neg_integer()
  def protocol_id(:secure_channel), do: @secure_channel
  def protocol_id(:interaction_model), do: @interaction_model
  def protocol_id(:bdx), do: @bdx
  def protocol_id(:user_directed_commissioning), do: @user_directed_commissioning

  # ── Opcode name lookup ────────────────────────────────────────────

  @spec opcode_name(non_neg_integer(), non_neg_integer()) :: opcode()
  # Secure Channel
  def opcode_name(@secure_channel, 0x00), do: :msg_counter_sync_request
  def opcode_name(@secure_channel, 0x01), do: :msg_counter_sync_response
  def opcode_name(@secure_channel, 0x10), do: :standalone_ack
  def opcode_name(@secure_channel, 0x20), do: :pbkdf_param_request
  def opcode_name(@secure_channel, 0x21), do: :pbkdf_param_response
  def opcode_name(@secure_channel, 0x22), do: :pase_pake1
  def opcode_name(@secure_channel, 0x23), do: :pase_pake2
  def opcode_name(@secure_channel, 0x24), do: :pase_pake3
  def opcode_name(@secure_channel, 0x30), do: :case_sigma1
  def opcode_name(@secure_channel, 0x31), do: :case_sigma2
  def opcode_name(@secure_channel, 0x32), do: :case_sigma3
  def opcode_name(@secure_channel, 0x33), do: :case_sigma2_resume
  def opcode_name(@secure_channel, 0x40), do: :status_report
  def opcode_name(@secure_channel, 0x50), do: :icd_check_in
  # Interaction Model
  def opcode_name(@interaction_model, 0x01), do: :status_response
  def opcode_name(@interaction_model, 0x02), do: :read_request
  def opcode_name(@interaction_model, 0x03), do: :subscribe_request
  def opcode_name(@interaction_model, 0x04), do: :subscribe_response
  def opcode_name(@interaction_model, 0x05), do: :report_data
  def opcode_name(@interaction_model, 0x06), do: :write_request
  def opcode_name(@interaction_model, 0x07), do: :write_response
  def opcode_name(@interaction_model, 0x08), do: :invoke_request
  def opcode_name(@interaction_model, 0x09), do: :invoke_response
  def opcode_name(@interaction_model, 0x0A), do: :timed_request
  # Unknown
  def opcode_name(_protocol, n), do: {:unknown, n}

  # ── Reverse: opcode atom to ID ────────────────────────────────────

  @spec opcode(atom(), atom()) :: non_neg_integer()
  def opcode(:secure_channel, :msg_counter_sync_request), do: 0x00
  def opcode(:secure_channel, :msg_counter_sync_response), do: 0x01
  def opcode(:secure_channel, :standalone_ack), do: 0x10
  def opcode(:secure_channel, :pbkdf_param_request), do: 0x20
  def opcode(:secure_channel, :pbkdf_param_response), do: 0x21
  def opcode(:secure_channel, :pase_pake1), do: 0x22
  def opcode(:secure_channel, :pase_pake2), do: 0x23
  def opcode(:secure_channel, :pase_pake3), do: 0x24
  def opcode(:secure_channel, :case_sigma1), do: 0x30
  def opcode(:secure_channel, :case_sigma2), do: 0x31
  def opcode(:secure_channel, :case_sigma3), do: 0x32
  def opcode(:secure_channel, :case_sigma2_resume), do: 0x33
  def opcode(:secure_channel, :status_report), do: 0x40
  def opcode(:secure_channel, :icd_check_in), do: 0x50
  def opcode(:interaction_model, :status_response), do: 0x01
  def opcode(:interaction_model, :read_request), do: 0x02
  def opcode(:interaction_model, :subscribe_request), do: 0x03
  def opcode(:interaction_model, :subscribe_response), do: 0x04
  def opcode(:interaction_model, :report_data), do: 0x05
  def opcode(:interaction_model, :write_request), do: 0x06
  def opcode(:interaction_model, :write_response), do: 0x07
  def opcode(:interaction_model, :invoke_request), do: 0x08
  def opcode(:interaction_model, :invoke_response), do: 0x09
  def opcode(:interaction_model, :timed_request), do: 0x0A
end
