defmodule Rondo.RedactionTest do
  use ExUnit.Case, async: true

  alias Rondo.Redaction

  @no_env [env: %{}]

  test "redacts provider API key shapes" do
    assert Redaction.redact("key sk-ant-api03-abcdef1234567890abcdef", @no_env) == "key [REDACTED]"
    assert Redaction.redact("openai sk-abcdefghijklmnop1234", @no_env) == "openai [REDACTED]"
  end

  test "redacts bearer tokens" do
    assert Redaction.redact("Authorization: Bearer abc.def-ghi_jkl1234567890", @no_env) =~ "[REDACTED]"
    refute Redaction.redact("Authorization: Bearer abc.def-ghi_jkl1234567890", @no_env) =~ "jkl1234567890"
  end

  test "redacts GitHub tokens" do
    assert Redaction.redact("push with ghp_abcdefghijklmnopqrst123456", @no_env) == "push with [REDACTED]"
    assert Redaction.redact("github_pat_11ABCDEFGHIJKLMNOPQRSTUVWXYZ", @no_env) == "[REDACTED]"
  end

  test "redacts Slack and AWS tokens" do
    assert Redaction.redact("slack xoxb-1234567890-abcdef", @no_env) == "slack [REDACTED]"
    assert Redaction.redact("aws AKIAIOSFODNN7EXAMPLE used", @no_env) == "aws [REDACTED] used"
  end

  test "redacts private key blocks" do
    pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
    assert Redaction.redact("cert:\n#{pem}\ndone", @no_env) == "cert:\n[REDACTED]\ndone"
  end

  test "redacts unterminated private key blocks" do
    assert Redaction.redact("-----BEGIN PRIVATE KEY-----\nMIIEpAIBAAKCAQEA", @no_env) == "[REDACTED]"
  end

  test "redacts secret-named assignments" do
    assert Redaction.redact("API_KEY=supersecretvalue", @no_env) == "[REDACTED]"
    assert Redaction.redact("password: \"hunter2hunter2\"", @no_env) =~ "[REDACTED]"
    refute Redaction.redact("export MY_AUTH_TOKEN=abcd1234efgh", @no_env) =~ "abcd1234efgh"
  end

  test "leaves benign strings untouched" do
    assert Redaction.redact("input_tokens counted 12345678 across turns", @no_env) == "input_tokens counted 12345678 across turns"
    assert Redaction.redact("ran make all in elixir/", @no_env) == "ran make all in elixir/"
  end

  test "redacts values of secret-named env vars" do
    env = %{"ANTHROPIC_API_KEY" => "value-1234567890", "HOME" => "/Users/someone"}

    assert Redaction.redact("calling with value-1234567890 now", env: env) == "calling with [REDACTED] now"
    assert Redaction.redact("home is /Users/someone", env: env) == "home is /Users/someone"
  end

  test "ignores short or non-string secret env values" do
    env = %{"MY_TOKEN" => "abc", "OTHER_SECRET" => nil}

    assert Redaction.secret_env_values(env) == []
    assert Redaction.redact("abc stays", env: env) == "abc stays"
  end

  test "defaults to the system environment" do
    assert Redaction.redact("plain text") == "plain text"
  end

  test "passes non-binary values through" do
    assert Redaction.redact(42, @no_env) == 42
    assert Redaction.redact(nil, @no_env) == nil
    assert Redaction.redact(:atom, @no_env) == :atom
  end
end
