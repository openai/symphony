defmodule SymphonyElixir.LinearCommentTest do
  use SymphonyElixir.TestSupport

  test "human feedback ignores non-comments and service markers" do
    refute Comment.human_feedback?(:not_a_comment)
    refute Comment.human_feedback?(%Comment{body: "   "})
    refute Comment.human_feedback?(%Comment{body: "## Codex Workpad\n- working"})
    refute Comment.human_feedback?(%Comment{body: "<!-- symphony:blocked -->"})
    assert Comment.human_feedback?(%Comment{body: "Please use the simpler approach."})
  end

  test "cursor helpers order dated and undated comments" do
    dated = %Comment{id: "dated", body: "dated", created_at: ~U[2026-01-01 00:00:00Z]}
    undated = %Comment{id: "undated", body: "undated"}
    later_undated = %Comment{id: "b", body: "later undated"}

    assert Comment.cursor_for([undated, dated]) == %{created_at: dated.created_at, id: "dated"}

    assert Comment.comments_after([dated], %{created_at: nil, id: "cursor"}) == [dated]
    assert Comment.comments_after([undated], %{created_at: ~U[2026-01-01 00:00:00Z], id: "cursor"}) == []
    assert Comment.comments_after([later_undated], %{created_at: nil, id: "a"}) == [later_undated]
    assert Comment.comments_after([%Comment{id: "a"}], %{created_at: nil, id: nil}) == [%Comment{id: "a"}]
    assert Comment.comments_after([%Comment{}], %{created_at: nil, id: "a"}) == []
    assert Comment.comments_after([%Comment{}], %{created_at: nil, id: nil}) == []
  end

  test "comment labels fall back when author or timestamp are missing" do
    assert Comment.author_label(%Comment{author_name: "  "}) == "Unknown"
    assert Comment.author_label(:not_a_comment) == "Unknown"
    assert Comment.timestamp_label(%Comment{}) == "unknown time"
  end
end
