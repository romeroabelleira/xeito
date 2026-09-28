defmodule Xeito.MonitorTest do
  # Probes run in tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.Client.StatusBar
  alias Xeito.{Monitor, Session}
  alias Xeito.Monitor.{Host, Models}
  alias Xeito.Session.Router

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    root = Path.join(System.tmp_dir!(), "xeito-mon-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp put(root, path, content) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  defp fixture(root) do
    put(root, "proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3\n")
    put(root, "proc/loadavg", "1.25 0.9 0.5 1/200 300\n")

    put(
      root,
      "proc/meminfo",
      "MemTotal:       65000000 kB\nMemFree: 1 kB\nMemAvailable:   45000000 kB\n"
    )

    # An integrated GPU and a discrete one: the larger VRAM is primary.
    put(root, "sys/class/drm/card0/device/gpu_busy_percent", "3\n")
    put(root, "sys/class/drm/card0/device/mem_info_vram_used", "20000000\n")
    put(root, "sys/class/drm/card0/device/mem_info_vram_total", "536870912\n")
    put(root, "sys/class/drm/card0/device/hwmon/hwmon0/power1_input", "42000000\n")

    dev = "sys/class/drm/card1/device"
    put(root, "#{dev}/gpu_busy_percent", "97\n")
    put(root, "#{dev}/mem_info_vram_used", "19860000000\n")
    put(root, "#{dev}/mem_info_vram_total", "25753026560\n")
    put(root, "#{dev}/hwmon/hwmon1/power1_average", "290500000\n")
    put(root, "#{dev}/hwmon/hwmon1/temp1_input", "61000\n")
    put(root, "#{dev}/hwmon/hwmon1/temp1_label", "edge\n")
    put(root, "#{dev}/hwmon/hwmon1/temp2_input", "74500\n")
    put(root, "#{dev}/hwmon/hwmon1/temp2_label", "junction\n")
  end

  test "system readings: CPU from counter deltas, RAM, and GPUs with the discrete one primary", %{
    root: root
  } do
    fixture(root)
    opts = [proc: Path.join(root, "proc"), sys: Path.join(root, "sys")]

    {first, counters} = Host.read(nil, opts)
    assert first.cpu.busy_pct == nil and first.cpu.load1 == 1.25
    assert first.mem == %{used_bytes: 20_000_000 * 1024, total_bytes: 65_000_000 * 1024}

    [card0, card1] = first.gpus
    refute card0.primary

    assert %{primary: true, busy_pct: 97, power_w: 290.5, vram_total_bytes: 25_753_026_560} =
             card1

    assert card1.temps_c == %{"edge" => 61.0, "junction" => 74.5}
    assert card0.power_w == 42.0

    # 200 more jiffies, 50 of them idle: 75 % busy.
    put(root, "proc/stat", "cpu  200 0 150 750 100 0 0 0 0 0\n")
    {second, _} = Host.read(counters, opts)
    assert second.cpu.busy_pct == 75.0

    # Without /proc and /sys (another OS), readings are nil, not errors.
    assert {%{cpu: %{busy_pct: nil, load1: nil}, mem: nil, gpus: []}, nil} =
             Host.read(nil, proc: "/nonexistent", sys: "/nonexistent")
  end

  test "model probes: resident models, busy slots, System One, and unconfigured tiers" do
    Req.Test.stub(:mon, fn conn ->
      case {conn.host, conn.request_path} do
        {"large.test", "/api/ps"} ->
          at = DateTime.utc_now() |> DateTime.add(252) |> DateTime.to_iso8601()

          Req.Test.json(conn, %{
            "models" => [
              %{
                "name" => "big:27b",
                "size_vram" => 19_000_000_000,
                "context_length" => 8192,
                "expires_at" => at
              }
            ]
          })

        {"small.test", "/health"} ->
          Req.Test.json(conn, %{"status" => "ok"})

        {"small.test", "/slots"} ->
          Req.Test.json(conn, [%{"is_processing" => true}, %{"is_processing" => false}])

        {"s1.test", "/health"} ->
          Plug.Conn.send_resp(conn, 503, "starting")
      end
    end)

    plug = {Req.Test, :mon}

    models =
      Models.read(
        tiers: [
          large: [url: "http://large.test", model: "big:27b", plug: plug],
          small: [url: "http://small.test", model: "small", plug: plug],
          system_one: [url: "http://s1.test", plug: plug]
        ]
      )

    assert %{up: true, loaded: [%{name: "big:27b", unload_in_s: s}]} = models.large
    assert s in 250..252
    assert %{up: true, slots: 2, busy: 1} = models.small
    assert %{configured: true, up: false} = models.system_one
    assert %{configured: false} = models.remote
  end

  test "the monitor polls only while someone watches" do
    name = :"mon_#{System.unique_integer([:positive])}"
    mon = start_supervised!({Monitor, name: name, interval: 20, models: [tiers: []]})

    refute Monitor.polling?(mon)
    :ok = Monitor.subscribe(self(), mon)

    assert_receive {:xeito_monitor, %{system: _, models: _, queues: %{large: %{in_use: 0}}}},
                   2_000

    assert_receive {:xeito_monitor, _}, 2_000
    assert Monitor.polling?(mon)

    :ok = Monitor.unsubscribe(self(), mon)
    refute Monitor.polling?(mon)

    # A subscriber that dies is dropped, and polling stops with the last one.
    watcher = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Monitor.subscribe(watcher, mon)
    assert Monitor.polling?(mon)
    Process.exit(watcher, :kill)
    eventually(fn -> not Monitor.polling?(mon) end)
  end

  test "status bar: usage, determinism budget and system line from events and a snapshot" do
    events = [
      %{"event" => "intent", "attrs" => %{"actor" => "rule"}},
      %{
        "event" => "decision_made",
        "run" => "s/t1",
        "attrs" => %{
          "actor" => "large",
          "tokens_in" => 300,
          "tokens_out" => 5,
          "joules_est" => 150.0
        }
      },
      %{
        "event" => "decision_made",
        "run" => "s/t1/e2/esc",
        "attrs" => %{"actor" => "large", "tokens_in" => 999}
      },
      %{
        "event" => "effect_completed",
        "run" => "s/t1",
        "attrs" => %{"kind" => "chat", "result" => %{"tokens_in" => 3200, "tokens_out" => 120}}
      },
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "code"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "rule"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "large"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "human"}}
    ]

    usage = Enum.reduce(events, StatusBar.new(), &StatusBar.count(&2, &1))
    assert usage.calls == %{"rule" => 1, "large" => 1, "chat" => 1}
    assert {usage.tokens_in, usage.tokens_out, usage.ctx} == {3500, 125, 3200}

    snapshot = %{
      "system" => %{
        "cpu" => %{"busy_pct" => 23.4, "load1" => 1.2},
        "mem" => %{"used_bytes" => 18_360_000_000, "total_bytes" => 66_571_993_088},
        "gpus" => [
          %{"primary" => false, "vram_used_bytes" => 1, "vram_total_bytes" => 2},
          %{
            "primary" => true,
            "vram_used_bytes" => 19_860_000_000,
            "vram_total_bytes" => 25_753_026_560,
            "busy_pct" => 97,
            "power_w" => 290.5,
            "temps_c" => %{"edge" => 61.0, "junction" => 74.5}
          }
        ]
      },
      "models" => %{
        "large" => %{
          "configured" => true,
          "up" => true,
          "loaded" => [%{"name" => "big:27b", "unload_in_s" => 252, "context" => 81_920}]
        },
        "small" => %{"configured" => true, "up" => true, "slots" => 4, "busy" => 1},
        "system_one" => %{"configured" => true, "up" => false},
        "remote" => %{"configured" => false}
      },
      "queues" => %{
        "large" => %{"in_use" => 1, "waiting" => 2},
        "small" => %{"in_use" => 0, "waiting" => 0}
      }
    }

    [system, use] = StatusBar.lines(usage, snapshot)

    assert system ==
             "GPU 18.5/24.0 GiB 97% 291 W 75°C │ large big:27b unload 4:12 │ small ✓ 1/4 │ S1 ✗ │ CPU 23% load 1.2 RAM 17.1/62.0 GiB"

    assert use ==
             "chat 1 · large 1 · rule 1 │ 3.5k→125 tok · ctx 3.2k/81.9k │ det 50% │ $0.0000 · ~150 J │ queue large 1+2"

    assert [_, _] = StatusBar.lines(StatusBar.new(), nil)
  end

  test "/machines lists every machine with its routing and its usage in the log" do
    log = start_log!()
    ws = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    runner = scripted_runner([%{exit_status: 0, output: "ok"}, %{exit_status: 1, output: "no"}])

    for _ <- 1..2 do
      {:ok, id} =
        Xeito.RunSupervisor.start_run(Xeito.Machines.RunTests, %{cwd: ws},
          run_id: run_id(),
          log: log,
          runner: runner
        )

      await_exit(id)
    end

    rows = Router.describe(ws, log)
    assert Enum.map(rows, & &1.name) == ~w(fix_failing_test check commit run_tests chat)

    assert %{usage: %{runs: 2, done: 1, failed: 1}, version: "0.1.0", states: 1} =
             Enum.find(rows, &(&1.name == "run_tests"))

    assert %{usage: %{runs: 0}} = Enum.find(rows, &(&1.name == "commit"))

    # Without a log in the workspace, nothing is created just to list machines.
    other = Path.join(ws, "elsewhere")
    File.mkdir_p!(other)
    assert [%{usage: %{runs: 0}} | _] = Router.describe(other)
    refute File.exists?(Path.join(other, ".xeito"))

    {:ok, id} =
      Session.start(cwd: ws, log: log, id: "ses-test-#{System.unique_integer([:positive])}")

    Session.subscribe(id)
    Session.prompt(id, "/machines")
    assert_receive {:xeito, _, %{type: "notice", attrs: %{"text" => text}}}, 2_000
    assert text =~ "run_tests         0.1.0    2     1     1"
    assert text =~ "routed from: intent run/edit + commit · /machine commit"
  end
end
