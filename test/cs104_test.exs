defmodule IEC60870.CS104Test do
  use ExUnit.Case, async: true

  alias IEC60870.ASDU
  alias IEC60870.CS104.{Connection, Frame, MasterConnection, RedundancyGroup, Slave}
  alias IEC60870.IO.{Control, Monitoring}
  alias IEC60870.Types.CPTime.CP56Time2a

  test "CS104.Frame U-Frame, S-Frame, I-Frame codec and TCP stream deframer" do
    for u_type <- [:startdt_act, :startdt_con, :stopdt_act, :stopdt_con, :testfr_act, :testfr_con] do
      assert {:ok, bin} = Frame.encode({:u_frame, u_type})
      assert byte_size(bin) == 6
      assert {:ok, {:u_frame, ^u_type}} = Frame.decode(bin)
    end

    assert {:ok, s_bin} = Frame.encode({:s_frame, 32767})
    assert {:ok, {:s_frame, 32767}} = Frame.decode(s_bin)

    assert {:ok, i_bin} = Frame.encode({:i_frame, 1234, 5678, <<1, 2, 3, 4>>})
    assert {:ok, {:i_frame, 1234, 5678, <<1, 2, 3, 4>>}} = Frame.decode(i_bin)

    # Concatenated + partial stream extraction
    stream = s_bin <> i_bin <> <<0x68, 0x04, 0x07>>

    assert {:ok, [{:s_frame, 32767}, {:i_frame, 1234, 5678, <<1, 2, 3, 4>>}],
            <<0x68, 0x04, 0x07>>} =
             Frame.extract_frames(stream)
  end

  test "CS104 Master <-> Slave end-to-end: STARTDT, Interrogation, ClockSync, Read, Control, Spontaneous Queue" do
    test_pid = self()

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        owner: test_pid,
        interrogation_handler: fn conn, asdu, qoi ->
          send(test_pid, {:slave_gi_received, qoi})
          MasterConnection.send_act_con(conn, asdu, false)

          io1 = Monitoring.measured_value_scaled(100, 42, 0x00)
          io2 = Monitoring.measured_value_scaled(101, 84, 0x00)

          gi_asdu =
            ASDU.new(:m_me_nb_1,
              is_sequence: true,
              cot: :interrogated_by_station,
              ca: asdu.ca,
              information_objects: [io1, io2]
            )

          MasterConnection.send_asdu(conn, gi_asdu)
          MasterConnection.send_act_term(conn, asdu)
          true
        end,
        clock_sync_handler: fn _conn, _asdu, ts ->
          send(test_pid, {:slave_clock_sync, ts})
          true
        end,
        read_handler: fn conn, asdu, ioa ->
          io = Monitoring.single_point(ioa, true, 0x00)
          resp = ASDU.new(:m_sp_na_1, cot: :request, ca: asdu.ca, information_objects: [io])
          MasterConnection.send_asdu(conn, resp)
          true
        end,
        asdu_handler: fn conn, asdu ->
          if asdu.type_id == :c_sc_na_1 do
            MasterConnection.send_act_con(conn, asdu, false)
            true
          else
            false
          end
        end
      )

    {:ok, port} = Slave.get_port(slave)

    {:ok, client} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        owner: test_pid
      )

    assert :ok = Connection.connect(client)
    assert_receive {:iec60870_cs104, ^client, {:connection_event, :opened}}, 2000

    assert :ok = Connection.send_start_dt(client)
    assert_receive {:iec60870_cs104, ^client, {:connection_event, :startdt_con_received}}, 2000

    # 1. General Interrogation
    assert :ok = Connection.send_interrogation_command(client, :activation, 1, 20)
    assert_receive {:slave_gi_received, 20}, 2000

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :m_me_nb_1, cot: :interrogated_by_station} = gi_data}},
                   2000

    assert Enum.map(gi_data.objects, & &1.value) == [42, 84]

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                   2000

    # 2. Clock Synchronization
    ts = CP56Time2a.from_ms(1_700_000_000_000)
    assert :ok = Connection.send_clock_sync_command(client, 1, ts)
    assert_receive {:slave_clock_sync, ^ts}, 2000

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :c_cs_na_1, cot: :activation_con}}},
                   2000

    # 3. Read Command
    assert :ok = Connection.send_read_command(client, 1, 500)

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :m_sp_na_1, cot: :request} = rd_resp}},
                   2000

    assert hd(rd_resp.objects).ioa == 500

    # 4. Single Command (Remote Control)
    sc = Control.single_command(200, true, false, 0)
    assert :ok = Connection.send_process_command(client, :activation, 1, sc)

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :c_sc_na_1, cot: :activation_con}}},
                   2000

    # 5. Spontaneous event via Slave low-priority queue
    spont_io = Monitoring.measured_value_short(300, 230.5, 0x00)
    spont_asdu = ASDU.new(:m_me_nc_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
    Slave.enqueue_asdu(slave, spont_asdu)

    assert_receive {:iec60870_cs104, ^client,
                    {:asdu, %ASDU{type_id: :m_me_nc_1, cot: :spontaneous} = recv_spont}},
                   2000

    assert_in_delta hd(recv_spont.objects).value, 230.5, 0.01

    assert :ok = Connection.send_stop_dt(client)
    assert_receive {:iec60870_cs104, ^client, {:connection_event, :stopdt_con_received}}, 2000

    Connection.close(client)
    Slave.stop(slave)
  end

  test "CS104 Slave single_redundancy_group failover deactivates old active connection" do
    test_pid = self()

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        server_mode: :single_redundancy_group,
        owner: test_pid
      )

    {:ok, port} = Slave.get_port(slave)

    {:ok, c1} = Connection.start_link(host: "127.0.0.1", port: port, owner: test_pid)
    {:ok, c2} = Connection.start_link(host: "127.0.0.1", port: port, owner: test_pid)

    assert :ok = Connection.connect(c1)
    assert :ok = Connection.connect(c2)

    assert :ok = Connection.send_start_dt(c1)
    assert_receive {:iec60870_cs104, ^c1, {:connection_event, :startdt_con_received}}, 2000

    # Activating c2 should close c1
    assert :ok = Connection.send_start_dt(c2)
    assert_receive {:iec60870_cs104, ^c2, {:connection_event, :startdt_con_received}}, 2000
    assert_receive {:iec60870_cs104, ^c1, {:connection_event, :closed}}, 2000

    # Spontaneous event should now arrive on c2
    spont_io = Monitoring.single_point(10, true, 0x00)

    Slave.enqueue_asdu(
      slave,
      ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
    )

    assert_receive {:iec60870_cs104, ^c2, {:asdu, %ASDU{type_id: :m_sp_na_1}}}, 2000

    Connection.close(c2)
    Slave.stop(slave)
  end

  test "CS104 Slave multiple_redundancy_groups and connection_is_redundancy_group modes" do
    test_pid = self()
    rg = RedundancyGroup.new("GroupA", ["127.0.0.1"])

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        server_mode: :multiple_redundancy_groups,
        redundancy_groups: [rg],
        owner: test_pid
      )

    {:ok, port} = Slave.get_port(slave)
    {:ok, c1} = Connection.start_link(host: "127.0.0.1", port: port, owner: test_pid)
    assert :ok = Connection.connect(c1)
    assert :ok = Connection.send_start_dt(c1)
    assert_receive {:iec60870_cs104, ^c1, {:connection_event, :startdt_con_received}}, 2000

    Connection.close(c1)
    Slave.stop(slave)
  end

  test "CS104 Slave UNCONFIRMED_STOPPED delays STOPDT_CON until all sent I-frames are confirmed by S-frame" do
    test_pid = self()

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        owner: test_pid
      )

    {:ok, port} = Slave.get_port(slave)

    # Connect using raw TCP socket so we can control exact S-frame timing
    {:ok, raw_sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    # 1. Send STARTDT_ACT and read STARTDT_CON
    {:ok, startdt_act} = Frame.encode({:u_frame, :startdt_act})
    :ok = :gen_tcp.send(raw_sock, startdt_act)
    assert {:ok, startdt_con_bin} = :gen_tcp.recv(raw_sock, 6, 2000)
    assert {:ok, {:u_frame, :startdt_con}} = Frame.decode(startdt_con_bin)

    # 2. Enqueue a spontaneous ASDU on Slave -> Slave sends I-frame (N(S) = 0, so unconfirmed seq_no = 1)
    io = Monitoring.single_point(42, true, 0x00)
    Slave.enqueue_asdu(slave, ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, objects: [io]))
    assert {:ok, <<0x68, len::8, _rest::binary>> = iframe_bin} = :gen_tcp.recv(raw_sock, 0, 2000)
    assert byte_size(iframe_bin) == len + 2
    assert {:ok, {:i_frame, 0, 0, _asdu}} = Frame.decode(iframe_bin)

    # 3. Send STOPDT_ACT BEFORE confirming the I-frame -> Slave enters :unconfirmed_stopped and must NOT send STOPDT_CON yet!
    {:ok, stopdt_act} = Frame.encode({:u_frame, :stopdt_act})
    :ok = :gen_tcp.send(raw_sock, stopdt_act)
    assert {:error, :timeout} = :gen_tcp.recv(raw_sock, 6, 150)

    # 4. Now send S-frame confirming N(R) = 1 -> Slave immediately sends STOPDT_CON!
    {:ok, s_frame} = Frame.encode({:s_frame, 1})
    :ok = :gen_tcp.send(raw_sock, s_frame)
    assert {:ok, stopdt_con_bin} = :gen_tcp.recv(raw_sock, 6, 2000)
    assert {:ok, {:u_frame, :stopdt_con}} = Frame.decode(stopdt_con_bin)

    :gen_tcp.close(raw_sock)
    Slave.stop(slave)
  end
end
