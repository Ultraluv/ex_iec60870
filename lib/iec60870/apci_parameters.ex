defmodule IEC60870.APCIParameters do
  @moduledoc """
  APCI (Application Protocol Control Information) parameters for IEC 60870-5-104.
  Corresponds to `sCS104_APCIParameters` in `lib60870-C`.

  - `k`: Maximum number of unacknowledged I-format APDUs sent (default: 12)
  - `w`: Latest acknowledge after receiving `w` I-format APDUs (default: 8)
  - `t0`: Timeout of connection establishment in seconds (default: 10)
  - `t1`: Timeout of send or test APDU in seconds (default: 15)
  - `t2`: Timeout for acknowledges in case of no data messages (`t2 < t1`, default: 10)
  - `t3`: Timeout for sending test frames in case of a long idle state in seconds (default: 20)
  """

  @type t :: %__MODULE__{
          k: pos_integer(),
          w: pos_integer(),
          t0: pos_integer(),
          t1: pos_integer(),
          t2: pos_integer(),
          t3: pos_integer()
        }

  defstruct k: 12,
            w: 8,
            t0: 10,
            t1: 15,
            t2: 10,
            t3: 20

  @doc """
  Creates a new APCI parameters struct with optional custom overrides.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
