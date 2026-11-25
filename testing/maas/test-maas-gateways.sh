#!/bin/bash
# Checks the exposure of every MaaS tenant (gateway + Route + certificate + maas-api + dashboard). Read-only by default.
#
#   ./test-maas-gateways.sh              # all tenants (AITenant), dashboard included
#   ./test-maas-gateways.sh --inference  # also creates a short-lived API key, calls the model of the default tenant and revokes the key
#
# See docs/maas-gateway.md for what each check proves and what to do when it fails. Needs: oc (logged in), curl, jq, openssl.

set -uo pipefail

INFERENCE=false; [[ "${1:-}" == "--inference" ]] && INFERENCE=true
GW_NS=openshift-ingress
FAILS=0
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAILS=$((FAILS+1)); }
warn() { echo "  ⚠️  $*"; }

oc whoami &> /dev/null || { echo "❌ You are not logged in. Please log in and run the script again." >&2; exit 1; }
TOKEN=$(oc whoami -t)

# In-cluster caller used to test the internal address of the gateways (maas-ui has curl)
incluster() { oc exec -n redhat-ods-applications deploy/maas-ui -- "$@" 2>/dev/null; }

for TENANT in $(oc get aitenant -A -o json | jq -r '.items[] | "\(.metadata.name):\(.spec.gateway.name // .metadata.name)"'); do
    NAME=${TENANT%%:*}; GW=${TENANT##*:}
    echo "== Tenant $NAME (gateway $GW)"

    # 1. Gateway: Programmed, a listener with hostname (maas-api reads it in /v1/tenants) and the internal listener without it
    GWJSON=$(oc get gateway "$GW" -n $GW_NS -o json 2>/dev/null) || { bad "Gateway $GW not found in $GW_NS"; continue; }
    [[ $(jq -r '[.status.conditions[]|select(.type=="Programmed")][0].status' <<< "$GWJSON") == True ]] && ok "Gateway Programmed" || bad "Gateway not Programmed"
    HOST=$(jq -r '[.spec.listeners[].hostname // empty][0] // empty' <<< "$GWJSON")
    [[ -n "$HOST" ]] && ok "Listener with hostname: $HOST" || bad "No listener has a hostname: /v1/tenants (and the dashboard) fails with 'Unable to determine external hostname'"
    [[ $(jq '[.spec.listeners[]|select(.hostname == null)]|length' <<< "$GWJSON") -ge 1 ]] && ok "Internal listener without hostname" || warn "No listener without hostname: the in-cluster address of the models will not answer"
    NOTPROG=$(jq -r '[.status.listeners[]|select(([.conditions[]|select(.type=="Programmed")][0].status)!="True")|.name]|join(",")' <<< "$GWJSON")
    [[ -z "$NOTPROG" ]] && ok "All listeners Programmed" || bad "Listeners not Programmed: $NOTPROG"

    # 2. Route: passthrough and same host as the listener
    ROUTE=$(oc get route -n $GW_NS -l gateway.networking.k8s.io/gateway-name="$GW" -o json | jq -c '.items[0] // empty')
    if [[ -z "$ROUTE" ]]; then bad "No Route with the label gateway.networking.k8s.io/gateway-name=$GW"; continue; fi
    TERM=$(jq -r .spec.tls.termination <<< "$ROUTE"); RHOST=$(jq -r .spec.host <<< "$ROUTE")
    [[ "$TERM" == passthrough ]] && ok "Route $RHOST is passthrough" || bad "Route termination is '$TERM' (expected passthrough: reencrypt resets against a listener with hostname -> HTTP 503)"
    [[ "$RHOST" == "$HOST" ]] && ok "Route host = listener hostname" || bad "Route host ($RHOST) differs from the listener hostname ($HOST)"

    # 3. Certificate that the users get: valid for the host and trusted by the system store
    OUT=$(echo | openssl s_client -connect "$RHOST:443" -servername "$RHOST" -verify_hostname "$RHOST" 2>/dev/null)
    if grep -q "Verification: OK" <<< "$OUT"; then
        ok "Certificate trusted and valid for $RHOST ($(openssl x509 -noout -issuer <<< "$(sed -n '/BEGIN CERT/,/END CERT/p' <<< "$OUT")" | sed 's/issuer=//'))"
    else
        bad "Certificate not trusted or not valid for $RHOST: $(grep -m1 'Verification' <<< "$OUT")"
    fi

    # 4. maas-api through the Route
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$RHOST/maas-api/health")
    [[ "$CODE" == 200 ]] && ok "/maas-api/health 200" || bad "/maas-api/health $CODE"
    RESP=$(curl -s --max-time 10 -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "https://$RHOST/maas-api/v1/tenants")
    CODE=${RESP##*$'\n'}; BODY=${RESP%$'\n'*}
    if [[ "$CODE" == 200 ]]; then
        EXT=$(jq -r '.tenants[0].gateway.externalUrl' <<< "$BODY")
        [[ "$EXT" == "https://$RHOST" ]] && ok "/v1/tenants 200, externalUrl $EXT" || bad "/v1/tenants externalUrl is $EXT (expected https://$RHOST)"
    elif [[ "$CODE" == 401 || "$CODE" == 403 ]]; then
        warn "/v1/tenants $CODE: this tenant does not accept the OpenShift token (OIDC tenant); test it with its own token"
    else
        bad "/v1/tenants $CODE: $(jq -r '.details // .error // .' <<< "$BODY" 2>/dev/null | head -c 200)"
    fi

    # 5. Internal address (the first URL in the status of every model): answered by the listener without hostname
    SVC=$(oc get svc -n $GW_NS -l gateway.networking.k8s.io/gateway-name="$GW" -o jsonpath='{.items[0].metadata.name}')
    if [[ -n "$SVC" ]]; then
        CODE=$(incluster curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$SVC.$GW_NS.svc.cluster.local/maas-api/health")
        [[ "$CODE" == 200 ]] && ok "Internal address $SVC answers 200" || bad "Internal address $SVC answers '${CODE:-no answer}' (SNI reset: the listener without hostname is missing?)"
    fi
done

# 6. maas-ui finds the API (this was the symptom: "MaaS API discovery failed; will retry")
echo "== Dashboard"
LAST=$(oc logs -n redhat-ods-applications deploy/maas-ui --since=5m 2>/dev/null | grep -E "discovery failed|discovered" | tail -1)
if grep -q "discovery failed" <<< "$LAST"; then bad "maas-ui: $(cut -c1-200 <<< "$LAST")"
elif [[ -n "$LAST" ]]; then ok "maas-ui discovered the API"
else warn "maas-ui logged neither discovery nor failure in the last 5 minutes (already discovered; restart it to force a new discovery)"; fi

DASH=$(oc get route rh-ai -n $GW_NS -o jsonpath='{.spec.host}' 2>/dev/null || oc get route data-science-gateway -n $GW_NS -o jsonpath='{.spec.host}')
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $TOKEN" "https://$DASH/maas/api/v1/models")
[[ "$CODE" == 200 ]] && ok "Dashboard backend /maas/api/v1/models 200" || bad "Dashboard backend /maas/api/v1/models $CODE"

# 7. Optional: the whole path with a real request (creates and deletes an API key of the default tenant)
if $INFERENCE; then
    echo "== Inference through the default tenant"
    MHOST=$(oc get route models-as-a-service -n $GW_NS -o jsonpath='{.spec.host}')
    SUB=$(curl -s -H "Authorization: Bearer $TOKEN" "https://$MHOST/maas-api/v1/subscriptions" | jq -r '(if type=="array" then . else .data end) | sort_by(.priority) | .[0].subscription_id_header // empty')
    KEY=$(curl -s -X POST "https://$MHOST/maas-api/v1/api-keys" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg s "$SUB" '{name:"test-maas-gateways", description:"Created by test-maas-gateways.sh", subscription:$s, expiresIn:"1h"}')")
    SECRET=$(jq -r '.key // empty' <<< "$KEY"); KID=$(jq -r '.id // empty' <<< "$KEY")
    if [[ -z "$SECRET" ]]; then bad "Could not create the API key: $(head -c 200 <<< "$KEY")"; else
        MODEL=$(curl -s -H "Authorization: Bearer $SECRET" "https://$MHOST/v1/models" | jq -r '.data[0].id // empty')
        if [[ -z "$MODEL" ]]; then bad "/v1/models returned no model"; else
            CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "https://$MHOST/v1/chat/completions" -H "Authorization: Bearer $SECRET" \
                -H "Content-Type: application/json" -d "$(jq -n --arg m "$MODEL" '{model:$m, messages:[{role:"user",content:"Say hi"}], max_tokens:5}')")
            [[ "$CODE" == 200 ]] && ok "Chat completion on $MODEL: 200" || bad "Chat completion on $MODEL: $CODE"
        fi
        curl -s -o /dev/null -X DELETE "https://$MHOST/maas-api/v1/api-keys/$KID" -H "Authorization: Bearer $TOKEN" && ok "API key revoked"
    fi
fi

echo
[[ $FAILS -eq 0 ]] && echo "✅ All checks passed" || { echo "❌ $FAILS check(s) failed"; exit 1; }
