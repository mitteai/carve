defmodule Carve.SlugIdTest do
  use ExUnit.Case, async: true

  defmodule TestNode do
    defstruct [:id, :slug, :label]
  end

  defmodule TestFlow do
    defstruct [:id, :name, :node_ids]
  end

  defmodule NodeJSON do
    use Carve.View, :nodes

    get fn id ->
      %TestNode{id: id, slug: "node-#{id}", label: "Node #{id}"}
    end

    view fn node ->
      %{
        # nodes are identified by slug everywhere — flow docs, selection, input
        # keys, submit messages — so the API id IS the slug
        id: node.slug || hash(node.id),
        label: node.label
      }
    end
  end

  defmodule FlowJSON do
    use Carve.View, :flow

    links fn flow ->
      %{NodeJSON => flow.node_ids}
    end

    get fn id -> %TestFlow{id: id, name: "Flow #{id}", node_ids: [id * 10]} end

    view fn flow ->
      %{
        id: hash(flow.id),
        name: flow.name
      }
    end
  end

  test "view-provided slug is used as the id of the entity envelope and its data" do
    node = %TestNode{id: 1, slug: "intro", label: "Intro"}
    result = NodeJSON.show(%{result: node})

    assert result.result == %{
             id: "intro",
             type: :nodes,
             data: %{id: "intro", label: "Intro"}
           }
  end

  test "falls back to hashed id when slug is nil" do
    node = %TestNode{id: 1, slug: nil, label: "Unnamed"}
    result = NodeJSON.show(%{result: node})

    hashed = Carve.HashIds.encode(:nodes, 1)

    assert result.result == %{
             id: hashed,
             type: :nodes,
             data: %{id: hashed, label: "Unnamed"}
           }
  end

  test "index uses the slug as id for each entity" do
    nodes = [
      %TestNode{id: 1, slug: "intro", label: "Intro"},
      %TestNode{id: 2, slug: nil, label: "Unnamed"}
    ]

    result = NodeJSON.index(%{result: nodes})

    assert result.result == [
             %{id: "intro", type: :nodes, data: %{id: "intro", label: "Intro"}},
             %{
               id: Carve.HashIds.encode(:nodes, 2),
               type: :nodes,
               data: %{id: Carve.HashIds.encode(:nodes, 2), label: "Unnamed"}
             }
           ]
  end

  test "linked entities carry the slug as id in the links payload" do
    flow = %TestFlow{id: 1, name: "Onboarding", node_ids: [10]}
    result = FlowJSON.show(%{result: flow})

    assert result.links == [
             %{
               type: :nodes,
               id: "node-10",
               data: %{id: "node-10", label: "Node 10"}
             }
           ]
  end
end
