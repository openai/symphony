defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case Keyword.pop(opts, :binding) do
      {nil, opts} -> Tracker.execute_agent_tool(tool, arguments, opts)
      {binding, opts} -> Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    Tracker.agent_tool_specs()
  end

  @spec bind() :: map()
  def bind do
    Tracker.bind_agent_tools()
  end
end
