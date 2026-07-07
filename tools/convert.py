#!/usr/bin/env python3
"""UI-format ComfyUI workflow -> API-format /prompt JSON converter.

See task spec for the rules. This is a best-effort generic converter built
against object_info fetched live from the server.
"""
import json
import sys
import copy

OBJECT_INFO_PATH = __file__.rsplit("/", 1)[0] + "/object_info.json"

with open(OBJECT_INFO_PATH) as f:
    OBJECT_INFO = json.load(f)

SKIP_TYPES = {"MarkdownNote", "Note"}
PASSTHROUGH_TYPES = {"Reroute"}

WARNINGS = []
BOUNDARY_DEFAULT = "__BOUNDARY_DEFAULT__"
_NOTFOUND = object()


def _is_boundary_default(resolved):
    return isinstance(resolved, tuple) and len(resolved) == 2 and resolved[0] == BOUNDARY_DEFAULT


def warn(msg):
    WARNINGS.append(msg)
    print("WARN:", msg, file=sys.stderr)


def is_widget_type(type_name):
    """True if this input type is widget-capable (shows up in widgets_values).
    ComfyUI 0.24 mixes two COMBO schema styles: legacy (type_name IS the
    literal options list) and V3-style (type_name == "COMBO" string, with
    the options list nested in extra["options"])."""
    if isinstance(type_name, list):
        return True
    return type_name in ("INT", "FLOAT", "STRING", "BOOLEAN", "COMBO")


def ordered_schema_inputs(node_type):
    schema = OBJECT_INFO.get(node_type)
    if schema is None:
        raise KeyError(f"node type {node_type!r} not found in object_info")
    inp = schema.get("input", {})
    required = inp.get("required", {})
    items = list(required.items()) + list(inp.get("optional", {}).items())
    required_names = set(required.keys())
    return items, schema, required_names


def is_output_node(node_type):
    schema = OBJECT_INFO.get(node_type, {})
    return bool(schema.get("output_node"))


class FlatLinkTable:
    """Top-level graph links: list form [id, origin_id, origin_slot, target_id, target_slot, type]."""

    def __init__(self, links):
        self.by_id = {}
        for l in links:
            lid, oid, oslot, tid, tslot, ltype = l[0], l[1], l[2], l[3], l[4], l[5]
            self.by_id[lid] = dict(origin_id=oid, origin_slot=oslot, target_id=tid, target_slot=tslot, type=ltype)


class SubgraphLinkTable:
    """Subgraph-internal links: list of dicts."""

    def __init__(self, links):
        self.by_id = {}
        for l in links:
            self.by_id[l["id"]] = dict(
                origin_id=l["origin_id"], origin_slot=l["origin_slot"],
                target_id=l["target_id"], target_slot=l["target_slot"], type=l.get("type"),
            )


class Converter:
    def __init__(self, ui_graph):
        self.ui = ui_graph
        self.api = {}
        self.node_types = {}  # api_id (str) -> node_type, for reroute-following
        self.node_type_by_orig = {}  # (context_key, orig_id) -> type, used for reroute-following inside contexts
        self.subgraph_defs = {}
        for s in ui_graph.get("definitions", {}).get("subgraphs", []):
            self.subgraph_defs[s["id"]] = s
        self.top_links = FlatLinkTable(ui_graph.get("links", []))
        # per subgraph-instance-id: output_slot_map {slot:(api_id,slot)}
        self.instance_output_map = {}
        # map of top-level node id -> node dict, for reroute/type lookup
        self.top_nodes_by_id = {n["id"]: n for n in ui_graph.get("nodes", [])}

    # ---------- reroute helpers (top-level) ----------
    def resolve_top_source(self, node_id, slot):
        """Given an origin (node_id, slot) in the TOP graph, resolve through
        Reroute nodes and subgraph instances to a final (api_id, slot)."""
        node = self.top_nodes_by_id.get(node_id)
        if node is None:
            raise KeyError(f"top node {node_id} not found (reroute/output resolution)")
        ntype = node["type"]
        if ntype in PASSTHROUGH_TYPES:
            # Reroute has exactly one input; find its link
            inp = node.get("inputs", [])
            if not inp or inp[0].get("link") is None:
                raise ValueError(f"Reroute node {node_id} has no input link")
            link = self.top_links.by_id[inp[0]["link"]]
            return self.resolve_top_source(link["origin_id"], link["origin_slot"])
        if ntype in self.subgraph_defs:
            # subgraph instance -- must already have been processed
            if node_id not in self.instance_output_map:
                self.instance_output_map[node_id] = self.instantiate_subgraph(node)
            return self.instance_output_map[node_id][slot]
        # normal node
        return (str(node_id), slot)

    # ---------- main conversion ----------
    def convert(self):
        for node in self.ui.get("nodes", []):
            ntype = node["type"]
            if ntype in SKIP_TYPES or ntype in PASSTHROUGH_TYPES:
                continue
            if ntype in self.subgraph_defs:
                if node["id"] not in self.instance_output_map:
                    self.instance_output_map[node["id"]] = self.instantiate_subgraph(node)
                continue  # subgraph instance itself emits no direct API node
            self.emit_flat_node(node)
        return self.api

    def emit_flat_node(self, node):
        api_id = str(node["id"])
        ntype = node["type"]
        inputs_by_name = {i["name"]: i for i in node.get("inputs", [])}
        widgets_values = node.get("widgets_values", []) or []
        schema_items, schema, required_names = ordered_schema_inputs(ntype)

        result_inputs = {}
        widx = 0

        def link_resolver(link_id):
            link = self.top_links.by_id[link_id]
            return self.resolve_top_source(link["origin_id"], link["origin_slot"])

        widx = self._consume_inputs(
            schema_items, inputs_by_name, widgets_values, widx,
            result_inputs, link_resolver, node_label=f"{ntype}#{api_id}",
            widget_override=None, required_names=required_names,
        )
        self.api[api_id] = {"class_type": ntype, "inputs": result_inputs}
        self.node_types[api_id] = ntype

    def _consume_inputs(self, schema_items, inputs_by_name, widgets_values, widx,
                         result_inputs, link_resolver, node_label, widget_override,
                         required_names=frozenset(), materialize_const=None):
        for name, spec in schema_items:
            type_name = spec[0] if isinstance(spec, list) else spec
            extra = spec[1] if isinstance(spec, list) and len(spec) > 1 else {}
            in_entry = inputs_by_name.get(name)
            has_link = in_entry is not None and in_entry.get("link") is not None

            if type_name == "COMFY_AUTOGROW_V3":
                # variadic group of named connection-only inputs, e.g. ComfyMathExpression's
                # "values" produces "values.a", "values.b", ... entries in the node's own
                # "inputs" list (not in object_info's flat schema). Wire up whichever are
                # actually connected; unconnected slots are just unused UI placeholders.
                dotted_prefix = f"{name}."
                any_connected = False
                for iname, ientry in inputs_by_name.items():
                    if not iname.startswith(dotted_prefix):
                        continue
                    if ientry.get("link") is None:
                        continue
                    resolved = link_resolver(ientry["link"])
                    if resolved is None or _is_boundary_default(resolved):
                        warn(f"{node_label}: autogrow input '{iname}' resolved to no connection")
                        continue
                    result_inputs[iname] = list(resolved)
                    any_connected = True
                if not any_connected:
                    warn(f"{node_label}: no connected slots found for autogrow input '{name}'")
                continue

            if type_name == "COMFY_DYNAMICCOMBO_V3":
                # dynamic combo: one selector widget value, followed positionally
                # by the selected option's own required+optional widget values,
                # which get flattened as sibling keys in the API inputs dict.
                if widx < len(widgets_values):
                    selector = widgets_values[widx]
                else:
                    selector = None
                    warn(f"{node_label}: widgets_values exhausted for dynamic combo '{name}'")
                widx += 1
                if widget_override is not None and name in widget_override:
                    selector = widget_override[name]
                result_inputs[name] = selector
                options = extra.get("options", [])
                opt = next((o for o in options if o.get("key") == selector), None)
                if opt is None:
                    warn(f"{node_label}: dynamic combo '{name}' selector {selector!r} not found in options")
                    continue
                nested_req = opt.get("inputs", {}).get("required", {})
                nested_opt = opt.get("inputs", {}).get("optional", {})
                nested_items = list(nested_req.items()) + list(nested_opt.items())
                nested_result = {}
                widx = self._consume_inputs(
                    nested_items, inputs_by_name, widgets_values, widx,
                    nested_result, link_resolver, node_label, widget_override,
                    required_names=set(nested_req.keys()), materialize_const=materialize_const,
                )
                # API expects dotted keys "sampling_mode.temperature" etc for
                # the nested dynamic-combo option fields.
                for nname, nval in nested_result.items():
                    result_inputs[f"{name}.{nname}"] = nval
                continue

            widget_capable = is_widget_type(type_name)

            if widget_capable:
                # consume positional slot regardless of link override (per node4 finding)
                if widx < len(widgets_values):
                    val = widgets_values[widx]
                else:
                    val = extra.get("default")
                    warn(f"{node_label}: widgets_values exhausted for '{name}', using schema default {val!r}")
                widx += 1
                if isinstance(extra, dict) and extra.get("control_after_generate"):
                    widx += 1  # drop the randomize/fixed control string
                if has_link:
                    resolved = link_resolver(in_entry["link"])
                    if resolved is None or _is_boundary_default(resolved):
                        # boundary input not externally connected -> fall through to
                        # (possibly overridden) widget value
                        if widget_override is not None and name in widget_override:
                            val = widget_override[name]
                        result_inputs[name] = val
                    else:
                        result_inputs[name] = list(resolved)
                else:
                    if widget_override is not None and name in widget_override:
                        val = widget_override[name]
                    result_inputs[name] = val
            else:
                # pure connection type
                if has_link:
                    resolved = link_resolver(in_entry["link"])
                    if resolved is None:
                        warn(f"{node_label}: input '{name}' resolved to no connection (unset boundary)")
                    elif _is_boundary_default(resolved):
                        k = resolved[1]
                        made = materialize_const(k) if materialize_const else None
                        if made is not None:
                            result_inputs[name] = list(made)
                        else:
                            warn(f"{node_label}: input '{name}' fed by unconnected subgraph boundary slot {k} "
                                 f"and no literal could be materialized")
                    else:
                        result_inputs[name] = list(resolved)
                else:
                    if name in required_names:
                        warn(f"{node_label}: REQUIRED connection input '{name}' is not connected at all")
        return widx

    # ---------- subgraph instantiation ----------
    def instantiate_subgraph(self, instance_node):
        def_id = instance_node["type"]
        sdef = self.subgraph_defs[def_id]
        prefix = str(instance_node["id"])
        sub_links = SubgraphLinkTable(sdef.get("links", []))
        sub_nodes_by_id = {n["id"]: n for n in sdef.get("nodes", [])}

        # boundary input map: slot -> ('connect', (api_id,slot)) or ('default',)
        inst_inputs_by_name = {i["name"]: i for i in instance_node.get("inputs", [])}
        boundary_input_map = {}
        for k, def_in in enumerate(sdef.get("inputs", [])):
            name = def_in["name"]
            entry = inst_inputs_by_name.get(name)
            if entry is not None and entry.get("link") is not None:
                resolved = self.resolve_top_source(*self._link_origin_top(entry["link"]))
                boundary_input_map[k] = ("connect", resolved)
            else:
                boundary_input_map[k] = ("default",)

        # widget overrides from proxyWidgets + instance widgets_values (zip shortest)
        proxy_widgets = instance_node.get("properties", {}).get("proxyWidgets", []) or []
        inst_widget_values = instance_node.get("widgets_values", []) or []
        overrides = {}  # (orig_interior_id:int, widget_name:str) -> value
        for (pw_node_id, pw_name), val in zip(proxy_widgets, inst_widget_values):
            if pw_name == "control_after_generate":
                continue
            overrides[(int(pw_node_id), pw_name)] = val

        fresh = lambda oid: f"{prefix}:{oid}"

        def sub_link_resolver_factory(current_interior_id):
            def resolver(link_id):
                link = sub_links.by_id[link_id]
                oid, oslot = link["origin_id"], link["origin_slot"]
                if oid == -10:
                    res = boundary_input_map[oslot]
                    if res[0] == "connect":
                        return res[1]
                    return (BOUNDARY_DEFAULT, oslot)  # signal: no live connection, k=oslot
                return self._resolve_sub_source(oid, oslot, sub_nodes_by_id, sub_links, fresh)
            return resolver

        const_cache = {}

        def get_boundary_literal(k):
            def_in = sdef["inputs"][k]
            for linkid in def_in.get("linkIds", []):
                link = sub_links.by_id.get(linkid)
                if not link:
                    continue
                tid, tslot = link["target_id"], link["target_slot"]
                tnode = sub_nodes_by_id.get(tid)
                if not tnode:
                    continue
                matching = [i for i in tnode.get("inputs", []) if i.get("link") == linkid]
                if not matching:
                    continue
                wname = matching[0].get("widget", {}).get("name")
                if wname is None:
                    continue
                val = self._positional_widget_value(tnode, wname)
                if val is _NOTFOUND:
                    continue
                ov = overrides.get((tid, wname))
                return ov if ov is not None else val
            return None

        def materialize_const(k):
            if k in const_cache:
                return const_cache[k]
            lit = get_boundary_literal(k)
            if lit is None:
                const_cache[k] = None
                return None
            if isinstance(lit, bool):
                ctype = "PrimitiveBoolean"
            elif isinstance(lit, int):
                ctype = "PrimitiveInt"
            elif isinstance(lit, float):
                ctype = "PrimitiveFloat"
            elif isinstance(lit, str):
                ctype = "PrimitiveString"
            else:
                const_cache[k] = None
                return None
            const_id = f"{prefix}:const{k}"
            self.api[const_id] = {"class_type": ctype, "inputs": {"value": lit}}
            self.node_types[const_id] = ctype
            result = (const_id, 0)
            const_cache[k] = result
            return result

        # instantiate interior nodes
        for interior in sdef.get("nodes", []):
            itype = interior["type"]
            if itype in SKIP_TYPES or itype in PASSTHROUGH_TYPES:
                continue
            if itype in self.subgraph_defs:
                raise NotImplementedError(f"nested subgraph instance found (interior node {interior['id']}) - not supported")
            api_id = fresh(interior["id"])
            inputs_by_name = {i["name"]: i for i in interior.get("inputs", [])}
            widgets_values = interior.get("widgets_values", []) or []
            schema_items, schema, required_names = ordered_schema_inputs(itype)
            wname_override = {wn: v for (nid, wn), v in overrides.items() if nid == interior["id"]}
            result_inputs = {}
            self._consume_inputs(
                schema_items, inputs_by_name, widgets_values, 0,
                result_inputs, sub_link_resolver_factory(interior["id"]),
                node_label=f"{itype}#{api_id}", widget_override=wname_override,
                required_names=required_names, materialize_const=materialize_const,
            )
            self.api[api_id] = {"class_type": itype, "inputs": result_inputs}
            self.node_types[api_id] = itype

        # output boundary map
        output_map = {}
        for j, def_out in enumerate(sdef.get("outputs", [])):
            found = None
            for lid, link in sub_links.by_id.items():
                if link["target_id"] == -20 and link["target_slot"] == j:
                    found = link
                    break
            if found is None:
                warn(f"subgraph {sdef['name']} output slot {j} has no internal source link")
                continue
            oid, oslot = found["origin_id"], found["origin_slot"]
            output_map[j] = self._resolve_sub_source(oid, oslot, sub_nodes_by_id, sub_links, fresh)
        return output_map

    def _resolve_sub_source(self, oid, oslot, sub_nodes_by_id, sub_links, fresh):
        node = sub_nodes_by_id.get(oid)
        if node is None:
            raise KeyError(f"subgraph interior node {oid} not found")
        if node["type"] in PASSTHROUGH_TYPES:
            inp = node.get("inputs", [])
            if not inp or inp[0].get("link") is None:
                raise ValueError(f"interior Reroute {oid} has no input link")
            link = sub_links.by_id[inp[0]["link"]]
            if link["origin_id"] == -10:
                # reroute fed directly from subgraph boundary -- not expected in our workflows
                raise NotImplementedError("Reroute fed from subgraph boundary input not supported")
            return self._resolve_sub_source(link["origin_id"], link["origin_slot"], sub_nodes_by_id, sub_links, fresh)
        return (fresh(oid), oslot)

    def _positional_widget_value(self, node, wname):
        """Best-effort: compute the value that would be assigned to widget
        `wname` on `node` purely positionally from its own widgets_values,
        ignoring links/overrides. Returns _NOTFOUND if it can't be determined
        (e.g. dynamic combo nesting)."""
        try:
            schema_items, schema, required_names = ordered_schema_inputs(node["type"])
        except KeyError:
            return _NOTFOUND
        wv = node.get("widgets_values", []) or []
        idx = 0
        for name, spec in schema_items:
            type_name = spec[0] if isinstance(spec, list) else spec
            extra = spec[1] if isinstance(spec, list) and len(spec) > 1 else {}
            if type_name == "COMFY_DYNAMICCOMBO_V3":
                return _NOTFOUND  # not supported for this fallback path
            if is_widget_type(type_name):
                if name == wname:
                    return wv[idx] if idx < len(wv) else extra.get("default")
                idx += 1
                if isinstance(extra, dict) and extra.get("control_after_generate"):
                    idx += 1
        return _NOTFOUND

    def _link_origin_top(self, link_id):
        link = self.top_links.by_id[link_id]
        return (link["origin_id"], link["origin_slot"])


def convert_file(path):
    with open(path) as f:
        ui_graph = json.load(f)
    conv = Converter(ui_graph)
    api = conv.convert()
    return api, WARNINGS


if __name__ == "__main__":
    path = sys.argv[1]
    api, warnings = convert_file(path)
    print(json.dumps(api, indent=1))
    print(f"--- {len(warnings)} warnings ---", file=sys.stderr)
