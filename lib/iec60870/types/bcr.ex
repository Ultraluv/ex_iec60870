defmodule IEC60870.Types.BCR do
  @moduledoc """
  Binary Counter Reading (`BinaryCounterReading`, 5 bytes) according to IEC 60870-5-101 7.2.6.9.
  Matches `cs101_bcr.c`.

  Byte layout:
  - Bytes 0..3: 32-bit signed integer counter value (little-endian)
  - Byte 4:
    - bits 0..4: `sequence_number` (0..31)
    - bit 5 (`0x20`): `carry` (CY)
    - bit 6 (`0x40`): `adjusted` (CA)
    - bit 7 (`0x80`): `invalid` (IV)
  """

  import Bitwise

  @type t :: %__MODULE__{
          value: integer(),
          sequence_number: 0..31,
          carry: boolean(),
          adjusted: boolean(),
          invalid: boolean()
        }

  defstruct value: 0,
            sequence_number: 0,
            carry: false,
            adjusted: false,
            invalid: false

  @spec new(integer(), non_neg_integer(), keyword()) :: t()
  def new(value, sequence_number \\ 0, opts \\ []) do
    %__MODULE__{
      value: value,
      sequence_number: sequence_number &&& 0x1F,
      carry: Keyword.get(opts, :carry, false),
      adjusted: Keyword.get(opts, :adjusted, false),
      invalid: Keyword.get(opts, :invalid, false)
    }
  end

  @spec encode(t()) :: <<_::40>>
  def encode(%__MODULE__{} = bcr) do
    flags =
      (bcr.sequence_number &&& 0x1F)
      |> bor(if(bcr.carry, do: 0x20, else: 0))
      |> bor(if(bcr.adjusted, do: 0x40, else: 0))
      |> bor(if(bcr.invalid, do: 0x80, else: 0))

    <<bcr.value::little-signed-32, flags::unsigned-8>>
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :insufficient_data}
  def decode(<<value::little-signed-32, flags::unsigned-8, rest::binary>>) do
    bcr = %__MODULE__{
      value: value,
      sequence_number: flags &&& 0x1F,
      carry: (flags &&& 0x20) != 0,
      adjusted: (flags &&& 0x40) != 0,
      invalid: (flags &&& 0x80) != 0
    }

    {:ok, bcr, rest}
  end

  def decode(_), do: {:error, :insufficient_data}
end
