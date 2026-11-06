defmodule IEC60870.CS101.LinkLayer do
  @moduledoc """
  IEC 60870-5-101 Link Layer state machines (`link_layer.c`), supporting:
  - `SecondaryUnbalanced` (Slave in `:unbalanced` mode)
  - `PrimaryUnbalanced` (Master in `:unbalanced` mode, supporting multiple slaves)
  - `Balanced` (Full-duplex Primary + Secondary for both Master and Slave in `:balanced` mode)
  """

  alias IEC60870.CS101.Frame
  alias IEC60870.LinkLayerParameters

  @type link_state :: :idle | :error | :busy | :available

  def broadcast_address(%LinkLayerParameters{address_length: 1}), do: 255
  def broadcast_address(%LinkLayerParameters{address_length: 2}), do: 65535
  def broadcast_address(_), do: 0

  def is_broadcast?(%LinkLayerParameters{address_length: 1}, 255), do: true
  def is_broadcast?(%LinkLayerParameters{address_length: 2}, 65535), do: true
  def is_broadcast?(_, _), do: false

  # ===========================================================================
  # Secondary Unbalanced State Machine (CS101 Slave in Unbalanced Mode)
  # ===========================================================================

  defmodule SecondaryUnbalanced do
    @moduledoc false
    alias IEC60870.CS101.{Frame, LinkLayer}
    alias IEC60870.LinkLayerParameters

    defstruct [
      :address,
      :ll_params,
      state: :idle,
      expected_fcb: true,
      last_sent_asdu_bin: nil,
      last_received_msg: 0,
      idle_timeout: 500
    ]

    def new(address, %LinkLayerParameters{} = ll_params, idle_timeout \\ 500) do
      %__MODULE__{
        address: address,
        ll_params: ll_params,
        idle_timeout: idle_timeout
      }
    end

    @doc """
    Handles an incoming FT 1.2 frame on an unbalanced slave.
    `callbacks` is a map with:
    - `:is_class_1_available` :: `(app_state -> boolean())`
    - `:pop_class_1_data` :: `(app_state -> {binary() | nil, app_state})`
    - `:pop_class_2_data` :: `(app_state -> {binary() | nil, app_state})`
    - `:handle_user_data` :: `(app_state, binary(), boolean() -> app_state)`
    - `:reset_cu_received` :: `(app_state, boolean() -> app_state)`
    Returns `{updated_ll, updated_app_state, frames_to_send, state_changes}`.
    """
    def handle_frame(%__MODULE__{} = ll, frame, app_state, callbacks, now_ms) do
      case frame do
        :single_char_ack ->
          set_state(ll, :error, app_state, [])

        {frame_kind, ctrl, addr} when frame_kind == :fixed_frame ->
          process_addressed_frame(ll, ctrl, addr, nil, app_state, callbacks, now_ms)

        {:variable_frame, ctrl, addr, user_data} ->
          process_addressed_frame(ll, ctrl, addr, user_data, app_state, callbacks, now_ms)
      end
    end

    def check_idle_timeout(%__MODULE__{state: :idle} = ll, _now_ms), do: {ll, []}

    def check_idle_timeout(%__MODULE__{} = ll, now_ms) do
      if now_ms - ll.last_received_msg > ll.idle_timeout do
        {%{ll | state: :idle}, [{-1, :idle}]}
      else
        {ll, []}
      end
    end

    defp process_addressed_frame(ll, ctrl, addr, user_data, app_state, callbacks, now_ms) do
      is_bcast = LinkLayer.is_broadcast?(ll.ll_params, addr)

      cond do
        is_bcast and ctrl.fc != Frame.fc_user_data_no_reply() ->
          set_state(%{ll | last_received_msg: now_ms}, :error, app_state, [])

        not is_bcast and addr != ll.address ->
          # Frame for another slave on the multidrop bus -> ignore
          {ll, app_state, [], []}

        not ctrl.prm ->
          set_state(%{ll | last_received_msg: now_ms}, :error, app_state, [])

        true ->
          {ll1, changes} = update_link_state(%{ll | last_received_msg: now_ms}, :available)
          dispatch_fc(ll1, ctrl, is_bcast, user_data, app_state, callbacks, changes)
      end
    end

    defp dispatch_fc(ll, %{fc: 9, fcv_or_dfc: fcv}, _is_bcast, _ud, app_state, callbacks, changes) do
      # LL_FC_09_REQUEST_LINK_STATUS
      if fcv do
        set_state(ll, :error, app_state, changes)
      else
        acd = callbacks.is_class_1_available.(app_state)

        reply =
          fixed_reply(ll.address, Frame.fc_status_of_link_or_access_demand(), false, acd, false)

        {ll, app_state, [reply], changes}
      end
    end

    defp dispatch_fc(
           ll,
           %{fc: 0, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           _is_bcast,
           _ud,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_00_RESET_REMOTE_LINK
      if fcb or fcv do
        set_state(ll, :error, app_state, changes)
      else
        ll = %{ll | expected_fcb: true, last_sent_asdu_bin: nil}
        app_state = callbacks.reset_cu_received.(app_state, false)
        reply = ack_or_single_char(ll, false)
        {ll, app_state, [reply], changes}
      end
    end

    defp dispatch_fc(
           ll,
           %{fc: 1, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           _is_bcast,
           _ud,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_01_RESET_USER_PROCESS (IEC 60870-5-1 Section 6.2.4)
      if fcb or fcv do
        set_state(ll, :error, app_state, changes)
      else
        ll = %{ll | expected_fcb: true, last_sent_asdu_bin: nil}
        app_state = callbacks.reset_cu_received.(app_state, false)
        reply = ack_or_single_char(ll, false)
        {ll, app_state, [reply], changes}
      end
    end

    defp dispatch_fc(
           ll,
           %{fc: 2, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           _is_bcast,
           _ud,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_02_TEST_FUNCTION_FOR_LINK (IEC 60870-5-2 Section 5.2.2)
      {ll, _invalid_fcb?} = check_fcb(ll, fcv, fcb)
      acd = callbacks.is_class_1_available.(app_state)
      reply = ack_or_single_char(ll, acd)
      {ll, app_state, [reply], changes}
    end

    defp dispatch_fc(
           ll,
           %{fc: 7, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           _is_bcast,
           _ud,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_07_RESET_FCB
      if fcb or fcv do
        set_state(ll, :error, app_state, changes)
      else
        ll = %{ll | expected_fcb: true}
        app_state = callbacks.reset_cu_received.(app_state, true)
        reply = ack_or_single_char(ll, false)
        {ll, app_state, [reply], changes}
      end
    end

    defp dispatch_fc(
           ll,
           %{fc: fc, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           _is_bcast,
           _ud,
           app_state,
           callbacks,
           changes
         )
         when fc in [10, 11] do
      # FC 10 (Class 1) or FC 11 (Class 2)
      {ll, invalid_fcb?} = check_fcb(ll, fcv, fcb)

      {asdu_bin, ll, app_state} =
        if invalid_fcb? do
          {ll.last_sent_asdu_bin, ll, app_state}
        else
          {bin, next_app_state} =
            if fc == 10 do
              callbacks.pop_class_1_data.(app_state)
            else
              callbacks.pop_class_2_data.(app_state)
            end

          {bin, %{ll | last_sent_asdu_bin: bin}, next_app_state}
        end

      acd = callbacks.is_class_1_available.(app_state)

      reply =
        if is_binary(asdu_bin) and byte_size(asdu_bin) > 0 do
          variable_reply(ll.address, Frame.fc_resp_user_data(), false, acd, false, asdu_bin)
        else
          if ll.ll_params.use_single_char_ack and not acd do
            :single_char_ack
          else
            fixed_reply(ll.address, Frame.fc_resp_nack_no_data(), false, acd, false)
          end
        end

      {ll, app_state, [reply], changes}
    end

    defp dispatch_fc(
           ll,
           %{fc: 3, fcb_or_acd: fcb, fcv_or_dfc: fcv},
           is_bcast,
           user_data,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_03_USER_DATA_CONFIRMED
      {ll, invalid_fcb?} = check_fcb(ll, fcv, fcb)

      app_state =
        if not invalid_fcb? and is_binary(user_data) and byte_size(user_data) > 0 do
          callbacks.handle_user_data.(app_state, user_data, is_bcast)
        else
          app_state
        end

      acd = callbacks.is_class_1_available.(app_state)
      reply = ack_or_single_char(ll, acd)
      {ll, app_state, [reply], changes}
    end

    defp dispatch_fc(
           ll,
           %{fc: 4, fcv_or_dfc: fcv},
           is_bcast,
           user_data,
           app_state,
           callbacks,
           changes
         ) do
      # LL_FC_04_USER_DATA_NO_REPLY
      if fcv do
        set_state(ll, :error, app_state, changes)
      else
        app_state =
          if is_binary(user_data) and byte_size(user_data) > 0 do
            callbacks.handle_user_data.(app_state, user_data, is_bcast)
          else
            app_state
          end

        {ll, app_state, [], changes}
      end
    end

    defp dispatch_fc(ll, _ctrl, _is_bcast, _ud, app_state, _callbacks, changes) do
      reply = fixed_reply(ll.address, Frame.fc_service_not_implemented(), false, false, false)
      {ll, app_state, [reply], changes}
    end

    defp check_fcb(ll, false, _fcb), do: {ll, false}

    defp check_fcb(ll, true, fcb) do
      if fcb == ll.expected_fcb do
        {%{ll | expected_fcb: not ll.expected_fcb}, false}
      else
        {ll, true}
      end
    end

    defp ack_or_single_char(ll, acd) do
      if ll.ll_params.use_single_char_ack and not acd do
        :single_char_ack
      else
        fixed_reply(ll.address, Frame.fc_ack(), false, acd, false)
      end
    end

    defp fixed_reply(address, fc, dir, acd, dfc) do
      {:fixed_frame, %{dir: dir, prm: false, fcb_or_acd: acd, fcv_or_dfc: dfc, fc: fc}, address}
    end

    defp variable_reply(address, fc, dir, acd, dfc, user_data) do
      {:variable_frame, %{dir: dir, prm: false, fcb_or_acd: acd, fcv_or_dfc: dfc, fc: fc},
       address, user_data}
    end

    defp update_link_state(%__MODULE__{state: old_state} = ll, new_state) do
      if old_state == new_state do
        {ll, []}
      else
        {%{ll | state: new_state}, [{-1, new_state}]}
      end
    end

    defp set_state(ll, new_state, app_state, prev_changes) do
      {ll1, more_changes} = update_link_state(ll, new_state)
      {ll1, app_state, [], prev_changes ++ more_changes}
    end
  end

  # ===========================================================================
  # Primary Unbalanced State Machine (CS101 Master in Unbalanced Mode)
  # ===========================================================================

  defmodule PrimaryUnbalanced do
    @moduledoc false
    alias IEC60870.CS101.{Frame, LinkLayer}
    alias IEC60870.LinkLayerParameters

    defmodule SlaveConn do
      @moduledoc false
      defstruct [
        :address,
        state: :idle,
        primary_state: :pll_idle,
        next_fcb: true,
        waiting_for_response: false,
        last_send_time: 0,
        original_send_time: 0,
        request_class_1: false,
        request_class_2: false,
        send_link_test: false,
        pending_messages: :queue.new(),
        active_message: nil,
        active_req_fc: nil,
        dont_send_messages: false
      ]
    end

    defstruct [
      :ll_params,
      slaves: %{},
      slave_order: [],
      current_slave: nil,
      current_idx: 0,
      broadcast_queue: :queue.new()
    ]

    def new(%LinkLayerParameters{} = ll_params) do
      %__MODULE__{ll_params: ll_params}
    end

    def add_slave(%__MODULE__{} = pll, slave_addr) do
      if Map.has_key?(pll.slaves, slave_addr) do
        pll
      else
        sc = %SlaveConn{address: slave_addr}

        %{
          pll
          | slaves: Map.put(pll.slaves, slave_addr, sc),
            slave_order: pll.slave_order ++ [slave_addr]
        }
      end
    end

    def is_channel_available?(%__MODULE__{} = pll, slave_addr) do
      case Map.get(pll.slaves, slave_addr) do
        nil ->
          false

        sc ->
          not sc.request_class_1 and not sc.request_class_2 and
            sc.active_message == nil and :queue.is_empty(sc.pending_messages)
      end
    end

    def request_class_1(%__MODULE__{} = pll, slave_addr) do
      update_slave(pll, slave_addr, fn sc -> %{sc | request_class_1: true} end)
    end

    def request_class_2(%__MODULE__{} = pll, slave_addr) do
      update_slave(pll, slave_addr, fn sc -> %{sc | request_class_2: true} end)
    end

    def send_link_test(%__MODULE__{} = pll, slave_addr) do
      update_slave(pll, slave_addr, fn sc -> %{sc | send_link_test: true} end)
    end

    def enqueue_confirmed(%__MODULE__{} = pll, slave_addr, asdu_bin) do
      pll = add_slave(pll, slave_addr)

      update_slave(pll, slave_addr, fn sc ->
        %{sc | pending_messages: :queue.in(asdu_bin, sc.pending_messages)}
      end)
    end

    def enqueue_no_reply(%__MODULE__{} = pll, slave_addr, asdu_bin) do
      if LinkLayer.is_broadcast?(pll.ll_params, slave_addr) do
        %{pll | broadcast_queue: :queue.in({slave_addr, asdu_bin}, pll.broadcast_queue)}
      else
        enqueue_confirmed(pll, slave_addr, asdu_bin)
      end
    end

    @doc """
    Handles an incoming secondary frame (`PRM = 0` or `:single_char_ack`) on the Unbalanced Master.
    Returns `{updated_pll, user_data_events, state_changes}` where:
    - `user_data_events` is `[{slave_addr, asdu_bin}]`
    - `state_changes` is `[{slave_addr, new_link_state}]`
    """
    def handle_frame(%__MODULE__{} = pll, frame, now_ms) do
      case frame do
        :single_char_ack ->
          if pll.current_slave != nil do
            ctrl = %{
              dir: false,
              prm: false,
              fcb_or_acd: false,
              fcv_or_dfc: false,
              fc: Frame.fc_ack()
            }

            handle_slave_response(pll, pll.current_slave, ctrl, nil, now_ms)
          else
            {pll, [], []}
          end

        {:fixed_frame, %{prm: false} = ctrl, addr} ->
          target = if pll.ll_params.address_length == 0, do: pll.current_slave, else: addr
          handle_slave_response(pll, target, ctrl, nil, now_ms)

        {:variable_frame, %{prm: false} = ctrl, addr, user_data} ->
          target = if pll.ll_params.address_length == 0, do: pll.current_slave, else: addr
          handle_slave_response(pll, target, ctrl, user_data, now_ms)

        _ ->
          {pll, [], []}
      end
    end

    @doc """
    Runs one step of the Primary Unbalanced state machine across configured slaves.
    Returns `{updated_pll, frames_to_send, state_changes}`.
    """
    def run(%__MODULE__{} = pll, now_ms) do
      # 1. Send any pending broadcast message first
      case :queue.out(pll.broadcast_queue) do
        {{:value, {bcast_addr, asdu_bin}}, rest_bcast} ->
          frame =
            {:variable_frame,
             %{
               dir: false,
               prm: true,
               fcb_or_acd: false,
               fcv_or_dfc: false,
               fc: Frame.fc_user_data_no_reply()
             }, bcast_addr, asdu_bin}

          {%{pll | broadcast_queue: rest_bcast}, [frame], []}

        {:empty, _} ->
          run_current_slave(pll, now_ms)
      end
    end

    defp run_current_slave(%__MODULE__{slave_order: []} = pll, _now_ms) do
      {pll, [], []}
    end

    defp run_current_slave(%__MODULE__{} = pll, now_ms) do
      slave_addr =
        if pll.current_slave != nil and Map.has_key?(pll.slaves, pll.current_slave) do
          pll.current_slave
        else
          Enum.at(pll.slave_order, rem(pll.current_idx, length(pll.slave_order)))
        end

      sc = Map.fetch!(pll.slaves, slave_addr)
      {sc1, frames, changes} = step_slave(sc, pll.ll_params, now_ms)
      pll1 = %{pll | current_slave: slave_addr, slaves: Map.put(pll.slaves, slave_addr, sc1)}

      # Advance round-robin pointer if this slave is not waiting for a response
      pll2 =
        if not sc1.waiting_for_response and length(pll1.slave_order) > 1 do
          next_idx = rem(pll1.current_idx + 1, length(pll1.slave_order))
          next_addr = Enum.at(pll1.slave_order, next_idx)
          %{pll1 | current_idx: next_idx, current_slave: next_addr}
        else
          pll1
        end

      {pll2, frames, changes}
    end

    defp step_slave(%SlaveConn{primary_state: :pll_timeout} = sc, ll_params, now_ms) do
      if now_ms - sc.last_send_time > ll_params.timeout_link_state do
        {%{sc | primary_state: :pll_idle}, [], []}
      else
        {sc, [], []}
      end
    end

    defp step_slave(%SlaveConn{primary_state: :pll_idle} = sc, _ll_params, now_ms) do
      frame =
        {:fixed_frame,
         %{
           dir: false,
           prm: true,
           fcb_or_acd: false,
           fcv_or_dfc: false,
           fc: Frame.fc_request_link_status()
         }, sc.address}

      sc1 = %{
        sc
        | original_send_time: 0,
          send_link_test: false,
          last_send_time: now_ms,
          waiting_for_response: true,
          primary_state: :pll_execute_request_status_of_link
      }

      {sc1, [frame], []}
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_execute_request_status_of_link} = sc,
           ll_params,
           now_ms
         ) do
      if sc.waiting_for_response do
        if now_ms - sc.last_send_time > ll_params.timeout_for_ack do
          {%{
             sc
             | waiting_for_response: false,
               last_send_time: now_ms,
               primary_state: :pll_timeout
           }, [], []}
        else
          {sc, [], []}
        end
      else
        {sc, [], []}
      end
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_send_reset_remote_link} = sc,
           _ll_params,
           now_ms
         ) do
      frame =
        {:fixed_frame,
         %{
           dir: false,
           prm: true,
           fcb_or_acd: false,
           fcv_or_dfc: false,
           fc: Frame.fc_reset_remote_link()
         }, sc.address}

      sc1 = %{
        sc
        | last_send_time: now_ms,
          waiting_for_response: true,
          next_fcb: true,
          primary_state: :pll_execute_reset_remote_link
      }

      {sc1, [frame], []}
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_execute_reset_remote_link} = sc,
           ll_params,
           now_ms
         ) do
      if sc.waiting_for_response do
        if now_ms - sc.last_send_time > ll_params.timeout_for_ack do
          {sc1, changes} =
            set_sc_state(
              %{
                sc
                | waiting_for_response: false,
                  last_send_time: now_ms,
                  primary_state: :pll_timeout
              },
              :error
            )

          {sc1, [], changes}
        else
          {sc, [], []}
        end
      else
        {sc1, changes} =
          set_sc_state(%{sc | primary_state: :pll_link_layers_available}, :available)

        {sc1, [], changes}
      end
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_link_layers_available} = sc,
           _ll_params,
           now_ms
         ) do
      sc = maybe_dequeue_pending_message(sc)

      cond do
        sc.send_link_test ->
          frame =
            {:fixed_frame,
             %{
               dir: false,
               prm: true,
               fcb_or_acd: sc.next_fcb,
               fcv_or_dfc: true,
               fc: Frame.fc_test_function_for_link()
             }, sc.address}

          sc1 = %{
            sc
            | next_fcb: not sc.next_fcb,
              last_send_time: now_ms,
              original_send_time: now_ms,
              waiting_for_response: true,
              active_req_fc: Frame.fc_test_function_for_link(),
              primary_state: :pll_execute_service_send_confirm
          }

          {sc1, [frame], []}

        sc.active_message != nil ->
          frame =
            {:variable_frame,
             %{
               dir: false,
               prm: true,
               fcb_or_acd: sc.next_fcb,
               fcv_or_dfc: true,
               fc: Frame.fc_user_data_confirmed()
             }, sc.address, sc.active_message}

          sc1 = %{
            sc
            | next_fcb: not sc.next_fcb,
              last_send_time: now_ms,
              original_send_time: now_ms,
              waiting_for_response: true,
              active_req_fc: Frame.fc_user_data_confirmed(),
              primary_state: :pll_execute_service_send_confirm
          }

          {sc1, [frame], []}

        sc.request_class_1 or sc.request_class_2 ->
          {fc, sc_updated} =
            if sc.request_class_1 do
              {Frame.fc_request_user_data_class_1(), %{sc | request_class_1: false}}
            else
              {Frame.fc_request_user_data_class_2(), %{sc | request_class_2: false}}
            end

          frame =
            {:fixed_frame,
             %{
               dir: false,
               prm: true,
               fcb_or_acd: sc_updated.next_fcb,
               fcv_or_dfc: true,
               fc: fc
             }, sc_updated.address}

          sc1 = %{
            sc_updated
            | next_fcb: not sc_updated.next_fcb,
              last_send_time: now_ms,
              original_send_time: now_ms,
              waiting_for_response: true,
              active_req_fc: fc,
              primary_state: :pll_execute_service_request_respond
          }

          {sc1, [frame], []}

        true ->
          {sc, [], []}
      end
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_execute_service_send_confirm} = sc,
           ll_params,
           now_ms
         ) do
      if now_ms - sc.last_send_time > ll_params.timeout_for_ack do
        if now_ms - sc.original_send_time > ll_params.timeout_repeat do
          {sc1, changes} =
            set_sc_state(
              %{
                sc
                | waiting_for_response: false,
                  last_send_time: now_ms,
                  active_message: nil,
                  send_link_test: false,
                  primary_state: :pll_timeout
              },
              :error
            )

          {sc1, [], changes}
        else
          # Repeat with previous FCB (!(next_fcb))
          prev_fcb = not sc.next_fcb

          frame =
            if sc.send_link_test do
              {:fixed_frame,
               %{
                 dir: false,
                 prm: true,
                 fcb_or_acd: prev_fcb,
                 fcv_or_dfc: true,
                 fc: Frame.fc_test_function_for_link()
               }, sc.address}
            else
              {:variable_frame,
               %{
                 dir: false,
                 prm: true,
                 fcb_or_acd: prev_fcb,
                 fcv_or_dfc: true,
                 fc: Frame.fc_user_data_confirmed()
               }, sc.address, sc.active_message}
            end

          {%{sc | last_send_time: now_ms}, [frame], []}
        end
      else
        {sc, [], []}
      end
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_execute_service_request_respond} = sc,
           ll_params,
           now_ms
         ) do
      if now_ms - sc.last_send_time > ll_params.timeout_for_ack do
        if now_ms - sc.original_send_time > ll_params.timeout_repeat do
          {sc1, changes} =
            set_sc_state(
              %{
                sc
                | waiting_for_response: false,
                  request_class_1: false,
                  request_class_2: false,
                  primary_state: :pll_idle
              },
              :error
            )

          {sc1, [], changes}
        else
          prev_fcb = not sc.next_fcb
          fc = sc.active_req_fc || Frame.fc_request_user_data_class_2()

          frame =
            {:fixed_frame,
             %{
               dir: false,
               prm: true,
               fcb_or_acd: prev_fcb,
               fcv_or_dfc: true,
               fc: fc
             }, sc.address}

          {%{sc | last_send_time: now_ms}, [frame], []}
        end
      else
        {sc, [], []}
      end
    end

    defp step_slave(
           %SlaveConn{primary_state: :pll_secondary_link_layer_busy} = sc,
           ll_params,
           now_ms
         ) do
      if now_ms - sc.last_send_time > ll_params.timeout_for_ack do
        {%{sc | dont_send_messages: false, primary_state: :pll_link_layers_available}, [], []}
      else
        {sc, [], []}
      end
    end

    defp step_slave(sc, _ll_params, _now_ms), do: {sc, [], []}

    defp handle_slave_response(pll, slave_addr, ctrl, user_data, now_ms) do
      case Map.get(pll.slaves, slave_addr) do
        nil ->
          {pll, [], []}

        sc ->
          {sc1, events, changes, _immediate_frames} =
            process_slave_msg(sc, ctrl, user_data, now_ms)

          pll1 = %{pll | slaves: Map.put(pll.slaves, slave_addr, sc1)}
          {pll1, events, changes}
      end
    end

    defp process_slave_msg(sc, %{fcb_or_acd: acd, fcv_or_dfc: dfc, fc: fc}, user_data, _now_ms) do
      if dfc do
        new_pstate =
          case sc.primary_state do
            s when s in [:pll_execute_request_status_of_link, :pll_execute_reset_remote_link] ->
              :pll_execute_request_status_of_link

            s when s in [:pll_execute_service_send_confirm, :pll_secondary_link_layer_busy] ->
              :pll_secondary_link_layer_busy

            other ->
              other
          end

        {sc1, changes} =
          set_sc_state(
            %{
              sc
              | waiting_for_response: false,
                dont_send_messages: true,
                primary_state: new_pstate
            },
            :busy
          )

        {sc1, [], changes, []}
      else
        sc = %{sc | dont_send_messages: false, request_class_1: sc.request_class_1 or acd}
        pstate = sc.primary_state

        case fc do
          0 ->
            # LL_FC_00_ACK (or single_char_ack)
            cond do
              pstate == :pll_execute_reset_remote_link ->
                {sc1, changes} =
                  set_sc_state(
                    %{
                      sc
                      | waiting_for_response: false,
                        primary_state: :pll_link_layers_available
                    },
                    :available
                  )

                {sc1, [], changes, []}

              pstate == :pll_execute_service_send_confirm ->
                sc0 =
                  if sc.send_link_test do
                    %{sc | send_link_test: false}
                  else
                    %{sc | active_message: nil}
                  end

                {sc1, changes} =
                  set_sc_state(
                    %{
                      sc0
                      | waiting_for_response: false,
                        primary_state: :pll_link_layers_available
                    },
                    :available
                  )

                {sc1, [], changes, []}

              pstate == :pll_execute_service_request_respond ->
                {sc1, changes} =
                  set_sc_state(
                    %{
                      sc
                      | waiting_for_response: false,
                        primary_state: :pll_link_layers_available
                    },
                    :available
                  )

                {sc1, [], changes, []}

              true ->
                {%{sc | waiting_for_response: false}, [], [], []}
            end

          1 ->
            # LL_FC_01_NACK
            if pstate == :pll_execute_service_send_confirm do
              {sc1, changes} =
                set_sc_state(
                  %{
                    sc
                    | waiting_for_response: false,
                      primary_state: :pll_secondary_link_layer_busy
                  },
                  :busy
                )

              {sc1, [], changes, []}
            else
              {%{sc | waiting_for_response: false}, [], [], []}
            end

          11 ->
            # LL_FC_11_STATUS_OF_LINK_OR_ACCESS_DEMAND
            if pstate == :pll_execute_request_status_of_link do
              # Transition to :pll_send_reset_remote_link while keeping waiting_for_response: true
              # so multi-slave round-robin does not switch away before RESET_REMOTE_LINK is sent.
              {sc1, changes} =
                set_sc_state(
                  %{
                    sc
                    | waiting_for_response: true,
                      primary_state: :pll_send_reset_remote_link
                  },
                  :busy
                )

              {sc1, [], changes, []}
            else
              {sc1, changes} =
                set_sc_state(
                  %{sc | waiting_for_response: false, primary_state: :pll_idle},
                  :error
                )

              {sc1, [], changes, []}
            end

          8 ->
            # LL_FC_08_RESP_USER_DATA
            if pstate == :pll_execute_service_request_respond do
              events =
                if is_binary(user_data) and byte_size(user_data) > 0 do
                  [{sc.address, user_data}]
                else
                  []
                end

              {sc1, changes} =
                set_sc_state(
                  %{
                    sc
                    | waiting_for_response: false,
                      primary_state: :pll_link_layers_available
                  },
                  :available
                )

              {sc1, events, changes, []}
            else
              {sc1, changes} =
                set_sc_state(
                  %{sc | waiting_for_response: false, primary_state: :pll_idle},
                  :error
                )

              {sc1, [], changes, []}
            end

          9 ->
            # LL_FC_09_RESP_NACK_NO_DATA
            if pstate == :pll_execute_service_request_respond do
              {sc1, changes} =
                set_sc_state(
                  %{sc | waiting_for_response: false, primary_state: :pll_link_layers_available},
                  :available
                )

              {sc1, [], changes, []}
            else
              {sc1, changes} =
                set_sc_state(
                  %{sc | waiting_for_response: false, primary_state: :pll_idle},
                  :error
                )

              {sc1, [], changes, []}
            end

          fc_not_impl when fc_not_impl in [14, 15] ->
            if pstate == :pll_execute_service_send_confirm do
              {sc1, changes} =
                set_sc_state(
                  %{
                    sc
                    | waiting_for_response: false,
                      active_message: nil,
                      send_link_test: false,
                      primary_state: :pll_link_layers_available
                  },
                  :available
                )

              {sc1, [], changes, []}
            else
              {%{sc | waiting_for_response: false}, [], [], []}
            end

          _ ->
            {%{sc | waiting_for_response: false}, [], [], []}
        end
      end
    end

    defp maybe_dequeue_pending_message(%SlaveConn{active_message: nil} = sc) do
      case :queue.out(sc.pending_messages) do
        {{:value, msg}, rest} -> %{sc | active_message: msg, pending_messages: rest}
        {:empty, _} -> sc
      end
    end

    defp maybe_dequeue_pending_message(sc), do: sc

    defp set_sc_state(%SlaveConn{state: old_state} = sc, new_state) do
      if old_state == new_state do
        {sc, []}
      else
        {%{sc | state: new_state}, [{sc.address, new_state}]}
      end
    end

    defp update_slave(%__MODULE__{} = pll, slave_addr, fun) do
      case Map.get(pll.slaves, slave_addr) do
        nil -> pll
        sc -> %{pll | slaves: Map.put(pll.slaves, slave_addr, fun.(sc))}
      end
    end
  end

  # ===========================================================================
  # Balanced Link Layer State Machine (Full-Duplex Master & Slave)
  # ===========================================================================

  defmodule Balanced do
    @moduledoc false
    alias IEC60870.CS101.Frame
    alias IEC60870.LinkLayerParameters

    defstruct [
      :address,
      :other_station_address,
      :dir,
      :ll_params,
      state: :idle,
      primary_state: :pll_idle,
      expected_fcb: true,
      next_fcb: true,
      waiting_for_response: false,
      last_send_time: 0,
      original_send_time: 0,
      last_received_msg: 0,
      idle_timeout: 5000,
      send_link_test: false,
      last_sent_asdu_bin: nil
    ]

    def new(
          address,
          other_station_address,
          dir,
          %LinkLayerParameters{} = ll_params,
          idle_timeout \\ 5000
        ) do
      %__MODULE__{
        address: address,
        other_station_address: other_station_address,
        dir: dir,
        ll_params: ll_params,
        idle_timeout: idle_timeout
      }
    end

    @doc """
    Handles an incoming FT 1.2 frame on a Balanced link layer (either PRM=1 or PRM=0 or 0xE5).
    `callbacks` has:
    - `:handle_user_data` :: `(app_state, binary() -> app_state)`
    Returns `{updated_bll, updated_app_state, frames_to_send, state_changes}`.
    """
    def handle_frame(%__MODULE__{} = bll, frame, app_state, callbacks, now_ms) do
      bll = %{bll | last_received_msg: now_ms}

      case frame do
        :single_char_ack ->
          {bll1, changes} = handle_primary_ack(bll)
          {bll1, app_state, [], changes}

        {:fixed_frame, %{prm: true} = ctrl, _addr} ->
          handle_secondary_message(bll, ctrl, nil, app_state, callbacks)

        {:variable_frame, %{prm: true} = ctrl, _addr, user_data} ->
          handle_secondary_message(bll, ctrl, user_data, app_state, callbacks)

        {:fixed_frame, %{prm: false} = ctrl, _addr} ->
          {bll1, frames, changes} = handle_primary_message(bll, ctrl, now_ms)
          {bll1, app_state, frames, changes}

        {:variable_frame, %{prm: false} = ctrl, _addr, _user_data} ->
          {bll1, frames, changes} = handle_primary_message(bll, ctrl, now_ms)
          {bll1, app_state, frames, changes}
      end
    end

    @doc """
    Runs one step of the Primary Balanced state machine.
    `pop_user_data_fun` is `fn app_state -> {binary() | nil, app_state} end`.
    Returns `{updated_bll, updated_app_state, frames_to_send, state_changes}`.
    """
    def run(%__MODULE__{} = bll, app_state, pop_user_data_fun, now_ms) do
      case bll.primary_state do
        :pll_idle ->
          frame =
            {:fixed_frame,
             %{
               dir: bll.dir,
               prm: true,
               fcb_or_acd: false,
               fcv_or_dfc: false,
               fc: Frame.fc_request_link_status()
             }, bll.other_station_address}

          bll1 = %{
            bll
            | original_send_time: 0,
              send_link_test: false,
              last_send_time: now_ms,
              waiting_for_response: true,
              primary_state: :pll_execute_request_status_of_link
          }

          {bll1, app_state, [frame], []}

        :pll_execute_request_status_of_link ->
          if bll.waiting_for_response do
            if now_ms - bll.last_send_time > bll.ll_params.timeout_for_ack do
              {%{bll | primary_state: :pll_idle}, app_state, [], []}
            else
              {bll, app_state, [], []}
            end
          else
            frame =
              {:fixed_frame,
               %{
                 dir: bll.dir,
                 prm: true,
                 fcb_or_acd: false,
                 fcv_or_dfc: false,
                 fc: Frame.fc_reset_remote_link()
               }, bll.other_station_address}

            bll1 = %{
              bll
              | last_send_time: now_ms,
                waiting_for_response: true,
                primary_state: :pll_execute_reset_remote_link
            }

            {bll1, app_state, [frame], []}
          end

        :pll_execute_reset_remote_link ->
          if bll.waiting_for_response do
            if now_ms - bll.last_send_time > bll.ll_params.timeout_for_ack do
              {bll1, changes} =
                set_bll_state(
                  %{bll | waiting_for_response: false, primary_state: :pll_idle},
                  :error
                )

              {bll1, app_state, [], changes}
            else
              {bll, app_state, [], []}
            end
          else
            {bll1, changes} =
              set_bll_state(%{bll | primary_state: :pll_link_layers_available}, :available)

            {bll1, app_state, [], changes}
          end

        :pll_link_layers_available ->
          bll =
            if bll.last_received_msg > 0 and now_ms - bll.last_received_msg > bll.idle_timeout do
              %{bll | send_link_test: true, last_received_msg: now_ms}
            else
              bll
            end

          if bll.send_link_test do
            frame =
              {:fixed_frame,
               %{
                 dir: bll.dir,
                 prm: true,
                 fcb_or_acd: bll.next_fcb,
                 fcv_or_dfc: true,
                 fc: Frame.fc_test_function_for_link()
               }, bll.other_station_address}

            bll1 = %{
              bll
              | next_fcb: not bll.next_fcb,
                last_send_time: now_ms,
                original_send_time: now_ms,
                waiting_for_response: true,
                primary_state: :pll_execute_service_send_confirm
            }

            {bll1, app_state, [frame], []}
          else
            {asdu_bin, next_app_state} = pop_user_data_fun.(app_state)

            if is_binary(asdu_bin) and byte_size(asdu_bin) > 0 do
              frame =
                {:variable_frame,
                 %{
                   dir: bll.dir,
                   prm: true,
                   fcb_or_acd: bll.next_fcb,
                   fcv_or_dfc: true,
                   fc: Frame.fc_user_data_confirmed()
                 }, bll.other_station_address, asdu_bin}

              bll1 = %{
                bll
                | next_fcb: not bll.next_fcb,
                  last_send_time: now_ms,
                  original_send_time: now_ms,
                  waiting_for_response: true,
                  last_sent_asdu_bin: asdu_bin,
                  primary_state: :pll_execute_service_send_confirm
              }

              {bll1, next_app_state, [frame], []}
            else
              {bll, next_app_state, [], []}
            end
          end

        :pll_execute_service_send_confirm ->
          if now_ms - bll.last_send_time > bll.ll_params.timeout_for_ack do
            if now_ms - bll.original_send_time > bll.ll_params.timeout_repeat do
              {bll1, changes} =
                set_bll_state(
                  %{
                    bll
                    | waiting_for_response: false,
                      last_sent_asdu_bin: nil,
                      send_link_test: false,
                      primary_state: :pll_idle
                  },
                  :error
                )

              {bll1, app_state, [], changes}
            else
              prev_fcb = not bll.next_fcb

              frame =
                if bll.send_link_test do
                  {:fixed_frame,
                   %{
                     dir: bll.dir,
                     prm: true,
                     fcb_or_acd: prev_fcb,
                     fcv_or_dfc: true,
                     fc: Frame.fc_test_function_for_link()
                   }, bll.other_station_address}
                else
                  {:variable_frame,
                   %{
                     dir: bll.dir,
                     prm: true,
                     fcb_or_acd: prev_fcb,
                     fcv_or_dfc: true,
                     fc: Frame.fc_user_data_confirmed()
                   }, bll.other_station_address, bll.last_sent_asdu_bin}
                end

              {%{bll | last_send_time: now_ms}, app_state, [frame], []}
            end
          else
            {bll, app_state, [], []}
          end

        _ ->
          {bll, app_state, [], []}
      end
    end

    # Secondary side of Balanced Link Layer (`LinkLayerSecondaryBalanced_handleMessage`)
    defp handle_secondary_message(bll, ctrl, user_data, app_state, callbacks) do
      {bll, fcb_ok?} =
        if ctrl.fcv_or_dfc do
          if ctrl.fcb_or_acd == bll.expected_fcb do
            {%{bll | expected_fcb: not bll.expected_fcb}, true}
          else
            {bll, false}
          end
        else
          {bll, true}
        end

      if not fcb_ok? do
        # IEC 60870-5-1 Section 6.2.4.2: Duplicate frame received (FCB mismatch).
        # Secondary MUST acknowledge to stop sender retransmissions, but do NOT process user data again.
        {bll, app_state, [secondary_ack(bll)], []}
      else
        case ctrl.fc do
          0 ->
            # LL_FC_00_RESET_REMOTE_LINK
            bll1 = %{bll | expected_fcb: true}
            {bll1, app_state, [secondary_ack(bll1)], []}

          2 ->
            # LL_FC_02_TEST_FUNCTION_FOR_LINK
            {bll, app_state, [secondary_ack(bll)], []}

          3 ->
            # LL_FC_03_USER_DATA_CONFIRMED
            app_state =
              if is_binary(user_data) and byte_size(user_data) > 0 do
                callbacks.handle_user_data.(app_state, user_data)
              else
                app_state
              end

            {bll, app_state, [secondary_ack(bll)], []}

          4 ->
            # LL_FC_04_USER_DATA_NO_REPLY
            app_state =
              if is_binary(user_data) and byte_size(user_data) > 0 do
                callbacks.handle_user_data.(app_state, user_data)
              else
                app_state
              end

            {bll, app_state, [], []}

          9 ->
            # LL_FC_09_REQUEST_LINK_STATUS
            reply =
              {:fixed_frame,
               %{
                 dir: bll.dir,
                 prm: false,
                 fcb_or_acd: false,
                 fcv_or_dfc: false,
                 fc: Frame.fc_status_of_link_or_access_demand()
               }, bll.address}

            {bll, app_state, [reply], []}

          _ ->
            reply =
              {:fixed_frame,
               %{
                 dir: bll.dir,
                 prm: false,
                 fcb_or_acd: false,
                 fcv_or_dfc: false,
                 fc: Frame.fc_service_not_implemented()
               }, bll.address}

            {bll, app_state, [reply], []}
        end
      end
    end

    # Primary side of Balanced Link Layer (`LinkLayerPrimaryBalanced_handleMessage`)
    defp handle_primary_message(bll, %{fcv_or_dfc: true}, _now_ms) do
      new_pstate =
        case bll.primary_state do
          s when s in [:pll_execute_request_status_of_link, :pll_execute_reset_remote_link] ->
            :pll_execute_request_status_of_link

          s when s in [:pll_execute_service_send_confirm, :pll_secondary_link_layer_busy] ->
            :pll_secondary_link_layer_busy

          other ->
            other
        end

      {bll1, changes} = set_bll_state(%{bll | primary_state: new_pstate}, :busy)
      {bll1, [], changes}
    end

    defp handle_primary_message(bll, %{fc: fc}, now_ms) do
      case fc do
        0 ->
          {bll1, changes} = handle_primary_ack(bll)
          {bll1, [], changes}

        1 ->
          if bll.primary_state == :pll_execute_service_send_confirm do
            {bll1, changes} =
              set_bll_state(%{bll | primary_state: :pll_secondary_link_layer_busy}, :busy)

            {bll1, [], changes}
          else
            {bll, [], []}
          end

        11 ->
          if bll.primary_state == :pll_execute_request_status_of_link do
            frame =
              {:fixed_frame,
               %{
                 dir: bll.dir,
                 prm: true,
                 fcb_or_acd: false,
                 fcv_or_dfc: false,
                 fc: Frame.fc_reset_remote_link()
               }, bll.other_station_address}

            {bll1, changes} =
              set_bll_state(
                %{
                  bll
                  | last_send_time: now_ms,
                    waiting_for_response: true,
                    primary_state: :pll_execute_reset_remote_link
                },
                :busy
              )

            {bll1, [frame], changes}
          else
            {bll1, changes} = set_bll_state(%{bll | primary_state: :pll_idle}, :error)
            {bll1, [], changes}
          end

        fc_err when fc_err in [8, 9] ->
          {bll1, changes} = set_bll_state(%{bll | primary_state: :pll_idle}, :error)
          {bll1, [], changes}

        fc_not_impl when fc_not_impl in [14, 15] ->
          bll = %{bll | send_link_test: false}

          if bll.primary_state == :pll_execute_service_send_confirm do
            {bll1, changes} =
              set_bll_state(
                %{
                  bll
                  | waiting_for_response: false,
                    last_sent_asdu_bin: nil,
                    primary_state: :pll_link_layers_available
                },
                :available
              )

            {bll1, [], changes}
          else
            {bll, [], []}
          end

        _ ->
          {bll, [], []}
      end
    end

    defp handle_primary_ack(bll) do
      case bll.primary_state do
        :pll_execute_reset_remote_link ->
          set_bll_state(
            %{bll | waiting_for_response: false, primary_state: :pll_link_layers_available},
            :available
          )

        :pll_execute_service_send_confirm ->
          set_bll_state(
            %{
              bll
              | send_link_test: false,
                last_sent_asdu_bin: nil,
                waiting_for_response: false,
                primary_state: :pll_link_layers_available
            },
            :available
          )

        :pll_execute_request_status_of_link ->
          {bll, []}

        _ ->
          {%{bll | waiting_for_response: false}, []}
      end
    end

    defp secondary_ack(bll) do
      if bll.ll_params.use_single_char_ack do
        :single_char_ack
      else
        {:fixed_frame,
         %{
           dir: bll.dir,
           prm: false,
           fcb_or_acd: false,
           fcv_or_dfc: false,
           fc: Frame.fc_ack()
         }, bll.address}
      end
    end

    defp set_bll_state(%__MODULE__{state: old_state} = bll, new_state) do
      if old_state == new_state do
        {bll, []}
      else
        {%{bll | state: new_state}, [{-1, new_state}]}
      end
    end
  end
end
