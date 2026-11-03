defmodule IEC60870.Types.COT do
  @moduledoc """
  Cause of Transmission (`CS101_CauseOfTransmission`).
  """

  @cot_mappings [
    {1, :periodic},
    {2, :background_scan},
    {3, :spontaneous},
    {4, :initialized},
    {5, :request},
    {6, :activation},
    {7, :activation_con},
    {8, :deactivation},
    {9, :deactivation_con},
    {10, :activation_termination},
    {11, :return_info_remote},
    {12, :return_info_local},
    {13, :file_transfer},
    {14, :authentication},
    {15, :maintenance_of_auth_session_key},
    {16, :maintenance_of_user_role_and_update_key},
    {20, :interrogated_by_station},
    {21, :interrogated_by_group_1},
    {22, :interrogated_by_group_2},
    {23, :interrogated_by_group_3},
    {24, :interrogated_by_group_4},
    {25, :interrogated_by_group_5},
    {26, :interrogated_by_group_6},
    {27, :interrogated_by_group_7},
    {28, :interrogated_by_group_8},
    {29, :interrogated_by_group_9},
    {30, :interrogated_by_group_10},
    {31, :interrogated_by_group_11},
    {32, :interrogated_by_group_12},
    {33, :interrogated_by_group_13},
    {34, :interrogated_by_group_14},
    {35, :interrogated_by_group_15},
    {36, :interrogated_by_group_16},
    {37, :requested_by_general_counter},
    {38, :requested_by_group_1_counter},
    {39, :requested_by_group_2_counter},
    {40, :requested_by_group_3_counter},
    {41, :requested_by_group_4_counter},
    {44, :unknown_type_id},
    {45, :unknown_cot},
    {46, :unknown_ca},
    {47, :unknown_ioa}
  ]

  @type name :: atom()
  @type code :: 0..63
  @type t :: name() | code()

  for {code, atom} <- @cot_mappings do
    def to_code(unquote(atom)), do: unquote(code)
    def to_code(unquote(code)), do: unquote(code)

    def to_atom(unquote(code)), do: unquote(atom)
    def to_atom(unquote(atom)), do: unquote(atom)

    def to_string(unquote(code)), do: unquote(Atom.to_string(atom) |> String.upcase())
    def to_string(unquote(atom)), do: unquote(Atom.to_string(atom) |> String.upcase())
  end

  @doc """
  Converts a COT atom or code to its 1..63 integer representation.
  """

  def to_code(code) when is_integer(code) and code in 0..63, do: code

  @doc """
  Converts a COT integer code to its descriptive atom representation.
  """
  def to_atom(code) when is_integer(code), do: code
  def to_string(_), do: "UNKNOWN"
end
