defmodule IEC60870.CS101Test do
  use ExUnit.Case, async: true

  alias IEC60870.ASDU
  alias IEC60870.CS101.{Frame, Master, Slave}
  alias IEC60870.CS101.Transport.VirtualBus
  alias IEC60870.IO.Monitoring

  test "CS101.Frame FT 1.2 variable, fixed, and 0xE5 codec and stream deframer" do
    assert {:ok, <<0xE5>>} = Frame.encode(:single_char_ack, 1)
    assert {:ok, :single_char_ack} = Frame.decode(<<0xE5>>, 1)

    ctrl = %{dir: false, prm: true, fcb_or_acd: true, fcv_or_dfc: true, fc: 10}
    assert {:ok, fixed_bin} = Frame.encode({:fixed_frame, ctrl, 2}, 1)
    assert {:ok, {:fixed_frame, ^ctrl, 2}} = Frame.decode(fixed_bin, 1)

    var_ctrl = %{dir: true, prm: true, fcb_or_acd: false, fcv_or_dfc: true, fc: 3}
    assert {:ok, var_bin} = Frame.encode({:variable_frame, var_ctrl, 258, <<10, 20, 30>>}, 2)
    assert {:ok, {:variable_frame, ^var_ctrl, 258, <<10, 20, 30>>}} = Frame.decode(var_bin, 2)

    stream = <<0xE5>> <> fixed_bin <> <<0x10, 0x49>>

    assert {:ok, [:single_char_ack, {:fixed_frame, ^ctrl, 2}], <<0x10, 0x49>>} =
             Frame.extract_frames(stream, 1)
  end

  test "CS101 Unbalanced mode: Master <-> 2 Slaves on VirtualBus with ACD Class 1 & Class 2 polling" do
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

    {:ok, _slave1} =
      Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        link_address: 1,
        owner: test_pid,
        interrogation_handler: fn conn, asdu, qoi ->
          send(test_pid, {:slave1_gi, qoi})
          Slave.send_act_con(conn, asdu, false)

          io = Monitoring.single_point(100, true, 0x00)

          gi_asdu =
            ASDU.new(:m_sp_na_1,
              cot: :interrogated_by_station,
              ca: asdu.ca,
              information_objects: [io]
            )

          Slave.enqueue_user_data_class_1(conn, gi_asdu)
          Slave.send_act_term(conn, asdu)
          true
        end
      )

    {:ok, slave2} =
      Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        link_address: 2,
        owner: test_pid
      )

    {:ok, master} =
      Master.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        slaves: [1, 2],
        slave_address: 1,
        owner: test_pid,
        tick_interval_ms: 10
      )

    # Wait for both slaves' link layers to reach :available
    assert_receive {:iec60870_cs101_master, ^master, {:link_state, 1, :available}}, 2000
    assert_receive {:iec60870_cs101_master, ^master, {:link_state, 2, :available}}, 2000

    # Send interrogation to Slave 1 -> Slave 1 sets ACD=true in ACK, Master automatically polls Class 1!
    assert :ok = Master.use_slave_address(master, 1)
    assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

    assert_receive {:slave1_gi, 20}, 2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :m_sp_na_1, cot: :interrogated_by_station}}},
                   2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                   2000

    # Enqueue Class 2 periodic data on Slave 2 and poll Slave 2
    c2_io = Monitoring.measured_value_scaled(200, 1234, 0x00)
    c2_asdu = ASDU.new(:m_me_nb_1, cot: :periodic, ca: 2, information_objects: [c2_io])
    assert :ok = Slave.enqueue_user_data_class_2(slave2, c2_asdu)

    assert :ok = Master.poll_single_slave(master, 2)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 2, %ASDU{type_id: :m_me_nb_1, cot: :periodic} = r_asdu}},
                   2000

    assert hd(r_asdu.objects).value == 1234
  end

  test "CS101 Balanced mode: Full-duplex Master <-> Slave bidirectional transmission" do
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

    {:ok, slave} =
      Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :balanced,
        link_address: 1,
        other_station_address: 1,
        dir: false,
        owner: test_pid,
        tick_interval_ms: 10,
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
    assert_receive {:iec60870_cs101_slave, ^slave, {:link_state, -1, :available}}, 2000

    # Master sends interrogation
    assert :ok = Master.send_interrogation_command(master, :activation, 1, 20)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 0, %ASDU{type_id: :c_ic_na_1, cot: :activation_con}}},
                   2000

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 0, %ASDU{type_id: :c_ic_na_1, cot: :activation_termination}}},
                   2000

    # Slave initiates spontaneous Class 1 transmission without polling in Balanced mode!
    spont_io = Monitoring.measured_value_short(555, 99.75, 0x00)
    spont_asdu = ASDU.new(:m_me_nc_1, cot: :spontaneous, ca: 1, information_objects: [spont_io])
    assert :ok = Slave.enqueue_user_data_class_1(slave, spont_asdu)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 0, %ASDU{type_id: :m_me_nc_1, cot: :spontaneous}}},
                   2000
  end

  test "CS101.Queue ring-buffer oldest-entry overwrite and Class 2 empty -> NACK with ACD -> Class 1 poll" do
    alias IEC60870.CS101.Queue

    # 1. Queue ring-buffer overwrites oldest entry when full (matches cs101_queue.c:114-134)
    q0 = Queue.new(2)

    a1 =
      ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, objects: [Monitoring.single_point(1, true)])

    a2 =
      ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, objects: [Monitoring.single_point(2, true)])

    a3 =
      ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, objects: [Monitoring.single_point(3, true)])

    {:ok, q1} = Queue.enqueue(q0, a1)
    {:ok, q2} = Queue.enqueue(q1, a2)
    assert Queue.full?(q2)
    {:ok, q3} = Queue.enqueue(q2, a3)
    assert Queue.size(q3) == 2
    assert {true, :m_sp_na_1} = Queue.has_waiting_asdu?(q3)

    {:ok, first_out, q4} = Queue.dequeue(q3)
    {:ok, second_out, _q5} = Queue.dequeue(q4)
    assert hd(first_out.objects).ioa == 2
    assert hd(second_out.objects).ioa == 3

    # 2. When Class 2 is empty but Class 1 has data, polling Class 2 (FC=11) returns FC=9 (NACK_NO_DATA)
    # with ACD=true, which triggers Master to automatically poll Class 1 (FC=10) and retrieve the Class 1 ASDU!
    test_pid = self()
    {:ok, bus} = VirtualBus.start_link()

    {:ok, slave} =
      Slave.start_link(
        transport: {VirtualBus, bus},
        mode: :unbalanced,
        link_address: 1,
        owner: test_pid
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

    c1_io = Monitoring.single_point(999, true, 0x00)
    c1_asdu = ASDU.new(:m_sp_na_1, cot: :spontaneous, ca: 1, objects: [c1_io])
    assert :ok = Slave.enqueue_user_data_class_1(slave, c1_asdu)

    # Master polls Class 2 (FC=11); Slave has empty Class 2 queue so responds FC=9 with ACD=1,
    # and Master automatically follows up with FC=10 (Class 1 request)!
    assert :ok = Master.request_class_2_data(master, 1)

    assert_receive {:iec60870_cs101_master, ^master,
                    {:asdu, 1, %ASDU{type_id: :m_sp_na_1} = recv}},
                   2000

    assert hd(recv.objects).ioa == 999
  end

  test "Balanced secondary handles duplicate FCB frame by returning ACK without reprocessing data" do
    alias IEC60870.CS101.LinkLayer.Balanced
    alias IEC60870.LinkLayerParameters

    bll = Balanced.new(1, 1, false, %LinkLayerParameters{use_single_char_ack: true})

    app_state = []

    callbacks = %{
      handle_user_data: fn list, data -> list ++ [data] end
    }

    # 1. First frame with FCB = true (matches expected)
    ctrl1 = %{fc: 3, fcb_or_acd: true, fcv_or_dfc: true, prm: true, dir: false}
    frame1 = {:variable_frame, ctrl1, 1, "packet_1"}

    {bll, app_state, replies, _changes} =
      Balanced.handle_frame(bll, frame1, app_state, callbacks, 1000)

    assert replies == [:single_char_ack]
    assert app_state == ["packet_1"]
    assert bll.expected_fcb == false

    # 2. Duplicate retransmitted frame with same FCB = true (mismatch because expected is false)
    {bll, app_state, replies2, _changes} =
      Balanced.handle_frame(bll, frame1, app_state, callbacks, 1100)

    # Secondary MUST acknowledge to stop sender retransmissions!
    assert replies2 == [:single_char_ack]
    # And MUST NOT re-deliver duplicate user data to application callback!
    assert app_state == ["packet_1"]
    # Expected FCB remains false
    assert bll.expected_fcb == false
  end

  test "Unbalanced secondary handles FC=2 (Test function for link) and FC=1 (Reset user process)" do
    alias IEC60870.CS101.LinkLayer.SecondaryUnbalanced
    alias IEC60870.LinkLayerParameters

    sll = SecondaryUnbalanced.new(1, %LinkLayerParameters{use_single_char_ack: true})

    callbacks = %{
      is_class_1_available: fn st -> st.has_c1 end,
      pop_class_1_data: fn st -> {nil, st} end,
      pop_class_2_data: fn st -> {nil, st} end,
      handle_user_data: fn st, _ud, _bcast -> st end,
      reset_cu_received: fn st, _only_fcb -> %{st | reset_called: true} end
    }

    app_state = %{has_c1: false, reset_called: false}

    # 1. Primary sends FC=2 (TEST_FUNCTION_FOR_LINK) with FCB=true, FCV=true
    ctrl_test = %{fc: 2, fcb_or_acd: true, fcv_or_dfc: true, prm: true, dir: false}
    frame_test = {:fixed_frame, ctrl_test, 1}

    {sll, app_state, replies, _changes} =
      SecondaryUnbalanced.handle_frame(sll, frame_test, app_state, callbacks, 1000)

    # When no class 1 is available and single char ack is enabled, reply :single_char_ack
    assert replies == [:single_char_ack]
    assert sll.expected_fcb == false

    # 2. When Class 1 data is available, FC=2 must reply with fixed frame carrying ACD=true
    app_state = %{app_state | has_c1: true}
    ctrl_test2 = %{fc: 2, fcb_or_acd: false, fcv_or_dfc: true, prm: true, dir: false}
    frame_test2 = {:fixed_frame, ctrl_test2, 1}

    {sll, app_state, replies2, _changes} =
      SecondaryUnbalanced.handle_frame(sll, frame_test2, app_state, callbacks, 1100)

    assert [
             {:fixed_frame, %{fc: 0, fcb_or_acd: true, fcv_or_dfc: false, prm: false}, 1}
           ] = replies2

    assert sll.expected_fcb == true

    # 3. Primary sends FC=1 (RESET_USER_PROCESS)
    ctrl_reset = %{fc: 1, fcb_or_acd: false, fcv_or_dfc: false, prm: true, dir: false}
    frame_reset = {:fixed_frame, ctrl_reset, 1}

    {sll, app_state, replies3, _changes} =
      SecondaryUnbalanced.handle_frame(sll, frame_reset, app_state, callbacks, 1200)

    assert replies3 == [:single_char_ack]
    assert app_state.reset_called == true
    assert sll.expected_fcb == true
  end
end
