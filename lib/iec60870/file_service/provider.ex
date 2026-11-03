defmodule IEC60870.FileService.TransparentFile do
  @moduledoc """
  Represents a file composed of one or more binary sections for IEC 60870-5-101/104 File Transfer
  (`CS101_IFileProvider` / `CS101_TransparentFile` in `cs101_file_service.h`).
  """

  alias IEC60870.Types.CPTime.CP56Time2a

  @type t :: %__MODULE__{
          ca: non_neg_integer(),
          ioa: non_neg_integer(),
          nof: non_neg_integer(),
          name: String.t() | nil,
          data: binary() | nil,
          sections: [binary()],
          sof: non_neg_integer(),
          created_at: CP56Time2a.t(),
          on_complete: (boolean() -> any()) | nil
        }

  defstruct ca: 1,
            ioa: 0,
            nof: 1,
            name: nil,
            data: nil,
            sections: [],
            sof: 0,
            created_at: %CP56Time2a{},
            on_complete: nil

  @doc """
  Creates a new `TransparentFile` with `(nof, name, data, opts)`.
  """
  @spec new(non_neg_integer(), String.t(), binary(), keyword()) :: t()
  def new(nof, name, data, opts)
      when is_integer(nof) and is_binary(name) and is_binary(data) and is_list(opts) do
    new(1, 0, nof, data, Keyword.put(opts, :name, name))
  end

  @doc """
  Creates a new `TransparentFile` with `(nof, name, data)` or `(nof, data, opts)`.
  """
  @spec new(non_neg_integer(), String.t() | binary(), binary() | keyword()) :: t()
  def new(nof, name, data)
      when is_integer(nof) and is_binary(name) and is_binary(data) do
    new(1, 0, nof, data, name: name)
  end

  def new(nof, data, opts)
      when is_integer(nof) and is_binary(data) and is_list(opts) do
    new(1, 0, nof, data, opts)
  end

  @doc """
  Creates a new `TransparentFile` with `(nof, data)`.
  """
  @spec new(non_neg_integer(), binary()) :: t()
  def new(nof, data) when is_integer(nof) and is_binary(data) do
    new(1, 0, nof, data, [])
  end

  @doc """
  Creates a new `TransparentFile` from a single binary or a list of section binaries.
  """
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          binary() | [binary()],
          keyword()
        ) :: t()
  def new(ca, ioa, nof, data_or_sections, opts \\ []) do
    sections =
      cond do
        is_binary(data_or_sections) -> [data_or_sections]
        is_list(data_or_sections) -> data_or_sections
      end

    raw_data =
      cond do
        is_binary(data_or_sections) -> data_or_sections
        is_list(data_or_sections) -> IO.iodata_to_binary(data_or_sections)
      end

    %__MODULE__{
      ca: ca,
      ioa: ioa,
      nof: nof,
      name: Keyword.get(opts, :name),
      data: raw_data,
      sections: sections,
      sof: Keyword.get(opts, :sof, 0),
      created_at:
        Keyword.get(opts, :created_at, CP56Time2a.from_ms(System.os_time(:millisecond))),
      on_complete: Keyword.get(opts, :on_complete)
    }
  end

  @spec add_section(t(), binary()) :: t()
  def add_section(%__MODULE__{sections: sections} = file, section_bin)
      when is_binary(section_bin) do
    %{file | sections: sections ++ [section_bin]}
  end

  @spec file_size(t()) :: non_neg_integer()
  def file_size(%__MODULE__{sections: sections}) do
    Enum.reduce(sections, 0, fn s, acc -> acc + byte_size(s) end)
  end

  @doc """
  Returns the byte size of section `section_index` (0-based), or `0` if out of range.
  """
  @spec section_size(t(), non_neg_integer()) :: non_neg_integer()
  def section_size(%__MODULE__{sections: sections}, section_index) when section_index >= 0 do
    case Enum.at(sections, section_index) do
      bin when is_binary(bin) -> byte_size(bin)
      _ -> 0
    end
  end

  @doc """
  Extracts a segment binary from `section_index` (0-based) starting at `offset` with `size`.
  """
  @spec get_segment_data(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | :error
  def get_segment_data(%__MODULE__{sections: sections}, section_index, offset, size) do
    case Enum.at(sections, section_index) do
      bin when is_binary(bin) and offset + size <= byte_size(bin) ->
        {:ok, binary_part(bin, offset, size)}

      _ ->
        :error
    end
  end

  @doc """
  Concatenates all sections into a single binary.
  """
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{sections: sections}) do
    IO.iodata_to_binary(sections)
  end
end
