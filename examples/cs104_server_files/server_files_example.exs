#!/usr/bin/env elixir
# examples/cs104_server_files/server_files_example.exs
# Run with: mix run examples/cs104_server_files/server_files_example.exs

alias IEC60870.CS104.Slave
alias IEC60870.FileService.{Server, TransparentFile}

port = 2404
IO.puts("==================================================")
IO.puts(" IEC 60870-5-104 File Server on port #{port}")
IO.puts(" Provides file directory, upload & download")
IO.puts("==================================================")

file1 = TransparentFile.new(101, "device_config.xml", "<config><device>RTU_104</device></config>")

file2 =
  TransparentFile.new(
    102,
    "fault_event_2026.log",
    "2026-11-03 14:00:00 Overcurrent Protection Tripped\n"
  )

{:ok, file_server} =
  Server.start_link(
    files: [file1, file2],
    file_received_handler: fn _srv, %TransparentFile{name: name, data: data} ->
      IO.puts("[FileServer] Client uploaded file '#{name}' (#{byte_size(data)} bytes):")
      IO.puts("  Payload preview: #{inspect(binary_part(data, 0, min(64, byte_size(data))))}")
    end
  )

{:ok, _slave} =
  Slave.start_link(
    port: port,
    asdu_handler: fn conn, asdu ->
      Server.handle_asdu(file_server, conn, asdu)
    end
  )

IO.puts("[FileServer] Ready. Press Ctrl+C to terminate.")
Process.sleep(:infinity)
