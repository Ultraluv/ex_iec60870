#!/usr/bin/env elixir
# examples/tls_server/tls_server_example.exs
# Run with: mix run examples/tls_server/tls_server_example.exs

alias IEC60870.CS104.Slave

port = 19999
IO.puts("==================================================")
IO.puts(" IEC 60870-5-104 TLS Secure Server on port #{port}")
IO.puts(" (Requires server certificate and private key)")
IO.puts("==================================================")

tls_options = [
  # certfile: "path/to/server.crt",
  # keyfile: "path/to/server.key",
  # cacertfile: "path/to/ca.crt",
  # verify: :verify_peer
]

{:ok, _slave} =
  Slave.start_link(
    port: port,
    use_tls: true,
    tls_opts: tls_options,
    connection_event_handler: fn conn_pid, event ->
      IO.puts("[TLS Server] Connection event: #{inspect(event)} on #{inspect(conn_pid)}")
    end
  )

IO.puts("[TLS Server] Listening for TLS 104 clients. Press Ctrl+C to terminate.")
Process.sleep(:infinity)
