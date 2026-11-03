#!/usr/bin/env elixir
# examples/cs101_master_unbalanced/master_example.exs
# Run with: mix run examples/cs101_master_unbalanced/master_example.exs

alias IEC60870.CS101.Master
alias IEC60870.CS101.Transport.VirtualBus
alias IEC60870.IO.Control

IO.puts("==================================================")
IO.puts(" IEC 60870-5-101 Unbalanced Master Example")
IO.puts("==================================================")

{:ok, bus} = VirtualBus.start_link()

{:ok, master} =
  Master.start_link(
    transport: {VirtualBus, bus},
    mode: :unbalanced,
    slaves: [1, 2],
    slave_address: 1,
    asdu_handler: fn _m, slave_addr, asdu ->
      IO.puts(
        "[CS101 Master] ASDU from Slave #{slave_addr}: Type=#{asdu.type_id}, COT=#{asdu.cot}"
      )
    end,
    link_state_handler: fn _m, slave_addr, state ->
      IO.puts("[CS101 Master] Slave #{slave_addr} link state: #{state}")
    end
  )

Process.sleep(200)

IO.puts("[CS101 Master] Polling Slave 1 for Class 2 background data...")
:ok = Master.poll_single_slave(master, 1)

IO.puts("[CS101 Master] Sending Interrogation Command to Slave 1...")
:ok = Master.use_slave_address(master, 1)
:ok = Master.send_interrogation_command(master, :activation, 1, 20)

Process.sleep(500)

IO.puts("[CS101 Master] Sending Control Command to Slave 2...")
cmd = Control.single_command(500, true, false, 0)
:ok = Master.use_slave_address(master, 2)
:ok = Master.send_process_command(master, :activation, 2, cmd)

IO.puts("[CS101 Master] Master loop running. Press Ctrl+C to terminate.")
Process.sleep(:infinity)
