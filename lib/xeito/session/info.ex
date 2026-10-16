defmodule Xeito.Session.Info do
  @moduledoc """
  The session's informational commands (`/why`, `/budget`, `/model`, `/help`, `/machines`) and its workspace state.

  `command/3` answers with a `notice` event, or an `error` for a bad argument. Only `/budget`
  (the decider policy's `max_usd_per_run`) and `/model` (the chat options' `tier`) change the
  state; a switch of tier also emits a fresh `workspace` event. `workspace/1` is the map status
  bars show: git, the off-box budget and the chat tier.
  """

  alias Xeito.Allowance
  alias Xeito.Budget
  alias Xeito.Log
  alias Xeito.Policy
  alias Xeito.Session
  alias Xeito.Session.ChatModel
  alias Xeito.Session.Git
  alias Xeito.Session.Notify
  alias Xeito.Session.Router
  alias Xeito.Tiers

  @doc "Runs the info command `name` (`why`, `budget`, `model`, `help` or `machines`) with its argument."
  @spec command(String.t(), String.t(), Session.state()) :: Session.state()
  def command("why", _arg, s), do: why(s)
  def command("budget", usd, s), do: budget(usd, s)
  def command("model", name, s), do: chat_model(name, s)
  def command("help", _arg, s), do: Notify.notice(s, help())
  def command("machines", _arg, s), do: Notify.notice(s, machines_text(s))

  @doc "The workspace state: whether the directory is missing, git, the off-box budget and the chat tier."
  @spec workspace(Session.state()) :: map()
  def workspace(s) do
    policy = Policy.effective(Keyword.take(s.decider, [:policy]))
    tier = ChatModel.current(s.chat)
    spent = if is_binary(s.root), do: Budget.get(s.root, :usd), else: 0

    %{
      "missing" => not File.dir?(s.cwd),
      "git" => Git.status(s.cwd),
      "budget" => %{
        "off_box" => (policy.remote == :allowed and policy.locality == :public) or ChatModel.off_box?(tier),
        "max_usd_per_run" => policy.max_usd_per_run,
        "spent_usd" => spent
      },
      "chat" => chat_attrs(tier, ChatModel.config(s.chat))
    }
  end

  # `Allowance.last/1` makes no request.
  defp chat_attrs(tier, cfg) do
    left = if ChatModel.off_box?(tier) and cfg[:url], do: Allowance.last(cfg)
    %{"tier" => tier, "model" => cfg[:model], "off_box" => ChatModel.off_box?(tier), "left_usd" => left}
  end

  defp why(s) do
    own =
      for d <- s.decisions do
        [inspect(d.type), d.value, d.confidence, d.actor, d.model, d.latency_ms]
      end

    rows =
      Log.query(
        s.log,
        "SELECT d.decision_type, d.value, d.confidence, d.actor, d.model, d.latency_ms " <>
          "FROM event_decision_made d JOIN xeito_term t ON t.ocel_id = d.ocel_id " <>
          "WHERE t.run_id LIKE ?1 ORDER BY t.rowid DESC LIMIT 10",
        [s.id <> "/%"]
      )

    lines =
      for [type, value, conf, actor, model, ms] <- own ++ rows do
        "#{String.replace_prefix(type, "Xeito.Decisions.", "")}: #{value} by #{actor} " <>
          "(#{format_conf(conf)}, #{model}, #{ms} ms)"
      end

    Notify.notice(s, if(lines == [], do: "no decisions yet", else: Enum.join(lines, "\n")))
  end

  defp format_conf(nil), do: "-"
  defp format_conf(c) when is_number(c), do: :erlang.float_to_binary(c * 1.0, decimals: 2)

  # Attributes read back from the log are text.
  defp format_conf(c) when is_binary(c) do
    case Float.parse(c) do
      {f, _} -> format_conf(f)
      :error -> c
    end
  end

  defp budget(usd, s) do
    case Float.parse(usd) do
      {value, _} when value >= 0 ->
        policy = Keyword.put(Keyword.get(s.decider, :policy, []), :max_usd_per_run, value)
        s = %{s | decider: Keyword.put(s.decider, :policy, policy)}
        Notify.notice(s, "off-box budget per run: $#{value}")

      _ ->
        Notify.error(s, "usage: /budget <usd>")
    end
  end

  defp chat_model("", s) do
    cfg = ChatModel.config(s.chat)
    Notify.notice(s, ChatModel.describe(ChatModel.current(s.chat), chat_configs(), cfg[:url] && Allowance.last(cfg)))
  end

  defp chat_model(name, s) do
    case ChatModel.choose(name, chat_configs()) do
      {:ok, tier} ->
        s = %{s | chat: Keyword.put(s.chat, :tier, tier)}
        Notify.emit(s, "workspace", nil, workspace(%{s | root: nil}))

        Notify.notice(
          s,
          ChatModel.switched(
            tier,
            ChatModel.config(s.chat),
            Policy.effective(Keyword.take(s.decider, [:policy])).max_usd_per_run
          )
        )

      {:error, text} ->
        Notify.error(s, text)
    end
  end

  defp chat_configs, do: Map.new(ChatModel.tiers(), &{&1, Tiers.config(&1)})

  defp machines_text(s) do
    rows = Router.describe(s.cwd, s.log)

    header =
      String.pad_trailing("machine", 18) <>
        String.pad_trailing("version", 9) <> "runs  done  failed  last run (UTC)"

    lines =
      for m <- rows do
        u = m.usage

        last =
          if u.last,
            do: u.last |> to_string() |> String.slice(0, 16) |> String.replace("T", " "),
            else: "-"

        String.pad_trailing(m.name, 18) <>
          String.pad_trailing(m.version, 9) <>
          String.pad_trailing("#{u.runs}", 6) <>
          String.pad_trailing("#{u.done}", 6) <>
          String.pad_trailing("#{u.failed}", 8) <>
          last <> "\n    #{m.summary}\n    routed from: #{m.routed_from} · /machine #{m.name}"
      end

    Enum.join([header | lines], "\n")
  end

  defp help do
    """
    /help                     this list
    /machines                 list the machines: what they do, how they are routed, usage
    /machine <name> [prompt]  start a machine directly (#{Enum.join(Map.keys(Router.machines()), ", ")})
    /skill:<name> [request]   run a skill (pi / Agent Skills format)
    /run <command>            run a shell command in the workspace, without a model or review;
                              its output joins the conversation for the next turn
    /approve · /deny          answer a command waiting for review (or type what to do instead)
    /approve session|always   approve it and do not ask about this exact command again: for the
                              rest of this session, or ever in this workspace (.xeito/allowed.json)
    /undo [n] · /redo [n]     revert this session's last n file changes, or put them back
    /steer <text>             a line for the running chat turn, taken at its next model call
                              (Ctrl-J in the TUI); idle, a prompt
    /send · /drop             send the first line typed while a turn ran, or drop it (held when
                              the turn ended halted, failed, stopped, or with a question)
    /halt                     stop the turn where it is (Esc in the TUI); "go ahead" continues it
    /why                      the last decisions, with tier and confidence
    /budget <usd>             off-box spend limit per run (a remote chat turn included)
    /model [tier]             the chat tiers; switch this session's chat (local, remote, remote_frontier)
    /quit                     close the client (the session keeps running; attach with --session)
    /statusbar …              TUI only: on|off|reset|segments|show|hide <segment>
    /legend                   TUI only: what the coloured dots beside commands mean
    /sessions [N|new]         TUI only: this directory's sessions; switch to one, or start another
    /step · /next · /continue step mode: pause before each result, release one, run on
    /decide <value>           answer a paused decision yourself (logged as a label)
    /break state:<s> | decision:<Type> | conf<0.6 | clear
    """
  end
end
