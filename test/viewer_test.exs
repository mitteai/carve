defmodule Carve.ViewerTest do
  # The viewer: show/index read it from the assigns, every function of every
  # view on the render gets it by arity, and a view that returns nil is left
  # out of the links. Views that do not ask for it render as before.
  use ExUnit.Case, async: false

  defmodule Log do
    def child_spec(_),
      do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__]]}}

    def put(entry), do: Agent.update(__MODULE__, &[entry | &1])

    def all(name),
      do: Agent.get(__MODULE__, fn log -> for {^name, arg} <- Enum.reverse(log), do: arg end)
  end

  # Who the viewer is to a user: the app's rule, not Carve's
  defp audience(user, viewer) do
    cond do
      viewer == nil -> :public
      viewer.id == user.id -> :owner
      viewer.team == user.team -> :team
      true -> :public
    end
  end

  defmodule UserJSON do
    use Carve.View, :user

    get(fn id -> %{id: id, name: "User #{id}", email: "u#{id}@x", team: rem(id, 2)} end)

    # one audience lookup per batch, logged to count calls
    cache_many(fn users, viewer ->
      Carve.ViewerTest.Log.put({:cache_many, {Enum.map(users, & &1.id), viewer}})

      Map.new(users, fn user ->
        {user.id, %{audience: Carve.ViewerTest.audience_of(user, viewer)}}
      end)
    end)

    links(fn user, cached, viewer ->
      Carve.ViewerTest.Log.put({:links, viewer})
      if cached.audience == :owner, do: %{Carve.ViewerTest.PlanJSON => user.id + 100}, else: %{}
    end)

    view(fn user, cached -> json(cached.audience, user) end)

    defp json(:public, user), do: %{id: hash(user.id), name: user.name}
    defp json(:team, user), do: json(:public, user) |> Map.put(:email, user.email)
    defp json(:owner, user), do: json(:team, user) |> Map.put(:owner, true)
  end

  # Owner-only, no cache: the viewer goes straight to view; nil for anyone else
  defmodule PlanJSON do
    use Carve.View, :plan

    get(fn id -> %{id: id, user_id: id - 100, secret: "cus_#{id}"} end)

    links(fn plan -> %{Carve.ViewerTest.NoteJSON => plan.id + 1000} end)

    view(fn plan, _cached, viewer ->
      if viewer && viewer.id == plan.user_id, do: %{id: hash(plan.id), secret: plan.secret}
    end)
  end

  # Below a plan: reachable only when the plan rendered
  defmodule NoteJSON do
    use Carve.View, :note

    get(fn id ->
      Carve.ViewerTest.Log.put({:note_get, id})
      %{id: id}
    end)

    view(fn note -> %{id: hash(note.id)} end)
  end

  defmodule PostJSON do
    use Carve.View, :post
    get(fn id -> %{id: id, author_id: id} end)
    links(fn post -> %{Carve.ViewerTest.UserJSON => post.author_id} end)
    view(fn post -> %{id: hash(post.id)} end)
  end

  # A view that never asks for the viewer: cache/1, links/2, view/2 as before
  defmodule PlainJSON do
    use Carve.View, :plain
    cache(fn item -> %{double: item.id * 2} end)
    links(fn _item, _cached -> %{} end)
    view(fn item, cached -> %{id: hash(item.id), double: cached.double} end)
  end

  def audience_of(user, viewer), do: audience(user, viewer)

  setup do
    start_supervised!(Log)
    :ok
  end

  defp data(body, type), do: for(%{type: ^type, data: d} <- body.links, do: d)

  test "no viewer: every linked user is public and no plan is rendered" do
    body = PostJSON.index(%{result: [%{id: 1, author_id: 1}, %{id: 2, author_id: 2}]})

    assert data(body, :user) == [
             %{id: UserJSON.hash(1), name: "User 1"},
             %{id: UserJSON.hash(2), name: "User 2"}
           ]

    assert data(body, :plan) == []
    assert Log.all(:cache_many) == [{[1, 2], nil}]
  end

  test "the viewer reaches cache_many, links and view down the link walk" do
    viewer = %{id: 1, team: 1}

    body =
      PostJSON.index(%{
        result: [%{id: 1, author_id: 1}, %{id: 2, author_id: 2}, %{id: 3, author_id: 3}],
        viewer: viewer
      })

    [me, stranger, mate] = data(body, :user)
    assert me == %{id: UserJSON.hash(1), name: "User 1", email: "u1@x", owner: true}
    assert stranger == %{id: UserJSON.hash(2), name: "User 2"}
    assert mate == %{id: UserJSON.hash(3), name: "User 3", email: "u3@x"}

    # the owner's plan rendered, with its secret, and nobody else's
    assert data(body, :plan) == [%{id: PlanJSON.hash(101), secret: "cus_101"}]
    assert Log.all(:cache_many) == [{[1, 2, 3], viewer}]
    assert Enum.all?(Log.all(:links), &(&1 == viewer))
  end

  test "a nil view is dropped from the links and its own links are not walked" do
    stranger = %{id: 9, team: 9}

    body =
      UserJSON.show(%{result: %{id: 1, name: "User 1", email: "u1@x", team: 1}, viewer: stranger})

    assert body.result.data == %{id: UserJSON.hash(1), name: "User 1"}
    assert body.links == []

    # the owner links the plan; a stranger must not see it, nor what hangs off it
    owner_body =
      UserJSON.show(%{
        result: %{id: 1, name: "User 1", email: "u1@x", team: 1},
        viewer: %{id: 1, team: 1}
      })

    assert data(owner_body, :plan) == [%{id: PlanJSON.hash(101), secret: "cus_101"}]
    assert data(owner_body, :note) == [%{id: NoteJSON.hash(1101)}]

    body = PlanJSON.show(%{result: %{id: 7, user_id: 7, secret: "s"}, viewer: %{id: 7, team: 0}})
    assert body.result.data.secret == "s"
    assert Log.all(:note_get) == [1101, 1007]
  end

  test "a nil view as a controller's own result raises" do
    assert_raise ArgumentError, ~r/PlanJSON rendered nil for 101/, fn ->
      PlanJSON.show(%{result: %{id: 101, user_id: 1, secret: "s"}, viewer: %{id: 2, team: 0}})
    end

    assert_raise ArgumentError, fn ->
      PlanJSON.index(%{result: [%{id: 101, user_id: 1, secret: "s"}]})
    end
  end

  test "the viewer key is configurable" do
    Application.put_env(:carve, Carve.Config, viewer: :current_user)

    body =
      UserJSON.show(%{
        result: %{id: 1, name: "User 1", email: "u1@x", team: 1},
        current_user: %{id: 1, team: 1}
      })

    assert body.result.data.owner == true
  after
    Application.delete_env(:carve, Carve.Config)
  end

  test "a view that does not ask for the viewer renders as before" do
    body = PlainJSON.index(%{result: [%{id: 2}], viewer: %{id: 1, team: 1}})

    assert body == %{
             result: [
               %{id: PlainJSON.hash(2), type: :plain, data: %{id: PlainJSON.hash(2), double: 4}}
             ],
             links: []
           }

    # the narrower generated forms still work, as an anonymous render
    assert PlainJSON.prepare_for_view(%{id: 3}).data.double == 6

    assert UserJSON.prepare_for_view(%{id: 1, name: "n", email: "e", team: 1}).data == %{
             id: UserJSON.hash(1),
             name: "n"
           }
  end
end
