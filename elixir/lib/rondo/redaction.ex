defmodule Rondo.Redaction do
  @moduledoc """
  Conservative deny-list redaction for strings persisted to run ledger artifacts.

  Two layers run before persistence:

  - secret-shaped patterns (provider API keys, bearer tokens, GitHub/Slack/AWS
    tokens, private-key markers, and `SECRET_NAME=value` assignments), and
  - exact values of environment variables whose names look secret.

  Redaction is intentionally lossy and safe-by-default: matched spans are
  replaced with `[REDACTED]`.
  """

  @replacement "[REDACTED]"
  @min_env_secret_bytes 8

  @secret_patterns [
    ~r/(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}/,
    ~r/\bbearer\s+[A-Za-z0-9._~+\/=-]{16,}/i,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    ~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----(?:.|\n)*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/,
    ~r/\b[A-Za-z0-9_.-]*(api[_-]?key|secret|token|password|passwd|credential|authorization)[A-Za-z0-9_.-]*["']?\s*[:=]\s*["']?[^\s"']{8,}/i
  ]

  @secret_env_name_pattern ~r/(api[_-]?key|secret|token|password|passwd|credential|auth)/i

  @doc """
  Redacts secret-shaped substrings and known secret env values from a string.

  Non-binary values are returned unchanged so callers can pipe arbitrary
  sanitized terms through.
  """
  @spec redact(term()) :: term()
  def redact(value), do: redact(value, [])

  @spec redact(term(), keyword()) :: term()
  def redact(value, opts) when is_binary(value) do
    value
    |> redact_env_values(Keyword.get(opts, :env, System.get_env()))
    |> redact_patterns()
  end

  def redact(value, _opts), do: value

  @doc "Returns true when redaction would remove secret-shaped content from a string."
  @spec contains_secret?(term()) :: boolean()
  def contains_secret?(value), do: contains_secret?(value, [])

  @spec contains_secret?(term(), keyword()) :: boolean()
  def contains_secret?(value, opts) when is_binary(value), do: redact(value, opts) != value
  def contains_secret?(_value, _opts), do: false

  @spec secret_env_values(%{optional(String.t()) => String.t()}) :: [String.t()]
  def secret_env_values(env) when is_map(env) do
    for {name, value} <- env,
        is_binary(value),
        byte_size(value) >= @min_env_secret_bytes,
        Regex.match?(@secret_env_name_pattern, name) do
      value
    end
  end

  defp redact_patterns(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @replacement)
    end)
  end

  defp redact_env_values(value, env) do
    env
    |> secret_env_values()
    |> Enum.reduce(value, fn secret, acc ->
      String.replace(acc, secret, @replacement)
    end)
  end
end
