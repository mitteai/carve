defmodule Carve.CacheTest do
  use ExUnit.Case, async: true

  defmodule TestUser do
    defstruct [:id, :name, :fetch_count]
  end

  defmodule TestPost do
    defstruct [:id, :title, :user_id]
  end

  # Track how many times get_by_id is called
  defmodule UserJSON do
    use Carve.View, :user

    get fn id ->
      # Increment a counter to track fetches
      Agent.update(:fetch_tracker, fn state ->
        Map.update(state, {:user, id}, 1, &(&1 + 1))
      end)

      %TestUser{id: id, name: "User #{id}"}
    end

    view fn user ->
      %{
        id: hash(user.id),
        name: user.name
      }
    end
  end

  defmodule PostJSON do
    use Carve.View, :post

    get fn id ->
      Agent.update(:fetch_tracker, fn state ->
        Map.update(state, {:post, id}, 1, &(&1 + 1))
      end)

      %TestPost{id: id, title: "Post #{id}", user_id: 1}
    end

    links fn post ->
      %{
        UserJSON => post.user_id
      }
    end

    view fn post ->
      %{
        id: hash(post.id),
        title: post.title,
        user_id: UserJSON.hash(post.user_id)
      }
    end
  end

  setup do
    {:ok, _pid} = Agent.start_link(fn -> %{} end, name: :fetch_tracker)

    on_exit(fn ->
      if Process.whereis(:fetch_tracker) do
        Agent.stop(:fetch_tracker)
      end
    end)

    :ok
  end

  test "caches entity fetches within a single render" do
    posts = [
      %TestPost{id: 1, title: "Post 1", user_id: 1},
      %TestPost{id: 2, title: "Post 2", user_id: 1},
      %TestPost{id: 3, title: "Post 3", user_id: 1}
    ]

    # All three posts reference the same user
    _result = PostJSON.index(%{result: posts, include: [:user]})

    fetch_counts = Agent.get(:fetch_tracker, & &1)

    # User 1 should only be fetched once, not three times
    assert fetch_counts[{:user, 1}] == 1
  end

  test "does not cache across different renders" do
    post1 = %TestPost{id: 1, title: "Post 1", user_id: 1}
    post2 = %TestPost{id: 1, title: "Post 1", user_id: 1}

    # First render
    _result1 = PostJSON.show(%{result: post1, include: [:user]})

    # Second render (separate request)
    _result2 = PostJSON.show(%{result: post2, include: [:user]})

    fetch_counts = Agent.get(:fetch_tracker, & &1)

    # User 1 should be fetched twice (once per render)
    assert fetch_counts[{:user, 1}] == 2
  end

  test "caches work with deeply nested structures" do
    # Create posts that all reference the same user through their links
    posts = Enum.map(1..5, fn id ->
      %TestPost{id: id, title: "Post #{id}", user_id: 1}
    end)

    _result = PostJSON.index(%{result: posts, include: [:user]})

    fetch_counts = Agent.get(:fetch_tracker, & &1)

    # User 1 should only be fetched once despite 5 posts referencing it
    assert fetch_counts[{:user, 1}] == 1
  end

  test "cache expires after TTL" do
    post = %TestPost{id: 1, title: "Post 1", user_id: 1}

    # Start a render with cache
    _result1 = PostJSON.show(%{result: post, include: [:user]})

    # Wait for cache to expire
    Process.sleep(150)

    # Make another call within the same "request" context
    # This should fetch again since cache expired
    _result2 = PostJSON.show(%{result: post, include: [:user]})

    fetch_counts = Agent.get(:fetch_tracker, & &1)

    # User should be fetched twice due to expiry
    assert fetch_counts[{:user, 1}] == 2
  end
end
