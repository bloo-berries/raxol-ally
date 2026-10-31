defmodule AllyTest do
  use ExUnit.Case

  test "vision prompts return strings for all modes" do
    for mode <- [:alt_text, :long_desc, :decorative] do
      prompt = Ally.Vision.Prompts.for_mode(mode)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end
  end
end
