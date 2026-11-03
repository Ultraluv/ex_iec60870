# ExIEC60870

A pure Elixir implementation of IEC 60870-5-101 and IEC 60870-5-104 (Master & Slave, Balanced & Unbalanced, full Information Objects, and bidirectional File Transfer Service), modeled directly after `lib60870-C`.

## Features

- **Pure Elixir & OTP**: No C NIF/Port compilation dependencies, cross-platform, safe, fault-tolerant.
- **Shared Application Layer (APL)**:
  - ASDU encoder & decoder supporting discrete (`SQ=0`) and compact sequences (`SQ=1`).
  - Full set of Information Objects: Monitoring (`1..41`, `70`), Control (`45..51`, `58..64`), System (`100..107`), Parameter (`110..113`), and File Transfer (`120..127` & `210`).
  - CPTime timestamps (`CP16Time2a`, `CP24Time2a`, `CP32Time2a`, `CP56Time2a`) with millisecond-level conversion.
  - Comprehensive quality descriptors and qualifiers (`Qualifiers`, `BCR`).
- **IEC 60870-5-104 (TCP / TLS)**:
  - APCI framing (`I-Frame`, `S-Frame`, `U-Frame`) with streaming deframer.
  - Master connection (`IEC60870.CS104.Connection`) with $k/w$ sliding window, $T0 \sim T3$ timers.
  - Slave server (`IEC60870.CS104.Slave`) with 3 redundancy modes and priority queues.
- **IEC 60870-5-101 (FT 1.2 Serial / Virtual Bus)**:
  - FT 1.2 framing (variable, fixed, and single-byte ACK `0xE5`).
  - Balanced and Unbalanced Primary/Secondary link-layer state machines (`FCB/FCV`, `ACD/DFC`).
  - Master (`IEC60870.CS101.Master`) & Slave (`IEC60870.CS101.Slave`) GenServers.
  - Modular transport: in-memory `VirtualBus` and optional hardware serial port `Circuits.UART`.
- **Bidirectional File Transfer**:
  - `IEC60870.FileService.Server` & `IEC60870.FileService.Client` supporting directory query, file upload, download, and log query (`F_SC_NB_1`).
- **Telemetry & Observability**:
  - Out-of-the-box telemetry events via `IEC60870.Telemetry` (`raw_message`, `asdu`, `connection_event`, `link_state`, `file_service`).

## Installation

Add `ex_iec60870` to your `mix.exs`:

```elixir
def deps do
  [
    {:ex_iec60870, "~> 0.1.0"}
  ]
end
```

## Examples

Just like `lib60870-C`, runnable standalone examples covering all modes are located in the `examples/` directory:

| Directory | Script | Description |
| :--- | :--- | :--- |
| `examples/cs104_server` | `server_example.exs` | Standard CS104 Server with General Interrogation, Time Sync, Control & Spontaneous events |
| `examples/cs104_client` | `client_example.exs` | Standard CS104 Client connecting, sending STARTDT, Interrogation, Clock Sync, Single Command |
| `examples/cs104_redundancy_server` | `redundancy_server_example.exs` | Multi-Redundancy Groups Server with independent queues and client IP matching |
| `examples/cs104_server_files` | `server_files_example.exs` | CS104 Server with File Transfer Service attached |
| `examples/cs101_slave` | `slave_example.exs` | CS101 Unbalanced Slave responding to polling and commands |
| `examples/cs101_master_unbalanced` | `master_example.exs` | CS101 Unbalanced Master polling multiple slaves over shared bus |
| `examples/cs101_master_balanced` | `master_example.exs` | CS101 Balanced point-to-point full duplex peer communication |
| `examples/cs101_slave_files` | `slave_files_example.exs` | CS101 Slave with File Service (disturbance records / files) |
| `examples/tls_server` | `tls_server_example.exs` | Secure TLS IEC 60870-5-104 Server |
| `examples/tls_client` | `tls_client_example.exs` | Secure TLS IEC 60870-5-104 Client |

Run any example with:
```bash
mix run examples/cs104_server/server_example.exs
# or
mix run examples/cs101_master_balanced/master_example.exs
```

## Quick Start

### 1. CS104 Master (Client)

```elixir
alias IEC60870.CS104.Connection

{:ok, conn} = Connection.start_link(
  host: "127.0.0.1",
  port: 2404,
  owner: self()
)

# Connect and activate data transfer
Connection.connect(conn)
Connection.send_start_dt(conn)

# Send General Interrogation (C_IC_NA_1, QOI = 20)
Connection.send_interrogation_command(conn, :activation, 1, 20)

receive do
  {:iec60870_cs104, ^conn, {:asdu, asdu}} ->
    IO.inspect(asdu, label: "Received ASDU")
end
```

### 2. CS104 Slave (Server)

```elixir
alias IEC60870.CS104.{Slave, MasterConnection}
alias IEC60870.{ASDU, IO.Monitoring}

{:ok, slave} = Slave.start_link(
  port: 2404,
  interrogation_handler: fn conn, asdu, _qoi ->
    # Acknowledge activation
    MasterConnection.send_act_con(conn, asdu, false)

    # Send interrogated data
    io = Monitoring.single_point(100, true, 0x00)
    resp = ASDU.new(:m_sp_na_1, cot: :interrogated_by_station, ca: asdu.ca, information_objects: [io])
    MasterConnection.send_asdu(conn, resp)

    # Terminate activation
    MasterConnection.send_act_term(conn, asdu)
    true
  end
)

# Enqueue spontaneous telemetry to connected active clients
spont_io = Monitoring.measured_value_scaled(101, 1250, 0x00)
spont_asdu = ASDU.new(:m_me_nb_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
Slave.enqueue_user_data(slave, spont_asdu)
```

### 3. CS101 Balanced Master & Slave (Serial / Virtual Bus)

```elixir
alias IEC60870.CS101.{Master, Slave}
alias IEC60870.CS101.Transport.VirtualBus

# In-memory virtual bus for testing or IPC
{:ok, bus} = VirtualBus.start_link()

# Balanced Slave (DIR = false)
{:ok, _slave} = Slave.start_link(
  transport: {VirtualBus, bus},
  mode: :balanced,
  link_address: 1,
  dir: false
)

# Balanced Master (DIR = true)
{:ok, master} = Master.start_link(
  transport: {VirtualBus, bus},
  mode: :balanced,
  own_address: 1,
  slave_address: 1,
  dir: true,
  owner: self()
)

# Send interrogation
Master.send_interrogation_command(master, :activation, 1, 20)
```

### 4. File Transfer Service

```elixir
alias IEC60870.FileService.{Server, Client, TransparentFile}

# Server side: host files
file = TransparentFile.new(101, "config.xml", "<config/>")
{:ok, file_server} = Server.start_link(files: [file])

# Client side: query directory and retrieve file
{:ok, file_client} = Client.start_link(connection: conn, ca: 1)
{:ok, entries} = Client.request_directory(file_client, 1, 0)
{:ok, binary_data} = Client.get_file(file_client, 1, 0, 101)
```

### 5. Telemetry & Observability

`ex_iec60870` emits structured telemetry events using `:telemetry`:

```elixir
:telemetry.attach_many(
  "iec60870-logger",
  [
    [:iec60870, :cs104, :raw_message],
    [:iec60870, :cs104, :connection_event],
    [:iec60870, :cs104, :asdu],
    [:iec60870, :cs101, :link_state],
    [:iec60870, :file_service, :transfer]
  ],
  fn event, measurements, metadata, _config ->
    IO.puts("Telemetry Event #{inspect(event)}: #{inspect(measurements)} #{inspect(metadata)}")
  end,
  nil
)
```

## Testing & Documentation

Run the test suite:
```bash
mix test --warnings-as-errors
```

Generate HTML and offline markdown documentation:
```bash
mix docs
```
The generated documentation is located in `doc/index.html`.
