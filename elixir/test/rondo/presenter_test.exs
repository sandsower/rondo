defmodule Rondo.PresenterTest do
  use Rondo.TestSupport

  test "run comparison labels omit timestamp suffix when started_at is invalid" do
    runs = [
      %{started_at: "invalid", tokens: %{input_tokens: 1, output_tokens: 2}},
      %{tokens: %{input_tokens: 3, output_tokens: 4}},
      %{started_at: "2026-05-10T11:14:57Z", tokens: %{input_tokens: 5, output_tokens: 6}}
    ]

    assert RondoWeb.Presenter.run_token_comparison(runs).labels == ["Run 1", "Run 2", "Run 3 (11:14)"]
    assert RondoWeb.Presenter.run_duration_comparison(runs).labels == ["Run 1", "Run 2", "Run 3 (11:14)"]
  end
end
