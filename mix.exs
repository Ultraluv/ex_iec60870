defmodule ExIEC60870.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_iec60870,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description:
        "A pure Elixir implementation of IEC 60870-5-101 and IEC 60870-5-104 (Master & Slave, Balanced & Unbalanced, full Information Objects, and bidirectional File Transfer Service), modeled directly after lib60870-C.",
      package: package(),
      deps: deps(),

      # Docs configuration
      name: "ExIEC60870",
      source_url: "https://github.com/Ultraluv/ex_iec60870",
      homepage_url: "https://github.com/Ultraluv/ex_iec60870",
      docs: [
        main: "IEC60870",
        extras: ["README.md"],
        groups_for_modules: [
          "Core & Application Layer": [
            IEC60870,
            IEC60870.ASDU,
            IEC60870.AppLayerParameters,
            IEC60870.InformationObject,
            IEC60870.InformationObject.RawObject,
            IEC60870.Telemetry
          ],
          "Monitoring Information Objects": [
            IEC60870.IO.Monitoring,
            IEC60870.IO.Monitoring.BitString32,
            IEC60870.IO.Monitoring.DoublePointInformation,
            IEC60870.IO.Monitoring.EndOfInitialization,
            IEC60870.IO.Monitoring.EventOfProtectionEquipment,
            IEC60870.IO.Monitoring.IntegratedTotals,
            IEC60870.IO.Monitoring.IntegratedTotalsForSecurityStatistics,
            IEC60870.IO.Monitoring.MeasuredValueNormalized,
            IEC60870.IO.Monitoring.MeasuredValueScaled,
            IEC60870.IO.Monitoring.MeasuredValueShort,
            IEC60870.IO.Monitoring.PackedOutputCircuitInfo,
            IEC60870.IO.Monitoring.PackedSinglePointWithSCD,
            IEC60870.IO.Monitoring.PackedStartEventsOfProtectionEquipment,
            IEC60870.IO.Monitoring.SinglePointInformation,
            IEC60870.IO.Monitoring.StepPositionInformation
          ],
          "Control Information Objects": [
            IEC60870.IO.Control,
            IEC60870.IO.Control.Bitstring32Command,
            IEC60870.IO.Control.DoubleCommand,
            IEC60870.IO.Control.SetpointCommandNormalized,
            IEC60870.IO.Control.SetpointCommandScaled,
            IEC60870.IO.Control.SetpointCommandShort,
            IEC60870.IO.Control.SingleCommand,
            IEC60870.IO.Control.StepCommand
          ],
          "System Information Objects": [
            IEC60870.IO.System,
            IEC60870.IO.System.ClockSynchronizationCommand,
            IEC60870.IO.System.CounterInterrogationCommand,
            IEC60870.IO.System.DelayAcquisitionCommand,
            IEC60870.IO.System.InterrogationCommand,
            IEC60870.IO.System.ReadCommand,
            IEC60870.IO.System.ResetProcessCommand,
            IEC60870.IO.System.TestCommand,
            IEC60870.IO.System.TestCommandWithCP56Time2a
          ],
          "Parameter Information Objects": [
            IEC60870.IO.Parameter,
            IEC60870.IO.Parameter.ParameterActivation,
            IEC60870.IO.Parameter.ParameterFloatValue,
            IEC60870.IO.Parameter.ParameterNormalizedValue,
            IEC60870.IO.Parameter.ParameterScaledValue
          ],
          "File Information Objects": [
            IEC60870.IO.File,
            IEC60870.IO.File.ExtendedFilePacket,
            IEC60870.IO.File.FileACK,
            IEC60870.IO.File.FileCallOrSelect,
            IEC60870.IO.File.FileDirectory,
            IEC60870.IO.File.FileLastSegmentOrSection,
            IEC60870.IO.File.FileReady,
            IEC60870.IO.File.FileSegment,
            IEC60870.IO.File.QueryLog,
            IEC60870.IO.File.SectionReady
          ],
          "Types & Qualifiers": [
            IEC60870.Types.BCR,
            IEC60870.Types.COT,
            IEC60870.Types.CPTime,
            IEC60870.Types.CPTime.CP16Time2a,
            IEC60870.Types.CPTime.CP24Time2a,
            IEC60870.Types.CPTime.CP32Time2a,
            IEC60870.Types.CPTime.CP56Time2a,
            IEC60870.Types.Qualifiers,
            IEC60870.Types.TypeID
          ],
          "IEC 60870-5-104 (Network)": [
            IEC60870.APCIParameters,
            IEC60870.CS104.Connection,
            IEC60870.CS104.Frame,
            IEC60870.CS104.MasterConnection,
            IEC60870.CS104.RedundancyGroup,
            IEC60870.CS104.Slave
          ],
          "IEC 60870-5-101 (Serial)": [
            IEC60870.CS101.Frame,
            IEC60870.CS101.LinkLayer,
            IEC60870.CS101.Master,
            IEC60870.CS101.Queue,
            IEC60870.CS101.Slave,
            IEC60870.CS101.Transport,
            IEC60870.CS101.Transport.UART,
            IEC60870.CS101.Transport.VirtualBus,
            IEC60870.LinkLayerParameters
          ],
          "File Transfer Service": [
            IEC60870.FileService.Client,
            IEC60870.FileService.Receiver,
            IEC60870.FileService.Receiver.Memory,
            IEC60870.FileService.Server,
            IEC60870.FileService.TransparentFile
          ]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
      # Optional dependency for real serial port hardware in CS101:
      # {:circuits_uart, "~> 1.5", optional: true}
    ]
  end

  defp package do
    [
      name: "ex_iec60870",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/Ultraluv/ex_iec60870"
      },
      files: ~w(lib examples mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
