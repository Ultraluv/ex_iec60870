defmodule IEC60870.Types.CPTime do
  @moduledoc """
  Binary time types `CP16Time2a` (2 bytes), `CP24Time2a` (3 bytes),
  `CP32Time2a` (4 bytes), and `CP56Time2a` (7 bytes).
  Matches `cpXXtime2a.c` in `lib60870-C`.
  """

  import Bitwise

  defmodule CP16Time2a do
    @moduledoc """
    2-byte binary time: elapsed time in milliseconds (`0..65535`).
    """
    @type t :: %__MODULE__{elapsed_time_ms: 0..65535}
    defstruct elapsed_time_ms: 0

    @spec new(non_neg_integer()) :: t()
    def new(ms \\ 0), do: %__MODULE__{elapsed_time_ms: ms &&& 0xFFFF}

    @spec from_ms(non_neg_integer()) :: t()
    def from_ms(ms), do: new(ms)

    @spec to_ms(t()) :: non_neg_integer()
    def to_ms(%__MODULE__{elapsed_time_ms: ms}), do: ms

    @spec encode(t() | non_neg_integer()) :: <<_::16>>
    def encode(%__MODULE__{elapsed_time_ms: ms}), do: <<ms::little-unsigned-16>>
    def encode(ms) when is_integer(ms), do: <<ms::little-unsigned-16>>

    @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :insufficient_data}
    def decode(<<ms::little-unsigned-16, rest::binary>>) do
      {:ok, %__MODULE__{elapsed_time_ms: ms}, rest}
    end

    def decode(_), do: {:error, :insufficient_data}
  end

  defmodule CP24Time2a do
    @moduledoc """
    3-byte binary time: millisecond (0..999), second (0..59), minute (0..59),
    substituted flag (`0x40`), invalid flag (`0x80`).
    """
    @type t :: %__MODULE__{
            millisecond: 0..999,
            second: 0..59,
            minute: 0..59,
            substituted: boolean(),
            invalid: boolean()
          }

    defstruct millisecond: 0,
              second: 0,
              minute: 0,
              substituted: false,
              invalid: false

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      struct(__MODULE__, opts)
    end

    @spec encode(t()) :: <<_::24>>
    def encode(%__MODULE__{} = t) do
      total_ms = t.second * 1000 + t.millisecond

      min_byte =
        (t.minute &&& 0x3F)
        |> bor(if(t.substituted, do: 0x40, else: 0))
        |> bor(if(t.invalid, do: 0x80, else: 0))

      <<total_ms::little-unsigned-16, min_byte::unsigned-8>>
    end

    @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :insufficient_data}
    def decode(<<total_ms::little-unsigned-16, min_byte::unsigned-8, rest::binary>>) do
      time = %__MODULE__{
        millisecond: rem(total_ms, 1000),
        second: div(total_ms, 1000),
        minute: min_byte &&& 0x3F,
        substituted: (min_byte &&& 0x40) != 0,
        invalid: (min_byte &&& 0x80) != 0
      }

      {:ok, time, rest}
    end

    def decode(_), do: {:error, :insufficient_data}
  end

  defmodule CP32Time2a do
    @moduledoc """
    4-byte binary time: millisecond, second, minute, substituted, invalid, hour (0..23), summer_time.
    """
    @type t :: %__MODULE__{
            millisecond: 0..999,
            second: 0..59,
            minute: 0..59,
            hour: 0..23,
            substituted: boolean(),
            invalid: boolean(),
            summer_time: boolean()
          }

    defstruct millisecond: 0,
              second: 0,
              minute: 0,
              hour: 0,
              substituted: false,
              invalid: false,
              summer_time: false

    @spec new(keyword()) :: t()
    def new(opts \\ []), do: struct(__MODULE__, opts)

    @spec from_ms_timestamp(non_neg_integer()) :: t()
    def from_ms_timestamp(timestamp_ms) when is_integer(timestamp_ms) do
      dt = DateTime.from_unix!(timestamp_ms, :millisecond)

      %__MODULE__{
        millisecond: rem(timestamp_ms, 1000),
        second: dt.second,
        minute: dt.minute,
        hour: dt.hour,
        substituted: false,
        invalid: false,
        summer_time: false
      }
    end

    @spec from_ms(non_neg_integer()) :: t()
    def from_ms(timestamp_ms), do: from_ms_timestamp(timestamp_ms)

    @spec encode(t()) :: <<_::32>>
    def encode(%__MODULE__{} = t) do
      total_ms = t.second * 1000 + t.millisecond

      min_byte =
        (t.minute &&& 0x3F)
        |> bor(if(t.substituted, do: 0x40, else: 0))
        |> bor(if(t.invalid, do: 0x80, else: 0))

      hour_byte =
        (t.hour &&& 0x1F)
        |> bor(if(t.summer_time, do: 0x80, else: 0))

      <<total_ms::little-unsigned-16, min_byte::unsigned-8, hour_byte::unsigned-8>>
    end

    @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :insufficient_data}
    def decode(
          <<total_ms::little-unsigned-16, min_byte::unsigned-8, hour_byte::unsigned-8,
            rest::binary>>
        ) do
      time = %__MODULE__{
        millisecond: rem(total_ms, 1000),
        second: div(total_ms, 1000),
        minute: min_byte &&& 0x3F,
        substituted: (min_byte &&& 0x40) != 0,
        invalid: (min_byte &&& 0x80) != 0,
        hour: hour_byte &&& 0x1F,
        summer_time: (hour_byte &&& 0x80) != 0
      }

      {:ok, time, rest}
    end

    def decode(_), do: {:error, :insufficient_data}
  end

  defmodule CP56Time2a do
    @moduledoc """
    7-byte binary time (`CP56Time2a`) according to IEC 60870-5-101 7.2.6.18.
    Matches `CP56Time2a_*` functions in `cpXXtime2a.c`.
    """
    @type t :: %__MODULE__{
            millisecond: 0..999,
            second: 0..59,
            minute: 0..59,
            hour: 0..23,
            day_of_month: 1..31,
            day_of_week: 0..7,
            month: 1..12,
            year: 0..99,
            substituted: boolean(),
            invalid: boolean(),
            summer_time: boolean()
          }

    defstruct millisecond: 0,
              second: 0,
              minute: 0,
              hour: 0,
              day_of_month: 1,
              day_of_week: 0,
              month: 1,
              year: 0,
              substituted: false,
              invalid: false,
              summer_time: false

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      t = struct(__MODULE__, opts)
      %{t | year: rem(t.year, 100)}
    end

    @spec from_ms_timestamp(non_neg_integer()) :: t()
    def from_ms_timestamp(timestamp_ms) when is_integer(timestamp_ms) do
      dt = DateTime.from_unix!(timestamp_ms, :millisecond)

      %__MODULE__{
        millisecond: rem(timestamp_ms, 1000),
        second: dt.second,
        minute: dt.minute,
        hour: dt.hour,
        day_of_month: dt.day,
        day_of_week: 0,
        month: dt.month,
        year: rem(dt.year, 100),
        substituted: false,
        invalid: false,
        summer_time: false
      }
    end

    @spec from_datetime(DateTime.t()) :: t()
    def from_datetime(%DateTime{} = dt) do
      from_ms_timestamp(DateTime.to_unix(dt, :millisecond))
    end

    @doc """
    Converts `CP56Time2a` to Unix epoch milliseconds (UTC), matching `CP56Time2a_toMsTimestamp` in `cpXXtime2a.c`
    (where 2-digit `year` is interpreted as `2000 + year`).
    Returns `0` if any field is out of valid calendar range.
    """
    @spec to_ms_timestamp(t()) :: non_neg_integer()
    def to_ms_timestamp(%__MODULE__{} = t) do
      with {:ok, date} <- Date.new(2000 + t.year, t.month, t.day_of_month),
           {:ok, time} <-
             Time.new(t.hour, t.minute, t.second, {rem(max(t.millisecond, 0), 1000) * 1000, 3}),
           {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
        DateTime.to_unix(dt, :millisecond)
      else
        _ -> 0
      end
    end

    @spec from_ms(non_neg_integer()) :: t()
    def from_ms(timestamp_ms), do: from_ms_timestamp(timestamp_ms)

    @spec to_ms(t()) :: non_neg_integer()
    def to_ms(%__MODULE__{} = t), do: to_ms_timestamp(t)

    @spec encode(t()) :: <<_::56>>
    def encode(%__MODULE__{} = t) do
      total_ms = t.second * 1000 + t.millisecond

      min_byte =
        (t.minute &&& 0x3F)
        |> bor(if(t.substituted, do: 0x40, else: 0))
        |> bor(if(t.invalid, do: 0x80, else: 0))

      hour_byte =
        (t.hour &&& 0x1F)
        |> bor(if(t.summer_time, do: 0x80, else: 0))

      day_byte = (t.day_of_week &&& 0x07) <<< 5 ||| (t.day_of_month &&& 0x1F)
      month_byte = t.month &&& 0x0F
      year_byte = rem(t.year, 100) &&& 0x7F

      <<total_ms::little-unsigned-16, min_byte::unsigned-8, hour_byte::unsigned-8,
        day_byte::unsigned-8, month_byte::unsigned-8, year_byte::unsigned-8>>
    end

    @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :insufficient_data}
    def decode(
          <<total_ms::little-unsigned-16, min_byte::unsigned-8, hour_byte::unsigned-8,
            day_byte::unsigned-8, month_byte::unsigned-8, year_byte::unsigned-8, rest::binary>>
        ) do
      time = %__MODULE__{
        millisecond: rem(total_ms, 1000),
        second: div(total_ms, 1000),
        minute: min_byte &&& 0x3F,
        substituted: (min_byte &&& 0x40) != 0,
        invalid: (min_byte &&& 0x80) != 0,
        hour: hour_byte &&& 0x1F,
        summer_time: (hour_byte &&& 0x80) != 0,
        day_of_week: (day_byte &&& 0xE0) >>> 5,
        day_of_month: day_byte &&& 0x1F,
        month: month_byte &&& 0x0F,
        year: year_byte &&& 0x7F
      }

      {:ok, time, rest}
    end

    def decode(_), do: {:error, :insufficient_data}
  end
end
