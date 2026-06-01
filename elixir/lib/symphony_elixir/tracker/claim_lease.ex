defmodule SymphonyElixir.Tracker.ClaimLease do
  @moduledoc """
  Durable tracker comment marker used to avoid duplicate issue dispatches.
  """

  @marker_start "<!-- symphony-claim-lease:v1 -->"
  @marker_end "<!-- /symphony-claim-lease -->"
  @kind "symphony_claim_lease"
  @version 1

  defstruct [
    :comment_id,
    :holder,
    :issue_id,
    :issue_identifier,
    :worker_host,
    :workspace_path,
    :session_id,
    :started_at,
    :refreshed_at,
    :expires_at,
    :attempt
  ]

  @type t :: %__MODULE__{
          comment_id: String.t() | nil,
          holder: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          session_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          refreshed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          attempt: non_neg_integer() | nil
        }

  @spec holder_id() :: String.t()
  def holder_id do
    Application.get_env(:symphony_elixir, :claim_lease_holder) ||
      System.get_env("SYMPHONY_CLAIM_LEASE_HOLDER") ||
      default_holder_id()
  end

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      comment_id: string_value(attrs, :comment_id),
      holder: string_value(attrs, :holder),
      issue_id: string_value(attrs, :issue_id),
      issue_identifier: string_value(attrs, :issue_identifier),
      worker_host: string_value(attrs, :worker_host),
      workspace_path: string_value(attrs, :workspace_path),
      session_id: string_value(attrs, :session_id),
      started_at: datetime_value(attrs, :started_at),
      refreshed_at: datetime_value(attrs, :refreshed_at),
      expires_at: datetime_value(attrs, :expires_at),
      attempt: non_negative_integer_value(attrs, :attempt)
    }
  end

  @spec render(t() | map() | keyword()) :: String.t()
  def render(%__MODULE__{} = lease), do: render_payload(lease)
  def render(attrs) when is_map(attrs) or is_list(attrs), do: attrs |> new() |> render_payload()

  @spec parse(String.t()) :: t() | nil
  def parse(body), do: parse(body, nil)

  @spec parse(String.t(), String.t() | nil) :: t() | nil
  def parse(body, comment_id) when is_binary(body) do
    with [_, encoded_payload] <- Regex.run(marker_regex(), body),
         {:ok, payload} <- Jason.decode(String.trim(encoded_payload)),
         true <- marker_payload?(payload) do
      payload
      |> Map.put("comment_id", comment_id)
      |> new()
    else
      _ -> nil
    end
  end

  def parse(_body, _comment_id), do: nil

  @spec from_comment(map()) :: t() | nil
  def from_comment(%{id: comment_id, body: body}), do: parse(body, comment_id)
  def from_comment(%{"id" => comment_id, "body" => body}), do: parse(body, comment_id)
  def from_comment(_comment), do: nil

  @spec find([map()]) :: t() | nil
  def find(comments) when is_list(comments) do
    comments
    |> Enum.map(&from_comment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&lease_sort_key/1, fn -> nil end)
  end

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) != :gt
  end

  def expired?(%__MODULE__{}, %DateTime{}), do: true

  @spec owned_by_current_holder?(t()) :: boolean()
  def owned_by_current_holder?(%__MODULE__{holder: holder}) when is_binary(holder) do
    holder == holder_id()
  end

  def owned_by_current_holder?(%__MODULE__{}), do: false

  @spec markers() :: {String.t(), String.t()}
  def markers, do: {@marker_start, @marker_end}

  defp render_payload(%__MODULE__{} = lease) do
    payload =
      %{
        "kind" => @kind,
        "version" => @version,
        "holder" => lease.holder,
        "issue_id" => lease.issue_id,
        "issue_identifier" => lease.issue_identifier,
        "worker_host" => lease.worker_host,
        "workspace_path" => lease.workspace_path,
        "session_id" => lease.session_id,
        "started_at" => encode_datetime(lease.started_at),
        "refreshed_at" => encode_datetime(lease.refreshed_at),
        "expires_at" => encode_datetime(lease.expires_at),
        "attempt" => lease.attempt
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    @marker_start <> "\n" <> Jason.encode!(payload, pretty: true) <> "\n" <> @marker_end
  end

  defp marker_regex do
    ~r/#{Regex.escape(@marker_start)}\s*(.*?)\s*#{Regex.escape(@marker_end)}/s
  end

  defp marker_payload?(%{"kind" => @kind, "version" => @version}), do: true
  defp marker_payload?(_payload), do: false

  defp string_value(attrs, key) do
    attrs
    |> value_for(key)
    |> normalize_string()
  end

  defp datetime_value(attrs, key) do
    attrs
    |> value_for(key)
    |> normalize_datetime()
  end

  defp non_negative_integer_value(attrs, key) do
    case value_for(attrs, key) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_non_negative_integer(value)
      _ -> nil
    end
  end

  defp value_for(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_value), do: nil

  defp lease_sort_key(%__MODULE__{} = lease) do
    [
      lease.refreshed_at,
      lease.expires_at,
      lease.started_at
    ]
    |> Enum.map(&datetime_sort_key/1)
    |> Enum.max()
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  defp default_holder_id do
    "#{hostname()}:#{System.pid()}"
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end
end
