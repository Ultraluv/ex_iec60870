defmodule IEC60870.CPTimeAndBCRTest do
  use ExUnit.Case, async: true

  alias IEC60870.Types.BCR
  alias IEC60870.Types.CPTime.{CP16Time2a, CP24Time2a, CP32Time2a, CP56Time2a}
  alias IEC60870.Types.Qualifiers

  test "CP56Time2a matches lib60870-C test_CP56Time2aToMsTimestamp vector" do
    raw = <<0x85, 0x49, 0x0C, 0x09, 0x55, 0x03, 0x11>>
    assert {:ok, t, <<>>} = CP56Time2a.decode(raw)
    assert CP56Time2a.to_ms(t) == 1_490_087_538_821
    assert CP56Time2a.encode(t) == raw
  end

  test "CP56Time2a roundtrip from millisecond timestamp" do
    now_ms = 1_700_000_123_456
    t = CP56Time2a.from_ms(now_ms)
    assert CP56Time2a.to_ms(t) == now_ms

    encoded = CP56Time2a.encode(t)
    assert byte_size(encoded) == 7
    assert {:ok, decoded, <<>>} = CP56Time2a.decode(encoded)
    assert CP56Time2a.to_ms(decoded) == now_ms
  end

  test "CP16Time2a, CP24Time2a, CP32Time2a encode and decode" do
    t16 = CP16Time2a.from_ms(45_678)
    assert {:ok, d16, <<>>} = CP16Time2a.decode(CP16Time2a.encode(t16))
    assert d16.elapsed_time_ms == 45_678

    t24 = %CP24Time2a{millisecond: 999, second: 59, minute: 42, invalid: true, substituted: true}
    assert {:ok, d24, <<>>} = CP24Time2a.decode(CP24Time2a.encode(t24))
    assert d24 == t24

    t32 = %CP32Time2a{
      millisecond: 500,
      second: 30,
      minute: 15,
      hour: 22,
      summer_time: true,
      invalid: false,
      substituted: true
    }

    assert {:ok, d32, <<>>} = CP32Time2a.decode(CP32Time2a.encode(t32))
    assert d32 == t32
  end

  test "BCR 5-byte binary counter reading roundtrip" do
    bcr = %BCR{
      value: -123_456_789,
      sequence_number: 19,
      carry: true,
      adjusted: false,
      invalid: true
    }

    bin = BCR.encode(bcr)
    assert byte_size(bin) == 5
    assert {:ok, decoded, <<>>} = BCR.decode(bin)
    assert decoded == bcr
  end

  test "Qualifiers normalized and scaled value conversions" do
    raw_zero = Qualifiers.float_to_normalized(0.0)
    assert raw_zero == 0
    assert_in_delta Qualifiers.normalized_to_float(raw_zero), 0.0, 0.0001

    raw_neg = Qualifiers.float_to_normalized(-1.0)
    assert raw_neg == -32768
    assert_in_delta Qualifiers.normalized_to_float(raw_neg), -1.0, 0.0001

    qds = %{overflow: true, blocked: false, substituted: true, non_topical: false, invalid: true}
    assert Qualifiers.decode_qds(Qualifiers.encode_qds(qds)) == qds
  end
end
