defmodule SymphonyElixir.TokenUsageLedger do
  @moduledoc """
  Durable JSONL ledger for per-issue Codex token usage observations.
  """

  require Logger

  alias SymphonyElixir.LogFile

  @schema_version 1
  @ledger_filename "token_usage.jsonl"

  @type token_summary :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          issue_count: non_neg_integer(),
          session_count: non_neg_integer()
        }

  @type issue_summary :: %{
          issue_id: String.t() | nil,
          issue_identifier: String.t(),
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          session_count: non_neg_integer()
        }

  @spec file_path() :: Path.t()
  def file_path do
    case Application.get_env(:symphony_elixir, :token_usage_ledger_file) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        default_file_path()
    end
  end

  @spec append_observation(map(), keyword()) :: :ok
  def append_observation(attrs, opts \\ []) when is_map(attrs) do
    file = Keyword.get(opts, :file, file_path())
    record = observation_record(attrs)
    line = Jason.encode!(record) <> "\n"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, line, [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to append token usage ledger record file=#{file} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to append token usage ledger record reason=#{Exception.message(error)}")
      :ok
  end

  @spec summary(keyword()) :: token_summary()
  def summary(opts \\ []) do
    high_water = opts |> read_records() |> high_water_records()

    %{
      input_tokens: sum_token(high_water, :input_tokens),
      output_tokens: sum_token(high_water, :output_tokens),
      total_tokens: sum_token(high_water, :total_tokens),
      issue_count: high_water |> Enum.map(& &1.issue_identifier) |> Enum.uniq() |> length(),
      session_count: length(high_water)
    }
  end

  @spec issue_summary(String.t(), keyword()) :: issue_summary() | nil
  def issue_summary(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    records =
      opts
      |> read_records()
      |> Enum.filter(&(&1.issue_identifier == issue_identifier))

    case high_water_records(records) do
      [] ->
        nil

      high_water ->
        latest = Enum.max_by(records, & &1.observed_at, fn -> nil end)

        %{
          issue_id: latest && latest.issue_id,
          issue_identifier: issue_identifier,
          worker_host: latest && latest.worker_host,
          workspace_path: latest && latest.workspace_path,
          input_tokens: sum_token(high_water, :input_tokens),
          output_tokens: sum_token(high_water, :output_tokens),
          total_tokens: sum_token(high_water, :total_tokens),
          session_count: length(high_water)
        }
    end
  end

  @spec read_records(keyword()) :: [map()]
  def read_records(opts \\ []) do
    file = Keyword.get(opts, :file, file_path())

    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_record/1)

      {:error, _reason} ->
        []
    end
  end

  defp default_file_path do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    Path.join(Path.dirname(log_file), @ledger_filename)
  end

  defp observation_record(attrs) do
    %{
      "schema_version" => @schema_version,
      "observed_at" => observed_at(attrs),
      "final" => boolean_value(value(attrs, :final), false),
      "issue_id" => string_value(value(attrs, :issue_id)),
      "issue_identifier" => string_value(value(attrs, :issue_identifier)),
      "session_id" => string_value(value(attrs, :session_id)),
      "worker_host" => string_value(value(attrs, :worker_host)),
      "workspace_path" => string_value(value(attrs, :workspace_path)),
      "turn_count" => integer_value(value(attrs, :turn_count), 0),
      "input_tokens" => integer_value(value(attrs, :input_tokens), 0),
      "output_tokens" => integer_value(value(attrs, :output_tokens), 0),
      "total_tokens" => integer_value(value(attrs, :total_tokens), 0),
      "source_event" => string_value(value(attrs, :source_event))
    }
  end

  defp observed_at(attrs) do
    case value(attrs, :observed_at) do
      %DateTime{} = observed_at ->
        observed_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      observed_at when is_binary(observed_at) and observed_at != "" ->
        observed_at

      _ ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp decode_record(line) do
    case Jason.decode(line) do
      {:ok, %{} = raw} ->
        case normalize_record(raw) do
          nil -> []
          record -> [record]
        end

      _ ->
        []
    end
  end

  defp normalize_record(raw) do
    with @schema_version <- integer_value(value(raw, :schema_version), 0),
         issue_identifier when is_binary(issue_identifier) <- string_value(value(raw, :issue_identifier)),
         session_id when is_binary(session_id) <- string_value(value(raw, :session_id)) do
      %{
        observed_at: string_value(value(raw, :observed_at)) || "",
        final: boolean_value(value(raw, :final), false),
        issue_id: string_value(value(raw, :issue_id)),
        issue_identifier: issue_identifier,
        session_id: session_id,
        worker_host: string_value(value(raw, :worker_host)),
        workspace_path: string_value(value(raw, :workspace_path)),
        turn_count: integer_value(value(raw, :turn_count), 0),
        input_tokens: integer_value(value(raw, :input_tokens), 0),
        output_tokens: integer_value(value(raw, :output_tokens), 0),
        total_tokens: integer_value(value(raw, :total_tokens), 0),
        source_event: string_value(value(raw, :source_event))
      }
    else
      _ -> nil
    end
  end

  defp high_water_records(records) do
    records
    |> Enum.group_by(&{&1.issue_identifier, &1.session_id})
    |> Enum.map(fn {_key, session_records} ->
      Enum.max_by(session_records, & &1.total_tokens)
    end)
  end

  defp sum_token(records, key) do
    Enum.reduce(records, 0, fn record, total ->
      total + Map.get(record, key, 0)
    end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp integer_value(value, _default) when is_integer(value), do: max(value, 0)

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> max(parsed, 0)
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp boolean_value(value, _default) when is_boolean(value), do: value
  defp boolean_value(_value, default), do: default

  defp string_value(nil), do: nil

  defp string_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil
end
