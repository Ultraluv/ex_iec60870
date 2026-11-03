defmodule IEC60870.CS101.Queue do
  @moduledoc """
  FIFO Queue for CS101 ASDUs (`cs101_queue.c`).
  Used for Class 1 / Class 2 queues in `CS101.Slave` and user data queue in `CS101.Master`.
  """

  alias IEC60870.ASDU

  @type t :: %__MODULE__{
          max_size: pos_neg_integer() | pos_integer(),
          q: :queue.queue(ASDU.t()),
          count: non_neg_integer()
        }

  @type pos_neg_integer :: integer()

  defstruct max_size: 100,
            q: :queue.new(),
            count: 0

  @spec new(integer()) :: t()
  def new(max_size \\ 100) when is_integer(max_size) do
    actual_size = if max_size <= 0, do: 100, else: max_size
    %__MODULE__{max_size: actual_size, q: :queue.new(), count: 0}
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{count: count}), do: count == 0

  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{count: count, max_size: max_size}), do: count >= max_size

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{count: count}), do: count

  @doc """
  Checks whether the queue has a waiting ASDU and returns `{boolean(), first_asdu_type_id}`,
  matching `CS101_Queue_hasWaitingAsdu` in `cs101_queue.c`.
  """
  @spec has_waiting_asdu?(t()) :: {boolean(), term()}
  def has_waiting_asdu?(%__MODULE__{count: 0}), do: {false, nil}

  def has_waiting_asdu?(%__MODULE__{q: q}) do
    {:value, %ASDU{type_id: type_id}} = :queue.peek(q)
    {true, type_id}
  end

  @doc """
  Enqueues an ASDU into the ring buffer queue.
  Matching `CS101_Queue_enqueue` in `cs101_queue.c`, when the queue is full (`count >= max_size`),
  the oldest entry in the queue is removed/overwritten to make room for the newest entry.
  """
  @spec enqueue(t(), ASDU.t()) :: {:ok, t()}
  def enqueue(%__MODULE__{count: count, max_size: max_size, q: q} = queue, %ASDU{} = asdu) do
    if count >= max_size do
      {{:value, _oldest}, rest} = :queue.out(q)
      {:ok, %{queue | q: :queue.in(asdu, rest), count: max_size}}
    else
      {:ok, %{queue | q: :queue.in(asdu, q), count: count + 1}}
    end
  end

  @doc """
  Dequeues the oldest ASDU. Returns `{:ok, asdu, updated_queue}` or `:empty`.
  """
  @spec dequeue(t()) :: {:ok, ASDU.t(), t()} | :empty
  def dequeue(%__MODULE__{count: 0}), do: :empty

  def dequeue(%__MODULE__{q: q, count: count} = queue) do
    {{:value, asdu}, rest} = :queue.out(q)
    {:ok, asdu, %{queue | q: rest, count: count - 1}}
  end

  @doc """
  Flushes all entries from the queue.
  """
  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = queue) do
    %{queue | q: :queue.new(), count: 0}
  end
end
