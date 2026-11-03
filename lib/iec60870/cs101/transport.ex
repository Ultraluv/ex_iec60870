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
  In-memory virtual serial bus (RS-232 / RS-485 bus simulator) for CS101 Master & Slave.

  Supports point-to-point (Balanced/Unbalanced) and multi-drop (Unbalanced Master with multiple Slaves).
  When a participant calls `send_data/2`, the bytes are broadcast to all other attached processes
  as `{:cs101_transport_data, bus_pid, data}`.
  """

  use GenServer
  @behaviour IEC60870.CS101.Transport

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Attaches `pid` (defaults to `self()`) to the virtual bus and returns a transport tuple
  `{IEC60870.CS101.Transport.VirtualBus, bus_pid}` ready to pass to `CS101.Master` or `CS101.Slave`.
  """
  @spec attach(pid(), pid()) :: {module(), pid()}
  def attach(bus_pid, pid \\ self()) when is_pid(bus_pid) and is_pid(pid) do
    :ok = GenServer.call(bus_pid, {:attach, pid})
    {__MODULE__, bus_pid}
  end

  @impl IEC60870.CS101.Transport
  def send_data(bus_pid, data) when is_pid(bus_pid) and is_binary(data) do
    GenServer.cast(bus_pid, {:transmit, self(), data})
  end

  @impl IEC60870.CS101.Transport
  def close(bus_pid) when is_pid(bus_pid) do
    GenServer.cast(bus_pid, {:detach, self()})
  end

  @impl true
  def init(:ok) do
    {:ok, %{peers: MapSet.new()}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | peers: MapSet.put(state.peers, pid)}}
  end

  @impl true
  def handle_cast({:transmit, sender, data}, state) do
    Enum.each(state.peers, fn peer ->
      if peer != sender do
        send(peer, {:cs101_transport_data, self(), data})
      end
    end)

    {:noreply, state}
  end

  def handle_cast({:detach, pid}, state) do
    {:noreply, %{state | peers: MapSet.delete(state.peers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | peers: MapSet.delete(state.peers, pid)}}
  end
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
