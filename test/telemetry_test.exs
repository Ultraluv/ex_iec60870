defmodule IEC60870.TelemetryTest do
  use ExUnit.Case, async: false

  alias IEC60870.ASDU
  alias IEC60870.CS104.{Connection, MasterConnection, Slave}
  alias IEC60870.IO.Monitoring

  test "CS104 emits Telemetry events for raw_message, connection_event, and asdu" do
    test_pid = self()

    # Define event handler attaching to telemetry
    events = [
      [:iec60870, :cs104, :raw_message],
      [:iec60870, :cs104, :connection_event],
      [:iec60870, :cs104, :asdu]
    ]

    handler_id = "test-telemetry-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        interrogation_handler: fn conn, asdu, _qoi ->
          MasterConnection.send_act_con(conn, asdu, false)
          io = Monitoring.single_point(101, true, 0x00)

          resp =
            ASDU.new(:m_sp_na_1,
              cot: :interrogated_by_station,
              ca: asdu.ca,
              information_objects: [io]
            )

          MasterConnection.send_asdu(conn, resp)
          MasterConnection.send_act_term(conn, asdu)
          true
        end
      )

    {:ok, port} = Slave.get_port(slave)

    {:ok, conn} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        owner: test_pid
      )

    assert :ok = Connection.connect(conn)

    # 1. Connection event
    assert_receive {:telemetry_event, [:iec60870, :cs104, :connection_event], _measurements,
                    %{event: :opened}},
                   2000

    assert :ok = Connection.send_start_dt(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :startdt_con_received}}, 2000

    # 2. Raw message event (sent or received STARTDT)
    assert_receive {:telemetry_event, [:iec60870, :cs104, :raw_message], %{byte_size: size},
                    %{direction: _dir}},
                   2000

    assert size > 0

    assert :ok = Connection.send_interrogation_command(conn, :activation, 1, 20)

    # 3. ASDU event (e.g., activation_con, interrogated_by_station, activation_termination)
    assert_receive {:telemetry_event, [:iec60870, :cs104, :asdu], %{count: 1},
                    %{type_id: :c_ic_na_1, cot: :activation}},
                   2000

    assert_receive {:telemetry_event, [:iec60870, :cs104, :asdu], %{count: 1},
                    %{type_id: :m_sp_na_1, cot: :interrogated_by_station}},
                   2000

    Connection.close(conn)
    Slave.stop(slave)
  end
end
