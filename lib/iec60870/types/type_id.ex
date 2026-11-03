defmodule IEC60870.Types.TypeID do
  @moduledoc """
  IEC 60870-5 ASDU Type Identifications (`IEC60870_5_TypeID`).
  Supports bidirectional conversion between integer codes (1..255) and descriptive atoms,
  as well as element byte size lookup and single-IO validation.
  """

  @type_mappings [
    # Monitoring direction process information
    {1, :m_sp_na_1, 1, false},
    {2, :m_sp_ta_1, 4, false},
    {3, :m_dp_na_1, 1, false},
    {4, :m_dp_ta_1, 4, false},
    {5, :m_st_na_1, 2, false},
    {6, :m_st_ta_1, 5, false},
    {7, :m_bo_na_1, 5, false},
    {8, :m_bo_ta_1, 8, false},
    {9, :m_me_na_1, 3, false},
    {10, :m_me_ta_1, 6, false},
    {11, :m_me_nb_1, 3, false},
    {12, :m_me_tb_1, 6, false},
    {13, :m_me_nc_1, 5, false},
    {14, :m_me_tc_1, 8, false},
    {15, :m_it_na_1, 5, false},
    {16, :m_it_ta_1, 8, false},
    {17, :m_ep_ta_1, 6, false},
    {18, :m_ep_tb_1, 7, false},
    {19, :m_ep_tc_1, 7, false},
    {20, :m_ps_na_1, 5, false},
    {21, :m_me_nd_1, 2, false},
    # Monitoring direction with CP56Time2a
    {30, :m_sp_tb_1, 8, false},
    {31, :m_dp_tb_1, 8, false},
    {32, :m_st_tb_1, 9, false},
    {33, :m_bo_tb_1, 12, false},
    {34, :m_me_td_1, 10, false},
    {35, :m_me_te_1, 10, false},
    {36, :m_me_tf_1, 12, false},
    {37, :m_it_tb_1, 12, false},
    {38, :m_ep_td_1, 10, false},
    {39, :m_ep_te_1, 11, false},
    {40, :m_ep_tf_1, 11, false},
    {41, :s_it_tc_1, 14, false},
    # Control direction process commands
    {45, :c_sc_na_1, 1, true},
    {46, :c_dc_na_1, 1, true},
    {47, :c_rc_na_1, 1, true},
    {48, :c_se_na_1, 3, true},
    {49, :c_se_nb_1, 3, true},
    {50, :c_se_nc_1, 5, true},
    {51, :c_bo_na_1, 4, true},
    # Control direction process commands with CP56Time2a
    {58, :c_sc_ta_1, 8, true},
    {59, :c_dc_ta_1, 8, true},
    {60, :c_rc_ta_1, 8, true},
    {61, :c_se_ta_1, 10, true},
    {62, :c_se_tb_1, 10, true},
    {63, :c_se_tc_1, 12, true},
    {64, :c_bo_ta_1, 11, true},
    # System information in monitoring direction
    {70, :m_ei_na_1, 1, true},
    # Security / Authentication (81..95) - matches CS101_ASDU_isSingleInformationObjectType (false)
    {81, :s_ch_na_1, -1, false},
    {82, :s_rp_na_1, -1, false},
    {83, :s_ar_na_1, -1, false},
    {84, :s_kr_na_1, -1, false},
    {85, :s_ks_na_1, -1, false},
    {86, :s_kc_na_1, -1, false},
    {87, :s_er_na_1, -1, false},
    {90, :s_us_na_1, -1, false},
    {91, :s_uq_na_1, -1, false},
    {92, :s_ur_na_1, -1, false},
    {93, :s_uk_na_1, -1, false},
    {94, :s_ua_na_1, -1, false},
    {95, :s_uc_na_1, -1, false},
    # System information in control direction
    {100, :c_ic_na_1, 1, true},
    {101, :c_ci_na_1, 1, true},
    {102, :c_rd_na_1, 0, true},
    {103, :c_cs_na_1, 7, true},
    {104, :c_ts_na_1, 2, true},
    {105, :c_rp_na_1, 1, true},
    {106, :c_cd_na_1, 2, true},
    {107, :c_ts_ta_1, 9, true},
    # Parameter in control direction
    {110, :p_me_na_1, 3, false},
    {111, :p_me_nb_1, 3, false},
    {112, :p_me_nc_1, 5, false},
    {113, :p_ac_na_1, 1, false},
    # File transfer
    {120, :f_fr_na_1, 6, true},
    {121, :f_sr_na_1, 7, true},
    {122, :f_sc_na_1, 4, true},
    {123, :f_ls_na_1, 5, true},
    {124, :f_af_na_1, 4, true},
    {125, :f_sg_na_1, -1, true},
    {126, :f_dr_ta_1, 13, false},
    {127, :f_sc_nb_1, 16, false},
    # Extended file transfer (commonly used in State Grid / domestic extensions)
    {210, :f_fr_na_2, -1, true}
  ]

  @type name :: atom()
  @type code :: 1..255
  @type t :: name() | code()

  for {code, atom, size, single_io?} <- @type_mappings do
    def to_code(unquote(atom)), do: unquote(code)
    def to_code(unquote(code)), do: unquote(code)

    def to_atom(unquote(code)), do: unquote(atom)
    def to_atom(unquote(atom)), do: unquote(atom)

    def element_data_size(unquote(code)), do: unquote(size)
    def element_data_size(unquote(atom)), do: unquote(size)

    def single_io?(unquote(code)), do: unquote(single_io?)
    def single_io?(unquote(atom)), do: unquote(single_io?)

    def to_string(unquote(code)), do: unquote(Atom.to_string(atom) |> String.upcase())
    def to_string(unquote(atom)), do: unquote(Atom.to_string(atom) |> String.upcase())
  end

  @doc """
  Converts a TypeID atom or code to its 1..255 integer representation.
  """

  def to_code(code) when is_integer(code) and code in 1..255, do: code

  @doc """
  Converts a TypeID integer code to its descriptive atom representation.
  """
  def to_atom(code) when is_integer(code), do: code
  def element_data_size(_), do: -1
  def single_io?(_), do: false
  def to_string(other), do: "UNKNOWN_TYPE_#{inspect(other)}"

  @doc """
  Returns `true` if compact sequence encoding (`SQ = 1`) is supported by `CS101_ASDU_getElementEx`
  in `lib60870-C` (`cs101_asdu.c:1378-1675`), which is true for TypeIDs `1..21` and `30..40` / `110..113`.
  Note: `126` (`F_DR_TA_1`), `127` (`F_SC_NB_1`), `41` (`S_IT_TC_1`), `70` (`M_EI_NA_1`), and all `single_io?` types
  always encode an IOA per element.
  """
  @spec sequence_supported?(t()) :: boolean()
  def sequence_supported?(type) do
    code = to_code(type)
    code in 1..21 or code in 30..40 or code in 110..113
  end
end
