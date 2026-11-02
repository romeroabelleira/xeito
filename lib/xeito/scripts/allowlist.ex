defmodule Xeito.Scripts.Allowlist do
  @moduledoc """
  What a script may call (`Dune.Allowlist`): Dune's default allow-list without the clock,
  randomness or processes, plus `Xeito.Scripts.Api`, through which every call to the outside goes.

  Dune's default leaves out the file system, the network, the environment, code loading and atom
  creation already. This list also refuses `DateTime`, `Date`, `NaiveDateTime`, `Time`, `Calendar`,
  `Process`, `:rand`, `:crypto`, and the `:erlang` functions that read a clock or make unique values, so a script sees
  only what the runner gives it (`now/0`, `random/0`) and a replay sees what the first run saw.
  """

  @behaviour Dune.Allowlist

  @restricted_modules [DateTime, Date, NaiveDateTime, Time, Calendar, Calendar.ISO, Process, :rand, :crypto]
  @restricted_erlang ~w(date time timestamp system_time monotonic_time universaltime localtime
                        localtime_to_universaltime universaltime_to_localtime unique_integer make_ref
                        phash2 time_offset)a

  @impl true
  def fun_status(module, _fun, _arity) when module in [Xeito.Scripts.Api, Script], do: :allowed
  def fun_status(module, _fun, _arity) when module in @restricted_modules, do: :restricted
  def fun_status(:erlang, fun, _arity) when fun in @restricted_erlang, do: :restricted
  def fun_status(module, fun, arity), do: Dune.Allowlist.Default.fun_status(module, fun, arity)
end
