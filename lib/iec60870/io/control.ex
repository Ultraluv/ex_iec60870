defmodule IEC60870.IO.Control do
  @moduledoc """
  Control direction Process Command Information Objects (TypeIDs 45..51, 58..64).
  Matches `cs101_information_objects.c` in `lib60870-C`.
  """

  import Bitwise
  alias IEC60870.Types.Qualifiers
  alias IEC60870.Types.CPTime.CP56Time2a

  # 45: C_SC_NA_1, 58: C_SC_TA_1
  defmodule SingleCommand do
    @moduledoc """
    Single command (C_SC_NA_1, C_SC_TA_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            state: boolean(),
            select: boolean(),
            qu: 0..31,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, state: false, select: false, qu: 0, timestamp: nil

    def new(ioa, state, select \\ false, qu \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        state: state == true or state == 1,
        select: select == true,
        qu: qu &&& 0x1F,
        timestamp: timestamp
      }
    end
  end

  # 46: C_DC_NA_1, 59: C_DC_TA_1
  defmodule DoubleCommand do
    @moduledoc """
    Double command (C_DC_NA_1, C_DC_TA_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            state: 0..3,
            select: boolean(),
            qu: 0..31,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, state: 1, select: false, qu: 0, timestamp: nil

    def new(ioa, state, select \\ false, qu \\ 0, timestamp \\ nil) do
      encoded_state = Qualifiers.encode_double_point(state)

      %__MODULE__{
        ioa: ioa,
        state: encoded_state,
        select: select == true,
        qu: qu &&& 0x1F,
        timestamp: timestamp
      }
    end
  end

  # 47: C_RC_NA_1, 60: C_RC_TA_1
  defmodule StepCommand do
    @moduledoc """
    Regulating step command (C_RC_NA_1, C_RC_TA_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            state: :invalid_0 | :lower | :higher | :invalid_3,
            select: boolean(),
            qu: 0..31,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, state: :lower, select: false, qu: 0, timestamp: nil

    def new(ioa, state, select \\ false, qu \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        state: Qualifiers.decode_step_command(Qualifiers.encode_step_command(state)),
        select: select == true,
        qu: qu &&& 0x1F,
        timestamp: timestamp
      }
    end
  end

  # 48: C_SE_NA_1, 61: C_SE_TA_1
  defmodule SetpointCommandNormalized do
    @moduledoc """
    Normalized setpoint command (C_SE_NA_1, C_SE_TA_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            select: boolean(),
            ql: 0..127,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0.0, select: false, ql: 0, timestamp: nil

    def new(ioa, value, select \\ false, ql \\ 0, timestamp \\ nil) do
      scaled = Qualifiers.normalized_to_scaled(value)

      %__MODULE__{
        ioa: ioa,
        value: Qualifiers.scaled_to_normalized(scaled),
        select: select == true,
        ql: ql &&& 0x7F,
        timestamp: timestamp
      }
    end
  end

  # 49: C_SE_NB_1, 62: C_SE_TB_1
  defmodule SetpointCommandScaled do
    @moduledoc """
    Scaled setpoint command (C_SE_NB_1, C_SE_TB_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: -32768..32767,
            select: boolean(),
            ql: 0..127,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0, select: false, ql: 0, timestamp: nil

    def new(ioa, value, select \\ false, ql \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: max(-32768, min(32767, value)),
        select: select == true,
        ql: ql &&& 0x7F,
        timestamp: timestamp
      }
    end
  end

  # 50: C_SE_NC_1, 63: C_SE_TC_1
  defmodule SetpointCommandShort do
    @moduledoc """
    Short floating point setpoint command (C_SE_NC_1, C_SE_TC_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: float(),
            select: boolean(),
            ql: 0..127,
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0.0, select: false, ql: 0, timestamp: nil

    def new(ioa, value, select \\ false, ql \\ 0, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: value * 1.0,
        select: select == true,
        ql: ql &&& 0x7F,
        timestamp: timestamp
      }
    end
  end

  # 51: C_BO_NA_1, 64: C_BO_TA_1
  defmodule Bitstring32Command do
    @moduledoc """
    32-bit bitstring command (C_BO_NA_1, C_BO_TA_1).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            value: non_neg_integer(),
            timestamp: nil | CP56Time2a.t()
          }
    defstruct ioa: 0, value: 0, timestamp: nil

    def new(ioa, value, timestamp \\ nil) do
      %__MODULE__{
        ioa: ioa,
        value: value &&& 0xFFFFFFFF,
        timestamp: timestamp
      }
    end
  end

  # Top-level convenience constructors
  @doc """
  Constructs a single command (`C_SC_NA_1`).
  """
  def single_command(ioa, state, select \\ false, qu \\ 0),
    do: SingleCommand.new(ioa, state, select, qu, nil)

  @doc """
  Constructs a single command with CP56Time2a (`C_SC_TA_1`).
  """
  def single_command_cp56time2a(ioa, state, select, qu, %CP56Time2a{} = ts),
    do: SingleCommand.new(ioa, state, select, qu, ts)

  @doc """
  Constructs a double command (`C_DC_NA_1`).
  """
  def double_command(ioa, state, select \\ false, qu \\ 0),
    do: DoubleCommand.new(ioa, state, select, qu, nil)

  @doc """
  Constructs a double command with CP56Time2a (`C_DC_TA_1`).
  """
  def double_command_cp56time2a(ioa, state, select, qu, %CP56Time2a{} = ts),
    do: DoubleCommand.new(ioa, state, select, qu, ts)

  @doc """
  Constructs a regulating step command (`C_RC_NA_1`).
  """
  def regulating_step_command(ioa, state, select \\ false, qu \\ 0),
    do: StepCommand.new(ioa, state, select, qu, nil)

  @doc """
  Constructs a regulating step command with CP56Time2a (`C_RC_TA_1`).
  """
  def regulating_step_command_cp56time2a(ioa, state, select, qu, %CP56Time2a{} = ts),
    do: StepCommand.new(ioa, state, select, qu, ts)

  def setpoint_command_normalized(ioa, value, select \\ false, ql \\ 0),
    do: SetpointCommandNormalized.new(ioa, value, select, ql, nil)

  def setpoint_command_normalized_cp56time2a(ioa, value, select, ql, %CP56Time2a{} = ts),
    do: SetpointCommandNormalized.new(ioa, value, select, ql, ts)

  def setpoint_command_scaled(ioa, value, select \\ false, ql \\ 0),
    do: SetpointCommandScaled.new(ioa, value, select, ql, nil)

  def setpoint_command_scaled_cp56time2a(ioa, value, select, ql, %CP56Time2a{} = ts),
    do: SetpointCommandScaled.new(ioa, value, select, ql, ts)

  def setpoint_command_short(ioa, value, select \\ false, ql \\ 0),
    do: SetpointCommandShort.new(ioa, value, select, ql, nil)

  def setpoint_command_short_cp56time2a(ioa, value, select, ql, %CP56Time2a{} = ts),
    do: SetpointCommandShort.new(ioa, value, select, ql, ts)

  @doc """
  Constructs a 32-bit bitstring command (`C_BO_NA_1`).
  """
  def bitstring32_command(ioa, value),
    do: Bitstring32Command.new(ioa, value, nil)

  @doc """
  Constructs a 32-bit bitstring command with CP56Time2a (`C_BO_TA_1`).
  """
  def bitstring32_command_cp56time2a(ioa, value, %CP56Time2a{} = ts),
    do: Bitstring32Command.new(ioa, value, ts)

  # Encoding
  def encode_payload(%SingleCommand{state: state, select: sel, qu: qu, timestamp: ts}) do
    sco =
      ((qu &&& 0x1F) <<< 2)
      |> bor(if(state, do: 0x01, else: 0))
      |> bor(if(sel, do: 0x80, else: 0))

    <<sco::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%DoubleCommand{state: state, select: sel, qu: qu, timestamp: ts}) do
    dco =
      ((qu &&& 0x1F) <<< 2)
      |> bor(state &&& 0x03)
      |> bor(if(sel, do: 0x80, else: 0))

    <<dco::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%StepCommand{state: state, select: sel, qu: qu, timestamp: ts}) do
    rco =
      ((qu &&& 0x1F) <<< 2)
      |> bor(Qualifiers.encode_step_command(state) &&& 0x03)
      |> bor(if(sel, do: 0x80, else: 0))

    <<rco::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%SetpointCommandNormalized{value: val, select: sel, ql: ql, timestamp: ts}) do
    scaled = Qualifiers.normalized_to_scaled(val)
    qos = (ql &&& 0x7F) ||| if(sel, do: 0x80, else: 0)
    <<scaled::little-signed-16, qos::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%SetpointCommandScaled{value: val, select: sel, ql: ql, timestamp: ts}) do
    qos = (ql &&& 0x7F) ||| if(sel, do: 0x80, else: 0)
    <<val::little-signed-16, qos::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%SetpointCommandShort{value: val, select: sel, ql: ql, timestamp: ts}) do
    qos = (ql &&& 0x7F) ||| if(sel, do: 0x80, else: 0)
    <<encode_float32(val)::binary, qos::8, encode_ts(ts)::binary>>
  end

  def encode_payload(%Bitstring32Command{value: val, timestamp: ts}) do
    <<val::little-unsigned-32, encode_ts(ts)::binary>>
  end

  defp encode_ts(nil), do: <<>>
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
  def decode_payload(:c_sc_na_1, ioa, <<sco::8, rest::binary>>) do
    {:ok,
     %SingleCommand{
       ioa: ioa,
       state: (sco &&& 0x01) == 1,
       qu: (sco &&& 0x7C) >>> 2,
       select: (sco &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_sc_ta_1, ioa, <<sco::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %SingleCommand{
         ioa: ioa,
         state: (sco &&& 0x01) == 1,
         qu: (sco &&& 0x7C) >>> 2,
         select: (sco &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_dc_na_1, ioa, <<dco::8, rest::binary>>) do
    {:ok,
     %DoubleCommand{
       ioa: ioa,
       state: dco &&& 0x03,
       qu: (dco &&& 0x7C) >>> 2,
       select: (dco &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_dc_ta_1, ioa, <<dco::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %DoubleCommand{
         ioa: ioa,
         state: dco &&& 0x03,
         qu: (dco &&& 0x7C) >>> 2,
         select: (dco &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_rc_na_1, ioa, <<rco::8, rest::binary>>) do
    {:ok,
     %StepCommand{
       ioa: ioa,
       state: Qualifiers.decode_step_command(rco &&& 0x03),
       qu: (rco &&& 0x7C) >>> 2,
       select: (rco &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_rc_ta_1, ioa, <<rco::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %StepCommand{
         ioa: ioa,
         state: Qualifiers.decode_step_command(rco &&& 0x03),
         qu: (rco &&& 0x7C) >>> 2,
         select: (rco &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_se_na_1, ioa, <<scaled::little-signed-16, qos::8, rest::binary>>) do
    {:ok,
     %SetpointCommandNormalized{
       ioa: ioa,
       value: Qualifiers.scaled_to_normalized(scaled),
       ql: qos &&& 0x7F,
       select: (qos &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_se_ta_1, ioa, <<scaled::little-signed-16, qos::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %SetpointCommandNormalized{
         ioa: ioa,
         value: Qualifiers.scaled_to_normalized(scaled),
         ql: qos &&& 0x7F,
         select: (qos &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_se_nb_1, ioa, <<val::little-signed-16, qos::8, rest::binary>>) do
    {:ok,
     %SetpointCommandScaled{
       ioa: ioa,
       value: val,
       ql: qos &&& 0x7F,
       select: (qos &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_se_tb_1, ioa, <<val::little-signed-16, qos::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %SetpointCommandScaled{
         ioa: ioa,
         value: val,
         ql: qos &&& 0x7F,
         select: (qos &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_se_nc_1, ioa, <<raw_f::binary-size(4), qos::8, rest::binary>>) do
    {:ok,
     %SetpointCommandShort{
       ioa: ioa,
       value: decode_float32(raw_f),
       ql: qos &&& 0x7F,
       select: (qos &&& 0x80) != 0
     }, rest}
  end

  def decode_payload(:c_se_tc_1, ioa, <<raw_f::binary-size(4), qos::8, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok,
       %SetpointCommandShort{
         ioa: ioa,
         value: decode_float32(raw_f),
         ql: qos &&& 0x7F,
         select: (qos &&& 0x80) != 0,
         timestamp: ts
       }, rest2}
    end
  end

  def decode_payload(:c_bo_na_1, ioa, <<val::little-unsigned-32, rest::binary>>) do
    {:ok, %Bitstring32Command{ioa: ioa, value: val}, rest}
  end

  def decode_payload(:c_bo_ta_1, ioa, <<val::little-unsigned-32, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok, %Bitstring32Command{ioa: ioa, value: val, timestamp: ts}, rest2}
    end
  end

  def decode_payload(_type, _ioa, _bin), do: {:error, :invalid_payload}
end
