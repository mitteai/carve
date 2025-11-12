defmodule Carve.LinksTest do
  use ExUnit.Case, async: true
  alias Carve.Links

  def data do
    %{
      users: %{
	1 => %{id: 1, posts: [1001, 1002, 1003]},
	2 => %{id: 2, posts: [2001, 2002, 2003]}
      },
      posts: %{
	1001 => %{
          id: 1001,
          title: "Post 1001",
          content: "Content of post 1001",
          user_id: 1,
          comments: [100_101, 100_102], # Added second comment
          tags: [2002, 2003]
	},
	1002 => %{
          id: 1002,
          title: "Post 1002",
          content: "Content of post 1002",
          user_id: 1,
          comments: [100_201, 100_202], # Added second comment
          tags: [2004, 2005]
	},
	1003 => %{
          id: 1003,
          title: "Post 1003",
          content: "Content of post 1003",
          user_id: 1,
          comments: [100_301, 100_302], # Added second comment
          tags: [2006, 2007]
	},
	2001 => %{
          id: 2001,
          title: "Post 2001",
          content: "Content of post 2001",
          user_id: 2,
          comments: [200_101, 200_102], # Added second comment
          tags: [4002, 4003]
	}
      },
      comments: %{
	# First comments for each post
	100_101 => %{id: 100_101, content: "Comment 100101", post_id: 1001, user_id: 1},
	100_201 => %{id: 100_201, content: "Comment 100201", post_id: 1002, user_id: 1},
	100_301 => %{id: 100_301, content: "Comment 100301", post_id: 1003, user_id: 1},
	200_101 => %{id: 200_101, content: "Comment 200101", post_id: 2001, user_id: 2},
	# Second comments for each post
	100_102 => %{id: 100_102, content: "Comment 100102", post_id: 1001, user_id: 1},
	100_202 => %{id: 100_202, content: "Comment 100202", post_id: 1002, user_id: 1},
	100_302 => %{id: 100_302, content: "Comment 100302", post_id: 1003, user_id: 1},
	200_102 => %{id: 200_102, content: "Comment 200102", post_id: 2001, user_id: 2}
      },
      tags: %{
	2002 => %{id: 2002, name: "Tag 2002", posts: [1001, 1002]},
	2003 => %{id: 2003, name: "Tag 2003", posts: [1003, 2001]},
	2004 => %{id: 2004, name: "Tag 2004", posts: [1001, 1002]},
	2005 => %{id: 2005, name: "Tag 2005", posts: [1001, 1002]},
	2006 => %{id: 2006, name: "Tag 2006", posts: [1001, 1002]},
	2007 => %{id: 2007, name: "Tag 2007", posts: [1001, 1002]},
	4002 => %{id: 4002, name: "Tag 4002", posts: [1001, 1002]},
	4003 => %{id: 4003, name: "Tag 4003", posts: [1001, 1002]}
      }
    }
  end



  defmodule UserJSON do
    use Carve.View, :user

    get(fn id ->
      user = get_in(Carve.LinksTest.data(), [:users, id])

      if user do
        %{id: id, name: "User #{id}", email: "user#{id}@example.com"}
      end
    end)

    view(fn user ->
      %{id: hash(user.id), name: user.name, email: user.email}
    end)

    links(fn user ->
      %{Carve.LinksTest.PostJSON => get_in(Carve.LinksTest.data(), [:users, user.id, :posts])}
    end)
  end

  defmodule PostJSON do
    use Carve.View, :post

    get(fn id ->
      case get_in(Carve.LinksTest.data(), [:posts, id]) do
        nil ->
          nil

        post ->
          %{
            id: post.id,
            title: post.title,
            content: post.content,
            user_id: post.user_id,
            tag_ids: post.tags
          }
      end
    end)

    view(fn post ->
      %{
        id: hash(post.id),
        title: post.title,
        content: post.content,
        user_id: Carve.LinksTest.UserJSON.hash(post.user_id),
        tag_ids: Enum.map(post.tag_ids, &Carve.LinksTest.TagJSON.hash/1)
      }
    end)

    links(fn post ->
      post_data = get_in(Carve.LinksTest.data(), [:posts, post.id])

      %{
        Carve.LinksTest.UserJSON => post_data.user_id,
        Carve.LinksTest.CommentJSON => post_data.comments,
        Carve.LinksTest.TagJSON => post_data.tags
      }
    end)
  end

  defmodule CommentJSON do
    use Carve.View, :comment

    get(fn id ->
      case get_in(Carve.LinksTest.data(), [:comments, id]) do
        nil ->
          nil

        comment ->
          %{id: id, content: comment.content, post_id: comment.post_id, user_id: comment.user_id}
      end
    end)

    view(fn comment ->
      %{
        id: hash(comment.id),
        content: comment.content,
        post_id: Carve.LinksTest.PostJSON.hash(comment.post_id),
        user_id: Carve.LinksTest.UserJSON.hash(comment.user_id)
      }
    end)

    links(fn comment ->
      comment_data = get_in(Carve.LinksTest.data(), [:comments, comment.id])

      %{
        Carve.LinksTest.PostJSON => comment_data.post_id,
        Carve.LinksTest.UserJSON => comment_data.user_id
      }
    end)
  end

  defmodule TagJSON do
    use Carve.View, :tag

    get(fn id ->
      case get_in(Carve.LinksTest.data(), [:tags, id]) do
        nil -> nil
        tag -> %{id: id, name: tag.name}
      end
    end)

    view(fn tag ->
      %{
        id: hash(tag.id),
        name: tag.name
      }
    end)

    links(fn tag ->
      %{
        Carve.LinksTest.PostJSON => get_in(Carve.LinksTest.data(), [:tags, tag.id, :posts])
      }
    end)
  end

  defmodule ArbitraryKeyJSON do
    use Carve.View, :arbitrary_key

    get(fn {key, value} ->
      %{key => value}
    end)

    view(fn data ->
      data
    end)

    links(fn _data ->
      %{
        Carve.LinksTest.UserJSON => 1
      }
    end)
  end

  test "get_links_by_id returns correct links for a user" do
    links = Links.get_links_by_id(UserJSON, 1, %{}, [:post])

    assert length(links) == 3
    assert Enum.all?(links, fn link -> link.type == :post end)
    assert Enum.map(links, & &1.id) == Enum.map([1001, 1002, 1003], &PostJSON.hash/1)
  end

  test "get_links_by_data returns correct links for a post" do
    post_data = %{
      id: 1001,
      title: "Post 1001",
      content: "Content of post 1001",
      user_id: 1,
      tag_ids: [2002, 2003]
    }

    links = Links.get_links_by_data(PostJSON, post_data, %{}, [:user, :comment, :tag])

    # 1 user + 2 comments + 2 tags
    assert length(links) == 5
    assert Enum.count(links, &(&1.type == :user)) == 1
    assert Enum.count(links, &(&1.type == :comment)) == 2
    assert Enum.count(links, &(&1.type == :tag)) == 2
  end



  test "get_links_by_id handles circular references without infinite loops" do
    links = Links.get_links_by_id(CommentJSON, 100_101, %{}, [:post, :user])

    assert length(links) == 4
    assert Enum.any?(links, &(&1.type == :post))
    assert Enum.any?(links, &(&1.type == :user))
  end

  test "get_links_by_id returns empty list for nil id" do
    assert Links.get_links_by_id(UserJSON, nil) == []
  end

  test "get_links_by_data returns empty list for nil data" do
    assert Links.get_links_by_data(UserJSON, nil) == []
  end

  test "get_links_by_data returns empty list for non-map data" do
    assert Links.get_links_by_data(UserJSON, "Not a map") == []
  end

  test "get_links_by_id handles a list of IDs" do
    links = Links.get_links_by_id(TagJSON, [2002, 2003, 2004], %{}, [:post])

    #IO.inspect links, label: "links"

    assert length(links) == 4
    assert Enum.all?(links, &(&1.type == :post))
  end

  test "get_links_by_data handles a list of data items" do
    post_data_list = [
      %{id: 1001, title: "Post 1001", content: "Content 1", user_id: 1, tag_ids: [2002, 2003]},
      %{id: 1002, title: "Post 1002", content: "Content 2", user_id: 1, tag_ids: [2004, 2005]}
    ]

    links = Links.get_links_by_data(PostJSON, post_data_list, %{},[:user, :comment, :tag])

    #IO.inspect links

    # (1 user + 2 comments + 2 tags) * 2 posts - 1 duplicate user
    assert length(links) == 9
    assert Enum.count(links, &(&1.type == :user)) == 1
    assert Enum.count(links, &(&1.type == :comment)) == 4
    assert Enum.count(links, &(&1.type == :tag)) == 4
  end

  test "get_links_by_id handles non-existent IDs gracefully" do
    links = Links.get_links_by_id(UserJSON, nil)
    assert links == []
  end

  test "get_links_by_data handles maps with arbitrary keys" do
    arbitrary_key = "foo"
    arbitrary_key_data = %{arbitrary_key => "bar"}
    links = Links.get_links_by_data(ArbitraryKeyJSON, arbitrary_key_data, %{}, [:user])

    assert length(links) == 1
    assert Enum.at(links, 0).type == :user
    assert Enum.at(links, 0).id == UserJSON.hash(1)
  end

  test "get_links_by_id handles arbitrary key-value pair IDs" do
    arbitrary_key = "foo"
    links = Links.get_links_by_id(ArbitraryKeyJSON, {arbitrary_key, "bar"}, %{}, [:user])

    assert length(links) == 1
    assert Enum.at(links, 0).type == :user
    assert Enum.at(links, 0).id == UserJSON.hash(1)
  end

  test "get_links_by_id with whitelist returns only whitelisted links" do
    links = Links.get_links_by_id(UserJSON, 1, %{}, [:post])

    assert length(links) == 3
    assert Enum.all?(links, fn link -> link.type == :post end)
  end

  test "get_links_by_data with whitelist returns only whitelisted links" do
    post_data = %{
      id: 1001,
      title: "Post 1001",
      content: "Content of post 1001",
      user_id: 1,
      tag_ids: [2002, 2003]
    }

    links = Links.get_links_by_data(PostJSON, post_data, %{}, [:user, :comment])

    # 1 user + 2 comments (tags filtered out)
    assert length(links) == 3
    assert Enum.count(links, &(&1.type == :user)) == 1
    assert Enum.count(links, &(&1.type == :comment)) == 2
    refute Enum.any?(links, &(&1.type == :tag))
  end

  test "get_links_by_id with empty whitelist returns no links" do
    links = Links.get_links_by_id(UserJSON, 1, %{}, [])

    assert links == []
  end

  test "get_links_by_data with empty whitelist returns no links" do
    post_data = %{
      id: 1001,
      title: "Post 1001",
      content: "Content of post 1001",
      user_id: 1,
      tag_ids: [2002, 2003]
    }

    links = Links.get_links_by_data(PostJSON, post_data, %{}, [])

    assert links == []
  end

  test "get_links_by_data handles a list of data items with whitelist" do
    post_data_list = [
      %{id: 1001, title: "Post 1001", content: "Content 1", user_id: 1, tag_ids: [2002, 2003]},
      %{id: 1002, title: "Post 1002", content: "Content 2", user_id: 1, tag_ids: [2004, 2005]}
    ]

    links = Links.get_links_by_data(PostJSON, post_data_list, %{}, [:user, :comment])

    # (1 user + 2 comments) * 2 posts - 1 duplicate user
    assert length(links) == 5
    assert Enum.count(links, &(&1.type == :user)) == 1
    assert Enum.count(links, &(&1.type == :comment)) == 4
    refute Enum.any?(links, &(&1.type == :tag))
  end

  describe "chained linking" do
    defmodule DraftVersionJSON do
      use Carve.View, :draft_version

      links(fn _draft ->
        %{}
      end)

      get(fn id ->
        %{id: id, version: "Draft #{id}"}
      end)

      view(fn draft ->
        %{
          id: hash(draft.id),
          version: draft.version
        }
      end)
    end

    defmodule ImageVersionJSON do
      use Carve.View, :image_version

      links(fn version ->
        %{
          DraftVersionJSON => version.draft_id
        }
      end)

      get(fn id ->
        %{id: id, name: "Version #{id}", draft_id: id * 2}
      end)

      view(fn version ->
        %{
          id: hash(version.id),
          name: version.name
        }
      end)
    end

    defmodule ImageJSON do
      use Carve.View, :image

      links(fn image ->
        %{
          ImageVersionJSON => image.version_id
        }
      end)

      get(fn id ->
        %{id: id, name: "Image #{id}", version_id: id * 3}
      end)

      view(fn image ->
        %{
          id: hash(image.id),
          name: image.name,
          version_id: ImageVersionJSON.hash(image.version_id)
        }
      end)
    end

    defmodule ImageSetJSON do
      use Carve.View, :image_set

      links(fn set ->
        %{
          ImageJSON => set.image_id
        }
      end)

      get(fn id ->
        %{id: id, name: "Set #{id}", image_id: id * 5}
      end)

      view(fn set ->
        %{
          id: hash(set.id),
          name: set.name,
          image_id: ImageJSON.hash(set.image_id)
        }
      end)
    end

    test "includes all nested linked entities when types specified" do
      image_set = %{id: 1, name: "Test Set", image_id: 5}

      links =
        Links.get_links_by_data(ImageSetJSON, image_set, %{}, [
          :image,
          :image_version,
          :draft_version
        ])

      # Should have image + its version + draft version
      assert length(links) == 3
      assert Enum.count(links, &(&1.type == :image)) == 1
      assert Enum.count(links, &(&1.type == :image_version)) == 1
      assert Enum.count(links, &(&1.type == :draft_version)) == 1
    end
  end
end
