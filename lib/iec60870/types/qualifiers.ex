defmodule IEC60870.Types.Qualifiers do
  @moduledoc """
  Quality descriptors, qualifiers, and value scaling helpers for IEC 60870-5-101/104.
  Matches `cs101_information_objects.h` and `cs101_information_objects.c`.
  """

  import Bitwise

  # QualityDescriptor (QDS) and QualityDescriptorP (QDP) bit flags
  @quality_good 0x00
  @quality_overflow 0x01
  @quality_reserved 0x04
  @quality_elapsed_time_invalid 0x08
  @quality_blocked 0x10
  @quality_substituted 0x20
  @quality_non_topical 0x40
  @quality_invalid 0x80

  def quality_good, do: @quality_good
  def quality_overflow, do: @quality_overflow
  def quality_reserved, do: @quality_reserved
  def quality_elapsed_time_invalid, do: @quality_elapsed_time_invalid
  def quality_blocked, do: @quality_blocked
  def quality_substituted, do: @quality_substituted
  def quality_non_topical, do: @quality_non_topical
  def quality_invalid, do: @quality_invalid

  @doc """
  Packs a list of quality atoms or an integer bitmask into a `uint8` quality byte.
  Supported flags: `:overflow`, `:reserved`, `:elapsed_time_invalid`, `:blocked`, `:substituted`, `:non_topical`, `:invalid`, `:good`.
  """
  @spec encode_quality(non_neg_integer() | [atom()]) :: byte()
  def encode_quality(q) when is_integer(q), do: q &&& 0xFF

  def encode_quality(flags) when is_list(flags) do
    Enum.reduce(flags, 0, fn
      :good, acc -> acc
      :overflow, acc -> acc ||| @quality_overflow
      :reserved, acc -> acc ||| @quality_reserved
      :elapsed_time_invalid, acc -> acc ||| @quality_elapsed_time_invalid
      :blocked, acc -> acc ||| @quality_blocked
      :substituted, acc -> acc ||| @quality_substituted
      :non_topical, acc -> acc ||| @quality_non_topical
      :invalid, acc -> acc ||| @quality_invalid
    end)
  end

  @doc """
  Checks whether a specific quality flag is set in a quality byte.
  """
  @spec has_quality_flag?(byte(), atom()) :: boolean()
  def has_quality_flag?(q, :overflow), do: (q &&& @quality_overflow) != 0
  def has_quality_flag?(q, :reserved), do: (q &&& @quality_reserved) != 0
  def has_quality_flag?(q, :elapsed_time_invalid), do: (q &&& @quality_elapsed_time_invalid) != 0
  def has_quality_flag?(q, :blocked), do: (q &&& @quality_blocked) != 0
  def has_quality_flag?(q, :substituted), do: (q &&& @quality_substituted) != 0
  def has_quality_flag?(q, :non_topical), do: (q &&& @quality_non_topical) != 0
  def has_quality_flag?(q, :invalid), do: (q &&& @quality_invalid) != 0

  # StartEvent (SPE) bit flags
  def start_event_none, do: 0x00
  def start_event_gs, do: 0x01
  def start_event_sl1, do: 0x02
  def start_event_sl2, do: 0x04
  def start_event_sl3, do: 0x08
  def start_event_sie, do: 0x10
  def start_event_srd, do: 0x20
  def start_event_res1, do: 0x40
  def start_event_res2, do: 0x80

  # OutputCircuitInfo (OCI) bit flags
  def output_ci_gc, do: 0x01
  def output_ci_cl1, do: 0x02
  def output_ci_cl2, do: 0x04
  def output_ci_cl3, do: 0x08

  # Qualifier of Parameter of Measured Values (QPM)
  def qpm_not_used, do: 0
  def qpm_threshold_value, do: 1
  def qpm_smoothing_factor, do: 2
  def qpm_low_limit_for_transmission, do: 3
  def qpm_high_limit_for_transmission, do: 4

  # Cause of Initialization (COI)
  def coi_local_switch_on, do: 0
  def coi_local_manual_reset, do: 1
  def coi_remote_reset, do: 2

  # Qualifier of Command (QOC)
  def qoc_no_additional_definition, do: 0
  def qoc_short_pulse_duration, do: 1
  def qoc_long_pulse_duration, do: 2
  def qoc_persistent_output, do: 3

  # Qualifier of Interrogation (QOI)
  def qoi_station, do: 20
  def qoi_group(n) when n in 1..16, do: 20 + n

  # Qualifier of Counter Interrogation (QCC = RQT + FRZ)
  def qcc_rqt_group(n) when n in 1..4, do: n
  def qcc_rqt_general, do: 5
  def qcc_frz_read, do: 0x00
  def qcc_frz_freeze_without_reset, do: 0x40
  def qcc_frz_freeze_with_reset, do: 0x80
  def qcc_frz_counter_reset, do: 0xC0

  # Qualifier of Reset Process Command (QRP)
  def qrp_not_used, do: 0
  def qrp_general_reset, do: 1
  def qrp_reset_pending_info_with_time_tag, do: 2

  # Qualifier of Parameter Activation (QPA)
  def qpa_not_used, do: 0
  def qpa_de_act_prev_loaded_parameter, do: 1
  def qpa_de_act_object_parameter, do: 2
  def qpa_de_act_object_transmission, do: 3

  # File Service Qualifiers (NOF, SCQ, LSQ, AFQ, SOF, FileError)
  def nof_default, do: 0
  def nof_transparent_file, do: 1
  def nof_disturbance_data, do: 2
  def nof_sequences_of_events, do: 3
  def nof_sequences_of_analogue_values, do: 4

  def scq_default, do: 0
  def scq_select_file, do: 1
  def scq_request_file, do: 2
  def scq_deactivate_file, do: 3
  def scq_delete_file, do: 4
  def scq_select_section, do: 5
  def scq_request_section, do: 6
  def scq_deactivate_section, do: 7

  def lsq_not_used, do: 0
  def lsq_file_transfer_without_deact, do: 1
  def lsq_file_transfer_with_deact, do: 2
  def lsq_section_transfer_without_deact, do: 3
  def lsq_section_transfer_with_deact, do: 4

  def afq_not_used, do: 0
  def afq_pos_ack_file, do: 1
  def afq_neg_ack_file, do: 2
  def afq_pos_ack_section, do: 3
  def afq_neg_ack_section, do: 4

  def file_error_default, do: 0
  def file_error_req_memory_not_available, do: 1
  def file_error_checksum_failed, do: 2
  def file_error_unexpected_comm_service, do: 3
  def file_error_unexpected_name_of_file, do: 4
  def file_error_unexpected_name_of_section, do: 5

  def sof_status_mask, do: 0x1F
  def sof_lfd, do: 0x20
  def sof_for, do: 0x40
  def sof_fa, do: 0x80

  # DoublePointValue mapping
  @spec encode_double_point(atom() | 0..3) :: 0..3
  def encode_double_point(:intermediate), do: 0
  def encode_double_point(:transient), do: 0
  def encode_double_point(:off), do: 1
  def encode_double_point(:on), do: 2
  def encode_double_point(:indeterminate), do: 3

  @doc """
  Encodes double-point value (:indeterminate, :off, :on, :intermediate) to 2-bit integer.
  """
  def encode_double_point(v) when v in 0..3, do: v

  @spec decode_double_point(0..3) :: :intermediate | :off | :on | :indeterminate
  def decode_double_point(0), do: :intermediate
  def decode_double_point(1), do: :off
  def decode_double_point(2), do: :on
  def decode_double_point(3), do: :indeterminate

  # StepCommandValue mapping
  @spec encode_step_command(atom() | 0..3) :: 0..3
  def encode_step_command(:invalid_0), do: 0
  def encode_step_command(:lower), do: 1
  def encode_step_command(:higher), do: 2
  def encode_step_command(:invalid_3), do: 3

  @doc """
  Encodes regulating step command to byte.
  """
  def encode_step_command(v) when v in 0..3, do: v

  @spec decode_step_command(0..3) :: :invalid_0 | :lower | :higher | :invalid_3
  def decode_step_command(0), do: :invalid_0
  def decode_step_command(1), do: :lower
  def decode_step_command(2), do: :higher
  def decode_step_command(3), do: :invalid_3

  # EventState mapping
  @spec encode_event_state(atom() | 0..3) :: 0..3
  def encode_event_state(:indeterminate_0), do: 0
  def encode_event_state(:off), do: 1
  def encode_event_state(:on), do: 2
  def encode_event_state(:indeterminate_3), do: 3
  def encode_event_state(v) when v in 0..3, do: v

  @spec decode_event_state(0..3) :: :indeterminate_0 | :off | :on | :indeterminate_3
  def decode_event_state(0), do: :indeterminate_0
  def decode_event_state(1), do: :off
  def decode_event_state(2), do: :on
  def decode_event_state(3), do: :indeterminate_3

  # SingleEvent (1 byte: bits 0..1 = EventState, bits 2..7 = QDP)
  @spec encode_single_event(atom() | 0..3, byte()) :: byte()
  def encode_single_event(event_state, qdp) do
    (qdp &&& 0xFC) + (encode_event_state(event_state) &&& 0x03)
  end

  @spec decode_single_event(byte()) :: {atom(), byte()}
  def decode_single_event(byte) do
    {decode_event_state(byte &&& 0x03), byte &&& 0xFC}
  end

  # StatusAndStatusChangeDetection (SCD: 2 bytes STn + 2 bytes CDn, little-endian)
  @spec encode_scd(non_neg_integer(), non_neg_integer()) :: <<_::32>>
  def encode_scd(stn, cdn) do
    <<stn::little-unsigned-16, cdn::little-unsigned-16>>
  end

  @spec decode_scd(<<_::32>>) :: {non_neg_integer(), non_neg_integer()}
  def decode_scd(<<stn::little-unsigned-16, cdn::little-unsigned-16>>) do
    {stn, cdn}
  end

  @doc """
  Checks whether bit `i` (`0..15`) is set in `stn` (`StatusAndStatusChangeDetection_getST`).
  """
  @spec scd_get_st(non_neg_integer() | {non_neg_integer(), non_neg_integer()}, 0..15) :: boolean()
  def scd_get_st({stn, _cdn}, i) when i in 0..15, do: scd_get_st(stn, i)
  def scd_get_st(stn, i) when is_integer(stn) and i in 0..15, do: (stn &&& 1 <<< i) != 0

  @doc """
  Checks whether bit `i` (`0..15`) is set in `cdn` (`StatusAndStatusChangeDetection_getCD`).
  """
  @spec scd_get_cd(non_neg_integer() | {non_neg_integer(), non_neg_integer()}, 0..15) :: boolean()
  def scd_get_cd({_stn, cdn}, i) when i in 0..15, do: scd_get_cd(cdn, i)
  def scd_get_cd(cdn, i) when is_integer(cdn) and i in 0..15, do: (cdn &&& 1 <<< i) != 0

  # NormalizedValue <-> Scaled 16-bit integer conversion matching `lib60870-C`
  @normalized_max 32767.0 / 32768.0
  @normalized_min -1.0

  @spec normalized_to_scaled(number()) :: -32768..32767
  def normalized_to_scaled(value) when is_number(value) do
    clamped =
      cond do
        value > @normalized_max -> @normalized_max
        value < @normalized_min -> @normalized_min
        true -> value * 1.0
      end

    scaled = clamped * 32768.0

    if scaled < 0 do
      trunc(scaled - 0.5)
    else
      trunc(scaled + 0.5)
    end
  end

  @spec scaled_to_normalized(integer()) :: float()
  def scaled_to_normalized(value) when is_integer(value) do
    clamped =
      cond do
        value > 32767 -> 32767
        value < -32768 -> -32768
        true -> value
      end

    clamped / 32768.0
  end

  def float_to_normalized(value), do: normalized_to_scaled(value)
  def normalized_to_float(value), do: scaled_to_normalized(value)

  @doc """
  Encodes Quality Descriptor for Events of Protection Equipment (QDS).
  """

  def encode_qds(q) when is_integer(q) or is_list(q), do: encode_quality(q)

  def encode_qds(%{} = map) do
    0
    |> bor(if(Map.get(map, :overflow, false), do: @quality_overflow, else: 0))
    |> bor(if(Map.get(map, :blocked, false), do: @quality_blocked, else: 0))
    |> bor(if(Map.get(map, :substituted, false), do: @quality_substituted, else: 0))
    |> bor(if(Map.get(map, :non_topical, false), do: @quality_non_topical, else: 0))
    |> bor(if(Map.get(map, :invalid, false), do: @quality_invalid, else: 0))
  end

  def decode_qds(q) when is_integer(q) do
    %{
      overflow: (q &&& @quality_overflow) != 0,
      blocked: (q &&& @quality_blocked) != 0,
      substituted: (q &&& @quality_substituted) != 0,
      non_topical: (q &&& @quality_non_topical) != 0,
      invalid: (q &&& @quality_invalid) != 0
    }
  end
end
