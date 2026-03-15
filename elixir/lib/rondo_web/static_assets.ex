defmodule RondoWeb.StaticAssets do
  @moduledoc """
  Embedded static assets for the observability dashboard.
  Assets are read at compile time when available for escript compatibility.
  """

  @dashboard_css_content (
    path = Path.join([__DIR__, "..", "..", "priv", "static", "dashboard.css"]) |> Path.expand()
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  )

  @phoenix_html_js_content (
    case :code.priv_dir(:phoenix_html) do
      {:error, _} -> nil
      priv_dir ->
        path = Path.join(to_string(priv_dir), "static/phoenix_html.js")
        case File.read(path) do
          {:ok, content} -> content
          {:error, _} -> nil
        end
    end
  )

  @phoenix_js_content (
    case :code.priv_dir(:phoenix) do
      {:error, _} -> nil
      priv_dir ->
        path = Path.join(to_string(priv_dir), "static/phoenix.js")
        case File.read(path) do
          {:ok, content} -> content
          {:error, _} -> nil
        end
    end
  )

  @phoenix_live_view_js_content (
    case :code.priv_dir(:phoenix_live_view) do
      {:error, _} -> nil
      priv_dir ->
        path = Path.join(to_string(priv_dir), "static/phoenix_live_view.js")
        case File.read(path) do
          {:ok, content} -> content
          {:error, _} -> nil
        end
    end
  )

  @spec fetch(String.t()) :: {:ok, String.t(), String.t()} | :error
  def fetch("/dashboard.css"), do: serve("text/css", @dashboard_css_content)
  def fetch("/vendor/phoenix_html/phoenix_html.js"), do: serve("application/javascript", @phoenix_html_js_content)
  def fetch("/vendor/phoenix/phoenix.js"), do: serve("application/javascript", @phoenix_js_content)
  def fetch("/vendor/phoenix_live_view/phoenix_live_view.js"), do: serve("application/javascript", @phoenix_live_view_js_content)
  def fetch(_path), do: :error

  defp serve(_content_type, nil), do: :error
  defp serve(content_type, body) when is_binary(body), do: {:ok, content_type, body}
end
