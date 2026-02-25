defmodule Carve.DuplicateCallsTest do
  use ExUnit.Case, async: true

  defmodule TestUser do
    defstruct [:id, :name]
  end

  defmodule TestPlan do
    defstruct [:id, :user_id]
  end

  defmodule TestAssetVersion do
    defstruct [:id, :user_id]
  end

  defmodule FakePlans do
    def get_active_user_plan(user_id) do
      Agent.update(:call_tracker, &Map.update(&1, {:plan, user_id}, 1, fn n -> n + 1 end))
      %TestPlan{id: 100 + user_id, user_id: user_id}
    end
  end

  defmodule PlanJSON do
    use Carve.View, :plan

    get fn id -> %TestPlan{id: id, user_id: nil} end
    view fn plan -> %{id: hash(plan.id)} end
  end

  defmodule UserJSON do
    use Carve.View, :user

    get fn id -> %TestUser{id: id, name: "User #{id}"} end

    cache fn user ->
      %{plan: FakePlans.get_active_user_plan(user.id)}
    end

    links fn user, cached ->
      %{PlanJSON => cached.plan.id}
    end

    view fn user, cached ->
      %{id: hash(user.id), name: user.name, plan_id: PlanJSON.hash(cached.plan.id)}
    end
  end

  # No cache macro — single-arity links/view stays unchanged
  defmodule AssetVersionJSON do
    use Carve.View, :asset_version

    get fn id -> %TestAssetVersion{id: id, user_id: 1} end
    links fn v -> %{UserJSON => v.user_id} end
    view fn v -> %{id: hash(v.id), user_id: UserJSON.hash(v.user_id)} end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: :call_tracker)
    on_exit(fn -> if Process.whereis(:call_tracker), do: Agent.stop(:call_tracker) end)
    :ok
  end

  defp calls(user_id), do: Agent.get(:call_tracker, &Map.get(&1, {:plan, user_id}, 0))

  test "show calls expensive function once per user, not twice" do
    UserJSON.show(%{result: %TestUser{id: 1, name: "Alice"}})
    assert calls(1) == 1
  end

  test "index calls expensive function once per user, not twice" do
    users = for i <- 1..3, do: %TestUser{id: i, name: "User #{i}"}
    UserJSON.index(%{result: users})

    assert calls(1) == 1
    assert calls(2) == 1
    assert calls(3) == 1
  end

  test "multiple asset versions referencing same user call expensive function once" do
    versions = for i <- 1..5, do: %TestAssetVersion{id: i, user_id: 1}
    AssetVersionJSON.index(%{result: versions})

    assert calls(1) == 1
  end
end
