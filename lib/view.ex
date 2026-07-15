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

  ## Generated Functions

  The `use Carve.View, :type` macro generates several functions at compile time:

  - `index/1`: Handles rendering a list of entities with their links.
  - `show/1`: Handles rendering a single entity with its links.
  - `hash/1`: Alias of encode_id.
  - `encode_id/1`: Encodes an ID using the view type as a salt.
  - `decode_id/1`: Decodes an ID using the view type as a salt.
  - `type_name/0`: Returns the type of the view.
  - `declare_links/1`: Processes links for an entity (if `links` macro is used).

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

      def declare_links(data) do
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
    has_declare_links =
      Module.defines?(env.module, {:declare_links, 1}) ||
        Module.defines?(env.module, {:declare_links, 2})

    has_cache = Module.defines?(env.module, {:__cache__, 1})
    has_cache_many = Module.defines?(env.module, {:__cache_many__, 1})
    has_2arity_view = Module.defines?(env.module, {:prepare_for_view, 2})
    has_2arity_links = Module.defines?(env.module, {:declare_links, 2})
    has_1arity_links = Module.defines?(env.module, {:declare_links, 1})

    if has_cache and has_cache_many do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} defines both cache and cache_many; " <>
            "they are two calling conventions for the same slot — define only one"
    end

    # Generate fallback for __cache__ if not defined
    cache_fallback =
      cond do
        has_cache ->
          nil

        has_cache_many ->
          # Per-entity fallback for paths that don't batch: a batch of one.
          quote do
            def __cache__(data) do
              Map.get(__cache_many__([data]), Carve.Batch.entity_id(data))
            end
          end

        true ->
          quote do
            def __cache__(_data), do: %{}
          end
      end

    # Generate 2-arity fallback for prepare_for_view
    view_fallback =
      unless has_2arity_view do
        quote do
          def prepare_for_view(data, _cached), do: prepare_for_view(data)
        end
      end

    # Generate 2-arity fallback for declare_links
    links_fallback =
      cond do
        has_2arity_links ->
          nil

        has_1arity_links ->
          quote do
            def declare_links(data, _cached), do: declare_links(data)
          end

        true ->
          nil
      end

    # Default declare_links if no links macro was used
    declare_links_default =
      unless has_declare_links do
        quote do
          def declare_links(_), do: %{}
          def declare_links(_, _), do: %{}
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
      defp do_show(%{result: data, include: include}, cache_key) do
        cached = Map.get(Carve.Batch.warm(__MODULE__, [data], cache_key), data.id)

        result = prepare_for_view(data, cached)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, include, cache_key)
          else
            []
          end

        %{result: result, links: links}
      end

      defp do_show(%{result: data}, cache_key) do
        cached = Map.get(Carve.Batch.warm(__MODULE__, [data], cache_key), data.id)

        result = prepare_for_view(data, cached)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, nil, cache_key)
          else
            []
          end

        %{result: result, links: links}
      end

      # Internal index implementation
      defp do_index(%{result: data, include: include}, cache_key) when is_list(data) do
        cached_by_id = Carve.Batch.warm(__MODULE__, data, cache_key)

        results =
          Enum.map(data, fn item ->
            prepare_for_view(item, Map.get(cached_by_id, item.id))
          end)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, include, cache_key)
          else
            []
          end

        %{result: results, links: links}
      end

      defp do_index(%{result: data}, cache_key) when is_list(data) do
        cached_by_id = Carve.Batch.warm(__MODULE__, data, cache_key)

        results =
          Enum.map(data, fn item ->
            prepare_for_view(item, Map.get(cached_by_id, item.id))
          end)

        links =
          if unquote(has_declare_links) do
            Carve.Links.get_links_by_data(__MODULE__, data, %{}, nil, cache_key)
          else
            []
          end

        %{result: results, links: links}
      end

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
      unquote(view_fallback)
      unquote(links_fallback)
      unquote(declare_links_default)
    end
  end

  @doc """
  Caches expensive computations that are shared between `links` and `view`.

  The function receives the entity data and should return a map of precomputed values.
  This map is then passed as the second argument to `links` and `view` functions.
  Results are cached per entity (by module + id) within a single request.

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
    quote do
      def __cache__(data) do
        unquote(func).(data)
      end
    end
  end

  @doc """
  Batch sibling of `cache`: computes the cached data for every entity of a
  render in one call instead of once per entity, so a query inside it runs
  once per render instead of once per row.

  The function receives the list of entities about to be rendered and must
  return a map keyed by entity id. Each entity's value is passed to `links`
  and `view` as their second argument, exactly like `cache`. Ids missing
  from the returned map are cached as nil, and the view handles absence per
  entity. Defining both `cache` and `cache_many` in one view is a
  compile-time error.

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
    quote do
      def __cache_many__(entities) when is_list(entities) do
        unquote(func).(entities)
      end
    end
  end

  @doc """
  Defines the links for the current view.

  This macro allows you to specify how to generate links for the current entity.
  Accepts a 1-arity function, or a 2-arity function when used with `cache`.

  ## Parameters

  - `func`: A function that takes the entity data (and optionally cached data)
    and returns a map of links.

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
      2 ->
        quote do
          def declare_links(data, cached) do
            unquote(func).(data, cached)
          end
        end

      _ ->
        quote do
          def declare_links(data) do
            unquote(func).(data)
          end
        end
    end
  end

  @doc """
  Defines how to render the view for the current entity.

  This macro specifies how to format the entity data for JSON output.
  Accepts a 1-arity function, or a 2-arity function when used with `cache`.

  The `id` returned by the function is also used as the entity's envelope id,
  so a view can expose a custom identifier (e.g. a slug) instead of the
  hashed id. When the function returns no `id`, the envelope falls back to
  `hash(data.id)`.

  ## Parameters

  - `func`: A function that takes the entity data (and optionally cached data)
    and returns a map for JSON rendering.

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
    case detect_fn_arity(func) do
      2 ->
        quote do
          def prepare_for_view(data, cached) do
            view = unquote(func).(data, cached)

            %{
              id: Map.get(view, :id) || hash(data.id),
              type: type_name(),
              data: view
            }
          end
        end

      _ ->
        quote do
          def prepare_for_view(data) do
            view = unquote(func).(data)

            %{
              id: Map.get(view, :id) || hash(data.id),
              type: type_name(),
              data: view
            }
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
