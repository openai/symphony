defmodule SymphonyElixir.GoldenDatasetTest do
  use SymphonyElixir.TestSupport

  @dataset_path Path.expand("../fixtures/golden_dataset/workflow_prompt_cases.json", __DIR__)
  @repo_workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @required_case_fields ~w(id purpose issue expect_prompt_contains)
  @required_issue_fields ~w(id identifier title state url labels blocked_by)
  @issue_fields [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :blocked_by,
    :labels,
    :assigned_to_worker,
    :created_at,
    :updated_at
  ]

  test "golden workflow prompt dataset is schema-valid and renderable" do
    original_workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(@repo_workflow_path)

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)

    dataset = load_dataset!()
    assert dataset["schema_version"] == 1
    assert is_binary(dataset["description"])

    cases = Map.fetch!(dataset, "cases")
    assert is_list(cases)
    assert length(cases) >= 4

    assert_unique_case_ids!(cases)
    assert_active_states_are_covered!(cases)

    Enum.each(cases, fn golden_case ->
      assert_required_fields!(golden_case, @required_case_fields)
      assert is_binary(golden_case["purpose"])

      issue_attrs = Map.fetch!(golden_case, "issue")
      assert_required_fields!(issue_attrs, @required_issue_fields)
      assert is_list(issue_attrs["labels"])
      assert is_list(issue_attrs["blocked_by"])

      prompt =
        issue_attrs
        |> issue_from_attrs()
        |> PromptBuilder.build_prompt(prompt_opts(golden_case))

      assert is_binary(prompt)
      assert prompt != ""

      golden_case
      |> Map.fetch!("expect_prompt_contains")
      |> assert_expected_fragments!(prompt, golden_case["id"])
    end)
  end

  defp load_dataset! do
    @dataset_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_unique_case_ids!(cases) do
    ids = Enum.map(cases, &Map.fetch!(&1, "id"))

    assert Enum.all?(ids, &is_binary/1)
    assert Enum.uniq(ids) == ids
  end

  defp assert_active_states_are_covered!(cases) do
    active_states =
      Config.settings!()
      |> Map.fetch!(:tracker)
      |> Map.fetch!(:active_states)
      |> MapSet.new()

    dataset_states =
      cases
      |> Enum.map(&get_in(&1, ["issue", "state"]))
      |> MapSet.new()

    assert MapSet.subset?(active_states, dataset_states)
  end

  defp assert_required_fields!(map, fields) do
    Enum.each(fields, fn field ->
      assert Map.has_key?(map, field), "expected #{inspect(map)} to include #{field}"
    end)
  end

  defp issue_from_attrs(attrs) do
    struct_attrs =
      @issue_fields
      |> Enum.reduce(%{}, fn field, acc ->
        case Map.fetch(attrs, Atom.to_string(field)) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    struct!(Issue, struct_attrs)
  end

  defp prompt_opts(%{"attempt" => attempt}) when is_integer(attempt), do: [attempt: attempt]
  defp prompt_opts(_case), do: []

  defp assert_expected_fragments!(fragments, prompt, case_id) do
    assert is_list(fragments)
    assert fragments != []

    Enum.each(fragments, fn fragment ->
      assert prompt =~ fragment, "expected golden case #{case_id} prompt to include #{inspect(fragment)}"
    end)
  end
end
