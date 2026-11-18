# Perses dashboards in the OpenShift console

Native dashboards under **Observe → Dashboards (Perses)**. Part of the `rhoai-dependencies` Kustomize (needs `operator-coo`, Cluster Observability Operator ≥ 1.5).

**Support level:** Perses dashboards are **GA** since COO 1.5 (OpenShift 4.22); they were Technology Preview in COO 1.4. The RHOAI built-in dashboards are also PersesDashboards (`redhat-ods-monitoring`), but the MaaS Usage dashboard is documented as Technology Preview in RHOAI 3.5.

| File | What it does |
|---|---|
| `UIPlugin.yaml` | Enables the monitoring plugin with Perses (creates a Perses server and the console menu) |
| `sa-/crb-/Secret-…` | ServiceAccount with `cluster-monitoring-view` and its token, used by Perses to query Thanos |
| `PersesGlobalDatasource-thanos-querier-datasource.yaml` | Default datasource for every dashboard: OpenShift Thanos Querier (platform + user-workload metrics) |
| `rb-dashboards-viewer.yaml` | Lets authenticated users view the dashboards namespace (`perses-dashboards`) |
| `dashboards/` | 11 dashboards converted from Grafana: llm-d (5), MaaS (2), RHCL (4) |

The dashboards read the OpenShift monitoring stack, the same one the Grafana datasource uses. They do **not** read the RHOAI platform stack (`data-science-prometheus-datasource`), so the llm-d/MaaS metrics need user-workload monitoring and the PodMonitors (see `docs/monitoring-models.md`).

## Regenerate from Grafana

`grafana2perses.py` converts Grafana JSON (timeseries, stat, gauge, bargauge, table, text; heatmap and state-timeline become time series). The Grafana `datasource` variable is dropped (the default datasource is used) and `dashlist` panels are skipped.

```bash
python3 rhoai-dependencies/perses/grafana2perses.py rhoai-dependencies/perses/dashboards <name>=<grafana.json> ...
```

Validate against a Perses server (`POST /api/validate/dashboards`) before committing. The Grafana originals are kept untouched.
