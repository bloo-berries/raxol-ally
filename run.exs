# Launch the Ally TUI application
{:ok, pid} = Raxol.start_link(Ally.App, title: "Ally - Accessible AI Terminal")
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
