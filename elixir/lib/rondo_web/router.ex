defmodule RondoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RondoWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", RondoWeb do
    pipe_through(:browser)
    live("/", DashboardLive)
  end

  scope "/api/v1", RondoWeb do
    pipe_through(:api)

    get("/state", ObservabilityApiController, :state)
    post("/state", ObservabilityApiController, :state)
    get("/refresh", ObservabilityApiController, :method_not_allowed)
    post("/refresh", ObservabilityApiController, :refresh)
    get("/:issue_identifier", ObservabilityApiController, :issue)
  end

  scope "/", RondoWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end
end
