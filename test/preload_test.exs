defmodule Carve.PreloadTest do
  use ExUnit.Case, async: true

  defmodule TestUser do
    defstruct [:id, :name, :team_id, :team]
  end

  defmodule TestTeam do
    defstruct [:id, :name]
  end

  defmodule TestPost do
    defstruct [:id, :title, :author_id, :author]
  end

  defmodule TeamJSON do
    use Carve.View, :team

    get fn id ->
      %TestTeam{id: id, name: "Team #{id}"}
    end

    view fn team ->
      %{
        id: hash(team.id),
        name: team.name
      }
    end
  end

  defmodule UserJSON do
    use Carve.View, :user

    get fn id ->
      send(self(), {:user_fetched, id})
      %TestUser{id: id, name: "User #{id}", team_id: id * 10, team: nil}
    end

    links fn user ->
      %{
        TeamJSON => user.team || user.team_id
      }
    end

    view fn user ->
      %{
        id: hash(user.id),
        name: user.name,
        team_id: TeamJSON.hash(user.team_id)
      }
    end
  end

  defmodule PostJSON do
    use Carve.View, :post

    get fn id ->
      send(self(), {:post_fetched, id})
      %TestPost{id: id, title: "Post #{id}", author_id: id * 2, author: nil}
    end

    links fn post ->
      %{
        UserJSON => post.author || post.author_id
      }
    end

    view fn post ->
      %{
        id: hash(post.id),
        title: post.title,
        author_id: UserJSON.hash(post.author_id)
      }
    end
  end

  describe "preloaded data handling" do
    test "uses preloaded data when available, skips database call" do
      preloaded_team = %TestTeam{id: 10, name: "Preloaded Team"}
      user = %TestUser{id: 1, name: "User 1", team_id: 10, team: preloaded_team}

      result = UserJSON.show(%{result: user})

      # Should not fetch team from database
      refute_received {:team_fetched, 10}

      assert length(result.links) == 1
      team_link = Enum.at(result.links, 0)
      assert team_link.type == :team
      assert team_link.data.name == "Preloaded Team"
    end

    test "fetches from database when preloaded data is nil" do
      user = %TestUser{id: 1, name: "User 1", team_id: 10, team: nil}

      result = UserJSON.show(%{result: user})

      assert length(result.links) == 1
      team_link = Enum.at(result.links, 0)
      assert team_link.type == :team
      assert team_link.data.name == "Team 10"
    end

    test "handles nested preloading correctly" do
      preloaded_team = %TestTeam{id: 20, name: "Nested Team"}
      preloaded_author = %TestUser{
        id: 2,
        name: "Author",
        team_id: 20,
        team: preloaded_team
      }
      post = %TestPost{id: 1, title: "Post 1", author_id: 2, author: preloaded_author}

      result = PostJSON.show(%{result: post})

      # Should not fetch author from database
      refute_received {:user_fetched, 2}

      assert length(result.links) == 2
      author_link = Enum.find(result.links, & &1.type == :user)
      team_link = Enum.find(result.links, & &1.type == :team)

      assert author_link.data.name == "Author"
      assert team_link.data.name == "Nested Team"
    end

    test "handles list of entities with mixed preloading" do
      preloaded_team = %TestTeam{id: 30, name: "Team A"}
      users = [
        %TestUser{id: 1, name: "User 1", team_id: 30, team: preloaded_team},
        %TestUser{id: 2, name: "User 2", team_id: 40, team: nil}
      ]

      result = UserJSON.index(%{result: users})

      assert length(result.links) == 2
      team_links = Enum.filter(result.links, & &1.type == :team)
      assert length(team_links) == 2

      preloaded_link = Enum.find(team_links, & &1.data.name == "Team A")
      fetched_link = Enum.find(team_links, & &1.data.name == "Team 40")

      assert preloaded_link != nil
      assert fetched_link != nil
    end
  end
end
