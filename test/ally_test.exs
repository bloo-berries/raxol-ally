defmodule AllyTest do
  use ExUnit.Case

  test "vision prompts return strings for all modes" do
    for mode <- [:alt_text, :long_desc, :decorative] do
      prompt = Ally.Vision.Prompts.for_mode(mode)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end
  end

  test "pipeline sanitize strips markdown and URLs" do
    assert Ally.Vision.Pipeline.sanitize("Hello world") == "Hello world"
    assert Ally.Vision.Pipeline.sanitize("Check [this](http://example.com)") == "Check this"

    assert Ally.Vision.Pipeline.sanitize("Visit http://example.com now") ==
             "Visit [link removed] now"

    assert Ally.Vision.Pipeline.sanitize("![alt](http://img.png) text") == " text"
    assert Ally.Vision.Pipeline.sanitize(nil) == ""
    assert Ally.Vision.Pipeline.sanitize("  padded  ") == "padded"
  end

  test "config returns default values" do
    assert is_binary(Ally.Config.otari_base_url())
    assert is_binary(Ally.Config.primary_model())
    assert is_binary(Ally.Config.fallback_model())
    assert is_integer(Ally.Config.ssh_port())
    assert is_float(Ally.Config.tenant_budget_usd())
  end

  test "MCP server exposes tool definitions" do
    tools = Ally.MCP.Server.tools()
    assert length(tools) == 3
    names = Enum.map(tools, & &1.name)
    assert "describe_image" in names
    assert "audit_url" in names
    assert "check_contrast" in names
  end

  test "MCP server rejects unknown tools" do
    assert {:error, "Unknown tool: fake_tool"} =
             Ally.MCP.Server.handle_tool_call("fake_tool", %{})
  end
end
