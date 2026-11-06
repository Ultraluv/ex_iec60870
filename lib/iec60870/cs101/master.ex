defmodule IEC60870.CS101.Master do
  @moduledoc """
  IEC 60870-5-101 Master (`cs101_master.c`), supporting both `:balanced` and `:unbalanced` link layer modes.

  Features:
  - Multi-slave polling and addressing in `:unbalanced` mode (`add_slave/2`, `use_slave_address/2`, `poll_single_slave/2`, `request_class_1_data/2`, `request_class_2_data/2`)
  - Automatic Class 1 polling when `ACD` (Access Demand) bit is set by a slave
  - Full-duplex peer-to-peer transmission in `:balanced` mode (`DIR = true` by default)
  - Convenience command functions (`send_interrogation_command/4`, `send_clock_sync_command/3`, `send_process_command/4`, `send_asdu/2`, etc.)
  """

  use GenServer

  alias IEC60870.{AppLayerParameters, ASDU, InformationObject, LinkLayerParameters}
  alias IEC60870.CS101.{Frame, Queue, Transport}
  alias IEC60870.CS101.LinkLayer.{Balanced, PrimaryUnbalanced}
  alias IEC60870.IO.System, as: SystemIO
  alias IEC60870.Telemetry
  alias IEC60870.Types.CPTime.CP56Time2a

  @type mode :: :balanced | :unbalanced

  defstruct [
    :transport,
    :mode,
    :ll_params,
    :al_params,
    :link_layer,
    :user_data_queue,
    :owner,
    :asdu_handler,
    :link_state_handler,
    :raw_message_handler,
    :tick_ref,
    own_address: 0,
    slave_address: 1,
    dir: true,
    recv_buffer: <<>>,
    tick_interval_ms: 20
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a `CS101.Master` GenServer.

  Options:
  - `:transport` (required) - `{transport_mod, handle}` (e.g. `VirtualBus.attach(bus)`)
  - `:mode` - `:unbalanced` or `:balanced` (default `:unbalanced`)
  - `:ll_params` - `%IEC60870.LinkLayerParameters{}`
  - `:al_params` - `%IEC60870.AppLayerParameters{}`
  - `:own_address` - own link layer address for balanced mode (default `0`)
  - `:slave_address` - default target slave link address (default `1`)
  - `:slaves` - list of slave link addresses to register initially in unbalanced mode
  - `:dir` - `DIR` bit in balanced mode (default `true`)
  - `:queue_size` - max ASDU queue size in balanced mode (default `100`)
  - `:owner` - PID to receive `{:iec60870_cs101_master, master_pid, event}` messages
  - `:asdu_handler` - `fn master_pid, slave_addr, asdu -> any() end`
  - `:link_state_handler` - `fn master_pid, slave_addr, new_state -> any() end`
  - `:raw_message_handler` - `fn master_pid, bytes, sent? -> any() end`
  """
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec add_slave(GenServer.server(), non_neg_integer()) :: :ok
  def add_slave(master, slave_address) do
    GenServer.call(master, {:add_slave, slave_address})
  end

  @spec use_slave_address(GenServer.server(), non_neg_integer()) :: :ok
  def use_slave_address(master, slave_address) do
    GenServer.call(master, {:use_slave_address, slave_address})
  end

  @spec poll_single_slave(GenServer.server(), non_neg_integer()) :: :ok
  def poll_single_slave(master, slave_address) do
    GenServer.call(master, {:request_class_2, slave_address})
  end

  @spec request_class_1_data(GenServer.server(), non_neg_integer()) :: :ok
  def request_class_1_data(master, slave_address) do
    GenServer.call(master, {:request_class_1, slave_address})
  end

  @spec request_class_2_data(GenServer.server(), non_neg_integer()) :: :ok
  def request_class_2_data(master, slave_address) do
    GenServer.call(master, {:request_class_2, slave_address})
  end

  @spec is_channel_ready?(GenServer.server(), non_neg_integer()) :: boolean()
  def is_channel_ready?(master, slave_address) do
    GenServer.call(master, {:is_channel_ready, slave_address})
  end

  @spec send_link_layer_test_function(GenServer.server()) :: :ok
  def send_link_layer_test_function(master) do
    GenServer.call(master, :send_link_test)
  end

  @spec send_asdu(GenServer.server(), ASDU.t(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def send_asdu(master, %ASDU{} = asdu, slave_address \\ nil) do
    GenServer.call(master, {:send_asdu, asdu, slave_address})
  end

  def send_interrogation_command(master, cot \\ :activation, ca, qoi \\ 20) do
    io = SystemIO.interrogation_command(0, qoi)
    send_process_command(master, cot, ca, io)
  end

  def send_counter_interrogation_command(master, cot \\ :activation, ca, qcc \\ 5) do
    io = SystemIO.counter_interrogation_command(0, qcc)
    send_process_command(master, cot, ca, io)
  end

  def send_read_command(master, ca, ioa) do
    io = SystemIO.read_command(ioa)
    send_process_command(master, :request, ca, io)
  end

  def send_clock_sync_command(master, ca, %CP56Time2a{} = new_time) do
    io = SystemIO.clock_sync_command(0, new_time)
    send_process_command(master, :activation, ca, io)
  end

  def send_test_command(master, ca) do
    io = SystemIO.test_command(0)
    send_process_command(master, :activation, ca, io)
  end

  def send_process_command(master, cot, ca, io, slave_address \\ nil) when is_struct(io) do
    GenServer.call(master, {:send_process_command, cot, ca, io, slave_address})
  end

  @doc """
  Sets the DIR bit in balanced link layer mode.
  """
  @spec set_dir(GenServer.server(), boolean()) :: :ok
  def set_dir(master, dir) when is_boolean(dir), do: GenServer.call(master, {:set_dir, dir})

  @doc """
  Sets own link layer address in balanced mode.
  """
  @spec set_own_address(GenServer.server(), non_neg_integer()) :: :ok
  def set_own_address(master, address) when is_integer(address) and address >= 0,
    do: GenServer.call(master, {:set_own_address, address})

  @doc """
  Sets idle timeout in milliseconds.
  """
  @spec set_idle_timeout(GenServer.server(), pos_integer()) :: :ok
  def set_idle_timeout(master, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: GenServer.call(master, {:set_idle_timeout, timeout_ms})

  @spec get_app_layer_parameters(GenServer.server()) :: AppLayerParameters.t()
  def get_app_layer_parameters(master), do: GenServer.call(master, :get_al_params)

  @spec get_link_layer_parameters(GenServer.server()) :: LinkLayerParameters.t()
  def get_link_layer_parameters(master), do: GenServer.call(master, :get_ll_params)

  @spec start(GenServer.server()) :: :ok
  def start(_master), do: :ok

  @spec stop(GenServer.server()) :: :ok
  def stop(master), do: GenServer.stop(master, :normal)

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    mode = Keyword.get(opts, :mode, :unbalanced)
    ll_params = Keyword.get(opts, :ll_params, %LinkLayerParameters{})
    al_params = Keyword.get(opts, :al_params, %AppLayerParameters{max_size_of_asdu: 249})
    own_address = Keyword.get(opts, :own_address, 0)
    slave_address = Keyword.get(opts, :slave_address, 1)
    dir = Keyword.get(opts, :dir, true)
    queue_size = Keyword.get(opts, :queue_size, 100)
    tick_interval = Keyword.get(opts, :tick_interval_ms, 20)

    # If transport is a VirtualBus pid, attach this process
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
          pll = PrimaryUnbalanced.new(ll_params)
          initial_slaves = Keyword.get(opts, :slaves, [])

          Enum.reduce(initial_slaves, pll, fn addr, acc ->
            PrimaryUnbalanced.add_slave(acc, addr)
          end)

        :balanced ->
          Balanced.new(own_address, slave_address, dir, ll_params, ll_params.timeout_link_state)
      end

    tick_ref = Process.send_after(self(), :tick, tick_interval)

    state = %__MODULE__{
      transport: transport,
      mode: mode,
      ll_params: ll_params,
      al_params: al_params,
      link_layer: link_layer,
      user_data_queue: Queue.new(queue_size),
      own_address: own_address,
      slave_address: slave_address,
      dir: dir,
      owner: Keyword.get(opts, :owner),
      asdu_handler: Keyword.get(opts, :asdu_handler),
      link_state_handler: Keyword.get(opts, :link_state_handler),
      raw_message_handler: Keyword.get(opts, :raw_message_handler),
      tick_interval_ms: tick_interval,
      tick_ref: tick_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_slave, addr}, _from, %{mode: :unbalanced} = state) do
    pll = PrimaryUnbalanced.add_slave(state.link_layer, addr)
    state = step_link_layer(%{state | link_layer: pll})
    {:reply, :ok, state}
  end

  def handle_call({:add_slave, _addr}, _from, state), do: {:reply, :ok, state}

  def handle_call({:use_slave_address, addr}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | other_station_address: addr}
        :unbalanced -> PrimaryUnbalanced.add_slave(state.link_layer, addr)
      end

    {:reply, :ok, %{state | slave_address: addr, link_layer: ll}}
  end

  def handle_call({:request_class_1, addr}, _from, %{mode: :unbalanced} = state) do
    pll =
      state.link_layer
      |> PrimaryUnbalanced.add_slave(addr)
      |> PrimaryUnbalanced.request_class_1(addr)

    state = step_link_layer(%{state | link_layer: pll})
    {:reply, :ok, state}
  end

  def handle_call({:request_class_1, _addr}, _from, state), do: {:reply, :ok, state}

  def handle_call({:request_class_2, addr}, _from, %{mode: :unbalanced} = state) do
    pll =
      state.link_layer
      |> PrimaryUnbalanced.add_slave(addr)
      |> PrimaryUnbalanced.request_class_2(addr)

    state = step_link_layer(%{state | link_layer: pll})
    {:reply, :ok, state}
  end

  def handle_call({:request_class_2, _addr}, _from, state), do: {:reply, :ok, state}

  def handle_call({:is_channel_ready, addr}, _from, %{mode: :unbalanced} = state) do
    {:reply, PrimaryUnbalanced.is_channel_available?(state.link_layer, addr), state}
  end

  def handle_call({:is_channel_ready, _addr}, _from, state) do
    {:reply, not Queue.full?(state.user_data_queue), state}
  end

  def handle_call(:send_link_test, _from, %{mode: :unbalanced} = state) do
    pll = PrimaryUnbalanced.send_link_test(state.link_layer, state.slave_address)
    {:reply, :ok, step_link_layer(%{state | link_layer: pll})}
  end

  def handle_call(:send_link_test, _from, %{mode: :balanced} = state) do
    bll = %{state.link_layer | send_link_test: true}
    {:reply, :ok, step_link_layer(%{state | link_layer: bll})}
  end

  def handle_call({:send_process_command, cot, ca, io, target_addr}, _from, state) do
    asdu =
      ASDU.new(InformationObject.type_id(io),
        cot: cot,
        oa: state.al_params.originator_address,
        ca: ca,
        objects: [io]
      )

    addr = target_addr || state.slave_address

    case do_send_asdu(state, asdu, addr) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:send_process_command, cot, ca, io}, from, state) do
    handle_call({:send_process_command, cot, ca, io, nil}, from, state)
  end

  def handle_call({:send_asdu, asdu, target_addr}, _from, state) do
    addr = target_addr || state.slave_address

    case do_send_asdu(state, asdu, addr) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:set_dir, dir}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | dir: dir}
        _ -> state.link_layer
      end

    {:reply, :ok, %{state | dir: dir, link_layer: ll}}
  end

  def handle_call({:set_own_address, addr}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | address: addr}
        _ -> state.link_layer
      end

    {:reply, :ok, %{state | own_address: addr, link_layer: ll}}
  end

  def handle_call({:set_idle_timeout, timeout_ms}, _from, state) do
    ll =
      case state.mode do
        :balanced -> %{state.link_layer | idle_timeout: timeout_ms}
        _ -> state.link_layer
      end

    {:reply, :ok, %{state | link_layer: ll}}
  end

  def handle_call(:get_al_params, _from, state), do: {:reply, state.al_params, state}
  def handle_call(:get_ll_params, _from, state), do: {:reply, state.ll_params, state}

  @impl true
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

  defp do_send_asdu(%{mode: :unbalanced} = state, asdu, slave_addr) do
    case ASDU.encode(asdu, state.al_params) do
      {:ok, asdu_bin} ->
        pll =
          if IEC60870.CS101.LinkLayer.is_broadcast?(state.ll_params, slave_addr) do
            PrimaryUnbalanced.enqueue_no_reply(state.link_layer, slave_addr, asdu_bin)
          else
            PrimaryUnbalanced.enqueue_confirmed(state.link_layer, slave_addr, asdu_bin)
          end

        {:ok, step_link_layer(%{state | link_layer: pll})}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_send_asdu(%{mode: :balanced} = state, asdu, _slave_addr) do
    {:ok, new_q} = Queue.enqueue(state.user_data_queue, asdu)
    {:ok, step_link_layer(%{state | user_data_queue: new_q})}
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

    {pll, user_data_events, state_changes} =
      PrimaryUnbalanced.handle_frame(state.link_layer, frame, now)

    state = %{state | link_layer: pll}

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state, addr, new_ls)
    end)

    Enum.each(user_data_events, fn {addr, asdu_bin} ->
      case ASDU.decode(asdu_bin, state.al_params) do
        {:ok, asdu} -> notify_asdu(state, addr, asdu)
        {:error, _} -> :ok
      end
    end)

    state
  end

  defp process_frame(%{mode: :balanced} = state, frame) do
    now = now_ms()

    callbacks = %{
      handle_user_data: fn st, asdu_bin ->
        case ASDU.decode(asdu_bin, st.al_params) do
          {:ok, asdu} -> notify_asdu(st, 0, asdu)
          {:error, _} -> :ok
        end

        st
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
    {pll, frames_to_send, state_changes} = PrimaryUnbalanced.run(state.link_layer, now)
    state = %{state | link_layer: pll}
    send_frames(state, frames_to_send)

    Enum.each(state_changes, fn {addr, new_ls} ->
      notify_link_state(state, addr, new_ls)
    end)

    state
  end

  defp step_link_layer(%{mode: :balanced} = state) do
    now = now_ms()

    pop_fun = fn st ->
      case Queue.dequeue(st.user_data_queue) do
        {:ok, asdu, next_q} ->
          case ASDU.encode(asdu, st.al_params) do
            {:ok, bin} -> {bin, %{st | user_data_queue: next_q}}
            {:error, _} -> {nil, %{st | user_data_queue: next_q}}
          end

        :empty ->
          {nil, st}
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

  defp notify_asdu(state, slave_addr, asdu) do
    Telemetry.execute(
      [:iec60870, :cs101, :asdu],
      %{count: 1, num_elements: length(asdu.objects || [])},
      %{
        pid: self(),
        direction: :received,
        slave_address: slave_addr,
        type_id: asdu.type_id,
        cot: asdu.cot,
        ca: asdu.ca,
        asdu: asdu
      }
    )

    if is_function(state.asdu_handler, 3) do
      state.asdu_handler.(self(), slave_addr, asdu)
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs101_master, self(), {:asdu, slave_addr, asdu}})
    end
  end

  defp notify_link_state(state, slave_addr, new_state) do
    Telemetry.execute([:iec60870, :cs101, :link_state], %{system_time: System.system_time()}, %{
      pid: self(),
      address: slave_addr,
      link_state: new_state
    })

    if is_function(state.link_state_handler, 3) do
      state.link_state_handler.(self(), slave_addr, new_state)
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs101_master, self(), {:link_state, slave_addr, new_state}})
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
