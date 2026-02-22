defmodule Matterlix.ACL do
  @moduledoc """
  Pure-function ACL engine for Matter access control.

  Evaluates whether a given subject/fabric has sufficient privilege
  for a requested operation on a target. No state — just pattern matching.
  """

  @type privilege :: :view | :proxy_view | :operate | :manage | :administer
  @type auth_mode :: :pase | :case | :group

  @type acl_entry :: %{
    privilege: 1..5,
    auth_mode: 2 | 3,
    subjects: [non_neg_integer()] | nil,
    targets: [map()] | nil,
    fabric_index: non_neg_integer()
  }

  @type context :: %{
    auth_mode: auth_mode(),
    subject: non_neg_integer(),
    fabric_index: non_neg_integer()
  }

  @privilege_levels %{
    view: 1,
    proxy_view: 2,
    operate: 3,
    manage: 4,
    administer: 5
  }

  @doc """
  Check whether the given context has sufficient privilege for the target.

  PASE sessions always get implicit admin access (bypass ACL).
  CASE sessions are checked against the ACL entries.
  """
  @spec check(context(), [acl_entry()], privilege(), {non_neg_integer(), non_neg_integer()}) ::
          :allow | :deny
  def check(%{auth_mode: :pase}, _acl_entries, _required_privilege, _target) do
    :allow
  end

  def check(context, acl_entries, required_privilege, target) do
    required_level = Map.fetch!(@privilege_levels, required_privilege)

    if Enum.any?(acl_entries, fn entry ->
         matches_fabric?(entry, context) &&
           matches_auth_mode?(entry, context) &&
           matches_subject?(entry, context) &&
           matches_target?(entry, target) &&
           get_field(entry, :privilege, 1) >= required_level
       end) do
      :allow
    else
      :deny
    end
  end

  @doc """
  Return the minimum privilege required for an IM operation.
  """
  @spec required_privilege(atom()) :: privilege()
  def required_privilege(:read_request), do: :view
  def required_privilege(:subscribe_request), do: :view
  def required_privilege(:write_request), do: :operate
  def required_privilege(:invoke_request), do: :operate

  @doc """
  Return the privilege required to write a specific cluster's attributes.
  The Access Control cluster (0x001F) requires Administer privilege.
  """
  @spec write_privilege(non_neg_integer()) :: privilege()
  def write_privilege(0x001F), do: :administer
  def write_privilege(_cluster_id), do: :operate

  # ── Private matching helpers ──────────────────────────────────────
  # ACL entries may use atom keys (internal) or integer keys with tagged
  # values (TLV format: 1=privilege, 2=authMode, 3=subjects, 4=targets, 254=fabricIndex).

  defp matches_fabric?(entry, context), do: get_field(entry, :fabric_index, 254) == context.fabric_index

  defp matches_auth_mode?(entry, context) do
    case context.auth_mode do
      :case -> get_field(entry, :auth_mode, 2) == 2
      :group -> get_field(entry, :auth_mode, 2) == 3
      _ -> false
    end
  end

  defp matches_subject?(entry, context) do
    subjects = get_field(entry, :subjects, 3)
    subjects == nil || context.subject in unwrap_subjects(subjects)
  end

  defp matches_target?(entry, _target) when not is_map(entry), do: false

  defp matches_target?(entry, {endpoint_id, cluster_id}) do
    targets = get_field(entry, :targets, 4)

    case targets do
      nil -> true
      targets when is_list(targets) ->
        Enum.any?(targets, fn t ->
          (t[:endpoint] == nil || t[:endpoint] == endpoint_id) &&
            (t[:cluster] == nil || t[:cluster] == cluster_id)
        end)
      _ -> true
    end
  end

  # Get a field from an entry that may use atom or integer keys, with possibly tagged values
  defp get_field(entry, atom_key, int_key) do
    case Map.get(entry, atom_key) do
      nil -> unwrap_tagged(Map.get(entry, int_key))
      value -> value
    end
  end

  defp unwrap_tagged({:uint, n}), do: n
  defp unwrap_tagged({:array, _} = arr), do: arr
  defp unwrap_tagged(nil), do: nil
  defp unwrap_tagged(value), do: value

  defp unwrap_subjects({:array, items}), do: Enum.map(items, &unwrap_tagged/1)
  defp unwrap_subjects(list) when is_list(list), do: list
  defp unwrap_subjects(_), do: []
end
