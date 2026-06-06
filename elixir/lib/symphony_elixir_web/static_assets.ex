defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @favicon_path Path.expand("../../priv/static/favicon.png", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")

  @external_resource @dashboard_css_path
  @external_resource @favicon_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path

  @dashboard_css File.read!(@dashboard_css_path)
  @dashboard_css_digest :crypto.hash(:sha256, @dashboard_css)
                        |> Base.encode16(case: :lower)
                        |> binary_part(0, 12)
  @favicon File.read!(@favicon_path)
  @favicon_digest :crypto.hash(:sha256, @favicon)
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 12)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/favicon.png" => {"image/png", @favicon},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @spec dashboard_css_url() :: String.t()
  def dashboard_css_url, do: "/dashboard.css?v=#{@dashboard_css_digest}"

  @spec favicon_url() :: String.t()
  def favicon_url, do: "/favicon.png?v=#{@favicon_digest}"

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
