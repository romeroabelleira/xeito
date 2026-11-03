defmodule Xeito.Source.PlanCheckTest do
  use ExUnit.Case, async: true

  alias Xeito.Source.PlanCheck

  @moduletag :tmp_dir
  @today ~D[2026-11-03]

  # A repository with a plan at docs/plan.md, two modules, a mix task and two documents.
  defp repo!(dir, plan) do
    write!(dir, "docs/plan.md", plan)
    write!(dir, "lib/xeito/here.ex", "defmodule Xeito.Here do\nend\n")
    write!(dir, "test/support/xeito/helper.ex", "defmodule Xeito.Helper do\nend\n")
    write!(dir, "lib/mix/tasks/xeito.here.ex", "defmodule Mix.Tasks.Xeito.Here do\nend\n")
    write!(dir, "bench/0-ok.md", "# Bench\n")
    write!(dir, "docs/architecture/01-ok.md", "# Ok\n\n## A heading here\n")
    dir
  end

  defp write!(dir, path, text) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, text)
  end

  defp check(dir, plan, opts \\ []) do
    repo!(dir, plan)
    PlanCheck.run(Keyword.merge([plan: Path.join(dir, "docs/plan.md"), root: dir, today: @today], opts))
  end

  describe "modules" do
    test "a module or task the plan names must be defined", %{tmp_dir: dir} do
      plan = """
      # Plan

      `Xeito.Here` and `Xeito.Helper` exist, `Xeito.Here.fun/1` too; `Xeito.Gone.Away` does not.
      `Mix.Tasks.Xeito.Here` exists; `mix xeito.here verify` too; `mix xeito.gone` does not.
      """

      assert [
               {:modules, 3, "Xeito.Gone.Away" <> _},
               {:modules, 4, "mix xeito.gone (Mix.Tasks.Xeito.Gone)" <> _}
             ] = check(dir, plan)
    end

    test "a line that says the name is planned, removed, renamed, not adopted or was is left alone",
         %{tmp_dir: dir} do
      plan = """
      # Plan

      - `Xeito.Later` (planned)
      - `Xeito.Old` was removed
      - `Xeito.Old` renamed to `Xeito.Here`
      - `Xeito.Never`: not adopted
      - `Xeito.Past` was the first
      - `Xeito.Gone` is named twice on this line: `Xeito.Gone`
      """

      assert [{:modules, 8, "Xeito.Gone" <> _}] = check(dir, plan)
    end
  end

  describe "links" do
    test "an anchor must slug a heading, GitHub's way", %{tmp_dir: dir} do
      plan = """
      # Plan

      ## P4d · Tier names

      ## P9 · Bridges (after P4; ≈2 weeks)

      ### `mix xeito.here` and friends

      ### Steps

      ### Steps

      [a](#p4d--tier-names) [b](#p9--bridges-after-p4-2-weeks) [c](#mix-xeitohere-and-friends)
      [d](#steps) [e](#steps-1) [f](#steps-2) [g](#p4d-tier-names)
      """

      assert [{:links, 14, "#steps-2" <> _}, {:links, 14, "#p4d-tier-names" <> _}] = check(dir, plan)
    end

    test "a relative link must reach a file, and its fragment a heading there", %{tmp_dir: dir} do
      plan = """
      # Plan

      [a](../bench/0-ok.md) [b](architecture/01-ok.md#a-heading-here) [c](https://example.org/x.md)
      [d](../bench/1-missing.md) [e](architecture/01-ok.md#no-such-heading) [f](architecture/02-missing.md#x)
      """

      assert [
               {:links, 4, "../bench/1-missing.md" <> _},
               {:links, 4, "architecture/01-ok.md#no-such-heading" <> _},
               {:links, 4, "architecture/02-missing.md" <> _}
             ] = check(dir, plan)
    end
  end

  describe "stale" do
    test "a checked note older than 14 days", %{tmp_dir: dir} do
      plan = """
      # Plan

      Fresh (checked 2026-10-21: fine). Stale (checked 2026-10-19: fine).
      (checked against the code, 2026-10-08: no date right after the word.)
      Superseded (checked 2026-09-01: then) by a later note on the line (checked 2026-10-30: still).
      """

      assert [{:stale, 3, "(checked 2026-10-19" <> rest}] = check(dir, plan)
      assert rest =~ "15 days"
    end

    test "a next, pending, planned or waits-for item whose nearest date is over 60 days old",
         %{tmp_dir: dir} do
      plan = """
      # Plan

      Status 2026-11-20: P4l planned; step 6 next.

      - 2026-09-01 old: step 7 waits for the `contained` level.
      | P4c · Dropped turns (planned) | — | after P4b |
      - the pending items of 2026-10-30 are fresh again.
      - also pending, dated by the line above.
      - nothing is Next to a Pending word in prose at 2026-08-01 before the word pending.
      """

      assert [
               {:stale, 5, "\"waits for\" item, last dated 2026-09-01, 118 days ago" <> _},
               {:stale, 6, "\"planned\" item, last dated 2026-09-01" <> _},
               {:stale, 9, "\"Next\"" <> _},
               {:stale, 9, "\"Pending\"" <> _},
               {:stale, 9, "\"pending\" item, last dated 2026-08-01" <> _}
             ] = check(dir, plan, today: ~D[2026-12-28])
    end

    test "today defaults to the current date", %{tmp_dir: dir} do
      plan = "# Plan\n\n(checked #{Date.utc_today()}: fine) (checked 2020-01-01: old)\n"
      repo!(dir, plan)
      assert [{:stale, 3, "(checked 2020-01-01" <> _}] = PlanCheck.run(plan: Path.join(dir, "docs/plan.md"), root: dir)
    end
  end

  describe "milestones" do
    @table """
    # Plan

    ## Milestones

    | Phase | Scope | Planned | Effective | Evidence |
    |---|---|---|---|---|
    | P0 · Toolchain | tools | 2026-10-05 | done 2026-09-27 | CI green |
    | Bench 1 · contention (inserted) | load | — | done 2026-09-27 | no section |
    | P1 · Core | core | — | done 2026-09-27 | tests |
    | P2 · Decisions | types | — | steps 1–2 done 2026-10-03; step 3 deferred | — |
    | P3 · Tiers | tiers | — | built 2026-10-04 | — |
    | P4 · Harness (planned) | tui | — | after P3 | — |
    | P5 · Mining | ocel | — | done 2026-10-05 | — |

    """

    # The number of the first line of `plan` that starts with `prefix`.
    defp line_of(plan, prefix) do
      plan |> String.split("\n") |> Enum.find_index(&String.starts_with?(&1, prefix)) |> Kernel.+(1)
    end

    test "a row that says done needs a section that says so", %{tmp_dir: dir} do
      plan =
        @table <>
          """
          ## P0 · Toolchain

          1. Install.
          2. Pin.

          **Status:** done 2026-09-27 (planned 2026-10-19).

          ## P1 · Core

          1. **Build** (done 2026-09-27).
          2. **Recover.** Still open.

          ## P2 · Decisions

          1. **Types** (done 2026-10-03).
          2. **Rules.** **Done 2026-10-03**
          3. **Deferred.** Not yet.

          ## P3 · Tiers

          1. ✅ **Ladder** (added and built 2026-10-04).
          2. **Policy** (done 2026-10-04).
          3. **Done 2026-10-04, in part.** Budgets.

          ## P4 · Harness

          1. A daemon.
          2. A client.

          **Status:** in progress since 2026-10-05.

          ## P5 · Mining

          1. Validate.
          2. **Export.** **Done 2026-10-05**
          """

      {p1_row, p1} = {line_of(plan, "| P1"), line_of(plan, "## P1")}
      {p3_row, p3} = {line_of(plan, "| P3"), line_of(plan, "## P3")}

      assert [
               {:milestones, ^p1_row, "P1: the table says done, but the section (line " <> p1_rest},
               {:milestones, ^p3_row, "P3: every step of the section (line " <> p3_rest}
             ] = check(dir, plan)

      assert p1_rest =~ ~r/^#{p1}\)/ and p3_rest =~ ~r/^#{p3}\)/
    end

    test "a section whose status line says done but whose row does not", %{tmp_dir: dir} do
      plan =
        @table <>
          """
          ## P3 · Tiers

          Prose without steps.

          **Status:** done 2026-10-04.
          """

      {p3_row, p3} = {line_of(plan, "| P3"), line_of(plan, "## P3")}
      assert [{:milestones, ^p3_row, "P3: the section (line " <> rest}] = check(dir, plan)
      assert rest =~ ~r/^#{p3}\) says done/
    end
  end

  describe "format" do
    test "findings grouped by check, then a count" do
      findings = [{:modules, 3, "Xeito.Gone is not defined"}, {:stale, 9, "x"}, {:stale, 4, "y"}]

      assert PlanCheck.format(findings) == """
             Modules (1)
               line 3: Xeito.Gone is not defined
             Links (0)
             Stale (2)
               line 4: y
               line 9: x
             Milestones (0)

             3 findings\
             """

      assert PlanCheck.format([]) =~ "no findings"
    end
  end
end
