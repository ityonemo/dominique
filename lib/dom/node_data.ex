defmodule DOM.NodeData do
  @moduledoc false

  # NodeData is the thing stored in the private ETS table. Public node structs
  # are handles containing the owning server and the ID used to find this data.

  alias DOM.Node.Comment
  alias DOM.Node.Document
  alias DOM.Node.DocumentFragment
  alias DOM.Node.DocumentType
  alias DOM.Node.Element
  alias DOM.Node.Text

  @enforce_keys [:type]
  defstruct type: nil,
            local_name: nil,
            name: nil,
            public_id: nil,
            system_id: nil,
            value: nil,
            parent: nil,
            children: [],
            attributes: []

  @type node_type :: Comment | Document | DocumentFragment | DocumentType | Element | Text

  @type t :: %__MODULE__{
          type: node_type(),
          local_name: String.t() | nil,
          name: String.t() | nil,
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          value: String.t() | nil,
          parent: reference() | nil,
          children: [reference()],
          attributes: [{String.t(), String.t()}]
        }
end
