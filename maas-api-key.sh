#!/bin/bash
# Creates a MaaS API key for a model and prints the variables that Open WebUI needs.
#
#   eval "$(./maas-api-key.sh [model] [expiration])"      # defaults: tinyllama-1b 90d
#   cat application-open-webui.yaml | OPENAI_API_URL=$OPENAI_API_URL OPENAI_API_KEY=$OPENAI_API_KEY envsubst | oc apply -f -
#
# The key is bound to ONE MaaSSubscription: the highest-priority one that includes the model (override with
# MAAS_SUBSCRIPTION). You must belong to one of its groups. The key is shown only once; revoke it with
# DELETE /maas-api/v1/api-keys/<id> (or from the dashboard: Gen AI studio > API keys).

set -euo pipefail

MODEL="${1:-tinyllama-1b}"
EXPIRES_IN="${2:-90d}"
MAAS_NAMESPACE="${MAAS_NAMESPACE:-models-as-a-service}"

oc whoami &> /dev/null || { echo "❌ You are not logged in. Please log in and run the script again." >&2; exit 1; }

MAAS_HOST=$(oc get route models-as-a-service -n openshift-ingress -o jsonpath='{.spec.host}')

SUBSCRIPTION="${MAAS_SUBSCRIPTION:-$(oc get maassubscription -n "$MAAS_NAMESPACE" -o json | jq -r --arg m "$MODEL" \
    '[.items[] | select(any(.spec.modelRefs[]; .name == $m))] | sort_by(-(.spec.priority // 0)) | .[0].metadata.name // empty')}"
[[ -n "$SUBSCRIPTION" ]] || { echo "❌ No MaaSSubscription includes the model '$MODEL'." >&2; exit 1; }

RESPONSE=$(curl -sS -X POST "https://$MAAS_HOST/maas-api/v1/api-keys" \
    -H "Authorization: Bearer $(oc whoami -t)" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$MODEL-$(date +%Y%m%d-%H%M%S)" --arg sub "$SUBSCRIPTION" --arg exp "$EXPIRES_IN" \
        '{name: $name, description: "Created by maas-api-key.sh", subscription: $sub, expiresIn: $exp}')")

API_KEY=$(jq -r '.key // empty' <<< "$RESPONSE")
[[ -n "$API_KEY" ]] || { echo "❌ Could not create the API key: $RESPONSE" >&2; exit 1; }

echo "✅ API key for '$MODEL' created (id: $(jq -r .id <<< "$RESPONSE"), subscription: $SUBSCRIPTION, expires in: $EXPIRES_IN)" >&2
echo "export OPENAI_API_URL=https://$MAAS_HOST/v1"
echo "export OPENAI_API_KEY=$API_KEY"
