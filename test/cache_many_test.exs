defmodule Carve.CacheManyTest do
  use ExUnit.Case, async: true

  # Acceptance tests for `cache_many` (docs/proposals/carve-cache-many.md).
  # The batched counterpart of test/cache_n_plus_one_test.exs: same renders,
  # same query-counting fake data layer, but the views declare their data
  # needs in bulk — so every render must cost exactly ONE query regardless
  # of list size. Red until `cache_many` is implemented.

  defmodule TestPost do
    defstruct [:id, :title, :author_id, :tag_ids]
  end

  defmodule TestUser do
    defstruct [:id, :name]
  end

  defmodule TestTag do
    defstruct [:id, :label]
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
    # The batched aggregate: one round trip for any number of posts.
    def count_for(post_ids) do
      DB.query(:counts_by_post_ids, post_ids)
      Map.new(post_ids, fn id -> {id, id * 10} end)
    end
  end

  defmodule Plans do
    def active_plans_for(user_ids) do
      DB.query(:plans_by_user_ids, user_ids)
      Map.new(user_ids, fn id -> {id, %{id: id + 1000, name: "pro"}} end)
    end
  end

  # The example use case from the proposal, batched.
  defmodule PostJSON do
    use Carve.View, :post

    cache_many fn posts ->
      counts = Comments.count_for(Enum.map(posts, & &1.id))
      Map.new(posts, fn post -> {post.id, %{comment_count: counts[post.id]}} end)
    end

    view fn post, cached ->
      %{
        id: hash(post.id),
        title: post.title,
        comment_count: cached.comment_count
      }
    end
  end

  # Batch function that omits even ids, to pin the missing-id contract:
  # ids absent from the returned map are cached as nil.
  defmodule SparsePostJSON do
    use Carve.View, :sparse_post

    cache_many fn posts ->
      ids = Enum.map(posts, & &1.id)
      DB.query(:sparse_counts, ids)

      for id <- ids, rem(id, 2) == 1, into: %{} do
        {id, %{comment_count: id * 10}}
      end
    end

    view fn post, cached ->
      %{
        id: hash(post.id),
        comment_count: if(cached, do: cached.comment_count, else: 0)
      }
    end
  end

  # A linked view with its own cache_many, for the link-resolution path.
  defmodule UserJSON do
    use Carve.View, :user

    get fn id ->
      DB.query(:get_user, id)
      # 999 plays a deleted user
      if id == 999, do: nil, else: %TestUser{id: id, name: "User #{id}"}
    end

    cache_many fn users ->
      plans = Plans.active_plans_for(Enum.map(users, & &1.id))
      Map.new(users, fn user -> {user.id, %{plan: plans[user.id]}} end)
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

    cache_many fn posts ->
      counts = Comments.count_for(Enum.map(posts, & &1.id))
      Map.new(posts, fn post -> {post.id, %{comment_count: counts[post.id]}} end)
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

  # A cache_many view linked through multi-id and lazy links.
  defmodule TagJSON do
    use Carve.View, :tag

    get fn id ->
      DB.query(:get_tag, id)
      %TestTag{id: id, label: "tag-#{id}"}
    end

    cache_many fn tags ->
      DB.query(:tags_usage_by_ids, Enum.map(tags, & &1.id))
      Map.new(tags, fn tag -> {tag.id, %{usage: tag.id * 2}} end)
    end

    view fn tag, cached ->
      %{id: hash(tag.id), label: tag.label, usage: cached.usage}
    end
  end

  defmodule PostWithTagsJSON do
    use Carve.View, :post

    links fn post ->
      %{TagJSON => post.tag_ids}
    end

    view fn post ->
      %{id: hash(post.id), title: post.title}
    end
  end

  defmodule PostWithLazyTagsJSON do
    use Carve.View, :post

    links fn post ->
      %{
        TagJSON =>
          fn ->
            DB.query(:lazy_tags_eval, post.id)
            post.tag_ids
          end
      }
    end

    view fn post ->
      %{id: hash(post.id), title: post.title}
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

  describe "index/show warm-up" do
    test "index of 100 distinct entities issues exactly one batched query" do
      posts = make_posts(100)

      result = PostJSON.index(%{result: posts})

      # Same rendered output as the per-entity version...
      counts = Enum.map(result.result, & &1.data.comment_count)
      assert counts == Enum.map(1..100, &(&1 * 10))

      # ...for one query instead of 100, covering every id in one call.
      assert DB.count(:counts_by_post_ids) == 1
      [ids] = DB.queries(:counts_by_post_ids)
      assert Enum.sort(ids) == Enum.to_list(1..100)
    end

    test "cache_many receives each entity once, even with duplicates in the list" do
      posts = make_posts(10) ++ make_posts(10)

      _result = PostJSON.index(%{result: posts})

      assert DB.count(:counts_by_post_ids) == 1
      [ids] = DB.queries(:counts_by_post_ids)
      assert Enum.sort(ids) == Enum.to_list(1..10)
    end

    test "show warms a one-element batch" do
      post = %TestPost{id: 7, title: "Post 7", author_id: 107}

      result = PostJSON.show(%{result: post})

      assert result.result.data.comment_count == 70
      assert DB.queries(:counts_by_post_ids) == [[7]]
    end

    test "ids missing from the returned map are cached as nil" do
      posts = Enum.map(1..6, fn id -> %TestPost{id: id, title: "Post #{id}"} end)

      result = SparsePostJSON.index(%{result: posts})

      # Even ids were omitted by the batch fn: the view receives nil and
      # handles absence itself, with no per-entity fallback queries.
      counts = Enum.map(result.result, & &1.data.comment_count)
      assert counts == [10, 0, 30, 0, 50, 0]
      assert DB.count(:sparse_counts) == 1
    end
  end

  describe "link resolution warm-up" do
    test "linked entities are warmed with one batched cache_many call" do
      posts = make_posts(50)

      result = PostWithAuthorJSON.index(%{result: posts, include: [:user]})

      assert length(result.links) == 50
      assert Enum.all?(result.links, &(&1.data.plan == "pro"))

      # The primary entities batch once...
      assert DB.count(:counts_by_post_ids) == 1

      # ...and the 50 linked users' cache blocks batch once too,
      # covering every author in one call.
      assert DB.count(:plans_by_user_ids) == 1
      [user_ids] = DB.queries(:plans_by_user_ids)
      assert Enum.sort(user_ids) == Enum.to_list(101..150)
    end
  end

  describe "stability" do
    test "separate renders re-run the batch — no cross-request leakage" do
      posts = make_posts(5)

      _first = PostJSON.index(%{result: posts})
      _second = PostJSON.index(%{result: posts})

      assert DB.count(:counts_by_post_ids) == 2
    end

    test "empty index issues no batch call" do
      result = PostJSON.index(%{result: []})

      assert result.result == []
      assert DB.count(:counts_by_post_ids) == 0
    end

    test "show with a multi-id link warms the linked view in one batch" do
      post = %TestPost{id: 1, title: "Post 1", tag_ids: [1, 2, 3]}

      result = PostWithTagsJSON.show(%{result: post, include: [:tag]})

      assert length(result.links) == 3
      assert Enum.sort(Enum.map(result.links, & &1.data.usage)) == [2, 4, 6]
      assert DB.count(:tags_usage_by_ids) == 1
      [ids] = DB.queries(:tags_usage_by_ids)
      assert Enum.sort(ids) == [1, 2, 3]
    end

    test "a linked id whose entity is missing is skipped without breaking the batch" do
      posts = [
        %TestPost{id: 1, title: "Post 1", author_id: 101},
        %TestPost{id: 2, title: "Post 2", author_id: 999}
      ]

      result = PostWithAuthorJSON.index(%{result: posts, include: [:user]})

      # The missing user is dropped from links and from the batch call.
      assert length(result.links) == 1
      assert DB.queries(:plans_by_user_ids) == [[101]]
    end

    test "lazy link functions are evaluated exactly once" do
      post = %TestPost{id: 1, title: "Post 1", tag_ids: [1, 2]}

      result = PostWithLazyTagsJSON.show(%{result: post, include: [:tag]})

      # The warm-up must not eagerly evaluate lazy links; the traversal
      # evaluates them once. (Lazy targets are not batched — they resolve
      # per entity through the batch-of-one fallback, which stays correct.)
      assert DB.count(:lazy_tags_eval) == 1
      assert length(result.links) == 2
      assert Enum.sort(Enum.map(result.links, & &1.data.usage)) == [2, 4]
    end
  end

  describe "definition rules" do
    test "defining both cache and cache_many is a compile-time error" do
      assert_raise CompileError, fn ->
        defmodule BothCacheStyles do
          use Carve.View, :both

          cache fn _post -> %{} end
          cache_many fn _posts -> %{} end

          view fn post, _cached -> %{id: hash(post.id)} end
        end
      end
    end
  end
end

defmodule Carve.CacheManyWithCacheDisabledTest do
  # Batching is not caching: with `enable_cache: false` the request cache is
  # off, but cache_many must still make exactly one batched call and deliver
  # each entity its value. async: false because it mutates global config.
  use ExUnit.Case, async: false

  alias Carve.CacheManyTest.{DB, PostJSON, TestPost}

  setup do
    original = Application.get_env(:carve, Carve.Config, [])
    Application.put_env(:carve, Carve.Config, Keyword.put(original, :enable_cache, false))
    on_exit(fn -> Application.put_env(:carve, Carve.Config, original) end)

    start_supervised!(DB)
    :ok
  end

  test "index still issues exactly one batched query with caching disabled" do
    posts = Enum.map(1..20, fn id -> %TestPost{id: id, title: "Post #{id}"} end)

    result = PostJSON.index(%{result: posts})

    counts = Enum.map(result.result, & &1.data.comment_count)
    assert counts == Enum.map(1..20, &(&1 * 10))
    assert DB.count(:counts_by_post_ids) == 1
  end
end
