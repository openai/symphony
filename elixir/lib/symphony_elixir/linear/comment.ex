defmodule SymphonyElixir.Linear.Comment do
  @moduledoc """
  Normalized Linear comment representation.
  """

  defstruct [
    :id,
    :body,
    :author_id,
    :author_name,
    :created_at,
    :updated_at
  ]

  @type cursor :: %{created_at: DateTime.t() | nil, id: String.t() | nil}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          body: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @ignored_markers [
    "<!-- symphony:",
    "## Codex Workpad",
    "## Codex needs input",
    "## Codex Needs Input"
  ]

  @spec human_feedback?(t()) :: boolean()
  def human_feedback?(%__MODULE__{body: body}) when is_binary(body) do
    trimmed = String.trim(body)

    trimmed != "" and
      Enum.all?(@ignored_markers, fn marker ->
        not String.contains?(body, marker)
      end)
  end

  def human_feedback?(_comment), do: false

  @spec cursor_for([t()]) :: cursor() | nil
  def cursor_for(comments) when is_list(comments) do
    comments
    |> Enum.filter(&match?(%__MODULE__{}, &1))
    |> Enum.sort(&compare_comments?/2)
    |> List.last()
    |> case do
      %__MODULE__{} = comment -> cursor_from_comment(comment)
      _ -> nil
    end
  end

  @spec comments_after([t()], cursor() | nil) :: [t()]
  def comments_after(comments, nil) when is_list(comments), do: []

  def comments_after(comments, cursor) when is_list(comments) and is_map(cursor) do
    comments
    |> Enum.filter(fn comment ->
      match?(%__MODULE__{}, comment) and after_cursor?(comment, cursor)
    end)
    |> Enum.sort(&compare_comments?/2)
  end

  @spec author_label(t()) :: String.t()
  def author_label(%__MODULE__{author_name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> "Unknown"
      trimmed -> trimmed
    end
  end

  def author_label(_comment), do: "Unknown"

  @spec timestamp_label(t()) :: String.t()
  def timestamp_label(%__MODULE__{created_at: %DateTime{} = created_at}), do: DateTime.to_iso8601(created_at)
  def timestamp_label(_comment), do: "unknown time"

  defp cursor_from_comment(%__MODULE__{created_at: created_at, id: id}) do
    %{created_at: created_at, id: id}
  end

  defp after_cursor?(%__MODULE__{} = comment, %{created_at: cursor_created_at, id: cursor_id}) do
    compare_cursor_parts(comment.created_at, comment.id, cursor_created_at, cursor_id) == :gt
  end

  defp compare_comments?(%__MODULE__{} = left, %__MODULE__{} = right) do
    compare_cursor_parts(left.created_at, left.id, right.created_at, right.id) != :gt
  end

  defp compare_cursor_parts(%DateTime{} = left_time, left_id, %DateTime{} = right_time, right_id) do
    case DateTime.compare(left_time, right_time) do
      :eq -> compare_ids(left_id, right_id)
      other -> other
    end
  end

  defp compare_cursor_parts(%DateTime{}, _left_id, _right_time, _right_id), do: :gt
  defp compare_cursor_parts(_left_time, _left_id, %DateTime{}, _right_id), do: :lt
  defp compare_cursor_parts(_left_time, left_id, _right_time, right_id), do: compare_ids(left_id, right_id)

  defp compare_ids(left_id, right_id) when is_binary(left_id) and is_binary(right_id) do
    cond do
      left_id > right_id -> :gt
      left_id < right_id -> :lt
      true -> :eq
    end
  end

  defp compare_ids(left_id, _right_id) when is_binary(left_id), do: :gt
  defp compare_ids(_left_id, right_id) when is_binary(right_id), do: :lt
  defp compare_ids(_left_id, _right_id), do: :eq
end
