defmodule DOM.HTML.TreeBuilder do
  @moduledoc false

  # The WHATWG HTML tree-construction algorithm (§13.2.6): a stateful
  # insertion-mode state machine that reduces the tokenizer's token stream into a
  # DOM tree. Public entry is DOM.HTML.parse/1.
  #
  # This is a faithful transcription of the spec: each `process(mode, token,
  # state)` clause corresponds to one (or a group of identical) token-rules of an
  # insertion mode, cited by section number in a comment. Rules with identical
  # actions are grouped. It is a pure reduce (not a GenServer); it drives the DOM
  # GenServer through the public build API.
  #
  # Spec: https://html.spec.whatwg.org/multipage/parsing.html#tree-construction

  alias DOM.Element
  alias DOM.HTML.Token
  alias DOM.Node

  defstruct [
    :document,
    :mode,
    :original_mode,
    :head,
    :form,
    :context,
    open_elements: [],
    active_formatting: [],
    template_modes: [],
    contents: %{},
    frameset_ok: true,
    foster_parenting: false,
    pending_table_chars: [],
    namespaces: %{}
  ]

  # `template_modes` is the stack of template insertion modes (§13.2.4.4); its
  # head is the "current template insertion mode". `contents` maps a template
  # element handle to its content DocumentFragment handle (so insertions into a
  # template are redirected into its content).

  # `context` is the fragment-parsing context element (a `%DOM.Node{}` handle) or
  # nil for a whole-document parse. It drives the fragment-case branches of
  # "reset the insertion mode appropriately" and "adjusted current node".

  # `namespaces` maps a foreign element handle to its namespace atom (:svg |
  # :mathml). HTML elements are not stored — the default is :html. Populated when
  # a foreign element is inserted; used by the tree-construction dispatcher to
  # decide HTML-content vs. foreign-content processing.

  # The list of active formatting elements (§13.2.4.3). Entries are either the
  # atom :marker or a {element_handle, token} tuple (the token is retained to
  # recreate the element during reconstruction and to compare attributes for the
  # Noah's Ark clause). Most-recent entry is the list head.

  # Rawtext/RCDATA elements the "in head" mode parses with the generic rawtext
  # algorithm (switch to the "text" insertion mode). textarea/xmp/iframe/noembed
  # are in-body-only and have their own "in body" rules — they must NOT be
  # consumed here, else they land in <head> instead of implying a <body>.
  @head_rawtext ~w(style script noframes noscript title)

  # Void elements: a start tag with no children and no end tag.
  @void ~w(area base br col embed hr img input keygen link meta param source track wbr)

  # "generate implied end tags" (§13.2.6.3): while the current node is one of
  # these, pop it. An optional exception name is excluded from the set.
  @implied_end_tags ~w(dd dt li optgroup option p rb rp rt rtc)

  # "have an element in scope" default scope set (§13.2.4.2): elements that
  # terminate the upward scope search. (Foreign-content members deferred to
  # tier 5; all HTML-namespace here since we have no namespace model yet.)
  @scope_markers ~w(applet caption html table td th marquee object template)

  # "in button scope" adds "button"; "in list item scope" adds "ol"/"ul".
  @button_scope_markers ["button" | @scope_markers]
  @list_item_scope_markers ~w(ol ul) ++ @scope_markers

  # "have an element in table scope" (§13.2.4.2): terminates only on html, table,
  # template — used by the table insertion modes.
  @table_scope_markers ~w(html table template)

  # The formatting elements handled by the active-formatting-list / adoption
  # agency machinery (§13.2.6.4.7). "a" and "nobr" have their own start-tag rules;
  # this group shares one.
  @formatting ~w(b big code em font i s small strike strong tt u)

  # The table-related insertion modes: a <select> opened while in one of these
  # switches to "in select in table" rather than "in select" (§13.2.6.4.7).
  @table_modes [:in_table, :in_caption, :in_table_body, :in_row, :in_cell]

  @doc "Builds a document tree from a decoded token list (§13.2.6.4)."
  @spec build([struct()]) :: Node.t()
  def build(tokens) do
    state = %__MODULE__{document: DOM.new(), mode: :initial}
    tokens |> Enum.reduce(state, &step/2) |> eof() |> Map.fetch!(:document)
  end

  @doc """
  The HTML fragment parsing algorithm (§13.4): parse `tokens` as the contents of
  a `context` element (`%{name, namespace}`). Returns the synthetic `html` root
  element whose children are the fragment nodes (serialize its children to get
  the fragment outline). Does NOT wire into `inner_html` — that is a later step.
  """
  @spec build_fragment([struct()], %{name: String.t(), namespace: atom()}) :: Node.t()
  def build_fragment(tokens, context) do
    document = DOM.new()
    root = DOM.create_element(document, "html")
    Node.append_child(document, root)

    context_el = DOM._create_element_ns(document, context.name, context.namespace, [])

    state =
      %__MODULE__{
        document: document,
        open_elements: [root],
        context: context_el,
        namespaces: fragment_namespaces(context, context_el),
        form: nil
      }
      |> reset_insertion_mode()

    tokens
    |> Enum.reduce(state, &step/2)
    |> eof()

    root
  end

  # Record the context element's namespace so the dispatcher treats it correctly
  # while its children are being parsed (foreign context → foreign content).
  defp fragment_namespaces(%{namespace: :html}, _context_el), do: %{}
  defp fragment_namespaces(%{namespace: ns}, context_el), do: %{context_el => ns}

  # The "tree construction dispatcher" (§13.2.6): route each token to HTML-content
  # processing or foreign-content processing based on the adjusted current node's
  # namespace and integration-point status.
  defp step(token, state) do
    if html_content?(token, state) do
      step_html(token, state)
    else
      process_foreign(token, state)
    end
  end

  # A character token may carry a run of text; the spec processes one character
  # at a time, so split into leading whitespace + the rest where a mode treats
  # them differently. Modes that treat all characters the same handle the whole
  # run in one clause.
  defp step_html(%Token.Character{} = token, state),
    do: process_characters(state.mode, token, state)

  defp step_html(token, state), do: process(state.mode, token, state)

  # Whether `token` is processed in HTML content (else foreign content) — the
  # dispatcher's condition list.
  defp html_content?(token, state) do
    node = adjusted_current_node(state)

    cond do
      state.open_elements == [] -> true
      namespace_of(state, node) == :html -> true
      mathml_text_point?(state, node) and mathml_text_html?(token) -> true
      annotation_xml_svg?(state, node, token) -> true
      html_integration_point?(state, node) and html_integration_token?(token) -> true
      :else -> false
    end
  end

  # A MathML text integration point processes start tags (except mglyph/
  # malignmark) and character tokens as HTML content.
  defp mathml_text_html?(%Token.StartTag{name: name}), do: name not in ~w(mglyph malignmark)
  defp mathml_text_html?(%Token.Character{}), do: true
  defp mathml_text_html?(_token), do: false

  # An HTML integration point processes start tags and character tokens as HTML.
  defp html_integration_token?(%Token.StartTag{}), do: true
  defp html_integration_token?(%Token.Character{}), do: true
  defp html_integration_token?(_token), do: false

  # An annotation-xml (MathML) element with an "svg" start tag stays HTML content.
  defp annotation_xml_svg?(state, node, %Token.StartTag{name: "svg"}) do
    namespace_of(state, node) == :mathml and Node.node_name(node) == "annotation-xml"
  end

  defp annotation_xml_svg?(_state, _node, _token), do: false

  # End-of-file: the pre-body insertion modes imply the missing elements (so an
  # empty or head-only document still yields <html><head><body>). Each mode's EOF
  # rule follows its "anything else" path; we chain the implied elements.
  #
  # In the FRAGMENT case there is no implied html/head/body scaffolding — the
  # synthetic root is fixed and EOF only needs the in-template unwinding. So a
  # fragment parse skips the pre-body chain entirely (except in_template below).
  defp eof(%__MODULE__{context: context, mode: mode} = state)
       when not is_nil(context) and
              mode in [:initial, :before_html, :before_head, :in_head, :after_head],
       do: state

  defp eof(%__MODULE__{mode: :initial} = state), do: eof(%{state | mode: :before_html})

  defp eof(%__MODULE__{mode: :before_html} = state) do
    html = create_element_for(%Token.StartTag{name: "html"}, state)
    append(state.document, html)
    eof(%{state | open_elements: [html], mode: :before_head})
  end

  defp eof(%__MODULE__{mode: :before_head} = state) do
    {head, state} = insert_html_element(%Token.StartTag{name: "head"}, state)
    eof(%{state | head: head, mode: :in_head})
  end

  defp eof(%__MODULE__{mode: :in_head} = state), do: eof(%{pop(state) | mode: :after_head})

  defp eof(%__MODULE__{mode: :after_head} = state) do
    {_body, state} = insert_html_element(%Token.StartTag{name: "body"}, state)
    %{state | mode: :in_body}
  end

  # "in table text" at EOF: flush the pending characters, then finish in the
  # original mode (the table modes' EOF rule is "process using in body", which
  # merely stops).
  defp eof(%__MODULE__{mode: :in_table_text} = state), do: eof(flush_table_text(state))

  # "in template" at EOF: if a template is still open, pop through it, clear the
  # formatting list and template mode, reset the insertion mode, and continue
  # (an unclosed template implies its closure). Otherwise stop.
  defp eof(%__MODULE__{mode: :in_template} = state), do: eof_in_template(state)

  # Any mode with a non-empty stack of template insertion modes at EOF uses the
  # "in template" EOF rule (§13.2.6.4.7 — the in-body EOF delegates when a
  # template is open).
  defp eof(%__MODULE__{template_modes: [_ | _]} = state), do: eof_in_template(state)

  # "text" mode at EOF (§13.2.6.4.8): an unclosed rawtext/RCDATA element (e.g.
  # <script> with no </script>) — parse error; pop the current node, switch back
  # to the original insertion mode, and continue EOF there (so a head-level
  # <script> still implies a <body>).
  defp eof(%__MODULE__{mode: :text} = state) do
    eof(%{pop(state) | mode: state.original_mode})
  end

  defp eof(state), do: state

  defp eof_in_template(state) do
    if Enum.any?(state.open_elements, &(Node.node_name(&1) == "template")) do
      state
      |> generate_all_implied_end_tags()
      |> pop_through("template")
      |> clear_formatting_to_marker()
      |> pop_template_mode()
      |> reset_insertion_mode()
      |> eof()
    else
      state
    end
  end

  # Reprocess a token in `mode` after a mode switch — dispatches by token type so
  # character tokens go through process_characters (the spec's "reprocess the
  # token" always re-runs the full per-mode handling).
  defp reprocess(mode, %Token.Character{} = token, state),
    do: process_characters(mode, token, state)

  defp reprocess(mode, token, state), do: process(mode, token, state)

  # ==========================================================================
  # §13.2.6.4.1  The "initial" insertion mode
  # ==========================================================================

  # A comment token: insert a comment as the last child of the Document.
  defp process(:initial, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  # A DOCTYPE token: append a DocumentType node to the Document. Public/system
  # ids are preserved as-is (nil when absent) so the serializer can distinguish
  # `<!DOCTYPE name>` from `<!DOCTYPE name "" "">`. (Quirks detection deferred.)
  defp process(:initial, %Token.Doctype{} = token, state) do
    doctype =
      DOM.create_document_type(
        state.document,
        token.name || "",
        token.public_id,
        token.system_id
      )

    append(state.document, doctype)
    %{state | mode: :before_html}
  end

  # Anything else: switch to "before html", then reprocess the token.
  defp process(:initial, token, state),
    do: reprocess(:before_html, token, %{state | mode: :before_html})

  # ==========================================================================
  # §13.2.6.4.2  The "before html" insertion mode
  # ==========================================================================

  # A DOCTYPE token: parse error, ignore.
  defp process(:before_html, %Token.Doctype{}, state), do: state

  # A comment token: insert a comment as the last child of the Document.
  defp process(:before_html, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  # A start tag whose tag name is "html": create an element for the token, append
  # it to the Document, push it onto the stack. Switch to "before head".
  defp process(:before_html, %Token.StartTag{name: "html"} = token, state) do
    html = create_element_for(token, state)
    append(state.document, html)
    %{state | open_elements: [html], mode: :before_head}
  end

  # An end tag other than head/body/html/br: parse error, ignore.
  defp process(:before_html, %Token.EndTag{name: name}, state)
       when name not in ~w(head body html br),
       do: state

  # Anything else: create an "html" element, append to Document, push. Switch to
  # "before head", then reprocess the token.
  defp process(:before_html, token, state) do
    html = create_element_for(%Token.StartTag{name: "html"}, state)
    append(state.document, html)
    reprocess(:before_head, token, %{state | open_elements: [html], mode: :before_head})
  end

  # ==========================================================================
  # §13.2.6.4.3  The "before head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:before_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:before_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:before_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag whose tag name is "head": insert an HTML element for the token,
  # set the head element pointer, switch to "in head".
  defp process(:before_head, %Token.StartTag{name: "head"} = token, state) do
    {head, state} = insert_html_element(token, state)
    %{state | head: head, mode: :in_head}
  end

  # An end tag other than head/body/html/br: parse error, ignore.
  defp process(:before_head, %Token.EndTag{name: name}, state)
       when name not in ~w(head body html br),
       do: state

  # Anything else: insert an implied "head" element, set the head pointer, switch
  # to "in head", then reprocess the token.
  defp process(:before_head, token, state) do
    {head, state} = insert_html_element(%Token.StartTag{name: "head"}, state)
    reprocess(:in_head, token, %{state | head: head, mode: :in_head})
  end

  # ==========================================================================
  # §13.2.6.4.4  The "in head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:in_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:in_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:in_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # base/basefont/bgsound/link/meta: insert an HTML element, immediately pop it,
  # acknowledge the self-closing flag. (Void — never has children.)
  defp process(:in_head, %Token.StartTag{name: name} = token, state)
       when name in ~w(base basefont bgsound link meta) do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # title (RCDATA) / noframes/style/noscript (rawtext) / script: follow the
  # generic rawtext/RCDATA element parsing algorithm — insert the element and
  # switch to "text" mode, saving the CURRENT insertion mode (which may be
  # "in body" when this clause is reached via the in-body delegation).
  defp process(:in_head, %Token.StartTag{name: name} = token, state)
       when name in @head_rawtext do
    {_el, state} = insert_html_element(token, state)
    %{state | original_mode: state.mode, mode: :text}
  end

  # A start tag "template": insert a template element (its children go into the
  # content fragment), insert a marker, frameset-ok not ok, push "in template"
  # onto the template insertion modes, switch to "in template".
  defp process(:in_head, %Token.StartTag{name: "template"} = token, state) do
    {_el, state} = insert_template_element(token, state)

    %{
      insert_marker(state)
      | frameset_ok: false,
        template_modes: [:in_template | state.template_modes],
        mode: :in_template
    }
  end

  # An end tag "template": if there is no template on the stack, ignore. Otherwise
  # generate all implied end tags, pop through the template, clear the active
  # formatting list to the last marker, pop the template insertion modes, and
  # reset the insertion mode.
  defp process(:in_head, %Token.EndTag{name: "template"}, state) do
    if Enum.any?(state.open_elements, &(Node.node_name(&1) == "template")) do
      state
      |> generate_all_implied_end_tags()
      |> pop_through("template")
      |> clear_formatting_to_marker()
      |> pop_template_mode()
      |> reset_insertion_mode()
    else
      state
    end
  end

  # An end tag whose tag name is "head": pop the head element, switch to "after
  # head".
  defp process(:in_head, %Token.EndTag{name: "head"}, state) do
    %{pop(state) | mode: :after_head}
  end

  # An end tag other than body/html/br: parse error, ignore.
  defp process(:in_head, %Token.EndTag{name: name}, state)
       when name not in ~w(body html br),
       do: state

  # Anything else: pop the head element, switch to "after head", reprocess.
  defp process(:in_head, token, state) do
    reprocess(:after_head, token, %{pop(state) | mode: :after_head})
  end

  # ==========================================================================
  # §13.2.6.4.6  The "after head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:after_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:after_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:after_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag whose tag name is "body": insert an HTML element, set frameset-ok
  # to "not ok", switch to "in body".
  defp process(:after_head, %Token.StartTag{name: "body"} = token, state) do
    {_body, state} = insert_html_element(token, state)
    %{state | frameset_ok: false, mode: :in_body}
  end

  # A start tag "frameset": insert an HTML element, switch to "in frameset".
  defp process(:after_head, %Token.StartTag{name: "frameset"} = token, state) do
    {_el, state} = insert_html_element(token, state)
    %{state | mode: :in_frameset}
  end

  # An end tag other than body/html/br: parse error, ignore.
  defp process(:after_head, %Token.EndTag{name: name}, state)
       when name not in ~w(body html br),
       do: state

  # Anything else: insert an implied "body" element, switch to "in body",
  # reprocess.
  defp process(:after_head, token, state) do
    {_body, state} = insert_html_element(%Token.StartTag{name: "body"}, state)
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  # ==========================================================================
  # §13.2.6.4.7  The "in body" insertion mode (tier 2 — in-body repairs)
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:in_body, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A start/end tag "template": process using the "in head" rules.
  defp process(:in_body, %Token.StartTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  defp process(:in_body, %Token.EndTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:in_body, %Token.Doctype{}, state), do: state

  # A start tag "html": parse error. If there is no template on the stack, merge
  # any attribute not already present onto the top (html) element.
  defp process(:in_body, %Token.StartTag{name: "html"} = token, state) do
    merge_attributes(List.last(state.open_elements), token.attributes)
    state
  end

  # A start tag "body": parse error. If a body exists (second element on the
  # stack), merge any attribute not already present onto it.
  defp process(:in_body, %Token.StartTag{name: "body"} = token, state) do
    if body = second_element(state), do: merge_attributes(body, token.attributes)
    state
  end

  # A start tag "frameset": parse error. If the stack has only one node, or the
  # second element is not a body, or frameset-ok is "not ok", ignore. Otherwise
  # remove the body, pop back to the html root, insert the frameset, and switch
  # to "in frameset".
  defp process(:in_body, %Token.StartTag{name: "frameset"} = token, state) do
    if frameset_replaceable?(state) do
      body = second_element(state)
      if parent = Node.parent_node(body), do: Node.remove_child(parent, body)
      state = pop_to_html_root(state)
      {_el, state} = insert_html_element(token, state)
      %{state | mode: :in_frameset}
    else
      state
    end
  end

  # A start tag "xmp"/"iframe"/"textarea": these use the raw-text/RCDATA parsing
  # algorithm (via "in head") but additionally set frameset-ok to "not ok".
  # A start tag "xmp": close a p in button scope, reconstruct, frameset-ok not ok,
  # then follow the generic rawtext algorithm (insert + switch to "text").
  defp process(:in_body, %Token.StartTag{name: "xmp"} = token, state) do
    state = state |> close_p_if_button_scope() |> reconstruct_formatting()
    {_el, state} = insert_html_element(token, %{state | frameset_ok: false})
    %{state | original_mode: :in_body, mode: :text}
  end

  # A start tag "textarea"/"iframe"/"noembed": frameset-ok not ok (for
  # textarea/iframe), then the generic rawtext/RCDATA algorithm in the in-body
  # context (insert + switch to "text"). (The leading-newline skip for textarea
  # is handled by coalesced text; deferred.)
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(textarea iframe noembed) do
    frameset_ok = name == "noembed" and state.frameset_ok
    {_el, state} = insert_html_element(token, %{state | frameset_ok: frameset_ok})
    %{state | original_mode: :in_body, mode: :text}
  end

  # A start tag whose tag name is one of the genuine "in head" tags
  # (base/link/meta/… + title/style/script/noframes/noscript): process using the
  # "in head" rules.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(base basefont bgsound link meta) or name in @head_rawtext do
    process(:in_head, token, state)
  end

  # A start tag "hr": if a p is in button scope, close it; insert an HTML
  # element, immediately pop it (void), acknowledge self-closing; frameset-ok
  # not ok.
  defp process(:in_body, %Token.StartTag{name: "hr"} = token, state) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    %{pop(state) | frameset_ok: false}
  end

  # A start tag "image": a parse error — act as if it were "img".
  defp process(:in_body, %Token.StartTag{name: "image"} = token, state) do
    process(:in_body, %{token | name: "img"}, state)
  end

  # A start tag "pre"/"listing": close a p element in button scope, insert an
  # HTML element; a following newline character is dropped (§13.2.6.4.7 — handled
  # by the tokenizer/text step is deferred); frameset-ok not ok.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(pre listing) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    %{state | frameset_ok: false}
  end

  # A start tag "plaintext": if a p is in button scope, close it; insert an HTML
  # element and switch the tokenizer to the PLAINTEXT state (already handled by
  # the tokenizer — the whole rest of input arrives as one Character run).
  defp process(:in_body, %Token.StartTag{name: "plaintext"} = token, state) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    state
  end

  # A start tag "form": if there is a form element pointer and no template on the
  # stack, ignore (parse error). Otherwise close a p in button scope, insert, and
  # set the form element pointer.
  defp process(:in_body, %Token.StartTag{name: "form"} = token, state) do
    if state.form do
      state
    else
      {form, state} = insert_html_element(token, close_p_if_button_scope(state))
      %{state | form: form}
    end
  end

  # A start tag for a void element: insert an HTML element, immediately pop it,
  # acknowledge the self-closing flag. area/br/embed/img/keygen/wbr and a
  # non-hidden input additionally set frameset-ok to "not ok".
  defp process(:in_body, %Token.StartTag{name: name} = token, state) when name in @void do
    {_el, state} = insert_html_element(token, state)
    state = pop(state)
    if void_clears_frameset?(name, token), do: %{state | frameset_ok: false}, else: state
  end

  # A start tag for "address, article, aside, …, div, dl, …, p, section, …"
  # (the block-level group): if the stack has a p element in button scope, close
  # it; then insert an HTML element.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(address article aside blockquote center details dialog dir
                       div dl fieldset figcaption figure footer header hgroup main
                       menu nav ol p section summary ul) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    state
  end

  # A start tag "h1".."h6": close a p element in button scope; if the current
  # node is itself a heading, pop it (parse error); insert an HTML element.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(h1 h2 h3 h4 h5 h6) do
    state = close_p_if_button_scope(state)
    state = if heading?(current_node(state)), do: pop(state), else: state
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "li": set frameset-ok "not ok"; walk the stack popping
  # generate-implied-end-tags-style from any open "li", closing it; then close a
  # p element in button scope and insert.
  defp process(:in_body, %Token.StartTag{name: "li"} = token, state) do
    state = close_list_item(%{state | frameset_ok: false}, ["li"])
    state = close_p_if_button_scope(state)
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "dd"/"dt": as "li" but keyed on dd/dt (also sets frameset-ok).
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(dd dt) do
    state = close_list_item(%{state | frameset_ok: false}, ~w(dd dt))
    state = close_p_if_button_scope(state)
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "button": if a button is in scope, generate implied end tags and
  # pop through the button (parse error); reconstruct (tier 4); insert; frameset-
  # ok not ok.
  defp process(:in_body, %Token.StartTag{name: "button"} = token, state) do
    state =
      if has_in_scope?(state, "button", @scope_markers) do
        state |> generate_implied_end_tags() |> pop_through("button")
      else
        state
      end

    {_el, state} = insert_html_element(token, state)
    %{state | frameset_ok: false}
  end

  # A start tag "table": (not quirks-mode — quirks detection deferred) if a p is
  # in button scope, close it; insert; frameset-ok not ok; switch to "in table".
  defp process(:in_body, %Token.StartTag{name: "table"} = token, state) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    %{state | frameset_ok: false, mode: :in_table}
  end

  # A start tag for a table-child tag ("caption"/"col"/"tbody"/… /"tr"/"frame"/
  # "head"): parse error, ignore in the "in body" mode.
  defp process(:in_body, %Token.StartTag{name: name}, state)
       when name in ~w(caption col colgroup frame head tbody td tfoot th thead tr) do
    state
  end

  # A start tag "select": reconstruct, insert, frameset-ok not ok; switch to "in
  # select in table" when currently within a table mode, else "in select".
  defp process(:in_body, %Token.StartTag{name: "select"} = token, state) do
    {_el, state} = insert_html_element(token, reconstruct_formatting(state))
    mode = if state.mode in @table_modes, do: :in_select_in_table, else: :in_select
    %{state | frameset_ok: false, mode: mode}
  end

  # A start tag "optgroup"/"option": if the current node is an "option", pop it,
  # then reconstruct and insert (they do not nest).
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(optgroup option) do
    state = if Node.node_name(current_node(state)) == "option", do: pop(state), else: state
    {_el, state} = insert_html_element(token, reconstruct_formatting(state))
    state
  end

  # A start tag "rb"/"rtc": if a ruby is in scope, generate implied end tags
  # (current node should then be ruby, else parse error); insert.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(rb rtc) do
    state =
      if has_in_scope?(state, "ruby", @scope_markers),
        do: generate_implied_end_tags(state),
        else: state

    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "rp"/"rt": if a ruby is in scope, generate implied end tags
  # EXCEPT rtc (so an open rtc keeps its rt/rp children); insert.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(rp rt) do
    state =
      if has_in_scope?(state, "ruby", @scope_markers),
        do: generate_implied_end_tags(state, "rtc"),
        else: state

    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "a": if an "a" is in the active formatting list after the last
  # marker, run the adoption agency for it and remove it from both lists (parse
  # error). Then reconstruct, insert, and push onto the formatting list.
  defp process(:in_body, %Token.StartTag{name: "a"} = token, state) do
    state =
      if existing = formatting_after_marker(state, "a") do
        state
        |> adoption_agency(%Token.EndTag{name: "a"})
        |> remove_from_formatting(existing)
        |> remove_from_stack(existing)
      else
        state
      end

    insert_formatting(token, state)
  end

  # A start tag for a formatting element (b/big/code/…/u): reconstruct, insert,
  # and push onto the active formatting list.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in @formatting do
    insert_formatting(token, state)
  end

  # A start tag "nobr": reconstruct; if a nobr is in scope, run the adoption
  # agency for it then reconstruct again (parse error). Insert and push.
  defp process(:in_body, %Token.StartTag{name: "nobr"} = token, state) do
    state = reconstruct_formatting(state)

    state =
      if has_in_scope?(state, "nobr", @scope_markers) do
        state |> adoption_agency(%Token.EndTag{name: "nobr"}) |> reconstruct_formatting()
      else
        state
      end

    insert_and_push(state, token)
  end

  # A start tag "math"/"svg": reconstruct; adjust MathML/SVG + foreign attributes;
  # insert a foreign element in the MathML/SVG namespace; if self-closing, pop and
  # acknowledge. (§13.2.6.4.7 — the foreign-content integration points.)
  defp process(:in_body, %Token.StartTag{name: "math"} = token, state) do
    insert_foreign_start(:mathml, adjust_mathml_attributes(token), state)
  end

  defp process(:in_body, %Token.StartTag{name: "svg"} = token, state) do
    insert_foreign_start(:svg, adjust_svg_attributes(token), state)
  end

  # A start tag "applet"/"marquee"/"object": reconstruct, insert, insert a marker
  # on the active formatting list, set frameset-ok "not ok".
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(applet marquee object) do
    {_el, state} = insert_html_element(token, reconstruct_formatting(state))
    %{insert_marker(state) | frameset_ok: false}
  end

  # Any other start tag: reconstruct active formatting elements, then insert an
  # HTML element for the token.
  defp process(:in_body, %Token.StartTag{} = token, state) do
    {_el, state} = insert_html_element(token, reconstruct_formatting(state))
    state
  end

  # An end tag whose tag name is "body"/"html": switch to "after body". ("html"
  # additionally reprocesses; tier 1 treats them alike.)
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(body html) do
    %{state | mode: :after_body}
  end

  # An end tag for a block-level element ("address, …, div, …, ul, …"): if it is
  # in scope, generate implied end tags then pop through it (else parse error,
  # ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state)
       when name in ~w(address article aside blockquote button center details
                       dialog dir div dl fieldset figcaption figure footer header
                       hgroup listing main menu nav ol pre section summary ul) do
    if has_in_scope?(state, name, @scope_markers) do
      state |> generate_implied_end_tags() |> pop_through(name)
    else
      state
    end
  end

  # An end tag "applet"/"marquee"/"object": if in scope, generate implied end
  # tags, pop through it, and clear the active formatting list to the last marker.
  defp process(:in_body, %Token.EndTag{name: name}, state)
       when name in ~w(applet marquee object) do
    if has_in_scope?(state, name, @scope_markers) do
      state |> generate_implied_end_tags() |> pop_through(name) |> clear_formatting_to_marker()
    else
      state
    end
  end

  # An end tag "form" (no template on the stack — templates are a later tier):
  # let node be the form pointer and clear it; if node is null or not in scope,
  # ignore; otherwise generate implied end tags and remove node from the stack.
  defp process(:in_body, %Token.EndTag{name: "form"}, state) do
    node = state.form
    state = %{state | form: nil}

    # The spec checks THIS element (the form pointer) in scope — not "a form by
    # name". A fostered form may have been removed from the stack (table foster
    # parenting), leaving the pointer dangling; then the token is ignored.
    if node && on_stack?(state, node) && element_in_scope?(state, node) do
      state
      |> generate_implied_end_tags()
      |> then(&%{&1 | open_elements: drop_including(&1.open_elements, node)})
    else
      state
    end
  end

  # An end tag "p": if there is no p element in button scope, insert one (parse
  # error) then close it; otherwise close a p element.
  defp process(:in_body, %Token.EndTag{name: "p"}, state) do
    state =
      if has_in_scope?(state, "p", @button_scope_markers) do
        state
      else
        {_el, state} = insert_html_element(%Token.StartTag{name: "p"}, state)
        state
      end

    close_p_element(state)
  end

  # An end tag "li": if in list-item scope, generate implied end tags except li,
  # then pop through the li (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: "li"}, state) do
    if has_in_scope?(state, "li", @list_item_scope_markers) do
      state |> generate_implied_end_tags("li") |> pop_through("li")
    else
      state
    end
  end

  # An end tag "dd"/"dt": if in scope, generate implied end tags except it, then
  # pop through it (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(dd dt) do
    if has_in_scope?(state, name, @scope_markers) do
      state |> generate_implied_end_tags(name) |> pop_through(name)
    else
      state
    end
  end

  # An end tag "h1".."h6": if any heading is in scope, generate implied end tags
  # then pop through the first heading on the stack (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(h1 h2 h3 h4 h5 h6) do
    if any_heading_in_scope?(state) do
      state |> generate_implied_end_tags() |> pop_through_heading()
    else
      state
    end
  end

  # An end tag for a formatting element (a/b/big/…/nobr/…/u): run the adoption
  # agency algorithm for the token.
  defp process(:in_body, %Token.EndTag{name: name} = token, state)
       when name == "a" or name == "nobr" or name in @formatting do
    adoption_agency(state, token)
  end

  # Any other end tag: walk the stack from the current node; on a node whose name
  # matches, generate implied end tags (except that name) and pop through it; on
  # a "special" element, stop (parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state) do
    any_other_end_tag(state, name, state.open_elements)
  end

  # ==========================================================================
  # The "text" insertion mode (§13.2.6.4.8)
  # ==========================================================================

  # An end tag: pop the current node, switch back to the original insertion mode.
  defp process(:text, %Token.EndTag{}, state), do: %{pop(state) | mode: state.original_mode}

  # ==========================================================================
  # §13.2.6.4.9  The "in table" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:in_table, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:in_table, %Token.Doctype{}, state), do: state

  # A start tag "caption": clear the stack back to a table context, insert a
  # marker on the active formatting list, insert an HTML element, switch to "in
  # caption".
  defp process(:in_table, %Token.StartTag{name: "caption"} = token, state) do
    state = state |> clear_to_table_context() |> insert_marker()
    {_el, state} = insert_html_element(token, state)
    %{state | mode: :in_caption}
  end

  # A start tag "colgroup": clear the stack back to a table context, insert,
  # switch to "in column group".
  defp process(:in_table, %Token.StartTag{name: "colgroup"} = token, state) do
    state = clear_to_table_context(state)
    {_el, state} = insert_html_element(token, state)
    %{state | mode: :in_column_group}
  end

  # A start tag "col": act as if a "colgroup" start tag had been seen, then
  # reprocess the "col" token in "in column group".
  defp process(:in_table, %Token.StartTag{name: "col"} = token, state) do
    state = clear_to_table_context(state)
    {_el, state} = insert_html_element(%Token.StartTag{name: "colgroup"}, state)
    reprocess(:in_column_group, token, %{state | mode: :in_column_group})
  end

  # A start tag "tbody"/"tfoot"/"thead": clear the stack back to a table context,
  # insert, switch to "in table body".
  defp process(:in_table, %Token.StartTag{name: name} = token, state)
       when name in ~w(tbody tfoot thead) do
    state = clear_to_table_context(state)
    {_el, state} = insert_html_element(token, state)
    %{state | mode: :in_table_body}
  end

  # A start tag "td"/"th"/"tr": act as if a "tbody" start tag had been seen, then
  # reprocess in "in table body".
  defp process(:in_table, %Token.StartTag{name: name} = token, state)
       when name in ~w(td th tr) do
    state = clear_to_table_context(state)
    {_el, state} = insert_html_element(%Token.StartTag{name: "tbody"}, state)
    reprocess(:in_table_body, token, %{state | mode: :in_table_body})
  end

  # A start tag "table": parse error. If no table is in table scope, ignore.
  # Otherwise pop through the table, reset the insertion mode, reprocess.
  defp process(:in_table, %Token.StartTag{name: "table"} = token, state) do
    if has_in_scope?(state, "table", @table_scope_markers) do
      state = pop_through(state, "table")
      state = reset_insertion_mode(state)
      reprocess(state.mode, token, state)
    else
      state
    end
  end

  # An end tag "table": if no table is in table scope, parse error, ignore.
  # Otherwise pop through the table and reset the insertion mode.
  defp process(:in_table, %Token.EndTag{name: "table"}, state) do
    if has_in_scope?(state, "table", @table_scope_markers) do
      state |> pop_through("table") |> reset_insertion_mode()
    else
      state
    end
  end

  # An end tag "body"/"caption"/"col"/…/"tr": parse error, ignore.
  defp process(:in_table, %Token.EndTag{name: name}, state)
       when name in ~w(body caption col colgroup html tbody td tfoot th thead tr) do
    state
  end

  # style/script/template start tags + template end tag: process using "in head".
  defp process(:in_table, %Token.StartTag{name: name} = token, state)
       when name in ~w(style script template) do
    process(:in_head, token, state)
  end

  defp process(:in_table, %Token.EndTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  # A start tag "input" that is type=hidden: insert, pop, acknowledge self-
  # closing. Any other input falls through to "anything else".
  defp process(:in_table, %Token.StartTag{name: "input"} = token, state) do
    if hidden_input?(token) do
      {_el, state} = insert_html_element(token, state)
      pop(state)
    else
      anything_else_in_table(token, state)
    end
  end

  # A start tag "form": if a form pointer is set (or a template is on the stack —
  # tier 6), ignore; else insert and set the pointer, then pop it.
  defp process(:in_table, %Token.StartTag{name: "form"} = token, state) do
    if state.form do
      state
    else
      {form, state} = insert_html_element(token, state)
      pop(%{state | form: form})
    end
  end

  # Anything else: parse error. Enable foster parenting, process using "in body",
  # then disable foster parenting.
  defp process(:in_table, token, state), do: anything_else_in_table(token, state)

  # ==========================================================================
  # §13.2.6.4.10  The "in table text" insertion mode (non-character tokens)
  # ==========================================================================

  # Anything else (a non-character token ends the run): flush the pending table
  # character tokens, switch back to the original insertion mode, and reprocess.
  defp process(:in_table_text, token, state) do
    state = flush_table_text(state)
    reprocess(state.mode, token, state)
  end

  # ==========================================================================
  # §13.2.6.4.11  The "in caption" insertion mode
  # ==========================================================================

  # An end tag "caption" / a start tag for a table-child / an end tag "table":
  # if no caption is in table scope, parse error, ignore. Otherwise generate
  # implied end tags, pop through the caption, clear formatting to last marker
  # (tier 4 — no-op), switch to "in table"; the table-child/table cases reprocess.
  defp process(:in_caption, %Token.EndTag{name: "caption"}, state) do
    close_caption(state)
  end

  defp process(:in_caption, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption col colgroup tbody td tfoot th thead tr) do
    close_caption_and_reprocess(token, state)
  end

  defp process(:in_caption, %Token.EndTag{name: "table"} = token, state) do
    close_caption_and_reprocess(token, state)
  end

  # An end tag "body"/"col"/…/"tr": parse error, ignore.
  defp process(:in_caption, %Token.EndTag{name: name}, state)
       when name in ~w(body col colgroup html tbody td tfoot th thead tr) do
    state
  end

  # Anything else: process using "in body".
  defp process(:in_caption, token, state), do: process(:in_body, token, state)

  # ==========================================================================
  # §13.2.6.4.12  The "in column group" insertion mode
  # ==========================================================================

  defp process(:in_column_group, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  defp process(:in_column_group, %Token.Doctype{}, state), do: state

  # A start tag "html": process using "in body".
  defp process(:in_column_group, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag "col": insert an HTML element, immediately pop it (void),
  # acknowledge self-closing.
  defp process(:in_column_group, %Token.StartTag{name: "col"} = token, state) do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # An end tag "colgroup": if the current node is not a colgroup, parse error,
  # ignore; otherwise pop it, switch to "in table".
  defp process(:in_column_group, %Token.EndTag{name: "colgroup"}, state) do
    if Node.node_name(current_node(state)) == "colgroup" do
      %{pop(state) | mode: :in_table}
    else
      state
    end
  end

  # An end tag "col": parse error, ignore.
  defp process(:in_column_group, %Token.EndTag{name: "col"}, state), do: state

  # template start/end tags: process using "in head".
  defp process(:in_column_group, %Token.StartTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  defp process(:in_column_group, %Token.EndTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  # Anything else: if the current node is not a colgroup, parse error, ignore;
  # otherwise pop it, switch to "in table", reprocess.
  defp process(:in_column_group, token, state) do
    if Node.node_name(current_node(state)) == "colgroup" do
      reprocess(:in_table, token, %{pop(state) | mode: :in_table})
    else
      state
    end
  end

  # ==========================================================================
  # §13.2.6.4.13  The "in table body" insertion mode
  # ==========================================================================

  # A start tag "tr": clear the stack back to a table body context, insert,
  # switch to "in row".
  defp process(:in_table_body, %Token.StartTag{name: "tr"} = token, state) do
    state = clear_to_table_body_context(state)
    {_el, state} = insert_html_element(token, state)
    %{state | mode: :in_row}
  end

  # A start tag "th"/"td": parse error. Act as if a "tr" start tag had been seen,
  # then reprocess in "in row".
  defp process(:in_table_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(th td) do
    state = clear_to_table_body_context(state)
    {_el, state} = insert_html_element(%Token.StartTag{name: "tr"}, state)
    reprocess(:in_row, token, %{state | mode: :in_row})
  end

  # An end tag "tbody"/"tfoot"/"thead": if not in table scope, parse error,
  # ignore; otherwise clear to a table body context, pop it, switch to "in table".
  defp process(:in_table_body, %Token.EndTag{name: name}, state)
       when name in ~w(tbody tfoot thead) do
    if has_in_scope?(state, name, @table_scope_markers) do
      %{pop(clear_to_table_body_context(state)) | mode: :in_table}
    else
      state
    end
  end

  # A start tag for a table-section sibling / an end tag "table": if no tbody/
  # thead/tfoot is in table scope, parse error, ignore. Otherwise clear to a
  # table body context, pop it, switch to "in table", reprocess.
  defp process(:in_table_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption col colgroup tbody tfoot thead) do
    table_body_to_table(token, state)
  end

  defp process(:in_table_body, %Token.EndTag{name: "table"} = token, state) do
    table_body_to_table(token, state)
  end

  # An end tag "body"/"caption"/…/"tr": parse error, ignore.
  defp process(:in_table_body, %Token.EndTag{name: name}, state)
       when name in ~w(body caption col colgroup html td th tr) do
    state
  end

  # Anything else: process using "in table".
  defp process(:in_table_body, token, state), do: process(:in_table, token, state)

  # ==========================================================================
  # §13.2.6.4.14  The "in row" insertion mode
  # ==========================================================================

  # A start tag "th"/"td": clear the stack back to a table row context, insert,
  # switch to "in cell", insert a marker on the active formatting list.
  defp process(:in_row, %Token.StartTag{name: name} = token, state)
       when name in ~w(th td) do
    state = clear_to_table_row_context(state)
    {_el, state} = insert_html_element(token, state)
    %{insert_marker(state) | mode: :in_cell}
  end

  # An end tag "tr": if no tr is in table scope, parse error, ignore. Otherwise
  # clear to a table row context, pop the tr, switch to "in table body".
  defp process(:in_row, %Token.EndTag{name: "tr"}, state) do
    if has_in_scope?(state, "tr", @table_scope_markers) do
      %{pop(clear_to_table_row_context(state)) | mode: :in_table_body}
    else
      state
    end
  end

  # A start tag for a table-child / an end tag "table": if no tr is in table
  # scope, ignore; otherwise pop the tr, switch to "in table body", reprocess.
  defp process(:in_row, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption col colgroup tbody tfoot thead tr) do
    row_to_table_body(token, state)
  end

  defp process(:in_row, %Token.EndTag{name: "table"} = token, state) do
    row_to_table_body(token, state)
  end

  # An end tag "tbody"/"tfoot"/"thead": if that section is not in table scope,
  # ignore; else if no tr in table scope, ignore; otherwise pop the tr, switch to
  # "in table body", reprocess.
  defp process(:in_row, %Token.EndTag{name: name} = token, state)
       when name in ~w(tbody tfoot thead) do
    if has_in_scope?(state, name, @table_scope_markers) do
      row_to_table_body(token, state)
    else
      state
    end
  end

  # An end tag "body"/"caption"/"col"/"colgroup"/"html"/"td"/"th": parse error,
  # ignore.
  defp process(:in_row, %Token.EndTag{name: name}, state)
       when name in ~w(body caption col colgroup html td th) do
    state
  end

  # Anything else: process using "in table".
  defp process(:in_row, token, state), do: process(:in_table, token, state)

  # ==========================================================================
  # §13.2.6.4.15  The "in cell" insertion mode
  # ==========================================================================

  # An end tag "td"/"th": if that element is not in table scope, parse error,
  # ignore. Otherwise generate implied end tags, pop through it, clear the active
  # formatting list up to the last marker, switch to "in row".
  defp process(:in_cell, %Token.EndTag{name: name}, state) when name in ~w(td th) do
    if has_in_scope?(state, name, @table_scope_markers) do
      state
      |> generate_implied_end_tags()
      |> pop_through(name)
      |> clear_formatting_to_marker()
      |> Map.put(:mode, :in_row)
    else
      state
    end
  end

  # A start tag for a table-child: if a td/th is in table scope, close the cell
  # and reprocess; otherwise (the fragment case — no cell to close) ignore.
  defp process(:in_cell, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption col colgroup tbody td tfoot th thead tr) do
    if any_in_scope?(state, ~w(td th), @table_scope_markers) do
      close_cell_and_reprocess(token, state)
    else
      state
    end
  end

  # An end tag "table"/"tbody"/"tfoot"/"thead"/"tr": if in table scope, close the
  # cell and reprocess; else parse error, ignore.
  defp process(:in_cell, %Token.EndTag{name: name} = token, state)
       when name in ~w(table tbody tfoot thead tr) do
    if has_in_scope?(state, name, @table_scope_markers) do
      close_cell_and_reprocess(token, state)
    else
      state
    end
  end

  # An end tag "body"/"caption"/"col"/"colgroup"/"html": parse error, ignore.
  defp process(:in_cell, %Token.EndTag{name: name}, state)
       when name in ~w(body caption col colgroup html) do
    state
  end

  # Anything else: process using "in body".
  defp process(:in_cell, token, state), do: process(:in_body, token, state)

  # ==========================================================================
  # The "in select" insertion mode (§13.2.6.4.16)
  # ==========================================================================

  defp process(:in_select, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  defp process(:in_select, %Token.Doctype{}, state), do: state

  # A start tag "html": process using "in body".
  defp process(:in_select, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag "option": if the current node is an option, pop it; insert.
  defp process(:in_select, %Token.StartTag{name: "option"} = token, state) do
    state = pop_if_current(state, "option")
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "optgroup": pop a current option, then a current optgroup; insert.
  defp process(:in_select, %Token.StartTag{name: "optgroup"} = token, state) do
    state = state |> pop_if_current("option") |> pop_if_current("optgroup")
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "hr": pop a current option, then a current optgroup; insert and
  # immediately pop (void), acknowledge self-closing.
  defp process(:in_select, %Token.StartTag{name: "hr"} = token, state) do
    state = state |> pop_if_current("option") |> pop_if_current("optgroup")
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # An end tag "optgroup": pop a current option first (if its parent is an
  # optgroup); then, if the current node is an optgroup, pop it.
  defp process(:in_select, %Token.EndTag{name: "optgroup"}, state) do
    state = pop_option_before_optgroup(state)
    if Node.node_name(current_node(state)) == "optgroup", do: pop(state), else: state
  end

  # An end tag "option": if the current node is an option, pop it.
  defp process(:in_select, %Token.EndTag{name: "option"}, state) do
    pop_if_current(state, "option")
  end

  # An end tag "select": if a select is in select scope, pop through it and reset
  # the insertion mode (else parse error, ignore — the fragment case).
  defp process(:in_select, %Token.EndTag{name: "select"}, state) do
    if select_in_scope?(state) do
      state |> pop_through("select") |> reset_insertion_mode()
    else
      state
    end
  end

  # A start tag "select": parse error — treat as </select> (close the select).
  defp process(:in_select, %Token.StartTag{name: "select"}, state) do
    if select_in_scope?(state) do
      state |> pop_through("select") |> reset_insertion_mode()
    else
      state
    end
  end

  # A start tag "input"/"keygen"/"textarea": if a select is in select scope, pop
  # through it, reset, and reprocess the token (else ignore).
  defp process(:in_select, %Token.StartTag{name: name} = token, state)
       when name in ~w(input keygen textarea) do
    if select_in_scope?(state) do
      state = state |> pop_through("select") |> reset_insertion_mode()
      reprocess(state.mode, token, state)
    else
      state
    end
  end

  # script/template start + template end: process using "in head".
  defp process(:in_select, %Token.StartTag{name: name} = token, state)
       when name in ~w(script template) do
    process(:in_head, token, state)
  end

  defp process(:in_select, %Token.EndTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  # Anything else (customizable select): process using the "in body" rules, so
  # arbitrary content (div/button/datalist/formatting/…) nests inside the select
  # with normal reconstruction. (The older spec ignored these; the vendored
  # html5lib data expects the customizable-select behavior.)
  defp process(:in_select, token, state), do: process(:in_body, token, state)

  # ==========================================================================
  # The "in select in table" insertion mode (§13.2.6.4.17)
  # ==========================================================================

  # A start tag for a table element / an end tag for a table element: parse error;
  # pop through the select, reset the insertion mode, and reprocess.
  defp process(:in_select_in_table, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption table tbody tfoot thead tr td th) do
    select_in_table_out(token, state)
  end

  defp process(:in_select_in_table, %Token.EndTag{name: name} = token, state)
       when name in ~w(caption table tbody tfoot thead tr td th) do
    select_in_table_out(token, state)
  end

  # Anything else: process using "in select".
  defp process(:in_select_in_table, token, state), do: process(:in_select, token, state)

  # ==========================================================================
  # The "in template" insertion mode (§13.2.6.4.16)
  # ==========================================================================

  # A comment or DOCTYPE token: process using "in body".
  defp process(:in_template, %Token.Comment{} = token, state), do: process(:in_body, token, state)
  defp process(:in_template, %Token.Doctype{} = token, state), do: process(:in_body, token, state)

  # base/basefont/bgsound/link/meta/noframes/script/style/template/title start
  # tags + template end tag: process using "in head".
  defp process(:in_template, %Token.StartTag{name: name} = token, state)
       when name in ~w(base basefont bgsound link meta noframes script style template title) do
    process(:in_head, token, state)
  end

  defp process(:in_template, %Token.EndTag{name: "template"} = token, state) do
    process(:in_head, token, state)
  end

  # Table-content start tags switch the current template insertion mode + the
  # insertion mode and reprocess (§13.2.6.4.16).
  defp process(:in_template, %Token.StartTag{name: name} = token, state)
       when name in ~w(caption colgroup tbody tfoot thead) do
    switch_template_mode(token, state, :in_table)
  end

  defp process(:in_template, %Token.StartTag{name: "col"} = token, state) do
    switch_template_mode(token, state, :in_column_group)
  end

  defp process(:in_template, %Token.StartTag{name: "tr"} = token, state) do
    switch_template_mode(token, state, :in_table_body)
  end

  defp process(:in_template, %Token.StartTag{name: name} = token, state) when name in ~w(td th) do
    switch_template_mode(token, state, :in_row)
  end

  # Any other start tag: switch to "in body" and reprocess.
  defp process(:in_template, %Token.StartTag{} = token, state) do
    switch_template_mode(token, state, :in_body)
  end

  # Any other end tag: parse error, ignore.
  defp process(:in_template, %Token.EndTag{}, state), do: state

  # ==========================================================================
  # §13.2.6.4.18  The "in frameset" insertion mode
  # ==========================================================================

  defp process(:in_frameset, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  defp process(:in_frameset, %Token.Doctype{}, state), do: state

  defp process(:in_frameset, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag "frameset": insert an HTML element.
  defp process(:in_frameset, %Token.StartTag{name: "frameset"} = token, state) do
    {_el, state} = insert_html_element(token, state)
    state
  end

  # An end tag "frameset": if the current node is the html root, ignore (fragment
  # case); otherwise pop it, and (non-fragment) if the new current node is not a
  # frameset, switch to "after frameset".
  defp process(:in_frameset, %Token.EndTag{name: "frameset"}, state) do
    if Node.node_name(current_node(state)) == "html" do
      state
    else
      state = pop(state)

      if is_nil(state.context) and Node.node_name(current_node(state)) != "frameset",
        do: %{state | mode: :after_frameset},
        else: state
    end
  end

  # A start tag "frame": insert an HTML element, immediately pop (void).
  defp process(:in_frameset, %Token.StartTag{name: "frame"} = token, state) do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # A start tag "noframes": process using "in head".
  defp process(:in_frameset, %Token.StartTag{name: "noframes"} = token, state) do
    process(:in_head, token, state)
  end

  # Anything else: parse error, ignore.
  defp process(:in_frameset, _token, state), do: state

  # ==========================================================================
  # §13.2.6.4.19  The "after frameset" insertion mode
  # ==========================================================================

  defp process(:after_frameset, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  defp process(:after_frameset, %Token.Doctype{}, state), do: state

  defp process(:after_frameset, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # An end tag "html": switch to "after after frameset".
  defp process(:after_frameset, %Token.EndTag{name: "html"}, state) do
    %{state | mode: :after_after_frameset}
  end

  defp process(:after_frameset, %Token.StartTag{name: "noframes"} = token, state) do
    process(:in_head, token, state)
  end

  defp process(:after_frameset, _token, state), do: state

  # ==========================================================================
  # §13.2.6.4.21  The "after after frameset" insertion mode
  # ==========================================================================

  # A comment token: insert as the last child of the Document.
  defp process(:after_after_frameset, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  defp process(:after_after_frameset, %Token.Doctype{}, state), do: state

  defp process(:after_after_frameset, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  defp process(:after_after_frameset, %Token.StartTag{name: "noframes"} = token, state) do
    process(:in_head, token, state)
  end

  defp process(:after_after_frameset, _token, state), do: state

  # ==========================================================================
  # §13.2.6.4.19  The "after body" insertion mode (partial — tier 1)
  # ==========================================================================

  # A comment token: insert as the last child of the first element (the html
  # element).
  defp process(:after_body, %Token.Comment{} = token, state) do
    append(List.last(state.open_elements) || state.document, comment(token, state))
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:after_body, %Token.Doctype{}, state), do: state

  # An end tag whose tag name is "html": switch to "after after body".
  defp process(:after_body, %Token.EndTag{name: "html"}, state) do
    %{state | mode: :after_after_body}
  end

  # Anything else: parse error, switch to "in body", reprocess.
  defp process(:after_body, token, state),
    do: reprocess(:in_body, token, %{state | mode: :in_body})

  # ==========================================================================
  # §13.2.6.4.22  The "after after body" insertion mode (partial — tier 1)
  # ==========================================================================

  # A comment token: insert as the last child of the Document.
  defp process(:after_after_body, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  defp process(:after_after_body, %Token.Doctype{}, state), do: state

  # Anything else: parse error, switch to "in body", reprocess.
  defp process(:after_after_body, token, state) do
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  # Not-yet-implemented modes: ignore (later tiers add clauses above this).
  defp process(_mode, _token, state), do: state

  # ==========================================================================
  # Character-token handling per mode (whitespace vs. the rest)
  # ==========================================================================

  # "initial"/"before html": whitespace characters are ignored; the non-whitespace
  # remainder runs the mode's "anything else" (the process/3 clause, which for a
  # character token performs the implied element + reprocess in the next mode).
  defp process_characters(mode, %Token.Character{data: data} = token, state)
       when mode in [:initial, :before_html] do
    case strip_leading_whitespace(data) do
      "" -> state
      rest -> process(mode, %{token | data: rest}, state)
    end
  end

  # "before head"/"in head"/"after head": leading whitespace is inserted; the
  # non-whitespace remainder runs the mode's "anything else" (process/3).
  defp process_characters(mode, %Token.Character{data: data} = token, state)
       when mode in [:before_head, :in_head, :after_head] do
    {ws, rest} = split_leading_whitespace(data)
    state = if ws != "", do: insert_characters(ws, state), else: state
    if rest == "", do: state, else: process(mode, %{token | data: rest}, state)
  end

  # "in body": reconstruct the active formatting elements, then insert the run.
  # Any non-whitespace character sets frameset-ok to "not ok".
  defp process_characters(:in_body, %Token.Character{data: data}, state) do
    state = if whitespace?(data), do: state, else: %{state | frameset_ok: false}
    insert_characters(data, reconstruct_formatting(state))
  end

  # "text": insert the character run as-is (no formatting reconstruction).
  defp process_characters(:text, %Token.Character{data: data}, state) do
    insert_characters(data, state)
  end

  # "after body"/"after after body": whitespace processed "in body"; anything
  # else reprocesses in "in body".
  defp process_characters(mode, token, state) when mode in [:after_body, :after_after_body] do
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  # §13.2.6.4.9 "in table": if the current node is a table section, start
  # collecting into the pending table character tokens list (save the original
  # mode, switch to "in table text", reprocess). Otherwise foster-parent via the
  # "anything else" path (process using "in body").
  defp process_characters(:in_table, token, state) do
    if Node.node_name(current_node(state)) in ~w(table tbody template tfoot thead tr) do
      state = %{state | pending_table_chars: [], original_mode: :in_table, mode: :in_table_text}
      reprocess(:in_table_text, token, state)
    else
      anything_else_in_table(token, state)
    end
  end

  # §13.2.6.4.10 "in table text": append the (non-null) characters to the pending
  # list. (Null characters are a parse error and dropped by the tokenizer's
  # replacement; here we accumulate the run as-is.)
  defp process_characters(:in_table_text, %Token.Character{data: data}, state) do
    %{state | pending_table_chars: [data | state.pending_table_chars]}
  end

  # §13.2.6.4.12 "in column group": whitespace is inserted; the non-whitespace
  # remainder runs the mode's "anything else" (process/3).
  defp process_characters(:in_column_group, %Token.Character{data: data} = token, state) do
    {ws, rest} = split_leading_whitespace(data)
    state = if ws != "", do: insert_characters(ws, state), else: state
    if rest == "", do: state, else: process(:in_column_group, %{token | data: rest}, state)
  end

  # "in table body"/"in row": character tokens are handled by "in table".
  defp process_characters(mode, token, state) when mode in [:in_table_body, :in_row] do
    process_characters(:in_table, token, state)
  end

  # "in caption"/"in cell": character tokens are handled by "in body".
  defp process_characters(mode, %Token.Character{data: data}, state)
       when mode in [:in_caption, :in_cell] do
    insert_characters(data, state)
  end

  # "in select"/"in select in table": reconstruct the active formatting elements
  # (so text inside a reconstructed div/button/formatting element nests), then
  # insert the characters (NULL is dropped).
  defp process_characters(mode, %Token.Character{data: data}, state)
       when mode in [:in_select, :in_select_in_table] do
    insert_characters(String.replace(data, "\0", ""), reconstruct_formatting(state))
  end

  # "in template": character tokens are processed using "in body".
  defp process_characters(:in_template, %Token.Character{data: data}, state) do
    insert_characters(data, reconstruct_formatting(state))
  end

  # "in frameset"/"after frameset"/"after after frameset": only whitespace
  # characters are inserted; any non-whitespace is a parse error and dropped.
  defp process_characters(mode, %Token.Character{data: data}, state)
       when mode in [:in_frameset, :after_frameset, :after_after_frameset] do
    ws = for <<c::utf8 <- data>>, c in [?\t, ?\n, ?\f, ?\r, ?\s], into: "", do: <<c::utf8>>
    if ws != "", do: insert_characters(ws, state), else: state
  end

  defp process_characters(_mode, _token, state), do: state

  # ==========================================================================
  # Tree-construction algorithms (spec-named)
  # ==========================================================================

  # "Insert an HTML element for the token": create it, insert at the appropriate
  # place (foster-parenting aware), push onto the stack. Returns {element, state}.
  defp insert_html_element(token, state) do
    element = create_element_for(token, state)
    insert_at(appropriate_insertion_location(state), element)
    {element, %{state | open_elements: [element | state.open_elements]}}
  end

  # Insert a template element: create the element + its content DocumentFragment,
  # insert the element at the appropriate place, record the content mapping, and
  # push the element onto the stack. Returns {element, state}.
  defp insert_template_element(token, state) do
    {element, content} = DOM._create_template(state.document, token.attributes)
    insert_at(appropriate_insertion_location(state), element)

    {element,
     %{
       state
       | open_elements: [element | state.open_elements],
         contents: Map.put(state.contents, element, content)
     }}
  end

  # Pop the current template insertion mode off the stack.
  defp pop_template_mode(%__MODULE__{template_modes: [_ | rest]} = state),
    do: %{state | template_modes: rest}

  defp pop_template_mode(%__MODULE__{template_modes: []} = state), do: state

  # "in template": replace the current template insertion mode with `mode`, switch
  # the insertion mode to it, and reprocess the token there.
  defp switch_template_mode(token, state, mode) do
    modes =
      case state.template_modes do
        [_ | rest] -> [mode | rest]
        [] -> [mode]
      end

    reprocess(mode, token, %{state | template_modes: modes, mode: mode})
  end

  # "Insert a comment": at the appropriate insertion location.
  defp insert_comment(token, state) do
    insert_at(appropriate_insertion_location(state), comment(token, state))
  end

  # "Insert a character": at the appropriate insertion location, coalescing with a
  # trailing Text node so a contiguous run is one Text node. (When foster
  # parenting the coalescing target is the node immediately before the reference.)
  defp insert_characters(data, state) do
    {parent, reference} = appropriate_insertion_location(state)

    case preceding_text(parent, reference) do
      %Node{type: :text} = text -> Node.set_text_content(text, Node.value(text) <> data)
      _ -> insert_at({parent, reference}, DOM.create_text_node(state.document, data))
    end

    state
  end

  # The text node a character run would coalesce with: the child immediately
  # before `reference` (or the last child when appending).
  defp preceding_text(parent, nil), do: parent |> Node.child_nodes() |> List.last()

  defp preceding_text(parent, reference) do
    parent |> Node.child_nodes() |> Enum.take_while(&(&1 != reference)) |> List.last()
  end

  # "Appropriate place for inserting a node" (§13.2.6.1): normally the current
  # node (append). With foster parenting enabled and the current node a table
  # section, redirect the insertion before the last table (or into its parent).
  # If the resulting parent is a template element, redirect into its content
  # DocumentFragment. Returns {parent, reference} where reference nil means append.
  defp appropriate_insertion_location(state) do
    target = current_node(state)

    location =
      if state.foster_parenting and Node.node_name(target) in ~w(table tbody tfoot thead tr) do
        foster_location(state)
      else
        {target, nil}
      end

    template_content_location(state, location)
  end

  # If the location's parent is a template element, the real location is inside
  # its content fragment, after the last child.
  defp template_content_location(state, {parent, _reference} = location) do
    case Map.get(state.contents, parent) do
      nil -> location
      content -> {content, nil}
    end
  end

  # Foster-parenting location: before the last open table if it has a parent,
  # else inside the element above it on the stack (templates deferred to tier 6).
  defp foster_location(state) do
    last_table = Enum.find(state.open_elements, &(Node.node_name(&1) == "table"))

    cond do
      is_nil(last_table) -> {List.last(state.open_elements) || state.document, nil}
      parent = Node.parent_node(last_table) -> {parent, last_table}
      :else -> {element_above(state.open_elements, last_table), nil}
    end
  end

  # The element immediately above `node` in the stack of open elements — i.e.
  # nearer the root (the entry pushed just *before* node). The stack list has
  # head = most recent (deepest), so "above" is the list-successor of node.
  defp element_above([node, above | _], node), do: above
  defp element_above([_ | rest], node), do: element_above(rest, node)

  # Insert `child` at {parent, reference}: append when reference is nil, else
  # insert immediately before reference.
  defp insert_at({parent, nil}, child), do: Node.append_child(parent, child)
  defp insert_at({parent, reference}, child), do: Node.insert_before(parent, child, reference)

  # Add each attribute not already present on `element` (the html/body attribute
  # merge for a duplicate start tag). `nil` element (fragment case) is a no-op.
  defp merge_attributes(nil, _attributes), do: :ok

  defp merge_attributes(element, attributes) do
    Enum.each(attributes, fn {name, value} ->
      if not Element.has_attribute(element, name),
        do: Element.set_attribute(element, name, value)
    end)
  end

  # "Create an element for the token": element + its attributes.
  defp create_element_for(token, state) do
    element = DOM.create_element(state.document, token.name)

    Enum.each(token.attributes, fn {name, value} ->
      Element.set_attribute(element, name, value)
    end)

    element
  end

  defp comment(token, state), do: DOM.create_comment(state.document, token.data)

  # ==========================================================================
  # Stack helpers
  # ==========================================================================

  # The current node = the bottommost (top-of-stack, list head) open element; the
  # Document when the stack is empty.
  defp current_node(%__MODULE__{open_elements: [current | _]}), do: current
  defp current_node(%__MODULE__{open_elements: [], document: document}), do: document

  # Pop the current node off the stack.
  defp pop(%__MODULE__{open_elements: [_ | rest]} = state), do: %{state | open_elements: rest}
  defp pop(%__MODULE__{open_elements: []} = state), do: state

  # Pop down to and including the first element named `name` (no-op if absent —
  # returns the original stack).
  defp pop_to(stack, name), do: pop_to(stack, name, stack)

  defp pop_to([el | rest], name, original) do
    if Node.node_name(el) == name, do: rest, else: pop_to(rest, name, original)
  end

  defp pop_to([], _name, original), do: original

  defp append(parent, child), do: Node.append_child(parent, child)

  # Pop the stack down to and INCLUDING the first element named `name`. (Callers
  # guarantee it is present via a scope check.)
  defp pop_through(state, name) do
    %{state | open_elements: pop_to(state.open_elements, name)}
  end

  # Pop down to and including the first heading (h1..h6) on the stack.
  defp pop_through_heading(%__MODULE__{open_elements: [el | rest]} = state) do
    if heading?(el),
      do: %{state | open_elements: rest},
      else: pop_through_heading(%{state | open_elements: rest})
  end

  # Pop the current node if it is named `name`.
  defp pop_if_current(state, name) do
    if Node.node_name(current_node(state)) == name, do: pop(state), else: state
  end

  # The void elements whose start tag sets frameset-ok to "not ok" (§13.2.6.4.7).
  # input does so only when its type is not "hidden".
  defp void_clears_frameset?(name, _token) when name in ~w(area br embed img keygen wbr), do: true
  defp void_clears_frameset?("input", token), do: not hidden_input?(token)
  defp void_clears_frameset?(_name, _token), do: false

  # Whether an in-body <frameset> may replace the body: the stack has more than
  # one node, the second element (from the bottom) is a body, and frameset-ok is
  # still set.
  defp frameset_replaceable?(state) do
    body = second_element(state)
    not is_nil(body) and Node.node_name(body) == "body" and state.frameset_ok
  end

  # The second element from the bottom of the stack (the stack head is the top),
  # i.e. the second-to-last list entry, or nil if the stack has one node.
  defp second_element(state) do
    case Enum.reverse(state.open_elements) do
      [_html, second | _] -> second
      _ -> nil
    end
  end

  # Pop the stack down to (but not including) the bottom html root element.
  defp pop_to_html_root(%__MODULE__{open_elements: [_ | _] = stack} = state) do
    %{state | open_elements: [List.last(stack)]}
  end

  # "Have a select in select scope" (§13.2.4.2): walk the stack while nodes are
  # optgroup/option; a select returns true, any other element returns false.
  defp select_in_scope?(%__MODULE__{open_elements: [el | rest]} = state) do
    case Node.node_name(el) do
      "select" -> true
      name when name in ~w(optgroup option) -> select_in_scope?(%{state | open_elements: rest})
      _ -> false
    end
  end

  defp select_in_scope?(%__MODULE__{open_elements: []}), do: false

  # For </optgroup>: if the current node is an option whose immediately-lower
  # stack entry is an optgroup, pop the option first (so the optgroup can close).
  defp pop_option_before_optgroup(%__MODULE__{open_elements: [a, b | _]} = state) do
    if Node.node_name(a) == "option" and Node.node_name(b) == "optgroup",
      do: pop(state),
      else: state
  end

  defp pop_option_before_optgroup(state), do: state

  # "in select in table" table-element tokens: pop through the select, reset the
  # insertion mode, and reprocess the token in the new mode.
  defp select_in_table_out(token, state) do
    state = state |> pop_through("select") |> reset_insertion_mode()
    reprocess(state.mode, token, state)
  end

  # ==========================================================================
  # §13.2.6.3 / §13.2.4.2  Implied-end-tag and scope algorithms
  # ==========================================================================

  # "Generate implied end tags": while the current node is an implied-end-tag
  # element (optionally excluding `except`), pop it.
  defp generate_implied_end_tags(state, except \\ nil) do
    node = current_node(state)
    name = Node.node_name(node)

    if name in @implied_end_tags and name != except do
      generate_implied_end_tags(pop(state), except)
    else
      state
    end
  end

  # "Generate implied end tags thoroughly" (§13.2.6.3): also pops caption/colgroup
  # and the table-section/row/cell elements — used when closing a template.
  @thorough_implied_end_tags @implied_end_tags ++
                               ~w(caption colgroup tbody td tfoot th thead tr)

  defp generate_all_implied_end_tags(state) do
    if Node.node_name(current_node(state)) in @thorough_implied_end_tags,
      do: generate_all_implied_end_tags(pop(state)),
      else: state
  end

  # "Close a p element" (§13.2.6.4.7): generate implied end tags except p, then
  # pop through the p element.
  defp close_p_element(state) do
    state |> generate_implied_end_tags("p") |> pop_through("p")
  end

  # If a p element is in button scope, close it (used by block-level start tags).
  defp close_p_if_button_scope(state) do
    if has_in_scope?(state, "p", @button_scope_markers), do: close_p_element(state), else: state
  end

  # "li"/"dd"/"dt" start tags (§13.2.6.4.7): walk the stack from the current
  # node; on a `names` element, generate implied end tags (except it) and pop
  # through it, stopping. Stop early (without closing) on a "special" element
  # that is not address/div/p.
  defp close_list_item(state, names), do: close_list_item(state, names, state.open_elements)

  defp close_list_item(state, names, [node | rest]) do
    name = Node.node_name(node)

    cond do
      name in names -> state |> generate_implied_end_tags(name) |> pop_through(name)
      special?(name) and name not in ~w(address div p) -> state
      :else -> close_list_item(state, names, rest)
    end
  end

  defp close_list_item(state, _names, []), do: state

  # "Have an element named `name` in scope", parameterized by the terminating
  # marker set: walk the stack; a match (an HTML-namespace element with that name)
  # returns true; a scope boundary returns false. Foreign integration-point and
  # foreign elements are always boundaries (their names only count in-namespace).
  defp has_in_scope?(state, name, markers),
    do: in_scope?(state, state.open_elements, name, markers)

  defp in_scope?(state, [el | rest], name, markers) do
    html? = namespace_of(state, el) == :html
    node_name = Node.node_name(el)

    cond do
      html? and node_name == name -> true
      html? and node_name in markers -> false
      not html? and foreign_scope_marker?(state, el) -> false
      :else -> in_scope?(state, rest, name, markers)
    end
  end

  defp in_scope?(_state, [], _name, _markers), do: false

  # The foreign members of the default scope set: MathML text integration points
  # and annotation-xml; SVG foreignObject/desc/title.
  defp foreign_scope_marker?(state, el) do
    mathml_text_point?(state, el) or html_integration_point?(state, el) or
      (namespace_of(state, el) == :mathml and Node.node_name(el) == "annotation-xml")
  end

  # "Have a heading (h1..h6) in scope" (for the heading end tag): walk the stack;
  # any heading returns true, a default-scope marker returns false.
  defp any_heading_in_scope?(state), do: heading_in_scope?(state.open_elements)

  defp heading_in_scope?([el | rest]) do
    name = Node.node_name(el)

    cond do
      heading?(el) -> true
      name in @scope_markers -> false
      :else -> heading_in_scope?(rest)
    end
  end

  defp heading_in_scope?([]), do: false

  # "Any other end tag" loop (§13.2.6.4.7): walk from the current node; a matching
  # element closes (generate implied end tags except it, pop through it); a
  # "special" element stops the loop (parse error, ignore).
  defp any_other_end_tag(state, name, [el | rest]) do
    node_name = Node.node_name(el)

    cond do
      node_name == name ->
        state
        |> generate_implied_end_tags(name)
        |> then(&%{&1 | open_elements: drop_including(&1.open_elements, el)})

      special?(node_name) ->
        state

      :else ->
        any_other_end_tag(state, name, rest)
    end
  end

  defp any_other_end_tag(state, _name, []), do: state

  # Drop stack entries up to and including `el` (by identity).
  defp drop_including([el | rest], el), do: rest
  defp drop_including([_ | rest], el), do: drop_including(rest, el)

  defp heading?(node), do: Node.node_name(node) in ~w(h1 h2 h3 h4 h5 h6)

  # "Special" category elements (§13.2.6.4.7 — subset relevant to tier 2's end-tag
  # loop; the full list grows as later tiers add table/foreign handling).
  @special ~w(address applet area article aside base basefont bgsound blockquote
              body br button caption center col colgroup dd details dir div dl dt
              embed fieldset figcaption figure footer form frame frameset h1 h2 h3
              h4 h5 h6 head header hgroup hr html iframe img input keygen li link
              listing main marquee menu meta nav noembed noframes noscript object
              ol p param plaintext pre script section select source style summary
              table tbody td template textarea tfoot th thead title tr track ul
              wbr xmp)

  defp special?(name), do: name in @special

  # ==========================================================================
  # §13.2.6.4.9-.15  Table insertion-mode algorithms
  # ==========================================================================

  # "Clear the stack back to a table context": pop until the current node is a
  # table, template, or html element.
  defp clear_to_table_context(state), do: clear_stack_to(state, ~w(table template html))

  # "Clear the stack back to a table body context": pop until tbody/tfoot/thead/
  # template/html.
  defp clear_to_table_body_context(state) do
    clear_stack_to(state, ~w(tbody tfoot thead template html))
  end

  # "Clear the stack back to a table row context": pop until tr/template/html.
  defp clear_to_table_row_context(state), do: clear_stack_to(state, ~w(tr template html))

  defp clear_stack_to(state, names) do
    if Node.node_name(current_node(state)) in names,
      do: state,
      else: clear_stack_to(pop(state), names)
  end

  # Flush the pending table character tokens and switch back to the original
  # insertion mode. Whitespace-only runs are inserted in the table section;
  # a run with non-whitespace is a parse error and foster-parented.
  defp flush_table_text(state) do
    data = state.pending_table_chars |> Enum.reverse() |> IO.iodata_to_binary()
    state = %{state | pending_table_chars: [], mode: state.original_mode}

    cond do
      data == "" -> state
      whitespace?(data) -> insert_characters(data, state)
      :else -> anything_else_in_table(%Token.Character{data: data}, state)
    end
  end

  # "in table" anything-else: enable foster parenting, process using "in body",
  # then disable foster parenting.
  defp anything_else_in_table(token, state) do
    state = reprocess(:in_body, token, %{state | foster_parenting: true})
    %{state | foster_parenting: false}
  end

  # An "input" start tag counts as hidden when its type attribute is an ASCII
  # case-insensitive match for "hidden".
  defp hidden_input?(token) do
    Enum.any?(token.attributes, fn {name, value} ->
      String.downcase(name) == "type" and String.downcase(value) == "hidden"
    end)
  end

  # "in caption" </caption>: if a caption is in table scope, generate implied end
  # tags, pop through the caption, clear the active formatting list up to the last
  # marker, switch to "in table" (else parse error, ignore).
  defp close_caption(state) do
    if has_in_scope?(state, "caption", @table_scope_markers) do
      state
      |> generate_implied_end_tags()
      |> pop_through("caption")
      |> clear_formatting_to_marker()
      |> Map.put(:mode, :in_table)
    else
      state
    end
  end

  defp close_caption_and_reprocess(token, state) do
    if has_in_scope?(state, "caption", @table_scope_markers),
      do: reprocess(:in_table, token, close_caption(state)),
      else: state
  end

  # "in cell" close-the-cell: generate implied end tags, pop through the td/th,
  # clear the active formatting list up to the last marker, switch to "in row",
  # then reprocess the token.
  defp close_cell_and_reprocess(token, state) do
    name = if has_in_scope?(state, "td", @table_scope_markers), do: "td", else: "th"

    state =
      state
      |> generate_implied_end_tags()
      |> pop_through(name)
      |> clear_formatting_to_marker()
      |> Map.put(:mode, :in_row)

    reprocess(:in_row, token, state)
  end

  # "in table body" -> "in table": if a tbody/thead/tfoot is in table scope, clear
  # to a table body context, pop it, switch to "in table", reprocess.
  defp table_body_to_table(token, state) do
    if any_in_scope?(state, ~w(tbody thead tfoot), @table_scope_markers) do
      state = %{pop(clear_to_table_body_context(state)) | mode: :in_table}
      reprocess(:in_table, token, state)
    else
      state
    end
  end

  # "in row" -> "in table body": if a tr is in table scope, clear to a table row
  # context, pop the tr, switch to "in table body", reprocess.
  defp row_to_table_body(token, state) do
    if has_in_scope?(state, "tr", @table_scope_markers) do
      state = %{pop(clear_to_table_row_context(state)) | mode: :in_table_body}
      reprocess(:in_table_body, token, state)
    else
      state
    end
  end

  # "Have any of `names` in the given scope."
  defp any_in_scope?(state, names, markers) do
    Enum.any?(names, &has_in_scope?(state, &1, markers))
  end

  # "Reset the insertion mode appropriately" (§13.2.6.3): scan the stack top-down
  # and switch to the matching mode. In the fragment case, the last (root) node is
  # treated as the context element. Falls through to "in body".
  defp reset_insertion_mode(state) do
    %{state | mode: reset_mode_for(state, state.open_elements)}
  end

  # The last node on the stack, in the fragment case, is the context element.
  defp reset_mode_for(state, [last]) do
    node = if state.context, do: state.context, else: last
    template_mode(state, node) || select_mode(node, []) || mode_for_node(node) || :in_body
  end

  defp reset_mode_for(state, [node | rest]) do
    template_mode(state, node) || select_mode(node, rest) || mode_for_node(node) ||
      reset_mode_for(state, rest)
  end

  defp reset_mode_for(_state, []), do: :in_body

  # A template element resets to the current template insertion mode.
  defp template_mode(state, node) do
    if Node.node_name(node) == "template", do: List.first(state.template_modes)
  end

  # A "select" open element resets to "in select in table" if a table is below it
  # on the stack (before a template), else "in select" (§13.2.6.3).
  defp select_mode(node, below) do
    if Node.node_name(node) == "select" do
      if Enum.any?(
           Enum.take_while(below, &(Node.node_name(&1) != "template")),
           &(Node.node_name(&1) == "table")
         ),
         do: :in_select_in_table,
         else: :in_select
    end
  end

  # The insertion mode a given open element selects when resetting (§13.2.6.3 —
  # table subset). nil = keep scanning further up the stack.
  @reset_modes %{
    "td" => :in_cell,
    "th" => :in_cell,
    "tr" => :in_row,
    "tbody" => :in_table_body,
    "thead" => :in_table_body,
    "tfoot" => :in_table_body,
    "caption" => :in_caption,
    "colgroup" => :in_column_group,
    "table" => :in_table,
    "head" => :in_head,
    "body" => :in_body,
    "html" => :before_head
  }

  defp mode_for_node(node), do: Map.get(@reset_modes, Node.node_name(node))

  # ==========================================================================
  # §13.2.4.3 / §13.2.6.4.7  Active formatting list + adoption agency
  # ==========================================================================

  # Insert a formatting element: reconstruct, insert, push onto the AFE list.
  defp insert_formatting(token, state) do
    state |> reconstruct_formatting() |> insert_and_push(token)
  end

  # Insert an HTML element for `token`, then push it onto the AFE list.
  defp insert_and_push(state, token) do
    {element, state} = insert_html_element(token, state)
    push_formatting(state, element, token)
  end

  # "Insert a marker at the end of the list of active formatting elements."
  defp insert_marker(state), do: %{state | active_formatting: [:marker | state.active_formatting]}

  # "Push onto the list of active formatting elements" with the Noah's Ark clause
  # (§13.2.4.3): before adding, if three entries after the last marker already
  # share the token's tag name + attributes, remove the earliest such entry.
  defp push_formatting(state, element, token) do
    recent = Enum.take_while(state.active_formatting, &(&1 != :marker))
    matches = Enum.filter(recent, fn {_el, t} -> same_formatting?(t, token) end)

    afe =
      if length(matches) >= 3 do
        earliest = List.last(matches)
        List.delete(state.active_formatting, earliest)
      else
        state.active_formatting
      end

    %{state | active_formatting: [{element, token} | afe]}
  end

  # Two formatting tokens match (Noah's Ark) when tag name + attribute set are
  # equal (attribute order does not matter).
  defp same_formatting?(a, b) do
    a.name == b.name and Enum.sort(a.attributes) == Enum.sort(b.attributes)
  end

  # The AFE entry for the most recent `name` element after the last marker, or nil.
  defp formatting_after_marker(state, name) do
    state.active_formatting
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.find(fn {el, _t} -> Node.node_name(el) == name end)
  end

  # "Clear the list of active formatting elements up to the last marker": drop
  # entries (including the marker) from the head.
  defp clear_formatting_to_marker(state) do
    %{state | active_formatting: drop_to_marker(state.active_formatting)}
  end

  defp drop_to_marker([:marker | rest]), do: rest
  defp drop_to_marker([_ | rest]), do: drop_to_marker(rest)
  defp drop_to_marker([]), do: []

  # "Reconstruct the active formatting elements" (§13.2.4.3): re-open any entry
  # after the last marker that is no longer on the stack of open elements.
  defp reconstruct_formatting(%__MODULE__{active_formatting: []} = state), do: state

  defp reconstruct_formatting(state) do
    case state.active_formatting do
      [:marker | _] -> state
      [{el, _} | _] -> if on_stack?(state, el), do: state, else: do_reconstruct(state)
    end
  end

  # Rebuild every stale entry from the earliest stale one forward. Entries are
  # head = most recent, so reverse to walk oldest-first; recreate each stale
  # entry's element (insert it, push onto the stack) and update the AFE entry.
  defp do_reconstruct(state) do
    {before_marker, marker_and_rest} = split_at_marker(state.active_formatting)

    rebuilt =
      before_marker
      |> Enum.reverse()
      |> Enum.reduce({[], state}, fn {el, token}, {acc, st} ->
        if on_stack?(st, el) do
          {[{el, token} | acc], st}
        else
          {new_el, st} = insert_html_element(token, st)
          {[{new_el, token} | acc], st}
        end
      end)

    {entries, state} = rebuilt
    %{state | active_formatting: entries ++ marker_and_rest}
  end

  # Split the AFE list into {entries before the last marker, [marker | rest]};
  # when there is no marker the second element is [].
  defp split_at_marker(afe) do
    before = Enum.take_while(afe, &(&1 != :marker))
    {before, Enum.drop(afe, length(before))}
  end

  defp on_stack?(state, element), do: element in state.open_elements

  defp remove_from_stack(state, element) do
    %{state | open_elements: List.delete(state.open_elements, element)}
  end

  defp remove_from_formatting(state, element) do
    afe = Enum.reject(state.active_formatting, &match?({^element, _}, &1))
    %{state | active_formatting: afe}
  end

  # Whether `element` currently has an AFE entry.
  defp in_formatting?(state, element) do
    Enum.any?(state.active_formatting, &match?({^element, _}, &1))
  end

  defp elem_of({element, _token}), do: element

  # Whether a formatting entry's element is on the stack of open elements.
  defp on_stack_entry?(state, entry), do: on_stack?(state, elem_of(entry))

  defp remove_from_formatting_entry(state, entry),
    do: remove_from_formatting(state, elem_of(entry))

  defp element_in_scope?(state, element) do
    has_in_scope?(state, Node.node_name(element), @scope_markers)
  end

  # The 0-based position of `element`'s AFE entry (head = 0).
  defp formatting_index(state, element) do
    Enum.find_index(state.active_formatting, &match?({^element, _}, &1))
  end

  # Insert an AFE entry at index `i` (bookmark position).
  defp insert_formatting_at(state, i, entry) do
    %{state | active_formatting: List.insert_at(state.active_formatting, i, entry)}
  end

  # "furthestBlock": the topmost node in the stack lower than `fmt_el` (i.e. more
  # recent — earlier in the list) that is in the special category, or nil.
  defp furthest_block(state, fmt_el) do
    state.open_elements
    |> Enum.take_while(&(&1 != fmt_el))
    |> Enum.reverse()
    |> Enum.find(&special?(Node.node_name(&1)))
  end

  # Pop the stack up to and including `element`.
  defp pop_including(state, element) do
    %{state | open_elements: drop_including(state.open_elements, element)}
  end

  # Insert `new_el` into the stack immediately below `furthest` (one position more
  # recent — nearer the head — than furthest).
  defp insert_below_furthest(state, furthest, new_el) do
    i = Enum.find_index(state.open_elements, &(&1 == furthest))
    %{state | open_elements: List.insert_at(state.open_elements, i, new_el)}
  end

  # Create a fresh element for `old`'s formatting token; replace `old` in both the
  # AFE list and the stack with the new element. Returns {new_element, state}.
  defp recreate_formatting(state, old) do
    {^old, token} = Enum.find(state.active_formatting, &match?({^old, _}, &1))
    new = create_element_for(token, state)

    afe = Enum.map(state.active_formatting, &replace_entry(&1, old, {new, token}))
    stack = Enum.map(state.open_elements, &if(&1 == old, do: new, else: &1))
    {new, %{state | active_formatting: afe, open_elements: stack}}
  end

  defp replace_entry({old, _}, old, new_entry), do: new_entry
  defp replace_entry(entry, _old, _new), do: entry

  # The appropriate insertion location with `target` as the override target
  # (foster parenting honored). Returns {parent, reference}.
  defp appropriate_insertion_location_for(state, target) do
    if state.foster_parenting and Node.node_name(target) in ~w(table tbody tfoot thead tr) do
      foster_location(state)
    else
      {target, nil}
    end
  end

  # "The adoption agency algorithm" (§13.2.6.4.7). `token` is the end tag whose
  # tag name is `subject`.
  defp adoption_agency(state, %{name: subject} = token) do
    current = current_node(state)

    # If the current node is an HTML element named subject and is NOT in the AFE
    # list, just pop it and return.
    if Node.node_name(current) == subject and not in_formatting?(state, current) do
      remove_from_stack(state, current)
    else
      adoption_outer_loop(state, subject, token, 0)
    end
  end

  # The outer loop (at most 8 iterations).
  defp adoption_outer_loop(state, _subject, _token, 8), do: state

  defp adoption_outer_loop(state, subject, token, counter) do
    formatting = formatting_after_marker(state, subject)

    cond do
      # No such formatting element: act as "any other end tag" and return.
      is_nil(formatting) ->
        any_other_end_tag(state, subject, state.open_elements)

      # In the AFE list but not on the stack: parse error, remove from AFE, return.
      not on_stack_entry?(state, formatting) ->
        remove_from_formatting_entry(state, formatting)

      # On the stack but not in scope: parse error, return unchanged.
      not element_in_scope?(state, elem_of(formatting)) ->
        state

      :else ->
        adoption_reparent(state, subject, token, counter, formatting)
    end
  end

  # Steps 8-19: locate the furthest block, run the inner loop, reparent.
  defp adoption_reparent(state, subject, token, counter, {fmt_el, _fmt_token} = formatting) do
    furthest = furthest_block(state, fmt_el)

    if is_nil(furthest) do
      # No furthest block: pop the stack up to and including the formatting
      # element, remove it from the AFE list, and return.
      state
      |> pop_including(fmt_el)
      |> remove_from_formatting(fmt_el)
    else
      state
      |> run_adoption(formatting, furthest)
      |> adoption_outer_loop(subject, token, counter + 1)
    end
  end

  # Steps 8-19: the inner loop plus the final reparent/replace. `common_ancestor`
  # is the element immediately above the formatting element on the stack.
  #
  # The stack (state.open_elements) is head = most recent (bottom of the DOM).
  # "lower in the stack" = closer to the head. We work with the reversed stack as
  # a positional list so "the element immediately above node" is the predecessor
  # index — this makes the "before it was removed" clause (step 14.2) trivial.
  defp run_adoption(state, {fmt_el, fmt_token}, furthest) do
    common_ancestor = element_above(state.open_elements, fmt_el)
    bookmark = formatting_index(state, fmt_el)

    {state, last_node, bookmark} =
      adoption_inner_loop({fmt_el, furthest}, state, furthest, furthest, 0, bookmark)

    # Step 15: insert last_node into common_ancestor at the appropriate place.
    insert_at(appropriate_insertion_location_for(state, common_ancestor), last_node)

    # Steps 16-18: new element for the formatting token; move furthest's children
    # into it; append it to furthest.
    new_el = create_element_for(fmt_token, state)
    Enum.each(Node.child_nodes(furthest), &Node.append_child(new_el, &1))
    Node.append_child(furthest, new_el)

    state
    # Step 19: replace fmt_el in the AFE list with the new element at the bookmark.
    |> remove_from_formatting(fmt_el)
    |> insert_formatting_at(bookmark, {new_el, fmt_token})
    # Step 20: remove fmt_el from the stack; insert new_el just below furthest.
    |> remove_from_stack(fmt_el)
    |> insert_below_furthest(furthest, new_el)
  end

  # The inner loop (step 14): walk upward from furthest toward fmt_el. `node` and
  # `last_node` start as furthest. `ctx` is the loop-invariant {fmt_el, furthest}.
  # Returns {state, last_node, bookmark}.
  defp adoption_inner_loop({fmt_el, _furthest} = ctx, state, node, last_node, inner, bookmark) do
    above = element_above(state.open_elements, node)

    if above == fmt_el do
      # Step 14.3: reached the formatting element — stop.
      {state, last_node, bookmark}
    else
      inner = inner + 1
      # Step 14.4: after three iterations, drop `above` from the AFE list.
      state = if inner > 3, do: remove_from_formatting(state, above), else: state

      inner_step(
        in_formatting?(state, above),
        ctx,
        state,
        node,
        last_node,
        inner,
        bookmark,
        above
      )
    end
  end

  # Step 14.6-14.9: `above` is still a formatting entry — recreate it, thread
  # last_node into the new element, and advance the walk to the new element.
  defp inner_step(
         true,
         {_fmt_el, furthest} = ctx,
         state,
         _node,
         last_node,
         inner,
         bookmark,
         above
       ) do
    {new, state} = recreate_formatting(state, above)
    bookmark = if last_node == furthest, do: formatting_index(state, new), else: bookmark
    Node.append_child(new, last_node)
    adoption_inner_loop(ctx, state, new, new, inner, bookmark)
  end

  # Step 14.5: `above` is not in the AFE list — remove it from the stack and
  # continue with `node` unchanged (the next iteration re-reads "the element above
  # node", which is now what was above `above`).
  defp inner_step(false, ctx, state, node, last_node, inner, bookmark, above) do
    adoption_inner_loop(ctx, remove_from_stack(state, above), node, last_node, inner, bookmark)
  end

  # ==========================================================================
  # §13.2.6 / §13.2.6.5  Foreign content (SVG / MathML)
  # ==========================================================================

  # SVG element tag-name case fixups (§13.2.6.5).
  @svg_tags %{
    "altglyph" => "altGlyph",
    "altglyphdef" => "altGlyphDef",
    "altglyphitem" => "altGlyphItem",
    "animatecolor" => "animateColor",
    "animatemotion" => "animateMotion",
    "animatetransform" => "animateTransform",
    "clippath" => "clipPath",
    "feblend" => "feBlend",
    "fecolormatrix" => "feColorMatrix",
    "fecomponenttransfer" => "feComponentTransfer",
    "fecomposite" => "feComposite",
    "feconvolvematrix" => "feConvolveMatrix",
    "fediffuselighting" => "feDiffuseLighting",
    "fedisplacementmap" => "feDisplacementMap",
    "fedistantlight" => "feDistantLight",
    "fedropshadow" => "feDropShadow",
    "feflood" => "feFlood",
    "fefunca" => "feFuncA",
    "fefuncb" => "feFuncB",
    "fefuncg" => "feFuncG",
    "fefuncr" => "feFuncR",
    "fegaussianblur" => "feGaussianBlur",
    "feimage" => "feImage",
    "femerge" => "feMerge",
    "femergenode" => "feMergeNode",
    "femorphology" => "feMorphology",
    "feoffset" => "feOffset",
    "fepointlight" => "fePointLight",
    "fespecularlighting" => "feSpecularLighting",
    "fespotlight" => "feSpotLight",
    "fetile" => "feTile",
    "feturbulence" => "feTurbulence",
    "foreignobject" => "foreignObject",
    "glyphref" => "glyphRef",
    "lineargradient" => "linearGradient",
    "radialgradient" => "radialGradient",
    "textpath" => "textPath"
  }

  # SVG attribute-name case fixups (§13.2.6.5).
  @svg_attributes %{
    "attributename" => "attributeName",
    "attributetype" => "attributeType",
    "basefrequency" => "baseFrequency",
    "baseprofile" => "baseProfile",
    "calcmode" => "calcMode",
    "clippathunits" => "clipPathUnits",
    "diffuseconstant" => "diffuseConstant",
    "edgemode" => "edgeMode",
    "filterunits" => "filterUnits",
    "glyphref" => "glyphRef",
    "gradienttransform" => "gradientTransform",
    "gradientunits" => "gradientUnits",
    "kernelmatrix" => "kernelMatrix",
    "kernelunitlength" => "kernelUnitLength",
    "keypoints" => "keyPoints",
    "keysplines" => "keySplines",
    "keytimes" => "keyTimes",
    "lengthadjust" => "lengthAdjust",
    "limitingconeangle" => "limitingConeAngle",
    "markerheight" => "markerHeight",
    "markerunits" => "markerUnits",
    "markerwidth" => "markerWidth",
    "maskcontentunits" => "maskContentUnits",
    "maskunits" => "maskUnits",
    "numoctaves" => "numOctaves",
    "pathlength" => "pathLength",
    "patterncontentunits" => "patternContentUnits",
    "patterntransform" => "patternTransform",
    "patternunits" => "patternUnits",
    "pointsatx" => "pointsAtX",
    "pointsaty" => "pointsAtY",
    "pointsatz" => "pointsAtZ",
    "preservealpha" => "preserveAlpha",
    "preserveaspectratio" => "preserveAspectRatio",
    "primitiveunits" => "primitiveUnits",
    "refx" => "refX",
    "refy" => "refY",
    "repeatcount" => "repeatCount",
    "repeatdur" => "repeatDur",
    "requiredextensions" => "requiredExtensions",
    "requiredfeatures" => "requiredFeatures",
    "specularconstant" => "specularConstant",
    "specularexponent" => "specularExponent",
    "spreadmethod" => "spreadMethod",
    "startoffset" => "startOffset",
    "stddeviation" => "stdDeviation",
    "stitchtiles" => "stitchTiles",
    "surfacescale" => "surfaceScale",
    "systemlanguage" => "systemLanguage",
    "tablevalues" => "tableValues",
    "targetx" => "targetX",
    "targety" => "targetY",
    "textlength" => "textLength",
    "viewbox" => "viewBox",
    "viewtarget" => "viewTarget",
    "xchannelselector" => "xChannelSelector",
    "ychannelselector" => "yChannelSelector",
    "zoomandpan" => "zoomAndPan"
  }

  # "Adjust foreign attributes" prefix table (§13.2.6.5): a prefixed name becomes
  # "prefix local" (space-separated) so the .dat outline renders both columns.
  @foreign_attributes %{
    "xlink:actuate" => "xlink actuate",
    "xlink:arcrole" => "xlink arcrole",
    "xlink:href" => "xlink href",
    "xlink:role" => "xlink role",
    "xlink:show" => "xlink show",
    "xlink:title" => "xlink title",
    "xlink:type" => "xlink type",
    "xml:lang" => "xml lang",
    "xml:space" => "xml space",
    "xmlns" => "xmlns",
    "xmlns:xlink" => "xmlns xlink"
  }

  defp svg_tag_name(name), do: Map.get(@svg_tags, name, name)

  # The adjusted current node: in the fragment case, when the stack holds only the
  # synthetic root, it is the context element; otherwise the current node.
  defp adjusted_current_node(%__MODULE__{context: context, open_elements: [_root]})
       when not is_nil(context),
       do: context

  defp adjusted_current_node(state), do: current_node(state)

  # The namespace of an element handle: :svg / :mathml if recorded, else :html.
  defp namespace_of(_state, %Node{type: type}) when type != :element, do: :html
  defp namespace_of(state, %Node{} = el), do: Map.get(state.namespaces, el, :html)

  # A MathML text integration point: an mi/mo/mn/ms/mtext element in the MathML
  # namespace.
  defp mathml_text_point?(state, node) do
    namespace_of(state, node) == :mathml and Node.node_name(node) in ~w(mi mo mn ms mtext)
  end

  # An HTML integration point: a MathML annotation-xml whose encoding attribute is
  # text/html or application/xhtml+xml; or an SVG foreignObject/desc/title.
  defp html_integration_point?(state, node) do
    case namespace_of(state, node) do
      :svg -> Node.node_name(node) in ~w(foreignObject desc title)
      :mathml -> annotation_xml_html?(node)
      :html -> false
    end
  end

  defp annotation_xml_html?(node) do
    Node.node_name(node) == "annotation-xml" and
      String.downcase(Element.get_attribute(node, "encoding") || "") in [
        "text/html",
        "application/xhtml+xml"
      ]
  end

  # "Insert a foreign element" from an in-body svg/math start tag: reconstruct,
  # adjust foreign attributes, insert in `namespace`; a self-closing tag is
  # immediately popped.
  defp insert_foreign_start(namespace, token, state) do
    state = reconstruct_formatting(state)
    {_el, state} = insert_foreign_element(adjust_foreign_attributes(token), namespace, state)
    if token.self_closing, do: pop(state), else: state
  end

  # "Insert a foreign element": create it in `namespace` (with adjusted attrs),
  # insert at the appropriate place, push it, and record its namespace.
  defp insert_foreign_element(token, namespace, state) do
    element = DOM._create_element_ns(state.document, token.name, namespace, token.attributes)
    insert_at(appropriate_insertion_location(state), element)

    {element,
     %{
       state
       | open_elements: [element | state.open_elements],
         namespaces: Map.put(state.namespaces, element, namespace)
     }}
  end

  # §13.2.6.5  Rules for parsing tokens in foreign content.

  # A NULL character: insert a U+FFFD replacement character.
  defp process_foreign(%Token.Character{data: data}, state) do
    insert_characters(String.replace(data, "\0", "�"), state)
  end

  defp process_foreign(%Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  defp process_foreign(%Token.Doctype{}, state), do: state

  # A start tag that "breaks out" of foreign content (b/big/…/font-with-attrs) or
  # an end tag br/p: pop foreign elements until an integration point or HTML
  # element, then reprocess in HTML content.
  defp process_foreign(%Token.StartTag{name: name} = token, state)
       when name in ~w(b big blockquote body br center code dd div dl dt em embed
                       h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr
                       ol p pre ruby s small span strong strike sub sup table tt u
                       ul var) do
    breakout(token, state)
  end

  defp process_foreign(%Token.StartTag{name: "font"} = token, state) do
    if Enum.any?(token.attributes, fn {n, _} -> n in ~w(color face size) end),
      do: breakout(token, state),
      else: foreign_other_start(token, state)
  end

  defp process_foreign(%Token.EndTag{name: name} = token, state) when name in ~w(br p) do
    breakout(token, state)
  end

  # Any other start tag: adjust attributes for the adjusted current node's
  # namespace, insert a foreign element; a self-closing tag is popped.
  defp process_foreign(%Token.StartTag{} = token, state), do: foreign_other_start(token, state)

  # Any other end tag: walk the stack; if a node's lowercased name matches, pop
  # to it; on reaching an HTML-namespace element, process in HTML content.
  defp process_foreign(%Token.EndTag{name: name}, state) do
    foreign_end_tag(state, name, state.open_elements)
  end

  # "Breaks out" of foreign content: pop until an integration point or an HTML
  # element is the current node, then reprocess the token in HTML content.
  defp breakout(token, state) do
    state = pop_until_html_or_integration_point(state)
    step_html(token, state)
  end

  defp pop_until_html_or_integration_point(state) do
    node = current_node(state)

    if namespace_of(state, node) == :html or mathml_text_point?(state, node) or
         html_integration_point?(state, node) do
      state
    else
      pop_until_html_or_integration_point(pop(state))
    end
  end

  defp foreign_other_start(token, state) do
    namespace = namespace_of(state, adjusted_current_node(state))

    token =
      token
      |> adjust_foreign_tag(namespace)
      |> adjust_ns_attributes(namespace)
      |> adjust_foreign_attributes()

    {_el, state} = insert_foreign_element(token, namespace, state)
    if token.self_closing, do: pop(state), else: state
  end

  # Adjust the tag name of a foreign start tag: SVG gets the camelCase fixup.
  defp adjust_foreign_tag(token, :svg), do: %{token | name: svg_tag_name(token.name)}
  defp adjust_foreign_tag(token, _namespace), do: token

  # Per-namespace attribute case fixups (§13.2.6.5): SVG attribute names and the
  # MathML definitionURL are corrected. (Applied to any foreign element, not just
  # the top-level math/svg — fixes e.g. <mn definitionurl=…> inside <math>.)
  defp adjust_ns_attributes(token, :svg), do: adjust_svg_attributes(token)
  defp adjust_ns_attributes(token, :mathml), do: adjust_mathml_attributes(token)
  defp adjust_ns_attributes(token, _namespace), do: token

  defp adjust_svg_attributes(%Token.StartTag{} = token) do
    %{token | attributes: Enum.map(token.attributes, &adjust_svg_attribute/1)}
  end

  defp adjust_mathml_attributes(%Token.StartTag{} = token) do
    %{token | attributes: Enum.map(token.attributes, &adjust_mathml_attribute/1)}
  end

  # Per-namespace attribute adjust dispatched inside foreign_other_start's
  # adjust_foreign_attributes is not enough — SVG/MathML case fixups run first.
  defp adjust_svg_attribute({name, value}), do: {Map.get(@svg_attributes, name, name), value}

  defp adjust_mathml_attribute({"definitionurl", value}), do: {"definitionURL", value}
  defp adjust_mathml_attribute(attr), do: attr

  # "Adjust foreign attributes": rewrite the fixed prefixed attribute names so the
  # outline renders them as "prefix local" (a namespaced attribute).
  defp adjust_foreign_attributes(%Token.StartTag{} = token) do
    %{token | attributes: Enum.map(token.attributes, &adjust_foreign_attribute/1)}
  end

  defp adjust_foreign_attribute({name, value}),
    do: {Map.get(@foreign_attributes, name, name), value}

  # Any-other-end-tag loop (§13.2.6.5): from the current node down, a name match
  # pops to it; an HTML-namespace node hands off to HTML content.
  defp foreign_end_tag(state, name, [node | rest]) do
    cond do
      String.downcase(Node.node_name(node)) == name ->
        %{state | open_elements: drop_including(state.open_elements, node)}

      namespace_of(state, node) == :html ->
        process(state.mode, %Token.EndTag{name: name}, state)

      :else ->
        foreign_end_tag(state, name, rest)
    end
  end

  defp foreign_end_tag(state, _name, []), do: state

  # ==========================================================================
  # Whitespace helpers
  # ==========================================================================

  # HTML whitespace = tab, LF, FF, CR, space. (String.trim_leading/2 trims a
  # whole string, not a character set, so a regex expresses the set here.)
  @leading_whitespace ~r/\A[\t\n\f\r ]+/

  defp strip_leading_whitespace(data), do: String.replace(data, @leading_whitespace, "")

  defp split_leading_whitespace(data) do
    rest = strip_leading_whitespace(data)
    ws_len = byte_size(data) - byte_size(rest)
    {binary_part(data, 0, ws_len), rest}
  end

  # Whether `data` is entirely HTML whitespace (tab/LF/FF/CR/space).
  defp whitespace?(data), do: strip_leading_whitespace(data) == ""
end
