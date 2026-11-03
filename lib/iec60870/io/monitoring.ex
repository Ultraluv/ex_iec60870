defmodule IEC60870.IO.Monitoring do
  @moduledoc """
  Monitoring direction Information Objects (TypeIDs 1..21, 30..41, 70).
  Matches `cs101_information_objects.c` in `lib60870-C`.
  """

  import Bitwise
  alias IEC60870.Types.{BCR, Qualifiers}
  alias IEC60870.Types.CPTime.{CP16Time2a, CP24Time2a, CP56Time2a}

  # 1: M_SP_NA_1, 2: M_SP_TA_1, 30: M_SP_TB_1
  defmodule SinglePointInformation do
    @moduledoc """
    Single point information with quality and optional timestamp (M_SP_NA_1, M_SP_TA_1, M_SP_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: boolean(),
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: false, quality: 0, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: value == true or value == 1,
        quality: Qualifiers.encode_quality(quality) &&& 0xF0,
        timestamp: timestamp
      }
    end
  end

  # 3: M_DP_NA_1, 4: M_DP_TA_1, 31: M_DP_TB_1
  defmodule DoublePointInformation do
    @moduledoc """
    Double point information with quality (:off, :on, etc.) and optional timestamp (M_DP_NA_1, M_DP_TA_1, M_DP_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: :intermediate | :off | :on | :indeterminate,
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: :off, quality: 0, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: Qualifiers.decode_double_point(Qualifiers.encode_double_point(value)),
        quality: Qualifiers.encode_quality(quality) &&& 0xF0,
        timestamp: timestamp
      }
    end
  end

  # 5: M_ST_NA_1, 6: M_ST_TA_1, 32: M_ST_TB_1
  defmodule StepPositionInformation do
    @moduledoc """
    Step position information with transient state and quality (M_ST_NA_1, M_ST_TA_1, M_ST_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: -64..63,
            transient: boolean(),
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0, transient: false, quality: 0, timestamp: nil

    def new(ioa, value, transient \\ false, quality \\ 0, timestamp \\ nil) do
      clamped = max(-64, min(63, value))

      %__MODULE__{
        ioa: ioa,
        value: clamped,
        transient: transient == true,
        quality: Qualifiers.encode_quality(quality),
        timestamp: timestamp
      }
    end
  end

  # 7: M_BO_NA_1, 8: M_BO_TA_1, 33: M_BO_TB_1
  defmodule BitString32 do
    @moduledoc """
    32-bit bitstring value with quality and optional timestamp (M_BO_NA_1, M_BO_TA_1, M_BO_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: non_neg_integer(),
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0, quality: 0, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: value &&& 0xFFFFFFFF,
        quality: Qualifiers.encode_quality(quality),
        timestamp: timestamp
      }
    end
  end

  # 9: M_ME_NA_1, 10: M_ME_TA_1, 34: M_ME_TD_1, 21: M_ME_ND_1 (without_quality: true)
  defmodule MeasuredValueNormalized do
    @moduledoc """
    Normalized measured value (-1.0..+1.0 / -32768..32767) (M_ME_NA_1, M_ME_TA_1, M_ME_TD_1, M_ME_ND_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            quality: nil | byte(),
            without_quality: boolean(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0.0, quality: 0, without_quality: false, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      scaled = Qualifiers.normalized_to_scaled(value)

      %__MODULE__{
        ioa: ioa,
        value: Qualifiers.scaled_to_normalized(scaled),
        quality: if(quality == nil, do: nil, else: Qualifiers.encode_quality(quality)),
        without_quality: quality == nil,
        timestamp: timestamp
      }
    end

    def new_without_quality(ioa, value) do
      new(ioa, value, nil, nil)
    end
  end

  # 11: M_ME_NB_1, 12: M_ME_TB_1, 35: M_ME_TE_1
  defmodule MeasuredValueScaled do
    @moduledoc """
    16-bit scaled integer measured value (-32768..32767) (M_ME_NB_1, M_ME_TB_1, M_ME_TE_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: -32768..32767,
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0, quality: 0, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      clamped = max(-32768, min(32767, value))

      %__MODULE__{
        ioa: ioa,
        value: clamped,
        quality: Qualifiers.encode_quality(quality),
        timestamp: timestamp
      }
    end
  end

  # 13: M_ME_NC_1, 14: M_ME_TC_1, 36: M_ME_TF_1
  defmodule MeasuredValueShort do
    @moduledoc """
    IEEE 754 32-bit single precision floating point measured value (M_ME_NC_1, M_ME_TC_1, M_ME_TF_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            quality: byte(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0.0, quality: 0, timestamp: nil

    def new(ioa, value, quality \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: value * 1.0,
        quality: Qualifiers.encode_quality(quality),
        timestamp: timestamp
      }
    end
  end

  # 15: M_IT_NA_1, 16: M_IT_TA_1, 37: M_IT_TB_1
  defmodule IntegratedTotals do
    @moduledoc """
    Integrated totals / counter value (BinaryCounterReading BCR) (M_IT_NA_1, M_IT_TA_1, M_IT_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            bcr: BCR.t(),
            timestamp: nil | CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0, bcr: %BCR{}, timestamp: nil

    def new(ioa, %BCR{} = bcr, timestamp \\ nil) do
      %__MODULE__{ioa: ioa, bcr: bcr, timestamp: timestamp}
    end
  end

  # 41: S_IT_TC_1
  defmodule IntegratedTotalsForSecurityStatistics do
    @moduledoc """
    Security statistics totals with sequence number (S_IT_TC_1, TypeID 41).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            aid: non_neg_integer(),
            bcr: BCR.t(),
            timestamp: CP56Time2a.t()
          }
    defstruct ioa: 0, aid: 0, bcr: %BCR{}, timestamp: %CP56Time2a{}

    def new(ioa, aid, %BCR{} = bcr, %CP56Time2a{} = timestamp) do
      %__MODULE__{ioa: ioa, aid: aid &&& 0xFFFF, bcr: bcr, timestamp: timestamp}
    end
  end

  # 17: M_EP_TA_1, 38: M_EP_TD_1
  defmodule EventOfProtectionEquipment do
    @moduledoc """
    Event of protection equipment with relative elapsed time (M_EP_TA_1, M_EP_TD_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            event_state: :indeterminate_0 | :off | :on | :indeterminate_3,
            qdp: byte(),
            elapsed_time: CP16Time2a.t(),
            timestamp: CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0,
              event_state: :off,
              qdp: 0,
              elapsed_time: %CP16Time2a{},
              timestamp: %CP24Time2a{}

    def new(ioa, event_state, qdp, %CP16Time2a{} = elapsed_time, timestamp) do
      %__MODULE__{
        ioa: ioa,
        event_state: Qualifiers.decode_event_state(Qualifiers.encode_event_state(event_state)),
        qdp: Qualifiers.encode_quality(qdp) &&& 0xFC,
        elapsed_time: elapsed_time,
        timestamp: timestamp
      }
    end
  end

  # 18: M_EP_TB_1, 39: M_EP_TE_1
  defmodule PackedStartEventsOfProtectionEquipment do
    @moduledoc """
    Packed start events of protection equipment (M_EP_TB_1, M_EP_TE_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            event: byte(),
            qdp: byte(),
            elapsed_time: CP16Time2a.t(),
            timestamp: CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0,
              event: 0,
              qdp: 0,
              elapsed_time: %CP16Time2a{},
              timestamp: %CP24Time2a{}

    def new(ioa, event, qdp, %CP16Time2a{} = elapsed_time, timestamp) do
      %__MODULE__{
        ioa: ioa,
        event: event &&& 0xFF,
        qdp: Qualifiers.encode_quality(qdp),
        elapsed_time: elapsed_time,
        timestamp: timestamp
      }
    end
  end

  # 19: M_EP_TC_1, 40: M_EP_TF_1
  defmodule PackedOutputCircuitInfo do
    @moduledoc """
    Packed output circuit information of protection equipment (M_EP_TC_1, M_EP_TF_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            oci: byte(),
            qdp: byte(),
            operating_time: CP16Time2a.t(),
            timestamp: CP24Time2a.t() | CP56Time2a.t()
          }
    defstruct ioa: 0,
              oci: 0,
              qdp: 0,
              operating_time: %CP16Time2a{},
              timestamp: %CP24Time2a{}

    def new(ioa, oci, qdp, %CP16Time2a{} = operating_time, timestamp) do
      %__MODULE__{
        ioa: ioa,
        oci: oci &&& 0xFF,
        qdp: Qualifiers.encode_quality(qdp),
        operating_time: operating_time,
        timestamp: timestamp
      }
    end
  end

  # 20: M_PS_NA_1
  defmodule PackedSinglePointWithSCD do
    @moduledoc """
    Packed single-point information with status change detection (M_PS_NA_1, TypeID 20).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            stn: non_neg_integer(),
            cdn: non_neg_integer(),
            quality: byte()
          }
    defstruct ioa: 0, stn: 0, cdn: 0, quality: 0

    def new(ioa, stn, cdn, quality \\ 0) do
      %__MODULE__{
        ioa: ioa,
        stn: stn &&& 0xFFFF,
        cdn: cdn &&& 0xFFFF,
        quality: Qualifiers.encode_quality(quality)
      }
    end
  end

  # 70: M_EI_NA_1
  defmodule EndOfInitialization do
    @moduledoc """
    End of initialization indicator with cause of initialization (M_EI_NA_1, TypeID 70).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            coi: byte()
          }
    defstruct ioa: 0, coi: 0

    def new(coi, ioa \\ 0) do
      %__MODULE__{ioa: ioa, coi: coi &&& 0xFF}
    end
  end

  # Top-level convenience constructors
  @doc """
  Constructs a single point information object without timestamp (`M_SP_NA_1`).
  """
  def single_point(ioa, value, quality \\ 0),
    do: SinglePointInformation.new(ioa, value, quality, nil)

  @doc """
  Constructs a single point information object with `CP24Time2a` timestamp (`M_SP_TA_1`).
  """
  def single_point_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: SinglePointInformation.new(ioa, value, quality, ts)

  @doc """
  Constructs a single point information object with `CP56Time2a` timestamp (`M_SP_TB_1`).
  """
  def single_point_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: SinglePointInformation.new(ioa, value, quality, ts)

  @doc """
  Constructs a double point information object without timestamp (`M_DP_NA_1`).
  """
  def double_point(ioa, value, quality \\ 0),
    do: DoublePointInformation.new(ioa, value, quality, nil)

  @doc """
  Constructs a double point information object with `CP24Time2a` timestamp (`M_DP_TA_1`).
  """
  def double_point_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: DoublePointInformation.new(ioa, value, quality, ts)

  @doc """
  Constructs a double point information object with `CP56Time2a` timestamp (`M_DP_TB_1`).
  """
  def double_point_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: DoublePointInformation.new(ioa, value, quality, ts)

  @doc """
  Constructs a step position information object without timestamp (`M_ST_NA_1`).
  """
  def step_position(ioa, value, transient \\ false, quality \\ 0),
    do: StepPositionInformation.new(ioa, value, transient, quality, nil)

  @doc """
  Constructs a step position information object with `CP24Time2a` timestamp (`M_ST_TA_1`).
  """
  def step_position_cp24time2a(ioa, value, transient, quality, %CP24Time2a{} = ts),
    do: StepPositionInformation.new(ioa, value, transient, quality, ts)

  @doc """
  Constructs a step position information object with `CP56Time2a` timestamp (`M_ST_TB_1`).
  """
  def step_position_cp56time2a(ioa, value, transient, quality, %CP56Time2a{} = ts),
    do: StepPositionInformation.new(ioa, value, transient, quality, ts)

  @doc """
  Constructs a 32-bit bitstring object without timestamp (`M_BO_NA_1`).
  """
  def bitstring32(ioa, value, quality \\ 0),
    do: BitString32.new(ioa, value, quality, nil)

  @doc """
  Constructs a 32-bit bitstring object with `CP24Time2a` timestamp (`M_BO_TA_1`).
  """
  def bitstring32_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: BitString32.new(ioa, value, quality, ts)

  @doc """
  Constructs a 32-bit bitstring object with `CP56Time2a` timestamp (`M_BO_TB_1`).
  """
  def bitstring32_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: BitString32.new(ioa, value, quality, ts)

  @doc """
  Constructs a normalized measured value without timestamp (`M_ME_NA_1`).
  """
  def measured_value_normalized(ioa, value, quality \\ 0),
    do: MeasuredValueNormalized.new(ioa, value, quality, nil)

  @doc """
  Constructs a normalized measured value with `CP24Time2a` timestamp (`M_ME_TA_1`).
  """
  def measured_value_normalized_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: MeasuredValueNormalized.new(ioa, value, quality, ts)

  @doc """
  Constructs a normalized measured value with `CP56Time2a` timestamp (`M_ME_TD_1`).
  """
  def measured_value_normalized_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: MeasuredValueNormalized.new(ioa, value, quality, ts)

  @doc """
  Constructs a normalized measured value without quality (`M_ME_ND_1`).
  """
  def measured_value_normalized_without_quality(ioa, value),
    do: MeasuredValueNormalized.new_without_quality(ioa, value)

  @doc """
  Constructs a scaled measured value without timestamp (`M_ME_NB_1`).
  """
  def measured_value_scaled(ioa, value, quality \\ 0),
    do: MeasuredValueScaled.new(ioa, value, quality, nil)

  @doc """
  Constructs a scaled measured value with `CP24Time2a` timestamp (`M_ME_TB_1`).
  """
  def measured_value_scaled_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: MeasuredValueScaled.new(ioa, value, quality, ts)

  @doc """
  Constructs a scaled measured value with `CP56Time2a` timestamp (`M_ME_TE_1`).
  """
  def measured_value_scaled_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: MeasuredValueScaled.new(ioa, value, quality, ts)

  @doc """
  Constructs a short float measured value without timestamp (`M_ME_NC_1`).
  """
  def measured_value_short(ioa, value, quality \\ 0),
    do: MeasuredValueShort.new(ioa, value, quality, nil)

  @doc """
  Constructs a short float measured value with `CP24Time2a` timestamp (`M_ME_TC_1`).
  """
  def measured_value_short_cp24time2a(ioa, value, quality, %CP24Time2a{} = ts),
    do: MeasuredValueShort.new(ioa, value, quality, ts)

  @doc """
  Constructs a short float measured value with `CP56Time2a` timestamp (`M_ME_TF_1`).
  """
  def measured_value_short_cp56time2a(ioa, value, quality, %CP56Time2a{} = ts),
    do: MeasuredValueShort.new(ioa, value, quality, ts)

  @doc """
  Constructs a counter totals object without timestamp (`M_IT_NA_1`).
  """
  def integrated_totals(ioa, %BCR{} = bcr),
    do: IntegratedTotals.new(ioa, bcr, nil)

  @doc """
  Constructs a counter totals object with `CP24Time2a` timestamp (`M_IT_TA_1`).
  """
  def integrated_totals_cp24time2a(ioa, %BCR{} = bcr, %CP24Time2a{} = ts),
    do: IntegratedTotals.new(ioa, bcr, ts)

  @doc """
  Constructs a counter totals object with `CP56Time2a` timestamp (`M_IT_TB_1`).
  """
  def integrated_totals_cp56time2a(ioa, %BCR{} = bcr, %CP56Time2a{} = ts),
    do: IntegratedTotals.new(ioa, bcr, ts)

  def event_of_protection_equipment_cp24time2a(
        ioa,
        es,
        qdp,
        %CP16Time2a{} = et,
        %CP24Time2a{} = ts
      ),
      do: EventOfProtectionEquipment.new(ioa, es, qdp, et, ts)

  def event_of_protection_equipment_cp56time2a(
        ioa,
        es,
        qdp,
        %CP16Time2a{} = et,
        %CP56Time2a{} = ts
      ),
      do: EventOfProtectionEquipment.new(ioa, es, qdp, et, ts)

  def packed_start_events_of_protection_equipment_cp24time2a(
        ioa,
        ev,
        qdp,
        %CP16Time2a{} = et,
        %CP24Time2a{} = ts
      ),
      do: PackedStartEventsOfProtectionEquipment.new(ioa, ev, qdp, et, ts)

  def packed_start_events_of_protection_equipment_cp56time2a(
        ioa,
        ev,
        qdp,
        %CP16Time2a{} = et,
        %CP56Time2a{} = ts
      ),
      do: PackedStartEventsOfProtectionEquipment.new(ioa, ev, qdp, et, ts)

  def packed_output_circuit_info_cp24time2a(
        ioa,
        oci,
        qdp,
        %CP16Time2a{} = ot,
        %CP24Time2a{} = ts
      ),
      do: PackedOutputCircuitInfo.new(ioa, oci, qdp, ot, ts)

  def packed_output_circuit_info_cp56time2a(
        ioa,
        oci,
        qdp,
        %CP16Time2a{} = ot,
        %CP56Time2a{} = ts
      ),
      do: PackedOutputCircuitInfo.new(ioa, oci, qdp, ot, ts)

  def packed_single_point_with_scd(ioa, stn, cdn, quality \\ 0),
    do: PackedSinglePointWithSCD.new(ioa, stn, cdn, quality)

  @doc """
  Constructs an end-of-initialization indicator object (`M_EI_NA_1`, TypeID 70).
  """
  def end_of_initialization(ioa \\ 0, coi \\ 0),
    do: EndOfInitialization.new(coi, ioa)

  # Encoding & Decoding for Monitoring IOs

  def encode_payload(%SinglePointInformation{value: val, quality: q, timestamp: ts}) do
    siq = (q &&& 0xF0) + if(val, do: 1, else: 0)
    <<siq::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%DoublePointInformation{value: val, quality: q, timestamp: ts}) do
    diq = (q &&& 0xF0) + Qualifiers.encode_double_point(val)
    <<diq::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%StepPositionInformation{
        value: val,
        transient: tr,
        quality: q,
        timestamp: ts
      }) do
    unsigned_val = if val < 0, do: val + 128, else: val
    vti = (unsigned_val &&& 0x7F) ||| if(tr, do: 0x80, else: 0)
    <<vti::8, q::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%BitString32{value: val, quality: q, timestamp: ts}) do
    <<val::little-unsigned-32, q::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%MeasuredValueNormalized{
        value: val,
        without_quality: true
      }) do
    scaled = Qualifiers.normalized_to_scaled(val)
    <<scaled::little-signed-16>>
  end

  def encode_payload(%MeasuredValueNormalized{
        value: val,
        quality: q,
        without_quality: false,
        timestamp: ts
      }) do
    scaled = Qualifiers.normalized_to_scaled(val)
    <<scaled::little-signed-16, q || 0::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%MeasuredValueScaled{value: val, quality: q, timestamp: ts}) do
    <<val::little-signed-16, q::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%MeasuredValueShort{value: val, quality: q, timestamp: ts}) do
    <<encode_float32(val)::binary, q::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%IntegratedTotals{bcr: bcr, timestamp: ts}) do
    <<BCR.encode(bcr)::binary, encode_ts(ts)::binary>>
  end

  def encode_payload(%IntegratedTotalsForSecurityStatistics{aid: aid, bcr: bcr, timestamp: ts}) do
    <<aid::little-unsigned-16, BCR.encode(bcr)::binary, CP56Time2a.encode(ts)::binary>>
  end

  def encode_payload(%EventOfProtectionEquipment{
        event_state: es,
        qdp: qdp,
        elapsed_time: et,
        timestamp: ts
      }) do
    se = Qualifiers.encode_single_event(es, qdp)
    <<se::8, CP16Time2a.encode(et)::binary, encode_ts(ts)::binary>>
  end

  def encode_payload(%PackedStartEventsOfProtectionEquipment{
        event: ev,
        qdp: qdp,
        elapsed_time: et,
        timestamp: ts
      }) do
    <<ev::8, qdp::8, CP16Time2a.encode(et)::binary, encode_ts(ts)::binary>>
  end

  def encode_payload(%PackedOutputCircuitInfo{
        oci: oci,
        qdp: qdp,
        operating_time: ot,
        timestamp: ts
      }) do
    <<oci::8, qdp::8, CP16Time2a.encode(ot)::binary, encode_ts(ts)::binary>>
  end

  def encode_payload(%PackedSinglePointWithSCD{stn: stn, cdn: cdn, quality: q}) do
    <<Qualifiers.encode_scd(stn, cdn)::binary, q::8>>
  end

  def encode_payload(%EndOfInitialization{coi: coi}) do
    <<coi::8>>
  end

  defp encode_ts(nil), do: <<>>
  defp encode_ts(%CP24Time2a{} = ts), do: CP24Time2a.encode(ts)
  defp encode_ts(%CP56Time2a{} = ts), do: CP56Time2a.encode(ts)

  defp encode_float32(:nan), do: <<0, 0, 0xC0, 0x7F>>
  defp encode_float32(:infinity), do: <<0, 0, 0x80, 0x7F>>
  defp encode_float32(:neg_infinity), do: <<0, 0, 0x80, 0xFF>>
  defp encode_float32(val) when is_number(val), do: <<val::little-float-32>>

  defp decode_float32(<<val::little-float-32>>), do: val
  defp decode_float32(<<0, 0, 0x80, 0x7F>>), do: :infinity
  defp decode_float32(<<0, 0, 0x80, 0xFF>>), do: :neg_infinity
  defp decode_float32(<<_::binary-size(4)>>), do: :nan

  # Decoding
  def decode_payload(:m_sp_na_1, ioa, <<siq::8, rest::binary>>) do
    {:ok, %SinglePointInformation{ioa: ioa, value: (siq &&& 0x01) == 1, quality: siq &&& 0xF0},
     rest}
  end

  def decode_payload(:m_sp_ta_1, ioa, <<siq::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok,
       %SinglePointInformation{
         ioa: ioa,
         value: (siq &&& 0x01) == 1,
         quality: siq &&& 0xF0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_sp_tb_1, ioa, <<siq::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %SinglePointInformation{
         ioa: ioa,
         value: (siq &&& 0x01) == 1,
         quality: siq &&& 0xF0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_dp_na_1, ioa, <<diq::8, rest::binary>>) do
    {:ok,
     %DoublePointInformation{
       ioa: ioa,
       value: Qualifiers.decode_double_point(diq &&& 0x03),
       quality: diq &&& 0xF0
     }, rest}
  end

  def decode_payload(:m_dp_ta_1, ioa, <<diq::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok,
       %DoublePointInformation{
         ioa: ioa,
         value: Qualifiers.decode_double_point(diq &&& 0x03),
         quality: diq &&& 0xF0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_dp_tb_1, ioa, <<diq::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %DoublePointInformation{
         ioa: ioa,
         value: Qualifiers.decode_double_point(diq &&& 0x03),
         quality: diq &&& 0xF0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_st_na_1, ioa, <<vti::8, q::8, rest::binary>>) do
    {val, tr} = decode_vti(vti)
    {:ok, %StepPositionInformation{ioa: ioa, value: val, transient: tr, quality: q}, rest}
  end

  def decode_payload(:m_st_ta_1, ioa, <<vti::8, q::8, rest::binary>>) do
    {val, tr} = decode_vti(vti)

    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok,
       %StepPositionInformation{ioa: ioa, value: val, transient: tr, quality: q, timestamp: ts},
       rest2}
    end
  end

  def decode_payload(:m_st_tb_1, ioa, <<vti::8, q::8, rest::binary>>) do
    {val, tr} = decode_vti(vti)

    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %StepPositionInformation{ioa: ioa, value: val, transient: tr, quality: q, timestamp: ts},
       rest2}
    end
  end

  def decode_payload(:m_bo_na_1, ioa, <<val::little-unsigned-32, q::8, rest::binary>>) do
    {:ok, %BitString32{ioa: ioa, value: val, quality: q}, rest}
  end

  def decode_payload(:m_bo_ta_1, ioa, <<val::little-unsigned-32, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok, %BitString32{ioa: ioa, value: val, quality: q, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:m_bo_tb_1, ioa, <<val::little-unsigned-32, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok, %BitString32{ioa: ioa, value: val, quality: q, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:m_me_nd_1, ioa, <<scaled::little-signed-16, rest::binary>>) do
    {:ok,
     %MeasuredValueNormalized{
       ioa: ioa,
       value: Qualifiers.scaled_to_normalized(scaled),
       quality: nil,
       without_quality: true
     }, rest}
  end

  def decode_payload(:m_me_na_1, ioa, <<scaled::little-signed-16, q::8, rest::binary>>) do
    {:ok,
     %MeasuredValueNormalized{
       ioa: ioa,
       value: Qualifiers.scaled_to_normalized(scaled),
       quality: q,
       without_quality: false
     }, rest}
  end

  def decode_payload(:m_me_ta_1, ioa, <<scaled::little-signed-16, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok,
       %MeasuredValueNormalized{
         ioa: ioa,
         value: Qualifiers.scaled_to_normalized(scaled),
         quality: q,
         without_quality: false,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_me_td_1, ioa, <<scaled::little-signed-16, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %MeasuredValueNormalized{
         ioa: ioa,
         value: Qualifiers.scaled_to_normalized(scaled),
         quality: q,
         without_quality: false,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:m_me_nb_1, ioa, <<val::little-signed-16, q::8, rest::binary>>) do
    {:ok, %MeasuredValueScaled{ioa: ioa, value: val, quality: q}, rest}
  end

  def decode_payload(:m_me_tb_1, ioa, <<val::little-signed-16, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok, %MeasuredValueScaled{ioa: ioa, value: val, quality: q, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:m_me_te_1, ioa, <<val::little-signed-16, q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok, %MeasuredValueScaled{ioa: ioa, value: val, quality: q, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:m_me_nc_1, ioa, <<raw_f::binary-size(4), q::8, rest::binary>>) do
    {:ok, %MeasuredValueShort{ioa: ioa, value: decode_float32(raw_f), quality: q}, rest}
  end

  def decode_payload(:m_me_tc_1, ioa, <<raw_f::binary-size(4), q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok,
       %MeasuredValueShort{ioa: ioa, value: decode_float32(raw_f), quality: q, timestamp: ts},
       rest2}
    end
  end

  def decode_payload(:m_me_tf_1, ioa, <<raw_f::binary-size(4), q::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %MeasuredValueShort{ioa: ioa, value: decode_float32(raw_f), quality: q, timestamp: ts},
       rest2}
    end
  end

  def decode_payload(:m_it_na_1, ioa, bin) do
    with {:ok, bcr, rest} <- BCR.decode(bin) do
      {:ok, %IntegratedTotals{ioa: ioa, bcr: bcr}, rest}
    end
  end

  def decode_payload(:m_it_ta_1, ioa, bin) do
    with {:ok, bcr, rest} <- BCR.decode(bin),
         {:ok, ts, rest2} <- CP24Time2a.decode(rest) do
      {:ok, %IntegratedTotals{ioa: ioa, bcr: bcr, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:m_it_tb_1, ioa, bin) do
    with {:ok, bcr, rest} <- BCR.decode(bin),
         {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok, %IntegratedTotals{ioa: ioa, bcr: bcr, timestamp: ts}, rest2}
    end
  end

  def decode_payload(:s_it_tc_1, ioa, <<aid::little-unsigned-16, rest::binary>>) do
    with {:ok, bcr, rest2} <- BCR.decode(rest),
         {:ok, ts, rest3} <- CP56Time2a.decode(rest2) do
      {:ok, %IntegratedTotalsForSecurityStatistics{ioa: ioa, aid: aid, bcr: bcr, timestamp: ts},
       rest3}
    end
  end

  def decode_payload(:m_ep_ta_1, ioa, <<se::8, rest::binary>>) do
    {es, qdp} = Qualifiers.decode_single_event(se)

    with {:ok, et, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP24Time2a.decode(rest2) do
      {:ok,
       %EventOfProtectionEquipment{
         ioa: ioa,
         event_state: es,
         qdp: qdp,
         elapsed_time: et,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ep_td_1, ioa, <<se::8, rest::binary>>) do
    {es, qdp} = Qualifiers.decode_single_event(se)

    with {:ok, et, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP56Time2a.decode(rest2) do
      {:ok,
       %EventOfProtectionEquipment{
         ioa: ioa,
         event_state: es,
         qdp: qdp,
         elapsed_time: et,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ep_tb_1, ioa, <<ev::8, qdp::8, rest::binary>>) do
    with {:ok, et, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP24Time2a.decode(rest2) do
      {:ok,
       %PackedStartEventsOfProtectionEquipment{
         ioa: ioa,
         event: ev,
         qdp: qdp,
         elapsed_time: et,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ep_te_1, ioa, <<ev::8, qdp::8, rest::binary>>) do
    with {:ok, et, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP56Time2a.decode(rest2) do
      {:ok,
       %PackedStartEventsOfProtectionEquipment{
         ioa: ioa,
         event: ev,
         qdp: qdp,
         elapsed_time: et,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ep_tc_1, ioa, <<oci::8, qdp::8, rest::binary>>) do
    with {:ok, ot, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP24Time2a.decode(rest2) do
      {:ok,
       %PackedOutputCircuitInfo{
         ioa: ioa,
         oci: oci,
         qdp: qdp,
         operating_time: ot,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ep_tf_1, ioa, <<oci::8, qdp::8, rest::binary>>) do
    with {:ok, ot, rest2} <- CP16Time2a.decode(rest),
         {:ok, ts, rest3} <- CP56Time2a.decode(rest2) do
      {:ok,
       %PackedOutputCircuitInfo{
         ioa: ioa,
         oci: oci,
         qdp: qdp,
         operating_time: ot,
         timestamp: ts
       }, rest3}
    end
  end

  def decode_payload(:m_ps_na_1, ioa, <<scd::binary-size(4), qds::8, rest::binary>>) do
    {stn, cdn} = Qualifiers.decode_scd(scd)
    {:ok, %PackedSinglePointWithSCD{ioa: ioa, stn: stn, cdn: cdn, quality: qds}, rest}
  end

  def decode_payload(:m_ei_na_1, ioa, <<coi::8, rest::binary>>) do
    {:ok, %EndOfInitialization{ioa: ioa, coi: coi}, rest}
  end

  def decode_payload(_type, _ioa, _bin), do: {:error, :invalid_payload}

  defp decode_vti(vti) do
    raw = vti &&& 0x7F
    val = if raw > 63, do: raw - 128, else: raw
    transient = (vti &&& 0x80) != 0
    {val, transient}
  end
end
