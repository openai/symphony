defmodule SymphonyElixir.GitLabRedirectTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitLab.AgentTool

  @token "redirect-test-token"
  @path "/projects/attacker%2Fbait/releases/v1/downloads/release.sha256"
  @settings %{provider: %{"api_url" => "https://gitlab.test", "api_key" => @token, "project_path" => "test/repo"}}

  setup do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    :ok
  end

  test "direct requests authenticate with Bearer instead of PRIVATE-TOKEN" do
    assert request()["success"]
    assert_received {:request, "gitlab.test", @path, headers}
    assert {"authorization", "Bearer " <> @token} in headers
    refute List.keymember?(headers, "private-token", 0)
  end

  test "same-origin redirects retain authentication" do
    assert request("/sink")["success"]
    assert_received {:request, "gitlab.test", "/sink", headers}
    assert {"authorization", "Bearer " <> @token} in headers
    refute List.keymember?(headers, "private-token", 0)
  end

  test "cross-origin redirects receive neither credential header" do
    assert request("https://sink.test/sink")["success"]
    assert_received {:request, "sink.test", "/sink", headers}
    refute List.keymember?(headers, "authorization", 0)
    refute List.keymember?(headers, "private-token", 0)
  end

  # Keep the tool, client, and Req redirect steps real; replace only transport.
  defp request(location \\ nil) do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {:request, conn.host, conn.request_path, conn.req_headers})
        conn = Plug.Conn.put_resp_content_type(conn, "application/json")

        if conn.request_path == @path and location do
          conn
          |> Plug.Conn.put_resp_header("location", location)
          |> Plug.Conn.send_resp(302, "{}")
        else
          Plug.Conn.send_resp(conn, 200, "{}")
        end
      end
    )

    AgentTool.execute("gitlab_api", %{"method" => "GET", "path" => @path}, tracker_settings: @settings)
  end
end
