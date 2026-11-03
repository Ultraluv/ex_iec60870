defmodule IEC60870.ExamplesTest do
  use ExUnit.Case, async: false

  alias IEC60870.ASDU
  alias IEC60870.CS101.{Master, Slave}
  alias IEC60870.CS101.Transport.VirtualBus
  alias IEC60870.CS104.{Connection, MasterConnection, RedundancyGroup}
  alias IEC60870.CS104.Slave, as: CS104Slave
  alias IEC60870.FileService.{Client, Receiver, Server, TransparentFile}
  alias IEC60870.IO.{Control, Monitoring}
  alias IEC60870.Types.CPTime.CP56Time2a

  test "CS104 Server <-> Client example flow" do
    test_pid = self()

    # 1. Start CS104 Server
    {:ok, slave} =
      CS104Slave.start_link(
        port: 0,
        interrogation_handler: fn conn, asdu, _qoi ->
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
        clock_sync_handler: fn _conn, _asdu, %CP56Time2a{} = _ts ->
          send(test_pid, :clock_synced)
          true
        end,
        asdu_handler: fn conn, asdu ->
          if asdu.type_id == :c_sc_na_1 do
            send(test_pid, {:command_executed, asdu.objects})
            MasterConnection.send_act_con(conn, asdu, false)
            true
          else
            false
          end
        end
      )

    {:ok, port} = CS104Slave.get_port(slave)

    # 2. Start CS104 Client
    {:ok, conn} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        owner: test_pid
      )

    assert :ok = Connection.connect(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :opened}}, 2000

    assert :ok = Connection.send_start_dt(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :startdt_con_received}}, 2000

    # 3. Interrogation
    assert :ok = Connection.send_interrogation_command(conn, :activation, 1, 20)

    assert_receive {:iec60870_cs104, ^conn,
                    {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    assert_receive {:iec60870_cs104, ^conn,
                    {:asdu, %ASDU{type_id: :m_sp_na_1, cot: :interrogated_by_station}}},
                   2000

    assert_receive {:iec60870_cs104, ^conn,
                    {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                   2000

    # 4. Clock Sync
    now_ts = CP56Time2a.from_datetime(DateTime.utc_now())
    assert :ok = Connection.send_clock_sync_command(conn, 1, now_ts)
    assert_receive :clock_synced, 2000

    # 5. Process Command
    sc = Control.single_command(100, true, false, 0)
    assert :ok = Connection.send_process_command(conn, :activation, 1, sc)
    assert_receive {:command_executed, [%Control.SingleCommand{ioa: 100, state: true}]}, 2000

    # 6. Spontaneous data from server
    spont_io = Monitoring.measured_value_scaled(110, 9999, 0x00)
    spont_asdu = ASDU.new(:m_me_nb_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
    assert :ok = CS104Slave.enqueue_user_data(slave, spont_asdu)

    assert_receive {:iec60870_cs104, ^conn,
                    {:asdu, %ASDU{type_id: :m_me_nb_1, cot: :spontaneous} = recv_asdu}},
                   2000

    assert hd(recv_asdu.objects).value == 9999

    Connection.close(conn)
    CS104Slave.stop(slave)
  end

  test "CS104 Multi-Redundancy Groups example flow" do
    g1 = RedundancyGroup.new("Group1", ["127.0.0.1"])
    g2 = RedundancyGroup.new("Group2", ["10.0.0.1"])

    {:ok, slave} =
      CS104Slave.start_link(
        port: 0,
        server_mode: :multiple_redundancy_groups,
        redundancy_groups: [g1, g2]
      )

    {:ok, port} = CS104Slave.get_port(slave)

    {:ok, conn} = Connection.start_link(host: "127.0.0.1", port: port)
    assert :ok = Connection.connect(conn)
    assert :ok = Connection.send_start_dt(conn)
    Process.sleep(100)

    Connection.close(conn)
    CS104Slave.stop(slave)
  end

  test "CS101 Unbalanced Master <-> Slave example flow" do
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

    {:ok, slave} =
      Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        link_address: 1,
        interrogation_handler: fn conn, asdu, _qoi ->
          Slave.send_act_con(conn, asdu, false)
          io = Monitoring.single_point(100, true, 0x00)

          gi_resp =
            ASDU.new(:m_sp_na_1, cot: :interrogated_by_station, ca: 1, information_objects: [io])

          Slave.enqueue_user_data_class_1(conn, gi_resp)
          Slave.send_act_term(conn, asdu)
          true
        end,
        asdu_handler: fn conn, asdu ->
          Slave.send_act_con(conn, asdu, false)
          true
        end
      )

    {:ok, master} =
      Master.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        slaves: [1],
        slave_address: 1,
        owner: test_pid,
        tick_interval_ms: 10
      )

    assert_receive {:iec60870_cs101_master, ^master, {:link_state, 1, :available}}, 2000

    # Interrogation
    assert :ok = Master.use_slave_address(master, 1)
    assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :m_sp_na_1, cot: :interrogated_by_station}}},
                   2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                   2000

    # Process command
    sc = Control.single_command(500, true, false, 0)
    assert :ok = Master.send_process_command(master, :activation, 1, sc)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :c_sc_na_1, cot: :activation_con}}},
                   2000

    Master.stop(master)
    Slave.stop(slave)
  end

  test "CS101 Balanced Master <-> Slave example flow" do
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

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

    {:ok, master} =
      Master.start_link(
        transport: {VirtualBus, bus},
        mode: :balanced,
        own_address: 1,
        slave_address: 1,
        dir: true,
        owner: test_pid,
        tick_interval_ms: 10
      )

    assert_receive {:iec60870_cs101_master, ^master, {:link_state, -1, :available}}, 2000

    assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 0, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    # Spontaneous transmission in balanced mode
    spont_io = Monitoring.single_point(300, true, 0x00)
    spont_asdu = ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
    assert :ok = Slave.enqueue_user_data_class_1(slave, spont_asdu)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 0, %ASDU{type_id: :m_sp_na_1, cot: :spontaneous}}},
                   2000

    Master.stop(master)
    Slave.stop(slave)
  end

  test "CS104 File Service Server <-> Client example flow" do
    file1 = TransparentFile.new(101, "config.json", ~s({"device_id": "RTU_01"}))
    file2 = TransparentFile.new(102, "fault.log", "Event Log 2026")

    {:ok, file_server} =
      Server.start_link(
        files: [file1, file2],
        file_received_handler: fn _srv, file ->
          assert file.nof == 201
          assert file.data == "UploadPayload"
        end
      )

    {:ok, slave} =
      CS104Slave.start_link(
        port: 0,
        asdu_handler: fn conn, asdu ->
          Server.handle_asdu(file_server, conn, asdu)
        end
      )

    {:ok, port} = CS104Slave.get_port(slave)

    {:ok, conn} = Connection.start_link(host: "127.0.0.1", port: port)
    assert :ok = Connection.connect(conn)
    assert :ok = Connection.send_start_dt(conn)
    Process.sleep(100)

    {:ok, file_client} = Client.start_link(connection: conn, ca: 1)

    Connection.set_asdu_handler(conn, fn _conn, asdu ->
      Client.handle_asdu(file_client, asdu)
    end)

    # 1. Request Directory
    assert {:ok, entries} = Client.request_directory(file_client, 1, 0)
    assert length(entries) == 2
    assert Enum.any?(entries, &(&1.nof == 101))

    # 2. Get file
    receiver = Receiver.Memory.new()
    assert {:ok, %Receiver.Memory{data: data}} = Client.get_file(file_client, 1, 0, 101, receiver)
    assert data == ~s({"device_id": "RTU_01"})

    # 3. Send file
    new_file = TransparentFile.new(201, "patch.dat", "UploadPayload")
    assert :ok = Client.send_file(file_client, 1, new_file)

    Connection.close(conn)
    CS104Slave.stop(slave)
  end

  test "CS104 TLS Server <-> Client handshake and communication" do
    test_pid = self()

    cert_file =
      Path.join(System.tmp_dir!(), "iec_test_cert_#{System.unique_integer([:positive])}.pem")

    key_file =
      Path.join(System.tmp_dir!(), "iec_test_key_#{System.unique_integer([:positive])}.pem")

    on_exit(fn ->
      File.rm(cert_file)
      File.rm(key_file)
    end)

    {_, 0} =
      System.cmd("openssl", [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        key_file,
        "-out",
        cert_file,
        "-days",
        "1",
        "-subj",
        "/CN=localhost"
      ])

    server_tls_opts = [
      certfile: cert_file,
      keyfile: key_file
    ]

    client_tls_opts = [
      verify: :verify_none
    ]

    {:ok, slave} =
      CS104Slave.start_link(
        port: 0,
        use_tls: true,
        tls_opts: server_tls_opts,
        interrogation_handler: fn conn, asdu, _qoi ->
          MasterConnection.send_act_con(conn, asdu, false)
          MasterConnection.send_act_term(conn, asdu)
          true
        end
      )

    {:ok, port} = CS104Slave.get_port(slave)

    {:ok, conn} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        use_tls: true,
        tls_opts: client_tls_opts,
        owner: test_pid
      )

    assert :ok = Connection.connect(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :opened}}, 3000

    assert :ok = Connection.send_start_dt(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :startdt_con_received}}, 3000

    assert :ok = Connection.send_interrogation_command(conn, :activation, 1, 20)

    assert_receive {:iec60870_cs104, ^conn,
                    {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   3000

    Connection.close(conn)
    CS104Slave.stop(slave)
  end
end
