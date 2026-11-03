defmodule IEC60870.InformationObject do
  @moduledoc """
  Unified dispatcher and helper functions for all IEC 60870-5-101/104 Information Objects.
  """

  alias IEC60870.AppLayerParameters
  alias IEC60870.Types.TypeID
  alias IEC60870.Types.CPTime.{CP24Time2a, CP56Time2a}

  alias IEC60870.IO.Monitoring.{
    SinglePointInformation,
    DoublePointInformation,
    StepPositionInformation,
    BitString32,
    MeasuredValueNormalized,
    MeasuredValueScaled,
    MeasuredValueShort,
    IntegratedTotals,
    IntegratedTotalsForSecurityStatistics,
    EventOfProtectionEquipment,
    PackedStartEventsOfProtectionEquipment,
    PackedOutputCircuitInfo,
    PackedSinglePointWithSCD,
    EndOfInitialization
  }

  alias IEC60870.IO.Control.{
    SingleCommand,
    DoubleCommand,
    StepCommand,
    SetpointCommandNormalized,
    SetpointCommandScaled,
    SetpointCommandShort,
    Bitstring32Command
  }

  alias IEC60870.IO.System.{
    InterrogationCommand,
    CounterInterrogationCommand,
    ReadCommand,
    ClockSynchronizationCommand,
    TestCommand,
    ResetProcessCommand,
    DelayAcquisitionCommand,
    TestCommandWithCP56Time2a
  }

  alias IEC60870.IO.Parameter.{
    ParameterNormalizedValue,
    ParameterScaledValue,
    ParameterFloatValue,
    ParameterActivation
  }

  alias IEC60870.IO.File.{
    FileReady,
    SectionReady,
    FileCallOrSelect,
    FileLastSegmentOrSection,
    FileACK,
    FileSegment,
    FileDirectory,
    QueryLog,
    ExtendedFilePacket
  }

  defmodule RawObject do
    @moduledoc """
    Fallback representation for custom or security ASDU payloads.
    """
    @type t :: %__MODULE__{
            type: TypeID.t(),
            ioa: non_neg_integer(),
            payload: binary()
          }
    defstruct type: 1, ioa: 0, payload: <<>>
  end

  @type t :: struct()

  @doc """
  Returns the Information Object Address (`ioa`) of any Information Object struct.
  """
  @spec ioa(t()) :: non_neg_integer()
  def ioa(%{ioa: ioa}), do: ioa

  @doc """
  Infers the `TypeID` atom for any Information Object struct based on its type and timestamp.
  """
  @spec type_id(t()) :: TypeID.name() | TypeID.code()
  def type_id(%SinglePointInformation{timestamp: nil}), do: :m_sp_na_1
  def type_id(%SinglePointInformation{timestamp: %CP24Time2a{}}), do: :m_sp_ta_1
  def type_id(%SinglePointInformation{timestamp: %CP56Time2a{}}), do: :m_sp_tb_1

  def type_id(%DoublePointInformation{timestamp: nil}), do: :m_dp_na_1
  def type_id(%DoublePointInformation{timestamp: %CP24Time2a{}}), do: :m_dp_ta_1
  def type_id(%DoublePointInformation{timestamp: %CP56Time2a{}}), do: :m_dp_tb_1

  def type_id(%StepPositionInformation{timestamp: nil}), do: :m_st_na_1
  def type_id(%StepPositionInformation{timestamp: %CP24Time2a{}}), do: :m_st_ta_1
  def type_id(%StepPositionInformation{timestamp: %CP56Time2a{}}), do: :m_st_tb_1

  def type_id(%BitString32{timestamp: nil}), do: :m_bo_na_1
  def type_id(%BitString32{timestamp: %CP24Time2a{}}), do: :m_bo_ta_1
  def type_id(%BitString32{timestamp: %CP56Time2a{}}), do: :m_bo_tb_1

  def type_id(%MeasuredValueNormalized{without_quality: true}), do: :m_me_nd_1
  def type_id(%MeasuredValueNormalized{timestamp: nil}), do: :m_me_na_1
  def type_id(%MeasuredValueNormalized{timestamp: %CP24Time2a{}}), do: :m_me_ta_1
  def type_id(%MeasuredValueNormalized{timestamp: %CP56Time2a{}}), do: :m_me_td_1

  def type_id(%MeasuredValueScaled{timestamp: nil}), do: :m_me_nb_1
  def type_id(%MeasuredValueScaled{timestamp: %CP24Time2a{}}), do: :m_me_tb_1
  def type_id(%MeasuredValueScaled{timestamp: %CP56Time2a{}}), do: :m_me_te_1

  def type_id(%MeasuredValueShort{timestamp: nil}), do: :m_me_nc_1
  def type_id(%MeasuredValueShort{timestamp: %CP24Time2a{}}), do: :m_me_tc_1
  def type_id(%MeasuredValueShort{timestamp: %CP56Time2a{}}), do: :m_me_tf_1

  def type_id(%IntegratedTotals{timestamp: nil}), do: :m_it_na_1
  def type_id(%IntegratedTotals{timestamp: %CP24Time2a{}}), do: :m_it_ta_1
  def type_id(%IntegratedTotals{timestamp: %CP56Time2a{}}), do: :m_it_tb_1

  def type_id(%IntegratedTotalsForSecurityStatistics{}), do: :s_it_tc_1

  def type_id(%EventOfProtectionEquipment{timestamp: %CP24Time2a{}}), do: :m_ep_ta_1
  def type_id(%EventOfProtectionEquipment{timestamp: %CP56Time2a{}}), do: :m_ep_td_1

  def type_id(%PackedStartEventsOfProtectionEquipment{timestamp: %CP24Time2a{}}), do: :m_ep_tb_1
  def type_id(%PackedStartEventsOfProtectionEquipment{timestamp: %CP56Time2a{}}), do: :m_ep_te_1

  def type_id(%PackedOutputCircuitInfo{timestamp: %CP24Time2a{}}), do: :m_ep_tc_1
  def type_id(%PackedOutputCircuitInfo{timestamp: %CP56Time2a{}}), do: :m_ep_tf_1

  def type_id(%PackedSinglePointWithSCD{}), do: :m_ps_na_1
  def type_id(%EndOfInitialization{}), do: :m_ei_na_1

  def type_id(%SingleCommand{timestamp: nil}), do: :c_sc_na_1
  def type_id(%SingleCommand{timestamp: %CP56Time2a{}}), do: :c_sc_ta_1

  def type_id(%DoubleCommand{timestamp: nil}), do: :c_dc_na_1
  def type_id(%DoubleCommand{timestamp: %CP56Time2a{}}), do: :c_dc_ta_1

  def type_id(%StepCommand{timestamp: nil}), do: :c_rc_na_1
  def type_id(%StepCommand{timestamp: %CP56Time2a{}}), do: :c_rc_ta_1

  def type_id(%SetpointCommandNormalized{timestamp: nil}), do: :c_se_na_1
  def type_id(%SetpointCommandNormalized{timestamp: %CP56Time2a{}}), do: :c_se_ta_1

  def type_id(%SetpointCommandScaled{timestamp: nil}), do: :c_se_nb_1
  def type_id(%SetpointCommandScaled{timestamp: %CP56Time2a{}}), do: :c_se_tb_1

  def type_id(%SetpointCommandShort{timestamp: nil}), do: :c_se_nc_1
  def type_id(%SetpointCommandShort{timestamp: %CP56Time2a{}}), do: :c_se_tc_1

  def type_id(%Bitstring32Command{timestamp: nil}), do: :c_bo_na_1
  def type_id(%Bitstring32Command{timestamp: %CP56Time2a{}}), do: :c_bo_ta_1

  def type_id(%InterrogationCommand{}), do: :c_ic_na_1
  def type_id(%CounterInterrogationCommand{}), do: :c_ci_na_1
  def type_id(%ReadCommand{}), do: :c_rd_na_1
  def type_id(%ClockSynchronizationCommand{}), do: :c_cs_na_1
  def type_id(%TestCommand{}), do: :c_ts_na_1
  def type_id(%ResetProcessCommand{}), do: :c_rp_na_1
  def type_id(%DelayAcquisitionCommand{}), do: :c_cd_na_1
  def type_id(%TestCommandWithCP56Time2a{}), do: :c_ts_ta_1

  def type_id(%ParameterNormalizedValue{}), do: :p_me_na_1
  def type_id(%ParameterScaledValue{}), do: :p_me_nb_1
  def type_id(%ParameterFloatValue{}), do: :p_me_nc_1
  def type_id(%ParameterActivation{}), do: :p_ac_na_1

  def type_id(%FileReady{}), do: :f_fr_na_1
  def type_id(%SectionReady{}), do: :f_sr_na_1
  def type_id(%FileCallOrSelect{}), do: :f_sc_na_1
  def type_id(%FileLastSegmentOrSection{}), do: :f_ls_na_1
  def type_id(%FileACK{}), do: :f_af_na_1
  def type_id(%FileSegment{}), do: :f_sg_na_1
  def type_id(%FileDirectory{}), do: :f_dr_ta_1
  def type_id(%QueryLog{}), do: :f_sc_nb_1
  def type_id(%ExtendedFilePacket{}), do: :f_fr_na_2

  def type_id(%RawObject{type: t}), do: TypeID.to_atom(t)

  @doc """
  Encodes an Information Object into binary.
  If `include_ioa?` is true, prepends the encoded IOA (`1..3` bytes per `params`).
  For sequence elements (`SQ=1`, element index > 0), `include_ioa?` is `false`.
  """
  @spec encode(t(), AppLayerParameters.t(), boolean()) :: binary()
  def encode(io, %AppLayerParameters{} = params, include_ioa? \\ true) do
    prefix = if include_ioa?, do: AppLayerParameters.encode_ioa(params, ioa(io)), else: <<>>
    payload = encode_payload(io)
    <<prefix::binary, payload::binary>>
  end

  @spec encode_payload(t()) :: binary()
  def encode_payload(%mod{} = io)
      when mod in [
             SinglePointInformation,
             DoublePointInformation,
             StepPositionInformation,
             BitString32,
             MeasuredValueNormalized,
             MeasuredValueScaled,
             MeasuredValueShort,
             IntegratedTotals,
             IntegratedTotalsForSecurityStatistics,
             EventOfProtectionEquipment,
             PackedStartEventsOfProtectionEquipment,
             PackedOutputCircuitInfo,
             PackedSinglePointWithSCD,
             EndOfInitialization
           ] do
    IEC60870.IO.Monitoring.encode_payload(io)
  end

  def encode_payload(%mod{} = io)
      when mod in [
             SingleCommand,
             DoubleCommand,
             StepCommand,
             SetpointCommandNormalized,
             SetpointCommandScaled,
             SetpointCommandShort,
             Bitstring32Command
           ] do
    IEC60870.IO.Control.encode_payload(io)
  end

  def encode_payload(%mod{} = io)
      when mod in [
             InterrogationCommand,
             CounterInterrogationCommand,
             ReadCommand,
             ClockSynchronizationCommand,
             TestCommand,
             ResetProcessCommand,
             DelayAcquisitionCommand,
             TestCommandWithCP56Time2a
           ] do
    IEC60870.IO.System.encode_payload(io)
  end

  def encode_payload(%mod{} = io)
      when mod in [
             ParameterNormalizedValue,
             ParameterScaledValue,
             ParameterFloatValue,
             ParameterActivation
           ] do
    IEC60870.IO.Parameter.encode_payload(io)
  end

  def encode_payload(%mod{} = io)
      when mod in [
             FileReady,
             SectionReady,
             FileCallOrSelect,
             FileLastSegmentOrSection,
             FileACK,
             FileSegment,
             FileDirectory,
             QueryLog,
             ExtendedFilePacket
           ] do
    IEC60870.IO.File.encode_payload(io)
  end

  def encode_payload(%RawObject{payload: payload}), do: payload

  @doc """
  Decodes an Information Object payload for a known `type_atom` and `ioa`.
  """
  @spec decode_payload(TypeID.t(), non_neg_integer(), binary()) ::
          {:ok, t(), binary()} | {:error, term()}
  def decode_payload(type, ioa, bin) do
    type_atom = TypeID.to_atom(type)
    code = TypeID.to_code(type)

    cond do
      code in 1..41 or code == 70 ->
        IEC60870.IO.Monitoring.decode_payload(type_atom, ioa, bin)

      code in 45..64 ->
        IEC60870.IO.Control.decode_payload(type_atom, ioa, bin)

      code in 100..107 ->
        IEC60870.IO.System.decode_payload(type_atom, ioa, bin)

      code in 110..113 ->
        IEC60870.IO.Parameter.decode_payload(type_atom, ioa, bin)

      code in 120..127 or code == 210 ->
        IEC60870.IO.File.decode_payload(type_atom, ioa, bin)

      true ->
        {:ok, %RawObject{type: type_atom, ioa: ioa, payload: bin}, <<>>}
    end
  end
end
