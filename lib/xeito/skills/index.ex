defmodule Xeito.Skills.Index do
  @moduledoc """
  Finds skills by what a request says: a full-text index of their names and descriptions, ranked
  by BM25 (P4f step 2). SQLite's FTS5 holds it, in memory: built per search, which takes a
  couple of milliseconds for about fifty skills, so an edited or new skill counts at once.

  Words are normalised the same way in the index and in the request: lower case, British
  endings in their American form (`summarise` and `summarize` meet), diacritics removed, and
  the Porter stemmer joins a word's other forms (`testing`, `tests`, `test`). A word of a skill's
  name weighs more than a word of its description; the skill bodies are not indexed (measured:
  no better, and slower).

  A turn's shortlist (the default) keeps a skill that shares two of the request's words, or one
  of its name's, so most requests that need no skill shortlist nothing and decide without a
  model call. `any: true` keeps every match and, when no word matches, looks for the request's
  fragments inside names and descriptions (`youtub`): for finding skills by hand.
  """

  alias Exqlite.Sqlite3
  alias Xeito.Log.Sql
  alias Xeito.Skills

  # Words too common to say what a request is about.
  @common ~w(the and for with this that from into when what which where why how use used user users
             want wants need needs please can could should would will just about also any all some
             its are was were been have has had does did not you your our their them they then than
             there here make made get got one two new old way ways like more most less very much many
             each other only own same such too out over under after before while because between
             through during without within upon let lets now see say says)

  # --- matching ------------------------------------------------------------------------------

  @doc "The text as the index sees it: lower case, with British endings in their American form."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/(\p{L}{2,})is(e|es|ed|ing|ation|ations|er|ers)\b/u, "\\1iz\\2")
    |> String.replace(~r/(\p{L}{2,})our\b/u, "\\1or")
  end

  @doc """
  The skills matching `request`, the best first, at most `opts[:k]` (default 3). See the module
  documentation for `opts[:any]`.
  """
  @spec search([Skills.t()], String.t(), keyword()) :: [Skills.t()]
  def search(skills, request, opts \\ []) do
    case words(request) do
      [] ->
        []

      words ->
        skills
        |> with_index(&rowids(&1, words, opts[:any]))
        |> Enum.take(opts[:k] || 3)
        |> Enum.map(&Enum.at(skills, &1 - 1))
    end
  end

  defp words(text) do
    text
    |> normalize()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2 and &1 not in @common))
    |> Enum.uniq()
  end

  defp with_index(skills, fun) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      Sql.exec(
        db,
        "CREATE VIRTUAL TABLE skill USING fts5(name, description, tokenize = 'porter unicode61 remove_diacritics 2')"
      )

      Sql.exec(db, "CREATE VIRTUAL TABLE fragment USING fts5(text, tokenize = 'trigram remove_diacritics 1')")

      for {skill, rowid} <- Enum.with_index(skills, 1) do
        {name, description} = {normalize(skill.name), normalize(skill.description)}
        Sql.exec(db, "INSERT INTO skill (rowid, name, description) VALUES (?1, ?2, ?3)", [rowid, name, description])
        Sql.exec(db, "INSERT INTO fragment (rowid, text) VALUES (?1, ?2)", [rowid, name <> " " <> description])
      end

      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  # Words hold letters and digits only, so quoting each keeps the index's query syntax out.
  defp rowids(db, words, true), do: with_fragments(db, ranked(db, words), words)
  defp rowids(db, words, _shortlist), do: Enum.filter(ranked(db, words), &fits?(&1, hits(db, words), names(db, words)))

  defp ranked(db, words),
    do: rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1 ORDER BY bm25(skill, 10.0, 3.0)", any_of(words))

  defp with_fragments(db, [], words) do
    case Enum.filter(words, &(String.length(&1) >= 3)) do
      [] -> []
      fragments -> rows(db, "SELECT rowid FROM fragment WHERE fragment MATCH ?1 ORDER BY rank", any_of(fragments))
    end
  end

  defp with_fragments(_db, ranked, _words), do: ranked

  defp fits?(rowid, hits, names), do: Map.get(hits, rowid, 0) >= 2 or MapSet.member?(names, rowid)

  # How many of the words each skill holds.
  defp hits(db, words),
    do:
      words |> Enum.flat_map(&rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1", ~s("#{&1}"))) |> Enum.frequencies()

  # The skills whose name holds one of the words.
  defp names(db, words),
    do: MapSet.new(rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1", "name : (#{any_of(words)})"))

  defp any_of(words), do: Enum.map_join(words, " OR ", &~s("#{&1}"))

  defp rows(db, sql, query), do: Enum.map(Sql.select(db, sql, [query]), fn [rowid] -> rowid end)
end
