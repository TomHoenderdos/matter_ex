defmodule Matterlix.MDNSTest do
  use ExUnit.Case

  alias Matterlix.MDNS
  alias Matterlix.MDNS.DNS

  @test_address {192, 168, 1, 100}
  @test_hostname "test-device"

  setup do
    mdns = start_supervised!({MDNS,
      port: 0,
      hostname: @test_hostname,
      addresses: [@test_address]
    })

    port = MDNS.port(mdns)
    {:ok, client} = :gen_udp.open(0, [:binary, {:active, true}])

    on_exit(fn -> :gen_udp.close(client) end)

    %{mdns: mdns, port: port, client: client}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp send_query(client, port, questions) do
    msg = %{
      id: 0,
      qr: :query,
      aa: false,
      questions: questions,
      answers: []
    }

    binary = DNS.encode_message(msg)
    :ok = :gen_udp.send(client, ~c"127.0.0.1", port, binary)

    receive do
      {:udp, ^client, _ip, _port, response} ->
        DNS.decode_message(response)
    after
      1000 -> :no_response
    end
  end

  defp advertise_test_service(mdns, opts \\ []) do
    instance = Keyword.get(opts, :instance, "TEST-INST")
    service_port = Keyword.get(opts, :port, 5540)
    txt = Keyword.get(opts, :txt, ["D=3840", "CM=1"])
    subtypes = Keyword.get(opts, :subtypes, [])

    MDNS.advertise(mdns, [
      service: "_matterc._udp.local",
      instance: instance,
      port: service_port,
      txt: txt,
      subtypes: subtypes
    ])
  end

  # ── Basic ───────────────────────────────────────────────────────

  describe "basic" do
    test "responder starts and listens", %{port: port} do
      assert port > 0
    end

    test "advertise registers a service", %{mdns: mdns, client: client, port: port} do
      advertise_test_service(mdns)

      # Query for the service type
      result = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      assert {:ok, response} = result
      assert response.qr == :response
      assert response.aa == true
      assert length(response.answers) > 0
    end
  end

  # ── Query Response ──────────────────────────────────────────────

  describe "query response" do
    setup %{mdns: mdns} do
      advertise_test_service(mdns, txt: ["D=3840", "VP=65521+32769", "CM=1"])
      :ok
    end

    test "PTR query returns PTR + SRV + TXT + A records", %{client: client, port: port} do
      {:ok, response} = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      types = Enum.map(response.answers, & &1.type)
      assert :ptr in types
      assert :srv in types
      assert :txt in types
      assert :a in types

      # Check PTR points to instance
      ptr = Enum.find(response.answers, &(&1.type == :ptr))
      assert ptr.data == "TEST-INST._matterc._udp.local"

      # Check SRV has correct port and target
      srv = Enum.find(response.answers, &(&1.type == :srv))
      {_pri, _weight, srv_port, target} = srv.data
      assert srv_port == 5540
      assert target == "test-device.local"

      # Check TXT records
      txt = Enum.find(response.answers, &(&1.type == :txt))
      assert "D=3840" in txt.data
      assert "VP=65521+32769" in txt.data
      assert "CM=1" in txt.data

      # Check A record
      a = Enum.find(response.answers, &(&1.type == :a))
      assert a.data == @test_address
      assert a.name == "test-device.local"
    end

    test "SRV query for instance returns SRV + A records", %{client: client, port: port} do
      {:ok, response} = send_query(client, port, [
        %{name: "TEST-INST._matterc._udp.local", type: :srv, class: :in}
      ])

      types = Enum.map(response.answers, & &1.type)
      assert :srv in types
      assert :a in types
      refute :ptr in types
      refute :txt in types
    end

    test "TXT query for instance returns TXT record", %{client: client, port: port} do
      {:ok, response} = send_query(client, port, [
        %{name: "TEST-INST._matterc._udp.local", type: :txt, class: :in}
      ])

      assert length(response.answers) == 1
      [txt] = response.answers
      assert txt.type == :txt
      assert "D=3840" in txt.data
    end

    test "A query for hostname returns A record", %{client: client, port: port} do
      {:ok, response} = send_query(client, port, [
        %{name: "test-device.local", type: :a, class: :in}
      ])

      assert length(response.answers) == 1
      [a] = response.answers
      assert a.type == :a
      assert a.data == @test_address
    end

    test "unrelated query gets no response", %{client: client, port: port} do
      result = send_query(client, port, [
        %{name: "_http._tcp.local", type: :ptr, class: :in}
      ])

      assert result == :no_response
    end
  end

  # ── Service Lifecycle ───────────────────────────────────────────

  describe "service lifecycle" do
    test "withdraw removes service", %{mdns: mdns, client: client, port: port} do
      advertise_test_service(mdns)

      # Should respond before withdraw
      {:ok, _response} = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      MDNS.withdraw(mdns, "TEST-INST")

      # Should not respond after withdraw
      result = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      assert result == :no_response
    end

    test "update_txt changes TXT records", %{mdns: mdns, client: client, port: port} do
      advertise_test_service(mdns, txt: ["D=3840", "CM=1"])

      # Read original
      {:ok, response1} = send_query(client, port, [
        %{name: "TEST-INST._matterc._udp.local", type: :txt, class: :in}
      ])

      [txt1] = response1.answers
      assert "CM=1" in txt1.data

      # Update TXT
      MDNS.update_txt(mdns, "TEST-INST", ["D=3840", "CM=2"])

      {:ok, response2} = send_query(client, port, [
        %{name: "TEST-INST._matterc._udp.local", type: :txt, class: :in}
      ])

      [txt2] = response2.answers
      assert "CM=2" in txt2.data
      refute "CM=1" in txt2.data
    end
  end

  # ── Matter Integration ──────────────────────────────────────────

  describe "Matter integration" do
    test "commissioning_service builds correct config" do
      config = MDNS.commissioning_service(
        port: 5540,
        discriminator: 3840,
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        device_name: "Test Light",
        device_type: 0x0100
      )

      assert config[:service] == "_matterc._udp.local"
      assert is_binary(config[:instance])
      assert config[:port] == 5540

      txt = config[:txt]
      assert "D=3840" in txt
      assert "VP=65521+32769" in txt
      assert "CM=1" in txt
      assert "T=1" in txt
      assert "DT=256" in txt
      assert "DN=Test Light" in txt

      subtypes = config[:subtypes]
      # short discriminator = 3840 >>> 8 = 15
      assert "_S15._sub._matterc._udp.local" in subtypes
      assert "_L3840._sub._matterc._udp.local" in subtypes
    end

    test "subtype PTR query matches service", %{mdns: mdns, client: client, port: port} do
      advertise_test_service(mdns,
        subtypes: ["_S15._sub._matterc._udp.local", "_L3840._sub._matterc._udp.local"]
      )

      # Query by short discriminator subtype
      {:ok, response} = send_query(client, port, [
        %{name: "_S15._sub._matterc._udp.local", type: :ptr, class: :in}
      ])

      types = Enum.map(response.answers, & &1.type)
      assert :ptr in types
      assert :srv in types

      ptr = Enum.find(response.answers, &(&1.type == :ptr))
      assert ptr.data == "TEST-INST._matterc._udp.local"
    end

    test "commissioning_service end-to-end", %{mdns: mdns, client: client, port: port} do
      config = MDNS.commissioning_service(
        port: 5540,
        discriminator: 3840,
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        device_name: "Test Light"
      )

      MDNS.advertise(mdns, config)

      # Query by service type
      {:ok, response} = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      ptr = Enum.find(response.answers, &(&1.type == :ptr))
      assert ptr != nil
      assert String.ends_with?(ptr.data, "._matterc._udp.local")

      txt = Enum.find(response.answers, &(&1.type == :txt))
      assert "D=3840" in txt.data
      assert "DN=Test Light" in txt.data
    end
  end

  # ── Operational Discovery ─────────────────────────────────────

  describe "operational discovery" do
    test "compressed_fabric_id is deterministic and 8 bytes" do
      {pub, _priv} = :crypto.generate_key(:ecdh, :secp256r1)
      fabric_id = 1

      cfid1 = MDNS.compressed_fabric_id(pub, fabric_id)
      cfid2 = MDNS.compressed_fabric_id(pub, fabric_id)

      assert cfid1 == cfid2
      assert byte_size(cfid1) == 8
    end

    test "different fabric IDs produce different compressed IDs" do
      {pub, _priv} = :crypto.generate_key(:ecdh, :secp256r1)

      cfid1 = MDNS.compressed_fabric_id(pub, 1)
      cfid2 = MDNS.compressed_fabric_id(pub, 2)

      assert cfid1 != cfid2
    end

    test "operational_service builds correct config" do
      cfid = :crypto.strong_rand_bytes(8)

      config = MDNS.operational_service(
        port: 5540,
        compressed_fabric_id: cfid,
        node_id: 1
      )

      assert config[:service] == "_matter._tcp.local"
      assert config[:port] == 5540

      # Instance name: <CFID-hex>-<node-id-hex>
      expected_instance = Base.encode16(cfid) <> "-0000000000000001"
      assert config[:instance] == expected_instance

      txt = config[:txt]
      assert "T=1" in txt
    end

    test "operational_service responds to _matter._tcp queries",
         %{mdns: mdns, client: client, port: port} do
      cfid = <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>

      config = MDNS.operational_service(
        port: 5540,
        compressed_fabric_id: cfid,
        node_id: 42
      )

      MDNS.advertise(mdns, config)

      {:ok, response} = send_query(client, port, [
        %{name: "_matter._tcp.local", type: :ptr, class: :in}
      ])

      types = Enum.map(response.answers, & &1.type)
      assert :ptr in types
      assert :srv in types
      assert :txt in types

      ptr = Enum.find(response.answers, &(&1.type == :ptr))
      assert ptr.data == "0102030405060708-000000000000002A._matter._tcp.local"

      srv = Enum.find(response.answers, &(&1.type == :srv))
      {_pri, _weight, srv_port, _target} = srv.data
      assert srv_port == 5540
    end

    test "mDNS transition: withdraw commissioning, advertise operational",
         %{mdns: mdns, client: client, port: port} do
      # Start with commissioning advertisement
      advertise_test_service(mdns)

      # Verify commissioning responds
      {:ok, _response} = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      # Withdraw commissioning
      MDNS.withdraw(mdns, "TEST-INST")

      # Advertise operational
      cfid = <<0xAB, 0xCD, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC>>

      config = MDNS.operational_service(
        port: 5540,
        compressed_fabric_id: cfid,
        node_id: 1
      )

      MDNS.advertise(mdns, config)

      # Commissioning should no longer respond
      result = send_query(client, port, [
        %{name: "_matterc._udp.local", type: :ptr, class: :in}
      ])

      assert result == :no_response

      # Operational should respond
      {:ok, response} = send_query(client, port, [
        %{name: "_matter._tcp.local", type: :ptr, class: :in}
      ])

      ptr = Enum.find(response.answers, &(&1.type == :ptr))
      assert String.ends_with?(ptr.data, "._matter._tcp.local")
    end
  end
end
