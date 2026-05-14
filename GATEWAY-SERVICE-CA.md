# Gateway with Service CA Certificate Generation

This solution uses OpenShift Service CA operator to automatically generate TLS certificates for the Gateway without requiring cert-manager or external CA.

## How It Works

### 1. ConfigMap with Service Override

The `ConfigMap-openshift-ai-inference-service-override.yaml` contains a Service override configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-ai-inference-service-override
  namespace: openshift-ingress
data:
  service: |
    metadata:
      annotations:
        service.beta.openshift.io/serving-cert-secret-name: "openshift-ai-inference-gateway-tls"
    spec:
      type: ClusterIP
```

### 2. Gateway References ConfigMap

The Gateway uses `infrastructure.parametersRef` to inject the ConfigMap into the Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
spec:
  gatewayClassName: openshift-ai-inference
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: openshift-ai-inference-service-override
  listeners:
    - name: external
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - name: openshift-ai-inference-gateway-tls
```

### 3. Automatic Flow

1. **Gateway Controller** creates a Service for the Gateway
2. **ConfigMap override** injects the `service.beta.openshift.io/serving-cert-secret-name` annotation into the Service
3. **Service CA Operator** detects the annotation and automatically creates the TLS Secret
4. **Gateway** uses the auto-generated Secret for TLS termination

## Certificate DNS Names

The Service CA operator generates a certificate with DNS names based on the Service:

- `openshift-ai-inference-openshift-ai-inference.openshift-ingress.svc`
- `openshift-ai-inference-openshift-ai-inference.openshift-ingress.svc.cluster.local`

**Note**: The certificate will NOT include the Route hostname (`openshift-ai-inference.apps.<cluster-domain>`). This is expected and acceptable because:

1. The Route uses `reencrypt` termination - the Router handles external TLS with its own certificate
2. Internal applications (Nemo Guardrails) connect via Service DNS, which IS in the certificate
3. No certificate trust errors for internal connections

## Deployment

When you have cluster connectivity again, run:

```bash
./apply-gateway-service-ca.sh
```

Or manually:

```bash
# Apply ConfigMap
oc apply -f rhoai-installation-chart/templates/08-llm-d/ConfigMap-openshift-ai-inference-service-override.yaml

# Apply Gateway
oc apply -f rhoai-installation-chart/templates/08-llm-d/Gateway-openshift-ai-inference.yaml

# Wait for Service CA to generate certificate
sleep 10

# Verify
oc get secret openshift-ai-inference-gateway-tls -n openshift-ingress
```

## Advantages

✅ **No cert-manager required** - Uses built-in OpenShift Service CA  
✅ **Automatic certificate generation** - No manual Secret creation  
✅ **Automatic renewal** - Service CA handles certificate lifecycle  
✅ **Native OpenShift integration** - Uses standard Service CA pattern  
✅ **Simple configuration** - Just a ConfigMap and Gateway reference  

## Comparison with cert-manager Approach

| Feature | Service CA (This Approach) | cert-manager |
|---------|---------------------------|--------------|
| External CA Required | ❌ No | ✅ Yes (or self-signed) |
| Setup Complexity | ⭐ Low | ⭐⭐ Medium |
| Certificate DNS Names | Service DNS only | Configurable (multi-DNS) |
| Automatic Renewal | ✅ Yes | ✅ Yes |
| Route Hostname in Cert | ❌ No | ✅ Yes (if configured) |
| Internal Access Trust | ✅ Yes | ✅ Yes |

## Verification

Check that everything is configured correctly:

```bash
# 1. ConfigMap exists
oc get configmap openshift-ai-inference-service-override -n openshift-ingress

# 2. Gateway references ConfigMap
oc get gateway openshift-ai-inference -n openshift-ingress -o yaml | grep -A 5 "infrastructure:"

# 3. Service has annotation
oc get service openshift-ai-inference-openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}'

# 4. Secret exists
oc get secret openshift-ai-inference-gateway-tls -n openshift-ingress

# 5. Certificate DNS names
oc get secret openshift-ai-inference-gateway-tls -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | grep -A 2 "Subject Alternative Name"
```

## Troubleshooting

### Secret not created

**Problem**: Secret `openshift-ai-inference-gateway-tls` doesn't exist after several minutes.

**Solution**:
1. Check Service has the annotation:
   ```bash
   oc get service openshift-ai-inference-openshift-ai-inference -n openshift-ingress -o yaml | grep serving-cert
   ```
2. Check Service CA controller logs:
   ```bash
   oc logs -n openshift-service-ca-operator -l app=service-ca-operator
   ```

### Gateway not Programmed

**Problem**: Gateway status shows `Programmed: False`.

**Solution**:
1. Check Gateway events:
   ```bash
   oc describe gateway openshift-ai-inference -n openshift-ingress
   ```
2. Verify ConfigMap exists and is referenced correctly
3. Check Gateway controller logs

## References

- [OpenShift Service Serving Certificates](https://docs.openshift.com/container-platform/latest/security/certificates/service-serving-certificate.html)
- [Kubernetes Gateway API - Infrastructure](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.GatewayInfrastructure)
- [OpenShift Gateway Controller](https://github.com/openshift/ingress-operator)
