defmodule IEC60870.ASDUAndIOTest do
  use ExUnit.Case, async: true

  alias IEC60870.{ASDU, InformationObject}
  alias IEC60870.IO.{Control, File, Monitoring, Parameter, System}
  alias IEC60870.Types.BCR
  alias IEC60870.Types.CPTime.{CP16Time2a, CP24Time2a, CP56Time2a}

  test "StepPositionInformation matches lib60870-C test_StepPositionInformation" do
    spis = [
      Monitoring.step_position(101, 0, true, 0x00),
      Monitoring.step_position(102, 63, false, 0x01),
      Monitoring.step_position(103, 62, false, 0x04),
      Monitoring.step_position(104, 61, false, 0x08),
      Monitoring.step_position(105, -61, false, 0x10),
      Monitoring.step_position(106, -62, false, 0x20),
      Monitoring.step_position(107, -63, false, 0x40),
      Monitoring.step_position(108, 0, false, 0x80)
    ]

    asdu = ASDU.new(:m_st_na_1, cot: :periodic, oa: 0, ca: 1, information_objects: spis)
    assert {:ok, encoded} = ASDU.encode(asdu)
    assert byte_size(encoded) == 46

    assert {:ok, decoded} = ASDU.decode(encoded)
    assert length(decoded.objects) == 8

    Enum.zip(spis, decoded.objects)
    |> Enum.each(fn {orig, dec} ->
      assert dec.ioa == orig.ioa
      assert dec.value == orig.value
      assert dec.transient == orig.transient
      assert dec.quality == orig.quality
    end)
  end

  test "ASDU SQ=1 compact sequence encoding and decoding" do
    ios = [
      Monitoring.measured_value_short(1000, 12.5, 0x00),
      Monitoring.measured_value_short(1001, -42.25, 0x00),
      Monitoring.measured_value_short(1002, 100.0, 0x80)
    ]

    asdu =
      ASDU.new(:m_me_nc_1,
        is_sequence: true,
        cot: :interrogated_by_station,
        oa: 1,
        ca: 10,
        information_objects: ios
      )

    assert {:ok, bin} = ASDU.encode(asdu)
    # Header (6) + 1st IOA (3) + 3 * (4 float + 1 QDS) = 6 + 3 + 15 = 24 bytes
    assert byte_size(bin) == 24

    assert {:ok, dec} = ASDU.decode(bin)
    assert dec.is_sequence == true
    assert Enum.map(dec.objects, & &1.ioa) == [1000, 1001, 1002]
    assert Enum.map(dec.objects, & &1.value) == [12.5, -42.25, 100.0]
  end

  test "Monitoring Information Objects (TypeIDs 1..41, 70) roundtrip" do
    ts24 = %CP24Time2a{millisecond: 120, second: 15, minute: 30}
    ts56 = CP56Time2a.from_ms(1_700_000_000_000)
    t16 = %CP16Time2a{elapsed_time_ms: 350}
    bcr = %BCR{value: 987_654, sequence_number: 5, carry: false, adjusted: true, invalid: false}

    samples = [
      Monitoring.single_point(1, true, 0x10),
      Monitoring.single_point_cp24time2a(2, false, 0x00, ts24),
      Monitoring.single_point_cp56time2a(3, true, 0x20, ts56),
      Monitoring.double_point(4, :on, 0x00),
      Monitoring.double_point_cp24time2a(5, :off, 0x10, ts24),
      Monitoring.double_point_cp56time2a(6, :transient, 0x80, ts56),
      Monitoring.step_position(7, -15, true, 0x00),
      Monitoring.step_position_cp24time2a(8, 32, false, 0x00, ts24),
      Monitoring.step_position_cp56time2a(9, 63, true, 0x01, ts56),
      Monitoring.bitstring32(10, 0xDEADBEEF, 0x00),
      Monitoring.bitstring32_cp24time2a(11, 0x12345678, 0x10, ts24),
      Monitoring.bitstring32_cp56time2a(12, 0xCAFEBABE, 0x00, ts56),
      Monitoring.measured_value_normalized(13, 0.5, 0x00),
      Monitoring.measured_value_normalized_cp24time2a(14, -0.25, 0x00, ts24),
      Monitoring.measured_value_normalized_cp56time2a(15, 0.75, 0x00, ts56),
      Monitoring.measured_value_normalized_without_quality(16, -0.5),
      Monitoring.measured_value_scaled(17, -1234, 0x00),
      Monitoring.measured_value_scaled_cp24time2a(18, 5678, 0x10, ts24),
      Monitoring.measured_value_scaled_cp56time2a(19, 32000, 0x00, ts56),
      Monitoring.measured_value_short(20, 3.1415927, 0x00),
      Monitoring.measured_value_short_cp24time2a(21, -273.15, 0x00, ts24),
      Monitoring.measured_value_short_cp56time2a(22, 50.0, 0x00, ts56),
      Monitoring.integrated_totals(23, bcr),
      Monitoring.integrated_totals_cp24time2a(24, bcr, ts24),
      Monitoring.integrated_totals_cp56time2a(25, bcr, ts56),
      Monitoring.event_of_protection_equipment_cp24time2a(26, 2, 0x08, t16, ts24),
      Monitoring.event_of_protection_equipment_cp56time2a(27, 1, 0x00, t16, ts56),
      Monitoring.packed_start_events_of_protection_equipment_cp24time2a(
        28,
        0x07,
        0x00,
        t16,
        ts24
      ),
      Monitoring.packed_start_events_of_protection_equipment_cp56time2a(
        29,
        0x15,
        0x00,
        t16,
        ts56
      ),
      Monitoring.packed_output_circuit_info_cp24time2a(30, 0x0F, 0x00, t16, ts24),
      Monitoring.packed_output_circuit_info_cp56time2a(31, 0x03, 0x00, t16, ts56),
      Monitoring.packed_single_point_with_scd(32, 0xAAAA, 0x5555, 0x00),
      Monitoring.end_of_initialization(0, 2)
    ]

    for io <- samples do
      type_id = InformationObject.type_id(io)
      asdu = ASDU.new(type_id, cot: :spontaneous, oa: 0, ca: 1, objects: [io])
      assert {:ok, bin} = ASDU.encode(asdu)
      assert {:ok, dec_asdu} = ASDU.decode(bin)
      [dec_io] = dec_asdu.objects
      assert InformationObject.type_id(dec_io) == type_id
      assert dec_io.ioa == io.ioa
    end
  end

  test "Control, System, Parameter, and File Information Objects roundtrip" do
    ts56 = CP56Time2a.from_ms(1_700_000_000_000)

    samples = [
      Control.single_command(10, true, true, 1),
      Control.single_command_cp56time2a(11, false, false, 2, ts56),
      Control.double_command(12, 2, true, 0),
      Control.double_command_cp56time2a(13, 1, false, 3, ts56),
      Control.regulating_step_command(14, 2, false, 1),
      Control.regulating_step_command_cp56time2a(15, 1, true, 0, ts56),
      Control.setpoint_command_normalized(16, 0.5, false, 0),
      Control.setpoint_command_normalized_cp56time2a(17, -0.5, true, 0, ts56),
      Control.setpoint_command_scaled(18, 4096, false, 0),
      Control.setpoint_command_scaled_cp56time2a(19, -4096, true, 0, ts56),
      Control.setpoint_command_short(20, 220.5, false, 0),
      Control.setpoint_command_short_cp56time2a(21, -110.25, true, 0, ts56),
      Control.bitstring32_command(22, 0x11223344),
      Control.bitstring32_command_cp56time2a(23, 0x55667788, ts56),
      System.interrogation_command(0, 20),
      System.counter_interrogation_command(0, 5),
      System.read_command(100),
      System.clock_sync_command(0, ts56),
      System.test_command(0),
      System.reset_process_command(0, 1),
      System.delay_acquisition_command(0, 1250),
      System.test_command_with_cp56time2a(0, 0x4321, ts56),
      Parameter.parameter_normalized_value(50, 0.25, 1),
      Parameter.parameter_scaled_value(51, 1500, 2),
      Parameter.parameter_float_value(52, 99.5, 3),
      Parameter.parameter_activation(0, 1),
      File.file_ready(0, 10, 4096, true),
      File.section_ready(0, 10, 1, 1024, false),
      File.file_call_or_select(0, 10, 1, 2),
      File.file_last_segment_or_section(0, 10, 1, 3, 0xAB),
      File.file_ack(0, 10, 1, 1),
      File.file_segment(0, 10, 1, <<"hello iec60870">>),
      File.file_directory(0, 10, 4096, 0x20, ts56),
      File.query_log(0, 10, ts56, ts56),
      File.private_file_transfer(0, <<1, 2, 3, 4, 5>>)
    ]

    for io <- samples do
      type_id = InformationObject.type_id(io)
      asdu = ASDU.new(type_id, cot: :activation, oa: 0, ca: 1, objects: [io])
      assert {:ok, bin} = ASDU.encode(asdu)
      assert {:ok, dec_asdu} = ASDU.decode(bin)
      [dec_io] = dec_asdu.objects
      assert InformationObject.type_id(dec_io) == type_id
      assert dec_io.ioa == io.ioa
    end
  end

  test "Edge cases: CP56Time2a invalid date safety, IEEE 754 NaN/Infinity, single-IO VSQ check, COT/Qualifiers helpers" do
    alias IEC60870.Types.{COT, Qualifiers, TypeID}

    # 1. Invalid calendar fields in CP56Time2a should return 0 instead of MatchError
    invalid_ts = %CP56Time2a{
      year: 26,
      month: 0,
      day_of_month: 0,
      hour: 99,
      minute: 99,
      second: 63
    }

    assert CP56Time2a.to_ms_timestamp(invalid_ts) == 0

    # 2. IEEE 754 NaN and Infinity in MeasuredValueShort / SetpointCommandShort / ParameterFloatValue
    nan_io = %Monitoring.MeasuredValueShort{ioa: 77, value: :nan, quality: 0x80}
    nan_asdu = ASDU.new(:m_me_nc_1, cot: :spontaneous, ca: 1, objects: [nan_io])
    assert {:ok, nan_bin} = ASDU.encode(nan_asdu)
    assert {:ok, nan_dec} = ASDU.decode(nan_bin)
    assert hd(nan_dec.objects).value == :nan

    # 3. Single-IO TypeID rejects num_elements > 1 on decode
    bad_single_io_bin = <<45, 2, 6, 0, 1, 0, 1, 0, 0, 1, 2, 0, 0, 1>>
    assert {:error, :single_io_type_only} = ASDU.decode(bad_single_io_bin)

    # 4. Security TypeIDs (81..95) are not single_io? and preserve raw_payload
    refute TypeID.single_io?(:s_ch_na_1)
    sec_bin = <<81, 2, 14, 0, 1, 0, 0xAA, 0xBB, 0xCC, 0xDD>>
    assert {:ok, sec_asdu} = ASDU.decode(sec_bin)
    assert sec_asdu.type_id == :s_ch_na_1
    assert sec_asdu.raw_payload == <<0xAA, 0xBB, 0xCC, 0xDD>>

    # 5. COT.to_string/1 and Qualifiers.scd_get_st/2, scd_get_cd/2
    assert COT.to_string(:spontaneous) == "SPONTANEOUS"
    assert COT.to_string(20) == "INTERROGATED_BY_STATION"
    assert Qualifiers.scd_get_st({0b0000_0100, 0b0000_0010}, 2) == true
    assert Qualifiers.scd_get_st({0b0000_0100, 0b0000_0010}, 1) == false
    assert Qualifiers.scd_get_cd({0b0000_0100, 0b0000_0010}, 1) == true
  end
end
