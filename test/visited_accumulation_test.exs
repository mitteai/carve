defmodule Carve.VisitedAccumulationTest do
  @moduledoc """
  Reproduces the N+1 problem from mitte.ai:
  An index of 10 asset_versions by the same user triggers hundreds of duplicate
  queries because `visited` is NOT accumulated across list items in
  `get_links_by_data/5`.

  Graph:
    AssetVersion 1..10 → User 1 → UserPlan 101 → Plan 3
                                 → UserPlanGrant 201
                                 → Plan 3 (via team_plan)

  Expected: each entity fetched & rendered once.
  Actual:   UserPlan, Plan, etc. fetched & rendered once per asset version.
  """
  use ExUnit.Case, async: false

  # ── structs ──────────────────────────────────────────────────────────

  defmodule AssetVersion do
    defstruct [:id, :user_id, :flow_id]
  end

  defmodule User do
    defstruct [:id, :name]
  end

  defmodule UserPlan do
    defstruct [:id, :user_id, :plan_id]
  end

  defmodule UserPlanGrant do
    defstruct [:id, :user_id, :plan_id]
  end

  defmodule Plan do
    defstruct [:id, :name]
  end

  defmodule Flow do
    defstruct [:id, :name]
  end

  # ── fake store with call tracking ───────────────────────────────────

  defmodule Store do
    def get_user(id) do
      track(:get_user, id)
      %User{id: id, name: "User #{id}"}
    end

    def get_user_plan(id) do
      track(:get_user_plan, id)
      # derive user_id from id (id = 100 + user_id)
      %UserPlan{id: id, user_id: id - 100, plan_id: 3}
    end

    def get_user_plan_grant(id) do
      track(:get_user_plan_grant, id)
      # derive user_id from id (id = 200 + user_id)
      %UserPlanGrant{id: id, user_id: id - 200, plan_id: 1}
    end

    def get_plan(id) do
      track(:get_plan, id)
      %Plan{id: id, name: "Plan #{id}"}
    end

    def get_flow(id) do
      track(:get_flow, id)
      %Flow{id: id, name: "Flow #{id}"}
    end

    # expensive queries called inside cache/view
    def get_active_user_plan(user_id) do
      track(:active_user_plan, user_id)
      # unique id per user so different users get different user_plans
      %UserPlan{id: 100 + user_id, user_id: user_id, plan_id: 3}
    end

    def get_active_user_plan_grant(user_id) do
      track(:active_user_plan_grant, user_id)
      # unique id per user
      %UserPlanGrant{id: 200 + user_id, user_id: user_id, plan_id: 1}
    end

    def find_active_team_plan(user_id) do
      track(:find_team_plan, user_id)
      nil
    end

    # expensive query called inside UserPlanJSON.view (not cached)
    def get_remaining_credits(user_id) do
      track(:remaining_credits, user_id)
      42
    end

    def track(type, id) do
      Agent.update(:visited_tracker, &Map.update(&1, {type, id}, 1, fn n -> n + 1 end))
    end
  end

  # ── JSON views (mirrors mitte structure) ────────────────────────────

  defmodule PlanJSON do
    use Carve.View, :plan
    get fn id -> Store.get_plan(id) end
    view fn plan -> %{id: hash(plan.id), name: plan.name} end
  end

  defmodule UserPlanGrantJSON do
    use Carve.View, :user_plan_grant
    get fn id -> Store.get_user_plan_grant(id) end
    view fn grant -> %{id: hash(grant.id)} end
  end

  defmodule UserPlanJSON do
    use Carve.View, :user_plan
    get fn id -> Store.get_user_plan(id) end

    links fn user_plan ->
      %{
        Carve.VisitedAccumulationTest.UserJSON => user_plan.user_id,
        PlanJSON => user_plan.plan_id
      }
    end

    # Mimics mitte's UserPlanJSON.view which calls expensive queries
    view fn user_plan ->
      credits_left = Store.get_remaining_credits(user_plan.user_id)

      %{
        id: hash(user_plan.id),
        credits_left: credits_left
      }
    end
  end

  defmodule UserJSON do
    use Carve.View, :user
    get fn id -> Store.get_user(id) end

    cache fn user ->
      %{
        user_plan: Store.get_active_user_plan(user.id),
        user_plan_grant: Store.get_active_user_plan_grant(user.id),
        team_plan: Store.find_active_team_plan(user.id)
      }
    end

    links fn user, cached ->
      %{
        UserPlanJSON => cached.user_plan && cached.user_plan.id,
        UserPlanGrantJSON => cached.user_plan_grant && cached.user_plan_grant.id,
        PlanJSON => cached.team_plan && cached.team_plan
      }
    end

    view fn user, cached ->
      %{
        id: hash(user.id),
        name: user.name,
        user_plan_id:
          if(cached.user_plan, do: UserPlanJSON.hash(cached.user_plan.id), else: nil),
        user_plan_grant_id:
          if(cached.user_plan_grant,
            do: UserPlanGrantJSON.hash(cached.user_plan_grant.id),
            else: nil
          )
      }
    end
  end

  defmodule FlowJSON do
    use Carve.View, :flow
    get fn id -> Store.get_flow(id) end
    view fn flow -> %{id: hash(flow.id), name: flow.name} end
  end

  defmodule AssetVersionJSON do
    use Carve.View, :asset_version
    get fn id -> %AssetVersion{id: id, user_id: 1, flow_id: 10} end

    links fn v ->
      %{
        UserJSON => v.user_id,
        FlowJSON => v.flow_id
      }
    end

    view fn v ->
      %{
        id: hash(v.id),
        user_id: UserJSON.hash(v.user_id),
        flow_id: FlowJSON.hash(v.flow_id)
      }
    end
  end

  # ── test setup ──────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: :visited_tracker)
    on_exit(fn -> if Process.whereis(:visited_tracker), do: Agent.stop(:visited_tracker) end)
    :ok
  end

  defp calls(type, id),
    do: Agent.get(:visited_tracker, &Map.get(&1, {type, id}, 0))

  defp total_calls(type) do
    Agent.get(:visited_tracker, fn state ->
      state
      |> Enum.filter(fn {{t, _id}, _count} -> t == type end)
      |> Enum.map(fn {_key, count} -> count end)
      |> Enum.sum()
    end)
  end

  # ── tests ───────────────────────────────────────────────────────────

  describe "10 asset versions by same user" do
    setup do
      versions = for i <- 1..10, do: %AssetVersion{id: i, user_id: 1, flow_id: 10}
      result = AssetVersionJSON.index(%{result: versions})
      {:ok, result: result}
    end

    test "user get_by_id called once" do
      assert calls(:get_user, 1) == 1
    end

    test "user cache (plan queries) called once" do
      assert calls(:active_user_plan, 1) == 1
      assert calls(:active_user_plan_grant, 1) == 1
      assert calls(:find_team_plan, 1) == 1
    end

    test "user_plan get_by_id called once" do
      assert calls(:get_user_plan, 101) == 1
    end

    test "user_plan_grant get_by_id called once" do
      assert calls(:get_user_plan_grant, 201) == 1
    end

    test "plan get_by_id called once" do
      assert calls(:get_plan, 3) == 1
    end

    test "flow get_by_id called once" do
      assert calls(:get_flow, 10) == 1
    end

    test "UserPlanJSON.view expensive query called once" do
      # This is the key test: UserPlanJSON.view calls get_remaining_credits
      # inside prepare_for_view, which is NOT covered by Cachex.
      # With visited not accumulating, this fires once per asset version.
      assert calls(:remaining_credits, 1) == 1
    end

    test "total get_by_id calls across all modules is minimal" do
      total =
        total_calls(:get_user) +
          total_calls(:get_user_plan) +
          total_calls(:get_user_plan_grant) +
          total_calls(:get_plan) +
          total_calls(:get_flow)

      # 1 user + 1 user_plan + 1 user_plan_grant + 1 plan + 1 flow = 5
      assert total == 5
    end
  end

  describe "10 asset versions by 2 different users" do
    setup do
      versions =
        for i <- 1..10 do
          user_id = if rem(i, 2) == 0, do: 2, else: 1
          %AssetVersion{id: i, user_id: user_id, flow_id: 10}
        end

      result = AssetVersionJSON.index(%{result: versions})
      {:ok, result: result}
    end

    test "each user's cache called once" do
      assert calls(:active_user_plan, 1) == 1
      assert calls(:active_user_plan, 2) == 1
    end

    test "each user fetched once" do
      assert calls(:get_user, 1) == 1
      assert calls(:get_user, 2) == 1
    end

    test "UserPlanJSON.view expensive query called once per user" do
      assert calls(:remaining_credits, 1) == 1
      assert calls(:remaining_credits, 2) == 1
    end
  end
end
