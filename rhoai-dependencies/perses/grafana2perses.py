#!/usr/bin/env python3
"""Convert Grafana dashboard JSON files into PersesDashboard (perses.dev/v1alpha2) manifests.

Usage: grafana2perses.py <out-dir> <name>=<grafana.json> [<name>=<grafana.json> ...]

Supported panels: timeseries, stat, gauge, bargauge, table, text, heatmap and state-timeline
(the last two are approximated with a TimeSeriesChart, since the Perses build shipped with COO
only has time series, stat, gauge, bar, table and markdown panels). Grafana alerts are not migrated.
Review the output: it is a mechanical translation, not a visual one.
"""
import json
import re
import sys
from pathlib import Path

import yaml

COLORS = {
    "red": "#E02F44", "green": "#56A64B", "yellow": "#F2CC0C", "orange": "#FF9830",
    "blue": "#3274D9", "purple": "#A352CC", "dark-red": "#8E1A2B", "dark-green": "#37872D",
    "dark-yellow": "#CC9D00", "dark-orange": "#C4720B", "dark-blue": "#1F60C4",
    "light-red": "#F2495C", "light-green": "#73BF69", "light-yellow": "#FADE2A",
    "light-orange": "#FF9830", "light-blue": "#5794F2", "semi-dark-red": "#C4162A",
    "semi-dark-green": "#37872D", "semi-dark-yellow": "#E0B400", "semi-dark-orange": "#FA6400",
    "text": "#B7B7B7", "super-light-green": "#C8F2C2", "super-light-red": "#FFA6B0",
}
UNITS = {
    "percent": "percent", "percentunit": "percent-decimal", "s": "seconds", "ms": "milliseconds",
    "µs": "microseconds", "ns": "nanoseconds", "m": "minutes", "h": "hours", "d": "days",
    "bytes": "bytes", "decbytes": "bytes", "Bps": "bytes/sec", "bps": "bits/sec",
    "reqps": "requests/sec", "ops": "ops/sec", "cps": "counts/sec", "wps": "writes/sec",
    "rps": "reads/sec", "pps": "packets/sec", "eps": "events/sec",
    "short": "decimal", "none": "decimal", "locale": "decimal", "": "decimal",
}
CALC = {"lastNotNull": "last", "last": "last", "mean": "mean", "max": "max", "min": "min",
        "sum": "sum", "first": "first", "firstNotNull": "first"}


def fmt(unit, decimals=None):
    f = {"unit": UNITS.get(unit or "", "decimal")}
    if decimals is not None:
        f["decimalPlaces"] = decimals
    return f


def thresholds(defaults):
    th = (defaults or {}).get("thresholds") or {}
    steps = th.get("steps") or []
    if not steps:
        return None
    out = {"steps": []}
    for s in steps:
        color = COLORS.get(s.get("color"), s.get("color") if str(s.get("color", "")).startswith("#") else None)
        if s.get("value") is None:
            if color:
                out["defaultColor"] = color
            continue
        step = {"value": s["value"]}
        if color:
            step["color"] = color
        out["steps"].append(step)
    return out if out["steps"] or "defaultColor" in out else None


def query(expr, legend=None):
    spec = {"query": expr}
    if legend:
        spec["seriesNameFormat"] = legend
    return {"kind": "TimeSeriesQuery",
            "spec": {"plugin": {"kind": "PrometheusTimeSeriesQuery", "spec": spec}}}


def clean(text):
    # Perses queries reuse the Grafana syntax for $var, $__interval, $__rate_interval and $__range.
    return text.replace("${DS_PROMETHEUS}", "").replace("$datasource", "")


def convert_panel(p):
    t = p["type"]
    d = (p.get("fieldConfig") or {}).get("defaults") or {}
    o = p.get("options") or {}
    display = {"name": p.get("title") or p["type"]}
    if p.get("description"):
        display["description"] = p["description"]
    targets = [x for x in p.get("targets", []) if x.get("expr") and not x.get("hide")]
    queries = [query(clean(x["expr"]), x.get("legendFormat") or None) for x in targets]
    calc = CALC.get(((o.get("reduceOptions") or {}).get("calcs") or ["lastNotNull"])[0], "last")
    unit = fmt(d.get("unit"), d.get("decimals"))
    th = thresholds(d)

    if t in ("timeseries", "heatmap", "state-timeline", "graph"):
        spec = {"legend": {"position": "bottom", "mode": "list"}, "yAxis": {"format": unit}}
        if d.get("min") is not None:
            spec["yAxis"]["min"] = d["min"]
        if d.get("max") is not None:
            spec["yAxis"]["max"] = d["max"]
        stack = ((d.get("custom") or {}).get("stacking") or {}).get("mode")
        if stack in ("normal", "percent"):
            spec["visual"] = {"stack": "all", "areaOpacity": 0.5}
        if t == "heatmap":
            display["description"] = (display.get("description", "") +
                                      " (Heatmap in Grafana; shown as one series per bucket.)").strip()
        plugin = {"kind": "TimeSeriesChart", "spec": spec}
    elif t == "stat":
        spec = {"calculation": calc, "format": unit}
        if th:
            spec["thresholds"] = th
        plugin = {"kind": "StatChart", "spec": spec}
    elif t == "gauge":
        spec = {"calculation": calc, "format": unit}
        if d.get("max") is not None:
            spec["max"] = d["max"]
        if th:
            spec["thresholds"] = th
        plugin = {"kind": "GaugeChart", "spec": spec}
    elif t == "bargauge":
        plugin = {"kind": "BarChart", "spec": {"calculation": calc, "format": unit, "sort": "desc",
                                              "mode": "value"}}
    elif t == "table":
        cols = [{"name": "timestamp", "hide": True}]
        excl, rename, order = {}, {}, {}
        for tr in p.get("transformations", []):
            if tr["id"] == "organize":
                excl = tr["options"].get("excludeByName", {})
                rename = tr["options"].get("renameByName", {})
                order = tr["options"].get("indexByName", {})
        for ov in (p.get("fieldConfig") or {}).get("overrides", []):
            for pr in ov.get("properties", []):
                if pr["id"] == "displayName":
                    rename[ov["matcher"]["options"]] = pr["value"]
        names = sorted(order, key=order.get)
        for n in names:
            cols.append({"name": n, "header": rename.get(n, n), "enableSorting": True})
        for n, hidden in excl.items():
            if hidden and n not in ("Time", "Value"):
                cols.append({"name": n, "hide": True})
        spec = {"density": "compact", "pagination": True, "columnSettings": cols}
        if len(queries) > 1:
            spec["transforms"] = [{"kind": "MergeSeries", "spec": {}}]
        plugin = {"kind": "Table", "spec": spec}
    elif t == "text":
        plugin = {"kind": "Markdown", "spec": {"text": o.get("content", "")}}
        return {"kind": "Panel", "spec": {"display": display, "plugin": plugin}}
    else:
        raise SystemExit(f"unsupported panel type {t!r} ({p.get('title')})")
    return {"kind": "Panel", "spec": {"display": display, "plugin": plugin, "queries": queries}}


def convert_variable(v):
    name = v["name"]
    display = {"name": v.get("label") or name, "hidden": v.get("hide", 0) == 2}
    if v["type"] == "datasource":
        return None  # the default PersesGlobalDatasource is used
    if v["type"] == "textbox":
        return {"kind": "TextVariable", "spec": {"name": name, "value": v.get("query", ""), "display": display}}
    if v["type"] == "custom":
        vals = [x.strip() for x in v["query"].split(",")]
        plugin = {"kind": "StaticListVariable", "spec": {"values": vals}}
    else:
        q = v["query"]["query"] if isinstance(v["query"], dict) else v["query"]
        m = re.fullmatch(r"\s*label_values\((?:(.+),\s*)?(\w+)\)\s*", q, re.S)
        if not m:
            raise SystemExit(f"unsupported variable query {q!r}")
        spec = {"labelName": m.group(2)}
        if m.group(1):
            spec["matchers"] = [clean(m.group(1)).strip()]
        plugin = {"kind": "PrometheusLabelValuesVariable", "spec": spec}
    multi = bool(v.get("multi")) or bool(v.get("includeAll"))
    out = {"name": name, "display": display, "allowMultiple": bool(v.get("multi")),
           "allowAllValue": bool(v.get("includeAll")), "plugin": plugin}
    if v.get("includeAll"):
        out["defaultValue"] = "$__all"
    elif multi is False:
        pass
    return {"kind": "ListVariable", "spec": out}


def flatten(panels):
    """Yield (row_title|None, collapsed, panel); rows own the panels after them (or their .panels)."""
    row, collapsed = None, False
    for p in sorted(panels, key=lambda x: (x["gridPos"]["y"], x["gridPos"]["x"])):
        if p["type"] == "dashlist":
            continue  # Grafana navigation list, no Perses equivalent
        if p["type"] == "row":
            row, collapsed = p.get("title"), p.get("collapsed", False)
            for sub in sorted(p.get("panels", []), key=lambda x: (x["gridPos"]["y"], x["gridPos"]["x"])):
                yield row, collapsed, sub
        else:
            yield row, collapsed, p


def convert(grafana, name):
    panels, groups, order = {}, {}, []
    for row, collapsed, p in flatten(grafana["panels"]):
        pid = f"p{p['id']}"
        panels[pid] = convert_panel(p)
        if row not in groups:
            groups[row] = {"collapsed": collapsed, "items": []}
            order.append(row)
        g = p["gridPos"]
        groups[row]["items"].append((g, pid))
    layouts = []
    for row in order:
        items = groups[row]["items"]
        y0 = min(g["y"] for g, _ in items)
        spec = {"items": [{"x": g["x"], "y": g["y"] - y0, "width": g["w"], "height": g["h"],
                            "content": {"$ref": f"#/spec/panels/{pid}"}} for g, pid in items]}
        if row:
            spec["display"] = {"title": row, "collapse": {"open": not groups[row]["collapsed"]}}
        layouts.append({"kind": "Grid", "spec": spec})
    variables = [x for x in (convert_variable(v) for v in grafana.get("templating", {}).get("list", [])) if x]
    time_from = (grafana.get("time") or {}).get("from", "now-1h")
    duration = re.sub(r"^now-", "", time_from)
    cfg = {"display": {"name": grafana.get("title", name)}, "duration": duration,
           "variables": variables, "panels": panels, "layouts": layouts}
    if grafana.get("description"):
        cfg["display"]["description"] = grafana["description"]
    return {"apiVersion": "perses.dev/v1alpha2", "kind": "PersesDashboard",
            "metadata": {"name": name, "namespace": "perses-dashboards", "annotations": {
                    "argocd.argoproj.io/sync-wave": "6",
                    "argocd.argoproj.io/sync-options": "SkipDryRunOnMissingResource=true"}}, "spec": {"config": cfg}}


class Dumper(yaml.SafeDumper):
    pass


Dumper.add_representer(str, lambda d, s: d.represent_scalar(
    "tag:yaml.org,2002:str", s, style="|" if "\n" in s else None))


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for arg in sys.argv[2:]:
        name, path = arg.split("=", 1)
        doc = convert(json.loads(Path(path).read_text()), name)
        (out / f"PersesDashboard-{name}.yaml").write_text(
            "---\n" + yaml.dump(doc, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=120))
        print(name, len(doc["spec"]["config"]["panels"]), "panels")


if __name__ == "__main__":
    main()
