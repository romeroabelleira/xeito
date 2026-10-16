defmodule Xeito.Skills.Index do
  @moduledoc """
  Finds skills matching a request: BM25 full-text search over names, keywords, examples and descriptions.

  The index is an in-memory SQLite FTS5 table built per search, so edited skills count at once.

    * words are lower-cased, British endings mapped to American (`summarise` = `summarize`),
      diacritics removed and Porter-stemmed, in the index and in the request alike
    * weights, highest first: name, keywords, examples, description; skill bodies are not indexed
    * default (a turn's shortlist): keeps a skill with one request word in its name or keywords,
      two in name, keywords and description, or three in its examples
    * `any: true` (search by hand): keeps every match and, when no word matches, falls back to
      trigram fragments of names and descriptions (`youtub`)
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

  @doc "The skills matching `request`, best first, at most `opts[:k]` (default 3); `opts[:any]` as in the moduledoc."
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

  @tables [
    "CREATE VIRTUAL TABLE skill USING fts5(name, keywords, examples, description, tokenize = 'porter unicode61 remove_diacritics 2')",
    "CREATE VIRTUAL TABLE fragment USING fts5(text, tokenize = 'trigram remove_diacritics 1')"
  ]

  defp with_index(skills, fun) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      Enum.each(@tables, &Sql.exec(db, &1))
      skills |> Enum.with_index(1) |> Enum.each(&insert(db, &1))
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp insert(db, {skill, rowid}) do
    [name, keywords, examples, description] =
      Enum.map([skill.name, list(skill, :keywords), list(skill, :examples), skill.description], &normalize/1)

    Sql.exec(db, "INSERT INTO skill (rowid, name, keywords, examples, description) VALUES (?1, ?2, ?3, ?4, ?5)", [
      rowid,
      name,
      keywords,
      examples,
      description
    ])

    Sql.exec(db, "INSERT INTO fragment (rowid, text) VALUES (?1, ?2)", [
      rowid,
      Enum.join([name, keywords, description], " ")
    ])
  end

  defp list(skill, key), do: skill |> Map.get(key, []) |> Enum.join("\n")

  # Words hold letters and digits only, so quoting each keeps the index's query syntax out.
  defp rowids(db, words, true), do: with_fragments(db, ranked(db, words), words)

  defp rowids(db, words, _shortlist) do
    counts = {hits(db, words, "{name keywords description}"), hits(db, words, "examples"), names(db, words)}
    Enum.filter(ranked(db, words), &fits?(&1, counts))
  end

  defp ranked(db, words),
    do: rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1 ORDER BY bm25(skill, 10.0, 5.0, 4.0, 3.0)", any_of(words))

  defp with_fragments(db, [], words) do
    case Enum.filter(words, &(String.length(&1) >= 3)) do
      [] -> []
      fragments -> rows(db, "SELECT rowid FROM fragment WHERE fragment MATCH ?1 ORDER BY rank", any_of(fragments))
    end
  end

  defp with_fragments(_db, ranked, _words), do: ranked

  # Examples need three hits: generated sentences hold everyday words ("tests", "error").
  defp fits?(rowid, {described, examples, names}),
    do: MapSet.member?(names, rowid) or Map.get(described, rowid, 0) >= 2 or Map.get(examples, rowid, 0) >= 3

  # rowid => how many of the words the skill holds in `columns`.
  defp hits(db, words, columns),
    do:
      words
      |> Enum.flat_map(&rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1", ~s(#{columns} : "#{&1}")))
      |> Enum.frequencies()

  defp names(db, words),
    do: MapSet.new(rows(db, "SELECT rowid FROM skill WHERE skill MATCH ?1", "{name keywords} : (#{any_of(words)})"))

  defp any_of(words), do: Enum.map_join(words, " OR ", &~s("#{&1}"))

  defp rows(db, sql, query), do: Enum.map(Sql.select(db, sql, [query]), fn [rowid] -> rowid end)
end
