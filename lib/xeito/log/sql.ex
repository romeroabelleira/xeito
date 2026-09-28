defmodule Xeito.Log.Sql do
  @moduledoc false
  # Small helpers over an Exqlite connection, shared by the log, its store and retention.

  alias Exqlite.Sqlite3

  @doc "Runs a statement that returns no rows."
  @spec exec(Sqlite3.db(), String.t(), list()) :: :ok
  def exec(db, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      :done = Sqlite3.step(db, stmt)
      :ok
    after
      Sqlite3.release(db, stmt)
    end
  end

  @doc "Runs a query and returns all rows."
  @spec select(Sqlite3.db(), String.t(), list()) :: [list()]
  def select(db, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end

  @doc "Runs `fun` in an immediate transaction, rolling back on an exception."
  @spec transaction(Sqlite3.db(), (-> result)) :: result when result: term()
  def transaction(db, fun) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = Sqlite3.execute(db, "COMMIT")
      result
    rescue
      error ->
        Sqlite3.execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end
end
