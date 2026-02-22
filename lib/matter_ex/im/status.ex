defmodule MatterEx.IM.Status do
  @moduledoc """
  Matter Interaction Model status codes (spec section 8.10).
  """

  @codes %{
    success: 0x00,
    failure: 0x01,
    invalid_subscription: 0x7D,
    unsupported_access: 0x7E,
    unsupported_endpoint: 0x7F,
    invalid_action: 0x80,
    unsupported_command: 0x81,
    invalid_command: 0x85,
    unsupported_attribute: 0x86,
    constraint_error: 0x87,
    unsupported_write: 0x88,
    resource_exhausted: 0x89,
    not_found: 0x8B,
    unreportable_attribute: 0x8C,
    invalid_data_type: 0x8D,
    unsupported_read: 0x8F,
    data_version_mismatch: 0x92,
    timeout: 0xF6,
    busy: 0x9C,
    unsupported_cluster: 0xC3,
    no_upstream_subscription: 0xC5,
    needs_timed_interaction: 0xC6,
    unsupported_event: 0xC7,
    paths_exhausted: 0xC8,
    timed_request_mismatch: 0xC9,
    failsafe_required: 0xCA
  }

  @reverse Map.new(@codes, fn {k, v} -> {v, k} end)

  @spec status_name(non_neg_integer()) :: atom() | {:unknown, non_neg_integer()}
  def status_name(code) do
    Map.get(@reverse, code, {:unknown, code})
  end

  @spec status_code(atom()) :: non_neg_integer()
  def status_code(name) do
    Map.fetch!(@codes, name)
  end
end
