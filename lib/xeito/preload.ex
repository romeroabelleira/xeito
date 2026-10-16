defmodule Xeito.Preload do
  @moduledoc """
  Loads all of the daemon's code when it starts, its own and every dependency's.

  Loading eagerly keeps one consistent code version until restart, even if the checkout is
  rebuilt meanwhile; `stale?/0` tells when the code on disk has moved on.
  """

  @doc "Loads every module of `apps` (default: the running applications). Returns how many."
  @spec load_all([atom()]) :: non_neg_integer()
  def load_all(apps \\ running()) do
    modules = Enum.flat_map(apps, &modules/1)

    case Code.ensure_all_loaded(modules) do
      :ok -> length(modules)
      {:error, failed} -> length(modules) - length(failed)
    end
  end

  @doc "The compiled modules (`.beam` files) in `dirs` written after `time` (Unix seconds)."
  @spec changed_since([Path.t()], integer()) :: [Path.t()]
  def changed_since(dirs, time) do
    for dir <- dirs,
        file <- Path.wildcard(Path.join(dir, "*.beam")),
        File.stat!(file, time: :posix).mtime > time,
        do: file
  end

  @doc """
  Whether the code on disk changed after the daemon loaded it (`:code_loaded_at`, set by
  `mix xeito.daemon`); always `false` outside the daemon.
  """
  @spec stale?() :: boolean()
  def stale? do
    case Application.get_env(:xeito, :code_loaded_at) do
      nil -> false
      time -> changed_since(Enum.flat_map(running(), &ebin/1), time) != []
    end
  end

  defp running, do: for({app, _, _} <- Application.started_applications(), do: app)

  defp modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  # Some applications (an escript's, Mix's own in a release) have no library directory.
  defp ebin(app) do
    case :code.lib_dir(app) do
      {:error, _} -> []
      dir -> [Path.join(to_string(dir), "ebin")]
    end
  end
end
