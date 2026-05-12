# Open WebUI OIDC Configuration with OpenShift

This document explains how to configure Open WebUI to use OpenShift as an OIDC (OpenID Connect) identity provider for authentication.

## Overview

Open WebUI supports OAuth/OIDC authentication, and OpenShift can act as an OIDC provider. This configuration allows users to authenticate to Open WebUI using their OpenShift credentials.

## Prerequisites

1. OpenShift cluster with OAuth server enabled (default)
2. Access to create OAuthClient resources
3. The cluster domain name (e.g., `apps.cluster.example.com`)

## Configuration Variables

You need to set the following variables in `application-open-webui.yaml`:

| Variable | Description | Example |
|----------|-------------|---------|
| `$OPENSHIFT_CLUSTER_DOMAIN` | Your OpenShift cluster domain | `apps.cluster.example.com` |
| `$OAUTH_CLIENT_SECRET` | Secure random string for OAuth | Generate with `openssl rand -base64 32` |

## How It Works

### 1. OAuthClient Resource

The `OAuthClient` resource registers Open WebUI as an OAuth client with OpenShift:

```yaml
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: open-webui
secret: "$OAUTH_CLIENT_SECRET"
redirectURIs:
  - "https://open-webui-open-webui.apps.$OPENSHIFT_CLUSTER_DOMAIN/oauth/oidc/callback"
grantMethod: auto
```

**Key fields:**
- `name`: Used as `client_id` in OAuth flows
- `secret`: Shared secret for authentication
- `redirectURIs`: Where OpenShift redirects after authentication
- `grantMethod: auto`: Automatically grants access without user prompt

### 2. Open WebUI Environment Variables

Open WebUI needs these environment variables for OIDC:

```yaml
# Enable authentication
WEBUI_AUTH: "True"

# OAuth Configuration
ENABLE_OAUTH_SIGNUP: "true"
OAUTH_PROVIDER_NAME: "OpenShift"
OAUTH_CLIENT_ID: "open-webui"
OAUTH_CLIENT_SECRET: "<from secret>"
OPENID_PROVIDER_URL: "https://oauth-openshift.apps.$OPENSHIFT_CLUSTER_DOMAIN"
WEBUI_URL: "https://open-webui-open-webui.apps.$OPENSHIFT_CLUSTER_DOMAIN"
OAUTH_SCOPES: "openid email profile"
```

### 3. OAuth Flow

1. User visits Open WebUI
2. Clicks "Login with OpenShift"
3. Redirected to OpenShift OAuth server
4. User authenticates with OpenShift credentials
5. OpenShift redirects back to Open WebUI with authorization code
6. Open WebUI exchanges code for access token
7. User is logged in

## OIDC Discovery

OpenShift exposes OIDC configuration at:
```
https://oauth-openshift.apps.<cluster-domain>/.well-known/openid-configuration
```

This endpoint provides:
- Authorization endpoint
- Token endpoint
- UserInfo endpoint
- Supported scopes and claims
- Public keys for token validation

## Optional: Role-Based Access Control

You can enable role management from OpenShift groups:

```yaml
extraEnvVars:
  - name: ENABLE_OAUTH_ROLE_MANAGEMENT
    value: "true"
  - name: OAUTH_ROLES_CLAIM
    value: "groups"
  - name: OAUTH_ADMIN_ROLES
    value: "cluster-admins,open-webui-admins"
  - name: OAUTH_ALLOWED_ROLES
    value: "developers,data-scientists"
```

This maps OpenShift groups to Open WebUI roles:
- Users in `OAUTH_ADMIN_ROLES` groups become admins
- Users in `OAUTH_ALLOWED_ROLES` groups get regular access
- Others are denied access

## Security Considerations

### 1. OAuth Client Secret

**Generate a secure secret:**
```bash
openssl rand -base64 32
```

**Never commit the secret to Git** - use:
- Sealed Secrets
- External Secrets Operator
- ArgoCD vault plugin

### 2. Redirect URI Validation

OpenShift validates that redirect URIs match exactly. The format must be:
```
https://<open-webui-route>/oauth/oidc/callback
```

### 3. TLS/SSL

- Route must use TLS (`termination: edge`)
- OpenShift OAuth endpoints use HTTPS
- For custom CA certificates, mount them via configMap

### 4. Session Management

Configure session timeout with:
```yaml
- name: OAUTH_TOKEN_MAX_AGE
  value: "86400"  # 24 hours
```

## Troubleshooting

### "Invalid redirect URI" Error

**Cause:** Redirect URI in OAuthClient doesn't match the actual callback URL.

**Fix:** Ensure the redirect URI exactly matches:
```
https://open-webui-open-webui.apps.<cluster-domain>/oauth/oidc/callback
```

### "Cannot connect to OIDC provider"

**Cause:** OPENID_PROVIDER_URL is incorrect or unreachable.

**Fix:** Verify the OpenShift OAuth server URL:
```bash
oc get route oauth-openshift -n openshift-authentication
```

### "Invalid client credentials"

**Cause:** OAUTH_CLIENT_SECRET doesn't match the OAuthClient secret.

**Fix:** Ensure both the Secret and OAuthClient use the same value.

### SSL Certificate Errors

**Cause:** Self-signed certificates not trusted.

**Fix:** Mount the cluster CA bundle:
```yaml
volumes:
  - name: config-trusted-cabundle
    configMap:
      name: config-trusted-cabundle
volumeMounts:
  - name: config-trusted-cabundle
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca-bundle.crt

extraEnvVars:
  - name: SSL_CERT_FILE
    value: "/etc/ssl/certs/ca-certificates.crt"
```

### Users Can't Sign Up

**Cause:** `ENABLE_OAUTH_SIGNUP` is not enabled.

**Fix:** Set `ENABLE_OAUTH_SIGNUP: "true"` to allow new user registration via OAuth.

### Persistent Configuration Changes Not Applied

**Cause:** OAuth settings are stored in database after first launch.

**Fix:** Set this to force reading from environment variables:
```yaml
- name: ENABLE_OAUTH_PERSISTENT_CONFIG
  value: "false"
```

## Getting the Cluster Domain

```bash
# Get the cluster domain from an existing route
oc get route console -n openshift-console -o jsonpath='{.spec.host}' | sed 's/console-openshift-console\.//'

# Or from ingress config
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
```

## Example: Complete Configuration

```yaml
# Generate the secret first
OAUTH_SECRET=$(openssl rand -base64 32)

# Get cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Update the ArgoCD Application
sed -i "s/\$OPENSHIFT_CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" application-open-webui.yaml
sed -i "s/\$OAUTH_CLIENT_SECRET/$OAUTH_SECRET/g" application-open-webui.yaml
```

## Testing OIDC Configuration

1. **Verify OAuthClient exists:**
   ```bash
   oc get oauthclient open-webui
   ```

2. **Check Open WebUI logs:**
   ```bash
   oc logs -n open-webui -l app=open-webui --tail=100
   ```

3. **Test OIDC discovery:**
   ```bash
   curl -k https://oauth-openshift.apps.<cluster-domain>/.well-known/openid-configuration | jq
   ```

4. **Access Open WebUI:**
   ```bash
   echo "https://$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}')"
   ```

## References

- [Open WebUI OIDC Documentation](https://docs.openwebui.com/features/authentication-access/auth/sso/)
- [OpenShift OAuth Configuration](https://docs.openshift.com/container-platform/4.10/authentication/configuring-oauth-clients.html)
- [Open WebUI Environment Variables](https://docs.openwebui.com/reference/env-configuration/)
- [OpenShift as OIDC Provider (Medium)](https://medium.com/@muhammadadel612/openshift-authentication-implementing-oidc-identity-provider-3b3810c84423)

## Common OAuth Scopes

| Scope | Description |
|-------|-------------|
| `openid` | Required for OIDC, provides user ID |
| `email` | Provides user email address |
| `profile` | Provides user display name |
| `groups` | Provides user group memberships (for RBAC) |

## Migration from No-Auth to OIDC

If you're migrating from `WEBUI_AUTH: "False"`:

1. **Backup existing data:**
   ```bash
   oc exec -n open-webui deployment/open-webui -- tar czf /tmp/backup.tar.gz /app/backend/data
   ```

2. **Enable OAuth** in configuration

3. **First login creates admin:** The first user to log in via OAuth becomes admin

4. **Migrate existing users:** Manually recreate users or use API to import them

## Advanced: Custom Claims Mapping

Map OpenShift user attributes to Open WebUI fields:

```yaml
- name: OAUTH_USERNAME_CLAIM
  value: "preferred_username"
- name: OAUTH_EMAIL_CLAIM
  value: "email"
- name: OAUTH_NAME_CLAIM
  value: "name"
```
