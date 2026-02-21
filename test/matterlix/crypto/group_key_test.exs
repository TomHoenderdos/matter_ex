defmodule Matterlix.Crypto.GroupKeyTest do
  use ExUnit.Case

  alias Matterlix.Crypto.GroupKey

  @epoch_key :crypto.strong_rand_bytes(16)

  describe "operational_key/1" do
    test "derives 16-byte key from epoch key" do
      key = GroupKey.operational_key(@epoch_key)
      assert byte_size(key) == 16
    end

    test "is deterministic" do
      k1 = GroupKey.operational_key(@epoch_key)
      k2 = GroupKey.operational_key(@epoch_key)
      assert k1 == k2
    end

    test "different epoch keys produce different operational keys" do
      k1 = GroupKey.operational_key(:crypto.strong_rand_bytes(16))
      k2 = GroupKey.operational_key(:crypto.strong_rand_bytes(16))
      assert k1 != k2
    end
  end

  describe "encryption_key/2" do
    test "derives 16-byte key from operational key and group ID" do
      op_key = GroupKey.operational_key(@epoch_key)
      enc_key = GroupKey.encryption_key(op_key, 1)
      assert byte_size(enc_key) == 16
    end

    test "different group IDs produce different encryption keys" do
      op_key = GroupKey.operational_key(@epoch_key)
      k1 = GroupKey.encryption_key(op_key, 1)
      k2 = GroupKey.encryption_key(op_key, 2)
      assert k1 != k2
    end

    test "is deterministic for same inputs" do
      op_key = GroupKey.operational_key(@epoch_key)
      k1 = GroupKey.encryption_key(op_key, 42)
      k2 = GroupKey.encryption_key(op_key, 42)
      assert k1 == k2
    end
  end

  describe "privacy_key/1" do
    test "derives 16-byte key" do
      op_key = GroupKey.operational_key(@epoch_key)
      priv_key = GroupKey.privacy_key(op_key)
      assert byte_size(priv_key) == 16
    end

    test "differs from operational key" do
      op_key = GroupKey.operational_key(@epoch_key)
      priv_key = GroupKey.privacy_key(op_key)
      assert priv_key != op_key
    end
  end

  describe "session_id/1" do
    test "returns a 16-bit integer" do
      op_key = GroupKey.operational_key(@epoch_key)
      sid = GroupKey.session_id(op_key)
      assert is_integer(sid)
      assert sid >= 0 and sid <= 0xFFFF
    end

    test "is deterministic" do
      op_key = GroupKey.operational_key(@epoch_key)
      s1 = GroupKey.session_id(op_key)
      s2 = GroupKey.session_id(op_key)
      assert s1 == s2
    end

    test "different keys produce different session IDs (probabilistic)" do
      ids =
        for _ <- 1..10 do
          ek = :crypto.strong_rand_bytes(16)
          op_key = GroupKey.operational_key(ek)
          GroupKey.session_id(op_key)
        end

      # With 10 random keys, very unlikely all session IDs are the same
      assert length(Enum.uniq(ids)) > 1
    end
  end

  describe "full derivation chain" do
    test "epoch_key → operational_key → encryption_key + session_id" do
      epoch_key = :crypto.strong_rand_bytes(16)
      op_key = GroupKey.operational_key(epoch_key)
      enc_key = GroupKey.encryption_key(op_key, 100)
      session_id = GroupKey.session_id(op_key)

      assert byte_size(op_key) == 16
      assert byte_size(enc_key) == 16
      assert is_integer(session_id)

      # All keys are different from each other
      assert op_key != enc_key
      assert op_key != epoch_key
    end
  end
end
