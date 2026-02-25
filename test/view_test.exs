defmodule Carve.ViewTest do
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

  test "get_by_id function is generated and works correctly" do
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

test "show function with include parameter works correctly" do
    post = %TestPost{id: 1, title: "Test Post", user_id: 2}
    result = PostJSON.show(%{result: post, include: [:user]})
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
        %{type: :user, id: Carve.HashIds.encode(:user, 2), data: %{id: Carve.HashIds.encode(:user, 2), name: "User 2"}}
      ]
    }
    assert result == expected
  end

  test "show function with empty include parameter returns no links" do
    post = %TestPost{id: 1, title: "Test Post", user_id: 2}
    result = PostJSON.show(%{result: post, include: []})
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
      links: []
    }
    assert result == expected
  end

  test "index function with include parameter works correctly" do
    posts = [
      %TestPost{id: 1, title: "Test Post 1", user_id: 2},
      %TestPost{id: 2, title: "Test Post 2", user_id: 4}
    ]
    result = PostJSON.index(%{result: posts, include: [:user]})
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
        %{type: :user, id: Carve.HashIds.encode(:user, 2), data: %{id: Carve.HashIds.encode(:user, 2), name: "User 2"}},
        %{type: :user, id: Carve.HashIds.encode(:user, 4), data: %{id: Carve.HashIds.encode(:user, 4), name: "User 4"}}
      ]
    }
    assert result == expected
  end

  test "index function with empty include parameter returns no links" do
    posts = [
      %TestPost{id: 1, title: "Test Post 1", user_id: 2},
      %TestPost{id: 2, title: "Test Post 2", user_id: 4}
    ]
    result = PostJSON.index(%{result: posts, include: []})
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
      links: []
    }
    assert result == expected
  end

  test "show function with multiple includes works correctly" do
    post = %TestPost{id: 1, title: "Test Post", user_id: 2}
    result = PostJSON.show(%{result: post, include: [:user, :comment]})
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

  test "index function with multiple includes works correctly" do
    posts = [
      %TestPost{id: 1, title: "Test Post 1", user_id: 2},
      %TestPost{id: 2, title: "Test Post 2", user_id: 4}
    ]
    result = PostJSON.index(%{result: posts, include: [:user, :comment]})
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
end
