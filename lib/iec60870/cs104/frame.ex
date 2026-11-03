defmodule IEC60870.CS104.Frame do
  @moduledoc """
  IEC 60870-5-104 APCI frame codec and stream deframer (`cs104_frame.c`).

  Supports:
  - `:i_frame`: `{:i_frame, send_seq, recv_seq, asdu_binary}`
  - `:s_frame`: `{:s_frame, recv_seq}`
  - `:u_frame`: `{:u_frame, :startdt_act | :startdt_con | :stopdt_act | :stopdt_con | :testfr_act | :testfr_con}`
  """

  import Bitwise

  @type u_type ::
          :startdt_act
          | :startdt_con
          | :stopdt_act
          | :stopdt_con
          | :testfr_act
          | :testfr_con

  @type t ::
          {:i_frame, non_neg_integer(), non_neg_integer(), binary()}
          | {:s_frame, non_neg_integer()}
          | {:u_frame, u_type()}

  @startdt_act <<0x68, 0x04, 0x07, 0x00, 0x00, 0x00>>
  @startdt_con <<0x68, 0x04, 0x0B, 0x00, 0x00, 0x00>>
  @stopdt_act <<0x68, 0x04, 0x13, 0x00, 0x00, 0x00>>
  @stopdt_con <<0x68, 0x04, 0x23, 0x00, 0x00, 0x00>>
  @testfr_act <<0x68, 0x04, 0x43, 0x00, 0x00, 0x00>>
  @testfr_con <<0x68, 0x04, 0x83, 0x00, 0x00, 0x00>>

  @doc """
  Encodes a 104 APCI frame to wire binary.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode({:u_frame, :startdt_act}), do: {:ok, @startdt_act}
  def encode({:u_frame, :startdt_con}), do: {:ok, @startdt_con}
  def encode({:u_frame, :stopdt_act}), do: {:ok, @stopdt_act}
  def encode({:u_frame, :stopdt_con}), do: {:ok, @stopdt_con}
  def encode({:u_frame, :testfr_act}), do: {:ok, @testfr_act}
  def encode({:u_frame, :testfr_con}), do: {:ok, @testfr_con}

  def encode({:s_frame, recv_seq}) when recv_seq >= 0 and recv_seq < 32768 do
    cf3 = rem(recv_seq, 128) * 2
    cf4 = div(recv_seq, 128)
    {:ok, <<0x68, 0x04, 0x01, 0x00, cf3::8, cf4::8>>}
  end

  def encode({:i_frame, send_seq, recv_seq, asdu_bin})
      when send_seq >= 0 and send_seq < 32768 and recv_seq >= 0 and recv_seq < 32768 and
             is_binary(asdu_bin) do
    apdu_len = 4 + byte_size(asdu_bin)

    if apdu_len > 253 or byte_size(asdu_bin) == 0 do
      {:error, :invalid_asdu_length}
    else
      cf1 = rem(send_seq, 128) * 2
      cf2 = div(send_seq, 128)
      cf3 = rem(recv_seq, 128) * 2
      cf4 = div(recv_seq, 128)
      {:ok, <<0x68, apdu_len::8, cf1::8, cf2::8, cf3::8, cf4::8, asdu_bin::binary>>}
    end
  end

  def encode(_), do: {:error, :invalid_frame}

  @doc """
  Decodes a single complete 104 APCI frame binary (starting with `0x68`).
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<0x68, len::8, cf1::8, cf2::8, cf3::8, cf4::8, rest::binary>>)
      when len == 4 + byte_size(rest) and len >= 4 and len <= 253 do
    cond do
      (cf1 &&& 0x01) == 0 ->
        if byte_size(rest) < 1 do
          {:error, :i_frame_too_short}
        else
          send_seq = div(cf2 * 256 + (cf1 &&& 0xFE), 2)
          recv_seq = div(cf4 * 256 + (cf3 &&& 0xFE), 2)
          {:ok, {:i_frame, send_seq, recv_seq, rest}}
        end

      cf1 == 0x01 and cf2 == 0x00 and byte_size(rest) == 0 ->
        recv_seq = div(cf4 * 256 + (cf3 &&& 0xFE), 2)
        {:ok, {:s_frame, recv_seq}}

      (cf1 &&& 0x03) == 0x03 and byte_size(rest) == 0 ->
        case cf1 do
          0x07 -> {:ok, {:u_frame, :startdt_act}}
          0x0B -> {:ok, {:u_frame, :startdt_con}}
          0x13 -> {:ok, {:u_frame, :stopdt_act}}
          0x23 -> {:ok, {:u_frame, :stopdt_con}}
          0x43 -> {:ok, {:u_frame, :testfr_act}}
          0x83 -> {:ok, {:u_frame, :testfr_con}}
          _ -> {:error, {:unknown_u_frame, cf1}}
        end

      true ->
        {:error, :invalid_control_fields}
    end
  end

  def decode(_), do: {:error, :invalid_apci_frame}

  @doc """
  Extracts complete APCI frames from a TCP byte stream buffer.
  Returns `{:ok, frames, remaining_buffer}` or `{:error, reason}`.
  """
  @spec extract_frames(binary()) :: {:ok, [t()], binary()} | {:error, term()}
  def extract_frames(buffer) when is_binary(buffer) do
    do_extract(buffer, [])
  end

  defp do_extract(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp do_extract(<<0x68>> = buf, acc), do: {:ok, Enum.reverse(acc), buf}

  defp do_extract(<<0x68, len::8, _::binary>>, _acc) when len < 4 or len > 253 do
    {:error, {:invalid_apdu_length, len}}
  end

  defp do_extract(<<0x68, len::8, rest::binary>> = buf, acc) do
    if byte_size(rest) < len do
      {:ok, Enum.reverse(acc), buf}
    else
      <<apdu_body::binary-size(^len), tail::binary>> = rest
      raw_frame = <<0x68, len::8, apdu_body::binary>>

      case decode(raw_frame) do
        {:ok, decoded} -> do_extract(tail, [decoded | acc])
        {:error, _} = err -> err
      end
    end
  end

  defp do_extract(<<bad_start::8, _::binary>>, _acc) do
    {:error, {:invalid_start_byte, bad_start}}
  end

  @doc """
  Validates whether `ack_seq_no` is within the sliding window of unacknowledged sent ASDUs
  (each item is `%{seq_no: integer(), sent_time: integer()}`).
  Returns `{:ok, remaining_sent_asdus}` or `{:error, :sequence_number_out_of_range}`.
  Matches `checkSequenceNumber` in `cs104_connection.c` / `cs104_slave.c`.
  """
  @spec check_sequence_number(list(map()), non_neg_integer(), non_neg_integer()) ::
          {:ok, list(map()), list(map())} | {:error, :sequence_number_out_of_range}
  def check_sequence_number([], send_count, ack_seq_no) do
    if ack_seq_no == send_count do
      {:ok, [], []}
    else
      {:error, :sequence_number_out_of_range}
    end
  end

  def check_sequence_number([oldest | _] = sent_asdus, _send_count, ack_seq_no) do
    newest = List.last(sent_asdus)
    oldest_seq = oldest.seq_no
    newest_seq = newest.seq_no

    {seq_valid?, overflow?} =
      if oldest_seq <= newest_seq do
        {ack_seq_no >= oldest_seq and ack_seq_no <= newest_seq, false}
      else
        {ack_seq_no >= oldest_seq or ack_seq_no <= newest_seq, true}
      end

    oldest_valid_seq =
      if oldest_seq == 0 do
        32767
      else
        rem(oldest_seq - 1, 32768)
      end

    seq_valid? = seq_valid? or ack_seq_no == oldest_valid_seq

    if seq_valid? do
      if ack_seq_no == oldest_valid_seq do
        {:ok, sent_asdus, []}
      else
        pop_confirmed(sent_asdus, ack_seq_no, overflow?, [])
      end
    else
      {:error, :sequence_number_out_of_range}
    end
  end

  defp pop_confirmed([], _ack_seq_no, _overflow?, confirmed) do
    {:ok, [], Enum.reverse(confirmed)}
  end

  defp pop_confirmed([head | tail] = list, ack_seq_no, overflow?, confirmed) do
    cond do
      not overflow? and ack_seq_no < head.seq_no ->
        {:ok, list, Enum.reverse(confirmed)}

      head.seq_no == ack_seq_no ->
        {:ok, tail, Enum.reverse([head | confirmed])}

      true ->
        pop_confirmed(tail, ack_seq_no, overflow?, [head | confirmed])
    end
  end
end
