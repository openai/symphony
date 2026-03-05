defmodule SymphonyElixirWeb.ErrorHTML do
  @moduledoc false

  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
