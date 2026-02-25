defmodule Carve.CarveTest do
  use ExUnit.Case, async: true

  defmodule TestPost do
    defstruct [:id, :title, :user_id]
  end

  defmodule TestUser do
    defstruct [:id, :name]
  end

  defmodule TestComment do
    defstruct [:id, :content]
  end

  defmodule TestComments do
    def get_by_post_id(post_id), do: [%TestComment{id: post_id * 10, content: "Comment for post #{post_id}"}]
  end

  defmodule UserJSON do
    use Carve.View, :user

    get fn id ->
      %TestUser{id: id, name: "User #{id}"}
    end

    view fn user ->
      %{
        id: hash(user.id),
        name: user.name
      }
    end
  end

  defmodule CommentJSON do
    use Carve.View, :comment

    get fn id ->
      %TestComment{id: id, content: "Comment #{id}"}
    end

    view fn comment ->
      %{
        id: hash(comment.id),
        content: comment.content
      }
    end
  end

  defmodule PostJSON do
    use Carve.View, :post

    links fn post ->
      %{
        UserJSON => post.user_id,
        CommentJSON => TestComments.get_by_post_id(post.id)
      }
    end

    get fn id -> %TestPost{id: id, title: "Post #{id}", user_id: id * 2} end

    view fn post ->
      %{
        id: hash(post.id),
        title: post.title,
        user_id: UserJSON.hash(post.user_id)
      }
    end
  end

  test "UserJSON get_by_id function is generated and works correctly" do
    assert %TestUser{id: 1, name: "User 1" } = UserJSON.get_by_id(1)
  end

  test "CommentJSON get_by_id function is generated and works correctly" do
    assert %TestComment{id: 10, content: "Comment 10" } = CommentJSON.get_by_id(10)
  end

  test "PostJSON get_by_id function is generated and works correctly" do
    assert %TestPost{id: 1, title: "Post 1", user_id: 2} = PostJSON.get_by_id(1)
  end

  test "hash function is generated and works correctly" do
    assert PostJSON.hash(1) == Carve.HashIds.encode(:post, 1)
    assert PostJSON.hash(%TestPost{id: 1}) == Carve.HashIds.encode(:post, 1)
  end

  test "prepare_for_view function is generated and works correctly" do
    post = %TestPost{id: 1, title: "Test Post", user_id: 2}
    result = PostJSON.prepare_for_view(post)
    expected = %{
      id: Carve.HashIds.encode(:post, 1),
      type: :post,
      data: %{
        id: Carve.HashIds.encode(:post, 1),
        title: "Test Post",
        user_id: Carve.HashIds.encode(:user, 2)
      }
    }
    assert result == expected
  end

  test "show function is generated and works correctly" do
    post = %TestPost{id: 1, title: "Test Post", user_id: 2}
    result = PostJSON.show(%{result: post})
    expected = %{
      result: %{
        id: Carve.HashIds.encode(:post, 1),
        type: :post,
        data: %{
          id: Carve.HashIds.encode(:post, 1),
          title: "Test Post",
          user_id: Carve.HashIds.encode(:user, 2)
        }
      },
      links: [
        %{type: :comment, id: Carve.HashIds.encode(:comment, 10), data: %{id: Carve.HashIds.encode(:comment, 10), content: "Comment for post 1"}},
        %{type: :user, id: Carve.HashIds.encode(:user, 2), data: %{id: Carve.HashIds.encode(:user, 2), name: "User 2"}}
      ]
    }
    assert result == expected
  end

  test "index function is generated and works correctly" do
    posts = [
      %TestPost{id: 1, title: "Test Post 1", user_id: 2},
      %TestPost{id: 2, title: "Test Post 2", user_id: 4}
    ]
    result = PostJSON.index(%{result: posts})
    expected = %{
      result: [
        %{
          id: Carve.HashIds.encode(:post, 1),
          type: :post,
          data: %{
            id: Carve.HashIds.encode(:post, 1),
            title: "Test Post 1",
            user_id: Carve.HashIds.encode(:user, 2)
          }
        },
        %{
          id: Carve.HashIds.encode(:post, 2),
          type: :post,
          data: %{
            id: Carve.HashIds.encode(:post, 2),
            title: "Test Post 2",
            user_id: Carve.HashIds.encode(:user, 4)
          }
        }
      ],
      links: [
        %{type: :comment, id: Carve.HashIds.encode(:comment, 10), data: %{id: Carve.HashIds.encode(:comment, 10), content: "Comment for post 1"}},
        %{type: :user, id: Carve.HashIds.encode(:user, 2), data: %{id: Carve.HashIds.encode(:user, 2), name: "User 2"}},
        %{type: :comment, id: Carve.HashIds.encode(:comment, 20), data: %{id: Carve.HashIds.encode(:comment, 20), content: "Comment for post 2"}},
        %{type: :user, id: Carve.HashIds.encode(:user, 4), data: %{id: Carve.HashIds.encode(:user, 4), name: "User 4"}}
      ]
    }
    assert result == expected
  end

  test "type_name function returns correct type" do
    assert :post == PostJSON.type_name()
  end

  test "links function handles single ID" do
    links = Carve.links(PostJSON, 1)
    assert length(links) == 2  # 1 user + 1 comment
    assert Enum.any?(links, & &1.type == :user)
    assert Enum.any?(links, & &1.type == :comment)
  end

  test "links function handles list of IDs" do
    links = Carve.links(PostJSON, [1, 2, 3])
    assert length(links) == 6  # (1 user + 1 comment) * 3 posts
    assert Enum.count(links, & &1.type == :user) == 3
    assert Enum.count(links, & &1.type == :comment) == 3
  end

  test "links function handles single data structure" do
    post_data = %TestPost{id: 1, title: "Test Post", user_id: 2}
    links = Carve.links(PostJSON, post_data)
    assert length(links) == 2  # 1 user + 1 comment
    assert Enum.any?(links, & &1.type == :user)
    assert Enum.any?(links, & &1.type == :comment)
  end

  test "links function handles list of data structures" do
    posts_data = [
      %TestPost{id: 1, title: "Test Post 1", user_id: 2},
      %TestPost{id: 2, title: "Test Post 2", user_id: 4}
    ]
    links = Carve.links(PostJSON, posts_data)
    assert length(links) == 4  # (1 user + 1 comment) * 2 posts
    assert Enum.count(links, & &1.type == :user) == 2
    assert Enum.count(links, & &1.type == :comment) == 2
  end

  test "links function returns empty list for invalid input" do
    assert Carve.links(PostJSON, "invalid") == []
    assert Carve.links(PostJSON, [1, "invalid", 3]) == []
    #assert Carve.links(PostJSON, [%{invalid: "data"}, %TestPost{id: 1, title: "Valid", user_id: 1}]) == []
  end

  describe "parse_include/1" do
    test "returns nil when include parameter is not specified" do
      params = %{}
      assert Carve.parse_include(params) == nil
    end

    test "returns an empty list when include parameter is an empty string" do
      params = %{"include" => ""}
      assert Carve.parse_include(params) == []
    end

    test "returns a list of atoms for a single include" do
      params = %{"include" => "user"}
      assert Carve.parse_include(params) == [:user]
    end

    test "returns a list of atoms for multiple includes" do
      params = %{"include" => "user,comment,post,post,user"}
      assert Carve.parse_include(params) == [:user, :comment, :post]
    end

    test "trims whitespace from includes" do
      params = %{"include" => " user , comment , post "}
      assert Carve.parse_include(params) == [:user, :comment, :post]
    end

    test "ignores empty segments in include string" do
      params = %{"include" => "user,,comment,,,post"}
      assert Carve.parse_include(params) == [:user, :comment, :post]
    end

    test "returns an empty list for only commas" do
      params = %{"include" => ",,,"}
      assert Carve.parse_include(params) == []
    end

    test "raises an error for non-existent atoms" do
      params = %{"include" => "user,non_existent_type,comment"}
      assert_raise ArgumentError, fn ->
        Carve.parse_include(params)
      end
    end
  end
end
