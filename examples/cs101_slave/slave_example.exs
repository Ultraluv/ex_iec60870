#!/usr/bin/env elixir
# examples/cs101_slave/slave_example.exs
# Run with: mix run examples/cs101_slave/slave_example.exs

alias IEC60870.ASDU
alias IEC60870.CS101.Slave
alias IEC60870.CS101.Transport.VirtualBus
alias IEC60870.IO.{Control, Monitoring}
alias IEC60870.Types.CPTime.CP56Time2a

IO.puts("==================================================")
IO.puts(" IEC 60870-5-101 Unbalanced Slave Example")
IO.puts("==================================================")

{:ok, _slave} =
  Slave.start_link(
    transport: {VirtualBus, self()},
    mode: :unbalanced,
    link_address: 1,
    interrogation_handler: fn conn, asdu, qoi ->
      IO.puts("[CS101 Slave] General interrogation received (QOI=#{qoi})")
      Slave.send_act_con(conn, asdu, false)

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
      IO.puts("[CS101 Slave] Clock synchronization received: #{inspect(ts)}")
      true
    end,
    asdu_handler: fn conn, asdu ->
      case asdu.type_id do
        :c_sc_na_1 ->
          [sc | _] = asdu.objects
          IO.puts("[CS101 Slave] Single command received: IOA=#{sc.ioa}, state=#{sc.state}")
          Slave.send_act_con(conn, asdu, false)
          true

        _ ->
          false
      end
    end
  )

IO.puts("[CS101 Slave] Slave station address 1 running. Press Ctrl+C to stop.")
Process.sleep(:infinity)
