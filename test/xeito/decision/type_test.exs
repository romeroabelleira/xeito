defmodule Xeito.Decision.TypeTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision.Type

  defp type(min_confidence),
    do: %Type{module: __MODULE__, name: "t", version: "1", instructions: nil, values: [], min_confidence: min_confidence}

  describe "threshold/3" do
    test "one number holds for every tier and backend" do
      assert Type.threshold(type(0.7), :local, :colibri) == 0.7
      assert Type.threshold(type(0.7), :remote, nil) == 0.7
    end

    test "a map is read by the backend that answered, then by the tier, then its default" do
      map = %{default: 0.9, local: 0.75, colibri: 0.6}

      assert Type.threshold(type(map), :local, :colibri) == 0.6
      assert Type.threshold(type(map), :local, :ollama) == 0.75
      assert Type.threshold(type(map), :remote, :openrouter) == 0.9
      assert Type.threshold(type(map), :remote, nil) == 0.9
    end

    test "a map without a default falls back to 0.8" do
      assert Type.threshold(type(%{colibri: 0.6}), :local, :ollama) == 0.8
    end
  end
end
