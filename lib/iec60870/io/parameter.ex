defmodule IEC60870.IO.Parameter do
  @moduledoc """
  Parameter Information Objects in Control Direction (TypeIDs 110..113).
  Matches `cs101_information_objects.c` in `lib60870-C`.
  """

  import Bitwise
  alias IEC60870.Types.Qualifiers

  # 110: P_ME_NA_1
  defmodule ParameterNormalizedValue do
    @moduledoc """
    Normalized value parameter (P_ME_NA_1, TypeID 110).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            qpm: byte()
          }
    defstruct ioa: 0, value: 0.0, qpm: 0

    def new(ioa, value, qpm \\ 0) do
      scaled = Qualifiers.normalized_to_scaled(value)

      %__MODULE__{
        ioa: ioa,
        value: Qualifiers.scaled_to_normalized(scaled),
        qpm: qpm &&& 0xFF
      }
    end
  end

  # 111: P_ME_NB_1
  defmodule ParameterScaledValue do
    @moduledoc """
    Scaled value parameter (P_ME_NB_1, TypeID 111).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: -32768..32767,
            qpm: byte()
          }
    defstruct ioa: 0, value: 0, qpm: 0

    def new(ioa, value, qpm \\ 0) do
      %__MODULE__{
        ioa: ioa,
        value: max(-32768, min(32767, value)),
        qpm: qpm &&& 0xFF
      }
    end
  end

  # 112: P_ME_NC_1
  defmodule ParameterFloatValue do
    @moduledoc """
    Short float parameter (P_ME_NC_1, TypeID 112).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            qpm: byte()
          }
    defstruct ioa: 0, value: 0.0, qpm: 0

    def new(ioa, value, qpm \\ 0) do
      %__MODULE__{
        ioa: ioa,
        value: value * 1.0,
        qpm: qpm &&& 0xFF
      }
    end
  end

  # 113: P_AC_NA_1
  defmodule ParameterActivation do
    @moduledoc """
    Parameter activation command (P_AC_NA_1, TypeID 113).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            qpa: byte()
          }
    defstruct ioa: 0, qpa: 0

    def new(ioa, qpa) do
      %__MODULE__{ioa: ioa, qpa: qpa &&& 0xFF}
    end
  end

  # Top-level convenience constructors
  @doc """
  Constructs a normalized value parameter (`P_ME_NA_1`, TypeID 110).
  """
  def parameter_normalized_value(ioa, value, qpm \\ 0),
    do: ParameterNormalizedValue.new(ioa, value, qpm)

  @doc """
  Constructs a scaled value parameter (`P_ME_NB_1`, TypeID 111).
  """
  def parameter_scaled_value(ioa, value, qpm \\ 0),
    do: ParameterScaledValue.new(ioa, value, qpm)

  @doc """
  Constructs a short float parameter (`P_ME_NC_1`, TypeID 112).
  """
  def parameter_float_value(ioa, value, qpm \\ 0),
    do: ParameterFloatValue.new(ioa, value, qpm)

  @doc """
  Constructs a parameter activation command (`P_AC_NA_1`, TypeID 113).
  """
  def parameter_activation(ioa, qpa),
    do: ParameterActivation.new(ioa, qpa)

  # Encoding
  def encode_payload(%ParameterNormalizedValue{value: val, qpm: qpm}) do
    scaled = Qualifiers.normalized_to_scaled(val)
    <<scaled::little-signed-16, qpm::8>>
  end

  def encode_payload(%ParameterScaledValue{value: val, qpm: qpm}) do
    <<val::little-signed-16, qpm::8>>
  end

  def encode_payload(%ParameterFloatValue{value: val, qpm: qpm}) do
    <<encode_float32(val)::binary, qpm::8>>
  end

  def encode_payload(%ParameterActivation{qpa: qpa}) do
    <<qpa::8>>
  end

  defp encode_float32(:nan), do: <<0, 0, 0xC0, 0x7F>>
  defp encode_float32(:infinity), do: <<0, 0, 0x80, 0x7F>>
  defp encode_float32(:neg_infinity), do: <<0, 0, 0x80, 0xFF>>
  defp encode_float32(val) when is_number(val), do: <<val::little-float-32>>

  defp decode_float32(<<val::little-float-32>>), do: val
  defp decode_float32(<<0, 0, 0x80, 0x7F>>), do: :infinity
  defp decode_float32(<<0, 0, 0x80, 0xFF>>), do: :neg_infinity
  defp decode_float32(<<_::binary-size(4)>>), do: :nan

  # Decoding
  def decode_payload(:p_me_na_1, ioa, <<scaled::little-signed-16, qpm::8, rest::binary>>) do
    {:ok,
     %ParameterNormalizedValue{
       ioa: ioa,
       value: Qualifiers.scaled_to_normalized(scaled),
       qpm: qpm
     }, rest}
  end

  def decode_payload(:p_me_nb_1, ioa, <<val::little-signed-16, qpm::8, rest::binary>>) do
    {:ok, %ParameterScaledValue{ioa: ioa, value: val, qpm: qpm}, rest}
  end

  def decode_payload(:p_me_nc_1, ioa, <<raw_f::binary-size(4), qpm::8, rest::binary>>) do
    {:ok, %ParameterFloatValue{ioa: ioa, value: decode_float32(raw_f), qpm: qpm}, rest}
  end

  def decode_payload(:p_ac_na_1, ioa, <<qpa::8, rest::binary>>) do
    {:ok, %ParameterActivation{ioa: ioa, qpa: qpa}, rest}
  end

  def decode_payload(_type, _ioa, _bin), do: {:error, :invalid_payload}
end
