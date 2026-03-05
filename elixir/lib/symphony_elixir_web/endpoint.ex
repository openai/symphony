defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: {:symphony_elixir, "priv/static"},
    gzip: false,
    only: ~w(assets dashboard.css)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix_html",
    from: {:phoenix_html, "priv/static"},
    gzip: false,
    only: ~w(phoenix_html.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SymphonyElixirWeb.Router)
end
