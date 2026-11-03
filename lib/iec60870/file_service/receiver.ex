defmodule IEC60870.FileService.Receiver.Memory do
  @moduledoc """
  In-memory file receiver container (`CS101_IFileReceiver` memory receiver).
  """

  @type t :: %__MODULE__{
          data: binary(),
          nof: non_neg_integer(),
          name: String.t() | nil
        }

  defstruct data: <<>>,
            nof: 0,
            name: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defmodule IEC60870.FileService.Receiver do
  @moduledoc """
  Accumulator for receiving multi-section / multi-segment files during IEC 60870-5-101/104
  file transfers (`CS101_IFileReceiver` in `cs101_file_service.h`).
  """

  @type t :: %__MODULE__{
          ca: non_neg_integer(),
          ioa: non_neg_integer(),
          nof: non_neg_integer(),
          name: String.t() | nil,
          data: binary(),
          expected_length: non_neg_integer(),
          sections: %{optional(pos_integer()) => binary()},
          on_finished: (t(), :ok | {:error, term()} -> any()) | nil
        }

  defstruct ca: 1,
            ioa: 0,
            nof: 1,
            name: nil,
            data: <<>>,
            expected_length: 0,
            sections: %{},
            on_finished: nil

  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), keyword()) ::
          t()
  def new(ca, ioa, nof, expected_length, opts \\ []) do
    %__MODULE__{
      ca: ca,
      ioa: ioa,
      nof: nof,
      name: Keyword.get(opts, :name),
      data: <<>>,
      expected_length: expected_length,
      sections: %{},
      on_finished: Keyword.get(opts, :on_finished)
    }
  end

  @doc """
  Appends a received segment to section `nos` (1-based section number).
  """
  @spec put_segment(t(), pos_integer(), non_neg_integer(), binary()) :: t()
  def put_segment(%__MODULE__{sections: sections} = rec, nos, offset, data)
      when is_integer(nos) and is_binary(data) do
    existing = Map.get(sections, nos, <<>>)

    updated_sec =
      cond do
        byte_size(existing) == offset ->
          existing <> data

        byte_size(existing) > offset ->
          <<prefix::binary-size(^offset), _::binary>> = existing
          prefix <> data

        true ->
          padding = :binary.copy(<<0>>, offset - byte_size(existing))
          existing <> padding <> data
      end

    %{rec | sections: Map.put(sections, nos, updated_sec)}
  end

  @doc """
  Reconstructs the complete file binary in section order (`1..N`).
  """
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{sections: sections}) do
    sections
    |> Enum.sort_by(fn {nos, _} -> nos end)
    |> Enum.map(fn {_nos, bin} -> bin end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns the ordered list of section binaries.
  """
  @spec sections_list(t()) :: [binary()]
  def sections_list(%__MODULE__{sections: sections}) do
    sections
    |> Enum.sort_by(fn {nos, _} -> nos end)
    |> Enum.map(fn {_nos, bin} -> bin end)
  end
end
