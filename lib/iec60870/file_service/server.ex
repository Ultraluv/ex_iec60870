defmodule IEC60870.FileService.Server do
  @moduledoc """
  IEC 60870-5-101 / 104 File Transfer Server (`file_server.c`) for Slave stations.

  Supports:
  1. Directory read requests (`F_SC_NA_1` / `F_SC_NB_1` with `COT = :request` -> `F_DR_TA_1`)
  2. File upload (Master reads file from Slave: `F_SC_NA_1` -> `F_FR_NA_1` -> `F_SR_NA_1` -> `F_SG_NA_1` -> `F_LS_NA_1` -> `F_AF_NA_1`)
  3. File download (Master writes file to Slave: `F_FR_NA_1` -> `F_SC_NA_1` -> `F_SR_NA_1` -> `F_SC_NA_1` -> `F_SG_NA_1` -> `F_LS_NA_1` -> `F_AF_NA_1`)

  Can be attached to a `CS104.Slave` or `CS101.Slave` by calling `handle_asdu/3` inside the Slave's `asdu_handler`.
  """

  use GenServer
  import Bitwise

  alias IEC60870.ASDU
  alias IEC60870.CS104.MasterConnection
  alias IEC60870.FileService.{Receiver, TransparentFile}
  alias IEC60870.IO.File, as: FileIO

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
    :owner,
    :file_ready_handler,
    :file_received_handler,
    state: :unselected_idle,
    files: %{},
    received_files: %{},
    selected_file: nil,
    selected_conn: nil,
    file_receiver: nil,
    ca: 1,
    ioa: 0,
    oa: 0,
    nof: 0,
    current_section_number: 1,
    current_section_size: 0,
    current_section_offset: 0,
    section_checksum: 0,
    file_checksum: 0,
    max_segment_size: 200,
    timeout_ms: 3_000,
    last_activity_time: 0,
    tick_ref: nil
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a `FileService.Server` GenServer.

  Options:
  - `:files` - list of `%TransparentFile{}` initially available for Master to read
  - `:max_segment_size` - max segment payload size in bytes (default `200`)
  - `:timeout_ms` - transfer timeout in milliseconds (default `10_000`)
  - `:owner` - PID to receive `{:iec60870_file_server, server_pid, event}` notifications
  - `:file_ready_handler` - `fn ca, ioa, nof, lof -> :ok | {:error, :unknown_ca | :unknown_ioa | :not_ready} end`
  - `:file_received_handler` - `fn %Receiver{} -> any() end`
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Adds or replaces an available `%TransparentFile{}` on the server.
  """
  @spec add_file(GenServer.server(), TransparentFile.t()) :: :ok
  def add_file(server, %TransparentFile{} = file) do
    GenServer.call(server, {:add_file, file})
  end

  @doc """
  Removes a file by `{ca, ioa, nof}`.
  """
  @spec remove_file(GenServer.server(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def remove_file(server, ca, ioa, nof) do
    GenServer.call(server, {:remove_file, ca, ioa, nof})
  end

  @doc """
  Returns a map of all files received from the Master (`%{{ca, ioa, nof} => binary()}`).
  """
  @spec get_received_files(GenServer.server()) :: map()
  def get_received_files(server) do
    GenServer.call(server, :get_received_files)
  end

  @doc """
  Processes a received ASDU from `CS104.Slave` or `CS101.Slave`.
  Returns `true` if the ASDU is a file service ASDU and was handled, or `false` otherwise.
  """
  @spec handle_asdu(GenServer.server(), pid(), ASDU.t()) :: boolean()
  def handle_asdu(server, conn_pid, %ASDU{type_id: type_id} = asdu) do
    if type_id in @file_type_ids do
      GenServer.call(server, {:handle_asdu, conn_pid, asdu})
    else
      false
    end
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    initial_files =
      opts
      |> Keyword.get(:files, [])
      |> Map.new(fn %TransparentFile{} = f -> {{f.ca, f.ioa, f.nof}, f} end)

    tick_ref = Process.send_after(self(), :tick, 200)

    state = %__MODULE__{
      files: initial_files,
      max_segment_size: Keyword.get(opts, :max_segment_size, 200),
      timeout_ms: Keyword.get(opts, :timeout_ms, 3_000),
      owner: Keyword.get(opts, :owner),
      file_ready_handler: Keyword.get(opts, :file_ready_handler),
      file_received_handler: Keyword.get(opts, :file_received_handler),
      last_activity_time: now_ms(),
      tick_ref: tick_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_file, %TransparentFile{} = f}, _from, state) do
    {:reply, :ok, %{state | files: Map.put(state.files, {f.ca, f.ioa, f.nof}, f)}}
  end

  def handle_call({:remove_file, ca, ioa, nof}, _from, state) do
    {:reply, :ok, %{state | files: Map.delete(state.files, {ca, ioa, nof})}}
  end

  def handle_call(:get_received_files, _from, state) do
    {:reply, state.received_files, state}
  end

  def handle_call({:handle_asdu, conn_pid, asdu}, _from, state) do
    now = now_ms()
    state = check_transfer_timeout(state, now)
    {handled?, next_state} = process_file_asdu(state, conn_pid, asdu, now)
    {:reply, handled?, next_state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = now_ms()
    state = check_transfer_timeout(state, now)
    tick_ref = Process.send_after(self(), :tick, 200)
    {:noreply, %{state | tick_ref: tick_ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp check_transfer_timeout(state, now) do
    if state.state != :unselected_idle and now > state.last_activity_time + state.timeout_ms do
      if state.selected_file && is_function(state.selected_file.on_complete, 1) do
        state.selected_file.on_complete.(false)
      end

      %{
        state
        | state: :unselected_idle,
          selected_file: nil,
          selected_conn: nil,
          file_receiver: nil
      }
    else
      state
    end
  end

  # ===========================================================================
  # Protocol State Machine (`CS101_FileServer_handleAsdu`)
  # ===========================================================================

  # 1. Master initiates file download to Slave (`F_FR_NA_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: :f_fr_na_1, cot: cot, ca: ca, oa: oa} = asdu,
         now
       ) do
    if cot != :file_transfer do
      MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
      {true, state}
    else
      case List.first(asdu.objects) do
        %{ioa: ioa, nof: nof, length_of_file: lof} ->
          allow_res =
            if is_function(state.file_ready_handler, 4) do
              state.file_ready_handler.(ca, ioa, nof, lof)
            else
              :ok
            end

          case allow_res do
            :ok ->
              receiver = Receiver.new(ca, ioa, nof, lof)
              send_call_file(conn_pid, oa, ca, ioa, nof)

              new_state = %{
                state
                | state: :waiting_for_section_ready,
                  file_receiver: receiver,
                  ca: ca,
                  ioa: ioa,
                  oa: oa,
                  nof: nof,
                  file_checksum: 0,
                  last_activity_time: now
              }

              {true, new_state}

            {:error, :unknown_ca} ->
              MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_ca, is_negative: true})
              {true, state}

            {:error, :unknown_ioa} ->
              MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_ioa, is_negative: true})
              {true, state}

            _ ->
              send_file_ready(conn_pid, oa, ca, ioa, nof, 0, false)
              {true, state}
          end

        _ ->
          {false, state}
      end
    end
  end

  # 2. Master announces Section Ready during file download (`F_SR_NA_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: :f_sr_na_1, cot: cot, oa: oa} = asdu,
         now
       ) do
    cond do
      cot != :file_transfer ->
        MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
        {true, state}

      state.state != :waiting_for_section_ready ->
        {true, state}

      true ->
        case List.first(asdu.objects) do
          %{nos: nos, length_of_section: los} ->
            send_call_section(conn_pid, oa, state.ca, state.ioa, state.nof, nos)

            new_state = %{
              state
              | state: :receive_section,
                current_section_number: nos,
                current_section_size: los,
                current_section_offset: 0,
                section_checksum: 0,
                last_activity_time: now
            }

            {true, new_state}

          _ ->
            {false, state}
        end
    end
  end

  # 3. Master sends Segment during file download (`F_SG_NA_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: :f_sg_na_1, cot: cot} = asdu,
         now
       ) do
    cond do
      cot != :file_transfer ->
        MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
        {true, state}

      state.state != :receive_section ->
        {true, state}

      true ->
        case List.first(asdu.objects) do
          %{nos: nos, data: seg_data} ->
            los = byte_size(seg_data)

            receiver =
              if state.file_receiver do
                Receiver.put_segment(
                  state.file_receiver,
                  nos,
                  state.current_section_offset,
                  seg_data
                )
              else
                nil
              end

            sec_chs = state.section_checksum + calc_checksum(seg_data) &&& 0xFF

            new_state = %{
              state
              | file_receiver: receiver,
                current_section_offset: state.current_section_offset + los,
                section_checksum: sec_chs,
                last_activity_time: now
            }

            {true, new_state}

          _ ->
            {false, state}
        end
    end
  end

  # 4. Master sends Last Segment / Last Section (`F_LS_NA_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: :f_ls_na_1, cot: cot, oa: oa} = asdu,
         now
       ) do
    if cot != :file_transfer do
      MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
      {true, state}
    else
      case List.first(asdu.objects) do
        %{nos: nos, lsq: lsq, chs: chs} ->
          cond do
            state.state == :receive_section and lsq == 3 ->
              if chs == state.section_checksum do
                send_file_ack(conn_pid, oa, state.ca, state.ioa, state.nof, nos, 3)

                new_state = %{
                  state
                  | state: :waiting_for_section_ready,
                    file_checksum: state.file_checksum + state.section_checksum &&& 0xFF,
                    section_checksum: 0,
                    last_activity_time: now
                }

                {true, new_state}
              else
                send_file_ack(conn_pid, oa, state.ca, state.ioa, state.nof, nos, 4)

                {true,
                 %{
                   state
                   | state: :waiting_for_section_ready,
                     section_checksum: 0,
                     last_activity_time: now
                 }}
              end

            state.state == :waiting_for_section_ready and lsq == 1 ->
              if chs == state.file_checksum do
                send_file_ack(conn_pid, oa, state.ca, state.ioa, state.nof, nos, 1)

                state =
                  if state.file_receiver do
                    bin = Receiver.to_binary(state.file_receiver)
                    key = {state.ca, state.ioa, state.nof}

                    rec_file = %TransparentFile{
                      ca: state.ca,
                      ioa: state.ioa,
                      nof: state.nof,
                      name: "file_#{state.nof}",
                      data: bin,
                      sections: [bin]
                    }

                    cond do
                      is_function(state.file_received_handler, 2) ->
                        state.file_received_handler.(self(), rec_file)

                      is_function(state.file_received_handler, 1) ->
                        state.file_received_handler.(rec_file)

                      true ->
                        :ok
                    end

                    if is_pid(state.owner) do
                      send(
                        state.owner,
                        {:iec60870_file_server, self(), {:file_received, key, bin}}
                      )
                    end

                    %{state | received_files: Map.put(state.received_files, key, bin)}
                  else
                    state
                  end

                {true,
                 %{state | state: :unselected_idle, file_receiver: nil, last_activity_time: now}}
              else
                # File checksum mismatch -> send negative file ACK (afq = 2)
                send_file_ack(conn_pid, oa, state.ca, state.ioa, state.nof, nos, 2)

                {true,
                 %{state | state: :unselected_idle, file_receiver: nil, last_activity_time: now}}
              end

            lsq in [2, 4] ->
              # Aborted by remote
              {true,
               %{state | state: :unselected_idle, file_receiver: nil, last_activity_time: now}}

            true ->
              {true, state}
          end

        _ ->
          {false, state}
      end
    end
  end

  # 5. Master sends File / Section ACK during file upload (`F_AF_NA_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: :f_af_na_1, cot: cot, oa: oa} = asdu,
         now
       ) do
    cond do
      cot != :file_transfer ->
        MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
        {true, state}

      state.state == :unselected_idle ->
        MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_ca})
        {true, state}

      true ->
        case List.first(asdu.objects) do
          %{afq: afq} ->
            low_afq = afq &&& 0x0F

            cond do
              low_afq == 1 and state.state == :waiting_for_file_ack ->
                # Positive File ACK
                if state.selected_file && is_function(state.selected_file.on_complete, 1) do
                  state.selected_file.on_complete.(true)
                end

                if is_pid(state.owner) do
                  send(
                    state.owner,
                    {:iec60870_file_server, self(),
                     {:file_upload_complete, {state.ca, state.ioa, state.nof}, true}}
                  )
                end

                {true,
                 %{
                   state
                   | state: :unselected_idle,
                     selected_file: nil,
                     selected_conn: nil,
                     last_activity_time: now
                 }}

              low_afq == 2 and state.state == :waiting_for_file_ack ->
                # Negative File ACK
                if state.selected_file && is_function(state.selected_file.on_complete, 1) do
                  state.selected_file.on_complete.(false)
                end

                {true,
                 %{
                   state
                   | state: :unselected_idle,
                     selected_file: nil,
                     selected_conn: nil,
                     last_activity_time: now
                 }}

              low_afq == 4 and state.state == :waiting_for_section_ack ->
                # Negative Section ACK -> repeat current section
                send_section_ready(
                  conn_pid,
                  oa,
                  state.ca,
                  state.ioa,
                  state.nof,
                  state.current_section_number,
                  state.current_section_size
                )

                {true,
                 %{
                   state
                   | state: :waiting_for_section_call,
                     current_section_offset: 0,
                     section_checksum: 0,
                     last_activity_time: now
                 }}

              low_afq == 3 and state.state == :waiting_for_section_ack ->
                # Positive Section ACK -> advance to next section or send last section
                next_sec_no = state.current_section_number + 1
                next_sec_size = TransparentFile.section_size(state.selected_file, next_sec_no - 1)

                if next_sec_size <= 0 do
                  send_last_section(
                    conn_pid,
                    oa,
                    state.ca,
                    state.ioa,
                    state.nof,
                    state.current_section_number,
                    state.file_checksum
                  )

                  {true,
                   %{
                     state
                     | state: :waiting_for_file_ack,
                       current_section_offset: 0,
                       section_checksum: 0,
                       last_activity_time: now
                   }}
                else
                  send_section_ready(
                    conn_pid,
                    oa,
                    state.ca,
                    state.ioa,
                    state.nof,
                    next_sec_no,
                    next_sec_size
                  )

                  {true,
                   %{
                     state
                     | state: :waiting_for_section_call,
                       current_section_number: next_sec_no,
                       current_section_size: next_sec_size,
                       current_section_offset: 0,
                       section_checksum: 0,
                       last_activity_time: now
                   }}
                end

              true ->
                {true, %{state | state: :unselected_idle}}
            end

          _ ->
            {false, state}
        end
    end
  end

  # 6. Master sends Call / Select (`F_SC_NA_1` or `F_SC_NB_1`)
  defp process_file_asdu(
         state,
         conn_pid,
         %ASDU{type_id: type_id, cot: cot, ca: ca, oa: oa, is_negative: is_neg} = asdu,
         now
       )
       when type_id in [:f_sc_na_1, :f_sc_nb_1] do
    cond do
      cot == :request ->
        # Directory read request (`F_SC_NA_1` with COT=REQUEST or `F_SC_NB_1` with COT=REQUEST)
        {ioa, time_range} =
          case List.first(asdu.objects) do
            %{ioa: addr, range_start_time: start_t, range_stop_time: stop_t} ->
              {addr, {start_t, stop_t}}

            %{ioa: addr} ->
              {addr, nil}

            _ ->
              {0, nil}
          end

        send_directory_entries(state, conn_pid, oa, ca, ioa, time_range)
        {true, state}

      cot == :file_transfer and type_id == :f_sc_na_1 ->
        case List.first(asdu.objects) do
          %{ioa: ioa, nof: nof, nos: nos, scq: scq} ->
            low_scq = scq &&& 0x0F

            case low_scq do
              1 ->
                # SELECT_FILE
                case Map.get(state.files, {ca, ioa, nof}) do
                  nil ->
                    send_file_ready(conn_pid, oa, ca, ioa, nof, 0, false)
                    {true, state}

                  %TransparentFile{} = file ->
                    fsize = TransparentFile.file_size(file)
                    send_file_ready(conn_pid, oa, ca, ioa, nof, fsize, true)

                    new_state = %{
                      state
                      | state: :waiting_for_file_call,
                        selected_file: file,
                        selected_conn: conn_pid,
                        ca: ca,
                        ioa: ioa,
                        oa: oa,
                        nof: nof,
                        last_activity_time: now
                    }

                    {true, new_state}
                end

              2 ->
                # REQUEST_FILE (Call File)
                if state.state == :waiting_for_file_call do
                  if ioa != state.ioa or ca != state.ca do
                    err_cot = if ca != state.ca, do: :unknown_ca, else: :unknown_ioa

                    MasterConnection.send_asdu(conn_pid, %{asdu | cot: err_cot, is_negative: true})

                    {true, state}
                  else
                    sec1_size = TransparentFile.section_size(state.selected_file, 0)
                    send_section_ready(conn_pid, oa, ca, ioa, nof, 1, sec1_size)

                    new_state = %{
                      state
                      | state: :waiting_for_section_call,
                        current_section_number: 1,
                        current_section_offset: 0,
                        current_section_size: sec1_size,
                        section_checksum: 0,
                        file_checksum: 0,
                        last_activity_time: now
                    }

                    {true, new_state}
                  end
                else
                  {true, state}
                end

              3 ->
                # DEACTIVATE_FILE
                {true,
                 %{
                   state
                   | state: :unselected_idle,
                     selected_file: nil,
                     selected_conn: nil,
                     last_activity_time: now
                 }}

              6 ->
                # REQUEST_SECTION (Call Section)
                if state.state == :waiting_for_section_call do
                  if ioa != state.ioa or ca != state.ca do
                    err_cot = if ca != state.ca, do: :unknown_ca, else: :unknown_ioa

                    MasterConnection.send_asdu(conn_pid, %{asdu | cot: err_cot, is_negative: true})

                    {true, state}
                  else
                    if is_neg do
                      # Skip section and advance to next
                      next_sec = state.current_section_number + 1
                      next_size = TransparentFile.section_size(state.selected_file, next_sec - 1)

                      if next_size > 0 do
                        send_section_ready(conn_pid, oa, ca, ioa, nof, next_sec, next_size)

                        {true,
                         %{
                           state
                           | state: :waiting_for_section_call,
                             current_section_number: next_sec,
                             current_section_size: next_size,
                             current_section_offset: 0,
                             last_activity_time: now
                         }}
                      else
                        send_last_section(
                          conn_pid,
                          oa,
                          ca,
                          ioa,
                          nof,
                          state.current_section_number,
                          state.file_checksum
                        )

                        {true, %{state | state: :waiting_for_file_ack, last_activity_time: now}}
                      end
                    else
                      sec_size = TransparentFile.section_size(state.selected_file, nos - 1)

                      if sec_size > 0 do
                        state1 = %{
                          state
                          | current_section_number: nos,
                            current_section_size: sec_size,
                            current_section_offset: 0,
                            section_checksum: 0,
                            last_activity_time: now
                        }

                        state2 = transmit_all_segments(state1, conn_pid, oa)
                        {true, state2}
                      else
                        MasterConnection.send_asdu(conn_pid, %{asdu | is_negative: true})
                        {true, state}
                      end
                    end
                  end
                else
                  {true, state}
                end

              _ ->
                {true, state}
            end

          _ ->
            {false, state}
        end

      true ->
        MasterConnection.send_asdu(conn_pid, %{asdu | cot: :unknown_cot, is_negative: true})
        {true, state}
    end
  end

  defp process_file_asdu(state, _conn_pid, _asdu, _now), do: {false, state}

  # ===========================================================================
  # Transmission Helpers
  # ===========================================================================

  defp transmit_all_segments(state, conn_pid, oa) do
    remaining = state.current_section_size - state.current_section_offset

    if remaining > 0 do
      seg_size = min(remaining, state.max_segment_size)

      {:ok, seg_data} =
        TransparentFile.get_segment_data(
          state.selected_file,
          state.current_section_number - 1,
          state.current_section_offset,
          seg_size
        )

      io = FileIO.file_segment(state.ioa, state.nof, state.current_section_number, seg_data)

      asdu =
        ASDU.new(:f_sg_na_1,
          cot: :file_transfer,
          oa: oa,
          ca: state.ca,
          information_objects: [io]
        )

      MasterConnection.send_asdu(conn_pid, asdu)

      new_sec_chs = state.section_checksum + calc_checksum(seg_data) &&& 0xFF

      state1 = %{
        state
        | current_section_offset: state.current_section_offset + seg_size,
          section_checksum: new_sec_chs
      }

      transmit_all_segments(state1, conn_pid, oa)
    else
      # All segments of section sent -> send F_LS_NA_1 (lsq = 3: section-transfer-without-deact)
      io =
        FileIO.file_last_segment_or_section(
          state.ioa,
          state.nof,
          state.current_section_number,
          3,
          state.section_checksum
        )

      asdu =
        ASDU.new(:f_ls_na_1,
          cot: :file_transfer,
          oa: oa,
          ca: state.ca,
          information_objects: [io]
        )

      MasterConnection.send_asdu(conn_pid, asdu)

      %{
        state
        | state: :waiting_for_section_ack,
          file_checksum: state.file_checksum + state.section_checksum &&& 0xFF,
          section_checksum: 0,
          last_activity_time: now_ms()
      }
    end
  end

  defp send_directory_entries(state, conn_pid, oa, ca, ioa, time_range) do
    matching_files =
      state.files
      |> Map.values()
      |> Enum.filter(fn f ->
        f.ca == ca and (ioa == 0 or f.ioa == ioa) and matches_time_range?(f, time_range)
      end)
      |> Enum.sort_by(& &1.nof)

    if matching_files == [] do
      # Matches sendDirectory in file_server.c:366-389:
      # When directory is empty, send a single F_DR_TA_1 with NOF=0, length=0, SOF=0x20 (last file)
      empty_ts = IEC60870.Types.CPTime.CP56Time2a.from_ms_timestamp(0)
      io = FileIO.file_directory(ioa, 0, 0, 0x20, empty_ts)

      asdu =
        ASDU.new(:f_dr_ta_1,
          cot: :request,
          oa: oa,
          ca: ca,
          information_objects: [io]
        )

      MasterConnection.send_asdu(conn_pid, asdu)
    else
      total = length(matching_files)

      matching_files
      |> Enum.with_index(1)
      |> Enum.each(fn {file, idx} ->
        is_last = idx == total
        sof = if is_last, do: file.sof ||| 0x20, else: file.sof &&& 0xDF

        io =
          FileIO.file_directory(
            file.ioa,
            file.nof,
            TransparentFile.file_size(file),
            sof,
            file.created_at
          )

        asdu =
          ASDU.new(:f_dr_ta_1,
            cot: :request,
            oa: oa,
            ca: ca,
            information_objects: [io]
          )

        MasterConnection.send_asdu(conn_pid, asdu)
      end)
    end
  end

  defp matches_time_range?(_file, nil), do: true

  defp matches_time_range?(%TransparentFile{created_at: created_at}, {start_t, stop_t}) do
    alias IEC60870.Types.CPTime.CP56Time2a
    file_ms = CP56Time2a.to_ms_timestamp(created_at)
    start_ms = CP56Time2a.to_ms_timestamp(start_t)
    stop_ms = CP56Time2a.to_ms_timestamp(stop_t)
    file_ms >= start_ms and file_ms <= stop_ms
  end

  defp send_file_ready(conn_pid, oa, ca, ioa, nof, lof, positive) do
    io = FileIO.file_ready(ioa, nof, lof, positive)
    asdu = ASDU.new(:f_fr_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp send_call_file(conn_pid, oa, ca, ioa, nof) do
    io = FileIO.file_call_or_select(ioa, nof, 0, 2)
    asdu = ASDU.new(:f_sc_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp send_call_section(conn_pid, oa, ca, ioa, nof, nos) do
    io = FileIO.file_call_or_select(ioa, nof, nos, 6)
    asdu = ASDU.new(:f_sc_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp send_section_ready(conn_pid, oa, ca, ioa, nof, nos, los) do
    io = FileIO.section_ready(ioa, nof, nos, los, false)
    asdu = ASDU.new(:f_sr_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp send_last_section(conn_pid, oa, ca, ioa, nof, nos, file_checksum) do
    io = FileIO.file_last_segment_or_section(ioa, nof, nos, 1, file_checksum)
    asdu = ASDU.new(:f_ls_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp send_file_ack(conn_pid, oa, ca, ioa, nof, nos, afq) do
    io = FileIO.file_ack(ioa, nof, nos, afq)
    asdu = ASDU.new(:f_af_na_1, cot: :file_transfer, oa: oa, ca: ca, information_objects: [io])
    MasterConnection.send_asdu(conn_pid, asdu)
  end

  defp calc_checksum(bin) when is_binary(bin) do
    for(<<b::8 <- bin>>, reduce: 0, do: (acc -> acc + b &&& 0xFF))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
