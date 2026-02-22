defmodule MatterEx.Protocol.ProtocolIDTest do
  use ExUnit.Case, async: true

  alias MatterEx.Protocol.ProtocolID

  describe "protocol_name/1" do
    test "secure channel" do
      assert ProtocolID.protocol_name(0x0000) == :secure_channel
    end

    test "interaction model" do
      assert ProtocolID.protocol_name(0x0001) == :interaction_model
    end

    test "BDX" do
      assert ProtocolID.protocol_name(0x0002) == :bdx
    end

    test "unknown protocol" do
      assert ProtocolID.protocol_name(0x0099) == {:unknown, 0x0099}
    end
  end

  describe "protocol_id/1 (reverse)" do
    test "roundtrips with protocol_name" do
      for proto <- [:secure_channel, :interaction_model, :bdx, :user_directed_commissioning] do
        id = ProtocolID.protocol_id(proto)
        assert ProtocolID.protocol_name(id) == proto
      end
    end
  end

  describe "opcode_name/2 — secure channel" do
    test "standalone ack" do
      assert ProtocolID.opcode_name(0x0000, 0x10) == :standalone_ack
    end

    test "PASE opcodes" do
      assert ProtocolID.opcode_name(0x0000, 0x20) == :pbkdf_param_request
      assert ProtocolID.opcode_name(0x0000, 0x21) == :pbkdf_param_response
      assert ProtocolID.opcode_name(0x0000, 0x22) == :pase_pake1
      assert ProtocolID.opcode_name(0x0000, 0x23) == :pase_pake2
      assert ProtocolID.opcode_name(0x0000, 0x24) == :pase_pake3
    end

    test "CASE opcodes" do
      assert ProtocolID.opcode_name(0x0000, 0x30) == :case_sigma1
      assert ProtocolID.opcode_name(0x0000, 0x31) == :case_sigma2
      assert ProtocolID.opcode_name(0x0000, 0x32) == :case_sigma3
      assert ProtocolID.opcode_name(0x0000, 0x33) == :case_sigma2_resume
    end

    test "status report" do
      assert ProtocolID.opcode_name(0x0000, 0x40) == :status_report
    end
  end

  describe "opcode_name/2 — interaction model" do
    test "all IM opcodes" do
      assert ProtocolID.opcode_name(0x0001, 0x01) == :status_response
      assert ProtocolID.opcode_name(0x0001, 0x02) == :read_request
      assert ProtocolID.opcode_name(0x0001, 0x03) == :subscribe_request
      assert ProtocolID.opcode_name(0x0001, 0x04) == :subscribe_response
      assert ProtocolID.opcode_name(0x0001, 0x05) == :report_data
      assert ProtocolID.opcode_name(0x0001, 0x06) == :write_request
      assert ProtocolID.opcode_name(0x0001, 0x07) == :write_response
      assert ProtocolID.opcode_name(0x0001, 0x08) == :invoke_request
      assert ProtocolID.opcode_name(0x0001, 0x09) == :invoke_response
      assert ProtocolID.opcode_name(0x0001, 0x0A) == :timed_request
    end
  end

  describe "opcode_name/2 — unknown" do
    test "unknown opcode in known protocol" do
      assert ProtocolID.opcode_name(0x0000, 0xFF) == {:unknown, 0xFF}
    end

    test "unknown protocol" do
      assert ProtocolID.opcode_name(0x0099, 0x01) == {:unknown, 0x01}
    end
  end

  describe "opcode/2 (reverse)" do
    test "secure channel roundtrips" do
      for {opcode_atom, expected_id} <- [
            standalone_ack: 0x10,
            pbkdf_param_request: 0x20,
            pase_pake1: 0x22,
            case_sigma1: 0x30,
            status_report: 0x40
          ] do
        id = ProtocolID.opcode(:secure_channel, opcode_atom)
        assert id == expected_id
        assert ProtocolID.opcode_name(0x0000, id) == opcode_atom
      end
    end

    test "interaction model roundtrips" do
      for {opcode_atom, expected_id} <- [
            read_request: 0x02,
            write_request: 0x06,
            invoke_request: 0x08,
            report_data: 0x05
          ] do
        id = ProtocolID.opcode(:interaction_model, opcode_atom)
        assert id == expected_id
        assert ProtocolID.opcode_name(0x0001, id) == opcode_atom
      end
    end
  end
end
