# Red Hat Connectivity Link Dashboards

Four Grafana dashboards for monitoring RHCL gateways and APIs:

- **Platform Engineer** (20982) - Policy compliance, resource consumption, error rates, latency
- **App Developer** (21538) - API latency, throughput, error rates by path
- **Business User** (20981) - API usage trends, requests per second
- **DNS Operator** (22695) - DNS operations monitoring

## Update Dashboards

```bash
cd dashboards/
wget -O <dashboard-name>.json "https://grafana.com/api/dashboards/<ID>/revisions/latest/download"
```

Source: [RHCL 1.3 Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability_and_troubleshooting/index)
