defmodule Carve.DeepGraphTest do
  use ExUnit.Case, async: true

  # Graph:
  #   5 assets → 3 users → 2 plans + 3 teams → back to same users
  #
  #   Asset 1,2 → User 1 (Alice)  → Plan 10, Team 100, Team 101
  #   Asset 3,4 → User 2 (Bob)    → Plan 11, Team 100, Team 102
  #   Asset 5   → User 3 (Charlie) → Plan 10, Team 101
  #
  #   Team 100 members: [User 1, User 2]
  #   Team 101 members: [User 1, User 3]
  #   Team 102 members: [User 2]
  #
  # Plan 10 is reachable via User 1 and User 3.
  # Team 100 is reachable via User 1 and User 2.
  # Every entity should be fetched exactly once.

  defmodule Asset do
    defstruct [:id, :user_id]
  end

  defmodule User do
    defstruct [:id, :name]
  end

  defmodule Plan do
    defstruct [:id, :name]
  end

  defmodule Team do
    defstruct [:id, :name, :member_ids]
  end

  defmodule Store do
    @users %{
      1 => %User{id: 1, name: "Alice"},
      2 => %User{id: 2, name: "Bob"},
      3 => %User{id: 3, name: "Charlie"}
    }

    @teams %{
      100 => %Team{id: 100, name: "Alpha", member_ids: [1, 2]},
      101 => %Team{id: 101, name: "Beta", member_ids: [1, 3]},
      102 => %Team{id: 102, name: "Gamma", member_ids: [2]}
    }

    @user_plans %{1 => 10, 2 => 11, 3 => 10}
    @user_teams %{1 => [100, 101], 2 => [100, 102], 3 => [101]}

    def get_user(id) do
      track(:get_user, id)
      Map.get(@users, id)
    end

    def get_plan(id) do
      track(:get_plan, id)
      %Plan{id: id, name: "Plan #{id}"}
    end

    def get_team(id) do
      track(:get_team, id)
      Map.get(@teams, id)
    end

    def get_user_plan_id(user_id) do
      track(:cache_user_plan, user_id)
      Map.get(@user_plans, user_id)
    end

    def get_user_team_ids(user_id) do
      track(:cache_user_teams, user_id)
      Map.get(@user_teams, user_id, [])
    end

    defp track(type, id) do
      Agent.update(:deep_graph_tracker, &Map.update(&1, {type, id}, 1, fn n -> n + 1 end))
    end
  end

  # Define in dependency order. UserJSON uses full name for TeamJSON (circular ref).

  defmodule PlanJSON do
    use Carve.View, :plan
    get fn id -> Store.get_plan(id) end
    view fn plan -> %{id: hash(plan.id), name: plan.name} end
  end

  defmodule UserJSON do
    use Carve.View, :user
    get fn id -> Store.get_user(id) end

    cache fn user ->
      %{
        plan_id: Store.get_user_plan_id(user.id),
        team_ids: Store.get_user_team_ids(user.id)
      }
    end

    links fn user, cached ->
      %{
        PlanJSON => cached.plan_id,
        Carve.DeepGraphTest.TeamJSON => cached.team_ids
      }
    end

    view fn user, cached ->
      %{
        id: hash(user.id),
        name: user.name,
        plan_id: PlanJSON.hash(cached.plan_id)
      }
    end
  end

  defmodule TeamJSON do
    use Carve.View, :team
    get fn id -> Store.get_team(id) end
    links fn team -> %{UserJSON => team.member_ids} end
    view fn team -> %{id: hash(team.id), name: team.name} end
  end

  defmodule AssetJSON do
    use Carve.View, :asset
    get fn id -> %Asset{id: id, user_id: 1} end
    links fn asset -> %{UserJSON => asset.user_id} end
    view fn asset -> %{id: hash(asset.id), user_id: UserJSON.hash(asset.user_id)} end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: :deep_graph_tracker)
    on_exit(fn -> if Process.whereis(:deep_graph_tracker), do: Agent.stop(:deep_graph_tracker) end)
    :ok
  end

  defp calls(type, id), do: Agent.get(:deep_graph_tracker, &Map.get(&1, {type, id}, 0))

  test "each get_by_id called once across the full graph" do
    assets = [
      %Asset{id: 1, user_id: 1},
      %Asset{id: 2, user_id: 1},
      %Asset{id: 3, user_id: 2},
      %Asset{id: 4, user_id: 2},
      %Asset{id: 5, user_id: 3}
    ]

    AssetJSON.index(%{result: assets})

    # 3 users, each fetched once
    assert calls(:get_user, 1) == 1
    assert calls(:get_user, 2) == 1
    assert calls(:get_user, 3) == 1

    # 2 plans, each fetched once (plan 10 shared by users 1 and 3)
    assert calls(:get_plan, 10) == 1
    assert calls(:get_plan, 11) == 1

    # 3 teams, each fetched once (team 100 shared by users 1 and 2)
    assert calls(:get_team, 100) == 1
    assert calls(:get_team, 101) == 1
    assert calls(:get_team, 102) == 1
  end

  test "each cache function called once across the full graph" do
    assets = [
      %Asset{id: 1, user_id: 1},
      %Asset{id: 2, user_id: 1},
      %Asset{id: 3, user_id: 2},
      %Asset{id: 4, user_id: 2},
      %Asset{id: 5, user_id: 3}
    ]

    AssetJSON.index(%{result: assets})

    # Each user's expensive lookups computed once
    assert calls(:cache_user_plan, 1) == 1
    assert calls(:cache_user_plan, 2) == 1
    assert calls(:cache_user_plan, 3) == 1
    assert calls(:cache_user_teams, 1) == 1
    assert calls(:cache_user_teams, 2) == 1
    assert calls(:cache_user_teams, 3) == 1
  end
end
