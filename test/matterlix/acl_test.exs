defmodule Matterlix.ACLTest do
  use ExUnit.Case, async: true

  alias Matterlix.ACL

  @admin_entry %{
    privilege: 5,
    auth_mode: 2,
    subjects: [42],
    targets: nil,
    fabric_index: 1
  }

  @case_context %{auth_mode: :case, subject: 42, fabric_index: 1}
  @pase_context %{auth_mode: :pase, subject: 0, fabric_index: 0}

  # ── PASE bypass ──────────────────────────────────────────────

  describe "PASE bypass" do
    test "PASE session always allowed with empty ACL" do
      assert :allow == ACL.check(@pase_context, [], :administer, {0, 0x001F})
    end

    test "PASE session allowed regardless of privilege or target" do
      assert :allow == ACL.check(@pase_context, [], :view, {1, 0x0006})
      assert :allow == ACL.check(@pase_context, [], :operate, {1, 0x0006})
      assert :allow == ACL.check(@pase_context, [], :administer, {0, 0x001F})
    end
  end

  # ── CASE access ─────────────────────────────────────────────

  describe "CASE access" do
    test "empty ACL denies CASE session" do
      assert :deny == ACL.check(@case_context, [], :view, {1, 0x0006})
    end

    test "admin entry grants access to any target" do
      assert :allow == ACL.check(@case_context, [@admin_entry], :view, {1, 0x0006})
      assert :allow == ACL.check(@case_context, [@admin_entry], :operate, {1, 0x0006})
      assert :allow == ACL.check(@case_context, [@admin_entry], :administer, {0, 0x001F})
    end

    test "correct subject allowed" do
      assert :allow == ACL.check(@case_context, [@admin_entry], :view, {1, 0x0006})
    end

    test "wrong subject denied" do
      wrong_subject = %{@case_context | subject: 999}
      assert :deny == ACL.check(wrong_subject, [@admin_entry], :view, {1, 0x0006})
    end

    test "nil subjects (wildcard) allows any node_id" do
      wildcard_entry = %{@admin_entry | subjects: nil}
      other_subject = %{@case_context | subject: 999}
      assert :allow == ACL.check(other_subject, [wildcard_entry], :view, {1, 0x0006})
    end

    test "specific target matches endpoint and cluster" do
      targeted_entry = %{@admin_entry | targets: [%{endpoint: 1, cluster: 0x0006}]}
      assert :allow == ACL.check(@case_context, [targeted_entry], :view, {1, 0x0006})
      assert :deny == ACL.check(@case_context, [targeted_entry], :view, {2, 0x0006})
      assert :deny == ACL.check(@case_context, [targeted_entry], :view, {1, 0x0008})
    end

    test "target with nil endpoint matches any endpoint" do
      entry = %{@admin_entry | targets: [%{cluster: 0x0006}]}
      assert :allow == ACL.check(@case_context, [entry], :view, {1, 0x0006})
      assert :allow == ACL.check(@case_context, [entry], :view, {2, 0x0006})
      assert :deny == ACL.check(@case_context, [entry], :view, {1, 0x0008})
    end

    test "insufficient privilege denied" do
      view_entry = %{@admin_entry | privilege: 1}
      assert :allow == ACL.check(@case_context, [view_entry], :view, {1, 0x0006})
      assert :deny == ACL.check(@case_context, [view_entry], :operate, {1, 0x0006})
      assert :deny == ACL.check(@case_context, [view_entry], :administer, {0, 0x001F})
    end

    test "wrong fabric_index denied" do
      wrong_fabric = %{@case_context | fabric_index: 2}
      assert :deny == ACL.check(wrong_fabric, [@admin_entry], :view, {1, 0x0006})
    end

    test "wrong auth_mode in entry denied" do
      group_entry = %{@admin_entry | auth_mode: 3}
      assert :deny == ACL.check(@case_context, [group_entry], :view, {1, 0x0006})
    end
  end

  # ── Privilege helpers ───────────────────────────────────────

  describe "required_privilege" do
    test "read and subscribe require view" do
      assert :view == ACL.required_privilege(:read_request)
      assert :view == ACL.required_privilege(:subscribe_request)
    end

    test "write and invoke require operate" do
      assert :operate == ACL.required_privilege(:write_request)
      assert :operate == ACL.required_privilege(:invoke_request)
    end
  end

  describe "write_privilege" do
    test "ACL cluster requires administer" do
      assert :administer == ACL.write_privilege(0x001F)
    end

    test "other clusters require operate" do
      assert :operate == ACL.write_privilege(0x0006)
      assert :operate == ACL.write_privilege(0x0028)
    end
  end
end
