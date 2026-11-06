defmodule IEC60870.LinkLayerParameters do
  @moduledoc """
  Serial link layer parameters for IEC 60870-5-101.
  Corresponds to `sLinkLayerParameters` in `lib60870-C`.

  - `address_length`: Length of link layer address in bytes (1 or 2, default: 1)
  - `timeout_for_ack`: Timeout for link layer ACK in ms (default: 1000)
  - `timeout_repeat`: Timeout for repeated message transmission when no ACK received in ms (default: 3000)
  - `use_single_char_ack`: Use single character `0xE5` for ACK (`FC=0`) or `RESP_NO_USER_DATA` (`FC=9`) (default: true)
  - `timeout_link_state`: Interval to repeat request status of link (`FC=9`) in ms (default: 5000)
  """

  @type t :: %__MODULE__{
          address_length: 0 | 1 | 2,
          timeout_for_ack: pos_integer(),
          timeout_repeat: pos_integer(),
          use_single_char_ack: boolean(),
          timeout_link_state: pos_integer()
        }

  defstruct address_length: 1,
            timeout_for_ack: 1000,
            timeout_repeat: 3000,
            use_single_char_ack: true,
            timeout_link_state: 5000

  @doc """
  Creates a new LinkLayerParameters struct with optional custom overrides.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
