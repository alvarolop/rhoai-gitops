#!/bin/bash
set -e

echo "🔧 Aplicando configuración de Gateway con Service CA"
echo ""

# Cleanup cert-manager resources if they exist
echo "🧹 Limpiando recursos de cert-manager..."
oc delete certificate openshift-ai-inference-serving-cert -n openshift-ingress 2>/dev/null || true
oc delete issuer openshift-ai-inference-selfsigned-issuer -n openshift-ingress 2>/dev/null || true
oc delete secret openshift-ai-inference-gateway-tls -n openshift-ingress 2>/dev/null || true

echo ""
echo "📝 Aplicando ConfigMap con anotación Service CA..."
helm template rhoai-installation-chart \
  --namespace rhoai-installation \
  --values rhoai-installation-chart/values.yaml \
  --show-only templates/08-llm-d/ConfigMap-openshift-ai-inference-service-override.yaml | \
  oc apply -f -

echo ""
echo "🌐 Aplicando Gateway con infrastructure.parametersRef..."
helm template rhoai-installation-chart \
  --namespace rhoai-installation \
  --values rhoai-installation-chart/values.yaml \
  --show-only templates/08-llm-d/Gateway-openshift-ai-inference.yaml | \
  oc apply -f -

echo ""
echo "⏳ Esperando a que el Service CA genere el certificado..."
sleep 10

echo ""
echo "✅ Verificando recursos:"
echo ""
echo "ConfigMap:"
oc get configmap openshift-ai-inference-service-override -n openshift-ingress

echo ""
echo "Gateway:"
oc get gateway openshift-ai-inference -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")]}' | jq -r '"Status: \(.status)\nMessage: \(.message)"'

echo ""
echo "Service (generado automáticamente por Gateway controller):"
oc get service openshift-ai-inference-openshift-ai-inference -n openshift-ingress -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}'
echo ""

echo ""
echo "Secret TLS (generado por Service CA operator):"
oc get secret openshift-ai-inference-gateway-tls -n openshift-ingress 2>/dev/null || echo "⚠️  Secret aún no generado. Espera unos segundos y verifica con: oc get secret openshift-ai-inference-gateway-tls -n openshift-ingress"

echo ""
echo "🎯 Configuración completa!"
