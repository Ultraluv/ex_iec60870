defmodule IEC60870.FileServiceTest do
  use ExUnit.Case, async: true

  alias IEC60870.CS101.Master, as: CS101Master
  alias IEC60870.CS101.Slave, as: CS101Slave
  alias IEC60870.CS101.Transport.VirtualBus
  alias IEC60870.CS104.{Connection, Slave}
  alias IEC60870.FileService.{Client, Server, TransparentFile}

  test "FileService over CS104: Directory listing, Multi-section File Read (Upload), and File Write (Download)" do
    test_pid = self()

    # Prepare two files on the Slave FileServer (including a multi-section file > max_segment_size)
    sec1 = :crypto.strong_rand_bytes(450)
    sec2 = :crypto.strong_rand_bytes(320)
    file1 = TransparentFile.new(1, 30000, 1001, [sec1, sec2])
    file2 = TransparentFile.new(1, 30000, 1002, "Hello IEC 60870-5-104 File Service!")

    {:ok, file_server} =
      Server.start_link(
        files: [file1, file2],
        max_segment_size: 180,
        owner: test_pid
      )

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        asdu_handler: fn conn, asdu ->
          Server.handle_asdu(file_server, conn, asdu)
        end
      )

    {:ok, port} = Slave.get_port(slave)
    agent = start_supervised!({Agent, fn -> nil end})

    {:ok, active_conn} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        owner: test_pid,
        asdu_handler: fn _c, asdu ->
          case Agent.get(agent, & &1) do
            pid when is_pid(pid) -> Client.handle_asdu(pid, asdu)
            _ -> :ok
          end
        end
      )

    {:ok, active_client} =
      Client.start_link(
        connection: active_conn,
        max_segment_size: 180
      )

    Agent.update(agent, fn _ -> active_client end)

    assert :ok = Connection.connect(active_conn)
    assert :ok = Connection.send_start_dt(active_conn)

    assert_receive {:iec60870_cs104, ^active_conn, {:connection_event, :startdt_con_received}},
                   2000

    # 1. Request directory from Slave
    assert {:ok, entries} = Client.request_directory(active_client, 1, 30000)
    assert length(entries) == 2
    assert Enum.map(entries, & &1.nof) == [1001, 1002]
    assert Enum.map(entries, & &1.length_of_file) == [770, 35]

    # 2. Read (upload) multi-section file 1001 from Slave
    assert {:ok, downloaded_bin} = Client.get_file(active_client, 1, 30000, 1001)
    assert downloaded_bin == sec1 <> sec2

    assert_receive {:iec60870_file_server, ^file_server,
                    {:file_upload_complete, {1, 30000, 1001}, true}},
                   2000

    # 3. Write (download) a new multi-section file 2001 from Master to Slave
    up_sec1 = :crypto.strong_rand_bytes(350)
    up_sec2 = :crypto.strong_rand_bytes(250)
    upload_file = TransparentFile.new(1, 30001, 2001, [up_sec1, up_sec2])

    assert :ok = Client.send_file(active_client, upload_file)

    assert_receive {:iec60870_file_server, ^file_server,
                    {:file_received, {1, 30001, 2001}, recv_bin}},
                   2000

    assert recv_bin == up_sec1 <> up_sec2

    received_map = Server.get_received_files(file_server)
    assert Map.get(received_map, {1, 30001, 2001}) == up_sec1 <> up_sec2

    Connection.close(active_conn)
    Slave.stop(slave)
  end

  test "FileService over CS101 Unbalanced mode: File Read (Upload) and File Write (Download)" do
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

    file_content = :crypto.strong_rand_bytes(320)
    file1 = TransparentFile.new(1, 40000, 3001, file_content)

    {:ok, file_server} =
      Server.start_link(
        files: [file1],
        max_segment_size: 160,
        owner: test_pid
      )

    {:ok, _slave} =
      CS101Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        link_address: 1,
        tick_interval_ms: 10,
        asdu_handler: fn conn, asdu ->
          Server.handle_asdu(file_server, conn, asdu)
        end
      )

    agent = start_supervised!({Agent, fn -> nil end}, id: :cs101_file_agent)

    {:ok, master} =
      CS101Master.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        slaves: [1],
        slave_address: 1,
        owner: test_pid,
        tick_interval_ms: 10,
        asdu_handler: fn _m, _addr, asdu ->
          case Agent.get(agent, & &1) do
            pid when is_pid(pid) -> Client.handle_asdu(pid, asdu)
            _ -> :ok
          end
        end
      )

    {:ok, file_client} =
      Client.start_link(
        master: master,
        max_segment_size: 160
      )

    Agent.update(agent, fn _ -> file_client end)
    assert_receive {:iec60870_cs101_master, ^master, {:link_state, 1, :available}}, 2000

    assert {:ok, downloaded_bin} = Client.get_file(file_client, 1, 40000, 3001)
    assert downloaded_bin == file_content

    upload_bin = "CS101 File Download Payload"
    upload_file = TransparentFile.new(1, 40000, 3002, upload_bin)
    assert :ok = Client.send_file(file_client, upload_file)

    assert_receive {:iec60870_file_server, ^file_server,
                    {:file_received, {1, 40000, 3002}, ^upload_bin}},
                   2000
  end

  test "FileService edge cases: Empty directory F_DR_TA_1, QueryLog time-range filtering, and FileReady rejection" do
    alias IEC60870.Types.CPTime.CP56Time2a
    test_pid = self()

    {:ok, file_server} =
      Server.start_link(
        files: [],
        file_ready_handler: fn _ca, _ioa, nof, _lof ->
          if nof == 9999, do: {:error, :not_ready}, else: :ok
        end,
        owner: test_pid
      )

    {:ok, slave} =
      Slave.start_link(
        port: 0,
        asdu_handler: fn conn, asdu ->
          Server.handle_asdu(file_server, conn, asdu)
        end
      )

    {:ok, port} = Slave.get_port(slave)
    agent = start_supervised!({Agent, fn -> nil end}, id: :edge_file_agent)

    {:ok, conn} =
      Connection.start_link(
        host: "127.0.0.1",
        port: port,
        owner: test_pid,
        asdu_handler: fn _c, asdu ->
          case Agent.get(agent, & &1) do
            pid when is_pid(pid) -> Client.handle_asdu(pid, asdu)
            _ -> :ok
          end
        end
      )

    {:ok, client} = Client.start_link(connection: conn)
    Agent.update(agent, fn _ -> client end)

    assert :ok = Connection.connect(conn)
    assert :ok = Connection.send_start_dt(conn)
    assert_receive {:iec60870_cs104, ^conn, {:connection_event, :startdt_con_received}}, 2000

    # 1. Empty directory request returns {:ok, []} without hanging
    assert {:ok, []} = Client.request_directory(client, 1, 30000)

    # 2. Add two files with different timestamps and test QueryLog (F_SC_NB_1) filtering
    t_early = CP56Time2a.from_ms_timestamp(1_700_000_000_000)
    t_late = CP56Time2a.from_ms_timestamp(1_700_100_000_000)
    f_early = %{TransparentFile.new(1, 30000, 101, "early") | created_at: t_early}
    f_late = %{TransparentFile.new(1, 30000, 102, "late") | created_at: t_late}
    :ok = Server.add_file(file_server, f_early)
    :ok = Server.add_file(file_server, f_late)

    t_mid = CP56Time2a.from_ms_timestamp(1_700_050_000_000)
    t_end = CP56Time2a.from_ms_timestamp(1_700_200_000_000)
    assert {:ok, [only_late]} = Client.query_log(client, 1, 30000, 0, t_mid, t_end)
    assert only_late.nof == 102

    # 3. Slave rejects FILE_READY (nof=9999) -> Client.send_file returns {:error, :file_ready_rejected} immediately
    rejected_file = TransparentFile.new(1, 30000, 9999, "rejected content")
    assert {:error, :file_ready_rejected} = Client.send_file(client, rejected_file)

    Connection.close(conn)
    Slave.stop(slave)
  end
end
