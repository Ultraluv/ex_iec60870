defmodule IEC60870.CS101.Slave do
  @moduledoc """
  IEC 60870-5-101 Slave (`cs101_slave.c`), supporting both `:unbalanced` and `:balanced` link layer modes.

  Features:
  - Separate Class 1 (high-priority / command confirmations / events) and Class 2 (periodic / background) FIFO queues
  - Compatible with `IEC60870.CS104.MasterConnection` helpers (`send_asdu/2`, `send_act_con/3`, `send_act_term/2`) so application handlers can be shared between 101 and 104 Slaves
  - Standard application callbacks (`interrogation_handler`, `counter_interrogation_handler`, `read_handler`, `clock_sync_handler`, `reset_process_handler`, `delay_acquisition_handler`, `reset_cu_handler`, `asdu_handler`)
  """

  use GenServer

  alias IEC60870.{AppLayerParameters, ASDU, LinkLayerParameters}
  alias IEC60870.CS101.{Frame, Queue, Transport}
  alias IEC60870.CS101.LinkLayer.{Balanced, SecondaryUnbalanced}
  alias IEC60870.IO.System, as: SystemIO
  alias IEC60870.Telemetry
  alias IEC60870.Types.CPTime.CP56Time2a

  defstruct [
    :transport,
    :mode,
    :ll_params,
    :al_params,
    :link_layer,
    :class_1_queue,
    :class_2_queue,
    :owner,
    :interrogation_handler,
    :counter_interrogation_handler,
    :read_handler,
    :clock_sync_handler,
    :reset_process_handler,
    :delay_acquisition_handler,
    :reset_cu_handler,
    :asdu_handler,
    :is_ca_allowed_handler,
    :link_state_handler,
    :raw_message_handler,
    :tick_ref,
    link_address: 1,
    other_station_address: 0,
    dir: false,
    recv_buffer: <<>>,
    tick_interval_ms: 20
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Enqueues an ASDU into the Class 1 (high-priority) queue.
  Safe to call from inside Slave callbacks or external processes.
  """
  @spec enqueue_user_data_class_1(GenServer.server(), ASDU.t()) :: :ok
  def enqueue_user_data_class_1(slave, %ASDU{} = asdu) do
    if self() == slave do
      send(slave, {:internal_enqueue_class_1, asdu})
      :ok
    else
      GenServer.call(slave, {:enqueue_class_1, asdu})
    end
  end

  @doc """
  Enqueues an ASDU into the Class 2 (low-priority) queue.
  Safe to call from inside Slave callbacks or external processes.
  """
  @spec enqueue_user_data_class_2(GenServer.server(), ASDU.t()) :: :ok
  def enqueue_user_data_class_2(slave, %ASDU{} = asdu) do
    if self() == slave do
      send(slave, {:internal_enqueue_class_2, asdu})
      :ok
    else
      GenServer.call(slave, {:enqueue_class_2, asdu})
    end
  end

  @spec send_act_con(GenServer.server(), ASDU.t(), boolean()) :: :ok
  def send_act_con(slave, %ASDU{} = asdu, negative \\ false) do
    resp_cot =
      case asdu.cot do
        :deactivation -> :deactivation_con
        _ -> :activation_con
      end

    resp = %{asdu | cot: resp_cot, is_negative: negative}
    enqueue_user_data_class_1(slave, resp)
  end

  @spec send_act_term(GenServer.server(), ASDU.t()) :: :ok
  def send_act_term(slave, %ASDU{} = asdu) do
    resp = %{asdu | cot: :activation_termination, is_negative: false}
    enqueue_user_data_class_1(slave, resp)
  end

  @spec flush_queues(GenServer.server()) :: :ok
  def flush_queues(slave), do: GenServer.call(slave, :flush_queues)

  @spec is_class_1_queue_full?(GenServer.server()) :: boolean()
  def is_class_1_queue_full?(slave), do: GenServer.call(slave, :is_class_1_full)

  @spec is_class_2_queue_full?(GenServer.server()) :: boolean()
  def is_class_2_queue_full?(slave), do: GenServer.call(slave, :is_class_2_full)

  @doc """
  Sets DIR bit in balanced link layer mode.
  """
  @spec set_dir(GenServer.server(), boolean()) :: :ok
  def set_dir(slave, dir) when is_boolean(dir), do: GenServer.call(slave, {:set_dir, dir})

  @doc """
  Sets idle timeout in milliseconds.
  """
  @spec set_idle_timeout(GenServer.server(), pos_integer()) :: :ok
  def set_idle_timeout(slave, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: GenServer.call(slave, {:set_idle_timeout, timeout_ms})

  @doc """
  Sets local link layer address.
  """
  @spec set_link_layer_address(GenServer.server(), non_neg_integer()) :: :ok
  def set_link_layer_address(slave, address) when is_integer(address) and address >= 0,
    do: GenServer.call(slave, {:set_link_address, address})

  @doc """
  Sets peer station link address.
  """
  @spec set_link_layer_address_other_station(GenServer.server(), non_neg_integer()) :: :ok
  def set_link_layer_address_other_station(slave, address)
      when is_integer(address) and address >= 0,
      do: GenServer.call(slave, {:set_other_station_address, address})

  @spec get_app_layer_parameters(GenServer.server()) :: AppLayerParameters.t()
  def get_app_layer_parameters(slave), do: GenServer.call(slave, :get_al_params)

  @spec get_link_layer_parameters(GenServer.server()) :: LinkLayerParameters.t()
  def get_link_layer_parameters(slave), do: GenServer.call(slave, :get_ll_params)

  @spec start(GenServer.server()) :: :ok
  def start(_slave), do: :ok

  @spec stop(GenServer.server()) :: :ok
  def stop(slave), do: GenServer.stop(slave, :normal)

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    mode = Keyword.get(opts, :mode, :unbalanced)
    ll_params = Keyword.get(opts, :ll_params, %LinkLayerParameters{})
    al_params = Keyword.get(opts, :al_params, %AppLayerParameters{max_size_of_asdu: 249})
    link_address = Keyword.get(opts, :link_address, 1)
    other_station_address = Keyword.get(opts, :other_station_address, 0)
    dir = Keyword.get(opts, :dir, false)
    c1_size = Keyword.get(opts, :class_1_queue_size, 100)
    c2_size = Keyword.get(opts, :class_2_queue_size, 100)
    idle_timeout = Keyword.get(opts, :idle_timeout, 500)
    tick_interval = Keyword.get(opts, :tick_interval_ms, 20)

    transport =
      case transport do
        {IEC60870.CS101.Transport.VirtualBus, bus_pid} ->
          IEC60870.CS101.Transport.VirtualBus.attach(bus_pid, self())

        other ->
          other
      end

    link_layer =
      case mode do
        :unbalanced ->
          SecondaryUnbalanced.new(link_address, ll_params, idle_timeout)

        :balanced ->
          Balanced.new(
            link_address,
            other_station_address,
            dir,
            ll_params,
            ll_params.timeout_link_state
          )
      end

    tick_ref = Process.send_after(self(), :tick, tick_interval)

    state = %__MODULE__{
      transport: transport,
      mode: mode,
      ll_params: ll_params,
      al_params: al_params,
      link_layer: link_layer,
      class_1_queue: Queue.new(c1_size),
      class_2_queue: Queue.new(c2_size),
      link_address: link_address,
      other_station_address: other_station_address,
      dir: dir,
      owner: Keyword.get(opts, :owner),
      interrogation_handler: Keyword.get(opts, :interrogation_handler),
      counter_interrogation_handler: Keyword.get(opts, :counter_interrogation_handler),
      read_handler: Keyword.get(opts, :read_handler),
      clock_sync_handler: Keyword.get(opts, :clock_sync_handler),
      reset_process_handler: Keyword.get(opts, :reset_process_handler),
      delay_acquisition_handler: Keyword.get(opts, :delay_acquisition_handler),
      reset_cu_handler: Keyword.get(opts, :reset_cu_handler),
      asdu_handler: Keyword.get(opts, :asdu_handler),
      is_ca_allowed_handler: Keyword.get(opts, :is_ca_allowed_handler),
      link_state_handler: Keyword.get(opts, :link_state_handler),
      raw_message_handler: Keyword.get(opts, :raw_message_handler),
      tick_interval_ms: tick_interval,
      tick_ref: tick_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue_class_1, asdu}, _from, state) do
    state = do_enqueue_class_1(state, asdu)
    {:reply, :ok, state}
  end

  def handle_call({:send_asdu, asdu}, _from, state) do
    state = do_enqueue_class_1(state, asdu)
    {:reply, :ok, state}
  end

  def handle_call({:enqueue_class_2, asdu}, _from, state) do
    state = do_enqueue_class_2(state, asdu)
    {:reply, :ok, state}
  end

  def handle_call(:flush_queues, _from, state) do
    {:reply, :ok,
     %{
       state
       | class_1_queue: Queue.flush(state.class_1_queue),
         class_2_queue: Queue.flush(state.class_2_queue)
     }}
  end

  def handle_call(:is_class_1_full, _from, state) do
    {:reply, Queue.full?(state.class_1_queue), state}
  end

  def handle_call(:is_class_2_full, _from, state) do
    {:reply, Queue.full?(state.class_2_queue), state}
  end

  def handle_call(:is_active, _from, state), do: {:reply, true, state}

  def handle_call(:get_peer_address, _from, state) do
    {:reply, {:ok, {"serial", state.link_address}}, state}
  end

  def handle_call({:set_dir, dir}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | dir: dir}
        _ -> state.link_layer
      end

    {:reply, :ok, %{state | dir: dir, link_layer: ll}}
  end

  def handle_call({:set_idle_timeout, timeout_ms}, _from, state) do
    ll = %{state.link_layer | idle_timeout: timeout_ms}
    {:reply, :ok, %{state | link_layer: ll}}
  end

  def handle_call({:set_link_address, addr}, _from, state) do
    ll = %{state.link_layer | address: addr}
    {:reply, :ok, %{state | link_address: addr, link_layer: ll}}
  end

  def handle_call({:set_other_station_address, addr}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | other_station_address: addr}
        _ -> state.link_layer
      end

    {:reply, :ok, %{state | other_station_address: addr, link_layer: ll}}
  end

  def handle_call(:get_al_params, _from, state), do: {:reply, state.al_params, state}
  def handle_call(:get_ll_params, _from, state), do: {:reply, state.ll_params, state}

  @impl true
  def handle_info({:internal_send_asdu, asdu}, state) do
    {:noreply, do_enqueue_class_1(state, asdu)}
  end

  def handle_info({:internal_enqueue_class_1, asdu}, state) do
    {:noreply, do_enqueue_class_1(state, asdu)}
  end

  def handle_info({:internal_enqueue_class_2, asdu}, state) do
    {:noreply, do_enqueue_class_2(state, asdu)}
  end

  def handle_info({:cs101_transport_data, _ref, data}, state) do
    {:noreply, handle_incoming_bytes(state, data)}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {:noreply, handle_incoming_bytes(state, data)}
  end

  def handle_info(:tick, state) do
    state = step_link_layer(state)
    tick_ref = Process.send_after(self(), :tick, state.tick_interval_ms)
    {:noreply, %{state | tick_ref: tick_ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Internal Logic
  # ===========================================================================

  defp do_enqueue_class_1(state, asdu) do
    {:ok, q} = Queue.enqueue(state.class_1_queue, asdu)
    %{state | class_1_queue: q}
  end

  defp do_enqueue_class_2(state, asdu) do
    {:ok, q} = Queue.enqueue(state.class_2_queue, asdu)
    %{state | class_2_queue: q}
  end

  defp flush_internal_mailbox(state) do
    receive do
      {:internal_send_asdu, asdu} ->
        state |> do_enqueue_class_1(asdu) |> flush_internal_mailbox()

      {:internal_enqueue_class_1, asdu} ->
        state |> do_enqueue_class_1(asdu) |> flush_internal_mailbox()

      {:internal_enqueue_class_2, asdu} ->
        state |> do_enqueue_class_2(asdu) |> flush_internal_mailbox()
    after
      0 -> state
    end
  end

  defp handle_incoming_bytes(state, data) do
    Telemetry.execute([:iec60870, :cs101, :raw_message], %{byte_size: byte_size(data)}, %{
      pid: self(),
      direction: :received,
      bytes: data
    })

    if state.raw_message_handler do
      state.raw_message_handler.(self(), data, false)
    end

    buf = state.recv_buffer <> data

    case Frame.extract_frames(buf, state.ll_params.address_length) do
      {:ok, frames, rest} ->
        state1 = Enum.reduce(frames, %{state | recv_buffer: rest}, &process_frame(&2, &1))
        step_link_layer(state1)

      {:error, _reason, rest} ->
        %{state | recv_buffer: rest}
    end
  end

  defp process_frame(%{mode: :unbalanced} = state, frame) do
    now = now_ms()

    callbacks = %{
      is_class_1_available: fn st ->
        not Queue.empty?(st.class_1_queue)
      end,
      pop_class_1_data: fn st ->
        pop_encoded_from_queue(st, :class_1_queue)
      end,
      pop_class_2_data: fn st ->
        # Matches GetClass2Data in cs101_slave.c:314-377:
        # Pop only from Class 2 queue; if empty, return nil so link layer responds with
        # FC=9 (RESP_NACK_NO_DATA) with ACD = is_class_1_available(st) (or 0xE5 if !ACD).
        pop_encoded_from_queue(st, :class_2_queue)
      end,
      handle_user_data: fn st, asdu_bin, _is_bcast ->
        case ASDU.decode(asdu_bin, st.al_params) do
          {:ok, asdu} ->
            st |> handle_received_asdu(asdu) |> flush_internal_mailbox()

          {:error, _} ->
            st
        end
      end,
      reset_cu_received: fn st, only_fcb? ->
        if not only_fcb? and is_function(st.reset_cu_handler, 1) do
          st.reset_cu_handler.(self())
        end

        flush_internal_mailbox(st)
      end
    }

    {sll, state1, frames_to_send, state_changes} =
      SecondaryUnbalanced.handle_frame(state.link_layer, frame, state, callbacks, now)

    state2 = %{state1 | link_layer: sll}
    send_frames(state2, frames_to_send)

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state2, addr, new_ls)
    end)

    state2
  end

  defp process_frame(%{mode: :balanced} = state, frame) do
    now = now_ms()

    callbacks = %{
      handle_user_data: fn st, asdu_bin ->
        case ASDU.decode(asdu_bin, st.al_params) do
          {:ok, asdu} ->
            st |> handle_received_asdu(asdu) |> flush_internal_mailbox()

          {:error, _} ->
            st
        end
      end
    }

    {bll, state1, frames_to_send, state_changes} =
      Balanced.handle_frame(state.link_layer, frame, state, callbacks, now)

    state2 = %{state1 | link_layer: bll}
    send_frames(state2, frames_to_send)

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state2, addr, new_ls)
    end)

    state2
  end

  defp step_link_layer(%{mode: :unbalanced} = state) do
    now = now_ms()
    {sll, state_changes} = SecondaryUnbalanced.check_idle_timeout(state.link_layer, now)
    state = %{state | link_layer: sll}

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state, addr, new_ls)
    end)

    state
  end

  defp step_link_layer(%{mode: :balanced} = state) do
    now = now_ms()

    pop_fun = fn st ->
      case pop_encoded_from_queue(st, :class_1_queue) do
        {nil, st1} -> pop_encoded_from_queue(st1, :class_2_queue)
        other -> other
      end
    end

    {bll, state1, frames_to_send, state_changes} =
      Balanced.run(state.link_layer, state, pop_fun, now)

    state2 = %{state1 | link_layer: bll}
    send_frames(state2, frames_to_send)

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state2, addr, new_ls)
    end)

    state2
  end

  defp pop_encoded_from_queue(state, field) do
    q = Map.fetch!(state, field)

    case Queue.dequeue(q) do
      {:ok, asdu, next_q} ->
        state1 = Map.put(state, field, next_q)

        case ASDU.encode(asdu, state1.al_params) do
          {:ok, bin} -> {bin, state1}
          {:error, _} -> {nil, state1}
        end

      :empty ->
        {nil, state}
    end
  end

  # ===========================================================================
  # Application Layer Dispatch (`handleASDU` in `cs101_slave.c`)
  # ===========================================================================

  defp handle_received_asdu(state, %ASDU{} = asdu) do
    Telemetry.execute(
      [:iec60870, :cs101, :asdu],
      %{count: 1, num_elements: length(asdu.objects || [])},
      %{
        pid: self(),
        direction: :received,
        slave_address: state.link_address,
        type_id: asdu.type_id,
        cot: asdu.cot,
        ca: asdu.ca,
        asdu: asdu
      }
    )

    ca = asdu.ca

    if is_function(state.is_ca_allowed_handler, 1) and not broadcast_ca?(state, ca) and
         not state.is_ca_allowed_handler.(ca) do
      enqueue_negative_response(state, asdu, :unknown_ca)
    else
      dispatch_asdu(state, asdu)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_ic_na_1, cot: cot} = asdu) do
    if cot in [:activation, :deactivation] do
      case state.interrogation_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              enqueue_negative_response(state, asdu, :unknown_ioa)

            %{qoi: qoi} ->
              if handler.(self(), asdu, qoi),
                do: state,
                else: fallback_to_asdu_handler(state, asdu)

            _ ->
              state
          end
      end
    else
      enqueue_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_ci_na_1, cot: cot} = asdu) do
    if cot in [:activation, :deactivation] do
      case state.counter_interrogation_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              enqueue_negative_response(state, asdu, :unknown_ioa)

            %{qcc: qcc} ->
              if handler.(self(), asdu, qcc),
                do: state,
                else: fallback_to_asdu_handler(state, asdu)

            _ ->
              state
          end
      end
    else
      enqueue_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_rd_na_1, cot: cot, ca: ca} = asdu) do
    cond do
      broadcast_ca?(state, ca) ->
        enqueue_negative_response(state, asdu, :unknown_ca)

      cot != :request ->
        enqueue_negative_response(state, asdu, :unknown_cot)

      state.read_handler != nil ->
        case List.first(asdu.objects) do
          %{ioa: ioa} ->
            if state.read_handler.(self(), asdu, ioa),
              do: state,
              else: fallback_to_asdu_handler(state, asdu)

          _ ->
            state
        end

      true ->
        fallback_to_asdu_handler(state, asdu)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_cs_na_1, cot: cot} = asdu) do
    if cot == :activation do
      case state.clock_sync_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              enqueue_negative_response(state, asdu, :unknown_ioa)

            %{timestamp: %CP56Time2a{} = ts} ->
              case handler.(self(), asdu, ts) do
                true ->
                  resp_io = SystemIO.clock_sync_command(0, ts)
                  resp = %{asdu | cot: :activation_con, is_negative: false, objects: [resp_io]}
                  do_enqueue_class_1(state, resp)

                {:ok, %CP56Time2a{} = updated_ts} ->
                  resp_io = SystemIO.clock_sync_command(0, updated_ts)
                  resp = %{asdu | cot: :activation_con, is_negative: false, objects: [resp_io]}
                  do_enqueue_class_1(state, resp)

                false ->
                  enqueue_negative_response(state, asdu, :activation_con)
              end

            _ ->
              state
          end
      end
    else
      enqueue_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: tc_type, cot: cot, ca: ca} = asdu)
       when tc_type in [:c_ts_na_1, :c_ts_ta_1] do
    cond do
      broadcast_ca?(state, ca) ->
        enqueue_negative_response(state, asdu, :unknown_ca)

      cot != :activation ->
        enqueue_negative_response(state, asdu, :unknown_cot)

      true ->
        case List.first(asdu.objects) do
          %{ioa: ioa} when ioa != 0 ->
            enqueue_negative_response(state, asdu, :unknown_ioa)

          %{} ->
            do_enqueue_class_1(state, %{asdu | cot: :activation_con, is_negative: false})

          _ ->
            state
        end
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_rp_na_1, cot: cot} = asdu) do
    if cot == :activation do
      case state.reset_process_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              enqueue_negative_response(state, asdu, :unknown_ioa)

            %{qrp: qrp} ->
              if handler.(self(), asdu, qrp),
                do: state,
                else: fallback_to_asdu_handler(state, asdu)

            _ ->
              state
          end
      end
    else
      enqueue_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu(state, %ASDU{type_id: :c_cd_na_1, cot: cot, ca: ca} = asdu) do
    cond do
      broadcast_ca?(state, ca) ->
        enqueue_negative_response(state, asdu, :unknown_ca)

      cot not in [:activation, :spontaneous] ->
        enqueue_negative_response(state, asdu, :unknown_cot)

      state.delay_acquisition_handler != nil ->
        case List.first(asdu.objects) do
          %{ioa: ioa} when ioa != 0 ->
            enqueue_negative_response(state, asdu, :unknown_ioa)

          %{delay: %{elapsed_time_ms: delay_ms}} ->
            if state.delay_acquisition_handler.(self(), asdu, delay_ms),
              do: state,
              else: fallback_to_asdu_handler(state, asdu)

          _ ->
            state
        end

      true ->
        fallback_to_asdu_handler(state, asdu)
    end
  end

  defp dispatch_asdu(state, asdu) do
    fallback_to_asdu_handler(state, asdu)
  end

  defp fallback_to_asdu_handler(state, asdu) do
    handled? =
      cond do
        is_function(state.asdu_handler, 2) ->
          state.asdu_handler.(self(), asdu)

        is_pid(state.owner) ->
          send(state.owner, {:iec60870_cs101_slave, self(), {:asdu, asdu}})
          true

        true ->
          false
      end

    if handled? do
      state
    else
      enqueue_negative_response(state, asdu, :unknown_type_id)
    end
  end

  defp enqueue_negative_response(state, asdu, cot) do
    do_enqueue_class_1(state, %{asdu | cot: cot, is_negative: true})
  end

  defp broadcast_ca?(state, ca) do
    case state.al_params.size_of_ca do
      2 -> ca == 65535
      _ -> ca == 255
    end
  end

  defp send_frames(state, frames) do
    Enum.each(frames, fn frame ->
      case Frame.encode(frame, state.ll_params.address_length) do
        {:ok, bin} ->
          Telemetry.execute([:iec60870, :cs101, :raw_message], %{byte_size: byte_size(bin)}, %{
            pid: self(),
            direction: :sent,
            bytes: bin
          })

          if state.raw_message_handler do
            state.raw_message_handler.(self(), bin, true)
          end

          Transport.send_data(state.transport, bin)

        {:error, _} ->
          :ok
      end
    end)
  end

  defp notify_link_state(state, addr, new_state) do
    Telemetry.execute([:iec60870, :cs101, :link_state], %{system_time: System.system_time()}, %{
      pid: self(),
      address: addr,
      link_state: new_state
    })

    if is_function(state.link_state_handler, 3) do
      state.link_state_handler.(self(), addr, new_state)
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs101_slave, self(), {:link_state, addr, new_state}})
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
