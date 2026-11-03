defmodule IEC60870.CS104.MasterConnection do
  @moduledoc """
  Represents a connected Master (Client) peer on a `CS104.Slave` server (`MasterConnection` in `cs104_slave.c`).

  Provides peer response helpers that can be safely called both inside Slave callbacks
  (`interrogation_handler`, `asdu_handler`, etc.) and from external processes:
  - `send_asdu/2`
  - `send_act_con/3`
  - `send_act_term/2`
  - `is_active?/1`
  - `get_peer_address/1`
  - `close/1`
  """

  alias IEC60870.ASDU

  @type t :: pid()

  @doc """
  Sends an ASDU over this specific master connection (or queues it in the high-priority queue).
  Safe to call from inside Slave callbacks or external processes.
  """
  @spec send_asdu(t(), ASDU.t()) :: :ok
  def send_asdu(conn_pid, %ASDU{} = asdu) when is_pid(conn_pid) do
    send(conn_pid, {:internal_send_asdu, asdu})
    :ok
  end

  @doc """
  Sends an `ACTIVATION_CON` (or `DEACTIVATION_CON` if the request was `DEACTIVATION`) response
  mirroring the request ASDU with `negative` flag set as specified.
  Matches `IMasterConnection_sendACT_CON` in `cs104_slave.c`.
  """
  @spec send_act_con(t(), ASDU.t(), boolean()) :: :ok | {:error, term()}
  def send_act_con(conn_pid, %ASDU{} = asdu, negative \\ false) when is_pid(conn_pid) do
    resp_cot =
      case asdu.cot do
        :deactivation -> :deactivation_con
        _ -> :activation_con
      end

    resp = %{asdu | cot: resp_cot, is_negative: negative}
    send_asdu(conn_pid, resp)
  end

  @doc """
  Sends an `ACTIVATION_TERMINATION` (`:activation_termination`) response mirroring the request ASDU.
  Matches `IMasterConnection_sendACT_TERM` in `cs104_slave.c`.
  """
  @spec send_act_term(t(), ASDU.t()) :: :ok | {:error, term()}
  def send_act_term(conn_pid, %ASDU{} = asdu) when is_pid(conn_pid) do
    resp = %{asdu | cot: :activation_termination, is_negative: false}
    send_asdu(conn_pid, resp)
  end

  @doc """
  Checks whether this connection is currently in the active (`STARTDT`) state.
  """
  @spec is_active?(t()) :: boolean()
  def is_active?(conn_pid) when is_pid(conn_pid) do
    if self() == conn_pid do
      true
    else
      GenServer.call(conn_pid, :is_active)
    end
  end

  @doc """
  Checks whether this connection is ready to transmit an ASDU (`IMasterConnection_isReady`).
  """
  @spec is_ready?(t()) :: boolean()
  def is_ready?(conn_pid) when is_pid(conn_pid) do
    if self() == conn_pid do
      true
    else
      GenServer.call(conn_pid, :is_ready)
    end
  end

  @doc """
  Returns the `IEC60870.AppLayerParameters` of this master connection.
  """
  @spec get_app_layer_parameters(t()) :: IEC60870.AppLayerParameters.t()
  def get_app_layer_parameters(conn_pid) when is_pid(conn_pid) do
    GenServer.call(conn_pid, :get_al_params)
  end

  @doc """
  Returns `{ip_string, port}` of the connected peer.
  """
  @spec get_peer_address(t()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def get_peer_address(conn_pid) when is_pid(conn_pid) do
    GenServer.call(conn_pid, :get_peer_address)
  end

  @doc """
  Closes the master connection.
  """
  @spec close(t()) :: :ok
  def close(conn_pid) when is_pid(conn_pid) do
    GenServer.cast(conn_pid, :close)
  end
end
