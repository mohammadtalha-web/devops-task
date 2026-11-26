#!/usr/bin/env python3
"""Generates the Grafana dashboard JSON files in monitoring/grafana/dashboards/.
The JSON files are the source of truth that Grafana provisions; this script only
exists so panel definitions are not hand-edited 300 lines at a time."""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "monitoring/grafana/dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
_id = 0


def _next():
    global _id
    _id += 1
    return _id


def timeseries(title, queries, x, y, w=12, h=8, unit="short", desc="", minv=None, maxv=None, thresholds=None):
    targets = [
        {"refId": chr(65 + i), "datasource": PROM, "expr": e, "legendFormat": l}
        for i, (e, l) in enumerate(queries)
    ]
    defaults = {"unit": unit, "custom": {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never"}}
    if minv is not None:
        defaults["min"] = minv
    if maxv is not None:
        defaults["max"] = maxv
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        defaults["custom"]["thresholdsStyle"] = {"mode": "line"}
    return {
        "id": _next(), "type": "timeseries", "title": title, "description": desc, "datasource": PROM,
        "gridPos": {"x": x, "y": y, "w": w, "h": h}, "targets": targets,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def stat(title, expr, x, y, w=6, h=4, unit="short", thresholds=None, desc=""):
    steps = thresholds or [{"color": "green", "value": None}]
    return {
        "id": _next(), "type": "stat", "title": title, "description": desc, "datasource": PROM,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [{"refId": "A", "datasource": PROM, "expr": expr}],
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
    }


def logs(title, expr, x, y, w=24, h=10):
    return {
        "id": _next(), "type": "logs", "title": title, "datasource": LOKI,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [{"refId": "A", "datasource": LOKI, "expr": expr, "queryType": "range"}],
        "options": {"showTime": True, "wrapLogMessage": True, "enableLogDetails": True,
                    "sortOrder": "Descending", "dedupStrategy": "none", "prettifyLogMessage": False},
    }


def dashboard(uid, title, tags, panels, refresh="10s"):
    return {
        "uid": uid, "title": title, "tags": tags, "schemaVersion": 39, "version": 1, "editable": True,
        "timezone": "browser", "refresh": refresh, "time": {"from": "now-1h", "to": "now"},
        "graphTooltip": 1, "annotations": {"list": []}, "templating": {"list": []}, "panels": panels,
    }


def write(name, dash):
    (OUT / name).write_text(json.dumps(dash, indent=2) + "\n")
    print("wrote", name)


GREEN_RED = lambda v: [{"color": "green", "value": None}, {"color": "red", "value": v}]
GYR = lambda y, r: [{"color": "green", "value": None}, {"color": "yellow", "value": y}, {"color": "red", "value": r}]

# ------------------------------------------------------------------ Application
app = [
    stat("Instances up", 'sum(up{job="app"})', 0, 0, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
    stat("Request rate", "sum(rate(http_requests_total[1m]))", 6, 0, unit="reqps"),
    stat("5xx error ratio (5m)",
         "sum(rate(http_errors_total[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 0.0001)",
         12, 0, unit="percentunit", thresholds=GYR(0.01, 0.05)),
    stat("p95 latency (5m)",
         "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))",
         18, 0, unit="s", thresholds=GYR(0.25, 0.5)),
    timeseries("Request rate by route", [("sum by (route) (rate(http_requests_total[1m]))", "{{route}}")],
               0, 4, unit="reqps", desc="Requests per second, split by (bounded) route label."),
    timeseries("Request rate by status", [("sum by (status) (rate(http_requests_total[1m]))", "{{status}}")],
               12, 4, unit="reqps"),
    timeseries("Error rate (5xx)", [
        ("sum(rate(http_errors_total[1m]))", "errors/s"),
        ("sum(rate(http_errors_total[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 0.0001)", "error ratio"),
    ], 0, 12, unit="short", desc="Absolute 5xx/s and ratio of all requests.", minv=0),
    timeseries("Latency percentiles", [
        ("histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))", "p50"),
        ("histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))", "p95"),
        ("histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))", "p99"),
    ], 12, 12, unit="s", minv=0),
    logs("App error & warning logs (same time range as the panels above)",
         '{service="app", level=~"error|warn"}', 0, 20),
    logs("All app logs for the failing route (edit the route filter)",
         '{service="app"} | route="/boom" | json', 0, 30),
]
write("application.json", dashboard("app-overview", "Application", ["app"], app))

# ------------------------------------------------------------------ Host
FS = 'fstype!~"tmpfs|overlay|squashfs|ramfs"'
host = [
    stat("CPU usage", '100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100', 0, 0, unit="percent", thresholds=GYR(70, 90)),
    stat("Memory usage", "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100", 6, 0, unit="percent", thresholds=GYR(75, 90)),
    stat("Root disk usage", f'(1 - node_filesystem_avail_bytes{{mountpoint="/",{FS}}} / node_filesystem_size_bytes{{mountpoint="/",{FS}}}) * 100',
         12, 0, unit="percent", thresholds=GYR(70, 80)),
    stat("Load avg (1m)", "node_load1", 18, 0, thresholds=GYR(2, 4)),
    timeseries("CPU usage by mode", [("sum by (mode) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) * 100", "{{mode}}")],
               0, 4, unit="percent", minv=0),
    timeseries("Memory", [
        ("node_memory_MemTotal_bytes", "total"),
        ("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "used"),
        ("node_memory_MemAvailable_bytes", "available"),
    ], 12, 4, unit="bytes", minv=0),
    timeseries("Disk usage by mount point", [
        (f"(1 - node_filesystem_avail_bytes{{{FS}}} / node_filesystem_size_bytes{{{FS}}}) * 100", "{{mountpoint}}"),
    ], 0, 12, unit="percent", minv=0, maxv=100, thresholds=GREEN_RED(80), desc="Alert fires above 80% for 15m."),
    timeseries("Disk I/O", [
        ("sum(rate(node_disk_read_bytes_total[5m]))", "read"),
        ("sum(rate(node_disk_written_bytes_total[5m]))", "write"),
    ], 12, 12, unit="Bps"),
    timeseries("Network traffic", [
        ('sum by (device) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[5m]))', "rx {{device}}"),
        ('sum by (device) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[5m]))', "tx {{device}}"),
    ], 0, 20, unit="Bps", desc="Seen from node-exporter's network namespace (see README caveat)."),
    timeseries("Load average", [("node_load1", "1m"), ("node_load5", "5m"), ("node_load15", "15m")], 12, 20, minv=0),
]
write("host.json", dashboard("host-overview", "Host (Node Exporter)", ["host"], host))

# ------------------------------------------------------------------ Containers
C = 'name!=""'
cont = [
    timeseries("CPU usage per container (cores)", [(f"sum by (name) (rate(container_cpu_usage_seconds_total{{{C}}}[5m]))", "{{name}}")],
               0, 0, unit="short", minv=0),
    timeseries("Memory working set per container", [(f"max by (name) (container_memory_working_set_bytes{{{C}}})", "{{name}}")],
               12, 0, unit="bytes", minv=0),
    timeseries("Memory usage relative to limit", [
        (f"max by (name) (container_memory_working_set_bytes{{{C}}}) / max by (name) (container_spec_memory_limit_bytes{{{C}}} > 0)", "{{name}}"),
    ], 0, 8, unit="percentunit", minv=0, maxv=1, thresholds=GYR(0.75, 0.9),
        desc="Working set divided by the configured memory limit. Alert fires above 90% for 5m."),
    timeseries("Memory limit per container", [(f"max by (name) (container_spec_memory_limit_bytes{{{C}}} > 0)", "{{name}}")],
               12, 8, unit="bytes", minv=0),
    timeseries("Network receive per container", [(f"sum by (name) (rate(container_network_receive_bytes_total{{{C}}}[5m]))", "{{name}}")],
               0, 16, unit="Bps"),
    timeseries("Network transmit per container", [(f"sum by (name) (rate(container_network_transmit_bytes_total{{{C}}}[5m]))", "{{name}}")],
               12, 16, unit="Bps"),
    timeseries("CPU throttling (fraction of periods throttled)", [
        (f"sum by (name) (rate(container_cpu_cfs_throttled_periods_total{{{C}}}[5m])) / clamp_min(sum by (name) (rate(container_cpu_cfs_periods_total{{{C}}}[5m])), 0.0001)", "{{name}}"),
    ], 0, 24, unit="percentunit", minv=0, desc="Sustained throttling means the CPU limit is too low."),
    logs("Container logs (all services)", '{container=~".+"}', 12, 24, w=12),
]
write("containers.json", dashboard("containers-overview", "Containers (cAdvisor)", ["containers"], cont))
