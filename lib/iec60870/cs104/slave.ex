defmodule IEC60870.CS104.RedundancyGroup do
  @moduledoc """
  Configuration for a CS104 redundancy group (`CS104_RedundancyGroup` in `cs104_slave.c`).

  If `allowed_clients` is empty (`[]`), this group acts as a catch-all redundancy group.
  """

  @type t :: %__MODULE__{
          name: String.t() | nil,
          allowed_clients: [String.t()]
        }

  defstruct name: nil,
            allowed_clients: []

  @spec new(String.t() | nil, [String.t()]) :: t()
  def new(name \\ nil, allowed_clients \\ []) do
    %__MODULE__{name: name, allowed_clients: allowed_clients}
  end

  @spec add_allowed_client(t(), String.t()) :: t()
  def add_allowed_client(%__MODULE__{} = group, ip_str) when is_binary(ip_str) do
    %{group | allowed_clients: Enum.uniq(group.allowed_clients ++ [ip_str])}
  end

  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{allowed_clients: []}, _ip_str), do: false

  def matches?(%__MODULE__{allowed_clients: clients}, ip_str) do
    norm_ip = normalize_ip(ip_str)
    Enum.any?(clients, fn c -> normalize_ip(c) == norm_ip end)
  end

  @spec catch_all?(t()) :: boolean()
  def catch_all?(%__MODULE__{allowed_clients: clients}), do: clients == []

  defp normalize_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, tuple} -> tuple
      _ -> ip_str
    end
  end
end

defmodule IEC60870.CS104.Slave do
  @moduledoc """
  IEC 60870-5-104 Slave / Server (`cs104_slave.c`).

  Supports:
  - TCP and TLS (`:ssl`) listening sockets
  - Three redundancy modes:
    - `:single_redundancy_group` (default: single shared low/high priority queue; only one active connection at a time)
    - `:connection_is_redundancy_group` (each connection has its own independent low/high priority queue)
    - `:multiple_redundancy_groups` (connections are grouped by IP into `RedundancyGroup`s, each with its own queues and single active connection)
  - Low-priority event queue (with ring-buffer overflow replacement and unconfirmed requeue on failover)
  - High-priority response queue
  - Standard application callbacks:
    - `interrogation_handler`: `fn conn_pid, asdu, qoi -> boolean() end`
    - `counter_interrogation_handler`: `fn conn_pid, asdu, qcc -> boolean() end`
    - `read_handler`: `fn conn_pid, asdu, ioa -> boolean() end`
    - `clock_sync_handler`: `fn conn_pid, asdu, cp56time2a -> boolean() | {:ok, CP56Time2a.t()} end`
    - `reset_process_handler`: `fn conn_pid, asdu, qrp -> boolean() end`
    - `delay_acquisition_handler`: `fn conn_pid, asdu, delay_ms -> boolean() end`
    - `asdu_handler`: `fn conn_pid, asdu -> boolean() end`
    - `connection_request_handler`: `fn {ip_str, port} -> boolean() end`
    - `connection_event_handler`: `fn conn_pid, event -> any() end`
    - `is_ca_allowed_handler`: `fn ca -> boolean() end`
  """

  use GenServer

  alias IEC60870.{APCIParameters, AppLayerParameters, ASDU}
  alias IEC60870.CS104.RedundancyGroup
  alias IEC60870.CS104.Slave.ConnectionWorker

  @type server_mode ::
          :single_redundancy_group
          | :connection_is_redundancy_group
          | :multiple_redundancy_groups

  defstruct [
    :local_ip,
    :port,
    :tls_opts,
    :transport,
    :listen_socket,
    :acceptor_pid,
    :apci_params,
    :al_params,
    :owner,
    :interrogation_handler,
    :counter_interrogation_handler,
    :read_handler,
    :clock_sync_handler,
    :reset_process_handler,
    :delay_acquisition_handler,
    :asdu_handler,
    :connection_request_handler,
    :connection_event_handler,
    :raw_message_handler,
    :is_ca_allowed_handler,
    server_mode: :single_redundancy_group,
    max_low_prio_queue_size: 100,
    max_high_prio_queue_size: 100,
    max_open_connections: 100,
    allow_test_command_104: false,
    redundancy_groups: [],
    queues: %{},
    next_entry_id: 1,
    connections: %{}
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a `CS104.Slave` server process.
  By default starts listening immediately unless `auto_start: false` is passed.
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec start(GenServer.server()) :: :ok | {:error, term()}
  def start(slave), do: GenServer.call(slave, :start)

  @spec stop(GenServer.server()) :: :ok
  def stop(slave), do: GenServer.call(slave, :stop)

  @doc """
  Returns the actual local TCP port the server is listening on (useful when started with `port: 0`).
  """
  @spec get_port(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_port(slave), do: GenServer.call(slave, :get_port)

  @doc """
  Returns the number of currently open client connections.
  """
  @spec get_open_connections(GenServer.server()) :: non_neg_integer()
  def get_open_connections(slave), do: GenServer.call(slave, :get_open_connections)

  @doc """
  Checks whether the Slave server is currently listening for connections (`CS104_Slave_isRunning`).
  """
  @spec is_running?(GenServer.server()) :: boolean()
  def is_running?(slave), do: GenServer.call(slave, :is_running)

  @doc """
  Returns the number of entries in the low-priority ASDU queue (`CS104_Slave_getNumberOfQueueEntries`).
  If `redundancy_group` is `nil`, returns the count for the default queue (or first redundancy group).
  """
  @spec get_number_of_queue_entries(
          GenServer.server(),
          RedundancyGroup.t() | non_neg_integer() | nil
        ) ::
          non_neg_integer()
  def get_number_of_queue_entries(slave, redundancy_group \\ nil) do
    GenServer.call(slave, {:get_number_of_queue_entries, redundancy_group})
  end

  @doc """
  Adds a `RedundancyGroup` to the Slave (`CS104_Slave_addRedundancyGroup`).
  """
  @spec add_redundancy_group(GenServer.server(), RedundancyGroup.t()) :: :ok
  def add_redundancy_group(slave, %RedundancyGroup{} = group) do
    GenServer.call(slave, {:add_redundancy_group, group})
  end

  @spec get_apci_parameters(GenServer.server()) :: APCIParameters.t()
  def get_apci_parameters(slave), do: GenServer.call(slave, :get_apci_params)

  @spec get_app_layer_parameters(GenServer.server()) :: AppLayerParameters.t()
  def get_app_layer_parameters(slave), do: GenServer.call(slave, :get_al_params)

  @doc """
  Enqueues a spontaneous/periodic ASDU into the low-priority transmission queue(s).
  Matches `CS104_Slave_enqueueASDU` in `cs104_slave.c`.
  """
  @spec enqueue_asdu(GenServer.server(), ASDU.t()) :: :ok
  def enqueue_asdu(slave, %ASDU{} = asdu) do
    GenServer.cast(slave, {:enqueue_asdu, asdu})
  end

  @doc """
  Enqueues an ASDU into the transmission queue(s). Convenience alias for `enqueue_asdu/2`.
  """
  @spec enqueue_user_data(GenServer.server(), ASDU.t()) :: :ok
  def enqueue_user_data(slave, %ASDU{} = asdu) do
    enqueue_asdu(slave, asdu)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    tls_opts = Keyword.get(opts, :tls_opts)
    default_port = if tls_opts, do: 19998, else: 2404
    server_mode = Keyword.get(opts, :server_mode, :single_redundancy_group)
    r_groups = Keyword.get(opts, :redundancy_groups, [])

    queues =
      case server_mode do
        :single_redundancy_group ->
          %{:default => new_queue_pair()}

        :multiple_redundancy_groups ->
          groups = if r_groups == [], do: [RedundancyGroup.new("default", [])], else: r_groups

          Map.new(Enum.with_index(groups), fn {_g, idx} ->
            {{:rg, idx}, new_queue_pair()}
          end)

        :connection_is_redundancy_group ->
          %{}
      end

    r_groups =
      if server_mode == :multiple_redundancy_groups and r_groups == [] do
        [RedundancyGroup.new("default", [])]
      else
        r_groups
      end

    state = %__MODULE__{
      local_ip: Keyword.get(opts, :local_ip),
      port: Keyword.get(opts, :port, default_port),
      tls_opts: tls_opts,
      transport: if(tls_opts, do: :ssl, else: :gen_tcp),
      apci_params: Keyword.get(opts, :apci_params, %APCIParameters{}),
      al_params: Keyword.get(opts, :al_params, %AppLayerParameters{}),
      owner: Keyword.get(opts, :owner),
      server_mode: server_mode,
      max_low_prio_queue_size: Keyword.get(opts, :max_low_prio_queue_size, 100),
      max_high_prio_queue_size: Keyword.get(opts, :max_high_prio_queue_size, 100),
      max_open_connections: Keyword.get(opts, :max_open_connections, 100),
      allow_test_command_104: Keyword.get(opts, :allow_test_command_104, false),
      redundancy_groups: r_groups,
      queues: queues,
      interrogation_handler: Keyword.get(opts, :interrogation_handler),
      counter_interrogation_handler: Keyword.get(opts, :counter_interrogation_handler),
      read_handler: Keyword.get(opts, :read_handler),
      clock_sync_handler: Keyword.get(opts, :clock_sync_handler),
      reset_process_handler: Keyword.get(opts, :reset_process_handler),
      delay_acquisition_handler: Keyword.get(opts, :delay_acquisition_handler),
      asdu_handler: Keyword.get(opts, :asdu_handler),
      connection_request_handler: Keyword.get(opts, :connection_request_handler),
      connection_event_handler: Keyword.get(opts, :connection_event_handler),
      raw_message_handler: Keyword.get(opts, :raw_message_handler),
      is_ca_allowed_handler: Keyword.get(opts, :is_ca_allowed_handler)
    }

    if Keyword.get(opts, :auto_start, true) do
      case do_start_listen(state) do
        {:ok, started_state} -> {:ok, started_state}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:start, _from, %{listen_socket: nil} = state) do
    case do_start_listen(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:start, _from, state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    {:reply, :ok, do_stop_listen(state)}
  end

  def handle_call(:get_port, _from, %{listen_socket: nil} = state) do
    {:reply, {:error, :not_listening}, state}
  end

  def handle_call(:get_port, _from, state) do
    {:reply, {:ok, state.port}, state}
  end

  def handle_call(:get_open_connections, _from, state) do
    {:reply, map_size(state.connections), state}
  end

  def handle_call(:is_running, _from, state) do
    {:reply, state.listen_socket != nil, state}
  end

  def handle_call({:get_number_of_queue_entries, rg}, _from, state) do
    count =
      case state.server_mode do
        :single_redundancy_group ->
          case Map.get(state.queues, :default) do
            %{low_prio: low} -> length(low)
            _ -> 0
          end

        :multiple_redundancy_groups ->
          qkey =
            cond do
              is_integer(rg) ->
                {:rg, rg}

              is_struct(rg, RedundancyGroup) ->
                idx = Enum.find_index(state.redundancy_groups, &(&1 == rg)) || 0
                {:rg, idx}

              true ->
                {:rg, 0}
            end

          case Map.get(state.queues, qkey) do
            %{low_prio: low} -> length(low)
            _ -> 0
          end

        :connection_is_redundancy_group ->
          state.queues
          |> Map.values()
          |> Enum.reduce(0, fn %{low_prio: low}, acc -> acc + length(low) end)
      end

    {:reply, count, state}
  end

  def handle_call({:add_redundancy_group, %RedundancyGroup{} = group}, _from, state) do
    idx = length(state.redundancy_groups)
    new_groups = state.redundancy_groups ++ [group]
    new_queues = Map.put(state.queues, {:rg, idx}, new_queue_pair())
    {:reply, :ok, %{state | redundancy_groups: new_groups, queues: new_queues}}
  end

  def handle_call(:get_apci_params, _from, state), do: {:reply, state.apci_params, state}
  def handle_call(:get_al_params, _from, state), do: {:reply, state.al_params, state}

  # Called by ConnectionWorker when STARTDT_ACT is received
  def handle_call({:activate_connection, conn_pid}, _from, state) do
    case Map.get(state.connections, conn_pid) do
      nil ->
        {:reply, :error, state}

      conn_info ->
        queue_key = conn_info.queue_key

        state =
          case state.server_mode do
            mode when mode in [:single_redundancy_group, :multiple_redundancy_groups] ->
              # Close any other active connection sharing the same queue_key
              Enum.reduce(state.connections, state, fn {other_pid, other_info}, acc ->
                if other_pid != conn_pid and other_info.queue_key == queue_key and
                     other_info.active do
                  ConnectionWorker.deactivate_and_close(other_pid)
                  acc = requeue_unconfirmed(acc, queue_key)
                  put_in(acc.connections[other_pid].active, false)
                else
                  acc
                end
              end)

            :connection_is_redundancy_group ->
              state
          end

        # Reset high-priority queue on connection activation (matches MessageQueue_reset in cs104_slave.c:1203)
        state =
          case Map.get(state.queues, queue_key) do
            nil ->
              state

            qpair ->
              put_in(state.queues[queue_key], %{qpair | high_prio: :queue.new()})
          end

        state = put_in(state.connections[conn_pid].active, true)
        notify_conn_event(state, conn_pid, :activated)
        {:reply, :ok, state}
    end
  end

  def handle_call({:deactivate_connection, conn_pid}, _from, state) do
    case Map.get(state.connections, conn_pid) do
      nil ->
        {:reply, :ok, state}

      conn_info ->
        state =
          if conn_info.active do
            notify_conn_event(state, conn_pid, :deactivated)
            put_in(state.connections[conn_pid].active, false)
          else
            state
          end

        {:reply, :ok, state}
    end
  end

  # Pop next ASDU (high priority first, then low priority) for an active connection
  def handle_call({:pop_next_asdu, conn_pid}, _from, state) do
    case Map.get(state.connections, conn_pid) do
      %{active: true, queue_key: queue_key} ->
        case Map.get(state.queues, queue_key) do
          nil ->
            {:reply, :empty, state}

          qpair ->
            case :queue.out(qpair.high_prio) do
              {{:value, asdu}, rest_high} ->
                new_qpair = %{qpair | high_prio: rest_high}
                {:reply, {:ok, asdu, nil}, put_in(state.queues[queue_key], new_qpair)}

              {:empty, _} ->
                case take_waiting_low_prio(qpair.low_prio) do
                  {:ok, entry, updated_low} ->
                    new_qpair = %{qpair | low_prio: updated_low}

                    {:reply, {:ok, entry.asdu, entry.entry_id},
                     put_in(state.queues[queue_key], new_qpair)}

                  :empty ->
                    {:reply, :empty, state}
                end
            end
        end

      _ ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:enqueue_high_prio, conn_pid, asdu}, _from, state) do
    case Map.get(state.connections, conn_pid) do
      nil ->
        {:reply, {:error, :closed}, state}

      %{queue_key: queue_key} ->
        qpair = Map.fetch!(state.queues, queue_key)

        if :queue.len(qpair.high_prio) >= state.max_high_prio_queue_size do
          {:reply, {:error, :queue_full}, state}
        else
          new_qpair = %{qpair | high_prio: :queue.in(asdu, qpair.high_prio)}
          {:reply, :ok, put_in(state.queues[queue_key], new_qpair)}
        end
    end
  end

  @impl true
  def handle_cast({:enqueue_asdu, asdu}, state) do
    {queues, next_id} =
      Enum.reduce(state.queues, {%{}, state.next_entry_id}, fn {qkey, qpair}, {acc_q, eid} ->
        new_entry = %{entry_id: eid, asdu: asdu, state: :waiting}

        low_list =
          if length(qpair.low_prio) >= state.max_low_prio_queue_size do
            tl(qpair.low_prio) ++ [new_entry]
          else
            qpair.low_prio ++ [new_entry]
          end

        {Map.put(acc_q, qkey, %{qpair | low_prio: low_list}), eid + 1}
      end)

    state = %{state | queues: queues, next_entry_id: next_id}

    # Notify active connections that queued data is available
    Enum.each(state.connections, fn {pid, info} ->
      if info.active, do: send(pid, :flush_queues)
    end)

    {:noreply, state}
  end

  def handle_cast({:confirm_entries, conn_pid, entry_ids}, state) do
    case Map.get(state.connections, conn_pid) do
      nil ->
        {:noreply, state}

      %{queue_key: queue_key} ->
        case Map.get(state.queues, queue_key) do
          nil ->
            {:noreply, state}

          qpair ->
            id_set = MapSet.new(entry_ids)

            new_low =
              Enum.reject(qpair.low_prio, fn entry ->
                MapSet.member?(id_set, entry.entry_id)
              end)

            {:noreply, put_in(state.queues[queue_key], %{qpair | low_prio: new_low})}
        end
    end
  end

  @impl true
  def handle_info({:accepted, client_socket}, state) do
    state = handle_accepted_socket(client_socket, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.connections, pid) do
      {nil, _} ->
        {:noreply, state}

      {conn_info, remaining_conns} ->
        state = %{state | connections: remaining_conns}

        state =
          case state.server_mode do
            :connection_is_redundancy_group ->
              %{state | queues: Map.delete(state.queues, conn_info.queue_key)}

            _ ->
              if conn_info.active do
                requeue_unconfirmed(state, conn_info.queue_key)
              else
                state
              end
          end

        if conn_info.active do
          notify_conn_event(state, pid, :deactivated)
        end

        notify_conn_event(state, pid, :closed)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_stop_listen(state)
    :ok
  end

  # ===========================================================================
  # Internal Listener & Queue Helpers
  # ===========================================================================

  defp do_start_listen(state) do
    base_opts = [:binary, active: false, packet: :raw, reuseaddr: true, nodelay: true]

    ip_opts =
      if state.local_ip do
        {:ok, ip_tuple} = :inet.parse_address(to_charlist_host(state.local_ip))
        [{:ip, ip_tuple}]
      else
        []
      end

    listen_res =
      if state.transport == :ssl do
        :ssl.listen(state.port, base_opts ++ ip_opts ++ state.tls_opts)
      else
        :gen_tcp.listen(state.port, base_opts ++ ip_opts)
      end

    case listen_res do
      {:ok, lsocket} ->
        actual_port =
          case state.transport do
            :ssl ->
              {:ok, {_ip, p}} = :ssl.sockname(lsocket)
              p

            :gen_tcp ->
              {:ok, p} = :inet.port(lsocket)
              p
          end

        parent = self()
        transport = state.transport

        acceptor_pid =
          spawn_link(fn ->
            accept_loop(parent, lsocket, transport)
          end)

        {:ok, %{state | listen_socket: lsocket, port: actual_port, acceptor_pid: acceptor_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stop_listen(state) do
    if state.acceptor_pid do
      Process.unlink(state.acceptor_pid)
      Process.exit(state.acceptor_pid, :kill)
    end

    if state.listen_socket do
      case state.transport do
        :ssl -> :ssl.close(state.listen_socket)
        :gen_tcp -> :gen_tcp.close(state.listen_socket)
      end
    end

    Enum.each(state.connections, fn {pid, _info} ->
      ConnectionWorker.deactivate_and_close(pid)
    end)

    %{state | listen_socket: nil, acceptor_pid: nil, connections: %{}}
  end

  defp accept_loop(parent, lsocket, :gen_tcp) do
    case :gen_tcp.accept(lsocket) do
      {:ok, client_socket} ->
        :ok = :gen_tcp.controlling_process(client_socket, parent)
        send(parent, {:accepted, client_socket})
        accept_loop(parent, lsocket, :gen_tcp)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(20)
        accept_loop(parent, lsocket, :gen_tcp)
    end
  end

  defp accept_loop(parent, lsocket, :ssl) do
    case :ssl.transport_accept(lsocket) do
      {:ok, tls_socket} ->
        case :ssl.handshake(tls_socket, 10_000) do
          {:ok, ssl_sock} ->
            :ok = :ssl.controlling_process(ssl_sock, parent)
            send(parent, {:accepted, ssl_sock})

          _ ->
            :ssl.close(tls_socket)
        end

        accept_loop(parent, lsocket, :ssl)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(20)
        accept_loop(parent, lsocket, :ssl)
    end
  end

  defp handle_accepted_socket(client_socket, state) do
    peer_info = get_socket_peer(state.transport, client_socket)

    cond do
      map_size(state.connections) >= state.max_open_connections ->
        close_socket(state.transport, client_socket)
        state

      state.connection_request_handler != nil and
          not allow_connection_request?(state.connection_request_handler, peer_info) ->
        close_socket(state.transport, client_socket)
        state

      true ->
        case resolve_queue_key(state, peer_info) do
          {:ok, queue_key_or_fun} ->
            worker_cfg = %{
              slave: self(),
              socket: client_socket,
              transport: state.transport,
              peer: peer_info,
              apci_params: state.apci_params,
              al_params: state.al_params,
              allow_test_command_104: state.allow_test_command_104,
              owner: state.owner,
              interrogation_handler: state.interrogation_handler,
              counter_interrogation_handler: state.counter_interrogation_handler,
              read_handler: state.read_handler,
              clock_sync_handler: state.clock_sync_handler,
              reset_process_handler: state.reset_process_handler,
              delay_acquisition_handler: state.delay_acquisition_handler,
              asdu_handler: state.asdu_handler,
              raw_message_handler: state.raw_message_handler,
              is_ca_allowed_handler: state.is_ca_allowed_handler
            }

            {:ok, worker_pid} = ConnectionWorker.start(worker_cfg)
            Process.monitor(worker_pid)

            case state.transport do
              :ssl -> :ssl.controlling_process(client_socket, worker_pid)
              :gen_tcp -> :gen_tcp.controlling_process(client_socket, worker_pid)
            end

            send(worker_pid, :socket_ready)

            {queue_key, queues} =
              case queue_key_or_fun do
                :per_connection ->
                  qkey = {:conn, worker_pid}
                  {qkey, Map.put(state.queues, qkey, new_queue_pair())}

                qkey ->
                  {qkey, state.queues}
              end

            conn_entry = %{
              peer: peer_info,
              queue_key: queue_key,
              active: false
            }

            new_state = %{
              state
              | queues: queues,
                connections: Map.put(state.connections, worker_pid, conn_entry)
            }

            notify_conn_event(new_state, worker_pid, :opened)
            new_state

          :reject ->
            close_socket(state.transport, client_socket)
            state
        end
    end
  end

  defp resolve_queue_key(%{server_mode: :single_redundancy_group}, _peer) do
    {:ok, :default}
  end

  defp resolve_queue_key(%{server_mode: :connection_is_redundancy_group}, _peer) do
    {:ok, :per_connection}
  end

  defp resolve_queue_key(%{server_mode: :multiple_redundancy_groups} = state, {ip_str, _port}) do
    indexed = Enum.with_index(state.redundancy_groups)

    case Enum.find(indexed, fn {g, _idx} -> RedundancyGroup.matches?(g, ip_str) end) do
      {_g, idx} ->
        {:ok, {:rg, idx}}

      nil ->
        case Enum.find(indexed, fn {g, _idx} -> RedundancyGroup.catch_all?(g) end) do
          {_g, idx} -> {:ok, {:rg, idx}}
          nil -> :reject
        end
    end
  end

  defp new_queue_pair do
    %{low_prio: [], high_prio: :queue.new()}
  end

  defp take_waiting_low_prio(entries) do
    do_take_waiting(entries, [])
  end

  defp do_take_waiting([], _acc), do: :empty

  defp do_take_waiting([%{state: :waiting} = entry | rest], acc) do
    updated_entry = %{entry | state: :sent}
    {:ok, updated_entry, Enum.reverse(acc) ++ [updated_entry | rest]}
  end

  defp do_take_waiting([head | rest], acc) do
    do_take_waiting(rest, [head | acc])
  end

  defp requeue_unconfirmed(state, queue_key) do
    case Map.get(state.queues, queue_key) do
      nil ->
        state

      qpair ->
        reset_low =
          Enum.map(qpair.low_prio, fn entry ->
            %{entry | state: :waiting}
          end)

        put_in(state.queues[queue_key], %{qpair | low_prio: reset_low})
    end
  end

  defp get_socket_peer(:gen_tcp, sock) do
    case :inet.peername(sock) do
      {:ok, {ip, port}} -> {to_string(:inet.ntoa(ip)), port}
      _ -> {"0.0.0.0", 0}
    end
  end

  defp get_socket_peer(:ssl, sock) do
    case :ssl.peername(sock) do
      {:ok, {ip, port}} -> {to_string(:inet.ntoa(ip)), port}
      _ -> {"0.0.0.0", 0}
    end
  end

  defp close_socket(:gen_tcp, sock), do: :gen_tcp.close(sock)
  defp close_socket(:ssl, sock), do: :ssl.close(sock)

  defp notify_conn_event(state, conn_pid, event) do
    peer_info =
      case Map.get(state.connections, conn_pid) do
        %{peer: peer} -> peer
        _ -> nil
      end

    IEC60870.Telemetry.execute(
      [:iec60870, :cs104, :connection_event],
      %{system_time: System.system_time()},
      %{
        pid: conn_pid,
        server_pid: self(),
        peer: peer_info,
        event: event
      }
    )

    if is_function(state.connection_event_handler, 2) do
      state.connection_event_handler.(conn_pid, event)
    end

    if is_pid(state.owner) do
      send(state.owner, {:iec60870_cs104_slave, self(), conn_pid, {:connection_event, event}})
    end
  end

  defp to_charlist_host(host) when is_binary(host), do: String.to_charlist(host)
  defp to_charlist_host(host) when is_list(host), do: host

  defp allow_connection_request?(handler, {ip_str, port} = peer_info) do
    cond do
      is_function(handler, 2) ->
        handler.(ip_str, port)

      is_function(handler, 1) ->
        try do
          handler.(peer_info)
        rescue
          FunctionClauseError -> handler.(ip_str)
        end

      true ->
        true
    end
  end
end

defmodule IEC60870.CS104.Slave.ConnectionWorker do
  @moduledoc false
  use GenServer

  alias IEC60870.ASDU
  alias IEC60870.CS104.Frame
  alias IEC60870.IO.System, as: SystemIO
  alias IEC60870.Telemetry
  alias IEC60870.Types.CPTime.CP56Time2a

  defstruct [
    :slave,
    :socket,
    :transport,
    :peer,
    :apci_params,
    :al_params,
    :allow_test_command_104,
    :owner,
    :interrogation_handler,
    :counter_interrogation_handler,
    :read_handler,
    :clock_sync_handler,
    :reset_process_handler,
    :delay_acquisition_handler,
    :asdu_handler,
    :raw_message_handler,
    :is_ca_allowed_handler,
    :tick_ref,
    active: false,
    con_state: :stopped,
    recv_buffer: <<>>,
    send_count: 0,
    receive_count: 0,
    unconfirmed_received_i_msgs: 0,
    timeout_t2_triggered: false,
    last_confirmation_time: 0,
    next_t3_timeout: 0,
    waiting_for_testfr_con: false,
    next_testfr_con_timeout: 0,
    sent_asdus: []
  ]

  def start(cfg) do
    GenServer.start(__MODULE__, cfg)
  end

  def deactivate_and_close(pid) do
    GenServer.cast(pid, :close)
  end

  @impl true
  def init(cfg) do
    now = now_ms()

    state = %__MODULE__{
      slave: cfg.slave,
      socket: cfg.socket,
      transport: cfg.transport,
      peer: cfg.peer,
      apci_params: cfg.apci_params,
      al_params: cfg.al_params,
      allow_test_command_104: cfg.allow_test_command_104,
      owner: cfg.owner,
      interrogation_handler: cfg.interrogation_handler,
      counter_interrogation_handler: cfg.counter_interrogation_handler,
      read_handler: cfg.read_handler,
      clock_sync_handler: cfg.clock_sync_handler,
      reset_process_handler: cfg.reset_process_handler,
      delay_acquisition_handler: cfg.delay_acquisition_handler,
      asdu_handler: cfg.asdu_handler,
      raw_message_handler: cfg.raw_message_handler,
      is_ca_allowed_handler: cfg.is_ca_allowed_handler,
      next_t3_timeout: now + cfg.apci_params.t3 * 1000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_asdu, asdu}, _from, state) do
    case send_or_queue_asdu(state, asdu) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:is_active, _from, state) do
    {:reply, state.active, state}
  end

  def handle_call(:is_ready, _from, state) do
    {:reply, state.active and length(state.sent_asdus) < state.apci_params.k, state}
  end

  def handle_call(:get_al_params, _from, state) do
    {:reply, state.al_params, state}
  end

  def handle_call(:get_peer_address, _from, state) do
    {:reply, {:ok, state.peer}, state}
  end

  @impl true
  def handle_cast(:close, state) do
    {:stop, :normal, close_socket(state)}
  end

  @impl true
  def handle_info(:socket_ready, state) do
    case state.transport do
      :ssl -> :ssl.setopts(state.socket, active: true)
      :gen_tcp -> :inet.setopts(state.socket, active: true)
    end

    tick_ref = Process.send_after(self(), :tick, 50)
    {:noreply, %{state | tick_ref: tick_ref}}
  end

  def handle_info({:internal_send_asdu, asdu}, state) do
    case send_or_queue_asdu(state, asdu) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:flush_queues, state) do
    case flush_queues(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:stop, :normal, close_socket(new_state)}
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
          {:ok, state1} ->
            case flush_queues(state1) do
              {:ok, state2} -> {:noreply, state2}
              {:error, _reason, state2} -> {:stop, :normal, close_socket(state2)}
            end

          {:error, _reason, state1} ->
            {:stop, :normal, close_socket(state1)}
        end

      {:error, _reason} ->
        {:stop, :normal, close_socket(state)}
    end
  end

  def handle_info({closed_tag, socket}, %{socket: socket} = state)
      when closed_tag in [:tcp_closed, :ssl_closed] do
    {:stop, :normal, %{state | socket: nil}}
  end

  def handle_info({error_tag, socket, _reason}, %{socket: socket} = state)
      when error_tag in [:tcp_error, :ssl_error] do
    {:stop, :normal, %{state | socket: nil}}
  end

  def handle_info(:tick, %{socket: nil} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:tick, state) do
    with {:ok, state1} <- handle_timeouts(state),
         {:ok, state2} <- flush_queues(state1) do
      tick_ref = Process.send_after(self(), :tick, 50)
      {:noreply, %{state2 | tick_ref: tick_ref}}
    else
      {:error, _reason, state1} ->
        {:stop, :normal, close_socket(state1)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Frame & ASDU Processing (`handleMessage` & `handleASDU` in `cs104_slave.c`)
  # ===========================================================================

  defp process_frames([], state), do: {:ok, state}

  defp process_frames([frame | rest], state) do
    case handle_frame(frame, state) do
      {:ok, state1} ->
        state2 = %{state1 | next_t3_timeout: now_ms() + state1.apci_params.t3 * 1000}

        state3 =
          if state2.unconfirmed_received_i_msgs >= state2.apci_params.w do
            send_s_frame(state2)
          else
            state2
          end

        process_frames(rest, state3)

      {:error, reason, state1} ->
        {:error, reason, state1}
    end
  end

  defp handle_frame({:i_frame, _send_seq, _recv_seq, _asdu_bin}, %{active: false} = state) do
    {:error, :i_frame_when_inactive, state}
  end

  defp handle_frame({:i_frame, frame_send_seq, frame_recv_seq, asdu_bin}, state) do
    now = now_ms()

    state =
      if not state.timeout_t2_triggered do
        %{state | timeout_t2_triggered: true, last_confirmation_time: now}
      else
        state
      end

    if frame_send_seq != state.receive_count do
      {:error, {:sequence_error, frame_send_seq, state.receive_count}, state}
    else
      case Frame.check_sequence_number(state.sent_asdus, state.send_count, frame_recv_seq) do
        {:ok, remaining_sent, confirmed} ->
          confirm_low_prio(state, confirmed)

          state = %{
            state
            | sent_asdus: remaining_sent,
              receive_count: rem(state.receive_count + 1, 32768),
              unconfirmed_received_i_msgs: state.unconfirmed_received_i_msgs + 1
          }

          case ASDU.decode(asdu_bin, state.al_params) do
            {:ok, asdu} ->
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

              handle_received_asdu(state, asdu)

            {:error, reason} ->
              {:error, {:invalid_asdu, reason}, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp handle_frame({:s_frame, recv_seq}, state) do
    # Matches cs104_slave.c:3185-3190: receiving S-frame while already in M_CON_STATE_STOPPED closes connection
    if state.con_state == :stopped do
      {:error, :s_frame_when_stopped, state}
    else
      case Frame.check_sequence_number(state.sent_asdus, state.send_count, recv_seq) do
        {:ok, remaining_sent, confirmed} ->
          confirm_low_prio(state, confirmed)
          state1 = %{state | sent_asdus: remaining_sent}

          # Matches cs104_slave.c:3173-3184: if in UNCONFIRMED_STOPPED and all sent I-frames are now confirmed,
          # send STOPDT_CON and transition to STOPPED
          if state1.con_state == :unconfirmed_stopped and remaining_sent == [] do
            {:ok, bin} = Frame.encode({:u_frame, :stopdt_con})

            case write_socket(state1, bin) do
              :ok -> {:ok, %{state1 | con_state: :stopped}}
              {:error, reason} -> {:error, reason, state1}
            end
          else
            {:ok, state1}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp handle_frame({:u_frame, :testfr_act}, state) do
    {:ok, bin} = Frame.encode({:u_frame, :testfr_con})

    case write_socket(state, bin) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_frame({:u_frame, :testfr_con}, state) do
    {:ok, %{state | waiting_for_testfr_con: false}}
  end

  defp handle_frame({:u_frame, :startdt_act}, state) do
    # Matches cs104_slave.c:3078-3088: activate connection and reset high-priority queue BEFORE sending STARTDT_CON
    _ = GenServer.call(state.slave, {:activate_connection, self()})
    state = %{state | active: true, con_state: :started}

    {:ok, bin} = Frame.encode({:u_frame, :startdt_con})

    case write_socket(state, bin) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_frame({:u_frame, :stopdt_act}, state) do
    # Matches cs104_slave.c:3091-3142:
    # 1. Flush any pending high-priority ASDUs and confirm any unconfirmed received I-messages
    {:ok, state} = flush_queues(state)

    state =
      if state.unconfirmed_received_i_msgs > 0 do
        send_s_frame(state)
      else
        state
      end

    _ = GenServer.call(state.slave, {:deactivate_connection, self()})
    state = %{state | active: false}

    # 2. If there are unconfirmed sent ASDUs, enter :unconfirmed_stopped and delay STOPDT_CON until S-frame confirms them
    if state.sent_asdus != [] do
      {:ok, %{state | con_state: :unconfirmed_stopped}}
    else
      {:ok, bin} = Frame.encode({:u_frame, :stopdt_con})

      case write_socket(state, bin) do
        :ok -> {:ok, %{state | con_state: :stopped}}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp handle_frame({:u_frame, _other}, state) do
    {:ok, state}
  end

  defp handle_received_asdu(state, %ASDU{} = asdu) do
    ca = asdu.ca

    if is_function(state.is_ca_allowed_handler, 1) and not broadcast_ca?(state, ca) and
         not state.is_ca_allowed_handler.(ca) do
      send_negative_response(state, asdu, :unknown_ca)
    else
      dispatch_asdu_by_type(state, asdu)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_ic_na_1, cot: cot} = asdu) do
    if cot in [:activation, :deactivation] do
      case state.interrogation_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              send_negative_response(state, asdu, :unknown_ioa)

            %{qoi: qoi} ->
              if handler.(self(), asdu, qoi) do
                {:ok, state}
              else
                fallback_to_asdu_handler(state, asdu)
              end

            _ ->
              {:error, :invalid_io, state}
          end
      end
    else
      send_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_ci_na_1, cot: cot} = asdu) do
    if cot in [:activation, :deactivation] do
      case state.counter_interrogation_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              send_negative_response(state, asdu, :unknown_ioa)

            %{qcc: qcc} ->
              if handler.(self(), asdu, qcc) do
                {:ok, state}
              else
                fallback_to_asdu_handler(state, asdu)
              end

            _ ->
              {:error, :invalid_io, state}
          end
      end
    else
      send_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_rd_na_1, cot: cot, ca: ca} = asdu) do
    cond do
      broadcast_ca?(state, ca) ->
        send_negative_response(state, asdu, :unknown_ca)

      cot != :request ->
        send_negative_response(state, asdu, :unknown_cot)

      state.read_handler != nil ->
        case List.first(asdu.objects) do
          %{ioa: ioa} ->
            if state.read_handler.(self(), asdu, ioa) do
              {:ok, state}
            else
              fallback_to_asdu_handler(state, asdu)
            end

          _ ->
            {:error, :invalid_io, state}
        end

      true ->
        fallback_to_asdu_handler(state, asdu)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_cs_na_1, cot: cot} = asdu) do
    if cot == :activation do
      case state.clock_sync_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              send_negative_response(state, asdu, :unknown_ioa)

            %{timestamp: %CP56Time2a{} = ts} ->
              case handler.(self(), asdu, ts) do
                true ->
                  resp_io = SystemIO.clock_sync_command(0, ts)
                  resp = %{asdu | cot: :activation_con, is_negative: false, objects: [resp_io]}
                  send_or_queue_asdu(state, resp)

                {:ok, %CP56Time2a{} = updated_ts} ->
                  resp_io = SystemIO.clock_sync_command(0, updated_ts)
                  resp = %{asdu | cot: :activation_con, is_negative: false, objects: [resp_io]}
                  send_or_queue_asdu(state, resp)

                false ->
                  send_negative_response(state, asdu, :activation_con)
              end

            _ ->
              {:error, :invalid_io, state}
          end
      end
    else
      send_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_ts_na_1, cot: cot, ca: ca} = asdu) do
    if state.allow_test_command_104 do
      cond do
        broadcast_ca?(state, ca) ->
          send_negative_response(state, asdu, :unknown_ca)

        cot != :activation ->
          send_negative_response(state, asdu, :unknown_cot)

        true ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              send_negative_response(state, asdu, :unknown_ioa)

            %{} ->
              resp = %{asdu | cot: :activation_con, is_negative: false}
              send_or_queue_asdu(state, resp)

            _ ->
              {:error, :invalid_io, state}
          end
      end
    else
      fallback_to_asdu_handler(state, asdu)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_rp_na_1, cot: cot} = asdu) do
    if cot == :activation do
      case state.reset_process_handler do
        nil ->
          fallback_to_asdu_handler(state, asdu)

        handler ->
          case List.first(asdu.objects) do
            %{ioa: ioa} when ioa != 0 ->
              send_negative_response(state, asdu, :unknown_ioa)

            %{qrp: qrp} ->
              if handler.(self(), asdu, qrp) do
                {:ok, state}
              else
                fallback_to_asdu_handler(state, asdu)
              end

            _ ->
              {:error, :invalid_io, state}
          end
      end
    else
      send_negative_response(state, asdu, :unknown_cot)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_cd_na_1, cot: cot, ca: ca} = asdu) do
    cond do
      broadcast_ca?(state, ca) ->
        send_negative_response(state, asdu, :unknown_ca)

      cot not in [:activation, :spontaneous] ->
        send_negative_response(state, asdu, :unknown_cot)

      state.delay_acquisition_handler != nil ->
        case List.first(asdu.objects) do
          %{ioa: ioa} when ioa != 0 ->
            send_negative_response(state, asdu, :unknown_ioa)

          %{delay: %{elapsed_time_ms: delay_ms}} ->
            if state.delay_acquisition_handler.(self(), asdu, delay_ms) do
              {:ok, state}
            else
              fallback_to_asdu_handler(state, asdu)
            end

          _ ->
            {:error, :invalid_io, state}
        end

      true ->
        fallback_to_asdu_handler(state, asdu)
    end
  end

  defp dispatch_asdu_by_type(state, %ASDU{type_id: :c_ts_ta_1, cot: cot, ca: ca} = asdu) do
    cond do
      cot != :activation ->
        send_negative_response(state, asdu, :unknown_cot)

      broadcast_ca?(state, ca) ->
        send_negative_response(state, asdu, :unknown_ca)

      true ->
        case List.first(asdu.objects) do
          %{ioa: ioa} when ioa != 0 ->
            send_negative_response(state, asdu, :unknown_ioa)

          %{} ->
            resp = %{asdu | cot: :activation_con, is_negative: false}
            send_or_queue_asdu(state, resp)

          _ ->
            {:error, :invalid_io, state}
        end
    end
  end

  defp dispatch_asdu_by_type(state, asdu) do
    fallback_to_asdu_handler(state, asdu)
  end

  defp fallback_to_asdu_handler(state, asdu) do
    handled? =
      cond do
        is_function(state.asdu_handler, 2) ->
          state.asdu_handler.(self(), asdu)

        is_pid(state.owner) ->
          send(state.owner, {:iec60870_cs104_slave, state.slave, self(), {:asdu, asdu}})
          true

        true ->
          false
      end

    if handled? do
      {:ok, state}
    else
      send_negative_response(state, asdu, :unknown_type_id)
    end
  end

  defp send_negative_response(state, asdu, cot) do
    resp = %{asdu | cot: cot, is_negative: true}
    send_or_queue_asdu(state, resp)
  end

  defp broadcast_ca?(state, ca) do
    case state.al_params.size_of_ca do
      2 -> ca == 65535
      _ -> ca == 255
    end
  end

  # ===========================================================================
  # Queue Flushing & Sliding Window Transmission
  # ===========================================================================

  defp send_or_queue_asdu(state, asdu) do
    # Matches MasterConnection_sendASDUInternal in cs104_slave.c:3841-3863:
    # Always enqueue into the high-priority queue first so responses preserve strict FIFO order,
    # and if the connection is active, immediately flush queues.
    res =
      try do
        GenServer.call(state.slave, {:enqueue_high_prio, self(), asdu})
      catch
        :exit, reason -> {:error, reason}
      end

    case res do
      :ok ->
        if state.active do
          flush_queues(state)
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp flush_queues(%{active: false} = state), do: {:ok, state}

  defp flush_queues(state) do
    if length(state.sent_asdus) >= state.apci_params.k do
      {:ok, state}
    else
      try do
        GenServer.call(state.slave, {:pop_next_asdu, self()})
      catch
        :exit, _reason -> {:ok, state}
      else
        {:ok, asdu, entry_id} ->
          case transmit_asdu(state, asdu, entry_id) do
            {:ok, next_state} -> flush_queues(next_state)
            {:error, reason, next_state} -> {:error, reason, next_state}
          end

        :empty ->
          {:ok, state}
      end
    end
  end

  defp transmit_asdu(state, asdu, entry_id) do
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

            sent_item = %{
              seq_no: next_send_count,
              sent_time: now,
              entry_id: entry_id
            }

            new_state = %{
              state
              | send_count: next_send_count,
                unconfirmed_received_i_msgs: 0,
                timeout_t2_triggered: false,
                sent_asdus: state.sent_asdus ++ [sent_item]
            }

            {:ok, new_state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp confirm_low_prio(state, confirmed_entries) do
    ids =
      confirmed_entries
      |> Enum.map(& &1.entry_id)
      |> Enum.reject(&is_nil/1)

    if ids != [] do
      GenServer.cast(state.slave, {:confirm_entries, self(), ids})
    end
  end

  defp send_s_frame(state) do
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

    # 1. T3 idle timeout / TESTFR_CON T1 timeout
    state_or_err =
      cond do
        state.waiting_for_testfr_con and now > state.next_testfr_con_timeout ->
          {:error, :testfr_con_timeout, state}

        not state.waiting_for_testfr_con and now > state.next_t3_timeout ->
          {:ok, bin} = Frame.encode({:u_frame, :testfr_act})

          case write_socket(state, bin) do
            :ok ->
              {:ok,
               %{
                 state
                 | waiting_for_testfr_con: true,
                   next_testfr_con_timeout: now + state.apci_params.t1 * 1000
               }}

            {:error, reason} ->
              {:error, reason, state}
          end

        true ->
          {:ok, state}
      end

    with {:ok, state} <- state_or_err do
      # 2. T2 confirmation timeout
      state =
        if state.unconfirmed_received_i_msgs > 0 and state.timeout_t2_triggered and
             now - state.last_confirmation_time >= state.apci_params.t2 * 1000 do
          send_s_frame(state)
        else
          state
        end

      # 3. Oldest unacknowledged I-frame T1 timeout
      case state.sent_asdus do
        [oldest | _] when now - oldest.sent_time >= state.apci_params.t1 * 1000 ->
          {:error, :i_message_t1_timeout, state}

        _ ->
          {:ok, state}
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

  defp close_socket(state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)

    state =
      if state.socket != nil and state.unconfirmed_received_i_msgs > 0 do
        send_s_frame(state)
      else
        state
      end

    if state.socket do
      case state.transport do
        :ssl -> :ssl.close(state.socket)
        :gen_tcp -> :gen_tcp.close(state.socket)
      end
    end

    %{state | socket: nil, tick_ref: nil}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
