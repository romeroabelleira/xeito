defmodule Xeito.EscalationTest do
  # Tier calls happen inside supervised effect tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.Budget
  alias Xeito.Decisions.Risk
  alias Xeito.Decisions.Triage

  # --- stubs -------------------------------------------------------------------------------

  alias Xeito.Escalation
  alias Xeito.Log
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Run
  alias Xeito.RunSupervisor

  setup {Req.Test, :set_req_test_to_shared}

  @input %{test: "CheckoutTest", output: "left: 107.0 right: 108.0", diff_stat: "lib/pricing.ex"}

  defp small(conf) do
    Req.Test.stub(:esc_small, fn conn ->
      case conn.request_path do
        "/apply-template" ->
          Req.Test.json(conn, %{"prompt" => "p"})

        "/completion" ->
          tops = [{"code", conf}, {"test", (1 - conf) / 2}, {"fl", (1 - conf) / 2}]

          Req.Test.json(conn, %{
            "completion_probabilities" => [
              %{
                "top_logprobs" => Enum.map(tops, fn {t, p} -> %{"token" => t, "logprob" => :math.log(p)} end)
              }
            ]
          })
      end
    end)

    [url: "http://small.test", plug: {Req.Test, :esc_small}, model: "small-test"]
  end

  defp large(loaded?, test_pid \\ nil) do
    Req.Test.stub(:esc_large, &ollama(&1, loaded?, test_pid))
    [url: "http://large.test", plug: {Req.Test, :esc_large}, model: "big"]
  end

  defp ollama(%{request_path: "/api/ps"} = conn, loaded?, _test_pid) do
    models = if loaded?, do: [%{"name" => "big", "model" => "big"}], else: []
    Req.Test.json(conn, %{"models" => models})
  end

  defp ollama(%{request_path: "/api/generate"} = conn, _loaded?, test_pid) do
    if test_pid, do: send(test_pid, :swap_requested)
    Req.Test.json(conn, %{"done" => true})
  end

  defp ollama(%{request_path: "/api/chat"} = conn, _loaded?, test_pid) do
    if test_pid, do: send(test_pid, :large_called)

    Req.Test.json(conn, %{
      "message" => %{"content" => ~s({"value": "code_bug"})},
      "prompt_eval_count" => 120,
      "eval_count" => 8,
      "logprobs" => ollama_logprobs()
    })
  end

  defp ollama_logprobs do
    for t <- [~s({"), "value", ~s(":), ~s( "), "code", "_bug", ~s("})] do
      tops =
        if t == "code",
          do: [
            %{"token" => "code", "logprob" => :math.log(0.97)},
            %{"token" => "test", "logprob" => :math.log(0.03)}
          ],
          else: []

      %{"token" => t, "logprob" => -0.01, "top_logprobs" => tops}
    end
  end

  defp remote(test_pid) do
    Req.Test.stub(:esc_remote, fn conn ->
      send(test_pid, :remote_called)

      Req.Test.json(conn, %{
        "model" => "claude-opus-5",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => ~s({"value": "test_bug"})}],
        "usage" => %{"input_tokens" => 400, "output_tokens" => 20}
      })
    end)

    [url: "http://remote.test", api_key: "k", plug: {Req.Test, :esc_remote}]
  end

  defp openrouter(test_pid, conf) do
    Req.Test.stub(:esc_openrouter, fn conn ->
      send(test_pid, :openrouter_called)

      Req.Test.json(conn, %{
        "model" => "qwen/qwen3.6-35b-a3b",
        "provider" => "Parasail",
        "choices" => [
          %{
            "message" => %{"content" => ~s({"value": "code_bug"})},
            "logprobs" => %{"content" => openai_logprobs(conf)}
          }
        ],
        "usage" => %{"prompt_tokens" => 300, "completion_tokens" => 7, "cost" => 0.00006}
      })
    end)

    [url: "http://openrouter.test", api_key: "k", model: "qwen/qwen3.6-35b-a3b"] ++
      [plug: {Req.Test, :esc_openrouter}]
  end

  defp openai_logprobs(conf) do
    for t <- [~s({"), "value", ~s(":), ~s( "), "code", "_bug", ~s("})] do
      tops =
        if t == "code",
          do: [
            %{"token" => "code", "logprob" => :math.log(conf)},
            %{"token" => "test", "logprob" => :math.log(1 - conf)}
          ],
          else: []

      %{"token" => t, "logprob" => -0.01, "top_logprobs" => tops}
    end

    # --- tests -------------------------------------------------------------------------------
  end

  defp decide(type, input, opts) do
    log = Keyword.get_lazy(opts, :log, fn -> start_log!() end)
    parent = Keyword.get(opts, :parent, run_id())
    decision = Escalation.decide(type, input, Keyword.merge([log: log, parent: parent], opts))
    {decision, log, parent}
  end

  defp states(log, id), do: for({_, "state_entered", {:state_entered, s}} <- Log.read_run(log, id), do: s)

  defp only_run(log, parent) do
    [[id]] =
      Log.query(
        log,
        "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'",
        [parent]
      )

    id
  end

  test "a rule decides at once; the escalation is a child run related to its parent" do
    {d, log, parent} =
      decide(Triage, %{test: "t", output: "sh: esbuild: command not found"}, deciders: [])

    assert %{value: :env_problem, actor: :rule} = d
    id = only_run(log, parent)
    assert states(log, id) == [:deciding, :rules, :committed]
    assert {:ok, %{status: :done, state: :committed}} = Run.result(log, id)
  end

  test "a low-confidence small answer escalates to the loaded large model" do
    tiers = [small: small(0.55), large: large(true)]
    {d, log, parent} = decide(Triage, @input, deciders: [:small, :large], tiers: tiers)

    assert %{value: :code_bug, actor: :large, model: "big"} = d
    assert_in_delta d.confidence, 0.97, 1.0e-9
    assert [%{tier: :rules, error: :no_rule}, %{tier: :small, value: :code_bug}] = d.evidence
    # 120 prompt tokens on the large tier; the stubbed small prompt is ~0 tokens.
    assert %{tokens_in: 120, tokens_out: 8, joules_est: _} = d.cost

    assert states(log, only_run(log, parent)) ==
             [:deciding, :rules, :small, :large, :check_loaded, :infer, :committed]
  end

  test "with the large model not loaded, a good-enough small answer is kept instead of swapping" do
    tiers = [small: small(0.7), large: large(false, self())]
    {d, log, parent} = decide(Triage, @input, deciders: [:small, :large], tiers: tiers)

    assert %{value: :code_bug, actor: :small} = d
    refute_received :swap_requested
    refute_received :large_called

    assert states(log, only_run(log, parent)) == [
             :deciding,
             :rules,
             :small,
             :large,
             :check_loaded,
             :committed
           ]
  end

  test "with no good small answer, the large model is swapped in and the swap is budgeted" do
    parent = run_id()
    tiers = [small: small(0.4), large: large(false, self())]

    {d, log, ^parent} =
      decide(Triage, @input, deciders: [:small, :large], tiers: tiers, parent: parent)

    assert %{value: :code_bug, actor: :large} = d
    assert_received :swap_requested
    assert Budget.get(parent, :swaps) == 1
    assert :swapping in states(log, only_run(log, parent))
  end

  test "when the swap budget is used up, the large tier is skipped and the decision abstains" do
    parent = run_id()
    Budget.add(parent, :swaps, 3)
    tiers = [small: small(0.4), large: large(false, self())]

    {d, log, ^parent} =
      decide(Triage, @input, deciders: [:small, :large], tiers: tiers, parent: parent)

    assert %{value: :abstain, actor: :none} = d
    refute_received :swap_requested
    assert List.last(states(log, only_run(log, parent))) == :abstained
    assert Enum.any?(d.evidence, &match?(%{tier: :large, error: {:skipped, _}}, &1))
  end

  test "budgets are deleted with their run, and swept when their owner is gone" do
    owner = run_id()
    Budget.add(owner, :usd, 0.2)
    Budget.add(owner, :swaps, 1)
    assert Budget.sweep() >= 1
    assert Budget.get(owner, :usd) == 0 and Budget.get(owner, :swaps) == 0

    Budget.add(owner, :usd, 0.2)
    Budget.delete(owner)
    assert Budget.get(owner, :usd) == 0
  end

  test "a rule's verdict is not raised by the severity floor; a model's is" do
    {safe, _, _} = decide(Risk, %{command: "git status"}, deciders: [])
    assert %{value: :safe, actor: :rule} = safe

    {forbidden, _, _} = decide(Risk, %{command: "rm -rf /"}, deciders: [])
    assert %{value: :forbidden, actor: :rule} = forbidden

    {unknown, _, _} = decide(Risk, %{command: "some-unknown-tool --flag"}, deciders: [])
    assert %{value: :review, actor: :none} = unknown
  end

  test "off-box tiers are never called for local-only inputs or for Risk" do
    tiers = [small: small(0.4), openrouter: openrouter(self(), 0.99), remote: remote(self())]

    # Default locality is :local_only.
    {d1, _, _} =
      decide(Triage, @input,
        deciders: [:small, :openrouter, :remote],
        tiers: tiers,
        policy: [remote: :allowed]
      )

    # Risk forbids the remote tier at type level, whatever the request says.
    {d2, _, _} =
      decide(Risk, %{command: "some-unknown-tool --flag"},
        deciders: [:openrouter, :remote],
        tiers: tiers,
        policy: [remote: :allowed, locality: :public]
      )

    refute_received :remote_called
    refute_received :openrouter_called
    assert d1.value == :abstain
    assert d2.value == :review
  end

  test "a confident OpenRouter answer commits, with its state logged and its cost charged" do
    parent = run_id()
    tiers = [small: small(0.4), openrouter: openrouter(self(), 0.95), remote: remote(self())]

    {d, log, ^parent} =
      decide(Triage, @input,
        deciders: [:small, :openrouter, :remote],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :openrouter_called
    refute_received :remote_called

    assert %{
             value: :code_bug,
             actor: :openrouter,
             model: "openrouter:qwen/qwen3.6-35b-a3b@Parasail"
           } = d

    assert_in_delta d.confidence, 0.95, 1.0e-9
    assert :openrouter in states(log, only_run(log, parent))
    assert_in_delta Budget.get(parent, :usd), 0.00006, 1.0e-12
  end

  test "an unsure OpenRouter answer escalates to the remote tier" do
    tiers = [openrouter: openrouter(self(), 0.55), remote: remote(self())]

    {d, _, _} =
      decide(Triage, @input,
        deciders: [:openrouter, :remote],
        tiers: tiers,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :openrouter_called
    assert_received :remote_called
    assert %{value: :test_bug, actor: :remote} = d
    assert Enum.any?(d.evidence, &match?(%{tier: :openrouter, value: :code_bug}, &1))
  end

  test "where policy allows it, the remote tier decides terminally and its spend is charged" do
    parent = run_id()
    tiers = [small: small(0.4), remote: remote(self())]

    {d, _log, ^parent} =
      decide(Triage, @input,
        deciders: [:small, :remote],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :remote_called
    assert %{value: :test_bug, actor: :remote, confidence: nil} = d
    assert_in_delta Budget.get(parent, :usd), (400 * 5 + 20 * 25) / 1_000_000, 1.0e-12
  end

  test "remote is skipped once the run's budget is spent" do
    parent = run_id()
    Budget.add(parent, :usd, 0.5)
    tiers = [remote: remote(self())]

    {d, _, _} =
      decide(Triage, @input,
        deciders: [:remote],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    refute_received :remote_called
    assert d.value == :abstain
  end

  test "a human tier waits for an answer" do
    log = start_log!()
    parent = run_id()

    task =
      Task.async(fn ->
        Escalation.decide(Triage, @input,
          log: log,
          parent: parent,
          deciders: [],
          policy: [human: true]
        )
      end)

    id =
      fn ->
        log
        |> Log.query("SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1", [
          parent
        ])
        |> List.first()
      end
      |> eventually()
      |> hd()

    eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == :human end)
    assert {:ok, :committed} = Run.send_event(id, :human_decision, %{value: :test_bug})

    assert %{value: :test_bug, actor: :human} = Task.await(task)
  end

  test "a run's decisions are escalated, logged with cost, and totalled per run" do
    log = start_log!()
    tiers = [large: large(true)]
    ws = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    runner = {Xeito.Effects.Local, decider: [deciders: [:large], tiers: tiers]}
    input = %{cwd: ws, test_cmd: "echo 'left: 1 right: 2'; exit 1"}

    {:ok, id} =
      RunSupervisor.start_run(FixFailingTest, input, run_id: run_id(), log: log, runner: runner)

    eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == :planning end)

    assert %{decisions: 1, tokens_in: 120, tokens_out: 8} = Run.cost(log, id)

    assert [[_child]] =
             Log.query(
               log,
               "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'",
               [id]
             )

    Run.send_event(id, :give_up)
  end
end
