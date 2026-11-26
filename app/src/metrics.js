'use strict';

// Hand-rolled Prometheus text exposition (format 0.0.4). The service therefore has
// zero runtime dependencies: smaller image, nothing to patch, nothing for Trivy to flag.

const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];

const esc = (v) => String(v).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');
const fmt = (labels) => {
  const keys = Object.keys(labels);
  return keys.length ? `{${keys.map((k) => `${k}="${esc(labels[k])}"`).join(',')}}` : '';
};

class Metrics {
  /**
   * @param {{version:string, environment:string, knownRoutes?:string[]}} opts
   * Route label values are a fixed allow-list (+ "unmatched") so label cardinality is bounded.
   */
  constructor({ version, environment, knownRoutes = [] }) {
    this.info = { version, environment };
    this.startTime = Date.now() / 1000;
    this.requests = new Map(); // method|route|status -> count
    this.errors = new Map(); //   method|route -> count (HTTP 5xx)
    this.durations = new Map(); // method|route -> histogram
    // Pre-create zero-valued error series so rate()/alerts work before the first failure.
    for (const route of knownRoutes) this.errors.set(`GET|${route}`, { labels: { method: 'GET', route }, value: 0 });
  }

  observe({ method, route, status, seconds }) {
    const rKey = `${method}|${route}|${status}`;
    const r = this.requests.get(rKey) || { labels: { method, route, status: String(status) }, value: 0 };
    r.value += 1;
    this.requests.set(rKey, r);

    const eKey = `${method}|${route}`;
    const e = this.errors.get(eKey) || { labels: { method, route }, value: 0 };
    if (status >= 500) e.value += 1;
    this.errors.set(eKey, e);

    const h = this.durations.get(eKey) || {
      labels: { method, route }, counts: new Array(BUCKETS.length).fill(0), sum: 0, count: 0,
    };
    const idx = BUCKETS.findIndex((b) => seconds <= b);
    if (idx >= 0) h.counts[idx] += 1;
    h.sum += seconds;
    h.count += 1;
    this.durations.set(eKey, h);
  }

  render() {
    const out = [];
    out.push('# HELP app_info Static application info (value is always 1).', '# TYPE app_info gauge');
    out.push(`app_info${fmt(this.info)} 1`);

    out.push('# HELP http_requests_total Total HTTP requests.', '# TYPE http_requests_total counter');
    for (const { labels, value } of this.requests.values()) out.push(`http_requests_total${fmt(labels)} ${value}`);

    out.push('# HELP http_errors_total Total HTTP responses with status >= 500.', '# TYPE http_errors_total counter');
    for (const { labels, value } of this.errors.values()) out.push(`http_errors_total${fmt(labels)} ${value}`);

    out.push('# HELP http_request_duration_seconds HTTP request latency.', '# TYPE http_request_duration_seconds histogram');
    for (const h of this.durations.values()) {
      let cumulative = 0;
      BUCKETS.forEach((le, i) => {
        cumulative += h.counts[i];
        out.push(`http_request_duration_seconds_bucket${fmt({ ...h.labels, le })} ${cumulative}`);
      });
      out.push(`http_request_duration_seconds_bucket${fmt({ ...h.labels, le: '+Inf' })} ${h.count}`);
      out.push(`http_request_duration_seconds_sum${fmt(h.labels)} ${h.sum}`);
      out.push(`http_request_duration_seconds_count${fmt(h.labels)} ${h.count}`);
    }

    out.push('# HELP process_start_time_seconds Process start time (unix seconds).', '# TYPE process_start_time_seconds gauge');
    out.push(`process_start_time_seconds ${this.startTime}`);
    out.push('# HELP process_resident_memory_bytes Resident memory size.', '# TYPE process_resident_memory_bytes gauge');
    out.push(`process_resident_memory_bytes ${process.memoryUsage().rss}`);
    return `${out.join('\n')}\n`;
  }
}

module.exports = { Metrics, BUCKETS };
