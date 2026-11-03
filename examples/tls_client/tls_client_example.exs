#!/usr/bin/env elixir
# examples/tls_client/tls_client_example.exs
# Run with: mix run examples/tls_client/tls_client_example.exs

alias IEC60870.CS104.Connection

host = "127.0.0.1"
port = 19999
IO.puts("==================================================")
IO.puts(" IEC 60870-5-104 TLS Secure Client connecting to #{host}:#{port}")
IO.puts("==================================================")

tls_options = [
  # cacertfile: "path/to/ca.crt",
  # certfile: "path/to/client.crt",
  # keyfile: "path/to/client.key",
  # verify: :verify_peer
]

{:ok, conn} =
  Connection.start_link(
    host: host,
    port: port,
    use_tls: true,
    tls_opts: tls_options,
    asdu_handler: fn _conn, asdu ->
      IO.puts("[TLS Client] ASDU: #{asdu.type_id}, COT: #{asdu.cot}")
    end,
    connection_handler: fn _conn, event ->
      IO.puts("[TLS Client] Connection event: #{inspect(event)}")
    end
  )

IO.puts("[TLS Client] Client started.")
