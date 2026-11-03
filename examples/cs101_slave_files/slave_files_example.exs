#!/usr/bin/env elixir
# examples/cs101_slave_files/slave_files_example.exs
# Run with: mix run examples/cs101_slave_files/slave_files_example.exs

alias IEC60870.CS101.Slave
alias IEC60870.CS101.Transport.VirtualBus
alias IEC60870.FileService.{Server, TransparentFile}

IO.puts("==================================================")
IO.puts(" IEC 60870-5-101 File Server Example")
IO.puts("==================================================")

{:ok, bus} = VirtualBus.start_link()

sample_file = TransparentFile.new(50, "disturbance_record.dat", <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)

{:ok, file_server} =
  Server.start_link(
    files: [sample_file],
    file_received_handler: fn _srv, file ->
      IO.puts("[CS101 FileServer] Received file #{file.name} (#{byte_size(file.data)} bytes)")
    end
  )

{:ok, _slave} =
  Slave.start_link(
    transport: {VirtualBus, bus},
    mode: :unbalanced,
    link_address: 1,
    asdu_handler: fn conn, asdu ->
      Server.handle_asdu(file_server, conn, asdu)
    end
  )

IO.puts("[CS101 FileServer] Ready on Link Address 1.")
Process.sleep(:infinity)
