defmodule IEC60870.IO.System do
  @moduledoc """
  System Command Information Objects in Control Direction (TypeIDs 100..107).
  Matches `cs101_information_objects.c` in `lib60870-C`.
  """

  import Bitwise
  alias IEC60870.Types.CPTime.{CP16Time2a, CP56Time2a}

  # 100: C_IC_NA_1
  defmodule InterrogationCommand do
    @moduledoc """
    General interrogation command (C_IC_NA_1, TypeID 100).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), qoi: byte()}
    defstruct ioa: 0, qoi: 20

    def new(qoi \\ 20, ioa \\ 0), do: %__MODULE__{ioa: ioa, qoi: qoi &&& 0xFF}
  end

  # 101: C_CI_NA_1
  defmodule CounterInterrogationCommand do
    @moduledoc """
    Counter interrogation command (C_CI_NA_1, TypeID 101).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), qcc: byte()}
    defstruct ioa: 0, qcc: 5

    def new(qcc \\ 5, ioa \\ 0), do: %__MODULE__{ioa: ioa, qcc: qcc &&& 0xFF}
  end

  # 102: C_RD_NA_1
  defmodule ReadCommand do
    @moduledoc """
    Read command (C_RD_NA_1, TypeID 102).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer()}
    defstruct ioa: 0

    def new(ioa), do: %__MODULE__{ioa: ioa}
  end

  # 103: C_CS_NA_1
  defmodule ClockSynchronizationCommand do
    @moduledoc """
    Clock synchronization command with CP56Time2a (C_CS_NA_1, TypeID 103).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), timestamp: CP56Time2a.t()}
    defstruct ioa: 0, timestamp: %CP56Time2a{}

    def new(%CP56Time2a{} = timestamp, ioa \\ 0) do
      %__MODULE__{ioa: ioa, timestamp: timestamp}
    end
  end

  # 104: C_TS_NA_1
  defmodule TestCommand do
    @moduledoc """
    Test command (C_TS_NA_1, TypeID 104).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), byte1: byte(), byte2: byte(), valid: boolean()}
    defstruct ioa: 0, byte1: 0xAA, byte2: 0x55, valid: true

    def new(ioa \\ 0) do
      %__MODULE__{ioa: ioa, byte1: 0xAA, byte2: 0x55, valid: true}
    end
  end

  # 105: C_RP_NA_1
  defmodule ResetProcessCommand do
    @moduledoc """
    Reset process command (C_RP_NA_1, TypeID 105).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), qrp: byte()}
    defstruct ioa: 0, qrp: 1

    def new(qrp \\ 1, ioa \\ 0), do: %__MODULE__{ioa: ioa, qrp: qrp &&& 0xFF}
  end

  # 106: C_CD_NA_1
  defmodule DelayAcquisitionCommand do
    @moduledoc """
    Delay acquisition command (C_CD_NA_1, TypeID 106).
    """
    @type t :: %__MODULE__{ioa: non_neg_integer(), delay: CP16Time2a.t()}
    defstruct ioa: 0, delay: %CP16Time2a{}

    def new(delay, ioa \\ 0)

    def new(%CP16Time2a{} = delay, ioa) do
      %__MODULE__{ioa: ioa, delay: delay}
    end

    def new(delay_ms, ioa) when is_integer(delay_ms) do
      %__MODULE__{ioa: ioa, delay: CP16Time2a.new(delay_ms)}
    end
  end

  # 107: C_TS_TA_1
  defmodule TestCommandWithCP56Time2a do
    @moduledoc """
    Test command with CP56Time2a timestamp (C_TS_TA_1, TypeID 107).
    """
    @type t :: %__MODULE__{
            ioa: non_neg_integer(),
            tsc: non_neg_integer(),
            timestamp: CP56Time2a.t()
          }
    defstruct ioa: 0, tsc: 0, timestamp: %CP56Time2a{}

    def new(tsc, %CP56Time2a{} = timestamp, ioa \\ 0) do
      %__MODULE__{ioa: ioa, tsc: tsc &&& 0xFFFF, timestamp: timestamp}
    end
  end

  # Convenience constructors matching `(ioa, ...)` parameter order
  def interrogation_command(ioa \\ 0, qoi \\ 20), do: InterrogationCommand.new(qoi, ioa)

  def counter_interrogation_command(ioa \\ 0, qcc \\ 5),
    do: CounterInterrogationCommand.new(qcc, ioa)

  def read_command(ioa), do: ReadCommand.new(ioa)

  def clock_sync_command(ioa \\ 0, %CP56Time2a{} = ts),
    do: ClockSynchronizationCommand.new(ts, ioa)

  def test_command(ioa \\ 0), do: TestCommand.new(ioa)
  def reset_process_command(ioa \\ 0, qrp \\ 1), do: ResetProcessCommand.new(qrp, ioa)
  def delay_acquisition_command(ioa \\ 0, delay), do: DelayAcquisitionCommand.new(delay, ioa)

  def test_command_with_cp56time2a(ioa \\ 0, tsc, %CP56Time2a{} = ts),
    do: TestCommandWithCP56Time2a.new(tsc, ts, ioa)

  # Encoding
  def encode_payload(%InterrogationCommand{qoi: qoi}), do: <<qoi::8>>
  def encode_payload(%CounterInterrogationCommand{qcc: qcc}), do: <<qcc::8>>
  def encode_payload(%ReadCommand{}), do: <<>>

  def encode_payload(%ClockSynchronizationCommand{timestamp: ts}),
    do: CP56Time2a.encode(ts)

  def encode_payload(%TestCommand{byte1: b1, byte2: b2}), do: <<b1::8, b2::8>>
  def encode_payload(%ResetProcessCommand{qrp: qrp}), do: <<qrp::8>>
  def encode_payload(%DelayAcquisitionCommand{delay: delay}), do: CP16Time2a.encode(delay)

  def encode_payload(%TestCommandWithCP56Time2a{tsc: tsc, timestamp: ts}) do
    <<tsc::little-unsigned-16, CP56Time2a.encode(ts)::binary>>
  end

  # Decoding
  def decode_payload(:c_ic_na_1, ioa, <<qoi::8, rest::binary>>) do
    {:ok, %InterrogationCommand{ioa: ioa, qoi: qoi}, rest}
  end

  def decode_payload(:c_ci_na_1, ioa, <<qcc::8, rest::binary>>) do
    {:ok, %CounterInterrogationCommand{ioa: ioa, qcc: qcc}, rest}
  end

  def decode_payload(:c_rd_na_1, ioa, rest) do
    {:ok, %ReadCommand{ioa: ioa}, rest}
  end

  def decode_payload(:c_cs_na_1, ioa, bin) do
    with {:ok, ts, rest} <- CP56Time2a.decode(bin) do
      {:ok, %ClockSynchronizationCommand{ioa: ioa, timestamp: ts}, rest}
    end
  end

  def decode_payload(:c_ts_na_1, ioa, <<b1::8, b2::8, rest::binary>>) do
    {:ok, %TestCommand{ioa: ioa, byte1: b1, byte2: b2, valid: b1 == 0xAA and b2 == 0x55}, rest}
  end

  def decode_payload(:c_rp_na_1, ioa, <<qrp::8, rest::binary>>) do
    {:ok, %ResetProcessCommand{ioa: ioa, qrp: qrp}, rest}
  end

  def decode_payload(:c_cd_na_1, ioa, bin) do
    with {:ok, delay, rest} <- CP16Time2a.decode(bin) do
      {:ok, %DelayAcquisitionCommand{ioa: ioa, delay: delay}, rest}
    end
  end

  def decode_payload(:c_ts_ta_1, ioa, <<tsc::little-unsigned-16, rest::binary>>) do
    with {:ok, ts, rest2} <- CP56Time2a.decode(rest) do
      {:ok, %TestCommandWithCP56Time2a{ioa: ioa, tsc: tsc, timestamp: ts}, rest2}
    end
  end

  def decode_payload(_type, _ioa, _bin), do: {:error, :invalid_payload}
end
