defmodule Xeito.SkillExamplesTest do
  @moduledoc "P4f step 4: example requests per skill, written by the local model, cached and logged."
  use ExUnit.Case, async: true

  alias Xeito.Log
  alias Xeito.Skills
  alias Xeito.Skills.Examples

  @moduletag :tmp_dir

  defp write_skill(dir, name, description, body \\ "Fetch the transcript with the script.") do
    path = Path.join([dir, "skills", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n#{body}\n")
    [skill] = Skills.load(Path.join(path, "SKILL.md"))
    skill
  end

  # A fake Ollama: `/api/tags` lists the model, `/api/chat` answers `requests` and reports the
  # request body to the test.
  defp ollama(stub, requests, test \\ self()) do
    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "big:27b", "digest" => "sha256:abc"}]})

        "/api/chat" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:chat, JSON.decode!(body)})
          content = JSON.encode!(%{"requests" => requests})
          Req.Test.json(conn, %{"message" => %{"content" => content}, "prompt_eval_count" => 300, "eval_count" => 120})
      end
    end)

    [url: "http://#{stub}.test", plug: {Req.Test, stub}, model: "big:27b"]
  end

  describe "generate/2" do
    test "asks the model for requests the skill serves, under a JSON schema", %{tmp_dir: dir} do
      skill = write_skill(dir, "youtube-transcript", "Fetch transcripts from YouTube videos.")
      cfg = ollama(:ex_gen, [" what does the speaker say? ", "summarise this talk", "", "summarise this talk"])

      assert {:ok, %{examples: ["what does the speaker say?", "summarise this talk"], tokens_in: 300, tokens_out: 120}} =
               Examples.generate(skill, cfg)

      assert_receive {:chat, request}
      assert %{"model" => "big:27b", "stream" => false, "format" => %{"properties" => %{"requests" => _}}} = request
      prompt = Enum.map_join(request["messages"], "\n", & &1["content"])
      assert prompt =~ "youtube-transcript"
      assert prompt =~ "Fetch transcripts from YouTube videos."
      assert prompt =~ "Fetch the transcript with the script."
    end

    test "an answer that is not the requested JSON is an error", %{tmp_dir: dir} do
      skill = write_skill(dir, "s", "d")

      Req.Test.stub(:ex_bad, fn conn -> Req.Test.json(conn, %{"message" => %{"content" => "not json"}}) end)

      assert {:error, :invalid_answer} =
               Examples.generate(skill, url: "http://b.test", plug: {Req.Test, :ex_bad}, model: "m")

      Req.Test.stub(:ex_500, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:http, 500, _}} =
               Examples.generate(skill, url: "http://f.test", plug: {Req.Test, :ex_500}, model: "m")
    end
  end

  describe "digest/1" do
    test "the digest Ollama lists for the model" do
      assert {:ok, "sha256:abc"} = Examples.digest(ollama(:ex_tags, []))
      assert {:ok, nil} = Examples.digest(Keyword.put(ollama(:ex_tags2, []), :model, "other"))
    end
  end

  describe "the cache" do
    test "attach/2 adds the cached examples of each skill whose file is unchanged", %{tmp_dir: dir} do
      skill = write_skill(dir, "youtube-transcript", "Fetch transcripts.")
      other = write_skill(dir, "other", "Other.")
      cache = Path.join(dir, "cache")

      Examples.put(skill, %{model: "big:27b", digest: "sha256:abc", examples: ["what does the speaker say?"]}, cache)
      assert [%{examples: ["what does the speaker say?"]}, %{examples: []}] = Examples.attach([skill, other], cache)

      File.write!(Path.join(skill.dir, "SKILL.md"), "---\nname: youtube-transcript\ndescription: Edited.\n---\n")
      assert [%{examples: []}] = Examples.attach([skill], cache)
    end

    test "stale/4: no entry, an edited skill, or another model or digest", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      fresh = write_skill(dir, "fresh", "Fresh.")
      missing = write_skill(dir, "missing", "Missing.")
      edited = write_skill(dir, "edited", "Edited.")
      Examples.put(fresh, %{model: "big:27b", digest: "sha256:abc", examples: ["x"]}, cache)
      Examples.put(edited, %{model: "big:27b", digest: "sha256:abc", examples: ["x"]}, cache)
      File.write!(Path.join(edited.dir, "SKILL.md"), "---\nname: edited\ndescription: Changed.\n---\n")

      assert ["missing", "edited"] =
               [fresh, missing, edited] |> Examples.stale("big:27b", "sha256:abc", cache) |> Enum.map(& &1.name)

      assert 3 = length(Examples.stale([fresh, missing, edited], "big:27b", "sha256:new", cache))
      assert 3 = length(Examples.stale([fresh, missing, edited], "small", "sha256:abc", cache))
    end
  end

  describe "refresh/3" do
    test "generates the stale skills' examples, caches them and logs each generation", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      {:ok, log} = Log.start_link(path: Path.join(dir, "log.sqlite"))
      skill = write_skill(dir, "youtube-transcript", "Fetch transcripts.")
      cfg = ollama(:ex_refresh, ["what does the speaker say?"])

      assert [{"youtube-transcript", {:ok, 1}}] = Examples.refresh([skill], cfg, dir: cache, log: log)
      assert [%{examples: ["what does the speaker say?"]}] = Examples.attach([skill], cache)

      assert [{_seq, "skill_examples_generated", {:skill_examples_generated, attrs}}] =
               Log.read_run(log, "skills/examples")

      assert %{skill: "youtube-transcript", model: "big:27b", digest: "sha256:abc", count: 1, tokens_out: 120} = attrs

      # Fresh now: nothing to generate.
      assert [] = Examples.refresh([skill], cfg, dir: cache, log: log)
    end

    test "a failed generation is reported and leaves the cache as it was", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      {:ok, log} = Log.start_link(path: Path.join(dir, "log.sqlite"))
      skill = write_skill(dir, "s", "d")

      Req.Test.stub(:ex_fail, fn conn ->
        case conn.request_path do
          "/api/tags" -> Req.Test.json(conn, %{"models" => []})
          "/api/chat" -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      cfg = [url: "http://fail.test", plug: {Req.Test, :ex_fail}, model: "m"]
      assert [{"s", {:error, {:http, 500, _}}}] = Examples.refresh([skill], cfg, dir: cache, log: log)
      assert [%{examples: []}] = Examples.attach([skill], cache)
    end
  end

  describe "the index searches the examples" do
    alias Xeito.Skills.Index

    defp indexed(name, description, extra),
      do:
        Map.merge(
          %{name: name, description: description, dir: "/s/#{name}", model_invocation: true, keywords: [], examples: []},
          extra
        )

    test "three words of a request in a skill's examples shortlist it, two do not" do
      talk = indexed("youtube-transcript", "Fetch transcripts.", %{examples: ["summarise the conference talk for me"]})
      assert [_] = Index.search([talk], "summarise this conference talk")
      assert [] = Index.search([talk], "summarise this conference keynote")
    end

    test "example words and description words are counted apart" do
      talk = indexed("talks", "Fetch transcripts.", %{examples: ["summarise the conference keynote"]})
      assert [] = Index.search([talk], "summarise the transcripts")
    end

    test "an example word ranks below a keyword" do
      skills = [
        indexed("a", "First.", %{examples: ["who was the speaker"]}),
        indexed("b", "Second.", %{keywords: ["speaker"]})
      ]

      assert ["b", "a"] = skills |> Index.search("speaker", any: true) |> Enum.map(& &1.name)
    end

    test "Skills.discover/2 attaches the cached examples", %{tmp_dir: dir} do
      skill = write_skill(dir, "youtube-transcript", "Fetch transcripts.")
      File.mkdir_p!(Path.join(dir, "ws/.agents/skills"))
      File.cp_r!(skill.dir, Path.join(dir, "ws/.agents/skills/youtube-transcript"))
      [copied] = Skills.discover(Path.join(dir, "ws"), home: dir, keywords: nil)
      Examples.put(copied, %{model: "m", digest: nil, examples: ["what does the speaker say?"]})

      assert [%{examples: ["what does the speaker say?"]}] =
               Skills.discover(Path.join(dir, "ws"), home: dir, keywords: nil)
    end
  end
end
