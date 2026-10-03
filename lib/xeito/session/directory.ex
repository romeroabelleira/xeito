defmodule Xeito.Session.Directory do
  @moduledoc """
  A directory's sessions, read from its log: the one a client continues by default
  (`latest/2`), the list `/sessions` shows (`sessions/2`), the prompts typed there, for
  Up/Down (`prompts/3`), and a session's turns with their answers, for its transcript
  (`turns/3`). A session belongs to the directory it was started in (its `cwd` in the
  log).

  A session's prompts are its `prompt_entered` events. Sessions logged before those existed
  contribute their turns' requests instead: the input of each `<session>/tN` run.
  """

  alias Xeito.Log
  alias Xeito.Session

  @type session :: %{
          id: String.t(),
          last: String.t(),
          prompts: non_neg_integer(),
          last_prompt: String.t() | nil
        }

  # Opening or resuming a session counts as activity; a status change (closing) does not.
  @opened """
  SELECT ocel_id, MAX(ocel_time) FROM object_session
  WHERE ocel_changed_field IS NULL AND ocel_id IN (SELECT ocel_id FROM object_session WHERE cwd = ?1)
  GROUP BY ocel_id
  """

  @entered """
  SELECT p.ocel_time, o.ocel_object_id, p.text
  FROM event_prompt_entered p JOIN event_object o ON o.ocel_event_id = p.ocel_id
  WHERE o.ocel_object_id IN (SELECT ocel_id FROM object_session WHERE cwd = ?1)
  """

  # The run started for each turn, `<session>/t<n>`: not its sub-runs (`…/t1/intent`).
  @requested """
  SELECT e.ocel_time, substr(o.ocel_object_id, 1, instr(o.ocel_object_id, '/') - 1),
         COALESCE(json_extract(e.input, '$.request'), json_extract(e.input, '$.prompt'))
  FROM event_run_started e JOIN event_object o ON o.ocel_event_id = e.ocel_id
  WHERE substr(o.ocel_object_id, 1, instr(o.ocel_object_id, '/') - 1)
          IN (SELECT ocel_id FROM object_session WHERE cwd = ?1)
    AND substr(o.ocel_object_id, instr(o.ocel_object_id, '/') + 1) GLOB 't[0-9]*'
    AND instr(substr(o.ocel_object_id, instr(o.ocel_object_id, '/') + 1), '/') = 0
  """

  @doc "The directory's sessions, the last updated first."
  @spec sessions(Log.server(), Path.t()) :: [session()]
  def sessions(log, cwd) do
    by_session = log |> entries(cwd) |> Enum.group_by(fn {_time, id, _text} -> id end)

    log
    |> Log.query(@opened, [Path.expand(cwd)])
    |> Enum.map(fn [id, opened] -> session(id, opened, Map.get(by_session, id, [])) end)
    |> Enum.sort_by(& &1.last, :desc)
  end

  defp session(id, opened, prompts) do
    %{
      id: id,
      last: Enum.max([opened | Enum.map(prompts, fn {time, _id, _text} -> time end)]),
      prompts: length(prompts),
      last_prompt: last_prompt(prompts)
    }
  end

  defp last_prompt([{_time, _id, text} | _]), do: text
  defp last_prompt([]), do: nil

  @doc "The directory's last updated session, or `nil` if it has none."
  @spec latest(Log.server(), Path.t()) :: String.t() | nil
  def latest(log, cwd) do
    case sessions(log, cwd) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  @doc "The prompts typed in the directory, newest first, each once, at most `limit`."
  @spec prompts(Log.server(), Path.t(), pos_integer()) :: [String.t()]
  def prompts(log, cwd, limit \\ 500) do
    log
    |> entries(cwd)
    |> Enum.map(fn {_time, _id, text} -> text end)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  @doc """
  A session's last `limit` turns, oldest first: each turn's request and its answer as the session
  reported it (`nil` while the turn runs). Read from the turns' runs (`<session>/t<n>`), so the
  harness's own messages to the model are not among them.
  """
  @spec turns(Log.server(), String.t(), pos_integer()) :: [%{prompt: String.t() | nil, answer: String.t() | nil}]
  def turns(log, session, limit \\ 20) do
    log
    |> Log.query("SELECT DISTINCT run_id FROM xeito_term WHERE run_id LIKE ?1", [session <> "/t%"])
    |> Enum.flat_map(fn [run] -> turn_number(run, session) end)
    |> Enum.sort()
    |> Enum.take(-limit)
    |> Enum.map(fn {_n, run} -> turn(log, run) end)
  end

  defp turn_number(run, session) do
    case Regex.run(~r/^t(\d+)$/, String.replace_prefix(run, session <> "/", "")) do
      [_, n] -> [{String.to_integer(n), run}]
      nil -> []
    end
  end

  defp turn(log, run) do
    entries = Log.read_run(log, run)
    [{machine, input}] = for {_, "run_started", {:run_started, machine, _, input}} <- entries, do: {machine, input}
    finished = for {_, "run_finished", {:run_finished, status, state, ctx}} <- entries, do: {status, state, ctx}
    %{prompt: input[:request] || input[:prompt], answer: answer(machine, finished)}
  end

  defp answer(machine, [{status, state, ctx} | _]),
    do: Session.turn_answer(machine, %{status: status, state: state, ctx: ctx})

  defp answer(_machine, []), do: nil

  # `{time, session, text}`, newest first: logged prompts, and the turns' requests of sessions
  # without any.
  defp entries(log, cwd) do
    cwd = Path.expand(cwd)
    entered = rows(log, @entered, cwd)
    logged = MapSet.new(entered, fn {_time, id, _text} -> id end)
    requested = for {_time, id, _text} = row <- rows(log, @requested, cwd), id not in logged, do: row

    Enum.sort_by(entered ++ requested, fn {time, _id, _text} -> time end, :desc)
  end

  defp rows(log, sql, cwd) do
    for [time, id, text] <- Log.query(log, sql, [cwd]), is_binary(text) and text != "", do: {time, id, text}
  end
end
