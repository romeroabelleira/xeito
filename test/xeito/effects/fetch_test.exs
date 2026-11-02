defmodule Xeito.Effects.FetchTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Effects.Fetch

  describe "allowed?/2: the policy's network setting" do
    test "forbidden refuses everything; allowed lets http and https through, nothing else" do
      refute Fetch.allowed?("https://a.test/x", :forbidden)
      assert Fetch.allowed?("https://a.test/x", :allowed)
      assert Fetch.allowed?("http://a.test/x", :allowed)
      refute Fetch.allowed?("file:///etc/passwd", :allowed)
      refute Fetch.allowed?("ftp://a.test", :allowed)
    end

    test "a list of hosts lets those hosts and their subdomains through" do
      assert Fetch.allowed?("https://docs.a.test/x", ["a.test"])
      assert Fetch.allowed?("https://a.test/x", ["a.test"])
      refute Fetch.allowed?("https://nota.test/x", ["a.test"])
      refute Fetch.allowed?("https://b.test/x", ["a.test"])
    end
  end

  describe "run/2" do
    setup do
      name = :"fetch_#{System.unique_integer([:positive])}"
      {:ok, name: name, opts: [plug: {Req.Test, name}, network: :allowed]}
    end

    defp effect(url), do: Effect.fetch(url)

    test "an HTML page comes back as Markdown with its title and final URL", %{name: name, opts: opts} do
      Req.Test.stub(name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html><head><title>T</title></head><body><h1>Hi</h1><p>There.</p></body></html>")
      end)

      assert Fetch.run(effect("https://a.test/page"), opts) ==
               %{ok: true, content: "# Hi\n\nThere.", url: "https://a.test/page", status: 200, title: "T"}
    end

    test "plain text and JSON come as they are", %{name: name, opts: opts} do
      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/t" -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "hello\n")
          "/j" -> Req.Test.json(conn, %{a: 1})
        end
      end)

      assert %{ok: true, content: "hello", title: nil} = Fetch.run(effect("https://a.test/t"), opts)
      assert %{ok: true, content: ~s({"a":1})} = Fetch.run(effect("https://a.test/j"), opts)
    end

    test "a refused network, an odd scheme, an error status, a binary body and too large a body are errors",
         %{name: name, opts: opts} do
      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/404" ->
            Plug.Conn.send_resp(conn, 404, "no")

          "/bin" ->
            conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, <<0, 255, 1, 2>>)

          "/big" ->
            conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, String.duplicate("x", 100))
        end
      end)

      assert %{ok: false, error: "the network is off" <> _} =
               Fetch.run(effect("https://a.test/x"), Keyword.put(opts, :network, :forbidden))

      assert %{ok: false, error: "this host is not among" <> _} =
               Fetch.run(effect("https://a.test/x"), Keyword.put(opts, :network, ["b.test"]))

      assert %{ok: false, error: "only http and https" <> _} = Fetch.run(effect("file:///etc/passwd"), opts)
      assert %{ok: false, error: "HTTP 404"} = Fetch.run(effect("https://a.test/404"), opts)
      assert %{ok: false, error: "the body is not text" <> _} = Fetch.run(effect("https://a.test/bin"), opts)

      assert %{ok: false, error: "the page is larger than 10 bytes"} =
               Fetch.run(effect("https://a.test/big"), Keyword.put(opts, :max_bytes, 10))
    end

    test "a connection error is an error, not a crash", %{name: name, opts: opts} do
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert %{ok: false, error: "could not fetch: " <> _} = Fetch.run(effect("https://a.test/x"), opts)
    end
  end
end
