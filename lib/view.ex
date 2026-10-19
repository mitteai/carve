defmodule Carve.View do
  @moduledoc """
  Carve.View provides a DSL for quickly building JSON API views in Phoenix applications.

  It automatically creates `show` and `index` functions for Phoenix controllers,
  handles ID hashing, and manages links between different entities.

  ## Usage

  In your Phoenix JSON view module:

      defmodule MyApp.UserJSON do
        use Carve.View, :user

        links fn user ->
          %{
            MyApp.TeamJSON => user.team_id,
            MyApp.ProfileJSON => user.profile_id
          }
        end

        get fn id ->
          MyApp.Users.get_by_id!(id)
        end

        view fn user ->
          %{
            id: hash(user.id),
            name: user.name,
            team_id: MyApp.TeamJSON.hash(user.team_id),
            profile_id: MyApp.ProfileJSON.hash(user.profile_id)
          }
        end
      end

  This will automatically create `show/1` and `index/1` functions that can be used
  in your Phoenix controllers, handling both data rendering and link generation.

  ## Caching Expensive Computations

  When both `links` and `view` need the same expensive data, use the `cache` macro
  to compute it once and pass it to both:

      defmodule MyApp.UserJSON do
        use Carve.View, :user

        get fn id -> MyApp.Users.get!(id) end

        cache fn user ->
          %{plan: MyApp.Plans.get_active_plan(user.id)}
        end

        links fn user, cached ->
          %{MyApp.PlanJSON => cached.plan.id}
        end

        view fn user, cached ->
          %{
            id: hash(user.id),
            plan_id: MyApp.PlanJSON.hash(cached.plan.id)
          }
        end
      end

  The cached result is also shared across entities within the same request,
  so if the same user is linked from multiple parents, the cache function
  runs only once.

  ## The viewer

  A render may carry who is looking. `show/1` and `index/1` read it from the
  assigns under the configured key (`config :carve, Carve.Config, viewer:
  :current_user`; the default key is `:viewer`), so a Phoenix `render/3`
  passes `conn.assigns.current_user` with no controller change. Every
  function of every view on the render, the root and each linked entity,
  gets the same viewer when it asks for it by arity:

      cache fn user, viewer -> ... end
      cache_many fn users, viewer -> ... end
      links fn user, cached, viewer -> ... end
      view fn user, cached, viewer -> ... end

  A `view` that returns `nil` says "not for this viewer": as a link the entity
  is left out and its own links are not walked; as a controller's result it
  raises, since the controller authorized a row its view refuses. Views that
  do not ask for the viewer render exactly as before.

  ## Generated Functions

  The `use Carve.View, :type` macro generates several functions at compile time:

  - `index/1`: Handles rendering a list of entities with their links.
  - `show/1`: Handles rendering a single entity with its links.
  - `hash/1`: Alias of encode_id.
  - `encode_id/1`: Encodes an ID using the view type as a salt.
  - `decode_id/1`: Decodes an ID using the view type as a salt.
  - `type_name/0`: Returns the type of the view.
  - `prepare_for_view/3`: Renders one entity's envelope for a viewer, or nil.
  - `declare_links/3`: Processes links for an entity (if `links` macro is used).

  Here's an example of what these functions might look like at runtime:

      def index(%{result: data}) when is_list(data) do
        results = Enum.map(data, &prepare_for_view/1)
        links = Carve.Links.get_links_by_data(__MODULE__, data)
        %{result: results, links: links}
      end

      def show(%{result: data}) do
        result = prepare_for_view(data)
        links = Carve.Links.get_links_by_data(__MODULE__, data)
        %{result: result, links: links}
      end

      def hash(id) when is_integer(id), do: Carve.HashIds.encode(:user, id)
      def hash(%{id: id}), do: hash(id)

      def type_name, do: :user

      def declare_links(data, cached, viewer) do
        %{
          MyApp.TeamJSON => data.team_id,
          MyApp.ProfileJSON => data.profile_id
        }
      end

  These generated functions work together to provide a seamless API for rendering
  JSON views with proper linking and ID hashing.
  """

  @doc """
  Sets up the view module with the given type.

  This macro is called when you use `use Carve.View, :type` in your module.
  It imports Carve.View functions and sets up the necessary module attributes.

  ## Parameters

  - `type`: An atom representing the type of the view (e.g., :user, :post).

  ## Example

      defmodule MyApp.UserJSON do
        use Carve.View, :user
        # ... rest of the module
      end
  """
  defmacro __using__(type) do
    quote do
      @carve_type unquote(type)
      import Carve.View
      @before_compile Carve.View
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    has_declare_links = Module.defines?(env.module, {:declare_links, 3})
    has_cache = Module.defines?(env.module, {:__cache__, 2})
    has_cache_many = Module.defines?(env.module, {:__cache_many__, 2})

    if has_cache and has_cache_many do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} defines both cache and cache_many; " <>
            "they are two calling conventions for the same slot — define only one"
    end

    # The per-entity cache slot: a batch of one when only cache_many is
    # defined, empty when neither is.
    cache_fallback =
      cond do
        has_cache ->
          nil

        has_cache_many ->
          quote do
            def __cache__(data, viewer) do
              Map.get(__cache_many__([data], viewer), Carve.Batch.entity_id(data))
            end
          end

        true ->
          quote do
            def __cache__(_data, _viewer), do: %{}
          end
      end

    # Default declare_links if no links macro was used
    declare_links_default =
      unless has_declare_links do
        quote do
          def declare_links(_data, _cached, _viewer), do: %{}
        end
      end

    quote do
      # Wrapper for show that manages cache context
      def show(assigns) do
        cache_key = Carve.Cache.get_or_create_context()

        try do
          do_show(assigns, cache_key)
        after
          Carve.Cache.clear_context()
        end
      end

      # Wrapper for index that manages cache context
      def index(assigns) do
        cache_key = Carve.Cache.get_or_create_context()

        try do
          do_index(assigns, cache_key)
        after
          Carve.Cache.clear_context()
        end
      end

      # Internal show implementation
      defp do_show(%{result: data} = assigns, cache_key) do
        viewer = Carve.View.viewer(assigns)
        include = Map.get(assigns, :include)
        cached = Map.get(Carve.Batch.warm(__MODULE__, [data], cache_key, viewer), data.id)

        result = result_for_viewer(data, cached, viewer)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, include, cache_key, viewer)
          else
            []
          end

        %{result: result, links: links}
      end

      # Internal index implementation
      defp do_index(%{result: data} = assigns, cache_key) when is_list(data) do
        viewer = Carve.View.viewer(assigns)
        include = Map.get(assigns, :include)
        cached_by_id = Carve.Batch.warm(__MODULE__, data, cache_key, viewer)

        results =
          Enum.map(data, fn item ->
            result_for_viewer(item, Map.get(cached_by_id, item.id), viewer)
          end)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, include, cache_key, viewer)
          else
            []
          end

        carve_count(%{result: results, links: links}, assigns)
      end

      # A controller's own result must render: a nil here means the controller
      # authorized a row its view refuses, which is a bug, not an empty response.
      defp result_for_viewer(data, cached, viewer) do
        case prepare_for_view(data, cached, viewer) do
          nil ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)} rendered nil for #{inspect(Carve.Batch.entity_id(data))}: " <>
                    "the view refuses this viewer, but the controller rendered it as a result"

          result ->
            result
        end
      end

      # A listing may carry how many rows it matches in all (the `count`
      # assign, a controller's `Bind.count/1` result); it rides along the
      # page as `count`.
      defp carve_count(response, %{count: count}) when is_integer(count) do
        Map.put(response, :count, count)
      end

      defp carve_count(response, _assigns), do: response

      # Keep all other generated functions the same
      def hash(id) when is_integer(id) do
        Carve.HashIds.encode(@carve_type, id)
      end

      def hash(%{id: id}) do
        hash(id)
      end

      def encode_id(id) when is_integer(id) do
        Carve.HashIds.encode(@carve_type, id)
      end

      def decode_id(hashed_id) when is_binary(hashed_id) do
        case Carve.HashIds.decode(@carve_type, hashed_id) do
          {:ok, id} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
      end

      def decode_id!(hashed_id) when is_binary(hashed_id) do
        case decode_id(hashed_id) do
          {:ok, id} -> id
          {:error, reason} -> raise "Failed to decode ID: #{reason}"
        end
      end

      def type_name, do: @carve_type

      unquote(cache_fallback)
      unquote(declare_links_default)

      # Narrower forms, for callers that render an entity by hand: no viewer
      # means an anonymous render.
      def __cache__(data), do: __cache__(data, nil)
      def declare_links(data), do: declare_links(data, __cache__(data, nil), nil)
      def declare_links(data, cached), do: declare_links(data, cached, nil)
      def prepare_for_view(data), do: prepare_for_view(data, __cache__(data, nil), nil)
      def prepare_for_view(data, cached), do: prepare_for_view(data, cached, nil)
    end
  end

  @doc false
  # The viewer of a render: the assign under the configured key, nil when absent.
  def viewer(assigns) when is_map(assigns), do: Map.get(assigns, Carve.Config.viewer_key())
  def viewer(_assigns), do: nil

  @doc """
  Caches expensive computations that are shared between `links` and `view`.

  The function receives the entity data (and the viewer, when it takes two
  arguments) and should return a map of precomputed values. This map is then
  passed as the second argument to `links` and `view` functions. Results are
  cached per entity (by module + id) within a single request.

  ## Example

      cache fn user ->
        %{
          plan: Plans.get_active_user_plan(user.id),
          team: Teams.get_team(user.team_id)
        }
      end

      links fn user, cached ->
        %{PlanJSON => cached.plan.id}
      end

      view fn user, cached ->
        %{id: hash(user.id), plan_id: PlanJSON.hash(cached.plan.id)}
      end
  """
  defmacro cache(func) do
    case detect_fn_arity(func) do
      2 ->
        quote do
          def __cache__(data, viewer), do: unquote(func).(data, viewer)
        end

      _ ->
        quote do
          def __cache__(data, _viewer), do: unquote(func).(data)
        end
    end
  end

  @doc """
  Batch sibling of `cache`: computes the cached data for every entity of a
  render in one call instead of once per entity, so a query inside it runs
  once per render instead of once per row.

  The function receives the list of entities about to be rendered (and the
  viewer, when it takes two arguments) and must return a map keyed by entity
  id. Each entity's value is passed to `links` and `view` as their second
  argument, exactly like `cache`. Ids missing from the returned map are
  cached as nil, and the view handles absence per entity. Defining both
  `cache` and `cache_many` in one view is a compile-time error.

  ## Example

      cache_many fn posts ->
        counts = Comments.count_for(Enum.map(posts, & &1.id))
        Map.new(posts, fn post -> {post.id, %{comment_count: counts[post.id]}} end)
      end

      view fn post, cached ->
        %{id: hash(post.id), comment_count: cached.comment_count}
      end
  """
  defmacro cache_many(func) do
    case detect_fn_arity(func) do
      2 ->
        quote do
          def __cache_many__(entities, viewer) when is_list(entities),
            do: unquote(func).(entities, viewer)
        end

      _ ->
        quote do
          def __cache_many__(entities, _viewer) when is_list(entities),
            do: unquote(func).(entities)
        end
    end
  end

  @doc """
  Defines the links for the current view.

  This macro allows you to specify how to generate links for the current entity.
  Accepts a 1-arity function, a 2-arity function when used with `cache`, or a
  3-arity function that also receives the viewer.

  ## Parameters

  - `func`: A function that takes the entity data (and optionally cached data
    and the viewer) and returns a map of links.

  ## Example

      links fn user ->
        %{
          MyApp.TeamJSON => user.team_id,
          MyApp.ProfileJSON => user.profile_id
        }
      end
  """
  defmacro links(func) do
    case detect_fn_arity(func) do
      3 ->
        quote do
          def declare_links(data, cached, viewer), do: unquote(func).(data, cached, viewer)
        end

      2 ->
        quote do
          def declare_links(data, cached, _viewer), do: unquote(func).(data, cached)
        end

      _ ->
        quote do
          def declare_links(data, _cached, _viewer), do: unquote(func).(data)
        end
    end
  end

  @doc """
  Defines how to render the view for the current entity.

  This macro specifies how to format the entity data for JSON output.
  Accepts a 1-arity function, a 2-arity function when used with `cache`, or a
  3-arity function that also receives the viewer.

  The `id` returned by the function is also used as the entity's envelope id,
  so a view can expose a custom identifier (e.g. a slug) instead of the
  hashed id. When the function returns no `id`, the envelope falls back to
  `hash(data.id)`.

  Returning `nil` means the entity is not shown to this viewer: it is left
  out of the links (and its own links are not walked), and raises when it is
  a controller's own result.

  ## Parameters

  - `func`: A function that takes the entity data (and optionally cached data
    and the viewer) and returns a map for JSON rendering, or nil.

  ## Example

      view fn user ->
        %{
          id: hash(user.id),
          name: user.name,
          team_id: MyApp.TeamJSON.hash(user.team_id)
        }
      end
  """
  defmacro view(func) do
    body =
      case detect_fn_arity(func) do
        3 -> quote do: unquote(func).(data, cached, viewer)
        2 -> quote do: unquote(func).(data, cached)
        _ -> quote do: unquote(func).(data)
      end

    quote do
      def prepare_for_view(data, cached, viewer) do
        _ = {cached, viewer}

        case unquote(body) do
          nil -> nil
          view -> %{id: Map.get(view, :id) || hash(data.id), type: type_name(), data: view}
        end
      end
    end
  end

  @doc """
  Defines how to retrieve an entity by its ID.

  This macro specifies a function to fetch an entity given its ID.

  ## Parameters

  - `func`: A function that takes an ID and returns the corresponding entity.

  ## Example

      get fn id ->
        MyApp.Users.get_by_id!(id)
      end
  """
  defmacro get(func) do
    quote do
      def get_by_id(id) do
        unquote(func).(id)
      end
    end
  end

  @doc """
  Generates a runtime `case` statement to return a loaded Ecto association or fall back to its ID.
  """
  defmacro data_or_id(association, id) do
    quote do
      case unquote(association) do
        %Ecto.Association.NotLoaded{} -> unquote(id)
        loaded -> loaded
      end
    end
  end

  # Detect the arity of a literal fn from its AST
  defp detect_fn_arity({:fn, _, [{:->, _, [args, _]} | _]}) when is_list(args), do: length(args)
  defp detect_fn_arity(_), do: 1
end
