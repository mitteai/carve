# Carve

Declare the view & relationships like this:

```ex
use Carve.View, :user

view fn user ->
  %{
    id: hash(user.id),
    name: user.name
  }
end

links fn user ->
  %{
    TeamJSON => user.team_id,
    ProfileJSON => user.profile_id,
    PostsJSON => fn -> Posts.get_by_user_id(user.id) end
   }
end
```

Get JSON endpoint views (`index`, `show`) with complete & linked data back in single request:

```js
// GET /users/xyz?include=profile,team
{
  "result": {
    "id": "D3Wcorr0oa",
    "type": "user",
    "data": { ... }
  },
  "links": [
    {
      "id": "Xk9Lp2Rr4m",
      "type": "team",
      "data": { ... }
    },
    {
      "id": "Bz7Jt5Yq1n",
      "type": "profile",
      "data": { ... }
    }
  ]
}
```

Features:

* Automatic endpoint generation (index/show)
* Smart data loading (lazy/eager)
* Relationship resolution
* Response structuring
* ID hashing (123 → Xk9Lp2R)

See also: [Bind](https://github.com/azer/bind)

## Installation

Add `carve` to your list of dependencies in `mix.exs`:


```elixir
def deps do
  [
    {:carve, "~> 0.1.0"}
  ]
end
```


To configure custom hashing salt, add to `config.exs`:

```elixir
config :carve,
  salt: "your-secret-salt",
  min_length: 10
```

## Usage

In your Phoenix JSON view, just declare how your endpoint should look like:

```elixir
defmodule UserJSON do
    use Carve.View, :user

    view fn user ->
      %{
        id: hash(user.id), # provided by Carve.View, encodes numerical ID (123) with an entity-specific salt (D3Wcorr0oa).
        name: user.name
      }
    end
end
```

And that's it -- this macro will make `index(%{ result: users })` and `show(%{ result: user })` methods available for your controller.

Of course, just formatting the view alone is not Carvers only point; you can declare the links of each view, and Carve will automatically output them for the client:

```elixir
defmodule UserJSON do
    use Carve.View, :user

    # Return the links of a given user as ViewModule => id
    links fn user ->
        %{
            FooWeb.TeamJSON => user.team_id, # You can also pass list of ids or the Ecto record(s)
            FooWeb.ProfileJSON => user.profile_id
        }
    end

    # Provide a method to retrieve user by id. This will be used by Carve to render links automatically.
    get fn id ->
        Foo.Users.get_by_id!(id)
    end

    view fn user ->
      %{
        id: hash(user.id),
        team_id: FooWeb.TeamJSON.hash(user.team_id),
        profile_id: FooWeb.ProfileJSON.hash(user.profile_id),
        name: user.name
      }
    end
end
```

After activating `show` and `index` methods in the controller:

```elixir
render(conn, :index, result: requests) # or render(conn, :show, result: record)
```

Example response Carve will render for this view:

```json
{
  "result": {
    "id": "D3Wcorr0oa",
    "type": "user",
    "data": {
      "id": "D3Wcorr0oa",
      "name": "John Doe",
      "team_id": "Xk9Lp2Rr4m",
      "profile_id": "Bz7Jt5Yq1n"
    }
  },
  "links": [
    {
      "id": "Xk9Lp2Rr4m",
      "type": "team",
      "data": {
        "id": "Xk9Lp2Rr4m",
        "name": "Engineering Team",
        "description": "Our awesome engineering team"
      }
    },
    {
      "id": "Bz7Jt5Yq1n",
      "type": "profile",
      "data": {
        "id": "Bz7Jt5Yq1n",
        "bio": "Software engineer passionate about Elixir",
        "avatar_url": "https://example.com/avatars/johndoe.jpg"
      }
    }
  ]
}
```

### Example Controller

Carve provides a flexible way to control which linked data is included in the response. This is achieved through the include parameter. Here's an example of how to use Carve in your Phoenix controllers:

```elixir
defmodule UserController do
  use FooWeb, :controller

  def show(conn, %{"id" => id} = params) do
    user = Foo.Users.get_user!(id)
    include = Carve.parse_include(params)

    render(conn, :show, %{ result: user, include: include })
  end

  def index(conn, params) do
    users = Foo.Users.list_users()
    include = Carve.parse_include(params)

    render(conn, :index, %{ result: users, include: include })
  end
end
```

This example also shows reading & parsing the `include` parameter, which can be one of following:

* Not specified (`GET  /api/users`): All link types are included.
* Empty list (`GET /api/users?included=`): No link types are included.
* Custom types: (`GET /api/users/123?include=team,profile`): Include comma-separated link types only.


## Links

Carve allows you to define links between resources directly in the view. When a user fetches a resource, all necessary context is automatically included in the response:

```elixir
defmodule UserJSON do
  use Carve.View, :user

  links fn user ->
    %{
      TeamJSON => user.team_id,
      CompanyJSON => user.company_id
    }
  end
end
```

Now, a request to `/api/users/123` automatically includes linked team and company in a single response. Client gets all data needed without extra requests.

Unlike GraphQL which requires defining a schema and writing resolvers for each field, Carve allows you to define links between resources directly in the view. When a user fetches a resource, all necessary context is automatically included in the response:

```elixir
defmodule UserJSON do
  use Carve.View, :user

  # Declare which other resources this view links to
  links fn user ->
    %{
      TeamJSON => user.team_id,       # User's team - needed to render user profile
      CompanyJSON => user.company_id  # User's company - needed for permissions
    }
  end
end
```

### Include Parameter

Carve allows selective loading so the API client can optimize the response size & number of DB queries.

You can enable it in the controller:

```ex
def show(conn, params) do
  user = Users.get!(params["id"])

  # Parses ?include=team,post into [:team, :post]
  include = Carve.parse_include(params)

  render(conn, :show, %{
    result: user,
    include: include
  })
end
```

The client now can specify what links should be included in the API.

```
GET /api/users/123                    # Include all links
GET /api/users/123?include=           # Include no links
GET /api/users/123?include=team       # Include only team links
GET /api/users/123?include=team,post  # Include team and post links
```

Example response with `?include=team`:

```json
{
  "result": {
    "id": "D3Wcorr0oa",
    "type": "user",
    "data": {
      "id": "D3Wcorr0oa",
      "name": "John Doe",
      "team_id": "Xk9Lp2Rr4m"
    }
  },
  "links": [
    {
      "id": "Xk9Lp2Rr4m",
      "type": "team",
      "data": {
        "id": "Xk9Lp2Rr4m",
        "name": "Engineering Team"
      }
    }
  ]
}
```

### Lazy Links

When using `links`, even if a link type is filtered out via `?include=`, database queries are still executed for all linked resources.

For expensive queries, you can simply declare lazy links;

```elixir
defmodule UserJSON do
  use Carve.View, :user

  links fn user ->
    %{
      TeamJSON => user.team_id, # Included by default
      CommentJSON => fn -> Comments.by_user_id(user.id) end # Called & included only if specified explicitly
    }
  end
end
```

The lazy function is evaluated only when requested in the include param:

```
GET /api/users/123                # No comments query executed
GET /api/users/123?include=comments  # Query executed for fetching comments
```

Both return same JSON format, just with different loading behavior. The function should return a tuple of `{ViewModule, id_or_ids}`.

### Large datasets

For relationships that could return large datasets, create dedicated endpoints instead of links:

```elixir
#  ✅ Good: /api/users/123 returns user with essential context
links fn user ->
  %{TeamJSON => user.team_id}
end

# ✅ Good: Get user's comments via dedicated endpoint
GET /api/users/123/comments?page=1

# ❌ Bad: Don't use links for large collections
links fn user ->
  %{
    CommentsJSON => Comments.by_user_id(user.id)  # Could be thousands
  }
end
```

## Preload support

Return preloaded association in your views, falling back to id using `data_or_id` macro:

```elixir
 links fn image ->
    %{
      UserJSON => data_or_id(image.user, image.user_id),
    }
  end
```

Example controller:

```elixir
def index(conn, params) do
    assets =
      MyApp.Assets.Asset
      |> MyApp.Assets.scope_to_user(conn.assigns.current_user.id)
      |> MyApp.Assets.scope_active()
      |> MyApp.Repo.all()
      |> MyApp.Repo.preload([:current_version, user: :subscription])

    render(conn, :index, %{result: assets, include: Carve.parse_include(params)})
  end
```

## Caching

Carve includes request-scoped caching enabled by default, using [cachex](https://github.com/whitfin/cachex) under the hood. Each linked resource is stored in the cache for 100ms by default.

To disable caching:

```
```elixir
config :carve, Carve.Config,
  enable_cache: false
```

## How does it work?

* Carve macros create view functions `index(%{ result: users })` and `show(%{ result: user })`
* Controller calls these view functions
* Carve pulls the list of links for given data (list or single record)
* Carve calls the `get_by_id` (`get` macro expanded) and `prepare_for_view` (`view` macro expanded) functions for each link
* The final expanded list of links get flattened & cleaned, returned to user with the main result: `{ result: {} || [], links: [] }`


## API

More detailed API docs are available at [https://hexdocs.pm/carve/Carve.html](https://hexdocs.pm/carve/Carve.html)

## Q&A

### Why?

1. **Performance vs Flexibility**
   - REST: Simple but requires multiple roundtrips
   - GraphQL: Flexible but complex infrastructure
   - Carve: Single request, zero infrastructure

2. **Development Speed**
   - Every new feature typically requires:
     - New endpoint handlers
     - New view logic
     - New data fetching code
     - New state management
   - Carve eliminates all of this with one view definition

3. **Maintainability**
   - As applications grow, data dependencies become complex
   - Changes ripple through multiple endpoints
   - State management becomes increasingly difficult
   - Carve centralizes this complexity in view definitions

### How does it compare to GraphQL?

GraphQL
- Requires schema definition (IDL) and resolver functions for each field
- Client needs to learn query language and construct queries
- Each query is a unique POST request, making caching challenging
- N+1 query problems require manual batching/dataloader setup
- Field-level authorization adds complexity
- Additional infrastructure needed (query validation, complexity limits, persisted queries)

Carve
- Simple & small lbirary, uses your existing Phoenix views and controllers
- Compatible with other libraries like [Bind](https://github.com/azer/bind)
- REST-like URLs with simple `?include=` parameter
- Standard GET requests, works with HTTP caching out of the box
- Automatic batching of related data queries
- Resource-level authorization using your existing Phoenix plugs
- Zero additional infrastructure required
