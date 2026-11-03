defmodule IEC60870 do
  @moduledoc """
  Pure Elixir implementation of IEC 60870-5-101 and IEC 60870-5-104 (Master & Slave, Balanced & Unbalanced,
  full Information Objects, and bidirectional File Transfer Service), modeled after `lib60870-C`.

  ## Core Modules
  - **Shared Application Layer**:
    - `IEC60870.ASDU`: ASDU header & payload encoding/decoding (including `SQ=0` discrete and `SQ=1` compact sequences)
    - `IEC60870.InformationObject`: Unified Information Object wrapper and codec dispatcher
    - `IEC60870.IO.Monitoring`: Monitoring direction Information Objects (TypeIDs `1..41`, `70`)
    - `IEC60870.IO.Control`: Control direction Information Objects (TypeIDs `45..51`, `58..64`)
    - `IEC60870.IO.System`: System Information Objects (TypeIDs `100..107`)
    - `IEC60870.IO.Parameter`: Parameter Information Objects (TypeIDs `110..113`)
    - `IEC60870.IO.File`: File Transfer Information Objects (TypeIDs `120..127` & domestic extension `210`)
    - `IEC60870.Types.CPTime`: `CP16Time2a`, `CP24Time2a`, `CP32Time2a`, `CP56Time2a`
    - `IEC60870.Types.BCR`: 5-byte `BinaryCounterReading`
    - `IEC60870.Types.Qualifiers`: Qualifier bitfields and normalized/scaled value helpers
  - **IEC 60870-5-104 (TCP / TLS)**:
    - `IEC60870.CS104.Frame`: APCI `I-Frame`, `S-Frame`, `U-Frame` codec and stream deframer
    - `IEC60870.CS104.Connection`: 104 Client / Master `GenServer`
    - `IEC60870.CS104.Slave`: 104 Server / Slave `GenServer` with 3 redundancy modes and priority queues
    - `IEC60870.CS104.MasterConnection`: Peer connection response API for Slave callbacks
  - **IEC 60870-5-101 (Serial FT 1.2 / Virtual Bus)**:
    - `IEC60870.CS101.Frame`: FT 1.2 variable, fixed, and single-byte ACK `0xE5` codec and stream deframer
    - `IEC60870.CS101.LinkLayer`: Balanced & Unbalanced Primary/Secondary link state machines
    - `IEC60870.CS101.Master`: 101 Master `GenServer` (Balanced & Unbalanced multi-slave)
    - `IEC60870.CS101.Slave`: 101 Slave `GenServer` (Balanced & Unbalanced Class 1 / Class 2 queues)
    - `IEC60870.CS101.Transport.VirtualBus` & `IEC60870.CS101.Transport.UART`: Serial / virtual transports
  - **File Transfer Service**:
    - `IEC60870.FileService.Server`: Slave file server (directory listing, file upload to Master, file download from Master)
    - `IEC60870.FileService.Client`: Master file client (`request_directory/4`, `get_file/5`, `send_file/3`)
    - `IEC60870.FileService.TransparentFile` & `IEC60870.FileService.Receiver`
  - **Observability & Metrics**:
    - `IEC60870.Telemetry`: Telemetry event dispatcher (`raw_message`, `asdu`, `connection_event`, `link_state`, `file_service`)
  """

  alias IEC60870.{ASDU, AppLayerParameters}

  @doc """
  Convenience helper to encode an `%IEC60870.ASDU{}` into binary.
  """
  def encode_asdu(%ASDU{} = asdu, params \\ %AppLayerParameters{}) do
    ASDU.encode(asdu, params)
  end

  @doc """
  Convenience helper to decode an ASDU binary into `%IEC60870.ASDU{}`.
  """
  def decode_asdu(bin, params \\ %AppLayerParameters{}) when is_binary(bin) do
    ASDU.decode(bin, params)
  end
end
