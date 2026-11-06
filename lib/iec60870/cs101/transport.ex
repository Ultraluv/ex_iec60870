defmodule IEC60870.CS101.Transport do
  @moduledoc """
  Transport abstraction for IEC 60870-5-101 serial / virtual links.

  Any transport implementation delivers incoming bytes to the controlling process
  as `{:cs101_transport_data, handle, binary_data}` messages and implements `send_data/2`.
  """

  @callback send_data(handle :: term(), data :: binary()) :: :ok | {:error, term()}
  @callback close(handle :: term()) :: :ok

  @doc """
  Sends raw bytes over a `{module, handle}` transport tuple.
  """
  @spec send_data({module(), term()}, binary()) :: :ok | {:error, term()}
  def send_data({mod, handle}, data) when is_atom(mod) and is_binary(data) do
    mod.send_data(handle, data)
  end

  @spec close({module(), term()}) :: :ok
  def close({mod, handle}) when is_atom(mod) do
    mod.close(handle)
  end
end

defmodule IEC60870.CS101.Transport.VirtualBus do
  @moduledoc """
  Virtual serial bus (RS-232 / RS-485 bus simulator) for CS101 Master & Slave.

  Supports point-to-point (Balanced/Unbalanced) and multi-drop (Unbalanced Master with multiple Slaves).
  Can run in-memory within a single BEAM node or bridge across separate OS processes via a TCP socket.

  When a participant calls `send_data/2`, the bytes are broadcast to all other attached processes
  as `{:cs101_transport_data, bus_pid, data}`.
  """

  use GenServer
  @behaviour IEC60870.CS101.Transport

  def start_link(opts \\ []) do
    {gen_opts, bus_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, bus_opts, gen_opts)
  end

  @doc """
  Connects to an existing VirtualBus or starts a new one.
  - If a TCP port is given (or `CS101_PORT` environment variable), tries to connect as client;
    if no server is running, starts as TCP server hub.
  - If no port is given, starts an in-memory VirtualBus.
  """
  def get_or_create(opts \\ []) do
    port =
      Keyword.get(opts, :port) ||
        (System.get_env("CS101_PORT") && String.to_integer(System.get_env("CS101_PORT")))

    case port do
      nil ->
        start_link(opts)

      p when is_integer(p) ->
        case :gen_tcp.connect(~c"127.0.0.1", p, [:binary, packet: :raw, active: false], 100) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            start_link([connect: p] ++ opts)

          {:error, _} ->
            start_link([port: p] ++ opts)
        end
    end
  end

  @doc """
  Attaches `pid` (defaults to `self()`) to the virtual bus and returns a transport tuple
  `{IEC60870.CS101.Transport.VirtualBus, bus_pid}` ready to pass to `CS101.Master` or `CS101.Slave`.
  """
  @spec attach(GenServer.server(), pid()) :: {module(), GenServer.server()}
  def attach(bus_ref, pid \\ self()) when is_pid(pid) do
    :ok = GenServer.call(bus_ref, {:attach, pid})
    {__MODULE__, bus_ref}
  end

  @impl IEC60870.CS101.Transport
  def send_data(bus_ref, data) when is_binary(data) do
    GenServer.cast(bus_ref, {:transmit, self(), data})
  end

  @impl IEC60870.CS101.Transport
  def close(bus_ref) do
    GenServer.cast(bus_ref, {:detach, self()})
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port)
    connect = Keyword.get(opts, :connect)

    cond do
      connect != nil ->
        {host, p} =
          case connect do
            {h, p} when is_binary(h) -> {to_charlist(h), p}
            {h, p} -> {h, p}
            p when is_integer(p) -> {~c"127.0.0.1", p}
          end

        case :gen_tcp.connect(host, p, [:binary, packet: :raw, active: true], 1000) do
          {:ok, sock} ->
            {:ok, %{peers: MapSet.new(), tcp_mode: :client, sock: sock}}

          {:error, reason} ->
            {:stop, reason}
        end

      port != nil ->
        case :gen_tcp.listen(port, [:binary, packet: :raw, active: true, reuseaddr: true]) do
          {:ok, listen_sock} ->
            send(self(), :accept)
            {:ok,
             %{
               peers: MapSet.new(),
               tcp_mode: :server,
               listen_sock: listen_sock,
               sockets: MapSet.new()
             }}

          {:error, reason} ->
            {:stop, reason}
        end

      true ->
        {:ok, %{peers: MapSet.new(), tcp_mode: :none}}
    end
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | peers: MapSet.put(state.peers, pid)}}
  end

  @impl true
  def handle_cast({:transmit, sender, data}, %{tcp_mode: :none} = state) do
    Enum.each(state.peers, fn peer ->
      if peer != sender do
        send(peer, {:cs101_transport_data, self(), data})
      end
    end)

    {:noreply, state}
  end

  def handle_cast({:transmit, sender, data}, %{tcp_mode: :client} = state) do
    Enum.each(state.peers, fn peer ->
      if peer != sender do
        send(peer, {:cs101_transport_data, self(), data})
      end
    end)

    _ = :gen_tcp.send(state.sock, data)
    {:noreply, state}
  end

  def handle_cast({:transmit, sender, data}, %{tcp_mode: :server} = state) do
    Enum.each(state.peers, fn peer ->
      if peer != sender do
        send(peer, {:cs101_transport_data, self(), data})
      end
    end)

    Enum.each(state.sockets, fn s -> :gen_tcp.send(s, data) end)
    {:noreply, state}
  end

  def handle_cast({:detach, pid}, state) do
    {:noreply, %{state | peers: MapSet.delete(state.peers, pid)}}
  end

  @impl true
  def handle_info(:accept, %{tcp_mode: :server} = state) do
    case :gen_tcp.accept(state.listen_sock, 100) do
      {:ok, client_sock} ->
        send(self(), :accept)
        {:noreply, %{state | sockets: MapSet.put(state.sockets, client_sock)}}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp, sock, data}, %{tcp_mode: :server} = state) do
    Enum.each(state.peers, fn peer ->
      send(peer, {:cs101_transport_data, self(), data})
    end)

    Enum.each(state.sockets, fn s ->
      if s != sock, do: :gen_tcp.send(s, data)
    end)

    {:noreply, state}
  end

  def handle_info({:tcp, _sock, data}, %{tcp_mode: :client} = state) do
    Enum.each(state.peers, fn peer ->
      send(peer, {:cs101_transport_data, self(), data})
    end)

    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, %{tcp_mode: :server} = state) do
    {:noreply, %{state | sockets: MapSet.delete(state.sockets, sock)}}
  end

  def handle_info({:tcp_closed, _sock}, %{tcp_mode: :client} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | peers: MapSet.delete(state.peers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{tcp_mode: :server} = state) do
    Enum.each(state.sockets, &:gen_tcp.close/1)
    :gen_tcp.close(state.listen_sock)
    :ok
  end

  def terminate(_reason, %{tcp_mode: :client} = state) do
    :gen_tcp.close(state.sock)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end

defmodule IEC60870.CS101.Transport.UART do
  @moduledoc """
  Adapter for `Circuits.UART` hardware serial ports.

  When `Circuits.UART` is installed and started in `:active` mode, incoming `{:circuits_uart, port, data}`
  messages are supported directly by `CS101.Master` and `CS101.Slave`, or via this transport wrapper.
  """

  @behaviour IEC60870.CS101.Transport

  @doc """
  Opens a `Circuits.UART` port with FT 1.2 framing defaults (even parity, 8 data bits, 1 stop bit).
  """
  def open(port_name, opts \\ []) do
    uart_mod = Module.concat([Circuits, UART])

    if Code.ensure_loaded?(uart_mod) do
      {:ok, pid} = apply(uart_mod, :start_link, [])
      speed = Keyword.get(opts, :speed, 9600)
      parity = Keyword.get(opts, :parity, :even)

      uart_opts = [
        speed: speed,
        data_bits: 8,
        stop_bits: 1,
        parity: parity,
        active: true
      ]

      case apply(uart_mod, :open, [pid, port_name, uart_opts]) do
        :ok -> {:ok, {__MODULE__, pid}}
        {:error, _} = err -> err
      end
    else
      {:error, :circuits_uart_not_available}
    end
  end

  @impl true
  def send_data(uart_pid, data) when is_pid(uart_pid) and is_binary(data) do
    uart_mod = Module.concat([Circuits, UART])
    apply(uart_mod, :write, [uart_pid, data])
  end

  @impl true
  def close(uart_pid) when is_pid(uart_pid) do
    uart_mod = Module.concat([Circuits, UART])

    if Code.ensure_loaded?(uart_mod) do
      _ = apply(uart_mod, :close, [uart_pid])
      _ = apply(uart_mod, :stop, [uart_pid])
    end

    :ok
  end
end
