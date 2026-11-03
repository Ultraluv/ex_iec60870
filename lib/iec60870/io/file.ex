defmodule IEC60870.IO.File do
  @moduledoc """
  File Transfer Information Objects (TypeIDs 120..127 and extended TypeID 210).
  Matches `cs101_information_objects.c` in `lib60870-C`.
  """

  import Bitwise
  alias IEC60870.AppLayerParameters
  alias IEC60870.Types.CPTime.CP56Time2a

  # 120: F_FR_NA_1
  # Note: In `lib60870-C` `FileReady_create`: `positive = true` -> `frq = 0`, `positive = false` -> `frq = 0x80` (negative confirm bit).
  defmodule FileReady do
    @moduledoc """
    File ready message (F_FR_NA_1, TypeID 120, and domestic F_FR_NA_2, TypeID 210).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            length_of_file: non_neg_integer(),
            frq: byte(),
            positive: boolean()
          }
    defstruct ioa: 0, nof: 1, length_of_file: 0, frq: 0, positive: true

    def new(ioa, nof, length_of_file, positive \\ true, frq_qualifier \\ 0) do
      frq = (frq_qualifier &&& 0x7F) ||| if(positive, do: 0x00, else: 0x80)

      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        length_of_file: length_of_file &&& 0xFFFFFF,
        frq: frq,
        positive: (frq &&& 0x80) == 0
      }
    end
  end

  # 121: F_SR_NA_1
  defmodule SectionReady do
    @moduledoc """
    Section ready message (F_SR_NA_1, TypeID 121).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            nos: byte(),
            length_of_section: non_neg_integer(),
            srq: byte(),
            not_ready: boolean()
          }
    defstruct ioa: 0, nof: 1, nos: 1, length_of_section: 0, srq: 0, not_ready: false

    def new(ioa, nof, nos, length_of_section, not_ready \\ false, srq_qualifier \\ 0) do
      srq = (srq_qualifier &&& 0x7F) ||| if(not_ready, do: 0x80, else: 0x00)

      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        nos: nos &&& 0xFF,
        length_of_section: length_of_section &&& 0xFFFFFF,
        srq: srq,
        not_ready: (srq &&& 0x80) != 0
      }
    end
  end

  # 122: F_SC_NA_1
  defmodule FileCallOrSelect do
    @moduledoc """
    Call directory, select file, call file, call section (F_SC_NA_1, TypeID 122).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            nos: byte(),
            scq: byte()
          }
    defstruct ioa: 0, nof: 1, nos: 0, scq: 1

    def new(ioa, nof, nos, scq) do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        nos: nos &&& 0xFF,
        scq: scq &&& 0xFF
      }
    end
  end

  # 123: F_LS_NA_1
  defmodule FileLastSegmentOrSection do
    @moduledoc """
    Last section or last segment confirmation (F_LS_NA_1, TypeID 123).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            nos: byte(),
            lsq: byte(),
            chs: byte()
          }
    defstruct ioa: 0, nof: 1, nos: 1, lsq: 1, chs: 0

    def new(ioa, nof, nos, lsq, chs) do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        nos: nos &&& 0xFF,
        lsq: lsq &&& 0xFF,
        chs: chs &&& 0xFF
      }
    end
  end

  # 124: F_AF_NA_1
  defmodule FileACK do
    @moduledoc """
    File transfer acknowledgement (F_AF_NA_1, TypeID 124).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            nos: byte(),
            afq: byte()
          }
    defstruct ioa: 0, nof: 1, nos: 1, afq: 1

    def new(ioa, nof, nos, afq) do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        nos: nos &&& 0xFF,
        afq: afq &&& 0xFF
      }
    end
  end

  # 125: F_SG_NA_1
  defmodule FileSegment do
    @moduledoc """
    File data segment (F_SG_NA_1, TypeID 125).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            nos: byte(),
            data: binary()
          }
    defstruct ioa: 0, nof: 1, nos: 1, data: <<>>

    def new(ioa, nof, nos, data) when is_binary(data) and byte_size(data) <= 255 do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        nos: nos &&& 0xFF,
        data: data
      }
    end

    @doc """
    Maximum segment payload size for given `AppLayerParameters`, matching `FileSegment_GetMaxDataSize`.
    """
    @spec max_data_size(AppLayerParameters.t()) :: non_neg_integer()
    def max_data_size(%AppLayerParameters{} = params) do
      params.max_size_of_asdu - AppLayerParameters.header_length(params) - params.size_of_ioa - 4
    end
  end

  # 126: F_DR_TA_1
  defmodule FileDirectory do
    @moduledoc """
    Directory information response (F_DR_TA_1, TypeID 126).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            length_of_file: non_neg_integer(),
            sof: byte(),
            creation_time: CP56Time2a.t()
          }
    defstruct ioa: 0, nof: 1, length_of_file: 0, sof: 0, creation_time: %CP56Time2a{}

    def new(ioa, nof, length_of_file, sof, %CP56Time2a{} = creation_time) do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        length_of_file: length_of_file &&& 0xFFFFFF,
        sof: sof &&& 0xFF,
        creation_time: creation_time
      }
    end

    def status(%__MODULE__{sof: sof}), do: sof &&& 0x1F
    def last_file?(%__MODULE__{sof: sof}), do: (sof &&& 0x20) != 0
    def subdirectory?(%__MODULE__{sof: sof}), do: (sof &&& 0x40) != 0
    def transfer_active?(%__MODULE__{sof: sof}), do: (sof &&& 0x80) != 0
  end

  # 127: F_SC_NB_1
  defmodule QueryLog do
    @moduledoc """
    Query log / directory by time range (F_SC_NB_1, TypeID 127).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            nof: non_neg_integer(),
            range_start_time: CP56Time2a.t(),
            range_stop_time: CP56Time2a.t()
          }
    defstruct ioa: 0,
              nof: 1,
              range_start_time: %CP56Time2a{},
              range_stop_time: %CP56Time2a{}

    def new(ioa, nof, %CP56Time2a{} = start_time, %CP56Time2a{} = stop_time) do
      %__MODULE__{
        ioa: ioa,
        nof: nof &&& 0xFFFF,
        range_start_time: start_time,
        range_stop_time: stop_time
      }
    end
  end

  # 210: F_FR_NA_2 (Extended File Transfer packet for domestic / State Grid extensions)
  defmodule ExtendedFilePacket do
    @moduledoc """
    Extended file packet for domestic 210 file transfer.
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            payload: binary()
          }
    defstruct ioa: 0, payload: <<>>

    def new(ioa, payload) when is_binary(payload) do
      %__MODULE__{ioa: ioa, payload: payload}
    end
  end

  # Top-level convenience constructors
  @doc """
  Constructs a file ready object (`F_FR_NA_1`, TypeID 120 / 210).
  """
  def file_ready(ioa, nof, length_of_file, positive \\ true, frq_qualifier \\ 0),
    do: FileReady.new(ioa, nof, length_of_file, positive, frq_qualifier)

  @doc """
  Constructs a section ready object (`F_SR_NA_1`, TypeID 121).
  """
  def section_ready(ioa, nof, nos, length_of_section, not_ready \\ false, srq_qualifier \\ 0),
    do: SectionReady.new(ioa, nof, nos, length_of_section, not_ready, srq_qualifier)

  @doc """
  Constructs a call directory, select/call file or section object (`F_SC_NA_1`, TypeID 122).
  """
  def file_call_or_select(ioa, nof, nos, scq),
    do: FileCallOrSelect.new(ioa, nof, nos, scq)

  @doc """
  Constructs a last segment/section confirmation (`F_LS_NA_1`, TypeID 123).
  """
  def file_last_segment_or_section(ioa, nof, nos, lsq, chs),
    do: FileLastSegmentOrSection.new(ioa, nof, nos, lsq, chs)

  @doc """
  Constructs a file transfer acknowledgement (`F_AF_NA_1`, TypeID 124).
  """
  def file_ack(ioa, nof, nos, afq),
    do: FileACK.new(ioa, nof, nos, afq)

  @doc """
  Constructs a file segment data object (`F_SG_NA_1`, TypeID 125).
  """
  def file_segment(ioa, nof, nos, data),
    do: FileSegment.new(ioa, nof, nos, data)

  @doc """
  Constructs a directory entry response object (`F_DR_TA_1`, TypeID 126).
  """
  def file_directory(ioa, nof, length_of_file, sof, %CP56Time2a{} = creation_time),
    do: FileDirectory.new(ioa, nof, length_of_file, sof, creation_time)

  @doc """
  Constructs a log query object (`F_SC_NB_1`, TypeID 127).
  """
  def query_log(ioa, nof, %CP56Time2a{} = start_time, %CP56Time2a{} = stop_time),
    do: QueryLog.new(ioa, nof, start_time, stop_time)

  def private_file_transfer(ioa, payload),
    do: ExtendedFilePacket.new(ioa, payload)

  # Encoding
  def encode_payload(%FileReady{nof: nof, length_of_file: len, frq: frq, positive: pos}) do
    frq_byte = (frq &&& 0x7F) ||| if(pos == false, do: 0x80, else: 0x00)
    <<nof::little-unsigned-16, len::little-unsigned-24, frq_byte::8>>
  end

  def encode_payload(%SectionReady{
        nof: nof,
        nos: nos,
        length_of_section: len,
        srq: srq,
        not_ready: nr
      }) do
    srq_byte = (srq &&& 0x7F) ||| if(nr == true, do: 0x80, else: 0x00)
    <<nof::little-unsigned-16, nos::8, len::little-unsigned-24, srq_byte::8>>
  end

  def encode_payload(%FileCallOrSelect{nof: nof, nos: nos, scq: scq}) do
    <<nof::little-unsigned-16, nos::8, scq::8>>
  end

  def encode_payload(%FileLastSegmentOrSection{nof: nof, nos: nos, lsq: lsq, chs: chs}) do
    <<nof::little-unsigned-16, nos::8, lsq::8, chs::8>>
  end

  def encode_payload(%FileACK{nof: nof, nos: nos, afq: afq}) do
    <<nof::little-unsigned-16, nos::8, afq::8>>
  end

  def encode_payload(%FileSegment{nof: nof, nos: nos, data: data}) do
    los = byte_size(data)
    <<nof::little-unsigned-16, nos::8, los::8, data::binary>>
  end

  def encode_payload(%FileDirectory{
        nof: nof,
        length_of_file: len,
        sof: sof,
        creation_time: ct
      }) do
    <<nof::little-unsigned-16, len::little-unsigned-24, sof::8, CP56Time2a.encode(ct)::binary>>
  end

  def encode_payload(%QueryLog{
        nof: nof,
        range_start_time: start_t,
        range_stop_time: stop_t
      }) do
    <<nof::little-unsigned-16, CP56Time2a.encode(start_t)::binary,
      CP56Time2a.encode(stop_t)::binary>>
  end

  def encode_payload(%ExtendedFilePacket{payload: payload}), do: payload

  # Decoding
  def decode_payload(
        :f_fr_na_1,
        ioa,
        <<nof::little-unsigned-16, len::little-unsigned-24, frq::8, rest::binary>>
      ) do
    {:ok,
     %FileReady{
       ioa: ioa,
       nof: nof,
       length_of_file: len,
       frq: frq,
       positive: (frq &&& 0x80) == 0
     }, rest}
  end

  def decode_payload(
        :f_sr_na_1,
        ioa,
        <<nof::little-unsigned-16, nos::8, len::little-unsigned-24, srq::8, rest::binary>>
      ) do
    {:ok,
     %SectionReady{
       ioa: ioa,
       nof: nof,
       nos: nos,
       length_of_section: len,
       srq: srq,
       not_ready: (srq &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:f_sc_na_1, ioa, <<nof::little-unsigned-16, nos::8, scq::8, rest::binary>>) do
    {:ok, %FileCallOrSelect{ioa: ioa, nof: nof, nos: nos, scq: scq}, rest}
  end

  def decode_payload(
        :f_ls_na_1,
        ioa,
        <<nof::little-unsigned-16, nos::8, lsq::8, chs::8, rest::binary>>
      ) do
    {:ok, %FileLastSegmentOrSection{ioa: ioa, nof: ioa_or_nof(nof), nos: nos, lsq: lsq, chs: chs},
     rest}
  end

  def decode_payload(:f_af_na_1, ioa, <<nof::little-unsigned-16, nos::8, afq::8, rest::binary>>) do
    {:ok, %FileACK{ioa: ioa, nof: nof, nos: nos, afq: afq}, rest}
  end

  def decode_payload(
        :f_sg_na_1,
        ioa,
        <<nof::little-unsigned-16, nos::8, los::8, data::binary-size(los), rest::binary>>
      ) do
    {:ok, %FileSegment{ioa: ioa, nof: nof, nos: nos, data: data}, rest}
  end

  def decode_payload(
        :f_dr_ta_1,
        ioa,
        <<nof::little-unsigned-16, len::little-unsigned-24, sof::8, rest::binary>>
      ) do
    with {:ok, ct, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %FileDirectory{
         ioa: ioa,
         nof: nof,
         length_of_file: len,
         sof: sof,
         creation_time: ct
       }, rest2}
    end
  end

  def decode_payload(:f_sc_nb_1, ioa, <<nof::little-unsigned-16, rest::binary>>) do
    with {:ok, start_t, rest2} <- CP56Time2a.decode(rest),
         {:ok, stop_t, rest3} <- CP56Time2a.decode(rest2) do
      {:ok,
       %QueryLog{
         ioa: ioa,
         nof: nof,
         range_start_time: start_t,
         range_stop_time: stop_t
       }, rest3}
    end
  end

  def decode_payload(:f_fr_na_2, ioa, payload) do
    {:ok, %ExtendedFilePacket{ioa: ioa, payload: payload}, <<>>}
  end

  def decode_payload(_type, _ioa, _bin), do: {:error, :invalid_payload}

  defp ioa_or_nof(nof), do: nof
end
