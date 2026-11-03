defmodule IEC60870.CS104.Connection do
  @moduledoc """
  IEC 60870-5-104 Client / Master Connection (`GenServer`), equivalent to `cs104_connection.c`.

  Manages:
  - TCP / TLS socket connection (`:gen_tcp` / `:ssl`)
  - `STARTDT` / `STOPDT` / `TESTFR` state transitions
  - 15-bit `N(S)` and `N(R)` sequence numbers and `k` / `w` sliding window
  - `T0`, `T1`, `T2`, `T3` timers
  - Helper command methods (`send_interrogation_command/4`, `send_clock_sync_command/3`, etc.)
  """

  use GenServer

  alias IEC60870.{APCIParameters, AppLayerParameters, ASDU, InformationObject}
  alias IEC60870.CS104.Frame
  alias IEC60870.IO.System, as: SystemIO
  alias IEC60870.Telemetry
  alias IEC60870.Types.CPTime.CP56Time2a

  @type connection_event ::
          :opened
          | :closed
          | :startdt_con_received
          | :stopdt_con_received
          | :failed

  @type state_name ::
          :idle
          | :inactive
          | :waiting_for_startdt_con
          | :active
          | :waiting_for_stopdt_con

  defstruct [
    :host,
    :port,
    :local_ip,
    :local_port,
    :tls_opts,
    :socket,
    :transport,
    :apci_params,
    :al_params,
    :owner,
    :connection_handler,
    :asdu_handler,
    :raw_message_handler,
    :tick_ref,
    con_state: :idle,
    recv_buffer: <<>>,
    send_count: 0,
    receive_count: 0,
    unconfirmed_received_i_msgs: 0,
    timeout_t2_triggered: false,
    last_confirmation_time: 0,
    next_t3_timeout: 0,
    u_message_timeout: 0,
    outstanding_testfr_con_msgs: 0,
    sent_asdus: []
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a `CS104.Connection` process.

  Options:
  - `:host` - remote IP or hostname (default `"127.0.0.1"`)
  - `:port` - remote TCP port (default `2404`, or `19998` if `:tls_opts` is given)
  - `:local_ip` - optional local bind address
  - `:local_port` - optional local bind port (default `0`)
  - `:tls_opts` - optional `:ssl` options list for TLS connections
  - `:apci_params` - `%IEC60870.APCIParameters{}`
  - `:al_params` - `%IEC60870.AppLayerParameters{}`
  - `:owner` - PID to receive `{:iec60870_cs104, pid, event}` messages
  - `:connection_handler` - `fn conn_pid, event -> any() end`
  - `:asdu_handler` - `fn conn_pid, asdu -> any() end`
  - `:raw_message_handler` - `fn conn_pid, raw_bytes, sent? -> any() end`
  - `:auto_connect` - boolean (default `false`)
  - `:name` - GenServer registration name
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec connect(GenServer.server()) :: :ok | {:error, term()}
  def connect(conn), do: GenServer.call(conn, :connect, 35_000)

  @spec connect_async(GenServer.server()) :: :ok
  def connect_async(conn), do: GenServer.cast(conn, :connect_async)

  @spec close(GenServer.server()) :: :ok
  def close(conn), do: GenServer.call(conn, :close)

  @spec send_start_dt(GenServer.server()) :: :ok | {:error, term()}
  def send_start_dt(conn), do: GenServer.call(conn, :send_start_dt)

  @spec send_stop_dt(GenServer.server()) :: :ok | {:error, term()}
  def send_stop_dt(conn), do: GenServer.call(conn, :send_stop_dt)

  @spec send_test_fr(GenServer.server()) :: :ok | {:error, term()}
  def send_test_fr(conn), do: GenServer.call(conn, :send_test_fr)

  @spec send_asdu(GenServer.server(), ASDU.t()) :: :ok | {:error, term()}
  def send_asdu(conn, %ASDU{} = asdu), do: GenServer.call(conn, {:send_asdu, asdu})

  @spec is_transmit_buffer_full?(GenServer.server()) :: boolean()
  def is_transmit_buffer_full?(conn), do: GenServer.call(conn, :is_transmit_buffer_full)

  @spec is_connected?(GenServer.server()) :: boolean()
  def is_connected?(conn), do: GenServer.call(conn, :is_connected)

  @spec set_originator_address(GenServer.server(), non_neg_integer()) :: :ok
  def set_originator_address(conn, oa) when is_integer(oa) and oa in 0..255 do
    GenServer.call(conn, {:set_originator_address, oa})
  end

  @spec get_apci_parameters(GenServer.server()) :: APCIParameters.t()
  def get_apci_parameters(conn), do: GenServer.call(conn, :get_apci_params)

  @spec set_apci_parameters(GenServer.server(), APCIParameters.t()) :: :ok
  def set_apci_parameters(conn, %APCIParameters{} = params),
    do: GenServer.call(conn, {:set_apci_params, params})

  @spec get_app_layer_parameters(GenServer.server()) :: AppLayerParameters.t()
  def get_app_layer_parameters(conn), do: GenServer.call(conn, :get_al_params)

  @spec set_app_layer_parameters(GenServer.server(), AppLayerParameters.t()) :: :ok
  def set_app_layer_parameters(conn, %AppLayerParameters{} = params),
    do: GenServer.call(conn, {:set_al_params, params})

  @doc """
  Sets or updates the ASDU received handler on the connection. Matches `CS104_Connection_setASDUReceivedHandler`.
  """
  @spec set_asdu_handler(
          GenServer.server(),
          (pid(), ASDU.t() -> any()) | (ASDU.t() -> any()) | nil
        ) :: :ok
  def set_asdu_handler(conn, handler) when is_function(handler) or is_nil(handler) do
    GenServer.call(conn, {:set_asdu_handler, handler})
  end

  @doc """
  Sets or updates the connection event handler on the connection. Matches `CS104_Connection_setConnectionHandler`.
  """
  @spec set_connection_handler(
          GenServer.server(),
          (pid(), atom() -> any()) | (atom() -> any()) | nil
        ) :: :ok
  def set_connection_handler(conn, handler) when is_function(handler) or is_nil(handler) do
    GenServer.call(conn, {:set_connection_handler, handler})
  end

  @spec get_state(GenServer.server()) :: map()
  def get_state(conn), do: GenServer.call(conn, :get_state)

  @doc """
  Sends `C_IC_NA_1` (TypeID 100) interrogation command.
  """
  def send_interrogation_command(conn, cot \\ :activation, ca, qoi \\ 20) do
    io = SystemIO.interrogation_command(0, qoi)
    send_process_command(conn, cot, ca, io)
  end

  @doc """
  Sends `C_CI_NA_1` (TypeID 101) counter interrogation command.
  """
  def send_counter_interrogation_command(conn, cot \\ :activation, ca, qcc \\ 5) do
    io = SystemIO.counter_interrogation_command(0, qcc)
    send_process_command(conn, cot, ca, io)
  end

  @doc """
  Sends `C_RD_NA_1` (TypeID 102) read command.
  """
  def send_read_command(conn, ca, ioa) do
    io = SystemIO.read_command(ioa)
    send_process_command(conn, :request, ca, io)
  end

  @doc """
  Sends `C_CS_NA_1` (TypeID 103) clock synchronization command.
  """
  def send_clock_sync_command(conn, ca, %CP56Time2a{} = new_time) do
    io = SystemIO.clock_sync_command(0, new_time)
    send_process_command(conn, :activation, ca, io)
  end

  @doc """
  Sends `C_TS_NA_1` (TypeID 104) test command.
  """
  def send_test_command(conn, ca) do
    io = SystemIO.test_command(0)
    send_process_command(conn, :activation, ca, io)
  end

  @doc """
  Sends `C_TS_TA_1` (TypeID 107) test command with CP56Time2a timestamp.
  """
  def send_test_command_with_timestamp(conn, ca, tsc, %CP56Time2a{} = timestamp) do
    io = SystemIO.test_command_with_cp56time2a(0, tsc, timestamp)
    send_process_command(conn, :activation, ca, io)
  end

  @doc """
  Sends a process command InformationObject wrapped in an ASDU.
  """
  def send_process_command(conn, cot, ca, io) when is_struct(io) do
    GenServer.call(conn, {:send_process_command, nil, cot, ca, io})
  end

  def send_process_command(conn, type_id, cot, ca, io) when is_struct(io) do
    GenServer.call(conn, {:send_process_command, type_id, cot, ca, io})
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    tls_opts = Keyword.get(opts, :tls_opts)
    default_port = if tls_opts, do: 19998, else: 2404

    state = %__MODULE__{
      host: Keyword.get(opts, :host, "127.0.0.1"),
      port: Keyword.get(opts, :port, default_port),
      local_ip: Keyword.get(opts, :local_ip),
      local_port: Keyword.get(opts, :local_port, 0),
      tls_opts: tls_opts,
      transport: if(tls_opts, do: :ssl, else: :gen_tcp),
      apci_params: Keyword.get(opts, :apci_params, %APCIParameters{}),
      al_params: Keyword.get(opts, :al_params, %AppLayerParameters{}),
      owner: Keyword.get(opts, :owner),
      connection_handler: Keyword.get(opts, :connection_handler),
      asdu_handler: Keyword.get(opts, :asdu_handler),
      raw_message_handler: Keyword.get(opts, :raw_message_handler)
    }

    if Keyword.get(opts, :auto_connect, false) do
      send(self(), :auto_connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case do_connect(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:close, _from, state) do
    new_state = do_close(state, :closed)
    {:reply, :ok, new_state}
  end

  def handle_call(:send_start_dt, _from, %{socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:send_start_dt, _from, state) do
    {:ok, bin} = Frame.encode({:u_frame, :startdt_act})

    case write_socket(state, bin) do
      :ok ->
        now = now_ms()

        new_state = %{
          state
          | con_state: :waiting_for_startdt_con,
            u_message_timeout: now + state.apci_params.t1 * 1000
        }

        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, do_close(state, :closed)}
    end
  end

  def handle_call(:send_stop_dt, _from, %{socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:send_stop_dt, _from, state) do
    state =
      if state.unconfirmed_received_i_msgs > 0 do
        confirm_outstanding_messages(state)
      else
        state
      end

    {:ok, bin} = Frame.encode({:u_frame, :stopdt_act})

    case write_socket(state, bin) do
      :ok ->
        now = now_ms()

        new_state = %{
          state
          | con_state: :waiting_for_stopdt_con,
            u_message_timeout: now + state.apci_params.t1 * 1000
        }

        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, do_close(state, :closed)}
    end
  end

  def handle_call(:send_test_fr, _from, %{socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:send_test_fr, _from, state) do
    {:ok, bin} = Frame.encode({:u_frame, :testfr_act})

    case write_socket(state, bin) do
      :ok ->
        now = now_ms()

        new_state = %{
          state
          | u_message_timeout: now + state.apci_params.t1 * 1000,
            outstanding_testfr_con_msgs: state.outstanding_testfr_con_msgs + 1,
            next_t3_timeout: now + state.apci_params.t3 * 1000
        }

        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, do_close(state, :closed)}
    end
  end

  def handle_call({:send_process_command, type_id_override, cot, ca, io}, _from, state) do
    type_id = type_id_override || InformationObject.type_id(io)

    asdu =
      ASDU.new(type_id,
        cot: cot,
        oa: state.al_params.originator_address,
        ca: ca,
        objects: [io]
      )

    case send_asdu_internal(state, asdu) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:send_asdu, asdu}, _from, state) do
    case send_asdu_internal(state, asdu) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:is_transmit_buffer_full, _from, state) do
    {:reply, sent_buffer_full?(state), state}
  end

  def handle_call(:is_connected, _from, state) do
    {:reply, state.socket != nil and state.con_state != :idle, state}
  end

  def handle_call({:set_originator_address, oa}, _from, state) do
    al = %{state.al_params | originator_address: oa}
    {:reply, :ok, %{state | al_params: al}}
  end

  def handle_call(:get_apci_params, _from, state), do: {:reply, state.apci_params, state}

  def handle_call({:set_apci_params, params}, _from, state) do
    {:reply, :ok, %{state | apci_params: params}}
  end

  def handle_call(:get_al_params, _from, state), do: {:reply, state.al_params, state}

  def handle_call({:set_al_params, params}, _from, state) do
    {:reply, :ok, %{state | al_params: params}}
  end

  def handle_call({:set_asdu_handler, handler}, _from, state) do
    {:reply, :ok, %{state | asdu_handler: handler}}
  end

  def handle_call({:set_connection_handler, handler}, _from, state) do
    {:reply, :ok, %{state | connection_handler: handler}}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      con_state: state.con_state,
      send_count: state.send_count,
      receive_count: state.receive_count,
      unconfirmed_received_i_msgs: state.unconfirmed_received_i_msgs,
      sent_asdus_count: length(state.sent_asdus)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:connect_async, state) do
    case do_connect(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:auto_connect, state) do
    case do_connect(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  def handle_info({transport_tag, socket, data}, %{socket: socket} = state)
      when transport_tag in [:tcp, :ssl] do
    Telemetry.execute([:iec60870, :cs104, :raw_message], %{byte_size: byte_size(data)}, %{
      pid: self(),
      direction: :received,
      bytes: data
    })

    if state.raw_message_handler do
      state.raw_message_handler.(self(), data, false)
    end

    buffer = state.recv_buffer <> data

    case Frame.extract_frames(buffer) do
      {:ok, frames, rest} ->
        case process_frames(frames, %{state | recv_buffer: rest}) do
          {:ok, new_state} ->
            {:noreply, new_state}

          {:error, _reason, new_state} ->
            {:noreply, do_close(new_state, :closed)}
        end

      {:error, _reason} ->
        {:noreply, do_close(state, :closed)}
    end
  end

  def handle_info({closed_tag, socket}, %{socket: socket} = state)
      when closed_tag in [:tcp_closed, :ssl_closed] do
    {:noreply, do_close(%{state | socket: nil}, :closed)}
  end

  def handle_info({error_tag, socket, _reason}, %{socket: socket} = state)
      when error_tag in [:tcp_error, :ssl_error] do
    {:noreply, do_close(%{state | socket: nil}, :closed)}
  end

  def handle_info(:tick, %{socket: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    case handle_timeouts(state) do
      {:ok, new_state} ->
        tick_ref = Process.send_after(self(), :tick, 100)
        {:noreply, %{new_state | tick_ref: tick_ref}}

      {:error, _reason, new_state} ->
        {:noreply, do_close(new_state, :closed)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      do_close(state, :closed)
    end

    :ok
  end

  # ===========================================================================
  # Internal Logic
  # ===========================================================================

  defp do_connect(state) do
    state =
      if state.socket do
        do_close(state, :closed)
      else
        state
      end

    now = now_ms()

    state = %{
      state
      | con_state: :idle,
        recv_buffer: <<>>,
        send_count: 0,
        receive_count: 0,
        unconfirmed_received_i_msgs: 0,
        timeout_t2_triggered: false,
        last_confirmation_time: 0,
        next_t3_timeout: now + state.apci_params.t3 * 1000,
        u_message_timeout: 0,
        outstanding_testfr_con_msgs: 0,
        sent_asdus: []
    }

    char_host = to_charlist_host(state.host)
    timeout_ms = state.apci_params.t0 * 1000

    base_opts = [:binary, active: true, packet: :raw, nodelay: true]

    bind_opts =
      if state.local_ip do
        {:ok, ip_tuple} = :inet.parse_address(to_charlist_host(state.local_ip))
        [{:ip, ip_tuple}, {:port, state.local_port}]
      else
        []
      end

    connect_res =
      if state.transport == :ssl do
        ssl_opts = base_opts ++ bind_opts ++ state.tls_opts
        :ssl.connect(char_host, state.port, ssl_opts, timeout_ms)
      else
        tcp_opts = base_opts ++ bind_opts
        :gen_tcp.connect(char_host, state.port, tcp_opts, timeout_ms)
      end

    case connect_res do
      {:ok, socket} ->
        tick_ref = Process.send_after(self(), :tick, 100)
        new_state = %{state | socket: socket, con_state: :inactive, tick_ref: tick_ref}
        notify_connection_event(new_state, :opened)
        {:ok, new_state}

      {:error, reason} ->
        notify_connection_event(state, :failed)
        {:error, reason, state}
    end
  end

  defp do_close(state, event) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)

    state =
      if state.socket != nil and state.unconfirmed_received_i_msgs > 0 do
        confirm_outstanding_messages(state)
      else
        state
      end

    if state.socket do
      case state.transport do
        :ssl -> :ssl.close(state.socket)
        :gen_tcp -> :gen_tcp.close(state.socket)
      end
    end

    was_active = state.con_state != :idle or state.socket != nil

    new_state = %{
      state
      | socket: nil,
        con_state: :idle,
        tick_ref: nil,
        recv_buffer: <<>>
    }

    if was_active do
      notify_connection_event(new_state, event)
    end

    new_state
  end

  defp process_frames([], state), do: {:ok, state}

  defp process_frames([frame | rest], state) do
    old_con_state = state.con_state

    case handle_frame(frame, state) do
      {:ok, state1} ->
        state2 = %{state1 | next_t3_timeout: now_ms() + state1.apci_params.t3 * 1000}

        if state2.con_state != old_con_state do
          case state2.con_state do
            :active -> notify_connection_event(state2, :startdt_con_received)
            :inactive -> notify_connection_event(state2, :stopdt_con_received)
            _ -> :ok
          end
        end

        state3 =
          if state2.unconfirmed_received_i_msgs >= state2.apci_params.w or
               (state2.con_state == :waiting_for_stopdt_con and
                  state2.unconfirmed_received_i_msgs > 0) do
            confirm_outstanding_messages(state2)
          else
            state2
          end

        process_frames(rest, state3)

      {:error, reason, state1} ->
        {:error, reason, state1}
    end
  end

  defp handle_frame({:i_frame, frame_send_seq, frame_recv_seq, asdu_bin}, state) do
    now = now_ms()

    state =
      if not state.timeout_t2_triggered do
        %{state | timeout_t2_triggered: true, last_confirmation_time: now}
      else
        state
      end

    cond do
      frame_send_seq != state.receive_count ->
        {:error, {:sequence_error, frame_send_seq, state.receive_count}, state}

      true ->
        case Frame.check_sequence_number(state.sent_asdus, state.send_count, frame_recv_seq) do
          {:ok, remaining_sent, _confirmed} ->
            case ASDU.decode(asdu_bin, state.al_params) do
              {:ok, asdu} ->
                new_state = %{
                  state
                  | sent_asdus: remaining_sent,
                    receive_count: rem(state.receive_count + 1, 32768),
                    unconfirmed_received_i_msgs: state.unconfirmed_received_i_msgs + 1
                }

                notify_asdu(new_state, asdu)
                {:ok, new_state}

              {:error, reason} ->
                {:error, {:invalid_asdu, reason}, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp handle_frame({:s_frame, recv_seq}, state) do
    case Frame.check_sequence_number(state.sent_asdus, state.send_count, recv_seq) do
      {:ok, remaining_sent, _confirmed} ->
        {:ok, %{state | sent_asdus: remaining_sent}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_frame({:u_frame, u_type}, state) do
    state = %{state | u_message_timeout: 0}

    case u_type do
      :testfr_act ->
        {:ok, bin} = Frame.encode({:u_frame, :testfr_con})

        case write_socket(state, bin) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end

      :testfr_con ->
        {:ok, %{state | outstanding_testfr_con_msgs: 0}}

      :startdt_act ->
        # Matches cs104_connection.c:1285-1289: reply STARTDT_CON without changing con_state
        {:ok, bin} = Frame.encode({:u_frame, :startdt_con})

        case write_socket(state, bin) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end

      :startdt_con ->
        {:ok, %{state | con_state: :active}}

      :stopdt_con ->
        {:ok, %{state | con_state: :inactive}}

      :stopdt_act ->
        {:ok, bin} = Frame.encode({:u_frame, :stopdt_con})

        case write_socket(state, bin) do
          :ok -> {:ok, %{state | con_state: :inactive}}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp send_asdu_internal(%{con_state: con_state} = state, _asdu)
       when con_state in [:idle, :inactive] do
    {:error, :connection_not_active, state}
  end

  defp send_asdu_internal(state, asdu) do
    if sent_buffer_full?(state) do
      {:error, :transmit_buffer_full, state}
    else
      case ASDU.encode(asdu, state.al_params) do
        {:ok, asdu_bin} ->
          {:ok, frame_bin} =
            Frame.encode({:i_frame, state.send_count, state.receive_count, asdu_bin})

          case write_socket(state, frame_bin) do
            :ok ->
              Telemetry.execute(
                [:iec60870, :cs104, :asdu],
                %{count: 1, num_elements: length(asdu.objects || [])},
                %{
                  pid: self(),
                  direction: :sent,
                  type_id: asdu.type_id,
                  cot: asdu.cot,
                  ca: asdu.ca,
                  asdu: asdu
                }
              )

              now = now_ms()
              next_send_count = rem(state.send_count + 1, 32768)

              entry = %{
                seq_no: next_send_count,
                sent_time: now
              }

              new_state = %{
                state
                | send_count: next_send_count,
                  unconfirmed_received_i_msgs: 0,
                  timeout_t2_triggered: false,
                  sent_asdus: state.sent_asdus ++ [entry]
              }

              {:ok, new_state}

            {:error, reason} ->
              {:error, reason, do_close(state, :closed)}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp sent_buffer_full?(state) do
    length(state.sent_asdus) >= state.apci_params.k
  end

  defp confirm_outstanding_messages(state) do
    {:ok, bin} = Frame.encode({:s_frame, state.receive_count})
    _ = write_socket(state, bin)

    %{
      state
      | last_confirmation_time: now_ms(),
        unconfirmed_received_i_msgs: 0,
        timeout_t2_triggered: false
    }
  end

  defp handle_timeouts(state) do
    now = now_ms()

    # 1. T3 idle timeout
    state_or_err =
      if now > state.next_t3_timeout do
        if state.outstanding_testfr_con_msgs > 2 do
          {:error, :testfr_con_timeout, state}
        else
          {:ok, bin} = Frame.encode({:u_frame, :testfr_act})

          case write_socket(state, bin) do
            :ok ->
              {:ok,
               %{
                 state
                 | u_message_timeout: now + state.apci_params.t1 * 1000,
                   outstanding_testfr_con_msgs: state.outstanding_testfr_con_msgs + 1,
                   next_t3_timeout: now + state.apci_params.t3 * 1000
               }}

            {:error, reason} ->
              {:error, reason, state}
          end
        end
      else
        {:ok, state}
      end

    with {:ok, state} <- state_or_err do
      # 2. T2 confirmation timeout
      state =
        if state.unconfirmed_received_i_msgs > 0 and
             now - state.last_confirmation_time >= state.apci_params.t2 * 1000 do
          confirm_outstanding_messages(state)
        else
          state
        end

      # 3. U-message T1 timeout
      if state.u_message_timeout != 0 and now > state.u_message_timeout do
        {:error, :u_message_t1_timeout, state}
      else
        # 4. Oldest unacknowledged I-frame T1 timeout
        case state.sent_asdus do
          [oldest | _] when now - oldest.sent_time >= state.apci_params.t1 * 1000 ->
            {:error, :i_message_t1_timeout, state}

          _ ->
            {:ok, state}
        end
      end
    end
  end

  defp write_socket(%{socket: nil}, _bin), do: {:error, :closed}

  defp write_socket(state, bin) do
    Telemetry.execute([:iec60870, :cs104, :raw_message], %{byte_size: byte_size(bin)}, %{
      pid: self(),
      direction: :sent,
      bytes: bin
    })

    if state.raw_message_handler do
      state.raw_message_handler.(self(), bin, true)
    end

    case state.transport do
      :ssl -> :ssl.send(state.socket, bin)
      :gen_tcp -> :gen_tcp.send(state.socket, bin)
    end
  end

  defp notify_connection_event(state, event) do
    Telemetry.execute(
      [:iec60870, :cs104, :connection_event],
      %{system_time: System.system_time()},
      %{
        pid: self(),
        event: event,
        host: state.host,
        port: state.port
      }
    )

    cond do
      is_function(state.connection_handler, 2) ->
        state.connection_handler.(self(), event)

      is_function(state.connection_handler, 1) ->
        state.connection_handler.(event)

      true ->
        :ok
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs104, self(), {:connection_event, event}})
    end
  end

  defp notify_asdu(state, asdu) do
    Telemetry.execute(
      [:iec60870, :cs104, :asdu],
      %{count: 1, num_elements: length(asdu.objects || [])},
      %{
        pid: self(),
        direction: :received,
        type_id: asdu.type_id,
        cot: asdu.cot,
        ca: asdu.ca,
        asdu: asdu
      }
    )

    cond do
      is_function(state.asdu_handler, 2) ->
        state.asdu_handler.(self(), asdu)

      is_function(state.asdu_handler, 1) ->
        state.asdu_handler.(asdu)

      true ->
        :ok
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs104, self(), {:asdu, asdu}})
    end
  end

  defp to_charlist_host(host) when is_binary(host), do: String.to_charlist(host)
  defp to_charlist_host(host) when is_list(host), do: host

  defp now_ms, do: System.monotonic_time(:millisecond)
end
