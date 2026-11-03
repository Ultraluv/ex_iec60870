#!/usr/bin/env elixir
# examples/cs104_redundancy_server/redundancy_server_example.exs
# Run with: mix run examples/cs104_redundancy_server/redundancy_server_example.exs

alias IEC60870.ASDU
alias IEC60870.CS104.{MasterConnection, RedundancyGroup, Slave}
alias IEC60870.IO.Monitoring

port = 2404
IO.puts("=================================================================")
IO.puts(" IEC 60870-5-104 Multi-Redundancy Group Server on port #{port}")
IO.puts(" Supports independent queues and active connection arbitration")
IO.puts("=================================================================")

# Define two redundancy groups: Primary Control Center & Backup Control Center
group_primary = RedundancyGroup.new("PrimaryCC", ["127.0.0.1", "192.168.1.10"])
group_backup = RedundancyGroup.new("BackupCC", ["192.168.2.10", "10.0.0.1"])

{:ok, _slave} =
  Slave.start_link(
    port: port,
    server_mode: :multiple_redundancy_groups,
    redundancy_groups: [group_primary, group_backup],
    max_open_connections: 10,
    interrogation_handler: fn conn, asdu, qoi ->
      IO.puts("[RedundancyServer] General Interrogation from #{inspect(conn)} (QOI=#{qoi})")
      MasterConnection.send_act_con(conn, asdu, false)

      io = Monitoring.single_point(100, true, 0x00)

      resp =
        ASDU.new(:m_sp_na_1,
          cot: :interrogated_by_station,
          ca: asdu.ca,
          information_objects: [io]
        )

      MasterConnection.send_asdu(conn, resp)
      MasterConnection.send_act_term(conn, asdu)
      true
    end,
    connection_event_handler: fn conn_pid, event ->
      IO.puts("[RedundancyServer] Peer #{inspect(conn_pid)} event: #{inspect(event)}")
    end
  )

IO.puts("[RedundancyServer] Running with 2 redundancy groups. Press Ctrl+C to stop.")
Process.sleep(:infinity)
