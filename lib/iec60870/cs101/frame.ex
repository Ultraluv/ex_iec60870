defmodule IEC60870.CS101.Frame do
  @moduledoc """
  IEC 60870-5-101 FT 1.2 frame codec and stream deframer (`serial_transceiver_ft_1_2.c` & `link_layer.c`).

  Supports:
  - Single-character ACK (`0xE5`): `:single_char_ack`
  - Fixed-length frame (`0x10, C, Addr..., CS, 0x16`):
    `{:fixed_frame, control_map, address}`
  - Variable-length frame (`0x68, L, L, 0x68, C, Addr..., UserData..., CS, 0x16`):
    `{:variable_frame, control_map, address, user_data}`
  """

  import Bitwise

  # Primary to Secondary Function Codes (PRM = 1)
  @fc_reset_remote_link 0
  @fc_reset_user_process 1
  @fc_test_function_for_link 2
  @fc_user_data_confirmed 3
  @fc_user_data_no_reply 4
  @fc_reset_fcb 7
  @fc_request_for_access_demand 8
  @fc_request_link_status 9
  @fc_request_user_data_class_1 10
  @fc_request_user_data_class_2 11

  # Secondary to Primary Function Codes (PRM = 0)
  @fc_ack 0
  @fc_nack 1
  @fc_resp_user_data 8
  @fc_resp_nack_no_data 9
  @fc_status_of_link_or_access_demand 11
  @fc_service_not_functioning 14
  @fc_service_not_implemented 15

  def fc_reset_remote_link, do: @fc_reset_remote_link
  def fc_reset_user_process, do: @fc_reset_user_process
  def fc_test_function_for_link, do: @fc_test_function_for_link
  def fc_user_data_confirmed, do: @fc_user_data_confirmed
  def fc_user_data_no_reply, do: @fc_user_data_no_reply
  def fc_reset_fcb, do: @fc_reset_fcb
  def fc_request_for_access_demand, do: @fc_request_for_access_demand
  def fc_request_link_status, do: @fc_request_link_status
  def fc_request_user_data_class_1, do: @fc_request_user_data_class_1
  def fc_request_user_data_class_2, do: @fc_request_user_data_class_2

  def fc_ack, do: @fc_ack
  def fc_nack, do: @fc_nack
  def fc_resp_user_data, do: @fc_resp_user_data
  def fc_resp_nack_no_data, do: @fc_resp_nack_no_data
  def fc_status_of_link_or_access_demand, do: @fc_status_of_link_or_access_demand
  def fc_service_not_functioning, do: @fc_service_not_functioning
  def fc_service_not_implemented, do: @fc_service_not_implemented

  @type control :: %{
          dir: boolean(),
          prm: boolean(),
          fcb_or_acd: boolean(),
          fcv_or_dfc: boolean(),
          fc: 0..15
        }

  @type t ::
          :single_char_ack
          | {:fixed_frame, control(), non_neg_integer()}
          | {:variable_frame, control(), non_neg_integer(), binary()}

  @doc """
  Encodes a control field map into an 8-bit integer.
  """
  @spec encode_control(map()) :: non_neg_integer()
  def encode_control(ctrl) when is_map(ctrl) do
    dir = if Map.get(ctrl, :dir, false), do: 0x80, else: 0
    prm = if Map.get(ctrl, :prm, false), do: 0x40, else: 0

    fcb_acd =
      if Map.get(ctrl, :fcb_or_acd, Map.get(ctrl, :fcb, Map.get(ctrl, :acd, false))),
        do: 0x20,
        else: 0

    fcv_dfc =
      if Map.get(ctrl, :fcv_or_dfc, Map.get(ctrl, :fcv, Map.get(ctrl, :dfc, false))),
        do: 0x10,
        else: 0

    fc = Map.get(ctrl, :fc, 0) &&& 0x0F
    dir ||| prm ||| fcb_acd ||| fcv_dfc ||| fc
  end

  @doc """
  Decodes an 8-bit control field byte into a map.
  """
  @spec decode_control(non_neg_integer()) :: control()
  def decode_control(c) when is_integer(c) do
    %{
      dir: (c &&& 0x80) != 0,
      prm: (c &&& 0x40) != 0,
      fcb_or_acd: (c &&& 0x20) != 0,
      fcv_or_dfc: (c &&& 0x10) != 0,
      fc: c &&& 0x0F
    }
  end

  @doc """
  Encodes a link layer address according to `address_length` (`0`, `1`, or `2`).
  """
  @spec encode_address(non_neg_integer(), 0..2) :: binary()
  def encode_address(_addr, 0), do: <<>>
  def encode_address(addr, 1), do: <<addr &&& 0xFF>>
  def encode_address(addr, 2), do: <<addr::little-unsigned-16>>

  @doc """
  Decodes a link layer address according to `address_length` (`0`, `1`, or `2`).
  """
  @spec decode_address(binary(), 0..2) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def decode_address(rest, 0), do: {:ok, 0, rest}
  def decode_address(<<a::8, rest::binary>>, 1), do: {:ok, a, rest}
  def decode_address(<<a::little-unsigned-16, rest::binary>>, 2), do: {:ok, a, rest}
  def decode_address(_, _), do: {:error, :insufficient_bytes_for_address}

  @doc """
  Computes 8-bit modulo-256 sum of bytes in `bin`.
  """
  @spec checksum(binary()) :: non_neg_integer()
  def checksum(bin) when is_binary(bin) do
    for(<<b::8 <- bin>>, reduce: 0, do: (acc -> acc + b &&& 0xFF))
  end

  @doc """
  Encodes an FT 1.2 frame into wire binary given `address_length` (`0`, `1`, or `2`).
  """
  @spec encode(t(), 0..2) :: {:ok, binary()} | {:error, term()}
  def encode(:single_char_ack, _addr_len), do: {:ok, <<0xE5>>}

  def encode({:fixed_frame, ctrl, address}, addr_len) when addr_len in 0..2 do
    c_byte = encode_control(ctrl)
    addr_bin = encode_address(address, addr_len)
    body = <<c_byte::8, addr_bin::binary>>
    cs = checksum(body)
    {:ok, <<0x10, body::binary, cs::8, 0x16>>}
  end

  def encode({:variable_frame, ctrl, address, user_data}, addr_len)
      when addr_len in 0..2 and is_binary(user_data) do
    c_byte = encode_control(ctrl)
    addr_bin = encode_address(address, addr_len)
    body = <<c_byte::8, addr_bin::binary, user_data::binary>>
    l = byte_size(body)

    if l > 255 or byte_size(user_data) == 0 do
      {:error, :invalid_variable_frame_length}
    else
      cs = checksum(body)
      {:ok, <<0x68, l::8, l::8, 0x68, body::binary, cs::8, 0x16>>}
    end
  end

  def encode(_, _), do: {:error, :invalid_frame}

  @doc """
  Decodes a single complete FT 1.2 frame given `address_length` (`0`, `1`, or `2`).
  """
  @spec decode(binary(), 0..2) :: {:ok, t()} | {:error, term()}
  def decode(<<0xE5>>, _addr_len), do: {:ok, :single_char_ack}

  def decode(<<0x10, rest::binary>>, addr_len) when byte_size(rest) == 3 + addr_len do
    body_len = 1 + addr_len

    case rest do
      <<body::binary-size(^body_len), cs::8, 0x16>> ->
        if checksum(body) == cs do
          <<c_byte::8, addr_part::binary>> = body
          {:ok, address, <<>>} = decode_address(addr_part, addr_len)
          {:ok, {:fixed_frame, decode_control(c_byte), address}}
        else
          {:error, :invalid_checksum}
        end

      _ ->
        {:error, :invalid_end_byte}
    end
  end

  def decode(<<0x68, l1::8, l2::8, 0x68, rest::binary>>, addr_len)
      when l1 == l2 and byte_size(rest) == l1 + 2 and l1 >= 1 + addr_len do
    case rest do
      <<body::binary-size(^l1), cs::8, 0x16>> ->
        if checksum(body) == cs do
          <<c_byte::8, after_c::binary>> = body
          {:ok, address, user_data} = decode_address(after_c, addr_len)
          {:ok, {:variable_frame, decode_control(c_byte), address, user_data}}
        else
          {:error, :invalid_checksum}
        end

      _ ->
        {:error, :invalid_end_byte}
    end
  end

  def decode(_, _), do: {:error, :invalid_ft12_frame}

  @doc """
  Extracts complete FT 1.2 frames from a stream buffer given `address_length`.
  Returns `{:ok, frames, remaining_buffer}` or `{:error, reason, remaining_buffer}`.
  """
  @spec extract_frames(binary(), 0..2) :: {:ok, [t()], binary()} | {:error, term(), binary()}
  def extract_frames(buffer, addr_len \\ 1) when is_binary(buffer) and addr_len in 0..2 do
    do_extract(buffer, addr_len, [])
  end

  defp do_extract(<<>>, _addr_len, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp do_extract(<<0xE5, rest::binary>>, addr_len, acc) do
    do_extract(rest, addr_len, [:single_char_ack | acc])
  end

  defp do_extract(<<0x10, rest::binary>> = buf, addr_len, acc) do
    needed = 3 + addr_len

    if byte_size(rest) < needed do
      {:ok, Enum.reverse(acc), buf}
    else
      <<frame_tail::binary-size(^needed), after_frame::binary>> = rest

      case decode(<<0x10, frame_tail::binary>>, addr_len) do
        {:ok, frame} ->
          do_extract(after_frame, addr_len, [frame | acc])

        {:error, reason} ->
          if acc != [] do
            {:ok, Enum.reverse(acc), after_frame}
          else
            {:error, reason, after_frame}
          end
      end
    end
  end

  defp do_extract(<<0x68>> = buf, _addr_len, acc), do: {:ok, Enum.reverse(acc), buf}
  defp do_extract(<<0x68, _l1::8>> = buf, _addr_len, acc), do: {:ok, Enum.reverse(acc), buf}

  defp do_extract(<<0x68, _l1::8, _l2::8>> = buf, _addr_len, acc),
    do: {:ok, Enum.reverse(acc), buf}

  defp do_extract(<<0x68, l1::8, l2::8, start2::8, rest::binary>> = buf, addr_len, acc) do
    cond do
      l1 != l2 or start2 != 0x68 or l1 < 1 + addr_len ->
        if acc != [] do
          {:ok, Enum.reverse(acc), rest}
        else
          {:error, :invalid_variable_frame_header, rest}
        end

      byte_size(rest) < l1 + 2 ->
        {:ok, Enum.reverse(acc), buf}

      true ->
        needed = l1 + 2
        <<frame_tail::binary-size(^needed), after_frame::binary>> = rest

        case decode(<<0x68, l1::8, l2::8, 0x68, frame_tail::binary>>, addr_len) do
          {:ok, frame} ->
            do_extract(after_frame, addr_len, [frame | acc])

          {:error, reason} ->
            if acc != [] do
              {:ok, Enum.reverse(acc), after_frame}
            else
              {:error, reason, after_frame}
            end
        end
    end
  end

  defp do_extract(<<bad_byte::8, rest::binary>>, _addr_len, acc) do
    if acc != [] do
      {:ok, Enum.reverse(acc), rest}
    else
      {:error, {:sync_error, bad_byte}, rest}
    end
  end
end
