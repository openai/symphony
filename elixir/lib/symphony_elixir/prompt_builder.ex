defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Comment
  alias SymphonyElixir.Workflow

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @spec build_continuation_prompt(SymphonyElixir.Linear.Issue.t(), pos_integer(), pos_integer()) :: String.t()
  def build_continuation_prompt(issue, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Re-read the Linear issue, the workpad, and any recent human comments before choosing the next action.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.

    #{human_comment_section(issue)}
    """
  end

  @spec build_human_followup_prompt(SymphonyElixir.Linear.Issue.t(), [Comment.t()]) :: String.t()
  def build_human_followup_prompt(issue, comments) when is_list(comments) do
    """
    Human Linear follow-up for #{issue.identifier || issue.id || "this issue"}:

    The user added the Linear comment(s) below. Treat them as fresh human input for this same Codex thread and workspace. If they answer a blocker, continue the work. If they redirect or correct the implementation, update the plan/workpad and act on the new direction.

    #{format_comments(comments)}
    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp human_comment_section(%{comments: comments}) when is_list(comments) do
    comments
    |> Enum.filter(&Comment.human_feedback?/1)
    |> case do
      [] ->
        ""

      human_comments ->
        """
        Recent human Linear comments:

        #{format_comments(human_comments)}
        """
    end
  end

  defp human_comment_section(_issue), do: ""

  defp format_comments(comments) do
    comments
    |> Enum.filter(&Comment.human_feedback?/1)
    |> Enum.map_join("\n\n", fn %Comment{} = comment ->
      """
      From #{Comment.author_label(comment)} at #{Comment.timestamp_label(comment)}:
      #{String.trim(comment.body || "")}
      """
      |> String.trim()
    end)
    |> case do
      "" -> "No human comments were included."
      formatted -> formatted
    end
  end
end
