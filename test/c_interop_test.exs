defmodule IEC60870.CInteropTest do
  use ExUnit.Case, async: false

  alias IEC60870.ASDU
  alias IEC60870.CS101.{Master, Slave, Transport}
  alias IEC60870.CS104.{Connection, MasterConnection}
  alias IEC60870.CS104.Slave, as: CS104Slave
  alias IEC60870.IO.{Control, Monitoring}

  @helper_bin "/tmp/c_interop_helper"

  defmodule TCPSerialTransport do
    @behaviour Transport

    def start_bridge(target_pid_fn) do
      {:ok, lsock} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, nodelay: true])

      {:ok, port} = :inet.port(lsock)
      {:ok, agent} = Agent.start_link(fn -> nil end)

      spawn_link(fn ->
        case :gen_tcp.accept(lsock, 3000) do
          {:ok, sock} ->
            Agent.update(agent, fn _ -> sock end)
            recv_loop(sock, target_pid_fn, agent)

          _ ->
            :ok
        end
      end)

      {port, {__MODULE__, agent}, lsock}
    end

    defp recv_loop(sock, target_pid_fn, agent) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, data} ->
          if pid = target_pid_fn.() do
            send(pid, {:cs101_transport_data, agent, data})
          end

          recv_loop(sock, target_pid_fn, agent)

        _ ->
          :ok
      end
    end

    @impl true
    def send_data(agent, data) do
      case Agent.get(agent, & &1) do
        nil -> :ok
        sock -> :gen_tcp.send(sock, data)
      end
    end

    @impl true
    def close(agent) do
      case Agent.get(agent, & &1) do
        nil -> :ok
        sock -> :gen_tcp.close(sock)
      end
    end
  end

  test "Elixir CS104.Connection (Master) <-> lib60870-C CS104_Slave interop" do
    if File.exists?(@helper_bin) do
      test_pid = self()
      # Pick an ephemeral port by opening and closing a socket
      {:ok, lsock} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
      {:ok, port} = :inet.port(lsock)
      :gen_tcp.close(lsock)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["slave", Integer.to_string(port)]
        ])

      assert_receive {^port_proc, {:data, "READY " <> _}}, 3000

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

      # Send Interrogation Command to C Slave
      assert :ok = Connection.send_interrogation_command(conn, :activation, 1, 20)

      assert_receive {:iec60870_cs104, ^conn,
                      {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                     2000

      assert_receive {:iec60870_cs104, ^conn,
                      {:asdu, %ASDU{type_id: :m_me_nb_1, cot: :interrogated_by_station} = gi_asdu}},
                     2000

      assert hd(gi_asdu.objects).ioa == 100
      assert hd(gi_asdu.objects).value == 1234

      assert_receive {:iec60870_cs104, ^conn,
                      {:asdu, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                     2000

      # Send Single Command to C Slave
      sc = Control.single_command(400, true, false, 0)
      assert :ok = Connection.send_process_command(conn, :activation, 1, sc)

      assert_receive {:iec60870_cs104, ^conn,
                      {:asdu, %ASDU{type_id: :c_sc_na_1, cot: :activation_con}}},
                     2000

      Connection.close(conn)
      Port.command(port_proc, "stop\n")
      assert_receive {^port_proc, {:exit_status, 0}}, 2000
    end
  end

  test "lib60870-C CS104_Connection (Master) <-> Elixir CS104.Slave interop" do
    if File.exists?(@helper_bin) do
      test_pid = self()

      {:ok, slave} =
        CS104Slave.start_link(
          port: 0,
          interrogation_handler: fn conn, asdu, qoi ->
            send(test_pid, {:from_c_master_gi, qoi})
            MasterConnection.send_act_con(conn, asdu, false)

            io = Monitoring.measured_value_scaled(100, 5678, 0x00)

            resp =
              ASDU.new(:m_me_nb_1,
                cot: :interrogated_by_station,
                ca: asdu.ca,
                information_objects: [io]
              )

            MasterConnection.send_asdu(conn, resp)
            MasterConnection.send_act_term(conn, asdu)
            true
          end
        )

      {:ok, port} = CS104Slave.get_port(slave)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          args: ["client", Integer.to_string(port)]
        ])

      assert_receive {:from_c_master_gi, 20}, 3000
      assert_receive {^port_proc, {:exit_status, 0}}, 3000

      CS104Slave.stop(slave)
    end
  end

  test "Elixir CS101.Master (Unbalanced) <-> lib60870-C CS101_Slave (Unbalanced) over PTY/FT1.2" do
    if File.exists?(@helper_bin) do
      test_pid = self()
      {:ok, target_holder} = Agent.start_link(fn -> nil end)

      {tcp_port, transport, lsock} =
        TCPSerialTransport.start_bridge(fn -> Agent.get(target_holder, & &1) end)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["cs101_slave_unbalanced", Integer.to_string(tcp_port)]
        ])

      assert_receive {^port_proc, {:data, "READY " <> _}}, 3000

      {:ok, master} =
        Master.start_link(
          transport: transport,
          mode: :unbalanced,
          slaves: [1],
          slave_address: 1,
          owner: test_pid,
          tick_interval_ms: 15
        )

      Agent.update(target_holder, fn _ -> master end)

      assert_receive {:iec60870_cs101_master, ^master, {:link_state, 1, :available}}, 3000

      assert :ok = Master.use_slave_address(master, 1)
      assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

      # C Slave sets ACD=true in ACK; Elixir Master automatically polls Class 1!
      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                     3000

      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 1,
                       %ASDU{type_id: :m_me_nb_1, cot: :interrogated_by_station} = gi_asdu}},
                     3000

      assert hd(gi_asdu.objects).ioa == 100
      assert hd(gi_asdu.objects).value == 1234

      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                     3000

      Master.stop(master)
      Port.command(port_proc, "stop\n")
      assert_receive {^port_proc, {:exit_status, 0}}, 3000
      :gen_tcp.close(lsock)
    end
  end

  test "lib60870-C CS101_Master (Unbalanced) <-> Elixir CS101.Slave (Unbalanced) over PTY/FT1.2" do
    if File.exists?(@helper_bin) do
      test_pid = self()
      {:ok, target_holder} = Agent.start_link(fn -> nil end)

      {tcp_port, transport, lsock} =
        TCPSerialTransport.start_bridge(fn -> Agent.get(target_holder, & &1) end)

      {:ok, slave} =
        Slave.start_link(
          transport: transport,
          mode: :unbalanced,
          link_address: 1,
          owner: test_pid,
          tick_interval_ms: 15,
          interrogation_handler: fn conn, asdu, qoi ->
            send(test_pid, {:c_cs101_master_gi, qoi})
            Slave.send_act_con(conn, asdu, false)

            io = Monitoring.measured_value_scaled(100, 5678, 0x00)

            resp =
              ASDU.new(:m_me_nb_1,
                cot: :interrogated_by_station,
                ca: asdu.ca,
                information_objects: [io]
              )

            Slave.enqueue_user_data_class_1(conn, resp)
            Slave.send_act_term(conn, asdu)
            true
          end
        )

      Agent.update(target_holder, fn _ -> slave end)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          args: ["cs101_master_unbalanced", Integer.to_string(tcp_port)]
        ])

      assert_receive {:c_cs101_master_gi, 20}, 3000
      assert_receive {^port_proc, {:exit_status, 0}}, 4000

      Slave.stop(slave)
      :gen_tcp.close(lsock)
    end
  end

  test "Elixir CS101.Master (Balanced) <-> lib60870-C CS101_Slave (Balanced) over PTY/FT1.2" do
    if File.exists?(@helper_bin) do
      test_pid = self()
      {:ok, target_holder} = Agent.start_link(fn -> nil end)

      {tcp_port, transport, lsock} =
        TCPSerialTransport.start_bridge(fn -> Agent.get(target_holder, & &1) end)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["cs101_slave_balanced", Integer.to_string(tcp_port)]
        ])

      assert_receive {^port_proc, {:data, "READY " <> _}}, 3000

      {:ok, master} =
        Master.start_link(
          transport: transport,
          mode: :balanced,
          own_address: 1,
          slave_address: 1,
          dir: true,
          owner: test_pid,
          tick_interval_ms: 15
        )

      Agent.update(target_holder, fn _ -> master end)

      assert_receive {:iec60870_cs101_master, ^master, {:link_state, -1, :available}}, 3000

      assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 0, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                     3000

      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 0,
                       %ASDU{type_id: :m_me_nb_1, cot: :interrogated_by_station} = gi_asdu}},
                     3000

      assert hd(gi_asdu.objects).value == 1234

      assert_receive {:iec60870_cs101_master, ^master,
                      {:asdu, 0, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                     3000

      Master.stop(master)
      Port.command(port_proc, "stop\n")
      assert_receive {^port_proc, {:exit_status, 0}}, 3000
      :gen_tcp.close(lsock)
    end
  end

  test "lib60870-C CS101_Master (Balanced) <-> Elixir CS101.Slave (Balanced) over PTY/FT1.2" do
    if File.exists?(@helper_bin) do
      test_pid = self()
      {:ok, target_holder} = Agent.start_link(fn -> nil end)

      {tcp_port, transport, lsock} =
        TCPSerialTransport.start_bridge(fn -> Agent.get(target_holder, & &1) end)

      {:ok, slave} =
        Slave.start_link(
          transport: transport,
          mode: :balanced,
          link_address: 1,
          other_station_address: 1,
          dir: false,
          owner: test_pid,
          tick_interval_ms: 15,
          interrogation_handler: fn conn, asdu, qoi ->
            send(test_pid, {:c_cs101_balanced_master_gi, qoi})
            Slave.send_act_con(conn, asdu, false)

            io = Monitoring.measured_value_scaled(100, 5678, 0x00)

            resp =
              ASDU.new(:m_me_nb_1,
                cot: :interrogated_by_station,
                ca: asdu.ca,
                information_objects: [io]
              )

            Slave.enqueue_user_data_class_1(conn, resp)
            Slave.send_act_term(conn, asdu)
            true
          end
        )

      Agent.update(target_holder, fn _ -> slave end)

      port_proc =
        Port.open({:spawn_executable, @helper_bin}, [
          :binary,
          :exit_status,
          args: ["cs101_master_balanced", Integer.to_string(tcp_port)]
        ])

      assert_receive {:c_cs101_balanced_master_gi, 20}, 3000
      assert_receive {^port_proc, {:exit_status, 0}}, 4000

      Slave.stop(slave)
      :gen_tcp.close(lsock)
    end
  end
end
