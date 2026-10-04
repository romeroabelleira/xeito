defmodule Xeito.SkillExamplesWorkerTest do
  @moduledoc "P4f step 4: the daemon writes missing examples in the background."
  # The worker makes the HTTP calls, so Req.Test stubs are shared (serial).
  use ExUnit.Case, async: false

  alias Xeito.Log
  alias Xeito.Skills
  alias Xeito.Skills.Examples
  alias Xeito.Skills.Examples.Worker

  @moduletag :tmp_dir
  setup {Req.Test, :set_req_test_to_shared}

  defp write_skill(dir, name) do
    path = Path.join([dir, "skills", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{name} things.\n---\nBody\n")
    [skill] = Skills.load(Path.join(path, "SKILL.md"))
    skill
  end

  defp ollama(stub, test) do
    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => []})

        "/api/chat" ->
          send(test, :generated)
          Req.Test.json(conn, %{"message" => %{"content" => ~s({"requests": ["an example"]})}})
      end
    end)

    [url: "http://#{stub}.test", plug: {Req.Test, stub}, model: "m"]
  end

  defp start(dir, cfg) do
    {:ok, log} = Log.start_link(path: Path.join(dir, "log.sqlite"))
    start_supervised!({Worker, name: nil, cfg: cfg, dir: Path.join(dir, "cache"), log: log, startup: []})
  end

  test "writes the examples of the skills a turn wants, once each", %{tmp_dir: dir} do
    cfg = ollama(:worker_wanted, self())
    worker = start(dir, cfg)
    skills = [write_skill(dir, "a"), write_skill(dir, "b")]

    Worker.wanted(worker, skills)
    Worker.wanted(worker, skills)
    assert_receive :generated
    assert_receive :generated
    :ok = Worker.idle(worker)
    refute_received :generated

    assert [%{examples: ["an example"]}, %{examples: ["an example"]}] = Examples.attach(skills, Path.join(dir, "cache"))
  end

  test "writes the skills it is started with", %{tmp_dir: dir} do
    cfg = ollama(:worker_startup, self())
    {:ok, log} = Log.start_link(path: Path.join(dir, "log.sqlite"))
    skill = write_skill(dir, "a")
    worker = start_supervised!({Worker, name: nil, cfg: cfg, dir: Path.join(dir, "cache"), log: log, startup: [skill]})
    :ok = Worker.idle(worker)
    assert [%{examples: ["an example"]}] = Examples.attach([skill], Path.join(dir, "cache"))
  end

  test "without a local tier it writes nothing", %{tmp_dir: dir} do
    {:ok, log} = Log.start_link(path: Path.join(dir, "log.sqlite"))
    worker = start_supervised!({Worker, name: nil, cfg: nil, dir: Path.join(dir, "cache"), log: log, startup: []})
    Worker.wanted(worker, [write_skill(dir, "a")])
    :ok = Worker.idle(worker)
    assert [%{examples: []}] = Examples.attach([write_skill(dir, "a")], Path.join(dir, "cache"))
  end
end
