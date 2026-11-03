defmodule IEC60870.Telemetry do
  @moduledoc """
  Telemetry integration for IEC 60870 protocol events and metrics.

  Emits events using `:telemetry` if `:telemetry` application is loaded and available.
  If `:telemetry` is not present in the runtime, invocations degrade gracefully into no-ops.

  ## Supported Events

  ### Raw Message Events:
  - `[:iec60870, :cs104, :raw_message]`
  - `[:iec60870, :cs101, :raw_message]`
    - Measurements: `%{byte_size: non_neg_integer()}`
    - Metadata: `%{pid: pid(), direction: :sent | :received, bytes: binary()}`

  ### ASDU Events:
  - `[:iec60870, :cs104, :asdu]`
  - `[:iec60870, :cs101, :asdu]`
    - Measurements: `%{count: 1, num_elements: non_neg_integer()}`
    - Metadata: `%{pid: pid(), direction: :sent | :received, type_id: atom() | non_neg_integer(), cot: atom() | non_neg_integer(), ca: non_neg_integer(), asdu: struct()}`

  ### Connection & Link Events:
  - `[:iec60870, :cs104, :connection_event]`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{pid: pid(), peer: tuple() | nil, event: atom()}`
  - `[:iec60870, :cs101, :link_state]`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{pid: pid(), address: integer(), link_state: atom()}`

  ### File Transfer Events:
  - `[:iec60870, :file_service, :transfer]`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{role: :client | :server, action: atom(), filename: String.t() | nil, status: :started | :progress | :completed | :failed | :aborted}`
  """

  @doc """
  Executes a telemetry event safely.
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event_name, measurements \\ %{}, metadata \\ %{}) when is_list(event_name) do
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [event_name, measurements, metadata])
    else
      :ok
    end
  end
end
