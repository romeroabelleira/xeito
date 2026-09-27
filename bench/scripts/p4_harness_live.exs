# Live harness check for P4: a client of a running daemon drives a session in a scratch project.
#
#   mix xeito.daemon &                      # with tier endpoints in the environment
#   mix run --no-start bench/scripts/p4_harness_live.exs WORKSPACE [prompt …]
#
# Each prompt is sent in turn; the rendered transcript is printed with the wall-clock time per
# turn and the time to the first streamed token (Intent decision + model start), whose median is
# the P4 exit criterion (< 1.5 s). Reviews are approved automatically (and printed), so run it on
# a scratch workspace only.

alias Xeito.Client
alias Xeito.Client.Render

[workspace | prompts] = System.argv()

prompts =
  if prompts == [],
    do: ["What files are in this project?", "The pricing test is failing. Fix it."],
    else: prompts

{:ok, client} = Client.connect(Xeito.Api.default_socket())
%{"ok" => true, "session" => session} = Client.request(client, %{"cmd" => "start", "cwd" => workspace})
IO.puts("session #{session} in #{workspace}\n")

wait = fn wait, started, first ->
  receive do
    {:xeito_event, %{"event" => "human_needed"} = e} ->
      IO.write(Render.line(e))
      IO.puts("  (auto-approved)")
      Client.request(client, %{"cmd" => "approve", "session" => session})
      wait.(wait, started, first)

    {:xeito_event, %{"event" => "turn_finished"} = e} ->
      IO.write(Render.line(e))
      total = System.monotonic_time(:millisecond) - started
      IO.puts("  [#{total} ms · first token #{inspect(first)} ms]\n")
      first

    {:xeito_event, %{"event" => "error"} = e} ->
      IO.write(Render.line(e))
      first

    {:xeito_event, %{"event" => "delta"} = e} ->
      IO.write(Render.line(e))
      wait.(wait, started, first || System.monotonic_time(:millisecond) - started)

    {:xeito_event, e} ->
      IO.write(Render.line(e))
      wait.(wait, started, first)
  after
    600_000 -> IO.puts("timeout")
  end
end

firsts =
  for prompt <- prompts do
    IO.puts("> " <> prompt)
    started = System.monotonic_time(:millisecond)
    %{"ok" => true} = Client.request(client, %{"cmd" => "prompt", "session" => session, "text" => prompt})
    wait.(wait, started, nil)
  end

case firsts |> Enum.reject(&is_nil/1) |> Enum.sort() do
  [] -> IO.puts("no streamed turns")
  sorted -> IO.puts("first token: median #{Enum.at(sorted, div(length(sorted), 2))} ms of #{inspect(sorted)}")
end

%{"status" => status} = Client.request(client, %{"cmd" => "status", "session" => session})
IO.puts("status: #{inspect(status)}")
