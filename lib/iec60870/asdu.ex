defmodule IEC60870.ASDU do
  @moduledoc """
  Application Service Data Unit (ASDU) shared by IEC 60870-5-101 and IEC 60870-5-104.
  Matches `cs101_asdu.c` in `lib60870-C`.

  Supports:
  - Discrete IOA encoding (`is_sequence: false`, `SQ = 0`)
  - Compact sequential IOA encoding (`is_sequence: true`, `SQ = 1`)
  - Configurable `COT` (1 or 2 bytes), `CA` (1 or 2 bytes), `IOA` (1, 2, or 3 bytes)
  - Strict VSQ and single-object type validation matching `lib60870-C`
  """

  import Bitwise
  alias IEC60870.{AppLayerParameters, InformationObject}
  alias IEC60870.Types.{COT, TypeID}

  @type t :: %__MODULE__{
          type_id: nil | TypeID.name() | TypeID.code(),
          is_sequence: boolean(),
          cot: COT.name() | COT.code(),
          is_test: boolean(),
          is_negative: boolean(),
          oa: non_neg_integer(),
          ca: non_neg_integer(),
          objects: [InformationObject.t()],
          raw_payload: nil | binary()
        }

  defstruct type_id: nil,
            is_sequence: false,
            cot: :spontaneous,
            is_test: false,
            is_negative: false,
            oa: 0,
            ca: 1,
            objects: [],
            raw_payload: nil

  @doc """
  Creates a new ASDU.
  Supports both `ASDU.new(type_id, kw_opts)` and `ASDU.new(cot, ca, kw_opts)`.
  """
  def new(type_id, opts) when is_list(opts) do
    cot = Keyword.get(opts, :cot, :spontaneous)
    ca = Keyword.get(opts, :ca, 1)
    new(cot, ca, Keyword.put(opts, :type_id, type_id))
  end

  def new(cot, ca) when is_integer(ca) do
    new(cot, ca, [])
  end

  @spec new(COT.t(), non_neg_integer(), keyword()) :: t()
  def new(cot, ca, opts) when is_integer(ca) and is_list(opts) do
    objs = Keyword.get(opts, :objects, Keyword.get(opts, :information_objects, []))

    %__MODULE__{
      type_id: Keyword.get(opts, :type_id, nil),
      is_sequence: Keyword.get(opts, :is_sequence, false),
      cot: COT.to_atom(cot),
      is_test: Keyword.get(opts, :is_test, false),
      is_negative: Keyword.get(opts, :is_negative, false),
      oa: Keyword.get(opts, :oa, 0),
      ca: ca,
      objects: objs,
      raw_payload: Keyword.get(opts, :raw_payload, nil)
    }
    |> sync_type_id()
  end

  @doc """
  Adds an Information Object to the ASDU, validating type consistency, single-object constraints,
  sequence address continuity (`SQ=1`), and maximum ASDU byte size.
  Matches `CS101_ASDU_addInformationObject` in `cs101_asdu.c`.
  """
  @spec add_object(t(), InformationObject.t(), AppLayerParameters.t()) ::
          {:ok, t()} | {:error, atom()}
  def add_object(
        %__MODULE__{objects: objects} = asdu,
        io,
        %AppLayerParameters{} = params \\ %AppLayerParameters{}
      ) do
    io_type = InformationObject.type_id(io)
    count = length(objects)

    cond do
      count >= 127 ->
        {:error, :max_elements_exceeded}

      count > 0 and TypeID.single_io?(asdu.type_id || io_type) ->
        {:error, :single_io_type_only}

      count > 0 and TypeID.to_code(asdu.type_id) != TypeID.to_code(io_type) ->
        {:error, :type_mismatch}

      count > 0 and asdu.is_sequence and
          InformationObject.ioa(io) != InformationObject.ioa(hd(objects)) + count ->
        {:error, :non_consecutive_ioa_in_sequence}

      true ->
        updated = %{asdu | type_id: asdu.type_id || io_type, objects: objects ++ [io]}

        case encode(updated, params) do
          {:ok, bin} when byte_size(bin) <= params.max_size_of_asdu ->
            {:ok, updated}

          {:ok, _bin} ->
            {:error, :asdu_max_size_exceeded}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Encodes an `%IEC60870.ASDU{}` into binary according to `AppLayerParameters`.
  """
  @spec encode(t(), AppLayerParameters.t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = asdu, %AppLayerParameters{} = params \\ %AppLayerParameters{}) do
    type_id =
      cond do
        asdu.type_id != nil -> asdu.type_id
        asdu.objects != [] -> InformationObject.type_id(hd(asdu.objects))
        true -> nil
      end

    if type_id == nil do
      {:error, :missing_type_id}
    else
      type_code = TypeID.to_code(type_id)
      num_elements = length(asdu.objects)

      vsq =
        (num_elements &&& 0x7F)
        |> bor(if(asdu.is_sequence, do: 0x80, else: 0))

      cot_byte =
        (COT.to_code(asdu.cot) &&& 0x3F)
        |> bor(if(asdu.is_negative, do: 0x40, else: 0))
        |> bor(if(asdu.is_test, do: 0x80, else: 0))

      cot_bin =
        case params.size_of_cot do
          1 -> <<cot_byte::8>>
          2 -> <<cot_byte::8, asdu.oa &&& 0xFF::8>>
        end

      ca_bin =
        case params.size_of_ca do
          1 -> <<asdu.ca &&& 0xFF::8>>
          2 -> <<asdu.ca::little-unsigned-16>>
        end

      payload =
        cond do
          asdu.raw_payload != nil and asdu.objects == [] ->
            asdu.raw_payload

          asdu.is_sequence ->
            asdu.objects
            |> Enum.with_index()
            |> Enum.map(fn {io, idx} -> InformationObject.encode(io, params, idx == 0) end)
            |> IO.iodata_to_binary()

          true ->
            asdu.objects
            |> Enum.map(&InformationObject.encode(&1, params, true))
            |> IO.iodata_to_binary()
        end

      bin = <<type_code::8, vsq::8, cot_bin::binary, ca_bin::binary, payload::binary>>

      if byte_size(bin) <= params.max_size_of_asdu do
        {:ok, bin}
      else
        {:error, :asdu_max_size_exceeded}
      end
    end
  end

  @doc """
  Encodes an ASDU and raises on error.
  """
  @spec encode!(t(), AppLayerParameters.t()) :: binary()
  def encode!(%__MODULE__{} = asdu, %AppLayerParameters{} = params \\ %AppLayerParameters{}) do
    case encode(asdu, params) do
      {:ok, bin} -> bin
      {:error, reason} -> raise ArgumentError, "Failed to encode ASDU: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes an ASDU binary buffer into `%IEC60870.ASDU{}` according to `AppLayerParameters`.
  Performs strict header and VSQ bounds checks matching `CS101_ASDU_createFromBufferEx`.
  """
  @spec decode(binary(), AppLayerParameters.t()) :: {:ok, t()} | {:error, term()}
  def decode(bin, %AppLayerParameters{} = params \\ %AppLayerParameters{})
      when is_binary(bin) do
    header_len = AppLayerParameters.header_length(params)

    if byte_size(bin) < header_len do
      {:error, :header_too_short}
    else
      <<type_code::8, vsq::8, after_vsq::binary>> = bin
      is_sequence = (vsq &&& 0x80) != 0
      num_elements = vsq &&& 0x7F

      {cot_byte, oa, after_cot} =
        case params.size_of_cot do
          1 ->
            <<c::8, r::binary>> = after_vsq
            {c, -1, r}

          2 ->
            <<c::8, o::8, r::binary>> = after_vsq
            {c, o, r}
        end

      {ca, payload} =
        case params.size_of_ca do
          1 ->
            <<ca_val::8, r::binary>> = after_cot
            {ca_val, r}

          2 ->
            <<ca_val::little-unsigned-16, r::binary>> = after_cot
            {ca_val, r}
        end

      is_test = (cot_byte &&& 0x80) != 0
      is_negative = (cot_byte &&& 0x40) != 0
      cot = COT.to_atom(cot_byte &&& 0x3F)
      type_id = TypeID.to_atom(type_code)

      with :ok <- validate_vsq_payload(type_code, is_sequence, num_elements, payload, params),
           {:ok, objects} <-
             decode_elements(type_id, is_sequence, num_elements, payload, params) do
        {:ok,
         %__MODULE__{
           type_id: type_id,
           is_sequence: is_sequence,
           cot: cot,
           is_test: is_test,
           is_negative: is_negative,
           oa: oa,
           ca: ca,
           objects: objects,
           raw_payload: payload
         }}
      end
    end
  end

  defp validate_vsq_payload(type_code, is_sequence, num_elements, payload, params) do
    elem_size = TypeID.element_data_size(type_code)

    cond do
      TypeID.single_io?(type_code) and num_elements > 1 ->
        {:error, :single_io_type_only}

      elem_size >= 0 and num_elements > 0 ->
        effective_seq? = is_sequence and TypeID.sequence_supported?(type_code)

        expected_min =
          if effective_seq? do
            params.size_of_ioa + num_elements * elem_size
          else
            num_elements * (params.size_of_ioa + elem_size)
          end

        if byte_size(payload) < expected_min do
          {:error, :vsq_payload_too_short}
        else
          :ok
        end

      true ->
        :ok
    end
  end

  defp decode_elements(_type_id, _is_seq, 0, _payload, _params), do: {:ok, []}

  defp decode_elements(type_id, is_sequence, num_elements, payload, params) do
    code = TypeID.to_code(type_id)

    cond do
      # Unknown / custom / security TypeID with unknown element size: preserve raw_payload
      TypeID.element_data_size(code) == -1 and code not in [125, 210] ->
        if num_elements == 1 and byte_size(payload) >= params.size_of_ioa do
          {:ok, ioa, rest} = AppLayerParameters.decode_ioa(params, payload)
          {:ok, [%InformationObject.RawObject{type: type_id, ioa: ioa, payload: rest}]}
        else
          {:ok, []}
        end

      is_sequence and TypeID.sequence_supported?(code) ->
        with {:ok, base_ioa, rest} <- AppLayerParameters.decode_ioa(params, payload) do
          do_decode_seq(type_id, base_ioa, 0, num_elements, rest, [])
        end

      true ->
        do_decode_discrete(type_id, 0, num_elements, payload, params, [])
    end
  end

  defp do_decode_seq(_type_id, _base_ioa, count, count, _rest, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_decode_seq(type_id, base_ioa, idx, count, bin, acc) do
    case InformationObject.decode_payload(type_id, base_ioa + idx, bin) do
      {:ok, obj, rest} ->
        do_decode_seq(type_id, base_ioa, idx + 1, count, rest, [obj | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_decode_discrete(_type_id, count, count, _rest, _params, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_decode_discrete(type_id, idx, count, bin, params, acc) do
    with {:ok, ioa, rest} <- AppLayerParameters.decode_ioa(params, bin),
         {:ok, obj, rest2} <- InformationObject.decode_payload(type_id, ioa, rest) do
      do_decode_discrete(type_id, idx + 1, count, rest2, params, [obj | acc])
    end
  end

  defp sync_type_id(%__MODULE__{type_id: nil, objects: [first | _]} = asdu) do
    %{asdu | type_id: InformationObject.type_id(first)}
  end

  defp sync_type_id(asdu), do: asdu
end
