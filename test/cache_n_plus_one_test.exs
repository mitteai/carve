defmodule Carve.CacheNPlusOneTest do
  use ExUnit.Case, async: true

  # Reproduces the N+1 described in docs/proposals/carve-cache-many.md:
  # a query inside a `cache` block runs once per entity, so an index render
  # of N distinct entities issues N queries. The request cache only dedupes
  # repeat appearances of the *same* entity — on a list of distinct rows it
  # never hits. The batched equivalent (one `GROUP BY ... WHERE id IN (...)`)
  # would answer each of these renders with a single query.
  #
  # These tests assert the current per-entity behavior. Once `cache_many`
  # exists, views using it should render the same output with 1 query.

  defmodule TestPost do
    defstruct [:id, :title, :author_id]
  end

  defmodule TestUser do
    defstruct [:id, :name]
  end

  # Fake data layer that logs every "query" it receives.
  defmodule DB do
    def child_spec(_) do
      %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__]]}}
    end

    def query(name, arg) do
      Agent.update(__MODULE__, &[{name, arg} | &1])
    end

    def queries(name) do
      Agent.get(__MODULE__, fn log ->
        for {^name, arg} <- log, do: arg
      end)
    end

    def count(name), do: length(queries(name))
  end

  defmodule Comments do
    # The per-entity aggregate from the proposal: fast query, one round trip per call.
    def count_by_post_id(post_id) do
      DB.query(:count_by_post_id, post_id)
      post_id * 10
    end
  end

  defmodule Plans do
    def get_active_plan(user_id) do
      DB.query(:get_active_plan, user_id)
      %{id: user_id + 1000, name: "pro"}
    end
  end

  # The example use case: an index of posts where each post's view needs its
  # comment count, computed in `cache`.
  defmodule PostJSON do
    use Carve.View, :post

    cache fn post ->
      %{comment_count: Comments.count_by_post_id(post.id)}
    end

    view fn post, cached ->
      %{
        id: hash(post.id),
        title: post.title,
        comment_count: cached.comment_count
      }
    end
  end

  # A linked view with its own `cache` query, to reproduce the same N+1 on
  # the link-resolution path.
  defmodule UserJSON do
    use Carve.View, :user

    get fn id ->
      DB.query(:get_user, id)
      %TestUser{id: id, name: "User #{id}"}
    end

    cache fn user ->
      %{plan: Plans.get_active_plan(user.id)}
    end

    view fn user, cached ->
      %{
        id: hash(user.id),
        name: user.name,
        plan: cached.plan.name
      }
    end
  end

  defmodule PostWithAuthorJSON do
    use Carve.View, :post

    cache fn post ->
      %{comment_count: Comments.count_by_post_id(post.id)}
    end

    links fn post ->
      %{UserJSON => post.author_id}
    end

    view fn post, cached ->
      %{
        id: hash(post.id),
        title: post.title,
        author_id: UserJSON.hash(post.author_id),
        comment_count: cached.comment_count
      }
    end
  end

  setup do
    start_supervised!(DB)
    :ok
  end

  defp make_posts(n) do
    Enum.map(1..n, fn id ->
      %TestPost{id: id, title: "Post #{id}", author_id: id + 100}
    end)
  end

  test "index of N distinct entities runs the cache query N times" do
    posts = make_posts(100)

    result = PostJSON.index(%{result: posts})

    # The rendered data itself is correct...
    counts = Enum.map(result.result, & &1.data.comment_count)
    assert counts == Enum.map(1..100, &(&1 * 10))

    # ...but it cost one query per row instead of one query total.
    assert DB.count(:count_by_post_id) == 100
    assert Enum.sort(DB.queries(:count_by_post_id)) == Enum.to_list(1..100)
  end

  test "the request cache never hits on distinct rows: every id is queried exactly once" do
    posts = make_posts(50)

    _result = PostJSON.index(%{result: posts})

    # No id is queried twice (dedup works), but no query is saved either —
    # dedup only helps when entities repeat, which distinct index rows never do.
    frequencies = Enum.frequencies(DB.queries(:count_by_post_id))
    assert Enum.all?(frequencies, fn {_id, n} -> n == 1 end)
    assert map_size(frequencies) == 50
  end

  test "show issues a single cache query (the baseline cache_many must preserve)" do
    post = %TestPost{id: 7, title: "Post 7", author_id: 107}

    result = PostJSON.show(%{result: post})

    assert result.result.data.comment_count == 70
    assert DB.count(:count_by_post_id) == 1
  end

  test "link resolution pays the same N+1: one get and one cache query per linked entity" do
    # 50 posts, each with a distinct author. Rendering the index resolves
    # each author through UserJSON one at a time.
    posts = make_posts(50)

    result = PostWithAuthorJSON.index(%{result: posts, include: [:user]})

    assert length(result.links) == 50

    # Per-post cache query: N+1 on the primary entities.
    assert DB.count(:count_by_post_id) == 50

    # Per-author queries: N+1 twice over on the linked entities —
    # once fetching each user, once running each user's cache block.
    assert DB.count(:get_user) == 50
    assert DB.count(:get_active_plan) == 50
  end

  test "repeated linked entities are deduped — the only case the request cache saves queries" do
    # All 50 posts share one author: this is the shape `cache` was built for.
    posts =
      Enum.map(1..50, fn id ->
        %TestPost{id: id, title: "Post #{id}", author_id: 1}
      end)

    _result = PostWithAuthorJSON.index(%{result: posts, include: [:user]})

    assert DB.count(:get_user) == 1
    assert DB.count(:get_active_plan) == 1

    # The primary entities are still distinct, so they still pay N.
    assert DB.count(:count_by_post_id) == 50
  end
end
