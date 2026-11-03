#!/usr/bin/env elixir
# examples/cs101_master_balanced/master_example.exs
# Run with: mix run examples/cs101_master_balanced/master_example.exs

alias IEC60870.ASDU
alias IEC60870.CS101.{Master, Slave}
alias IEC60870.CS101.Transport.VirtualBus
alias IEC60870.IO.Monitoring

IO.puts("==================================================")
IO.puts(" IEC 60870-5-101 Balanced Peer-to-Peer Link Example")
IO.puts(" (Full duplex point-to-point communication)")
IO.puts("==================================================")

{:ok, bus} = VirtualBus.start_link()

# Slave endpoint in balanced mode (DIR = false)
{:ok, slave} =
  Slave.start_link(
    transport: {VirtualBus, bus},
    mode: :balanced,
    link_address: 1,
    other_station_address: 1,
    dir: false,
    interrogation_handler: fn conn, asdu, _qoi ->
      Slave.send_act_con(conn, asdu, false)
      Slave.send_act_term(conn, asdu)
      true
    end
  )

# Master endpoint in balanced mode (DIR = true)
{:ok, master} =
  Master.start_link(
    transport: {VirtualBus, bus},
    mode: :balanced,
    own_address: 1,
    slave_address: 1,
    dir: true,
    asdu_handler: fn _m, _addr, asdu ->
      IO.puts("[Balanced Master] ASDU received: #{asdu.type_id}, COT: #{asdu.cot}")
    end,
    link_state_handler: fn _m, addr, state ->
      IO.puts("[Balanced Master] Link state to #{addr} changed to #{state}")
    end
  )

Process.sleep(500)

IO.puts("[Balanced Master] Sending Interrogation Command...")
:ok = Master.send_interrogation_command(master, :activation, 1, 20)
Process.sleep(500)

# In Balanced mode, the Slave can spontaneously transmit without waiting for polling!
IO.puts("[Balanced Slave] Spontaneously sending Class 1 event without being polled...")
io = Monitoring.single_point(300, true, 0x00)
spont_asdu = ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, information_objects: [io])
Slave.enqueue_user_data_class_1(slave, spont_asdu)

Process.sleep(500)
IO.puts("[Balanced Link] Demo finished.")
