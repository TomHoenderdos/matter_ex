defmodule MatterEx.MDNS.DNS do
  @moduledoc """
  DNS wire format encoder/decoder per RFC 1035.

  Pure functional module — no side effects. Handles the subset of DNS
  needed for mDNS/DNS-SD service discovery.

  Uses Erlang's `:binary` module for efficient parsing.

  - Name encoding with length-prefixed labels
  - Name decoding with pointer compression
  - Record types: A, AAAA, PTR, SRV, TXT
  - Complete message encode/decode

  ## Example

      # Encode a query
      query = %{
        id: 0, qr: :query, aa: false,
        questions: [%{name: "_matterc._udp.local", type: :ptr, class: :in}],
        answers: [], authority: [], additional: []
      }
      binary = DNS.encode_message(query)

      # Decode a message
      {:ok, msg} = DNS.decode_message(binary)
  """

  import Bitwise

  # DNS record type codes
  @type_a 1
  @type_aaaa 28
  @type_ptr 12
  @type_srv 33
  @type_txt 16
  @type_any 255

  # DNS class
  @class_in 1

  # mDNS cache-flush bit (bit 15 of class field)
  @cache_flush 0x8000

  # ── Name Encoding/Decoding ──────────────────────────────────────

  @doc """
  Encode a domain name as length-prefixed labels.

  ## Examples

      iex> DNS.encode_name("local")
      <<5, "local", 0>>

      iex> DNS.encode_name("_matterc._udp.local")
      <<9, "_matterc", 4, "_udp", 5, "local", 0>>
  """
  @spec encode_name(String.t()) :: binary()
  def encode_name(name) do
    name
    |> String.split(".")
    |> Enum.reduce(<<>>, fn label, acc ->
      acc <> <<byte_size(label)>> <> label
    end)
    |> Kernel.<>(<<0>>)
  end

  @doc """
  Decode a domain name from a DNS message binary.

  Handles pointer compression (top 2 bits = 0b11 → offset pointer).

  Returns `{name, bytes_consumed}` where bytes_consumed is the number
  of bytes read from the current position (not following pointers).
  """
  @spec decode_name(binary(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  def decode_name(message, offset) do
    {labels, consumed} = decode_labels(message, offset, [], 0, false)
    {Enum.join(labels, "."), consumed}
  end

  defp decode_labels(message, offset, labels, consumed, followed_pointer) do
    case :binary.at(message, offset) do
      0 ->
        # End of name
        final_consumed = if followed_pointer, do: consumed, else: consumed + 1
        {Enum.reverse(labels), final_consumed}

      byte when byte >= 0xC0 ->
        # Pointer compression: 2 bytes form a 14-bit offset
        <<_::binary-size(offset), 0b11::2, ptr_offset::14, _::binary>> = message
        new_consumed = if followed_pointer, do: consumed, else: consumed + 2
        decode_labels(message, ptr_offset, labels, new_consumed, true)

      len ->
        label = :binary.part(message, offset + 1, len)
        new_consumed = if followed_pointer, do: consumed, else: consumed + 1 + len
        decode_labels(message, offset + 1 + len, [label | labels], new_consumed, followed_pointer)
    end
  end

  # ── TXT Encoding ────────────────────────────────────────────────

  @doc """
  Encode TXT record data from a list of strings.

  Each string is length-prefixed (1 byte length + string bytes).
  An empty list produces a single zero byte (RFC 6763 §6.1).

  ## Examples

      iex> DNS.encode_txt(["D=3840", "CM=1"])
      <<6, "D=3840", 4, "CM=1">>
  """
  @spec encode_txt([String.t()]) :: binary()
  def encode_txt([]), do: <<0>>

  def encode_txt(entries) do
    Enum.reduce(entries, <<>>, fn entry, acc ->
      acc <> <<byte_size(entry)>> <> entry
    end)
  end

  @doc """
  Decode TXT record data into a list of strings.
  """
  @spec decode_txt(binary()) :: [String.t()]
  def decode_txt(<<0>>), do: []
  def decode_txt(data), do: decode_txt_entries(data, [])

  defp decode_txt_entries(<<>>, acc), do: Enum.reverse(acc)

  defp decode_txt_entries(<<len, entry::binary-size(len), rest::binary>>, acc) do
    decode_txt_entries(rest, [entry | acc])
  end

  # ── Record Data Encoding ────────────────────────────────────────

  @doc """
  Encode record-type-specific data (rdata).
  """
  @spec encode_rdata(atom(), term()) :: binary()
  def encode_rdata(:a, {a, b, c, d}), do: <<a, b, c, d>>

  def encode_rdata(:aaaa, addr) when is_binary(addr) and byte_size(addr) == 16, do: addr

  def encode_rdata(:aaaa, {a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  def encode_rdata(:ptr, name), do: encode_name(name)

  def encode_rdata(:srv, {priority, weight, port, target}) do
    <<priority::16, weight::16, port::16>> <> encode_name(target)
  end

  def encode_rdata(:txt, entries), do: encode_txt(entries)

  # ── Record Data Decoding ────────────────────────────────────────

  defp decode_rdata(:a, <<a, b, c, d>>, _message), do: {a, b, c, d}

  defp decode_rdata(:aaaa, <<data::binary-size(16)>>, _message), do: data

  defp decode_rdata(:ptr, rdata, message) do
    # PTR rdata is a domain name — need full message for pointer compression
    # Calculate absolute offset of rdata within the message
    {name, _consumed} = find_and_decode_name(message, rdata)
    name
  end

  defp decode_rdata(:srv, <<priority::16, weight::16, port::16, rest::binary>>, message) do
    {target, _consumed} = find_and_decode_name(message, rest)
    {priority, weight, port, target}
  end

  defp decode_rdata(:txt, data, _message), do: decode_txt(data)
  defp decode_rdata(_type, data, _message), do: data

  # Find where rdata appears in the message and decode the name at that offset
  defp find_and_decode_name(message, rdata) do
    # Find the offset of rdata within the full message
    case :binary.match(message, rdata) do
      {offset, _len} -> decode_name(message, offset)
      :nomatch -> decode_name(rdata <> <<0>>, 0)
    end
  end

  # ── Message Encoding ────────────────────────────────────────────

  @doc """
  Encode a complete DNS message to binary.

  ## Message format

      %{
        id: 0,
        qr: :query | :response,
        aa: boolean(),
        questions: [%{name: String.t(), type: atom(), class: :in}],
        answers: [record()],
        authority: [record()],
        additional: [record()]
      }

  ## Record format

      %{
        name: String.t(),
        type: :a | :aaaa | :ptr | :srv | :txt,
        class: :in,
        cache_flush: boolean(),  # mDNS cache-flush bit (optional, default false)
        ttl: non_neg_integer(),
        data: term()             # type-specific
      }
  """
  @spec encode_message(map()) :: binary()
  def encode_message(msg) do
    header = encode_header(msg)
    questions = Enum.map(msg.questions, &encode_question/1)
    answers = Enum.map(msg.answers, &encode_record/1)
    authority = Enum.map(Map.get(msg, :authority, []), &encode_record/1)
    additional = Enum.map(Map.get(msg, :additional, []), &encode_record/1)

    IO.iodata_to_binary([header | questions] ++ answers ++ authority ++ additional)
  end

  defp encode_header(msg) do
    qr = if msg.qr == :response, do: 1, else: 0
    aa = if Map.get(msg, :aa, false), do: 1, else: 0
    qdcount = length(msg.questions)
    ancount = length(msg.answers)
    nscount = length(Map.get(msg, :authority, []))
    arcount = length(Map.get(msg, :additional, []))

    <<
      Map.get(msg, :id, 0)::16,
      qr::1, 0::4, aa::1, 0::1, 0::1,
      0::1, 0::3, 0::4,
      qdcount::16,
      ancount::16,
      nscount::16,
      arcount::16
    >>
  end

  defp encode_question(q) do
    name = encode_name(q.name)
    type_code = type_to_code(q.type)
    name <> <<type_code::16, @class_in::16>>
  end

  defp encode_record(r) do
    name = encode_name(r.name)
    type_code = type_to_code(r.type)
    rdata = encode_rdata(r.type, r.data)

    class = if Map.get(r, :cache_flush, false) do
      @class_in ||| @cache_flush
    else
      @class_in
    end

    name <> <<type_code::16, class::16, r.ttl::32, byte_size(rdata)::16>> <> rdata
  end

  # ── Message Decoding ────────────────────────────────────────────

  @doc """
  Decode a binary DNS message.

  Returns `{:ok, message_map}` or `{:error, reason}`.
  """
  @spec decode_message(binary()) :: {:ok, map()} | {:error, term()}
  def decode_message(<<
    id::16,
    qr::1, _opcode::4, aa::1, _tc::1, _rd::1,
    _ra::1, _z::3, _rcode::4,
    qdcount::16,
    ancount::16,
    nscount::16,
    arcount::16,
    _body::binary
  >> = message) do
    offset = 12  # header size

    {questions, offset} = decode_questions(message, offset, qdcount)
    {answers, offset} = decode_records(message, offset, ancount)
    {authority, offset} = decode_records(message, offset, nscount)
    {additional, _offset} = decode_records(message, offset, arcount)

    {:ok, %{
      id: id,
      qr: if(qr == 1, do: :response, else: :query),
      aa: aa == 1,
      questions: questions,
      answers: answers,
      authority: authority,
      additional: additional
    }}
  rescue
    _ -> {:error, :invalid_message}
  end

  def decode_message(_), do: {:error, :too_short}

  defp decode_questions(_message, offset, 0), do: {[], offset}

  defp decode_questions(message, offset, count) do
    {questions, final_offset} =
      Enum.reduce(1..count, {[], offset}, fn _i, {acc, off} ->
        {name, consumed} = decode_name(message, off)
        <<_::binary-size(off + consumed), type_code::16, _class::16, _::binary>> = message
        question = %{name: name, type: code_to_type(type_code), class: :in}
        {[question | acc], off + consumed + 4}
      end)

    {Enum.reverse(questions), final_offset}
  end

  defp decode_records(_message, offset, 0), do: {[], offset}

  defp decode_records(message, offset, count) do
    {records, final_offset} =
      Enum.reduce(1..count, {[], offset}, fn _i, {acc, off} ->
        {name, consumed} = decode_name(message, off)
        data_start = off + consumed

        <<_::binary-size(data_start),
          type_code::16, class_raw::16, ttl::32, rdlength::16,
          _::binary>> = message

        rdata_offset = data_start + 10
        rdata = :binary.part(message, rdata_offset, rdlength)

        type = code_to_type(type_code)
        cache_flush = (class_raw &&& @cache_flush) != 0
        data = decode_rdata(type, rdata, message)

        record = %{
          name: name,
          type: type,
          class: :in,
          cache_flush: cache_flush,
          ttl: ttl,
          data: data
        }

        {[record | acc], rdata_offset + rdlength}
      end)

    {Enum.reverse(records), final_offset}
  end

  # ── Type Code Mapping ───────────────────────────────────────────

  defp type_to_code(:a), do: @type_a
  defp type_to_code(:aaaa), do: @type_aaaa
  defp type_to_code(:ptr), do: @type_ptr
  defp type_to_code(:srv), do: @type_srv
  defp type_to_code(:txt), do: @type_txt
  defp type_to_code(:any), do: @type_any

  defp code_to_type(@type_a), do: :a
  defp code_to_type(@type_aaaa), do: :aaaa
  defp code_to_type(@type_ptr), do: :ptr
  defp code_to_type(@type_srv), do: :srv
  defp code_to_type(@type_txt), do: :txt
  defp code_to_type(@type_any), do: :any
  defp code_to_type(code), do: code
end
