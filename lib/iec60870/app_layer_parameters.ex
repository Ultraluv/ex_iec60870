defmodule IEC60870.AppLayerParameters do
  @moduledoc """
  Application layer parameters shared by IEC 60870-5-101 and IEC 60870-5-104.
  Corresponds to `sCS101_AppLayerParameters` in `lib60870-C`.
  """

  @type t :: %__MODULE__{
          size_of_type_id: 1,
          size_of_vsq: 1,
          size_of_cot: 1 | 2,
          originator_address: 0..255,
          size_of_ca: 1 | 2,
          size_of_ioa: 1 | 2 | 3,
          max_size_of_asdu: pos_integer()
        }

  defstruct size_of_type_id: 1,
            size_of_vsq: 1,
            size_of_cot: 2,
            originator_address: 0,
            size_of_ca: 2,
            size_of_ioa: 3,
            max_size_of_asdu: 249

  @doc """
  Default parameters for IEC 60870-5-104 (COT=2, CA=2, IOA=3, maxASDU=249).
  """
  @spec default_cs104(keyword()) :: t()
  def default_cs104(opts \\ []) do
    struct(%__MODULE__{max_size_of_asdu: 249}, opts)
  end

  @doc """
  Default parameters for IEC 60870-5-101 (COT=1 or 2, CA=1 or 2, IOA=2 or 3, maxASDU=253).
  Match `lib60870-C` defaults (COT=2, CA=2, IOA=3, maxASDU=249) unless overridden.
  """
  @spec default_cs101(keyword()) :: t()
  def default_cs101(opts \\ []) do
    struct(%__MODULE__{max_size_of_asdu: 249}, opts)
  end

  @doc """
  Returns the byte length of the ASDU header (`TypeID + VSQ + COT(+OA) + CA`).
  """
  @spec header_length(t()) :: pos_integer()
  def header_length(%__MODULE__{
        size_of_type_id: tid,
        size_of_vsq: vsq,
        size_of_cot: cot,
        size_of_ca: ca
      }) do
    tid + vsq + cot + ca
  end

  @doc """
  Encodes an Information Object Address (IOA) according to `size_of_ioa` (little-endian).
  """
  @spec encode_ioa(t(), non_neg_integer()) :: binary()
  def encode_ioa(%__MODULE__{size_of_ioa: 1}, ioa), do: <<ioa::little-unsigned-8>>
  def encode_ioa(%__MODULE__{size_of_ioa: 2}, ioa), do: <<ioa::little-unsigned-16>>
  def encode_ioa(%__MODULE__{size_of_ioa: 3}, ioa), do: <<ioa::little-unsigned-24>>

  @doc """
  Decodes an Information Object Address (IOA) according to `size_of_ioa` (little-endian).
  """
  @spec decode_ioa(t(), binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :insufficient_data}
  def decode_ioa(%__MODULE__{size_of_ioa: 1}, <<ioa::little-unsigned-8, rest::binary>>),
    do: {:ok, ioa, rest}

  def decode_ioa(%__MODULE__{size_of_ioa: 2}, <<ioa::little-unsigned-16, rest::binary>>),
    do: {:ok, ioa, rest}

  def decode_ioa(%__MODULE__{size_of_ioa: 3}, <<ioa::little-unsigned-24, rest::binary>>),
    do: {:ok, ioa, rest}

  def decode_ioa(_params, _bin), do: {:error, :insufficient_data}
end
