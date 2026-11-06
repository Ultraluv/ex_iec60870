#!/usr/bin/env elixir
# examples/cs101_peer_test.exs
# Run with: mix run examples/cs101_peer_test.exs

alias IEC60870.ASDU
alias IEC60870.CS101.{Master, Slave}
alias IEC60870.CS101.Transport.VirtualBus
alias IEC60870.IO.{Control, Monitoring}
alias IEC60870.Types.CPTime.CP56Time2a

IO.puts("=================================================================")
IO.puts(" IEC 60870-5-101 Unbalanced Master <-> Slave Peer-to-Peer Test")
IO.puts("=================================================================")

# Start in-memory VirtualBus
{:ok, bus} = VirtualBus.start_link()

# 1. Start Slave station (Address = 1)
{:ok, _slave} =
  Slave.start_link(
    transport: {VirtualBus, bus},
    mode: :unbalanced,
    link_address: 1,
    interrogation_handler: fn conn, asdu, qoi ->
      IO.puts("  [Slave 1] General Interrogation received (QOI=#{qoi})")
      Slave.send_act_con(conn, asdu, false)

      # Provide telemetry measurement
      io = Monitoring.measured_value_scaled(100, 2500, 0x00)
      resp =
        ASDU.new(:m_me_nb_1,
          cot: :interrogated_by_station,
          ca: asdu.ca,
          information_objects: [io]
        )

      Slave.enqueue_user_data_class_1(conn, resp)
      Slave.send_act_term(conn, asdu)
      true
    end,
    clock_sync_handler: fn _conn, _asdu, %CP56Time2a{} = ts ->
      IO.puts("  [Slave 1] Clock synchronization received: #{inspect(ts)}")
      true
    end,
    asdu_handler: fn conn, asdu ->
      case asdu.type_id do
        :c_sc_na_1 ->
          [sc | _] = asdu.objects
          IO.puts("  [Slave 1] Single command received: IOA=#{sc.ioa}, state=#{sc.state}")
          Slave.send_act_con(conn, asdu, false)
          true

        _ ->
          false
      end
    end
  )

IO.puts("[1/5] Slave station address 1 started.")

# 2. Start Master station (monitoring Slave 1)
{:ok, master} =
  Master.start_link(
    transport: {VirtualBus, bus},
    mode: :unbalanced,
    slaves: [1],
    slave_address: 1,
    tick_interval_ms: 10,
    asdu_handler: fn _m, slave_addr, asdu ->
      IO.puts(
        "  [Master] Received ASDU from Slave #{slave_addr}: Type=#{asdu.type_id}, COT=#{asdu.cot}"
      )
    end,
    link_state_handler: fn _m, slave_addr, state ->
      IO.puts("  [Master] Slave #{slave_addr} link state changed to: #{state}")
    end
  )

IO.puts("[2/5] Master started. Waiting for link handshake...")

# Wait for FT1.2 link handshake (FC=9 -> FC=11, FC=0 -> ACK)
Process.sleep(200)

# 3. Poll Slave 1 for Class 2 background data
IO.puts("[3/5] Master polling Slave 1 for Class 2 background data...")
:ok = Master.poll_single_slave(master, 1)
Process.sleep(100)

# 4. Master sends General Interrogation to Slave 1
IO.puts("[4/5] Master sending General Interrogation (C_IC_NA_1, QOI=20) to Slave 1...")
:ok = Master.use_slave_address(master, 1)
:ok = Master.send_interrogation_command(master, :activation, 1, 20)
Process.sleep(300)

# 5. Master sends Single Command to Slave 1
IO.puts("[5/5] Master sending Single Command (C_SC_NA_1, IOA=500, state=true) to Slave 1...")
cmd = Control.single_command(500, true, false, 0)
:ok = Master.use_slave_address(master, 1)
:ok = Master.send_process_command(master, :activation, 1, cmd)
Process.sleep(300)

IO.puts("=================================================================")
IO.puts(" Peer-to-Peer test successfully verified all exchanges!")
IO.puts("=================================================================")
