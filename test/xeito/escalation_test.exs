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

  # A System One decision model: `conf` on code_bug, the rest spread over two others.
  defp decision_model(stub, conf, test_pid \\ nil) do
    Req.Test.stub(stub, fn conn ->
      if test_pid, do: send(test_pid, {:called, stub})
      rest = (1 - conf) / 2

      Req.Test.json(conn, %{
        "answers" => %{
          "triage" => %{
            "choice" => "code_bug",
            "probabilities" => %{"code_bug" => conf, "test_bug" => rest, "flaky" => rest}
          }
        }
      })
    end)

    [url: "http://#{stub}.test", plug: {Req.Test, stub}, model: "multilingual"]
  end

  defp local_decision(conf), do: decision_model(:esc_local_decision, conf)

  defp local(loaded?, test_pid \\ nil) do
    Req.Test.stub(:esc_local, &ollama(&1, loaded?, test_pid))
    [url: "http://local.test", plug: {Req.Test, :esc_local}, model: "big"]
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
    if test_pid, do: send(test_pid, :local_called)

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

  # The frontier model through OpenRouter: no logprobs, so its answer is terminal.
  defp frontier(test_pid) do
    Req.Test.stub(:esc_frontier, fn conn ->
      send(test_pid, :frontier_called)

      Req.Test.json(conn, %{
        "model" => "anthropic/claude-sonnet-5.5",
        "provider" => "Amazon Bedrock",
        "choices" => [%{"message" => %{"content" => ~s({"value": "test_bug"})}}],
        "usage" => %{"prompt_tokens" => 400, "completion_tokens" => 20, "cost" => 0.0028}
      })
    end)

    [url: "http://frontier.test", api_key: "k", model: "anthropic/claude-sonnet-5.5", plug: {Req.Test, :esc_frontier}]
  end

  defp remote(test_pid, conf) do
    Req.Test.stub(:esc_remote, fn conn ->
      send(test_pid, :remote_called)

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

    [url: "http://remote.test", api_key: "k", model: "qwen/qwen3.6-35b-a3b"] ++
      [plug: {Req.Test, :esc_remote}]
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

  test "a low-confidence decision-model answer escalates to the loaded local model" do
    tiers = [local_decision: local_decision(0.55), local: local(true)]
    {d, log, parent} = decide(Triage, @input, deciders: [:local_decision, :local], tiers: tiers)

    assert %{value: :code_bug, actor: :local, model: "big"} = d
    assert_in_delta d.confidence, 0.97, 1.0e-9
    assert [%{tier: :rules, error: :no_rule}, %{tier: :local_decision, value: :code_bug}] = d.evidence
    # 120 prompt tokens on the local tier; the stubbed decision model reports none.
    assert %{tokens_in: 120, tokens_out: 8, joules_est: _} = d.cost

    assert states(log, only_run(log, parent)) ==
             [:deciding, :rules, :local_decision, :local, :check_loaded, :infer, :committed]
  end

  test "with the local model not loaded, a good-enough earlier answer is kept instead of swapping" do
    tiers = [local_decision: local_decision(0.7), local: local(false, self())]
    {d, log, parent} = decide(Triage, @input, deciders: [:local_decision, :local], tiers: tiers)

    assert %{value: :code_bug, actor: :local_decision} = d
    refute_received :swap_requested
    refute_received :local_called

    assert states(log, only_run(log, parent)) == [
             :deciding,
             :rules,
             :local_decision,
             :local,
             :check_loaded,
             :committed
           ]
  end

  test "with no good earlier answer, the local model is swapped in and the swap is budgeted" do
    parent = run_id()
    tiers = [local_decision: local_decision(0.4), local: local(false, self())]

    {d, log, ^parent} =
      decide(Triage, @input, deciders: [:local_decision, :local], tiers: tiers, parent: parent)

    assert %{value: :code_bug, actor: :local} = d
    assert_received :swap_requested
    assert Budget.get(parent, :swaps) == 1
    assert :swapping in states(log, only_run(log, parent))
  end

  test "when the swap budget is used up, the local tier is skipped and the decision abstains" do
    parent = run_id()
    Budget.add(parent, :swaps, 3)
    tiers = [local_decision: local_decision(0.4), local: local(false, self())]

    {d, log, ^parent} =
      decide(Triage, @input, deciders: [:local_decision, :local], tiers: tiers, parent: parent)

    assert %{value: :abstain, actor: :none} = d
    refute_received :swap_requested
    assert List.last(states(log, only_run(log, parent))) == :abstained
    assert Enum.any?(d.evidence, &match?(%{tier: :local, error: {:skipped, _}}, &1))
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

  test "remote tiers are never called for local-only inputs or for Risk" do
    tiers = [
      local_decision: local_decision(0.4),
      remote_decision: decision_model(:esc_remote_decision, 0.99, self()),
      remote: remote(self(), 0.99),
      remote_frontier: frontier(self())
    ]

    ladder = [:local_decision, :remote_decision, :remote, :remote_frontier]

    # Default locality is :local_only.
    {d1, _, _} = decide(Triage, @input, deciders: ladder, tiers: tiers, policy: [remote: :allowed])

    # Risk forbids remote tiers at type level, whatever the request says.
    {d2, _, _} =
      decide(Risk, %{command: "some-unknown-tool --flag"},
        deciders: ladder,
        tiers: tiers,
        policy: [remote: :allowed, locality: :public]
      )

    refute_received {:called, :esc_remote_decision}
    refute_received :remote_called
    refute_received :frontier_called
    assert d1.value == :abstain
    assert d2.value == :review
  end

  test "a hosted decision model is a remote tier: called where policy allows it" do
    tiers = [remote_decision: decision_model(:esc_remote_decision, 0.95, self())]

    {d, log, parent} =
      decide(Triage, @input,
        deciders: [:remote_decision],
        tiers: tiers,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received {:called, :esc_remote_decision}
    assert %{value: :code_bug, actor: :remote_decision} = d
    assert :remote_decision in states(log, only_run(log, parent))
  end

  test "a confident remote answer commits, with its state logged and its cost charged" do
    parent = run_id()
    tiers = [local_decision: local_decision(0.4), remote: remote(self(), 0.95), remote_frontier: frontier(self())]

    {d, log, ^parent} =
      decide(Triage, @input,
        deciders: [:local_decision, :remote, :remote_frontier],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :remote_called
    refute_received :frontier_called

    assert %{
             value: :code_bug,
             actor: :remote,
             model: "openrouter:qwen/qwen3.6-35b-a3b@Parasail"
           } = d

    assert_in_delta d.confidence, 0.95, 1.0e-9
    assert :remote in states(log, only_run(log, parent))
    assert_in_delta Budget.get(parent, :usd), 0.00006, 1.0e-12
  end

  test "an unsure remote answer escalates to the frontier tier" do
    tiers = [remote: remote(self(), 0.55), remote_frontier: frontier(self())]

    {d, _, _} =
      decide(Triage, @input,
        deciders: [:remote, :remote_frontier],
        tiers: tiers,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :remote_called
    assert_received :frontier_called
    assert %{value: :test_bug, actor: :remote_frontier} = d
    assert Enum.any?(d.evidence, &match?(%{tier: :remote, value: :code_bug}, &1))
  end

  test "where policy allows it, the frontier tier decides terminally and its spend is charged" do
    parent = run_id()
    tiers = [local_decision: local_decision(0.4), remote_frontier: frontier(self())]

    {d, _log, ^parent} =
      decide(Triage, @input,
        deciders: [:local_decision, :remote_frontier],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    assert_received :frontier_called
    assert %{value: :test_bug, actor: :remote_frontier, confidence: nil} = d
    assert_in_delta Budget.get(parent, :usd), 0.0028, 1.0e-12
  end

  test "remote tiers are skipped once the run's budget is spent" do
    parent = run_id()
    Budget.add(parent, :usd, 0.5)
    tiers = [remote_frontier: frontier(self())]

    {d, _, _} =
      decide(Triage, @input,
        deciders: [:remote_frontier],
        tiers: tiers,
        parent: parent,
        policy: [remote: :allowed, locality: :public]
      )

    refute_received :frontier_called
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
    tiers = [local: local(true)]
    ws = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    runner = {Xeito.Effects.Local, decider: [deciders: [:local], tiers: tiers]}
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
