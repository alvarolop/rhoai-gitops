# Exposing and testing the MaaS gateways

How each Models-as-a-Service tenant is exposed through the OpenShift router, why it is built this way, and how to check it with `maas/3-test.sh`. Verified on OpenShift 4.22 with OpenShift AI 3.5.4.

## 1. The shape

Every tenant has one `Gateway` (`maas-default-gateway` for the default tenant in `rhoai-installation-chart/templates/11-maas/2-gateway`, `maas-keycloak` in `maas-keycloak-chart`) and one `Route` in `openshift-ingress`.

```
 client ──TLS (Let's Encrypt wildcard)──▶ Route (passthrough) ──▶ Service (ClusterIP) ──▶ Gateway
                                                                                     │
   listener "https"           hostname = Route host, certificate = default certificate of the router (ingress-certs)
   listener "https-internal"  no hostname, certificate of the service CA (the in-cluster address of the models)
```

| Piece | Setting | Why |
|---|---|---|
| Route | `termination: passthrough`, host `maas.apps.<domain>` | The router does not terminate TLS, it forwards by SNI. The gateway presents the certificate, so the SNI is the Route host and a listener bound to that hostname accepts it |
| Listener `https` | `hostname` = Route host, `tlsSecret` (default `ingress-certs`) | `maas-api` reads the external host of `/v1/tenants` from `spec.listeners[].hostname`. The certificate is the default one of the router, so the users get a trusted certificate |
| Listener `https-internal` | no hostname, `<gateway>-internal-certs` (service CA, issued through the ConfigMap `parametersRef`) | Every model publishes `https://<gateway>-<class>.openshift-ingress.svc.cluster.local/...` as its first address. A hostname-bound listener resets any other SNI, so this one answers it |
| Service | `ClusterIP` (annotation `networking.istio.io/service-type`) | The Route is the entry point: no cloud load balancer |

`tlsSecret` is the secret named in `spec.defaultCertificate` of the default IngressController (`oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}'`), or `router-certs-default` when it has none. It must be in `openshift-ingress`. Argo CD renders the charts without cluster access, so it is a value, not a lookup.

## 2. What went wrong before (so you recognize it)

Until `0f9d155` / `9051ca9` the listeners had no hostname and the Routes were `reencrypt`. The router re-encrypted with the SNI of the Service, which a listener bound to a hostname resets (HTTP 503), so the hostname had been removed. Without it, `/v1/tenants` of `maas-api` 3.5.4 failed with `Failed to resolve gateway: Unable to determine external hostname from Gateway status`, and the `maas-ui` pod looped on `MaaS API discovery failed; will retry`, so the dashboard could not reach MaaS. Newer `maas-api` builds fall back to the OpenShift Route (opendatahub-io/models-as-a-service #1888), but 3.5.4 does not. The RHOAI docs use a listener with hostname, a router certificate and a Route, which is what this shape follows.

## 3. The test

The checks of this exposure (gateway, listeners, Route, certificate, `/maas-api/health`, `/v1/tenants`, internal address, dashboard, and an optional real request) are the script `maas/3-test.sh` of [rhoai-serving](https://github.com/alvarolop/rhoai-serving), documented in its [docs/011-maas.md](https://github.com/alvarolop/rhoai-serving/blob/main/docs/011-maas.md), together with what to do when a check fails. Run it after changing a gateway or a Route here:

```bash
maas/3-test.sh              # every tenant
maas/3-test.sh maas-keycloak
maas/4-test-inference.sh    # a real message per tenant
```

## 4. Known limits

- `DNSReady=False` ("The wildcard record resource was not found") on the public listener: the gateway controller expects to create a DNS record for the hostname, and a ClusterIP Service has no address. The host resolves through the cluster `*.apps` wildcard and everything works, so it is cosmetic.
- A renewal of the certificate in `tlsSecret` (Let's Encrypt) is not tested: check that the gateway serves the new one without a restart.
- The test uses the OpenShift token. A tenant with OIDC (Keycloak) answers 401 to `/v1/tenants` with it in some builds; it is reported as a warning, not a failure.
