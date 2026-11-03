#!/usr/bin/env elixir
# examples/cs104_server/server_example.exs
# Run with: mix run examples/cs104_server/server_example.exs

alias IEC60870.ASDU
alias IEC60870.CS104.{MasterConnection, Slave}
alias IEC60870.IO.{Control, Monitoring}
alias IEC60870.Types.CPTime.CP56Time2a

port = 2404
IO.puts("==================================================")
IO.puts(" Starting IEC 60870-5-104 Server on port #{port}")
IO.puts(" Press Ctrl+C to terminate")
IO.puts("==================================================")

{:ok, state_agent} = Agent.start_link(fn -> %{scaled_val: 100, single_val: false} end)

{:ok, slave} =
  Slave.start_link(
    port: port,
    # 1. General Interrogation Handler (QOI=20)
    interrogation_handler: fn conn, asdu, qoi ->
      IO.puts("[Server] Received General Interrogation (QOI=#{qoi}) from #{inspect(conn)}")
      MasterConnection.send_act_con(conn, asdu, false)

      # Send snapshot of process measurements
      io1 = Monitoring.single_point(100, true, 0x00)
      io2 = Monitoring.measured_value_scaled(110, 1234, 0x00)
      io3 = Monitoring.measured_value_short(120, 220.5, 0x00)

      gi_asdu =
        ASDU.new(:m_sp_na_1,
          cot: :interrogated_by_station,
          ca: asdu.ca,
          information_objects: [io1]
        )

      MasterConnection.send_asdu(conn, gi_asdu)

      me_asdu =
        ASDU.new(:m_me_nb_1,
          cot: :interrogated_by_station,
          ca: asdu.ca,
          information_objects: [io2]
        )

      MasterConnection.send_asdu(conn, me_asdu)

      fl_asdu =
        ASDU.new(:m_me_nc_1,
          cot: :interrogated_by_station,
          ca: asdu.ca,
          information_objects: [io3]
        )

      MasterConnection.send_asdu(conn, fl_asdu)

      MasterConnection.send_act_term(conn, asdu)
      IO.puts("[Server] Completed General Interrogation response")
      true
    end,

    # 2. Clock Synchronization Handler
    clock_sync_handler: fn _conn, _asdu, %CP56Time2a{} = new_time ->
      IO.puts("[Server] Clock synchronization command received: #{inspect(new_time)}")
      true
    end,

    # 3. Process Command Handler (Control direction: C_SC_NA_1, C_DC_NA_1, etc.)
    asdu_handler: fn conn, asdu ->
      case asdu.type_id do
        :c_sc_na_1 ->
          [sc | _] = asdu.objects

          IO.puts(
            "[Server] Received Single Command (IOA=#{sc.ioa}, state=#{sc.state}, select=#{sc.select})"
          )

          Agent.update(state_agent, fn st -> %{st | single_val: sc.state} end)
          MasterConnection.send_act_con(conn, asdu, false)
          true

        :c_se_nc_1 ->
          [se | _] = asdu.objects
          IO.puts("[Server] Received Setpoint Command Short (IOA=#{se.ioa}, value=#{se.value})")
          MasterConnection.send_act_con(conn, asdu, false)
          true

        other ->
          IO.puts("[Server] Unhandled ASDU type #{inspect(other)}")
          false
      end
    end,

    # 4. Connection event callback
    connection_event_handler: fn conn_pid, event ->
      IO.puts("[Server] Connection event from #{inspect(conn_pid)}: #{inspect(event)}")
    end
  )

# Background simulation loop: generate spontaneous telemetry periodic event every 5 seconds
spawn(fn ->
  Stream.interval(5000)
  |> Enum.each(fn _ ->
    val =
      Agent.get_and_update(state_agent, fn st ->
        {st.scaled_val, %{st | scaled_val: st.scaled_val + 1}}
      end)

    io = Monitoring.measured_value_scaled(110, val, 0x00)
    spont_asdu = ASDU.new(:m_me_nb_1, cot: :spontaneous, ca: 1, information_objects: [io])
    Slave.enqueue_user_data(slave, spont_asdu)
    IO.puts("[Server] Spontaneous event enqueued: scaled_value=#{val}")
  end)
end)

Process.sleep(:infinity)
