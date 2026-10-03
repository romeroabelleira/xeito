defmodule Xeito.TestMachines.Counter do
  @moduledoc "A small hierarchical machine for engine tests."

  use Xeito.Machine, version: "1.0.0", default_timeout: 50

  initial :idle

  state :idle, timeout: 60_000 do
    on :go, to: :active
    on :tick, to: :idle, action: :bump
    # An internal transition: no `to:`, so the state is neither left nor entered again.
    on :note, action: :bump
  end

  state :active, initial: :low do
    on :stop, to: :done
    on :reset, to: :idle

    state :low, entry: :announce, timeout: 60_000 do
      on :up, to: :high, guard: :allowed?
      on :up, to: :low, action: :bump
      on :note, action: :bump
    end

    state :high, timeout: {60_000, :cool_down} do
      on :cool_down, to: :low
    end
  end

  final :done
  final :failed

  @doc false
  def bump(ctx, _data), do: Map.update(ctx, :count, 1, &(&1 + 1))
  @doc false
  def allowed?(ctx, data), do: Map.get(data, :force, false) or Map.get(ctx, :count, 0) >= 2
  @doc false
  def announce(ctx), do: [Xeito.Effect.bash("echo low", cwd: Map.get(ctx, :cwd, "."))]
end

defmodule Xeito.TestMachines.Patient do
  @moduledoc "Runs a slow command; a `:note` (internal) may arrive while it runs."

  use Xeito.Machine, version: "1.0.0"

  initial :working

  state :working, entry: :work, timeout: 5_000 do
    on :ran, to: :done
    on :note, action: :note
  end

  final :done
  final :failed

  @doc false
  def work(ctx), do: [Xeito.Effect.bash("sleep 0.3", cwd: Map.get(ctx, :cwd, "/tmp"))]
  @doc false
  def note(ctx, _data), do: Map.update(ctx, :notes, 1, &(&1 + 1))
end

defmodule Xeito.TestMachines.Sleepy do
  @moduledoc "Waits for `:wake`; its 50 ms default timeout is unhandled, so it fails."

  use Xeito.Machine, version: "1.0.0", default_timeout: 50

  initial :waiting

  state :waiting do
    on :wake, to: :done
  end

  final :done
  final :failed
end

defmodule Xeito.TestMachines.AmbiguousType do
  @moduledoc "A decision type whose values share first tokens (scoring tests)."
  use Xeito.Decision, version: "1", name: "ambiguous"

  instructions "Ambiguous prefixes"
  input :output
  value :test_bug, "a"
  value :test_flaky, "b"
  value :env_problem, "c"
end
