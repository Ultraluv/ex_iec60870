defmodule IEC60870.FileService.Client do
  @moduledoc """
  IEC 60870-5-101 / 104 File Transfer Client for Master stations.

  Supports:
  1. `request_directory/4`: Calls directory on Slave and returns `{:ok, [directory_entry]}`
  2. `get_file/5`: Selects and reads (uploads) a file from Slave (`F_SC_NA_1` -> `F_FR_NA_1` -> `F_SR_NA_1` -> `F_SG_NA_1` -> `F_LS_NA_1` -> `F_AF_NA_1`)
  3. `send_file/3`: Sends (downloads) a `%TransparentFile{}` from Master to Slave (`F_FR_NA_1` -> `F_SC_NA_1` -> `F_SR_NA_1` -> `F_SC_NA_1` -> `F_SG_NA_1` -> `F_LS_NA_1` -> `F_AF_NA_1`)

  Can work over either `IEC60870.CS104.Connection` or `IEC60870.CS101.Master` by passing a `send_asdu_fun`
  (or `:master` option) and forwarding received ASDUs via `handle_asdu/2`.
  """

  use GenServer
  import Bitwise

  alias IEC60870.ASDU
  alias IEC60870.FileService.{Receiver, TransparentFile}
  alias IEC60870.IO.File, as: FileIO
  alias IEC60870.Telemetry

  @file_type_ids [
    :f_fr_na_1,
    :f_sr_na_1,
    :f_sc_na_1,
    :f_ls_na_1,
    :f_af_na_1,
    :f_sg_na_1,
    :f_dr_ta_1,
    :f_sc_nb_1
  ]

  defstruct [
    :send_asdu_fun,
    :caller,
    mode: :idle,
    ca: 1,
    ioa: 0,
    oa: 0,
    nof: 0,
    max_segment_size: 200,
    dir_entries: [],
    receiver: nil,
    upload_file: nil,
    current_section_number: 1,
    current_section_offset: 0,
    section_checksum: 0,
    file_checksum: 0
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a `FileService.Client` GenServer.

  Options:
  - `:send_asdu_fun` (required or `:connection` / `:master`) - `fn %ASDU{} -> :ok end`
  - `:connection` - `CS104.Connection` pid (automatically builds `send_asdu_fun`)
  - `:master` - `CS101.Master` pid (automatically builds `send_asdu_fun`)
  - `:oa` - Originator Address (default `0`)
  - `:max_segment_size` - max segment payload size in bytes when sending files (default `200`)
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Requests the file directory from the Slave (`F_SC_NA_1` with `COT = :request`).
  Returns `{:ok, entries}` when the last directory entry (`SOF` bit `0x20`) is received.
  """
  @spec request_directory(GenServer.server(), non_neg_integer(), non_neg_integer(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def request_directory(client, ca, ioa \\ 0, timeout \\ 10_000) do
    GenServer.call(client, {:request_directory, ca, ioa}, timeout)
  end

  @doc """
  Queries the file directory filtered by creation time range (`F_SC_NB_1` with `COT = :request`).
  Returns `{:ok, entries}` when the last directory entry (`SOF` bit `0x20`) is received.
  """
  def query_log(client, ca, ioa, nof, start_time, stop_time, timeout \\ 10_000) do
    GenServer.call(client, {:query_log, ca, ioa, nof, start_time, stop_time}, timeout)
  end

  @doc """
  Reads (uploads) a file `(ca, ioa, nof)` from the Slave.
  Returns `{:ok, binary()}` (or `{:ok, %Receiver.Memory{}}` if passed as receiver) upon completion.
  """
  @spec get_file(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          term()
        ) ::
          {:ok, binary() | Receiver.Memory.t()} | {:error, term()}
  def get_file(client, ca, ioa, nof, receiver_or_timeout \\ 15_000) do
    timeout = if is_integer(receiver_or_timeout), do: receiver_or_timeout, else: 15_000

    case GenServer.call(client, {:get_file, ca, ioa, nof}, timeout) do
      {:ok, bin} when is_binary(bin) ->
        if is_struct(receiver_or_timeout, Receiver.Memory) do
          {:ok, %{receiver_or_timeout | data: bin, nof: nof}}
        else
          {:ok, bin}
        end

      other ->
        other
    end
  end

  @doc """
  Writes (downloads) a `%TransparentFile{}` from the Master to the Slave.
  Returns `:ok` upon receiving positive file ACK (`F_AF_NA_1` with `afq = 1`).
  """
  @spec send_file(
          GenServer.server(),
          non_neg_integer() | TransparentFile.t(),
          TransparentFile.t() | timeout(),
          timeout()
        ) ::
          :ok | {:error, term()}
  def send_file(client, ca_or_file, file_or_timeout \\ 15_000, timeout \\ 15_000) do
    cond do
      is_integer(ca_or_file) and is_struct(file_or_timeout, TransparentFile) ->
        timeout_val = if is_integer(timeout), do: timeout, else: 15_000
        GenServer.call(client, {:send_file, %{file_or_timeout | ca: ca_or_file}}, timeout_val)

      is_struct(ca_or_file, TransparentFile) ->
        timeout_val = if is_integer(file_or_timeout), do: file_or_timeout, else: 15_000
        GenServer.call(client, {:send_file, ca_or_file}, timeout_val)
    end
  end

  @doc """
  Feeds an incoming ASDU from `CS104.Connection` or `CS101.Master` into the FileService Client.
  Returns `true` if handled, `false` otherwise.
  """
  @spec handle_asdu(GenServer.server(), ASDU.t()) :: boolean()
  def handle_asdu(client, %ASDU{type_id: type_id} = asdu) do
    if type_id in @file_type_ids do
      GenServer.cast(client, {:handle_asdu, asdu})
      true
    else
      false
    end
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    send_fun =
      cond do
        is_function(Keyword.get(opts, :send_asdu_fun), 1) ->
          Keyword.fetch!(opts, :send_asdu_fun)

        Keyword.has_key?(opts, :connection) ->
          conn = Keyword.fetch!(opts, :connection)
          fn asdu -> IEC60870.CS104.Connection.send_asdu(conn, asdu) end

        Keyword.has_key?(opts, :master) ->
          master = Keyword.fetch!(opts, :master)
          fn asdu -> IEC60870.CS101.Master.send_asdu(master, asdu) end
      end

    state = %__MODULE__{
      send_asdu_fun: send_fun,
      oa: Keyword.get(opts, :oa, 0),
      max_segment_size: Keyword.get(opts, :max_segment_size, 200)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(_req, _from, %{mode: mode} = state) when mode != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:request_directory, ca, ioa}, from, state) do
    Telemetry.execute(
      [:iec60870, :file_service, :transfer],
      %{system_time: System.system_time()},
      %{
        role: :client,
        action: :request_directory,
        status: :started
      }
    )

    io = FileIO.file_call_or_select(ioa, 0, 0, 0)
    asdu = ASDU.new(:f_sc_na_1, cot: :request, oa: state.oa, ca: ca, information_objects: [io])
    _ = state.send_asdu_fun.(asdu)

    new_state = %{
      state
      | mode: :reading_directory,
        caller: from,
        ca: ca,
        ioa: ioa,
        dir_entries: []
    }

    {:noreply, new_state}
  end

  def handle_call({:query_log, ca, ioa, nof, start_time, stop_time}, from, state) do
    io = FileIO.query_log(ioa, nof, start_time, stop_time)
    asdu = ASDU.new(:f_sc_nb_1, cot: :request, oa: state.oa, ca: ca, information_objects: [io])
    _ = state.send_asdu_fun.(asdu)

    new_state = %{
      state
      | mode: :reading_directory,
        caller: from,
        ca: ca,
        ioa: ioa,
        dir_entries: []
    }

    {:noreply, new_state}
  end

  def handle_call({:get_file, ca, ioa, nof}, from, state) do
    Telemetry.execute(
      [:iec60870, :file_service, :transfer],
      %{system_time: System.system_time()},
      %{
        role: :client,
        action: :get_file,
        nof: nof,
        status: :started
      }
    )

    # Step 1: Send SELECT_FILE (scq = 1)
    io = FileIO.file_call_or_select(ioa, nof, 0, 1)

    asdu =
      ASDU.new(:f_sc_na_1,
        cot: :file_transfer,
        oa: state.oa,
        ca: ca,
        information_objects: [io]
      )

    _ = state.send_asdu_fun.(asdu)

    new_state = %{
      state
      | mode: :reading_file_wait_ready,
        caller: from,
        ca: ca,
        ioa: ioa,
        nof: nof,
        section_checksum: 0,
        file_checksum: 0
    }

    {:noreply, new_state}
  end

  def handle_call({:send_file, %TransparentFile{} = file}, from, state) do
    # Step 1: Send FILE_READY (F_FR_NA_1)
    fsize = TransparentFile.file_size(file)
    io = FileIO.file_ready(file.ioa, file.nof, fsize, true)

    asdu =
      ASDU.new(:f_fr_na_1,
        cot: :file_transfer,
        oa: state.oa,
        ca: file.ca,
        information_objects: [io]
      )

    _ = state.send_asdu_fun.(asdu)

    new_state = %{
      state
      | mode: :writing_file_wait_call,
        caller: from,
        ca: file.ca,
        ioa: file.ioa,
        nof: file.nof,
        upload_file: file,
        current_section_number: 1,
        current_section_offset: 0,
        section_checksum: 0,
        file_checksum: 0
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:handle_asdu, asdu}, state) do
    {:noreply, process_asdu(state, asdu)}
  end

  # ===========================================================================
  # Incoming ASDU Handling
  # ===========================================================================

  # Directory response (`F_DR_TA_1`) or negative response during directory read
  defp process_asdu(
         %{mode: :reading_directory} = state,
         %ASDU{is_negative: true, cot: cot}
       ) do
    GenServer.reply(state.caller, {:error, {:negative_response, cot}})
    %{state | mode: :idle, caller: nil, dir_entries: []}
  end

  defp process_asdu(%{mode: :reading_directory} = state, %ASDU{type_id: :f_dr_ta_1} = asdu) do
    entries = asdu.objects
    valid_entries = Enum.reject(entries, fn e -> e.nof == 0 and e.length_of_file == 0 end)
    all_entries = state.dir_entries ++ valid_entries

    last? =
      Enum.any?(entries, fn entry ->
        (entry.sof &&& 0x20) != 0
      end)

    if last? or entries == [] do
      GenServer.reply(state.caller, {:ok, all_entries})
      %{state | mode: :idle, caller: nil, dir_entries: []}
    else
      %{state | dir_entries: all_entries}
    end
  end

  # Reading file: Slave replies with `F_FR_NA_1` (File Ready)
  defp process_asdu(
         %{mode: :reading_file_wait_ready} = state,
         %ASDU{type_id: :f_fr_na_1, is_negative: is_neg} = asdu
       ) do
    case List.first(asdu.objects) do
      %{nof: nof, length_of_file: lof, positive: true} when not is_neg ->
        receiver = Receiver.new(state.ca, state.ioa, nof, lof)
        # Send REQUEST_FILE (scq = 2)
        io = FileIO.file_call_or_select(state.ioa, nof, 0, 2)

        req_asdu =
          ASDU.new(:f_sc_na_1,
            cot: :file_transfer,
            oa: state.oa,
            ca: state.ca,
            information_objects: [io]
          )

        _ = state.send_asdu_fun.(req_asdu)
        %{state | mode: :reading_file_sections, receiver: receiver}

      _ ->
        GenServer.reply(state.caller, {:error, :file_not_ready})
        %{state | mode: :idle, caller: nil}
    end
  end

  # Reading file: Slave sends `F_SR_NA_1` (Section Ready)
  defp process_asdu(
         %{mode: :reading_file_sections} = state,
         %ASDU{type_id: :f_sr_na_1} = asdu
       ) do
    case List.first(asdu.objects) do
      %{nos: nos, not_ready: false} ->
        # Send REQUEST_SECTION (scq = 6)
        io = FileIO.file_call_or_select(state.ioa, state.nof, nos, 6)

        req_asdu =
          ASDU.new(:f_sc_na_1,
            cot: :file_transfer,
            oa: state.oa,
            ca: state.ca,
            information_objects: [io]
          )

        _ = state.send_asdu_fun.(req_asdu)

        %{
          state
          | current_section_number: nos,
            current_section_offset: 0,
            section_checksum: 0
        }

      _ ->
        GenServer.reply(state.caller, {:error, :section_not_ready})
        %{state | mode: :idle, caller: nil}
    end
  end

  # Reading file: Slave sends `F_SG_NA_1` (File Segment)
  defp process_asdu(
         %{mode: :reading_file_sections} = state,
         %ASDU{type_id: :f_sg_na_1} = asdu
       ) do
    case List.first(asdu.objects) do
      %{nos: nos, data: seg_data} ->
        los = byte_size(seg_data)
        rec = Receiver.put_segment(state.receiver, nos, state.current_section_offset, seg_data)
        sec_chs = state.section_checksum + calc_checksum(seg_data) &&& 0xFF

        %{
          state
          | receiver: rec,
            current_section_offset: state.current_section_offset + los,
            section_checksum: sec_chs
        }

      _ ->
        state
    end
  end

  # Reading file: Slave sends `F_LS_NA_1` (Last Segment or Last Section)
  defp process_asdu(
         %{mode: :reading_file_sections} = state,
         %ASDU{type_id: :f_ls_na_1} = asdu
       ) do
    case List.first(asdu.objects) do
      %{nos: nos, lsq: 3, chs: chs} ->
        # End of section (SECTION_TRANSFER_WITHOUT_DEACT)
        if chs == state.section_checksum do
          io = FileIO.file_ack(state.ioa, state.nof, nos, 3)

          ack_asdu =
            ASDU.new(:f_af_na_1,
              cot: :file_transfer,
              oa: state.oa,
              ca: state.ca,
              information_objects: [io]
            )

          _ = state.send_asdu_fun.(ack_asdu)

          %{
            state
            | file_checksum: state.file_checksum + state.section_checksum &&& 0xFF,
              section_checksum: 0
          }
        else
          # Checksum mismatch -> request section repeat (afq = 4)
          io = FileIO.file_ack(state.ioa, state.nof, nos, 4)

          ack_asdu =
            ASDU.new(:f_af_na_1,
              cot: :file_transfer,
              oa: state.oa,
              ca: state.ca,
              information_objects: [io]
            )

          _ = state.send_asdu_fun.(ack_asdu)
          %{state | current_section_offset: 0, section_checksum: 0}
        end

      %{nos: nos, lsq: 1, chs: chs} ->
        # End of file (FILE_TRANSFER_WITHOUT_DEACT)
        if chs == state.file_checksum do
          io = FileIO.file_ack(state.ioa, state.nof, nos, 1)

          ack_asdu =
            ASDU.new(:f_af_na_1,
              cot: :file_transfer,
              oa: state.oa,
              ca: state.ca,
              information_objects: [io]
            )

          _ = state.send_asdu_fun.(ack_asdu)
          file_bin = Receiver.to_binary(state.receiver)
          GenServer.reply(state.caller, {:ok, file_bin})
          %{state | mode: :idle, caller: nil, receiver: nil}
        else
          io = FileIO.file_ack(state.ioa, state.nof, nos, 2)

          ack_asdu =
            ASDU.new(:f_af_na_1,
              cot: :file_transfer,
              oa: state.oa,
              ca: state.ca,
              information_objects: [io]
            )

          _ = state.send_asdu_fun.(ack_asdu)
          GenServer.reply(state.caller, {:error, :file_checksum_mismatch})
          %{state | mode: :idle, caller: nil, receiver: nil}
        end

      %{lsq: lsq} when lsq in [2, 4] ->
        GenServer.reply(state.caller, {:error, :transfer_aborted_by_remote})
        %{state | mode: :idle, caller: nil, receiver: nil}

      _ ->
        state
    end
  end

  # Writing file to Slave: Slave rejects FILE_READY with negative F_FR_NA_1
  defp process_asdu(
         %{mode: :writing_file_wait_call} = state,
         %ASDU{type_id: :f_fr_na_1, cot: cot, is_negative: is_neg} = asdu
       ) do
    case List.first(asdu.objects) do
      %{positive: false} ->
        GenServer.reply(state.caller, {:error, :file_ready_rejected})
        %{state | mode: :idle, caller: nil, upload_file: nil}

      _ when is_neg or cot in [:unknown_ca, :unknown_ioa, :unknown_cot, :unknown_type_id] ->
        GenServer.reply(state.caller, {:error, {:negative_response, cot}})
        %{state | mode: :idle, caller: nil, upload_file: nil}

      _ ->
        state
    end
  end

  # Writing file to Slave: Slave sends `F_SC_NA_1` (Call File scq=2 or Call Section scq=6)
  defp process_asdu(
         %{mode: mode} = state,
         %ASDU{type_id: :f_sc_na_1, is_negative: is_neg} = asdu
       )
       when mode in [:writing_file_wait_call, :writing_file_sections] do
    if is_neg do
      GenServer.reply(state.caller, {:error, {:negative_response, asdu.cot}})
      %{state | mode: :idle, caller: nil, upload_file: nil}
    else
      case List.first(asdu.objects) do
        %{scq: scq, nos: nos} ->
          low_scq = scq &&& 0x0F

          cond do
            low_scq == 2 and mode == :writing_file_wait_call ->
              # Slave called file -> announce Section 1 Ready (F_SR_NA_1)
              sec1_size = TransparentFile.section_size(state.upload_file, 0)
              io = FileIO.section_ready(state.ioa, state.nof, 1, sec1_size, false)

              sr_asdu =
                ASDU.new(:f_sr_na_1,
                  cot: :file_transfer,
                  oa: state.oa,
                  ca: state.ca,
                  information_objects: [io]
                )

              _ = state.send_asdu_fun.(sr_asdu)

              %{
                state
                | mode: :writing_file_sections,
                  current_section_number: 1,
                  current_section_offset: 0,
                  section_checksum: 0,
                  file_checksum: 0
              }

            low_scq == 6 and mode == :writing_file_sections ->
              # Slave called section `nos` -> send all segments + F_LS_NA_1 (lsq = 3)
              send_section_segments(state, nos)

            true ->
              state
          end

        _ ->
          state
      end
    end
  end

  # Writing file to Slave: Slave sends `F_AF_NA_1` (ACK section or ACK file)
  defp process_asdu(
         %{mode: :writing_file_sections} = state,
         %ASDU{type_id: :f_af_na_1} = asdu
       ) do
    case List.first(asdu.objects) do
      %{afq: afq} ->
        low_afq = afq &&& 0x0F

        cond do
          low_afq == 3 ->
            # Positive Section ACK -> check if more sections exist
            next_sec = state.current_section_number + 1
            next_size = TransparentFile.section_size(state.upload_file, next_sec - 1)

            if next_size > 0 do
              io = FileIO.section_ready(state.ioa, state.nof, next_sec, next_size, false)

              sr_asdu =
                ASDU.new(:f_sr_na_1,
                  cot: :file_transfer,
                  oa: state.oa,
                  ca: state.ca,
                  information_objects: [io]
                )

              _ = state.send_asdu_fun.(sr_asdu)

              %{
                state
                | current_section_number: next_sec,
                  current_section_offset: 0,
                  section_checksum: 0
              }
            else
              # Send Last Section (lsq = 1)
              io =
                FileIO.file_last_segment_or_section(
                  state.ioa,
                  state.nof,
                  state.current_section_number,
                  1,
                  state.file_checksum
                )

              ls_asdu =
                ASDU.new(:f_ls_na_1,
                  cot: :file_transfer,
                  oa: state.oa,
                  ca: state.ca,
                  information_objects: [io]
                )

              _ = state.send_asdu_fun.(ls_asdu)
              state
            end

          low_afq == 4 ->
            # Negative Section ACK -> repeat current section ready
            sec_size =
              TransparentFile.section_size(state.upload_file, state.current_section_number - 1)

            io =
              FileIO.section_ready(
                state.ioa,
                state.nof,
                state.current_section_number,
                sec_size,
                false
              )

            sr_asdu =
              ASDU.new(:f_sr_na_1,
                cot: :file_transfer,
                oa: state.oa,
                ca: state.ca,
                information_objects: [io]
              )

            _ = state.send_asdu_fun.(sr_asdu)
            %{state | current_section_offset: 0, section_checksum: 0}

          low_afq == 1 ->
            # Positive File ACK -> transfer finished!
            GenServer.reply(state.caller, :ok)
            %{state | mode: :idle, caller: nil, upload_file: nil}

          low_afq == 2 ->
            GenServer.reply(state.caller, {:error, :negative_file_ack})
            %{state | mode: :idle, caller: nil, upload_file: nil}

          true ->
            state
        end

      _ ->
        state
    end
  end

  defp process_asdu(state, _asdu), do: state

  defp send_section_segments(state, nos) do
    sec_size = TransparentFile.section_size(state.upload_file, nos - 1)

    do_send_segments(
      %{state | current_section_number: nos, current_section_offset: 0, section_checksum: 0},
      sec_size
    )
  end

  defp do_send_segments(state, sec_size) do
    remaining = sec_size - state.current_section_offset

    if remaining > 0 do
      seg_len = min(remaining, state.max_segment_size)

      {:ok, seg_data} =
        TransparentFile.get_segment_data(
          state.upload_file,
          state.current_section_number - 1,
          state.current_section_offset,
          seg_len
        )

      io = FileIO.file_segment(state.ioa, state.nof, state.current_section_number, seg_data)

      seg_asdu =
        ASDU.new(:f_sg_na_1,
          cot: :file_transfer,
          oa: state.oa,
          ca: state.ca,
          information_objects: [io]
        )

      _ = state.send_asdu_fun.(seg_asdu)
      sec_chs = state.section_checksum + calc_checksum(seg_data) &&& 0xFF

      do_send_segments(
        %{
          state
          | current_section_offset: state.current_section_offset + seg_len,
            section_checksum: sec_chs
        },
        sec_size
      )
    else
      io =
        FileIO.file_last_segment_or_section(
          state.ioa,
          state.nof,
          state.current_section_number,
          3,
          state.section_checksum
        )

      ls_asdu =
        ASDU.new(:f_ls_na_1,
          cot: :file_transfer,
          oa: state.oa,
          ca: state.ca,
          information_objects: [io]
        )

      _ = state.send_asdu_fun.(ls_asdu)

      %{
        state
        | file_checksum: state.file_checksum + state.section_checksum &&& 0xFF,
          section_checksum: 0
      }
    end
  end

  defp calc_checksum(bin) when is_binary(bin) do
    for(<<b::8 <- bin>>, reduce: 0, do: (acc -> acc + b &&& 0xFF))
  end
end
