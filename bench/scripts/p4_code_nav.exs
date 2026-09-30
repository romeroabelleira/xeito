# Code-navigation benchmark for P4: one task, run in-process by the harness checkout it is started
# from, so two harness versions can be compared on identical scratch workspaces.
#
#   source tiers.env   # tier endpoints
#   mix run bench/scripts/p4_code_nav.exs WORKSPACE OUT.json
#
# The prompt (BENCH_PROMPT) goes through the normal session: Intent, routing, the chat machine,
# Risk, the quick check. Reviews are *denied* automatically (and counted), so no command a human
# would have to approve ever runs and both variants are treated alike. Writes a JSON summary:
# steps, tool calls by kind, reads by mode, bash commands, edited files, check outcome, tokens and
# wall time.

alias Xeito.{Log, Run, Session}

[workspace, out] = System.argv()

prompt =
  System.get_env("BENCH_PROMPT", "Make the TUI's prompt cursor blink, like an editor's cursor.")

{:ok, id} = Session.start(cwd: workspace)
Session.subscribe(id)
started = System.monotonic_time(:millisecond)
:ok = Session.prompt(id, prompt)

wait = fn wait, denied ->
  receive do
    {:xeito, _, %{type: "human_needed"}} ->
      Session.deny(id)
      wait.(wait, denied + 1)

    {:xeito, _, %{type: "turn_finished", run: run}} ->
      {run, denied}

    {:xeito, _, _} ->
      wait.(wait, denied)
  after
    1_800_000 -> {:timeout, denied}
  end
end

{run, denied} = wait.(wait, 0)
wall_ms = System.monotonic_time(:millisecond) - started
log = Log.for_workspace(workspace)

summary =
  case run do
    :timeout ->
      %{outcome: "timeout"}

    run ->
      {:ok, result} = Run.result(log, run)
      ctx = result.ctx

      effects =
        for {_, "effect_requested", {:effect_requested, e}} <- Log.read_run(log, run), do: e

      reads =
        for %{kind: :read, args: a} <- effects do
          cond do
            a[:result] -> "result"
            a[:lines] -> "lines"
            a[:symbol] -> "symbol"
            a[:outline] -> "outline"
            true -> "file"
          end
        end

      %{
        outcome: to_string(result.state),
        machine: run |> then(&Log.read_run(log, &1)) |> hd() |> elem(2) |> elem(1) |> inspect(),
        steps: ctx[:steps],
        stopped: ctx[:stopped] || false,
        checks: ctx[:checks] && Map.new(ctx.checks, fn {k, v} -> {k, to_string(v)} end),
        effects: effects |> Enum.frequencies_by(&to_string(&1.kind)),
        reads: Enum.frequencies(reads),
        bash: for(%{kind: :bash, args: a} <- effects, do: a.cmd),
        edited: for(%{kind: k, args: a} <- effects, k in [:write, :edit], uniq: true, do: a.path),
        tokens_in: ctx[:tokens_in],
        tokens_out: ctx[:tokens_out],
        answer: ctx[:answer]
      }
  end
  |> Map.merge(%{run: to_string(run), denied_reviews: denied, wall_ms: wall_ms, prompt: prompt})

File.write!(out, JSON.encode!(summary))
IO.puts(JSON.encode!(Map.drop(summary, [:bash, :answer])))
