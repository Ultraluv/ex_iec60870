#!/usr/bin/env elixir
# examples/cs104_client/client_example.exs
# Run with: mix run examples/cs104_client/client_example.exs

alias IEC60870.ASDU
alias IEC60870.CS104.Connection
alias IEC60870.IO.Control
alias IEC60870.Types.CPTime.CP56Time2a

host = System.get_env("CS104_HOST") || "127.0.0.1"
port = String.to_integer(System.get_env("CS104_PORT") || "2404")

IO.puts("==================================================")
IO.puts(" Starting IEC 60870-5-104 Client connecting to #{host}:#{port}")
IO.puts("==================================================")

{:ok, conn} =
  Connection.start_link(
    host: host,
    port: port,
    owner: self(),
    asdu_handler: fn _conn, asdu ->
      IO.puts("[Client ASDU Received] Type: #{asdu.type_id}, COT: #{asdu.cot}, CA: #{asdu.ca}")

      Enum.each(asdu.objects, fn obj ->
        IO.puts("  -> IO: #{inspect(obj)}")
      end)
    end,
    connection_handler: fn _conn, event ->
      IO.puts("[Client Connection Event] #{inspect(event)}")
    end
  )

# 1. Establish TCP connection
IO.puts("[Client] Connecting...")

case Connection.connect(conn) do
  :ok ->
    IO.puts("[Client] TCP connection established!")

  {:error, reason} ->
    IO.puts("[Client] Connect failed: #{inspect(reason)}")
    System.halt(1)
end

# 2. Send STARTDT Act
IO.puts("[Client] Sending STARTDT_ACT...")
:ok = Connection.send_start_dt(conn)
Process.sleep(200)

# 3. Send General Interrogation (C_IC_NA_1, QOI=20)
IO.puts("[Client] Sending General Interrogation (Station Interrogation, QOI=20)...")
:ok = Connection.send_interrogation_command(conn, :activation, 1, 20)
Process.sleep(1000)

# 4. Send Clock Synchronization Command (C_CS_NA_1)
IO.puts("[Client] Sending Clock Synchronization Command...")
now_ts = CP56Time2a.from_datetime(DateTime.utc_now())
:ok = Connection.send_clock_sync_command(conn, 1, now_ts)
Process.sleep(500)

# 5. Send Single Command Control (C_SC_NA_1)
IO.puts("[Client] Sending Single Command (C_SC_NA_1) to IOA 100 (state=true)...")
sc = Control.single_command(100, true, false, 0)
:ok = Connection.send_process_command(conn, :activation, 1, sc)

IO.puts("[Client] Listening for incoming spontaneous events for 5 seconds...")
Process.sleep(5000)

IO.puts("[Client] Closing connection...")
Connection.close(conn)
IO.puts("[Client] Done.")
