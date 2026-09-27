defmodule Xeito.Effects.Runner do
  @moduledoc "Behaviour for effect runners. `run/2` executes one effect and returns its result."

  @callback run(Xeito.Effect.t(), keyword()) :: map()
end
